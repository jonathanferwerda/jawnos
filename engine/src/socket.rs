//! The control socket: one flat JSON object per line, in and out.
//!
//! The Perl manager arms a take (`record`), watches it (`status`) and ends it
//! (`stop`) over a Unix socket, so the wire format here is deliberately dumb:
//! one object per line, values that are only strings, numbers, booleans or
//! null, and no crates — the parser below is the whole of it. That keeps the
//! engine's dependency set at "the audio backend, and nothing else"
//! (docs/studio-audio-roadmap.md §7, P2).
//!
//! # The socket's life
//!
//! The parent directory is created if missing, a socket left by a killed
//! engine is unlinked, the socket is bound, and its mode is set to 0600 at
//! once. A clean `quit` unlinks it; a crash leaves the file behind on purpose,
//! because the next start removes whatever is at that path before binding.
//! That is why the unlink happens *before* `bind` and never after a successful
//! bind: removing a live socket would strand the running engine.
//!
//! # One client at a time
//!
//! The manager is the only caller, and two controllers would arm and stop the
//! same take. A second connection is answered with one error line and closed.
//! Seeing it takes a non-blocking accept while the first client is connected,
//! so the loop here is a small poll rather than a plain `accept`/read pair.
//!
//! # Recording
//!
//! A take runs on its own thread and never writes to disk itself: it hands
//! blocks to [`DiskWriter`], whose writer thread owns the WAV, so a capture
//! loop cannot miss its deadline because a file write stalled. `status` reads a
//! small mutex the worker updates; `stop` sets a flag and *joins* the worker, so
//! the answer describes a closed WAV rather than a guess about one still being
//! written. A take keeps running if its client hangs up; the next client can
//! ask `status` or `stop` it.

use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use jawn_audio::{to_i16, BackendKind, Device, DiskWriter, NullDevice};

use crate::{take_frames, RECORD_CHANNELS};

/// How long a take runs when the command does not say.
const DEFAULT_SECONDS: f64 = 10.0;

/// The serve loop's poll interval. A command that arrives waits at most this
/// long to be read; the socket is idle almost all the time.
const POLL: Duration = Duration::from_millis(2);

/// A command is one flat object; this bounds a client that never sends a
/// newline.
const MAX_LINE: usize = 64 * 1024;

/// How many times `send` retries a blocked write before deciding the peer is
/// gone. A reply is one short line, so this is generous.
const SEND_RETRIES: usize = 2_000;

/// The engine's shape for a take, plus where it listens.
#[derive(Clone)]
pub(crate) struct Config {
    pub backend: BackendKind,
    pub device: String,
    pub rate: u32,
    pub period: usize,
    pub buffer: usize,
    pub socket: PathBuf,
}

/// `--socket`, else `$JAWNOS_AUDIO_SOCKET`, else `$HOME/.president/audio.sock`.
pub(crate) fn default_path(flag: Option<&str>) -> Result<PathBuf, String> {
    if let Some(path) = flag {
        return Ok(PathBuf::from(path));
    }
    if let Ok(path) = std::env::var("JAWNOS_AUDIO_SOCKET") {
        if !path.is_empty() {
            return Ok(PathBuf::from(path));
        }
    }
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() => Ok(PathBuf::from(home).join(".president/audio.sock")),
        _ => Err(
            "no control socket path: pass --socket, set JAWNOS_AUDIO_SOCKET, or set HOME"
                .to_string(),
        ),
    }
}

pub(crate) fn serve(config: Config) -> Result<ExitCode, String> {
    let path = config.socket.clone();
    let listener = bind(&path)?;
    let mut server = Server {
        config,
        current: None,
        next_take: 1,
    };
    let outcome = server.run(listener);
    // A clean exit unlinks the socket. A crash leaves it behind, and the next
    // start unlinks that stale path before it binds.
    let _ = fs::remove_file(&path);
    outcome.map(|()| ExitCode::SUCCESS)
}

/// Create the parent directory, drop a stale socket, bind, and lock the socket
/// down to its owner.
fn bind(path: &Path) -> Result<UnixListener, String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            fs::create_dir_all(parent).map_err(|error| {
                format!("cannot create the socket directory {}: {error}", parent.display())
            })?;
        }
    }
    // A socket file with a listener behind it is a live engine. Refuse rather
    // than unlink it: a second engine must never steal the first one's path or
    // answer its manager. `connect` to a stale file fails, which is the only
    // case where removing it is safe.
    if path.exists() {
        if UnixStream::connect(path).is_ok() {
            return Err(format!(
                "another engine is already serving {}",
                path.display()
            ));
        }
        match fs::remove_file(path) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(format!(
                    "cannot remove the stale socket {}: {error}",
                    path.display()
                ))
            }
        }
    }
    let listener = UnixListener::bind(path)
        .map_err(|error| format!("cannot listen on {}: {error}", path.display()))?;
    // `bind` honours the umask, so the mode is corrected at once. The window is
    // a few instructions wide, and the socket has not accepted anything yet.
    if let Err(error) = fs::set_permissions(path, fs::Permissions::from_mode(0o600)) {
        let _ = fs::remove_file(path);
        return Err(format!("cannot set 0600 on {}: {error}", path.display()));
    }
    Ok(listener)
}

/// The last take, and the worker that produced it.
struct Server {
    config: Config,
    /// The most recent take. It stays after the worker ends, so `status` can
    /// report the final state until the next `record`.
    current: Option<Running>,
    next_take: u64,
}

impl Server {
    fn run(&mut self, listener: UnixListener) -> Result<(), String> {
        loop {
            // Block while idle; `serve_one` switches to non-blocking so it can
            // see a second connection arrive while the first still holds the
            // socket.
            listener
                .set_nonblocking(false)
                .map_err(|error| format!("cannot set the socket blocking: {error}"))?;
            let (stream, _) = listener.accept().map_err(|error| {
                format!("accept on {}: {error}", self.config.socket.display())
            })?;
            stream
                .set_nonblocking(true)
                .map_err(|error| format!("cannot set the client non-blocking: {error}"))?;
            let client = Client {
                stream,
                pending: Vec::new(),
            };
            if self.serve_one(&listener, client)? {
                return Ok(());
            }
        }
    }

    /// Serve one client until it disconnects. Returns true when it asked to
    /// quit, which ends the process.
    fn serve_one(&mut self, listener: &UnixListener, mut client: Client) -> Result<bool, String> {
        listener
            .set_nonblocking(true)
            .map_err(|error| format!("cannot set the socket non-blocking: {error}"))?;
        let mut scratch = [0u8; 8192];
        loop {
            // One client at a time: a second connection is told why, in the
            // same line protocol, and closed without reading anything from it.
            match listener.accept() {
                Ok((mut second, _)) => {
                    let line = format!("{}\n", error_line("a client is already connected"));
                    let _ = second.write_all(line.as_bytes());
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => {
                    return Err(format!(
                        "accept on {}: {error}",
                        self.config.socket.display()
                    ))
                }
            }

            match client.stream.read(&mut scratch) {
                Ok(0) => return Ok(false),
                Ok(count) => client.pending.extend_from_slice(&scratch[..count]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(POLL);
                    continue;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => return Ok(false),
            }

            if client.pending.len() > MAX_LINE && !client.pending.contains(&b'\n') {
                client.pending.clear();
                if !send(
                    &mut client.stream,
                    &error_line("a command line is limited to 65536 bytes"),
                ) {
                    return Ok(false);
                }
                continue;
            }

            while let Some(end) = client.pending.iter().position(|byte| *byte == b'\n') {
                let line: Vec<u8> = client.pending.drain(..=end).collect();
                let text = String::from_utf8_lossy(&line[..line.len() - 1]);
                let text = text.trim_end_matches('\r').to_string();
                match self.handle(&text) {
                    Action::Reply(reply) => {
                        if !send(&mut client.stream, &reply) {
                            return Ok(false);
                        }
                    }
                    Action::Quit(reply) => {
                        // Finish the take before the process goes, so the WAV
                        // the caller armed is closed rather than left as a
                        // prefix. A quit is still answered exactly as promised.
                        if let Some(running) = &mut self.current {
                            running.finish();
                        }
                        let _ = send(&mut client.stream, &reply);
                        return Ok(true);
                    }
                }
            }
        }
    }

    fn handle(&mut self, line: &str) -> Action {
        let object = match parse_object(line) {
            Ok(object) => object,
            Err(error) => return Action::Reply(error_line(&error)),
        };
        let command = match get(&object, "cmd") {
            Some(Value::Str(command)) => command.as_str(),
            _ => return Action::Reply(error_line("unknown command")),
        };
        match command {
            "record" => Action::Reply(self.record(&object)),
            "status" => Action::Reply(self.status_line()),
            "stop" => Action::Reply(self.stop_line()),
            "quit" => Action::Quit("{\"ok\":true}".to_string()),
            _ => Action::Reply(error_line("unknown command")),
        }
    }

    fn record(&mut self, object: &Object) -> String {
        let path = match get(object, "out") {
            Some(Value::Str(path)) => path.clone(),
            _ => return error_line("record needs \"out\": an absolute path"),
        };
        if !Path::new(&path).is_absolute() {
            return error_line("record needs \"out\" to be an absolute path");
        }
        let seconds = match get(object, "seconds") {
            None | Some(Value::Null) => DEFAULT_SECONDS,
            Some(Value::Num(value)) if value.is_finite() && *value >= 0.0 => *value,
            _ => return error_line("\"seconds\" must be a number of seconds, not negative"),
        };
        let start_at = match get(object, "start_at") {
            None | Some(Value::Null) => 0,
            Some(Value::Num(value))
                if value.is_finite()
                    && *value >= 0.0
                    && value.fract() == 0.0
                    && *value <= u64::MAX as f64 =>
            {
                *value as u64
            }
            _ => return error_line("\"start_at\" must be a whole, non-negative sample count"),
        };
        if let Some(running) = &self.current {
            if running.is_recording() {
                return error_line("a take is already running");
            }
        }

        // Support and device first, in the same order as `--record`: a backend
        // that cannot capture must not truncate a file the caller named.
        if let Err(error) = crate::record_support(self.config.backend) {
            return error_line(&error);
        }
        if let Err(error) = crate::probe_capture(
            self.config.backend,
            &self.config.device,
            self.config.rate,
            self.config.period,
            self.config.buffer,
        ) {
            return error_line(&error);
        }

        let frames = take_frames(seconds, self.config.rate);
        let queue = crate::queue_blocks(
            self.config.backend,
            frames,
            self.config.period,
            RECORD_CHANNELS,
        );
        let disk = match DiskWriter::spawn(
            Path::new(&path),
            self.config.rate,
            RECORD_CHANNELS as u16,
            self.config.period,
            queue,
        ) {
            Ok(disk) => disk,
            Err(error) => return error_line(&format!("cannot write {path}: {error}")),
        };

        // Join a finished worker before replacing it, so a stream of takes does
        // not leave detached threads behind.
        if let Some(mut previous) = self.current.take() {
            previous.finish();
        }

        let take = self.next_take;
        self.next_take += 1;
        let shared = Arc::new(Mutex::new(Status {
            take,
            state: State::Recording,
            path: path.clone(),
            frames: 0,
            dropped: 0,
            start_sample: start_at,
            xruns: 0,
            error: String::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));

        let spawned = {
            let shared = Arc::clone(&shared);
            let stop = Arc::clone(&stop);
            let config = self.config.clone();
            thread::Builder::new()
                .name("jawn-audio-take".to_string())
                .spawn(move || run_take(config, seconds, disk, shared, stop))
        };
        let handle = match spawned {
            Ok(handle) => handle,
            Err(error) => {
                // No worker, no take: do not leave a WAV nobody will finish.
                let _ = fs::remove_file(&path);
                return error_line(&format!("cannot start the take thread: {error}"));
            }
        };

        self.current = Some(Running {
            status: shared,
            stop,
            handle: Some(handle),
        });
        format!(
            "{{\"ok\":true,\"take\":{take},\"state\":\"recording\",\"start_sample\":{start_at}}}"
        )
    }

    fn status_line(&self) -> String {
        match &self.current {
            Some(running) => running.line(),
            None => idle_line(),
        }
    }

    fn stop_line(&mut self) -> String {
        match &mut self.current {
            Some(running) => {
                // Signals the worker and joins it: the disk writer has closed
                // the WAV before this returns, so `frames` is what is on disk.
                running.finish();
                running.line()
            }
            None => idle_line(),
        }
    }
}

fn idle_line() -> String {
    "{\"ok\":true,\"take\":0,\"state\":\"idle\"}".to_string()
}

fn error_line(error: &str) -> String {
    format!(
        "{{\"ok\":false,\"error\":\"{}\"}}",
        jawn_audio::loopback::json_escape(error)
    )
}

/// What the protocol answers: a line, or a line and then the end.
enum Action {
    Reply(String),
    Quit(String),
}

/// One connected client: its stream and the bytes of a line not yet complete.
struct Client {
    stream: UnixStream,
    pending: Vec<u8>,
}

/// Write one reply line. False means the client is gone (or will not read).
fn send(stream: &mut UnixStream, line: &str) -> bool {
    let mut bytes = Vec::with_capacity(line.len() + 1);
    bytes.extend_from_slice(line.as_bytes());
    bytes.push(b'\n');
    let mut sent = 0;
    let mut stalls = 0;
    while sent < bytes.len() {
        match stream.write(&bytes[sent..]) {
            Ok(0) => return false,
            Ok(count) => {
                sent += count;
                stalls = 0;
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                stalls += 1;
                if stalls > SEND_RETRIES {
                    return false;
                }
                thread::sleep(POLL);
            }
            Err(_) => return false,
        }
    }
    true
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum State {
    Recording,
    Done,
    Failed,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Recording => "recording",
            State::Done => "done",
            State::Failed => "failed",
        }
    }
}

#[derive(Clone)]
struct Status {
    take: u64,
    state: State,
    path: String,
    frames: u64,
    dropped: u64,
    start_sample: u64,
    xruns: usize,
    error: String,
}

/// The server's handle to one take's worker thread.
struct Running {
    status: Arc<Mutex<Status>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl Running {
    fn snapshot(&self) -> Status {
        let status = self
            .status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        status.clone()
    }

    fn is_recording(&self) -> bool {
        self.snapshot().state == State::Recording
    }

    /// Signal the worker and wait for it. When this returns the writer thread
    /// has finished the WAV and the status is final.
    fn finish(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let joined = match self.handle.take() {
            Some(handle) => handle.join(),
            None => Ok(()),
        };
        if joined.is_err() {
            // A panicked worker leaves nothing to guess about: say so instead of
            // reporting `recording` forever.
            let mut status = self
                .status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if status.state == State::Recording {
                status.state = State::Failed;
                status.error = "the take thread panicked".to_string();
            }
        }
    }

    fn line(&self) -> String {
        let status = self.snapshot();
        format!(
            "{{\"ok\":true,\"take\":{},\"state\":\"{}\",\"path\":\"{}\",\"frames\":{},\"dropped\":{},\"start_sample\":{},\"xruns\":{},\"error\":\"{}\"}}",
            status.take,
            status.state.name(),
            jawn_audio::loopback::json_escape(&status.path),
            status.frames,
            status.dropped,
            status.start_sample,
            status.xruns,
            jawn_audio::loopback::json_escape(&status.error)
        )
    }
}

/// What a capture produced besides its frames.
struct Captured {
    rate: u32,
    xruns: usize,
}

/// The take's worker: capture, hand every block to the disk writer, then say
/// how it ended.
fn run_take(
    config: Config,
    seconds: f64,
    mut disk: DiskWriter,
    status: Arc<Mutex<Status>>,
    stop: Arc<AtomicBool>,
) {
    let outcome = match config.backend {
        BackendKind::Null => capture_null(&config, seconds, &mut disk, &status, &stop),
        BackendKind::Alsa | BackendKind::PipeWire | BackendKind::Jack => {
            capture_hardware(&config, seconds, &mut disk, &status, &stop)
        }
    };
    // A stop is the caller's choice, not a failure: the take ends where it was
    // asked to, with a finished header.
    let was_stopped = stop.load(Ordering::SeqCst);
    let produced = frames_so_far(&status);
    let dropped = disk.dropped_frames();
    let finished = disk.finish();

    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.dropped = dropped;
    let path = current.path.clone();
    match finished {
        Ok(frames) => {
            current.frames = frames;
            match outcome {
                Ok(captured) => {
                    current.xruns = captured.xruns;
                    if captured.rate != config.rate {
                        // The samples are at the granted rate; the header must
                        // say so, and only the worker knows the granted rate.
                        if let Err(error) = crate::rewrite_rate(Path::new(&path), captured.rate) {
                            current.state = State::Failed;
                            current.error = error;
                            return;
                        }
                    }
                    current.state = State::Done;
                }
                Err(_) if was_stopped => current.state = State::Done,
                Err(error) => {
                    current.state = State::Failed;
                    current.error = error;
                    // An empty failed take is not a take; a partial one is kept
                    // for the manager to decide about.
                    if produced == 0 {
                        let _ = fs::remove_file(&path);
                    }
                }
            }
        }
        Err(error) => {
            current.state = State::Failed;
            current.error = format!("cannot finish the take: {error}");
            if produced == 0 {
                let _ = fs::remove_file(&path);
            }
        }
    }
}

/// Update what `status` reads while a take runs: frames captured so far and
/// frames dropped so far. The lock is uncontended and held for two field
/// writes, so this never blocks the capture loop in practice.
fn note_progress(status: &Arc<Mutex<Status>>, frames: u64, dropped: u64) {
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.frames = frames;
    current.dropped = dropped;
}

/// The frames the worker has handed to disk so far.
fn frames_so_far(status: &Arc<Mutex<Status>>) -> u64 {
    status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .frames
}

/// The null take: silence through the same block loop as hardware. The queue is
/// sized for the whole take (see `main::queue_blocks`), because this loop runs
/// far faster than real time.
fn capture_null(
    config: &Config,
    seconds: f64,
    disk: &mut DiskWriter,
    status: &Arc<Mutex<Status>>,
    stop: &AtomicBool,
) -> Result<Captured, String> {
    let mut device = NullDevice::new(config.rate, config.period, RECORD_CHANNELS);
    let total = take_frames(seconds, config.rate);
    let mut block = vec![0.0f32; config.period * RECORD_CHANNELS];
    let mut pcm = vec![0i16; config.period * RECORD_CHANNELS];
    let mut remaining = total;
    let mut pushed = 0u64;
    while remaining > 0 {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        device
            .process(&mut block)
            .map_err(|error| format!("device: {error:?}"))?;
        let frames = remaining.min(config.period as u64) as usize;
        let samples = frames * RECORD_CHANNELS;
        for (out, sample) in pcm[..samples].iter_mut().zip(&block[..samples]) {
            *out = to_i16(*sample);
        }
        disk.push(&pcm[..samples]);
        pushed += frames as u64;
        note_progress(status, pushed, disk.dropped_frames());
        remaining -= frames as u64;
    }
    Ok(Captured {
        rate: config.rate,
        xruns: 0,
    })
}

#[cfg(feature = "alsa")]
struct ServeSink<'a> {
    disk: &'a mut DiskWriter,
    status: &'a Arc<Mutex<Status>>,
    stop: &'a AtomicBool,
    pushed: u64,
}

#[cfg(feature = "alsa")]
impl jawn_audio::alsa_device::CaptureSink for ServeSink<'_> {
    fn block(&mut self, block: &[i16]) -> Result<(), String> {
        // The sink is the only place a stop can reach a device loop that owns
        // the read: ending the sink ends the capture.
        if self.stop.load(Ordering::SeqCst) {
            return Err("stopped".to_string());
        }
        self.disk.push(block);
        self.pushed += (block.len() / RECORD_CHANNELS) as u64;
        note_progress(self.status, self.pushed, self.disk.dropped_frames());
        Ok(())
    }
}

#[cfg(feature = "alsa")]
fn capture_hardware(
    config: &Config,
    seconds: f64,
    disk: &mut DiskWriter,
    status: &Arc<Mutex<Status>>,
    stop: &AtomicBool,
) -> Result<Captured, String> {
    let sink = ServeSink {
        disk,
        status,
        stop,
        pushed: 0,
    };
    let report = jawn_audio::alsa_device::run_capture(
        &config.device,
        config.rate,
        config.period,
        config.buffer,
        seconds,
        sink,
    )
    .map_err(|error| format!("cannot record: {error}"))?;
    Ok(Captured {
        rate: report.rate,
        xruns: report.xruns,
    })
}

#[cfg(not(feature = "alsa"))]
fn capture_hardware(
    config: &Config,
    seconds: f64,
    disk: &mut DiskWriter,
    status: &Arc<Mutex<Status>>,
    stop: &AtomicBool,
) -> Result<Captured, String> {
    let _ = (config, seconds, disk, status, stop);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

// --- the parser -------------------------------------------------------------

/// One scalar from a flat object.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Str(String),
    Num(f64),
    Bool(bool),
    Null,
}

/// A flat object, in the order its keys appeared. A repeated key reads as the
/// last one, as a JSON parser would.
pub type Object = Vec<(String, Value)>;

/// The last value for `key`, if the object has one.
pub fn get<'a>(object: &'a Object, key: &str) -> Option<&'a Value> {
    object
        .iter()
        .rev()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value)
}

/// Parse one flat JSON object.
///
/// Values are strings, numbers, booleans or null only: an array or an object
/// in a value position is an error, so a caller cannot smuggle a shape this
/// protocol never promised. Strings decode `\"`, `\\`, `\/`, `\b`, `\f`, `\n`,
/// `\r`, `\t` and `\uXXXX` (including surrogate pairs); every other character,
/// including non-ASCII and spaces, is taken literally.
pub fn parse_object(line: &str) -> Result<Object, String> {
    let mut parser = Parser { text: line, at: 0 };
    parser.skip_ws();
    parser.expect(b'{')?;
    let mut object = Object::new();
    parser.skip_ws();
    if parser.bump_if(b'}') {
        parser.finish()?;
        return Ok(object);
    }
    loop {
        parser.skip_ws();
        let key = parser.string()?;
        parser.skip_ws();
        parser.expect(b':')?;
        parser.skip_ws();
        let value = parser.value()?;
        object.push((key, value));
        parser.skip_ws();
        if parser.bump_if(b',') {
            continue;
        }
        if parser.bump_if(b'}') {
            break;
        }
        return Err(format!(
            "expected `,` or `}}` after a value (byte {})",
            parser.at
        ));
    }
    parser.finish()?;
    Ok(object)
}

struct Parser<'a> {
    text: &'a str,
    at: usize,
}

impl Parser<'_> {
    fn peek(&self) -> Option<u8> {
        self.text.as_bytes().get(self.at).copied()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
            self.at += 1;
        }
    }

    fn bump_if(&mut self, byte: u8) -> bool {
        if self.peek() == Some(byte) {
            self.at += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, byte: u8) -> Result<(), String> {
        match self.peek() {
            Some(found) if found == byte => {
                self.at += 1;
                Ok(())
            }
            Some(found) => Err(format!(
                "expected `{}` but found `{}` at byte {}",
                byte as char,
                char::from(found),
                self.at
            )),
            None => Err(format!(
                "expected `{}` but the line ended",
                byte as char
            )),
        }
    }

    fn next_char(&mut self) -> Option<char> {
        let character = self.text[self.at..].chars().next()?;
        self.at += character.len_utf8();
        Some(character)
    }

    fn eat(&mut self, text: &str) -> bool {
        if self.text[self.at..].starts_with(text) {
            self.at += text.len();
            true
        } else {
            false
        }
    }

    fn finish(&mut self) -> Result<(), String> {
        self.skip_ws();
        if self.at == self.text.len() {
            Ok(())
        } else {
            Err(format!(
                "trailing text after the object at byte {}",
                self.at
            ))
        }
    }

    fn value(&mut self) -> Result<Value, String> {
        match self.peek() {
            Some(b'"') => return self.string().map(Value::Str),
            Some(b'{') | Some(b'[') => {
                return Err(
                    "a value must be a string, number, boolean or null: arrays and nested objects are not allowed"
                        .to_string(),
                )
            }
            Some(b'-') | Some(b'0'..=b'9') => return self.number(),
            Some(_) => {}
            None => return Err("the object ends where a value was expected".to_string()),
        }
        if self.eat("true") {
            return Ok(Value::Bool(true));
        }
        if self.eat("false") {
            return Ok(Value::Bool(false));
        }
        if self.eat("null") {
            return Ok(Value::Null);
        }
        Err(format!(
            "a value must be a string, number, boolean or null (byte {})",
            self.at
        ))
    }

    fn number(&mut self) -> Result<Value, String> {
        let start = self.at;
        if self.peek() == Some(b'-') {
            self.at += 1;
        }
        let mut digits = 0;
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.at += 1;
            digits += 1;
        }
        if digits == 0 {
            return Err(format!("`-` is not a number (byte {start})"));
        }
        if self.peek() == Some(b'.') {
            self.at += 1;
            let mut fraction = 0;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.at += 1;
                fraction += 1;
            }
            if fraction == 0 {
                return Err(format!("a decimal point needs digits (byte {start})"));
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.at += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.at += 1;
            }
            let mut exponent = 0;
            while matches!(self.peek(), Some(b'0'..=b'9')) {
                self.at += 1;
                exponent += 1;
            }
            if exponent == 0 {
                return Err(format!("an exponent needs digits (byte {start})"));
            }
        }
        let text = &self.text[start..self.at];
        text.parse::<f64>()
            .map(Value::Num)
            .map_err(|_| format!("`{text}` is not a number"))
    }

    fn string(&mut self) -> Result<String, String> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            let character = match self.next_char() {
                Some(character) => character,
                None => return Err("a string is not terminated".to_string()),
            };
            match character {
                '"' => return Ok(out),
                '\\' => out.push(self.escape()?),
                control if (control as u32) < 0x20 => {
                    return Err(format!(
                        "a raw control character (0x{:02x}) in a string must be escaped",
                        control as u32
                    ))
                }
                other => out.push(other),
            }
        }
    }

    fn escape(&mut self) -> Result<char, String> {
        let character = match self.next_char() {
            Some(character) => character,
            None => return Err("a string ends after a backslash".to_string()),
        };
        Ok(match character {
            '"' => '"',
            '\\' => '\\',
            '/' => '/',
            'b' => '\u{8}',
            'f' => '\u{c}',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => self.unicode_escape()?,
            other => return Err(format!("unknown string escape `\\{other}`")),
        })
    }

    fn unicode_escape(&mut self) -> Result<char, String> {
        let first = self.hex4()?;
        if (0xD800..=0xDBFF).contains(&first) {
            if !self.eat("\\u") {
                return Err("a high surrogate needs a low surrogate after it".to_string());
            }
            let second = self.hex4()?;
            if !(0xDC00..=0xDFFF).contains(&second) {
                return Err("a high surrogate was not followed by a low surrogate".to_string());
            }
            let code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00);
            return char::from_u32(code)
                .ok_or_else(|| "the surrogate pair is not a character".to_string());
        }
        if (0xDC00..=0xDFFF).contains(&first) {
            return Err("a lone low surrogate is not a character".to_string());
        }
        char::from_u32(first).ok_or_else(|| format!("\\u{first:04X} is not a character"))
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let mut value = 0u32;
        for _ in 0..4 {
            let character = match self.next_char() {
                Some(character) => character,
                None => return Err("a \\u escape needs four hex digits".to_string()),
            };
            let digit = character
                .to_digit(16)
                .ok_or_else(|| format!("`{character}` is not a hex digit in a \\u escape"))?;
            value = value * 16 + digit;
        }
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text<'a>(object: &'a Object, key: &str) -> Option<&'a str> {
        match get(object, key) {
            Some(Value::Str(value)) => Some(value.as_str()),
            _ => None,
        }
    }

    fn number(object: &Object, key: &str) -> Option<f64> {
        match get(object, key) {
            Some(Value::Num(value)) => Some(*value),
            _ => None,
        }
    }

    #[test]
    fn a_flat_object_keeps_strings_numbers_booleans_and_null() {
        let object =
            parse_object(r#"{"cmd":"record","seconds":0.25,"start_at":96000,"loud":true,"quiet":false,"device":null}"#)
                .expect("parse");
        assert_eq!(text(&object, "cmd"), Some("record"));
        assert_eq!(number(&object, "seconds"), Some(0.25));
        assert_eq!(number(&object, "start_at"), Some(96000.0));
        assert_eq!(get(&object, "loud"), Some(&Value::Bool(true)));
        assert_eq!(get(&object, "quiet"), Some(&Value::Bool(false)));
        assert_eq!(get(&object, "device"), Some(&Value::Null));
    }

    #[test]
    fn a_string_keeps_spaces_and_non_ascii() {
        let object = parse_object("{\"out\":\"/tmp/a take — café/one.wav\"}").expect("parse");
        assert_eq!(text(&object, "out"), Some("/tmp/a take — café/one.wav"));
    }

    #[test]
    fn a_string_decodes_the_escapes_a_path_or_message_can_carry() {
        let object =
            parse_object(r#"{"p":"quote \" slash / backslash \\ tab \t newline \n"}"#)
                .expect("parse");
        assert_eq!(
            text(&object, "p"),
            Some("quote \" slash / backslash \\ tab \t newline \n")
        );
    }

    #[test]
    fn unicode_escapes_decode_including_a_surrogate_pair() {
        let object = parse_object(r#"{"a":"caf\u00e9","b":"\ud83c\udfb5"}"#).expect("parse");
        assert_eq!(text(&object, "a"), Some("café"));
        assert_eq!(text(&object, "b"), Some("🎵"));
    }

    #[test]
    fn a_lone_or_malformed_surrogate_is_refused() {
        assert!(parse_object(r#"{"a":"\ud83c"}"#).is_err());
        assert!(parse_object(r#"{"a":"\ud83c\u0041"}"#).is_err());
        assert!(parse_object(r#"{"a":"\udc00"}"#).is_err());
        assert!(parse_object(r#"{"a":"\u12"}"#).is_err());
        assert!(parse_object(r#"{"a":"\uZZZZ"}"#).is_err());
    }

    #[test]
    fn numbers_take_a_sign_a_fraction_and_an_exponent() {
        let object = parse_object("{\"a\":-1,\"b\":-0.5,\"c\":1e3,\"d\":2.5E-2,\"e\":0}")
            .expect("parse");
        assert_eq!(number(&object, "a"), Some(-1.0));
        assert_eq!(number(&object, "b"), Some(-0.5));
        assert_eq!(number(&object, "c"), Some(1000.0));
        assert_eq!(number(&object, "d"), Some(0.025));
        assert_eq!(number(&object, "e"), Some(0.0));
    }

    #[test]
    fn a_broken_number_is_refused_rather_than_guessed() {
        assert!(parse_object("{\"a\":-}").is_err());
        assert!(parse_object("{\"a\":1.}").is_err());
        assert!(parse_object("{\"a\":1e}").is_err());
        assert!(parse_object("{\"a\":NaN}").is_err());
        assert!(parse_object("{\"a\":+1}").is_err());
    }

    #[test]
    fn the_empty_object_parses_and_whitespace_is_ignored() {
        let object = parse_object("  {  }  ").expect("parse");
        assert!(object.is_empty());
        let object = parse_object("{\n\t\"cmd\" : \"status\"\r\n}").expect("parse");
        assert_eq!(text(&object, "cmd"), Some("status"));
    }

    #[test]
    fn the_last_repeated_key_wins() {
        let object = parse_object(r#"{"cmd":"status","cmd":"quit"}"#).expect("parse");
        assert_eq!(text(&object, "cmd"), Some("quit"));
    }

    #[test]
    fn arrays_and_nested_objects_are_refused() {
        let error = parse_object(r#"{"a":[1,2]}"#).unwrap_err();
        assert!(error.contains("arrays"), "{error}");
        let error = parse_object(r#"{"a":{"b":1}}"#).unwrap_err();
        assert!(error.contains("nested"), "{error}");
        // A nested object in the key position is not a shape either.
        assert!(parse_object(r#"{{"a":1}:2}"#).is_err());
    }

    #[test]
    fn a_bare_array_is_not_an_object() {
        let error = parse_object("[1,2,3]").unwrap_err();
        assert!(error.contains('{'), "{error}");
    }

    #[test]
    fn malformed_objects_say_where_they_broke() {
        assert!(parse_object("").is_err());
        assert!(parse_object("{} extra").is_err());
        assert!(parse_object(r#"{"a" 1}"#).is_err());
        assert!(parse_object(r#"{"a":1 "b":2}"#).is_err());
        assert!(parse_object(r#"{"a":"unterminated}"#).is_err());
        assert!(parse_object(r#"{"a":"line
break"}"#).is_err());
        assert!(parse_object(r#"{"a":"bad \q escape"}"#).is_err());
        assert!(parse_object(r#"{"a":1,}"#).is_err());
        assert!(parse_object("{\"a\":1}").is_ok(), "a good object parses");
    }
}
