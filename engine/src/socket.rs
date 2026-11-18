//! The control socket: one flat JSON object per line, in and out.
//!
//! The Perl manager arms a take (`record`), watches it (`status`), moves the
//! running strip's knobs (`param`) and ends it (`stop`) over a Unix socket, so
//! the wire format here is deliberately dumb:
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

use jawn_audio::{
    to_i16, BackendKind, Channel, Device, DiskWriter, Mixer, NullDevice, ParamName, ParamQueue,
};

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
            "param" => Action::Reply(self.param(&object)),
            "status" => Action::Reply(self.status_line()),
            "stop" => Action::Reply(self.stop_line()),
            "quit" => Action::Quit("{\"ok\":true}".to_string()),
            _ => Action::Reply(error_line("unknown command")),
        }
    }

    /// `{"cmd":"param","track":0,"name":"gain","value":0.5}`: move one
    /// knob of a running take's strip.
    ///
    /// The command moves the strip at its next block, so the answer means
    /// "queued", not "heard". The effect clamps the value (see
    /// [`Channel::set`]); the socket rejects only what is not a parameter at
    /// all. The knob mirror in `status` is updated here, because the strip
    /// itself lives on the take thread and nothing else writes these values.
    fn param(&mut self, object: &Object) -> String {
        let running = match &self.current {
            Some(running) if running.is_recording() => running,
            _ => return error_line("no take is running"),
        };
        let track = match get(object, "track") {
            Some(Value::Num(value))
                if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 => *value as usize,
            _ => return error_line("param needs \"track\": a 0-based track number"),
        };
        let name = match get(object, "name") {
            Some(Value::Str(name)) => name.as_str(),
            _ => return error_line("param needs \"name\": a parameter name"),
        };
        // A finite number only: a NaN or an infinity has no knob position, and
        // the effects refuse one rather than smoothing toward it.
        let value = match get(object, "value") {
            Some(Value::Num(value)) if value.is_finite() => *value as f32,
            _ => return error_line("\"value\" must be a finite number"),
        };

        let snapshot = running.snapshot();
        let count = snapshot.tracks.len();
        if track >= count {
            return error_line(&format!("no track {track} (the take has {count})"));
        }
        let parameter = match ParamName::parse(name) {
            Some(parameter) => parameter,
            None => return error_line(&format!("no such parameter: {name}")),
        };
        if let Some(insert) = parameter.insert() {
            let present = snapshot.tracks[track]
                .inserts
                .split(',')
                .any(|entry| entry == insert);
            if !present {
                return error_line(&format!("no such parameter: {name}"));
            }
        }

        if !running.params.push(track, parameter, value) {
            return error_line("the parameter queue is full; try again next block");
        }
        if matches!(parameter, ParamName::Gain | ParamName::Pan) {
            let mut status = running
                .status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(entry) = status.tracks.get_mut(track) {
                match parameter {
                    ParamName::Gain => entry.gain = Channel::clamp_gain(value),
                    ParamName::Pan => entry.pan = Channel::clamp_pan(value),
                    _ => {}
                }
            }
        }

        format!(
            "{{\"ok\":true,\"track\":{},\"name\":\"{}\"}}",
            track,
            jawn_audio::loopback::json_escape(name)
        )
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
        let tracks = match get(object, "tracks") {
            None | Some(Value::Null) => 1usize,
            Some(Value::Num(value))
                if value.is_finite() && (*value == 1.0 || *value == 2.0) =>
            {
                *value as usize
            }
            _ => return error_line("\"tracks\" must be 1 or 2"),
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

        // One WAV per track: a one-track take keeps `out` exactly; two tracks
        // split the stem into `-ch1`/`-ch2`. Both files share one start_sample,
        // because one take is one position on the transport.
        let paths = match crate::take_paths(&path, tracks) {
            Ok(paths) => paths,
            Err(error) => return error_line(&error),
        };
        let frames = take_frames(seconds, self.config.rate);
        let queue = crate::queue_blocks(
            self.config.backend,
            frames,
            self.config.period,
            RECORD_CHANNELS,
        );
        let mut disks: Vec<DiskWriter> = Vec::with_capacity(paths.len());
        for (index, track_path) in paths.iter().enumerate() {
            match DiskWriter::spawn(
                Path::new(track_path),
                self.config.rate,
                RECORD_CHANNELS as u16,
                self.config.period,
                queue,
            ) {
                Ok(disk) => disks.push(disk),
                Err(error) => {
                    for disk in disks {
                        let _ = disk.finish();
                    }
                    for spawned in &paths[..index] {
                        let _ = fs::remove_file(spawned);
                    }
                    return error_line(&format!("cannot write {track_path}: {error}"));
                }
            }
        }

        let inputs: Vec<usize> = (0..tracks).collect();

        // Join a finished worker before replacing it, so a stream of takes does
        // not leave detached threads behind.
        if let Some(mut previous) = self.current.take() {
            previous.finish();
        }

        let take = self.next_take;
        self.next_take += 1;
        // A serve take starts as a wire: gain 1, centred, no inserts, until a
        // `param` moves it. The values here are the knobs `status` reports and
        // only this thread changes them, so the mirror is the truth.
        let track_status: Vec<TrackStatus> = paths
            .iter()
            .enumerate()
            .map(|(index, path)| TrackStatus {
                path: path.clone(),
                input: inputs[index],
                frames: 0,
                dropped: 0,
                gain: 1.0,
                pan: 0.0,
                inserts: String::new(),
            })
            .collect();
        let shared = Arc::new(Mutex::new(Status {
            take,
            state: State::Recording,
            path: paths[0].clone(),
            frames: 0,
            dropped: 0,
            start_sample: start_at,
            xruns: 0,
            tracks: track_status.clone(),
            error: String::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        // The queue exists before the worker does: the take thread builds the
        // strips (they need not be `Send`), but the socket must be able to push
        // to them as soon as `record` answers.
        let params = Arc::new(ParamQueue::new());

        let spawned = {
            let shared = Arc::clone(&shared);
            let stop = Arc::clone(&stop);
            let params = Arc::clone(&params);
            let config = self.config.clone();
            thread::Builder::new()
                .name("jawn-audio-take".to_string())
                .spawn(move || run_take(config, seconds, disks, tracks, shared, stop, params))
        };
        let handle = match spawned {
            Ok(handle) => handle,
            Err(error) => {
                // No worker, no take: do not leave WAVs nobody will finish.
                for track_path in &paths {
                    let _ = fs::remove_file(track_path);
                }
                return error_line(&format!("cannot start the take thread: {error}"));
            }
        };

        self.current = Some(Running {
            status: shared,
            stop,
            handle: Some(handle),
            params,
        });
        format!(
            "{{\"ok\":true,\"take\":{take},\"state\":\"recording\",\"start_sample\":{start_at}{}}}",
            tracks_json(&track_status)
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
struct TrackStatus {
    path: String,
    input: usize,
    frames: u64,
    dropped: u64,
    /// The strip's trim, mirrored from the last `param` this socket accepted.
    gain: f32,
    /// -1 left ..= 1 right.
    pan: f32,
    /// The chain order, e.g. `tone,reverb`; empty for a wire.
    inserts: String,
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
    /// One entry per track; track 1's also fills the top-level fields.
    tracks: Vec<TrackStatus>,
    error: String,
}

/// The `tracks` array for a take. A one-track take keeps its historical line
/// and omits the array; a two-track take carries both files so a caller can
/// find the second one without guessing the naming scheme.
fn tracks_json(tracks: &[TrackStatus]) -> String {
    if tracks.len() <= 1 {
        return String::new();
    }
    let entries: Vec<String> = tracks
        .iter()
        .map(|track| {
            format!(
                "{{\"path\":\"{}\",\"input\":{},\"frames\":{},\"dropped\":{},\"gain\":{},\"pan\":{},\"inserts\":\"{}\"}}",
                jawn_audio::loopback::json_escape(&track.path),
                track.input,
                track.frames,
                track.dropped,
                track.gain,
                track.pan,
                jawn_audio::loopback::json_escape(&track.inserts)
            )
        })
        .collect();
    format!(",\"tracks\":[{}]", entries.join(","))
}

/// The server's handle to one take's worker thread.
struct Running {
    status: Arc<Mutex<Status>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    /// The same ring the take's mixer drains. Kept so `param` can push after
    /// the worker owns the strips.
    params: Arc<ParamQueue>,
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
        // Track 1's strip fills the top-level fields, as `path` and `frames`
        // already do; every track's own values are in `tracks`.
        let first = status.tracks.first();
        format!(
            "{{\"ok\":true,\"take\":{},\"state\":\"{}\",\"path\":\"{}\",\"frames\":{},\"dropped\":{},\"start_sample\":{},\"xruns\":{}{},\"gain\":{},\"pan\":{},\"inserts\":\"{}\",\"error\":\"{}\"}}",
            status.take,
            status.state.name(),
            jawn_audio::loopback::json_escape(&status.path),
            status.frames,
            status.dropped,
            status.start_sample,
            status.xruns,
            tracks_json(&status.tracks),
            first.map(|track| track.gain).unwrap_or(1.0),
            first.map(|track| track.pan).unwrap_or(0.0),
            jawn_audio::loopback::json_escape(first.map(|track| track.inserts.as_str()).unwrap_or("")),
            jawn_audio::loopback::json_escape(&status.error)
        )
    }
}

/// What a capture produced besides its frames.
struct Captured {
    rate: u32,
    xruns: usize,
}

/// The take's worker: capture, hand every block to each track's writer, then
/// say how it ended. `stop` has already joined every writer before the status
/// is final.
fn run_take(
    config: Config,
    seconds: f64,
    mut disks: Vec<DiskWriter>,
    tracks: usize,
    status: Arc<Mutex<Status>>,
    stop: Arc<AtomicBool>,
    params: Arc<ParamQueue>,
) {
    // Build the mixer here, on the take's thread, so it is never moved between
    // threads. Its control ring is the one the socket already holds.
    let inputs: Vec<usize> = (0..tracks).collect();
    let labels: Vec<String> = (1..=tracks).map(|track| format!("ch{track}")).collect();
    let label_refs: Vec<&str> = labels.iter().map(|label| label.as_str()).collect();
    let mut mixer = Mixer::with_queue(&inputs, &label_refs, Arc::clone(&params));
    let outcome = match config.backend {
        BackendKind::Null => {
            capture_null(&config, seconds, &mut disks, &mut mixer, &status, &stop)
        }
        BackendKind::Alsa | BackendKind::PipeWire | BackendKind::Jack => {
            capture_hardware(&config, seconds, &mut disks, &mut mixer, &status, &stop)
        }
    };
    // A stop is the caller's choice, not a failure: the take ends where it was
    // asked to, with a finished header.
    let was_stopped = stop.load(Ordering::SeqCst);
    let produced = frames_so_far(&status);
    // Read every count before `finish`, which consumes each handle.
    let dropped: Vec<u64> = disks.iter().map(|disk| disk.dropped_frames()).collect();

    let mut finished = Vec::with_capacity(disks.len());
    for disk in disks {
        finished.push(disk.finish());
    }

    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.dropped = dropped.first().copied().unwrap_or(0);
    for (index, track) in current.tracks.iter_mut().enumerate() {
        track.dropped = dropped.get(index).copied().unwrap_or(0);
    }

    let (capture_rate, capture_xruns, capture_error) = match outcome {
        Ok(captured) => (Some(captured.rate), captured.xruns, None),
        Err(_) if was_stopped => (None, 0, None),
        Err(error) => (None, 0, Some(error)),
    };
    let mut failure = capture_error;
    for (index, result) in finished.into_iter().enumerate() {
        match result {
            Ok(frames) => {
                if let Some(track) = current.tracks.get_mut(index) {
                    track.frames = frames;
                }
                if failure.is_none() {
                    if let Some(rate) = capture_rate {
                        if rate != config.rate {
                            // The samples are at the granted rate; the header
                            // must say so, and only the worker knows it.
                            let path = match current.tracks.get(index) {
                                Some(track) => track.path.clone(),
                                None => continue,
                            };
                            if let Err(error) = crate::rewrite_rate(Path::new(&path), rate) {
                                failure = Some(error);
                            }
                        }
                    }
                }
            }
            Err(error) => {
                if failure.is_none() {
                    failure = Some(format!("cannot finish the take: {error}"));
                }
            }
        }
    }

    current.frames = current.tracks.first().map(|track| track.frames).unwrap_or(0);
    current.xruns = capture_xruns;
    match failure {
        None => current.state = State::Done,
        Some(error) => {
            current.state = State::Failed;
            current.error = error;
            // An empty failed take is not a take; a partial one is kept for the
            // manager to decide about.
            if produced == 0 {
                for track in &current.tracks {
                    let _ = fs::remove_file(&track.path);
                }
            }
        }
    }
}

/// Update what `status` reads while a take runs: frames captured so far and
/// each track's dropped count. The lock is uncontended and held for a handful
/// of field writes, so this never blocks the capture loop in practice.
fn note_progress(status: &Arc<Mutex<Status>>, frames: u64, disks: &[DiskWriter]) {
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.frames = frames;
    current.dropped = disks.first().map(|disk| disk.dropped_frames()).unwrap_or(0);
    for (index, track) in current.tracks.iter_mut().enumerate() {
        track.frames = frames;
        track.dropped = disks
            .get(index)
            .map(|disk| disk.dropped_frames())
            .unwrap_or(0);
    }
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
    disks: &mut [DiskWriter],
    mixer: &mut Mixer,
    status: &Arc<Mutex<Status>>,
    stop: &AtomicBool,
) -> Result<Captured, String> {
    let track_count = mixer.tracks().len();
    if disks.len() != track_count {
        return Err(format!(
            "{track_count} track(s) but {} disk writer(s)",
            disks.len()
        ));
    }
    let mut device = NullDevice::new(config.rate, config.period, track_count);
    mixer.prepare(config.rate, config.period);
    let total = take_frames(seconds, config.rate);
    let mut source = vec![0.0f32; config.period * track_count];
    let mut mono = vec![0.0f32; config.period];
    let mut stereo = vec![0.0f32; config.period * RECORD_CHANNELS];
    let mut pcm = vec![0i16; config.period * RECORD_CHANNELS];
    let mut remaining = total;
    let mut pushed = 0u64;
    while remaining > 0 {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        device
            .process(&mut source)
            .map_err(|error| format!("device: {error:?}"))?;
        let frames = remaining.min(config.period as u64) as usize;
        let samples = frames * RECORD_CHANNELS;
        for track in 0..track_count {
            for frame in 0..frames {
                mono[frame] = source[frame * track_count + track];
            }
            mixer
                .process(track, &mono[..frames], &mut stereo[..samples])
                .map_err(|error| format!("track {track}: {error}"))?;
            for (out, sample) in pcm[..samples].iter_mut().zip(&stereo[..samples]) {
                *out = to_i16(*sample);
            }
            disks[track].push(&pcm[..samples]);
        }
        pushed += frames as u64;
        note_progress(status, pushed, disks);
        remaining -= frames as u64;
    }
    Ok(Captured {
        rate: config.rate,
        xruns: 0,
    })
}

#[cfg(feature = "alsa")]
struct ServeSink<'a> {
    mixer: &'a mut Mixer,
    disks: &'a mut [DiskWriter],
    status: &'a Arc<Mutex<Status>>,
    stop: &'a AtomicBool,
    pushed: u64,
    mono: Vec<f32>,
    stereo: Vec<f32>,
    pcm: Vec<i16>,
}

#[cfg(feature = "alsa")]
impl jawn_audio::alsa_device::CaptureSink for ServeSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        self.mixer.prepare(rate, period);
        self.mono = vec![0.0; period];
        self.stereo = vec![0.0; period * RECORD_CHANNELS];
        self.pcm = vec![0i16; period * RECORD_CHANNELS];
        Ok(())
    }

    fn block(&mut self, block: &[i16]) -> Result<(), String> {
        // The sink is the only place a stop can reach a device loop that owns
        // the read: ending the sink ends the capture.
        if self.stop.load(Ordering::SeqCst) {
            return Err("stopped".to_string());
        }
        let frames = (block.len() / RECORD_CHANNELS).min(self.mono.len());
        let track_count = self.mixer.tracks().len();
        if self.disks.len() != track_count {
            return Err(format!(
                "{track_count} track(s) but {} disk writer(s)",
                self.disks.len()
            ));
        }
        let samples = frames * RECORD_CHANNELS;
        for track in 0..track_count {
            let input = self.mixer.tracks()[track].input.min(1);
            for frame in 0..frames {
                self.mono[frame] = f32::from(block[frame * RECORD_CHANNELS + input]) / 32_768.0;
            }
            self.mixer
                .process(track, &self.mono[..frames], &mut self.stereo[..samples])
                .map_err(|error| format!("track {track}: {error}"))?;
            for (out, sample) in self.pcm[..samples].iter_mut().zip(&self.stereo[..samples]) {
                *out = to_i16(*sample);
            }
            self.disks[track].push(&self.pcm[..samples]);
        }
        self.pushed += frames as u64;
        note_progress(self.status, self.pushed, self.disks);
        Ok(())
    }
}

#[cfg(feature = "alsa")]
fn capture_hardware(
    config: &Config,
    seconds: f64,
    disks: &mut [DiskWriter],
    mixer: &mut Mixer,
    status: &Arc<Mutex<Status>>,
    stop: &AtomicBool,
) -> Result<Captured, String> {
    let sink = ServeSink {
        mixer,
        disks,
        status,
        stop,
        pushed: 0,
        mono: Vec::new(),
        stereo: Vec::new(),
        pcm: Vec::new(),
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
    disks: &mut [DiskWriter],
    mixer: &mut Mixer,
    status: &Arc<Mutex<Status>>,
    stop: &AtomicBool,
) -> Result<Captured, String> {
    let _ = (config, seconds, disks, mixer, status, stop);
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
