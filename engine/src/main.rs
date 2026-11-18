//! `jawn-audio`, the engine's command line.
//!
//! The null device is still the default, so every mode runs on a machine with
//! no sound card. `--backends` says which optional backends this build carries,
//! and `--loopback` measures the patch-cable round trip when one does
//! (docs/studio-audio-roadmap.md P1). `--serve` is the control socket the
//! manager drives: one flat JSON object per line, one client at a time
//! (docs/studio-audio-roadmap.md P2).

mod socket;

use std::path::Path;
use std::process::ExitCode;

use jawn_audio::{
    backends::{self, BackendKind, RunReport},
    decode, encode_datagram, loopback, mix_mono_into_stereo, peak, to_i16, Channel, Codec, Device,
    DiskWriter, Header, InsertKind, NullDevice, Strip, HEADER_LEN,
};

/// A take is the interface's own shape: stereo at the sample rate in the
/// header. `--channels` is a `--run` option and is not silently reused here.
pub(crate) const RECORD_CHANNELS: usize = 2;
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
  jawn-audio --serve [options]            arm and place takes over a Unix socket
  jawn-audio --version                    print the version
  jawn-audio --help                       this text

--run options:
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N      block/period size in frames (default 64; --frames is an alias)
  --buffer N      buffer size in frames (default 256)
  --seconds S     how long to run, in seconds (default 1)
  --rate HZ       sample rate (default 48000)
  --channels N    channels per frame (default 2)
  --tone HZ       emit a sine instead of silence
  --json          one JSON line instead of prose

--record options:
  --out FILE.wav  where to write the take (required)
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N      block/period size in frames (default 64)
  --buffer N      buffer size in frames (default 256)
  --seconds S     how long to record, in seconds (default 5)
  --rate HZ       sample rate (default 48000)
  --start-at S    the take's start sample on the transport (default 0)
  --gain N        channel trim, linear (default 1.0)
  --pan N         channel pan, -1 left .. 1 right (default 0, centre)
  --channel N     which input the strip records (0 or 1, default 0)
  --insert NAME   an insert, repeatable in chain order:
                  tone, distortion, delay or compressor (default none)
  --tone HZ       with the null backend, record a sine instead of silence
  --json          one JSON line instead of prose

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
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N      block/period size in frames (default 64)
  --buffer N      buffer size in frames (default 256)
  --rate HZ       sample rate (default 48000)

--serve speaks one flat JSON object per line: record, status, stop, quit.
The null backend needs no sound card. ALSA and JACK exist only in a build with
--features alsa and/or --features jack; pipewire uses the ALSA `default` PCM.
A loopback needs the interface's output patched into its input.";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Check,
    Backends,
    Run,
    Loopback,
    Record,
    Serve,
    SelfTest,
    Version,
    Help,
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
    start_at: u64,
    gain: f32,
    pan: f32,
    inserts: Vec<InsertKind>,
    input: usize,
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

fn run() -> Result<ExitCode, String> {
    let mut options = Options {
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
        start_at: 0,
        gain: 1.0,
        pan: 0.0,
        inserts: Vec::new(),
        input: 0,
        seconds_given: false,
        json: false,
    };

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--check" => options.mode = Mode::Check,
            "--backends" => options.mode = Mode::Backends,
            "--run" => options.mode = Mode::Run,
            "--loopback" => options.mode = Mode::Loopback,
            "--record" => options.mode = Mode::Record,
            "--serve" => options.mode = Mode::Serve,
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
            "--start-at" => {
                let raw = value(&mut args, "--start-at")?;
                options.start_at = raw
                    .parse()
                    .map_err(|_| format!("--start-at wants a sample count, not `{raw}`"))?;
            }
            "--gain" => {
                let raw = value(&mut args, "--gain")?;
                options.gain = raw
                    .parse()
                    .map_err(|_| format!("--gain wants a multiplier, not `{raw}`"))?;
            }
            "--channel" => {
                let raw = value(&mut args, "--channel")?;
                options.input = raw
                    .parse()
                    .map_err(|_| format!("--channel wants 0 or 1, not `{raw}`"))?;
            }
            "--pan" => {
                let raw = value(&mut args, "--pan")?;
                options.pan = raw
                    .parse()
                    .map_err(|_| format!("--pan wants -1, 0 or 1, not `{raw}`"))?;
            }
            "--insert" => {
                let raw = value(&mut args, "--insert")?;
                options.inserts.push(InsertKind::parse(&raw).ok_or_else(|| {
                    format!(
                        "unknown insert `{raw}` (want tone, distortion, delay or compressor)"
                    )
                })?);
            }
            other => return Err(format!("unknown option `{other}` (try --help)")),
        }
    }

    // These three describe a channel, and `--record` is the only mode that has
    // one today; say so instead of accepting a knob that does nothing.
    if options.mode != Mode::Record
        && (options.gain != 1.0 || options.pan != 0.0 || !options.inserts.is_empty())
    {
        return Err("--gain, --pan and --insert apply only to --record".to_string());
    }

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
        Mode::Serve => run_serve(&options),
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

fn validate_run(options: &Options) -> Result<(), String> {
    validate_block(options.frames, options.buffer)?;
    if options.rate == 0 {
        return Err("--rate must be at least 1".to_string());
    }
    if options.channels == 0 {
        return Err("--channels must be at least 1".to_string());
    }
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

fn run_serve(options: &Options) -> Result<ExitCode, String> {
    validate_serve(options)?;
    let socket = socket::default_path(options.socket.as_deref())?;
    let device = options.backend.device_name(options.device.as_deref());
    // A server that cannot bind is a runtime failure, not a usage error: exit 1
    // tells a supervisor to try again, while 2 would mean the arguments are bad.
    let outcome = socket::serve(socket::Config {
        backend: options.backend,
        device,
        rate: options.rate,
        period: options.frames,
        buffer: options.buffer,
        socket,
    });
    match outcome {
        Ok(code) => Ok(code),
        Err(error) => {
            eprintln!("jawn-audio: {error}");
            Ok(ExitCode::from(1))
        }
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
    error: String,
}

impl TakeReport {
    fn success(
        path: String,
        backend: &'static str,
        device: String,
        rate: u32,
        frames: u64,
        dropped: u64,
        start_sample: u64,
        xruns: usize,
        inserts: String,
    ) -> Self {
        TakeReport {
            ok: true,
            path,
            backend,
            device,
            rate,
            frames,
            dropped,
            channels: RECORD_CHANNELS,
            start_sample,
            xruns,
            inserts,
            error: String::new(),
        }
    }

    fn failure(
        path: String,
        backend: &'static str,
        device: String,
        rate: u32,
        start_sample: u64,
        inserts: String,
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
            channels: RECORD_CHANNELS,
            start_sample,
            xruns: 0,
            inserts,
            error,
        }
    }

    fn to_json(&self) -> String {
        format!(
            "{{\"ok\":{},\"path\":\"{}\",\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"frames\":{},\"dropped\":{},\"channels\":{},\"start_sample\":{},\"xruns\":{},\"inserts\":\"{}\",\"error\":\"{}\"}}",
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
        format!(
            "take {}: {} frames at {} Hz, {} channels ({:.3} s), backend {}, device {}, start_sample {}, dropped {}, xruns {}, inserts {}",
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
            inserts
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
    if options.input > 1 {
        return Err("--channel must be 0 or 1".to_string());
    }
    if options.channels != RECORD_CHANNELS {
        return Err(format!(
            "--record writes stereo; --channels must be {RECORD_CHANNELS}"
        ));
    }
    if options.seconds < 0.0 {
        return Err("--seconds cannot be negative".to_string());
    }
    validate_channel(options)?;
    Ok(())
}

fn validate_channel(options: &Options) -> Result<(), String> {
    if !options.gain.is_finite() {
        return Err("--gain must be a finite number".to_string());
    }
    if !options.pan.is_finite() {
        return Err("--pan must be a finite number".to_string());
    }
    Ok(())
}

/// The take's channel: trim, the inserts in the order they were given, pan.
fn channel_for(options: &Options) -> Channel {
    let mut channel = Channel::new(options.gain, options.pan.clamp(-1.0, 1.0));
    for kind in &options.inserts {
        channel.push(kind.build());
    }
    channel
}

/// The chain order for the take report, e.g. `tone,distortion` or an empty
/// string when the take was a wire.
fn insert_list(options: &Options) -> String {
    options
        .inserts
        .iter()
        .map(|kind| kind.name())
        .collect::<Vec<_>>()
        .join(",")
}

fn validate_serve(options: &Options) -> Result<(), String> {
    validate_block(options.frames, options.buffer)?;
    if options.rate == 0 {
        return Err("--rate must be at least 1".to_string());
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
                path,
                options.backend.name(),
                device,
                options.rate,
                options.start_at,
                insert_list(options),
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
fn record_take(options: &Options, path: &str, device: &str) -> Result<TakeReport, String> {
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
    probe_capture(
        options.backend,
        device,
        options.rate,
        options.frames,
        options.buffer,
    )?;

    let frames = take_frames(seconds, options.rate);
    let queue = queue_blocks(options.backend, frames, options.frames, RECORD_CHANNELS);
    let mut disk = DiskWriter::spawn(
        Path::new(path),
        options.rate,
        RECORD_CHANNELS as u16,
        options.frames,
        queue,
    )
    .map_err(|error| format!("cannot write {path}: {error}"))?;

    let outcome = match options.backend {
        BackendKind::Null => record_null(options, seconds, &mut disk),
        BackendKind::Alsa | BackendKind::PipeWire => {
            record_alsa(device, options, seconds, &mut disk)
        }
        BackendKind::Jack => Err(
            "no JACK capture backend yet; use --backend alsa or null".to_string(),
        ),
    };

    match outcome {
        Ok((rate, xruns)) => {
            // Read the count before `finish`, which consumes the handle.
            let dropped = disk.dropped_frames();
            match disk.finish() {
                Ok(frames) => {
                    if rate != options.rate {
                        // The samples are at the rate the backend granted, so
                        // the header must say that rate too. The writer thread
                        // owned the file until `finish`, hence the correction
                        // afterwards.
                        if let Err(error) = rewrite_rate(Path::new(path), rate) {
                            let _ = std::fs::remove_file(path);
                            return Err(error);
                        }
                    }
                    Ok(TakeReport::success(
                        path.to_string(),
                        options.backend.name(),
                        device.to_string(),
                        rate,
                        frames,
                        dropped,
                        options.start_at,
                        xruns,
                        insert_list(options),
                    ))
                }
                Err(error) => {
                    let _ = std::fs::remove_file(path);
                    Err(format!("cannot finish {path}: {error}"))
                }
            }
        }
        Err(error) => {
            // Join the writer thread before the file goes, so no block is
            // written to a file this thread has just unlinked.
            let _ = disk.finish();
            let _ = std::fs::remove_file(path);
            Err(error)
        }
    }
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
/// busy or missing device fails before a path is truncated.
pub(crate) fn probe_capture(
    backend: BackendKind,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> Result<(), String> {
    match backend {
        BackendKind::Alsa | BackendKind::PipeWire => {
            capture_probe(device, rate, period, buffer)
        }
        BackendKind::Null | BackendKind::Jack => Ok(()),
    }
}

#[cfg(feature = "alsa")]
fn capture_probe(device: &str, rate: u32, period: usize, buffer: usize) -> Result<(), String> {
    jawn_audio::alsa_device::check_capture(device, rate, period, buffer)
        .map_err(|error| format!("cannot record: {error}"))
}

#[cfg(not(feature = "alsa"))]
fn capture_probe(device: &str, rate: u32, period: usize, buffer: usize) -> Result<(), String> {
    let _ = (device, rate, period, buffer);
    Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
}

/// Point the header at the rate a backend actually granted.
///
/// `DiskWriter` owns the file until it finishes, so the correction is made on
/// the closed file, at the same two offsets `WavWriter::set_rate` writes.
pub(crate) fn rewrite_rate(path: &Path, rate: u32) -> Result<(), String> {
    use std::io::{Seek, SeekFrom, Write};

    let byte_rate = u64::from(rate) * RECORD_CHANNELS as u64 * 2;
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
    disk: &mut DiskWriter,
) -> Result<(u32, usize), String> {
    // The null backend is the source's mono shape; the channel makes the take
    // stereo, exactly as a live mono input reaches the web's recorder.
    let mut device = NullDevice::new(options.rate, options.frames, 1);
    if let Some(hz) = options.tone {
        device = device.with_tone(hz);
    }
    let mut channel = channel_for(options);
    channel.prepare(options.rate, options.frames);

    let total = take_frames(seconds, options.rate);
    let mut mono = vec![0.0f32; options.frames];
    let mut stereo = vec![0.0f32; options.frames * RECORD_CHANNELS];
    let mut pcm = vec![0i16; options.frames * RECORD_CHANNELS];
    let mut remaining = total;
    while remaining > 0 {
        device
            .process(&mut mono)
            .map_err(|error| format!("device: {error:?}"))?;
        let frames = remaining.min(options.frames as u64) as usize;
        let samples = frames * RECORD_CHANNELS;
        channel
            .process(&mono[..frames], &mut stereo[..samples])
            .map_err(|error| format!("channel: {error:?}"))?;
        for (out, sample) in pcm[..samples].iter_mut().zip(&stereo[..samples]) {
            *out = to_i16(*sample);
        }
        // Never blocks; the queue is sized for the whole take, so a drop here
        // means the cap was reached and is counted in the report.
        disk.push(&pcm[..samples]);
        remaining -= frames as u64;
    }
    Ok((options.rate, 0))
}

/// The hardware take's channel: downmix each interleaved stereo block to mono,
/// run the strip, write the stereo result. Every buffer is sized once in
/// [`CaptureSink::prepared`] from the shape ALSA granted.
#[cfg(feature = "alsa")]
struct TakeChannel<'a> {
    channel: Channel,
    input: usize,
    mono: Vec<f32>,
    stereo: Vec<f32>,
    pcm: Vec<i16>,
    disk: &'a mut DiskWriter,
}

#[cfg(feature = "alsa")]
impl jawn_audio::alsa_device::CaptureSink for TakeChannel<'_> {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        self.channel.prepare(rate, period);
        self.mono = vec![0.0; period];
        self.stereo = vec![0.0; period * RECORD_CHANNELS];
        self.pcm = vec![0i16; period * RECORD_CHANNELS];
        Ok(())
    }

    fn block(&mut self, block: &[i16]) -> Result<(), String> {
        let frames = (block.len() / RECORD_CHANNELS).min(self.mono.len());
        // One input per channel strip, not the sum of two: a mic on input 0 and
        // an instrument on input 1 are different sources, and averaging them
        // mixes a vocal into a guitar. `--channel` picks the one this take is.
        let offset = self.input.min(1);
        for frame in 0..frames {
            self.mono[frame] = f32::from(block[frame * 2 + offset]) / 32_768.0;
        }
        let samples = frames * RECORD_CHANNELS;
        self.channel
            .process(&self.mono[..frames], &mut self.stereo[..samples])
            .map_err(|error| format!("channel: {error:?}"))?;
        for (out, sample) in self.pcm[..samples].iter_mut().zip(&self.stereo[..samples]) {
            *out = to_i16(*sample);
        }
        self.disk.push(&self.pcm[..samples]);
        Ok(())
    }
}

#[cfg(feature = "alsa")]
fn record_alsa(
    device: &str,
    options: &Options,
    seconds: f64,
    disk: &mut DiskWriter,
) -> Result<(u32, usize), String> {
    let sink = TakeChannel {
        channel: channel_for(options),
        input: options.input,
        mono: Vec::new(),
        stereo: Vec::new(),
        pcm: Vec::new(),
        disk,
    };
    let report = jawn_audio::alsa_device::run_capture(
        device,
        options.rate,
        options.frames,
        options.buffer,
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
    disk: &mut DiskWriter,
) -> Result<(u32, usize), String> {
    let _ = (device, options, seconds, disk);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_null_queue_holds_the_whole_take() {
        // 0.2 s at 48 kHz in 64-frame blocks is 150 blocks. Every one has to
        // fit, or a loop that runs faster than real time drops the take.
        let frames = take_frames(0.2, 48_000);
        assert_eq!(frames, 9_600);
        assert_eq!(take_blocks(frames, 64), 150);
        assert_eq!(
            queue_blocks(BackendKind::Null, frames, 64, RECORD_CHANNELS),
            150
        );
    }

    #[test]
    fn the_null_queue_is_capped_so_a_long_take_cannot_ask_for_the_world() {
        let frames = take_frames(3_600.0, 48_000);
        let blocks = take_blocks(frames, 64);
        let queue = queue_blocks(BackendKind::Null, frames, 64, RECORD_CHANNELS);
        assert!(queue < blocks, "the cap must bite: {queue} of {blocks}");
        assert_eq!(queue, NULL_QUEUE_BYTES / (64 * 2 * 2));
    }

    #[test]
    fn hardware_gets_a_shallow_queue() {
        // Hardware is paced by the device; a deep queue would only hide a
        // stalled disk until the take ended.
        let queue = queue_blocks(BackendKind::Alsa, 480_000, 64, RECORD_CHANNELS);
        assert_eq!(queue, HARDWARE_QUEUE_BLOCKS);
    }

    #[test]
    fn an_empty_take_still_gets_a_queue_with_room() {
        assert_eq!(take_blocks(0, 64), 0);
        assert_eq!(
            queue_blocks(BackendKind::Null, 0, 64, RECORD_CHANNELS),
            1,
            "a queue of zero blocks is refused before the file is created"
        );
    }
}
