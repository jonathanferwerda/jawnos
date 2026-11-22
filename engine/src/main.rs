//! `jawn-audio`, the engine's command line.
//!
//! The null device is still the default, so every mode runs on a machine with
//! no sound card. `--backends` says which optional backends this build carries,
//! and `--loopback` measures the patch-cable round trip when one does
//! (docs/studio-audio-roadmap.md P1). `--serve` is the control socket the
//! manager drives: one JSON object per line, one client at a time
//! (docs/studio-audio-roadmap.md P2).

mod patchbay;
mod system_capture;
mod socket;

use std::io::ErrorKind;
use std::net::{SocketAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use jawn_audio::{
    backends::{self, BackendKind, RunReport},
    decode, encode_datagram, loopback, mix_mono_into_stereo, monitor_start, peak, to_i16, Channel,
    listen::{self, ListenPlan, ListenReport, ListenStrip},
    peer::{self, Clock, ClockEstimator, ClockReport, InstantClock, ProbeSample},
    Codec, Device, DiskWriter, Header, InsertKind, Mixer, MonitorSpec, NullDevice, PlayTrack,
    Playback, Strip, HEADER_LEN,
};

/// Every track's WAV is stereo: the strip's panned output. `--channels` is the
/// take's *source* shape, the number of device channels the interface is asked
/// for, and one track reads one of them.
pub(crate) const TAKE_CHANNELS: usize = 2;
/// The largest interface and the largest take the engine accepts. One track per
/// input channel is the largest shape the strip model has.
pub(crate) const MAX_CHANNELS: usize = 32;
pub(crate) const MAX_TRACKS: usize = MAX_CHANNELS;
/// `--record` without `--seconds`: long enough to be a take, short enough to
/// not surprise someone who forgot the flag.
const RECORD_SECONDS: f64 = 5.0;

const USAGE: &str = "\
jawn-audio — the JawnOS audio engine

  jawn-audio --check                      say which backends are present
  jawn-audio --backends [--json]          report device-backend availability
  jawn-audio --selftest                   run a block through the graph and protocol
  jawn-audio --run [options]              run a device for a while and report
  jawn-audio --loopback [options]         measure the round trip through a patch cable
  jawn-audio --record --out FILE.wav      record a take to a 16-bit WAV
  jawn-audio --record --out FILE.wav --play --file A.wav
                                          overdub: record while A.wav plays back
  jawn-audio --play --file A.wav          play takes back through their strips
  jawn-audio --listen [options]           monitor one input through a strip
  jawn-audio --patch --plan FILE          run the house patchbay from a saved plan
  jawn-audio --serve [options]            arm and place takes over a Unix socket
  jawn-audio --clock-master [options]     answer clock probes over UDP (P3)
  jawn-audio --clock-peer [options]       measure a master's clock over UDP (P3)
  jawn-audio --version                    print the version
  jawn-audio --help                       this text

--run options:
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N      block/period size in frames (default 64; --frames is an alias)
  --buffer N      buffer size in frames (default 256)
  --seconds S     how long to run, in seconds (default 1)
  --rate HZ       sample rate (default 48000)
  --channels N    channels per frame (default 2, 1..=32)
  --tone HZ       emit a sine instead of silence
  --json          one JSON line instead of prose

--record options:
  --out FILE.wav  where to write the take (required)
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --system-device NAME
                  mix the machine's own audio from this PulseAudio/PipeWire
                  source into the monitor output only, never the take
                  (the manager uses jawn_system.monitor)
  --period N      block/period size in frames (default 64)
  --buffer N      buffer size in frames (default 256)
  --seconds S     how long to record, in seconds (default 5)
  --rate HZ       sample rate (default 48000)
  --start-at S    the take's start sample on the transport (default 0)
  --channels N    capture channels to ask the device for (default 2, 1..=32)
  --tracks N      tracks to write, 1..=channels (default 1)
  --inputs LIST   which device channels become tracks, e.g. 2,0,3
                  (default 0..tracks, in track order)
  --gain N        channel trim, linear (default 1.0)
  --pan N         channel pan, -1 left .. 1 right (default 0, centre)
  --channel N     which input a one-track take records (default input 0)
  --insert NAME   an insert, repeatable in chain order:
                  tone, distortion, delay, compressor, reverb, flanger, fuzz,
                  amp, limiter, autotune, equalizer or maximizer
                  (reverb2 is accepted as the web's name; default none)
  --tone HZ       with the null backend, record a sine instead of silence
  --monitor FILE.wav
                  play FILE.wav to the outputs while this take records;
                  repeatable (--play --file FILE.wav is the same thing)
  --monitor-file FILE.wav
                  the same monitor bus, spelled for per-file knobs
  --monitor-gain [N:]G
                  trim for monitor file N (1-based), or every file
  --monitor-pan [N:]P
                  pan for monitor file N, or every file (default 0, centre)
  --monitor-insert [N:]NAME
                  an insert on monitor file N (or every file), repeatable
                  in chain order: tone, distortion, delay, compressor,
                  reverb, flanger, fuzz, amp, limiter, autotune, equalizer
                  or maximizer
  --align-samples N
                  start the monitor N samples before the take's --start-at;
                  use a measured capture offset (clamped so it never starts
                  before sample 0)
  --calibrate     measure that offset once with the patch cable before the
                  take; a failed or zero measurement shifts nothing
  --json          one JSON line instead of prose

  Every track writes its own stereo WAV: --out take.wav becomes take-ch1.wav,
  take-ch2.wav, ... for each track. All files share the take's start_sample.
  --inputs 2,0 makes track 1 input 2 and track 2 input 0, in the order given.
  A track whose input is outside the device's channels is refused before any
  file is created. --gain, --pan and --insert apply to every track unless
  prefixed with a 1-based track number, e.g. --insert 1:delay, --gain 2:0.5,
  --pan 2:-1. A prefixed knob may only name a track the take has. The JSON's
  top-level path/frames/dropped/inserts describe track 1; channels is the
  count the device granted; a multi-track take adds
  \"tracks\":[{\"path\":...,\"input\":N,\"frames\":N,\"dropped\":N},...]. A
  one-track take keeps its historical shape and omits \"tracks\".

  --monitor (or --play together with --file) is an overdub: the take captures
  the inputs while the named files play to the outputs. The monitor is a
  separate playback on its own device handle; it is never summed into the
  take, which stays the input through its strip. The monitor files must share
  the take's rate. Each monitor file gets its own strip: the unprefixed
  --monitor-gain/--monitor-pan/--monitor-insert apply to every file and an
  N: prefix to one 1-based file. The monitor starts at the take's --start-at
  sample minus the capture offset: --align-samples gives that offset, or
  --calibrate measures the patch-cable round trip once before the take. With
  neither, nothing is shifted. A take reports
  \"playing\":N,\"monitor_frames\":M and
  \"align_samples\":N,\"align_from\":\"measured|given|none\" when a monitor
  ran (plus \"monitor_error\" if the player failed after the take started).
  The offset is a start correction; drift over a long take is not measured.
  Two takes at once are still refused; so are two playbacks.

--play options:
  --file FILE.wav   a take to play; repeat the flag, one strip per file
  --backend N       null (default), alsa, pipewire or jack
  --device NAME     ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N        block/period size in frames (default 64; --frames is an alias)
  --buffer N        buffer size in frames (default 256)
  --seconds S       stop after S seconds (default: every file to its end)
  --start-at SAMPLE skip this many frames of every file (default 0)
  --gain N          channel trim, linear (default 1.0)
  --pan N           channel pan, -1 left .. 1 right (default 0, centre)
  --insert NAME     an insert, repeatable in chain order:
                    tone, distortion, delay, compressor, reverb, flanger,
                    fuzz, amp, limiter, autotune, equalizer or maximizer
  --json            accepted for symmetry: --play always prints its JSON line

  Every file gets its own strip and the strips are summed into the stereo
  output. Files share one timeline: playback starts at frame 0 of each (or at
  --start-at), so takes cut from the same transport stay lined up. They must
  share a sample rate; the rate comes from the files, not --rate. A 16-bit
  PCM WAV of one or two channels is playable; anything else is refused by
  name. As with --record, --gain 2:0.5, --pan 2:-1 and --insert 1:delay apply
  to one 1-based file, and an unprefixed knob applies to every file. The null
  backend plays as fast as it can; ALSA is paced by the card.

--listen options:
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --system-device NAME
                  mix the machine's own audio from this PulseAudio/PipeWire
                  source into the monitored output (the manager uses
                  jawn_system.monitor)
  --channel N     which input to monitor (default 0; the instrument is 1)
  --gain N        channel trim, linear (default 1.0)
  --pan N         channel pan, -1 left .. 1 right (default 0, centre)
  --insert NAME   an insert, repeatable in chain order:
                  tone, distortion, delay, compressor, reverb, flanger, fuzz,
                  amp, limiter, autotune, equalizer or maximizer
  --period N      block/period size in frames (default 64; --frames is an alias)
  --buffer N      buffer size in frames (default 256)
  --seconds S     stop after S seconds (default: until SIGINT/SIGTERM)
  --rate HZ       sample rate (default 48000)
  --channels N    capture channels to ask the device for (default 2, 1..=32)
  --tone HZ       with the null backend, generate this sine as the input
  --json          accepted for symmetry: --listen always prints its JSON line

  One capture stream, one mono block, one strip: --channel selects the input,
  the trim runs before the inserts and the equal-power pan after them, and the
  stereo pair goes to the outputs. A device error is one JSON line and exit 1.
  A SIGINT or SIGTERM stops both streams cleanly, prints the same line and
  exits 0. A take cannot record while listening, and listen is refused while a
  take records: sharing one capture between listen and record is the next step.

--patch options:
  --plan FILE     the saved plan to run (required), one JSON object with
                  sources, buses, sinks and routes
  --machine NAME  which machine this engine is (default: --machine, then
                  $JAWNOS_AUDIO_MACHINE, then $HOSTNAME, then \"local\")
  --system-device NAME
                  capture the machine's own mix from this PulseAudio/PipeWire
                  source (the manager uses jawn_system.monitor)
  --handset-device NAME
                  capture a plan's `handset` source from this PulseAudio/
                  PipeWire source (default jawn_call_in.monitor)
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N      block/period size in frames (default 64; --frames is an alias)
  --buffer N      buffer size in frames (default 256)
  --seconds S     stop after S seconds (default: until SIGINT/SIGTERM)
  --rate HZ       sample rate (default 48000)
  --channels N    capture channels to ask the device for (default 2, 1..=32)
  --tone HZ       with the null backend, generate this sine as the input
  --json          one JSON line instead of prose

  The plan is docs/studio-audio-roadmap.md §8. A source is an input channel,
  the machine's own mix (a `device` source), or the reception handset's
  screened call (a `handset` source); a bus is a stereo sum, a sink is the
  output pair, and a route is an edge with gain and pan. A node this machine
  cannot bind (a peer, a phone, a zone) is reported in \"silent\" and
  contributes nothing; a route delay, a gain or
  pan outside its range, an unknown endpoint and a bus loop are refused. The
  graph is compiled before the device opens: the block loop allocates nothing.

--loopback options:
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N      period/block size in frames (default 64)
  --buffer N      buffer size in frames (default 256)
  --rate HZ       sample rate (default 48000)
  --json          one JSON line instead of prose

--serve options:
  --socket PATH   control socket (default $JAWNOS_AUDIO_SOCKET, else
                  $HOME/.president/audio.sock)
  --plan FILE     the saved-plan wrapper to restore at startup (default
                  $JAWNOS_AUDIO_PLAN, else $HOME/.president/audio-plan.json);
                  a missing file, manage false, or an invalid plan still serves
  --machine NAME  which machine this engine serves (same precedence as --patch)
  --system-device NAME
                  capture the machine's own mix from this PulseAudio/PipeWire
                  source (the manager uses jawn_system.monitor)
  --handset-device NAME
                  capture a plan's `handset` source from this PulseAudio/
                  PipeWire source (default jawn_call_in.monitor)
  --uplink ADDR   listen on UDP ADDR for a peer's audio (e.g.
                  0.0.0.0:7060); needs --session-key-hex HEX64 (or
                  $JAWNOS_AUDIO_SESSION_KEY). A plan's `peer` source is
                  `pending` until a peer gets a clock session, then mixed
                  like a local input
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N      block/period size in frames (default 64)
  --buffer N      buffer size in frames (default 256)
  --rate HZ       sample rate (default 48000)
  --channels N    capture channels a take asks for (default 2, 1..=32)

--serve speaks one JSON object per line: record, play, listen, patch,
unpatch, param, status, stop, quit. `patch` takes `plan`, the saved sources,
buses, sinks and routes, and runs the house mixer until `unpatch` or `stop`;
`status` reports its shape, the frames it has rendered and the nodes this
machine cannot bind. A `peer` source is another machine's input on the
`--uplink`: audio stream 0x1000 + the source's plan index, carried on the
clock session and mixed like a local input. `status` also reports
\"uplink\":{\"state\",\"bind\",\"error\",\"sessions\",\"rejected\",\"sources\"}, where
each source carries its received, late, concealed and dropped frame counts.
`record` takes \"out\", \"seconds\", \"start_at\", \"tracks\" and \"inputs\";
\"monitor\" is an array of absolute WAV paths, or of objects
{\"file\":\"/abs/a.wav\",\"gain\":0.8,\"pan\":-0.2,\"inserts\":[\"tone\"]},
played to the outputs while the take records (an overdub; the monitor never
enters the take). \"click\" is the take's metronome,
{\"bpm\":120,\"beats_per_bar\":4,\"gain\":0.5}: the engine generates it on the
monitor's own sample clock, accented on the first beat of each bar, for the
take's \"seconds\" (a click-only take opens the output with no monitor files
and no live input). It is monitor-only and never enters the take. `play` may
run beside a recording's monitor, and `record`
may start over a running playback. Two takes at once, and two playbacks at
once, are refused. `listen` opens capture on \"channel\" and plays it through
one strip (\"gain\", \"pan\", \"inserts\"); `status` reports it as \"listening\"
with \"frames\" and the strip, and `param` addresses it with
\"target\":\"listen\". A take and a listen refuse each other while both need the
capture stream. One `stop` ends and joins every running role, and `status` reports
the take's state with \"playing\", \"monitor_frames\" and the monitor strips
beside it. `start_at` is the take's stamp; the monitor starts that many
samples minus the capture offset given by \"align_samples\" or measured by
\"calibrate\":true before the take. `param` addresses the take's tracks with
\"track\", or a monitor strip with \"target\":\"monitor\".
`tracks` is a count (one wire per input) or an array of per-track objects
{\"input\":N,\"gain\":G,\"pan\":P,\"inserts\":[NAMES]}, which arms that track's
real chain. `param` moves one knob of a running take's strip and answers when
the change is queued for the next block; `status` reports every track and
the gain, pan and inserts it was armed with.
The null backend needs no sound card. ALSA and JACK exist only in a build with
--features alsa and/or --features jack; pipewire uses the ALSA `default` PCM.
A loopback needs the interface's output patched into its input.

--clock-master options:
  --bind IP:PORT  address to listen on (default 127.0.0.1:0, loopback only and
                  an ephemeral port); the bound address is printed on stderr
                  as soon as it binds
  --lease-ms MS   forget a session idle for more than MS milliseconds
                  (default 30000); a peer that keeps pinging refreshes it, so
                  only a vanished peer expires
  --session-key-hex HEX64
                  the 32-byte session key, 64 hex characters (default
                  $JAWNOS_AUDIO_SESSION_KEY); a clock session has no
                  unauthenticated mode
  --seconds S     how long to answer probes, in seconds (default 1)
  --rate HZ       the sample rate the timestamps count (default 48000)
  --json          one JSON line at the end instead of prose

--clock-peer options:
  --master IP:PORT  the clock master to probe (required; there is no default)
  --session-key-hex HEX64
                  the same 32-byte key as the master (default
                  $JAWNOS_AUDIO_SESSION_KEY); a clock session needs a key
  --seconds S       how long to probe, in seconds (default 1)
  --rate HZ         the sample rate the timestamps count (default 48000)
  --pong-timeout-ms MS
                  how long one ping waits for its pong before the next
                  (default 20; a LAN's round trip must fit, or every reply is
                  discarded)
  --window N        probes kept in the least-squares fit (default 64). A
                  window at least as long as the run fits the whole run, so
                  the slope is the drift over that span rather than the rate
                  of the last second.
  --json            one JSON line instead of prose

  The peer sends a CLOCK_HELLO carrying a tag before its first ping; the master
  answers a CLOCK_WELCOME with a fresh session id, then a CLOCK_PING every
  10 ms is signed with that session and a 16-byte truncated HMAC-SHA256. The
  master drops a ping whose session it did not issue, whose tag fails, or whose
  seq it already accepted, and reports it in \"rejected\". It also forgets a
  session idle past --lease-ms. The master repeats the receive and send times
  in a CLOCK_PONG, and the peer least-squares fits master = a + b*local over a
  bounded window. offset_samples is a and drift_ppm is the peer clock's rate
  error (positive means the peer runs fast). High-RTT probes are dropped rather
  than fitted. If no pong is accepted for two seconds (or 100 ping intervals,
  whichever is longer), the peer resets its session and repeats the HELLO /
  WELCOME exchange, so a master restart does not strand it. The peer's JSON
  also carries \"session\", \"handshakes\" and \"rejected\". This mode opens no
  audio device and writes no socket under ~/.president; the default master
  bind is loopback, and an address another machine can reach is an explicit
  --bind.";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Check,
    Backends,
    Run,
    Loopback,
    Record,
    Play,
    Listen,
    Patch,
    Serve,
    ClockMaster,
    ClockPeer,
    SelfTest,
    Version,
    Help,
}

#[derive(Clone, Copy)]
struct InsertSpec {
    /// 1-based track number, or `None` for every track.
    track: Option<usize>,
    kind: InsertKind,
}

struct Options {
    mode: Mode,
    backend: BackendKind,
    device: Option<String>,
    seconds: f64,
    rate: u32,
    frames: usize,
    buffer: usize,
    channels: usize,
    tone: Option<f32>,
    out: Option<String>,
    socket: Option<String>,
    /// `--plan`: the saved plan a `--patch` run applies, or the saved-plan
    /// wrapper a `--serve` restores from.
    plan: Option<String>,
    /// `--bind`: the address a clock master listens on.
    bind: Option<String>,
    /// `--master`: the address a clock peer probes.
    master: Option<String>,
    /// `--session-key-hex`: the 32-byte key a clock session signs with. When
    /// the flag is absent, `$JAWNOS_AUDIO_SESSION_KEY` fills it.
    session_key_hex: Option<String>,
    /// Whether `--session-key-hex` was given on the command line (so the
    /// environment fallback is not mistaken for a flag outside the clock modes).
    session_key_given: bool,
    /// `--pong-timeout-ms`: how long one clock ping waits for its pong. Shorter
    /// than a LAN's round trip loses every reply; longer only delays the next
    /// ping after a loss.
    pong_timeout_ms: u64,
    /// `--window`: how many probes the clock estimator's least-squares fit
    /// keeps. A window at least as long as the run fits the whole run, which
    /// is what turns a rate estimate into a drift measurement.
    window: usize,
    /// `--lease-ms`: how long the clock master keeps an idle session.
    lease_ms: u64,
    /// Which machine this engine serves, resolved from `--machine`, then
    /// `$JAWNOS_AUDIO_MACHINE`, then `$HOSTNAME`, then `"local"`.
    machine: String,
    /// Whether `--machine` was given on the command line (so it can be refused
    /// outside `--patch`/`--serve`).
    machine_given: bool,
    /// The PulseAudio/PipeWire source the machine's own mix is captured from.
    /// The supervisor names the virtual sink's monitor; a hand-run patch can
    /// name a fixture source. `None` means no system mix.
    system_device: Option<String>,
    /// Whether `--system-device` was given on the command line.
    system_device_given: bool,
    /// The PulseAudio/PipeWire source a plan's `handset` source is captured
    /// from. `None` means the caller asked for no handset capture at all.
    handset_device: Option<String>,
    /// Whether `--handset-device` was given on the command line.
    handset_device_given: bool,
    /// `--uplink`: the UDP address a `--serve` listens on for peer audio.
    uplink: Option<String>,
    start_at: u64,
    gain: f32,
    pan: f32,
    gains: Vec<(usize, f32)>,
    pans: Vec<(usize, f32)>,
    inserts: Vec<InsertSpec>,
    /// `--insert` words the engine does not know. `--listen` reports one as a
    /// runtime failure (exit 1); every other mode keeps the historical usage
    /// error (exit 2). The mode is not known until the whole line is read.
    invalid_inserts: Vec<String>,
    /// `--file` in the order given; one strip per file for `--play`.
    files: Vec<String>,
    /// `--monitor`/`--monitor-file` in the order given, or `--file` when
    /// `--play` accompanies `--record`: the takes played to the outputs while
    /// a new one records.
    monitor: Vec<String>,
    /// `--monitor-gain`: the unprefixed trim for every monitor file, and the
    /// 1-based per-file overrides in the order given.
    monitor_gain: f32,
    monitor_gains: Vec<(usize, f32)>,
    /// `--monitor-pan`, the same shape.
    monitor_pan: f32,
    monitor_pans: Vec<(usize, f32)>,
    /// `--monitor-insert`: one file, or every file when unprefixed.
    monitor_inserts: Vec<InsertSpec>,
    /// `--align-samples`: a measured or manual capture offset.
    align_samples: Option<u64>,
    /// `--calibrate`: measure the offset with the patch cable before the take.
    calibrate: bool,
    /// Which mode flags the command line actually carried. `--record --play`
    /// together is an overdub, so the two flags cannot be one enum field.
    record_flag: bool,
    play_flag: bool,
    tracks: usize,
    /// The device channels a take records, in track order. Empty means the
    /// default `0..tracks`; `--inputs` fills it.
    inputs: Vec<usize>,
    inputs_given: bool,
    input: usize,
    input_given: bool,
    seconds_given: bool,
    json: bool,
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(message) => {
            eprintln!("jawn-audio: {message}");
            ExitCode::from(2)
        }
    }
}

fn default_options() -> Options {
    Options {
        mode: Mode::Help,
        backend: BackendKind::Null,
        device: None,
        seconds: 1.0,
        rate: 48_000,
        frames: 64,
        buffer: 256,
        channels: 2,
        tone: None,
        out: None,
        socket: None,
        plan: None,
        bind: None,
        master: None,
        session_key_hex: None,
        session_key_given: false,
        pong_timeout_ms: peer::PONG_TIMEOUT_MS,
        window: peer::ESTIMATOR_CAPACITY,
        lease_ms: peer::DEFAULT_LEASE_MS,
        machine: String::new(),
        machine_given: false,
        system_device: None,
        system_device_given: false,
        handset_device: None,
        handset_device_given: false,
        uplink: None,
        start_at: 0,
        gain: 1.0,
        pan: 0.0,
        gains: Vec::new(),
        pans: Vec::new(),
        inserts: Vec::new(),
        invalid_inserts: Vec::new(),
        files: Vec::new(),
        monitor: Vec::new(),
        monitor_gain: 1.0,
        monitor_gains: Vec::new(),
        monitor_pan: 0.0,
        monitor_pans: Vec::new(),
        monitor_inserts: Vec::new(),
        align_samples: None,
        calibrate: false,
        record_flag: false,
        play_flag: false,
        tracks: 1,
        inputs: Vec::new(),
        inputs_given: false,
        input: 0,
        input_given: false,
        seconds_given: false,
        json: false,
    }
}

fn parse_arguments(
    options: &mut Options,
    mut args: impl Iterator<Item = String>,
) -> Result<(), String> {
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--check" => options.mode = Mode::Check,
            "--backends" => options.mode = Mode::Backends,
            "--run" => options.mode = Mode::Run,
            "--loopback" => options.mode = Mode::Loopback,
            "--record" => {
                options.mode = Mode::Record;
                options.record_flag = true;
            }
            "--play" => {
                options.mode = Mode::Play;
                options.play_flag = true;
            }
            "--listen" => options.mode = Mode::Listen,
            "--patch" => options.mode = Mode::Patch,
            "--file" => options.files.push(value(&mut args, "--file")?),
            "--monitor" | "--monitor-file" => {
                options.monitor.push(value(&mut args, &arg)?)
            }
            "--monitor-gain" => {
                let raw = value(&mut args, "--monitor-gain")?;
                let (file, text) = split_target(&raw);
                let gain: f32 = text
                    .parse()
                    .map_err(|_| format!("--monitor-gain wants a multiplier, not `{raw}`"))?;
                match file {
                    Some(file) => options.monitor_gains.push((file, gain)),
                    None => options.monitor_gain = gain,
                }
            }
            "--monitor-pan" => {
                let raw = value(&mut args, "--monitor-pan")?;
                let (file, text) = split_target(&raw);
                let pan: f32 = text
                    .parse()
                    .map_err(|_| format!("--monitor-pan wants -1, 0 or 1, not `{raw}`"))?;
                match file {
                    Some(file) => options.monitor_pans.push((file, pan)),
                    None => options.monitor_pan = pan,
                }
            }
            "--monitor-insert" => {
                let raw = value(&mut args, "--monitor-insert")?;
                let (file, text) = split_target(&raw);
                let kind = InsertKind::parse(text).ok_or_else(|| {
                    format!(
                        "unknown insert `{text}` (want tone, distortion, delay, compressor, reverb, flanger, fuzz, amp, limiter, autotune, equalizer or maximizer)"
                    )
                })?;
                options.monitor_inserts.push(InsertSpec { track: file, kind });
            }
            "--align-samples" => {
                let raw = value(&mut args, "--align-samples")?;
                options.align_samples = Some(
                    raw.parse()
                        .map_err(|_| format!("--align-samples wants a sample count, not `{raw}`"))?,
                );
            }
            "--calibrate" => options.calibrate = true,
            "--serve" => options.mode = Mode::Serve,
            "--clock-master" => options.mode = Mode::ClockMaster,
            "--clock-peer" => options.mode = Mode::ClockPeer,
            "--bind" => options.bind = Some(value(&mut args, "--bind")?),
            "--master" => options.master = Some(value(&mut args, "--master")?),
            "--session-key-hex" => {
                options.session_key_hex = Some(value(&mut args, "--session-key-hex")?);
                options.session_key_given = true;
            }
            "--pong-timeout-ms" => {
                let raw = value(&mut args, "--pong-timeout-ms")?;
                options.pong_timeout_ms = raw.parse().map_err(|_| {
                    format!("--pong-timeout-ms wants milliseconds, not `{raw}`")
                })?;
            }
            "--window" => {
                let raw = value(&mut args, "--window")?;
                options.window = raw
                    .parse()
                    .map_err(|_| format!("--window wants a probe count, not `{raw}`"))?;
            }
            "--lease-ms" => {
                let raw = value(&mut args, "--lease-ms")?;
                options.lease_ms = raw
                    .parse()
                    .map_err(|_| format!("--lease-ms wants milliseconds, not `{raw}`"))?;
            }
            "--selftest" => options.mode = Mode::SelfTest,
            "--version" | "-V" => options.mode = Mode::Version,
            "--help" | "-h" => options.mode = Mode::Help,
            "--json" => options.json = true,
            "--backend" => {
                let raw = value(&mut args, "--backend")?;
                options.backend = BackendKind::parse(&raw).ok_or_else(|| {
                    format!("unknown backend `{raw}` (want null, alsa, pipewire or jack)")
                })?;
            }
            "--device" => options.device = Some(value(&mut args, "--device")?),
            "--period" | "--frames" => {
                let raw = value(&mut args, &arg)?;
                options.frames = raw
                    .parse()
                    .map_err(|_| format!("{arg} wants a block size, not `{raw}`"))?;
            }
            "--buffer" => {
                let raw = value(&mut args, "--buffer")?;
                options.buffer = raw
                    .parse()
                    .map_err(|_| format!("--buffer wants a buffer size, not `{raw}`"))?;
            }
            "--seconds" => {
                let raw = value(&mut args, "--seconds")?;
                options.seconds = raw
                    .parse()
                    .map_err(|_| format!("--seconds wants a number, not `{raw}`"))?;
                options.seconds_given = true;
            }
            "--rate" => {
                let raw = value(&mut args, "--rate")?;
                options.rate = raw
                    .parse()
                    .map_err(|_| format!("--rate wants a sample rate, not `{raw}`"))?;
            }
            "--channels" => {
                let raw = value(&mut args, "--channels")?;
                options.channels = raw
                    .parse()
                    .map_err(|_| format!("--channels wants a channel count, not `{raw}`"))?;
            }
            "--tone" => {
                let raw = value(&mut args, "--tone")?;
                options.tone = Some(
                    raw.parse()
                        .map_err(|_| format!("--tone wants a frequency, not `{raw}`"))?,
                );
            }
            "--out" => options.out = Some(value(&mut args, "--out")?),
            "--socket" => options.socket = Some(value(&mut args, "--socket")?),
            "--plan" => options.plan = Some(value(&mut args, "--plan")?),
            "--machine" => {
                options.machine = value(&mut args, "--machine")?;
                options.machine_given = true;
            }
            "--system-device" => {
                options.system_device = Some(value(&mut args, "--system-device")?);
                options.system_device_given = true;
            }
            "--handset-device" => {
                let name = value(&mut args, "--handset-device")?;
                options.handset_device = (!name.is_empty()).then_some(name);
                options.handset_device_given = true;
            }
            "--uplink" => {
                options.uplink = Some(value(&mut args, "--uplink")?);
            }
            "--start-at" => {
                let raw = value(&mut args, "--start-at")?;
                options.start_at = raw
                    .parse()
                    .map_err(|_| format!("--start-at wants a sample count, not `{raw}`"))?;
            }
            "--tracks" => {
                let raw = value(&mut args, "--tracks")?;
                options.tracks = raw
                    .parse()
                    .map_err(|_| format!("--tracks wants a track count, not `{raw}`"))?;
            }
            "--inputs" => {
                let raw = value(&mut args, "--inputs")?;
                options.inputs = parse_inputs(&raw)?;
                options.inputs_given = true;
            }
            "--gain" => {
                let raw = value(&mut args, "--gain")?;
                let (track, text) = split_target(&raw);
                let gain: f32 = text
                    .parse()
                    .map_err(|_| format!("--gain wants a multiplier, not `{raw}`"))?;
                match track {
                    Some(track) => options.gains.push((track, gain)),
                    None => options.gain = gain,
                }
            }
            "--channel" => {
                let raw = value(&mut args, "--channel")?;
                options.input = raw
                    .parse()
                    .map_err(|_| format!("--channel wants an input number, not `{raw}`"))?;
                options.input_given = true;
            }
            "--pan" => {
                let raw = value(&mut args, "--pan")?;
                let (track, text) = split_target(&raw);
                let pan: f32 = text
                    .parse()
                    .map_err(|_| format!("--pan wants -1, 0 or 1, not `{raw}`"))?;
                match track {
                    Some(track) => options.pans.push((track, pan)),
                    None => options.pan = pan,
                }
            }
            "--insert" => {
                let raw = value(&mut args, "--insert")?;
                let (track, text) = split_target(&raw);
                match InsertKind::parse(text) {
                    Some(kind) => options.inserts.push(InsertSpec { track, kind }),
                    None => options.invalid_inserts.push(text.to_string()),
                }
            }
            other => return Err(format!("unknown option `{other}` (try --help)")),
        }
    }
    Ok(())
}

/// The clock modes' own rules. `--bind` and `--master` belong to one role
/// each, a probe loop needs a duration and rate it can act on, and the two
/// knobs that tune that loop belong to the peer alone.
fn validate_clock_options(options: &Options) -> Result<(), String> {
    let clock = matches!(options.mode, Mode::ClockMaster | Mode::ClockPeer);
    // A serve's uplink is the other keyed transport: it answers a peer's HELLO
    // and authenticates its audio with the same 32-byte key.
    let keyed_serve = options.mode == Mode::Serve && options.uplink.is_some();
    if options.session_key_given && !clock && !keyed_serve {
        return Err(
            "--session-key-hex applies only to --clock-master, --clock-peer and --serve --uplink"
                .to_string(),
        );
    }
    if options.bind.is_some() && options.mode != Mode::ClockMaster {
        return Err("--bind applies only to --clock-master".to_string());
    }
    if options.master.is_some() && options.mode != Mode::ClockPeer {
        return Err("--master applies only to --clock-peer".to_string());
    }
    if options.mode != Mode::ClockPeer
        && (options.pong_timeout_ms != peer::PONG_TIMEOUT_MS
            || options.window != peer::ESTIMATOR_CAPACITY)
    {
        return Err("--pong-timeout-ms and --window apply only to --clock-peer".to_string());
    }
    if options.mode != Mode::ClockMaster && options.lease_ms != peer::DEFAULT_LEASE_MS {
        return Err("--lease-ms applies only to --clock-master".to_string());
    }
    if options.mode == Mode::ClockPeer && options.master.is_none() {
        return Err(
            "--clock-peer needs --master IP:PORT: the clock master to probe".to_string(),
        );
    }
    if clock {
        let key = options.session_key_hex.as_deref().ok_or_else(|| {
            "a clock session needs a key: pass --session-key-hex HEX64 \
             or set $JAWNOS_AUDIO_SESSION_KEY"
                .to_string()
        })?;
        peer::parse_session_key(key).map_err(|error| format!("--session-key-hex: {error}"))?;
        if !(options.seconds.is_finite() && options.seconds > 0.0) {
            return Err("--seconds wants a positive, finite duration".to_string());
        }
        if options.rate == 0 {
            return Err("--rate wants a positive sample rate".to_string());
        }
    }
    if options.mode == Mode::ClockPeer {
        if options.pong_timeout_ms == 0 {
            return Err("--pong-timeout-ms wants a positive number of milliseconds".to_string());
        }
        if options.window == 0 {
            return Err("--window wants at least one probe".to_string());
        }
    }
    if options.mode == Mode::ClockMaster && options.lease_ms == 0 {
        return Err("--lease-ms wants a positive number of milliseconds".to_string());
    }
    Ok(())
}

/// The 32-byte key both clock roles sign with. Validation has already proved it
/// is present and well formed, but the run functions decode it themselves so a
/// direct caller cannot skip the check.
fn session_key(options: &Options) -> Result<[u8; 32], String> {
    let text = options.session_key_hex.as_deref().ok_or_else(|| {
        "a clock session needs a key: pass --session-key-hex HEX64 \
         or set $JAWNOS_AUDIO_SESSION_KEY"
            .to_string()
    })?;
    peer::parse_session_key(text).map_err(|error| format!("--session-key-hex: {error}"))
}

fn run() -> Result<ExitCode, String> {
    let mut options = default_options();
    parse_arguments(&mut options, std::env::args().skip(1))?;

    // A clock session has no unauthenticated form. The flag wins; otherwise the
    // supervisor's environment supplies the same 32-byte key.
    if !options.session_key_given {
        if let Ok(key) = std::env::var("JAWNOS_AUDIO_SESSION_KEY") {
            let key = key.trim();
            if !key.is_empty() {
                options.session_key_hex = Some(key.to_string());
            }
        }
    }

    // The machine is resolved once, from the flag, then the environment, then
    // the hostname, then "local". It is only used by `--patch` and `--serve`,
    // but the default is harmless for every other mode.
    options.machine = resolve_machine(if options.machine_given {
        Some(options.machine.as_str())
    } else {
        None
    });
    if !options.system_device_given {
        if let Ok(device) = std::env::var("JAWNOS_AUDIO_SYSTEM_DEVICE") {
            if !device.is_empty() {
                options.system_device = Some(device);
            }
        }
    }
    if !options.handset_device_given {
        options.handset_device = Some(
            std::env::var("JAWNOS_AUDIO_HANDSET_DEVICE")
                .ok()
                .filter(|device| !device.is_empty())
                .unwrap_or_else(|| "jawn_call_in.monitor".to_string()),
        );
    }

    // `--record` together with `--play` is an overdub, not two modes: the
    // take is the capture and the files are the monitoring bus. `--monitor`
    // names the same bus without the extra flag. Reconciled here, after the
    // whole command line (and therefore after every `--file`) is read.
    if options.record_flag && options.play_flag {
        if options.files.is_empty() && options.monitor.is_empty() {
            return Err(
                "--play with --record needs at least one --file FILE.wav to monitor".to_string(),
            );
        }
        options.mode = Mode::Record;
        options.monitor.append(&mut options.files);
    } else if !options.monitor.is_empty() {
        if !options.record_flag {
            return Err(
                "--monitor plays earlier takes while a new one records; pass --record --out FILE.wav"
                    .to_string(),
            );
        }
        options.mode = Mode::Record;
    }

    // An unknown insert is a usage error everywhere except `--listen`, whose
    // one contract is the JSON line. Reporting it now means the word added at
    // parse time does not have to guess the mode.
    if let Some(word) = options.invalid_inserts.first() {
        let message = format!(
            "unknown insert `{word}` (want tone, distortion, delay, compressor, reverb, flanger, fuzz, amp, limiter, autotune, equalizer or maximizer)"
        );
        if options.mode == Mode::Listen {
            let device = options.backend.device_name(options.device.as_deref());
            let report = ListenReport::failure(
                options.backend.name(),
                device,
                options.input,
                options.rate,
                message,
            );
            println!("{}", report.to_json());
            return Ok(ExitCode::from(1));
        }
        return Err(message);
    }

    // These knobs describe a take's tracks, and `--record` is the only mode
    // that has them today; say so instead of accepting a knob that does
    // nothing. `--channel` keeps its old shape outside `--record` (it was
    // always accepted there) so this is not a regression for an existing call.
    let strips = matches!(options.mode, Mode::Record | Mode::Play | Mode::Listen);
    if !strips
        && (options.gain != 1.0
            || options.pan != 0.0
            || !options.gains.is_empty()
            || !options.pans.is_empty()
            || !options.inserts.is_empty())
    {
        return Err("--gain, --pan and --insert apply only to --record and --play".to_string());
    }
    if options.mode != Mode::Record && (options.tracks != 1 || options.inputs_given) {
        return Err("--tracks and --inputs apply only to --record".to_string());
    }
    let monitor_knobs = options.monitor_gain != 1.0
        || options.monitor_pan != 0.0
        || !options.monitor_gains.is_empty()
        || !options.monitor_pans.is_empty()
        || !options.monitor_inserts.is_empty();
    if options.mode != Mode::Record && monitor_knobs {
        return Err(
            "--monitor-gain, --monitor-pan and --monitor-insert apply only to --record"
                .to_string(),
        );
    }
    if options.mode != Mode::Record && (options.align_samples.is_some() || options.calibrate) {
        return Err("--align-samples and --calibrate apply only to --record".to_string());
    }
    if options.mode == Mode::Patch && options.plan.is_none() {
        return Err("--patch needs --plan FILE: the saved plan to run".to_string());
    }
    if !matches!(options.mode, Mode::Patch | Mode::Serve) && options.plan.is_some() {
        return Err("--plan applies only to --patch and --serve".to_string());
    }
    if options.machine_given && !matches!(options.mode, Mode::Patch | Mode::Serve) {
        return Err("--machine applies only to --patch and --serve".to_string());
    }
    if !matches!(
        options.mode,
        Mode::Record | Mode::Listen | Mode::Patch | Mode::Serve
    ) && options.system_device_given
    {
        return Err(
            "--system-device applies only to --record, --listen, --patch and --serve"
                .to_string(),
        );
    }
    if options.handset_device_given && !matches!(options.mode, Mode::Patch | Mode::Serve) {
        return Err("--handset-device applies only to --patch and --serve".to_string());
    }
    if options.uplink.is_some() && options.mode != Mode::Serve {
        return Err("--uplink applies only to --serve".to_string());
    }
    validate_clock_options(&options)?;

    match options.mode {
        Mode::Help => {
            println!("{USAGE}");
            Ok(ExitCode::SUCCESS)
        }
        Mode::Version => {
            println!("jawn-audio {}", env!("CARGO_PKG_VERSION"));
            Ok(ExitCode::SUCCESS)
        }
        Mode::Check => {
            let available = backends::availability();
            println!("device: null (default backend)");
            println!(
                "backends: alsa {}, pipewire {}, jack {}, null yes",
                yes_no(available.alsa),
                yes_no(available.pipewire),
                yes_no(available.jack)
            );
            println!("shape: {} Hz, {} frames, {} channels", 48_000, 64, 2);
            Ok(ExitCode::SUCCESS)
        }
        Mode::Backends => {
            let available = backends::availability();
            if options.json {
                println!("{}", backends::json(&available));
            } else {
                print!("{}", backends::prose(&available));
            }
            Ok(ExitCode::SUCCESS)
        }
        Mode::SelfTest => {
            self_test()?;
            Ok(ExitCode::SUCCESS)
        }
        Mode::Run => {
            validate_run(&options)?;
            let report = run_device(&options)?;
            print_run(&report, options.json);
            Ok(ExitCode::SUCCESS)
        }
        Mode::Loopback => run_loopback(&options),
        Mode::Record => run_record(&options),
        Mode::Play => run_play(&options),
        Mode::Listen => run_listen(&options),
        Mode::Patch => run_patch(&options),
        Mode::Serve => run_serve(&options),
        Mode::ClockMaster => run_clock_master(&options),
        Mode::ClockPeer => run_clock_peer(&options),
    }
}

fn yes_no(value: bool) -> &'static str {
    if value {
        "yes"
    } else {
        "no"
    }
}

fn value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next().ok_or_else(|| format!("{flag} wants a value"))
}

/// The engine's machine, highest precedence first: `--machine`, then
/// `$JAWNOS_AUDIO_MACHINE`, then `$HOSTNAME`, then `"local"`.
fn resolve_machine(flag: Option<&str>) -> String {
    if let Some(name) = flag {
        if !name.is_empty() {
            return name.to_string();
        }
    }
    if let Ok(name) = std::env::var("JAWNOS_AUDIO_MACHINE") {
        if !name.is_empty() {
            return name;
        }
    }
    if let Ok(name) = std::env::var("HOSTNAME") {
        if !name.is_empty() {
            return name;
        }
    }
    "local".to_string()
}

/// `--inputs 0,1,2` -> the device channels that become tracks, in track order.
/// A channel is a 0-based device input; the track number is its position.
fn parse_inputs(raw: &str) -> Result<Vec<usize>, String> {
    if raw.trim().is_empty() {
        return Err("--inputs wants at least one input channel, e.g. 0,1".to_string());
    }
    raw.split(',')
        .map(|part| {
            part.trim().parse::<usize>().map_err(|_| {
                format!("--inputs wants input channels separated by commas, not `{raw}`")
            })
        })
        .collect()
}

/// `1:delay` -> `(Some(1), "delay")`; an unprefixed value -> `(None, value)`.
/// The track number is 1-based and matched against `--tracks`, so `1:` is the
/// first track whether the take has one or two. A colon that is not preceded by
/// digits is part of the value (`--pan -1` has none, and an insert name has no
/// colon today), so it is left alone.
fn split_target(raw: &str) -> (Option<usize>, &str) {
    if let Some((head, rest)) = raw.split_once(':') {
        if !head.is_empty() && head.bytes().all(|byte| byte.is_ascii_digit()) {
            if let Ok(track) = head.parse() {
                return (Some(track), rest);
            }
        }
    }
    (None, raw)
}

fn validate_block(frames: usize, buffer: usize) -> Result<(), String> {
    if frames == 0 {
        return Err("--period (or --frames) must be at least 1".to_string());
    }
    if buffer == 0 {
        return Err("--buffer must be at least 1".to_string());
    }
    if buffer < frames {
        return Err("--buffer must be at least one period (`--period`)".to_string());
    }
    Ok(())
}

fn validate_channels(options: &Options) -> Result<(), String> {
    if options.channels == 0 {
        return Err("--channels must be at least 1".to_string());
    }
    if options.channels > MAX_CHANNELS {
        return Err(format!(
            "--channels is {}; at most {MAX_CHANNELS} channels can be captured",
            options.channels
        ));
    }
    Ok(())
}

fn validate_run(options: &Options) -> Result<(), String> {
    validate_block(options.frames, options.buffer)?;
    if options.rate == 0 {
        return Err("--rate must be at least 1".to_string());
    }
    validate_channels(options)?;
    if options.seconds < 0.0 {
        return Err("--seconds cannot be negative".to_string());
    }
    Ok(())
}

fn run_device(options: &Options) -> Result<RunReport, String> {
    let device = options.backend.device_name(options.device.as_deref());
    match options.backend {
        BackendKind::Null => null_run(options),
        BackendKind::Alsa | BackendKind::PipeWire => alsa_run(&device, options),
        BackendKind::Jack => jack_run(&device, options),
    }
}

fn null_run(options: &Options) -> Result<RunReport, String> {
    let mut device = NullDevice::new(options.rate, options.frames, options.channels);
    if let Some(hz) = options.tone {
        device = device.with_tone(hz);
    }

    // Integer block count from a floating duration: round the frame total first,
    // so `--seconds 0.1` is exactly 75 blocks at 48 kHz / 64 frames rather than
    // 76 from a rounding error in 0.1.
    let total_frames = (options.seconds * options.rate as f64).round();
    let blocks = (total_frames / options.frames as f64) as usize;

    let mut block = vec![0.0f32; options.frames * options.channels];
    let mut loudest = 0.0f32;
    let mut samples = 0usize;
    for _ in 0..blocks {
        device
            .process(&mut block)
            .map_err(|error| format!("device: {error:?}"))?;
        loudest = loudest.max(peak(&block));
        samples += block.len();
    }

    Ok(RunReport {
        backend: "null",
        device: "null".to_string(),
        rate: options.rate,
        frames: options.frames,
        buffer: options.buffer,
        channels: options.channels,
        blocks,
        samples,
        peak: loudest,
        xruns: 0,
    })
}

#[cfg(feature = "alsa")]
fn alsa_run(device: &str, options: &Options) -> Result<RunReport, String> {
    let mut report = jawn_audio::alsa_device::run_playback(
        device,
        options.rate,
        options.frames,
        options.buffer,
        options.channels,
        options.seconds,
        options.tone,
    )?;
    // `alsa_run` also serves `--backend pipewire`, which opens the ALSA
    // `default` PCM; name the backend the caller asked for, not the library.
    report.backend = options.backend.name();
    Ok(report)
}

#[cfg(not(feature = "alsa"))]
fn alsa_run(device: &str, options: &Options) -> Result<RunReport, String> {
    let _ = (device, options);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

#[cfg(feature = "jack")]
fn jack_run(device: &str, options: &Options) -> Result<RunReport, String> {
    jawn_audio::jack_device::run_playback(
        device,
        options.rate,
        options.frames,
        options.buffer,
        options.seconds,
        options.tone,
    )
}

#[cfg(not(feature = "jack"))]
fn jack_run(device: &str, options: &Options) -> Result<RunReport, String> {
    let _ = (device, options);
    Err("this build has no JACK backend; rebuild with --features jack".to_string())
}

fn print_run(report: &RunReport, json: bool) {
    if json {
        println!(
            "{{\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"frames\":{},\"buffer\":{},\"channels\":{},\"blocks\":{},\"samples\":{},\"peak\":{:.6},\"xruns\":{}}}",
            loopback::json_escape(report.backend),
            loopback::json_escape(&report.device),
            report.rate,
            report.frames,
            report.buffer,
            report.channels,
            report.blocks,
            report.samples,
            report.peak,
            report.xruns
        );
    } else {
        println!(
            "device {} ({}): {} blocks of {} frames at {} Hz ({} samples), buffer {}, peak {:.4}, xruns {}",
            report.device,
            report.backend,
            report.blocks,
            report.frames,
            report.rate,
            report.samples,
            report.buffer,
            report.peak,
            report.xruns
        );
    }
}

fn run_loopback(options: &Options) -> Result<ExitCode, String> {
    validate_block(options.frames, options.buffer)?;
    if options.rate == 0 {
        return Err("--rate must be at least 1".to_string());
    }

    let device = options.backend.device_name(options.device.as_deref());
    let report = loopback::measure(
        options.backend,
        &device,
        options.rate,
        options.frames,
        options.buffer,
    );
    if options.json {
        println!("{}", report.to_json());
    } else {
        println!("{}", report.prose());
    }
    Ok(ExitCode::from(if report.ok { 0 } else { 1 }))
}

/// A receive that has nothing for us yet. `ConnectionRefused` arrives on a
/// connected UDP socket when the far end's port is closed — the master
/// restarted or stopped — and `ConnectionReset` the same way after an ICMP
/// error. Neither ends the run: the peer's quiet timer turns them into a
/// re-handshake once the master is back.
fn quiet_receive(error: &std::io::Error) -> bool {
    matches!(
        error.kind(),
        ErrorKind::WouldBlock
            | ErrorKind::TimedOut
            | ErrorKind::ConnectionRefused
            | ErrorKind::ConnectionReset
    )
}

fn run_clock_master(options: &Options) -> Result<ExitCode, String> {
    let key = session_key(options)?;
    let requested = options.bind.as_deref().unwrap_or(peer::DEFAULT_BIND);
    let socket = UdpSocket::bind(requested)
        .map_err(|error| format!("--clock-master cannot bind {requested}: {error}"))?;
    let bound = socket
        .local_addr()
        .map_err(|error| format!("clock master address: {error}"))?;
    socket
        .set_read_timeout(Some(Duration::from_millis(20)))
        .map_err(|error| format!("clock master timeout: {error}"))?;
    // The default port is ephemeral, so the human (or the peer's command line)
    // needs the bound address before this run ends.
    eprintln!("jawn-audio: clock master listening on {bound}");

    let clock = InstantClock::new(options.rate);
    let mut master =
        peer::ClockMaster::new(key).with_lease(Duration::from_millis(options.lease_ms));
    let duration = Duration::try_from_secs_f64(options.seconds)
        .map_err(|_| format!("--seconds is out of range: {}", options.seconds))?;
    let deadline = Instant::now()
        .checked_add(duration)
        .ok_or_else(|| format!("--seconds is out of range: {}", options.seconds))?;
    let mut incoming = [0u8; 2048];
    let mut outgoing = [0u8; 2048];
    let mut served = 0u64;
    while Instant::now() < deadline {
        match socket.recv_from(&mut incoming) {
            Ok((length, origin)) => {
                if let Some(answer) = master.answer(&incoming[..length], &clock, &mut outgoing) {
                    if socket.send_to(&outgoing[..answer.length()], origin).is_ok()
                        && answer.is_pong()
                    {
                        served += 1;
                    }
                }
            }
            Err(error) if quiet_receive(&error) => {}
            Err(error) => return Err(format!("clock master receive: {error}")),
        }
    }

    let report = ClockReport::master(
        bound.to_string(),
        options.rate,
        options.seconds,
        served,
        master.rejected(),
    );
    if options.json {
        println!("{}", report.to_json());
    } else {
        println!("{}", report.prose());
    }
    Ok(ExitCode::SUCCESS)
}

fn run_clock_peer(options: &Options) -> Result<ExitCode, String> {
    let key = session_key(options)?;
    let text = options
        .master
        .as_deref()
        .expect("--clock-peer validates --master");
    let master: SocketAddr = text
        .parse()
        .map_err(|_| format!("--master wants ip:port, not `{text}`"))?;
    let local = if master.is_ipv6() {
        if master.ip().is_loopback() {
            "[::1]:0"
        } else {
            "[::]:0"
        }
    } else if master.ip().is_loopback() {
        "127.0.0.1:0"
    } else {
        "0.0.0.0:0"
    };
    let socket = UdpSocket::bind(local)
        .map_err(|error| format!("--clock-peer cannot bind {local}: {error}"))?;
    socket
        .connect(master)
        .map_err(|error| format!("--clock-peer cannot reach {master}: {error}"))?;
    socket
        .set_read_timeout(Some(Duration::from_millis(options.pong_timeout_ms)))
        .map_err(|error| format!("clock peer timeout: {error}"))?;

    let clock = InstantClock::new(options.rate);
    let mut probe = peer::ClockPeer::new(key);
    let mut estimator = ClockEstimator::with_capacity(options.window, options.rate);
    let shared = peer::new_shared_estimate();
    let duration = Duration::try_from_secs_f64(options.seconds)
        .map_err(|_| format!("--seconds is out of range: {}", options.seconds))?;
    let deadline = Instant::now()
        .checked_add(duration)
        .ok_or_else(|| format!("--seconds is out of range: {}", options.seconds))?;
    let interval = Duration::from_millis(peer::PING_INTERVAL_MS);
    let mut outgoing = [0u8; 128];
    let mut incoming = [0u8; 2048];
    let mut sent = 0u64;
    let mut received = 0u64;
    let mut handshakes = 0u64;

    // The handshake precedes the first ping, and runs again whenever the master
    // has been quiet for `HANDSHAKE_TIMEOUT` (a restart issues a new session, so
    // the old one stops answering). If the run ends before a WELCOME arrives
    // there is no session to report, so say so rather than probing an open port
    // hopefully.
    if clock_handshake(&socket, &mut probe, deadline, &mut outgoing, &mut incoming)? {
        handshakes += 1;
    } else {
        let report = ClockReport::failure(
            "peer",
            master.to_string(),
            "no clock master answered the HELLO handshake",
        );
        if options.json {
            println!("{}", report.to_json());
        } else {
            println!("{}", report.prose());
        }
        return Ok(ExitCode::from(1));
    }

    while Instant::now() < deadline {
        let cycle = Instant::now();
        if probe.needs_handshake(Instant::now()) {
            probe.reset_session();
            if clock_handshake(&socket, &mut probe, deadline, &mut outgoing, &mut incoming)? {
                handshakes += 1;
            } else {
                break;
            }
        }
        let local_send = clock.now();
        let length = probe
            .ping(&mut outgoing, local_send, 0)
            .map_err(|error| format!("clock ping: {error:?}"))?;
        socket
            .send(&outgoing[..length])
            .map_err(|error| format!("clock peer send: {error}"))?;
        sent += 1;

        match socket.recv(&mut incoming) {
            Ok(length) => {
                let local_recv = clock.now();
                // `accept_pong` verifies the tag, the session, the echo and the
                // replay window before the sample reaches the estimator.
                if let Some(pong) = probe.accept_pong(&incoming[..length], local_send) {
                    let sample = ProbeSample::from_pong(pong, local_send, local_recv);
                    estimator.push(sample);
                    if let Some(estimate) = estimator.estimate() {
                        peer::publish_estimate(&shared, estimate);
                    }
                    received += 1;
                }
            }
            Err(error) if quiet_receive(&error) => {}
            Err(error) => return Err(format!("clock peer receive: {error}")),
        }

        let elapsed = cycle.elapsed();
        if elapsed < interval {
            thread::sleep(interval - elapsed);
        }
    }

    let estimate = estimator.estimate();
    let report = ClockReport::peer(
        master.to_string(),
        options.rate,
        options.seconds,
        sent,
        received,
        &estimator,
        estimate,
        probe.session(),
        handshakes,
        probe.rejected(),
    );
    if options.json {
        println!("{}", report.to_json());
    } else {
        println!("{}", report.prose());
    }
    Ok(ExitCode::SUCCESS)
}

/// Run the HELLO/WELCOME exchange until the master issues a session or the
/// deadline passes. The startup handshake and every re-handshake after the
/// master goes quiet share this, so they cannot drift apart. Returns whether a
/// session is held when it returns; a `false` means the deadline was reached
/// without a WELCOME.
fn clock_handshake(
    socket: &UdpSocket,
    probe: &mut peer::ClockPeer,
    deadline: Instant,
    outgoing: &mut [u8],
    incoming: &mut [u8],
) -> Result<bool, String> {
    while probe.session() == peer::CLOCK_SESSION && Instant::now() < deadline {
        let length = probe
            .hello(outgoing)
            .map_err(|error| format!("clock hello: {error:?}"))?;
        socket
            .send(&outgoing[..length])
            .map_err(|error| format!("clock peer send: {error}"))?;
        match socket.recv(incoming) {
            Ok(length) => {
                let _ = probe.accept_welcome(&incoming[..length]);
            }
            Err(error) if quiet_receive(&error) => {}
            Err(error) => return Err(format!("clock peer receive: {error}")),
        }
    }
    Ok(probe.session() != peer::CLOCK_SESSION)
}

fn run_serve(options: &Options) -> Result<ExitCode, String> {
    validate_serve(options)?;
    // A signal must take the same clean path as `quit`: the workers finish, the
    // output fades and drains, and the socket is unlinked. The C handler sets
    // SA_RESTART, so it cannot wake the server's `poll` by interrupting it; it
    // writes to a wake pipe that the server polls beside its own descriptors.
    let stop = signals::install();
    #[cfg(unix)]
    let wake = match signals::wake_pipe() {
        Ok(pipe) => Some(pipe),
        Err(error) => {
            eprintln!("jawn-audio: cannot make the signal wake pipe: {error}");
            None
        }
    };
    #[cfg(unix)]
    let wake_fd = {
        use std::os::unix::io::AsRawFd;
        wake.as_ref().map(|pipe| pipe.as_raw_fd())
    };
    #[cfg(not(unix))]
    let wake_fd = None;
    let socket = socket::default_path(options.socket.as_deref())?;
    let device = options.backend.device_name(options.device.as_deref());
    // Set the PipeWire target on the control thread, before the server spawns
    // its capture threads; the guard re-checks it rather than racing a
    // worker-thread `setenv`.
    if options.backend == BackendKind::PipeWire {
        if let Some(target) = options.device.as_deref() {
            std::env::set_var("PIPEWIRE_NODE", target);
        }
    }
    let plan = socket::default_plan_path(options.plan.as_deref());
    // The uplink share of the serve config. The key comes from the same flag
    // or environment the clock modes use; validation has already proved it.
    let uplink = match options.uplink.as_deref() {
        Some(address) => Some(jawn_audio::uplink::UplinkConfig {
            bind: address.parse().map_err(|_| {
                format!("--uplink wants an IP:PORT address, not `{address}`")
            })?,
            key: session_key(options)?,
        }),
        None => None,
    };
    // A server that cannot bind is a runtime failure, not a usage error: exit 1
    // tells a supervisor to try again, while 2 would mean the arguments are bad.
    let outcome = socket::serve(
        socket::Config {
            backend: options.backend,
            device,
            target: options.device.clone(),
            rate: options.rate,
            period: options.frames,
            buffer: options.buffer,
            channels: options.channels,
            socket,
            plan,
            machine: options.machine.clone(),
            system_device: options.system_device.clone(),
            handset_device: options.handset_device.clone(),
            uplink,
        },
        stop,
        wake_fd,
    );
    match outcome {
        Ok(code) => Ok(code),
        Err(error) => {
            eprintln!("jawn-audio: {error}");
            Ok(ExitCode::from(1))
        }
    }
}

/// One track's half of a take report.
struct TakeTrack {
    path: String,
    input: usize,
    frames: u64,
    dropped: u64,
}

/// The capture offset an overdub's monitor is started early by, and where the
/// number came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Alignment {
    /// Samples of round trip the monitor starts before the take's stamp.
    pub samples: u64,
    /// `measured`, `given` or `none`; a guess is never one of them.
    pub from: &'static str,
}

impl Alignment {
    pub(crate) fn none() -> Self {
        Alignment {
            samples: 0,
            from: "none",
        }
    }

    pub(crate) fn given(samples: u64) -> Self {
        Alignment {
            samples,
            from: "given",
        }
    }

    /// What the command line already knows without measuring: an explicit
    /// `--align-samples`, else none. `--calibrate` is resolved later, once the
    /// device is known.
    fn hint(options: &Options) -> Self {
        match options.align_samples {
            Some(samples) => Alignment::given(samples),
            None => Alignment::none(),
        }
    }
}

/// The `align_samples`/`align_from` pair every take status carries.
pub(crate) fn alignment_json(align: Alignment) -> String {
    format!(
        ",\"align_samples\":{},\"align_from\":\"{}\"",
        align.samples, align.from
    )
}

/// Resolve the take's capture offset. An explicit number is a measurement the
/// caller already made (or chose by hand) and wins; otherwise `calibrate` runs
/// the patch-cable loopback once and uses its samples. A failed or zero
/// measurement is not shifted by: it reports `none`.
///
/// The null backend has no signal path, so calibration there returns
/// `LoopbackReport::null` (zero samples) and this reports `none` — a
/// deterministic refusal to invent a number, not a fake measurement.
pub(crate) fn resolve_alignment(
    backend: BackendKind,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    given: Option<u64>,
    calibrate: bool,
) -> Alignment {
    if let Some(samples) = given {
        return Alignment::given(samples);
    }
    if !calibrate {
        return Alignment::none();
    }
    let report = loopback::measure(backend, device, rate, period, buffer);
    match report.samples {
        Some(samples) if report.ok && samples > 0 => Alignment {
            samples,
            from: "measured",
        },
        _ => Alignment::none(),
    }
}

/// What one `--record` produced, in the exact key order the JSON contract
/// names. A failed take keeps the same shape with `frames` and `dropped` at
/// zero, so a caller parses one struct either way.
struct TakeReport {
    ok: bool,
    path: String,
    backend: &'static str,
    device: String,
    rate: u32,
    frames: u64,
    dropped: u64,
    channels: usize,
    start_sample: u64,
    xruns: usize,
    inserts: String,
    tracks: Vec<TakeTrack>,
    /// How many monitor files played while this take recorded (0 = no
    /// overdub), how far the player got, and why it stopped early, if it did.
    monitor_files: usize,
    monitor_frames: u64,
    monitor_error: String,
    /// The capture offset applied to the monitor, and where it came from.
    align: Alignment,
    error: String,
}

impl TakeReport {
    fn success(
        tracks: Vec<TakeTrack>,
        backend: &'static str,
        device: String,
        rate: u32,
        channels: usize,
        start_sample: u64,
        xruns: usize,
        inserts: String,
        monitor_files: usize,
        monitor_frames: u64,
        monitor_error: String,
        align: Alignment,
    ) -> Self {
        // The top-level fields describe track 1, as they did before a take
        // could carry more than one; the `tracks` array carries the rest.
        let path = tracks.first().map(|track| track.path.clone()).unwrap_or_default();
        let frames = tracks.first().map(|track| track.frames).unwrap_or(0);
        let dropped = tracks.first().map(|track| track.dropped).unwrap_or(0);
        TakeReport {
            ok: true,
            path,
            backend,
            device,
            rate,
            frames,
            dropped,
            channels,
            start_sample,
            xruns,
            inserts,
            tracks,
            monitor_files,
            monitor_frames,
            monitor_error,
            align,
            error: String::new(),
        }
    }

    fn failure(
        path: String,
        backend: &'static str,
        device: String,
        rate: u32,
        channels: usize,
        start_sample: u64,
        inserts: String,
        align: Alignment,
        error: String,
    ) -> Self {
        TakeReport {
            ok: false,
            path,
            backend,
            device,
            rate,
            frames: 0,
            dropped: 0,
            channels,
            start_sample,
            xruns: 0,
            inserts,
            tracks: Vec::new(),
            monitor_files: 0,
            monitor_frames: 0,
            monitor_error: String::new(),
            align,
            error,
        }
    }

    fn to_json(&self) -> String {
        // A one-track take keeps the historical line exactly; only a take with
        // more than one track adds the array.
        let tracks = if self.tracks.len() > 1 {
            let entries: Vec<String> = self
                .tracks
                .iter()
                .map(|track| {
                    format!(
                        "{{\"path\":\"{}\",\"input\":{},\"frames\":{},\"dropped\":{}}}",
                        loopback::json_escape(&track.path),
                        track.input,
                        track.frames,
                        track.dropped
                    )
                })
                .collect();
            format!(",\"tracks\":[{}]", entries.join(","))
        } else {
            String::new()
        };
        let monitor = if self.monitor_files > 0 {
            let mut part = format!(
                ",\"playing\":{},\"monitor_frames\":{}",
                self.monitor_files, self.monitor_frames
            );
            if !self.monitor_error.is_empty() {
                part.push_str(&format!(
                    ",\"monitor_error\":\"{}\"",
                    loopback::json_escape(&self.monitor_error)
                ));
            }
            part
        } else {
            String::new()
        };
        let alignment = format!(
            ",\"align_samples\":{},\"align_from\":\"{}\"",
            self.align.samples, self.align.from
        );
        format!(
            "{{\"ok\":{},\"path\":\"{}\",\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"frames\":{},\"dropped\":{},\"channels\":{},\"start_sample\":{},\"xruns\":{},\"inserts\":\"{}\"{}{}{},\"error\":\"{}\"}}",
            self.ok,
            loopback::json_escape(&self.path),
            loopback::json_escape(self.backend),
            loopback::json_escape(&self.device),
            self.rate,
            self.frames,
            self.dropped,
            self.channels,
            self.start_sample,
            self.xruns,
            loopback::json_escape(&self.inserts),
            tracks,
            monitor,
            alignment,
            loopback::json_escape(&self.error)
        )
    }

    fn prose(&self) -> String {
        let seconds = if self.rate == 0 {
            0.0
        } else {
            self.frames as f64 / self.rate as f64
        };
        let inserts = if self.inserts.is_empty() {
            "none"
        } else {
            self.inserts.as_str()
        };
        let tracks = if self.tracks.len() > 1 {
            format!(
                ", {} tracks: {}",
                self.tracks.len(),
                self.tracks
                    .iter()
                    .map(|track| track.path.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        } else {
            String::new()
        };
        let monitor = if self.monitor_files > 0 {
            match self.monitor_error.is_empty() {
                true => format!(
                    ", monitoring {} file(s) ({} frames)",
                    self.monitor_files, self.monitor_frames
                ),
                false => format!(
                    ", monitoring {} file(s) ({} frames, {}), the take is complete",
                    self.monitor_files, self.monitor_frames, self.monitor_error
                ),
            }
        } else {
            String::new()
        };
        format!(
            "take {}: {} frames at {} Hz, {} channels ({:.3} s), backend {}, device {}, start_sample {}, dropped {}, xruns {}, inserts {}{}{}, alignment {} samples ({})",
            self.path,
            self.frames,
            self.rate,
            self.channels,
            seconds,
            self.backend,
            self.device,
            self.start_sample,
            self.dropped,
            self.xruns,
            inserts,
            tracks,
            monitor,
            self.align.samples,
            self.align.from
        )
    }
}

fn validate_record(options: &Options) -> Result<(), String> {
    if options.out.is_none() {
        return Err("--record needs --out FILE.wav".to_string());
    }
    validate_block(options.frames, options.buffer)?;
    if options.rate == 0 {
        return Err("--rate must be at least 1".to_string());
    }
    validate_channels(options)?;
    if options.tracks == 0 {
        return Err("--tracks must be at least 1".to_string());
    }
    if options.tracks > MAX_TRACKS {
        return Err(format!(
            "--tracks is {}; at most {MAX_TRACKS} tracks can be recorded at once",
            options.tracks
        ));
    }
    if options.tracks > options.channels {
        return Err(format!(
            "--tracks {} needs at least {} input channels, but --channels is {}: an interface records one track per input channel",
            options.tracks, options.tracks, options.channels
        ));
    }
    if options.inputs_given && options.input_given {
        return Err("--inputs chooses the take's channels; --channel picks one input, so pass one of them".to_string());
    }
    if options.tracks > 1 && options.input_given {
        return Err("--channel picks one input; --tracks N records N inputs".to_string());
    }
    if options.input_given && options.input >= options.channels {
        return Err(format!(
            "--channel {} is outside the {}-channel device",
            options.input, options.channels
        ));
    }
    if options.inputs_given {
        if options.inputs.len() != options.tracks {
            return Err(format!(
                "--inputs names {} input channel(s) but --tracks is {}: a take has one input per track",
                options.inputs.len(),
                options.tracks
            ));
        }
        for (index, input) in options.inputs.iter().enumerate() {
            if *input >= options.channels {
                return Err(format!(
                    "track {} records input {input}, but the device has only {} channel(s): pass a smaller --inputs or a larger --channels",
                    index + 1,
                    options.channels
                ));
            }
        }
    }
    if options.seconds < 0.0 {
        return Err("--seconds cannot be negative".to_string());
    }
    validate_channel(options)?;
    validate_targets(options)?;
    validate_monitor(options)?;
    Ok(())
}

/// The monitor's own knobs: 1-based file numbers in the monitor's order, and
/// no knob without a file to apply it to. Checked after `--record --play`
/// has merged `--file` into the monitor, so the numbering is final.
fn validate_monitor(options: &Options) -> Result<(), String> {
    let files = options.monitor.len();
    if files == 0 {
        if options.monitor_gain != 1.0
            || options.monitor_pan != 0.0
            || !options.monitor_gains.is_empty()
            || !options.monitor_pans.is_empty()
            || !options.monitor_inserts.is_empty()
        {
            return Err(
                "--monitor-gain, --monitor-pan and --monitor-insert need a --monitor-file"
                    .to_string(),
            );
        }
        return Ok(());
    }
    if !options.monitor_gain.is_finite()
        || options.monitor_gains.iter().any(|(_, gain)| !gain.is_finite())
    {
        return Err("--monitor-gain must be a finite number".to_string());
    }
    if !options.monitor_pan.is_finite()
        || options.monitor_pans.iter().any(|(_, pan)| !pan.is_finite())
    {
        return Err("--monitor-pan must be a finite number".to_string());
    }
    let in_range = |file: usize| file >= 1 && file <= files;
    for spec in &options.monitor_inserts {
        if let Some(file) = spec.track {
            if !in_range(file) {
                return Err(format!(
                    "--monitor-insert names file {file}, but the monitor has {files} file(s) (1..={files})"
                ));
            }
        }
    }
    for (flag, files_named) in [
        ("--monitor-gain", &options.monitor_gains),
        ("--monitor-pan", &options.monitor_pans),
    ] {
        for (file, _) in files_named {
            if !in_range(*file) {
                return Err(format!(
                    "{flag} names file {file}, but the monitor has {files} file(s) (1..={files})"
                ));
            }
        }
    }
    Ok(())
}

fn validate_channel(options: &Options) -> Result<(), String> {
    if !options.gain.is_finite() || options.gains.iter().any(|(_, gain)| !gain.is_finite()) {
        return Err("--gain must be a finite number".to_string());
    }
    if !options.pan.is_finite() || options.pans.iter().any(|(_, pan)| !pan.is_finite()) {
        return Err("--pan must be a finite number".to_string());
    }
    Ok(())
}

/// A `N:` prefix names a track the take has. Checked after all arguments are
/// read, because `--tracks` may come after the knob it applies to.
fn validate_targets(options: &Options) -> Result<(), String> {
    let track_in_range = |track: usize| track >= 1 && track <= options.tracks;
    for spec in &options.inserts {
        if let Some(track) = spec.track {
            if !track_in_range(track) {
                return Err(format!(
                    "--insert names track {track}, but a {}-track take has tracks 1..={}",
                    options.tracks, options.tracks
                ));
            }
        }
    }
    for (flag, tracks) in [("--gain", &options.gains), ("--pan", &options.pans)] {
        for (track, _) in tracks {
            if !track_in_range(*track) {
                return Err(format!(
                    "{flag} names track {track}, but a {}-track take has tracks 1..={}",
                    options.tracks, options.tracks
                ));
            }
        }
    }
    Ok(())
}

/// One track's gain: a `N:value` for this track overrides the unprefixed value.
fn track_gain(options: &Options, track: usize) -> f32 {
    options
        .gains
        .iter()
        .rev()
        .find(|(number, _)| *number == track)
        .map(|(_, gain)| *gain)
        .unwrap_or(options.gain)
}

fn track_pan(options: &Options, track: usize) -> f32 {
    options
        .pans
        .iter()
        .rev()
        .find(|(number, _)| *number == track)
        .map(|(_, pan)| *pan)
        .unwrap_or(options.pan)
}

/// The take's `track` (1-based) channel: trim, the inserts that apply to it in
/// the order they were given, pan.
fn channel_for(options: &Options, track: usize) -> Channel {
    let mut channel = Channel::new(track_gain(options, track), track_pan(options, track).clamp(-1.0, 1.0));
    for spec in &options.inserts {
        if spec.track.is_none() || spec.track == Some(track) {
            channel.push(spec.kind.build());
        }
    }
    channel
}

/// The chain order for one track's report, e.g. `tone,distortion` or an empty
/// string when that track was a wire.
fn insert_list(options: &Options, track: usize) -> String {
    options
        .inserts
        .iter()
        .filter(|spec| spec.track.is_none() || spec.track == Some(track))
        .map(|spec| spec.kind.name())
        .collect::<Vec<_>>()
        .join(",")
}

/// One monitor file's gain: an `N:value` for this file overrides the
/// unprefixed value, exactly as a take's track knobs do.
fn monitor_gain_for(options: &Options, file: usize) -> f32 {
    options
        .monitor_gains
        .iter()
        .rev()
        .find(|(number, _)| *number == file)
        .map(|(_, gain)| Channel::clamp_gain(*gain))
        .unwrap_or_else(|| Channel::clamp_gain(options.monitor_gain))
}

fn monitor_pan_for(options: &Options, file: usize) -> f32 {
    options
        .monitor_pans
        .iter()
        .rev()
        .find(|(number, _)| *number == file)
        .map(|(_, pan)| Channel::clamp_pan(*pan))
        .unwrap_or_else(|| Channel::clamp_pan(options.monitor_pan))
}

fn monitor_inserts_for(options: &Options, file: usize) -> Vec<InsertKind> {
    options
        .monitor_inserts
        .iter()
        .filter(|spec| spec.track.is_none() || spec.track == Some(file))
        .map(|spec| spec.kind)
        .collect()
}

/// The monitor files and the strip each plays through, in the order given.
fn monitor_specs(options: &Options) -> Vec<MonitorSpec> {
    options
        .monitor
        .iter()
        .enumerate()
        .map(|(index, path)| {
            let file = index + 1;
            MonitorSpec {
                path: path.clone(),
                gain: monitor_gain_for(options, file),
                pan: monitor_pan_for(options, file),
                inserts: monitor_inserts_for(options, file),
            }
        })
        .collect()
}

/// One output file and the input that feeds it.
struct TrackPlan {
    path: String,
    input: usize,
    label: String,
}

/// The take's files. A one-track take writes exactly `--out`, as it always
/// did. A multi-track take splits the stem: `take.wav` becomes `take-ch1.wav`,
/// `take-ch2.wav`, ..., in the same directory (or relative to the same cwd).
pub(crate) fn take_paths(out: &str, tracks: usize) -> Result<Vec<String>, String> {
    if tracks <= 1 {
        return Ok(vec![out.to_string()]);
    }
    let source = Path::new(out);
    let stem = source
        .file_stem()
        .ok_or_else(|| format!("--out {out} needs a file name to derive per-track takes"))?;
    let stem = stem.to_string_lossy();
    let parent: PathBuf = match source.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
        _ => PathBuf::new(),
    };
    let mut paths = Vec::with_capacity(tracks);
    for track in 1..=tracks {
        let path = parent.join(format!("{stem}-ch{track}.wav"));
        paths.push(path.to_string_lossy().into_owned());
    }
    Ok(paths)
}

/// The device input behind each positional track: `--inputs` in the order it
/// was given, or a one-track `--channel`, or `0..tracks` by default.
fn take_inputs(options: &Options) -> Vec<usize> {
    if options.inputs_given {
        options.inputs.clone()
    } else if options.tracks == 1 {
        vec![options.input]
    } else {
        (0..options.tracks).collect()
    }
}

fn track_plans(options: &Options, out: &str) -> Result<Vec<TrackPlan>, String> {
    let paths = take_paths(out, options.tracks)?;
    Ok(paths
        .into_iter()
        .zip(take_inputs(options))
        .enumerate()
        .map(|(index, (path, input))| TrackPlan {
            path,
            input,
            label: format!("ch{}", index + 1),
        })
        .collect())
}

/// The path a failed take reports in its top-level field: track 1's file.
fn first_track_path(options: &Options, out: &str) -> String {
    track_plans(options, out)
        .ok()
        .and_then(|plans| plans.into_iter().next().map(|plan| plan.path))
        .unwrap_or_else(|| out.to_string())
}

/// What one `--play` produced. The key order is the JSON contract; a failed
/// playback keeps the same shape so a caller parses one struct either way.
struct PlayReport {
    ok: bool,
    backend: &'static str,
    files: usize,
    frames: u64,
    rate: u32,
    seconds: f64,
    xruns: usize,
    error: String,
}

impl PlayReport {
    fn success(backend: &'static str, files: usize, frames: u64, rate: u32, xruns: usize) -> Self {
        let seconds = if rate == 0 {
            0.0
        } else {
            frames as f64 / f64::from(rate)
        };
        PlayReport {
            ok: true,
            backend,
            files,
            frames,
            rate,
            seconds,
            xruns,
            error: String::new(),
        }
    }

    /// A playback that never started has no rate and no frames; the file count
    /// is still what the caller asked for, so the line is recognisably about
    /// that request.
    fn failure(backend: &'static str, files: usize, error: String) -> Self {
        PlayReport {
            ok: false,
            backend,
            files,
            frames: 0,
            rate: 0,
            seconds: 0.0,
            xruns: 0,
            error,
        }
    }

    fn to_json(&self) -> String {
        format!(
            "{{\"ok\":{},\"backend\":\"{}\",\"files\":{},\"frames\":{},\"rate\":{},\"seconds\":{:.3},\"xruns\":{},\"error\":\"{}\"}}",
            self.ok,
            loopback::json_escape(self.backend),
            self.files,
            self.frames,
            self.rate,
            self.seconds,
            self.xruns,
            loopback::json_escape(&self.error)
        )
    }
}

fn run_play(options: &Options) -> Result<ExitCode, String> {
    validate_play(options)?;
    // `--play` has one output contract: the JSON line, success or failure. A
    // caller that arms a playback is a program, not a person reading prose.
    match play_files(options) {
        Ok(report) => {
            println!("{}", report.to_json());
            Ok(ExitCode::SUCCESS)
        }
        Err(error) => {
            let report = PlayReport::failure(options.backend.name(), options.files.len(), error);
            println!("{}", report.to_json());
            Ok(ExitCode::from(1))
        }
    }
}

fn validate_play(options: &Options) -> Result<(), String> {
    if options.files.is_empty() {
        return Err("--play needs at least one --file FILE.wav".to_string());
    }
    validate_block(options.frames, options.buffer)?;
    validate_channel(options)?;
    if options.seconds < 0.0 {
        return Err("--seconds cannot be negative".to_string());
    }
    // A `N:` prefix is 1-based and ranges over the files, exactly as it ranges
    // over a take's tracks in `--record`.
    let files = options.files.len();
    for spec in &options.inserts {
        if let Some(file) = spec.track {
            if file < 1 || file > files {
                return Err(format!(
                    "--insert names file {file}, but --play has {files} file(s) (1..={files})"
                ));
            }
        }
    }
    for (flag, targets) in [("--gain", &options.gains), ("--pan", &options.pans)] {
        for (file, _) in targets {
            if *file < 1 || *file > files {
                return Err(format!(
                    "{flag} names file {file}, but --play has {files} file(s) (1..={files})"
                ));
            }
        }
    }
    Ok(())
}

/// The inserts that apply to one 1-based file, in chain order.
fn inserts_for(options: &Options, file: usize) -> Vec<InsertKind> {
    options
        .inserts
        .iter()
        .filter(|spec| spec.track.is_none() || spec.track == Some(file))
        .map(|spec| spec.kind)
        .collect()
}

/// `--listen`'s inserts. One strip, so an `N:` prefix cannot name anything.
fn listen_inserts(options: &Options) -> Result<Vec<InsertKind>, String> {
    let mut inserts = Vec::with_capacity(options.inserts.len());
    for spec in &options.inserts {
        if spec.track.is_some() {
            return Err("--listen has one strip; --insert cannot name a track".to_string());
        }
        inserts.push(spec.kind);
    }
    Ok(inserts)
}

fn validate_listen(options: &Options) -> Result<Vec<InsertKind>, String> {
    validate_block(options.frames, options.buffer)?;
    if options.rate == 0 {
        return Err("--rate must be at least 1".to_string());
    }
    validate_channels(options)?;
    if options.seconds < 0.0 {
        return Err("--seconds cannot be negative".to_string());
    }
    if options.input >= options.channels {
        return Err(format!(
            "--channel {} is outside the {}-channel device",
            options.input, options.channels
        ));
    }
    listen_inserts(options)
}

/// `--listen`: one input through one strip to the outputs, until `--seconds`
/// or a signal. It always prints its JSON line, success or failure, exactly as
/// `--play` does.
fn run_listen(options: &Options) -> Result<ExitCode, String> {
    let inserts = validate_listen(options)?;
    let device = options.backend.device_name(options.device.as_deref());
    let plan = ListenPlan {
        channel: options.input,
        gain: Channel::clamp_gain(options.gain),
        pan: Channel::clamp_pan(options.pan),
        inserts,
    };
    let stop = signals::install();
    let total = if options.seconds_given {
        Some(take_frames(options.seconds, options.rate))
    } else {
        None
    };
    match listen_run(options, &device, &plan, total, stop) {
        Ok(run) => {
            let report = ListenReport::success(
                options.backend.name(),
                device,
                plan.channel,
                run.frames,
                run.rate,
                run.xruns,
            );
            println!("{}", report.to_json());
            Ok(ExitCode::SUCCESS)
        }
        Err(error) => {
            let report = ListenReport::failure(
                options.backend.name(),
                device,
                plan.channel,
                options.rate,
                error,
            );
            println!("{}", report.to_json());
            Ok(ExitCode::from(1))
        }
    }
}

fn listen_run(
    options: &Options,
    device: &str,
    plan: &ListenPlan,
    total: Option<u64>,
    stop: &AtomicBool,
) -> Result<listen::ListenRun, String> {
    let mut strip = ListenStrip::new(plan.channel, plan.gain, plan.pan, &plan.inserts, None);
    match options.backend {
        BackendKind::Null => listen::run_null(
            &mut strip,
            options.rate,
            options.frames,
            options.channels,
            total,
            options.tone,
            stop,
            |_| {},
        ),
        BackendKind::Alsa | BackendKind::PipeWire => {
            listen_alsa(device, options, &mut strip, total, stop)
        }
        BackendKind::Jack => Err(listen_support_message()),
    }
}

#[cfg(feature = "alsa")]
fn listen_alsa(
    device: &str,
    options: &Options,
    strip: &mut ListenStrip,
    total: Option<u64>,
    stop: &AtomicBool,
) -> Result<listen::ListenRun, String> {
    // The system mix is the machine's own audio. On ALSA the engine owns the
    // card; on the shared PipeWire backend it plays the output the mix
    // replaced, so it captures the sink either way.
    let system_device = if owns_system_mix(options.backend) {
        options.system_device.as_deref()
    } else {
        None
    };
    let (mut capture, mut system) = match system_device {
        Some(source) => match crate::system_capture::SystemCapture::start(source, options.rate) {
            Ok((capture, consumer)) => (Some(capture), Some(consumer)),
            Err(error) => {
                eprintln!("jawn-audio: system mix: {error}");
                (None, None)
            }
        },
        None => (None, None),
    };
    	let sink = CliListenSink { strip, channels: 0 };
    	let guard = match (&capture, options.backend) {
    		(Some(_), BackendKind::PipeWire) => Some(
    			jawn_audio::pipewire_guard::PlaybackGuard::new(
    				options.device.as_deref(),
    				system_device.unwrap_or(""),
    			)?,
    		),
    		_ => None,
    	};
    	let run = jawn_audio::alsa_device::run_listen_with_system(
    		device,
    		options.rate,
    		options.frames,
    		options.buffer,
    		options.channels,
    		total,
    		stop,
    		sink,
    		system.as_mut(),
    		guard.as_ref(),
    	);
    if let Some(capture) = capture.as_mut() {
        capture.stop();
    }
    run
}

#[cfg(not(feature = "alsa"))]
fn listen_alsa(
    device: &str,
    options: &Options,
    strip: &mut ListenStrip,
    total: Option<u64>,
    stop: &AtomicBool,
) -> Result<listen::ListenRun, String> {
    let _ = (device, options, strip, total, stop);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

/// What a patch run produced, in the shape the report needs.
struct PatchRun {
    frames: u64,
    rate: u32,
    xruns: usize,
}

fn run_patch(options: &Options) -> Result<ExitCode, String> {
    let path = options
        .plan
        .as_ref()
        .ok_or_else(|| "--patch needs --plan FILE".to_string())?;
    let device = options.backend.device_name(options.device.as_deref());
    // A plan the caller named is runtime input, like a monitor WAV: a missing
    // file or a malformed plan is one report line and exit 1, not a usage error.
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) => {
            return Ok(patch_failure(
                options.backend.name(),
                &device,
                &format!("cannot read the plan {path}: {error}"),
                options.json,
            ))
        }
    };
    let object = match socket::parse_object(text.trim()) {
        Ok(object) => object,
        Err(error) => {
            return Ok(patch_failure(
                options.backend.name(),
                &device,
                &format!("{path}: {error}"),
                options.json,
            ))
        }
    };
    let mut patchbay =
        match patchbay::Patchbay::from_object(&object, options.channels, &options.machine) {
        Ok(patchbay) => patchbay,
        Err(error) => {
            return Ok(patch_failure(
                options.backend.name(),
                &device,
                &format!("{path}: {error}"),
                options.json,
            ))
        }
    };
    // The reception mixer's screened call is a second capture, started only
    // when the plan declares a `handset` source. A sink this machine does not
    // offer is reported silent; the rest of the patch still runs.
    let handset = attach_patch_handset(options, &mut patchbay);
    // The summary is taken before the ALSA arm moves the graph to the device
    // loop, and it is what the report says either way.
    let summary = patchbay.summary().clone();
    let stop = signals::install();
    let total = if options.seconds_given {
        Some(take_frames(options.seconds, options.rate))
    } else {
        None
    };

    let outcome = match options.backend {
        BackendKind::Null => patchbay::run_null(
            &mut patchbay,
            options.rate,
            options.frames,
            options.channels,
            total,
            options.tone,
            &stop,
            |_| {},
        )
        .map(|frames| PatchRun {
            frames,
            rate: options.rate,
            xruns: 0,
        }),
        BackendKind::Alsa | BackendKind::PipeWire => {
            patch_alsa(&device, options, patchbay, total, &stop)
        }
        BackendKind::Jack => Err(listen_support_message()),
    };

    // Stop the handset capture with the patch; the consumer moved into the
    // graph, so the process handle is all that is left here.
    if let Some(mut capture) = handset {
        capture.stop();
    }

    match outcome {
        Ok(run) => {
            if options.json {
                println!(
                    "{{\"ok\":true,\"state\":\"done\",\"backend\":\"{}\",\"device\":\"{}\",\"frames\":{},\"rate\":{},\"xruns\":{},{}}}",
                    options.backend.name(),
                    jawn_audio::loopback::json_escape(&device),
                    run.frames,
                    run.rate,
                    run.xruns,
                    summary.json()
                );
            }
            else {
                println!(
                    "patched {} ({}, {}) at {} Hz: {} frames, {} xrun(s); {} source(s), {} bus(es), {} sink(s), {} route(s)",
                    options.backend.name(),
                    device,
                    summary.mode,
                    run.rate,
                    run.frames,
                    run.xruns,
                    summary.sources,
                    summary.buses,
                    summary.sinks,
                    summary.routes
                );
                if !summary.silent.is_empty() {
                    println!(
                        "note: declared here but not bindable on this machine: {}",
                        summary.silent.join(", ")
                    );
                }
            }
            Ok(ExitCode::SUCCESS)
        }
        Err(error) => {
            if options.json {
                println!(
                    "{{\"ok\":false,\"state\":\"failed\",\"backend\":\"{}\",\"device\":\"{}\",\"error\":\"{}\",{}}}",
                    options.backend.name(),
                    jawn_audio::loopback::json_escape(&device),
                    jawn_audio::loopback::json_escape(&error),
                    summary.json()
                );
            }
            else {
                eprintln!("jawn-audio: patch: {error}");
            }
            Ok(ExitCode::from(1))
        }
    }
}

fn patch_failure(backend: &str, device: &str, error: &str, json: bool) -> ExitCode {
    if json {
        println!(
            "{{\"ok\":false,\"state\":\"failed\",\"backend\":\"{}\",\"device\":\"{}\",\"error\":\"{}\"}}",
            backend,
            jawn_audio::loopback::json_escape(device),
            jawn_audio::loopback::json_escape(error)
        );
    }
    else {
        eprintln!("jawn-audio: patch: {error}");
    }
    ExitCode::from(1)
}

/// Start the reception mixer's screened-call capture when the plan declares a
/// `handset` source. No handset in the plan means no extra `parec`. A sink the
/// server does not offer (or a capture that cannot start) is a silent node,
/// not a failed patch.
fn attach_patch_handset(
    options: &Options,
    patchbay: &mut patchbay::Patchbay,
) -> Option<crate::system_capture::SystemCapture> {
    if !patchbay.wants_handset() {
        return None;
    }
    if !matches!(options.backend, BackendKind::Alsa | BackendKind::PipeWire) {
        patchbay.silence_handset();
        return None;
    }
    let Some(source) = options.handset_device.as_deref() else {
        patchbay.silence_handset();
        return None;
    };
    if crate::system_capture::source_exists(source) == Some(false) {
        patchbay.silence_handset();
        return None;
    }
    match crate::system_capture::SystemCapture::start(source, options.rate) {
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

#[cfg(feature = "alsa")]
fn patch_alsa(
    device: &str,
    options: &Options,
    mut patchbay: patchbay::Patchbay,
    total: Option<u64>,
    stop: &AtomicBool,
) -> Result<PatchRun, String> {
    // The manager names the virtual sink's monitor; the engine plays the
    // output the mix replaced, so capturing the sink is not a loop. A plan that
    // wants no system audio simply has no source here.
    let system_source = if owns_system_mix(options.backend) {
        options.system_device.as_deref()
    } else {
        None
    };
    // A PipeWire pass that plays through `default` would play into the sink it
    // captures. Refuse a target it does not have rather than fall back.
    let guard = match system_source {
        Some(source) if options.backend == BackendKind::PipeWire => Some(
            jawn_audio::pipewire_guard::PlaybackGuard::new(options.device.as_deref(), source)?,
        ),
        _ => None,
    };
    let (mut capture, mut system) = match system_source {
        Some(source) => match crate::system_capture::SystemCapture::start(source, options.rate) {
            Ok((capture, consumer)) => (Some(capture), Some(consumer)),
            Err(error) => {
                eprintln!("jawn-audio: system mix: {error}");
                (None, None)
            }
        },
        None => (None, None),
    };
    // On PipeWire each routed local input gets its own capture: the loop plays
    // out the node the mix replaced and never opens the card for capture. On
    // ALSA the same channel arrives in the duplex loop below, so no second
    // process runs.
    let streams = patchbay.stream_plan(options.backend);
    let mut input_captures = Vec::new();
    for input in &streams.inputs {
        let node = input
            .node
            .as_deref()
            .unwrap_or(crate::system_capture::DEFAULT_INPUT);
        match crate::system_capture::SystemCapture::start_channel(
            node,
            options.rate,
            input.channel,
            options.channels,
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
    let run = if streams.card_capture {
        // A routed local input reads a card channel, so the loop is duplex.
        jawn_audio::alsa_device::run_listen_with_system(
            device,
            options.rate,
            options.frames,
            options.buffer,
            options.channels,
            total,
            stop,
            patchbay,
            system.as_mut(),
            None,
        )?
    } else {
        // Nothing reads the card: open only the output and leave the capture
        // to PipeWire, so the microphone and its privacy indicator stay off.
        jawn_audio::alsa_device::run_playback_with_system(
            device,
            options.rate,
            options.frames,
            options.buffer,
            options.channels,
            total,
            stop,
            patchbay,
            system.as_mut(),
            guard.as_ref(),
        )?
    };
    for mut capture in input_captures {
        capture.stop();
    }
    if let Some(capture) = capture.as_mut() {
        capture.stop();
    }
    Ok(PatchRun {
        frames: run.frames,
        rate: run.rate,
        xruns: run.xruns,
    })
}

#[cfg(not(feature = "alsa"))]
fn patch_alsa(
    device: &str,
    options: &Options,
    patchbay: patchbay::Patchbay,
    total: Option<u64>,
    stop: &AtomicBool,
) -> Result<PatchRun, String> {
    let _ = (device, options, patchbay, total, stop);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

#[cfg(feature = "alsa")]
struct CliListenSink<'a> {
    strip: &'a mut ListenStrip,
    /// Device channels per frame, learned in `prepared`.
    channels: usize,
}

#[cfg(feature = "alsa")]
impl listen::ListenSink for CliListenSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        self.channels = channels;
        self.strip.prepare(rate, period);
        Ok(())
    }

    fn block(&mut self, input: &[i16], output: &mut [i16]) -> Result<(), String> {
        self.strip.process_i16(input, self.channels, output)?;
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
        Ok(())
    }
}

fn play_files(options: &Options) -> Result<PlayReport, String> {
    let mut tracks = Vec::with_capacity(options.files.len());
    for (index, path) in options.files.iter().enumerate() {
        let file = index + 1;
        tracks.push(PlayTrack::from_wav(
            path.clone(),
            track_gain(options, file),
            track_pan(options, file),
            inserts_for(options, file),
        )?);
    }
    let mut playback = Playback::new(tracks, options.start_at)?;
    let rate = playback.rate();
    if options.seconds_given {
        playback.limit(take_frames(options.seconds, rate));
    }
    let device = options.backend.device_name(options.device.as_deref());
    let (frames, xruns) = match options.backend {
        BackendKind::Null => play_null(&mut playback, options)?,
        BackendKind::Alsa | BackendKind::PipeWire => play_alsa(&device, &mut playback, options)?,
        BackendKind::Jack => return Err(play_support_message()),
    };
    Ok(PlayReport::success(
        options.backend.name(),
        options.files.len(),
        frames,
        rate,
        xruns,
    ))
}

/// The null backend has no card to pace it, so it renders every block as fast
/// as the CPU will and reports what it rendered.
fn play_null(playback: &mut Playback, options: &Options) -> Result<(u64, usize), String> {
    playback.prepare(playback.rate(), options.frames)?;
    let mut out = vec![0.0f32; options.frames * 2];
    while playback.remaining() > 0 {
        let frames = playback.remaining().min(options.frames as u64) as usize;
        playback.render(&mut out[..frames * 2])?;
    }
    Ok((playback.position(), 0))
}

#[cfg(feature = "alsa")]
fn play_alsa(
    device: &str,
    playback: &mut Playback,
    options: &Options,
) -> Result<(u64, usize), String> {
    let rate = playback.rate();
    let total = playback.total_frames();
    let sink = FileSink { playback };
    let report = jawn_audio::alsa_device::run_file_playback(
        device,
        rate,
        options.frames,
        options.buffer,
        total,
        sink,
    )?;
    Ok((report.frames, report.xruns))
}

#[cfg(not(feature = "alsa"))]
fn play_alsa(
    device: &str,
    playback: &mut Playback,
    options: &Options,
) -> Result<(u64, usize), String> {
    let _ = (device, playback, options);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

#[cfg(feature = "alsa")]
struct FileSink<'a> {
    playback: &'a mut Playback,
}

#[cfg(feature = "alsa")]
impl jawn_audio::playback::RenderSource for FileSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        self.playback.prepare(rate, period)
    }

    fn block(&mut self, out: &mut [f32]) -> Result<(), String> {
        self.playback.render(out)
    }
}

/// The overdub's monitoring bus: the earlier takes through plain strips to the
/// outputs, on a device handle of its own.
///
/// Nothing here touches a [`DiskWriter`] or the capture device, which is what
/// keeps the monitor out of the recording. `start_at` is where the monitor
/// begins: the take's stamp minus the measured capture offset
/// ([`monitor_start`]), never before sample zero. The offset corrects the
/// start; a clock that drifts over a long take is still not corrected. `stop`
/// ends the bus when the take does; the two threads never wait on one another.
fn run_monitor(
    backend: BackendKind,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    tracks: Vec<PlayTrack>,
    start_at: u64,
    stop: Arc<AtomicBool>,
    system_device: Option<String>,
    target: Option<String>,
) -> Result<(u64, usize), String> {
    let mut playback = Playback::new(tracks, start_at)?;
    // A PipeWire monitor that plays through `default` would play into the sink
    // it captures; refuse a missing target rather than fall back.
    let guard = match system_device.as_deref() {
        Some(source) if backend == BackendKind::PipeWire => Some(
            jawn_audio::pipewire_guard::PlaybackGuard::new(target.as_deref(), source)?,
        ),
        _ => None,
    };
    // The machine's own mix goes to the monitor only, never to the take's
    // capture or writers. The capture lives exactly as long as this thread, so
    // a finished monitor leaves no `parec` behind.
    let _system = match system_device {
        Some(source) => match crate::system_capture::SystemCapture::start(&source, rate) {
            Ok((capture, consumer)) => {
                playback = playback.with_system_input(consumer);
                Some(capture)
            }
            Err(error) => {
                eprintln!("jawn-audio: system mix: {error}");
                None
            }
        },
        None => None,
    };
    match backend {
        BackendKind::Null => {
            playback.prepare(rate, period)?;
            let mut out = vec![0.0f32; period * 2];
            while playback.remaining() > 0 && !stop.load(Ordering::SeqCst) {
                let frames = playback.remaining().min(period as u64) as usize;
                playback.render(&mut out[..frames * 2])?;
            }
            Ok((playback.position(), 0))
        }
        BackendKind::Alsa | BackendKind::PipeWire => {
            monitor_hardware(device, rate, period, buffer, &mut playback, &stop, guard.as_ref())
        }
        BackendKind::Jack => Err(play_support_message()),
    }
}

#[cfg(feature = "alsa")]
fn monitor_hardware(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    playback: &mut Playback,
    stop: &AtomicBool,
    guard: Option<&jawn_audio::pipewire_guard::PlaybackGuard>,
) -> Result<(u64, usize), String> {
    let total = playback.total_frames();
    let sink = MonitorSink { playback, stop };
    match jawn_audio::alsa_device::run_file_playback_guarded(
        device,
        rate,
        period,
        buffer,
        total,
        sink,
        guard,
    ) {
        Ok(report) => Ok((report.frames, report.xruns)),
        // A stop is the take ending, not a monitor failure.
        Err(_) if stop.load(Ordering::SeqCst) => Ok((playback.position(), 0)),
        Err(error) => Err(error),
    }
}

#[cfg(not(feature = "alsa"))]
fn monitor_hardware(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    playback: &mut Playback,
    stop: &AtomicBool,
    guard: Option<&jawn_audio::pipewire_guard::PlaybackGuard>,
) -> Result<(u64, usize), String> {
    let _ = (device, rate, period, buffer, playback, stop, guard);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

#[cfg(feature = "alsa")]
struct MonitorSink<'a> {
    playback: &'a mut Playback,
    stop: &'a AtomicBool,
}

#[cfg(feature = "alsa")]
impl jawn_audio::playback::RenderSource for MonitorSink<'_> {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        self.playback.prepare(rate, period)
    }

    fn block(&mut self, out: &mut [f32]) -> Result<(), String> {
        if self.stop.load(Ordering::SeqCst) {
            return Err("stopped".to_string());
        }
        self.playback.render(out)
    }
}

/// A backend that cannot play files says so before a worker is started.
pub(crate) fn play_support(backend: BackendKind) -> Result<(), String> {
    match backend {
        BackendKind::Null => Ok(()),
        BackendKind::Alsa | BackendKind::PipeWire => {
            if cfg!(feature = "alsa") {
                Ok(())
            } else {
                Err(
                    "this build has no ALSA/PipeWire backend; rebuild with --features alsa"
                        .to_string(),
                )
            }
        }
        BackendKind::Jack => Err(play_support_message()),
    }
}

fn play_support_message() -> String {
    "no JACK file playback yet; use --backend alsa or null".to_string()
}

/// The backends that carry the machine's own audio through the engine. ALSA
/// owns the card exclusively; a managed PipeWire engine plays the output it
/// replaced and captures the mix sink. JACK and the null device neither own an
/// output nor have a sink of ours to capture.
pub(crate) fn owns_system_mix(backend: BackendKind) -> bool {
    matches!(backend, BackendKind::Alsa | BackendKind::PipeWire)
}

/// A backend that cannot monitor an input says so before a worker is started.
pub(crate) fn listen_support(backend: BackendKind) -> Result<(), String> {
    match backend {
        BackendKind::Null => Ok(()),
        BackendKind::Alsa | BackendKind::PipeWire => {
            if cfg!(feature = "alsa") {
                Ok(())
            } else {
                Err(
                    "this build has no ALSA/PipeWire backend; rebuild with --features alsa"
                        .to_string(),
                )
            }
        }
        BackendKind::Jack => Err(listen_support_message()),
    }
}

fn listen_support_message() -> String {
    "no JACK monitoring path yet; use --backend alsa or null".to_string()
}

/// Open and close the playback device without starting the stream, so the
/// socket can refuse a busy card instead of answering `playing` and failing a
/// block later. Returns the rate the device granted.
pub(crate) fn probe_playback(
    backend: BackendKind,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> Result<u32, String> {
    match backend {
        BackendKind::Alsa | BackendKind::PipeWire => playback_probe(device, rate, period, buffer),
        // The null device runs at whatever rate the files carry.
        BackendKind::Null | BackendKind::Jack => Ok(rate),
    }
}

#[cfg(feature = "alsa")]
fn playback_probe(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> Result<u32, String> {
    jawn_audio::alsa_device::check_playback(device, rate, period, buffer)
        .map_err(|error| format!("cannot play: {error}"))
}

#[cfg(not(feature = "alsa"))]
fn playback_probe(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> Result<u32, String> {
    let _ = (device, rate, period, buffer);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

fn validate_serve(options: &Options) -> Result<(), String> {
    validate_block(options.frames, options.buffer)?;
    if options.rate == 0 {
        return Err("--rate must be at least 1".to_string());
    }
    validate_channels(options)?;
    // An uplink is a keyed transport: without a key it would be an open UDP
    // microphone, so the same rule as a clock session applies here.
    if let Some(address) = options.uplink.as_deref() {
        address.parse::<std::net::SocketAddr>().map_err(|_| {
            format!("--uplink wants an IP:PORT address such as 0.0.0.0:7060, not `{address}`")
        })?;
        let key = options.session_key_hex.as_deref().ok_or_else(|| {
            "an uplink needs a session key: pass --session-key-hex HEX64 \
             or set $JAWNOS_AUDIO_SESSION_KEY"
                .to_string()
        })?;
        peer::parse_session_key(key).map_err(|error| format!("--session-key-hex: {error}"))?;
    }
    // A backend that cannot capture is a configuration mistake, so say it at
    // startup rather than when the first take is armed.
    record_support(options.backend)
}

/// Frames a take of `seconds` holds, rounded once so the queue size and the
/// recording loop agree exactly on where the take ends.
pub(crate) fn take_frames(seconds: f64, rate: u32) -> u64 {
    (seconds.max(0.0) * rate as f64).round() as u64
}

/// How many blocks the disk queue may hold between the audio side and its
/// writer thread.
///
/// Hardware is paced by the device, so the queue stays shallow: a few periods
/// cover a scheduling hiccup, and a disk that stalls past that must drop rather
/// than stall the capture loop past its deadline.
pub(crate) const HARDWARE_QUEUE_BLOCKS: usize = 8;

/// The most the null backend's whole-take queue may hold. The cap keeps a very
/// long `--seconds` from asking for an unbounded allocation; past it the disk
/// sets the pace and any drop is counted, never hidden.
const NULL_QUEUE_BYTES: usize = 8 * 1024 * 1024;

/// The blocks a take will push: `frames` split into `period`-sized blocks, the
/// last one short.
pub(crate) fn take_blocks(frames: u64, period: usize) -> usize {
    let period = period.max(1) as u64;
    let blocks = frames / period + u64::from(frames % period != 0);
    usize::try_from(blocks).unwrap_or(usize::MAX)
}

/// A queue sized for the whole take, bounded by [`NULL_QUEUE_BYTES`].
pub(crate) fn null_queue_blocks(blocks: usize, period: usize, channels: usize) -> usize {
    let block_bytes = period
        .max(1)
        .saturating_mul(channels.max(1))
        .saturating_mul(2);
    let cap = (NULL_QUEUE_BYTES / block_bytes).max(1);
    blocks.clamp(1, cap)
}

/// The queue a take gets. The null backend produces faster than real time, so
/// a shallow queue would drop most of a take before the writer thread had a
/// chance to drain it: its queue is the whole take. Hardware keeps the shallow
/// queue above.
pub(crate) fn queue_blocks(
    backend: BackendKind,
    frames: u64,
    period: usize,
    channels: usize,
) -> usize {
    match backend {
        BackendKind::Null => null_queue_blocks(take_blocks(frames, period), period, channels),
        BackendKind::Alsa | BackendKind::PipeWire | BackendKind::Jack => HARDWARE_QUEUE_BLOCKS,
    }
}

fn run_record(options: &Options) -> Result<ExitCode, String> {
    validate_record(options)?;
    let path = options.out.clone().expect("validated --out");
    let device = options.backend.device_name(options.device.as_deref());

    match record_take(options, &path, &device) {
        Ok(report) => {
            if options.json {
                println!("{}", report.to_json());
            } else {
                println!("{}", report.prose());
            }
            Ok(ExitCode::SUCCESS)
        }
        Err(error) => {
            let report = TakeReport::failure(
                first_track_path(options, &path),
                options.backend.name(),
                device,
                options.rate,
                options.channels,
                options.start_at,
                insert_list(options, 1),
                Alignment::hint(options),
                error.clone(),
            );
            if options.json {
                println!("{}", report.to_json());
            } else {
                eprintln!("record failed: {error}");
            }
            Ok(ExitCode::from(1))
        }
    }
}

/// Create the take, stream the backend into it, and finish it. Any runtime
/// failure removes the partial file: a short take is only left behind when the
/// process is killed, where the per-block sizes still make it a valid WAV.
///
/// The samples never go to disk on this thread. Every block is handed to a
/// [`DiskWriter`], whose writer thread owns the WAV (docs: `engine/src/disk.rs`).
/// A track gets its **own** writer: a full queue on one track drops that track's
/// block and cannot stall the other, and each writer counts its own drops.
fn record_take(options: &Options, out: &str, device: &str) -> Result<TakeReport, String> {
    // Answer "can this build/backend record?" before opening the output: a
    // backend that cannot run must not truncate a file the user named.
    record_support(options.backend)?;

    let seconds = if options.seconds_given {
        options.seconds
    } else {
        RECORD_SECONDS
    };
    // Open and close the device before the file. A busy or missing device then
    // fails without truncating a path the caller named; the real open follows
    // inside the recording run.
    let granted = probe_capture(
        options.backend,
        device,
        options.rate,
        options.frames,
        options.buffer,
        options.channels,
    )?;

    let plans = track_plans(options, out)?;
    // The device may have granted fewer channels than asked; a track that names
    // an input past that count is refused here, before any WAV is created.
    for (index, plan) in plans.iter().enumerate() {
        if plan.input >= granted {
            return Err(format!(
                "track {} records input {}, but the device granted only {granted} channel(s)",
                index + 1,
                plan.input
            ));
        }
    }
    let frames = take_frames(seconds, options.rate);
    let queue = queue_blocks(options.backend, frames, options.frames, TAKE_CHANNELS);

    // The monitoring bus is decoded here and probed separately, before any WAV
    // exists: a missing file or a busy output is a refusal, not a take that
    // records silence the person thought they would hear. Its strips are built
    // on the playback thread, because an insert is not `Send`.
    let monitor_plans = monitor_specs(options);
    let mut monitor_tracks: Vec<PlayTrack> = Vec::with_capacity(monitor_plans.len());
    for spec in &monitor_plans {
        monitor_tracks.push(
            PlayTrack::from_wav(
                spec.path.clone(),
                spec.gain,
                spec.pan,
                spec.inserts.clone(),
            )
            .map_err(|error| format!("monitor: {error}"))?,
        );
    }
    if !monitor_tracks.is_empty() {
        play_support(options.backend)?;
        let (monitor_rate, _) = jawn_audio::playback::check_tracks(&monitor_tracks)?;
        if monitor_rate != options.rate {
            return Err(format!(
                "the monitor is {monitor_rate} Hz but the take records at {} Hz; the monitor must share the take's rate or it would play at the wrong pitch",
                options.rate
            ));
        }
        let playback_rate = probe_playback(
            options.backend,
            device,
            options.rate,
            options.frames,
            options.buffer,
        )?;
        if playback_rate != options.rate {
            return Err(format!(
                "the device granted {playback_rate} Hz for the monitor, but the take records at {} Hz",
                options.rate
            ));
        }
    }

    // The capture offset is resolved before any file exists: an explicit
    // number wins, `--calibrate` measures once through the patch cable, and
    // neither means no shift. This is a start correction only; drift over a
    // long take is not measured here.
    let alignment = if monitor_tracks.is_empty() {
        Alignment::hint(options)
    } else {
        resolve_alignment(
            options.backend,
            device,
            options.rate,
            options.frames,
            options.buffer,
            options.align_samples,
            options.calibrate,
        )
    };

    // One writer per track. Each spawn creates its WAV before any audio, so a
    // bad path fails here; a failure on a later track joins the writers already
    // started and removes only the files they created.
    let mut disks: Vec<DiskWriter> = Vec::with_capacity(plans.len());
    for (index, plan) in plans.iter().enumerate() {
        match DiskWriter::spawn(
            Path::new(&plan.path),
            options.rate,
            TAKE_CHANNELS as u16,
            options.frames,
            queue,
        ) {
            Ok(disk) => disks.push(disk),
            Err(error) => {
                for disk in disks {
                    let _ = disk.finish();
                }
                for spawned in &plans[..index] {
                    let _ = std::fs::remove_file(&spawned.path);
                }
                return Err(format!("cannot write {}: {error}", plan.path));
            }
        }
    }

    // One strip per track: the same unprefixed knobs reach every track, and a
    // `N:` prefix overrides just that track.
    let inputs: Vec<usize> = plans.iter().map(|plan| plan.input).collect();
    let labels: Vec<&str> = plans.iter().map(|plan| plan.label.as_str()).collect();
    let mut mixer = Mixer::new(&inputs, &labels);
    for (index, track) in mixer.tracks_mut().iter_mut().enumerate() {
        track.channel = channel_for(options, index + 1);
    }

    // Two threads and two device handles: this one captures the take, the
    // monitor renders to the outputs. Neither waits on the other; the monitor
    // never touches the take's writers, so it cannot enter the recording. The
    // monitor starts `alignment.samples` before the take's stamp, so the
    // monitored sound reaches the capture at the stamp it was played for; with
    // no measurement the start is the stamp itself.
    let monitor_stop = Arc::new(AtomicBool::new(false));
    let monitor = if monitor_tracks.is_empty() {
        None
    } else {
        let spawned = {
            let stop = Arc::clone(&monitor_stop);
            let device = device.to_string();
            let backend = options.backend;
            let rate = options.rate;
            let period = options.frames;
            let buffer = options.buffer;
            let start_at = monitor_start(options.start_at, alignment.samples);
            // The monitor plays the output the mix replaced and adds the
            // machine's own audio, so it carries the sink either way.
            let system_device = if owns_system_mix(options.backend) {
                options.system_device.clone()
            } else {
                None
            };
            let target = options.device.clone();
            thread::Builder::new()
                .name("jawn-audio-monitor".to_string())
                .spawn(move || {
                    run_monitor(
                        backend,
                        &device,
                        rate,
                        period,
                        buffer,
                        monitor_tracks,
                        start_at,
                        stop,
                        system_device,
                        target,
                    )
                })
        };
        match spawned {
            Ok(handle) => Some(handle),
            Err(error) => {
                // No monitor, no overdub: finish the writers and remove the
                // take files nobody will fill.
                for disk in disks {
                    let _ = disk.finish();
                }
                for plan in &plans {
                    let _ = std::fs::remove_file(&plan.path);
                }
                return Err(format!("cannot start the monitor thread: {error}"));
            }
        }
    };

    let outcome = match options.backend {
        BackendKind::Null => record_null(options, seconds, &mut disks, &mut mixer),
        BackendKind::Alsa | BackendKind::PipeWire => {
            record_alsa(device, options, seconds, &mut disks, &mut mixer)
        }
        BackendKind::Jack => Err(
            "no JACK capture backend yet; use --backend alsa or null".to_string(),
        ),
    };

    // The take decides when the monitoring bus ends: silence the player, then
    // join it, so `monitor_frames` is what was played rather than a guess. A
    // monitor failure does not discard the take; it is reported beside it.
    monitor_stop.store(true, Ordering::SeqCst);
    let (monitor_frames, monitor_error) = match monitor {
        None => (0, String::new()),
        Some(handle) => match handle.join() {
            Ok(Ok((frames, _xruns))) => (frames, String::new()),
            Ok(Err(error)) => (0, error),
            Err(_) => (0, "the monitor thread panicked".to_string()),
        },
    };

    let (rate, xruns) = match outcome {
        Ok(result) => result,
        Err(error) => {
            // Join every writer before the files go, so no block is written to
            // a file this thread has just unlinked.
            for disk in disks {
                let _ = disk.finish();
            }
            for plan in &plans {
                let _ = std::fs::remove_file(&plan.path);
            }
            return Err(error);
        }
    };

    // Read the counts before `finish`, which consumes each handle.
    let dropped: Vec<u64> = disks.iter().map(|disk| disk.dropped_frames()).collect();
    let mut finished: Vec<Result<u64, String>> = Vec::with_capacity(plans.len());
    for (index, disk) in disks.into_iter().enumerate() {
        // Every writer is joined even if an earlier one failed, so no thread is
        // left writing into an unlinked file.
        match disk.finish() {
            Ok(track_frames) => {
                if rate != options.rate {
                    // The samples are at the rate the backend granted, so the
                    // header must say that rate too. The writer thread owned
                    // the file until `finish`, hence the correction afterwards.
                    if let Err(error) = rewrite_rate(Path::new(&plans[index].path), rate) {
                        finished.push(Err(error));
                        continue;
                    }
                }
                finished.push(Ok(track_frames));
            }
            Err(error) => finished.push(Err(format!(
                "cannot finish {}: {error}",
                plans[index].path
            ))),
        }
    }

    if let Some(error) = finished.iter().find_map(|result| result.as_ref().err()) {
        for plan in &plans {
            let _ = std::fs::remove_file(&plan.path);
        }
        return Err(error.clone());
    }

    let mut tracks = Vec::with_capacity(plans.len());
    for (index, result) in finished.into_iter().enumerate() {
        let track_frames = match result {
            Ok(frames) => frames,
            Err(_) => 0,
        };
        tracks.push(TakeTrack {
            path: plans[index].path.clone(),
            input: plans[index].input,
            frames: track_frames,
            dropped: dropped[index],
        });
    }
    Ok(TakeReport::success(
        tracks,
        options.backend.name(),
        device.to_string(),
        rate,
        granted,
        options.start_at,
        xruns,
        insert_list(options, 1),
        options.monitor.len(),
        monitor_frames,
        monitor_error,
        alignment,
    ))
}

pub(crate) fn record_support(backend: BackendKind) -> Result<(), String> {
    match backend {
        BackendKind::Null => Ok(()),
        BackendKind::Alsa | BackendKind::PipeWire => {
            if cfg!(feature = "alsa") {
                Ok(())
            } else {
                Err(
                    "this build has no ALSA/PipeWire backend; rebuild with --features alsa"
                        .to_string(),
                )
            }
        }
        BackendKind::Jack => Err(
            "no JACK capture backend yet; use --backend alsa or null".to_string(),
        ),
    }
}

/// Open and close the capture device without touching the output file, so a
/// busy or missing device fails before a path is truncated. Returns the channel
/// count the device granted.
pub(crate) fn probe_capture(
    backend: BackendKind,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    channels: usize,
) -> Result<usize, String> {
    match backend {
        BackendKind::Alsa | BackendKind::PipeWire => {
            capture_probe(device, rate, period, buffer, channels)
        }
        // The null device is whatever count it was asked for.
        BackendKind::Null | BackendKind::Jack => Ok(channels),
    }
}

#[cfg(feature = "alsa")]
fn capture_probe(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    channels: usize,
) -> Result<usize, String> {
    jawn_audio::alsa_device::check_capture(device, rate, period, buffer, channels)
        .map_err(|error| format!("cannot record: {error}"))
}

#[cfg(not(feature = "alsa"))]
fn capture_probe(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    channels: usize,
) -> Result<usize, String> {
    let _ = (device, rate, period, buffer, channels);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

/// Point the header at the rate a backend actually granted.
///
/// `DiskWriter` owns the file until it finishes, so the correction is made on
/// the closed file, at the same two offsets `WavWriter::set_rate` writes.
pub(crate) fn rewrite_rate(path: &Path, rate: u32) -> Result<(), String> {
    use std::io::{Seek, SeekFrom, Write};

    let byte_rate = u64::from(rate) * TAKE_CHANNELS as u64 * 2;
    if rate == 0 || byte_rate > u64::from(u32::MAX) {
        return Err(format!("{rate} Hz does not fit a WAV header"));
    }
    let fail =
        |error: std::io::Error| format!("cannot set the take rate in {}: {error}", path.display());
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .open(path)
        .map_err(fail)?;
    file.seek(SeekFrom::Start(24)).map_err(fail)?;
    file.write_all(&rate.to_le_bytes()).map_err(fail)?;
    file.seek(SeekFrom::Start(28)).map_err(fail)?;
    file.write_all(&(byte_rate as u32).to_le_bytes()).map_err(fail)?;
    file.flush().map_err(fail)?;
    Ok(())
}

/// The null take: silence, or a sine, through the same block loop as hardware.
/// The frame buffer is allocated once; each block is sliced to the frames that
/// remain, so the take is exactly `--seconds` even when it is not a whole
/// number of periods.
fn record_null(
    options: &Options,
    seconds: f64,
    disks: &mut [DiskWriter],
    mixer: &mut Mixer,
) -> Result<(u32, usize), String> {
    let track_count = mixer.tracks().len();
    if disks.len() != track_count {
        return Err(format!(
            "{track_count} track(s) but {} disk writer(s)",
            disks.len()
        ));
    }
    // The null backend is the source's own shape: one channel per device
    // channel, so a track reads the input `--inputs` gave it even though every
    // channel carries the same silence or sine.
    let channels = options.channels;
    let mut device = NullDevice::new(options.rate, options.frames, channels);
    if let Some(hz) = options.tone {
        device = device.with_tone(hz);
    }
    mixer.prepare(options.rate, options.frames);

    let total = take_frames(seconds, options.rate);
    let mut source = vec![0.0f32; options.frames * channels];
    let mut mono = vec![0.0f32; options.frames];
    let mut stereo = vec![0.0f32; options.frames * TAKE_CHANNELS];
    let mut pcm = vec![0i16; options.frames * TAKE_CHANNELS];
    let mut remaining = total;
    while remaining > 0 {
        device
            .process(&mut source)
            .map_err(|error| format!("device: {error:?}"))?;
        let frames = remaining.min(options.frames as u64) as usize;
        let samples = frames * TAKE_CHANNELS;
        for track in 0..track_count {
            let input = mixer.tracks()[track].input;
            if input >= channels {
                return Err(format!(
                    "track {track} records input {input}, but the device has {channels} channel(s)"
                ));
            }
            for frame in 0..frames {
                mono[frame] = source[frame * channels + input];
            }
            mixer
                .process(track, &mono[..frames], &mut stereo[..samples])
                .map_err(|error| format!("track {track}: {error}"))?;
            for (out, sample) in pcm[..samples].iter_mut().zip(&stereo[..samples]) {
                *out = to_i16(*sample);
            }
            // Never blocks; each track's queue is sized for the whole take, so
            // a drop here means that track's cap was reached and is counted in
            // its own report. One track's full queue does not touch the other.
            disks[track].push(&pcm[..samples]);
        }
        remaining -= frames as u64;
    }
    Ok((options.rate, 0))
}

/// The hardware take's tracks: read each track's input from the interleaved
/// block at the granted channel count, run its strip, write its stereo result
/// to its own writer. Every buffer is sized once in [`CaptureSink::prepared`]
/// from the shape ALSA granted.
#[cfg(feature = "alsa")]
struct TakeChannel<'a> {
    mixer: &'a mut Mixer,
    disks: &'a mut [DiskWriter],
    /// Device channels per frame, learned in `prepared`.
    channels: usize,
    mono: Vec<f32>,
    stereo: Vec<f32>,
    pcm: Vec<i16>,
}

#[cfg(feature = "alsa")]
impl jawn_audio::alsa_device::CaptureSink for TakeChannel<'_> {
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
            // One input per channel strip, not the sum of two: a mic on input 0
            // and an instrument on input 1 are different sources, and averaging
            // them mixes a vocal into a guitar.
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
        Ok(())
    }
}

#[cfg(feature = "alsa")]
fn record_alsa(
    device: &str,
    options: &Options,
    seconds: f64,
    disks: &mut [DiskWriter],
    mixer: &mut Mixer,
) -> Result<(u32, usize), String> {
    let sink = TakeChannel {
        mixer,
        disks,
        channels: options.channels,
        mono: Vec::new(),
        stereo: Vec::new(),
        pcm: Vec::new(),
    };
    let report = jawn_audio::alsa_device::run_capture(
        device,
        options.rate,
        options.frames,
        options.buffer,
        options.channels,
        seconds,
        sink,
    )?;
    // ALSA may grant a rate other than the one requested; the samples are at
    // the granted rate, so the header and the report must say that rate. The
    // header is corrected by `record_take` once the writer has closed the file.
    Ok((report.rate, report.xruns))
}

#[cfg(not(feature = "alsa"))]
fn record_alsa(
    device: &str,
    options: &Options,
    seconds: f64,
    disks: &mut [DiskWriter],
    mixer: &mut Mixer,
) -> Result<(u32, usize), String> {
    let _ = (device, options, seconds, disks, mixer);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

fn self_test() -> Result<(), String> {
    let frames = 64usize;
    let mut mono = vec![0.0f32; frames];
    let step = std::f32::consts::TAU * 1_000.0 / 48_000.0;
    for (index, sample) in mono.iter_mut().enumerate() {
        *sample = (index as f32 * step).sin();
    }

    let mut stereo = vec![0.0f32; frames * 2];
    let strip = Strip::new(1.0, 0.0);
    mix_mono_into_stereo(&mut stereo, &mono, &strip).map_err(|error| format!("graph: {error:?}"))?;
    let left = stereo
        .iter()
        .step_by(2)
        .fold(0.0f32, |loudest, sample| loudest.max(sample.abs()));
    let right = stereo
        .iter()
        .skip(1)
        .step_by(2)
        .fold(0.0f32, |loudest, sample| loudest.max(sample.abs()));
    if (left - right).abs() > 1e-6 {
        return Err("a centred strip was not symmetric".to_string());
    }

    let header = Header {
        codec: Codec::Pcm16,
        flags: 0,
        session: 1,
        stream: 2,
        channels: 2,
        seq: 3,
        master_sample: 4,
    };
    let mut datagram = vec![0u8; HEADER_LEN + 4];
    let len = encode_datagram(&mut datagram, &header, &[0u8; 4])
        .map_err(|error| format!("protocol: {error:?}"))?;
    let (back, offset) =
        decode(&datagram[..len]).map_err(|error| format!("protocol: {error:?}"))?;
    if back != header || offset != HEADER_LEN {
        return Err("the datagram header did not round-trip".to_string());
    }

    println!("selftest: header ok, graph ok, left {left:.4} right {right:.4}");
    Ok(())
}

/// SIGINT/SIGTERM for a run with no `--seconds`, and for the server.
///
/// The handler only sets an `AtomicBool`; the listen loop checks it between
/// blocks, so both streams are dropped in order and the report is printed
/// rather than the process dying mid-period. The server waits in `poll`, and
/// the C `signal` sets SA_RESTART, which restarts that wait instead of
/// returning: so the handler also writes one byte to a wake pipe the server
/// adds to the descriptors it polls. `signal` and `write` are declared directly
/// because the crate deliberately has no dependency beyond the audio backend.
#[cfg(unix)]
mod signals {
    use std::io;
    use std::os::unix::io::{AsRawFd, RawFd};
    use std::os::unix::net::UnixStream;
    use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};

    static STOP: AtomicBool = AtomicBool::new(false);
    /// The wake pipe's write end, or -1 before one exists.
    static WAKE: AtomicI32 = AtomicI32::new(-1);

    extern "C" {
        fn signal(signum: i32, handler: usize) -> usize;
        fn write(fd: i32, buf: *const std::ffi::c_void, count: usize) -> isize;
    }

    extern "C" fn on_signal(_: i32) {
        STOP.store(true, Ordering::SeqCst);
        let fd = WAKE.load(Ordering::SeqCst);
        if fd >= 0 {
            // One byte, async-signal-safe. A full pipe is harmless: the fd is
            // already readable, which is all the poll below needs.
            unsafe {
                write(fd, b"x".as_ptr() as *const std::ffi::c_void, 1);
            }
        }
    }

    /// Install the handlers once and return the flag the loop reads.
    pub fn install() -> &'static AtomicBool {
        const SIGINT: i32 = 2;
        const SIGTERM: i32 = 15;
        unsafe {
            signal(SIGINT, on_signal as extern "C" fn(i32) as usize);
            signal(SIGTERM, on_signal as extern "C" fn(i32) as usize);
        }
        &STOP
    }

    /// The read end a `poll`-blocked loop adds to its descriptors. Call
    /// `install` first. The write end lives for the process: the handler can
    /// only hold a number, so closing it would leave the wake pointing at a
    /// reused descriptor.
    pub fn wake_pipe() -> io::Result<UnixStream> {
        let (reader, writer) = UnixStream::pair()?;
        reader.set_nonblocking(true)?;
        writer.set_nonblocking(true)?;
        let fd: RawFd = writer.as_raw_fd();
        WAKE.store(fd, Ordering::SeqCst);
        std::mem::forget(writer);
        Ok(reader)
    }
}

#[cfg(not(unix))]
mod signals {
    use std::sync::atomic::AtomicBool;

    static STOP: AtomicBool = AtomicBool::new(false);

    pub fn install() -> &'static AtomicBool {
        &STOP
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_quiet_receive_includes_a_restarted_masters_refusal() {
        use std::io::{Error, ErrorKind};
        for kind in [
            ErrorKind::WouldBlock,
            ErrorKind::TimedOut,
            ErrorKind::ConnectionRefused,
            ErrorKind::ConnectionReset,
        ] {
            assert!(quiet_receive(&Error::from(kind)), "{kind:?}");
        }
        for kind in [
            ErrorKind::Other,
            ErrorKind::PermissionDenied,
            ErrorKind::AddrNotAvailable,
        ] {
            assert!(!quiet_receive(&Error::from(kind)), "{kind:?}");
        }
    }

    #[test]
    fn clock_knobs_parse_and_apply_only_to_the_peer() {
        let parse = |words: &[&str]| {
            let mut options = default_options();
            parse_arguments(&mut options, words.iter().map(|word| word.to_string()))
                .expect("a parse");
            options
        };

        // The defaults are the peer module's own, so a run that names neither
        // knob behaves as the constant says.
        let bare = parse(&[]);
        assert_eq!(bare.pong_timeout_ms, peer::PONG_TIMEOUT_MS);
        assert_eq!(bare.window, peer::ESTIMATOR_CAPACITY);

        let peer = parse(&[
            "--clock-peer",
            "--master",
            "127.0.0.1:7050",
            "--session-key-hex",
            TEST_KEY,
            "--pong-timeout-ms",
            "40",
            "--window",
            "65536",
        ]);
        assert_eq!(peer.pong_timeout_ms, 40);
        assert_eq!(peer.window, 65_536);
        validate_clock_options(&peer).expect("a peer may set both knobs");

        // The master answers pings; it has no probe loop to tune.
        let master = parse(&[
            "--clock-master",
            "--session-key-hex",
            TEST_KEY,
            "--pong-timeout-ms",
            "40",
        ]);
        assert!(validate_clock_options(&master).is_err());

        // Zero would mean a probe loop that waits for nothing or fits nothing.
        let zero = parse(&[
            "--clock-peer",
            "--master",
            "127.0.0.1:7050",
            "--session-key-hex",
            TEST_KEY,
            "--window",
            "0",
        ]);
        assert!(validate_clock_options(&zero).is_err());
    }

    const TEST_KEY: &str =
        "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

    #[test]
    fn an_uplink_belongs_to_serve_and_needs_a_key() {
        let parse = |words: &[&str]| {
            let mut options = default_options();
            parse_arguments(&mut options, words.iter().map(|word| word.to_string()))
                .expect("a parse");
            options
        };

        let serve = parse(&[
            "--serve",
            "--uplink",
            "127.0.0.1:7060",
            "--session-key-hex",
            TEST_KEY,
        ]);
        assert_eq!(serve.uplink.as_deref(), Some("127.0.0.1:7060"));
        validate_clock_options(&serve).expect("serve may carry the key when it names an uplink");
        validate_serve(&serve).expect("a loopback uplink is valid");

        // The address must parse before anything binds it.
        let bad_address = parse(&["--serve", "--uplink", "not-an-address"]);
        let error = validate_serve(&bad_address).expect_err("a bad address");
        assert!(error.contains("--uplink wants an IP:PORT"), "{error}");

        // No key is an open UDP microphone, so it is refused at startup.
        let no_key = parse(&["--serve", "--uplink", "127.0.0.1:7060"]);
        validate_clock_options(&no_key).expect("serve still reaches its own key check");
        let error = validate_serve(&no_key).expect_err("no key");
        assert!(error.contains("uplink needs a session key"), "{error}");
    }

    #[test]
    fn a_lease_is_positive_and_only_the_master_may_set_it() {
        let parse = |words: &[&str]| {
            let mut options = default_options();
            parse_arguments(&mut options, words.iter().map(|word| word.to_string()))
                .expect("a parse");
            options
        };

        // `new(key)`'s own default, so a master that names nothing behaves as
        // the constant says.
        let bare = parse(&[]);
        assert_eq!(bare.lease_ms, peer::DEFAULT_LEASE_MS);

        let master = parse(&[
            "--clock-master",
            "--session-key-hex",
            TEST_KEY,
            "--lease-ms",
            "5000",
        ]);
        assert_eq!(master.lease_ms, 5_000);
        validate_clock_options(&master).expect("the master owns the lease");

        // The peer tunes its own loop; the lease is the master's alone.
        let peer = parse(&[
            "--clock-peer",
            "--master",
            "127.0.0.1:7050",
            "--session-key-hex",
            TEST_KEY,
            "--lease-ms",
            "5000",
        ]);
        let error = validate_clock_options(&peer).expect_err("the peer cannot set a lease");
        assert!(error.contains("--lease-ms applies only"), "unhelpful error: {error}");

        // A lease of zero would expire every session at once.
        let zero = parse(&[
            "--clock-master",
            "--session-key-hex",
            TEST_KEY,
            "--lease-ms",
            "0",
        ]);
        assert!(validate_clock_options(&zero).is_err());

        // And it does not belong to a mode with no sessions at all.
        let elsewhere = parse(&["--run", "--lease-ms", "5000"]);
        assert!(validate_clock_options(&elsewhere).is_err());
    }

    #[test]
    fn a_clock_session_needs_a_key_and_only_where_it_applies() {
        let parse = |words: &[&str]| {
            let mut options = default_options();
            parse_arguments(&mut options, words.iter().map(|word| word.to_string()))
                .expect("a parse");
            options
        };

        // There is no unauthenticated clock master any more.
        let no_key = parse(&["--clock-master"]);
        let error = validate_clock_options(&no_key).expect_err("no key");
        assert!(
            error.contains("clock session needs a key"),
            "unhelpful error: {error}"
        );
        let peer_no_key = parse(&["--clock-peer", "--master", "127.0.0.1:7050"]);
        let error = validate_clock_options(&peer_no_key).expect_err("no peer key");
        assert!(
            error.contains("clock session needs a key"),
            "unhelpful error: {error}"
        );

        // A key that is not 64 hex characters is a usage error.
        let malformed = parse(&["--clock-master", "--session-key-hex", "abc"]);
        assert!(validate_clock_options(&malformed).is_err());
        let not_hex = "g".repeat(64);
        let bad_hex = parse(&["--clock-master", "--session-key-hex", &not_hex]);
        assert!(validate_clock_options(&bad_hex).is_err());

        // The peer needs the same treatment as the master.
        let peer = parse(&[
            "--clock-peer",
            "--master",
            "127.0.0.1:7050",
            "--session-key-hex",
            TEST_KEY,
        ]);
        validate_clock_options(&peer).expect("a keyed peer");
        assert_eq!(peer.session_key_hex.as_deref(), Some(TEST_KEY));
        assert_eq!(session_key(&peer).expect("the decoded key").len(), 32);

        // The flag belongs to the clock modes alone.
        let elsewhere = parse(&["--run", "--session-key-hex", TEST_KEY]);
        let error = validate_clock_options(&elsewhere).expect_err("outside clock");
        assert!(
            error.contains("--session-key-hex applies only"),
            "unhelpful error: {error}"
        );
    }

    #[test]
    fn an_explicit_alignment_is_given_and_a_null_calibration_shifts_nothing() {
        let given = resolve_alignment(
            BackendKind::Null,
            "null",
            48_000,
            64,
            256,
            Some(96),
            false,
        );
        assert_eq!(given, Alignment::given(96));
        // A given number wins even when calibrate was also asked for.
        assert_eq!(
            resolve_alignment(BackendKind::Null, "null", 48_000, 64, 256, Some(12), true),
            Alignment::given(12)
        );
        // The null backend has no signal path: calibration reports none, never
        // a guessed number.
        assert_eq!(
            resolve_alignment(BackendKind::Null, "null", 48_000, 64, 256, None, true),
            Alignment::none()
        );
        assert_eq!(
            resolve_alignment(BackendKind::Null, "null", 48_000, 64, 256, None, false),
            Alignment::none()
        );
    }

    #[test]
    fn alignment_json_names_the_source() {
        assert_eq!(
            alignment_json(Alignment::given(480)),
            ",\"align_samples\":480,\"align_from\":\"given\""
        );
        assert_eq!(
            alignment_json(Alignment::none()),
            ",\"align_samples\":0,\"align_from\":\"none\""
        );
    }

    #[test]
    fn the_null_queue_holds_the_whole_take() {
        // 0.2 s at 48 kHz in 64-frame blocks is 150 blocks. Every one has to
        // fit, or a loop that runs faster than real time drops the take.
        let frames = take_frames(0.2, 48_000);
        assert_eq!(frames, 9_600);
        assert_eq!(take_blocks(frames, 64), 150);
        assert_eq!(
            queue_blocks(BackendKind::Null, frames, 64, TAKE_CHANNELS),
            150
        );
    }

    #[test]
    fn the_null_queue_is_capped_so_a_long_take_cannot_ask_for_the_world() {
        let frames = take_frames(3_600.0, 48_000);
        let blocks = take_blocks(frames, 64);
        let queue = queue_blocks(BackendKind::Null, frames, 64, TAKE_CHANNELS);
        assert!(queue < blocks, "the cap must bite: {queue} of {blocks}");
        assert_eq!(queue, NULL_QUEUE_BYTES / (64 * 2 * 2));
    }

    #[test]
    fn hardware_gets_a_shallow_queue() {
        // Hardware is paced by the device; a deep queue would only hide a
        // stalled disk until the take ended.
        let queue = queue_blocks(BackendKind::Alsa, 480_000, 64, TAKE_CHANNELS);
        assert_eq!(queue, HARDWARE_QUEUE_BLOCKS);
    }

    #[test]
    fn an_empty_take_still_gets_a_queue_with_room() {
        assert_eq!(take_blocks(0, 64), 0);
        assert_eq!(
            queue_blocks(BackendKind::Null, 0, 64, TAKE_CHANNELS),
            1,
            "a queue of zero blocks is refused before the file is created"
        );
    }

    #[test]
    fn the_engine_carries_the_system_mix_on_the_backends_that_own_the_output() {
        assert!(owns_system_mix(BackendKind::Alsa));
        assert!(owns_system_mix(BackendKind::PipeWire));
        assert!(!owns_system_mix(BackendKind::Jack));
        assert!(!owns_system_mix(BackendKind::Null));
    }
}
