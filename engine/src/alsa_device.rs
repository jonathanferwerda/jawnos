//! Raw ALSA playback and the patch-cable loopback, behind `--features alsa`.
//!
//! The target is a USB class-compliant interface (a PCM2902), which accepts
//! only 48-sample periods at 48 kHz. We ask for the requested period with
//! `Near` and report what was granted, so a 64-frame block is honestly a block
//! spread across two USB frames rather than an imaginary 64-sample period
//! (docs/studio-audio-roadmap.md §2, P1).

use std::f32::consts::TAU;

use alsa::pcm::{Access, Format, HwParams, State, PCM};
use alsa::{Direction, ValueOr};

use crate::backends::RunReport;
use crate::loopback::{self, LoopbackReport};

const CHANNELS: u32 = 2;

/// One open and configured PCM stream, plus the shape ALSA actually granted.
struct Stream {
    pcm: PCM,
    rate: u32,
    period: usize,
    buffer: usize,
}

fn sample_format() -> Format {
    if cfg!(target_endian = "little") {
        Format::S16LE
    } else {
        Format::S16BE
    }
}

fn open(
    device: &str,
    direction: Direction,
    rate: u32,
    period: usize,
    buffer: usize,
) -> Result<Stream, String> {
    let pcm = PCM::new(device, direction, false)
        .map_err(|error| format!("cannot open {device}: {error}"))?;

    // Fill the hardware parameter space, then ask for the requested shape and
    // read back the final one from the applied parameters.
    {
        let params =
            HwParams::any(&pcm).map_err(|error| format!("{device}: hardware parameters: {error}"))?;
        params
            .set_access(Access::RWInterleaved)
            .map_err(|error| format!("{device}: interleaved access: {error}"))?;
        params
            .set_channels(CHANNELS)
            .map_err(|error| format!("{device}: {CHANNELS} channels: {error}"))?;
        params
            .set_format(sample_format())
            .map_err(|error| format!("{device}: S16 format: {error}"))?;
        params
            .set_rate(rate, ValueOr::Nearest)
            .map_err(|error| format!("{device}: {rate} Hz: {error}"))?;
        params
            .set_period_size_near(period as i64, ValueOr::Nearest)
            .map_err(|error| format!("{device}: {period}-frame period: {error}"))?;
        params
            .set_buffer_size_near(buffer as i64)
            .map_err(|error| format!("{device}: {buffer}-frame buffer: {error}"))?;
        pcm.hw_params(&params)
            .map_err(|error| format!("{device}: apply hardware parameters: {error}"))?;
    }

    let applied = pcm
        .hw_params_current()
        .map_err(|error| format!("{device}: read hardware parameters: {error}"))?;
    let rate = applied.get_rate().unwrap_or(rate);
    let period = applied.get_period_size().unwrap_or(period as i64).max(1) as usize;
    let buffer = applied
        .get_buffer_size()
        .unwrap_or(buffer as i64)
        .max(period as i64) as usize;
    drop(applied);

    pcm.prepare()
        .map_err(|error| format!("{device}: prepare: {error}"))?;

    Ok(Stream {
        pcm,
        rate,
        period,
        buffer,
    })
}

fn to_i16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
}

/// Play `seconds` of silence or a sine through `device`. Returns the shape ALSA
/// granted, the peak, and the number of underruns recovered from.
pub fn run_playback(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    seconds: f64,
    tone: Option<f32>,
) -> Result<RunReport, String> {
    let stream = open(device, Direction::Playback, rate, period, buffer)?;
    let io = stream
        .pcm
        .io_i16()
        .map_err(|error| format!("{device}: S16 stream: {error}"))?;

    let frames = stream.period.max(1);
    let total_frames = (seconds * stream.rate as f64).round();
    let blocks = (total_frames / frames as f64) as usize;
    let step = tone.map(|hz| TAU * hz / stream.rate as f32);

    let mut block = vec![0i16; frames * CHANNELS as usize];
    let mut phase = 0.0f32;
    let mut peak = 0.0f32;
    let mut xruns = 0usize;

    for _ in 0..blocks {
        for frame in block.chunks_mut(CHANNELS as usize) {
            let sample = if let Some(step) = step {
                let value = phase.sin();
                phase = (phase + step) % TAU;
                value
            } else {
                0.0
            };
            peak = peak.max(sample.abs());
            let quantised = to_i16(sample);
            for out in frame.iter_mut() {
                *out = quantised;
            }
        }

        // `writei` counts frames; the buffer is interleaved, so advance by
        // frames * channels. A partial write is normal near the end of a block.
        let mut written = 0usize;
        while written < block.len() {
            match io.writei(&block[written..]) {
                Ok(0) => break,
                Ok(count) => written += count * CHANNELS as usize,
                Err(error) => {
                    let message = format!("{error}");
                    match stream.pcm.try_recover(error, true) {
                        Ok(()) => xruns += 1,
                        Err(_) => return Err(format!("{device}: write: {message}")),
                    }
                }
            }
        }
    }

    // Let the last buffered period reach the device; a drain timeout is not a
    // failure of the run itself.
    let _ = stream.pcm.drain();

    Ok(RunReport {
        backend: "alsa",
        device: device.to_string(),
        rate: stream.rate,
        frames,
        buffer: stream.buffer,
        channels: CHANNELS as usize,
        blocks,
        samples: blocks * frames * CHANNELS as usize,
        peak,
        xruns,
    })
}

/// What one real-device capture produced: the shape ALSA granted, and the
/// frames that actually reached the caller's sink.
#[derive(Debug, Clone)]
pub struct CaptureReport {
    pub rate: u32,
    pub period: usize,
    pub buffer: usize,
    pub channels: usize,
    pub frames: u64,
    pub xruns: usize,
}

/// Capture `seconds` of the input, handing each block to `sink` as interleaved
/// S16 samples. The sink does the writing, so this module stays about the
/// device and the take's WAV layout stays in `wav` (docs/studio-audio-roadmap.md
/// §7, P2).
///
/// The final block is short when the requested duration is not a whole number
/// of periods: the take is exactly `seconds`, not padded to the block size.
/// Answer "can this device be opened for capture?" and close it again.
///
/// `--record` asks this before it creates the output file, so a take that
/// cannot start never truncates a path the caller already named. Opening twice
/// costs a millisecond and saves an existing take; the real open follows.
pub fn check_capture(device: &str, rate: u32, period: usize, buffer: usize) -> Result<(), String> {
    let stream = open(device, Direction::Capture, rate, period, buffer)?;
    let _ = stream.pcm.drop();
    Ok(())
}

pub fn run_capture<F>(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    seconds: f64,
    mut sink: F,
) -> Result<CaptureReport, String>
where
    F: FnMut(&[i16]) -> Result<(), String>,
{
    let stream = open(device, Direction::Capture, rate, period, buffer)?;
    let io = stream
        .pcm
        .io_i16()
        .map_err(|error| format!("{device}: S16 stream: {error}"))?;

    // Capture starts when read is called, but starting it explicitly makes the
    // first frame's position unambiguous and matches the loopback path.
    stream
        .pcm
        .start()
        .map_err(|error| format!("{device}: start capture: {error}"))?;

    let frames = stream.period.max(1);
    let total = (seconds.max(0.0) * stream.rate as f64).round() as u64;
    let mut remaining = total;
    let mut captured = 0u64;
    let mut xruns = 0usize;
    let mut block = vec![0i16; frames * CHANNELS as usize];

    while remaining > 0 {
        let want = remaining.min(frames as u64) as usize;
        let slice = &mut block[..want * CHANNELS as usize];
        match io.readi(slice) {
            Ok(0) => break,
            Ok(got) => {
                let got = got.min(want);
                sink(&slice[..got * CHANNELS as usize])
                    .map_err(|error| format!("{device}: write take: {error}"))?;
                captured += got as u64;
                remaining -= got as u64;
            }
            Err(error) => {
                let message = format!("{error}");
                match stream.pcm.try_recover(error, true) {
                    Ok(()) => xruns += 1,
                    Err(_) => return Err(format!("{device}: capture: {message}")),
                }
            }
        }
    }

    let _ = stream.pcm.drop();

    Ok(CaptureReport {
        rate: stream.rate,
        period: frames,
        buffer: stream.buffer,
        channels: CHANNELS as usize,
        frames: captured,
        xruns,
    })
}

/// Write one click and find it again. Capture starts first; playback starts a
/// moment later, so `precision_samples` is the period ALSA granted, not a
/// claim of sample alignment.
pub fn loopback(
    backend: &'static str,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> LoopbackReport {
    match measure(device, rate, period, buffer) {
        Ok(result) => LoopbackReport::success(
            backend,
            device,
            result.rate,
            period,
            buffer,
            result.samples,
            result.precision,
            "unlinked",
        ),
        Err(failure) => LoopbackReport::failure(
            backend,
            device,
            rate,
            period,
            buffer,
            failure.precision,
            "unlinked",
            failure.reason,
        ),
    }
}

struct Measurement {
    samples: u64,
    rate: u32,
    precision: u64,
}

struct Failure {
    reason: String,
    precision: u64,
}

fn measure(
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> Result<Measurement, Failure> {
    let requested_period = period.max(1) as u64;
    let fail = |reason: String| Failure {
        reason,
        precision: requested_period,
    };

    let capture = open(device, Direction::Capture, rate, period, buffer).map_err(fail)?;
    let playback = open(device, Direction::Playback, rate, period, buffer).map_err(fail)?;
    let precision = capture.period.max(1) as u64;

    // Start playback on a full buffer. A short click alone would otherwise
    // auto-start on the first write and underrun before the explicit start; a
    // threshold larger than the buffer is rejected by `snd_pcm_start`.
    {
        let sw = playback
            .pcm
            .sw_params_current()
            .map_err(|error| fail(format!("{device}: software parameters: {error}")))?;
        let threshold = (playback.buffer as i64).max(1);
        sw.set_start_threshold(threshold)
            .map_err(|error| fail(format!("{device}: start threshold: {error}")))?;
        playback
            .pcm
            .sw_params(&sw)
            .map_err(|error| fail(format!("{device}: software parameters: {error}")))?;
    }

    let capture_io = capture
        .pcm
        .io_i16()
        .map_err(|error| fail(format!("{device}: capture stream: {error}")))?;
    let playback_io = playback
        .pcm
        .io_i16()
        .map_err(|error| fail(format!("{device}: playback stream: {error}")))?;

    // Capture first: a click written into a stopped capture stream would be
    // gone before anything listened.
    capture
        .pcm
        .start()
        .map_err(|error| fail(format!("{device}: start capture: {error}")))?;

    // Learn the room's noise floor before sending anything.
    let preroll_frames =
        ((capture.rate as f64 * loopback::PRE_ROLL_MS as f64 / 1000.0).round() as usize).max(1);
    let mut noise_peak = 0.0f32;
    let mut read_frames = 0usize;
    let mut chunk = vec![0i16; capture.period.max(1) * CHANNELS as usize];
    while read_frames < preroll_frames {
        let want = (preroll_frames - read_frames).min(capture.period.max(1));
        let got = capture_io
            .readi(&mut chunk[..want * CHANNELS as usize])
            .map_err(|error| fail(format!("{device}: capture: {error}")))?;
        if got == 0 {
            break;
        }
        for frame in chunk[..got * CHANNELS as usize].chunks(CHANNELS as usize) {
            for sample in frame {
                noise_peak = noise_peak.max(sample.unsigned_abs() as f32 / 32768.0);
            }
        }
        read_frames += got;
    }
    let threshold = loopback::threshold(noise_peak);

    // The capture position when playback begins. Everything before this is our
    // own pre-roll and start-up, not latency, so it must not be in the number.
    let origin = read_frames as u64;

    // One full playback buffer: the click, then silence to the start
    // threshold. The first buffer lasts longer than the round trip at the
    // target's 256-frame buffer, so playback has not underrun before the click
    // comes back.
    let click_frames = loopback::click_frames();
    let play_frames = playback.buffer.max(click_frames.len());
    let mut click = vec![0i16; play_frames * CHANNELS as usize];
    for (frame, sample) in click_frames.iter().enumerate() {
        let quantised = to_i16(*sample);
        click[frame * CHANNELS as usize] = quantised;
        click[frame * CHANNELS as usize + 1] = quantised;
    }

    // Buffer the click while playback is still stopped, then start playback:
    // the two streams are not linked, which is exactly why the result carries
    // a one-period uncertainty. A short write may have auto-started playback
    // already, so only start a stream that is still prepared.
    let mut written = 0usize;
    while written < click.len() {
        let got = playback_io
            .writei(&click[written..])
            .map_err(|error| fail(format!("{device}: playback: {error}")))?;
        if got == 0 {
            return Err(fail(format!("{device}: playback wrote nothing")));
        }
        written += got * CHANNELS as usize;
    }
    if playback.pcm.state() != State::Running {
        let state = playback.pcm.state();
        playback
            .pcm
            .start()
            .map_err(|error| fail(format!("{device}: start playback in state {state:?}: {error}")))?;
    }

    let limit = capture.rate as usize * loopback::CAPTURE_SECONDS as usize;
    let mut position = read_frames;
    let mut peak_seen = 0.0f32;
    while position < limit {
        let want = (limit - position).min(capture.period.max(1));
        let got = capture_io
            .readi(&mut chunk[..want * CHANNELS as usize])
            .map_err(|error| fail(format!("{device}: capture: {error}")))?;
        if got == 0 {
            continue;
        }
        for (offset, frame) in chunk[..got * CHANNELS as usize]
            .chunks(CHANNELS as usize)
            .enumerate()
        {
            let level = frame
                .iter()
                .fold(0.0f32, |loudest, sample| {
                    loudest.max(sample.unsigned_abs() as f32 / 32768.0)
                });
            peak_seen = peak_seen.max(level);
            if level >= threshold {
                let _ = playback.pcm.drop();
                let _ = capture.pcm.drop();
                let elapsed = (position + offset) as u64;
                return Ok(Measurement {
                    samples: elapsed.saturating_sub(origin),
                    rate: capture.rate,
                    precision,
                });
            }
        }
        position += got;
    }

    let _ = playback.pcm.drop();
    let _ = capture.pcm.drop();
    Err(fail(format!(
        "no signal above the noise floor (threshold {threshold:.3}, loudest {peak_seen:.3}) within {} s (is the output patched into the input?)",
        loopback::CAPTURE_SECONDS
    )))
}
