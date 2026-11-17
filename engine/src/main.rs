//! `jawn-audio`, the engine's command line.
//!
//! The null device is still the default, so every mode runs on a machine with
//! no sound card. `--backends` says which optional backends this build carries,
//! and `--loopback` measures the patch-cable round trip when one does
//! (docs/studio-audio-roadmap.md P1).

use std::process::ExitCode;

use jawn_audio::{
    backends::{self, BackendKind, RunReport},
    decode, encode_datagram, loopback, mix_mono_into_stereo, peak, Codec, Device, Header,
    NullDevice, Strip, HEADER_LEN,
};

const USAGE: &str = "\
jawn-audio — the JawnOS audio engine

  jawn-audio --check                      say which backends are present
  jawn-audio --backends [--json]          report device-backend availability
  jawn-audio --selftest                   run a block through the graph and protocol
  jawn-audio --run [options]              run a device for a while and report
  jawn-audio --loopback [options]         measure the round trip through a patch cable
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

--loopback options:
  --backend N     null (default), alsa, pipewire or jack
  --device NAME   ALSA PCM name (alsa defaults to hw:1,0; pipewire uses default)
  --period N      period/block size in frames (default 64)
  --buffer N      buffer size in frames (default 256)
  --rate HZ       sample rate (default 48000)
  --json          one JSON line instead of prose

The null backend needs no sound card. ALSA and JACK exist only in a build with
--features alsa and/or --features jack; pipewire uses the ALSA `default` PCM.
A loopback needs the interface's output patched into its input.";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Check,
    Backends,
    Run,
    Loopback,
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
        json: false,
    };

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--check" => options.mode = Mode::Check,
            "--backends" => options.mode = Mode::Backends,
            "--run" => options.mode = Mode::Run,
            "--loopback" => options.mode = Mode::Loopback,
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
            other => return Err(format!("unknown option `{other}` (try --help)")),
        }
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
