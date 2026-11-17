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
    NullDevice, Strip, WavWriter, HEADER_LEN,
};

/// A take is the interface's own shape: stereo at the sample rate in the
/// header. `--channels` is a `--run` option and is not silently reused here.
const RECORD_CHANNELS: usize = 2;
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
  --tone HZ       with the null backend, record a sine instead of silence
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
    Record,
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
    start_at: u64,
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
        start_at: 0,
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
            "--start-at" => {
                let raw = value(&mut args, "--start-at")?;
                options.start_at = raw
                    .parse()
                    .map_err(|_| format!("--start-at wants a sample count, not `{raw}`"))?;
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
        Mode::Record => run_record(&options),
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

/// What one `--record` produced, in the exact key order the JSON contract
/// names. A failed take keeps the same shape with `frames` at zero, so a caller
/// parses one struct either way.
struct TakeReport {
    ok: bool,
    path: String,
    backend: &'static str,
    device: String,
    rate: u32,
    frames: u64,
    channels: usize,
    start_sample: u64,
    xruns: usize,
    error: String,
}

impl TakeReport {
    fn success(
        path: String,
        backend: &'static str,
        device: String,
        rate: u32,
        frames: u64,
        start_sample: u64,
        xruns: usize,
    ) -> Self {
        TakeReport {
            ok: true,
            path,
            backend,
            device,
            rate,
            frames,
            channels: RECORD_CHANNELS,
            start_sample,
            xruns,
            error: String::new(),
        }
    }

    fn failure(
        path: String,
        backend: &'static str,
        device: String,
        rate: u32,
        start_sample: u64,
        error: String,
    ) -> Self {
        TakeReport {
            ok: false,
            path,
            backend,
            device,
            rate,
            frames: 0,
            channels: RECORD_CHANNELS,
            start_sample,
            xruns: 0,
            error,
        }
    }

    fn to_json(&self) -> String {
        format!(
            "{{\"ok\":{},\"path\":\"{}\",\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"frames\":{},\"channels\":{},\"start_sample\":{},\"xruns\":{},\"error\":\"{}\"}}",
            self.ok,
            loopback::json_escape(&self.path),
            loopback::json_escape(self.backend),
            loopback::json_escape(&self.device),
            self.rate,
            self.frames,
            self.channels,
            self.start_sample,
            self.xruns,
            loopback::json_escape(&self.error)
        )
    }

    fn prose(&self) -> String {
        let seconds = if self.rate == 0 {
            0.0
        } else {
            self.frames as f64 / self.rate as f64
        };
        format!(
            "take {}: {} frames at {} Hz, {} channels ({:.3} s), backend {}, device {}, start_sample {}, xruns {}",
            self.path,
            self.frames,
            self.rate,
            self.channels,
            seconds,
            self.backend,
            self.device,
            self.start_sample,
            self.xruns
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
    if options.channels != RECORD_CHANNELS {
        return Err(format!(
            "--record writes stereo; --channels must be {RECORD_CHANNELS}"
        ));
    }
    if options.seconds < 0.0 {
        return Err("--seconds cannot be negative".to_string());
    }
    Ok(())
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
fn record_take(options: &Options, path: &str, device: &str) -> Result<TakeReport, String> {
    // Answer "can this build/backend record?" before opening the output: a
    // backend that cannot run must not truncate a file the user named.
    record_support(options)?;

    let seconds = if options.seconds_given {
        options.seconds
    } else {
        RECORD_SECONDS
    };
    // Open and close the device before the file. A busy or missing device then
    // fails without truncating a path the caller named; the real open follows
    // inside the recording run.
    if matches!(options.backend, BackendKind::Alsa | BackendKind::PipeWire) {
        #[cfg(feature = "alsa")]
        jawn_audio::alsa_device::check_capture(
            device,
            options.rate,
            options.frames,
            options.buffer,
        )
        .map_err(|error| format!("cannot record: {error}"))?;
    }

    let mut writer = WavWriter::create(path, options.rate, RECORD_CHANNELS as u16, options.frames)
        .map_err(|error| format!("cannot write {path}: {error}"))?;

    let outcome = match options.backend {
        BackendKind::Null => record_null(options, seconds, &mut writer),
        BackendKind::Alsa | BackendKind::PipeWire => {
            record_alsa(device, options, seconds, &mut writer)
        }
        BackendKind::Jack => Err(
            "--record has no JACK capture backend yet; use --backend alsa or null".to_string(),
        ),
    };

    match outcome {
        Ok((rate, xruns)) => match writer.finish() {
            Ok(frames) => Ok(TakeReport::success(
                path.to_string(),
                options.backend.name(),
                device.to_string(),
                rate,
                frames,
                options.start_at,
                xruns,
            )),
            Err(error) => {
                let _ = std::fs::remove_file(path);
                Err(format!("cannot finish {path}: {error}"))
            }
        },
        Err(error) => {
            drop(writer);
            let _ = std::fs::remove_file(path);
            Err(error)
        }
    }
}

fn record_support(options: &Options) -> Result<(), String> {
    match options.backend {
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
            "--record has no JACK capture backend yet; use --backend alsa or null".to_string(),
        ),
    }
}

/// The null take: silence, or a sine, through the same block loop as hardware.
/// The frame buffer is allocated once; each block is sliced to the frames that
/// remain, so the take is exactly `--seconds` even when it is not a whole
/// number of periods.
fn record_null(
    options: &Options,
    seconds: f64,
    writer: &mut WavWriter,
) -> Result<(u32, usize), String> {
    let mut device = NullDevice::new(options.rate, options.frames, RECORD_CHANNELS);
    if let Some(hz) = options.tone {
        device = device.with_tone(hz);
    }

    let total = (seconds.max(0.0) * options.rate as f64).round() as u64;
    let mut block = vec![0.0f32; options.frames * RECORD_CHANNELS];
    let mut remaining = total;
    while remaining > 0 {
        device
            .process(&mut block)
            .map_err(|error| format!("device: {error:?}"))?;
        let frames = remaining.min(options.frames as u64) as usize;
        writer
            .write_f32(&block[..frames * RECORD_CHANNELS])
            .map_err(|error| format!("write take: {error}"))?;
        remaining -= frames as u64;
    }
    Ok((options.rate, 0))
}

#[cfg(feature = "alsa")]
fn record_alsa(
    device: &str,
    options: &Options,
    seconds: f64,
    writer: &mut WavWriter,
) -> Result<(u32, usize), String> {
    let report = jawn_audio::alsa_device::run_capture(
        device,
        options.rate,
        options.frames,
        options.buffer,
        seconds,
        |block| writer.write_i16(block).map_err(|error| error.to_string()),
    )?;
    // ALSA may grant a rate other than the one requested; the samples are at
    // the granted rate, so the header and the report must say that rate.
    writer
        .set_rate(report.rate)
        .map_err(|error| format!("cannot set the take rate: {error}"))?;
    Ok((report.rate, report.xruns))
}

#[cfg(not(feature = "alsa"))]
fn record_alsa(
    device: &str,
    options: &Options,
    seconds: f64,
    writer: &mut WavWriter,
) -> Result<(u32, usize), String> {
    let _ = (device, options, seconds, writer);
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
