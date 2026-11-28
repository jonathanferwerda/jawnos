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
//! # The live monitor
//!
//! Studio's controller picker can name another machine's Studio and hear it on
//! the controller's own Music receiver. `{"cmd":"monitor","action":"start",
//! "port":0}` binds a loopback TCP listener and answers the port; the transport
//! pushes every finished block through [`jawn_audio::stream::TapSource`] after the
//! master rack, and the writer thread sends little-endian S16LE stereo. A patch
//! that owns the output instead feeds the same ring from its final mix, so the
//! stream follows the engine's output bus rather than one transport. With no
//! client attached the writer drains and discards, so a late listener never
//! starts on stale audio. `monitor stop` closes it and `status` reports the
//! `stream` object and its `streaming` flag. The engine's control socket stays
//! one line per request; the stream is the only continuous channel.
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
//! `none`. The take reports `first_sample`, where its first stored frame
//! actually sits (the stamp less that offset). Capture still begins when the
//! device opens, so a device's own start delay and clock drift are not
//! measured and never guessed. That is a start correction, not a drift model.
//! One `stop` signals both before joining either, and `status` reports the
//! take's state with `playing`, `monitor_frames`, the alignment and the
//! monitor strips beside it. Two takes at once, or two playbacks at once, are still refused.
//!
//! The transport follows the same shape: it owns one output thread, so a take
//! that asks for no monitor may record beside it and the transport plays its
//! clips. A take that asks for monitor files or its own click still needs an
//! output of its own, so it refuses while the transport plays: the transport
//! already plays the takes and owns the metronome. Its live input is the one
//! exception, because it rides the transport's own bus through the same master
//! chain; `record` attaches that ring to the transport's render thread, and
//! `{"cmd":"record","action":"stop"}` detaches it while the transport keeps
//! playing. `status` leads with the take and reports the transport beside it.

use std::collections::HashMap;
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
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use jawn_audio::{
    listen::{self, ListenPlan, ListenSink, ListenUnit},
    monitor_start, plan::PlanInsert, to_i16, BackendKind, Channel, ClickSpec, Consumer, Device,
    DiskWriter, InsertKind, Mixer, MonitorBus, MonitorSpec, NullDevice, ParamName, ParamQueue,
    PlayTrack, Playback, Producer, TransportClip, TransportControl, TransportLive, TransportPlan,
    TransportSource, MASTER_ORDER,
};
use jawn_audio::playback::{AppRoute, DrumChart, SynthClip, SynthNote, SynthPlan, TransportHit, TransportNote};
use jawn_drums::{Kit, Performance, Player, Style, Voice};
use jawn_synth::{Engine as SynthEngine, Envelope, FilterKind, Patch, Wave};
use jawn_audio::uplink::{Uplink, UplinkConfig, UplinkSourceSpec, UplinkStatus};

use crate::patchbay::{PatchSummary, Patchbay};
use jawn_audio::stream::{MonitorControl, MonitorTap};
use jawn_audio::pipewire_guard::{PlaybackGuard, FEEDBACK_PREFIX};
use jawn_audio::playback::{RenderSource, StandaloneClick};

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

/// A value may hold an object (a take's `tracks` plan or a source insert's
/// `controls` map), so the plan's own nesting is allowed: this bounds a caller
/// that nests objects without limit. The deepest legitimate plan is
/// `plan > source > insert > controls`, four objects.
const MAX_VALUE_DEPTH: usize = 4;

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
    /// The peer uplink, when `--serve --uplink ADDR` named one. `None` leaves
    /// every `peer` source pending; a peer source never opens its own port.
    pub uplink: Option<UplinkConfig>,
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
    /// cannot share a machine with a take, a playback or a listen. The one
    /// exception is a bus take: it records a running patch's bus through the
    /// patchbay's tap, so it needs the patch and adds no device.
    patch: Option<PatchSession>,
    /// The most recent bus take, kept after it ends so `status` can report the
    /// final WAV. At most one runs, and only beside a patch.
    bus_take: Option<BusTakeSession>,
    /// The most recent transport, kept after it stops so `transport status`
    /// and `seek` can describe a resting position. A transport owns an output
    /// like a playback, so it cannot start beside one; a take that captures
    /// without a monitor can record beside it, because the two use different
    /// device streams.
    transport: Option<TransportSession>,
    /// The decoded takes the control thread has already read, so a placement
    /// update reuses megabytes instead of re-decoding them. It lives beside the
    /// transport and is touched only from `transport start`/`update`.
    take_cache: TakeCache,
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
    /// The live monitor tap. It exists for the process's lifetime; `start` and
    /// `stop` only change what its writer thread serves, so the transport and
    /// the house patch may take turns feeding it beneath one stable tap. The
    /// audio thread pushes into its lock-free ring and never waits on a client.
    monitor: MonitorTap,
    /// The uplink's published state. One patch at a time owns the binding, but
    /// the status object outlives a patch, so this is the server's. `off` or
    /// `idle` until a patch with a peer source starts the thread.
    uplink: Arc<Mutex<UplinkStatus>>,
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
        let uplink = Arc::new(Mutex::new(if config.uplink.is_some() {
            UplinkStatus::idle()
        } else {
            UplinkStatus::off()
        }));
        Server {
            config,
            current: None,
            playback: None,
            listen: None,
            patch: None,
            bus_take: None,
            transport: None,
            take_cache: TakeCache::default(),
            stop,
            wake,
            gateway: Gateway::off(capable),
            next_take: 1,
            boot: BootPlan::Error("no audio plan file configured".to_string()),
            monitor: MonitorTap::new(),
            uplink,
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
        // The live monitor follows the engine's output bus, not the transport.
        // While this patch owns the outputs it feeds the same ring the transport
        // taps, so a controller keeps hearing the house mix across either one.
        patchbay.attach_monitor(self.monitor.control().producer());
        // A plan that declares a handset source gets the reception mixer's call
        // monitor captured here; one that does not runs no extra `parec`. A
        // missing sink silences the node and leaves the rest of the patch up.
        let handset = attach_handset(&mut patchbay, &self.config);

        // Every routed `peer` source gets one ring; the uplink owns the
        // producer and the patch bay the consumer. `--uplink` is the only way
        // a peer can receive anything, so without it the sources stay pending
        // and the rest of the plan runs. A bind failure is reported here and
        // never stops the patch: a peer is a source, not the device.
        let mut uplink = None;
        let peer_sources = patchbay.wants_peer();
        if let Some(uplink_config) = self.config.uplink.clone() {
            if peer_sources.is_empty() {
                *self
                    .uplink
                    .lock()
                    .unwrap_or_else(|poisoned| poisoned.into_inner()) = UplinkStatus::idle();
            } else {
                let mut specs = Vec::with_capacity(peer_sources.len());
                let mut consumers = Vec::with_capacity(peer_sources.len());
                for (index, id, latency_ms, buffer_ms) in peer_sources {
                    let (producer, consumer) =
                        jawn_audio::monbus::new(jawn_audio::monbus::MIN_FRAMES);
                    specs.push(UplinkSourceSpec {
                        index,
                        id,
                        producer,
                        latency_ms,
                        buffer_ms,
                    });
                    consumers.push((index, consumer));
                }
                match Uplink::start(
                    &uplink_config,
                    self.config.rate,
                    Arc::clone(&self.uplink),
                    specs,
                ) {
                    Ok(started) => {
                        for (index, consumer) in consumers {
                            patchbay.attach_input(index, consumer);
                        }
                        uplink = Some(started);
                    }
                    Err(error) => {
                        eprintln!("jawn-audio: uplink: {error}");
                        *self
                            .uplink
                            .lock()
                            .unwrap_or_else(|poisoned| poisoned.into_inner()) =
                            UplinkStatus::failed(error);
                    }
                }
            }
        } else {
            *self
                .uplink
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()) = UplinkStatus::off();
        }

        let summary = patchbay.summary().clone();
        let params = patchbay.params();
        let source_params = patchbay.source_params();
        let source_inserts = patchbay.source_inserts();
        let bus_ids = patchbay.bus_ids().to_vec();
        let tap = patchbay.tap();
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
        let alive = Arc::new(AtomicBool::new(true));
        let spawned = {
            let status = Arc::clone(&status);
            let stop = Arc::clone(&stop);
            let alive = Arc::clone(&alive);
            let config = self.config.clone();
            thread::Builder::new()
                .name("jawn-audio-patch".to_string())
                .spawn(move || run_patch_worker(config, patchbay, status, stop, alive, system_device))
        };
        match spawned {
            Ok(handle) => {
                self.patch = Some(PatchSession {
                    status,
                    stop,
                    handle: Some(handle),
                    params,
                    source_params,
                    source_inserts,
                    executable,
                    handset,
                    uplink,
                    bus_ids,
                    tap,
                    alive,
                });
                Ok(summary)
            }
            Err(error) => Err(format!("cannot start the patch thread: {error}")),
        }
    }

    /// Append `machine`, the boot-restore outcome (`plan` or `plan_error`) and
    /// the uplink's state to a status object, without changing any key already
    /// present.
    fn add_boot(&self, line: String) -> String {
        let head = match line.strip_suffix('}') {
            Some(head) => head,
            None => return line,
        };
        let uplink = self
            .uplink
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .json();
        match &self.boot {
            BootPlan::Armed(summary) => format!(
                "{head},\"machine\":\"{}\",\"plan\":{{{}}},{},\"uplink\":{}}}",
                jawn_audio::loopback::json_escape(&self.config.machine),
                summary.json(),
                self.gateway.fragment(),
                uplink
            ),
            BootPlan::Error(message) => format!(
                "{head},\"machine\":\"{}\",\"plan_error\":\"{}\",{},\"uplink\":{}}}",
                jawn_audio::loopback::json_escape(&self.config.machine),
                jawn_audio::loopback::json_escape(message),
                self.gateway.fragment(),
                uplink
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
        if let Some(session) = &self.bus_take {
            session.stop.store(true, Ordering::SeqCst);
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
        if let Some(session) = &mut self.bus_take {
            session.finish();
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
        // The monitor writer is process state, not a role; a clean quit closes
        // its listener and client so no controller is left reading silence.
        self.monitor.finish();
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
            "transport" => Action::Reply(self.transport_command(&object)),
            "monitor" => Action::Reply(self.monitor_command(&object)),
            "synth" => Action::Reply(self.synth_command(&object)),
            "drums" => Action::Reply(self.drums_command(&object)),
            "gateway" => Action::Reply(self.gateway_command(&object)),
            "unpatch" => Action::Reply(self.unpatch_line()),
            "param" => Action::Reply(self.param(&object)),
            "status" => Action::Reply(self.status_line()),
            "stop" => Action::Reply(self.stop_line()),
            "quit" => Action::Quit("{\"ok\":true}".to_string()),
            _ => Action::Reply(error_line("unknown command")),
        }
    }

    /// `{"cmd":"monitor","action":"start","port":0}`: a live stream of the
    /// engine's final stereo output over loopback TCP. `start` binds the port,
    /// answers the one actually granted, and leaves the writer serving; `stop`
    /// closes it and drops the client; `status` answers the tap's object alone.
    /// An already-running tap is rebound to the new port rather than refused, so
    /// the manager can replace a controller without a second command.
    fn monitor_command(&mut self, object: &Object) -> String {
        let action = match get(object, "action") {
            Some(Value::Str(action)) => action.as_str(),
            _ => return error_line("monitor needs \"action\": start, stop or status"),
        };
        match action {
            "start" => {
                let port = match get(object, "port") {
                    None | Some(Value::Null) => 0,
                    Some(Value::Num(value))
                        if value.is_finite()
                            && *value >= 0.0
                            && value.fract() == 0.0
                            && *value <= 65_535.0 =>
                    {
                        *value as u16
                    }
                    _ => return error_line("\"port\" must be 0 or a whole number from 1 to 65535"),
                };
                match self.monitor.control().start(port) {
                    Ok(bound) => format!(
                        "{{\"ok\":true,\"action\":\"start\",\"stream\":true,\"streaming\":{},\"port\":{},\"rate\":{},\"channels\":{}}}",
                        self.monitor.control().is_streaming(),
                        bound,
                        jawn_audio::stream::MONITOR_RATE,
                        jawn_audio::stream::MONITOR_CHANNELS
                    ),
                    Err(error) => error_line(&format!("cannot start the monitor stream: {error}")),
                }
            }
            "stop" => {
                self.monitor.control().stop();
                "{\"ok\":true,\"action\":\"stop\",\"stream\":false,\"streaming\":false,\"port\":0}"
                    .to_string()
            }
            "status" => {
                let control = self.monitor.control();
                format!(
                    "{{\"ok\":true,\"action\":\"status\",\"stream\":{},\"streaming\":{},\"port\":{}}}",
                    control.status_fragment(),
                    control.is_streaming(),
                    control.port()
                )
            }
            _ => error_line("choose a monitor action: start, stop or status"),
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
            Some(Value::Str(target)) if target == "patch_source" => {
                self.param_patch_source(object)
            }
            _ => error_line("\"target\" must be \"take\", \"monitor\", \"input\", \"listen\", \"master\", \"patch\" or \"patch_source\""),
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
            // A take armed with `monitor_input` off beside the transport parked
            // its ring in `Running`; the transport is the output, so pressing
            // Monitor mid-take attaches the ring there. Opening a playback here
            // would ask for the output the transport already owns.
            let transport_playing = self
                .transport
                .as_ref()
                .map(TransportSession::is_playing)
                .unwrap_or(false);
            if transport_playing {
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
                let attached = self
                    .transport
                    .as_mut()
                    .map(|session| session.attach_live(consumer, Arc::clone(&gain)))
                    .unwrap_or(false);
                if !attached {
                    return error_line(
                        "the transport is no longer playing; the take's live input could not be attached",
                    );
                }
                armed.store(true, Ordering::Release);
                if let Some(running) = &self.current {
                    let mut status = running
                        .status
                        .lock()
                        .unwrap_or_else(|poisoned| poisoned.into_inner());
                    status.monitor_input = true;
                }
                return input_line(clamped, true);
            }
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
                            None,
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

    /// The same knobs, addressed to a patch route: `"target":"patch"`.
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

    /// A source's own trim or one of its insert knobs:
    /// `{"cmd":"param","target":"patch_source","source":0,
    /// "name":"distortion.drive","value":75}`. The source index is the
    /// 0-based position in the plan's `sources` array. `gain` moves the trim
    /// before the chain; an `<insert>.<control>` name is accepted only when
    /// the source actually declared that insert, so a typo is a refusal rather
    /// than a knob the audio thread silently drops.
    fn param_patch_source(&mut self, object: &Object) -> String {
        let source = match get(object, "source") {
            Some(Value::Num(value))
                if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 =>
            {
                *value as usize
            }
            _ => return error_line("param needs \"source\": a 0-based source number"),
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
        if source >= session.source_inserts.len() {
            return error_line(&format!(
                "no source {source} (the plan has {})",
                session.source_inserts.len()
            ));
        }
        let parameter = match ParamName::parse(name) {
            Some(parameter) if !parameter.master() => parameter,
            _ => return error_line(&format!("no such parameter: {name}")),
        };
        match parameter.insert_kind() {
            None => {
                if !matches!(parameter.control(), "gain" | "mute") {
                    return error_line(
                        "a patch source carries \"gain\", \"mute\" or an <insert>.<control> name",
                    );
                }
            }
            Some(kind) => {
                let armed = session.source_inserts[source]
                    .iter()
                    .any(|candidate| candidate.name() == kind.name());
                if !armed {
                    return error_line(&format!(
                        "source {source} has no {} insert",
                        kind.name()
                    ));
                }
            }
        }
        if !session.source_params.push(source, parameter, value) {
            return error_line("the parameter queue is full; try again next block");
        }
        // The audio thread owns the chain; this mirror is what `status` reads.
        if parameter.insert_kind().is_none() {
            let mut status = session
                .status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some(effects) = status.summary.source_effects.get_mut(source) {
                match parameter.control() {
                    "gain" => effects.gain = Channel::clamp_gain(value),
                    "mute" => effects.mute = value >= 0.5,
                    _ => {}
                }
            }
        }
        format!(
            "{{\"ok\":true,\"target\":\"patch_source\",\"source\":{},\"name\":\"{}\"}}",
            source,
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
        // A scoped stop: end the listen and nothing else. The transport keeps
        // playing (and any recording take keeps recording), because the listen
        // is only one live input on the transport's output.
        if matches!(get(object, "action"), Some(Value::Str(action)) if action == "stop") {
            return self.listen_stop();
        }
        // A playing transport owns the output. The listen no longer opens a
        // second one: its worker builds the capture and the strip and hands the
        // finished stereo to the transport's render through the same live slot a
        // take uses. Every other user of the outputs keeps its refusal.
        let transport_playing = self
            .transport
            .as_ref()
            .map(TransportSession::is_playing)
            .unwrap_or(false);
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

        // One input is the historical `channel`; several are a `channels`
        // array. The array is what lets Studio monitor two inputs at once, and
        // every one gets its own strip, so each input's inserts are still its
        // own. Giving both is ambiguous and refused rather than guessed.
        let has_channel = matches!(get(object, "channel"), Some(value) if !matches!(value, Value::Null));
        let has_channels =
            matches!(get(object, "channels"), Some(value) if !matches!(value, Value::Null));
        if has_channel && has_channels {
            return error_line("give \"channel\" or \"channels\", not both");
        }
        let channels = if has_channels {
            match get(object, "channels") {
                Some(Value::Arr(values)) if !values.is_empty() => {
                    let mut channels = Vec::with_capacity(values.len());
                    for value in values {
                        match value {
                            Value::Num(value)
                                if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 =>
                            {
                                channels.push(*value as usize)
                            }
                            _ => {
                                return error_line(
                                    "\"channels\" must hold whole, non-negative input numbers",
                                )
                            }
                        }
                    }
                    channels
                }
                Some(Value::Arr(_)) => {
                    return error_line("\"channels\" must name at least one input")
                }
                _ => return error_line("\"channels\" must be an array of input numbers"),
            }
        } else {
            let channel = match get(object, "channel") {
                None | Some(Value::Null) => 0,
                Some(Value::Num(value))
                    if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 =>
                {
                    *value as usize
                }
                _ => return error_line("\"channel\" must be a whole, non-negative input number"),
            };
            vec![channel]
        };
        let mut seen_channels: Vec<usize> = Vec::with_capacity(channels.len());
        for channel in &channels {
            if *channel >= self.config.channels {
                return error_line(&format!(
                    "listen channel {channel} is outside the {}-channel device: restart the engine with a larger --channels",
                    self.config.channels
                ));
            }
            if seen_channels.contains(channel) {
                return error_line(&format!("listen channel {channel} is named twice"));
            }
            seen_channels.push(*channel);
        }
        let channel = channels[0];
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
        let master = match parse_master(get(object, "master")) {
            Ok(kinds) => kinds,
            Err(error) => return error_line(&error),
        };
        let master_values = match parse_master_values(get(object, "master_values")) {
            Ok(values) => values.unwrap_or_default(),
            Err(error) => return error_line(&error),
        };
        // The rack is one bus after the sum, so it has no place in a listen
        // that sums several inputs; refusing is honest, applying it per input
        // would run it once per channel.
        if channels.len() > 1 && !master.is_empty() {
            return error_line("a master rack needs one input: monitor one channel to hear it");
        }
        // A monitor that folds the machine's system mix into its output can hear
        // the page that is monitoring it, which is a feedback loop on one card.
        // `system` lets Studio's input monitor carry only its own capture; the
        // standalone Listen keeps the mix by default.
        let system = match get(object, "system") {
            None | Some(Value::Null) => true,
            Some(Value::Bool(value)) => *value,
            _ => return error_line("\"system\" must be a boolean"),
        };
        if let Err(error) = crate::listen_support(self.config.backend) {
            return error_line(&error);
        }

        // Join a finished listener before replacing it, so a sequence of
        // listens does not leave detached threads behind. A listener riding the
        // transport leaves its live slot before the next attach claims it.
        if let Some(mut previous) = self.listen.take() {
            if let Some(transport) = &mut self.transport {
                transport.detach_listen_live();
            }
            previous.finish();
        }

        // A listen riding the transport joins that render's bus before the
        // transport's master chain, so running the listen's own rack would
        // master the same signal twice. The standalone listen keeps the rack;
        // the riding one lets the transport's one mastering pass cover it.
        let master = if transport_playing {
            Vec::new()
        } else {
            master_plan(&master, master_values)
        };
        let plan = ListenPlan {
            channel,
            channels: channels.clone(),
            gain,
            pan,
            inserts,
            master,
        };
        let inserts_text = plan.insert_list();
        // The reply keeps the old single-input shape exactly; a multi listen
        // names every input it is monitoring.
        let multi = channels.len() > 1;
        let channel_list = channels
            .iter()
            .map(|channel| channel.to_string())
            .collect::<Vec<String>>()
            .join(",");
        let status = Arc::new(Mutex::new(ListenStatus {
            state: State::Listening,
            channel,
            channels,
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
        // A listen beside a playing transport opens no output of its own: its
        // capture and strip run on this worker, and the finished stereo joins
        // the transport's render through the one live slot a take already uses.
        // The attach is a block-edge edge, so the device never reopens and the
        // clips and click never gap.
        let bus = if transport_playing {
            let (producer, consumer) = MonitorBus::new(MONITOR_RING_FRAMES);
            let attached = match &mut self.transport {
                Some(session) if session.is_playing() => session.attach_listen(consumer),
                _ => false,
            };
            if !attached {
                return error_line(
                    "the transport is no longer playing; the listen could not be attached",
                );
            }
            Some(producer)
        } else {
            None
        };
        let spawned = {
            let status = Arc::clone(&status);
            let stop = Arc::clone(&stop);
            let params = Arc::clone(&params);
            let mut config = self.config.clone();
            // The standalone Listen keeps the house mix. A listen riding the
            // transport does not capture it: the transport's own output is that
            // mix, and folding it back in would be a feedback loop.
            if !system || transport_playing {
                config.system_device = None;
            }
            thread::Builder::new()
                .name("jawn-audio-listen".to_string())
                .spawn(move || run_listen_worker(config, plan, status, stop, params, bus))
        };
        match spawned {
            Ok(handle) => {
                self.listen = Some(ListenSession {
                    status,
                    stop,
                    handle: Some(handle),
                    params,
                });
                if multi {
                    format!(
                        "{{\"ok\":true,\"state\":\"listening\",\"channel\":{channel},\"channels\":[{channel_list}]}}"
                    )
                } else {
                    format!("{{\"ok\":true,\"state\":\"listening\",\"channel\":{channel}}}")
                }
            }
            Err(error) => {
                if transport_playing {
                    if let Some(session) = &mut self.transport {
                        session.detach_listen_live();
                    }
                }
                error_line(&format!("cannot start the listen thread: {error}"))
            }
        }
    }

    /// `{"cmd":"listen","action":"stop"}`: end the listen and nothing else.
    ///
    /// A listen may be riding the transport's output, so this detaches only the
    /// listen's live input. The transport keeps playing its clips and click and
    /// a recording take keeps recording, which is why the Studio route uses
    /// this instead of the global stop.
    fn listen_stop(&mut self) -> String {
        let listening = self
            .listen
            .as_ref()
            .map(ListenSession::is_listening)
            .unwrap_or(false);
        if !listening {
            return error_line("no listen is running");
        }
        // Signal the worker, then detach its slot before joining, so the next
        // block is already silence while the capture loop finishes.
        if let Some(session) = &self.listen {
            session.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &mut self.transport {
            session.detach_listen_live();
        }
        if let Some(session) = &mut self.listen {
            session.finish();
        }
        match &self.listen {
            Some(session) => session.line(),
            None => idle_line(),
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
        if let Some(session) = &self.transport {
            if session.is_playing() {
                return error_line(
                    "the transport is playing; stop it before patching. Sharing the transport's output with the patchbay is the next stage",
                );
            }
        }
        if let Some(running) = &self.current {
            if running.is_recording() {
                return error_line(
                    "a take is recording; the patchbay needs the capture and the outputs. Stop the take before patching",
                );
            }
        }
        if let Some(session) = &self.bus_take {
            if session.is_recording() {
                return error_line(
                    "a bus take is recording the running patch; stop the take before replacing the patch",
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
        // A finished bus take belonged to the patch that just ended; a running
        // one was refused above.
        if let Some(mut previous) = self.bus_take.take() {
            previous.finish();
        }
        format!(
            "{{\"ok\":true,\"state\":\"patching\",{},{}}}",
            summary.json(),
            self.gateway.fragment()
        )
    }

    /// `{"cmd":"record","out":...,"bus":"<bus-id>","seconds":N}`: record
    /// one bus of the running patch to a WAV.
    ///
    /// The patchbay keeps the device and the capture; this attaches a ring to
    /// the named bus and a writer thread to the ring, so the same patch can
    /// feed the Studio take (guitar, voice and a peer in one file) while it is
    /// playing. A click travels to the patch's output only: it is rendered
    /// after the bus has been tapped, so the performer hears it and the WAV
    /// cannot. Everything a normal take owns — tracks, monitor files, the live
    /// input, the mastering rack — is refused here by name; a request without
    /// `bus` still takes the path it always did.
    fn record_bus(&mut self, object: &Object, bus: &str) -> String {
        if bus.trim().is_empty() {
            return error_line("\"bus\" must name one bus from the running patch");
        }
        if let Some(running) = &self.current {
            if running.is_recording() {
                return error_line("a take is already running");
            }
        }
        if let Some(session) = &self.bus_take {
            if session.is_recording() {
                return error_line("a bus take is already running");
            }
        }
        // Fields that only a normal take has. `click` is deliberately not one:
        // it is monitoring, and a bus take puts it on the patch's output.
        for key in ["tracks", "inputs", "master", "align_samples", "calibrate"] {
            if matches!(get(object, key), Some(value) if !matches!(value, Value::Null)) {
                return error_line(&format!(
                    "\"{key}\" belongs to a normal take; a bus take records the running patch's bus"
                ));
            }
        }
        match get(object, "monitor") {
            None | Some(Value::Null) => {}
            Some(Value::Arr(files)) if files.is_empty() => {}
            Some(_) => {
                return error_line(
                    "a bus take records the patch's bus; monitor files belong to a normal take",
                )
            }
        }
        match get(object, "monitor_input") {
            None | Some(Value::Null) => {}
            Some(Value::Bool(false)) => {}
            Some(Value::Bool(true)) => {
                return error_line(
                    "a bus take records the patch's bus; the live input belongs to a normal take",
                )
            }
            Some(_) => return error_line("\"monitor_input\" must be true or false"),
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
        // The click is parsed before a file or thread exists, exactly as a
        // normal take parses it.
        let click = match parse_click(get(object, "click")) {
            Ok(click) => click,
            Err(error) => return error_line(&error),
        };

        // The patch and the bus it names, resolved before any file exists. A
        // name the compiled plan does not have is refused by name.
        let (index, tap, alive, bus_name) = {
            let Some(session) = self.patch.as_ref().filter(|session| session.is_patching())
            else {
                return error_line(
                    "no patch is running; a bus take records a running patch's bus. Start the patch, or record a normal take",
                );
            };
            let Some(index) = session.bus_ids.iter().position(|id| id == bus) else {
                let known = if session.bus_ids.is_empty() {
                    "none".to_string()
                } else {
                    session.bus_ids.join(", ")
                };
                return error_line(&format!(
                    "the patch has no bus \"{bus}\"; its buses are: {known}"
                ));
            };
            (
                index,
                Arc::clone(&session.tap),
                Arc::clone(&session.alive),
                session.bus_ids[index].clone(),
            )
        };

        let frames = take_frames(seconds, self.config.rate);
        let queue = crate::queue_blocks(
            self.config.backend,
            frames,
            self.config.period,
            TAKE_CHANNELS,
        );
        let disk = match DiskWriter::spawn(
            Path::new(&path),
            self.config.rate,
            TAKE_CHANNELS as u16,
            self.config.period,
            queue,
        ) {
            Ok(disk) => disk,
            Err(error) => return error_line(&format!("cannot write {path}: {error}")),
        };

        let (producer, consumer) = MonitorBus::new(MONITOR_RING_FRAMES);
        let ring_dropped = producer.dropped_handle();
        let click = click.map(|spec| {
            StandaloneClick::new(spec, self.config.rate, self.config.period)
        });
        if !tap.attach(index, producer, click) {
            let _ = disk.finish();
            let _ = fs::remove_file(&path);
            return error_line(&format!("the patch has no bus \"{bus}\""));
        }

        // A finished bus take is only a status line now; a recording one was
        // refused above.
        if let Some(mut previous) = self.bus_take.take() {
            previous.finish();
        }
        let take = self.next_take;
        self.next_take += 1;
        let status = Arc::new(Mutex::new(BusTakeStatus {
            take,
            state: State::Recording,
            path: path.clone(),
            bus: bus_name,
            frames: 0,
            dropped: 0,
            total_frames: frames,
            start_sample: start_at,
            error: String::new(),
        }));
        let stop = Arc::new(AtomicBool::new(false));
        let spawn = {
            let status = Arc::clone(&status);
            let stop = Arc::clone(&stop);
            let tap = Arc::clone(&tap);
            let period = self.config.period;
            thread::Builder::new()
                .name("jawn-audio-bus-take".to_string())
                .spawn(move || {
                    run_bus_take(
                        period,
                        frames,
                        disk,
                        consumer,
                        ring_dropped,
                        status,
                        stop,
                        alive,
                        tap,
                    )
                })
        };
        let handle = match spawn {
            Ok(handle) => handle,
            Err(error) => {
                // No worker, no take: stop the copy and remove the header-only
                // WAV rather than leave a file nobody will finish.
                tap.detach();
                let _ = fs::remove_file(&path);
                return error_line(&format!("cannot start the bus take thread: {error}"));
            }
        };
        self.bus_take = Some(BusTakeSession {
            status,
            stop,
            handle: Some(handle),
        });
        match &self.bus_take {
            Some(session) => session.line(),
            None => idle_line(),
        }
    }

    fn record(&mut self, object: &Object) -> String {
        // `{"cmd":"record","action":"stop"}` ends the take and nothing else.
        // It exists because a take beside the transport borrows the transport's
        // one output: stopping the take must hand that output back rather than
        // stop the transport with it.
        if matches!(get(object, "action"), Some(Value::Str(action)) if action == "stop") {
            return self.record_stop();
        }
        // A `bus` makes this a bus take: it records one bus of the running
        // patch through the patchbay's tap instead of the card's capture. A
        // request without `bus` keeps every refusal and every path below.
        match get(object, "bus") {
            None | Some(Value::Null) => {}
            Some(Value::Str(bus)) => return self.record_bus(object, bus),
            Some(_) => return error_line("\"bus\" must be one bus id from the running patch"),
        }
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
        // The metronome click, if this take asked for one. Parsed before any
        // file or thread exists, exactly as the monitor is.
        let click = match parse_click(get(object, "click")) {
            Ok(click) => click,
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
        // A click-only monitor is still output, so it follows the same rule.
        //
        // The transport owns one output. A take may record beside it only when
        // the take asks for no output of its own: the transport already plays
        // the takes and owns the metronome, so monitor files and the take's own
        // click are refused. The take's live input is the exception, because
        // it rides the transport's own bus instead of opening a second device.
        let transport_playing = self
            .transport
            .as_ref()
            .map(TransportSession::is_playing)
            .unwrap_or(false);
        if transport_playing && (!monitor.is_empty() || click.is_some()) {
            return error_line(
                "the transport is playing; it already plays the takes and owns the metronome, so a take cannot open monitor files or its own click. Record with \"monitor_input\" alone, or stop the transport",
            );
        }
        if !transport_playing && (!monitor.is_empty() || monitor_input || click.is_some()) {
            if let Some(session) = &self.playback {
                if session.is_playing() {
                    return error_line("a playback is already running");
                }
            }
        }
        // The live input is the one monitor part that may share the transport's
        // output. It is attached after the files exist, so every other refusal
        // still leaves no thread or file behind.
        let transport_live = transport_playing && monitor_input;
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
        		// Which track the live monitor carries. Without it the engine sums every
        		// terminal track, which is the historical shape; a take that names one
        		// track (Studio's monitored channel) hears only that strip.
        		let monitor_track = match get(object, "monitor_track") {
        			None | Some(Value::Null) => None,
        			Some(Value::Num(value))
        				if value.is_finite() && *value >= 0.0 && value.fract() == 0.0 =>
        			{
        				Some(*value as usize)
        			}
        			_ => {
        				return error_line(
        					"\"monitor_track\" must be a whole, non-negative track number",
        				)
        			}
        		};
        		if monitor_track.is_some() && !monitor_input {
        			return error_line("\"monitor_track\" needs \"monitor_input\": true");
        		}
        		if let Some(index) = monitor_track {
        			if index >= plans.len() {
        				return error_line(&format!(
        					"monitor_track {index} is outside the take's {} tracks",
        					plans.len()
        				));
        			}
        		}
        		let tracks = plans.len();
        // A take may carry more tracks than the device has inputs. Every track
        // still has to name a real input below, and several tracks may share
        // one: a source can split into more than one chain through the same
        // input. The per-track bound is the only device bound.
        for (index, plan) in plans.iter().enumerate() {
            // A sent track takes the upstream track's block, not a device
            // channel, so the capture width is not its question.
            if plan.from.is_some() {
                continue;
            }
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
        if !transport_live && (!monitor_tracks.is_empty() || monitor_input || click.is_some()) {
            // A monitor with no files is still a monitor: a live input or a
            // click needs a backend that can play and a free output, exactly as
            // a monitor file does. A live input on the transport's bus owns
            // neither: the transport's output is already open and playing.
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
                from: plan.from,
                frames: 0,
                dropped: 0,
                gain: plan.gain,
                pan: plan.pan,
                inserts: plan.insert_list(),
            })
            .collect();
        // Where the take's first stored frame is placed on the transport: the
        // requested stamp less the capture offset, clamped at 0. That offset is
        // what the monitor is pre-rolled by and what the capture is corrected
        // for. Reporting it is what lets a caller place the WAV by the engine's
        // own answer instead of guessing from the round trip.
        let first_sample = monitor_start(start_at, alignment.samples);
        let shared = Arc::new(Mutex::new(Status {
            take,
            state: State::Recording,
            path: paths[0].clone(),
            frames: 0,
            dropped: 0,
            channels,
            start_sample: start_at,
            first_sample,
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

        // A take beside the transport does not open an output of its own: its
        // live ring is attached to the transport's render thread, which sums it
        // into the same master chain as the clips. The consumer leaves the take
        // here, and the transport owns it for the life of the take.
        if transport_live {
            let attached = parked_consumer
                .take()
                .map(|consumer| {
                    self.transport
                        .as_mut()
                        .map(|session| session.attach_live(consumer, Arc::clone(&input_gain)))
                        .unwrap_or(false)
                })
                .unwrap_or(false);
            if !attached {
                for disk in disks {
                    let _ = disk.finish();
                }
                for track_path in &paths {
                    let _ = fs::remove_file(track_path);
                }
                return error_line(
                    "the transport is no longer playing; the take's live input could not be attached",
                );
            }
        }

        // The monitoring bus: its own thread and its own device handle, fed by
        // `Playback` and never by the capture loop. Started before the take so
        // a player that cannot start is still a refusal rather than a take that
        // records without the monitor the caller asked for. A live-only monitor
        // has no files but still runs for the take's length. A take beside the
        // transport has no monitor here: the transport's output is the monitor.
        let mut monitor_session = if transport_live
            || (monitor_tracks.is_empty() && !monitor_input && click.is_none())
        {
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
            let click_spec = click;
            // Even a file monitor with `monitor_input` off carries the live
            // input: arming later is one atomic store, not a monitor rebuild.
            let live = parked_consumer
                .take()
                .map(|consumer| (consumer, Arc::clone(&input_gain)));
            // A live input runs for the take; so does a click, even when the
            // monitor has no files, so the click covers the whole take.
            let live_length = if monitor_input || click.is_some() {
                Some(frames)
            } else {
                None
            };
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
                            click_spec,
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
                						monitor_track,
                					)
                				})
        };
        let handle = match spawned {
            Ok(handle) => handle,
            Err(error) => {
                // No worker, no take: detach the transport's live ring, stop the
                // monitor and do not leave WAVs nobody will finish.
                if transport_live {
                    if let Some(session) = &mut self.transport {
                        session.detach_live();
                    }
                }
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
        let monitor_owned = monitor_session.is_some();
        if let Some(session) = monitor_session {
            self.playback = Some(session);
        }
        // A finished bus take is only a status line; a normal take now owns the
        // status. A recording one cannot be here: a patch is not running.
        if let Some(mut previous) = self.bus_take.take() {
            previous.finish();
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
            monitor_owned,
        });
        let monitor_part = if monitor_files == 0 && !monitor_input && click.is_none() {
            String::new()
        } else {
            format!(
                ",\"playing\":{},\"monitor_frames\":0{}{}",
                monitor_files,
                jawn_audio::playback::monitor_json(&monitor),
                click_json(click)
            )
        };
        format!(
            "{{\"ok\":true,\"take\":{take},\"state\":\"recording\",\"channels\":{channels},\"start_sample\":{start_at},\"first_sample\":{first_sample}{}{monitor_part},\"monitor_input\":{monitor_input},\"monitor_gain\":{monitor_gain},\"monitor_dropped\":0{}}}",
            tracks_json(&track_status),
            alignment_json(alignment)
        )
    }

    /// `{"cmd":"record","action":"stop"}`: end the take and nothing else.
    ///
    /// A take beside the transport borrowed the transport's one output, so
    /// stopping it hands that output back: the live ring is detached at the
    /// next block, the transport keeps playing its takes and its click, and its
    /// status reports `monitor_input:false`. A take that owns its own monitor
    /// stops that monitor too; an independent playback is left alone.
    fn record_stop(&mut self) -> String {
        let was_recording = self
            .current
            .as_ref()
            .map(Running::is_recording)
            .unwrap_or(false);
        let bus_recording = self
            .bus_take
            .as_ref()
            .map(BusTakeSession::is_recording)
            .unwrap_or(false);
        if !was_recording && !bus_recording {
            return error_line("no take is recording");
        }
        // A bus take owns no device: stopping it detaches the tap and closes
        // the WAV, and the patch keeps playing.
        if bus_recording {
            if let Some(session) = &self.bus_take {
                session.stop.store(true, Ordering::SeqCst);
            }
            if let Some(session) = &mut self.bus_take {
                session.finish();
            }
            if !was_recording {
                return match &self.bus_take {
                    Some(session) => session.line(),
                    None => idle_line(),
                };
            }
        }
        // Signal the take and its monitor before joining either, exactly as
        // `stop` does, so neither waits on the other's block.
        if let Some(running) = &self.current {
            running.stop.store(true, Ordering::SeqCst);
        }
        let monitor_owned = self
            .current
            .as_ref()
            .map(|running| running.monitor_owned)
            .unwrap_or(false);
        if monitor_owned {
            if let Some(session) = &self.playback {
                session.stop.store(true, Ordering::SeqCst);
            }
        }
        if let Some(running) = &mut self.current {
            running.finish();
        }
        if monitor_owned {
            if let Some(session) = &mut self.playback {
                session.finish();
            }
        }
        // The transport keeps its output and its clock; only the take's live
        // input leaves it. A listen riding the same transport is not touched.
        // The edge lands at the next block, so the clips and the click never
        // gap.
        if let Some(session) = &mut self.transport {
            session.detach_take_live();
        }
        match &self.current {
            Some(running) => running.line(),
            None => idle_line(),
        }
    }

    /// `{"cmd":"play","files":["/abs/a.wav"],"start_at":0}`: play takes back
    /// through their strips.
    ///
    /// Every file is decoded on this thread before the reply, so a missing or
    /// unplayable file is a refusal rather than a `playing` that turns into
    /// `failed` a moment later. The strips are the defaults the wire has no
    /// knobs for yet: unity trim, centre pan, no inserts.
    fn play(&mut self, object: &Object) -> String {
        // A transport owns the output exactly as a playback does; sharing one
        // device between them is the punch stage, not this one.
        if let Some(session) = &self.transport {
            if session.is_playing() {
                return error_line(
                    "the transport is playing; stop it before starting a playback. Sharing the transport's output with a playback is the next stage",
                );
            }
        }
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

    /// `{"cmd":"transport","action":"start","position":0,"bpm":120,
    /// "beats_per_bar":4,"gain":0.5,"loop_start":0,"loop_end":0}`.
    ///
    /// The engine owns the metronome and the clock for the browser transport.
    /// Positions are seconds on the song timeline; the render thread converts
    /// them to absolute device frames. Every field is validated before a thread
    /// or a device exists. A `start` while the transport already plays retunes
    /// and seeks in place: no device is closed, so there is no gap. Clips ride
    /// `update`, which replaces the placement of the running transport without
    /// stopping it. `sends` is the Studio output-cord graph (one destination
    /// per source, no self edge, no cycle); a clip or an app tap that names a
    /// `channel` follows its cord, and one that does not sums straight into the
    /// master. Both `start` and `update` carry it.
    fn transport_command(&mut self, object: &Object) -> String {
        let action = match get(object, "action") {
            Some(Value::Str(action)) => action.as_str(),
            _ => {
                return error_line(
                    "transport needs \"action\": \"start\", \"stop\", \"seek\", \"update\" or \"status\"",
                )
            }
        };
        match action {
            "start" => self.transport_start(object),
            "stop" => self.transport_stop(),
            "seek" => self.transport_seek(object),
            "update" => self.transport_update(object),
            "status" => self.transport_status(),
            other => error_line(&format!("no such transport action: {other}")),
        }
    }

    fn transport_start(&mut self, object: &Object) -> String {
        let bpm = match transport_bpm(object) {
            Ok(value) => value,
            Err(error) => return error_line(&error),
        };
        let beats_per_bar = match transport_beats_per_bar(object) {
            Ok(value) => value,
            Err(error) => return error_line(&error),
        };
        let gain = match transport_gain(object) {
            Ok(value) => value,
            Err(error) => return error_line(&error),
        };
        let position = match transport_frames(object, "position", 0.0, self.config.rate) {
            Ok(value) => value,
            Err(error) => return error_line(&error),
        };
        let loop_start = match transport_frames(object, "loop_start", 0.0, self.config.rate) {
            Ok(value) => value,
            Err(error) => return error_line(&error),
        };
        let loop_end = match transport_frames(object, "loop_end", 0.0, self.config.rate) {
            Ok(value) => value,
            Err(error) => return error_line(&error),
        };
        if loop_end > 0 && loop_end <= loop_start {
            return error_line(
                "transport \"loop_end\" must be greater than \"loop_start\", or 0 for no loop",
            );
        }
        // The takes to render are read before any device opens, so a missing or
        // wrong-shaped file is this command's refusal, not a silent gap. The
        // decoded samples are cached by path, so a restart-led update re-reads
        // only what changed.
        let clips = match transport_clips(object, self.config.rate, &mut self.take_cache) {
            Ok(clips) => clips,
            Err(error) => return error_line(&error),
        };
        // The mastering rack is the same shape a take arms. It is built on the
        // clip mix's bus, so the transport sounds like the browser's master.
        let master = match parse_master(get(object, "master")) {
            Ok(master) => master,
            Err(error) => return error_line(&error),
        };
        // The rack arrives with its knob positions, so the transport starts
        // with the mix the page is showing rather than the insert defaults.
        let master_values = match parse_master_values(get(object, "master_values")) {
            Ok(values) => values.unwrap_or_default(),
            Err(error) => return error_line(&error),
        };
        let drums = match parse_drums(get(object, "drums")) {
            Ok(drums) => drums,
            Err(error) => return error_line(&error),
        };
        // The scheduled Studio note clips. Parsed before any device opens, so a
        // wrong note or range is this command's refusal, not a silent clip.
        let (synth_clips_requested, synth_clips) = match parse_synth_clips(get(object, "synth_clips")) {
            Ok(SynthClipsField::Absent) => (false, None),
            Ok(SynthClipsField::Touch) => (true, None),
            Ok(SynthClipsField::Replace(clips)) => (true, Some(clips)),
            Err(error) => return error_line(&error),
        };
        // The Studio output cords. Validated here, before any device opens, so
        // a self edge, a second destination for one source or a cycle is one
        // clear refusal and no thread.
        let sends = match parse_sends(get(object, "sends")) {
            Ok(sends) => sends.unwrap_or_default(),
            Err(error) => return error_line(&error),
        };
        let spec = match ClickSpec::new(bpm, beats_per_bar, gain) {
            Ok(spec) => spec,
            Err(error) => return error_line(&error),
        };

        // Already ours: a tempo, loop or position change takes effect at the
        // next block. This is the responsive path the page's knobs use.
        if let Some(session) = self.transport.as_mut() {
            if session.is_playing() {
                // Strips are built for the render thread, so a different take set
                // needs a new thread and therefore a stop. Tempo and loop changes
                // ride on without one.
                if !clips.is_empty() {
                    return error_line(
                        "the transport is playing; stop it before changing its clips",
                    );
                }
                session.control.set_tempo(bpm, beats_per_bar, gain);
                session.control.set_loop(loop_start, loop_end);
                session.control.seek(position);
                // A `start` on a playing transport may carry a chart, a new
                // output-cord graph or a scheduled-clip plan: all ride the plan
                // channel like an `update`, so the device stays open. A plan
                // with no `clips` array (a tempo-only start) is a marker that
                // leaves the running clips alone.
                let sends_changed = get(object, "sends").is_some();
                if drums.is_some() || sends_changed || synth_clips_requested {
                    let chart = drums.as_ref().map(|chart| chart.clone());
                    let clip_count = synth_clips.as_ref().map(|clips| clips.len());
                    let plan = TransportPlan {
                        clips: None,
                        master: None,
                        master_values: None,
                        drums: chart,
                        synth: None,
                        synth_clips,
                        // A request that carried `sends` may replace the graph,
                        // exactly as before; a synth-clips-only tempo start keeps
                        // the one the transport is already following.
                        sends: if drums.is_some() || sends_changed {
                            Some(sends)
                        } else {
                            None
                        },
                    };
                    if session.plan_tx.send(plan).is_err() {
                        return error_line(
                            "the transport's render thread is no longer accepting plans",
                        );
                    }
                    if let Some(count) = clip_count {
                        session.synth_clips = count;
                    }
                    if let Some(chart) = drums {
                        session.drums = chart.length;
                        session.drum_routes = chart.routing.len();
                        session.drum_kit = chart.kit_name().to_string();
                    }
                }
                return self.transport_status();
            }
        }

        // A take may be recording beside the transport: it owns only the
        // capture stream, and the transport owns the output. A take's monitor,
        // however, lives in the playback slot, so the check below still refuses
        // it by the name of the output it is using.
        if let Some(session) = &self.playback {
            if session.is_playing() {
                let recording = self
                    .current
                    .as_ref()
                    .map(Running::is_recording)
                    .unwrap_or(false);
                return error_line(if recording {
                    "the take's monitor is using the output; stop the take before starting the transport. Sharing the transport's output with a monitor is the next stage"
                } else {
                    "a playback is running; stop it before starting the transport. Sharing the transport's output with a playback is the next stage"
                });
            }
        }
        if let Some(session) = &self.listen {
            if session.is_listening() {
                return error_line(
                    "listen is monitoring the inputs; stop it before starting the transport. Sharing the transport's output with a listen is the next stage",
                );
            }
        }
        if let Some(session) = &self.patch {
            if session.is_patching() {
                return error_line(
                    "the patchbay is using the outputs; stop the patch before starting the transport. Sharing the transport's output with the patchbay is the next stage",
                );
            }
        }

        if let Err(error) = crate::play_support(self.config.backend) {
            return error_line(&error);
        }
        match crate::probe_playback(
            self.config.backend,
            &self.config.device,
            self.config.rate,
            self.config.period,
            self.config.buffer,
        ) {
            Ok(granted) if granted != self.config.rate => {
                return error_line(&format!(
                    "the device granted {granted} Hz, but the transport runs at {} Hz; the click would be at the wrong tempo",
                    self.config.rate
                ))
            }
            Ok(_) => {}
            Err(error) => return error_line(&error),
        }

        if let Some(mut previous) = self.transport.take() {
            previous.finish();
        }
        let clip_count = clips.len();
        let master_count = master.len();
        let drum_count = drums.as_ref().map(|chart| chart.length).unwrap_or(0);
        let drum_routes = drums.as_ref().map(|chart| chart.routing.len()).unwrap_or(0);
        let drum_kit = drums
            .as_ref()
            .map(|chart| chart.kit_name().to_string())
            .unwrap_or_else(|| "off".to_string());
        let synth_clip_count = synth_clips.as_ref().map(|clips| clips.len()).unwrap_or(0);
        let control = Arc::new(TransportControl::new(spec, position, loop_start, loop_end));
        control.set_playing(true);
        let error = Arc::new(Mutex::new(String::new()));
        // The live monitor tap is attached before the device opens: the
        // transport pushes every finished block into its ring, and `monitor
        // start` only has to begin serving that ring.
        let monitor = self.monitor.control();
        // The control thread sends replacement plans; the render thread receives
        // them at a block edge. Nothing is shared under a lock, so a plan never
        // stalls the device. A take's live input rides its own channel and the
        // same block edge, so attaching one never stops or reopens the device.
        let (plan_tx, plan_rx) = std::sync::mpsc::channel();
        let (live_tx, live_rx) = std::sync::mpsc::channel();
        // Synth notes and audition hits ride their own channels, so neither
        // waits behind a plan or a live attach at the block edge.
        let (note_tx, note_rx) = std::sync::mpsc::channel();
        let (hit_tx, hit_rx) = std::sync::mpsc::channel();
        let spawned = {
            let control = Arc::clone(&control);
            let error = Arc::clone(&error);
            let config = self.config.clone();
            thread::Builder::new()
                .name("jawn-audio-transport".to_string())
                .spawn(move || {
                    run_transport(
                        config,
                        control,
                        error,
                        clips,
                        master,
                        master_values,
                        drums,
                        synth_clips.unwrap_or_default(),
                        sends,
                        plan_rx,
                        live_rx,
                        note_rx,
                        hit_rx,
                        monitor,
                    )
                })
        };
        let handle = match spawned {
            Ok(handle) => handle,
            Err(error) => {
                control.set_playing(false);
                return error_line(&format!("cannot start the transport thread: {error}"));
            }
        };
        self.transport = Some(TransportSession {
            control,
            handle: Some(handle),
            error,
            clips: clip_count,
            master: master_count,
            drums: drum_count,
            drum_kit,
            // A start carries no synth patch; the page sends one with a
            // `synth` command once the transport is playing.
            synth: 0,
            synth_clips: synth_clip_count,
            drum_routes,
            synth_routes: 0,
            plan_tx,
            live_tx,
            note_tx,
            hit_tx,
            live_owner: None,
            monitor_input: false,
            monitor_gain: None,
            buffer: self.config.buffer,
            period: self.config.period,
            rate: self.config.rate,
        });
        self.transport_status()
    }

    /// `{"cmd":"transport","action":"update","clips":[...],"master":[...],
    /// "master_values":[{"name":"master_comp.thresh","value":-18.0}]}`.
    ///
    /// Replace the placement or the master rack of a running transport, or move
    /// only the master knobs: the takes are read (and reused from the cache) on
    /// this control thread, then handed to the render thread, which swaps them
    /// in at the next block with the device still open. A transport that is not
    /// playing (never started, or stopped) is refused rather than silently
    /// holding a plan no thread will apply. Every field is optional, but an
    /// update must carry at least one of them.
    fn transport_update(&mut self, object: &Object) -> String {
        let rate = self.config.rate;
        // Refuse before reading any file, so an update against a stopped
        // transport is one clear sentence and no disk work.
        let playing = self
            .transport
            .as_ref()
            .map(TransportSession::is_playing)
            .unwrap_or(false);
        if !playing {
            return error_line(
                "the transport is not playing; start it before updating its clips",
            );
        }
        let clips = match transport_clips_plan(object, rate, &mut self.take_cache) {
            Ok(clips) => clips,
            Err(error) => return error_line(&error),
        };
        let master = match get(object, "master") {
            None | Some(Value::Null) => None,
            Some(value) => match parse_master(Some(value)) {
                Ok(master) => Some(master),
                Err(error) => return error_line(&error),
            },
        };
        let master_values = match parse_master_values(get(object, "master_values")) {
            Ok(values) => values,
            Err(error) => return error_line(&error),
        };
        let drums = match parse_drums(get(object, "drums")) {
            Ok(drums) => drums,
            Err(error) => return error_line(&error),
        };
        let (synth_clips_requested, synth_clips) = match parse_synth_clips(get(object, "synth_clips")) {
            Ok(SynthClipsField::Absent) => (false, None),
            Ok(SynthClipsField::Touch) => (true, None),
            Ok(SynthClipsField::Replace(clips)) => (true, Some(clips)),
            Err(error) => return error_line(&error),
        };
        let sends = match parse_sends(get(object, "sends")) {
            Ok(sends) => sends,
            Err(error) => return error_line(&error),
        };
        if clips.is_none()
            && master.is_none()
            && master_values.is_none()
            && drums.is_none()
            && sends.is_none()
            && !synth_clips_requested
        {
            return error_line(
                "update needs \"clips\", \"master\", \"master_values\", \"drums\", \"sends\" or \"synth_clips\": the change for the running transport",
            );
        }
        let clip_count = clips.as_ref().map(|clips| clips.len());
        let master_count = master.as_ref().map(|master| master.len());
        let drum_count = drums.as_ref().map(|chart| chart.length);
        let drum_routes = drums.as_ref().map(|chart| chart.routing.len());
        let drum_kit = drums.as_ref().map(|chart| chart.kit_name().to_string());
        let synth_clip_count = synth_clips.as_ref().map(|clips| clips.len());
        let plan = TransportPlan {
            clips,
            master,
            master_values,
            drums,
            synth: None,
            synth_clips,
            sends,
        };
        let session = match self.transport.as_mut() {
            Some(session) => session,
            None => {
                return error_line(
                    "the transport is not playing; start it before updating its clips",
                )
            }
        };
        if session.plan_tx.send(plan).is_err() {
            return error_line("the transport's render thread is no longer accepting plans");
        }
        if let Some(count) = clip_count {
            session.clips = count;
        }
        if let Some(count) = master_count {
            session.master = count;
        }
        if let Some(count) = drum_count {
            session.drums = count;
        }
        if let Some(count) = drum_routes {
            session.drum_routes = count;
        }
        if let Some(kit) = drum_kit {
            session.drum_kit = kit;
        }
        if let Some(count) = synth_clip_count {
            session.synth_clips = count;
        }
        self.transport_status()
    }

    /// Whether a transport owns the output right now. The synth and audition
    /// commands need one: their buses live on that render thread, and a command
    /// against a stopped session would have no reader.
    fn transport_playing(&self) -> bool {
        self.transport
            .as_ref()
            .map(TransportSession::is_playing)
            .unwrap_or(false)
    }

    /// `{"cmd":"synth","action":"patch","patch":{...}}`,
    /// `{"cmd":"synth","action":"note","on":1,"note":60,"velocity":0.8}`,
    /// `{"cmd":"synth","action":"all_off"}` and
    /// `{"cmd":"synth","action":"routing","routing":[...]}`: the native synth on
    /// the running transport's app bus.
    ///
    /// A patch or routing rides the plan channel and is applied at the next
    /// block edge; a note rides its own channel and is applied before that
    /// block renders. Every action needs a playing transport, because the
    /// synth lives on that render thread and its output is the transport's
    /// output. A malformed patch field is refused by name rather than
    /// defaulted.
    fn synth_command(&mut self, object: &Object) -> String {
        let action = match get(object, "action") {
            Some(Value::Str(action)) => action.as_str(),
            _ => {
                return error_line(
                    "synth needs \"action\": \"patch\", \"note\", \"all_off\" or \"routing\"",
                )
            }
        };
        match action {
            "patch" => self.synth_patch(object),
            "note" => self.synth_note(object),
            "all_off" => self.synth_all_off(),
            "routing" => self.synth_routing(object),
            other => error_line(&format!("no such synth action: {other}")),
        }
    }

    /// Load or retune the synth's patch. A transport that already has a synth
    /// applies it with `set_patch` at the block edge, so a held note keeps
    /// sounding while the page edits the patch.
    fn synth_patch(&mut self, object: &Object) -> String {
        if !self.transport_playing() {
            return error_line("the transport is not playing; start it before changing the synth patch");
        }
        let patch = match parse_synth_patch(get(object, "patch")) {
            Ok(patch) => patch,
            Err(error) => return error_line(&error),
        };
        let voices = patch.voices as usize;
        let session = match self.transport.as_mut() {
            Some(session) if session.is_playing() => session,
            _ => {
                return error_line(
                    "the transport is not playing; start it before changing the synth patch",
                )
            }
        };
        let plan = TransportPlan {
            clips: None,
            master: None,
            master_values: None,
            drums: None,
            synth: Some(SynthPlan {
                patch: Some(patch),
                routing: None,
            }),
            synth_clips: None,
            sends: None,
        };
        if session.plan_tx.send(plan).is_err() {
            return error_line("the transport's render thread is no longer accepting plans");
        }
        // The patch's own voice cap is the status line's `synth` value, exactly
        // as the page shows the knob rather than the live voice count.
        session.synth = voices;
        self.transport_status()
    }

    /// Replace the synth's routing strips. The synth app does not know which
    /// Studio channel it feeds, so Studio sends that channel's OUT chain here.
    /// The routing rides a plan and is applied at a block edge; the patch and
    /// any sounding voice are left alone.
    fn synth_routing(&mut self, object: &Object) -> String {
        if !self.transport_playing() {
            return error_line("the transport is not playing; start it before routing the synth");
        }
        let routing = match parse_app_routing(get(object, "routing"), "synth routing") {
            Ok(routing) => routing,
            Err(error) => return error_line(&error),
        };
        let session = match self.transport.as_mut() {
            Some(session) if session.is_playing() => session,
            _ => {
                return error_line(
                    "the transport is not playing; start it before routing the synth",
                )
            }
        };
        let count = routing.len();
        let plan = TransportPlan {
            clips: None,
            master: None,
            master_values: None,
            drums: None,
            synth: Some(SynthPlan {
                patch: None,
                routing: Some(routing),
            }),
            synth_clips: None,
            sends: None,
        };
        if session.plan_tx.send(plan).is_err() {
            return error_line("the transport's render thread is no longer accepting plans");
        }
        session.synth_routes = count;
        self.transport_status()
    }

    /// One note edge for the synth: `on` starts or releases `note`. A note-off
    /// keeps its velocity at zero on the wire, where it is unused.
    fn synth_note(&mut self, object: &Object) -> String {
        if !self.transport_playing() {
            return error_line("the transport is not playing; start it before playing the synth");
        }
        let on = match get(object, "on") {
            Some(Value::Bool(on)) => *on,
            Some(Value::Num(value)) if *value == 0.0 => false,
            Some(Value::Num(value)) if *value == 1.0 => true,
            _ => return error_line("synth note needs \"on\": 1 or 0 (or true/false)"),
        };
        let note = match get(object, "note") {
            Some(Value::Num(value))
                if value.is_finite()
                    && value.fract() == 0.0
                    && *value >= 0.0
                    && *value <= 127.0 =>
            {
                *value as u8
            }
            _ => {
                return error_line(
                    "synth note needs \"note\": a whole number from 0 to 127",
                )
            }
        };
        let velocity = match get(object, "velocity") {
            None | Some(Value::Null) => {
                if on {
                    1.0
                } else {
                    0.0
                }
            }
            Some(Value::Num(value)) if value.is_finite() && *value >= 0.0 && *value <= 1.0 => {
                *value as f32
            }
            _ => return error_line("synth \"velocity\" must be a number from 0 to 1"),
        };
        let session = match self.transport.as_mut() {
            Some(session) if session.is_playing() => session,
            _ => {
                return error_line(
                    "the transport is not playing; start it before playing the synth",
                )
            }
        };
        let edge = TransportNote::Note {
            on,
            note,
            velocity,
        };
        if session.note_tx.send(edge).is_err() {
            return error_line("the transport's render thread is no longer accepting notes");
        }
        self.transport_status()
    }

    /// Release every synth voice at the next block edge.
    fn synth_all_off(&mut self) -> String {
        if !self.transport_playing() {
            return error_line("the transport is not playing; start it before playing the synth");
        }
        let session = match self.transport.as_mut() {
            Some(session) if session.is_playing() => session,
            _ => {
                return error_line(
                    "the transport is not playing; start it before playing the synth",
                )
            }
        };
        if session.note_tx.send(TransportNote::AllOff).is_err() {
            return error_line("the transport's render thread is no longer accepting notes");
        }
        self.transport_status()
    }

    /// `{"cmd":"drums","action":"hit","voice":"kick","velocity":70}`: audition
    /// one drum voice on the running transport's machine.
    ///
    /// The hit uses the chart's loaded kit, so it needs a chart: a transport
    /// with no chart has no machine and the command is refused by name. The
    /// velocity is the machine's own whole `1..=100` scale.
    fn drums_command(&mut self, object: &Object) -> String {
        let action = match get(object, "action") {
            Some(Value::Str(action)) => action.as_str(),
            _ => return error_line("drums needs \"action\": \"hit\""),
        };
        if action != "hit" {
            return error_line(&format!("no such drums action: {action}"));
        }
        if !self.transport_playing() {
            return error_line("the transport is not playing; start it before hitting a drum");
        }
        let name = match get(object, "voice") {
            Some(Value::Str(name)) => name.as_str(),
            _ => return error_line("a drum hit needs \"voice\": a kit voice name"),
        };
        let voice = match Voice::from_name(name) {
            Some(voice) => voice,
            None => return error_line(&format!("no such drum voice: {name}")),
        };
        let velocity = match get(object, "velocity") {
            Some(Value::Num(value))
                if value.is_finite()
                    && value.fract() == 0.0
                    && *value >= 1.0
                    && *value <= 100.0 =>
            {
                *value as u8
            }
            _ => {
                return error_line(
                    "a drum hit needs \"velocity\": a whole number from 1 to 100",
                )
            }
        };
        let session = match self.transport.as_mut() {
            Some(session) if session.is_playing() => session,
            _ => {
                return error_line(
                    "the transport is not playing; start it before hitting a drum",
                )
            }
        };
        let hit = TransportHit {
            voice: voice.index(),
            velocity,
        };
        if session.hit_tx.send(hit).is_err() {
            return error_line("the transport's render thread is no longer accepting hits");
        }
        self.transport_status()
    }

    /// `{"cmd":"transport","action":"seek","position":12.5}`. A seek is a
    /// position change at the next block; a loop or tempo change rides a
    /// `start`, which updates the running transport in place.
    fn transport_seek(&mut self, object: &Object) -> String {
        let position = match get(object, "position") {
            Some(Value::Num(value)) if value.is_finite() && *value >= 0.0 => {
                match transport_frames(object, "position", 0.0, self.config.rate) {
                    Ok(value) => value,
                    Err(error) => return error_line(&error),
                }
            }
            _ => return error_line("seek needs \"position\": a number of seconds on the song timeline"),
        };
        match &self.transport {
            Some(session) => {
                session.control.seek(position);
                self.transport_status()
            }
            None => error_line("the transport has not been started"),
        }
    }

    /// `{"cmd":"transport","action":"stop"}`: silence the click and join the
    /// render thread. The session stays, so a following `status` still reports
    /// where it stopped and a `start` can resume from there.
    fn transport_stop(&mut self) -> String {
        if let Some(mut session) = self.transport.take() {
            // The output is about to close, so the take's live ring has no
            // reader left. Clear the attachment before the render thread leaves,
            // so `status` never reports a monitor on a stopped transport.
            session.detach_live();
            session.finish();
            self.transport = Some(session);
        }
        self.transport_status()
    }

    /// The dedicated transport status: state, seconds, tempo, signature and the
    /// loop bounds. The historical `status` command keeps its own shape.
    fn transport_status(&mut self) -> String {
        self.reconcile_transport_monitor();
        match &self.transport {
            Some(session) => session.line(self.config.rate),
            None => default_transport_line(),
        }
    }

    /// A take or listen that ends on its own (a take's `seconds` ran out, or a
    /// listen's capture failed) has no command to detach its live input. Any
    /// status request notices first, so the transport stops claiming a live
    /// slot whose owner is gone and the ring is dropped at the next block
    /// instead of being read forever.
    fn reconcile_transport_monitor(&mut self) {
        let owner = match &self.transport {
            Some(session) => session.live_owner,
            None => return,
        };
        let Some(owner) = owner else { return };
        let alive = match owner {
            LiveInputOwner::Take => self
                .current
                .as_ref()
                .map(Running::is_recording)
                .unwrap_or(false),
            LiveInputOwner::Listen => self
                .listen
                .as_ref()
                .map(ListenSession::is_listening)
                .unwrap_or(false),
        };
        if alive {
            return;
        }
        if let Some(session) = &mut self.transport {
            match owner {
                LiveInputOwner::Take => session.detach_take_live(),
                LiveInputOwner::Listen => session.detach_listen_live(),
            }
        }
    }

    fn status_line(&mut self) -> String {
        self.reconcile_transport_monitor();
        // A take that is recording is the transport, so its line leads and the
        // monitor reports beside it. An engine transport may be playing beside
        // it, so its object rides the same line. A finished take stays a status
        // line and an independent playback keeps its historical shape.
        let live_transport = self
            .transport
            .as_ref()
            .filter(|session| session.is_playing())
            .map(|session| (session, self.config.rate));
        let line = if let Some(session) = self
            .bus_take
            .as_ref()
            .filter(|session| session.is_recording())
        {
            session.line()
        } else if let Some(running) = self
            .current
            .as_ref()
            .filter(|running| running.is_recording())
        {
            running.line_with_roles(self.playback.as_ref(), live_transport)
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
        } else if let Some(session) = &self.bus_take {
            session.line()
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
        // boot restore adds `machine` and `plan`/`plan_error` on top, and the
        // monitor adds its `stream` object and `streaming` flag.
        let control = self.monitor.control();
        self.add_boot(add_monitor(add_config(line, &self.config), &control))
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
        // A bus take records the patch that is about to end, so it is stopped
        // first and its WAV is finished. A normal take is someone else's work
        // and is left alone, exactly as before.
        if let Some(session) = &self.bus_take {
            session.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &mut self.bus_take {
            session.finish();
        }
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
        let was_bus_take = self
            .bus_take
            .as_ref()
            .map(BusTakeSession::is_recording)
            .unwrap_or(false);
        let was_transport = self
            .transport
            .as_ref()
            .map(TransportSession::is_playing)
            .unwrap_or(false);
        // Signal every worker before joining any: a join waits for a loop that
        // has already been told to stop, so neither worker can hold the other
        // past its block.
        if let Some(running) = &self.current {
            running.stop.store(true, Ordering::SeqCst);
        }
        if let Some(session) = &self.bus_take {
            session.stop.store(true, Ordering::SeqCst);
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
        if let Some(session) = &self.transport {
            session.control.request_stop();
        }
        // Joining before answering makes `frames` and `monitor_frames` what was
        // actually produced, not a guess about a running loop.
        if let Some(running) = &mut self.current {
            running.finish();
        }
        // A bus take is joined before the patch: its writer closes the file
        // with the frames the patch has already produced.
        if let Some(session) = &mut self.bus_take {
            session.finish();
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
        if let Some(session) = &mut self.transport {
            // The take, if any, is going too; detach its live ring so a stopped
            // transport never claims a monitor it can no longer carry.
            session.detach_live();
            session.finish();
        }
        if was_bus_take {
            if let Some(session) = &self.bus_take {
                return session.line();
            }
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
                // The stop reply describes the take and, when one was playing,
                // the transport whose thread was joined beside it.
                let transport = if was_transport {
                    self.transport
                        .as_ref()
                        .map(|session| (session, self.config.rate))
                } else {
                    None
                };
                return running.line_with_roles(self.playback.as_ref(), transport);
            }
        }
        if was_transport {
            return self.transport_status();
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

/// Append the live monitor's state to a status object. `stream` is the tap's
/// own object (enabled, streaming, port, rate, frames, dropped); `streaming` is
/// repeated at the top level so a caller that only wants the boolean does not
/// have to reach into it.
fn add_monitor(line: String, monitor: &MonitorControl) -> String {
    let head = match line.strip_suffix('}') {
        Some(head) => head,
        None => return line,
    };
    format!(
        "{head},\"streaming\":{},\"stream\":{}}}",
        monitor.is_streaming(),
        monitor.status_fragment()
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
    /// Another track whose post-insert, pre-pan block feeds this track. When
    /// present the track reads no device input: the send replaces its plug, as
    /// a Studio channel send releases the destination's input.
    from: Option<usize>,
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
            from: None,
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

/// The `click` object: `{"bpm":120,"beats_per_bar":4,"gain":0.5}`.
///
/// The tempo is the take's one tempo; a take has no tempo map. `beats_per_bar`
/// carries the signature's numerator (the page sends "4" out of "4/4"), and a
/// missing `gain` is the page's default half. Every value is validated here,
/// before any WAV or thread exists, so a malformed click is a refusal.
fn parse_click(value: Option<&Value>) -> Result<Option<ClickSpec>, String> {
    let fields = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Obj(fields)) => fields,
        _ => return Err("\"click\" must be an object with bpm, beats_per_bar and gain".to_string()),
    };
    let bpm = match get(fields, "bpm") {
        Some(Value::Num(value)) => *value,
        _ => return Err("click \"bpm\" must be a finite number greater than zero".to_string()),
    };
    let beats_per_bar = match get(fields, "beats_per_bar") {
        Some(Value::Num(value))
            if value.is_finite() && *value >= 1.0 && *value <= 32.0 && value.fract() == 0.0 =>
        {
            *value as u32
        }
        _ => {
            return Err(
                "click \"beats_per_bar\" must be a whole number from 1 to 32".to_string()
            )
        }
    };
    let gain = match get(fields, "gain") {
        None | Some(Value::Null) => ClickSpec::DEFAULT_GAIN,
        Some(Value::Num(value)) => *value as f32,
        _ => return Err("click \"gain\" must be a finite number from 0 to 1".to_string()),
    };
    ClickSpec::new(bpm, beats_per_bar, gain).map(Some)
}

/// The transport's `bpm`: a finite number greater than zero. Missing means the
/// page's default 120.
fn transport_bpm(object: &Object) -> Result<f64, String> {
    match get(object, "bpm") {
        None | Some(Value::Null) => Ok(120.0),
        Some(Value::Num(value)) if value.is_finite() && *value > 0.0 => Ok(*value),
        _ => Err("transport \"bpm\" must be a finite number greater than zero".to_string()),
    }
}

/// The signature's numerator: a whole number from 1 to 32. Missing means 4.
fn transport_beats_per_bar(object: &Object) -> Result<u32, String> {
    match get(object, "beats_per_bar") {
        None | Some(Value::Null) => Ok(4),
        Some(Value::Num(value))
            if value.is_finite() && *value >= 1.0 && *value <= 32.0 && value.fract() == 0.0 =>
        {
            Ok(*value as u32)
        }
        _ => Err(
            "transport \"beats_per_bar\" must be a whole number from 1 to 32".to_string(),
        ),
    }
}

/// The click trim: 0..=1. Missing means the same half a take's click defaults to.
fn transport_gain(object: &Object) -> Result<f32, String> {
    match get(object, "gain") {
        None | Some(Value::Null) => Ok(ClickSpec::DEFAULT_GAIN),
        Some(Value::Num(value))
            if value.is_finite() && (0.0..=1.0).contains(value) =>
        {
            Ok(*value as f32)
        }
        _ => Err("transport \"gain\" must be a finite number from 0 to 1".to_string()),
    }
}

/// One seconds field converted to absolute device frames. A missing field uses
/// `default`; a negative, non-finite or absurdly large value is refused before
/// a thread exists.
fn transport_frames(
    object: &Object,
    key: &str,
    default: f64,
    rate: u32,
) -> Result<u64, String> {
    let seconds = match get(object, key) {
        None | Some(Value::Null) => default,
        Some(Value::Num(value)) if value.is_finite() && *value >= 0.0 => *value,
        _ => {
            return Err(format!(
                "transport \"{key}\" must be a finite number of seconds, not negative"
            ))
        }
    };
    let frames = seconds * f64::from(rate.max(1));
    if !frames.is_finite() || frames > u64::MAX as f64 {
        return Err(format!("transport \"{key}\" is too large for this device"));
    }
    Ok(frames.round() as u64)
}

/// One clip field in seconds, signed when `signed` is true (a take recorded
/// with a negative latency correction starts before the timeline's zero).
fn clip_seconds(fields: &Object, key: &str, default: f64, signed: bool) -> Result<f64, String> {
    match get(fields, key) {
        None | Some(Value::Null) => Ok(default),
        Some(Value::Num(value)) if value.is_finite() && (signed || *value >= 0.0) => Ok(*value),
        _ => Err(format!(
            "a transport clip \"{key}\" must be a finite number of seconds{}",
            if signed { "" } else { ", not negative" }
        )),
    }
}

/// A seconds value rounded to device frames. `0` means "to the end of the
/// file" for `duration` and "no fade" for a fade length.
fn clip_frames(seconds: f64, rate: u32) -> Result<u64, String> {
    let frames = seconds * f64::from(rate.max(1));
    if !frames.is_finite() || frames.abs() > u64::MAX as f64 {
        return Err("a transport clip field is too large for this device".to_string());
    }
    if frames <= 0.0 {
        return Ok(0);
    }
    Ok(frames.round() as u64)
}

/// A signed seconds value rounded to device frames (a clip's timeline start).
fn clip_signed_frames(seconds: f64, rate: u32) -> Result<i64, String> {
    let frames = seconds * f64::from(rate.max(1));
    if !frames.is_finite() || frames.abs() > i64::MAX as f64 {
        return Err("a transport clip field is too large for this device".to_string());
    }
    Ok(frames.round() as i64)
}

/// Identity of a WAV on disk: its length and modification time. A re-staged
/// take at the same path changes at least one of them, so the cache decodes it
/// again instead of serving the old audio.
#[derive(Clone, PartialEq, Eq)]
struct TakeStamp {
    len: u64,
    modified: Option<std::time::SystemTime>,
}

/// One decoded take, shared by every clip that names the same file.
#[derive(Clone)]
struct CachedTake {
    rate: u32,
    samples: Arc<[f32]>,
}

/// The control thread's decoded-take cache.
///
/// A transport plan re-reads every WAV it names unless the decode is kept. A
/// fader drag posts the same files over and over, and an add or delete repeats
/// the rest, so the cache is keyed by the absolute path the plan names and
/// stamped with the file's size and modification time: a re-staged take at the
/// same path is noticed. Entries the current plan no longer names are evicted
/// after each successful plan, so a long session cannot grow without bound.
/// The cache lives on the control thread; the render thread receives `Arc`
/// clones and never touches it.
#[derive(Default)]
struct TakeCache {
    entries: HashMap<String, (TakeStamp, CachedTake)>,
    /// Real disk reads, so a test can prove a repeated plan reused the decode.
    reads: u64,
}

impl TakeCache {
    fn stamp(path: &Path) -> Result<TakeStamp, String> {
        let metadata = fs::metadata(path)
            .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
        Ok(TakeStamp {
            len: metadata.len(),
            modified: metadata.modified().ok(),
        })
    }

    /// The decode for `path`, reading the file only when the path is new or the
    /// file behind it has changed. The rate travels with the samples, so the
    /// caller still validates it against the device rate.
    fn decode(&mut self, path: &str) -> Result<CachedTake, String> {
        let key = Path::new(path);
        let stamp = Self::stamp(key)?;
        if let Some((known, take)) = self.entries.get(path) {
            if *known == stamp {
                return Ok(take.clone());
            }
        }
        let (rate, samples) = jawn_audio::playback::decode_take(path)?;
        self.reads += 1;
        let take = CachedTake { rate, samples };
        self.entries.insert(path.to_string(), (stamp, take.clone()));
        Ok(take)
    }

    /// Drop every decode the current plan does not name. `live` holds the
    /// absolute paths of the clips that were just accepted; an empty plan
    /// clears the cache.
    fn retain(&mut self, live: &std::collections::HashSet<&str>) {
        self.entries.retain(|path, _| live.contains(path.as_str()));
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }
}

/// The `clips` field: the recorded takes placed on the transport timeline.
///
/// Every entry is an object with an absolute WAV `file`, a timeline `start`,
/// a source `offset`, an optional `duration`, `gain`, `pan`, `loop` and the
/// two crossfade lengths. The whole set is read and checked against the device
/// rate before any thread or device exists, so a bad take is a refusal from
/// `start` rather than a missing voice in a running transport.
fn transport_clips(
    object: &Object,
    rate: u32,
    cache: &mut TakeCache,
) -> Result<Vec<TransportClip>, String> {
    let values = match get(object, "clips") {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Arr(values)) => values,
        _ => return Err("transport \"clips\" must be an array of clip objects".to_string()),
    };
    let mut clips = Vec::with_capacity(values.len());
    for value in values {
        clips.push(transport_clip(value, rate, cache)?);
    }
    // A plan is the whole set, so anything it no longer names is dead weight.
    let live: std::collections::HashSet<&str> = clips.iter().map(|clip| clip.path.as_str()).collect();
    cache.retain(&live);
    Ok(clips)
}

/// The `clips` field only when the request carried it: `None` is a values-only
/// update (a master knob moved), which must never clear the placement.
fn transport_clips_plan(
    object: &Object,
    rate: u32,
    cache: &mut TakeCache,
) -> Result<Option<Vec<TransportClip>>, String> {
    match get(object, "clips") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Arr(_)) => transport_clips(object, rate, cache).map(Some),
        _ => Err("transport \"clips\" must be an array of clip objects".to_string()),
    }
}

/// One clip object. Missing knobs default to a wire, and a `duration` of zero
/// means the rest of the file after `offset`.
fn transport_clip(value: &Value, rate: u32, cache: &mut TakeCache) -> Result<TransportClip, String> {
    let fields = match value {
        Value::Obj(fields) => fields,
        _ => return Err("each transport clip must be an object".to_string()),
    };
    let path = match get(fields, "file").or_else(|| get(fields, "path")) {
        Some(Value::Str(path)) => path.clone(),
        _ => {
            return Err("a transport clip needs \"file\": an absolute WAV path".to_string())
        }
    };
    if !Path::new(&path).is_absolute() {
        return Err("transport needs every clip \"file\" to be an absolute path".to_string());
    }
    let start = clip_signed_frames(clip_seconds(fields, "start", 0.0, true)?, rate)?;
    let offset = clip_frames(clip_seconds(fields, "offset", 0.0, false)?, rate)?;
    let duration = clip_frames(clip_seconds(fields, "duration", 0.0, false)?, rate)?;
    let fade_in = clip_frames(clip_seconds(fields, "fade_in", 0.0, false)?, rate)?;
    let fade_out = clip_frames(clip_seconds(fields, "fade_out", 0.0, false)?, rate)?;
    let gain = match get(fields, "gain") {
        None | Some(Value::Null) => 1.0,
        Some(Value::Num(value)) if value.is_finite() => Channel::clamp_gain(*value as f32),
        _ => return Err("a transport clip \"gain\" must be a finite number".to_string()),
    };
    let pan = match get(fields, "pan") {
        None | Some(Value::Null) => 0.0,
        Some(Value::Num(value)) if value.is_finite() => Channel::clamp_pan(*value as f32),
        _ => return Err("a transport clip \"pan\" must be a finite number".to_string()),
    };
    let looped = match get(fields, "loop") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(value)) => *value,
        Some(Value::Num(value)) => *value != 0.0,
        _ => return Err("a transport clip \"loop\" must be true or false".to_string()),
    };
    let inserts = match get(fields, "inserts") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Arr(names)) => {
            let mut inserts = Vec::with_capacity(names.len());
            for name in names {
                let word = match name {
                    Value::Str(word) => word.as_str(),
                    _ => return Err("a transport clip \"inserts\" must hold insert names".to_string()),
                };
                let kind = InsertKind::parse(word)
                    .ok_or_else(|| format!("no such insert: {word}"))?;
                inserts.push(kind);
            }
            inserts
        }
        _ => {
            return Err(
                "a transport clip \"inserts\" must be an array of insert names".to_string(),
            )
        }
    };
    // The Studio channel this take follows. Absent means no cord: the take is
    // summed straight into the master bus, exactly as before sends existed.
    let channel = match get(fields, "channel") {
        None | Some(Value::Null) => None,
        Some(Value::Num(value))
            if value.is_finite()
                && value.fract() == 0.0
                && *value >= 1.0
                && *value <= 32.0 =>
        {
            Some(*value as usize)
        }
        _ => {
            return Err(
                "a transport clip \"channel\" must be a whole number from 1 to 32".to_string(),
            )
        }
    };
    let take = cache.decode(&path)?;
    if take.rate != rate {
        return Err(format!(
            "{} is {} Hz and the transport runs at {} Hz; every clip must share the device rate",
            path, take.rate, rate
        ));
    }
    let mut clip = TransportClip::from_samples(
        path,
        take.rate,
        take.samples,
        start,
        offset,
        duration,
        gain,
        pan,
        looped,
        fade_in,
        fade_out,
        inserts,
    )?;
    clip.channel = channel;
    Ok(clip)
}

/// The `click` object `record` echoes when it armed one, e.g.
/// `,"click":{"bpm":120,"beats_per_bar":4,"gain":0.5}`. Empty otherwise, so a
/// take without a click gains no key.
fn click_json(click: Option<ClickSpec>) -> String {
    match click {
        Some(spec) => format!(
            ",\"click\":{{\"bpm\":{},\"beats_per_bar\":{},\"gain\":{}}}",
            spec.bpm, spec.beats_per_bar, spec.gain
        ),
        None => String::new(),
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

/// The `master_values` field: the armed rack's live knob positions, as
/// `[{"name":"master_comp.thresh","value":-18.0},...]`. Each name is a master
/// insert prefix and one of that insert's controls; each value is finite. The
/// rack itself is armed by `master`, so a value for an insert that is not in
/// the rack moves nothing here rather than refusing the whole update: a page
/// may race a toggle with a knob turn.
fn parse_master_values(value: Option<&Value>) -> Result<Option<Vec<(String, f32)>>, String> {
    let values = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Arr(values)) => values,
        _ => {
            return Err(
                "\"master_values\" must be an array of master control objects".to_string()
            )
        }
    };
    let mut out = Vec::with_capacity(values.len());
    for entry in values {
        let fields = match entry {
            Value::Obj(fields) => fields,
            _ => {
                return Err(
                    "each master value must be an object with \"name\" and \"value\""
                        .to_string(),
                )
            }
        };
        let name = match get(fields, "name") {
            Some(Value::Str(name)) => name.as_str().to_string(),
            _ => return Err("a master value needs \"name\": insert.control".to_string()),
        };
        let (prefix, control) = name.split_once('.').ok_or_else(|| {
            format!("a master value names an insert and control: {name}")
        })?;
        let kind = InsertKind::parse(prefix)
            .filter(|kind| kind.master_prefix().is_some())
            .ok_or_else(|| format!("no such master insert: {prefix}"))?;
        if kind.control_index(control).is_none() && control != "bypass" {
            return Err(format!("no such master control: {name}"));
        }
        let value = match get(fields, "value") {
            Some(Value::Num(value)) if value.is_finite() => *value as f32,
            _ => {
                return Err(format!("the master value for {name} must be a finite number"))
            }
        };
        if !value.is_finite() {
            return Err(format!("the master value for {name} is too large for this device"));
        }
        out.push((name, value));
    }
    Ok(Some(out))
}

/// The master rack as a listen strip builds it: each armed insert with its
/// values, in the contract's order. A value for a slot the rack does not hold is
/// dropped, exactly as the transport's update drops it.
fn master_plan(kinds: &[InsertKind], values: Vec<(String, f32)>) -> Vec<PlanInsert> {
    let mut plan: Vec<PlanInsert> = kinds
        .iter()
        .map(|kind| PlanInsert {
            kind: *kind,
            knobs: Vec::new(),
        })
        .collect();
    for (name, value) in values {
        let Some((prefix, control)) = name.split_once('.') else {
            continue;
        };
        let Some(slot) = plan
            .iter_mut()
            .find(|slot| slot.kind.master_prefix() == Some(prefix))
        else {
            continue;
        };
        slot.knobs.push((control.to_string(), value));
    }
    plan
}

/// The largest fan-out an app's routing may carry. Each entry is one Studio
/// channel strip, and sixteen is far above any real channel count while
/// keeping the per-block strip list small.
const MAX_APP_ROUTES: usize = 16;

/// The most scheduled synth clips one transport plan may carry. The Studio has
/// 32 channels and a song rarely arms more than a handful, so 64 is a generous
/// ceiling that still bounds the per-clip synth buffers.
const MAX_SYNTH_CLIPS: usize = 64;

/// The most notes one scheduled synth clip may carry. A sixteen-bar loop at a
/// dense sixteenth grid is a few hundred notes; 4096 is far above that while
/// keeping a malicious plan from allocating without bound.
const MAX_SYNTH_CLIP_NOTES: usize = 4096;

/// The `routing` field shared by `drums.routing` and the synth's `routing`
/// action: one strip per channel the app is patched into.
///
/// ```text
/// "routing":[{"channel":2,"gain":0.8,"pan":-0.5,"inserts":["fuzz","reverb"]}]
/// ```
///
/// An absent or `null` routing is the empty list (unpatched: unity gain,
/// centre pan, no inserts). A present entry must be an object; an absent
/// `gain` is 1, an absent `pan` is 0, an absent `inserts` is none and an
/// absent `channel` means the tap has no output cord. `gain` is in `0..=1`,
/// `pan` in `-1..=1`, `channel` a whole 1..=32, and every insert name must be
/// one the engine can build. Each refusal names the path the page sent, e.g.
/// `drums.routing[1].gain` or `synth routing[0].inserts[2]`.
fn parse_app_routing(value: Option<&Value>, prefix: &str) -> Result<Vec<AppRoute>, String> {
    let entries = match value {
        None | Some(Value::Null) => return Ok(Vec::new()),
        Some(Value::Arr(entries)) => entries,
        _ => return Err(format!("{prefix} must be an array of routing objects")),
    };
    if entries.len() > MAX_APP_ROUTES {
        return Err(format!(
            "{prefix} must hold at most {MAX_APP_ROUTES} routing entries"
        ));
    }
    let mut routes = Vec::with_capacity(entries.len());
    for (index, entry) in entries.iter().enumerate() {
        let label = format!("{prefix}[{index}]");
        let fields = match entry {
            Value::Obj(fields) => fields,
            _ => return Err(format!("{label} must be an object")),
        };
        let gain = match get(fields, "gain") {
            None | Some(Value::Null) => 1.0,
            Some(Value::Num(value)) if value.is_finite() && *value >= 0.0 && *value <= 1.0 => {
                *value as f32
            }
            _ => return Err(format!("{label}.gain must be a number from 0 to 1")),
        };
        let pan = match get(fields, "pan") {
            None | Some(Value::Null) => 0.0,
            Some(Value::Num(value))
                if value.is_finite() && *value >= -1.0 && *value <= 1.0 =>
            {
                *value as f32
            }
            _ => return Err(format!("{label}.pan must be a number from -1 to 1")),
        };
        let inserts = match get(fields, "inserts") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Arr(names)) => {
                let mut inserts = Vec::with_capacity(names.len());
                for (slot, name) in names.iter().enumerate() {
                    let word = match name {
                        Value::Str(word) => word.as_str(),
                        _ => {
                            return Err(format!(
                                "{label}.inserts[{slot}] must be an insert name"
                            ))
                        }
                    };
                    let kind = InsertKind::parse(word).ok_or_else(|| {
                        format!("{label}.inserts[{slot}]: no such insert: {word}")
                    })?;
                    inserts.push(kind);
                }
                inserts
            }
            _ => return Err(format!("{label}.inserts must be an array of insert names")),
        };
        // The Studio channel this tap follows. Absent means no cord: the app
        // sums straight into the pre-master bus, exactly as before sends.
        let channel = match get(fields, "channel") {
            None | Some(Value::Null) => None,
            Some(Value::Num(value))
                if value.is_finite()
                    && value.fract() == 0.0
                    && *value >= 1.0
                    && *value <= 32.0 =>
            {
                Some(*value as usize)
            }
            _ => {
                return Err(format!(
                    "{label}.channel must be a whole number from 1 to 32"
                ))
            }
        };
        routes.push(AppRoute {
            gain,
            pan,
            inserts,
            channel,
        });
    }
    Ok(routes)
}

/// The `sends` field: the Studio output-cord graph, one destination per source.
///
/// ```text
/// "sends":[{"from":1,"to":2},{"from":3,"to":2}]
/// ```
///
/// Each entry is one cord. `from` and `to` must be whole channels in `1..=32`,
/// `from` cannot equal `to`, a source may appear once (it has one output jack)
/// and the graph must be acyclic. A refusal names the channel it is about, and
/// a cycle names the channel where it closes. `None` leaves the running graph
/// alone; an empty array is a graph with no cords, so every source sums into
/// the master bus.
fn parse_sends(value: Option<&Value>) -> Result<Option<Vec<(usize, usize)>>, String> {
    let entries = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Arr(entries)) => entries,
        _ => return Err("\"sends\" must be an array of send objects".to_string()),
    };
    let mut sends = Vec::with_capacity(entries.len());
    let mut destinations = [None::<usize>; 32];
    for (index, entry) in entries.iter().enumerate() {
        let fields = match entry {
            Value::Obj(fields) => fields,
            _ => return Err(format!("sends[{index}] must be an object with \"from\" and \"to\"")),
        };
        let from = match get(fields, "from") {
            Some(Value::Num(value))
                if value.is_finite()
                    && value.fract() == 0.0
                    && *value >= 1.0
                    && *value <= 32.0 =>
            {
                *value as usize
            }
            _ => return Err(format!("sends[{index}].from must be a whole channel 1 to 32")),
        };
        let to = match get(fields, "to") {
            Some(Value::Num(value))
                if value.is_finite()
                    && value.fract() == 0.0
                    && *value >= 1.0
                    && *value <= 32.0 =>
            {
                *value as usize
            }
            _ => return Err(format!("sends[{index}].to must be a whole channel 1 to 32")),
        };
        if from == to {
            return Err(format!("channel {from} cannot send to itself"));
        }
        if let Some(other) = destinations[from - 1] {
            return Err(format!(
                "channel {from} already sends to channel {other}; a channel send has one destination"
            ));
        }
        destinations[from - 1] = Some(to);
        sends.push((from, to));
    }
    // Walk every chain. A node visited twice closes a loop at that node, which
    // is the channel the refusal names.
    for start in 1..=32usize {
        if destinations[start - 1].is_none() {
            continue;
        }
        let mut visited = [false; 32];
        let mut at = start;
        let mut path: Vec<usize> = Vec::new();
        loop {
            if visited[at - 1] {
                let named: Vec<String> = path.iter().map(|channel| channel.to_string()).collect();
                return Err(format!(
                    "channel {at} closes a send loop ({} -> {})",
                    named.join(" -> "),
                    at
                ));
            }
            visited[at - 1] = true;
            path.push(at);
            match destinations[at - 1] {
                Some(next) => at = next,
                None => break,
            }
        }
    }
    Ok(Some(sends))
}

/// The `drums` field: the native machine's chart.
///
/// ```text
/// {"kit":"acoustic","length":16,"loop":1,
///  "steps":{"kick":[70,0,...],"snare":[...]}}
/// ```
///
/// `length` is required and must be a whole 1..=128. `kit` is optional (an
/// unknown name falls back to acoustic, exactly as the page does), `loop`
/// defaults to 1, and `steps` is optional. Rows are keyed by the eight wire
/// voice names; any other key is ignored. A row shorter than `length` is
/// zero-padded, a longer one is cut, and a velocity must be a whole 0..=100 or
/// the field is refused by name (`drums.steps.kick[3]`), never clamped.
///
/// `player` and `style` are optional and name the expression: `"player":
/// "wren"` plays the chart through that character at their own style, and a
/// `"style"` overrides how hard anyone plays. A style with no player plays it
/// through the uncoloured house player. No player at all is the plain grid,
/// exactly as the page has always sent it, so old songs do not change.
fn parse_drums(value: Option<&Value>) -> Result<Option<DrumChart>, String> {
    let fields = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Obj(fields)) => fields,
        _ => return Err("drums must be an object with \"length\"".to_string()),
    };
    let length = match get(fields, "length") {
        Some(Value::Num(value))
            if value.is_finite()
                && value.fract() == 0.0
                && *value >= 1.0
                && *value <= DrumChart::MAX_STEPS as f64 =>
        {
            *value as usize
        }
        None | Some(Value::Null) => {
            return Err(
                "drums \"length\" is required: a whole number of sixteenth steps from 1 to 128"
                    .to_string(),
            )
        }
        _ => {
            return Err(
                "drums \"length\" must be a whole number from 1 to 128 sixteenth steps"
                    .to_string(),
            )
        }
    };
    let kit = match get(fields, "kit") {
        None | Some(Value::Null) => Kit::Acoustic,
        Some(Value::Str(name)) => Kit::from_name_or_acoustic(name),
        _ => return Err("drums \"kit\" must be a kit name".to_string()),
    };
    let looped = match get(fields, "loop") {
        None | Some(Value::Null) => true,
        Some(Value::Num(value)) if *value == 0.0 => false,
        Some(Value::Num(value)) if *value == 1.0 => true,
        _ => return Err("drums \"loop\" must be 0 or 1".to_string()),
    };
    let player = match get(fields, "player") {
        None | Some(Value::Null) => None,
        Some(Value::Str(name)) => match Player::from_name(name) {
            Some(player) => Some(player),
            None => {
                let names: Vec<&str> = Player::ALL.iter().map(|player| player.name()).collect();
                return Err(format!(
                    "drums \"player\" must be a player name ({})",
                    names.join(", ")
                ));
            }
        },
        _ => return Err("drums \"player\" must be a player name".to_string()),
    };
    let style = match get(fields, "style") {
        None | Some(Value::Null) => None,
        Some(Value::Str(name)) => match Style::from_name(name) {
            Some(style) => Some(style),
            None => {
                let names: Vec<&str> = Style::ALL.iter().map(|style| style.name()).collect();
                return Err(format!(
                    "drums \"style\" must be one of {}",
                    names.join(", ")
                ));
            }
        },
        _ => return Err("drums \"style\" must be one of timid, soft, moderate, cool, hard, aggressive".to_string()),
    };
    let performance = match (player, style) {
        (None, None) => None,
        (Some(player), Some(style)) => Some(Performance::new(player, style)),
        (Some(player), None) => Some(Performance::of(player)),
        (None, Some(style)) => Some(Performance::new(Player::Studio, style)),
    };
    let mut steps = vec![[0u8; Voice::COUNT]; length];
    if let Some(value) = get(fields, "steps") {
        match value {
            Value::Null => {}
            Value::Obj(rows) => {
                for (name, row) in rows {
                    let Some(voice) = Voice::from_name(name) else {
                        // An unknown row name is not an error: the page may send
                        // a future voice the engine does not know yet.
                        continue;
                    };
                    let cells = match row {
                        Value::Arr(cells) => cells,
                        Value::Null => continue,
                        _ => {
                            return Err(format!(
                                "drums.steps.{name} must be an array of velocities"
                            ))
                        }
                    };
                    for (index, cell) in cells.iter().take(length).enumerate() {
                        let velocity = match cell {
                            Value::Num(value)
                                if value.is_finite()
                                    && value.fract() == 0.0
                                    && *value >= 0.0
                                    && *value <= 100.0 =>
                            {
                                *value as u8
                            }
                            _ => {
                                return Err(format!(
                                    "drums.steps.{name}[{index}] must be a whole number from 0 to 100"
                                ))
                            }
                        };
                        steps[index][voice.index()] = velocity;
                    }
                }
            }
            _ => return Err("drums \"steps\" must be an object of voice rows".to_string()),
        }
    }
    let routing = parse_app_routing(get(fields, "routing"), "drums.routing")?;
    let mut chart = DrumChart::new(kit, length, looped, steps).with_routing(routing);
    if let Some(performance) = performance {
        chart = chart.with_performance(performance);
    }
    Ok(Some(chart))
}

/// The `synth_clips` field on a transport `start` or `update`: the scheduled
/// Studio note clips, each with its own patch.
///
/// ```text
/// {"synth_clips":{"clips":[
///   {"patch":{...},"notes":[{"n":60,"t":0,"d":1,"v":0.8}],
///    "start":0.0,"beats":16.0,"loop":1,"channel":1,
///    "gain":1.0,"pan":0.0,"inserts":["reverb"]}
/// ]}}
/// ```
///
/// `start` is seconds on the song timeline; `beats` and the notes' `t`/`d` are
/// beats, so the engine restretches a clip with the transport's tempo. Every
/// refusal names the field it is about, e.g. `synth_clips.clips[2].notes[7].n`.
/// An object with no `clips` array is a marker with nothing to replace (a
/// tempo-only `start`); it leaves a running plan alone.
enum SynthClipsField {
    /// The field was absent.
    Absent,
    /// The field was present but carried no `clips` array.
    Touch,
    /// A replacement plan; an empty list removes every scheduled clip.
    Replace(Vec<SynthClip>),
}

fn parse_synth_clips(value: Option<&Value>) -> Result<SynthClipsField, String> {
    let fields = match value {
        None | Some(Value::Null) => return Ok(SynthClipsField::Absent),
        Some(Value::Obj(fields)) => fields,
        _ => return Err("synth_clips must be an object with \"clips\"".to_string()),
    };
    let entries = match get(fields, "clips") {
        None | Some(Value::Null) => return Ok(SynthClipsField::Touch),
        Some(Value::Arr(entries)) => entries,
        _ => return Err("synth_clips.clips must be an array of clip objects".to_string()),
    };
    if entries.len() > MAX_SYNTH_CLIPS {
        return Err(format!(
            "synth_clips carries {} clips, but the engine takes at most {MAX_SYNTH_CLIPS}",
            entries.len()
        ));
    }
    let mut clips = Vec::with_capacity(entries.len());
    for (index, entry) in entries.iter().enumerate() {
        let label = format!("synth_clips.clips[{index}]");
        let fields = match entry {
            Value::Obj(fields) => fields,
            _ => return Err(format!("{label} must be an object")),
        };
        // The patch is parsed by the synth's own reader, so a clip accepts
        // exactly the patch fields the live synth does.
        let patch = match get(fields, "patch") {
            Some(Value::Obj(_)) => parse_synth_patch(get(fields, "patch"))
                .map_err(|error| format!("{label}.{error}"))?,
            _ => {
                return Err(format!(
                    "{label}.patch must be an object with the browser patch fields"
                ))
            }
        };

        let note_values = match get(fields, "notes") {
            Some(Value::Arr(note_values)) => note_values,
            _ => return Err(format!("{label}.notes must be an array of note objects")),
        };
        if note_values.len() > MAX_SYNTH_CLIP_NOTES {
            return Err(format!(
                "{label}.notes carries {} notes, but a clip takes at most {MAX_SYNTH_CLIP_NOTES}",
                note_values.len()
            ));
        }
        let mut notes = Vec::with_capacity(note_values.len());
        for (slot, note) in note_values.iter().enumerate() {
            let note_label = format!("{label}.notes[{slot}]");
            let note_fields = match note {
                Value::Obj(note_fields) => note_fields,
                _ => return Err(format!("{note_label} must be an object")),
            };
            let number = match get(note_fields, "n") {
                Some(Value::Num(value))
                    if value.is_finite()
                        && value.fract() == 0.0
                        && *value >= 0.0
                        && *value <= 127.0 =>
                {
                    *value as u8
                }
                _ => {
                    return Err(format!(
                        "{note_label}.n must be a whole MIDI note from 0 to 127"
                    ))
                }
            };
            let start = match get(note_fields, "t") {
                Some(Value::Num(value)) if value.is_finite() && *value >= 0.0 => *value,
                _ => {
                    return Err(format!(
                        "{note_label}.t must be a finite number of beats, not negative"
                    ))
                }
            };
            let length = match get(note_fields, "d") {
                Some(Value::Num(value)) if value.is_finite() && *value > 0.0 => *value,
                _ => {
                    return Err(format!(
                        "{note_label}.d must be a finite number of beats greater than zero"
                    ))
                }
            };
            let velocity = match get(note_fields, "v") {
                Some(Value::Num(value))
                    if value.is_finite() && *value >= 0.0 && *value <= 1.0 =>
                {
                    *value as f32
                }
                _ => return Err(format!("{note_label}.v must be a number from 0 to 1")),
            };
            notes.push(SynthNote {
                note: number,
                t: start,
                d: length,
                v: velocity,
            });
        }

        let start = match get(fields, "start") {
            Some(Value::Num(value)) if value.is_finite() && *value >= 0.0 => *value,
            _ => {
                return Err(format!(
                    "{label}.start must be a finite number of seconds, not negative"
                ))
            }
        };
        let beats = match get(fields, "beats") {
            Some(Value::Num(value)) if value.is_finite() && *value > 0.0 => *value,
            _ => {
                return Err(format!(
                    "{label}.beats must be a finite number of beats greater than zero"
                ))
            }
        };
        let looped = match get(fields, "loop") {
            None | Some(Value::Null) => false,
            Some(Value::Num(value)) if *value == 0.0 => false,
            Some(Value::Num(value)) if *value == 1.0 => true,
            Some(Value::Bool(value)) => *value,
            _ => return Err(format!("{label}.loop must be 0 or 1")),
        };
        let channel = match get(fields, "channel") {
            None | Some(Value::Null) => None,
            Some(Value::Num(value))
                if value.is_finite()
                    && value.fract() == 0.0
                    && *value >= 1.0
                    && *value <= 32.0 =>
            {
                Some(*value as usize)
            }
            _ => {
                return Err(format!(
                    "{label}.channel must be a whole number from 1 to 32"
                ))
            }
        };
        let gain = match get(fields, "gain") {
            None | Some(Value::Null) => 1.0,
            Some(Value::Num(value)) if value.is_finite() && *value >= 0.0 && *value <= 1.0 => {
                *value as f32
            }
            _ => return Err(format!("{label}.gain must be a number from 0 to 1")),
        };
        let pan = match get(fields, "pan") {
            None | Some(Value::Null) => 0.0,
            Some(Value::Num(value)) if value.is_finite() && *value >= -1.0 && *value <= 1.0 => {
                *value as f32
            }
            _ => return Err(format!("{label}.pan must be a number from -1 to 1")),
        };
        let inserts = match get(fields, "inserts") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Arr(names)) => {
                let mut inserts = Vec::with_capacity(names.len());
                for (slot, name) in names.iter().enumerate() {
                    let word = match name {
                        Value::Str(word) => word.as_str(),
                        _ => {
                            return Err(format!(
                                "{label}.inserts[{slot}] must be an insert name"
                            ))
                        }
                    };
                    let kind = InsertKind::parse(word).ok_or_else(|| {
                        format!("{label}.inserts[{slot}]: no such insert: {word}")
                    })?;
                    inserts.push(kind);
                }
                inserts
            }
            _ => return Err(format!("{label}.inserts must be an array of insert names")),
        };
        clips.push(SynthClip {
            patch,
            notes,
            start,
            beats,
            looped,
            channel,
            gain,
            pan,
            inserts,
        });
    }
    Ok(SynthClipsField::Replace(clips))
}

/// The `synth` command's `patch` field: the browser's patch JSON, field for
/// field.
///
/// Every field inside `patch` is optional, and an absent one keeps
/// [`Patch::default`]'s value, so the page may send a partial patch. A present
/// field of the wrong type, or an unknown enum name, is refused by field
/// (`patch.filter.type`), never defaulted. Ranges are the crate's to clamp, in
/// [`Patch::clamped`], exactly as the browser clamps them.
fn parse_synth_patch(value: Option<&Value>) -> Result<Patch, String> {
    let fields = match value {
        Some(Value::Obj(fields)) => fields,
        None | Some(Value::Null) => {
            return Err(
                "synth \"patch\" is required: an object with the browser patch fields".to_string(),
            )
        }
        _ => return Err("synth \"patch\" must be an object".to_string()),
    };
    let defaults = Patch::default();
    let mut patch = defaults;

    if let Some(name) = patch_string(fields, "patch", "engine")? {
        patch.engine = SynthEngine::from_name(name)
            .ok_or_else(|| format!("no such patch.engine: {name}"))?;
    }
    if let Some(name) = patch_string(fields, "patch", "wave")? {
        patch.wave =
            Wave::from_name(name).ok_or_else(|| format!("no such patch.wave: {name}"))?;
    }
    if let Some(value) = patch_number(fields, "patch", "noise")? {
        patch.noise = value;
    }
    if let Some(value) = patch_whole(fields, "patch", "voices")? {
        patch.voices = u8::try_from(value)
            .map_err(|_| "patch.voices must be a whole number from 0 to 255".to_string())?;
    }
    if let Some(value) = patch_number(fields, "patch", "transpose")? {
        patch.transpose = value;
    }
    if let Some(value) = patch_number(fields, "patch", "glide")? {
        patch.glide = value;
    }
    if let Some(value) = patch_number(fields, "patch", "drive")? {
        patch.drive = value;
    }
    if let Some(value) = patch_number(fields, "patch", "damping")? {
        patch.damping = value;
    }
    if let Some(value) = patch_number(fields, "patch", "brightness")? {
        patch.brightness = value;
    }

    match get(fields, "osc") {
        None | Some(Value::Null) => {}
        Some(Value::Arr(entries)) => {
            if entries.is_empty() || entries.len() > 2 {
                return Err(format!(
                    "patch.osc must hold one or two oscillators, found {}",
                    entries.len()
                ));
            }
            for (index, entry) in entries.iter().enumerate() {
                let label = format!("patch.osc[{index}]");
                let osc_fields = match entry {
                    Value::Obj(fields) => fields,
                    _ => return Err(format!("{label} must be an object")),
                };
                let mut osc = defaults.osc[index];
                if let Some(value) = patch_whole(osc_fields, &label, "octave")? {
                    osc.octave = i8::try_from(value).map_err(|_| {
                        format!("{label}.octave must be a whole number from -128 to 127")
                    })?;
                }
                if let Some(value) = patch_number(osc_fields, &label, "detune")? {
                    osc.detune = value;
                }
                if let Some(value) = patch_number(osc_fields, &label, "level")? {
                    osc.level = value;
                }
                patch.osc[index] = osc;
            }
            patch.osc_count = entries.len() as u8;
        }
        Some(_) => {
            return Err("patch.osc must be an array of one or two oscillator objects".to_string())
        }
    }

    if let Some(filter) = patch_object(fields, "patch", "filter")? {
        // The JSON key is `type`; the Rust field is `kind`, because `type` is
        // a Rust keyword. That is the one name the bridge translates.
        if let Some(name) = patch_string(filter, "patch.filter", "type")? {
            patch.filter.kind = FilterKind::from_name(name)
                .ok_or_else(|| format!("no such patch.filter.type: {name}"))?;
        }
        if let Some(value) = patch_number(filter, "patch.filter", "cutoff")? {
            patch.filter.cutoff = value;
        }
        if let Some(value) = patch_number(filter, "patch.filter", "q")? {
            patch.filter.q = value;
        }
        if let Some(value) = patch_number(filter, "patch.filter", "env")? {
            patch.filter.env = value;
        }
        if let Some(value) = patch_number(filter, "patch.filter", "keytrack")? {
            patch.filter.keytrack = value;
        }
    }

    if let Some(amp) = patch_object(fields, "patch", "amp")? {
        patch.amp = parse_synth_envelope(amp, "patch.amp", defaults.amp)?;
    }
    if let Some(fenv) = patch_object(fields, "patch", "fenv")? {
        patch.fenv = parse_synth_envelope(fenv, "patch.fenv", defaults.fenv)?;
    }

    if let Some(lfo) = patch_object(fields, "patch", "lfo")? {
        let mut settings = defaults.lfo;
        if let Some(value) = patch_number(lfo, "patch.lfo", "rate")? {
            settings.rate = value;
        }
        if let Some(value) = patch_number(lfo, "patch.lfo", "pitch")? {
            settings.pitch = value;
        }
        if let Some(value) = patch_number(lfo, "patch.lfo", "cutoff")? {
            settings.cutoff = value;
        }
        if let Some(value) = patch_number(lfo, "patch.lfo", "amp")? {
            settings.amp = value;
        }
        patch.lfo = settings;
    }

    Ok(patch.clamped())
}

/// One ADSR object from the patch, starting from `base` so a field the page
/// omits keeps the crate's default.
fn parse_synth_envelope(
    fields: &Object,
    label: &str,
    mut env: Envelope,
) -> Result<Envelope, String> {
    if let Some(value) = patch_number(fields, label, "a")? {
        env.a = value;
    }
    if let Some(value) = patch_number(fields, label, "d")? {
        env.d = value;
    }
    if let Some(value) = patch_number(fields, label, "s")? {
        env.s = value;
    }
    if let Some(value) = patch_number(fields, label, "r")? {
        env.r = value;
    }
    Ok(env)
}

/// A string field of a patch object. `label` is the field's parent path, so an
/// error names exactly where the page sent the wrong type.
fn patch_string<'a>(
    fields: &'a Object,
    label: &str,
    key: &str,
) -> Result<Option<&'a str>, String> {
    match get(fields, key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Str(value)) => Ok(Some(value.as_str())),
        _ => Err(format!("{label}.{key} must be a string")),
    }
}

/// A finite number field of a patch object.
fn patch_number(fields: &Object, label: &str, key: &str) -> Result<Option<f32>, String> {
    match get(fields, key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Num(value)) if value.is_finite() => Ok(Some(*value as f32)),
        _ => Err(format!("{label}.{key} must be a number")),
    }
}

/// A whole-number field of a patch object, kept in `i64` so the caller can
/// refuse an out-of-range value by name rather than wrapping it.
fn patch_whole(fields: &Object, label: &str, key: &str) -> Result<Option<i64>, String> {
    match get(fields, key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Num(value)) if value.is_finite() && value.fract() == 0.0 => {
            Ok(Some(*value as i64))
        }
        _ => Err(format!("{label}.{key} must be a whole number")),
    }
}

/// An object field of a patch object.
fn patch_object<'a>(
    fields: &'a Object,
    label: &str,
    key: &str,
) -> Result<Option<&'a Object>, String> {
    match get(fields, key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Obj(value)) => Ok(Some(value)),
        _ => Err(format!("{label}.{key} must be an object")),
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
                    "track {} must be an object with input, channels, gain, pan and inserts",
                    index + 1
                ))
            }
        };
        plans.push(track_plan(index, fields)?);
    }
    // A send is an edge between two tracks. Range, self, a repeated source and
    // a loop are refused before any device opens or file exists.
    let sends: Vec<Option<usize>> = plans.iter().map(|plan| plan.from).collect();
    jawn_audio::send_order(&sends)?;
    Ok(plans)
}

/// One object from the `tracks` plan. A missing field takes the CLI's default;
/// gain and pan are clamped exactly as the CLI clamps them.
fn track_plan(index: usize, fields: &Object) -> Result<TrackPlan, String> {
    let from = match get(fields, "from") {
        None | Some(Value::Null) => None,
        Some(Value::Num(value))
            if value.is_finite()
                && *value >= 0.0
                && *value <= MAX_TRACKS as f64
                && value.fract() == 0.0 =>
        {
            Some(*value as usize)
        }
        _ => {
            return Err(format!(
                "track {} \"from\" must be a whole, non-negative track number",
                index + 1
            ))
        }
    };
    // A send replaces the device input: the source's post-pedal block is this
    // track's input. Carrying both would leave two answers to one question, so
    // a plan that gives `from` and an input is refused rather than guessed.
    if from.is_some() {
        for key in ["input", "channels"] {
            if matches!(get(fields, key), Some(value) if !matches!(value, Value::Null)) {
                return Err(format!(
                    "track {} takes its input from another track, so it cannot also name \"{key}\"",
                    index + 1
                ));
            }
        }
    }
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
        from,
    })
}

#[derive(Clone)]
struct TrackStatus {
    path: String,
    input: usize,
    /// The upstream track when this track takes a channel send, else `None`.
    from: Option<usize>,
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
    /// The transport sample the take's first stored frame sits at: the
    /// requested stamp less the capture offset, clamped at 0. The capture
    /// begins when the device opens, so its own start delay is not measured;
    /// `align_from` says whether an offset was given or measured. Drift is
    /// never modelled.
    first_sample: u64,
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
/// find the second one without guessing the naming scheme. A track fed by a
/// channel send reports `from` instead of `input`, because it reads no device
/// channel at all.
fn tracks_json(tracks: &[TrackStatus]) -> String {
    if tracks.len() <= 1 {
        return String::new();
    }
    let entries: Vec<String> = tracks
        .iter()
        .map(|track| {
            let source = match track.from {
                Some(from) => format!("\"from\":{from}"),
                None => format!("\"input\":{}", track.input),
            };
            format!(
                "{{\"path\":\"{}\",{},\"frames\":{},\"dropped\":{},\"gain\":{},\"pan\":{},\"inserts\":\"{}\"}}",
                jawn_audio::loopback::json_escape(&track.path),
                source,
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
    /// Whether this take owns the playback slot's monitor output. A take
    /// beside the transport does not: the transport owns the output and the
    /// live ring rides it, so `record` stop must leave the transport playing.
    monitor_owned: bool,
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
        self.line_with_roles(None, None)
    }

    /// The take's line with the monitoring role beside it. `playing` is how many
    /// files the monitor holds (not whether it is still running) and
    /// `monitor_frames` is what it rendered, so a finished monitor is still
    /// visible while its take remains the state being reported. A transport
    /// that is running beside the take rides the same line as its own object.
    fn line_with_roles(
        &self,
        play: Option<&PlaySession>,
        transport: Option<(&TransportSession, u32)>,
    ) -> String {
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
        let transport = match transport {
            Some((session, rate)) => {
                format!(",\"transport\":{}", session.fragment(rate))
            }
            None => String::new(),
        };
        let alignment = alignment_json(Alignment {
            samples: status.align_samples,
            from: status.align_from,
        });
        format!(
            "{{\"ok\":true,\"take\":{},\"state\":\"{}\",\"path\":\"{}\",\"frames\":{},\"dropped\":{},\"channels\":{},\"start_sample\":{},\"first_sample\":{},\"xruns\":{}{}{}{}{},\"gain\":{},\"pan\":{},\"inserts\":\"{}\",\"monitor_input\":{},\"monitor_gain\":{},\"monitor_dropped\":{},\"error\":\"{}\"}}",
            status.take,
            status.state.name(),
            jawn_audio::loopback::json_escape(&status.path),
            status.frames,
            status.dropped,
            status.channels,
            status.start_sample,
            status.first_sample,
            status.xruns,
            tracks_json(&status.tracks),
            monitor,
            alignment,
            transport,
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

/// What `status` reads for a bus take: a take that records one bus of a
/// running patch instead of the card's capture.
#[derive(Clone)]
struct BusTakeStatus {
    take: u64,
    state: State,
    path: String,
    /// The plan's bus id this take records.
    bus: String,
    frames: u64,
    dropped: u64,
    total_frames: u64,
    start_sample: u64,
    error: String,
}

/// The server's handle to one bus take's writer thread.
struct BusTakeSession {
    status: Arc<Mutex<BusTakeStatus>>,
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl BusTakeSession {
    fn snapshot(&self) -> BusTakeStatus {
        self.status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    fn is_recording(&self) -> bool {
        self.snapshot().state == State::Recording
    }

    /// Signal the writer and wait for it. When this returns the WAV is closed.
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
            if status.state == State::Recording {
                status.state = State::Failed;
                status.error = "the bus take thread panicked".to_string();
            }
        }
    }

    /// The take's line. It keeps the take shape Studio already reads (`take`,
    /// `state`, `path`, `frames`, `dropped`, `start_sample`, `error`) and adds
    /// the bus it recorded.
    fn line(&self) -> String {
        let status = self.snapshot();
        format!(
            "{{\"ok\":true,\"take\":{},\"state\":\"{}\",\"path\":\"{}\",\"bus\":\"{}\",\"frames\":{},\"dropped\":{},\"channels\":{},\"start_sample\":{},\"total_frames\":{},\"monitor_input\":false,\"error\":\"{}\"}}",
            status.take,
            status.state.name(),
            jawn_audio::loopback::json_escape(&status.path),
            jawn_audio::loopback::json_escape(&status.bus),
            status.frames,
            status.dropped,
            TAKE_CHANNELS,
            status.start_sample,
            status.total_frames,
            jawn_audio::loopback::json_escape(&status.error)
        )
    }
}

/// The bus take's writer: pop the tapped bus from its ring, convert to the
/// on-disk i16 shape and hand it to the WAV writer. It ends on `stop`, at
/// `total_frames`, or when the patch that feeds it ends (the ring drains and
/// `patch_alive` is false). Every ending closes the WAV; a patch that stops
/// while the take runs therefore leaves a finished file, not a lost one.
fn run_bus_take(
    period: usize,
    total_frames: u64,
    mut disk: DiskWriter,
    consumer: Consumer,
    ring_dropped: Arc<AtomicU64>,
    status: Arc<Mutex<BusTakeStatus>>,
    stop: Arc<AtomicBool>,
    patch_alive: Arc<AtomicBool>,
    tap: Arc<crate::patchbay::BusTap>,
) {
    let period = period.max(1);
    let mut block = vec![0.0f32; period * 2];
    let mut pcm = vec![0i16; period * 2];
    let mut frames = 0u64;
    let mut disk_dropped = 0u64;
    while !stop.load(Ordering::SeqCst) {
        let left = total_frames.saturating_sub(frames);
        if left == 0 {
            break;
        }
        let want = left.min(period as u64) as usize;
        let got = consumer.pop(&mut block[..want * 2]);
        if got == 0 {
            // The patch is the producer. Once it is gone, an empty ring is the
            // end of the take rather than a dropout, and the file is finished
            // below with everything the patch rendered.
            if !patch_alive.load(Ordering::Acquire) {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
            continue;
        }
        for (sample, out) in block[..got * 2].iter().zip(pcm[..got * 2].iter_mut()) {
            *out = to_i16(*sample);
        }
        disk_dropped += disk.push(&pcm[..got * 2]) as u64;
        frames += got as u64;
        let mut current = status
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        current.frames = frames;
        current.dropped = disk_dropped + ring_dropped.load(Ordering::Relaxed);
    }
    // The patch copies only while a take is attached; detaching stops the copy
    // at its next block, so this writer can close the file once.
    tap.detach();
    let written = match disk.finish() {
        Ok(written) => written,
        Err(error) => {
            let mut current = status
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            current.state = State::Failed;
            current.error = format!("the bus take could not finish its WAV: {error}");
            return;
        }
    };
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.frames = written;
    current.dropped = disk_dropped + ring_dropped.load(Ordering::Relaxed);
    current.state = State::Done;
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


/// The server's handle to one transport's render thread. The control block is
/// the same one the socket writes: seek, tempo and loop changes are atomic and
/// take effect at the next block.
/// Which role's live input a transport is carrying. The render thread has one
/// live slot; a take and a listen never share it, because a listen refuses while
/// a take records and a take with `monitor_input` refuses while a listen runs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum LiveInputOwner {
    Take,
    Listen,
}

struct TransportSession {
    control: Arc<TransportControl>,
    handle: Option<JoinHandle<()>>,
    /// The worker's failure, empty while healthy. A stopped transport can still
    /// report why it stopped.
    error: Arc<Mutex<String>>,
    /// How many recorded takes this transport renders. Zero is the click-only
    /// clock the page used before its takes moved into the engine.
    clips: usize,
    /// How many mastering inserts are armed on the clip mix. Zero is a dry sum.
    master: usize,
    /// The drum chart's length in sixteenth steps; zero is no chart.
    drums: usize,
    /// The kit the drum machine actually loaded, or `"off"` for no chart.
    drum_kit: String,
    /// The loaded synth's voice cap (`patch.voices`); zero is no patch. It is
    /// the patch's own limit, not the live voice count, exactly as the page
    /// shows the patch's `voices` knob.
    synth: usize,
    /// How many scheduled Studio synth clips the plan carries. Beside the live
    /// synth's voice count, so the page can show that the engine owns a clip.
    synth_clips: usize,
    /// How many routing strips the drum chart feeds through.
    drum_routes: usize,
    /// How many routing strips the synth feeds through.
    synth_routes: usize,
    /// Replacement plans to the render thread. A send never waits for the audio
    /// thread; the receiver's `try_recv` at a block edge is the only consumer.
    plan_tx: Sender<TransportPlan>,
    /// Attach and detach edges for a take's live input, read at a block edge.
    live_tx: Sender<TransportLive>,
    /// Note edges for the native synth, read at a block edge.
    note_tx: Sender<TransportNote>,
    /// One-shot drum hits for audition, read at a block edge.
    hit_tx: Sender<TransportHit>,
    /// Which role's live input is attached right now. `None` is the state
    /// before any take or listen and again after its stop detaches it.
    live_owner: Option<LiveInputOwner>,
    /// Whether a take's live ring is attached right now. `false` is the state
    /// before any take and again after `record` stop detaches it, and it stays
    /// false for a listen riding the transport.
    monitor_input: bool,
    /// The attached take's trim, the same `Arc` its own `param` writes. Kept
    /// only while attached, so `transport status` reports the value the take
    /// reports without a second copy to drift.
    monitor_gain: Option<Arc<AtomicU32>>,
    /// The device's configured buffer and period, in frames, and its rate. The
    /// page maps the transport's position onto its own audio clock with these,
    /// so a browser voice and the engine's click share one timeline.
    buffer: usize,
    period: usize,
    rate: u32,
}

impl TransportSession {
    fn is_playing(&self) -> bool {
        self.control.is_playing() && !self.control.is_stopping()
    }

    /// Attach a take's live ring to this transport's render thread. False means
    /// the thread has gone; the caller then refuses the take rather than
    /// starting one whose live input nobody will read.
    fn attach_live(&mut self, consumer: Consumer, gain: Arc<AtomicU32>) -> bool {
        if self
            .live_tx
            .send(TransportLive::Attach {
                consumer,
                gain: Arc::clone(&gain),
            })
            .is_err()
        {
            return false;
        }
        self.live_owner = Some(LiveInputOwner::Take);
        self.monitor_input = true;
        self.monitor_gain = Some(gain);
        true
    }

    /// Attach a listen's finished stereo to this transport. The listen's strip
    /// already applied its gain, pan, inserts and rack, so the transport trims
    /// the slot at unity; this is not a take, so `monitor_input` stays false.
    fn attach_listen(&mut self, consumer: Consumer) -> bool {
        let gain = Arc::new(AtomicU32::new(1f32.to_bits()));
        if self
            .live_tx
            .send(TransportLive::Attach { consumer, gain })
            .is_err()
        {
            return false;
        }
        self.live_owner = Some(LiveInputOwner::Listen);
        self.monitor_input = false;
        self.monitor_gain = None;
        true
    }

    /// Detach the live input at the next block. The transport's clips and
    /// click keep playing; the live part of its bus becomes silence.
    fn detach_live(&mut self) {
        if self.live_owner.is_some() {
            let _ = self.live_tx.send(TransportLive::Detach);
        }
        self.live_owner = None;
        self.monitor_input = false;
        self.monitor_gain = None;
    }

    /// Detach only a take's live input, leaving a listen attached. A take stop
    /// must not silence a listen riding the same transport.
    fn detach_take_live(&mut self) {
        if self.live_owner == Some(LiveInputOwner::Take) {
            let _ = self.live_tx.send(TransportLive::Detach);
            self.live_owner = None;
            self.monitor_input = false;
            self.monitor_gain = None;
        }
    }

    /// Detach only a listen, leaving a take's live input attached.
    fn detach_listen_live(&mut self) {
        if self.live_owner == Some(LiveInputOwner::Listen) {
            let _ = self.live_tx.send(TransportLive::Detach);
            self.live_owner = None;
        }
    }

    /// Signal the render thread and wait for it. When this returns the device
    /// is closed (or the null loop has left) and `state` is stopped.
    fn finish(&mut self) {
        self.control.request_stop();
        let joined = match self.handle.take() {
            Some(handle) => handle.join(),
            None => Ok(()),
        };
        self.control.set_playing(false);
        if joined.is_err() {
            let mut error = self
                .error
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            if error.is_empty() {
                *error = "the transport thread panicked".to_string();
            }
        }
    }

    fn line(&self, rate: u32) -> String {
        format!("{{\"ok\":true,\"transport\":{}}}", self.fragment(rate))
    }

    /// The transport's own object, without the `ok` wrapper. `status` uses it
    /// beside a recording take so one line can carry both roles.
    fn fragment(&self, rate: u32) -> String {
        let control = &self.control;
        let rate = rate.max(1) as f64;
        let state = if control.is_playing() {
            "playing"
        } else {
            "stopped"
        };
        let error = self
            .error
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        let error = if error.is_empty() {
            String::new()
        } else {
            format!(
                ",\"error\":\"{}\"",
                jawn_audio::loopback::json_escape(&error)
            )
        };
        let monitor_gain = self
            .monitor_gain
            .as_ref()
            .map(|gain| f32::from_bits(gain.load(Ordering::Acquire)))
            .unwrap_or(1.0);
        format!(
            "{{\"state\":\"{}\",\"position\":{:.6},\"bpm\":{},\"beats_per_bar\":{},\"loop_start\":{:.6},\"loop_end\":{:.6},\"clips\":{},\"master\":{},\"drums\":{},\"drum_kit\":\"{}\",\"synth\":{},\"synth_clips\":{},\"apps\":{},\"monitor_input\":{},\"monitor_gain\":{},\"buffer\":{},\"period\":{},\"rate\":{}{}}}",
            state,
            control.position() as f64 / rate,
            control.bpm(),
            control.beats_per_bar(),
            control.loop_start() as f64 / rate,
            control.loop_end() as f64 / rate,
            self.clips,
            self.master,
            self.drums,
            jawn_audio::loopback::json_escape(&self.drum_kit),
            self.synth,
            self.synth_clips,
            self.drum_routes + self.synth_routes,
            self.monitor_input,
            monitor_gain,
            self.buffer,
            self.period,
            self.rate.max(1),
            error
        )
    }
}

/// The transport before it was ever started: stopped at zero, at the page's
/// default tempo and signature, with no loop. The route always has a shape to
/// answer with, exactly as an idle `status` does.
fn default_transport_line() -> String {
    "{\"ok\":true,\"transport\":{\"state\":\"stopped\",\"position\":0.000000,\"bpm\":120,\"beats_per_bar\":4,\"loop_start\":0.000000,\"loop_end\":0.000000,\"clips\":0,\"master\":0,\"drums\":0,\"drum_kit\":\"off\",\"synth\":0,\"synth_clips\":0,\"apps\":0,\"monitor_input\":false,\"monitor_gain\":1}}"
        .to_string()
}

/// The transport's worker. It owns the output for as long as it runs; the
/// socket never opens a second output for a playback, listen or patch while it
/// does. A take may still capture beside it, because a take's capture stream
/// and its monitor are separate. A take's live input may also join this
/// output through `live`, while its own monitor files and click still refuse.
/// The device loop never returns on its own: `stop` makes the source's next
/// block fail, which is the same clean path a stopped playback takes.
fn run_transport(
    config: Config,
    control: Arc<TransportControl>,
    error: Arc<Mutex<String>>,
    clips: Vec<TransportClip>,
    master: Vec<InsertKind>,
    master_values: Vec<(String, f32)>,
    drums: Option<DrumChart>,
    synth_clips: Vec<SynthClip>,
    sends: Vec<(usize, usize)>,
    plans: std::sync::mpsc::Receiver<TransportPlan>,
    live: std::sync::mpsc::Receiver<TransportLive>,
    notes: std::sync::mpsc::Receiver<TransportNote>,
    hits: std::sync::mpsc::Receiver<TransportHit>,
    monitor: MonitorControl,
) {
    let mut source = TransportSource::new(Arc::clone(&control))
        .with_clips(clips)
        .with_master(master)
        .with_master_values(master_values)
        .with_synth_clips(synth_clips)
        .with_sends(sends)
        .with_plan_rx(plans)
        .with_live_rx(live)
        .with_note_rx(notes)
        .with_hit_rx(hits);
    if let Some(chart) = drums {
        source = source.with_drums(chart);
    }
    // The tap wraps the finished source, so it copies the same block the room
    // hears: the clip mix after the master rack, plus the click. The ring push
    // is lock-free and never waits for a controller.
    let mut source = jawn_audio::stream::TapSource::new(source, monitor.producer());
    let outcome = match config.backend {
        BackendKind::Null => transport_null(&config, &mut source, &control),
        BackendKind::Alsa | BackendKind::PipeWire => {
            transport_hardware(&config, source, &control)
        }
        BackendKind::Jack => Err(crate::play_support_message()),
        BackendKind::Oboe => Err(crate::oboe_capture_only_message()),
    };
    // The monitor stream outlives this transport. It follows the engine's
    // output bus: it keeps its listener and client, and serves the house patch's
    // mix if one takes the output. While nothing feeds the ring the writer sends
    // no bytes, so the receiver plays its own silence instead of a stale block.
    // It ends only on an explicit `monitor stop`, engine shutdown
    // (`MonitorTap::finish`) or the controller disconnecting.
    control.set_playing(false);
    if let Err(message) = outcome {
        if !control.is_stopping() {
            let mut slot = error
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner());
            *slot = message;
        }
    }
}

/// The null transport keeps the same real-time shape a device does: one block
/// per period, so status and control latency read like the hardware path. It
/// writes no samples anywhere; the click exists only in the rendered block.
fn transport_null<S: RenderSource>(
    config: &Config,
    source: &mut S,
    control: &TransportControl,
) -> Result<(), String> {
    source.prepared(config.rate, config.period)?;
    let mut out = vec![0.0f32; config.period * 2];
    let step = Duration::from_secs_f64(config.period as f64 / config.rate.max(1) as f64);
    while !control.is_stopping() {
        source.block(&mut out)?;
        thread::sleep(step);
    }
    Ok(())
}

#[cfg(feature = "alsa")]
fn transport_hardware<S: RenderSource>(
    config: &Config,
    source: S,
    _control: &TransportControl,
) -> Result<(), String> {
    jawn_audio::alsa_device::run_file_playback_guarded(
        &config.device,
        config.rate,
        config.period,
        config.buffer,
        u64::MAX,
        source,
        None,
    )
    .map(|_| ())
    .map_err(|error| {
        if error == "stopped" {
            error
        } else {
            format!("cannot play: {error}")
        }
    })
}

#[cfg(not(feature = "alsa"))]
fn transport_hardware<S: RenderSource>(
    config: &Config,
    source: S,
    _control: &TransportControl,
) -> Result<(), String> {
    let _ = (config, source);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

/// What `status` reads for a listen: its state, the frames it has rendered and
/// the strip it was armed with.
#[derive(Clone)]
struct ListenStatus {
    state: State,
    channel: usize,
    /// Every input this listen monitors, in the order it was armed. `channel`
    /// is the first, kept so an older page reads the field it always read.
    channels: Vec<usize>,
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
        let channels = status
            .channels
            .iter()
            .map(|channel| channel.to_string())
            .collect::<Vec<String>>()
            .join(",");
        format!(
            "{{\"ok\":{},\"state\":\"{}\",\"channel\":{},\"channels\":[{}],\"frames\":{},\"gain\":{},\"pan\":{},\"inserts\":\"{}\",\"error\":\"{}\"}}",
            ok,
            status.state.name(),
            status.channel,
            channels,
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
    bus: Option<Producer>,
) {
    // One input is the old strip; several are the same strip built once per
    // input and summed. The unit is built on this thread because an insert is
    // not `Send`.
    let mut unit = ListenUnit::new(&plan, Some(Arc::clone(&params)));
    let inputs = plan.channels.clone();
    // A `bus` means a listening transport already owns the output: the same
    // capture and strip run here, but the stereo block goes to the transport's
    // live ring instead of a device this worker would have to open.
    let outcome = match bus.as_ref() {
        Some(producer) => match config.backend {
            BackendKind::Null => {
                listen_bus_null(&mut unit, &inputs, &config, &status, &stop, producer)
            }
            BackendKind::Alsa | BackendKind::PipeWire => {
                listen_bus_hardware(&config, &mut unit, &status, &stop, producer)
            }
            BackendKind::Jack => Err(crate::listen_support_message()),
            BackendKind::Oboe => Err(crate::oboe_capture_only_message()),
        },
        None => match config.backend {
            BackendKind::Null => listen_null(&mut unit, &inputs, &config, &status, &stop),
            BackendKind::Alsa | BackendKind::PipeWire => {
                listen_hardware(&config, &mut unit, &status, &stop)
            }
            BackendKind::Jack => Err(crate::listen_support_message()),
            BackendKind::Oboe => Err(crate::oboe_capture_only_message()),
        },
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

/// The null listen: silence through the same strips, as fast as the CPU allows.
/// `progress` keeps `status`'s frame count moving while the client watches.
fn listen_null(
    sink: &mut ListenUnit,
    inputs: &[usize],
    config: &Config,
    status: &Arc<Mutex<ListenStatus>>,
    stop: &AtomicBool,
) -> Result<u64, String> {
    let run = listen::run_null_sink(
        sink,
        inputs,
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

/// Push one finished stereo block into the transport's live ring and count it
/// for `status`. The ring never blocks: a full one drops the newest frames and
/// counts them, exactly as it does for a take's monitor.
fn push_listen_bus(
    producer: &Producer,
    status: &Arc<Mutex<ListenStatus>>,
    frames: &mut u64,
    block: &[f32],
) {
    producer.push(block);
    *frames += (block.len() / 2) as u64;
    let mut current = status
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    current.frames = *frames;
}

/// The null listen that rides a transport: the same strip and a silent source,
/// with its stereo block written to the transport's live ring.
fn listen_bus_null(
    unit: &mut ListenUnit,
    inputs: &[usize],
    config: &Config,
    status: &Arc<Mutex<ListenStatus>>,
    stop: &AtomicBool,
    producer: &Producer,
) -> Result<u64, String> {
    let mut sink = BusNullSink {
        unit,
        producer,
        status,
        frames: 0,
        input_f32: Vec::new(),
        output_f32: Vec::new(),
    };
    let run = listen::run_null_sink(
        &mut sink,
        inputs,
        config.rate,
        config.period,
        config.channels,
        None,
        None,
        stop,
        |_| {},
    )?;
    Ok(run.frames)
}

/// The null loop's sink: runs the listen unit, then hands the stereo block to
/// the transport's ring. `block` is implemented for completeness; the null
/// loop takes the f32 path, which needs no conversion.
struct BusNullSink<'a> {
    unit: &'a mut ListenUnit,
    producer: &'a Producer,
    status: &'a Arc<Mutex<ListenStatus>>,
    frames: u64,
    input_f32: Vec<f32>,
    output_f32: Vec<f32>,
}

impl ListenSink for BusNullSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        self.input_f32 = vec![0.0; period.saturating_mul(channels)];
        self.output_f32 = vec![0.0; period.saturating_mul(2)];
        self.unit.prepared(rate, period, channels)
    }

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        let frames = output.len() / 2;
        if frames == 0 {
            return Ok(());
        }
        let channels = input.len() / frames;
        for (target, sample) in self.input_f32[..input.len()].iter_mut().zip(input) {
            *target = f32::from(*sample) / 32_768.0;
        }
        let rendered = self.unit.block_f32(
            &self.input_f32[..input.len()],
            channels,
            &mut self.output_f32[..frames * 2],
        )?;
        push_listen_bus(
            self.producer,
            self.status,
            &mut self.frames,
            &self.output_f32[..rendered * 2],
        );
        for (target, sample) in output[..rendered * 2]
            .iter_mut()
            .zip(&self.output_f32[..rendered * 2])
        {
            *target = to_i16(*sample);
        }
        Ok(())
    }

    fn block_f32(
        &mut self,
        input: &[f32],
        channels: usize,
        output: &mut [f32],
    ) -> Result<usize, String> {
        let rendered = self.unit.block_f32(input, channels, output)?;
        push_listen_bus(
            self.producer,
            self.status,
            &mut self.frames,
            &output[..rendered * 2],
        );
        Ok(rendered)
    }
}

/// The hardware listen that rides a transport: capture only. The transport has
/// the playback stream open already, so this opens the capture side and pushes
/// each finished block into its live ring rather than writing a second output.
#[cfg(feature = "alsa")]
fn listen_bus_hardware(
    config: &Config,
    unit: &mut ListenUnit,
    status: &Arc<Mutex<ListenStatus>>,
    stop: &AtomicBool,
    producer: &Producer,
) -> Result<u64, String> {
    let sink = BusCaptureSink {
        unit,
        producer,
        status,
        stop,
        frames: 0,
        channels: config.channels,
        input_f32: Vec::new(),
        stereo: Vec::new(),
    };
    // The capture loop is duration-shaped, so ask for the longest run its u64
    // frame count can hold; the sink's stop check is what actually ends it.
    let seconds = (u64::MAX as f64) / f64::from(config.rate.max(1));
    let report = jawn_audio::alsa_device::run_capture(
        &config.device,
        config.rate,
        config.period,
        config.buffer,
        config.channels,
        seconds,
        sink,
    )
    .map_err(|error| format!("cannot listen: {error}"))?;
    Ok(report.frames)
}

#[cfg(not(feature = "alsa"))]
fn listen_bus_hardware(
    config: &Config,
    unit: &mut ListenUnit,
    status: &Arc<Mutex<ListenStatus>>,
    stop: &AtomicBool,
    producer: &Producer,
) -> Result<u64, String> {
    let _ = (config, unit, status, stop, producer);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

/// The capture sink for a listen riding a transport: the same i16 read a take
/// gets, run through the listen unit, then pushed to the transport's ring. The
/// stop check lives here because this loop owns the device read.
#[cfg(feature = "alsa")]
struct BusCaptureSink<'a> {
    unit: &'a mut ListenUnit,
    producer: &'a Producer,
    status: &'a Arc<Mutex<ListenStatus>>,
    stop: &'a AtomicBool,
    frames: u64,
    channels: usize,
    input_f32: Vec<f32>,
    stereo: Vec<f32>,
}

#[cfg(feature = "alsa")]
impl jawn_audio::alsa_device::CaptureSink for BusCaptureSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        self.channels = channels;
        self.input_f32 = vec![0.0; period.saturating_mul(channels)];
        self.stereo = vec![0.0; period.saturating_mul(2)];
        self.unit.prepared(rate, period, channels)
    }

    fn block(&mut self, input: &[i16]) -> Result<(), String> {
        if self.stop.load(Ordering::SeqCst) {
            return Err("stopped".to_string());
        }
        let channels = self.channels;
        if channels == 0 {
            return Err("a capture needs at least one channel".to_string());
        }
        let frames = input.len() / channels;
        if frames > self.stereo.len() / 2 {
            return Err(format!(
                "a {frames}-frame block is longer than the prepared {} frames",
                self.stereo.len() / 2
            ));
        }
        for (target, sample) in self.input_f32[..input.len()].iter_mut().zip(input) {
            *target = f32::from(*sample) / 32_768.0;
        }
        let rendered = self.unit.block_f32(
            &self.input_f32[..input.len()],
            channels,
            &mut self.stereo[..frames * 2],
        )?;
        push_listen_bus(
            self.producer,
            self.status,
            &mut self.frames,
            &self.stereo[..rendered * 2],
        );
        Ok(())
    }
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
    /// Source trims and insert knobs, drained beside the route queue.
    source_params: Arc<ParamQueue>,
    /// Each source's armed insert chain, in plan order, so a `patch_source`
    /// param can be checked against the chain the source actually built.
    source_inserts: Vec<Vec<InsertKind>>,
    /// One flag per route (plan order): whether it has a live strip and can
    /// take a gain/pan change.
    executable: Vec<bool>,
    /// The reception mixer's screened-call capture, when the plan declared a
    /// `handset` source. Stopped and joined with the patch.
    handset: Option<crate::system_capture::SystemCapture>,
    /// The peer uplink thread, when `--uplink` is configured and the plan has
    /// a routed peer source. Stopped and joined with the patch.
    uplink: Option<Uplink>,
    /// The plan's bus ids, in compile order: a bus take may name only one of
    /// these.
    bus_ids: Vec<String>,
    /// The bus take's control side. It lives as long as the patch and lets a
    /// take attach mid-patch.
    tap: Arc<crate::patchbay::BusTap>,
    /// False once the patch worker's block loop has ended, so a bus take can
    /// close its file with the frames that already exist instead of waiting
    /// for a producer that is gone.
    alive: Arc<AtomicBool>,
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
        if let Some(mut uplink) = self.uplink.take() {
            uplink.stop();
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
    alive: Arc<AtomicBool>,
    system_device: Option<String>,
) {
    let outcome: Result<(u64, usize), String> = match config.backend {
        BackendKind::Null => patch_null(&mut patchbay, &config, &status, &stop),
        BackendKind::Alsa | BackendKind::PipeWire => {
            patch_hardware(&config, patchbay, &status, &stop, system_device)
        }
        BackendKind::Jack => Err(crate::listen_support_message()),
        BackendKind::Oboe => Err(crate::oboe_capture_only_message()),
    };
    // The block loop is over, so the tap's producer will push nothing more.
    // A bus take reads this and closes its WAV with the frames that exist.
    alive.store(false, Ordering::Release);
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
        Err(error) => {
            let sink = if config.backend == BackendKind::PipeWire {
                crate::system_capture::default_sink()
            } else {
                None
            };
            return Err(patch_error(
                &error,
                &config.device,
                config.target.as_deref(),
                sink.as_deref(),
            ));
        }
    };
    for mut capture in input_captures {
        capture.stop();
    }
    if let Some(capture) = capture.as_mut() {
        capture.stop();
    }
    Ok((run.frames, run.xruns))
}

/// The sentence a failed patch reports: the backend's own error plus the PCM
/// it opened, the node it was told to play out, and the sink the server would
/// otherwise have used. A fact that is not known is left out rather than shown
/// empty, and a value already named is not repeated.
#[cfg_attr(not(feature = "alsa"), allow(dead_code))]
fn patch_error(error: &str, device: &str, target: Option<&str>, sink: Option<&str>) -> String {
    let mut facts = vec![format!("pcm \"{device}\"")];
    let target = target.map(str::trim).filter(|value| !value.is_empty());
    if let Some(target) = target.filter(|value| *value != device) {
        facts.push(format!("target \"{target}\""));
    }
    let sink = sink.map(str::trim).filter(|value| !value.is_empty());
    if let Some(sink) = sink.filter(|value| *value != device && Some(*value) != target) {
        facts.push(format!("default sink \"{sink}\""));
    }
    format!("cannot patch: {error} ({})", facts.join("; "))
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
    sink: &'a mut ListenUnit,
    status: &'a Arc<Mutex<ListenStatus>>,
    frames: u64,
}

#[cfg(feature = "alsa")]
impl listen::ListenSink for SocketListenSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        self.sink.prepared(rate, period, channels)
    }

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        self.sink.block(input, output)?;
        self.record(output.len() / 2);
        Ok(())
    }

    fn block_with_system(
        &mut self,
        input: &[i16],
        system: &[f32],
        output: &mut [i16],
    ) -> Result<(), String> {
        self.sink.block_with_system(input, system, output)?;
        self.record(output.len() / 2);
        Ok(())
    }
}

#[cfg(feature = "alsa")]
impl SocketListenSink<'_> {
    /// Count the frames the unit actually rendered. The sink's trait method
    /// returns only success or a sentence, so the width comes from the stereo
    /// output the unit wrote; this is also why `block` cannot treat its
    /// `Result` as a frame count.
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
fn listen_hardware(
    config: &Config,
    sink: &mut ListenUnit,
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
        sink,
        status,
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
    sink: &mut ListenUnit,
    status: &Arc<Mutex<ListenStatus>>,
    stop: &AtomicBool,
) -> Result<u64, String> {
    let _ = (config, sink, status, stop);
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
    click: Option<ClickSpec>,
) {
    // Build the strips here, on the playback thread, so a chain never moves
    // between threads. The control thread already checked the shape. A
    // monitor's control ring is the one `param` pushes to; a plain playback
    // has no live knobs yet.
    let built = if tracks.is_empty() {
        // No files: a live monitor or a click-only monitor. The take's frames
        // and rate are the whole shape, and a click alone is a legal playback.
        match live {
            Some((consumer, gain)) => Ok(Playback::live(
                config.rate,
                length.unwrap_or(0),
                consumer,
                gain,
            )),
            None if click.is_some() => {
                Ok(Playback::click_only(config.rate, length.unwrap_or(0)))
            }
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
            // The click is built from the spec in `prepare`, after the master
            // rack is armed, so it is never in the master chain or the take.
            if let Some(spec) = click {
                playback = playback.with_click(spec);
            }
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
        BackendKind::Oboe => Err(crate::oboe_capture_only_message()),
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
	monitor_track: Option<usize>,
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
    // The send graph was validated when the plan was read. Repeating it here is
    // the same defence the patchbay uses: a hand-built plan cannot reach the
    // block with a loop or an out-of-range edge.
    let sends: Vec<Option<usize>> = plans.iter().map(|plan| plan.from).collect();
    let outcome = match mixer.set_sends(&sends) {
        Err(error) => Err(error),
        Ok(()) => match config.backend {
            			BackendKind::Null => capture_null(
            				&config,
            				seconds,
            				&mut disks,
            				&mut mixer,
            				&status,
            				&stop,
            				live.as_ref(),
            				&armed,
            				monitor_track,
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
            				monitor_track,
            			),
            // Oboe is capture-only in this slice, and `--serve` is not wired
            // to it; an honest refusal beats a half-wired backend.
            BackendKind::Oboe => Err(crate::oboe_capture_only_message()),
        },
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
	monitor_track: Option<usize>,
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
    // One mono and one stereo block per track: a send hands the upstream mono
    // block to the downstream strip, so the two cannot share one buffer.
    let mut mono: Vec<Vec<f32>> = (0..track_count).map(|_| vec![0.0f32; config.period]).collect();
    let mut stereo: Vec<Vec<f32>> = (0..track_count)
        .map(|_| vec![0.0f32; config.period * TAKE_CHANNELS])
        .collect();
    let mut pcm = vec![0i16; config.period * TAKE_CHANNELS];
    // The monitoring bus is the sum of every terminal track's processed stereo
    // output, pushed once per block so the monitor hears the whole take, not
    // one stem. A track that feeds another is heard through it, never twice.
    let mut live_block = vec![0.0f32; config.period * TAKE_CHANNELS];
    // The device shape each track reads. A sent track reads no channel, so its
    // entry is unused; the closure below only runs for a track with no send.
    let track_inputs: Vec<(usize, usize)> = mixer
        .tracks()
        .iter()
        .map(|track| (track.input, track.channels))
        .collect();
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
        mixer.process_tracks(
            frames,
            |track, out| {
                let (input, track_channels) = track_inputs[track];
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
                    out,
                );
                Ok(())
            },
            &mut mono,
            &mut stereo,
        )?;
        		for track in 0..track_count {
        			if live.is_some() {
        				let heard = match monitor_track {
        					Some(selected) => selected == track,
        					None => !mixer.has_outgoing(track),
        				};
        				if heard {
        					for (out, sample) in live_block[..samples].iter_mut().zip(&stereo[track][..samples]) {
        						*out += sample;
        					}
        				}
        			}
            for (out, sample) in pcm[..samples].iter_mut().zip(&stereo[track][..samples]) {
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
    mono: Vec<Vec<f32>>,
    stereo: Vec<Vec<f32>>,
    track_inputs: Vec<(usize, usize)>,
	    live_block: Vec<f32>,
	    pcm: Vec<i16>,
	    /// The one track the live monitor carries; `None` is the historical sum
	    /// of every terminal track.
	    monitor_track: Option<usize>,
	}

#[cfg(feature = "alsa")]
impl jawn_audio::alsa_device::CaptureSink for ServeSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        self.channels = channels;
        if let Some(index) = self
            .mixer
            .tracks()
            .iter()
            .position(|track| track.from.is_none() && track.input + track.channels > channels)
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
        let count = self.mixer.tracks().len();
        self.mono = (0..count).map(|_| vec![0.0; period]).collect();
        self.stereo = (0..count)
            .map(|_| vec![0.0; period * TAKE_CHANNELS])
            .collect();
        self.track_inputs = self
            .mixer
            .tracks()
            .iter()
            .map(|track| (track.input, track.channels))
            .collect();
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
        let track_count = self.mixer.tracks().len();
        if self.disks.len() != track_count {
            return Err(format!(
                "{track_count} track(s) but {} disk writer(s)",
                self.disks.len()
            ));
        }
        let frames = (block.len() / channels).min(
            self.mono.first().map(|block| block.len()).unwrap_or(0),
        );
        let samples = frames * TAKE_CHANNELS;
        if self.live.is_some() {
            self.live_block[..samples].fill(0.0);
        }
        self.mixer.process_tracks(
            frames,
            |track, out| {
                let (input, track_channels) = self.track_inputs[track];
                if input + track_channels > channels {
                    return Err(channel_error(
                        track + 1,
                        input,
                        track_channels,
                        channels,
                        "the device has",
                    ));
                }
                read_mono_i16(block, frames, channels, input, track_channels, out);
                Ok(())
            },
            &mut self.mono,
            &mut self.stereo,
        )?;
	        for track in 0..track_count {
	            if self.live.is_some() {
	                let heard = match self.monitor_track {
	                    Some(selected) => selected == track,
	                    None => !self.mixer.has_outgoing(track),
	                };
	                if heard {
	                    for (out, sample) in self.live_block[..samples]
	                        .iter_mut()
	                        .zip(&self.stereo[track][..samples])
	                    {
	                        *out += sample;
	                    }
	                }
	            }
            for (out, sample) in self.pcm[..samples].iter_mut().zip(&self.stereo[track][..samples]) {
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
    monitor_track: Option<usize>,
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
        track_inputs: Vec::new(),
	        live_block: Vec::new(),
	        pcm: Vec::new(),
	        monitor_track,
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
	monitor_track: Option<usize>,
) -> Result<Captured, String> {
	let _ = (config, seconds, disks, mixer, status, stop, live, armed, monitor_track);
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
    fn a_failed_patch_names_the_pcm_and_only_the_facts_it_knows() {
        // No target and no sink: the raw error plus the PCM the backend opened.
        let line = patch_error(
            "ALSA function 'snd_pcm_writei' failed with error 'I/O error (5)'",
            "default",
            None,
            None,
        );
        assert!(line.starts_with("cannot patch:"), "{line}");
        assert!(line.contains("ALSA function 'snd_pcm_writei' failed"), "{line}");
        assert!(line.contains("pcm \"default\""), "{line}");
        assert!(!line.contains("target"), "{line}");
        assert!(!line.contains("default sink"), "{line}");

        // A named target, still no sink to report.
        let line = patch_error("boom", "default", Some("jawn_system"), None);
        assert!(line.starts_with("cannot patch:"), "{line}");
        assert_eq!(line.matches("jawn_system").count(), 1, "{line}");
        assert!(line.contains("target \"jawn_system\""), "{line}");
        assert!(!line.contains("default sink"), "{line}");

        // Both facts, each exactly once.
        let line = patch_error(
            "boom",
            "default",
            Some("jawn_system"),
            Some("alsa_output.pci.analog-stereo"),
        );
        assert!(line.starts_with("cannot patch:"), "{line}");
        assert_eq!(line.matches("jawn_system").count(), 1, "{line}");
        assert_eq!(
            line.matches("alsa_output.pci.analog-stereo").count(),
            1,
            "{line}"
        );
        assert!(line.contains("default sink \"alsa_output.pci.analog-stereo\""), "{line}");
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
        let deep = r#"{"a":{"b":{"c":{"d":{"e":1}}}}}"#;
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
                uplink: None,
            },
            &STOP,
            None,
        )
    }

    /// The status line keeps every existing key and always adds `uplink`; with
    /// no `--uplink` the object says `off` rather than disappearing.
    #[test]
    fn every_status_line_reports_the_uplink() {
        let mut server = socket_server();
        let line = server.status_line();
        let object = parse_object(&line).expect("the status parses");
        let uplink = match get(&object, "uplink") {
            Some(Value::Obj(uplink)) => uplink,
            other => panic!("no uplink object: {other:?}"),
        };
        assert!(matches!(get(uplink, "state"), Some(Value::Str(state)) if state == "off"));
        assert!(matches!(get(uplink, "bind"), Some(Value::Str(bind)) if bind.is_empty()));
    }

    #[test]
    fn the_monitor_command_starts_reports_and_stops() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"monitor","action":"start","port":0}"#));
        assert!(started.contains("\"ok\":true"), "{started}");
        assert!(started.contains("\"stream\":true"), "{started}");
        let object = parse_object(&started).expect("the start reply parses");
        let port = number(&object, "port").expect("a bound port");
        assert!(port >= 1.0 && port <= 65_535.0, "{started}");

        let status = server.status_line();
        assert!(status.contains("\"stream\":{"), "{status}");
        assert!(status.contains("\"streaming\":false"), "{status}");
        assert!(status.contains("\"rate\":48000"), "{status}");

        let stopped = reply(server.handle(r#"{"cmd":"monitor","action":"stop"}"#));
        assert!(stopped.contains("\"ok\":true"), "{stopped}");
        assert!(stopped.contains("\"stream\":false"), "{stopped}");
        assert!(
            server.status_line().contains("\"stream\":{\"enabled\":false"),
            "the status saw the stop"
        );

        for (line, needle) in [
            (r#"{"cmd":"monitor","action":"play"}"#, "start, stop or status"),
            (r#"{"cmd":"monitor"}"#, "action"),
            (r#"{"cmd":"monitor","action":"start","port":"x"}"#, "port"),
            (r#"{"cmd":"monitor","action":"start","port":70000}"#, "port"),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
        }
    }

    #[test]
    fn a_transport_feeds_the_monitor_and_its_end_keeps_the_stream() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"monitor","action":"start","port":0}"#));
        let object = parse_object(&started).expect("the start reply parses");
        let port = number(&object, "port").expect("a bound port") as u16;

        let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("read timeout");
        let deadline = Instant::now() + Duration::from_secs(3);
        while !server.monitor.control().is_streaming() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
        }
        assert!(server.monitor.control().is_streaming(), "the client connected");

        let playing = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(playing.contains("\"state\":\"playing\""), "{playing}");
        let mut bytes = [0u8; 16];
        client.read_exact(&mut bytes).expect("the monitor wrote PCM");
        let status = server.status_line();
        assert!(status.contains("\"streaming\":true"), "{status}");
        assert!(status.contains("\"monitor_frames\":"), "{status}");

        // The stream follows the engine's output bus, not the transport: the
        // transport ending leaves the listener and its client in place, ready
        // for the house patch to take the output or for an explicit stop.
        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
        let status = server.status_line();
        assert!(status.contains("\"stream\":{\"enabled\":true"), "{status}");
        assert!(status.contains("\"port\":"), "{status}");
        client
            .set_read_timeout(Some(Duration::from_millis(100)))
            .expect("read timeout");
        let mut probe = [0u8; 1];
        assert!(
            !matches!(client.read(&mut probe), Ok(0)),
            "the transport's end did not close the controller"
        );

        // Only an explicit stop ends it.
        let stopped = reply(server.handle(r#"{"cmd":"monitor","action":"stop"}"#));
        assert!(stopped.contains("\"stream\":false"), "{stopped}");
        assert!(
            server.status_line().contains("\"stream\":{\"enabled\":false"),
            "the explicit stop closed it"
        );
    }

    #[test]
    fn a_patch_keeps_feeding_the_monitor_after_the_transport_ends() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"monitor","action":"start","port":0}"#));
        let object = parse_object(&started).expect("the start reply parses");
        let port = number(&object, "port").expect("a bound port") as u16;
        let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).expect("connect");
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("read timeout");
        let deadline = Instant::now() + Duration::from_secs(3);
        while !server.monitor.control().is_streaming() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
        }
        assert!(server.monitor.control().is_streaming(), "the client connected");

        let playing = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(playing.contains("\"state\":\"playing\""), "{playing}");
        let mut bytes = [0u8; 16];
        client.read_exact(&mut bytes).expect("the transport fed the monitor");
        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
        let deadline = Instant::now() + Duration::from_secs(3);
        while server
            .transport
            .as_ref()
            .map(TransportSession::is_playing)
            .unwrap_or(false)
            && Instant::now() < deadline
        {
            thread::sleep(Duration::from_millis(2));
        }

        // Drain what the transport left in the ring and the socket, so the
        // bytes read below can only come from the patch.
        client
            .set_read_timeout(Some(Duration::from_millis(100)))
            .expect("read timeout");
        let mut drain = [0u8; 4096];
        while client.read(&mut drain).map(|got| got > 0).unwrap_or(false) {}

        // The house patch owns the output now; it feeds the same ring, so the
        // controller the transport left behind keeps hearing the room.
        let patch = r#"{"cmd":"patch","plan":{"sources":[{"id":"in0","kind":"input","channel":0}],"sinks":[{"id":"out","kind":"speakers"}],"routes":[{"from":"in0","to":"out","gain":1,"pan":0}]}}"#;
        let answer = reply(server.handle(patch));
        assert!(answer.contains("\"state\":\"patching\""), "{answer}");
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("read timeout");
        let mut bytes = [0u8; 16];
        client.read_exact(&mut bytes).expect("the patch fed the monitor");

        let _ = server.handle(r#"{"cmd":"unpatch"}"#);
        let _ = server.handle(r#"{"cmd":"monitor","action":"stop"}"#);
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
            first_sample: 0,
            xruns: 0,
            align_samples: 0,
            align_from: "none",
            tracks: vec![TrackStatus {
                path: "/tmp/take.wav".to_string(),
                input: 0,
                from: None,
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
            // No monitor output was started for this stand-in take.
            monitor_owned: false,
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
    fn a_take_plan_may_feed_a_track_from_another() {
        let object = parse_object(
            r#"{"tracks":[{"input":0,"inserts":["tone"]},{"from":0,"inserts":["delay"]}]}"#,
        )
        .expect("parse");
        let values = match get(&object, "tracks") {
            Some(Value::Arr(values)) => values,
            other => panic!("tracks is not an array: {other:?}"),
        };
        let plans = track_plans(values).expect("a send plan");
        assert_eq!(plans[0].from, None);
        assert_eq!(plans[0].input, 0);
        assert_eq!(plans[1].from, Some(0));
        assert_eq!(plans[1].inserts, vec![InsertKind::Delay]);

        for (body, sentence) in [
            (
                r#"[{"input":0},{"from":0,"input":1}]"#,
                "track 2 takes its input from another track, so it cannot also name \"input\"",
            ),
            (
                r#"[{"from":0}]"#,
                "track 1 cannot take its own output as its input",
            ),
            (
                r#"[{"input":0},{"from":4}]"#,
                "track 2 is fed by track 5, but the take has only 2 track(s)",
            ),
            (
                r#"[{"input":0},{"from":0},{"from":0}]"#,
                "track 1 feeds track 2 and track 3; a channel send has one destination",
            ),
            (
                r#"[{"from":1},{"from":0}]"#,
                "tracks 1, 2 form a channel send loop",
            ),
        ] {
            let object = parse_object(&format!(r#"{{"tracks":{body}}}"#)).expect("parse");
            let values = match get(&object, "tracks") {
                Some(Value::Arr(values)) => values,
                other => panic!("tracks is not an array: {other:?}"),
            };
            let error = track_plans(values).err().expect("a bad send plan");
            assert_eq!(error, sentence);
        }
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

    #[test]
    fn a_click_plan_is_validated_before_any_file_or_thread_exists() {
        let object = parse_object(
            r#"{"click":{"bpm":120,"beats_per_bar":4,"gain":0.5}}"#,
        )
        .expect("parse");
        let click = parse_click(get(&object, "click")).expect("click");
        assert_eq!(
            click,
            Some(ClickSpec {
                bpm: 120.0,
                beats_per_bar: 4,
                gain: 0.5,
            })
        );

        // A missing gain takes the page's half, and no click at all is absent.
        let defaulted = parse_object(r#"{"click":{"bpm":120,"beats_per_bar":3}}"#)
            .expect("parse");
        let click = parse_click(get(&defaulted, "click")).expect("click");
        assert_eq!(click.expect("click").gain, ClickSpec::DEFAULT_GAIN);
        assert_eq!(parse_click(None).expect("no click"), None);

        for bad in [
            r#"{"click":{"bpm":0,"beats_per_bar":4}}"#,
            r#"{"click":{"bpm":120,"beats_per_bar":0}}"#,
            r#"{"click":{"bpm":120,"beats_per_bar":33}}"#,
            r#"{"click":{"bpm":120,"beats_per_bar":4,"gain":2}}"#,
            r#"{"click":{"bpm":120}}"#,
            r#"{"click":120}"#,
        ] {
            let object = parse_object(bad).expect("parse");
            assert!(parse_click(get(&object, "click")).is_err(), "accepted {bad}");
        }
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

    fn write_wav(path: &str, frames: usize) {
        use jawn_audio::WavWriter;
        let mut writer = WavWriter::create(path, 48_000, 1, 4096).expect("a WAV writer");
        writer
            .write_f32(&vec![0.25f32; frames])
            .expect("write samples");
        writer.finish().expect("finish the WAV");
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
    fn a_take_with_no_alignment_reports_none_at_its_stamp() {
        // Neither `align_samples` nor a calibration: nothing is shifted, and
        // the take reports `none` rather than inventing a capture offset. Its
        // first stored frame is stamped where the caller put it.
        let mut server = socket_server();
        let out = temp_take("unaligned");
        let started = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":30,"start_at":9600}}"#
        )));
        assert!(started.contains("\"ok\":true"), "{started}");
        assert!(started.contains("\"start_sample\":9600"), "{started}");
        assert!(started.contains("\"first_sample\":9600"), "{started}");
        assert!(started.contains("\"align_samples\":0"), "{started}");
        assert!(started.contains("\"align_from\":\"none\""), "{started}");

        let status = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(status.contains("\"first_sample\":9600"), "{status}");
        assert!(status.contains("\"align_from\":\"none\""), "{status}");

        let _ = server.handle(r#"{"cmd":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_given_alignment_shifts_the_take_first_sample() {
        // A declared capture offset places the take's first stored frame that
        // many samples before the stamp. The stamp is unchanged; `first_sample`
        // is where the WAV is placed on the transport.
        let mut server = socket_server();
        let out = temp_take("aligned");
        let started = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":30,"start_at":9600,"align_samples":1200}}"#
        )));
        assert!(started.contains("\"ok\":true"), "{started}");
        assert!(started.contains("\"start_sample\":9600"), "{started}");
        assert!(started.contains("\"first_sample\":8400"), "{started}");
        assert!(started.contains("\"align_samples\":1200"), "{started}");
        assert!(started.contains("\"align_from\":\"given\""), "{started}");

        let status = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(status.contains("\"first_sample\":8400"), "{status}");
        assert!(status.contains("\"align_samples\":1200"), "{status}");
        let _ = server.handle(r#"{"cmd":"stop"}"#);

        // The offset is clamped at sample 0: a stamp smaller than the offset
        // cannot report a negative first sample.
        let near_zero = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":30,"start_at":600,"align_samples":1200}}"#
        )));
        assert!(near_zero.contains("\"first_sample\":0"), "{near_zero}");
        let _ = server.handle(r#"{"cmd":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_malformed_alignment_is_refused_before_a_take_exists() {
        let mut server = socket_server();
        let out = temp_take("bad-align");
        for bad in ["-1", "1.5"] {
            let line = reply(server.handle(&format!(
                r#"{{"cmd":"record","out":"{out}","seconds":1,"align_samples":{bad}}}"#
            )));
            assert!(line.contains("\"ok\":false"), "{bad}: {line}");
            assert!(line.contains("align_samples"), "{bad}: {line}");
            assert!(!std::path::Path::new(&out).exists(), "{bad} created a file");
        }
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
                        source_effects: Vec::new(),
                        inputs: Vec::new(),
                        system: route,
                        handset: "off",
                        mode: "playback",
                        peer: "off",
                        player: "off",
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

    fn playing_transport(position: u64) -> TransportSession {
        let control = Arc::new(TransportControl::new(
            ClickSpec::new(120.0, 4, 0.5).expect("spec"),
            position,
            0,
            0,
        ));
        control.set_playing(true);
        let (plan_tx, _plan_rx) = std::sync::mpsc::channel();
        let (live_tx, _live_rx) = std::sync::mpsc::channel();
        let (note_tx, _note_rx) = std::sync::mpsc::channel();
        let (hit_tx, _hit_rx) = std::sync::mpsc::channel();
        TransportSession {
            control,
            handle: None,
            error: Arc::new(Mutex::new(String::new())),
            clips: 0,
            master: 0,
            drums: 0,
            drum_kit: "off".to_string(),
            synth: 0,
            synth_clips: 0,
            drum_routes: 0,
            synth_routes: 0,
            plan_tx,
            live_tx,
            note_tx,
            hit_tx,
            live_owner: None,
            monitor_input: false,
            monitor_gain: None,
            buffer: 1024,
            period: 256,
            rate: 48_000,
        }
    }

    #[test]
    fn a_transport_status_is_stopped_before_it_ever_starts() {
        let mut server = socket_server();
        let line = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(line.contains("\"transport\":{\"state\":\"stopped\""), "{line}");
        assert!(line.contains("\"bpm\":120"), "{line}");
        assert!(line.contains("\"beats_per_bar\":4"), "{line}");
        assert!(line.contains("\"loop_start\":0.000000"), "{line}");
        assert!(line.contains("\"loop_end\":0.000000"), "{line}");
        assert!(line.contains("\"synth\":0"), "{line}");
        assert!(line.contains("\"apps\":0"), "{line}");
    }

    #[test]
    fn a_transport_refuses_every_bad_field_before_a_thread_exists() {
        let mut server = socket_server();
        let bad = [
            r#"{"cmd":"transport","action":"start","position":-1}"#,
            r#"{"cmd":"transport","action":"start","bpm":0}"#,
            r#"{"cmd":"transport","action":"start","bpm":-120}"#,
            r#"{"cmd":"transport","action":"start","beats_per_bar":33}"#,
            r#"{"cmd":"transport","action":"start","beats_per_bar":2.5}"#,
            r#"{"cmd":"transport","action":"start","gain":2}"#,
            r#"{"cmd":"transport","action":"start","loop_start":4,"loop_end":2}"#,
            r#"{"cmd":"transport","action":"seek","position":12.5}"#,
        ];
        for line in bad {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(
                server.transport.is_none(),
                "{line} started a transport anyway"
            );
        }
    }

    #[test]
    fn a_transport_starts_and_stops_on_the_null_device() {
        let mut server = socket_server();
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"start","position":0,"bpm":120,"beats_per_bar":4,"gain":0.5,"loop_start":0,"loop_end":0}"#,
        ));
        assert!(line.contains("\"transport\":{\"state\":\"playing\""), "{line}");

        let stopped = reply(server.handle(r#"{"cmd":"transport","action":"stop"}"#));
        assert!(
            stopped.contains("\"transport\":{\"state\":\"stopped\""),
            "{stopped}"
        );
    }

    #[test]
    fn a_transport_update_is_refused_when_nothing_is_playing() {
        let mut server = socket_server();
        // Never started: the plan is refused before any file is read.
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","clips":[]}"#,
        ));
        assert!(line.contains("\"ok\":false"), "{line}");
        assert!(line.contains("not playing"), "{line}");

        // Stopped: the session still exists, but no render thread is running.
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");
        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","clips":[]}"#,
        ));
        assert!(line.contains("\"ok\":false"), "{line}");
        assert!(line.contains("not playing"), "{line}");
    }

    #[test]
    fn a_transport_update_reaches_a_running_transport() {
        use jawn_audio::WavWriter;

        let mut server = socket_server();
        let out = temp_take("plan");
        {
            let mut writer = WavWriter::create(&out, 48_000, 1, 4096).expect("a WAV writer");
            writer.write_f32(&[0.25f32; 4_800]).expect("write samples");
            writer.finish().expect("finish the WAV");
        }

        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");
        assert!(started.contains("\"clips\":0"), "{started}");

        let line = reply(server.handle(&format!(
            r#"{{"cmd":"transport","action":"update","clips":[{{"file":"{out}","start":0,"gain":1,"pan":0}}]}}"#
        )));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"playing\""), "{line}");
        assert!(line.contains("\"clips\":1"), "the update did not change the clip count: {line}");

        // A second update clears the plan; the transport keeps playing.
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","clips":[]}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"clips\":0"), "{line}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_repeated_plan_reuses_the_decoded_take() {
        let out = temp_take("cache");
        write_wav(&out, 4_800);
        let mut cache = TakeCache::default();
        let request = parse_object(&format!(
            r#"{{"clips":[{{"file":"{out}","start":0,"gain":1,"pan":0}}]}}"#
        ))
        .expect("parse");

        let first = transport_clips(&request, 48_000, &mut cache).expect("first plan");
        assert_eq!(cache.reads, 1, "the first plan did not read the take");
        let second = transport_clips(&request, 48_000, &mut cache).expect("second plan");
        assert_eq!(cache.reads, 1, "the second plan re-read an unchanged take");
        assert!(
            Arc::ptr_eq(&first[0].samples, &second[0].samples),
            "the plan copied the samples instead of sharing them"
        );

        // A cached entry is still checked against the device rate: reusing the
        // decode never skips the shape check.
        assert!(
            transport_clips(&request, 44_100, &mut cache).is_err(),
            "a cached take skipped its device-rate validation"
        );

        // A re-staged take at the same path has a new size, so the stamp
        // changes and the cache decodes it again.
        write_wav(&out, 9_600);
        let third = transport_clips(&request, 48_000, &mut cache).expect("restaged plan");
        assert_eq!(cache.reads, 2, "a re-staged take was served from the cache");
        assert_eq!(third[0].samples.len(), 9_600);

        // The plan is the whole set: an empty one evicts what it no longer
        // names, so a long session's cache cannot grow without bound.
        let empty = parse_object(r#"{"clips":[]}"#).expect("parse");
        let _ = transport_clips(&empty, 48_000, &mut cache).expect("empty plan");
        assert_eq!(cache.len(), 0, "the emptied plan kept the decoded take");

        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_master_values_update_reaches_a_running_transport() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","master_values":[{"name":"master_comp.thresh","value":-18.0},{"name":"master_limiter.ceiling","value":-1.0}]}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"playing\""), "{line}");
        // A value-only update moves the rack and leaves the takes alone.
        assert!(line.contains("\"clips\":0"), "{line}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_master_values_update_refuses_unknown_names_and_shapes() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        for (line, needle) in [
            (
                r#"{"cmd":"transport","action":"update","master_values":"master_comp.thresh"}"#,
                "array of master control objects",
            ),
            (
                r#"{"cmd":"transport","action":"update","master_values":[1]}"#,
                "object with",
            ),
            (
                r#"{"cmd":"transport","action":"update","master_values":[{"name":"flanger.drive","value":1}]}"#,
                "no such master insert",
            ),
            (
                r#"{"cmd":"transport","action":"update","master_values":[{"name":"master_comp.nope","value":1}]}"#,
                "no such master control",
            ),
            (
                r#"{"cmd":"transport","action":"update","master_values":[{"name":"master_comp.thresh","value":"loud"}]}"#,
                "finite number",
            ),
            (
                r#"{"cmd":"transport","action":"update"}"#,
                "needs",
            ),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
        }

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_transport_start_accepts_a_send_graph_and_an_update_can_replace_it() {
        let mut server = socket_server();
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"start","position":0,"sends":[{"from":1,"to":2},{"from":2,"to":3}]}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"playing\""), "{line}");

        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","sends":[{"from":1,"to":3}]}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");

        // The same command refuses a cycle while the transport keeps playing.
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","sends":[{"from":1,"to":2},{"from":2,"to":1}]}"#,
        ));
        assert!(line.contains("\"ok\":false"), "{line}");
        assert!(line.contains("channel 1 closes a send loop"), "{line}");
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"state\":\"playing\""), "{status}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_transport_start_refuses_a_bad_send_graph_by_name() {
        let mut server = socket_server();
        for (line, needle) in [
            (
                r#"{"cmd":"transport","action":"start","sends":[{"from":1,"to":2},{"from":2,"to":1}]}"#,
                "channel 1 closes a send loop",
            ),
            (
                r#"{"cmd":"transport","action":"start","sends":[{"from":2,"to":2}]}"#,
                "channel 2 cannot send to itself",
            ),
            (
                r#"{"cmd":"transport","action":"start","sends":[{"from":1,"to":2},{"from":1,"to":3}]}"#,
                "channel 1 already sends to channel 2",
            ),
            (
                r#"{"cmd":"transport","action":"start","sends":[{"from":0,"to":2}]}"#,
                "from must be a whole channel",
            ),
            (
                r#"{"cmd":"transport","action":"start","sends":[{"from":1,"to":33}]}"#,
                "to must be a whole channel",
            ),
            (
                r#"{"cmd":"transport","action":"start","sends":[{"from":1.5,"to":2}]}"#,
                "from must be a whole channel",
            ),
            (
                r#"{"cmd":"transport","action":"start","sends":"cords"}"#,
                "array of send objects",
            ),
            (
                r#"{"cmd":"transport","action":"start","sends":[{"from":1}]}"#,
                "to must be a whole channel",
            ),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
        }
        // No refusal opened a device or a thread.
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"state\":\"stopped\""), "{status}");
    }

    #[test]
    fn a_routing_tap_refuses_a_channel_outside_the_wire_range() {
        let mut server = socket_server();
        for (line, needle) in [
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"routing":[{"channel":0}]}}"#,
                "drums.routing[0].channel",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"routing":[{"channel":33}]}}"#,
                "drums.routing[0].channel",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"routing":[{"channel":1.5}]}}"#,
                "drums.routing[0].channel",
            ),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
        }
    }

    #[test]
    fn a_transport_start_carries_a_drum_chart() {
        let mut server = socket_server();
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"start","position":0,"drums":{"kit":"metal","length":16,"loop":1,"steps":{"kick":[70],"snare":[0,90]}}}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"playing\""), "{line}");
        assert!(line.contains("\"drums\":16"), "{line}");
        assert!(line.contains("\"drum_kit\":\"metal\""), "{line}");
        // Every existing key still rides the same line.
        assert!(line.contains("\"clips\":0"), "{line}");
        assert!(line.contains("\"master\":0"), "{line}");
        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_drum_chart_reads_its_player_and_style() {
        let chart = |json: &str| {
            let object = parse_object(json).expect("parse");
            parse_drums(get(&object, "drums"))
                .expect("parse drums")
                .expect("a chart")
        };

        // No player is the plain grid, exactly as every older song sends it.
        assert_eq!(chart(r#"{"drums":{"length":4}}"#).performance, None);
        // A player alone plays their own style.
        assert_eq!(
            chart(r#"{"drums":{"length":4,"player":"wren"}}"#).performance,
            Some(Performance::new(Player::Wren, Style::Cool))
        );
        // A style overrides how hard that player is playing.
        assert_eq!(
            chart(r#"{"drums":{"length":4,"player":"wren","style":"aggressive"}}"#).performance,
            Some(Performance::new(Player::Wren, Style::Aggressive))
        );
        // A style with no player is the house player playing that style.
        assert_eq!(
            chart(r#"{"drums":{"length":4,"style":"hard"}}"#).performance,
            Some(Performance::new(Player::Studio, Style::Hard))
        );
    }

    #[test]
    fn a_transport_refuses_a_malformed_drum_chart_by_name() {
        let mut server = socket_server();
        for (line, needle) in [
            (
                r#"{"cmd":"transport","action":"start","drums":{"kit":"acoustic"}}"#,
                "length",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":0}}"#,
                "length",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":129}}"#,
                "length",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":2.5}}"#,
                "length",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"loop":2}}"#,
                "loop",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"steps":{"kick":[0,0,0,101]}}}"#,
                "drums.steps.kick[3]",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"steps":{"snare":[0,0,0,2.5]}}}"#,
                "drums.steps.snare[3]",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"steps":{"snare":[0,0,"loud"]}}}"#,
                "drums.steps.snare[2]",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"steps":{"snare":7}}}"#,
                "drums.steps.snare",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":[1,2,3]}"#,
                "drums",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"routing":[{"pan":-3}]}}"#,
                "drums.routing[0].pan",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"player":"nobody"}}"#,
                "player",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"player":7}}"#,
                "player",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"player":"wren","style":"loud"}}"#,
                "style",
            ),
            (
                r#"{"cmd":"transport","action":"start","drums":{"length":4,"style":3}}"#,
                "style",
            ),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
            assert!(server.transport.is_none(), "{line} started a transport");
        }
    }

    #[test]
    fn synth_clips_parse_a_clip_field_for_field() {
        let object = parse_object(
            r#"{"synth_clips":{"clips":[{"patch":{},"notes":[{"n":60,"t":0.0,"d":1.0,"v":0.8}],"start":1.5,"beats":16.0,"loop":1,"channel":3,"gain":0.5,"pan":-0.25,"inserts":["reverb"]}]}}"#,
        )
        .expect("parse");
        let clips = match parse_synth_clips(get(&object, "synth_clips")).expect("parse clips") {
            SynthClipsField::Replace(clips) => clips,
            _ => panic!("a clips array should be a replacement plan"),
        };
        assert_eq!(clips.len(), 1);
        let clip = &clips[0];
        assert_eq!(clip.notes.len(), 1);
        assert_eq!(clip.notes[0].note, 60);
        assert_eq!(clip.start, 1.5);
        assert_eq!(clip.beats, 16.0);
        assert!(clip.looped);
        assert_eq!(clip.channel, Some(3));
        assert_eq!(clip.gain, 0.5);
        assert_eq!(clip.pan, -0.25);
        assert_eq!(clip.inserts, vec![InsertKind::Reverb]);

        // An object with no clips array is a marker, not a replacement.
        let marker = parse_object(r#"{"synth_clips":{}}"#).expect("parse");
        assert!(matches!(
            parse_synth_clips(get(&marker, "synth_clips")).expect("parse marker"),
            SynthClipsField::Touch
        ));
        // An absent field leaves the running plan alone.
        let empty = parse_object(r#"{}"#).expect("parse");
        assert!(matches!(
            parse_synth_clips(get(&empty, "synth_clips")).expect("parse absent"),
            SynthClipsField::Absent
        ));
    }

    #[test]
    fn a_transport_refuses_a_malformed_synth_clip_by_name() {
        let mut server = socket_server();
        for (line, needle) in [
            (
                r#"{"cmd":"transport","action":"start","synth_clips":[1]}"#,
                "synth_clips",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[7]}}"#,
                "synth_clips.clips[0]",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"notes":[],"start":0,"beats":4}]}}"#,
                "synth_clips.clips[0].patch",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"start":0,"beats":4}]}}"#,
                "synth_clips.clips[0].notes",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[{"n":128,"t":0,"d":1,"v":0.5}],"start":0,"beats":4}]}}"#,
                "synth_clips.clips[0].notes[0].n",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[{"n":60,"t":-1,"d":1,"v":0.5}],"start":0,"beats":4}]}}"#,
                "synth_clips.clips[0].notes[0].t",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[{"n":60,"t":0,"d":0,"v":0.5}],"start":0,"beats":4}]}}"#,
                "synth_clips.clips[0].notes[0].d",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[{"n":60,"t":0,"d":1,"v":2}],"start":0,"beats":4}]}}"#,
                "synth_clips.clips[0].notes[0].v",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[],"start":-1,"beats":4}]}}"#,
                "synth_clips.clips[0].start",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[],"start":0,"beats":0}]}}"#,
                "synth_clips.clips[0].beats",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[],"start":0,"beats":4,"loop":2}]}}"#,
                "synth_clips.clips[0].loop",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[],"start":0,"beats":4,"channel":0}]}}"#,
                "synth_clips.clips[0].channel",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[],"start":0,"beats":4,"gain":2}]}}"#,
                "synth_clips.clips[0].gain",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[],"start":0,"beats":4,"pan":-2}]}}"#,
                "synth_clips.clips[0].pan",
            ),
            (
                r#"{"cmd":"transport","action":"start","synth_clips":{"clips":[{"patch":{},"notes":[],"start":0,"beats":4,"inserts":["nope"]}]}}"#,
                "synth_clips.clips[0].inserts[0]",
            ),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
            assert!(server.transport.is_none(), "{line} started a transport");
        }
    }

    #[test]
    fn a_transport_start_carries_scheduled_synth_clips() {
        let mut server = socket_server();
        let clip = |beat: f64| {
            format!(
                r#"{{"patch":{{}},"notes":[{{"n":60,"t":{beat},"d":0.25,"v":0.8}}],"start":0.0,"beats":1.0,"loop":1,"channel":1}}"#
            )
        };
        let line = format!(
            r#"{{"cmd":"transport","action":"start","position":0,"synth_clips":{{"clips":[{},{}]}}}}"#,
            clip(0.0),
            clip(0.5)
        );
        let started = reply(server.handle(&line));
        assert!(started.contains("\"ok\":true"), "{started}");
        assert!(started.contains("\"synth_clips\":2"), "{started}");

        // A tempo-only `start` (no clips array) is accepted and leaves the
        // running plan alone. A `start` with a replacement counts the new set.
        let marker = reply(server.handle(
            r#"{"cmd":"transport","action":"start","position":0,"bpm":140,"synth_clips":{}}"#,
        ));
        assert!(marker.contains("\"ok\":true"), "{marker}");
        assert!(marker.contains("\"synth_clips\":2"), "{marker}");

        let update = reply(server.handle(
            r#"{"cmd":"transport","action":"update","synth_clips":{"clips":[{"patch":{},"notes":[],"start":0,"beats":2}]}}"#,
        ));
        assert!(update.contains("\"ok\":true"), "{update}");
        assert!(update.contains("\"synth_clips\":1"), "{update}");

        // An empty plan is a real update that removes every scheduled clip.
        let removed = reply(server.handle(
            r#"{"cmd":"transport","action":"update","synth_clips":{"clips":[]}}"#,
        ));
        assert!(removed.contains("\"ok\":true"), "{removed}");
        assert!(removed.contains("\"synth_clips\":0"), "{removed}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_synth_clip_plan_alone_is_a_valid_update() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"ok\":true"), "{started}");
        assert!(started.contains("\"synth_clips\":0"), "{started}");

        let touched = reply(server.handle(
            r#"{"cmd":"transport","action":"update","synth_clips":{}}"#,
        ));
        assert!(touched.contains("\"ok\":true"), "{touched}");

        // An update with no field at all is still refused, and the message names
        // the scheduled-clip field.
        let empty = reply(server.handle(r#"{"cmd":"transport","action":"update"}"#));
        assert!(empty.contains("\"ok\":false"), "{empty}");
        assert!(empty.contains("synth_clips"), "{empty}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_drum_only_update_reaches_a_running_transport() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"drums\":0"), "{started}");
        assert!(started.contains("\"drum_kit\":\"off\""), "{started}");

        // A `start` on the playing transport may carry a chart: it is applied
        // as a plan, never refused and never a device reopen.
        let carried = reply(server.handle(
            r#"{"cmd":"transport","action":"start","position":0,"drums":{"length":4,"steps":{"kick":[100]}}}"#,
        ));
        assert!(carried.contains("\"ok\":true"), "{carried}");
        assert!(carried.contains("\"drums\":4"), "{carried}");
        assert!(carried.contains("\"drum_kit\":\"acoustic\""), "{carried}");

        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","drums":{"kit":"techno","length":8,"steps":{"kick":[80]}}}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"playing\""), "{line}");
        assert!(line.contains("\"drums\":8"), "{line}");
        assert!(line.contains("\"drum_kit\":\"techno\""), "{line}");

        // An update with no field at all is still refused.
        let empty = reply(server.handle(r#"{"cmd":"transport","action":"update"}"#));
        assert!(empty.contains("\"ok\":false"), "{empty}");
        assert!(empty.contains("drums"), "{empty}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_drum_routing_plan_parses_and_reports_the_strip_count() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"apps\":0"), "{started}");

        // A playing `start` carries the chart, routing included, as a plan.
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"start","position":0,"drums":{"length":4,"steps":{"kick":[100]},"routing":[{"gain":0.8,"pan":-0.5,"inserts":["fuzz"]}]}}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"drums\":4"), "{line}");
        assert!(line.contains("\"apps\":1"), "{line}");

        // A chart update replaces the routing list, so the count follows it.
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","drums":{"length":4,"routing":[{"gain":1},{"gain":0.5,"pan":1,"inserts":["reverb","compressor"]}]}}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"apps\":2"), "{line}");

        // A chart with no routing is unpatched again.
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"update","drums":{"length":4}}"#,
        ));
        assert!(line.contains("\"apps\":0"), "{line}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_synth_routing_action_parses_and_reports_the_strip_count() {
        let mut server = socket_server();
        // No transport: the routing has no render thread to reach.
        let refused = reply(server.handle(
            r#"{"cmd":"synth","action":"routing","routing":[{"gain":0.5}]}"#,
        ));
        assert!(refused.contains("\"ok\":false"), "{refused}");
        assert!(refused.contains("not playing"), "{refused}");
        assert!(server.transport.is_none(), "a routing action started a transport");

        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"ok\":true"), "{started}");

        let line = reply(server.handle(
            r#"{"cmd":"synth","action":"routing","routing":[{"gain":1,"pan":1,"inserts":["delay"]}]}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"playing\""), "{line}");
        assert!(line.contains("\"apps\":1"), "{line}");

        // `null` is the empty list: the synth is unpatched again.
        let line = reply(server.handle(
            r#"{"cmd":"synth","action":"routing","routing":null}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"apps\":0"), "{line}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn an_app_routing_refuses_each_bad_shape_by_path() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        let too_many = format!(
            r#"{{"cmd":"synth","action":"routing","routing":[{}]}}"#,
            vec!["{}"; MAX_APP_ROUTES + 1].join(",")
        );
        let mut cases: Vec<(String, &str)> = vec![
            (
                r#"{"cmd":"synth","action":"routing","routing":"left"}"#.to_string(),
                "synth routing must be an array",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[1]}"#.to_string(),
                "synth routing[0] must be an object",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"gain":1.5}]}"#.to_string(),
                "synth routing[0].gain",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"gain":-0.1}]}"#.to_string(),
                "synth routing[0].gain",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"gain":"loud"}]}"#.to_string(),
                "synth routing[0].gain",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"pan":2}]}"#.to_string(),
                "synth routing[0].pan",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"pan":-2}]}"#.to_string(),
                "synth routing[0].pan",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"inserts":["nope"]}]}"#.to_string(),
                "synth routing[0].inserts[0]",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"inserts":["fuzz","nope"]}]}"#.to_string(),
                "synth routing[0].inserts[1]",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"inserts":[3]}]}"#.to_string(),
                "synth routing[0].inserts[0]",
            ),
            (
                r#"{"cmd":"synth","action":"routing","routing":[{"inserts":"fuzz"}]}"#.to_string(),
                "synth routing[0].inserts",
            ),
            (
                r#"{"cmd":"transport","action":"update","drums":{"length":4,"routing":[{"gain":1},{"gain":2}]}}"#.to_string(),
                "drums.routing[1].gain",
            ),
            (
                r#"{"cmd":"transport","action":"update","drums":{"length":4,"routing":[{"inserts":["nope","fuzz"]}]}}"#.to_string(),
                "drums.routing[0].inserts[0]",
            ),
            (too_many, "at most 16"),
        ];
        for (line, needle) in cases.drain(..) {
            let answer = reply(server.handle(&line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
        }

        // Every refusal left the transport playing.
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"state\":\"playing\""), "{status}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_synth_patch_plan_sets_the_status_voices() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"synth\":0"), "{started}");

        // A partial patch is enough: an absent field keeps the crate default.
        let line = reply(server.handle(
            r#"{"cmd":"synth","action":"patch","patch":{"engine":"subtractive","wave":"sine","voices":8}}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"playing\""), "{line}");
        assert!(line.contains("\"synth\":8"), "the status did not carry the voice cap: {line}");
        // Every existing key stays on the line beside the new one.
        assert!(line.contains("\"drums\":0"), "{line}");
        assert!(line.contains("\"drum_kit\":\"off\""), "{line}");
        assert!(line.contains("\"clips\":0"), "{line}");
        assert!(line.contains("\"master\":0"), "{line}");

        // A second patch retunes the loaded synth and updates the cap.
        let line = reply(server.handle(
            r#"{"cmd":"synth","action":"patch","patch":{"filter":{"type":"bandpass","cutoff":900}}}"#,
        ));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"playing\""), "{line}");
        // The absent `voices` takes the default, not the previous patch's 8.
        assert!(line.contains("\"synth\":32"), "{line}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_synth_note_and_all_off_reach_a_running_transport() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        for line in [
            r#"{"cmd":"synth","action":"note","on":1,"note":60,"velocity":0.8}"#,
            r#"{"cmd":"synth","action":"note","on":0,"note":60}"#,
            r#"{"cmd":"synth","action":"note","on":true,"note":67,"velocity":1}"#,
            r#"{"cmd":"synth","action":"all_off"}"#,
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":true"), "{line}: {answer}");
            assert!(answer.contains("\"state\":\"playing\""), "{line}: {answer}");
        }

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_synth_patch_refuses_a_malformed_field_by_name() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        for (line, needle) in [
            (
                r#"{"cmd":"synth","action":"patch","patch":"loud"}"#,
                "patch",
            ),
            (r#"{"cmd":"synth","action":"patch"}"#, "patch"),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"engine":"reed"}}"#,
                "patch.engine",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"wave":"noise"}}"#,
                "patch.wave",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"wave":5}}"#,
                "patch.wave",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"noise":"loud"}}"#,
                "patch.noise",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"voices":2.5}}"#,
                "patch.voices",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"voices":300}}"#,
                "patch.voices",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"osc":[]}}"#,
                "patch.osc",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"osc":"sine"}}"#,
                "patch.osc",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"osc":[1]}}"#,
                "patch.osc[0]",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"osc":[{"octave":1.5}]}}"#,
                "patch.osc[0].octave",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"filter":"soft"}}"#,
                "patch.filter",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"filter":{"type":"highpass"}}}"#,
                "patch.filter.type",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"filter":{"cutoff":"high"}}}"#,
                "patch.filter.cutoff",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"amp":{"a":"slow"}}}"#,
                "patch.amp.a",
            ),
            (
                r#"{"cmd":"synth","action":"patch","patch":{"lfo":{"rate":"fast"}}}"#,
                "patch.lfo.rate",
            ),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
        }
        // A refused patch never stopped the transport.
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"state\":\"playing\""), "{status}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_synth_note_refuses_bad_shapes_by_name() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        for (line, needle) in [
            (
                r#"{"cmd":"synth","action":"note","on":2,"note":60}"#,
                "on",
            ),
            (
                r#"{"cmd":"synth","action":"note","on":"yes","note":60}"#,
                "on",
            ),
            (
                r#"{"cmd":"synth","action":"note","on":1,"note":128}"#,
                "note",
            ),
            (
                r#"{"cmd":"synth","action":"note","on":1,"note":-1}"#,
                "note",
            ),
            (
                r#"{"cmd":"synth","action":"note","on":1,"note":60.5}"#,
                "note",
            ),
            (
                r#"{"cmd":"synth","action":"note","on":1}"#,
                "note",
            ),
            (
                r#"{"cmd":"synth","action":"note","on":1,"note":60,"velocity":"loud"}"#,
                "velocity",
            ),
            (
                r#"{"cmd":"synth","action":"note","on":1,"note":60,"velocity":1.5}"#,
                "velocity",
            ),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
        }

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_drum_hit_refuses_bad_shapes_by_name() {
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        // A hit parses even without a chart: the render thread drops it, which
        // is documented, but the wire shape is valid.
        let hit = reply(server.handle(
            r#"{"cmd":"drums","action":"hit","voice":"kick","velocity":70}"#,
        ));
        assert!(hit.contains("\"ok\":true"), "{hit}");

        for (line, needle) in [
            (
                r#"{"cmd":"drums","action":"hit","voice":"crash","velocity":70}"#,
                "no such drum voice: crash",
            ),
            (
                r#"{"cmd":"drums","action":"hit","voice":3,"velocity":70}"#,
                "voice",
            ),
            (
                r#"{"cmd":"drums","action":"hit","velocity":70}"#,
                "voice",
            ),
            (
                r#"{"cmd":"drums","action":"hit","voice":"kick","velocity":0}"#,
                "velocity",
            ),
            (
                r#"{"cmd":"drums","action":"hit","voice":"kick","velocity":101}"#,
                "velocity",
            ),
            (
                r#"{"cmd":"drums","action":"hit","voice":"kick","velocity":70.5}"#,
                "velocity",
            ),
            (
                r#"{"cmd":"drums","action":"hit","voice":"kick"}"#,
                "velocity",
            ),
            (
                r#"{"cmd":"drums","action":"roll","voice":"kick","velocity":70}"#,
                "no such drums action: roll",
            ),
        ] {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains(needle), "{line}: {answer}");
        }

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn the_synth_and_drum_commands_refuse_a_stopped_transport() {
        let mut server = socket_server();
        let commands = [
            r#"{"cmd":"synth","action":"patch","patch":{"voices":8}}"#,
            r#"{"cmd":"synth","action":"note","on":1,"note":60}"#,
            r#"{"cmd":"synth","action":"all_off"}"#,
            r#"{"cmd":"synth","action":"routing","routing":[]}"#,
            r#"{"cmd":"drums","action":"hit","voice":"kick","velocity":70}"#,
        ];
        // Never started: no transport exists, so each command is one sentence.
        for line in commands {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains("not playing"), "{line}: {answer}");
            assert!(server.transport.is_none(), "{line} created a transport");
        }

        // Stopped: the session still exists, but no render thread reads it.
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");
        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
        for line in commands {
            let answer = reply(server.handle(line));
            assert!(answer.contains("\"ok\":false"), "{line}: {answer}");
            assert!(answer.contains("not playing"), "{line}: {answer}");
        }
    }

    #[test]
    fn a_master_toggle_update_changes_the_armed_rack() {
        // Toggling a master insert is the rack set: the update carries the new
        // list and the engine swaps it at a block edge. Adding then removing a
        // slot is visible in the session's own count.
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"master\":0"), "{started}");

        let added = reply(server.handle(
            r#"{"cmd":"transport","action":"update","clips":[],"master":["master_limiter"],"master_values":[{"name":"master_limiter.ceiling","value":-1.0}]}"#,
        ));
        assert!(added.contains("\"ok\":true"), "{added}");
        assert!(added.contains("\"master\":1"), "{added}");

        let removed = reply(server.handle(
            r#"{"cmd":"transport","action":"update","clips":[],"master":[]}"#,
        ));
        assert!(removed.contains("\"ok\":true"), "{removed}");
        assert!(removed.contains("\"master\":0"), "{removed}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_seek_moves_a_resting_transport() {
        let mut server = socket_server();
        server.transport = Some(playing_transport(0));
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"seek","position":12.5}"#,
        ));
        assert!(
            line.contains("\"transport\":{\"state\":\"playing\""),
            "{line}"
        );
        assert!(line.contains("\"position\":12.500000"), "{line}");
    }

    #[test]
    fn a_transport_status_carries_its_device_shape() {
        // The page maps the transport position onto its own audio clock with
        // these, so a browser voice can be scheduled on the engine's grid.
        let mut server = socket_server();
        server.transport = Some(playing_transport(0));
        let line = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(line.contains("\"buffer\":1024"), "{line}");
        assert!(line.contains("\"period\":256"), "{line}");
        assert!(line.contains("\"rate\":48000"), "{line}");
    }

    #[test]
    fn a_transport_refuses_a_running_playback() {
        let mut server = socket_server();
        server.playback = Some(PlaySession {
            status: Arc::new(Mutex::new(PlayStatus {
                state: State::Playing,
                files: 1,
                frames: 0,
                error: String::new(),
            })),
            stop: Arc::new(AtomicBool::new(false)),
            handle: None,
            strips: Vec::new(),
            params: None,
            align: None,
            live: false,
        });
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"start","position":0}"#,
        ));
        assert!(line.contains("playback is running"), "{line}");
        assert!(server.transport.is_none());
    }

    #[test]
    fn record_monitor_track_needs_the_live_input_and_a_real_track() {
        // The live monitor may carry one chosen track instead of every terminal
        // track. Naming one without arming the live input, or naming a track the
        // take does not carry, is refused before any device or file is touched.
        let mut server = socket_server();
        let line = reply(server.handle(
            r#"{"cmd":"record","out":"/tmp/x.wav","tracks":[{"input":0},{"input":0}],"monitor_track":0}"#,
        ));
        assert!(line.contains(r#"needs \"monitor_input\": true"#), "{line}");

        let line = reply(server.handle(
            r#"{"cmd":"record","out":"/tmp/x.wav","tracks":[{"input":0}],"monitor_input":true,"monitor_track":1}"#,
        ));
        assert!(line.contains("outside the take's 1 tracks"), "{line}");
    }

    #[test]
    fn a_transport_starts_beside_a_recording_take_and_keeps_its_output() {
        // The take owns only the capture stream, so the transport starts beside
        // it. One stop joins both.
        let mut server = socket_server();
        server.current = Some(running(take_status("tone"), Arc::new(ParamQueue::new())));
        let line = reply(server.handle(
            r#"{"cmd":"transport","action":"start","position":0}"#,
        ));
        assert!(line.contains("\"state\":\"playing\""), "{line}");
        assert!(server.transport.is_some());
        let stopped = reply(server.handle(r#"{"cmd":"stop"}"#));
        assert!(
            stopped.contains("\"transport\":{\"state\":\"stopped\""),
            "{stopped}"
        );

        // A record that asks for monitor files or its own click still needs an
        // output of its own, so those are refused while the transport plays.
        // The live input is the exception; it rides the transport's bus and is
        // covered by the tests below. A playback and the patchbay keep their
        // refusals; a listen is no longer one of them, because it now rides the
        // transport's output too.
        let mut server = socket_server();
        server.transport = Some(playing_transport(0));
        for request in [
            r#"{"cmd":"record","out":"/tmp/transport-take.wav","monitor":["/tmp/a.wav"]}"#,
            r#"{"cmd":"record","out":"/tmp/transport-take.wav","click":{"bpm":120,"beats_per_bar":4}}"#,
        ] {
            let answer = reply(server.handle(request));
            assert!(answer.contains("owns the metronome"), "{request}: {answer}");
            assert!(answer.contains("monitor files"), "{request}: {answer}");
        }
        for (command, needle) in [
            (r#"{"cmd":"play","files":["/tmp/a.wav"]}"#, "before starting a playback"),
            (r#"{"cmd":"patch"}"#, "before patching"),
        ] {
            let answer = reply(server.handle(command));
            assert!(answer.contains("transport is playing"), "{command}: {answer}");
            assert!(answer.contains(needle), "{command}: {answer}");
        }
    }

    #[test]
    fn a_live_take_monitors_beside_the_playing_transport() {
        // The transport owns the output; the take's live ring joins its master
        // chain instead of opening a second device. This is the one monitor a
        // take may carry while the transport plays.
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        let out = temp_take("transport-live");
        let recorded = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":30,"monitor_input":true,"monitor_gain":0.5}}"#
        )));
        assert!(recorded.contains("\"ok\":true"), "{recorded}");
        assert!(recorded.contains("\"state\":\"recording\""), "{recorded}");
        assert!(recorded.contains("\"monitor_input\":true"), "{recorded}");

        // The transport reports the attachment and the trim the take will use.
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"monitor_input\":true"), "{status}");
        assert!(status.contains("\"monitor_gain\":0.5"), "{status}");

        // `param` moves the same `Arc` the take reports, so the transport sees
        // the new trim at the next block without a second knob to update.
        let param = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":0.75}"#,
        ));
        assert!(param.contains("\"gain\":0.75"), "{param}");
        assert!(param.contains("\"monitor_input\":true"), "{param}");
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"monitor_gain\":0.75"), "{status}");

        // Stopping the take detaches the monitor and leaves the transport
        // playing: one output, one take, one attachment.
        let stopped = reply(server.handle(r#"{"cmd":"record","action":"stop"}"#));
        assert!(stopped.contains("\"state\":\"done\""), "{stopped}");
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"state\":\"playing\""), "{status}");
        assert!(status.contains("\"monitor_input\":false"), "{status}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_param_arms_a_live_input_on_a_take_beside_the_transport() {
        // Pressing Monitor mid-take posts a positive gain. A take armed with
        // `monitor_input` off parked its ring, so the trim must attach that ring
        // to the transport instead of opening a playback the transport forbids.
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        let out = temp_take("transport-armed-later");
        let recorded = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":30,"monitor_input":false}}"#
        )));
        assert!(recorded.contains("\"ok\":true"), "{recorded}");
        assert!(recorded.contains("\"monitor_input\":false"), "{recorded}");

        let armed = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":1}"#,
        ));
        assert!(armed.contains("\"ok\":true"), "{armed}");
        assert!(armed.contains("\"gain\":1"), "{armed}");
        assert!(armed.contains("\"monitor_input\":true"), "{armed}");
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"state\":\"playing\""), "{status}");
        assert!(status.contains("\"monitor_input\":true"), "{status}");
        assert!(status.contains("\"monitor_gain\":1"), "{status}");

        // Zero is a mute, not a detach: the take is still monitoring.
        let muted = reply(server.handle(
            r#"{"cmd":"param","target":"input","name":"gain","value":0}"#,
        ));
        assert!(muted.contains("\"gain\":0"), "{muted}");
        assert!(muted.contains("\"monitor_input\":true"), "{muted}");
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"monitor_gain\":0"), "{status}");

        // Stopping the take detaches it; the transport keeps playing.
        let stopped = reply(server.handle(r#"{"cmd":"record","action":"stop"}"#));
        assert!(stopped.contains("\"state\":\"done\""), "{stopped}");
        let status = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(status.contains("\"state\":\"playing\""), "{status}");
        assert!(status.contains("\"monitor_input\":false"), "{status}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_listen_rides_a_playing_transport_and_stops_alone() {
        // The transport owns the output. A listen beside it builds its capture
        // and strip on the listen worker and attaches the finished stereo to
        // the transport's render through the same live slot a take uses, so no
        // second output opens. A scoped stop detaches only the listen.
        let mut server = socket_server();
        let started = reply(server.handle(r#"{"cmd":"transport","action":"start","position":0}"#));
        assert!(started.contains("\"state\":\"playing\""), "{started}");

        let listening = reply(server.handle(r#"{"cmd":"listen","channel":0}"#));
        assert!(listening.contains("\"ok\":true"), "{listening}");
        assert!(listening.contains("\"state\":\"listening\""), "{listening}");
        assert_eq!(
            server
                .transport
                .as_ref()
                .expect("the transport session")
                .live_owner,
            Some(LiveInputOwner::Listen),
            "the listen owns the transport's live slot"
        );

        // The listen is the reported role while it runs, and the transport is
        // still playing underneath it.
        let status = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(status.contains("\"state\":\"listening\""), "{status}");
        let transport = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(transport.contains("\"state\":\"playing\""), "{transport}");

        // A scoped stop ends the listen and leaves the transport playing.
        let stopped = reply(server.handle(r#"{"cmd":"listen","action":"stop"}"#));
        assert!(stopped.contains("\"ok\":true"), "{stopped}");
        assert!(stopped.contains("\"state\":\"done\""), "{stopped}");
        let transport = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(transport.contains("\"state\":\"playing\""), "{transport}");
        assert_eq!(
            server
                .transport
                .as_ref()
                .expect("the transport session")
                .live_owner,
            None,
            "the listen left the transport's live slot empty"
        );

        // A second scoped stop is an answer, not a second stop, and the
        // transport is untouched either way.
        let again = reply(server.handle(r#"{"cmd":"listen","action":"stop"}"#));
        assert!(again.contains("\"ok\":false"), "{again}");
        assert!(again.contains("no listen is running"), "{again}");
        let transport = reply(server.handle(r#"{"cmd":"transport","action":"status"}"#));
        assert!(transport.contains("\"state\":\"playing\""), "{transport}");

        let _ = server.handle(r#"{"cmd":"transport","action":"stop"}"#);
    }

    #[test]
    fn a_scoped_listen_stop_leaves_a_recording_take_and_the_transport_alone() {
        // The take's live input rides the transport; a listen stop must not
        // stop the take, the transport or the take's live slot.
        let mut server = socket_server();
        server.transport = Some(playing_transport(0));
        let mut take = take_status("tone");
        take.monitor_input = true;
        server.current = Some(running(take, Arc::new(ParamQueue::new())));
        {
            let session = server.transport.as_mut().expect("the transport session");
            session.live_owner = Some(LiveInputOwner::Take);
            session.monitor_input = true;
            session.monitor_gain = Some(Arc::new(AtomicU32::new(1f32.to_bits())));
        }

        let refused = reply(server.handle(r#"{"cmd":"listen","action":"stop"}"#));
        assert!(refused.contains("\"ok\":false"), "{refused}");
        assert!(refused.contains("no listen is running"), "{refused}");

        let status = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(status.contains("\"state\":\"recording\""), "{status}");
        assert!(
            status.contains("\"transport\":{\"state\":\"playing\""),
            "{status}"
        );
        assert_eq!(
            server
                .transport
                .as_ref()
                .expect("the transport session")
                .live_owner,
            Some(LiveInputOwner::Take),
            "the take kept its live slot"
        );
    }

    #[test]
    fn a_take_records_a_channel_send_into_the_destination_file() {
        // Channel 2's input is Channel 1's output: track 2 names no device
        // channel, and the take still writes one body per track. The null
        // backend gives silence, so this proves the graph, the files and the
        // report, not the samples; the mixer's own tests prove the block.
        let mut server = socket_server();
        server.config.channels = 2;
        let out = temp_take("send");
        let request = format!(
            r#"{{"cmd":"record","out":"{out}","seconds":0.05,"tracks":[{{"input":0}},{{"from":0}}]}}"#
        );
        let line = reply(server.handle(&request));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(
            line.contains("\"from\":0"),
            "the report does not name the send: {line}"
        );
        assert!(
            !line.contains("\"input\":1"),
            "a sent track reported a device input: {line}"
        );

        let produced = |line: &str| -> bool {
            match parse_object(line) {
                Ok(object) => {
                    matches!(get(&object, "frames"), Some(Value::Num(frames)) if *frames > 0.0)
                }
                Err(_) => false,
            }
        };
        let mut status = reply(server.handle(r#"{"cmd":"status"}"#));
        let deadline = Instant::now() + Duration::from_secs(2);
        while !produced(&status) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
            status = reply(server.handle(r#"{"cmd":"status"}"#));
        }
        assert!(
            status.contains("\"from\":0"),
            "the status lost the send: {status}"
        );

        let stopped = reply(server.handle(r#"{"cmd":"stop"}"#));
        assert!(stopped.contains("\"state\":\"done\""), "{stopped}");
        for track in 1..=2 {
            let path = out.replace(".wav", &format!("-ch{track}.wav"));
            let written = std::fs::metadata(&path)
                .map(|meta| meta.len() > 44)
                .unwrap_or(false);
            assert!(written, "track {track} wrote no WAV body: {path}");
            let _ = std::fs::remove_file(path);
        }
        let _ = std::fs::remove_file(&out);
    }

    #[cfg(feature = "alsa")]
    #[test]
    fn a_listen_sink_counts_the_frames_its_unit_processed() {
        use jawn_audio::listen::ListenSink;
        let plan = ListenPlan {
            channel: 0,
            channels: vec![0],
            gain: 1.0,
            pan: 0.0,
            inserts: Vec::new(),
            master: Vec::new(),
        };
        let mut unit = ListenUnit::new(&plan, None);
        let status = Arc::new(Mutex::new(ListenStatus {
            state: State::Listening,
            channel: 0,
            channels: vec![0],
            frames: 0,
            gain: 1.0,
            pan: 0.0,
            inserts: String::new(),
            error: String::new(),
        }));
        let mut sink = SocketListenSink {
            sink: &mut unit,
            status: &status,
            frames: 0,
        };
        sink.prepared(48_000, 4, 1).expect("prepare");
        let mut output = [0i16; 8];
        sink.block(&[1000i16; 4], &mut output).expect("block");
        assert_eq!(sink.frames, 4, "the sink did not count the block");
        assert_eq!(output.len() / 2, 4);
        assert_eq!(status.lock().unwrap().frames, 4);
    }

    #[test]
    fn a_record_stop_is_refused_when_no_take_is_recording() {
        let mut server = socket_server();
        let answer = reply(server.handle(r#"{"cmd":"record","action":"stop"}"#));
        assert!(answer.contains("\"ok\":false"), "{answer}");
        assert!(answer.contains("no take is recording"), "{answer}");
    }

    #[test]
    fn four_tracks_may_share_one_input_on_a_two_input_engine() {
        // The P2 gate records four tracks through the UM2's two inputs. A take
        // may carry more tracks than the device has channels as long as every
        // track names a real input; several tracks may share one source.
        let mut server = socket_server();
        server.config.channels = 2;
        let out = temp_take("shared-input");
        let request = format!(
            r#"{{"cmd":"record","out":"{out}","seconds":0.05,"tracks":[{{"input":0}},{{"input":0}},{{"input":0}},{{"input":0}}]}}"#
        );
        let line = reply(server.handle(&request));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"recording\""), "{line}");
        assert!(
            line.contains("\"tracks\":["),
            "a four-track take did not report its tracks: {line}"
        );

        // Every track names input 0, and the status carries all four. Wait for
        // the take's first block so the four files have a body, not only a
        // header.
        let produced = |line: &str| -> bool {
            match parse_object(line) {
                Ok(object) => {
                    matches!(get(&object, "frames"), Some(Value::Num(frames)) if *frames > 0.0)
                }
                Err(_) => false,
            }
        };
        let mut status = reply(server.handle(r#"{"cmd":"status"}"#));
        let deadline = Instant::now() + Duration::from_secs(2);
        while !produced(&status) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
            status = reply(server.handle(r#"{"cmd":"status"}"#));
        }
        assert_eq!(
            status.matches("\"input\":0").count(),
            4,
            "status did not report four tracks on input 0: {status}"
        );
        assert!(
            produced(&status),
            "the four-track take produced no frames: {status}"
        );

        // One WAV per track, all written from the same input.
        let stopped = reply(server.handle(r#"{"cmd":"stop"}"#));
        assert!(stopped.contains("\"state\":\"done\""), "{stopped}");
        for track in 1..=4 {
            let path = out.replace(".wav", &format!("-ch{track}.wav"));
            let written = std::fs::metadata(&path)
                .map(|meta| meta.len() > 44)
                .unwrap_or(false);
            assert!(written, "track {track} wrote no WAV body: {path}");
            let _ = std::fs::remove_file(path);
        }
        let _ = std::fs::remove_file(&out);
    }

    /// The P4 gate's patch: one input into the `house` bus and on to the
    /// interface. The null backend feeds it silence, which is enough to prove
    /// the take's state, length and file; the mix itself is proven in
    /// `patchbay`'s own tap tests.
    const HOUSE_PATCH: &str = r#"{"sources":[{"id":"in0","kind":"input","channel":0}],"buses":[{"id":"house"}],"sinks":[{"id":"out","kind":"interface"}],"routes":[{"from":"in0","to":"house","gain":1,"pan":0},{"from":"house","to":"out","gain":1,"pan":0}]}"#;

    fn start_house_patch(server: &mut Server) -> String {
        let request = format!("{{\"cmd\":\"patch\",\"plan\":{HOUSE_PATCH}}}");
        reply(server.handle(&request))
    }

    /// A patch whose source carries its own trim and insert, so the
    /// `patch_source` address has a chain to move.
    const SOURCE_EFFECTS_PATCH: &str = r#"{"sources":[{"id":"in0","kind":"input","channel":0,"gain":1,"inserts":["distortion"]}],"buses":[{"id":"house"}],"sinks":[{"id":"out","kind":"interface"}],"routes":[{"from":"in0","to":"house","gain":1,"pan":0},{"from":"house","to":"out","gain":1,"pan":0}]}"#;

    #[test]
    fn patch_source_params_move_an_armed_chain_and_refuse_a_stranger() {
        let mut server = socket_server();
        let started = reply(server.handle(&format!(
            "{{\"cmd\":\"patch\",\"plan\":{SOURCE_EFFECTS_PATCH}}}"
        )));
        assert!(started.contains("\"state\":\"patching\""), "{started}");
        assert!(
            started.contains("\"source_effects\":[{\"id\":\"in0\",\"gain\":1,\"mute\":false,\"inserts\":[\"distortion\"]}]"),
            "the patch reports the source's chain: {started}"
        );

        let drive = reply(server.handle(
            r#"{"cmd":"param","target":"patch_source","source":0,"name":"distortion.drive","value":100}"#,
        ));
        assert!(drive.contains("\"ok\":true"), "{drive}");
        assert!(drive.contains("\"target\":\"patch_source\""), "{drive}");
        assert!(drive.contains("\"source\":0"), "{drive}");

        let gain = reply(server.handle(
            r#"{"cmd":"param","target":"patch_source","source":0,"name":"gain","value":0.5}"#,
        ));
        assert!(gain.contains("\"ok\":true"), "{gain}");
        let status = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(
            status.contains("\"source_effects\":[{\"id\":\"in0\",\"gain\":0.5,\"mute\":false,\"inserts\":[\"distortion\"]}]"),
            "status mirrors the moved trim: {status}"
        );

        // A mute is the source's own footswitch: it moves live and is mirrored
        // in `status` without touching the trim the player set.
        let mute = reply(server.handle(
            r#"{"cmd":"param","target":"patch_source","source":0,"name":"mute","value":1}"#,
        ));
        assert!(mute.contains("\"ok\":true"), "{mute}");
        let muted = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(
            muted.contains("\"source_effects\":[{\"id\":\"in0\",\"gain\":0.5,\"mute\":true,\"inserts\":[\"distortion\"]}]"),
            "status reports the mute beside the trim: {muted}"
        );

        // A name for an insert the source did not arm is a refusal, not a
        // knob the audio thread silently drops.
        let stranger = reply(server.handle(
            r#"{"cmd":"param","target":"patch_source","source":0,"name":"reverb.mix","value":50}"#,
        ));
        assert!(stranger.contains("\"ok\":false"), "{stranger}");
        assert!(stranger.contains("has no reverb insert"), "{stranger}");

        let missing = reply(server.handle(
            r#"{"cmd":"param","target":"patch_source","source":2,"name":"gain","value":1}"#,
        ));
        assert!(missing.contains("no source 2"), "{missing}");

        let _ = server.handle(r#"{"cmd":"unpatch"}"#);
    }

    #[test]
    fn a_master_bypass_is_a_value_the_transport_can_carry() {
        let object = parse_object(
            r#"{"master_values":[{"name":"master_limiter.bypass","value":1}]}"#,
        )
        .expect("parse");
        let values = parse_master_values(get(&object, "master_values"))
            .expect("valid")
            .expect("a list");
        assert_eq!(values, vec![("master_limiter.bypass".to_string(), 1.0)]);
    }

    #[test]
    fn a_multi_input_listen_arms_status_and_refuses_bad_input_sets() {
        let mut server = socket_server();
        server.config.channels = 2;

        for (request, error) in [
            (r#"{"cmd":"listen","channels":[]}"#, "at least one input"),
            (r#"{"cmd":"listen","channels":[0,0]}"#, "named twice"),
            (r#"{"cmd":"listen","channel":0,"channels":[0,1]}"#, "not both"),
            (r#"{"cmd":"listen","channels":[0,2]}"#, "outside"),
        ] {
            let refused = reply(server.handle(request));
            assert!(refused.contains("\"ok\":false"), "{request}: {refused}");
            assert!(refused.contains(error), "{request}: {refused}");
        }

        let started = reply(server.handle(r#"{"cmd":"listen","channels":[0,1]}"#));
        assert!(started.contains("\"ok\":true"), "{started}");
        assert!(started.contains("\"channels\":[0,1]"), "{started}");

        let status = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(status.contains("\"channels\":[0,1]"), "{status}");

        let stopped = reply(server.handle(r#"{"cmd":"stop"}"#));
        assert!(stopped.contains("\"channels\":[0,1]"), "{stopped}");
    }

    #[test]
    fn a_listen_arms_the_master_rack_and_refuses_it_with_several_inputs() {
        let mut server = socket_server();

        // One input: the rack rides the same values the transport uses, so a
        // switched-off slot is a bypass rather than an absent insert.
        let started = reply(server.handle(
            r#"{"cmd":"listen","channel":0,"master":["master_limiter"],"master_values":[{"name":"master_limiter.bypass","value":1}]}"#,
        ));
        assert!(started.contains("\"ok\":true"), "{started}");
        assert!(started.contains("\"state\":\"listening\""), "{started}");
        let _ = server.handle(r#"{"cmd":"stop"}"#);

        // Several inputs sum before the rack, so it has no one bus to run on.
        server.config.channels = 2;
        let refused = reply(
            server.handle(r#"{"cmd":"listen","channels":[0,1],"master":["master_limiter"]}"#),
        );
        assert!(refused.contains("\"ok\":false"), "{refused}");
        assert!(refused.contains("one input"), "{refused}");
    }

    /// Poll until the bus take has written its first block, so the test never
    /// joins a take that has not started rather than one that is recording.
    fn wait_for_bus_frames(server: &mut Server) -> String {
        let mut status = reply(server.handle(r#"{"cmd":"status"}"#));
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            let recording = status.contains("\"state\":\"recording\"")
                && status.contains("\"bus\":\"house\"")
                && match parse_object(&status) {
                    Ok(object) => {
                        matches!(get(&object, "frames"), Some(Value::Num(frames)) if *frames > 0.0)
                    }
                    Err(_) => false,
                };
            if recording {
                break;
            }
            thread::sleep(Duration::from_millis(2));
            status = reply(server.handle(r#"{"cmd":"status"}"#));
        }
        status
    }

    #[test]
    fn a_bus_take_records_a_running_patch() {
        let mut server = socket_server();
        let started = start_house_patch(&mut server);
        assert!(started.contains("\"state\":\"patching\""), "{started}");

        let out = temp_take("bus-take");
        let line = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","bus":"house","seconds":3600}}"#
        )));
        assert!(line.contains("\"ok\":true"), "{line}");
        assert!(line.contains("\"state\":\"recording\""), "{line}");
        assert!(line.contains("\"bus\":\"house\""), "{line}");

        let status = wait_for_bus_frames(&mut server);
        assert!(status.contains("\"state\":\"recording\""), "{status}");
        assert!(status.contains("\"bus\":\"house\""), "{status}");

        let stopped = reply(server.handle(r#"{"cmd":"record","action":"stop"}"#));
        assert!(stopped.contains("\"state\":\"done\""), "{stopped}");
        assert!(stopped.contains("\"bus\":\"house\""), "{stopped}");
        let written = std::fs::metadata(&out)
            .map(|meta| meta.len() > 44)
            .unwrap_or(false);
        assert!(written, "the bus take wrote no WAV body: {out}");

        // The patch kept playing: stopping the take only detached it.
        let status = reply(server.handle(r#"{"cmd":"status"}"#));
        assert!(status.contains("\"state\":\"patching\""), "{status}");

        let _ = server.handle(r#"{"cmd":"unpatch"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_normal_take_is_still_refused_while_the_patch_runs() {
        let mut server = socket_server();
        let started = start_house_patch(&mut server);
        assert!(started.contains("\"state\":\"patching\""), "{started}");

        let out = temp_take("not-bus");
        let refused = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":1}}"#
        )));
        assert!(refused.contains("stop the patch before recording"), "{refused}");
        assert!(!std::path::Path::new(&out).exists(), "a refused take left a file");

        let _ = server.handle(r#"{"cmd":"unpatch"}"#);
    }

    #[test]
    fn a_patch_is_still_refused_while_a_normal_take_records() {
        let mut server = socket_server();
        let out = temp_take("normal-first");
        let started = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","seconds":3600}}"#
        )));
        assert!(started.contains("\"state\":\"recording\""), "{started}");

        let refused = start_house_patch(&mut server);
        assert!(refused.contains("a take is recording"), "{refused}");
        assert!(refused.contains("Stop the take before patching"), "{refused}");

        let _ = server.handle(r#"{"cmd":"stop"}"#);
        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn an_unknown_bus_is_refused_by_name() {
        let mut server = socket_server();
        let started = start_house_patch(&mut server);
        assert!(started.contains("\"state\":\"patching\""), "{started}");

        let out = temp_take("no-such-bus");
        let refused = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","bus":"booth","seconds":1}}"#
        )));
        assert!(refused.contains("the patch has no bus"), "{refused}");
        assert!(refused.contains("booth"), "{refused}");
        assert!(refused.contains("its buses are: house"), "{refused}");
        assert!(!std::path::Path::new(&out).exists(), "a refused take left a file");

        let _ = server.handle(r#"{"cmd":"unpatch"}"#);
    }

    #[test]
    fn a_bus_take_closes_its_file_when_the_patch_ends() {
        let mut server = socket_server();
        let started = start_house_patch(&mut server);
        assert!(started.contains("\"state\":\"patching\""), "{started}");

        let out = temp_take("patch-ends");
        let line = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","bus":"house","seconds":3600}}"#
        )));
        assert!(line.contains("\"state\":\"recording\""), "{line}");
        let status = wait_for_bus_frames(&mut server);
        assert!(status.contains("\"state\":\"recording\""), "{status}");

        // The patch ends under the take. The writer must notice and close the
        // WAV, not wait for a producer that is gone.
        let _ = server.handle(r#"{"cmd":"unpatch"}"#);
        let mut status = reply(server.handle(r#"{"cmd":"status"}"#));
        let deadline = Instant::now() + Duration::from_secs(3);
        while !status.contains("\"state\":\"done\"") && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(2));
            status = reply(server.handle(r#"{"cmd":"status"}"#));
        }
        assert!(status.contains("\"state\":\"done\""), "{status}");
        assert!(status.contains("\"bus\":\"house\""), "{status}");
        let written = std::fs::metadata(&out)
            .map(|meta| meta.len() > 44)
            .unwrap_or(false);
        assert!(written, "the ended patch lost the bus take's file: {out}");
        assert!(
            reply(server.handle(r#"{"cmd":"record","action":"stop"}"#))
                .contains("no take is recording"),
            "the bus take was still recording after the patch ended"
        );

        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn a_patch_is_refused_while_a_bus_take_records() {
        let mut server = socket_server();
        let started = start_house_patch(&mut server);
        assert!(started.contains("\"state\":\"patching\""), "{started}");

        let out = temp_take("bus-before-patch");
        let line = reply(server.handle(&format!(
            r#"{{"cmd":"record","out":"{out}","bus":"house","seconds":3600}}"#
        )));
        assert!(line.contains("\"state\":\"recording\""), "{line}");
        let status = wait_for_bus_frames(&mut server);
        assert!(status.contains("\"state\":\"recording\""), "{status}");

        let refused = start_house_patch(&mut server);
        assert!(refused.contains("a bus take is recording"), "{refused}");

        let _ = server.handle(r#"{"cmd":"record","action":"stop"}"#);
        let _ = server.handle(r#"{"cmd":"unpatch"}"#);
        let _ = std::fs::remove_file(&out);
    }
}
