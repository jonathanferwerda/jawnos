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
        Self::start_with(name, &[])
    }

    /// The same, with extra `--serve` arguments such as `--channels 8`.
    fn start_with(name: &str, extra: &[&str]) -> Self {
        let socket = std::env::temp_dir().join(format!(
            "jawn-audio-sock-{}-{name}.sock",
            std::process::id()
        ));
        let _ = fs::remove_file(&socket);
        let child = Command::new(env!("CARGO_BIN_EXE_jawn-audio"))
            .args(["--serve", "--backend", "null", "--socket"])
            .arg(&socket)
            .args(extra)
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

    /// `status` until a playback has rendered at least one frame (or ended).
    fn wait_for_play_frames(&mut self) -> String {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let status = self.ask("{\"cmd\":\"status\"}");
            assert!(status.contains("\"ok\":true"), "status: {status}");
            if status.contains("\"state\":\"done\"")
                || (status.contains("\"state\":\"playing\"")
                    && json_number(&status, "frames") > 0.0)
            {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "the playback never produced a frame: {status}"
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

/// A multi-track base path and the files a take derives from it.
struct TwoTracks {
    base: PathBuf,
    count: usize,
}

impl TwoTracks {
    fn new(name: &str) -> Self {
        Self::with_count(name, 2)
    }

    fn with_count(name: &str, count: usize) -> Self {
        let base = std::env::temp_dir().join(format!(
            "jawn-audio-socket-tracks-{}-{name}.wav",
            std::process::id()
        ));
        let set = TwoTracks { base, count };
        let _ = fs::remove_file(&set.base);
        for track in 1..=set.count {
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
        for track in 1..=self.count {
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
fn eight_tracks_over_the_socket_report_every_track() {
    let server = Server::start_with("eight", &["--channels", "8"]);
    let mut client = server.connect();
    let take = TwoTracks::with_count("eight", 8);
    let inputs = [7usize, 0, 1, 2, 3, 4, 5, 6];

    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.05,\"tracks\":8,\"inputs\":[7,0,1,2,3,4,5,6]}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    assert!(reply.contains("\"channels\":8"), "record: {reply}");
    for (index, input) in inputs.iter().enumerate() {
        assert!(
            reply.contains(&format!(
                "\"path\":\"{}\",\"input\":{input}",
                take.derived(index + 1).display()
            )),
            "track {}: {reply}",
            index + 1
        );
    }

    let status = client.wait_for_done();
    assert!(status.contains("\"state\":\"done\""), "status: {status}");
    assert_eq!(json_number(&status, "channels"), 8.0, "status: {status}");
    assert_eq!(json_number(&status, "frames"), 2_400.0, "status: {status}");
    for (index, input) in inputs.iter().enumerate() {
        assert!(
            status.contains(&format!(
                "\"path\":\"{}\",\"input\":{input},\"frames\":2400,\"dropped\":0",
                take.derived(index + 1).display()
            )),
            "track {}: {status}",
            index + 1
        );
        assert_wav(&take.derived(index + 1), 2_400);
    }

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
fn a_take_that_does_not_fit_the_device_is_refused_before_any_file() {
    let server = Server::start("too-many");
    let mut client = server.connect();
    let take = TwoTracks::with_count("refused", 9);

    // More tracks than the engine's two channels.
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.05,\"tracks\":9}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":false"), "nine tracks: {reply}");
    assert!(reply.contains("channel"), "nine tracks: {reply}");

    // A track whose input is outside the granted count.
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.05,\"tracks\":2,\"inputs\":[0,9]}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":false"), "input 9: {reply}");
    assert!(reply.contains("input 9"), "input 9: {reply}");

    for track in 1..=9 {
        assert!(
            !take.derived(track).exists(),
            "a refused take created track {track}"
        );
    }

    // The connection survives both refusals.
    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"ok\":true"), "status: {status}");

    let reply = client.ask("{\"cmd\":\"quit\"}");
    assert_eq!(reply, "{\"ok\":true}");
    let (output, _) = server.finish();
    assert!(output.status.success());
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
fn a_take_is_armed_with_a_per_track_plan_and_status_reports_it() {
    let server = Server::start("planned");
    let mut client = server.connect();
    let take = TwoTracks::new("planned");

    // A long take, so the knobs below have a live strip to reach.
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300,\"tracks\":[{{\"input\":0,\"gain\":0.8,\"pan\":-0.3,\"inserts\":[\"tone\",\"delay\"]}},{{\"input\":1,\"gain\":900,\"pan\":-9,\"inserts\":[\"reverb\"]}}]}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    // The reply already carries the armed plan, not a wire.
    assert!(
        reply.contains("\"gain\":0.8,\"pan\":-0.3,\"inserts\":\"tone,delay\""),
        "track 1 plan: {reply}"
    );
    // Gain and pan are clamped exactly as the CLI clamps them.
    assert!(
        reply.contains("\"gain\":4,\"pan\":-1,\"inserts\":\"reverb\""),
        "track 2 plan: {reply}"
    );

    // `param` addresses the effects that were armed, and says so when the
    // effect is not in that track's chain.
    let reply = client.ask("{\"cmd\":\"param\",\"track\":0,\"name\":\"tone.bass\",\"value\":3}");
    assert_eq!(reply, "{\"ok\":true,\"track\":0,\"name\":\"tone.bass\"}");
    let reply = client.ask("{\"cmd\":\"param\",\"track\":0,\"name\":\"delay.feedback\",\"value\":0.5}");
    assert!(reply.contains("\"ok\":true"), "delay knob: {reply}");
    let reply = client.ask("{\"cmd\":\"param\",\"track\":1,\"name\":\"reverb.mix\",\"value\":0.5}");
    assert!(reply.contains("\"ok\":true"), "reverb knob: {reply}");
    let reply = client.ask("{\"cmd\":\"param\",\"track\":1,\"name\":\"tone.bass\",\"value\":3}");
    assert!(reply.contains("\"ok\":false"), "tone is not on track 2: {reply}");
    assert!(
        reply.contains("no such parameter: tone.bass"),
        "tone is not on track 2: {reply}"
    );

    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"state\":\"recording\""), "status: {status}");
    assert!(
        status.contains(&format!(
            "{{\"path\":\"{}\",\"input\":0",
            take.derived(1).display()
        )),
        "track 1 entry: {status}"
    );
    assert!(
        status.contains("\"gain\":0.8,\"pan\":-0.3,\"inserts\":\"tone,delay\""),
        "track 1 plan in status: {status}"
    );
    assert!(
        status.contains("\"gain\":4,\"pan\":-1,\"inserts\":\"reverb\""),
        "track 2 plan in status: {status}"
    );

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    assert!(
        stopped.contains("\"inserts\":\"tone,delay\""),
        "stop keeps the plan: {stopped}"
    );
    assert_eq!(json_number(&stopped, "gain"), 0.8, "stop: {stopped}");
    assert_eq!(json_number(&stopped, "pan"), -0.3, "stop: {stopped}");

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
fn an_unknown_insert_is_refused_before_a_file_exists() {
    let server = Server::start("bad-insert");
    let mut client = server.connect();
    let take = TempFile::new("bad-insert");

    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.05,\"tracks\":[{{\"input\":0,\"inserts\":[\"tone\",\"flanger\"]}}]}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":false"), "unknown insert: {reply}");
    assert!(
        reply.contains("no such insert: flanger"),
        "unknown insert: {reply}"
    );
    assert!(
        !take.path.exists(),
        "a refused plan must not create the take file"
    );

    // The connection survives, and a plan the engine can build still runs.
    let good = TempFile::new("good-insert");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1,\"tracks\":[{{\"input\":0,\"inserts\":[\"tone\",\"delay\"]}}]}}",
        good.text()
    ));
    assert!(reply.contains("\"ok\":true"), "good plan: {reply}");
    let status = client.wait_for_done();
    assert!(status.contains("\"state\":\"done\""), "status: {status}");
    assert!(
        status.contains("\"inserts\":\"tone,delay\""),
        "a one-track take still reports its chain: {status}"
    );
    assert_wav(&good.path, 4_800);

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

// --- play -------------------------------------------------------------------

/// A silent stereo 48 kHz WAV, written directly: playback should not depend on
/// how fast this machine records, only on the file's shape.
fn write_silent_wav(path: &Path, frames: u32) {
    let data_len = frames * 4;
    let mut bytes = Vec::with_capacity(44 + data_len as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&48_000u32.to_le_bytes());
    bytes.extend_from_slice(&(48_000u32 * 4).to_le_bytes());
    bytes.extend_from_slice(&4u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_len.to_le_bytes());
    bytes.resize(44 + data_len as usize, 0);
    fs::write(path, bytes).expect("write the silent WAV");
}

#[test]
fn the_socket_plays_then_reports_and_stops() {
    let server = Server::start("play");
    let mut client = server.connect();

    // A take first, so the playback reads a file the engine itself wrote.
    let take = TempFile::new("play-source");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    let status = client.wait_for_done();
    assert!(status.contains("\"state\":\"done\""), "status: {status}");

    let reply = client.ask(&format!(
        "{{\"cmd\":\"play\",\"files\":[\"{}\"]}}",
        take.text()
    ));
    assert_eq!(reply, "{\"ok\":true,\"state\":\"playing\",\"files\":1}");

    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"ok\":true"), "status: {status}");
    assert!(status.contains("\"files\":1"), "status: {status}");
    // The null backend runs as fast as it can, so the reply may arrive after
    // the last block; both answers are the contract, idle is not.
    assert!(
        status.contains("\"state\":\"playing\"") || status.contains("\"state\":\"done\""),
        "status: {status}"
    );
    if status.contains("\"state\":\"done\"") {
        assert_eq!(json_number(&status, "frames"), 4_800.0, "status: {status}");
    }

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"ok\":true"), "stop: {stopped}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    assert!(stopped.contains("\"files\":1"), "stop: {stopped}");
    let frames = json_number(&stopped, "frames");
    assert!(frames > 0.0 && frames <= 4_800.0, "stop: {stopped}");

    // A path the engine cannot read or should not accept is refused before a
    // worker starts.
    let reply = client.ask("{\"cmd\":\"play\",\"files\":[\"relative.wav\"]}");
    assert!(reply.contains("\"ok\":false"), "relative: {reply}");
    assert!(reply.contains("absolute"), "relative: {reply}");

    let missing = std::env::temp_dir().join(format!(
        "jawn-audio-socket-missing-{}.wav",
        std::process::id()
    ));
    let _ = fs::remove_file(&missing);
    let reply = client.ask(&format!(
        "{{\"cmd\":\"play\",\"files\":[\"{}\"]}}",
        missing.display()
    ));
    assert!(reply.contains("\"ok\":false"), "missing: {reply}");
    assert!(
        reply.contains("cannot read"),
        "the refusal names the failure: {reply}"
    );

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
fn a_playback_and_a_recording_refuse_each_other() {
    let server = Server::start("play-exclusive");
    let mut client = server.connect();

    // Four long silent files: enough material that the playback thread is
    // certainly still rendering while the next commands arrive.
    let long = TempFile::new("play-long");
    write_silent_wav(&long.path, 48_000 * 30);
    let files = format!(
        "\"{0}\",\"{0}\",\"{0}\",\"{0}\"",
        long.text()
    );

    let reply = client.ask(&format!("{{\"cmd\":\"play\",\"files\":[{files}]}}"));
    assert_eq!(reply, "{\"ok\":true,\"state\":\"playing\",\"files\":4}");

    // A second playback is refused while one runs.
    let reply = client.ask(&format!(
        "{{\"cmd\":\"play\",\"files\":[\"{}\"]}}",
        long.text()
    ));
    assert!(reply.contains("\"ok\":false"), "second play: {reply}");
    assert!(
        reply.contains("playback is already running"),
        "second play: {reply}"
    );

    // Recording while playing is out of scope: say so, and create no file.
    let while_playing = TempFile::new("while-playing");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1}}",
        while_playing.text()
    ));
    assert!(reply.contains("\"ok\":false"), "record during play: {reply}");
    assert!(
        reply.contains("a playback is running"),
        "record during play: {reply}"
    );
    assert!(
        !while_playing.path.exists(),
        "a refused record must not create a file"
    );

    // Let the playback reach the first block before stopping it, so the stop
    // has frames to report rather than a race with the thread's start.
    let status = client.wait_for_play_frames();
    assert!(status.contains("\"files\":4"), "status: {status}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop play: {stopped}");
    assert!(stopped.contains("\"files\":4"), "stop play: {stopped}");
    let played = json_number(&stopped, "frames");
    assert!(played > 0.0, "stop play: {stopped}");

    // The other direction: a take is recording, so a playback is refused.
    let long_take = TempFile::new("long-record");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300}}",
        long_take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");

    let reply = client.ask(&format!(
        "{{\"cmd\":\"play\",\"files\":[\"{}\"]}}",
        long.text()
    ));
    assert!(reply.contains("\"ok\":false"), "play during record: {reply}");
    assert!(
        reply.contains("a take is recording"),
        "play during record: {reply}"
    );
    // Wait for the take to reach disk before stopping it, so `frames` is not a
    // race with the worker thread's start.
    client.wait_for_frames();

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop record: {stopped}");
    let frames = json_number(&stopped, "frames");
    assert!(frames > 0.0, "stop record kept its frames: {stopped}");
    assert_wav(&long_take.path, frames as u64);

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
