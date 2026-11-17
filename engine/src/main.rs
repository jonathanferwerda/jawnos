//! `jawn-audio`, the engine's command line.
//!
//! P1 has no sound card behind it yet, so every mode runs the null device. That
//! is deliberate: the binary is the seam the manager will spawn, and the suite
//! can only assert it if it runs on a machine with no audio at all.

use std::process::ExitCode;

use jawn_audio::{
    decode, encode_datagram, mix_mono_into_stereo, peak, Codec, Device, Header, NullDevice, Strip,
    HEADER_LEN,
};

const USAGE: &str = "\
jawn-audio — the JawnOS audio engine

  jawn-audio --check                      say whether a device is present
  jawn-audio --selftest                   run a block through the graph and protocol
  jawn-audio --run [options]              run a device for a while and report
  jawn-audio --version                    print the version
  jawn-audio --help                       this text

--run options:
  --seconds S     how long to run, in seconds (default 1)
  --rate HZ       sample rate (default 48000)
  --frames N      block size in frames (default 64)
  --channels N    channels per frame (default 2)
  --tone HZ       emit a sine instead of silence
  --json          one JSON line instead of prose

P1 has no ALSA, CoreAudio or WASAPI backend: every mode above runs the null
device, so the engine and its graph can be exercised with no sound card
(docs/studio-audio-roadmap.md).";

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Check,
    Run,
    SelfTest,
    Version,
    Help,
}

struct Options {
    mode: Mode,
    seconds: f64,
    rate: u32,
    frames: usize,
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
        seconds: 1.0,
        rate: 48_000,
        frames: 64,
        channels: 2,
        tone: None,
        json: false,
    };

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--check" => options.mode = Mode::Check,
            "--run" => options.mode = Mode::Run,
            "--selftest" => options.mode = Mode::SelfTest,
            "--version" | "-V" => options.mode = Mode::Version,
            "--help" | "-h" => options.mode = Mode::Help,
            "--json" => options.json = true,
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
            "--frames" => {
                let raw = value(&mut args, "--frames")?;
                options.frames = raw
                    .parse()
                    .map_err(|_| format!("--frames wants a block size, not `{raw}`"))?;
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
            println!("device: null (no ALSA, CoreAudio or WASAPI backend in this build)");
            println!(
                "shape: {} Hz, {} frames, {} channels",
                48_000, 64, 2
            );
            Ok(ExitCode::SUCCESS)
        }
        Mode::SelfTest => {
            self_test()?;
            Ok(ExitCode::SUCCESS)
        }
        Mode::Run => {
            run_device(&options)?;
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn value(args: &mut impl Iterator<Item = String>, flag: &str) -> Result<String, String> {
    args.next().ok_or_else(|| format!("{flag} wants a value"))
}

fn run_device(options: &Options) -> Result<(), String> {
    if options.frames == 0 {
        return Err("--frames must be at least 1".to_string());
    }
    if options.rate == 0 {
        return Err("--rate must be at least 1".to_string());
    }
    if options.channels == 0 {
        return Err("--channels must be at least 1".to_string());
    }
    if options.seconds < 0.0 {
        return Err("--seconds cannot be negative".to_string());
    }

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

    if options.json {
        println!(
            "{{\"device\":\"null\",\"rate\":{},\"frames\":{},\"channels\":{},\"blocks\":{},\"samples\":{},\"peak\":{:.6}}}",
            device.rate(),
            device.frames(),
            device.channels(),
            blocks,
            samples,
            loudest
        );
    } else {
        println!(
            "device null: {} blocks of {} frames at {} Hz ({} samples), peak {:.4}",
            blocks,
            device.frames(),
            device.rate(),
            samples,
            loudest
        );
    }
    Ok(())
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
