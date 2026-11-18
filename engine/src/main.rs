//! `jawn-audio`, the engine's command line.
//!
//! The null device is still the default, so every mode runs on a machine with
//! no sound card. `--backends` says which optional backends this build carries,
//! and `--loopback` measures the patch-cable round trip when one does
//! (docs/studio-audio-roadmap.md P1). `--serve` is the control socket the
//! manager drives: one flat JSON object per line, one client at a time
//! (docs/studio-audio-roadmap.md P2).

mod socket;

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use jawn_audio::{
    backends::{self, BackendKind, RunReport},
    decode, encode_datagram, loopback, mix_mono_into_stereo, peak, to_i16, Channel, Codec, Device,
    DiskWriter, Header, InsertKind, Mixer, NullDevice, Strip, HEADER_LEN,
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
  --tracks N      1 (default) or 2: one WAV per device input
  --gain N        channel trim, linear (default 1.0)
  --pan N         channel pan, -1 left .. 1 right (default 0, centre)
  --channel N     which input a one-track take records (0 or 1, default 0)
  --insert NAME   an insert, repeatable in chain order:
                  tone, distortion, delay, compressor or reverb
                  (reverb2 is accepted as the web's name; default none)
  --tone HZ       with the null backend, record a sine instead of silence
  --json          one JSON line instead of prose

  --tracks 2 records inputs 0 and 1 at once and writes one WAV per track:
  --out take.wav becomes take-ch1.wav and take-ch2.wav. Both files share the
  take's start_sample. --gain, --pan and --insert apply to every track unless
  prefixed with a 1-based track number, e.g. --insert 1:delay, --gain 2:0.5,
  --pan 2:-1. A prefixed knob may only name a track the take has. The JSON's
  top-level path/frames/dropped/inserts describe track 1; a two-track take adds
  \"tracks\":[{\"path\":...,\"input\":N,\"frames\":N,\"dropped\":N},...]. A
  one-track take keeps its historical shape and omits \"tracks\".

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

--serve speaks one flat JSON object per line: record, param, status, stop,
quit. `param` moves one knob of a running take's strip and answers when the
change is queued for the next block.
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
    start_at: u64,
    gain: f32,
    pan: f32,
    gains: Vec<(usize, f32)>,
    pans: Vec<(usize, f32)>,
    inserts: Vec<InsertSpec>,
    tracks: usize,
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
        gains: Vec::new(),
        pans: Vec::new(),
        inserts: Vec::new(),
        tracks: 1,
        input: 0,
        input_given: false,
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
            "--tracks" => {
                let raw = value(&mut args, "--tracks")?;
                options.tracks = raw
                    .parse()
                    .map_err(|_| format!("--tracks wants 1 or 2, not `{raw}`"))?;
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
                    .map_err(|_| format!("--channel wants 0 or 1, not `{raw}`"))?;
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
                let kind = InsertKind::parse(text).ok_or_else(|| {
                    format!(
                        "unknown insert `{text}` (want tone, distortion, delay, compressor or reverb)"
                    )
                })?;
                options.inserts.push(InsertSpec { track, kind });
            }
            other => return Err(format!("unknown option `{other}` (try --help)")),
        }
    }

    // These knobs describe a take's tracks, and `--record` is the only mode
    // that has them today; say so instead of accepting a knob that does
    // nothing. `--channel` keeps its old shape outside `--record` (it was
    // always accepted there) so this is not a regression for an existing call.
    if options.mode != Mode::Record
        && (options.gain != 1.0
            || options.pan != 0.0
            || !options.gains.is_empty()
            || !options.pans.is_empty()
            || !options.inserts.is_empty()
            || options.tracks != 1)
    {
        return Err(
            "--tracks, --gain, --pan and --insert apply only to --record".to_string(),
        );
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

/// One track's half of a take report.
struct TakeTrack {
    path: String,
    input: usize,
    frames: u64,
    dropped: u64,
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
    error: String,
}

impl TakeReport {
    fn success(
        tracks: Vec<TakeTrack>,
        backend: &'static str,
        device: String,
        rate: u32,
        start_sample: u64,
        xruns: usize,
        inserts: String,
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
            channels: RECORD_CHANNELS,
            start_sample,
            xruns,
            inserts,
            tracks,
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
            tracks: Vec::new(),
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
        format!(
            "{{\"ok\":{},\"path\":\"{}\",\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"frames\":{},\"dropped\":{},\"channels\":{},\"start_sample\":{},\"xruns\":{},\"inserts\":\"{}\"{},\"error\":\"{}\"}}",
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
        format!(
            "take {}: {} frames at {} Hz, {} channels ({:.3} s), backend {}, device {}, start_sample {}, dropped {}, xruns {}, inserts {}{}",
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
            tracks
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
    if options.tracks != 1 && options.tracks != 2 {
        return Err(format!(
            "--tracks must be 1 or 2, not {}",
            options.tracks
        ));
    }
    if options.tracks > 1 && options.input_given {
        return Err("--channel picks one input; --tracks 2 records both".to_string());
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
    validate_targets(options)?;
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

/// One output file and the input that feeds it.
struct TrackPlan {
    path: String,
    input: usize,
    label: String,
}

/// The take's files. A one-track take writes exactly `--out`, as it always
/// did. A two-track take splits the stem: `take.wav` becomes `take-ch1.wav`
/// and `take-ch2.wav`, in the same directory (or relative to the same cwd).
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

fn track_plans(options: &Options, out: &str) -> Result<Vec<TrackPlan>, String> {
    let paths = take_paths(out, options.tracks)?;
    let inputs: Vec<usize> = if options.tracks == 1 {
        vec![options.input]
    } else {
        (0..options.tracks).collect()
    };
    Ok(paths
        .into_iter()
        .zip(inputs)
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
                first_track_path(options, &path),
                options.backend.name(),
                device,
                options.rate,
                options.start_at,
                insert_list(options, 1),
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
    probe_capture(
        options.backend,
        device,
        options.rate,
        options.frames,
        options.buffer,
    )?;

    let plans = track_plans(options, out)?;
    let frames = take_frames(seconds, options.rate);
    let queue = queue_blocks(options.backend, frames, options.frames, RECORD_CHANNELS);

    // One writer per track. Each spawn creates its WAV before any audio, so a
    // bad path fails here; a failure on a later track joins the writers already
    // started and removes only the files they created.
    let mut disks: Vec<DiskWriter> = Vec::with_capacity(plans.len());
    for (index, plan) in plans.iter().enumerate() {
        match DiskWriter::spawn(
            Path::new(&plan.path),
            options.rate,
            RECORD_CHANNELS as u16,
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

    let outcome = match options.backend {
        BackendKind::Null => record_null(options, seconds, &mut disks, &mut mixer),
        BackendKind::Alsa | BackendKind::PipeWire => {
            record_alsa(device, options, seconds, &mut disks, &mut mixer)
        }
        BackendKind::Jack => Err(
            "no JACK capture backend yet; use --backend alsa or null".to_string(),
        ),
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
        options.start_at,
        xruns,
        insert_list(options, 1),
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
    // The null backend is the source's own shape: one channel per track, so a
    // two-track take has two inputs to read even though both are the same sine.
    let mut device = NullDevice::new(options.rate, options.frames, track_count);
    if let Some(hz) = options.tone {
        device = device.with_tone(hz);
    }
    mixer.prepare(options.rate, options.frames);

    let total = take_frames(seconds, options.rate);
    let mut source = vec![0.0f32; options.frames * track_count];
    let mut mono = vec![0.0f32; options.frames];
    let mut stereo = vec![0.0f32; options.frames * RECORD_CHANNELS];
    let mut pcm = vec![0i16; options.frames * RECORD_CHANNELS];
    let mut remaining = total;
    while remaining > 0 {
        device
            .process(&mut source)
            .map_err(|error| format!("device: {error:?}"))?;
        let frames = remaining.min(options.frames as u64) as usize;
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
/// stereo block, run its strip, write its stereo result to its own writer.
/// Every buffer is sized once in [`CaptureSink::prepared`] from the shape ALSA
/// granted.
#[cfg(feature = "alsa")]
struct TakeChannel<'a> {
    mixer: &'a mut Mixer,
    disks: &'a mut [DiskWriter],
    mono: Vec<f32>,
    stereo: Vec<f32>,
    pcm: Vec<i16>,
}

#[cfg(feature = "alsa")]
impl jawn_audio::alsa_device::CaptureSink for TakeChannel<'_> {
    fn prepared(&mut self, rate: u32, period: usize) -> Result<(), String> {
        self.mixer.prepare(rate, period);
        self.mono = vec![0.0; period];
        self.stereo = vec![0.0; period * RECORD_CHANNELS];
        self.pcm = vec![0i16; period * RECORD_CHANNELS];
        Ok(())
    }

    fn block(&mut self, block: &[i16]) -> Result<(), String> {
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
            // One input per channel strip, not the sum of two: a mic on input 0
            // and an instrument on input 1 are different sources, and averaging
            // them mixes a vocal into a guitar.
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
        mono: Vec::new(),
        stereo: Vec::new(),
        pcm: Vec::new(),
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
