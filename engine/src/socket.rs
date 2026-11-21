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
//! The parent directory is created if missing, whatever is at the path is
//! asked for a `status` line, and only a socket that does not answer (a crash
//! remnant) is unlinked. A live engine is refused instead, so a second start
//! can never displace the one that owns the path. The socket is then bound and
//! its mode set to 0600 at once. A clean `quit` unlinks it; a crash leaves the
//! file behind on purpose, because the next start can tell that remnant from a
//! live engine. That is why the unlink happens *before* `bind` and never after
//! a successful bind: removing a live socket would strand the running engine.
//! A running engine also watches the file it bound, and exits if it is gone or
//! was replaced, so an engine displaced by an older binary cannot play and
//! capture forever where no manager can reach it.
//!
//! # One client at a time
//!
//! The manager is the only caller, and two controllers would arm and stop the
//! same take. A second connection is answered with one error line and closed.
//! Seeing it takes a non-blocking accept while the first client is connected,
//! so the loop waits in `poll(2)` for either descriptor rather than sleeping
//! between looks: an idle engine must not wake for nothing. A signal is the
//! one thing that must wake it from outside, and `signal(2)` restarts `poll`
//! (SA_RESTART), so the handler writes a byte to a wake pipe that is polled
//! beside the listener: a TERM takes the same clean path as `quit`.
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

use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::raw::{c_int, c_short, c_ulong};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::io::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use jawn_audio::{
    listen::{self, ListenPlan, ListenStrip},
    monitor_start, to_i16, BackendKind, Channel, Consumer, Device, DiskWriter, InsertKind, Mixer,
    MonitorBus, MonitorSpec, NullDevice, ParamName, ParamQueue, PlayTrack, Playback, Producer,
    MASTER_ORDER,
};

use crate::patchbay::{PatchSummary, Patchbay};
use jawn_audio::pipewire_guard::{PlaybackGuard, FEEDBACK_PREFIX};

use crate::{alignment_json, take_frames, Alignment, MAX_CHANNELS, MAX_TRACKS, TAKE_CHANNELS};

/// How long a take runs when the command does not say.
const DEFAULT_SECONDS: f64 = 10.0;

/// The live-input ring: about 170 ms of stereo at 48 kHz, enough for a
/// scheduling hiccup without letting a late monitor delay the take.
const MONITOR_RING_FRAMES: usize = 8192;

/// The gateway's inbound boundary: the call is 8 kHz mono, and the engine owns
/// that rate, not the house rate (`docs/ivr-gateway-engine.md`).
const GATEWAY_RATE: u32 = 8_000;
const GATEWAY_CHANNELS: usize = 1;

/// The gateway drain's tick and block: one 10 ms frame of the call, popped
/// every 10 ms. `parec` delivers 20 ms at a time, so the ring is emptied at
/// real time while each write to `call_in` is one whole 160-byte frame.
const GATEWAY_DRAIN_MSEC: u64 = 10;
const GATEWAY_DRAIN_FRAMES: usize = 80;

/// The prompt the reception mixer plays into (`JawnOS::Sco::Mixer`), used when
/// a bind names no `prompt` sink of its own.
const GATEWAY_PROMPT_SINK: &str = "jawn_prompt";

/// The prompt FIFO's read pace. `pacat` asks for 20 ms of latency; a 10 ms
/// tick keeps the FIFO from filling between reads without busy-waiting.
const GATEWAY_PROMPT_MSEC: u64 = 10;

/// A silent bind retries this often, for this long, while `call_in` stays
/// requested. The reception mixer creates `jawn_call_in` a moment after the
/// engine is asked to bind it, so the first look can honestly be `silent`.
const GATEWAY_RETRY: Duration = Duration::from_millis(500);
const GATEWAY_RETRY_FOR: Duration = Duration::from_secs(5);

/// `O_NONBLOCK`, without dragging in the libc crate for one constant. Linux's
/// value on every architecture the engine builds for.
const O_NONBLOCK: i32 = 0o4000;

/// `poll(2)`'s one request flag, and the descriptor set it fills. Declared here
/// for the same reason as `O_NONBLOCK`: the engine builds for Linux only, where
/// `nfds_t` is `unsigned long` and these field types are fixed, and a wait that
/// blocks is worth three constants — but not a crate dependency, which is the
/// standing bargain at the top of this file. `poll` returns for POLLHUP and
/// POLLERR too, and the loop below treats every wake as "look at both", so only
/// POLLIN ever needs a name.
const POLLIN: c_short = 0x001;

#[repr(C)]
struct PollFd {
    fd: c_int,
    events: c_short,
    revents: c_short,
}

extern "C" {
    fn poll(fds: *mut PollFd, nfds: c_ulong, timeout: c_int) -> c_int;
}

/// How long `send` waits between attempts at a client that has stopped reading.
/// Only a wedged peer reaches this; the serve loop itself never sleeps.
const SEND_BACKOFF: Duration = Duration::from_millis(2);

/// How long a status probe waits for the peer to answer. A live engine answers
/// in microseconds; this only bounds a wedged one.
const PROBE_TIMEOUT: Duration = Duration::from_millis(500);

/// How often the watchdog compares the socket file's identity. An engine that
/// lost its socket is invisible to the manager either way; this only bounds
/// how long it keeps playing and capturing first.
const SOCKET_WATCH: Duration = Duration::from_millis(250);

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
    /// The output the caller named for a PipeWire stream. The backend opens the
    /// ALSA `default` PCM regardless, so this is what the guard hands to
    /// `PIPEWIRE_NODE` and verifies after the stream exists.
    pub target: Option<String>,
    pub rate: u32,
    pub period: usize,
    pub buffer: usize,
    /// The capture channel count a take asks the device for.
    pub channels: usize,
    pub socket: PathBuf,
    /// The saved-plan wrapper a `--serve` restores from, if any.
    pub plan: Option<PathBuf>,
    /// Which machine this engine serves; a node delegated elsewhere is silent.
    pub machine: String,
    /// The PulseAudio/PipeWire source for this machine's own mix. `None` keeps
    /// the old behaviour: the patch plays only what the plan routes from the
    /// interface.
    pub system_device: Option<String>,
    /// The PulseAudio/PipeWire source a plan's `handset` source is captured
    /// from (`jawn_call_in.monitor` by default). `None` starts no capture and
    /// reports a declared handset as silent.
    pub handset_device: Option<String>,
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

/// `--plan`, else `$JAWNOS_AUDIO_PLAN`, else `$HOME/.president/audio-plan.json`.
/// A missing `HOME` and no flag/env means no saved plan to restore; `None` is
/// the only case where the engine serves with no boot-restore report at all.
pub(crate) fn default_plan_path(flag: Option<&str>) -> Option<PathBuf> {
    if let Some(path) = flag {
        return Some(PathBuf::from(path));
    }
    if let Ok(path) = std::env::var("JAWNOS_AUDIO_PLAN") {
        if !path.is_empty() {
            return Some(PathBuf::from(path));
        }
    }
    match std::env::var("HOME") {
        Ok(home) if !home.is_empty() => {
            Some(PathBuf::from(home).join(".president/audio-plan.json"))
        }
        _ => None,
    }
}

/// Start the reception mixer's screened-call capture when the plan declares a
/// `handset` source. A plan without one runs no extra `parec`. A sink the
/// sound server does not offer (or a capture that cannot start) silences the
/// node and leaves the rest of the patch running.
fn attach_handset(
    patchbay: &mut Patchbay,
    config: &Config,
) -> Option<crate::system_capture::SystemCapture> {
    if !patchbay.wants_handset() {
        return None;
    }
    if !matches!(config.backend, BackendKind::Alsa | BackendKind::PipeWire) {
        // The null device captures nothing; report the node as silent rather
        // than leave it "pending" forever.
        patchbay.silence_handset();
        return None;
    }
    let Some(source) = config.handset_device.as_deref() else {
        patchbay.silence_handset();
        return None;
    };
    if crate::system_capture::source_exists(source) == Some(false) {
        patchbay.silence_handset();
        return None;
    }
    match crate::system_capture::SystemCapture::start(source, config.rate) {
        Ok((capture, consumer)) => {
            patchbay.set_handset(consumer);
            Some(capture)
        }
        Err(error) => {
            eprintln!("jawn-audio: handset: {error}");
            patchbay.silence_handset();
            None
        }
    }
}

/// The gateway's three ports (`docs/ivr-gateway-engine.md`).
///
/// Phase 4b-2 carries the call's PCM. `bind` creates a per-call directory with
/// two named pipes beside the engine's plan and socket:
///
/// - `call_in`: the engine writes the caller's voice, mono s16le at 8 kHz; the
///   helper reads it as its capture side.
/// - `prompt`: the helper writes the prompt, the engine feeds it to `pacat` on
///   the reception mixer's prompt sink.
///
/// The control socket stays line-based; PCM never crosses it. The capture is
/// still the same `parec` of `<call_in>.monitor` the system mix uses, drained on
/// its own worker, keeping a frame count, a peak and a drop count.
struct Gateway {
    /// The sink named by the last `bind`; `None` before the first bind and
    /// after `release`.
    call_in: Option<String>,
    /// `Some` while the monitor is actually captured; `None` with `call_in`
    /// set means the bind found nothing it could capture (`silent`).
    capture: Option<GatewayCapture>,
    /// The prompt port, opened at bind and run by its own worker. `None` means
    /// the port could not be opened; `prompt` then answers `silent`.
    prompt: Option<GatewayPrompt>,
    /// Where the FIFOs live. `None` until a bind makes them and after release.
    paths: Option<GatewayPaths>,
    /// A silent bind's bounded retry, cleared when the capture starts or the
    /// window closes.
    retry: Option<BindRetry>,
    /// Whether this engine could carry a gateway at all: the socket answers
    /// (by construction) and both `parec` and `pacat` are on `PATH`. Readiness
    /// reads this while idle, before any call binds.
    capable: bool,
}

/// The two FIFOs one bound call uses. Absolute, because the helper is given the
/// directory and both sides must agree without consulting a working directory.
#[derive(Clone)]
struct GatewayPaths {
    dir: PathBuf,
    call_in: PathBuf,
    prompt: PathBuf,
}

/// A bind that found no source yet: look again every `GATEWAY_RETRY` for
/// `GATEWAY_RETRY_FOR`. The reception mixer creates its sink a moment after the
/// engine is asked to bind it, and a port that stayed silent forever was the
/// defect 4b-1's review named.
struct BindRetry {
    sink: String,
    next: Instant,
    deadline: Instant,
}

impl Gateway {
    fn off(capable: bool) -> Self {
        Gateway {
            call_in: None,
            capture: None,
            prompt: None,
            paths: None,
            retry: None,
            capable,
        }
    }

    /// `off` before any bind, `silent` when the sink could not be captured,
    /// `captured` while the drain runs.
    fn state(&self) -> &'static str {
        match (&self.call_in, &self.capture) {
            (None, _) => "off",
            (Some(_), Some(_)) => "captured",
            (Some(_), None) => "silent",
        }
    }

    /// `writing` once a call bound the prompt port and its worker is alive,
    /// `silent` when no call is bound or `pacat` died. The port is bound even
    /// before the first prompt byte; the child spawns lazily with the first.
    fn prompt_state(&self) -> &'static str {
        match &self.prompt {
            Some(prompt) if prompt.writing() => "writing",
            _ => "silent",
        }
    }

    /// The `"gateway":{...}` fragment every status line and the patch reply
    /// carry. The field names are the house's contract: it reads them, and they
    /// do not move between slices. `dropped` is additive (4b-2): frames the
    /// ring or a full `call_in` pipe could not take.
    fn fragment(&self) -> String {
        let (frames, peak, dropped) = match &self.capture {
            Some(capture) => capture.counters.read(),
            None => (0, 0.0, 0),
        };
        let paths = match &self.paths {
            Some(paths) => format!(
                "{{\"call_in\":\"{}\",\"prompt\":\"{}\"}}",
                jawn_audio::loopback::json_escape(&paths.call_in.to_string_lossy()),
                jawn_audio::loopback::json_escape(&paths.prompt.to_string_lossy())
            ),
            None => "{}".to_string(),
        };
        format!(
            "\"gateway\":{{\"call_in\":\"{}\",\"prompt\":\"{}\",\"monitor\":\"helper\",\"rate\":{},\"channels\":{},\"peak\":{:.6},\"frames\":{},\"dropped\":{},\"paths\":{},\"capable\":{}}}",
            self.state(),
            self.prompt_state(),
            GATEWAY_RATE,
            GATEWAY_CHANNELS,
            peak,
            frames,
            dropped,
            paths,
            self.capable
        )
    }

    /// Open the two FIFOs for a call and start the prompt worker. Returns the
    /// paths so a caller can report them; a stale directory from a crashed
    /// engine is removed first, because it is this process's own name.
    fn open_ports(
        &mut self,
        state_dir: &Path,
        prompt_sink: &str,
        volume: Option<u32>,
    ) -> Result<GatewayPaths, String> {
        if let Some(paths) = &self.paths {
            return Ok(paths.clone());
        }
        let dir = gateway_dir(state_dir);
        if dir.exists() {
            let _ = fs::remove_dir_all(&dir);
        }
        fs::create_dir_all(&dir)
            .map_err(|error| format!("cannot create {}: {error}", dir.display()))?;
        let paths = GatewayPaths {
            call_in: dir.join("call_in"),
            prompt: dir.join("prompt"),
            dir,
        };
        make_fifo(&paths.call_in)?;
        make_fifo(&paths.prompt)?;
        // Opening the read side does not start `pacat`; the child waits for the
        // first prompt byte, so a bind with no call runs only the capture.
        self.prompt = Some(GatewayPrompt::start(
            paths.prompt.clone(),
            prompt_sink.to_string(),
            volume,
        )?);
        self.paths = Some(paths.clone());
        Ok(paths)
    }

    /// Try the capture once. `true` means it started; `false` leaves `call_in`
    /// set and the port `silent`, and the caller schedules a retry.
    fn try_capture(&mut self, sink: &str, paths: &GatewayPaths) -> bool {
        let monitor = crate::system_capture::monitor_name(sink);
        if crate::system_capture::source_exists(&monitor) == Some(false) {
            return false;
        }
        match GatewayCapture::start(sink, paths.call_in.clone()) {
            Ok(capture) => {
                self.capture = Some(capture);
                true
            }
            Err(error) => {
                eprintln!("jawn-audio: gateway: {error}");
                false
            }
        }
    }

    /// One look at a silent bind's retry clock. Called from the serve loop, so
    /// the retry runs whether or not a client is connected. Nothing is tried
    /// after the window closes; a `release` clears it too.
    fn tick(&mut self) {
        if self.capture.is_some() {
            self.retry = None;
            return;
        }
        let Some(retry) = &self.retry else { return };
        let now = Instant::now();
        if now >= retry.deadline {
            self.retry = None;
            return;
        }
        if now < retry.next {
            return;
        }
        let sink = retry.sink.clone();
        if let Some(retry) = self.retry.as_mut() {
            retry.next = now + GATEWAY_RETRY;
        }
        let Some(paths) = self.paths.clone() else {
            self.retry = None;
            return;
        };
        if self.try_capture(&sink, &paths) {
            self.retry = None;
        }
    }

    /// When the serve loop must next come back to [`Gateway::tick`], if ever.
    /// `None` is "nothing pending": the loop may wait on its descriptors with
    /// no deadline, which is what keeps an idle engine out of the wakeup it
    /// used to spend on the retry clock.
    fn next_tick(&self) -> Option<Instant> {
        if self.capture.is_some() {
            return None;
        }
        self.retry
            .as_ref()
            .map(|retry| retry.next.min(retry.deadline))
    }

    /// Stop the capture and the prompt, then remove the per-call directory,
    /// leaving no child, thread, ring or stale path.
    fn release(&mut self) {
        if let Some(mut capture) = self.capture.take() {
            capture.finish();
        }
        if let Some(mut prompt) = self.prompt.take() {
            prompt.finish();
        }
        if let Some(paths) = self.paths.take() {
            let _ = fs::remove_dir_all(&paths.dir);
        }
        self.call_in = None;
        self.retry = None;
    }
}

impl Drop for Gateway {
    fn drop(&mut self) {
        self.release();
    }
}

/// The per-call directory beside the engine's own state: the plan's directory
/// when there is a plan, else the socket's, else `~/.president`. The Perl side
/// names the same one (`JawnOS::Audio::Engine::audio_engine_state_dir`).
fn state_dir(config: &Config) -> PathBuf {
    let parent = config
        .plan
        .as_ref()
        .and_then(|plan| plan.parent())
        .filter(|parent| !parent.as_os_str().is_empty())
        .or_else(|| {
            config
                .socket
                .parent()
                .filter(|parent| !parent.as_os_str().is_empty())
        });
    let dir = match parent {
        Some(parent) => parent.to_path_buf(),
        None => match std::env::var("HOME") {
            Ok(home) if !home.is_empty() => PathBuf::from(home).join(".president"),
            _ => PathBuf::from("."),
        },
    };
    if dir.is_absolute() {
        dir
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(&dir))
            .unwrap_or(dir)
    }
}

/// `<state dir>/gateway-<pid>`: one call at a time, one engine process.
fn gateway_dir(state_dir: &Path) -> PathBuf {
    state_dir.join(format!("gateway-{}", std::process::id()))
}

extern "C" {
    fn mkfifo(pathname: *const std::os::raw::c_char, mode: u32) -> i32;
}

/// A named pipe the engine and the helper meet on. `mkfifo` is the one portable
/// way to make it without a new crate; its failure is the bind's failure.
fn make_fifo(path: &Path) -> Result<(), String> {
    let name = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| format!("a FIFO path cannot hold a NUL: {}", path.display()))?;
    let made = unsafe { mkfifo(name.as_ptr(), 0o600) };
    if made != 0 {
        return Err(format!(
            "cannot create the FIFO {}: {}",
            path.display(),
            io::Error::last_os_error()
        ));
    }
    Ok(())
}

/// The `call_in` write side. Opened lazily, because a FIFO's write end refuses
/// to open until the helper's read end exists; a frame that arrives first is a
/// counted drop, exactly like a frame the ring could not hold.
struct CallInPort {
    path: PathBuf,
    file: Option<File>,
    dropped: Arc<AtomicU64>,
}

impl CallInPort {
    fn new(path: PathBuf, dropped: Arc<AtomicU64>) -> Self {
        CallInPort {
            path,
            file: None,
            dropped,
        }
    }

    fn open(&mut self) -> bool {
        if self.file.is_some() {
            return true;
        }
        match OpenOptions::new()
            .write(true)
            .custom_flags(O_NONBLOCK)
            .open(&self.path)
        {
            Ok(file) => {
                self.file = Some(file);
                true
            }
            Err(_) => false,
        }
    }

    /// One whole frame or nothing: a FIFO write of at most `PIPE_BUF` is atomic,
    /// so a full pipe answers `EAGAIN` instead of a partial frame. Return `true`
    /// when the frame was written.
    fn write_frame(&mut self, bytes: &[u8]) -> bool {
        if !self.open() {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        }
        let Some(file) = self.file.as_mut() else {
            self.dropped.fetch_add(1, Ordering::Relaxed);
            return false;
        };
        match file.write(bytes) {
            Ok(written) if written == bytes.len() => true,
            Ok(_) => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                false
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                self.dropped.fetch_add(1, Ordering::Relaxed);
                false
            }
            Err(_) => {
                // The helper closed its read end. Drop the handle so a later
                // call's helper can open a fresh writer.
                self.file = None;
                self.dropped.fetch_add(1, Ordering::Relaxed);
                false
            }
        }
    }
}

/// One bound gateway capture: the `parec` child, the worker draining its ring
/// into `call_in`, and the counters `status` reads.
struct GatewayCapture {
    capture: crate::system_capture::SystemCapture,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    counters: GatewayCounters,
}

/// The drain's answer: how many frames it heard, the loudest sample, and how
/// many frames the ring or the pipe refused. Shared with the worker, so `status`
/// never touches the ring.
#[derive(Clone, Default)]
struct GatewayCounters {
    frames: Arc<AtomicU64>,
    peak: Arc<AtomicU32>,
    dropped: Arc<AtomicU64>,
}

impl GatewayCounters {
    fn read(&self) -> (u64, f32, u64) {
        (
            self.frames.load(Ordering::Relaxed),
            f32::from_bits(self.peak.load(Ordering::Relaxed)),
            self.dropped.load(Ordering::Relaxed),
        )
    }
}

impl GatewayCapture {
    fn start(sink: &str, call_in: PathBuf) -> Result<GatewayCapture, String> {
        let (capture, consumer) =
            crate::system_capture::SystemCapture::start_sink(sink, GATEWAY_RATE)?;
        let counters = GatewayCounters::default();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread_counters = counters.clone();
        let handle = thread::Builder::new()
            .name("jawn-audio-gateway".to_string())
            .spawn(move || {
                let mut block = vec![0.0f32; GATEWAY_DRAIN_FRAMES * 2];
                let mut mono = vec![0u8; GATEWAY_DRAIN_FRAMES * 2];
                let mut port = CallInPort::new(call_in, thread_counters.dropped.clone());
                while !thread_stop.load(Ordering::SeqCst) {
                    drain_gateway(&consumer, &thread_counters, &mut block, &mut mono, &mut port);
                    thread::sleep(Duration::from_millis(GATEWAY_DRAIN_MSEC));
                }
            })
            .map_err(|error| format!("cannot start the gateway thread: {error}"))?;
        Ok(GatewayCapture {
            capture,
            stop,
            handle: Some(handle),
            counters,
        })
    }

    /// Stop the drain, then the capture: when this returns `parec` is reaped
    /// and no thread is left holding the ring.
    fn finish(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
        self.capture.stop();
    }
}

impl Drop for GatewayCapture {
    fn drop(&mut self) {
        self.finish();
    }
}

/// The prompt port's read side. The worker sleeps on the FIFO and spawns
/// `pacat` only when the first prompt byte arrives, so an idle bind runs no
/// process. A dead child is reported through `writing` and reaped; it is never
/// fatal to the engine or the call.
struct GatewayPrompt {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    writing: Arc<AtomicBool>,
}

impl GatewayPrompt {
    fn start(
        path: PathBuf,
        sink: String,
        volume: Option<u32>,
    ) -> Result<GatewayPrompt, String> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(O_NONBLOCK)
            .open(&path)
            .map_err(|error| format!("cannot open the prompt FIFO {}: {error}", path.display()))?;
        let stop = Arc::new(AtomicBool::new(false));
        let writing = Arc::new(AtomicBool::new(true));
        let thread_stop = Arc::clone(&stop);
        let thread_writing = Arc::clone(&writing);
        let handle = thread::Builder::new()
            .name("jawn-audio-gateway-prompt".to_string())
            .spawn(move || prompt_worker(file, sink, volume, thread_stop, thread_writing))
            .map_err(|error| format!("cannot start the prompt thread: {error}"))?;
        Ok(GatewayPrompt {
            stop,
            handle: Some(handle),
            writing,
        })
    }

    fn writing(&self) -> bool {
        self.writing.load(Ordering::Relaxed)
    }

    /// Stop the worker and reap `pacat` if it was ever spawned.
    fn finish(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for GatewayPrompt {
    fn drop(&mut self) {
        self.finish();
    }
}

fn prompt_child(sink: &str, volume: Option<u32>) -> Result<Child, String> {
    let mut args = vec![
        "--playback".to_string(),
        "--raw".to_string(),
        format!("--device={sink}"),
        "--format=s16le".to_string(),
        format!("--rate={GATEWAY_RATE}"),
        format!("--channels={GATEWAY_CHANNELS}"),
        "--latency-msec=20".to_string(),
        // The mixer repairs the prompt's route by this name (a bare `pacat`
        // can inherit a saved route onto `jawn_call_in`), so the engine's
        // child wears the same name the helper's did.
        "--client-name=jawn-sco-prompt".to_string(),
        "--stream-name=jawn-sco-prompt".to_string(),
    ];
    // The phone channel's gain, in the mixer's own percent form. Absent means
    // `pacat`'s default (100%), exactly as the helper's command omits it.
    if let Some(percent) = volume {
        args.push(format!("--volume={percent}%"));
    }
    Command::new("pacat")
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("cannot start pacat: {error}"))
}

fn prompt_worker(
    mut fifo: File,
    sink: String,
    volume: Option<u32>,
    stop: Arc<AtomicBool>,
    writing: Arc<AtomicBool>,
) {
    let mut child: Option<Child> = None;
    let mut buffer = [0u8; 4096];
    while !stop.load(Ordering::SeqCst) {
        match fifo.read(&mut buffer) {
            Ok(0) => {
                // No writer: the helper is not in the call yet, or it has gone.
                // Take a dead child with it so `pacat` never outlives the call.
                if let Some(mut done) = child.take() {
                    let _ = done.kill();
                    let _ = done.wait();
                }
                thread::sleep(Duration::from_millis(GATEWAY_PROMPT_MSEC));
            }
            Ok(count) => {
                if child.is_none() {
                    match prompt_child(&sink, volume) {
                        Ok(spawned) => {
                            child = Some(spawned);
                            writing.store(true, Ordering::Relaxed);
                        }
                        Err(error) => {
                            eprintln!("jawn-audio: gateway prompt: {error}");
                            writing.store(false, Ordering::Relaxed);
                            thread::sleep(Duration::from_millis(GATEWAY_PROMPT_MSEC));
                            continue;
                        }
                    }
                }
                let fed = child
                    .as_mut()
                    .and_then(|running| running.stdin.as_mut())
                    .map(|stdin| stdin.write_all(&buffer[..count]).is_ok())
                    .unwrap_or(false);
                if !fed {
                    if let Some(mut done) = child.take() {
                        let _ = done.kill();
                        let _ = done.wait();
                    }
                    writing.store(false, Ordering::Relaxed);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(GATEWAY_PROMPT_MSEC));
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(_) => {
                writing.store(false, Ordering::Relaxed);
                thread::sleep(Duration::from_millis(GATEWAY_PROMPT_MSEC));
            }
        }
    }
    if let Some(mut done) = child.take() {
        let _ = done.kill();
        let _ = done.wait();
    }
}

/// Pop whatever the capture holds, keep a frame count and a peak, downmix the
/// stereo ring to mono s16le, and write it to `call_in`. `block` and `mono` are
/// reused between ticks, so the drain allocates nothing while a call runs. The
/// ring and the pipe both drop rather than block, so a busy drain is a counted
/// lost frame, never a stalled `parec`.
fn drain_gateway(
    consumer: &Consumer,
    counters: &GatewayCounters,
    block: &mut [f32],
    mono: &mut [u8],
    port: &mut CallInPort,
) {
    let wanted = block.len() / 2;
    let mut frames = 0u64;
    let mut peak = 0.0f32;
    loop {
        let got = consumer.pop(block);
        if got == 0 {
            break;
        }
        let mut at = 0;
        for frame in 0..got {
            let left = block[frame * 2];
            let right = block[frame * 2 + 1];
            peak = peak.max(left.abs()).max(right.abs());
            let down = to_i16((left + right) * 0.5);
            mono[at..at + 2].copy_from_slice(&down.to_le_bytes());
            at += 2;
        }
        port.write_frame(&mono[..at]);
        frames += got as u64;
        if got < wanted {
            break;
        }
    }
    if frames > 0 {
        counters.frames.fetch_add(frames, Ordering::Relaxed);
        // A non-negative f32 keeps its numeric order in its bit pattern, so
        // `fetch_max` is a monotonic peak without a lock on the worker.
        if peak > 0.0 {
            counters.peak.fetch_max(peak.to_bits(), Ordering::Relaxed);
        }
    }
}

/// The `poll` timeout that lets a loop look at the retry clock at `next` and
/// otherwise wait for a descriptor. `-1` is poll's own "block until ready"; a
/// millisecond is never rounded away, so a deadline a fraction of a millisecond
/// ahead does not become `poll(0)` and spin the loop.
fn wait_millis(next: Option<Instant>, now: Instant) -> c_int {
    let Some(next) = next else { return -1 };
    let left = next.saturating_duration_since(now);
    let ms = (left.as_micros() + 999) / 1_000;
    ms.min(c_int::MAX as u128) as c_int
}

/// Block until one of `fds` is readable or the retry clock at `next` is due.
/// A timeout is success: the caller's next act is to look at the clock either
/// way, and [`Gateway::tick`] is what decides whether anything is left to do.
fn wait_readable(fds: &[i32], next: Option<Instant>) -> Result<(), String> {
    let mut watched: Vec<PollFd> = fds
        .iter()
        .map(|fd| PollFd {
            fd: *fd,
            events: POLLIN,
            revents: 0,
        })
        .collect();
    loop {
        // Recomputed each pass: a signal that interrupts the wait must not
        // push the retry clock back by another full interval.
        let timeout = wait_millis(next, Instant::now());
        let ready = unsafe { poll(watched.as_mut_ptr(), watched.len() as c_ulong, timeout) };
        if ready >= 0 {
            return Ok(());
        }
        let error = io::Error::last_os_error();
        if error.kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return Err(format!("poll: {error}"));
    }
}

pub(crate) fn serve(
    config: Config,
    stop: &'static AtomicBool,
    wake: Option<c_int>,
) -> Result<ExitCode, String> {
    let path = config.socket.clone();
    let listener = bind(&path)?;
    let bound = socket_id(&path).ok_or_else(|| {
        format!(
            "cannot stat the socket {}: {}",
            path.display(),
            io::Error::last_os_error()
        )
    })?;
    // A second engine used to unlink this path and bind its own, leaving this
    // one playing and capturing where nothing could reach it. Watch the file we
    // bound: if it is gone, or another engine replaced it (a new inode), this
    // engine is the invisible one and must go. The check runs on a thread so a
    // blocked `accept` cannot postpone it.
    let watched = path.clone();
    let finished = Arc::new(AtomicBool::new(false));
    let watch_finished = Arc::clone(&finished);
    thread::spawn(move || {
        wait_for_socket_change(&watched, bound);
        // A clean quit removes the path just before the process goes; that is
        // not a replacement, and it must not print a second exit line.
        if watch_finished.load(Ordering::SeqCst) {
            return;
        }
        eprintln!(
            "jawn-audio: the control socket {} was removed or replaced; exiting",
            watched.display()
        );
        // `serve`'s clean unlink must not run here: the replacement owns the
        // path now, and removing it would strand the engine that took over.
        std::process::exit(0);
    });
    let mut server = Server::new(config, stop, wake);
    server.boot_restore();
    let outcome = server.run(listener);
    finished.store(true, Ordering::SeqCst);
    // A clean exit unlinks the socket, but only if it is still the file this
    // engine bound. A crash leaves it behind, and the next start unlinks that
    // stale path before it binds.
    if socket_id(&path) == Some(bound) {
        let _ = fs::remove_file(&path);
    }
    outcome.map(|()| ExitCode::SUCCESS)
}

/// Ask whatever is listening on `path` for a status line.
///
/// `Some` means the peer answered in the engine's protocol: either a healthy
/// `{"ok":true,...}` or the one error line a busy engine sends while another
/// client holds the socket. Both are a live engine; only a path with nothing
/// behind it (or a peer that never answers) is stale. The pid rides in the
/// status object, so it is absent for an engine too old to report one. Factored
/// out of `bind` so a test can put a fake engine on a socket and exercise the
/// decision without a device.
fn probe_live_engine(path: &Path) -> Option<LiveEngine> {
    let stream = UnixStream::connect(path).ok()?;
    stream.set_read_timeout(Some(PROBE_TIMEOUT)).ok()?;
    stream.set_write_timeout(Some(PROBE_TIMEOUT)).ok()?;
    (&stream).write_all(b"{\"cmd\":\"status\"}\n").ok()?;
    let mut reader = BufReader::new(&stream).take(MAX_LINE as u64);
    let mut line = String::new();
    match reader.read_line(&mut line) {
        Ok(0) | Err(_) => return None,
        Ok(_) => {}
    }
    let object = parse_object(line.trim()).ok()?;
    let pid = match get(&object, "pid") {
        Some(Value::Num(value)) if *value >= 1.0 && value.fract() == 0.0 => Some(*value as u32),
        _ => None,
    };
    Some(LiveEngine { pid })
}

/// What a live engine's status answer tells us about the process behind it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct LiveEngine {
    /// The pid the engine reports, when it is new enough to report one.
    pid: Option<u32>,
}

/// The file identity of a path. A replacement at the same path is a different
/// inode, which is how a displaced engine notices it no longer owns the name.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SocketId {
    dev: u64,
    ino: u64,
}

fn socket_id(path: &Path) -> Option<SocketId> {
    let meta = fs::metadata(path).ok()?;
    Some(SocketId {
        dev: meta.dev(),
        ino: meta.ino(),
    })
}

/// Block until the file at `path` is gone or is no longer the one `bound`
/// described. The serve loop calls this on a thread; returning is the signal
/// that another engine (or a person) took the path.
fn wait_for_socket_change(path: &Path, bound: SocketId) {
    loop {
        thread::sleep(SOCKET_WATCH);
        if socket_id(path) != Some(bound) {
            return;
        }
    }
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
    // A socket that answers a status request has a live engine behind it.
    // Refuse rather than unlink it: a second engine must never steal the first
    // one's path or answer its manager. A file with nothing behind it (a crash
    // remnant) does not answer, and removing it is safe.
    if path.exists() {
        if let Some(live) = probe_live_engine(path) {
            return Err(match live.pid {
                Some(pid) => format!(
                    "another engine (pid {pid}) is already serving {}",
                    path.display()
                ),
                None => format!("another engine is already serving {}", path.display()),
            });
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
    /// The most recent listen, kept after it ends for the same reason a take is.
    /// A take and a listen cannot both hold the capture stream, so at most one
    /// of `current` and `listen` can be live.
    listen: Option<ListenSession>,
    /// The house patchbay. It owns both the capture and the outputs, so it
    /// cannot share a machine with a take, a playback or a listen.
    patch: Option<PatchSession>,
    /// The signal flag the serve loop reads, and the wake pipe that makes a
    /// blocked `poll` look at it. Both are set up by `run_serve`; a signal
    /// stops the server exactly as a `quit` command does.
    stop: &'static AtomicBool,
    wake: Option<c_int>,
    /// The gateway's inbound port, if a call bound it. Independent of the
    /// patch: the caller's monitor is captured by `parec`, not by the device
    /// loop, so it runs beside a patch and says `off` until the first bind.
    gateway: Gateway,
    next_take: u64,
    /// What the boot restore did with the saved plan, reported on every status
    /// line as `plan` or `plan_error` beside `machine`.
    boot: BootPlan,
}

/// The boot-restore outcome, in the shape `status` reports it.
enum BootPlan {
    Armed(PatchSummary),
    Error(String),
}

/// Validate one take or listen parameter against the strip's armed chain.
///
/// The name must parse (which rejects an unknown control) and, when it names an
/// insert, that insert must be in the chain `status` reports. A `master_*`
/// address is the master rack's, never a track's, so it is refused here.
fn chain_parameter(name: &str, has_insert: impl Fn(&str) -> bool) -> Result<ParamName, String> {
    let parameter = ParamName::parse(name).ok_or_else(|| format!("no such parameter: {name}"))?;
    if parameter.master() {
        return Err(format!("no such parameter: {name}"));
    }
    if let Some(insert) = parameter.insert() {
        if !has_insert(insert) {
            return Err(format!("no such parameter: {name}"));
        }
    }
    Ok(parameter)
}

/// The optional `volume` a bind may carry: the phone channel's gain as a
/// percentage, which is how `JawnOS::Sco::Mixer::playback_volume` reports it and
/// how the helper's `pacat --volume` spells it. It is clamped the way the mixer
/// clamps the gain (0..1 → 0..100%), and absent means `pacat`'s own default.
fn parse_prompt_volume(object: &Object) -> Result<Option<u32>, String> {
    match get(object, "volume") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Num(value)) if value.is_finite() => {
            Ok(Some(value.round().clamp(0.0, 100.0) as u32))
        }
        Some(_) => Err("gateway bind \"volume\" must be a number from 0 to 100".to_string()),
    }
}

impl Server {
    fn new(config: Config, stop: &'static AtomicBool, wake: Option<c_int>) -> Self {
        // `capable` is the environment, not a call: a socket that answers (this
        // one) plus the two tools the ports need. Readiness reads it while idle.
        let capable = jawn_audio::backends::command_exists("parec")
            && jawn_audio::backends::command_exists("pacat");
        Server {
            config,
            current: None,
            playback: None,
            listen: None,
            patch: None,
            stop,
            wake,
            gateway: Gateway::off(capable),
            next_take: 1,
            boot: BootPlan::Error("no audio plan file configured".to_string()),
        }
    }

    /// Restore the saved plan at startup. The server always starts and serves;
    /// this only records what happened (and arms the patch when `manage` is
    /// true and the plan compiles).
    fn boot_restore(&mut self) {
        let plan_path = match self.config.plan.clone() {
            Some(path) => path,
            None => return,
        };
        let text = match fs::read_to_string(&plan_path) {
            Ok(text) => text,
            Err(_) => {
                self.boot =
                    BootPlan::Error(format!("no audio plan at {}", plan_path.display()));
                return;
            }
        };
        let object = match parse_object(text.trim()) {
            Ok(object) => object,
            Err(error) => {
                self.boot = BootPlan::Error(format!("{}: {error}", plan_path.display()));
                return;
            }
        };
        let manage = match get(&object, "manage") {
            Some(Value::Bool(value)) => *value,
            Some(Value::Num(value)) if *value == 1.0 => true,
            Some(Value::Num(value)) if *value == 0.0 => false,
            None | Some(Value::Null) => false,
            Some(_) => {
                self.boot = BootPlan::Error(format!(
                    "{}: \"manage\" must be true or false",
                    plan_path.display()
                ));
                return;
            }
        };
        if !manage {
            self.boot = BootPlan::Error(format!("{}: manage is off", plan_path.display()));
            return;
        }
        let plan = match get(&object, "plan") {
            Some(Value::Obj(plan)) => plan,
            _ => {
                self.boot = BootPlan::Error(format!(
                    "{}: the saved plan has no \"plan\" object",
                    plan_path.display()
                ));
                return;
            }
        };
        let patchbay = match Patchbay::from_object(plan, self.config.channels, &self.config.machine) {
            Ok(patchbay) => patchbay,
            Err(error) => {
                self.boot = BootPlan::Error(format!("{}: {error}", plan_path.display()));
                return;
            }
        };
        match self.start_patch_worker(patchbay, self.config.system_device.clone()) {
            Ok(summary) => self.boot = BootPlan::Armed(summary),
            Err(error) => {
                self.boot = BootPlan::Error(format!("{}: {error}", plan_path.display()));
            }
        }
    }

    /// Spawn the patch worker and store its handle, queue and per-route liveness.
    /// `system_device` names this machine's ordinary-audio source; the boot
    /// restore uses the configured one, and a `patch` command may carry its own
    /// so turning the mixer switch on does not need an engine restart.
    /// Returns the summary the caller reports in its reply.
    fn start_patch_worker(
        &mut self,
        mut patchbay: Patchbay,
        system_device: Option<String>,
    ) -> Result<PatchSummary, String> {
        // A plan that declares a handset source gets the reception mixer's call
        // monitor captured here; one that does not runs no extra `parec`. A
        // missing sink silences the node and leaves the rest of the patch up.
        let handset = attach_handset(&mut patchbay, &self.config);
        let summary = patchbay.summary().clone();
        let params = patchbay.params();
        let executable = (0..patchbay.route_count())
            .map(|route| patchbay.route_live(route))
            .collect();
        let status = Arc::new(Mutex::new(PatchStatus {
            state: State::Patching,
            frames: 0,
            xruns: 0,
            summary: summary.clone(),
            system: if crate::owns_system_mix(self.config.backend)
                && system_device.is_some()
            {
                "pending".to_string()
            } else {
                "off".to_string()
            },
            error: String::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let spawned = {
            let status = Arc::clone(&status);
            let stop = Arc::clone(&stop);
            let config = self.config.clone();
            thread::Builder::new()
                .name("jawn-audio-patch".to_string())
                .spawn(move || run_patch_worker(config, patchbay, status, stop, system_device))
        };
        match spawned {
            Ok(handle) => {
                self.patch = Some(PatchSession {
                    status,
                    stop,
                    handle: Some(handle),
                    params,
                    executable,
                    handset,
                });
                Ok(summary)
            }
            Err(error) => Err(format!("cannot start the patch thread: {error}")),
        }
    }

    /// Append `machine` and the boot-restore outcome (`plan` or `plan_error`) to
    /// a status object, without changing any key already present.
    fn add_boot(&self, line: String) -> String {
        let head = match line.strip_suffix('}') {
            Some(head) => head,
            None => return line,
        };
        match &self.boot {
            BootPlan::Armed(summary) => format!(
                "{head},\"machine\":\"{}\",\"plan\":{{{}}},{}}}",
                jawn_audio::loopback::json_escape(&self.config.machine),
                summary.json(),
                self.gateway.fragment()
            ),
            BootPlan::Error(message) => format!(
                "{head},\"machine\":\"{}\",\"plan_error\":\"{}\",{}}}",
                jawn_audio::loopback::json_escape(&self.config.machine),
                jawn_audio::loopback::json_escape(message),
                self.gateway.fragment()
            ),
        }
    }

    fn stopping(&self) -> bool {
        self.stop.load(Ordering::SeqCst)
    }

    /// Stop everything the server owns and reap the gateway's child. A `quit`
    /// and a SIGTERM reach the same place, so a signal never leaves a closed
    /// WAV unwritten, a device held, or an orphan behind. Every step takes its
    /// handle, so a second call changes nothing.
    fn shutdown(&mut self) {
        if let Some(running) = &self.current {
            running.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &self.playback {
            session.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &self.listen {
            session.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &self.patch {
            session.stop.store(true, Ordering::SeqCst);
        }
        if let Some(running) = &mut self.current {
            running.finish();
        }
        if let Some(session) = &mut self.playback {
            session.finish();
        }
        if let Some(session) = &mut self.listen {
            session.finish();
        }
        if let Some(session) = &mut self.patch {
            session.finish();
        }
        // A quit is the process's end, so the gateway's child must be reaped
        // here rather than left to init.
        self.gateway.release();
    }

    fn run(&mut self, listener: UnixListener) -> Result<(), String> {
        // Non-blocking accept, because the loop waits in `poll` and then takes
        // everything that is ready: the wait is the watcher, not a sleep.
        listener
            .set_nonblocking(true)
            .map_err(|error| format!("cannot set the socket non-blocking: {error}"))?;
        let listener_fd = listener.as_raw_fd();
        loop {
            self.gateway.tick();
            if self.stopping() {
                self.shutdown();
                return Ok(());
            }
            // The listener, and the wake pipe a signal writes to: the wait has
            // no deadline, so an idle engine still costs nothing, and a TERM
            // still gets here. The old 2 ms sleep woke 500 times a second
            // forever and kept the CPU out of its deeper idle states.
            let mut fds = [listener_fd, -1];
            let mut count = 1;
            if let Some(wake) = self.wake {
                fds[count] = wake;
                count += 1;
            }
            wait_readable(&fds[..count], self.gateway.next_tick())?;
            if self.stopping() {
                self.shutdown();
                return Ok(());
            }
            let (stream, _) = match listener.accept() {
                Ok(accepted) => accepted,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    // A readiness that accept did not consume: poll again.
                    continue;
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => {
                    return Err(format!(
                        "accept on {}: {error}",
                        self.config.socket.display()
                    ))
                }
            };
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
        let listener_fd = listener.as_raw_fd();
        let client_fd = client.stream.as_raw_fd();
        let mut scratch = [0u8; 8192];
        loop {
            self.gateway.tick();
            if self.stopping() {
                self.shutdown();
                return Ok(true);
            }
            // Both descriptors: this client's next line, and the second
            // connection that must be told the socket is taken. A pending
            // silent-bind retry bounds the wait, so a client that says nothing
            // cannot postpone the retry clock. The wake pipe is the third: a
            // signal has to reach a server that is blocked on a quiet client.
            let mut fds = [listener_fd, client_fd, -1];
            let mut count = 2;
            if let Some(wake) = self.wake {
                fds[count] = wake;
                count += 1;
            }
            wait_readable(&fds[..count], self.gateway.next_tick())?;
            if self.stopping() {
                self.shutdown();
                return Ok(true);
            }
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
                    // Poll said the client was readable; a partial line may
                    // still be all there is. Look again.
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
                        self.shutdown();
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
            "listen" => Action::Reply(self.listen(&object)),
            "patch" => Action::Reply(self.patch(&object)),
            "gateway" => Action::Reply(self.gateway_command(&object)),
            "unpatch" => Action::Reply(self.unpatch_line()),
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
            Some(Value::Str(target)) if target == "input" => self.param_input(object),
            Some(Value::Str(target)) if target == "listen" => self.param_listen(object),
            Some(Value::Str(target)) if target == "master" => self.param_master(object),
            Some(Value::Str(target)) if target == "patch" => self.param_patch(object),
            _ => error_line("\"target\" must be \"take\", \"monitor\", \"input\", \"listen\", \"master\" or \"patch\""),
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
        let parameter = match chain_parameter(name, |insert| {
            snapshot.tracks[track]
                .inserts
                .split(',')
                .any(|entry| entry == insert)
        }) {
            Ok(parameter) => parameter,
            Err(error) => return error_line(&error),
        };

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
        if ParamName::parse(name).is_none() {
            return error_line(&format!("no such parameter: {name}"));
        }
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
        let parameter = match chain_parameter(name, |insert| {
            session.strips[track]
                .inserts
                .iter()
                .any(|kind| kind.name() == insert)
        }) {
            Ok(parameter) => parameter,
            Err(error) => return error_line(&error),
        };
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

    /// The take's live-input trim: `"target":"input","name":"gain"`. It
    /// trims only the monitoring bus (the take's writers never see it), and
    /// `0` is how the page mutes live input without ending the take.
    ///
    /// Every take builds the monitoring ring, so a positive gain can also arm
    /// the live input after the take has started: the ring is empty until then,
    /// and a monitor opens on the live edge rather than on a backlog. `0` only
    /// silences; it never arms.
    fn param_input(&mut self, object: &Object) -> String {
        let name = match get(object, "name") {
            Some(Value::Str(name)) => name.as_str(),
            _ => return error_line("param needs \"name\": a parameter name"),
        };
        if name != "gain" {
            return error_line("target \"input\" only carries \"gain\"");
        }
        let value = match get(object, "value") {
            Some(Value::Num(value)) if value.is_finite() => *value as f32,
            _ => return error_line("\"value\" must be a finite number"),
        };
        // The take owns the ring and the trim from the moment it starts, so the
        // gain is addressable whether or not monitoring was on at arm time.
        let (clamped, armed, gain, remaining, master) = {
            let running = match &self.current {
                Some(running) if running.is_recording() => running,
                _ => return error_line("no live input is being monitored"),
            };
            let clamped = value.clamp(0.0, 4.0);
            running
                .input_gain
                .store(clamped.to_bits(), Ordering::Release);
            let remaining = {
                let mut status = running
                    .status
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                status.monitor_gain = clamped;
                remaining_frames(running.total_frames, status.frames)
            };
            (
                clamped,
                Arc::clone(&running.armed),
                Arc::clone(&running.input_gain),
                remaining,
                running.master.clone(),
            )
        };

        // Zero is a mute, not an arming: a page that fades the trim out must
        // not open the ring by accident.
        let armed_now = armed.load(Ordering::Acquire);
        if clamped <= 0.0 || armed_now {
            return input_line(clamped, armed_now);
        }
        if remaining == 0 {
            return error_line("the take has no time left to monitor");
        }

        // A monitor `record` built already carries the live input (with or
        // without monitor files), so arming it rebuilds nothing. A take armed
        // with monitoring off has no session and starts one here.
        let has_live_session = self
            .playback
            .as_ref()
            .map(|session| session.live)
            .unwrap_or(false);
        if !has_live_session {
            // Two outputs on one device would fail mid-block; a plain playback
            // that is still running is refused exactly as `record` refuses it.
            if self
                .playback
                .as_ref()
                .map(PlaySession::is_playing)
                .unwrap_or(false)
            {
                return error_line("a playback is already running");
            }
            // The same probe `record` runs, so a busy or unopenable output is a
            // refusal here rather than a monitor that fails a block later.
            // `armed` stays false on every refusal, so a later `param` retries.
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
            // The consumer left the take only if an earlier monitor took it;
            // then that monitor, not this call, owns the live edge.
            let consumer = match self
                .current
                .as_mut()
                .and_then(|running| running.consumer.take())
            {
                Some(consumer) => consumer,
                None => {
                    return error_line(
                        "the take's monitor has ended; the live input cannot be reattached",
                    )
                }
            };
            let status = Arc::new(Mutex::new(PlayStatus {
                state: State::Playing,
                files: 0,
                frames: 0,
                error: String::new(),
            }));
            let monitor_stop = Arc::new(AtomicBool::new(false));
            let monitor_params = Arc::new(ParamQueue::new());
            let spawned = {
                let status = Arc::clone(&status);
                let stop = Arc::clone(&monitor_stop);
                let params = Arc::clone(&monitor_params);
                let config = self.config.clone();
                let system_device = self.config.system_device.clone();
                thread::Builder::new()
                    .name("jawn-audio-monitor".to_string())
                    .spawn(move || {
                        run_playback(
                            config,
                            Vec::new(),
                            0,
                            status,
                            stop,
                            Some(params),
                            master,
                            Some((consumer, gain)),
                            Some(remaining),
                            system_device,
                        )
                    })
            };
            match spawned {
                Ok(handle) => {
                    // Whatever finished session `status` was still reporting is
                    // a status line now; the monitor replaces it.
                    if let Some(mut previous) = self.playback.take() {
                        previous.finish();
                    }
                    self.playback = Some(PlaySession {
                        status,
                        stop: monitor_stop,
                        handle: Some(handle),
                        strips: Vec::new(),
                        params: Some(monitor_params),
                        align: None,
                        live: true,
                    });
                }
                Err(error) => {
                    return error_line(&format!("cannot start the monitor thread: {error}"))
                }
            }
        }
        armed.store(true, Ordering::Release);
        if let Some(running) = &self.current {
            let mut status = running
                .status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            status.monitor_input = true;
        }
        input_line(clamped, true)
    }


    /// The same knobs, addressed to the listen strip: `"target":"listen"`.
    /// One strip, so `track` is not part of the contract; a name the strip's
    /// chain does not have is refused exactly as it is for a take.
    fn param_listen(&mut self, object: &Object) -> String {
        let name = match get(object, "name") {
            Some(Value::Str(name)) => name.as_str(),
            _ => return error_line("param needs \"name\": a parameter name"),
        };
        let value = match get(object, "value") {
            Some(Value::Num(value)) if value.is_finite() => *value as f32,
            _ => return error_line("\"value\" must be a finite number"),
        };
        let session = match &self.listen {
            Some(session) if session.is_listening() => session,
            _ => return error_line("no listen is running"),
        };
        let parameter = match chain_parameter(name, |insert| {
            session
                .snapshot()
                .inserts
                .split(',')
                .any(|entry| entry == insert)
        }) {
            Ok(parameter) => parameter,
            Err(error) => return error_line(&error),
        };
        if !session.params.push(0, parameter, value) {
            return error_line("the parameter queue is full; try again next block");
        }
        let mut status = session
            .status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        match parameter {
            ParamName::Gain => status.gain = Channel::clamp_gain(value),
            ParamName::Pan => status.pan = Channel::clamp_pan(value),
            _ => {}
        }
        format!(
            "{{\"ok\":true,\"target\":\"listen\",\"name\":\"{}\"}}",
            jawn_audio::loopback::json_escape(name)
        )
    }

    /// One master-rack knob: `{"cmd":"param","target":"master",
    /// "name":"master_comp.thresh","value":-20}`. The rack is not a track, so
    /// the address carries no `track`; the queue's master bit routes it to the
    /// master slots at the next block.
    ///
    /// The name must be a `master_*` prefix for one of the five effects the
    /// rack holds, and a control that effect owns (or `.bypass` for the
    /// footswitch). The rack is fixed, so this is the whole "is it in the
    /// chain" check; a name for a track insert is refused rather than quietly
    /// aimed at the bus.
    ///
    /// The rack itself is armed by `record` from the names the page sent with
    /// the take. An effect switched on after the take started has no slot in
    /// that playback: its param is queued and ignored, and the next take is
    /// where it is heard. The help topic says so; nothing here pretends to add
    /// a slot to a running bus.
    fn param_master(&mut self, object: &Object) -> String {
        let name = match get(object, "name") {
            Some(Value::Str(name)) => name.as_str(),
            _ => return error_line("param needs \"name\": a parameter name"),
        };
        let value = match get(object, "value") {
            Some(Value::Num(value)) if value.is_finite() => *value as f32,
            _ => return error_line("\"value\" must be a finite number"),
        };
        let parameter = match ParamName::parse(name) {
            Some(parameter) if parameter.master() && parameter.master_capable() => parameter,
            _ => return error_line(&format!("no such parameter: {name}")),
        };

        // The master is the bus the monitor plays through, so a live monitor's
        // queue comes first: a take's own mixer records each strip before the
        // bus and never runs `mix`. A take without a monitor falls back to its
        // queue, where the rack is armed but only the next monitor hears it.
        let mut queue = None;
        if let Some(session) = &self.playback {
            if session.is_playing() {
                queue = session.params.as_ref().map(Arc::clone);
            }
        }
        if queue.is_none() {
            if let Some(running) = &self.current {
                if running.is_recording() {
                    queue = Some(Arc::clone(&running.params));
                }
            }
        }
        if queue.is_none() {
            if let Some(session) = &self.listen {
                if session.is_listening() {
                    queue = Some(Arc::clone(&session.params));
                }
            }
        }
        let queue = match queue {
            Some(queue) => queue,
            None => return error_line("no audio session is running"),
        };
        if !queue.push_master(parameter, value) {
            return error_line("the parameter queue is full; try again next block");
        }
        format!(
            "{{\"ok\":true,\"target\":\"master\",\"name\":\"{}\"}}",
            jawn_audio::loopback::json_escape(name)
        )
    }

    /// The same two knobs, addressed to a patch route: `"target":"patch"`.
    /// `route` is the 0-based index in the plan's `routes` array; only gain and
    /// pan are live, a muted route is refused, and the change is queued for the
    /// next block (see [`ParamQueue`]).
    fn param_patch(&mut self, object: &Object) -> String {
        let route = match get(object, "route") {
            Some(Value::Num(value))
                if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 =>
            {
                *value as usize
            }
            _ => return error_line("param needs \"route\": a 0-based route number"),
        };
        let name = match get(object, "name") {
            Some(Value::Str(name)) => name.as_str(),
            _ => return error_line("param needs \"name\": a parameter name"),
        };
        let value = match get(object, "value") {
            Some(Value::Num(value)) if value.is_finite() => *value as f32,
            _ => return error_line("\"value\" must be a finite number"),
        };
        let session = match &self.patch {
            Some(session) if session.is_patching() => session,
            _ => return error_line("no patch is running"),
        };
        if route >= session.executable.len() {
            return error_line(&format!(
                "no route {route} (the plan has {})",
                session.executable.len()
            ));
        }
        if !session.executable[route] {
            return error_line(&format!("route {route} is muted"));
        }
        let parameter = match ParamName::parse(name) {
            Some(ParamName::Gain) => ParamName::Gain,
            Some(ParamName::Pan) => ParamName::Pan,
            _ => return error_line(&format!("no such parameter: {name}")),
        };
        if !session.params.push(route, parameter, value) {
            return error_line("the parameter queue is full; try again next block");
        }
        format!(
            "{{\"ok\":true,\"target\":\"patch\",\"route\":{},\"name\":\"{}\"}}",
            route,
            jawn_audio::loopback::json_escape(name)
        )
    }

    /// `{"cmd":"listen","channel":1,"gain":0.8,"pan":0,"inserts":["tone"]}`:
    /// monitor one input through one strip until `stop`.
    ///
    /// The strip lives on the worker thread (an insert is not `Send`), so the
    /// reply means "running"; `status` reports the frames it has rendered and
    /// the gain, pan and inserts it was armed with. A `param` moves those
    /// values at the next block, through the same [`ParamQueue`] a take uses.
    fn listen(&mut self, object: &Object) -> String {
        // One capture stream, one owner: a take cannot also feed the monitor
        // yet. Sharing one capture between listen and record is the next step.
        if let Some(running) = &self.current {
            if running.is_recording() {
                return error_line(
                    "a take is recording; one capture stream cannot record and listen at once. Sharing one capture between listen and record is the next step",
                );
            }
        }
        if let Some(session) = &self.listen {
            if session.is_listening() {
                return error_line("listen is already running");
            }
        }
        if let Some(session) = &self.patch {
            if session.is_patching() {
                return error_line(
                    "the patchbay is using the capture and the outputs; stop the patch before listening",
                );
            }
        }
        if let Some(session) = &self.playback {
            if session.is_playing() {
                return error_line(
                    "a playback is already using the outputs; stop it before listening",
                );
            }
        }

        let channel = match get(object, "channel") {
            None | Some(Value::Null) => 0,
            Some(Value::Num(value))
                if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 =>
            {
                *value as usize
            }
            _ => return error_line("\"channel\" must be a whole, non-negative input number"),
        };
        if channel >= self.config.channels {
            return error_line(&format!(
                "listen channel {channel} is outside the {}-channel device: restart the engine with a larger --channels",
                self.config.channels
            ));
        }
        let gain = match get(object, "gain") {
            None | Some(Value::Null) => 1.0,
            Some(Value::Num(value)) if value.is_finite() => Channel::clamp_gain(*value as f32),
            _ => return error_line("\"gain\" must be a finite number"),
        };
        let pan = match get(object, "pan") {
            None | Some(Value::Null) => 0.0,
            Some(Value::Num(value)) if value.is_finite() => Channel::clamp_pan(*value as f32),
            _ => return error_line("\"pan\" must be a finite number"),
        };
        let inserts = match get(object, "inserts") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Arr(names)) => {
                let mut inserts = Vec::with_capacity(names.len());
                for name in names {
                    let word = match name {
                        Value::Str(word) => word.as_str(),
                        _ => return error_line("\"inserts\" must hold insert names"),
                    };
                    match InsertKind::parse(word) {
                        Some(kind) => inserts.push(kind),
                        None => return error_line(&format!("no such insert: {word}")),
                    }
                }
                inserts
            }
            _ => return error_line("\"inserts\" must be an array of insert names"),
        };
        if let Err(error) = crate::listen_support(self.config.backend) {
            return error_line(&error);
        }

        // Join a finished listener before replacing it, so a sequence of
        // listens does not leave detached threads behind.
        if let Some(mut previous) = self.listen.take() {
            previous.finish();
        }

        let plan = ListenPlan {
            channel,
            gain,
            pan,
            inserts,
        };
        let inserts_text = plan.insert_list();
        let status = Arc::new(Mutex::new(ListenStatus {
            state: State::Listening,
            channel,
            frames: 0,
            gain,
            pan,
            inserts: inserts_text,
            error: String::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        // The queue exists before the worker does: the strip is built on the
        // listen thread, but `param` must be able to push as soon as this
        // command answers.
        let params = Arc::new(ParamQueue::new());
        let spawned = {
            let status = Arc::clone(&status);
            let stop = Arc::clone(&stop);
            let params = Arc::clone(&params);
            let config = self.config.clone();
            thread::Builder::new()
                .name("jawn-audio-listen".to_string())
                .spawn(move || run_listen_worker(config, plan, status, stop, params))
        };
        match spawned {
            Ok(handle) => {
                self.listen = Some(ListenSession {
                    status,
                    stop,
                    handle: Some(handle),
                    params,
                });
                format!("{{\"ok\":true,\"state\":\"listening\",\"channel\":{channel}}}")
            }
            Err(error) => error_line(&format!("cannot start the listen thread: {error}")),
        }
    }

    /// `{"cmd":"gateway","action":"bind","call_in":"jawn_call_in"}`:
    /// bind the gateway's inbound port to `<call_in>.monitor`, and `release` or
    /// `status` it.
    ///
    /// This rides the socket, not the saved plan, because the Sound/Studio UI
    /// rewrites the plan on every save and a `gateway` section would vanish
    /// under a person's edits. The gateway is machine-local and lives only
    /// while a call is up, which is exactly a transient command.
    ///
    /// Binding is idempotent: a second `bind` keeps the first capture. A sink
    /// the machine cannot capture answers `ok` with `call_in:"silent"` — a
    /// missing sink must not fail the engine, the same rule the patchbay
    /// follows.
    fn gateway_command(&mut self, object: &Object) -> String {
        let action = match get(object, "action") {
            Some(Value::Str(action)) => action.as_str(),
            _ => {
                return error_line(
                    "\"gateway\" needs \"action\": \"bind\", \"release\" or \"status\"",
                )
            }
        };
        match action {
            "bind" => self.gateway_bind(object),
            "release" => {
                self.gateway.release();
                format!("{{\"ok\":true,{}}}", self.gateway.fragment())
            }
            "status" => format!("{{\"ok\":true,{}}}", self.gateway.fragment()),
            other => error_line(&format!("no such gateway action: {other}")),
        }
    }

    fn gateway_bind(&mut self, object: &Object) -> String {
        let sink = match get(object, "call_in") {
            Some(Value::Str(name)) if !name.is_empty() => name.clone(),
            _ => return error_line("gateway bind needs \"call_in\": a sink name"),
        };
        let prompt_sink = match get(object, "prompt") {
            Some(Value::Str(name)) if !name.is_empty() => name.clone(),
            _ => GATEWAY_PROMPT_SINK.to_string(),
        };
        let volume = match parse_prompt_volume(object) {
            Ok(volume) => volume,
            Err(error) => return error_line(&error),
        };
        // One call at a time: a bind while the capture runs is a no-op and keeps
        // the first capture, its sink and its counters.
        if self.gateway.capture.is_some() {
            return format!("{{\"ok\":true,{}}}", self.gateway.fragment());
        }
        let state_dir = state_dir(&self.config);
        // A silent bind may be retried by a later bind; the ports it already
        // made are still this call's, so keep them rather than removing a
        // worker that may already be feeding the helper.
        if self.gateway.paths.is_none() {
            if let Err(error) = self.gateway.open_ports(&state_dir, &prompt_sink, volume) {
                eprintln!("jawn-audio: gateway: {error}");
                return error_line(&error);
            }
        }
        self.gateway.call_in = Some(sink.clone());
        let paths = self.gateway.paths.clone().expect("open_ports made them");
        if self.gateway.try_capture(&sink, &paths) {
            self.gateway.retry = None;
        } else {
            let now = Instant::now();
            self.gateway.retry = Some(BindRetry {
                sink,
                next: now + GATEWAY_RETRY,
                deadline: now + GATEWAY_RETRY_FOR,
            });
        }
        format!("{{\"ok\":true,{}}}", self.gateway.fragment())
    }

    /// `{"cmd":"patch","plan":{...}}`: run the house patchbay from the saved
    /// plan until `stop`.
    ///
    /// The patchbay owns both the capture and the outputs, so it refuses while a
    /// take records, a playback plays or a listen monitors. A second `patch`
    /// replaces the first: the old graph is joined before the new one opens the
    /// device, so the reply describes a graph that is actually running.
    fn patch(&mut self, object: &Object) -> String {
        if let Some(running) = &self.current {
            if running.is_recording() {
                return error_line(
                    "a take is recording; the patchbay needs the capture and the outputs. Stop the take before patching",
                );
            }
        }
        if let Some(session) = &self.listen {
            if session.is_listening() {
                return error_line(
                    "listen is monitoring the inputs; the patchbay needs the capture and the outputs. Stop the listen before patching",
                );
            }
        }
        if let Some(session) = &self.playback {
            if session.is_playing() {
                return error_line(
                    "a playback is using the outputs; the patchbay needs them. Stop the playback before patching",
                );
            }
        }

        let plan = match get(object, "plan") {
            Some(Value::Obj(plan)) => plan,
            _ => return error_line("patch needs \"plan\": the saved sources, buses, sinks and routes"),
        };
        let patchbay = match Patchbay::from_object(plan, self.config.channels, &self.config.machine)
        {
            Ok(patchbay) => patchbay,
            Err(error) => return error_line(&error),
        };
        if let Err(error) = crate::listen_support(self.config.backend) {
            return error_line(&error);
        }

        // The manager creates the virtual sink and names its monitor here. An
        // older caller sends no field and keeps the engine's startup choice; an
        // explicit empty string means "no system mix for this patch".
        let system_device = match get(object, "system_device") {
            None | Some(Value::Null) => self.config.system_device.clone(),
            Some(Value::Str(name)) if name.is_empty() => None,
            Some(Value::Str(name)) => Some(name.clone()),
            Some(_) => {
                return error_line("\"system_device\" must be one source name")
            }
        };

        // Join a finished patch before replacing it, so a sequence of plans
        // does not leave detached threads behind.
        if let Some(mut previous) = self.patch.take() {
            previous.finish();
        }

        let summary = match self.start_patch_worker(patchbay, system_device) {
            Ok(summary) => summary,
            Err(error) => return error_line(&error),
        };
        format!(
            "{{\"ok\":true,\"state\":\"patching\",{},{}}}",
            summary.json(),
            self.gateway.fragment()
        )
    }

    fn record(&mut self, object: &Object) -> String {
        // One capture stream, one owner: a take cannot also feed the monitor
        // yet. Sharing one capture between listen and record is the next step.
        if let Some(session) = &self.listen {
            if session.is_listening() {
                return error_line(
                    "listen is monitoring the inputs; a take cannot share the capture stream yet. Sharing one capture between listen and record is the next step",
                );
            }
        }
        if let Some(session) = &self.patch {
            if session.is_patching() {
                return error_line(
                    "the patchbay is using the capture and the outputs; stop the patch before recording. Sharing one capture between a patch and a take is the next step",
                );
            }
        }
        // The monitoring bus, if this take is an overdub. Parsed first so a
        // malformed list is a refusal whether or not a take is already running.
        let monitor = match parse_monitor(get(object, "monitor")) {
            Ok(monitor) => monitor,
            Err(error) => return error_line(&error),
        };
        // The live-input monitoring switch and trim. Parsed before any file or
        // thread exists, and valid with no monitor files at all.
        let monitor_input = match get(object, "monitor_input") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(value)) => *value,
            _ => return error_line("\"monitor_input\" must be true or false"),
        };
        let monitor_gain = match get(object, "monitor_gain") {
            None | Some(Value::Null) => 1.0,
            Some(Value::Num(value)) if value.is_finite() => (*value as f32).clamp(0.0, 4.0),
            _ => return error_line("\"monitor_gain\" must be a finite number"),
        };
        // One playback at a time: a take over the monitor it names is the
        // point, but a second monitor cannot join a playback already running.
        if !monitor.is_empty() || monitor_input {
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
        let master = match parse_master(get(object, "master")) {
            Ok(master) => master,
            Err(error) => return error_line(&error),
        };
        let tracks = plans.len();
        if tracks > self.config.channels {
            return error_line(&format!(
                "a {tracks}-track take needs at least {tracks} input channels, but the engine has {} channel(s): restart it with a larger --channels",
                self.config.channels
            ));
        }
        for (index, plan) in plans.iter().enumerate() {
            let claimed = plan.input + plan.channels;
            if claimed > self.config.channels {
                // A stereo track claims both channels, so the refusal names the
                // pair rather than pretending it asked for one.
                if plan.channels == 2 {
                    return error_line(&format!(
                        "track {} records inputs {}..{}, but the engine has only {} channel(s)",
                        index + 1,
                        plan.input,
                        plan.input + 1,
                        self.config.channels
                    ));
                }
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
        let monitor_files = monitor_tracks.len();
        if !monitor_tracks.is_empty() || monitor_input {
            // Live-only monitoring is still a monitor: it needs a backend that
            // can play and a free output, exactly as a monitor file does.
            if let Err(error) = crate::play_support(self.config.backend) {
                return error_line(&error);
            }
            if !monitor_tracks.is_empty() {
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
            monitor_input,
            monitor_gain,
            monitor_dropped: 0,
            error: String::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        // The queue exists before the worker does: the take thread builds the
        // strips (they need not be `Send`), but the socket must be able to push
        // to them as soon as `record` answers.
        let params = Arc::new(ParamQueue::new());

        // The live-input ring: every take builds one, whether or not it is
        // monitoring, so a monitor armed mid-take never has to restart the
        // take. The capture thread pushes only while `armed`, which keeps the
        // ring empty until monitoring begins; the trim is always addressable.
        let (input_producer, input_consumer) = MonitorBus::new(MONITOR_RING_FRAMES);
        let armed = Arc::new(AtomicBool::new(monitor_input));
        let input_gain = Arc::new(AtomicU32::new(monitor_gain.to_bits()));
        // The socket keeps the read side unless a monitor takes it here.
        let mut parked_consumer = Some(input_consumer);

        // The monitoring bus: its own thread and its own device handle, fed by
        // `Playback` and never by the capture loop. Started before the take so
        // a player that cannot start is still a refusal rather than a take that
        // records without the monitor the caller asked for. A live-only monitor
        // has no files but still runs for the take's length.
        let mut monitor_session = if monitor_tracks.is_empty() && !monitor_input {
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
            let monitor_master = master.clone();
            // Even a file monitor with `monitor_input` off carries the live
            // input: arming later is one atomic store, not a monitor rebuild.
            let live = parked_consumer
                .take()
                .map(|consumer| (consumer, Arc::clone(&input_gain)));
            let live_length = if monitor_input { Some(frames) } else { None };
            let system_device = self.config.system_device.clone();
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
                            monitor_master,
                            live,
                            live_length,
                            system_device,
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
                    live: true,
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

        // The take thread owns `master`; the socket keeps a copy so a monitor
        // armed mid-take arms the same mastering chain.
        let master_for_monitor = master.clone();
        let spawned = {
            let shared = Arc::clone(&shared);
            let stop = Arc::clone(&stop);
            let params = Arc::clone(&params);
            let config = self.config.clone();
            let plans = plans.clone();
            let armed = Arc::clone(&armed);
            thread::Builder::new()
                .name("jawn-audio-take".to_string())
                .spawn(move || {
                    run_take(
                        config,
                        seconds,
                        disks,
                        plans,
                        shared,
                        stop,
                        params,
                        master,
                        Some(input_producer),
                        armed,
                    )
                })
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
            input_gain,
            armed,
            total_frames: frames,
            consumer: parked_consumer,
            master: master_for_monitor,
        });
        let monitor_part = if monitor_files == 0 && !monitor_input {
            String::new()
        } else {
            format!(
                ",\"playing\":{},\"monitor_frames\":0{}",
                monitor_files,
                jawn_audio::playback::monitor_json(&monitor)
            )
        };
        format!(
            "{{\"ok\":true,\"take\":{take},\"state\":\"recording\",\"channels\":{channels},\"start_sample\":{start_at}{}{monitor_part},\"monitor_input\":{monitor_input},\"monitor_gain\":{monitor_gain},\"monitor_dropped\":0{}}}",
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
        if let Some(session) = &self.listen {
            if session.is_listening() {
                return error_line(
                    "listen is using the capture and playback streams; stop it before starting a playback",
                );
            }
        }
        if let Some(session) = &self.patch {
            if session.is_patching() {
                return error_line(
                    "the patchbay is using the outputs; stop the patch before starting a playback",
                );
            }
        }
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
                .spawn(move || {
                    run_playback(
                        config,
                        tracks,
                        start_at,
                        status,
                        stop,
                        None,
                        Vec::new(),
                        None,
                        None,
                        None,
                    )
                })
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
            live: false,
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
        } else if let Some(session) = self
            .patch
            .as_ref()
            .filter(|session| session.is_patching())
        {
            session.line()
        } else if let Some(session) = self
            .listen
            .as_ref()
            .filter(|session| session.is_listening())
        {
            session.line()
        } else if let Some(session) = &self.playback {
            session.line()
        } else if let Some(running) = &self.current {
            running.line()
        } else if let Some(session) = &self.patch {
            session.line()
        } else if let Some(session) = &self.listen {
            session.line()
        } else {
            idle_line()
        };
        // The configuration describes the process, not the take, so every
        // state carries it: a supervisor compares these with its own flags to
        // tell whether the engine it adopted is the one it asked for. The
        // boot restore adds `machine` and `plan`/`plan_error` on top.
        self.add_boot(add_config(line, &self.config))
    }

    /// `{"cmd":"unpatch"}`: end the patchbay and nothing else.
    ///
    /// `stop` is the transport's one stop and joins every role; the mixer
    /// switch's off is narrower, because a take or a listen is someone else's
    /// work and turning the mixer off must not end it.
    fn unpatch_line(&mut self) -> String {
        let was_patching = self
            .patch
            .as_ref()
            .map(PatchSession::is_patching)
            .unwrap_or(false);
        if let Some(session) = &self.patch {
            session.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &mut self.patch {
            session.finish();
        }
        if was_patching {
            if let Some(session) = &self.patch {
                return session.line();
            }
        }
        idle_line()
    }

    fn stop_line(&mut self) -> String {
        let was_recording = self
            .current
            .as_ref()
            .map(Running::is_recording)
            .unwrap_or(false);
        let was_listening = self
            .listen
            .as_ref()
            .map(ListenSession::is_listening)
            .unwrap_or(false);
        let was_patching = self
            .patch
            .as_ref()
            .map(PatchSession::is_patching)
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
        if let Some(session) = &self.listen {
            session.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &self.patch {
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
        if let Some(session) = &mut self.listen {
            session.finish();
        }
        if let Some(session) = &mut self.patch {
            session.finish();
        }
        if was_patching {
            if let Some(session) = &self.patch {
                return session.line();
            }
        }
        if was_listening {
            if let Some(session) = &self.listen {
                return session.line();
            }
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
            None => match &self.patch {
                Some(session) => session.line(),
                None => match &self.listen {
                    Some(session) => session.line(),
                    None => idle_line(),
                },
            },
        }
    }
}

fn idle_line() -> String {
	"{\"ok\":true,\"take\":0,\"state\":\"idle\"}".to_string()
}

/// Append the configuration the engine actually serves with to a status
/// object. The existing keys keep their order and meaning; these seven are
/// added at the end, so every state answers the same question. `pid` is the
/// engine process itself, which lets a supervisor refuse to displace it even
/// when the manager's own client holds the socket. A recording line
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
        "{head},\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"period\":{},\"buffer\":{},\"device_channels\":{},\"pid\":{}}}",
        config.backend.name(),
        jawn_audio::loopback::json_escape(&config.device),
        config.rate,
        config.period,
        config.buffer,
        config.channels,
        std::process::id()
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
                thread::sleep(SEND_BACKOFF);
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
    Listening,
    Patching,
    Done,
    Failed,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Recording => "recording",
            State::Playing => "playing",
            State::Listening => "listening",
            State::Patching => "patching",
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
    /// The device channels this track claims: `1` mono, `2` stereo.
    channels: usize,
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
            channels: 1,
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

/// The take's master rack: an array of `master_*` names, in any order. The
/// engine builds the effects the page switched on in [`MASTER_ORDER`], not in
/// the order they arrived, so the bus is the house's chain whatever the page
/// happens to list. A name the rack does not hold, or a duplicate, is refused
/// before any file or thread exists.
fn parse_master(value: Option<&Value>) -> Result<Vec<InsertKind>, String> {
    let names = match value {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Arr(names)) => names,
        _ => return Err("\"master\" must be an array of master insert names".to_string()),
    };
    let mut wanted = [false; MASTER_ORDER.len()];
    for name in names {
        let word = match name {
            Value::Str(word) => word.as_str(),
            _ => return Err("\"master\" must hold master insert names".to_string()),
        };
        let kind = InsertKind::parse(word)
            .filter(|kind| kind.master_prefix().is_some())
            .ok_or_else(|| format!("no such master insert: {word}"))?;
        let slot = MASTER_ORDER
            .iter()
            .position(|candidate| *candidate == kind)
            .expect("MASTER_ORDER holds every master kind");
        if wanted[slot] {
            return Err(format!("duplicate master insert: {word}"));
        }
        wanted[slot] = true;
    }
    Ok(MASTER_ORDER
        .iter()
        .zip(wanted)
        .filter_map(|(kind, on)| if on { Some(*kind) } else { None })
        .collect())
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
                    "track {} must be an object with input, channels, gain, pan and inserts",
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
    let channels = match get(fields, "channels") {
        None | Some(Value::Null) => 1,
        Some(Value::Num(value)) if value.is_finite() && (*value == 1.0 || *value == 2.0) => {
            *value as usize
        }
        _ => {
            return Err(format!(
                "track {} \"channels\" must be 1 (mono) or 2 (stereo)",
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
        channels,
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
    /// Whether this take is pushing its live input to the monitor right now,
    /// the gain it is using, and frames the monitoring ring discarded because
    /// the monitor was late. All three are measurements, never errors.
    monitor_input: bool,
    monitor_gain: f32,
    monitor_dropped: u64,
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

/// The `param` reply for the live trim: the gain just stored and whether the
/// take is pushing the live edge. The page reads `monitor_input` instead of
/// asking `status` a second time, so a raise that arms the input is visible in
/// the answer itself.
fn input_line(gain: f32, monitoring: bool) -> String {
    format!(
        "{{\"ok\":true,\"target\":\"input\",\"name\":\"gain\",\"gain\":{gain},\"monitor_input\":{monitoring}}}"
    )
}

/// The frames a take has left to capture: its whole length less what the
/// capture loop has already handed to disk. A monitor armed with none left
/// would open a ring nobody can drain.
fn remaining_frames(total_frames: u64, captured: u64) -> u64 {
    total_frames.saturating_sub(captured)
}

/// The server's handle to one take's worker thread.
struct Running {
    status: Arc<Mutex<Status>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    /// The same ring the take's mixer drains. Kept so `param` can push after
    /// the worker owns the strips.
    params: Arc<ParamQueue>,
    /// The live-input trim. Every take has one, because every take builds the
    /// monitoring ring; `param target=input` moves it and `status` mirrors it.
    input_gain: Arc<AtomicU32>,
    /// Whether the capture thread is pushing the take's live input into the
    /// ring. `false` at arm time when `monitor_input` was off, and `param`
    /// raises it mid-take to start monitoring without restarting the take.
    armed: Arc<AtomicBool>,
    /// The take's whole length in frames, which is where a mid-take monitor's
    /// remaining length is measured from.
    total_frames: u64,
    /// The ring's read side, parked here until a mid-take monitor takes it.
    /// `record` hands it to a monitor it starts, and `None` then means that
    /// monitor owns the live edge for the rest of the take.
    consumer: Option<Consumer>,
    /// The take's master rack, so a monitor armed mid-take runs the same
    /// mastering chain as one `record` started.
    master: Vec<InsertKind>,
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
            "{{\"ok\":true,\"take\":{},\"state\":\"{}\",\"path\":\"{}\",\"frames\":{},\"dropped\":{},\"channels\":{},\"start_sample\":{},\"xruns\":{}{}{}{},\"gain\":{},\"pan\":{},\"inserts\":\"{}\",\"monitor_input\":{},\"monitor_gain\":{},\"monitor_dropped\":{},\"error\":\"{}\"}}",
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
            status.monitor_input,
            status.monitor_gain,
            status.monitor_dropped,
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
    /// monitor was placed after the take ends. `None` for a plain playback and
    /// for a monitor armed mid-take, which has no measured offset.
    align: Option<Alignment>,
    /// Whether this session carries a take's live input. `param` uses it to
    /// tell its own monitor from a plain `play`, which cannot take the ring.
    live: bool,
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


/// What `status` reads for a listen: its state, the frames it has rendered and
/// the strip it was armed with.
#[derive(Clone)]
struct ListenStatus {
    state: State,
    channel: usize,
    frames: u64,
    gain: f32,
    pan: f32,
    inserts: String,
    error: String,
}

/// The server's handle to one listen's worker thread.
struct ListenSession {
    status: Arc<Mutex<ListenStatus>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    /// The control ring the strip drains at the top of every block.
    params: Arc<ParamQueue>,
}

impl ListenSession {
    fn snapshot(&self) -> ListenStatus {
        self.status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn is_listening(&self) -> bool {
        self.snapshot().state == State::Listening
    }

    /// Signal the worker and wait for it. When this returns the device loops
    /// have stopped and the frames are final.
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
            if status.state == State::Listening {
                status.state = State::Failed;
                status.error = "the listen thread panicked".to_string();
            }
        }
    }

    fn line(&self) -> String {
        let status = self.snapshot();
        let ok = status.state != State::Failed;
        format!(
            "{{\"ok\":{},\"state\":\"{}\",\"channel\":{},\"frames\":{},\"gain\":{},\"pan\":{},\"inserts\":\"{}\",\"error\":\"{}\"}}",
            ok,
            status.state.name(),
            status.channel,
            status.frames,
            status.gain,
            status.pan,
            jawn_audio::loopback::json_escape(&status.inserts),
            jawn_audio::loopback::json_escape(&status.error)
        )
    }
}

/// The listener's worker: build the strip on this thread (an insert is not
/// `Send`), then read and write until `stop` or a device error.
fn run_listen_worker(
    config: Config,
    plan: ListenPlan,
    status: Arc<Mutex<ListenStatus>>,
    stop: Arc<AtomicBool>,
    params: Arc<ParamQueue>,
) {
    let mut strip = ListenStrip::new(
        plan.channel,
        plan.gain,
        plan.pan,
        &plan.inserts,
        Some(Arc::clone(&params)),
    );
    let outcome = match config.backend {
        BackendKind::Null => listen_null(&mut strip, &config, &status, &stop),
        BackendKind::Alsa | BackendKind::PipeWire => {
            listen_hardware(&config, &mut strip, &status, &stop)
        }
        BackendKind::Jack => Err(crate::listen_support_message()),
    };
    let was_stopped = stop.load(Ordering::SeqCst);
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match outcome {
        Ok(frames) => {
            current.frames = frames;
            if current.state == State::Listening {
                current.state = State::Done;
            }
        }
        // A stop is the caller's choice, not a failure.
        Err(_) if was_stopped => current.state = State::Done,
        Err(error) => {
            current.state = State::Failed;
            current.error = error;
        }
    }
}

/// The null listen: silence through the same strip, as fast as the CPU allows.
/// `progress` keeps `status`'s frame count moving while the client watches.
fn listen_null(
    strip: &mut ListenStrip,
    config: &Config,
    status: &Arc<Mutex<ListenStatus>>,
    stop: &AtomicBool,
) -> Result<u64, String> {
    let run = listen::run_null(
        strip,
        config.rate,
        config.period,
        config.channels,
        None,
        None,
        stop,
        |frames| {
            let mut current = status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            current.frames = frames;
        },
    )?;
    Ok(run.frames)
}

/// What `status` reads for the patchbay: its state, the frames it has rendered
/// and the plan's shape (including the nodes this machine cannot bind).
#[derive(Clone)]
struct PatchStatus {
    state: State,
    frames: u64,
    xruns: usize,
    summary: PatchSummary,
    /// The system mix: `pending` before the worker opens it, `capturing` while
    /// it runs, `unavailable` when this machine cannot capture it (no parec or
    /// no source), and `off` when the patch was not asked for one. The
    /// supervisor reads this before it keeps the virtual sink as the default.
    /// It is the line's only `system` key: the plan's own shape is
    /// `system_route` (`routed`/`fallback`), so a decoder that keeps the last
    /// duplicate cannot mistake the route for the capture state.
    system: String,
    error: String,
}

/// The server's handle to one patchbay's worker thread.
struct PatchSession {
    status: Arc<Mutex<PatchStatus>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    /// The shared control ring the socket pushes `param` changes to; the
    /// patchbay drains it at the top of each block.
    params: Arc<ParamQueue>,
    /// One flag per route (plan order): whether it has a live strip and can
    /// take a gain/pan change.
    executable: Vec<bool>,
    /// The reception mixer's screened-call capture, when the plan declared a
    /// `handset` source. Stopped and joined with the patch.
    handset: Option<crate::system_capture::SystemCapture>,
}

impl PatchSession {
    fn snapshot(&self) -> PatchStatus {
        self.status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn is_patching(&self) -> bool {
        self.snapshot().state == State::Patching
    }

    /// Signal the worker and wait for it. When this returns the device loop
    /// has stopped and the frame count is final.
    fn finish(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let joined = match self.handle.take() {
            Some(handle) => handle.join(),
            None => Ok(()),
        };
        if let Some(mut handset) = self.handset.take() {
            handset.stop();
        }
        if joined.is_err() {
            let mut status = self
                .status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if status.state == State::Patching {
                status.state = State::Failed;
                status.error = "the patch thread panicked".to_string();
            }
        }
    }

    fn line(&self) -> String {
        patch_line(&self.snapshot())
    }
}

/// The status line for one patch snapshot: the capture state, the frame count,
/// the plan's shape and the error. Free rather than a method so a test can
/// build a line without a worker thread.
fn patch_line(status: &PatchStatus) -> String {
    let ok = status.state != State::Failed;
    format!(
        "{{\"ok\":{},\"state\":\"{}\",\"frames\":{},\"xruns\":{},\"system\":\"{}\",{},\"error\":\"{}\"}}",
        ok,
        status.state.name(),
        status.frames,
        status.xruns,
        jawn_audio::loopback::json_escape(&status.system),
        status.summary.json(),
        jawn_audio::loopback::json_escape(&status.error)
    )
}

/// The patchbay's worker: compile happened on the control thread, so this only
/// opens the device and runs blocks until `stop` or a device error.
fn run_patch_worker(
    config: Config,
    mut patchbay: Patchbay,
    status: Arc<Mutex<PatchStatus>>,
    stop: Arc<AtomicBool>,
    system_device: Option<String>,
) {
    let outcome: Result<(u64, usize), String> = match config.backend {
        BackendKind::Null => patch_null(&mut patchbay, &config, &status, &stop),
        BackendKind::Alsa | BackendKind::PipeWire => {
            patch_hardware(&config, patchbay, &status, &stop, system_device)
        }
        BackendKind::Jack => Err(crate::listen_support_message()),
    };
    let was_stopped = stop.load(Ordering::SeqCst);
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    match outcome {
        Ok((frames, xruns)) => {
            current.frames = frames;
            current.xruns = xruns;
            if current.state == State::Patching {
                current.state = State::Done;
            }
        }
        // A stop is the caller's choice, not a failure.
        Err(_) if was_stopped => current.state = State::Done,
        Err(error) => {
            current.state = State::Failed;
            current.error = error;
        }
    }
}

fn patch_null(
    patchbay: &mut Patchbay,
    config: &Config,
    status: &Arc<Mutex<PatchStatus>>,
    stop: &AtomicBool,
) -> Result<(u64, usize), String> {
    let frames = crate::patchbay::run_null(
        patchbay,
        config.rate,
        config.period,
        config.channels,
        None,
        None,
        stop,
        |frames| {
            let mut current = status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            current.frames = frames;
        },
    )?;
    Ok((frames, 0))
}

#[cfg(feature = "alsa")]
struct SocketPatchSink<'a> {
    patchbay: Patchbay,
    status: &'a Arc<Mutex<PatchStatus>>,
    /// Device channels per frame, learned in `prepared`.
    channels: usize,
    frames: u64,
}

#[cfg(feature = "alsa")]
impl listen::ListenSink for SocketPatchSink<'_> {
	fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
		self.channels = channels;
		self.patchbay.prepared(rate, period, channels)?;
		// The device may have granted fewer channels than the process was
		// configured for; a source that lost its channel is silent now, and
		// `status` should say so rather than repeat the compile-time shape.
		let mut current = self
			.status
			.lock()
			.unwrap_or_else(|poisoned| poisoned.into_inner());
		current.summary = self.patchbay.summary().clone();
		Ok(())
	}

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        self.patchbay.block(input, output)?;
        self.record(input.len() / self.channels);
        Ok(())
    }

    fn block_with_system(
        &mut self,
        input: &[i16],
        system: &[f32],
        output: &mut [i16],
    ) -> Result<(), String> {
        self.patchbay.block_with_system_f32(input, system, output)?;
        self.record(input.len() / self.channels);
        Ok(())
    }
}

#[cfg(feature = "alsa")]
impl SocketPatchSink<'_> {
    fn record(&mut self, frames: usize) {
        self.frames += frames as u64;
        let mut current = self
            .status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        current.frames = self.frames;
    }
}

#[cfg(feature = "alsa")]
fn patch_hardware(
    config: &Config,
    mut patchbay: Patchbay,
    status: &Arc<Mutex<PatchStatus>>,
    stop: &AtomicBool,
    system_device: Option<String>,
) -> Result<(u64, usize), String> {
    // The system mix is the machine's own audio; the engine plays the output
    // the mix replaced, so capturing the sink is not a loop.
    let system_device = if crate::owns_system_mix(config.backend) {
        system_device
    } else {
        None
    };
    let expected = system_device.is_some();
    // Decide before `prepared` can drop a channel: what streams the plan asks
    // for. On ALSA a routed local input is a card capture in the loop; on
    // PipeWire it is one `parec` per input, because one pipewire-alsa process
    // cannot play out the replaced node and capture the card at the same time.
    let streams = patchbay.stream_plan(config.backend);
    let (mut capture, mut system) = match system_device.as_deref() {
        Some(source) => match crate::system_capture::SystemCapture::start(source, config.rate) {
            Ok((capture, consumer)) => (Some(capture), Some(consumer)),
            Err(error) => {
                eprintln!("jawn-audio: system mix: {error}");
                (None, None)
            }
        },
        None => (None, None),
    };
    // Every routed input gets its own capture on the PipeWire backend. A
    // failed one is named in `silent` and the rest of the patch, including the
    // machine's ordinary audio, keeps playing.
    let mut input_captures = Vec::new();
    for input in &streams.inputs {
        let node = input
            .node
            .as_deref()
            .unwrap_or(crate::system_capture::DEFAULT_INPUT);
        match crate::system_capture::SystemCapture::start_channel(
            node,
            config.rate,
            input.channel,
            config.channels,
        ) {
            Ok((capture, consumer)) => {
                patchbay.attach_input(input.index, consumer);
                input_captures.push(capture);
            }
            Err(error) => {
                eprintln!("jawn-audio: input {}: {error}", input.id);
                patchbay.silence_input(input.index);
            }
        }
    }
    {
        let mut current = status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        current.system = if capture.is_some() {
            "capturing".to_string()
        } else if expected {
            "unavailable".to_string()
        } else {
            "off".to_string()
        };
    }
    let sink = SocketPatchSink {
        patchbay,
        status,
        channels: config.channels,
        frames: 0,
    };
    // A PipeWire playback that falls back to the default sink would play into
    // the sink captured above. Build the guard before opening, and report a
    // refusal as this pass's own verdict so the supervisor can hand the machine
    // back instead of leaving a loop running.
    let guard = match (&capture, config.backend) {
        (Some(_), BackendKind::PipeWire) => match PlaybackGuard::new(
            config.target.as_deref(),
            system_device.as_deref().unwrap_or(""),
        ) {
            Ok(guard) => Some(guard),
            Err(error) => {
                note_feedback(status, &error);
                return Ok((0, 0));
            }
        },
        _ => None,
    };
    let run = if streams.card_capture {
        jawn_audio::alsa_device::run_listen_with_system(
            &config.device,
            config.rate,
            config.period,
            config.buffer,
            config.channels,
            None,
            stop,
            sink,
            system.as_mut(),
            None,
        )
    } else {
        jawn_audio::alsa_device::run_playback_with_system(
            &config.device,
            config.rate,
            config.period,
            config.buffer,
            config.channels,
            None,
            stop,
            sink,
            system.as_mut(),
            guard.as_ref(),
        )
    };
    let run = match run {
        Ok(run) => run,
        Err(error) if error.starts_with(FEEDBACK_PREFIX) => {
            note_feedback(status, &error);
            return Ok((0, 0));
        }
        Err(error) => return Err(format!("cannot patch: {error}")),
    };
    for mut capture in input_captures {
        capture.stop();
    }
    if let Some(capture) = capture.as_mut() {
        capture.stop();
    }
    Ok((run.frames, run.xruns))
}

/// Record a playback-guard refusal as the pass's system-mix verdict. The
/// status stays `ok` (the server is healthy) with `system: "feedback"` and the
/// sentence a supervisor or person can act on, rather than a generic failure.
#[cfg(feature = "alsa")]
fn note_feedback(status: &Arc<Mutex<PatchStatus>>, error: &str) {
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.system = "feedback".to_string();
    current.error = error
        .strip_prefix(FEEDBACK_PREFIX)
        .unwrap_or(error)
        .to_string();
}

#[cfg(not(feature = "alsa"))]
fn patch_hardware(
    config: &Config,
    patchbay: Patchbay,
    status: &Arc<Mutex<PatchStatus>>,
    stop: &AtomicBool,
    system_device: Option<String>,
) -> Result<(u64, usize), String> {
    let _ = (config, patchbay, status, stop, system_device);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

#[cfg(feature = "alsa")]
struct SocketListenSink<'a> {
    strip: &'a mut ListenStrip,
    status: &'a Arc<Mutex<ListenStatus>>,
    /// Device channels per frame, learned in `prepared`.
    channels: usize,
    frames: u64,
}

#[cfg(feature = "alsa")]
impl listen::ListenSink for SocketListenSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        self.channels = channels;
        self.strip.prepare(rate, period);
        Ok(())
    }

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        let frames = self.strip.process_i16(input, self.channels, output)?;
        self.frames += frames as u64;
        let mut current = self
            .status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        current.frames = self.frames;
        Ok(())
    }

    fn block_with_system(
        &mut self,
        input: &[i16],
        system: &[f32],
        output: &mut [i16],
    ) -> Result<(), String> {
        let frames = self.strip.process_i16(input, self.channels, output)?;
        listen::add_system_to_i16(output, system, frames);
        self.frames += frames as u64;
        let mut current = self
            .status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        current.frames = self.frames;
        Ok(())
    }
}

#[cfg(feature = "alsa")]
fn listen_hardware(
    config: &Config,
    strip: &mut ListenStrip,
    status: &Arc<Mutex<ListenStatus>>,
    stop: &AtomicBool,
) -> Result<u64, String> {
    // The system mix is the machine's own audio; the engine plays the output
    // the mix replaced, so capturing the sink is not a loop.
    let system_device = if crate::owns_system_mix(config.backend) {
        config.system_device.as_deref()
    } else {
        None
    };
    let guard = match (system_device, config.backend) {
        (Some(source), BackendKind::PipeWire) => Some(PlaybackGuard::new(
            config.target.as_deref(),
            source,
        )?),
        _ => None,
    };
    let (mut capture, mut system) = match system_device {
        Some(source) => match crate::system_capture::SystemCapture::start(source, config.rate) {
            Ok((capture, consumer)) => (Some(capture), Some(consumer)),
            Err(error) => {
                eprintln!("jawn-audio: system mix: {error}");
                (None, None)
            }
        },
        None => (None, None),
    };
    let sink = SocketListenSink {
        strip,
        status,
        channels: config.channels,
        frames: 0,
    };
    let run = jawn_audio::alsa_device::run_listen_with_system(
        &config.device,
        config.rate,
        config.period,
        config.buffer,
        config.channels,
        None,
        stop,
        sink,
        system.as_mut(),
        guard.as_ref(),
    );
    if let Some(capture) = capture.as_mut() {
        capture.stop();
    }
    let run = run.map_err(|error| format!("cannot listen: {error}"))?;
    Ok(run.frames)
}

#[cfg(not(feature = "alsa"))]
fn listen_hardware(
    config: &Config,
    strip: &mut ListenStrip,
    status: &Arc<Mutex<ListenStatus>>,
    stop: &AtomicBool,
) -> Result<u64, String> {
    let _ = (config, strip, status, stop);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
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
    master: Vec<InsertKind>,
    live: Option<(jawn_audio::Consumer, Arc<AtomicU32>)>,
    length: Option<u64>,
    system_device: Option<String>,
) {
    // Build the strips here, on the playback thread, so a chain never moves
    // between threads. The control thread already checked the shape. A
    // monitor's control ring is the one `param` pushes to; a plain playback
    // has no live knobs yet.
    let built = if tracks.is_empty() {
        // A live-only monitor: no files to check, the take's frames and rate
        // are the whole shape.
        match live {
            Some((consumer, gain)) => Ok(Playback::live(
                config.rate,
                length.unwrap_or(0),
                consumer,
                gain,
            )),
            None => Err("playback needs at least one file".to_string()),
        }
    } else {
        let params = params.unwrap_or_else(|| Arc::new(ParamQueue::new()));
        match Playback::with_queue(tracks, start_at, params) {
            Ok(playback) => {
                let mut playback = playback;
                if let Some((consumer, gain)) = live {
                    playback = playback.with_live_input(consumer, gain);
                }
                if let Some(length) = length {
                    playback.set_length(length);
                }
                Ok(playback)
            }
            Err(error) => Err(error),
        }
    };
    let mut playback = match built {
        Ok(mut playback) => {
            // The master rack is armed before the device is opened, so the
            // first monitored block already has the page's mastering chain.
            playback.arm_master(&master);
            playback
        }
        Err(error) => {
            let mut current = status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            current.state = State::Failed;
            current.error = error;
            return;
        }
    };
    // The machine's own mix is monitor-only, added after the master chain. It
    // never reaches the take's capture or writers; the capture lives exactly
    // as long as this playback thread, so stopping the monitor joins `parec`.
    let _system = if crate::owns_system_mix(config.backend) {
        match system_device {
            Some(source) => {
                match crate::system_capture::SystemCapture::start(&source, config.rate) {
                    Ok((capture, consumer)) => {
                        playback = playback.with_system_input(consumer);
                        Some(capture)
                    }
                    Err(error) => {
                        eprintln!("jawn-audio: system mix: {error}");
                        None
                    }
                }
            }
            None => None,
        }
    } else {
        None
    };
    // A PipeWire playback that falls back to the default sink would play into
    // the sink captured above. Build the guard before the device opens; a
    // refusal fails this playback rather than feeding the mix back to itself.
    let guard = match (&_system, config.backend) {
        (Some(_), BackendKind::PipeWire) => match PlaybackGuard::new(
            config.target.as_deref(),
            config.system_device.as_deref().unwrap_or(""),
        ) {
            Ok(guard) => Some(guard),
            Err(error) => {
                let mut current = status
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner());
                current.state = State::Failed;
                current.error = error
                    .strip_prefix(FEEDBACK_PREFIX)
                    .unwrap_or(&error)
                    .to_string();
                return;
            }
        },
        _ => None,
    };
    let outcome = match config.backend {
        BackendKind::Null => play_null_stream(config.period, &mut playback, &status, &stop),
        BackendKind::Alsa | BackendKind::PipeWire => {
            play_hardware(&config, &mut playback, &status, &stop, guard.as_ref())
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
    guard: Option<&PlaybackGuard>,
) -> Result<u64, String> {
    let rate = playback.rate();
    let total = playback.total_frames();
    let sink = PlaySink {
        playback,
        status,
        stop,
    };
    let report = jawn_audio::alsa_device::run_file_playback_guarded(
        &config.device,
        rate,
        config.period,
        config.buffer,
        total,
        sink,
        guard,
    )
    .map_err(|error| {
        if error.starts_with(FEEDBACK_PREFIX) {
            error
                .strip_prefix(FEEDBACK_PREFIX)
                .unwrap_or(&error)
                .to_string()
        } else {
            format!("cannot play: {error}")
        }
    })?;
    Ok(report.frames)
}

#[cfg(not(feature = "alsa"))]
fn play_hardware(
    config: &Config,
    playback: &mut Playback,
    status: &Arc<Mutex<PlayStatus>>,
    stop: &AtomicBool,
    guard: Option<&PlaybackGuard>,
) -> Result<u64, String> {
    let _ = (config, playback, status, stop, guard);
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
    master: Vec<InsertKind>,
    live: Option<Producer>,
    armed: Arc<AtomicBool>,
) {
    // Build the mixer here, on the take's thread, so it is never moved between
    // threads. Its control ring is the one the socket already holds. The
    // chains are built here too: an insert is not `Send`, and `param` addresses
    // the effects that are actually in each track's strip.
    let inputs: Vec<usize> = plans.iter().map(|plan| plan.input).collect();
    let labels: Vec<String> = (1..=plans.len()).map(|track| format!("ch{track}")).collect();
    let label_refs: Vec<&str> = labels.iter().map(|label| label.as_str()).collect();
    let mut mixer = Mixer::with_queue(&inputs, &label_refs, Arc::clone(&params));
    // The take records each strip before the bus, so the master rack is armed
    // for the take's own queue too; the monitored mix is the monitor's
    // playback, which arms the same list on its thread.
    for kind in &master {
        mixer.push_master(*kind);
    }
    for (index, track) in mixer.tracks_mut().iter_mut().enumerate() {
        let plan = &plans[index];
        let mut channel = Channel::new(plan.gain, plan.pan);
        for kind in &plan.inserts {
            channel.push(kind.build());
        }
        track.channels = plan.channels;
        track.channel = channel;
    }
    let outcome = match config.backend {
        BackendKind::Null => capture_null(
            &config,
            seconds,
            &mut disks,
            &mut mixer,
            &status,
            &stop,
            live.as_ref(),
            &armed,
        ),
        BackendKind::Alsa | BackendKind::PipeWire | BackendKind::Jack => capture_hardware(
            &config,
            seconds,
            &mut disks,
            &mut mixer,
            &status,
            &stop,
            live.as_ref(),
            &armed,
        ),
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
    current.monitor_dropped = live.as_ref().map(Producer::dropped).unwrap_or(0);
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
fn note_progress(
    status: &Arc<Mutex<Status>>,
    frames: u64,
    disks: &[DiskWriter],
    monitor_dropped: u64,
) {
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.frames = frames;
    current.dropped = disks.first().map(|disk| disk.dropped_frames()).unwrap_or(0);
    current.monitor_dropped = monitor_dropped;
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

/// Read one track's input from an interleaved block. A stereo pair is summed
/// at `0.5` each *before* the mono strip, so a guitar on two channels is one
/// source, not two half-volume copies.
fn read_mono_f32(
    block: &[f32],
    frames: usize,
    device: usize,
    input: usize,
    channels: usize,
    mono: &mut [f32],
) {
    if channels == 2 {
        for frame in 0..frames {
            let base = frame * device + input;
            mono[frame] = 0.5 * (block[base] + block[base + 1]);
        }
    } else {
        for frame in 0..frames {
            mono[frame] = block[frame * device + input];
        }
    }
}

/// The hardware spelling of [`read_mono_f32`], from a signed 16-bit block.
#[cfg(any(feature = "alsa", test))]
fn read_mono_i16(
    block: &[i16],
    frames: usize,
    device: usize,
    input: usize,
    channels: usize,
    mono: &mut [f32],
) {
    if channels == 2 {
        for frame in 0..frames {
            let base = frame * device + input;
            mono[frame] =
                (f32::from(block[base]) + f32::from(block[base + 1])) / (2.0 * 32_768.0);
        }
    } else {
        for frame in 0..frames {
            mono[frame] = f32::from(block[frame * device + input]) / 32_768.0;
        }
    }
}

/// The refusal a track's claimed channels earn when the device cannot carry
/// them. The pair is named for stereo; the count is always the device's.
fn channel_error(track: usize, input: usize, channels: usize, device: usize, limit: &str) -> String {
    if channels == 2 {
        format!(
            "track {track} records inputs {input}..{}, but {limit} {device} channel(s)",
            input + 1
        )
    } else {
        format!("track {track} records input {input}, but {limit} {device} channel(s)")
    }
}

/// Push one summed block to the live ring, but only while the take is armed.
/// A take that is not monitoring leaves the ring empty, so the live edge is
/// where monitoring starts and a monitor never plays a backlog from before it.
/// The push itself is lock-free; the load is the whole cost of a muted take.
fn push_if_armed(producer: &Producer, armed: &AtomicBool, block: &[f32]) -> usize {
    if armed.load(Ordering::Acquire) {
        producer.push(block)
    } else {
        0
    }
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
    live: Option<&Producer>,
    armed: &AtomicBool,
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
    // The monitoring bus is the sum of every track's processed stereo output,
    // pushed once per block so the monitor hears the whole take, not one stem.
    let mut live_block = vec![0.0f32; config.period * TAKE_CHANNELS];
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
        if live.is_some() {
            live_block[..samples].fill(0.0);
        }
        for track in 0..track_count {
            let input = mixer.tracks()[track].input;
            let track_channels = mixer.tracks()[track].channels;
            if input + track_channels > config.channels {
                return Err(channel_error(
                    track + 1,
                    input,
                    track_channels,
                    config.channels,
                    "the device has",
                ));
            }
            read_mono_f32(
                &source,
                frames,
                config.channels,
                input,
                track_channels,
                &mut mono[..frames],
            );
            mixer
                .process(track, &mono[..frames], &mut stereo[..samples])
                .map_err(|error| format!("track {track}: {error}"))?;
            if live.is_some() {
                for (out, sample) in live_block[..samples].iter_mut().zip(&stereo[..samples]) {
                    *out += sample;
                }
            }
            for (out, sample) in pcm[..samples].iter_mut().zip(&stereo[..samples]) {
                *out = to_i16(*sample);
            }
            disks[track].push(&pcm[..samples]);
        }
        if let Some(producer) = live {
            push_if_armed(producer, armed, &live_block[..samples]);
        }
        pushed += frames as u64;
        note_progress(
            status,
            pushed,
            disks,
            live.map(Producer::dropped).unwrap_or(0),
        );
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
    live: Option<&'a Producer>,
    /// Whether the take is pushing its live input; read once per block.
    armed: &'a AtomicBool,
    pushed: u64,
    /// Device channels per frame, learned in `prepared`.
    channels: usize,
    mono: Vec<f32>,
    stereo: Vec<f32>,
    live_block: Vec<f32>,
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
            .position(|track| track.input + track.channels > channels)
        {
            let track = &self.mixer.tracks()[index];
            return Err(channel_error(
                index + 1,
                track.input,
                track.channels,
                channels,
                "the device granted only",
            ));
        }
        self.mixer.prepare(rate, period);
        self.mono = vec![0.0; period];
        self.stereo = vec![0.0; period * TAKE_CHANNELS];
        self.live_block = vec![0.0; period * TAKE_CHANNELS];
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
        if self.live.is_some() {
            self.live_block[..samples].fill(0.0);
        }
        for track in 0..track_count {
            let input = self.mixer.tracks()[track].input;
            let track_channels = self.mixer.tracks()[track].channels;
            if input + track_channels > channels {
                return Err(channel_error(
                    track + 1,
                    input,
                    track_channels,
                    channels,
                    "the device has",
                ));
            }
            read_mono_i16(
                block,
                frames,
                channels,
                input,
                track_channels,
                &mut self.mono[..frames],
            );
            self.mixer
                .process(track, &self.mono[..frames], &mut self.stereo[..samples])
                .map_err(|error| format!("track {track}: {error}"))?;
            if self.live.is_some() {
                for (out, sample) in self.live_block[..samples]
                    .iter_mut()
                    .zip(&self.stereo[..samples])
                {
                    *out += sample;
                }
            }
            for (out, sample) in self.pcm[..samples].iter_mut().zip(&self.stereo[..samples]) {
                *out = to_i16(*sample);
            }
            self.disks[track].push(&self.pcm[..samples]);
        }
        if let Some(producer) = self.live {
            push_if_armed(producer, self.armed, &self.live_block[..samples]);
        }
        self.pushed += frames as u64;
        note_progress(
            self.status,
            self.pushed,
            self.disks,
            self.live.map(Producer::dropped).unwrap_or(0),
        );
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
    live: Option<&Producer>,
    armed: &AtomicBool,
) -> Result<Captured, String> {
    let sink = ServeSink {
        mixer,
        disks,
        status,
        stop,
        live,
        armed,
        pushed: 0,
        channels: config.channels,
        mono: Vec::new(),
        stereo: Vec::new(),
        live_block: Vec::new(),
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
    live: Option<&Producer>,
    armed: &AtomicBool,
) -> Result<Captured, String> {
    let _ = (config, seconds, disks, mixer, status, stop, live, armed);
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
    fn socket_server() -> Server {
        // A server built for a protocol test has no one to stop it; the flag is
        // static because that is what the real one reads.
        static STOP: AtomicBool = AtomicBool::new(false);
        Server::new(
            Config {
                backend: BackendKind::Null,
                device: "null".to_string(),
                target: None,
                rate: 48_000,
                period: 4096,
                buffer: 2,
                channels: 1,
                socket: PathBuf::from("/tmp/jawn-audio-test.sock"),
                plan: None,
                machine: "test".to_string(),
                system_device: None,
                handset_device: None,
            },
            &STOP,
            None,
        )
    }

    fn take_status(inserts: &str) -> Status {
        Status {
            take: 1,
            state: State::Recording,
            path: "/tmp/take.wav".to_string(),
            frames: 0,
            dropped: 0,
            channels: 1,
            start_sample: 0,
            xruns: 0,
            align_samples: 0,
            align_from: "none",
            tracks: vec![TrackStatus {
                path: "/tmp/take.wav".to_string(),
                input: 0,
                frames: 0,
                dropped: 0,
                gain: 1.0,
                pan: 0.0,
                inserts: inserts.to_string(),
            }],
            monitor_input: false,
            monitor_gain: 1.0,
            monitor_dropped: 0,
            error: String::new(),
        }
    }

    fn running(status: Status, params: Arc<ParamQueue>) -> Running {
        Running {
            status: Arc::new(Mutex::new(status)),
            stop: Arc::new(AtomicBool::new(false)),
            handle: None,
            params,
            input_gain: Arc::new(AtomicU32::new(1f32.to_bits())),
            // Most of these tests predate mid-take arming: a take that is
            // already monitoring keeps the gain test about the gain.
            armed: Arc::new(AtomicBool::new(true)),
            total_frames: 0,
            consumer: None,
            master: Vec::new(),
        }
    }

    fn reply(action: Action) -> String {
        match action {
            Action::Reply(line) => line,
            Action::Quit(_) => panic!("expected a param reply"),
        }
    }

    #[test]
    fn a_socket_parameter_reaches_a_new_insert_and_refuses_an_unknown_control() {
        let mut server = socket_server();
        let params = Arc::new(ParamQueue::new());
        server.current = Some(running(take_status("limiter"), Arc::clone(&params)));

        // An unknown control of a known effect is a refusal, not a clamp onto
        // the nearest knob.
        let line = reply(server.handle(
            r#"{"cmd":"param","track":0,"name":"limiter.wobble","value":-6}"#,
        ));
        assert!(line.contains("no such parameter"), "{line}");

        // An insert the take was not armed with is refused the same way.
        let line = reply(server.handle(
            r#"{"cmd":"param","track":0,"name":"flanger.rate","value":2}"#,
        ));
        assert!(line.contains("no such parameter"), "{line}");

        // A real control of the armed insert is queued, and the strip applies
        // it at its next block: the block above the new ceiling is caught.
        let line = reply(server.handle(
            r#"{"cmd":"param","track":0,"name":"limiter.ceiling","value":-6}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");

        let mut mixer = Mixer::with_queue(&[0], &["ch1"], Arc::clone(&params));
        mixer.tracks_mut()[0]
            .channel
            .push(InsertKind::Limiter.build());
        mixer.prepare(48_000, 4096);
        let mono = vec![0.8f32; 4096];
        let mut stereo = vec![0.0f32; 8192];
        for _ in 0..4 {
            mixer.process(0, &mono, &mut stereo).expect("process");
        }
        let ceiling = 10f32.powf(-6.0 / 20.0);
        assert!(
            stereo.iter().all(|sample| sample.abs() <= ceiling + 1e-3),
            "the queued ceiling did not reach the limiter"
        );
    }

    #[test]
    fn a_master_parameter_is_addressed_to_the_master_rack() {
        let mut server = socket_server();
        let params = Arc::new(ParamQueue::new());
        server.current = Some(running(take_status("limiter"), Arc::clone(&params)));

        for bad in ["master_comp.wobble", "flanger.rate"] {
            let line = reply(server.handle(&format!(
                r#"{{"cmd":"param","target":"master","name":"{bad}","value":-6}}"#
            )));
            assert!(line.contains("no such parameter"), "{bad}: {line}");
        }

        let line = reply(server.handle(
            r#"{"cmd":"param","target":"master","name":"master_limiter.ceiling","value":-6}"#,
        ));
        assert!(line.contains("\"target\":\"master\""), "{line}");

        let mut mixer = Mixer::with_queue(&[0], &["ch1"], Arc::clone(&params));
        mixer.push_master(InsertKind::Limiter);
        mixer.prepare(48_000, 4096);
        let mono = vec![0.8f32; 4096];
        let mut bus = vec![0.0f32; 8192];
        for _ in 0..4 {
            mixer.mix(&[&mono], &mut bus).expect("mix");
        }
        let ceiling = 10f32.powf(-6.0 / 20.0);
        assert!(
            bus.iter().all(|sample| sample.abs() <= ceiling + 2e-2),
            "the master ceiling did not reach the bus"
        );

        // The footswitch moves the armed insert in place; bypassed, the bus is
        // the plain sum again. An insert that was never armed has no slot.
        let line = reply(server.handle(
            r#"{"cmd":"param","target":"master","name":"master_limiter.bypass","value":1}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        mixer.mix(&[&mono], &mut bus).expect("mix");
        let plain = 0.8 * std::f32::consts::FRAC_1_SQRT_2;
        assert!(
            (bus[0] - plain).abs() < 1e-3,
            "a bypassed master was not transparent: {}",
            bus[0]
        );

        let line = reply(server.handle(
            r#"{"cmd":"param","target":"master","name":"master_limiter.bypass","value":0}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        mixer.mix(&[&mono], &mut bus).expect("mix");
        assert!(
            bus.iter().all(|sample| sample.abs() <= ceiling + 2e-2),
            "restoring the master insert did not limit again"
        );
    }

    #[test]
    fn a_per_track_plan_arms_each_chain_differently() {
        let object = parse_object(
            r#"{"tracks":[{"input":0,"inserts":["tone","delay"]},{"input":1,"inserts":["flanger","amp"]}]}"#,
        )
        .expect("parse");
        let values = match get(&object, "tracks") {
            Some(Value::Arr(values)) => values,
            other => panic!("tracks is not an array: {other:?}"),
        };
        let plans = track_plans(values).expect("plan");
        assert_eq!(plans[0].input, 0);
        assert_eq!(plans[0].inserts, vec![InsertKind::Tone, InsertKind::Delay]);
        assert_eq!(plans[1].input, 1);
        assert_eq!(plans[1].inserts, vec![InsertKind::Flanger, InsertKind::Amp]);
    }

    #[test]
    fn a_master_plan_is_ordered_by_the_contract_and_refuses_duplicates() {
        let object = parse_object(
            r#"{"master":["master_limiter","master_comp","master_reverb"]}"#,
        )
        .expect("parse");
        let master = parse_master(get(&object, "master")).expect("master");
        assert_eq!(
            master,
            vec![InsertKind::Compressor, InsertKind::Reverb, InsertKind::Limiter],
            "the rack is built in the house's order"
        );

        let duplicate = parse_object(r#"{"master":["master_comp","master_comp"]}"#).expect("parse");
        assert!(parse_master(get(&duplicate, "master")).is_err());
        let wrong = parse_object(r#"{"master":["flanger"]}"#).expect("parse");
        assert!(parse_master(get(&wrong, "master")).is_err());
        let wrong_shape = parse_object(r#"{"master":"master_comp"}"#).expect("parse");
        assert!(parse_master(get(&wrong_shape, "master")).is_err());
    }

    fn temp_take(name: &str) -> String {
        use std::sync::atomic::AtomicUsize;
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let count = NEXT.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir()
            .join(format!(
                "jawn-live-{}-{count}-{name}.wav",
                std::process::id()
            ))
            .to_string_lossy()
            .into_owned()
    }

    fn temp_socket(name: &str) -> PathBuf {
        use std::sync::atomic::AtomicUsize;
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let count = NEXT.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "jawn-audio-sock-{}-{count}-{name}.sock",
            std::process::id()
        ))
    }

    /// Bind a stand-in engine at `path` that answers exactly one status probe
    /// with `reply` (or closes without answering, like a wedged engine).
    fn fake_engine(path: &Path, reply: Option<&'static str>) -> thread::JoinHandle<()> {
        let listener = UnixListener::bind(path).expect("bind the fake engine");
        thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                let mut buffer = [0u8; 128];
                let _ = stream.read(&mut buffer);
                if let Some(reply) = reply {
                    let _ = stream.write_all(reply.as_bytes());
                }
            }
        })
    }

    #[test]
    fn a_probe_reads_a_live_engines_pid() {
        let path = temp_socket("live");
        let engine = fake_engine(
            &path,
            Some("{\"ok\":true,\"take\":0,\"state\":\"idle\",\"pid\":4242}\n"),
        );
        let probe = probe_live_engine(&path).expect("a live engine answers");
        assert_eq!(probe.pid, Some(4242));
        engine.join().expect("fake engine");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_busy_engines_error_line_still_counts_as_live() {
        // The manager holds the one client slot during a take; the engine
        // answers a probe with its one error line. That is still an engine to
        // refuse, never a stale socket to unlink.
        let path = temp_socket("busy");
        let engine = fake_engine(
            &path,
            Some("{\"ok\":false,\"error\":\"a client is already connected\"}\n"),
        );
        let probe = probe_live_engine(&path).expect("the busy line speaks the protocol");
        assert_eq!(probe.pid, None, "an error line carries no pid");
        engine.join().expect("fake engine");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_socket_that_never_answers_is_stale() {
        let path = temp_socket("silent");
        let engine = fake_engine(&path, None);
        assert_eq!(probe_live_engine(&path), None);
        engine.join().expect("fake engine");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn bind_refuses_a_live_engine_without_unlinking_its_socket() {
        let path = temp_socket("refuse");
        let engine = fake_engine(
            &path,
            Some("{\"ok\":true,\"take\":0,\"state\":\"idle\",\"pid\":77}\n"),
        );
        let error = bind(&path).expect_err("a live engine must not be displaced");
        assert!(error.contains("pid 77"), "{error}");
        assert!(error.contains(&path.display().to_string()), "{error}");
        assert!(path.exists(), "a refused bind leaves the live socket alone");
        engine.join().expect("fake engine");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn bind_still_replaces_a_socket_that_does_not_answer() {
        let path = temp_socket("stale");
        {
            let dead = UnixListener::bind(&path).expect("bind the stale socket");
            drop(dead);
        }
        assert!(path.exists(), "a crash leaves the file behind");
        let listener = bind(&path).expect("a stale socket is replaced");
        drop(listener);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_replaced_or_removed_socket_is_noticed() {
        let path = temp_socket("watch");
        let original = UnixListener::bind(&path).expect("bind the watched socket");
        let bound = socket_id(&path).expect("stat the watched socket");
        let watched = path.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        thread::spawn(move || {
            wait_for_socket_change(&watched, bound);
            let _ = tx.send(());
        });

        // A second listener moved onto the path is a different inode: the
        // engine that bound the old one no longer owns the name.
        let replacement = temp_socket("watch-replacement");
        let takeover = UnixListener::bind(&replacement).expect("bind the replacement");
        fs::rename(&replacement, &path).expect("replace the socket path");
        rx.recv_timeout(Duration::from_secs(2))
            .expect("a replaced socket is noticed");
        drop(takeover);
        drop(original);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_removed_socket_is_noticed() {
        let path = temp_socket("gone");
        let original = UnixListener::bind(&path).expect("bind the watched socket");
        let bound = socket_id(&path).expect("stat the watched socket");
        let watched = path.clone();
        let (tx, rx) = std::sync::mpsc::channel();
        thread::spawn(move || {
            wait_for_socket_change(&watched, bound);
            let _ = tx.send(());
        });
        fs::remove_file(&path).expect("remove the socket path");
        rx.recv_timeout(Duration::from_secs(2))
            .expect("a removed socket is noticed");
        drop(original);
    }

    #[test]
    fn a_live_only_monitor_is_accepted_with_no_files() {
        let mut server = socket_server();
        let out = temp_take("live");
        let line = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":0.05,"monitor_input":true,"monitor_gain":0.9}}"#
        )));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"monitor_input\":true"), "{line}");
        assert!(line.contains("\"monitor_gain\":0.9"), "{line}");
        assert!(line.contains("\"monitor_dropped\":0"), "{line}");
        // The live monitor is a session even though it has no files.
        assert!(line.contains("\"playing\":0"), "{line}");
        let _ = server.handle(r#"{"cmd":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_tracks_channels_must_be_one_or_two() {
        for bad in ["3", "1.5", "0", "\"2\""] {
            let object = parse_object(&format!(
                r#"{{"tracks":[{{"input":0,"channels":{bad}}}]}}"#
            ))
            .expect("parse");
            let values = match get(&object, "tracks") {
                Some(Value::Arr(values)) => values,
                other => panic!("tracks is not an array: {other:?}"),
            };
            let error = track_plans(values)
                .err()
                .expect("channels must be refused");
            assert_eq!(
                error,
                "track 1 \"channels\" must be 1 (mono) or 2 (stereo)",
                "{bad}"
            );
        }
    }

    #[test]
    fn a_stereo_pair_past_the_engine_channels_is_refused() {
        let mut server = socket_server();
        let out = temp_take("stereo");
        let line = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":0.01,"tracks":[{{"input":0,"channels":2}}]}}"#
        )));
        assert!(
            line.contains("track 1 records inputs 0..1, but the engine has only 1 channel(s)"),
            "{line}"
        );
        assert!(!std::path::Path::new(&out).exists(), "a refusal created a file");
    }

    #[test]
    fn monitor_input_and_gain_shapes_are_refused() {
        let mut server = socket_server();
        let out = temp_take("shape");
        for (field, value, sentence) in [
            (
                "monitor_input",
                "\"yes\"",
                "\"monitor_input\" must be true or false",
            ),
            (
                "monitor_gain",
                "\"loud\"",
                "\"monitor_gain\" must be a finite number",
            ),
        ] {
            let line = reply(server.handle(&format!(
                r#"{{"cmd":"record","out":"{out}","seconds":0.01,"{field}":{value}}}"#
            )));
            assert_eq!(line, error_line(sentence));
        }
    }

    #[test]
    fn a_plan_keeps_each_tracks_channels_and_the_reader_uses_them() {
        let object = parse_object(
            r#"{"tracks":[{"input":0,"channels":2},{"input":2,"channels":1}]}"#,
        )
        .expect("parse");
        let values = match get(&object, "tracks") {
            Some(Value::Arr(values)) => values,
            other => panic!("tracks is not an array: {other:?}"),
        };
        let plans = track_plans(values).expect("plan");
        assert_eq!(plans[0].channels, 2);
        assert_eq!(plans[1].channels, 1);

        // Two frames across three device channels: stereo at 0 averages each
        // pair; mono at 2 takes the third channel alone.
        let block = [0.2f32, 0.4, 0.6, 0.8, 1.0, 1.2];
        let mut mono = [0.0f32; 2];
        read_mono_f32(&block, 2, 3, 0, 2, &mut mono);
        assert!((mono[0] - 0.3).abs() < 1e-6, "{mono:?}");
        assert!((mono[1] - 0.9).abs() < 1e-6, "{mono:?}");
        read_mono_f32(&block, 2, 3, 2, 1, &mut mono);
        assert!((mono[0] - 0.6).abs() < 1e-6, "{mono:?}");
        assert!((mono[1] - 1.2).abs() < 1e-6, "{mono:?}");

        let hardware: Vec<i16> = [0.2f32, 0.4, 0.6, 0.8, 0.0, 0.2]
            .iter()
            .map(|sample| to_i16(*sample))
            .collect();
        read_mono_i16(&hardware, 2, 3, 0, 2, &mut mono);
        assert!((mono[0] - 0.3).abs() < 1e-3, "{mono:?}");
        assert!((mono[1] - 0.4).abs() < 1e-3, "{mono:?}");
        read_mono_i16(&hardware, 2, 3, 2, 1, &mut mono);
        assert!((mono[0] - 0.6).abs() < 1e-3, "{mono:?}");
        assert!((mono[1] - 0.2).abs() < 1e-3, "{mono:?}");

        let error = channel_error(1, 0, 2, 1, "the engine has only");
        assert_eq!(
            error,
            "track 1 records inputs 0..1, but the engine has only 1 channel(s)"
        );
    }

    #[test]
    fn param_input_moves_the_live_gain_and_refuses_without_a_take() {
        let mut server = socket_server();
        let gain = Arc::new(AtomicU32::new(1f32.to_bits()));
        let mut take = running(take_status(""), Arc::new(ParamQueue::new()));
        take.input_gain = Arc::clone(&gain);
        server.current = Some(take);

        let line = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":2.5}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"monitor_input\":true"), "{line}");
        assert_eq!(f32::from_bits(gain.load(Ordering::Acquire)), 2.5);
        let status = server.current.as_ref().unwrap().snapshot();
        assert_eq!(status.monitor_gain, 2.5);

        // The gain is clamped to 0..=4.
        let _ = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":9}"#,
        ));
        assert_eq!(f32::from_bits(gain.load(Ordering::Acquire)), 4.0);

        let line = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"pan","value":1}"#,
        ));
        assert_eq!(line, error_line("target \"input\" only carries \"gain\""));

        // With no take there is no ring to address.
        server.current = None;
        let line = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":1}"#,
        ));
        assert!(line.contains("no live input is being monitored"), "{line}");
    }

    #[test]
    fn a_param_arms_monitoring_on_a_take_that_started_with_it_off() {
        let mut server = socket_server();
        let out = temp_take("arm");
        // Long enough that the take is still recording when the next line is
        // read: the null backend renders as fast as the CPU allows, so a short
        // take could finish before a loaded test thread got to send `param`.
        let line = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":30}}"#
        )));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"monitor_input\":false"), "{line}");

        let line = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":1}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"monitor_input\":true"), "{line}");

        // The take never restarted: it is the same take, now monitoring.
        let line = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(line.contains("\"state\":\"recording\""), "{line}");
        assert!(line.contains("\"monitor_input\":true"), "{line}");
        assert!(line.contains("\"monitor_gain\":1"), "{line}");

        let _ = server.handle(r#"{"cmd":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_zero_gain_never_arms_the_live_input() {
        let mut server = socket_server();
        let out = temp_take("zero");
        // As above: the take must still be recording when the mute arrives.
        let line = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":30}}"#
        )));
        assert!(line.contains("\"ok\":true"), "{line}");

        let line = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":0}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"monitor_input\":false"), "{line}");

        let line = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(line.contains("\"monitor_input\":false"), "{line}");
        assert!(line.contains("\"monitor_gain\":0"), "{line}");

        let _ = server.handle(r#"{"cmd":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn arming_on_a_take_with_no_time_left_is_refused() {
        let mut server = socket_server();
        let mut take = running(take_status(""), Arc::new(ParamQueue::new()));
        take.armed = Arc::new(AtomicBool::new(false));
        take.total_frames = 4096;
        server.current = Some(take);
        // Every frame this take had is already on disk, so no ring could be
        // drained before the take ended.
        server
            .current
            .as_ref()
            .unwrap()
            .status
            .lock()
            .expect("status")
            .frames = 4096;

        let line = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":1}"#,
        ));
        assert_eq!(line, error_line("the take has no time left to monitor"));
        assert!(
            !server.current.as_ref().unwrap().armed.load(Ordering::Acquire),
            "a refused arm opened the ring"
        );
        assert_eq!(remaining_frames(0, 0), 0);
        assert_eq!(remaining_frames(512, 512), 0, "a finished take has none left");
        assert_eq!(remaining_frames(512, 200), 312);
    }

    #[test]
    fn the_ring_stays_empty_until_the_take_is_armed() {
        let (producer, consumer) = MonitorBus::new(4096);
        let armed = AtomicBool::new(false);
        assert_eq!(push_if_armed(&producer, &armed, &[0.5, -0.5]), 0);
        let mut out = vec![9.0f32; 2];
        assert_eq!(consumer.pop(&mut out), 0, "an unarmed take pushed");
        assert_eq!(out, vec![0.0f32; 2], "an underrun must be silence");

        armed.store(true, Ordering::Release);
        assert_eq!(push_if_armed(&producer, &armed, &[0.5, -0.5]), 0);
        assert_eq!(consumer.pop(&mut out), 1);
        assert_eq!(out, vec![0.5f32, -0.5], "the armed take's frame arrived");
    }

    /// A patch line carries two different facts whose names once collided: the
    /// capture state (`system`) and the plan's routing (`system_route`). A JSON
    /// decoder keeps the last duplicate, so one key with two meanings made the
    /// supervisor read `fallback` where the engine meant `capturing`, drop the
    /// virtual sink, and leave the machine silent behind a card it still held.
    #[test]
    fn a_patch_line_names_the_capture_state_and_the_route_separately() {
        let known = ["pending", "capturing", "unavailable", "off"];
        for capture in known {
            for route in ["routed", "fallback"] {
                let status = PatchStatus {
                    state: State::Patching,
                    frames: 960,
                    xruns: 0,
                    summary: crate::patchbay::PatchSummary {
                        sources: 1,
                        buses: 0,
                        sinks: 1,
                        routes: 1,
                        bound_sources: 1,
                        bound_sinks: 1,
                        silent: Vec::new(),
                        inputs: Vec::new(),
                        system: route,
                        handset: "off",
                        mode: "playback",
                    },
                    system: capture.to_string(),
                    error: String::new(),
                };
                let line = patch_line(&status);
                let object = parse_object(&line).expect("the line parses");
                let systems: Vec<&str> = object
                    .iter()
                    .filter(|(key, _)| key == "system")
                    .filter_map(|(_, value)| match value {
                        Value::Str(text) => Some(text.as_str()),
                        _ => None,
                    })
                    .collect();
                assert_eq!(
                    systems.len(),
                    1,
                    "exactly one `system` key, and it is the capture state: {line}"
                );
                assert!(
                    known.contains(&systems[0]),
                    "`system` is a capture state, not a route: {}",
                    systems[0]
                );
                assert_eq!(systems[0], capture, "the capture state survived: {line}");
                let routes: Vec<&str> = object
                    .iter()
                    .filter(|(key, _)| key == "system_route")
                    .filter_map(|(_, value)| match value {
                        Value::Str(text) => Some(text.as_str()),
                        _ => None,
                    })
                    .collect();
                assert_eq!(routes, vec![route], "the plan's routing has its own key: {line}");
            }
        }
    }

    #[test]
    fn the_gateway_is_off_until_a_bind_and_an_unknown_action_is_refused() {
        let mut server = socket_server();

        let line = reply(server.handle("{\"cmd\":\"gateway\",\"action\":\"status\"}"));
        assert!(line.contains("\"ok\":true"), "status: {line}");
        assert!(line.contains("\"call_in\":\"off\""), "status: {line}");
        assert!(line.contains("\"prompt\":\"silent\""), "status: {line}");
        assert!(line.contains("\"monitor\":\"helper\""), "status: {line}");
        assert!(line.contains("\"rate\":8000"), "status: {line}");
        assert!(line.contains("\"channels\":1"), "status: {line}");
        assert!(line.contains("\"peak\":0.000000"), "status: {line}");
        assert!(line.contains("\"frames\":0"), "status: {line}");
        assert!(line.contains("\"dropped\":0"), "status: {line}");
        assert!(line.contains("\"paths\":{}"), "status: {line}");
        assert!(line.contains("\"capable\":"), "status does not name the environment: {line}");

        // `capable` is the environment, not a call: the same two worlds answer
        // differently while both are `off`.
        let capable = jawn_audio::backends::command_exists("parec")
            && jawn_audio::backends::command_exists("pacat");
        assert!(
            line.contains(&format!("\"capable\":{capable}")),
            "capable disagrees with PATH: {line}"
        );

        // Every status line carries the same object, so a page that already
        // polls the engine does not need a second command.
        let line = server.status_line();
        assert!(
            line.contains(
                "\"gateway\":{\"call_in\":\"off\",\"prompt\":\"silent\",\"monitor\":\"helper\",\"rate\":8000,\"channels\":1,\"peak\":0.000000,\"frames\":0,\"dropped\":0,\"paths\":{},\"capable\":"
            ),
            "status: {line}"
        );

        // A bind without a sink names nothing to capture.
        let line = reply(server.handle("{\"cmd\":\"gateway\",\"action\":\"bind\"}"));
        assert!(line.contains("\"ok\":false"), "bind: {line}");
        assert!(line.contains("call_in"), "bind: {line}");

        // A missing action is refused the same way an unknown command is.
        let line = reply(server.handle("{\"cmd\":\"gateway\",\"action\":\"wobble\"}"));
        assert!(line.contains("\"ok\":false"), "unknown action: {line}");
        assert!(line.contains("no such gateway action"), "{line}");
        let line = reply(server.handle("{\"cmd\":\"gateway\"}"));
        assert!(line.contains("\"ok\":false"), "no action: {line}");
    }

    /// A throwaway directory for one test's FIFOs and socket.
    fn gateway_test_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "jawn-audio-gw-unit-{}-{name}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("create the gateway test directory");
        dir
    }

    /// A server whose state directory is the test's own, so two tests never
    /// meet in `<tmp>/gateway-<pid>`.
    fn gateway_server(dir: &Path) -> Server {
        let mut server = socket_server();
        server.config.socket = dir.join("audio.sock");
        server
    }

    #[test]
    fn a_bind_makes_absolute_fifos_and_release_removes_the_directory() {
        use std::os::unix::fs::FileTypeExt;

        let dir = gateway_test_dir("bind");
        let mut server = gateway_server(&dir);
        let line = reply(server.handle(
            "{\"cmd\":\"gateway\",\"action\":\"bind\",\"call_in\":\"jawn_call_in\"}",
        ));
        assert!(line.contains("\"ok\":true"), "bind: {line}");
        assert!(line.contains("\"monitor\":\"helper\""), "bind: {line}");
        assert!(line.contains("\"call_in\":\""), "bind: {line}");

        let call_dir = dir.join(format!("gateway-{}", std::process::id()));
        let call_in = call_dir.join("call_in");
        let prompt = call_dir.join("prompt");
        assert!(call_in.is_absolute(), "{} is not absolute", call_in.display());
        assert!(prompt.is_absolute(), "{} is not absolute", prompt.display());
        assert!(
            line.contains(call_in.to_str().expect("UTF-8 path")),
            "the reply does not name the call_in FIFO: {line}"
        );
        assert!(
            line.contains(prompt.to_str().expect("UTF-8 path")),
            "the reply does not name the prompt FIFO: {line}"
        );
        assert!(
            fs::metadata(&call_in).expect("call_in exists").file_type().is_fifo(),
            "call_in is not a FIFO"
        );
        assert!(
            fs::metadata(&prompt).expect("prompt exists").file_type().is_fifo(),
            "prompt is not a FIFO"
        );

        // The prompt port is open and idle; its `pacat` waits for a byte.
        assert!(
            line.contains("\"prompt\":\"writing\""),
            "an idle prompt port still answers writing: {line}"
        );

        let released = reply(server.handle("{\"cmd\":\"gateway\",\"action\":\"release\"}"));
        assert!(released.contains("\"call_in\":\"off\""), "release: {released}");
        assert!(
            !call_dir.exists(),
            "release left {} behind",
            call_dir.display()
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_drain_writes_ten_millisecond_mono_frames_to_call_in() {
        let dir = gateway_test_dir("drain");
        let fifo = dir.join("call_in");
        make_fifo(&fifo).expect("make the call_in FIFO");
        let mut reader = OpenOptions::new()
            .read(true)
            .custom_flags(O_NONBLOCK)
            .open(&fifo)
            .expect("open the reading end");

        let (producer, consumer) = MonitorBus::new(4096);
        let frames = vec![0.5f32; GATEWAY_DRAIN_FRAMES];
        let mut stereo = Vec::with_capacity(GATEWAY_DRAIN_FRAMES * 2);
        for value in frames {
            stereo.push(value);
            stereo.push(value);
        }
        assert_eq!(producer.push(&stereo), 0, "the fake ring holds one block");

        let counters = GatewayCounters::default();
        let mut block = vec![0.0f32; GATEWAY_DRAIN_FRAMES * 2];
        let mut mono = vec![0u8; GATEWAY_DRAIN_FRAMES * 2];
        let mut port = CallInPort::new(fifo, counters.dropped.clone());
        drain_gateway(&consumer, &counters, &mut block, &mut mono, &mut port);

        // One 10 ms frame at 8 kHz mono s16le is 160 bytes.
        let mut got = Vec::new();
        let mut buffer = [0u8; 512];
        let deadline = Instant::now() + Duration::from_secs(2);
        while got.len() < 160 && Instant::now() < deadline {
            match reader.read(&mut buffer) {
                Ok(0) => thread::sleep(Duration::from_millis(5)),
                Ok(count) => got.extend_from_slice(&buffer[..count]),
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(5))
                }
                Err(error) => panic!("read call_in: {error}"),
            }
        }
        assert_eq!(got.len(), 160, "one 10 ms mono frame was written");
        let sample = i16::from_le_bytes([got[0], got[1]]);
        assert!(
            (i32::from(sample) - i32::from(to_i16(0.5))).abs() <= 1,
            "the stereo ring was not downmixed: {sample}"
        );
        let (counted, peak, dropped) = counters.read();
        assert_eq!(counted, GATEWAY_DRAIN_FRAMES as u64, "the frame count survived");
        assert!((peak - 0.5).abs() < 1e-6, "the peak survived: {peak}");
        assert_eq!(dropped, 0, "nothing was dropped");

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_full_call_in_pipe_drops_the_frame_and_counts_it() {
        let dir = gateway_test_dir("full");
        let fifo = dir.join("call_in");
        make_fifo(&fifo).expect("make the call_in FIFO");
        // A reader that never reads: the pipe fills and stays full.
        let _reader = OpenOptions::new()
            .read(true)
            .custom_flags(O_NONBLOCK)
            .open(&fifo)
            .expect("open the reading end");

        let counters = GatewayCounters::default();
        let mut port = CallInPort::new(fifo, counters.dropped.clone());
        let frame = [0u8; 160];
        for _ in 0..1000 {
            port.write_frame(&frame);
        }
        assert!(
            counters.read().2 > 0,
            "a full pipe must drop and count rather than block"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_full_gateway_ring_drops_frames_and_the_count_and_peak_still_answer() {
        // The smallest ring `monbus` offers; one frame more than it holds is
        // the burst a late drain would see.
        let (producer, consumer) = MonitorBus::new(4096);
        let pushed = 4096 + 16;
        let block: Vec<f32> = (0..pushed)
            .flat_map(|frame| {
                if frame % 2 == 0 {
                    [0.5f32, -0.75]
                } else {
                    [-0.25, 0.125]
                }
            })
            .collect();
        assert_eq!(
            producer.push(&block),
            16,
            "a full ring drops the newest frames rather than blocking"
        );

        let dir = gateway_test_dir("ring");
        let fifo = dir.join("call_in");
        make_fifo(&fifo).expect("make the call_in FIFO");
        let mut reader = OpenOptions::new()
            .read(true)
            .custom_flags(O_NONBLOCK)
            .open(&fifo)
            .expect("open the reading end");

        let counters = GatewayCounters::default();
        let mut block = vec![0.0f32; GATEWAY_DRAIN_FRAMES * 2];
        let mut mono = vec![0u8; GATEWAY_DRAIN_FRAMES * 2];
        let mut port = CallInPort::new(fifo, counters.dropped.clone());
        drain_gateway(&consumer, &counters, &mut block, &mut mono, &mut port);
        let (frames, peak, _) = counters.read();
        assert_eq!(frames, 4096, "the drain kept every frame the ring held");
        assert!((peak - 0.75).abs() < 1e-6, "the peak survived the drop: {peak}");

        // Drain what the pipe took; the ring is empty now, and a second drain
        // adds nothing.
        let mut sink = Vec::new();
        let mut buffer = [0u8; 4096];
        while let Ok(count) = reader.read(&mut buffer) {
            if count == 0 {
                break;
            }
            sink.extend_from_slice(&buffer[..count]);
        }
        drain_gateway(&consumer, &counters, &mut block, &mut mono, &mut port);
        assert_eq!(counters.read().0, 4096);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_bind_volume_is_clamped_like_the_mixers_phone_gain() {
        let volume = |line: &str| parse_prompt_volume(&parse_object(line).expect("an object"));
        assert_eq!(volume("{\"volume\":37}"), Ok(Some(37)));
        assert_eq!(volume("{\"volume\":0}"), Ok(Some(0)));
        assert_eq!(volume("{\"volume\":100}"), Ok(Some(100)));
        assert_eq!(volume("{\"volume\":150}"), Ok(Some(100)), "over the top clamps");
        assert_eq!(volume("{\"volume\":-5}"), Ok(Some(0)), "under zero clamps");
        assert_eq!(volume("{\"volume\":42.6}"), Ok(Some(43)), "the mixer rounds");
        assert_eq!(volume("{\"call_in\":\"jawn_call_in\"}"), Ok(None), "absent is omitted");
        assert_eq!(volume("{\"volume\":null}"), Ok(None), "null is omitted too");
        assert!(
            volume("{\"volume\":\"loud\"}").is_err(),
            "a non-number is a refusal, not a silent 100%"
        );
    }

    #[test]
    fn a_retry_clock_becomes_poll_milliseconds_and_nothing_is_a_block() {
        let now = Instant::now();
        assert_eq!(wait_millis(None, now), -1, "nothing pending blocks in poll");
        assert_eq!(wait_millis(Some(now), now), 0, "a due retry polls at once");
        assert_eq!(
            wait_millis(Some(now + Duration::from_millis(500)), now),
            500,
            "the interval reaches poll unchanged"
        );
        assert_eq!(
            wait_millis(Some(now + Duration::from_micros(1_500)), now),
            2,
            "a fraction of a millisecond rounds up instead of spinning"
        );
    }

    #[test]
    fn a_silent_bind_asks_the_serve_loop_to_look_again() {
        let mut gateway = Gateway::off(false);
        assert_eq!(gateway.next_tick(), None, "an idle gateway has no deadline");
        let next = Instant::now() + GATEWAY_RETRY;
        gateway.retry = Some(BindRetry {
            sink: "jawn_call_in".to_string(),
            next,
            deadline: next + GATEWAY_RETRY_FOR,
        });
        assert_eq!(gateway.next_tick(), Some(next), "the retry is the next look");
    }

    #[test]
    fn a_wait_with_no_retry_blocks_until_the_client_speaks() {
        let (reader, mut writer) = UnixStream::pair().expect("a socket pair");
        reader.set_nonblocking(true).expect("non-blocking reader");
        let fd = reader.as_raw_fd();
        let talker = thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            let _ = writer.write_all(b"{\"cmd\":\"status\"}\n");
        });
        let started = Instant::now();
        wait_readable(&[fd], None).expect("wait");
        let waited = started.elapsed();
        assert!(
            waited >= Duration::from_millis(20),
            "the wait returned before a line was written: {waited:?}"
        );
        let mut buffer = [0u8; 64];
        let got = (&reader).read(&mut buffer).expect("read");
        assert_eq!(&buffer[..got], b"{\"cmd\":\"status\"}\n");
        talker.join().expect("talker");
    }

    #[test]
    fn a_pending_retry_bounds_the_wait_when_the_client_says_nothing() {
        let (reader, _writer) = UnixStream::pair().expect("a socket pair");
        reader.set_nonblocking(true).expect("non-blocking reader");
        let fd = reader.as_raw_fd();
        let started = Instant::now();
        wait_readable(&[fd], Some(Instant::now() + Duration::from_millis(30)))
            .expect("wait");
        let waited = started.elapsed();
        assert!(
            waited >= Duration::from_millis(15),
            "the wait did not reach the retry clock: {waited:?}"
        );
        assert!(
            waited < Duration::from_secs(10),
            "the retry clock did not bound the wait: {waited:?}"
        );
    }
}
