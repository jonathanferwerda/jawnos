//! The control socket is the seam the manager drives, so it is tested the way
//! it will be used: a spawned `--serve` process, a `UnixStream`, one line out,
//! one line back. No sound card anywhere — the backend is `null`.

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

/// A running `--serve`, killed however the test ends.
struct Server {
    child: Option<Child>,
    socket: PathBuf,
}

impl Server {
    fn start(name: &str) -> Self {
        let socket = std::env::temp_dir().join(format!(
            "jawn-audio-sock-{}-{name}.sock",
            std::process::id()
        ));
        let _ = fs::remove_file(&socket);
        let child = Command::new(env!("CARGO_BIN_EXE_jawn-audio"))
            .args(["--serve", "--backend", "null", "--socket"])
            .arg(&socket)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .expect("spawn --serve");
        // Generous: under a loaded suite a spawn plus a bind can take seconds.
        let deadline = Instant::now() + Duration::from_secs(60);
        while !socket.exists() {
            assert!(
                Instant::now() < deadline,
                "the server never created its socket"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        Server {
            child: Some(child),
            socket,
        }
    }

    fn connect(&self) -> Conversation {
        Conversation::open(&self.socket)
    }

    /// Wait for the served process and answer with its output and whether its
    /// socket file is still there.
    fn finish(mut self) -> (Output, bool) {
        let child = self.child.take().expect("the server is running");
        let output = child.wait_with_output().expect("wait for --serve");
        (output, self.socket.exists())
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = fs::remove_file(&self.socket);
    }
}

/// One client: the writing half and a buffered reading half of the same socket.
struct Conversation {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Conversation {
    fn open(path: &Path) -> Self {
        let stream = UnixStream::connect(path).expect("connect to the control socket");
        stream
            .set_read_timeout(Some(Duration::from_secs(30)))
            .expect("read timeout");
        let reader = BufReader::new(stream.try_clone().expect("clone the socket"));
        Conversation { stream, reader }
    }

    fn send(&mut self, line: &str) {
        self.stream
            .write_all(format!("{line}\n").as_bytes())
            .expect("send a command");
        self.stream.flush().expect("flush the command");
    }

    fn reply(&mut self) -> String {
        let mut line = String::new();
        let read = self.reader.read_line(&mut line).expect("read a reply");
        assert!(read > 0, "the server closed the connection instead of replying");
        assert!(line.ends_with('\n'), "a reply is one line, got {line:?}");
        line.trim_end().to_string()
    }

    fn ask(&mut self, line: &str) -> String {
        self.send(line);
        self.reply()
    }

    /// `status` until the take leaves `recording`, or the deadline passes.
    fn wait_for_done(&mut self) -> String {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let status = self.ask("{\"cmd\":\"status\"}");
            assert!(status.contains("\"ok\":true"), "status: {status}");
            if status.contains("\"state\":\"done\"") || status.contains("\"state\":\"failed\"") {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "the take never finished: {status}"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// `status` until the take has produced at least one frame.
    fn wait_for_frames(&mut self) -> String {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let status = self.ask("{\"cmd\":\"status\"}");
            assert!(status.contains("\"ok\":true"), "status: {status}");
            if status.contains("\"state\":\"recording\"") && json_number(&status, "frames") > 0.0 {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "the take never produced a frame: {status}"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }
}

/// A take or socket path under the system temp directory, removed however the
/// test ends.
struct TempFile {
    path: PathBuf,
}

impl TempFile {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "jawn-audio-socket-{}-{name}.wav",
            std::process::id()
        ));
        let _ = fs::remove_file(&path);
        TempFile { path }
    }

    fn text(&self) -> &str {
        self.path.to_str().expect("temp path is UTF-8")
    }
}

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

/// A `tracks:2` base path and the two files a take derives from it.
struct TwoTracks {
    base: PathBuf,
}

impl TwoTracks {
    fn new(name: &str) -> Self {
        let base = std::env::temp_dir().join(format!(
            "jawn-audio-socket-tracks-{}-{name}.wav",
            std::process::id()
        ));
        let set = TwoTracks { base };
        let _ = fs::remove_file(&set.base);
        for track in 1..=2 {
            let _ = fs::remove_file(set.derived(track));
        }
        set
    }

    fn text(&self) -> &str {
        self.base.to_str().expect("temp path is UTF-8")
    }

    fn derived(&self, track: usize) -> PathBuf {
        let stem = self
            .base
            .file_stem()
            .expect("temp path has a stem")
            .to_string_lossy();
        self.base.with_file_name(format!("{stem}-ch{track}.wav"))
    }
}

impl Drop for TwoTracks {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.base);
        for track in 1..=2 {
            let _ = fs::remove_file(self.derived(track));
        }
    }
}

fn json_number(text: &str, key: &str) -> f64 {
    let needle = format!("\"{key}\":");
    let start = text
        .find(&needle)
        .unwrap_or_else(|| panic!("no {key} in {text}"))
        + needle.len();
    let rest = &text[start..];
    let end = rest
        .find(|c: char| c == ',' || c == '}')
        .unwrap_or_else(|| panic!("unterminated {key} in {text}"));
    rest[..end]
        .parse()
        .unwrap_or_else(|_| panic!("{key} is not a number in {text}"))
}

fn u16_at(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

/// A take the socket wrote: header first, then the sizes it promises.
fn assert_wav(path: &Path, frames: u64) {
    let bytes = fs::read(path).unwrap_or_else(|error| panic!("read {}: {error}", path.display()));
    assert!(bytes.len() >= 44, "a WAV is at least its header");
    assert_eq!(&bytes[0..4], b"RIFF");
    assert_eq!(u32_at(&bytes, 4) as usize, bytes.len() - 8, "RIFF size");
    assert_eq!(&bytes[8..12], b"WAVE");
    assert_eq!(&bytes[12..16], b"fmt ");
    assert_eq!(u16_at(&bytes, 20), 1, "PCM");
    assert_eq!(u16_at(&bytes, 22), 2, "channels");
    assert_eq!(u32_at(&bytes, 24), 48_000, "rate");
    assert_eq!(u16_at(&bytes, 34), 16, "bits");
    assert_eq!(&bytes[36..40], b"data");
    let data = frames as usize * 2 * 2;
    assert_eq!(u32_at(&bytes, 40) as usize, data, "data size");
    assert_eq!(bytes.len(), 44 + data, "the file is the header and its frames");
}

#[test]
fn the_socket_arms_places_and_finishes_a_take() {
    let server = Server::start("take");

    // The socket is for its owner only.
    let mode = fs::metadata(&server.socket)
        .expect("stat the socket")
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o600, "the socket must be 0600");

    let mut client = server.connect();

    // One client at a time: the second connection is told why and closed, and
    // the first is untouched.
    let mut second = server.connect();
    let refusal = second.reply();
    assert!(refusal.contains("\"ok\":false"), "second client: {refusal}");
    assert!(
        refusal.contains("already connected"),
        "second client: {refusal}"
    );
    drop(second);

    // --- a take that runs to its own end -----------------------------------
    let take = TempFile::new("measured");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.2}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    assert!(reply.contains("\"take\":1"), "record: {reply}");
    assert!(reply.contains("\"state\":\"recording\""), "record: {reply}");
    assert!(reply.contains("\"start_sample\":0"), "record: {reply}");
    assert!(take.path.exists(), "record must create the take file");

    let status = client.wait_for_done();
    assert!(status.contains("\"state\":\"done\""), "status: {status}");
    assert_eq!(json_number(&status, "take"), 1.0, "status: {status}");
    assert_eq!(json_number(&status, "frames"), 9_600.0, "status: {status}");
    assert_eq!(json_number(&status, "dropped"), 0.0, "status: {status}");
    assert_eq!(
        json_number(&status, "start_sample"),
        0.0,
        "status: {status}"
    );
    assert!(
        status.contains(&format!("\"path\":\"{}\"", take.text())),
        "status: {status}"
    );
    assert!(status.contains("\"error\":\"\""), "status: {status}");
    assert_wav(&take.path, 9_600);

    // --- the next take gets its own id and its own transport stamp ---------
    let stamped = TempFile::new("stamped");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.2,\"start_at\":96000}}",
        stamped.text()
    ));
    assert!(reply.contains("\"take\":2"), "record: {reply}");
    assert!(
        reply.contains("\"start_sample\":96000"),
        "record: {reply}"
    );
    let status = client.wait_for_done();
    assert!(status.contains("\"state\":\"done\""), "status: {status}");
    assert_eq!(
        json_number(&status, "start_sample"),
        96_000.0,
        "status: {status}"
    );
    assert_wav(&stamped.path, 9_600);

    // --- a second take is refused while one runs, and `stop` joins it ------
    let long = TempFile::new("stopped");
    let other = TempFile::new("refused");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":20}}",
        long.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    assert!(reply.contains("\"take\":3"), "record: {reply}");
    // Wait until it has actually produced frames, so the take is certainly
    // running and `stop` has something to stop.
    let running = client.wait_for_frames();
    assert!(running.contains("\"state\":\"recording\""), "{running}");

    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":1}}",
        other.text()
    ));
    assert!(reply.contains("\"ok\":false"), "second record: {reply}");
    assert!(
        reply.contains("a take is already running"),
        "second record: {reply}"
    );
    assert!(
        !other.path.exists(),
        "a refused take must not create a file"
    );

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"ok\":true"), "stop: {stopped}");
    assert!(stopped.contains("\"take\":3"), "stop: {stopped}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    let frames = json_number(&stopped, "frames");
    assert!(frames > 0.0, "stop kept the frames it had: {stopped}");
    assert_eq!(json_number(&stopped, "dropped"), 0.0, "stop: {stopped}");
    assert_wav(&long.path, frames as u64);

    // --- an unknown or malformed command is an error, not a hang ------------
    let reply = client.ask("{\"cmd\":\"banana\"}");
    assert_eq!(reply, "{\"ok\":false,\"error\":\"unknown command\"}");
    let reply = client.ask("{\"cmd\":");
    assert!(reply.contains("\"ok\":false"), "malformed: {reply}");
    assert!(reply.contains("\"error\":"), "malformed: {reply}");
    // The connection still works after both.
    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"state\":\"done\""), "status: {status}");

    // --- record refuses a path that is not absolute ------------------------
    let reply = client.ask("{\"cmd\":\"record\",\"out\":\"take.wav\",\"seconds\":0.1}");
    assert!(reply.contains("\"ok\":false"), "relative out: {reply}");
    assert!(reply.contains("absolute"), "relative out: {reply}");

    // --- quit answers, exits 0, and takes the socket with it ---------------
    let reply = client.ask("{\"cmd\":\"quit\"}");
    assert_eq!(reply, "{\"ok\":true}");

    let (output, socket_left) = server.finish();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!socket_left, "a clean quit must unlink the socket");
}

#[test]
fn a_two_track_record_reports_both_and_status_carries_them() {
    let server = Server::start("tracks");
    let mut client = server.connect();
    let take = TwoTracks::new("both");

    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1,\"tracks\":2}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    assert!(reply.contains("\"tracks\":["), "record: {reply}");
    assert!(
        reply.contains(&format!("\"path\":\"{}\",\"input\":0", take.derived(1).display())),
        "record: {reply}"
    );
    assert!(
        reply.contains(&format!("\"path\":\"{}\",\"input\":1", take.derived(2).display())),
        "record: {reply}"
    );

    let status = client.wait_for_done();
    assert!(status.contains("\"state\":\"done\""), "status: {status}");
    assert_eq!(json_number(&status, "frames"), 4_800.0, "status: {status}");
    assert!(status.contains("\"tracks\":["), "status: {status}");
    assert!(
        status.contains(&format!(
            "{{\"path\":\"{}\",\"input\":0,\"frames\":4800,\"dropped\":0,\"gain\":1,\"pan\":0,\"inserts\":\"\"}}",
            take.derived(1).display()
        )),
        "track 1 entry: {status}"
    );
    assert!(
        status.contains(&format!(
            "{{\"path\":\"{}\",\"input\":1,\"frames\":4800,\"dropped\":0,\"gain\":1,\"pan\":0,\"inserts\":\"\"}}",
            take.derived(2).display()
        )),
        "track 2 entry: {status}"
    );
    // Track 1's strip also fills the top-level keys.
    assert_eq!(json_number(&status, "gain"), 1.0, "status: {status}");
    assert_eq!(json_number(&status, "pan"), 0.0, "status: {status}");
    assert!(status.contains("\"inserts\":\"\""), "status: {status}");

    assert_wav(&take.derived(1), 4_800);
    assert_wav(&take.derived(2), 4_800);

    let reply = client.ask("{\"cmd\":\"quit\"}");
    assert_eq!(reply, "{\"ok\":true}");
    let (output, socket_left) = server.finish();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!socket_left, "a clean quit must unlink the socket");
}

#[test]
fn a_param_moves_a_running_strip_and_the_take_still_finishes() {
    let server = Server::start("param");
    let mut client = server.connect();

    // No take yet: a knob has nothing to move.
    let reply = client.ask("{\"cmd\":\"param\",\"track\":0,\"name\":\"gain\",\"value\":0.5}");
    assert!(reply.contains("\"ok\":false"), "no take: {reply}");
    assert!(reply.contains("no take is running"), "no take: {reply}");

    // A long take, so the knob arrives while the strip is certainly running.
    let take = TempFile::new("param");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");

    let reply = client.ask("{\"cmd\":\"param\",\"track\":0,\"name\":\"gain\",\"value\":0.5}");
    assert_eq!(reply, "{\"ok\":true,\"track\":0,\"name\":\"gain\"}");

    let status = client.ask("{\"cmd\":\"status\"}");
    assert_eq!(json_number(&status, "gain"), 0.5, "status: {status}");
    assert_eq!(json_number(&status, "pan"), 0.0, "status: {status}");
    assert!(status.contains("\"inserts\":\"\""), "status: {status}");

    let reply = client.ask("{\"cmd\":\"param\",\"track\":0,\"name\":\"pan\",\"value\":-1}");
    assert!(reply.contains("\"ok\":true"), "pan: {reply}");
    let status = client.ask("{\"cmd\":\"status\"}");
    assert_eq!(json_number(&status, "pan"), -1.0, "status: {status}");

    // 900 is a legal number that the strip clamps to +12 dB; `status` says so.
    let reply = client.ask("{\"cmd\":\"param\",\"track\":0,\"name\":\"gain\",\"value\":900}");
    assert!(reply.contains("\"ok\":true"), "clamped gain: {reply}");
    let status = client.ask("{\"cmd\":\"status\"}");
    assert_eq!(json_number(&status, "gain"), 4.0, "status: {status}");

    // An unknown name, an effect that is not in the chain, an unknown track and
    // a value that is not a number are errors, and the connection survives each.
    for (line, message) in [
        (
            "{\"cmd\":\"param\",\"track\":0,\"name\":\"banana\",\"value\":1}",
            "no such parameter: banana",
        ),
        (
            "{\"cmd\":\"param\",\"track\":0,\"name\":\"tone.bass\",\"value\":1}",
            "no such parameter: tone.bass",
        ),
        (
            "{\"cmd\":\"param\",\"track\":7,\"name\":\"gain\",\"value\":1}",
            "no track 7",
        ),
        (
            "{\"cmd\":\"param\",\"track\":0,\"name\":\"gain\",\"value\":\"loud\"}",
            "finite number",
        ),
    ] {
        let reply = client.ask(line);
        assert!(reply.contains("\"ok\":false"), "{line}: {reply}");
        assert!(reply.contains(message), "{line}: {reply}");
        let status = client.ask("{\"cmd\":\"status\"}");
        assert!(status.contains("\"ok\":true"), "after {line}: {status}");
    }

    // The take still finishes, keeps its frames, and reports what it was told.
    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    let frames = json_number(&stopped, "frames");
    assert!(frames > 0.0, "stop kept the frames it had: {stopped}");
    assert_eq!(json_number(&stopped, "gain"), 4.0, "stop: {stopped}");
    assert_eq!(json_number(&stopped, "pan"), -1.0, "stop: {stopped}");
    assert_wav(&take.path, frames as u64);

    // A finished take has no running strip, so a knob is refused.
    let reply = client.ask("{\"cmd\":\"param\",\"track\":0,\"name\":\"gain\",\"value\":0.5}");
    assert!(reply.contains("\"ok\":false"), "after done: {reply}");
    assert!(reply.contains("no take is running"), "after done: {reply}");

    let reply = client.ask("{\"cmd\":\"quit\"}");
    assert_eq!(reply, "{\"ok\":true}");
    let (output, socket_left) = server.finish();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!socket_left, "a clean quit must unlink the socket");
}

#[test]
fn a_second_engine_on_the_same_socket_refuses_to_steal_it() {
    let server = Server::start("twice");
    let second = Command::new(env!("CARGO_BIN_EXE_jawn-audio"))
        .args(["--serve", "--backend", "null", "--socket"])
        .arg(&server.socket)
        .output()
        .expect("run the second engine");

    assert_eq!(second.status.code(), Some(1), "the second engine must refuse");
    let text = String::from_utf8_lossy(&second.stderr);
    assert!(
        text.contains("already serving"),
        "stderr: {text}"
    );

    // The first engine is still the one answering. The guard's own probe
    // connection may still be counted as the one client for a moment, so ask
    // again rather than racing it.
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let mut stream = UnixStream::connect(&server.socket).expect("still listening");
        stream.write_all(b"{\"cmd\":\"status\"}\n").expect("send");
        let mut reply = String::new();
        BufReader::new(&stream).read_line(&mut reply).expect("read");
        if reply.contains("\"ok\":true") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the first engine stopped answering: {reply}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}
