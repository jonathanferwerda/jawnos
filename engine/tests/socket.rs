//! The control socket is the seam the manager drives, so it is tested the way
//! it will be used: a spawned `--serve` process, a `UnixStream`, one line out,
//! one line back. No sound card anywhere — the backend is `null`.

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
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
        Self::start_env(name, extra, &[])
    }

    /// The same, with environment overrides. The gateway tests use this to
    /// choose what `parec` is (a stand-in, or nothing at all) without touching
    /// the machine.
    fn start_env(name: &str, extra: &[&str], env: &[(&str, &str)]) -> Self {
        let socket = std::env::temp_dir().join(format!(
            "jawn-audio-sock-{}-{name}.sock",
            std::process::id()
        ));
        let _ = fs::remove_file(&socket);
        let mut command = Command::new(env!("CARGO_BIN_EXE_jawn-audio"));
        command
            .args(["--serve", "--backend", "null", "--socket"])
            .arg(&socket)
            .args(extra)
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        for (key, value) in env {
            command.env(key, value);
        }
        let child = command.spawn().expect("spawn --serve");
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

    /// The served process's pid. The gateway's per-call directory is keyed by
    /// it, so a test can find the FIFOs without parsing a reply.
    fn child_id(&self) -> u32 {
        self.child.as_ref().expect("the server is running").id()
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


    /// `status` until the listener has rendered at least one frame.
    fn wait_for_listen_frames(&mut self) -> String {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let status = self.ask("{\"cmd\":\"status\"}");
            assert!(status.contains("\"ok\":true"), "status: {status}");
            if status.contains("\"state\":\"listening\"") && json_number(&status, "frames") > 0.0
            {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "the listener never produced a frame: {status}"
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

    /// `status` until the take reports at least `frames` monitored frames, so a
    /// test reads a monitor that has actually run instead of racing its start.
    fn wait_for_monitor_frames(&mut self, frames: u64) -> String {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let status = self.ask("{\"cmd\":\"status\"}");
            assert!(status.contains("\"ok\":true"), "status: {status}");
            if status.contains("\"state\":\"recording\"")
                && status.contains("\"monitor_frames\"")
                && json_number(&status, "monitor_frames") >= frames as f64
            {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "the monitor never reached {frames} frames: {status}"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    /// `status` until the gateway's drain has counted at least one frame.
    /// Before a patch is armed the gateway's `frames` is the line's only one.
    fn wait_for_gateway_frames(&mut self) -> String {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let status = self.ask("{\"cmd\":\"status\"}");
            assert!(status.contains("\"ok\":true"), "status: {status}");
            assert!(
                status.contains("\"call_in\":\"captured\""),
                "the gateway is not capturing: {status}"
            );
            if json_number(&status, "frames") > 0.0 {
                return status;
            }
            assert!(
                Instant::now() < deadline,
                "the gateway never heard a frame: {status}"
            );
            std::thread::sleep(Duration::from_millis(10));
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
fn status_carries_the_configuration_serve_was_given() {
    // Six values that are not all defaults: the process reports the ones it
    // was actually started with, in every state, so a supervisor can compare
    // them with its own flags.
    let server = Server::start_with(
        "config",
        &[
            "--rate", "44100", "--period", "128", "--buffer", "512", "--channels", "4",
        ],
    );
    let mut client = server.connect();

    let assert_config = |status: &str| {
        assert!(
            status.contains("\"backend\":\"null\""),
            "backend: {status}"
        );
        assert!(
            status.contains("\"device\":\"null\""),
            "device: {status}"
        );
        assert_eq!(json_number(status, "rate"), 44_100.0, "rate: {status}");
        assert_eq!(json_number(status, "period"), 128.0, "period: {status}");
        assert_eq!(json_number(status, "buffer"), 512.0, "buffer: {status}");
        assert_eq!(json_number(status, "device_channels"), 4.0, "device_channels: {status}");
        // These fields sit together at the object's tail, so the values the
        // served process was started with are unambiguous even where the take
        // line already carries `channels` for granted capture width. The boot
        // restore adds `machine` and `plan`/`plan_error` after them.
        assert!(
            status.contains(
                "\"backend\":\"null\",\"device\":\"null\",\"rate\":44100,\"period\":128,\"buffer\":512,\"device_channels\":4"
            ),
            "config tail: {status}"
        );
        assert!(status.contains("\"machine\":"), "machine: {status}");
        assert!(
            status.contains("\"plan\":") || status.contains("\"plan_error\":"),
            "boot plan: {status}"
        );
    };

    let idle = client.ask("{\"cmd\":\"status\"}");
    assert!(idle.contains("\"state\":\"idle\""), "status: {idle}");
    assert_config(&idle);

    let take = TempFile::new("config-take");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":20}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    let recording = client.wait_for_frames();
    assert!(
        recording.contains("\"state\":\"recording\""),
        "status: {recording}"
    );
    assert_config(&recording);
    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");

    // A playback line is its own shape; it carries the same configuration.
    let play = TempFile::new("config-play");
    write_silent_wav_at(&play.path, 44_100, 4_410);
    let reply = client.ask(&format!(
        "{{\"cmd\":\"play\",\"files\":[\"{}\"]}}",
        play.text()
    ));
    assert!(reply.contains("\"ok\":true"), "play: {reply}");
    let playing = client.ask("{\"cmd\":\"status\"}");
    assert!(
        playing.contains("\"state\":\"playing\"") || playing.contains("\"state\":\"done\""),
        "status: {playing}"
    );
    assert_config(&playing);

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
    // The strip is only running once the engine has clocked a block; on a
    // loaded box the first `stop` can otherwise arrive before any frame is
    // recorded, and this test is about moving a running strip, not a race.
    client.wait_for_frames();

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
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.05,\"tracks\":[{{\"input\":0,\"inserts\":[\"tone\",\"theremin\"]}}]}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":false"), "unknown insert: {reply}");
    assert!(
        reply.contains("no such insert: theremin"),
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

/// An engine that lost its socket used to keep playing and capturing where no
/// manager could reach it. Replacing the path (a new inode) must end it.
#[test]
fn an_engine_whose_socket_is_replaced_exits_zero() {
    let mut server = Server::start("displaced");
    let replacement = std::env::temp_dir().join(format!(
        "jawn-audio-sock-{}-displaced-takeover.sock",
        std::process::id()
    ));
    let _ = fs::remove_file(&replacement);
    let takeover = UnixListener::bind(&replacement).expect("bind the takeover");
    fs::rename(&replacement, &server.socket).expect("replace the socket path");

    let deadline = Instant::now() + Duration::from_secs(10);
    let status = loop {
        let child = server.child.as_mut().expect("the server is running");
        if let Some(status) = child.try_wait().expect("wait for the displaced engine") {
            break status;
        }
        assert!(
            Instant::now() < deadline,
            "the displaced engine kept serving where nothing could reach it"
        );
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success(), "a displaced engine exits 0, not by a signal");

    let mut stderr = String::new();
    server
        .child
        .as_mut()
        .expect("the server is running")
        .stderr
        .take()
        .expect("stderr is piped")
        .read_to_string(&mut stderr)
        .expect("read stderr");
    assert!(
        stderr.contains("was removed or replaced"),
        "the exit is explained once: {stderr}"
    );
    assert!(
        server.socket.exists(),
        "the replacement owns the path; the displaced engine must not unlink it"
    );
    drop(takeover);
}

// --- play -------------------------------------------------------------------

/// A silent stereo WAV, written directly: playback should not depend on
/// how fast this machine records, only on the file's shape.
fn write_silent_wav(path: &Path, frames: u32) {
    write_silent_wav_at(path, 48_000, frames);
}

/// The same at an arbitrary rate, for the monitor-shape refusals.
fn write_silent_wav_at(path: &Path, rate: u32, frames: u32) {
    let data_len = frames * 4;
    let mut bytes = Vec::with_capacity(44 + data_len as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&rate.to_le_bytes());
    bytes.extend_from_slice(&(rate * 4).to_le_bytes());
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
    // Let the playback reach a block before stopping it, so the stop has
    // frames to report rather than racing the worker's start.
    client.wait_for_play_frames();

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
fn an_overdub_reports_both_roles_and_one_stop_joins_both() {
    let server = Server::start("overdub");
    let mut client = server.connect();

    // A short silent monitor beside a long take, so the take is still recording
    // when the monitor has already run to its end.
    let monitor = TempFile::new("overdub-monitor");
    write_silent_wav(&monitor.path, 2_400);
    let take = TempFile::new("overdub-take");

    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300,\"monitor\":[\"{}\"]}}",
        take.text(),
        monitor.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    assert!(reply.contains("\"state\":\"recording\""), "record: {reply}");
    assert!(reply.contains("\"playing\":1"), "record: {reply}");
    assert!(
        reply.contains("\"monitor_frames\":0"),
        "the monitor starts at zero: {reply}"
    );

    // Two takes at once are still impossible, and a refused take creates no
    // file.
    let other = TempFile::new("overdub-refused");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1}}",
        other.text()
    ));
    assert!(reply.contains("\"ok\":false"), "second record: {reply}");
    assert!(
        reply.contains("a take is already running"),
        "second record: {reply}"
    );
    assert!(!other.path.exists(), "a refused take created a file");

    // `status` leads with the take and reports the monitor beside it, even
    // after the monitor has reached the end of its file.
    let status = client.wait_for_monitor_frames(2_400);
    assert!(status.contains("\"state\":\"recording\""), "status: {status}");
    assert!(status.contains("\"playing\":1"), "status: {status}");
    assert_eq!(
        json_number(&status, "monitor_frames"),
        2_400.0,
        "status: {status}"
    );

    // One stop ends and joins both roles.
    let status = client.wait_for_frames();
    assert!(status.contains("\"state\":\"recording\""), "status: {status}");
    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"ok\":true"), "stop: {stopped}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    assert!(stopped.contains("\"playing\":1"), "stop: {stopped}");
    let frames = json_number(&stopped, "frames");
    assert!(frames > 0.0, "stop kept the take's frames: {stopped}");
    assert_eq!(
        json_number(&stopped, "monitor_frames"),
        2_400.0,
        "stop: {stopped}"
    );
    assert_wav(&take.path, frames as u64);

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
fn an_overdub_reports_its_alignment_and_each_monitor_strip() {
    let server = Server::start("overdub-strips");
    let mut client = server.connect();

    let first = TempFile::new("strips-a");
    let second = TempFile::new("strips-b");
    write_silent_wav(&first.path, 4_800);
    write_silent_wav(&second.path, 4_800);
    let take = TempFile::new("strips-take");

    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300,\"start_at\":1000,\"align_samples\":100,\"monitor\":[{{\"file\":\"{}\",\"gain\":0.8,\"pan\":-0.2,\"inserts\":[\"tone\"]}},\"{}\"]}}",
        take.text(),
        first.text(),
        second.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    assert!(reply.contains("\"playing\":2"), "record: {reply}");
    assert!(
        reply.contains("\"align_samples\":100"),
        "record: {reply}"
    );
    assert!(reply.contains("\"align_from\":\"given\""), "record: {reply}");
    assert!(reply.contains("\"monitor\":["), "record: {reply}");

    let status = client.wait_for_monitor_frames(2_400);
    assert!(status.contains("\"state\":\"recording\""), "status: {status}");
    assert!(status.contains("\"align_samples\":100"), "status: {status}");
    assert!(status.contains("\"align_from\":\"given\""), "status: {status}");
    assert!(status.contains(&format!("\"file\":\"{}\"", first.text())), "status: {status}");
    assert!(status.contains("\"gain\":0.8"), "status: {status}");
    assert!(status.contains("\"pan\":-0.2"), "status: {status}");
    assert!(status.contains("\"inserts\":[\"tone\"]"), "status: {status}");
    assert!(status.contains(&format!("\"file\":\"{}\"", second.text())), "status: {status}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    // The take keeps its alignment after the monitor ends.
    assert!(stopped.contains("\"align_from\":\"given\""), "stop: {stopped}");

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
fn a_param_moves_a_monitor_strip_and_not_the_take() {
    let server = Server::start("monitor-param");
    let mut client = server.connect();

    let monitor = TempFile::new("monitor-param-file");
    write_silent_wav(&monitor.path, 48_000 * 300);
    let take = TempFile::new("monitor-param-take");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300,\"monitor\":[{{\"file\":\"{}\",\"gain\":1,\"pan\":0,\"inserts\":[\"tone\"]}}]}}",
        take.text(),
        monitor.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    client.wait_for_frames();

    let reply = client.ask(
        "{\"cmd\":\"param\",\"target\":\"monitor\",\"track\":0,\"name\":\"gain\",\"value\":0.5}",
    );
    assert_eq!(
        reply,
        "{\"ok\":true,\"target\":\"monitor\",\"track\":0,\"name\":\"gain\"}"
    );
    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"monitor\":["), "status: {status}");
    assert!(status.contains("\"gain\":0.5"), "status: {status}");
    // The take's own strip is untouched: its top-level gain is still 1.
    assert!(status.contains(",\"gain\":1,\"pan\":0,"), "status: {status}");

    // An effect knob on the monitor follows the insert it names; one that is
    // not in the chain is refused exactly as it is for a take track.
    let reply = client.ask(
        "{\"cmd\":\"param\",\"target\":\"monitor\",\"track\":0,\"name\":\"tone.bass\",\"value\":3}",
    );
    assert_eq!(
        reply,
        "{\"ok\":true,\"target\":\"monitor\",\"track\":0,\"name\":\"tone.bass\"}"
    );
    let reply = client.ask(
        "{\"cmd\":\"param\",\"target\":\"monitor\",\"track\":0,\"name\":\"delay.mix\",\"value\":0.5}",
    );
    assert!(reply.contains("\"ok\":false"), "missing insert: {reply}");

    // The existing `track` form still moves the recording track.
    let reply = client.ask("{\"cmd\":\"param\",\"track\":0,\"name\":\"gain\",\"value\":0.25}");
    assert_eq!(reply, "{\"ok\":true,\"track\":0,\"name\":\"gain\"}");
    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains(",\"gain\":0.25,\"pan\":0,"), "status: {status}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"ok\":true"), "stop: {stopped}");
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
fn a_socket_calibration_without_a_cable_reports_none() {
    let server = Server::start("calibrate-none");
    let mut client = server.connect();

    let monitor = TempFile::new("calibrate-monitor");
    write_silent_wav(&monitor.path, 4_800);
    let take = TempFile::new("calibrate-take");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1,\"calibrate\":true,\"monitor\":[\"{}\"]}}",
        take.text(),
        monitor.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    // The null backend cannot measure a cable; it must not fake a number.
    assert!(reply.contains("\"align_samples\":0"), "record: {reply}");
    assert!(reply.contains("\"align_from\":\"none\""), "record: {reply}");

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
fn play_is_accepted_while_a_take_records() {
    let server = Server::start("play-beside");
    let mut client = server.connect();

    let take = TempFile::new("play-beside-take");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    client.wait_for_frames();

    let monitor = TempFile::new("play-beside-monitor");
    write_silent_wav(&monitor.path, 2_400);
    let reply = client.ask(&format!(
        "{{\"cmd\":\"play\",\"files\":[\"{}\"]}}",
        monitor.text()
    ));
    assert_eq!(reply, "{\"ok\":true,\"state\":\"playing\",\"files\":1}");

    let status = client.wait_for_monitor_frames(2_400);
    assert!(status.contains("\"state\":\"recording\""), "status: {status}");
    assert!(status.contains("\"playing\":1"), "status: {status}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    assert!(stopped.contains("\"playing\":1"), "stop: {stopped}");
    let frames = json_number(&stopped, "frames");
    assert!(frames > 0.0, "stop kept the take's frames: {stopped}");
    assert_eq!(
        json_number(&stopped, "monitor_frames"),
        2_400.0,
        "stop: {stopped}"
    );
    assert_wav(&take.path, frames as u64);

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
fn record_is_accepted_while_a_playback_runs_and_two_playbacks_still_refuse() {
    let server = Server::start("record-over");
    let mut client = server.connect();

    // Four long silent files: enough material that the playback thread is
    // likely still rendering while the next commands arrive.
    let long = TempFile::new("record-over-long");
    write_silent_wav(&long.path, 48_000 * 30);
    let files = format!("\"{0}\",\"{0}\",\"{0}\",\"{0}\"", long.text());
    let reply = client.ask(&format!("{{\"cmd\":\"play\",\"files\":[{files}]}}"));
    assert_eq!(reply, "{\"ok\":true,\"state\":\"playing\",\"files\":4}");

    // Two playbacks at once are still refused.
    let reply = client.ask(&format!(
        "{{\"cmd\":\"play\",\"files\":[\"{}\"]}}",
        long.text()
    ));
    assert!(reply.contains("\"ok\":false"), "second play: {reply}");
    assert!(
        reply.contains("playback is already running"),
        "second play: {reply}"
    );

    // Recording over the running playback is the overdub, and the take keeps
    // the playback alive rather than joining it.
    let take = TempFile::new("record-over-take");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record during play: {reply}");
    assert!(
        reply.contains("\"state\":\"recording\""),
        "record during play: {reply}"
    );

    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"state\":\"recording\""), "status: {status}");
    assert!(status.contains("\"playing\":4"), "status: {status}");
    // Wait for the take to reach disk before stopping it, so `frames` is not a
    // race with the worker thread's start.
    client.wait_for_frames();

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    assert!(stopped.contains("\"playing\":4"), "stop: {stopped}");
    let frames = json_number(&stopped, "frames");
    assert!(frames > 0.0, "stop kept the take's frames: {stopped}");
    assert!(
        json_number(&stopped, "monitor_frames") > 0.0,
        "stop kept the monitor's frames: {stopped}"
    );
    assert_wav(&take.path, frames as u64);

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
fn a_monitor_at_another_rate_is_refused_without_a_take() {
    let server = Server::start("monitor-rate");
    let mut client = server.connect();

    let monitor = TempFile::new("monitor-rate-44k");
    write_silent_wav_at(&monitor.path, 44_100, 441);
    let take = TempFile::new("monitor-rate-take");

    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1,\"monitor\":[\"{}\"]}}",
        take.text(),
        monitor.text()
    ));
    assert!(reply.contains("\"ok\":false"), "monitor rate: {reply}");
    assert!(reply.contains("44100"), "monitor rate: {reply}");
    assert!(reply.contains("48000"), "monitor rate: {reply}");
    assert!(
        !take.path.exists(),
        "a refused overdub created the take file"
    );

    // The connection survives, and a monitor at the take's rate still runs.
    let good = TempFile::new("monitor-rate-good");
    write_silent_wav(&good.path, 480);
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1,\"monitor\":[\"{}\"]}}",
        take.text(),
        good.text()
    ));
    assert!(reply.contains("\"ok\":true"), "good monitor: {reply}");
    let status = client.wait_for_done();
    assert!(status.contains("\"state\":\"done\""), "status: {status}");
    assert_wav(&take.path, 4_800);

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

// --- patch ------------------------------------------------------------------

#[test]
fn patch_runs_a_plan_and_reports_its_shape() {
    let server = Server::start("patch");
    let mut client = server.connect();

    // Channel 0 is real, `phone` is a peer on this machine (pending until an
    // uplink attaches its ring), and the plan routes both into the house bus.
    let plan = "{\"sources\":[{\"id\":\"in0\",\"kind\":\"input\",\"channel\":0},{\"id\":\"phone\",\"kind\":\"peer\"}],\"buses\":[{\"id\":\"house\"}],\"sinks\":[{\"id\":\"out\",\"kind\":\"interface\"}],\"routes\":[{\"from\":\"in0\",\"to\":\"house\"},{\"from\":\"phone\",\"to\":\"house\"},{\"from\":\"house\",\"to\":\"out\"}]}";
    let reply = client.ask(&format!("{{\"cmd\":\"patch\",\"plan\":{plan}}}"));
    assert!(reply.contains("\"ok\":true"), "patch: {reply}");
    assert!(reply.contains("\"state\":\"patching\""), "patch: {reply}");
    assert!(reply.contains("\"sources\":2"), "patch: {reply}");
    assert!(reply.contains("\"bound_sources\":2"), "patch: {reply}");
    assert!(reply.contains("\"silent\":[]"), "patch: {reply}");
    assert!(reply.contains("\"peer\":\"pending\""), "patch: {reply}");
    // The plan does not route a `device` source, so the machine's own mix is
    // carried at the output (the compile-time statement, not the runtime one).
    assert!(
        reply.contains("\"system_route\":\"fallback\""),
        "patch: {reply}"
    );

    // The null loop runs until stop, so status has frames and the plan's shape.
    std::thread::sleep(Duration::from_millis(20));
    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"state\":\"patching\""), "status: {status}");
    assert!(json_number(&status, "frames") > 0.0, "status: {status}");
    assert!(status.contains("\"buses\":1"), "status: {status}");
    // The null backend never captures a system mix, and says so.
    assert!(status.contains("\"system\":\"off\""), "status: {status}");
    // No `--uplink` was named, so the uplink object is present but off.
    assert!(status.contains("\"uplink\":{\"state\":\"off\""), "status: {status}");

    // One capture and one set of outputs: a listen is refused while patching.
    let reply = client.ask("{\"cmd\":\"listen\",\"channel\":0}");
    assert!(reply.contains("\"ok\":false"), "listen: {reply}");
    assert!(reply.contains("patchbay"), "listen: {reply}");

    let unpatched = client.ask("{\"cmd\":\"unpatch\"}");
    assert!(unpatched.contains("\"state\":\"done\""), "unpatch: {unpatched}");
    assert!(json_number(&unpatched, "frames") > 0.0, "unpatch: {unpatched}");

    // A second patch, and the transport's one stop joins it too. The manager's
    // system source is accepted even though this null backend has none.
    let reply = client.ask(&format!(
        "{{\"cmd\":\"patch\",\"plan\":{plan},\"system_device\":\"jawn_system.monitor\"}}"
    ));
    assert!(reply.contains("\"ok\":true"), "second patch: {reply}");
    std::thread::sleep(Duration::from_millis(20));
    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");

    // A plan whose route names an undeclared node is refused, not run.
    let reply = client.ask(
        "{\"cmd\":\"patch\",\"plan\":{\"sources\":[],\"buses\":[],\"sinks\":[],\"routes\":[{\"from\":\"a\",\"to\":\"b\"}]}}",
    );
    assert!(reply.contains("\"ok\":false"), "bad plan: {reply}");
    assert!(reply.contains("does not declare"), "bad plan: {reply}");

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
fn patch_params_move_a_live_route_and_refuse_a_muted_one() {
    let server = Server::start("patch-param");
    let mut client = server.connect();

    // Route 0 is muted, route 1 is the live bus -> sink send.
    let plan = "{\"sources\":[{\"id\":\"in0\",\"kind\":\"input\",\"channel\":0}],\"buses\":[{\"id\":\"house\"}],\"sinks\":[{\"id\":\"out\",\"kind\":\"interface\"}],\"routes\":[{\"from\":\"in0\",\"to\":\"house\",\"mute\":1},{\"from\":\"house\",\"to\":\"out\",\"gain\":1,\"pan\":0}]}";
    let reply = client.ask(&format!("{{\"cmd\":\"patch\",\"plan\":{plan}}}"));
    assert!(reply.contains("\"ok\":true"), "patch: {reply}");

    // A muted route is refused in one sentence.
    let reply = client.ask("{\"cmd\":\"param\",\"target\":\"patch\",\"route\":0,\"name\":\"gain\",\"value\":0.5}");
    assert!(reply.contains("\"ok\":false"), "muted route: {reply}");
    assert!(reply.contains("muted"), "muted route: {reply}");

    // A live route moves.
    let reply = client.ask("{\"cmd\":\"param\",\"target\":\"patch\",\"route\":1,\"name\":\"gain\",\"value\":0.5}");
    assert_eq!(reply, "{\"ok\":true,\"target\":\"patch\",\"route\":1,\"name\":\"gain\"}");

    // A bad name is refused.
    let reply = client.ask("{\"cmd\":\"param\",\"target\":\"patch\",\"route\":1,\"name\":\"tone.bass\",\"value\":1}");
    assert!(reply.contains("\"ok\":false"), "bad name: {reply}");
    assert!(reply.contains("no such parameter"), "bad name: {reply}");

    // An out-of-range route is refused.
    let reply = client.ask("{\"cmd\":\"param\",\"target\":\"patch\",\"route\":7,\"name\":\"gain\",\"value\":1}");
    assert!(reply.contains("\"ok\":false"), "bad route: {reply}");

    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"state\":\"patching\""), "status: {status}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");

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

// --- boot restore -----------------------------------------------------------

fn serve_plan_path(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "jawn-audio-serve-plan-{}-{name}.json",
        std::process::id()
    ))
}

#[test]
fn serve_restores_a_managed_plan_at_boot() {
    let plan = serve_plan_path("managed");
    fs::write(
        &plan,
        r#"{"manage":true,"plan":{"sources":[{"id":"in0","kind":"input","channel":0}],"buses":[{"id":"house"}],"sinks":[{"id":"out","kind":"interface"}],"routes":[{"from":"in0","to":"house"},{"from":"house","to":"out"}]}}"#,
    )
    .expect("write the plan");
    let server = Server::start_with(
        "serve-plan-managed",
        &["--plan", plan.to_str().expect("path"), "--machine", "table"],
    );
    let mut client = server.connect();
    let status = client.ask("{\"cmd\":\"status\"}");
    let _ = fs::remove_file(&plan);
    assert!(status.contains("\"machine\":\"table\""), "status: {status}");
    assert!(status.contains("\"plan\":"), "status: {status}");
    assert!(status.contains("\"state\":\"patching\""), "status: {status}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
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
fn serve_with_manage_off_does_not_patch() {
    let plan = serve_plan_path("off");
    fs::write(&plan, r#"{"manage":false,"plan":{"sources":[],"buses":[],"sinks":[],"routes":[]}}"#)
        .expect("write the plan");
    let server = Server::start_with(
        "serve-plan-off",
        &["--plan", plan.to_str().expect("path"), "--machine", "table"],
    );
    let mut client = server.connect();
    let status = client.ask("{\"cmd\":\"status\"}");
    let _ = fs::remove_file(&plan);
    assert!(status.contains("\"machine\":\"table\""), "status: {status}");
    assert!(status.contains("\"plan_error\":"), "status: {status}");
    assert!(status.contains("manage is off"), "status: {status}");
    assert!(!status.contains("\"state\":\"patching\""), "status: {status}");

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
fn serve_with_a_malformed_plan_still_serves() {
    let plan = serve_plan_path("malformed");
    fs::write(&plan, "not json at all").expect("write the plan");
    let server = Server::start_with(
        "serve-plan-malformed",
        &["--plan", plan.to_str().expect("path"), "--machine", "table"],
    );
    let mut client = server.connect();
    let status = client.ask("{\"cmd\":\"status\"}");
    let _ = fs::remove_file(&plan);
    assert!(status.contains("\"machine\":\"table\""), "status: {status}");
    assert!(status.contains("\"plan_error\":"), "status: {status}");
    assert!(!status.contains("\"state\":\"patching\""), "status: {status}");

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

// --- listen -----------------------------------------------------------------

#[test]
fn listen_reports_status_takes_params_and_stops() {
    let server = Server::start("listen");
    let mut client = server.connect();

    let reply = client.ask(
        "{\"cmd\":\"listen\",\"channel\":1,\"gain\":0.8,\"pan\":0,\"inserts\":[\"tone\"],\"system\":false}",
    );
    assert_eq!(reply, "{\"ok\":true,\"state\":\"listening\",\"channel\":1}");

    let status = client.wait_for_listen_frames();
    assert!(status.contains("\"state\":\"listening\""), "status: {status}");
    assert_eq!(json_number(&status, "channel"), 1.0, "status: {status}");
    assert_eq!(json_number(&status, "gain"), 0.8, "status: {status}");
    assert_eq!(json_number(&status, "pan"), 0.0, "status: {status}");
    assert!(status.contains("\"inserts\":\"tone\""), "status: {status}");
    assert!(json_number(&status, "frames") > 0.0, "status: {status}");

    // `param` moves the listen strip, and status mirrors it.
    let reply = client.ask(
        "{\"cmd\":\"param\",\"target\":\"listen\",\"name\":\"gain\",\"value\":0.5}",
    );
    assert_eq!(reply, "{\"ok\":true,\"target\":\"listen\",\"name\":\"gain\"}");
    let status = client.ask("{\"cmd\":\"status\"}");
    assert_eq!(json_number(&status, "gain"), 0.5, "status: {status}");

    let reply = client.ask(
        "{\"cmd\":\"param\",\"target\":\"listen\",\"name\":\"pan\",\"value\":-1}",
    );
    assert!(reply.contains("\"ok\":true"), "pan: {reply}");
    let status = client.ask("{\"cmd\":\"status\"}");
    assert_eq!(json_number(&status, "pan"), -1.0, "status: {status}");

    // An insert that is in the chain takes its own knob...
    let reply = client.ask(
        "{\"cmd\":\"param\",\"target\":\"listen\",\"name\":\"tone.bass\",\"value\":6}",
    );
    assert!(reply.contains("\"ok\":true"), "tone.bass: {reply}");
    // ...and one that is not is refused, as it is for a take.
    let reply = client.ask(
        "{\"cmd\":\"param\",\"target\":\"listen\",\"name\":\"delay.mix\",\"value\":0.5}",
    );
    assert!(reply.contains("\"ok\":false"), "delay.mix: {reply}");
    assert!(reply.contains("no such parameter: delay.mix"), "{reply}");

    // A stop joins the loop and answers with the final line.
    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"ok\":true"), "stop: {stopped}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    assert_eq!(json_number(&stopped, "channel"), 1.0, "stop: {stopped}");
    assert_eq!(json_number(&stopped, "gain"), 0.5, "stop: {stopped}");
    assert_eq!(json_number(&stopped, "pan"), -1.0, "stop: {stopped}");
    assert!(json_number(&stopped, "frames") > 0.0, "stop: {stopped}");

    // A finished listener is a status line, not a running strip.
    let reply = client.ask(
        "{\"cmd\":\"param\",\"target\":\"listen\",\"name\":\"gain\",\"value\":0.5}",
    );
    assert!(reply.contains("\"ok\":false"), "after stop: {reply}");
    assert!(reply.contains("no listen is running"), "after stop: {reply}");

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
fn listen_and_record_refuse_each_other() {
    let server = Server::start("listen-record");
    let mut client = server.connect();

    let reply = client.ask("{\"cmd\":\"listen\",\"channel\":1}");
    assert_eq!(reply, "{\"ok\":true,\"state\":\"listening\",\"channel\":1}");
    client.wait_for_listen_frames();

    let take = TempFile::new("listen-refused");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":false"), "record while listen: {reply}");
    assert!(reply.contains("capture"), "record while listen: {reply}");
    assert!(reply.contains("next step"), "record while listen: {reply}");
    assert!(!take.path.exists(), "a refused take must not create a file");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop listen: {stopped}");

    // With the listener stopped, a take runs.
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":0.1}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    let status = client.wait_for_done();
    assert!(status.contains("\"state\":\"done\""), "status: {status}");

    // A long take holds the capture: listen is refused with the same reason.
    let long = TempFile::new("listen-long");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300}}",
        long.text()
    ));
    assert!(reply.contains("\"ok\":true"), "long record: {reply}");
    client.wait_for_frames();

    let reply = client.ask("{\"cmd\":\"listen\",\"channel\":1}");
    assert!(reply.contains("\"ok\":false"), "listen while record: {reply}");
    assert!(reply.contains("capture"), "listen while record: {reply}");
    assert!(reply.contains("next step"), "listen while record: {reply}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop take: {stopped}");
    let frames = json_number(&stopped, "frames");
    assert!(frames > 0.0, "stop kept the frames it had: {stopped}");
    assert_wav(&long.path, frames as u64);

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

// --- the gateway's inbound port ---------------------------------------------

/// A stand-in `parec` on a private `PATH`: it ignores the arguments the engine
/// passes and writes one 20 ms chunk of 8 kHz mono silence per 20 ms. Paced, so
/// the test does not burn a core and the ring drops only if the drain stops.
/// The same directory gets a `pacat` that records what the prompt sent it, so
/// `capable` is true in these tests.
fn fake_parec(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "jawn-audio-parec-{}-{name}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).expect("create the fake tool directory");
    let path = dir.join("parec");
    fs::write(
        &path,
        "#!/bin/sh\nwhile :; do\n  dd if=/dev/zero bs=320 count=1 2>/dev/null\n  sleep 0.02\ndone\n",
    )
    .expect("write the stand-in parec");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755))
        .expect("make the stand-in executable");
    // The prompt child: record its own pid and argv, then copy its stdin to the
    // file the test named, so a test can prove both that it ran and what it
    // heard (and with which gain).
    let pacat = dir.join("pacat");
    fs::write(
        &pacat,
        "#!/bin/sh\n[ -n \"$PACAT_PID\" ] && echo $$ > \"$PACAT_PID\"\n[ -n \"$PACAT_ARGS\" ] && printf '%s\\n' \"$@\" > \"$PACAT_ARGS\"\nexec cat > \"${PACAT_OUT:-/dev/null}\"\n",
    )
    .expect("write the stand-in pacat");
    fs::set_permissions(&pacat, fs::Permissions::from_mode(0o755))
        .expect("make the stand-in executable");
    dir
}

/// A plan path under a private state directory, so the gateway's FIFOs land in
/// the test's own directory instead of `~/.president`.
fn gateway_state(name: &str) -> (PathBuf, String) {
    let dir = std::env::temp_dir().join(format!(
        "jawn-audio-state-{}-{name}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("create the gateway state directory");
    let plan = dir.join("audio-plan.json");
    (dir, plan.to_str().expect("UTF-8 path").to_string())
}

/// A stand-in `pactl`: it lists the call monitor only after the marker file
/// exists, so a bind made first is honestly silent and the retry has something
/// to find later. All other `pactl` verbs succeed quietly.
fn fake_pactl(name: &str, marker: &Path) -> PathBuf {
    let dir = fake_parec(name);
    let path = dir.join("pactl");
    let marker = marker.to_str().expect("UTF-8 marker path");
    fs::write(
        &path,
        format!(
            "#!/bin/sh\nif [ -e '{marker}' ]; then\n  printf '47\\tjawn_call_in.monitor\\tPipeWire\\ts16le 2ch 48000Hz\\n'\nfi\nexit 0\n"
        ),
    )
    .expect("write the stand-in pactl");
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755))
        .expect("make the stand-in executable");
    dir
}

#[test]
fn the_gateway_binds_the_call_monitor_and_releases_it() {
    let parec = fake_parec("gateway");
    let (state, plan) = gateway_state("gateway");
    // The stand-in's directory comes first, so it wins even on a machine that
    // has a real parec; `dd` and `sleep` come from the usual places.
    let path = format!("{}:/usr/bin:/bin", parec.display());
    let server = Server::start_env(
        "gateway",
        &[],
        &[("PATH", path.as_str()), ("JAWNOS_AUDIO_PLAN", plan.as_str())],
    );
    let mut client = server.connect();

    // Nothing is bound until a call asks for it.
    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(
        status.contains("\"gateway\":{\"call_in\":\"off\""),
        "status: {status}"
    );
    assert!(status.contains("\"prompt\":\"silent\""), "status: {status}");

    let bind = "{\"cmd\":\"gateway\",\"action\":\"bind\",\"call_in\":\"jawn_call_in\"}";
    let bound = client.ask(bind);
    assert!(bound.contains("\"ok\":true"), "bind: {bound}");
    assert!(bound.contains("\"call_in\":\"captured\""), "bind: {bound}");
    assert!(bound.contains("\"rate\":8000"), "bind: {bound}");
    assert!(bound.contains("\"channels\":1"), "bind: {bound}");

    let status = client.wait_for_gateway_frames();
    let first = json_number(&status, "frames") as u64;
    assert!(first > 0, "the drain never counted a frame: {status}");
    assert!(status.contains("\"peak\":"), "status: {status}");

    // Binding again keeps the first capture: the count never restarts.
    let again = client.ask(bind);
    assert!(
        again.contains("\"call_in\":\"captured\""),
        "second bind: {again}"
    );
    let status = client.wait_for_gateway_frames();
    assert!(
        json_number(&status, "frames") as u64 >= first,
        "the second bind restarted the capture: {status}"
    );

    // A page that already polls the engine sees the gateway on the patch line
    // too, since the patchbay and the gateway coexist.
    let plan = "{\"sources\":[{\"id\":\"in0\",\"kind\":\"input\",\"channel\":0}],\"buses\":[{\"id\":\"house\"}],\"sinks\":[{\"id\":\"out\",\"kind\":\"interface\"}],\"routes\":[{\"from\":\"in0\",\"to\":\"house\"},{\"from\":\"house\",\"to\":\"out\"}]}";
    let reply = client.ask(&format!("{{\"cmd\":\"patch\",\"plan\":{plan}}}"));
    assert!(reply.contains("\"ok\":true"), "patch: {reply}");
    assert!(
        reply.contains("\"gateway\":{\"call_in\":\"captured\""),
        "patch: {reply}"
    );
    std::thread::sleep(Duration::from_millis(20));
    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"state\":\"patching\""), "status: {status}");
    assert!(
        status.contains("\"gateway\":{\"call_in\":\"captured\""),
        "status: {status}"
    );

    // Release ends the capture and returns the port to off.
    let released = client.ask("{\"cmd\":\"gateway\",\"action\":\"release\"}");
    assert!(released.contains("\"ok\":true"), "release: {released}");
    assert!(released.contains("\"call_in\":\"off\""), "release: {released}");
    assert!(released.contains("\"frames\":0"), "release: {released}");

    let unknown = client.ask("{\"cmd\":\"gateway\",\"action\":\"wobble\"}");
    assert!(unknown.contains("\"ok\":false"), "unknown: {unknown}");
    assert!(unknown.contains("no such gateway action"), "unknown: {unknown}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    let reply = client.ask("{\"cmd\":\"quit\"}");
    assert_eq!(reply, "{\"ok\":true}");
    let (output, socket_left) = server.finish();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!socket_left, "a clean quit must unlink the socket");
    let _ = fs::remove_dir_all(&parec);
    let _ = fs::remove_dir_all(&state);
}

#[test]
fn a_gateway_bind_that_cannot_capture_is_silent_and_the_engine_serves_on() {
    // No `parec` anywhere on this engine's PATH: a missing tool is a silent
    // port, never a failed bind.
    let empty = std::env::temp_dir().join(format!(
        "jawn-audio-nopath-{}-gateway",
        std::process::id()
    ));
    fs::create_dir_all(&empty).expect("create the empty PATH directory");
    let (state, plan) = gateway_state("gateway-silent");
    let server = Server::start_env(
        "gateway-silent",
        &[],
        &[
            ("PATH", empty.to_str().expect("temp path is UTF-8")),
            ("JAWNOS_AUDIO_PLAN", plan.as_str()),
        ],
    );
    let mut client = server.connect();

    let bound = client.ask("{\"cmd\":\"gateway\",\"action\":\"bind\",\"call_in\":\"jawn_call_in\"}");
    assert!(bound.contains("\"ok\":true"), "bind: {bound}");
    assert!(bound.contains("\"call_in\":\"silent\""), "bind: {bound}");
    assert!(bound.contains("\"frames\":0"), "bind: {bound}");

    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"ok\":true"), "status: {status}");
    assert!(
        status.contains("\"gateway\":{\"call_in\":\"silent\""),
        "status: {status}"
    );

    // The engine keeps serving: a patch still compiles and runs beside it.
    let plan = "{\"sources\":[{\"id\":\"in0\",\"kind\":\"input\",\"channel\":0}],\"buses\":[{\"id\":\"house\"}],\"sinks\":[{\"id\":\"out\",\"kind\":\"interface\"}],\"routes\":[{\"from\":\"in0\",\"to\":\"house\"},{\"from\":\"house\",\"to\":\"out\"}]}";
    let reply = client.ask(&format!("{{\"cmd\":\"patch\",\"plan\":{plan}}}"));
    assert!(reply.contains("\"ok\":true"), "patch: {reply}");
    std::thread::sleep(Duration::from_millis(20));
    let status = client.ask("{\"cmd\":\"status\"}");
    assert!(status.contains("\"state\":\"patching\""), "status: {status}");
    assert!(
        status.contains("\"gateway\":{\"call_in\":\"silent\""),
        "status: {status}"
    );

    // A release returns the port to off even though nothing was captured.
    let released = client.ask("{\"cmd\":\"gateway\",\"action\":\"release\"}");
    assert!(released.contains("\"call_in\":\"off\""), "release: {released}");

    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    let reply = client.ask("{\"cmd\":\"quit\"}");
    assert_eq!(reply, "{\"ok\":true}");
    let (output, socket_left) = server.finish();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!socket_left, "a clean quit must unlink the socket");
    let _ = fs::remove_dir_all(&empty);
    let _ = fs::remove_dir_all(&state);
}

/// The prompt child is spawned by the first byte, not by the bind, and is
/// reaped by `release`.
#[test]
fn the_gateway_prompt_spawns_pacat_on_the_first_byte_and_reaps_it_on_release() {
    let tools = fake_parec("gateway-prompt");
    let (state, plan) = gateway_state("gateway-prompt");
    let out = state.join("prompt.pcm");
    let pid_file = state.join("pacat.pid");
    let args_file = state.join("pacat.args");
    let path = format!("{}:/usr/bin:/bin", tools.display());
    let server = Server::start_env(
        "gateway-prompt",
        &[],
        &[
            ("PATH", path.as_str()),
            ("JAWNOS_AUDIO_PLAN", plan.as_str()),
            ("PACAT_OUT", out.to_str().expect("UTF-8 output path")),
            ("PACAT_PID", pid_file.to_str().expect("UTF-8 pid path")),
            ("PACAT_ARGS", args_file.to_str().expect("UTF-8 argv path")),
        ],
    );
    let mut client = server.connect();

    // The phone channel's gain rides the bind; the child must carry it.
    let bound = client.ask(
        "{\"cmd\":\"gateway\",\"action\":\"bind\",\"call_in\":\"jawn_call_in\",\"volume\":37}",
    );
    assert!(bound.contains("\"ok\":true"), "bind: {bound}");
    assert!(bound.contains("\"prompt\":\"writing\""), "bind: {bound}");

    // The bind runs the capture but not `pacat`: no prompt byte has arrived.
    std::thread::sleep(Duration::from_millis(150));
    assert!(
        !pid_file.exists(),
        "pacat was spawned by the bind, not by the first prompt byte"
    );

    let dir = state.join(format!("gateway-{}", server.child_id()));
    let prompt = dir.join("prompt");
    let mut writer = fs::OpenOptions::new()
        .write(true)
        .custom_flags(0o4000)
        .open(&prompt)
        .expect("open the prompt write end");
    let frame: Vec<u8> = (0..80)
        .flat_map(|sample| ((sample as i16) * 100).to_le_bytes())
        .collect();
    writer.write_all(&frame).expect("write one prompt frame");
    writer.flush().expect("flush the prompt frame");

    // `pacat` now exists and has the frame on its stdin.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut heard = Vec::new();
    while heard.len() < frame.len() && Instant::now() < deadline {
        heard = fs::read(&out).unwrap_or_default();
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(heard, frame, "the prompt frame did not reach pacat");
    let argv = fs::read_to_string(&args_file).expect("pacat recorded its argv");
    assert!(
        argv.lines().any(|arg| arg == "--volume=37%"),
        "the bind volume did not reach pacat: {argv}"
    );
    let pacat = fs::read_to_string(&pid_file).expect("pacat wrote its pid");
    let pacat: u32 = pacat.trim().parse().expect("a numeric pid");

    let released = client.ask("{\"cmd\":\"gateway\",\"action\":\"release\"}");
    assert!(released.contains("\"call_in\":\"off\""), "release: {released}");
    assert!(released.contains("\"prompt\":\"silent\""), "release: {released}");
    assert!(!dir.exists(), "release removed the call's directory");

    // A reaped child leaves `/proc`; a leaked one does not.
    let deadline = Instant::now() + Duration::from_secs(5);
    while std::path::Path::new(&format!("/proc/{pacat}")).exists() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        !std::path::Path::new(&format!("/proc/{pacat}")).exists(),
        "pacat {pacat} outlived release"
    );

    let reply = client.ask("{\"cmd\":\"quit\"}");
    assert_eq!(reply, "{\"ok\":true}");
    let (output, _socket_left) = server.finish();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let _ = fs::remove_dir_all(&tools);
    let _ = fs::remove_dir_all(&state);
}

/// A sink the server does not list at bind time comes up a moment later; the
/// engine's own retry reaches `captured` without anyone asking again.
#[test]
fn a_silent_gateway_bind_retries_until_the_source_appears() {
    let (state, plan) = gateway_state("gateway-retry");
    let marker = state.join("source-ready");
    let tools = fake_pactl("gateway-retry", &marker);
    let path = format!("{}:/usr/bin:/bin", tools.display());
    let server = Server::start_env(
        "gateway-retry",
        &[],
        &[("PATH", path.as_str()), ("JAWNOS_AUDIO_PLAN", plan.as_str())],
    );
    let mut client = server.connect();

    let bound = client.ask("{\"cmd\":\"gateway\",\"action\":\"bind\",\"call_in\":\"jawn_call_in\"}");
    assert!(bound.contains("\"call_in\":\"silent\""), "bind: {bound}");

    fs::write(&marker, b"now").expect("the source appears");
    let deadline = Instant::now() + Duration::from_secs(8);
    let mut last = String::new();
    while Instant::now() < deadline {
        last = client.ask("{\"cmd\":\"gateway\",\"action\":\"status\"}");
        if last.contains("\"call_in\":\"captured\"") {
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(
        last.contains("\"call_in\":\"captured\""),
        "the silent bind never retried: {last}"
    );

    let released = client.ask("{\"cmd\":\"gateway\",\"action\":\"release\"}");
    assert!(released.contains("\"call_in\":\"off\""), "release: {released}");
    let reply = client.ask("{\"cmd\":\"quit\"}");
    assert_eq!(reply, "{\"ok\":true}");
    let (output, _socket_left) = server.finish();
    assert!(
        output.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let _ = fs::remove_dir_all(&tools);
    let _ = fs::remove_dir_all(&state);
}

#[test]
fn the_transport_carries_a_clip_plan_and_reports_it() {
    // A real take on disk, so `start` reads it the way it reads a staged
    // browser take. The null backend renders the block and plays nothing.
    let take = TempFile::new("transport-clip");
    let mut writer =
        jawn_audio::WavWriter::create(&take.path, 48_000, 1, 512).expect("create the take");
    writer.write_f32(&vec![0.5f32; 4_800]).expect("write");
    writer.finish().expect("finish the take");

    let server = Server::start("transport-clip");
    let mut client = server.connect();

    let start = client.ask(&format!(
        "{{\"cmd\":\"transport\",\"action\":\"start\",\"position\":0,\"bpm\":120,\"beats_per_bar\":4,\"gain\":0,\"clips\":[{{\"file\":\"{}\",\"start\":0,\"offset\":0,\"duration\":0.1,\"gain\":1,\"pan\":-1}}]}}",
        take.text()
    ));
    assert!(start.contains("\"ok\":true"), "start: {start}");
    assert!(start.contains("\"state\":\"playing\""), "start: {start}");
    assert!(start.contains("\"clips\":1"), "start: {start}");

    // A different take set needs a new render thread: the running transport
    // refuses it rather than mixing two plans.
    let swap = client.ask(&format!(
        "{{\"cmd\":\"transport\",\"action\":\"start\",\"clips\":[{{\"file\":\"{}\",\"start\":0}}]}}",
        take.text()
    ));
    assert!(swap.contains("\"ok\":false"), "swap: {swap}");
    assert!(
        swap.contains("stop it before changing its clips"),
        "swap: {swap}"
    );

    // A seek keeps the clips and moves the position.
    let seek = client.ask("{\"cmd\":\"transport\",\"action\":\"seek\",\"position\":0.05}");
    assert!(seek.contains("\"ok\":true"), "seek: {seek}");
    assert!(seek.contains("\"clips\":1"), "seek: {seek}");
    assert_eq!(json_number(&seek, "position"), 0.05, "seek: {seek}");

    // The clip rate is the device rate; another rate is refused by name,
    // before a second thread or a device exists.
    let other = TempFile::new("transport-clip-rate");
    let mut writer =
        jawn_audio::WavWriter::create(&other.path, 44_100, 1, 512).expect("create the take");
    writer.write_f32(&vec![0.5f32; 4_410]).expect("write");
    writer.finish().expect("finish the take");
    let stopped = client.ask("{\"cmd\":\"transport\",\"action\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"stopped\""), "stop: {stopped}");
    assert!(stopped.contains("\"clips\":1"), "stop: {stopped}");

    let refused = client.ask(&format!(
        "{{\"cmd\":\"transport\",\"action\":\"start\",\"clips\":[{{\"file\":\"{}\",\"start\":0}}]}}",
        other.text()
    ));
    assert!(refused.contains("\"ok\":false"), "rate: {refused}");
    assert!(refused.contains("44100"), "rate: {refused}");

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
fn a_monitorless_take_records_beside_the_playing_transport() {
    // The transport owns the output and the take owns only the capture stream,
    // so the two can run at once. This is the same split `record` and `play`
    // already use: a take thread beside one output thread.
    let clip = TempFile::new("transport-share-clip");
    write_silent_wav(&clip.path, 4_800);

    let server = Server::start("transport-share");
    let mut client = server.connect();

    let start = client.ask(&format!(
        "{{\"cmd\":\"transport\",\"action\":\"start\",\"position\":0,\"bpm\":120,\"beats_per_bar\":4,\"gain\":0,\"clips\":[{{\"file\":\"{}\",\"start\":0}}]}}",
        clip.text()
    ));
    assert!(start.contains("\"ok\":true"), "start: {start}");
    assert!(start.contains("\"state\":\"playing\""), "start: {start}");

    // A take's own monitor files or click need an output of its own, so those
    // still refuse while the transport plays. Its live input is the exception
    // and is covered by its own test below.
    let monitored = TempFile::new("transport-share-monitored");
    let refused = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":1,\"monitor\":[\"{}\"]}}",
        monitored.text(),
        clip.text()
    ));
    assert!(refused.contains("\"ok\":false"), "monitor: {refused}");
    assert!(
        refused.contains("owns the metronome"),
        "monitor: {refused}"
    );

    // A take with no monitor only captures, so it records beside the transport.
    let take = TempFile::new("transport-share-take");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300,\"start_at\":48000}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    assert!(reply.contains("\"state\":\"recording\""), "record: {reply}");
    assert!(reply.contains("\"start_sample\":48000"), "record: {reply}");

    // One status leads with the take and reports the transport beside it.
    let status = client.wait_for_frames();
    assert!(status.contains("\"state\":\"recording\""), "status: {status}");
    assert!(
        status.contains("\"transport\":{\"state\":\"playing\""),
        "status: {status}"
    );

    // One stop joins both and answers with each role's final state.
    let stopped = client.ask("{\"cmd\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    assert!(
        stopped.contains("\"transport\":{\"state\":\"stopped\""),
        "stop: {stopped}"
    );
    let transport = client.ask("{\"cmd\":\"transport\",\"action\":\"status\"}");
    assert!(
        transport.contains("\"state\":\"stopped\""),
        "transport: {transport}"
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
fn a_live_take_monitors_beside_the_playing_transport() {
    // A take's live input rides the transport's one output through the same
    // master chain as the clips. `record` stop detaches it and leaves the
    // transport playing, so one output, one take and one attachment are all
    // the session ever has.
    let clip = TempFile::new("transport-live-clip");
    write_silent_wav(&clip.path, 4_800);

    let server = Server::start("transport-live");
    let mut client = server.connect();

    let start = client.ask(&format!(
        "{{\"cmd\":\"transport\",\"action\":\"start\",\"position\":0,\"bpm\":120,\"beats_per_bar\":4,\"gain\":0,\"clips\":[{{\"file\":\"{}\",\"start\":0}}]}}",
        clip.text()
    ));
    assert!(start.contains("\"state\":\"playing\""), "start: {start}");

    let take = TempFile::new("transport-live-take");
    let reply = client.ask(&format!(
        "{{\"cmd\":\"record\",\"out\":\"{}\",\"seconds\":300,\"monitor_input\":true,\"monitor_gain\":0.5}}",
        take.text()
    ));
    assert!(reply.contains("\"ok\":true"), "record: {reply}");
    assert!(reply.contains("\"state\":\"recording\""), "record: {reply}");
    assert!(reply.contains("\"monitor_input\":true"), "record: {reply}");

    // The transport carries the attachment and the same trim the take reports.
    let status = client.ask("{\"cmd\":\"transport\",\"action\":\"status\"}");
    assert!(status.contains("\"monitor_input\":true"), "status: {status}");
    assert!(status.contains("\"monitor_gain\":0.5"), "status: {status}");

    let param = client.ask(
        "{\"cmd\":\"param\",\"target\":\"input\",\"name\":\"gain\",\"value\":0.75}",
    );
    assert!(param.contains("\"gain\":0.75"), "param: {param}");
    let status = client.ask("{\"cmd\":\"transport\",\"action\":\"status\"}");
    assert!(status.contains("\"monitor_gain\":0.75"), "status: {status}");

    // Stopping the take hands the output back to the transport.
    let stopped = client.ask("{\"cmd\":\"record\",\"action\":\"stop\"}");
    assert!(stopped.contains("\"state\":\"done\""), "stop: {stopped}");
    let status = client.ask("{\"cmd\":\"transport\",\"action\":\"status\"}");
    assert!(status.contains("\"state\":\"playing\""), "status: {status}");
    assert!(status.contains("\"monitor_input\":false"), "status: {status}");

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
