//! The control socket: one JSON object per line, in and out.
//!
//! The Perl manager arms a take (`record`) or plays takes back (`play`),
//! watches it (`status`), moves a running strip's knobs (`param`) and ends it
//! (`stop`) over a Unix socket, so
//! the wire format here is deliberately dumb:
//! one object per line, values that are strings, numbers, booleans, null,
//! arrays, or (for a take's `tracks` plan) one object per track, and no crates
//! — the parser below is the whole of it. That keeps the engine's dependency
//! set at "the audio backend, and nothing else"
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
//!
//! # Overdub
//!
//! A take and a playback are independent: `record` may carry `monitor`, an
//! array of paths or per-file strips played to the outputs while the take
//! captures, and `play` may start while a take records. The capture thread owns
//! the capture device and its [`DiskWriter`]s; the playback thread owns a second
//! device handle and renders only to the outputs, so the monitoring bus can
//! never reach the take. The monitor starts `align_samples` before the take's
//! `start_at` (`"align_samples"`, or a measurement from `"calibrate":true`),
//! clamped at sample 0; with neither, nothing is shifted and `align_from` says
//! `none`. That is a start correction, not a drift model. One `stop` signals
//! both before joining either, and `status` reports the take's state with
//! `playing`, `monitor_frames`, the alignment and the monitor strips beside it.
//! Two takes at once, or two playbacks at once, are still refused.

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
    monitor_start, to_i16, BackendKind, Channel, Device, DiskWriter, InsertKind, Mixer,
    MonitorSpec, NullDevice, ParamName, ParamQueue, PlayTrack, Playback,
};

use crate::{alignment_json, take_frames, Alignment, MAX_CHANNELS, MAX_TRACKS, TAKE_CHANNELS};

/// How long a take runs when the command does not say.
const DEFAULT_SECONDS: f64 = 10.0;

/// The serve loop's poll interval. A command that arrives waits at most this
/// long to be read; the socket is idle almost all the time.
const POLL: Duration = Duration::from_millis(2);

/// A command is one object; this bounds a client that never sends a newline.
const MAX_LINE: usize = 64 * 1024;

/// A value may hold an object (a take's `tracks` plan), but a plan is one
/// level deep: this bounds a caller that nests one object inside another.
const MAX_VALUE_DEPTH: usize = 3;

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
    /// The capture channel count a take asks the device for.
    pub channels: usize,
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
        playback: None,
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
    /// report the final state until the next `record` or `play`.
    current: Option<Running>,
    /// The most recent playback, kept after it ends for the same reason. A
    /// take and a playback may run together (overdub), so both fields can be
    /// live; only one take and one playback can, at most.
    playback: Option<PlaySession>,
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
                        // Finish both workers before the process goes, so the
                        // WAV the caller armed is closed and the monitor loop
                        // has stopped rather than being killed mid-block. A
                        // quit is still answered exactly as promised.
                        if let Some(running) = &self.current {
                            running.stop.store(true, Ordering::SeqCst);
                        }
                        if let Some(session) = &self.playback {
                            session.stop.store(true, Ordering::SeqCst);
                        }
                        if let Some(running) = &mut self.current {
                            running.finish();
                        }
                        if let Some(session) = &mut self.playback {
                            session.finish();
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
            "play" => Action::Reply(self.play(&object)),
            "param" => Action::Reply(self.param(&object)),
            "status" => Action::Reply(self.status_line()),
            "stop" => Action::Reply(self.stop_line()),
            "quit" => Action::Quit("{\"ok\":true}".to_string()),
            _ => Action::Reply(error_line("unknown command")),
        }
    }

    /// `{"cmd":"param","track":0,"name":"gain","value":0.5}`: move one
    /// knob of a running take's strip, or of a monitor strip when
    /// `"target":"monitor"` is given.
    ///
    /// The command moves the strip at its next block, so the answer means
    /// "queued", not "heard". The effect clamps the value (see
    /// [`Channel::set`]); the socket rejects only what is not a parameter at
    /// all. The knob mirror in `status` is updated here, because the strip
    /// itself lives on the worker thread and nothing else writes these values.
    fn param(&mut self, object: &Object) -> String {
        match get(object, "target") {
            None | Some(Value::Null) => self.param_take(object),
            Some(Value::Str(target)) if target == "take" => self.param_take(object),
            Some(Value::Str(target)) if target == "monitor" => self.param_monitor(object),
            _ => error_line("\"target\" must be \"take\" or \"monitor\""),
        }
    }

    fn param_take(&mut self, object: &Object) -> String {
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

    /// The same knobs, addressed to a monitor strip: `"target":"monitor"`.
    /// The monitor's own queue is what its playback drains at the top of a
    /// block, so a gain change never touches the take's strip.
    fn param_monitor(&mut self, object: &Object) -> String {
        let track = match get(object, "track") {
            Some(Value::Num(value))
                if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 => *value as usize,
            _ => return error_line("param needs \"track\": a 0-based monitor file number"),
        };
        let name = match get(object, "name") {
            Some(Value::Str(name)) => name.as_str(),
            _ => return error_line("param needs \"name\": a parameter name"),
        };
        let value = match get(object, "value") {
            Some(Value::Num(value)) if value.is_finite() => *value as f32,
            _ => return error_line("\"value\" must be a finite number"),
        };
        let parameter = match ParamName::parse(name) {
            Some(parameter) => parameter,
            None => return error_line(&format!("no such parameter: {name}")),
        };
        let session = match self.playback.as_mut() {
            Some(session) if !session.strips.is_empty() && session.is_playing() => session,
            _ => return error_line("no monitor is running"),
        };
        let count = session.strips.len();
        if track >= count {
            return error_line(&format!(
                "no monitor file {track} (the monitor has {count})"
            ));
        }
        if let Some(insert) = parameter.insert() {
            let present = session.strips[track]
                .inserts
                .iter()
                .any(|kind| kind.name() == insert);
            if !present {
                return error_line(&format!("no such parameter: {name}"));
            }
        }
        let queue = match &session.params {
            Some(queue) => Arc::clone(queue),
            None => return error_line("no monitor is running"),
        };
        if !queue.push(track, parameter, value) {
            return error_line("the parameter queue is full; try again next block");
        }
        match parameter {
            ParamName::Gain => session.strips[track].gain = Channel::clamp_gain(value),
            ParamName::Pan => session.strips[track].pan = Channel::clamp_pan(value),
            _ => {}
        }
        format!(
            "{{\"ok\":true,\"target\":\"monitor\",\"track\":{},\"name\":\"{}\"}}",
            track,
            jawn_audio::loopback::json_escape(name)
        )
    }

    fn record(&mut self, object: &Object) -> String {
        // The monitoring bus, if this take is an overdub. Parsed first so a
        // malformed list is a refusal whether or not a take is already running.
        let monitor = match parse_monitor(get(object, "monitor")) {
            Ok(monitor) => monitor,
            Err(error) => return error_line(&error),
        };
        // One playback at a time: a take over the monitor it names is the
        // point, but a second monitor cannot join a playback already running.
        if !monitor.is_empty() {
            if let Some(session) = &self.playback {
                if session.is_playing() {
                    return error_line("a playback is already running");
                }
            }
        }
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
        let align_samples = match get(object, "align_samples") {
            None | Some(Value::Null) => None,
            Some(Value::Num(value))
                if value.is_finite()
                    && *value >= 0.0
                    && value.fract() == 0.0
                    && *value <= u64::MAX as f64 =>
            {
                Some(*value as u64)
            }
            _ => return error_line("\"align_samples\" must be a whole, non-negative sample count"),
        };
        let calibrate = match get(object, "calibrate") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(value)) => *value,
            _ => return error_line("\"calibrate\" must be true or false"),
        };
        // Two shapes for `tracks`: the historical count (`"tracks":2`, one
        // wire per input) and the plan the page arms, one object per track.
        let plans = match get(object, "tracks") {
            None | Some(Value::Null) => vec![TrackPlan::wire(0)],
            Some(Value::Num(value))
                if value.is_finite()
                    && *value >= 1.0
                    && *value <= MAX_TRACKS as f64
                    && value.fract() == 0.0 =>
            {
                let tracks = *value as usize;
                let inputs = match parse_inputs(object, tracks) {
                    Ok(inputs) => inputs,
                    Err(error) => return error_line(&error),
                };
                inputs
                    .into_iter()
                    .map(TrackPlan::wire)
                    .collect::<Vec<TrackPlan>>()
            }
            Some(Value::Arr(values)) => {
                // The plan names each track's input, so the parallel `inputs`
                // array would be a second, possibly contradictory answer.
                if matches!(get(object, "inputs"), Some(value) if !matches!(value, Value::Null)) {
                    return error_line(
                        "\"inputs\" cannot be combined with a per-track \"tracks\" plan: give each track its input",
                    );
                }
                match track_plans(values) {
                    Ok(plans) => plans,
                    Err(error) => return error_line(&error),
                }
            }
            _ => {
                return error_line(&format!(
                    "\"tracks\" must be a whole number of tracks, 1..={MAX_TRACKS}, or an array of track plans"
                ))
            }
        };
        let tracks = plans.len();
        if tracks > self.config.channels {
            return error_line(&format!(
                "a {tracks}-track take needs at least {tracks} input channels, but the engine has {} channel(s): restart it with a larger --channels",
                self.config.channels
            ));
        }
        for (index, plan) in plans.iter().enumerate() {
            if plan.input >= self.config.channels {
                return error_line(&format!(
                    "track {} records input {}, but the engine has only {} channel(s): pass a smaller input or restart it with a larger --channels",
                    index + 1,
                    plan.input,
                    self.config.channels
                ));
            }
        }
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
        let channels = match crate::probe_capture(
            self.config.backend,
            &self.config.device,
            self.config.rate,
            self.config.period,
            self.config.buffer,
            self.config.channels,
        ) {
            Ok(granted) => granted,
            Err(error) => return error_line(&error),
        };

        // The monitor is decoded here, before any WAV exists, so a missing
        // file is a refusal rather than a take that records under a silence
        // the person thought was their earlier take. The strips are built on
        // the playback thread, because an insert is not `Send`.
        let mut monitor_tracks: Vec<PlayTrack> = Vec::with_capacity(monitor.len());
        for spec in &monitor {
            match PlayTrack::from_wav(
                spec.path.clone(),
                spec.gain,
                spec.pan,
                spec.inserts.clone(),
            ) {
                Ok(track) => monitor_tracks.push(track),
                Err(error) => return error_line(&error),
            }
        }
        if !monitor_tracks.is_empty() {
            if let Err(error) = crate::play_support(self.config.backend) {
                return error_line(&error);
            }
            match jawn_audio::playback::check_tracks(&monitor_tracks) {
                Ok((rate, _)) if rate == self.config.rate => {}
                Ok((rate, _)) => {
                    return error_line(&format!(
                        "the monitor is {rate} Hz but the take records at {} Hz; the monitor must share the take's rate or it would play at the wrong pitch",
                        self.config.rate
                    ))
                }
                Err(error) => return error_line(&error),
            }
            match crate::probe_playback(
                self.config.backend,
                &self.config.device,
                self.config.rate,
                self.config.period,
                self.config.buffer,
            ) {
                Ok(granted) if granted == self.config.rate => {}
                Ok(granted) => {
                    return error_line(&format!(
                        "the device granted {granted} Hz for the monitor, but the take records at {} Hz",
                        self.config.rate
                    ))
                }
                Err(error) => return error_line(&error),
            }
        }

        // The capture offset is resolved before any file exists. An explicit
        // `align_samples` wins, `calibrate` runs the patch-cable measurement
        // once, and neither means no shift. This corrects the start; drift
        // over a long take is still unmeasured.
        let alignment = if monitor_tracks.is_empty() {
            match align_samples {
                Some(samples) => Alignment::given(samples),
                None => Alignment::none(),
            }
        } else {
            crate::resolve_alignment(
                self.config.backend,
                &self.config.device,
                self.config.rate,
                self.config.period,
                self.config.buffer,
                align_samples,
                calibrate,
            )
        };

        // One WAV per track: a one-track take keeps `out` exactly; more tracks
        // split the stem into `-ch1`/`-ch2`/... All files share one
        // start_sample, because one take is one position on the transport.
        let paths = match crate::take_paths(&path, tracks) {
            Ok(paths) => paths,
            Err(error) => return error_line(&error),
        };
        let frames = take_frames(seconds, self.config.rate);
        let queue = crate::queue_blocks(
            self.config.backend,
            frames,
            self.config.period,
            TAKE_CHANNELS,
        );
        let mut disks: Vec<DiskWriter> = Vec::with_capacity(paths.len());
        for (index, track_path) in paths.iter().enumerate() {
            match DiskWriter::spawn(
                Path::new(track_path),
                self.config.rate,
                TAKE_CHANNELS as u16,
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

        // Join a finished worker before replacing it, so a stream of takes does
        // not leave detached threads behind. A take that is still recording was
        // refused above.
        if let Some(mut previous) = self.current.take() {
            previous.finish();
        }
        // A playback that has already ended is only a status line now; a
        // running one keeps playing, because a take over a monitor is the
        // point. (A monitor requested over a running playback was refused.)
        if self.playback.as_ref().map(PlaySession::is_playing) != Some(true) {
            if let Some(mut previous) = self.playback.take() {
                previous.finish();
            }
        }

        let take = self.next_take;
        self.next_take += 1;
        // The plan is what the page asked for: gain and pan are already
        // clamped, the inserts already named. `status` mirrors these values
        // until a `param` moves one, because the strips themselves live on the
        // take thread and nothing else writes them.
        let track_status: Vec<TrackStatus> = paths
            .iter()
            .zip(plans.iter())
            .map(|(path, plan)| TrackStatus {
                path: path.clone(),
                input: plan.input,
                frames: 0,
                dropped: 0,
                gain: plan.gain,
                pan: plan.pan,
                inserts: plan.insert_list(),
            })
            .collect();
        let shared = Arc::new(Mutex::new(Status {
            take,
            state: State::Recording,
            path: paths[0].clone(),
            frames: 0,
            dropped: 0,
            channels,
            start_sample: start_at,
            xruns: 0,
            align_samples: alignment.samples,
            align_from: alignment.from,
            tracks: track_status.clone(),
            error: String::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        // The queue exists before the worker does: the take thread builds the
        // strips (they need not be `Send`), but the socket must be able to push
        // to them as soon as `record` answers.
        let params = Arc::new(ParamQueue::new());

        // The monitoring bus: its own thread and its own device handle, fed by
        // `Playback` and never by the capture loop. Started before the take so
        // a player that cannot start is still a refusal rather than a take that
        // records without the monitor the caller asked for.
        let mut monitor_session = if monitor_tracks.is_empty() {
            None
        } else {
            let status = Arc::new(Mutex::new(PlayStatus {
                state: State::Playing,
                files: monitor_tracks.len(),
                frames: 0,
                error: String::new(),
            }));
            let monitor_stop = Arc::new(AtomicBool::new(false));
            let monitor_params = Arc::new(ParamQueue::new());
            let monitor_at = monitor_start(start_at, alignment.samples);
            let strips = monitor.clone();
            let spawned = {
                let status = Arc::clone(&status);
                let stop = Arc::clone(&monitor_stop);
                let params = Arc::clone(&monitor_params);
                let config = self.config.clone();
                thread::Builder::new()
                    .name("jawn-audio-monitor".to_string())
                    .spawn(move || {
                        run_playback(
                            config,
                            monitor_tracks,
                            monitor_at,
                            status,
                            stop,
                            Some(params),
                        )
                    })
            };
            match spawned {
                Ok(handle) => Some(PlaySession {
                    status,
                    stop: monitor_stop,
                    handle: Some(handle),
                    strips,
                    params: Some(monitor_params),
                    align: Some(alignment),
                }),
                Err(error) => {
                    for disk in disks {
                        let _ = disk.finish();
                    }
                    for track_path in &paths {
                        let _ = fs::remove_file(track_path);
                    }
                    return error_line(&format!(
                        "cannot start the monitor thread: {error}"
                    ));
                }
            }
        };

        let spawned = {
            let shared = Arc::clone(&shared);
            let stop = Arc::clone(&stop);
            let params = Arc::clone(&params);
            let config = self.config.clone();
            let plans = plans.clone();
            thread::Builder::new()
                .name("jawn-audio-take".to_string())
                .spawn(move || run_take(config, seconds, disks, plans, shared, stop, params))
        };
        let handle = match spawned {
            Ok(handle) => handle,
            Err(error) => {
                // No worker, no take: stop the monitor and do not leave WAVs
                // nobody will finish.
                if let Some(mut session) = monitor_session.take() {
                    session.finish();
                }
                for track_path in &paths {
                    let _ = fs::remove_file(track_path);
                }
                return error_line(&format!("cannot start the take thread: {error}"));
            }
        };

        // A take with no monitor leaves a running playback alone; a monitor
        // replaces whatever finished session was kept as a status line.
        if let Some(session) = monitor_session {
            self.playback = Some(session);
        }
        self.current = Some(Running {
            status: shared,
            stop,
            handle: Some(handle),
            params,
        });
        let monitor_part = if monitor.is_empty() {
            String::new()
        } else {
            format!(
                ",\"playing\":{},\"monitor_frames\":0{}",
                monitor.len(),
                jawn_audio::playback::monitor_json(&monitor)
            )
        };
        format!(
            "{{\"ok\":true,\"take\":{take},\"state\":\"recording\",\"channels\":{channels},\"start_sample\":{start_at}{}{monitor_part}{}}}",
            tracks_json(&track_status),
            alignment_json(alignment)
        )
    }

    /// `{"cmd":"play","files":["/abs/a.wav"],"start_at":0}`: play takes back
    /// through their strips.
    ///
    /// Every file is decoded on this thread before the reply, so a missing or
    /// unplayable file is a refusal rather than a `playing` that turns into
    /// `failed` a moment later. The strips are the defaults the wire has no
    /// knobs for yet: unity trim, centre pan, no inserts.
    fn play(&mut self, object: &Object) -> String {
        let files = match get(object, "files") {
            Some(Value::Arr(values)) if !values.is_empty() => {
                let mut paths = Vec::with_capacity(values.len());
                for value in values {
                    match value {
                        Value::Str(path) if Path::new(path).is_absolute() => {
                            paths.push(path.clone())
                        }
                        Value::Str(_) => {
                            return error_line(
                                "play needs every \"files\" entry to be an absolute path",
                            )
                        }
                        _ => return error_line("\"files\" must be an array of WAV paths"),
                    }
                }
                paths
            }
            Some(Value::Arr(_)) => {
                return error_line("play needs at least one file in \"files\"")
            }
            _ => {
                return error_line("play needs \"files\": an array of absolute WAV paths")
            }
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

        // Playback may join a take that is recording: that is the overdub the
        // monitor bus and the Studio transport ask for. Only a second playback
        // is refused.
        if let Some(session) = &self.playback {
            if session.is_playing() {
                return error_line("a playback is already running");
            }
        }
        if let Err(error) = crate::play_support(self.config.backend) {
            return error_line(&error);
        }

        let mut tracks = Vec::with_capacity(files.len());
        for path in &files {
            match PlayTrack::from_wav(path.clone(), 1.0, 0.0, Vec::new()) {
                Ok(track) => tracks.push(track),
                Err(error) => return error_line(&error),
            }
        }
        // The strips themselves are built on the worker, because an insert is
        // not `Send`; this check is everything the reply needs from them.
        let (rate, longest) = match jawn_audio::playback::check_tracks(&tracks) {
            Ok(shape) => shape,
            Err(error) => return error_line(&error),
        };
        match crate::probe_playback(
            self.config.backend,
            &self.config.device,
            rate,
            self.config.period,
            self.config.buffer,
        ) {
            Ok(granted) if granted != rate => {
                return error_line(&format!(
                    "the device granted {granted} Hz, but the files are {rate} Hz; they would play at the wrong pitch"
                ))
            }
            Ok(_) => {}
            Err(error) => return error_line(&error),
        }
        let total = longest.saturating_sub(start_at);
        if total == 0 {
            // Nothing to render is not a playback: answer with the final state
            // instead of starting a worker that is already finished.
            if let Some(mut previous) = self.playback.take() {
                previous.finish();
            }
            return format!(
                "{{\"ok\":true,\"state\":\"done\",\"files\":{},\"frames\":0}}",
                files.len()
            );
        }

        // Join whatever ended earlier: a finished take or an earlier playback
        // is a status line, not a thread to leave detached. A take that is
        // recording is left alone and keeps capturing beside this playback.
        if self.current.as_ref().map(Running::is_recording) != Some(true) {
            if let Some(mut previous) = self.current.take() {
                previous.finish();
            }
        }
        if let Some(mut previous) = self.playback.take() {
            previous.finish();
        }

        let status = Arc::new(Mutex::new(PlayStatus {
            state: State::Playing,
            files: files.len(),
            frames: 0,
            error: String::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let spawned = {
            let status = Arc::clone(&status);
            let stop = Arc::clone(&stop);
            let config = self.config.clone();
            thread::Builder::new()
                .name("jawn-audio-play".to_string())
                .spawn(move || run_playback(config, tracks, start_at, status, stop, None))
        };
        let handle = match spawned {
            Ok(handle) => handle,
            Err(error) => return error_line(&format!("cannot start the playback thread: {error}")),
        };
        self.playback = Some(PlaySession {
            status,
            stop,
            handle: Some(handle),
            strips: Vec::new(),
            params: None,
            align: None,
        });
        format!(
            "{{\"ok\":true,\"state\":\"playing\",\"files\":{}}}",
            files.len()
        )
    }

    fn status_line(&self) -> String {
        // A take that is recording is the transport, so its line leads and the
        // monitor reports beside it. A finished take stays a status line and an
        // independent playback keeps its historical shape.
        let line = if let Some(running) = self
            .current
            .as_ref()
            .filter(|running| running.is_recording())
        {
            running.line_with_play(self.playback.as_ref())
        } else if let Some(session) = &self.playback {
            session.line()
        } else {
            match &self.current {
                Some(running) => running.line(),
                None => idle_line(),
            }
        };
        // The configuration describes the process, not the take, so every
        // state carries it: a supervisor compares these with its own flags to
        // tell whether the engine it adopted is the one it asked for.
        add_config(line, &self.config)
    }

    fn stop_line(&mut self) -> String {
        let was_recording = self
            .current
            .as_ref()
            .map(Running::is_recording)
            .unwrap_or(false);
        // Signal every worker before joining any: a join waits for a loop that
        // has already been told to stop, so neither worker can hold the other
        // past its block.
        if let Some(running) = &self.current {
            running.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &self.playback {
            session.stop.store(true, Ordering::SeqCst);
        }
        // Joining before answering makes `frames` and `monitor_frames` what was
        // actually produced, not a guess about a running loop.
        if let Some(running) = &mut self.current {
            running.finish();
        }
        if let Some(session) = &mut self.playback {
            session.finish();
        }
        if was_recording {
            if let Some(running) = &self.current {
                return running.line_with_play(self.playback.as_ref());
            }
        }
        if let Some(session) = &self.playback {
            return session.line();
        }
        match &self.current {
            Some(running) => running.line(),
            None => idle_line(),
        }
    }
}

fn idle_line() -> String {
	"{\"ok\":true,\"take\":0,\"state\":\"idle\"}".to_string()
}

/// Append the configuration the engine actually serves with to a status
/// object. The existing keys keep their order and meaning; these six are added
/// at the end, so every state answers the same question. A recording line
/// already has a `channels` key for the take's granted capture channels; the
/// configured capture width is `device_channels`, not `channels`: a recording
/// line already carries `channels` for the take's granted width, and two keys of
/// the same name meaning different things is how a page reads the wrong one.
fn add_config(line: String, config: &Config) -> String {
    let head = match line.strip_suffix('}') {
        Some(head) => head,
        None => return line,
    };
    format!(
        "{head},\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"period\":{},\"buffer\":{},\"device_channels\":{}}}",
        config.backend.name(),
        jawn_audio::loopback::json_escape(&config.device),
        config.rate,
        config.period,
        config.buffer,
        config.channels
    )
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
    Playing,
    Done,
    Failed,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Recording => "recording",
            State::Playing => "playing",
            State::Done => "done",
            State::Failed => "failed",
        }
    }
}

/// One track the socket arms: the input it records, the strip's knobs, and its
/// inserts in chain order.
#[derive(Clone)]
struct TrackPlan {
    input: usize,
    /// Clamped to [`Channel::MAX_GAIN`] when the plan is read.
    gain: f32,
    /// -1 left ..= 1 right.
    pan: f32,
    inserts: Vec<InsertKind>,
}

impl TrackPlan {
    /// A wire: gain 1, centred, no inserts. The historical `"tracks":N` shape
    /// arms one of these per input.
    fn wire(input: usize) -> Self {
        TrackPlan {
            input,
            gain: 1.0,
            pan: 0.0,
            inserts: Vec::new(),
        }
    }

    /// The chain order `status` reports, e.g. `tone,delay`.
    fn insert_list(&self) -> String {
        self.inserts
            .iter()
            .map(|kind| kind.name())
            .collect::<Vec<&str>>()
            .join(",")
    }
}

/// The historical `"inputs":[0,1]` field: one device channel per track, in
/// track order. Absent means `0..tracks`.
fn parse_inputs(object: &Object, tracks: usize) -> Result<Vec<usize>, String> {
    let inputs = match get(object, "inputs") {
        None | Some(Value::Null) => (0..tracks).collect::<Vec<usize>>(),
        Some(Value::Arr(values)) => {
            let mut inputs = Vec::with_capacity(values.len());
            for value in values {
                match value {
                    Value::Num(input)
                        if input.is_finite()
                            && *input >= 0.0
                            && *input <= MAX_CHANNELS as f64
                            && input.fract() == 0.0 =>
                    {
                        inputs.push(*input as usize)
                    }
                    _ => {
                        return Err(
                            "\"inputs\" must be whole, non-negative channel numbers".to_string(),
                        )
                    }
                }
            }
            inputs
        }
        _ => return Err("\"inputs\" must be an array of channel numbers".to_string()),
    };
    if inputs.len() != tracks {
        return Err(format!(
            "\"inputs\" names {} channel(s) but \"tracks\" is {tracks}: a take has one input per track",
            inputs.len()
        ));
    }
    Ok(inputs)
}

/// The `monitor` field: either the historical array of absolute paths, or an
/// array of objects with their own strip (`file`, `gain`, `pan`, `inserts`).
/// Both shapes may be mixed in one array; the position is the 1-based file
/// number `param` addresses.
fn parse_monitor(value: Option<&Value>) -> Result<Vec<MonitorSpec>, String> {
    match value {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Arr(values)) if values.is_empty() => {
            Err("record \"monitor\" needs at least one absolute WAV path".to_string())
        }
        Some(Value::Arr(values)) => values.iter().map(monitor_spec).collect(),
        _ => Err(
            "\"monitor\" must be an array of WAV paths or monitor objects".to_string(),
        ),
    }
}

/// One monitor entry: a bare path, or an object whose missing knobs default to
/// a wire. The file must be absolute, exactly as a bare path must be.
fn monitor_spec(value: &Value) -> Result<MonitorSpec, String> {
    match value {
        Value::Str(path) => {
            if !Path::new(path).is_absolute() {
                return Err(
                    "record needs every \"monitor\" entry to be an absolute path".to_string(),
                );
            }
            Ok(MonitorSpec::wire(path.clone()))
        }
        Value::Obj(fields) => {
            let path = match get(fields, "file") {
                Some(Value::Str(path)) => path.clone(),
                _ => {
                    return Err(
                        "a monitor object needs \"file\": an absolute WAV path".to_string()
                    )
                }
            };
            if !Path::new(&path).is_absolute() {
                return Err(
                    "record needs every \"monitor\" entry to be an absolute path".to_string(),
                );
            }
            let gain = match get(fields, "gain") {
                None | Some(Value::Null) => 1.0,
                Some(Value::Num(value)) if value.is_finite() => {
                    Channel::clamp_gain(*value as f32)
                }
                _ => return Err("a monitor \"gain\" must be a finite number".to_string()),
            };
            let pan = match get(fields, "pan") {
                None | Some(Value::Null) => 0.0,
                Some(Value::Num(value)) if value.is_finite() => {
                    Channel::clamp_pan(*value as f32)
                }
                _ => return Err("a monitor \"pan\" must be a finite number".to_string()),
            };
            let inserts = match get(fields, "inserts") {
                None | Some(Value::Null) => Vec::new(),
                Some(Value::Arr(names)) => {
                    let mut inserts = Vec::with_capacity(names.len());
                    for name in names {
                        let word = match name {
                            Value::Str(word) => word.as_str(),
                            _ => {
                                return Err(
                                    "a monitor \"inserts\" must hold insert names".to_string()
                                )
                            }
                        };
                        let kind = InsertKind::parse(word)
                            .ok_or_else(|| format!("no such insert: {word}"))?;
                        inserts.push(kind);
                    }
                    inserts
                }
                _ => {
                    return Err(
                        "a monitor \"inserts\" must be an array of insert names".to_string()
                    )
                }
            };
            Ok(MonitorSpec {
                path,
                gain,
                pan,
                inserts,
            })
        }
        _ => Err("\"monitor\" must hold WAV paths or monitor objects".to_string()),
    }
}

/// The array form: one object per track. Every insert is parsed here, before
/// any file is created, and a name the engine does not have is refused by
/// name.
fn track_plans(values: &[Value]) -> Result<Vec<TrackPlan>, String> {
    if values.is_empty() {
        return Err("\"tracks\" is empty: a take needs at least one track".to_string());
    }
    if values.len() > MAX_TRACKS {
        return Err(format!(
            "\"tracks\" has {} tracks, but the engine takes at most {MAX_TRACKS}",
            values.len()
        ));
    }
    let mut plans = Vec::with_capacity(values.len());
    for (index, value) in values.iter().enumerate() {
        let fields = match value {
            Value::Obj(fields) => fields,
            _ => {
                return Err(format!(
                    "track {} must be an object with input, gain, pan and inserts",
                    index + 1
                ))
            }
        };
        plans.push(track_plan(index, fields)?);
    }
    Ok(plans)
}

/// One object from the `tracks` plan. A missing field takes the CLI's default;
/// gain and pan are clamped exactly as the CLI clamps them.
fn track_plan(index: usize, fields: &Object) -> Result<TrackPlan, String> {
    let input = match get(fields, "input") {
        None | Some(Value::Null) => index,
        Some(Value::Num(value))
            if value.is_finite()
                && *value >= 0.0
                && *value <= MAX_CHANNELS as f64
                && value.fract() == 0.0 =>
        {
            *value as usize
        }
        _ => {
            return Err(format!(
                "track {} \"input\" must be a whole, non-negative channel number",
                index + 1
            ))
        }
    };
    let gain = match get(fields, "gain") {
        None | Some(Value::Null) => 1.0,
        Some(Value::Num(value)) if value.is_finite() => Channel::clamp_gain(*value as f32),
        _ => {
            return Err(format!(
                "track {} \"gain\" must be a finite number",
                index + 1
            ))
        }
    };
    let pan = match get(fields, "pan") {
        None | Some(Value::Null) => 0.0,
        Some(Value::Num(value)) if value.is_finite() => Channel::clamp_pan(*value as f32),
        _ => {
            return Err(format!(
                "track {} \"pan\" must be a finite number",
                index + 1
            ))
        }
    };
    let inserts = match get(fields, "inserts") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Arr(names)) => {
            let mut inserts = Vec::with_capacity(names.len());
            for name in names {
                let word = match name {
                    Value::Str(word) => word.as_str(),
                    _ => {
                        return Err(format!(
                            "track {} \"inserts\" must hold insert names",
                            index + 1
                        ))
                    }
                };
                let kind = InsertKind::parse(word)
                    .ok_or_else(|| format!("no such insert: {word}"))?;
                inserts.push(kind);
            }
            inserts
        }
        _ => {
            return Err(format!(
                "track {} \"inserts\" must be an array of insert names",
                index + 1
            ))
        }
    };
    Ok(TrackPlan {
        input,
        gain,
        pan,
        inserts,
    })
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
    /// The capture channel count the engine asked the device for.
    channels: usize,
    start_sample: u64,
    xruns: usize,
    /// The capture offset applied to this take's monitor, and its source.
    align_samples: u64,
    align_from: &'static str,
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
        self.line_with_play(None)
    }

    /// The take's line with the monitoring role beside it. `playing` is how many
    /// files the monitor holds (not whether it is still running) and
    /// `monitor_frames` is what it rendered, so a finished monitor is still
    /// visible while its take remains the state being reported.
    fn line_with_play(&self, play: Option<&PlaySession>) -> String {
        let status = self.snapshot();
        // Track 1's strip fills the top-level fields, as `path` and `frames`
        // already do; every track's own values are in `tracks`.
        let first = status.tracks.first();
        let monitor = match play {
            Some(session) => {
                let played = session.snapshot();
                format!(
                    ",\"playing\":{},\"monitor_frames\":{}{}",
                    played.files,
                    played.frames,
                    jawn_audio::playback::monitor_json(&session.strips)
                )
            }
            None => String::new(),
        };
        let alignment = alignment_json(Alignment {
            samples: status.align_samples,
            from: status.align_from,
        });
        format!(
            "{{\"ok\":true,\"take\":{},\"state\":\"{}\",\"path\":\"{}\",\"frames\":{},\"dropped\":{},\"channels\":{},\"start_sample\":{},\"xruns\":{}{}{}{},\"gain\":{},\"pan\":{},\"inserts\":\"{}\",\"error\":\"{}\"}}",
            status.take,
            status.state.name(),
            jawn_audio::loopback::json_escape(&status.path),
            status.frames,
            status.dropped,
            status.channels,
            status.start_sample,
            status.xruns,
            tracks_json(&status.tracks),
            monitor,
            alignment,
            first.map(|track| track.gain).unwrap_or(1.0),
            first.map(|track| track.pan).unwrap_or(0.0),
            jawn_audio::loopback::json_escape(first.map(|track| track.inserts.as_str()).unwrap_or("")),
            jawn_audio::loopback::json_escape(&status.error)
        )
    }
}

/// What `status` reads for a playback: its state and the frames rendered.
#[derive(Clone)]
struct PlayStatus {
    state: State,
    files: usize,
    frames: u64,
    error: String,
}

/// The server's handle to one playback's worker thread.
struct PlaySession {
    status: Arc<Mutex<PlayStatus>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    /// The monitor's strips, empty for a plain `play`. `status` reports them
    /// and `param` addresses them.
    strips: Vec<MonitorSpec>,
    /// The control ring for those strips; `None` for a plain playback.
    params: Option<Arc<ParamQueue>>,
    /// The take's alignment, so an overdub's status keeps reporting where its
    /// monitor was placed after the take ends. `None` for a plain playback.
    align: Option<Alignment>,
}

impl PlaySession {
    fn snapshot(&self) -> PlayStatus {
        self.status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn is_playing(&self) -> bool {
        self.snapshot().state == State::Playing
    }

    /// Signal the worker and wait for it. When this returns `frames` is the
    /// number of frames the loop actually rendered.
    fn finish(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let joined = match self.handle.take() {
            Some(handle) => handle.join(),
            None => Ok(()),
        };
        if joined.is_err() {
            let mut status = self
                .status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if status.state == State::Playing {
                status.state = State::Failed;
                status.error = "the playback thread panicked".to_string();
            }
        }
    }

    fn line(&self) -> String {
        let status = self.snapshot();
        let monitor = jawn_audio::playback::monitor_json(&self.strips);
        let align = self.align.map(alignment_json).unwrap_or_default();
        if status.state == State::Failed {
            format!(
                "{{\"ok\":false,\"state\":\"failed\",\"files\":{},\"frames\":{}{monitor}{align},\"error\":\"{}\"}}",
                status.files,
                status.frames,
                jawn_audio::loopback::json_escape(&status.error)
            )
        } else {
            format!(
                "{{\"ok\":true,\"state\":\"{}\",\"files\":{},\"frames\":{}{monitor}{align}}}",
                status.state.name(),
                status.files,
                status.frames
            )
        }
    }
}

/// Update what `status` reads while a playback runs.
fn note_play_progress(status: &Arc<Mutex<PlayStatus>>, frames: u64) {
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.frames = frames;
}

/// The playback's worker: render every frame, then say how it ended. A stop is
/// the caller's choice, not a failure, exactly as it is for a take.
fn run_playback(
    config: Config,
    tracks: Vec<PlayTrack>,
    start_at: u64,
    status: Arc<Mutex<PlayStatus>>,
    stop: Arc<AtomicBool>,
    params: Option<Arc<ParamQueue>>,
) {
    // Build the strips here, on the playback thread, so a chain never moves
    // between threads. The control thread already checked the shape. A
    // monitor's control ring is the one `param` pushes to; a plain playback
    // has no live knobs yet.
    let built = match params {
        Some(params) => Playback::with_queue(tracks, start_at, params),
        None => Playback::new(tracks, start_at),
    };
    let mut playback = match built {
        Ok(playback) => playback,
        Err(error) => {
            let mut current = status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            current.state = State::Failed;
            current.error = error;
            return;
        }
    };
    let outcome = match config.backend {
        BackendKind::Null => play_null_stream(config.period, &mut playback, &status, &stop),
        BackendKind::Alsa | BackendKind::PipeWire => {
            play_hardware(&config, &mut playback, &status, &stop)
        }
        // `play` already refused a backend that cannot play; name it if a
        // future caller reaches the worker another way.
        BackendKind::Jack => Err(crate::play_support_message()),
    };
    let was_stopped = stop.load(Ordering::SeqCst);
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match outcome {
        Ok(frames) => {
            current.frames = frames;
            if current.state == State::Playing {
                current.state = State::Done;
            }
        }
        Err(_) if was_stopped => current.state = State::Done,
        Err(error) => {
            current.state = State::Failed;
            current.error = error;
        }
    }
}

/// The null playback: no card to pace it, so every block is rendered as fast as
/// the CPU will and `status` is updated once per block.
fn play_null_stream(
    period: usize,
    playback: &mut Playback,
    status: &Arc<Mutex<PlayStatus>>,
    stop: &AtomicBool,
) -> Result<u64, String> {
    let rate = playback.rate();
    playback.prepare(rate, period)?;
    let mut out = vec![0.0f32; period * 2];
    while playback.remaining() > 0 {
        if stop.load(Ordering::SeqCst) {
            break;
        }
        let frames = playback.remaining().min(period as u64) as usize;
        playback.render(&mut out[..frames * 2])?;
        note_play_progress(status, playback.position());
        // Yielding does not pace the audio; it lets a client polling `status`
        // run between blocks, which a tight loop would starve.
        std::thread::yield_now();
    }
    Ok(playback.position())
}

#[cfg(feature = "alsa")]
struct PlaySink<'a> {
    playback: &'a mut Playback,
    status: &'a Arc<Mutex<PlayStatus>>,
    stop: &'a AtomicBool,
}

#[cfg(feature = "alsa")]
impl jawn_audio::playback::RenderSource for PlaySink<'_> {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        self.playback.prepare(rate, period)
    }

    fn block(&mut self, out: &mut [f32]) -> Result<(), String> {
        // The sink is the only place a stop can reach the device loop.
        if self.stop.load(Ordering::SeqCst) {
            return Err("stopped".to_string());
        }
        self.playback.render(out)?;
        note_play_progress(self.status, self.playback.position());
        Ok(())
    }
}

#[cfg(feature = "alsa")]
fn play_hardware(
    config: &Config,
    playback: &mut Playback,
    status: &Arc<Mutex<PlayStatus>>,
    stop: &AtomicBool,
) -> Result<u64, String> {
    let rate = playback.rate();
    let total = playback.total_frames();
    let sink = PlaySink {
        playback,
        status,
        stop,
    };
    let report = jawn_audio::alsa_device::run_file_playback(
        &config.device,
        rate,
        config.period,
        config.buffer,
        total,
        sink,
    )
    .map_err(|error| format!("cannot play: {error}"))?;
    Ok(report.frames)
}

#[cfg(not(feature = "alsa"))]
fn play_hardware(
    config: &Config,
    playback: &mut Playback,
    status: &Arc<Mutex<PlayStatus>>,
    stop: &AtomicBool,
) -> Result<u64, String> {
    let _ = (config, playback, status, stop);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
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
    plans: Vec<TrackPlan>,
    status: Arc<Mutex<Status>>,
    stop: Arc<AtomicBool>,
    params: Arc<ParamQueue>,
) {
    // Build the mixer here, on the take's thread, so it is never moved between
    // threads. Its control ring is the one the socket already holds. The
    // chains are built here too: an insert is not `Send`, and `param` addresses
    // the effects that are actually in each track's strip.
    let inputs: Vec<usize> = plans.iter().map(|plan| plan.input).collect();
    let labels: Vec<String> = (1..=plans.len()).map(|track| format!("ch{track}")).collect();
    let label_refs: Vec<&str> = labels.iter().map(|label| label.as_str()).collect();
    let mut mixer = Mixer::with_queue(&inputs, &label_refs, Arc::clone(&params));
    for (index, track) in mixer.tracks_mut().iter_mut().enumerate() {
        let plan = &plans[index];
        let mut channel = Channel::new(plan.gain, plan.pan);
        for kind in &plan.inserts {
            channel.push(kind.build());
        }
        track.channel = channel;
    }
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
    let mut device = NullDevice::new(config.rate, config.period, config.channels);
    mixer.prepare(config.rate, config.period);
    let total = take_frames(seconds, config.rate);
    let mut source = vec![0.0f32; config.period * config.channels];
    let mut mono = vec![0.0f32; config.period];
    let mut stereo = vec![0.0f32; config.period * TAKE_CHANNELS];
    let mut pcm = vec![0i16; config.period * TAKE_CHANNELS];
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
        let samples = frames * TAKE_CHANNELS;
        for track in 0..track_count {
            let input = mixer.tracks()[track].input;
            if input >= config.channels {
                return Err(format!(
                    "track {track} records input {input}, but the device has {} channel(s)",
                    config.channels
                ));
            }
            for frame in 0..frames {
                mono[frame] = source[frame * config.channels + input];
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
    /// Device channels per frame, learned in `prepared`.
    channels: usize,
    mono: Vec<f32>,
    stereo: Vec<f32>,
    pcm: Vec<i16>,
}

#[cfg(feature = "alsa")]
impl jawn_audio::alsa_device::CaptureSink for ServeSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        self.channels = channels;
        if let Some(index) = self
            .mixer
            .tracks()
            .iter()
            .position(|track| track.input >= channels)
        {
            let input = self.mixer.tracks()[index].input;
            return Err(format!(
                "track {} records input {input}, but the device granted only {channels} channel(s)",
                index + 1
            ));
        }
        self.mixer.prepare(rate, period);
        self.mono = vec![0.0; period];
        self.stereo = vec![0.0; period * TAKE_CHANNELS];
        self.pcm = vec![0i16; period * TAKE_CHANNELS];
        Ok(())
    }

    fn block(&mut self, block: &[i16]) -> Result<(), String> {
        // The sink is the only place a stop can reach a device loop that owns
        // the read: ending the sink ends the capture.
        if self.stop.load(Ordering::SeqCst) {
            return Err("stopped".to_string());
        }
        let channels = self.channels;
        let frames = (block.len() / channels).min(self.mono.len());
        let track_count = self.mixer.tracks().len();
        if self.disks.len() != track_count {
            return Err(format!(
                "{track_count} track(s) but {} disk writer(s)",
                self.disks.len()
            ));
        }
        let samples = frames * TAKE_CHANNELS;
        for track in 0..track_count {
            let input = self.mixer.tracks()[track].input;
            if input >= channels {
                return Err(format!(
                    "track {track} records input {input}, but the device has {channels} channel(s)"
                ));
            }
            for frame in 0..frames {
                self.mono[frame] = f32::from(block[frame * channels + input]) / 32_768.0;
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
        channels: config.channels,
        mono: Vec::new(),
        stereo: Vec::new(),
        pcm: Vec::new(),
    };
    let report = jawn_audio::alsa_device::run_capture(
        &config.device,
        config.rate,
        config.period,
        config.buffer,
        config.channels,
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

/// One value from the line: a scalar, an array of values, or an object (a
/// take's per-track plan).
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Str(String),
    Num(f64),
    Bool(bool),
    Null,
    /// An array: `"inputs":[0,1,2]` or `"inserts":["tone","delay"]`.
    Arr(Vec<Value>),
    /// One object in a value position, as `tracks` carries one per track.
    Obj(Object),
}

/// An object, in the order its keys appeared. A repeated key reads as the last
/// one, as a JSON parser would.
pub type Object = Vec<(String, Value)>;

/// The last value for `key`, if the object has one.
pub fn get<'a>(object: &'a Object, key: &str) -> Option<&'a Value> {
    object
        .iter()
        .rev()
        .find(|(name, _)| name == key)
        .map(|(_, value)| value)
}

/// Parse one JSON object.
///
/// Values are strings, numbers, booleans, null, arrays, or objects. An object
/// is what a take's `tracks` array carries one of per track; an array inside an
/// array is still an error, and nesting is bounded by [`MAX_VALUE_DEPTH`], so a
/// caller cannot smuggle an unbounded shape this protocol never promised.
/// Strings decode `\"`, `\\`, `\/`, `\b`, `\f`, `\n`, `\r`, `\t` and
/// `\uXXXX` (including surrogate pairs); every other character, including
/// non-ASCII and spaces, is taken literally.
pub fn parse_object(line: &str) -> Result<Object, String> {
    let mut parser = Parser {
        text: line,
        at: 0,
        depth: 0,
    };
    parser.skip_ws();
    let object = parser.object()?;
    parser.finish()?;
    Ok(object)
}

struct Parser<'a> {
    text: &'a str,
    at: usize,
    /// How many objects enclose the value being read.
    depth: usize,
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

    /// One object: the line's own, or a `tracks` plan entry. Every caller
    /// expects the leading `{`, so the caller's `skip_ws` is what allows it.
    fn object(&mut self) -> Result<Object, String> {
        if self.depth >= MAX_VALUE_DEPTH {
            return Err(format!(
                "objects are nested more than {MAX_VALUE_DEPTH} deep"
            ));
        }
        self.expect(b'{')?;
        self.depth += 1;
        let mut object = Object::new();
        self.skip_ws();
        if self.bump_if(b'}') {
            self.depth -= 1;
            return Ok(object);
        }
        loop {
            self.skip_ws();
            let key = self.string()?;
            self.skip_ws();
            self.expect(b':')?;
            self.skip_ws();
            let value = self.value()?;
            object.push((key, value));
            self.skip_ws();
            if self.bump_if(b',') {
                continue;
            }
            if self.bump_if(b'}') {
                break;
            }
            return Err(format!(
                "expected `,` or `}}` after a value (byte {})",
                self.at
            ));
        }
        self.depth -= 1;
        Ok(object)
    }

    fn value(&mut self) -> Result<Value, String> {
        match self.peek() {
            Some(b'"') => return self.string().map(Value::Str),
            Some(b'[') => return self.array(),
            Some(b'{') => return self.object().map(Value::Obj),
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
            "a value must be a string, number, boolean, null or an array (byte {})",
            self.at
        ))
    }

    fn array(&mut self) -> Result<Value, String> {
        self.expect(b'[')?;
        let mut values = Vec::new();
        self.skip_ws();
        if self.bump_if(b']') {
            return Ok(Value::Arr(values));
        }
        loop {
            self.skip_ws();
            if self.peek() == Some(b'[') {
                return Err("nested arrays are not allowed".to_string());
            }
            values.push(self.value()?);
            self.skip_ws();
            if self.bump_if(b',') {
                continue;
            }
            if self.bump_if(b']') {
                break;
            }
            return Err(format!(
                "expected `,` or `]` in an array (byte {})",
                self.at
            ));
        }
        Ok(Value::Arr(values))
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
    fn an_array_of_scalars_parses_but_a_nested_array_is_refused() {
        let object = parse_object(r#"{"inputs":[2,0,3]}"#).expect("parse");
        assert_eq!(
            get(&object, "inputs"),
            Some(&Value::Arr(vec![
                Value::Num(2.0),
                Value::Num(0.0),
                Value::Num(3.0)
            ]))
        );
        let empty = parse_object(r#"{"a":[]}"#).expect("parse");
        assert_eq!(get(&empty, "a"), Some(&Value::Arr(Vec::new())));

        let error = parse_object(r#"{"a":[[1]]}"#).unwrap_err();
        assert!(error.contains("nested"), "{error}");
        // A nested object in the key position is not a shape either.
        assert!(parse_object(r#"{{"a":1}:2}"#).is_err());
        // A trailing comma and an unterminated array are errors, not guesses.
        assert!(parse_object(r#"{"a":[1,]}"#).is_err());
        assert!(parse_object(r#"{"a":[1,2}"#).is_err());
    }

    #[test]
    fn a_tracks_plan_is_an_array_of_objects() {
        let object = parse_object(
            r#"{"tracks":[{"input":0,"gain":0.8,"inserts":["tone","delay"]},{"input":1,"inserts":[]}]}"#,
        )
        .expect("parse");
        let tracks = match get(&object, "tracks") {
            Some(Value::Arr(tracks)) => tracks,
            other => panic!("tracks is not an array: {other:?}"),
        };
        assert_eq!(tracks.len(), 2);
        let first = match &tracks[0] {
            Value::Obj(fields) => fields,
            other => panic!("a track is not an object: {other:?}"),
        };
        assert_eq!(number(first, "input"), Some(0.0));
        assert_eq!(text(first, "gain"), None);
        assert_eq!(
            get(first, "inserts"),
            Some(&Value::Arr(vec![
                Value::Str("tone".to_string()),
                Value::Str("delay".to_string())
            ]))
        );
        let second = match &tracks[1] {
            Value::Obj(fields) => fields,
            other => panic!("a track is not an object: {other:?}"),
        };
        assert_eq!(number(second, "input"), Some(1.0));
        assert_eq!(get(second, "inserts"), Some(&Value::Arr(Vec::new())));

        // Depth is bounded, so a caller cannot nest a plan inside a plan.
        let deep = r#"{"a":{"b":{"c":{"d":1}}}}"#;
        assert!(parse_object(deep).is_err());
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
