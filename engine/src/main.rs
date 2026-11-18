//! `jawn-audio`, the engine's command line.
//!
//! The null device is still the default, so every mode runs on a machine with
//! no sound card. `--backends` says which optional backends this build carries,
//! and `--loopback` measures the patch-cable round trip when one does
//! (docs/studio-audio-roadmap.md P1). `--serve` is the control socket the
//! manager drives: one JSON object per line, one client at a time
//! (docs/studio-audio-roadmap.md P2).

mod socket;

use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

use jawn_audio::{
    backends::{self, BackendKind, RunReport},
    decode, encode_datagram, loopback, mix_mono_into_stereo, peak, to_i16, Channel, Codec, Device,
    DiskWriter, Header, InsertKind, Mixer, NullDevice, PlayTrack, Playback, Strip, HEADER_LEN,
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
  --channels N    channels per frame (default 2, 1..=32)
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
  --channels N    capture channels to ask the device for (default 2, 1..=32)
  --tracks N      tracks to write, 1..=channels (default 1)
  --inputs LIST   which device channels become tracks, e.g. 2,0,3
                  (default 0..tracks, in track order)
  --gain N        channel trim, linear (default 1.0)
  --pan N         channel pan, -1 left .. 1 right (default 0, centre)
  --channel N     which input a one-track take records (default input 0)
  --insert NAME   an insert, repeatable in chain order:
                  tone, distortion, delay, compressor or reverb
                  (reverb2 is accepted as the web's name; default none)
  --tone HZ       with the null backend, record a sine instead of silence
  --monitor FILE.wav
                  play FILE.wav to the outputs while this take records;
                  repeatable (--play --file FILE.wav is the same thing)
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
  the take's rate, and both start at the take's --start-at sample: alignment
  is by that stamp, not by a measured offset, so the player is assumed to
  begin at the take's first sample. A take reports
  \"playing\":N,\"monitor_frames\":M when a monitor ran (plus
  \"monitor_error\" if the player failed after the take started). Two takes at
  once are still refused; so are two playbacks.

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
                    tone, distortion, delay, compressor or reverb
  --json            accepted for symmetry: --play always prints its JSON line

  Every file gets its own strip and the strips are summed into the stereo
  output. Files share one timeline: playback starts at frame 0 of each (or at
  --start-at), so takes cut from the same transport stay lined up. They must
  share a sample rate; the rate comes from the files, not --rate. A 16-bit
  PCM WAV of one or two channels is playable; anything else is refused by
  name. As with --record, --gain 2:0.5, --pan 2:-1 and --insert 1:delay apply
  to one 1-based file, and an unprefixed knob applies to every file. The null
  backend plays as fast as it can; ALSA is paced by the card.

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
  --channels N    capture channels a take asks for (default 2, 1..=32)

--serve speaks one JSON object per line: record, param, status, stop,
quit. `record` takes \"out\", \"seconds\", \"start_at\", \"tracks\" and \"inputs\";
\"monitor\" is an array of absolute WAV paths played to the outputs while the
take records (an overdub; the monitor never enters the take). `play` may run
beside a recording's monitor, and `record` may start over a running playback.
Two takes at once, and two playbacks at once, are refused. One `stop` ends and
joins both roles, and `status` reports the take's state with \"playing\" and
\"monitor_frames\" beside it. `start_at` is the take's stamp and the monitor's
start sample: alignment is by that stamp, not a measured offset.
`tracks` is a count (one wire per input) or an array of per-track objects
{\"input\":N,\"gain\":G,\"pan\":P,\"inserts\":[NAMES]}, which arms that track's
real chain. `param` moves one knob of a running take's strip and answers when
the change is queued for the next block; `status` reports every track and
the gain, pan and inserts it was armed with.
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
    Play,
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
    /// `--file` in the order given; one strip per file for `--play`.
    files: Vec<String>,
    /// `--monitor` in the order given, or `--file` when `--play` accompanies
    /// `--record`: the takes played to the outputs while a new one records.
    monitor: Vec<String>,
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
        files: Vec::new(),
        monitor: Vec::new(),
        record_flag: false,
        play_flag: false,
        tracks: 1,
        inputs: Vec::new(),
        inputs_given: false,
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
            "--record" => {
                options.mode = Mode::Record;
                options.record_flag = true;
            }
            "--play" => {
                options.mode = Mode::Play;
                options.play_flag = true;
            }
            "--file" => options.files.push(value(&mut args, "--file")?),
            "--monitor" => options.monitor.push(value(&mut args, "--monitor")?),
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

    // These knobs describe a take's tracks, and `--record` is the only mode
    // that has them today; say so instead of accepting a knob that does
    // nothing. `--channel` keeps its old shape outside `--record` (it was
    // always accepted there) so this is not a regression for an existing call.
    let strips = matches!(options.mode, Mode::Record | Mode::Play);
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
        channels: options.channels,
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
    /// How many monitor files played while this take recorded (0 = no
    /// overdub), how far the player got, and why it stopped early, if it did.
    monitor_files: usize,
    monitor_frames: u64,
    monitor_error: String,
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
        format!(
            "{{\"ok\":{},\"path\":\"{}\",\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"frames\":{},\"dropped\":{},\"channels\":{},\"start_sample\":{},\"xruns\":{},\"inserts\":\"{}\"{}{},\"error\":\"{}\"}}",
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
            "take {}: {} frames at {} Hz, {} channels ({:.3} s), backend {}, device {}, start_sample {}, dropped {}, xruns {}, inserts {}{}{}",
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
            monitor
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
/// keeps the monitor out of the recording. `start_at` is the take's stamp, so
/// the alignment is by that stamp and not by a measured offset: the player is
/// assumed to begin at the take's first sample, and a clock that drifts (or a
/// device that starts late) is not corrected. `stop` ends the bus when the take
/// does; the two threads never wait on one another.
fn run_monitor(
    backend: BackendKind,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    tracks: Vec<PlayTrack>,
    start_at: u64,
    stop: Arc<AtomicBool>,
) -> Result<(u64, usize), String> {
    let mut playback = Playback::new(tracks, start_at)?;
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
            monitor_hardware(device, rate, period, buffer, &mut playback, &stop)
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
) -> Result<(u64, usize), String> {
    let total = playback.total_frames();
    let sink = MonitorSink { playback, stop };
    match jawn_audio::alsa_device::run_file_playback(device, rate, period, buffer, total, sink) {
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
) -> Result<(u64, usize), String> {
    let _ = (device, rate, period, buffer, playback, stop);
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
    let mut monitor_tracks: Vec<PlayTrack> = Vec::with_capacity(options.monitor.len());
    for path in &options.monitor {
        monitor_tracks.push(
            PlayTrack::from_wav(path.clone(), 1.0, 0.0, Vec::new())
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
    // never touches the take's writers, so it cannot enter the recording. Both
    // are aligned by the take's `start_at` stamp rather than a measured
    // offset: the player is assumed to begin at the take's first sample.
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
            let start_at = options.start_at;
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
}
