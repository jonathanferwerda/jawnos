//! The Android capture seam: one Oboe input stream, 48 kHz mono, to a local WAV.
//!
//! This is the first slice of `docs/studio-oboe-slice.md` §2.4. It follows the
//! ALSA module's shape (free functions, not a `Device` implementation), because
//! the only real backend in the tree already bypasses `Device` (§3).
//!
//! The data callback is the audio path, so it does no allocation, no locking
//! and no logging. It converts the granted S16 mono block into the fixed
//! [`crate::monbus`] ring and raises an atomic peak; a writer thread drains the
//! ring into the existing [`DiskWriter`], which owns the WAV and its header
//! cadence. A full ring drops the newest frames and counts them, exactly as the
//! Linux monitor bus does.
//!
//! The report carries both ends of that accounting: `frames_captured` from the
//! callback and `frames_written` from the WAV, plus the overflow split
//! (`dropped_ring` + `dropped_disk`), so a short take explains itself instead of
//! leaving the difference to be inferred.
//!
//! Capture only in this slice: Oboe has no `FullDuplex` mode, so the duplex
//! (monitor-out) variant reads the input from an output callback and arrives
//! with the headphone-only monitoring half.
//!
//! The module also exports the plain-C ABI the app's service calls
//! (`jawn_audio_start`, `jawn_audio_stop`, `jawn_audio_status`,
//! `jawn_audio_free`). The app's Java wrapper marshals the strings; no `jni`
//! crate is needed (docs/studio-oboe-slice.md §2.4).

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use oboe::{
    AudioInputCallback, AudioInputStreamSafe, AudioOutputCallback, AudioOutputStreamSafe,
    AudioStream, AudioStreamBase, AudioStreamBuilder, AudioStreamSafe, DataCallbackResult, Input,
    Mono, Output, PerformanceMode, SharingMode,
};

use crate::disk::DiskWriter;
use crate::monbus::{self, Consumer, Producer};
use crate::plan::{ChannelPlan, Strip};
use crate::roundtrip as rt;

/// The rate the slice asks for. The report carries the rate actually granted;
/// a device that refuses 48 kHz is reported, never silently resampled.
pub const REQUESTED_RATE: u32 = 48_000;

/// The most frames one callback may hand us. Sized once at setup; a callback
/// that arrives larger is truncated and its extra frames counted, never
/// allocated for on the audio thread.
const MAX_CALLBACK_FRAMES: usize = 32_768;

/// Ring capacity: about 341 ms at 48 kHz, enough to ride out a disk stall. A
/// full ring discards the newest frames and counts them.
const RING_FRAMES: usize = 16_384;

/// What one Oboe take actually got. The granted values, not the requested ones.
#[derive(Debug, Clone)]
pub struct OboeReport {
    pub device: String,
    /// `getSampleRate()` after open.
    pub rate: u32,
    /// Frames per data callback (the granted burst).
    pub frames: usize,
    /// `getBufferSizeInFrames()`.
    pub buffer_frames: usize,
    pub channels: usize,
    /// `getSharingMode()`: `"Exclusive"` or `"Shared"`.
    pub sharing: String,
    /// `getPerformanceMode()`: `"LowLatency"`, `"None"` or `"PowerSaving"`.
    pub performance: String,
    /// `getXRunCount()`; 0 when the stream cannot report it.
    pub xruns: u32,
    /// Every frame the callback received, including frames the ring dropped.
    pub frames_captured: u64,
    /// Frames the WAV actually holds: the `DiskWriter::finish` count. Zero
    /// when the take ran without an `out` path.
    pub frames_written: u64,
    /// Frames captured but never written: `dropped_ring + dropped_disk`. With a
    /// WAV this is exactly `frames_captured - frames_written`.
    pub dropped: u64,
    /// Of `dropped`: frames the monitor ring discarded because the drain fell
    /// behind (the newest frames are dropped when the ring is full).
    pub dropped_ring: u64,
    /// Of `dropped`: frames the disk queue refused because the writer thread
    /// fell behind, so the block never reached the file.
    pub dropped_disk: u64,
    /// Frames the device handed in one callback larger than
    /// `MAX_CALLBACK_FRAMES`, so they were never offered to the ring. These are
    /// outside `frames_captured`; normally zero.
    pub dropped_callback: u64,
    pub peak: f32,
    /// What the take ran through: the plan's own label (`tone+delay`), or
    /// `raw` when no plan was given. The sidecar carries this, so a WAV on disk
    /// says which strip made it.
    pub plan: String,
}

/// One capture take. `out` writes a 16-bit mono WAV at the granted rate; without
/// it the take still runs and reports, which is what `--run` measures.
pub fn run_duplex(
    device_id: Option<i32>,
    seconds: f64,
    out: Option<&str>,
) -> Result<OboeReport, String> {
    run_capture(device_id, seconds, out, &AtomicBool::new(false))
}

/// The same take with a stop flag, so the service's `stop` call can end a long
/// recording without waiting for its deadline. `seconds <= 0` means "until the
/// flag is set". No plan is the raw path.
pub fn run_capture(
    device_id: Option<i32>,
    seconds: f64,
    out: Option<&str>,
    stop: &AtomicBool,
) -> Result<OboeReport, String> {
    run_capture_plan(device_id, seconds, out, stop, None)
}

/// The plan-carrying take: the same capture, with one [`ChannelPlan`] applied
/// in the drain thread. The callback still hands over the raw duplicated mono;
/// the strip runs where a block is written, never in the callback.
pub fn run_capture_plan(
    device_id: Option<i32>,
    seconds: f64,
    out: Option<&str>,
    stop: &AtomicBool,
    plan: Option<ChannelPlan>,
) -> Result<OboeReport, String> {
    let peak = Arc::new(AtomicU32::new(0));
    let frames = Arc::new(AtomicU64::new(0));
    let callbacks = Arc::new(AtomicU64::new(0));
    // Two independent losses: the callback's own truncation, and the ring's
    // overflow when the drain fell behind. Both are measured so the report can
    // split them instead of leaving the gap unexplained.
    let dropped_callback = Arc::new(AtomicU64::new(0));
    let dropped_ring = Arc::new(AtomicU64::new(0));
    let enabled = Arc::new(AtomicBool::new(true));

    let attempt = |sharing: SharingMode| -> Result<
        (oboe::AudioStreamAsync<Input, CaptureCallback>, Consumer),
        String,
    > {
        let (producer, consumer) = monbus::new(RING_FRAMES);
        let callback = CaptureCallback::new(
            producer,
            Arc::clone(&peak),
            Arc::clone(&frames),
            Arc::clone(&callbacks),
            Arc::clone(&dropped_callback),
            Arc::clone(&dropped_ring),
            Arc::clone(&enabled),
        );
        open_stream(device_id, sharing, callback).map(|stream| (stream, consumer))
    };

    // Exclusive first for the lowest latency, then Shared: Android grants
    // exclusive capture only when nobody else owns the mic, which is normal on
    // a phone with an assistant listening.
    let (mut stream, consumer) = match attempt(SharingMode::Exclusive) {
        Ok(pair) => pair,
        Err(exclusive) => attempt(SharingMode::Shared).map_err(|shared| {
            format!(
                "cannot open an Oboe input stream (exclusive: {exclusive}; shared: {shared})"
            )
        })?,
    };

    let rate = stream.get_sample_rate().max(1) as u32;
    let frames_per_burst = stream.get_frames_per_burst().max(1) as usize;
    let buffer_frames = stream.get_buffer_size_in_frames().max(0) as usize;
    let channels = stream.get_channel_count() as i32 as usize;
    let sharing = format!("{:?}", stream.get_sharing_mode());
    let performance = format!("{:?}", stream.get_performance_mode());
    let xruns = stream.get_xrun_count().unwrap_or(0).max(0) as u32;
    // The report names the strip before the take starts, so a failed drain
    // still says what was meant to run.
    let plan_label = plan
        .as_ref()
        .map(|plan| plan.label())
        .unwrap_or_else(|| "raw".to_string());

    // The WAV is created before the stream starts, at the rate the device
    // granted. A bad path fails here, not after the take began.
    let disk = match out {
        Some(path) => Some(
            DiskWriter::spawn(Path::new(path), rate, 1, frames_per_burst, 8)
                .map_err(|error| format!("cannot write {path}: {error}"))?,
        ),
        None => None,
    };

    let sink_stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&sink_stop);
    let period = frames_per_burst;
    let sink = thread::Builder::new()
        .name("jawn-audio-oboe-disk".to_string())
        .spawn(move || drain_ring(consumer, disk, period, &thread_stop, plan, rate))
        .map_err(|error| format!("cannot start the Oboe disk thread: {error}"))?;

    if let Err(error) = stream.start() {
        enabled.store(false, Ordering::Release);
        sink_stop.store(true, Ordering::Release);
        let _ = sink.join();
        return Err(format!("cannot start the Oboe stream: {error}"));
    }

    let deadline = if seconds > 0.0 {
        Some(Instant::now() + Duration::from_secs_f64(seconds))
    } else {
        None
    };
    loop {
        if stop.load(Ordering::Acquire) {
            break;
        }
        match deadline {
            Some(deadline) if Instant::now() >= deadline => break,
            _ => thread::sleep(Duration::from_millis(10)),
        }
    }

    // Stop first, so the callback cannot push a frame after the writer was
    // told the take is over. `stop` blocks until the stream is stopped; a stop
    // error (a device that vanished) does not invalidate the frames already on
    // disk, so the report below still tells the truth.
    enabled.store(false, Ordering::Release);
    let _ = stream.stop();
    sink_stop.store(true, Ordering::Release);
    let drained = sink
        .join()
        .map_err(|_| "the Oboe disk thread panicked".to_string())?
        .map_err(|error| format!("cannot finish the Oboe take: {error}"))?;

    let frames_captured = frames.load(Ordering::Acquire);
    let dropped_ring = dropped_ring.load(Ordering::Acquire);
    let dropped_disk = drained.dropped;
    // Everything the callback handed the ring that never reached the file. With
    // a WAV this also equals `frames_captured - frames_written`; without one,
    // both are zero and this honestly reports no overflow loss.
    let dropped = dropped_ring + dropped_disk;

    Ok(OboeReport {
        device: device_label(device_id),
        rate,
        frames: frames_per_burst,
        buffer_frames,
        channels,
        sharing,
        performance,
        xruns,
        frames_captured,
        frames_written: drained.written,
        dropped,
        dropped_ring,
        dropped_disk,
        dropped_callback: dropped_callback.load(Ordering::Acquire),
        peak: f32::from_bits(peak.load(Ordering::Acquire)),
        plan: plan_label,
    })
}

/// A device id is the Android HAL's own label; without one, the HAL picks.
fn device_label(device_id: Option<i32>) -> String {
    match device_id {
        Some(id) => format!("device {id}"),
        None => "default".to_string(),
    }
}

// --- the duplex round-trip probe (docs/studio-mobile-audio.md §6) -------------
//
// This is the *engine* half of the measurement. It is deliberately not
// exported through the JNI shim or the Studio panel yet: the measurement has not
// been proven on a device. What is testable without hardware is in
// `roundtrip.rs` (the chirp, the correlation, the timestamp arithmetic); what
// remains is whether two Oboe streams on the phone grant comparable
// CLOCK_MONOTONIC timestamps and whether the built-in speaker/mic path yields a
// strong enough correlation. Until a real number exists, a button would invite a
// false reading.

/// What one duplex probe got. All the granted shapes are reported beside the
/// number, because a round trip without its buffer and sharing mode is not a
/// measurement.
#[derive(Debug, Clone)]
pub struct RoundTripReport {
    pub device_in: String,
    pub device_out: String,
    pub rate: u32,
    pub input_channels: usize,
    pub output_channels: usize,
    pub input_buffer_frames: usize,
    pub output_buffer_frames: usize,
    pub input_burst: usize,
    pub output_burst: usize,
    pub sharing_input: String,
    pub sharing_output: String,
    pub performance_input: String,
    pub performance_output: String,
    pub xruns_input: u32,
    pub xruns_output: u32,
    pub input_frames: u64,
    pub output_frames: u64,
    pub input_dropped: u64,
    pub click_frame: i64,
    pub heard_frame: i64,
    pub score: f32,
    pub method: String,
    pub round_trip_ms: f64,
    pub round_trip_frames: f64,
}

impl RoundTripReport {
    /// The status line the app would show. Not wired to the panel; kept beside
    /// the report so a later JNI method has one shape to marshal.
    pub fn to_json(&self) -> String {
        format!(
            "{{\"ok\":true,\"backend\":\"oboe\",\"probe\":\"roundtrip\",\"method\":\"{}\",\"device_in\":\"{}\",\"device_out\":\"{}\",\"rate\":{},\"channels_in\":{},\"channels_out\":{},\"buffer_in\":{},\"buffer_out\":{},\"burst_in\":{},\"burst_out\":{},\"sharing_in\":\"{}\",\"sharing_out\":\"{}\",\"performance_in\":\"{}\",\"performance_out\":\"{}\",\"xruns_in\":{},\"xruns_out\":{},\"input_frames\":{},\"output_frames\":{},\"input_dropped\":{},\"click_frame\":{},\"heard_frame\":{},\"score\":{:.3},\"round_trip_ms\":{:.3},\"round_trip_frames\":{:.1}}}",
            json_escape(&self.method),
            json_escape(&self.device_in),
            json_escape(&self.device_out),
            self.rate,
            self.input_channels,
            self.output_channels,
            self.input_buffer_frames,
            self.output_buffer_frames,
            self.input_burst,
            self.output_burst,
            json_escape(&self.sharing_input),
            json_escape(&self.sharing_output),
            json_escape(&self.performance_input),
            json_escape(&self.performance_output),
            self.xruns_input,
            self.xruns_output,
            self.input_frames,
            self.output_frames,
            self.input_dropped,
            self.click_frame,
            self.heard_frame,
            self.score,
            self.round_trip_ms,
            self.round_trip_frames,
        )
    }
}

/// One short chirp out, one capture back: the duplex probe.
///
/// Both streams are opened at 48 kHz mono f32, Exclusive first and Shared as a
/// pair; a mixed grant is refused rather than measured. The click plays a
/// quarter second after the streams start (so the buffers are settled), the
/// capture runs 1.5 s, and the result is the difference of the two streams'
/// own `getTimestamp(CLOCK_MONOTONIC)` readings at the played and heard frames.
///
/// A device that cannot open both streams, or a stream that does not report
/// timestamps, answers a sentence. Nothing here panics on a HAL refusal.
pub fn run_roundtrip(
    device_in: Option<i32>,
    device_out: Option<i32>,
) -> Result<RoundTripReport, String> {
    let try_pair = |sharing: SharingMode| -> Result<ProbePair, String> {
        let (producer, consumer) = monbus::new(RING_FRAMES);
        let frames = Arc::new(AtomicU64::new(0));
        let dropped = Arc::new(AtomicU64::new(0));
        let enabled = Arc::new(AtomicBool::new(true));
        let input_callback = ProbeInput::new(
            producer,
            Arc::clone(&frames),
            Arc::clone(&dropped),
            Arc::clone(&enabled),
        );
        let mut input = open_probe_input(device_in, sharing, input_callback)
            .map_err(|error| format!("input ({sharing:?}): {error}"))?;
        let rate = input.get_sample_rate().max(1) as u32;
        if rate != REQUESTED_RATE {
            return Err(format!(
                "the input granted {rate} Hz, not {REQUESTED_RATE}; a round trip across two rates is not measured"
            ));
        }

        let click = rt::click(rate);
        let click_frame = (rate as i64 / 4).max(1);
        let played = Arc::new(AtomicBool::new(false));
        let output_frames = Arc::new(AtomicU64::new(0));
        let output_callback = ProbeOutput::new(
            click,
            click_frame,
            Arc::clone(&played),
            Arc::clone(&output_frames),
        );
        let mut output = match open_probe_output(device_out, sharing, output_callback) {
            Ok(output) => output,
            Err(error) => {
                let _ = input.stop();
                return Err(format!("output ({sharing:?}): {error}"));
            }
        };
        if output.get_sample_rate().max(1) as u32 != rate {
            let _ = input.stop();
            let _ = output.stop();
            return Err(format!(
                "the output granted {} Hz and the input {rate} Hz; a round trip across two rates is not measured",
                output.get_sample_rate()
            ));
        }
        Ok(ProbePair {
            input,
            output,
            consumer,
            frames,
            dropped,
            enabled,
            played,
            output_frames,
            click_frame,
            rate,
        })
    };

    let mut pair = match try_pair(SharingMode::Exclusive) {
        Ok(pair) => pair,
        Err(exclusive) => try_pair(SharingMode::Shared).map_err(|shared| {
            format!("cannot open both an Oboe input and output: {exclusive}; then {shared}")
        })?,
    };

    let input_burst = pair.input.get_frames_per_burst().max(1) as usize;
    let output_burst = pair.output.get_frames_per_burst().max(1) as usize;
    let input_buffer = pair.input.get_buffer_size_in_frames().max(0) as usize;
    let output_buffer = pair.output.get_buffer_size_in_frames().max(0) as usize;
    let input_channels = pair.input.get_channel_count() as i32 as usize;
    let output_channels = pair.output.get_channel_count() as i32 as usize;
    let sharing_input = format!("{:?}", pair.input.get_sharing_mode());
    let sharing_output = format!("{:?}", pair.output.get_sharing_mode());
    let performance_input = format!("{:?}", pair.input.get_performance_mode());
    let performance_output = format!("{:?}", pair.output.get_performance_mode());

    // Input first: the capture must be running before the click can be heard.
    if let Err(error) = pair.input.start() {
        pair.enabled.store(false, Ordering::Release);
        return Err(format!("cannot start the probe input: {error}"));
    }
    if let Err(error) = pair.output.start() {
        pair.enabled.store(false, Ordering::Release);
        let _ = pair.input.stop();
        return Err(format!("cannot start the probe output: {error}"));
    }

    let mut captured: Vec<f32> = Vec::with_capacity(pair.rate as usize * 2);
    let mut stereo = vec![0.0f32; input_burst.max(1) * 2];
    let mut input_stamp: Option<rt::StreamStamp> = None;
    let mut input_count_at_stamp: u64 = 0;
    let mut output_stamp: Option<rt::StreamStamp> = None;
    let mut output_count_at_stamp: u64 = 0;
    let deadline = Instant::now() + Duration::from_millis(3_000);
    let want_frames = (pair.rate as f64 * 1.5) as u64;
    while Instant::now() < deadline {
        loop {
            let got = pair.consumer.pop(&mut stereo);
            if got == 0 {
                break;
            }
            captured.extend_from_slice(&stereo[..got * 2]);
        }
        if let Ok(stamp) = pair.input.get_timestamp(rt::CLOCK_MONOTONIC) {
            input_stamp = Some(rt::StreamStamp {
                frame: stamp.position,
                time_ns: stamp.timestamp,
                rate: pair.rate,
            });
            input_count_at_stamp = pair.frames.load(Ordering::Acquire);
        }
        if pair.played.load(Ordering::Acquire) && output_stamp.is_none() {
            if let Ok(stamp) = pair.output.get_timestamp(rt::CLOCK_MONOTONIC) {
                output_stamp = Some(rt::StreamStamp {
                    frame: stamp.position,
                    time_ns: stamp.timestamp,
                    rate: pair.rate,
                });
                output_count_at_stamp = pair.output_frames.load(Ordering::Acquire);
            }
        }
        if pair.frames.load(Ordering::Acquire) >= want_frames
            && pair.played.load(Ordering::Acquire)
        {
            break;
        }
        thread::sleep(Duration::from_millis(5));
    }

    pair.enabled.store(false, Ordering::Release);
    let _ = pair.output.stop();
    let _ = pair.input.stop();
    // The last of the ring, after the callbacks are stopped.
    loop {
        let got = pair.consumer.pop(&mut stereo);
        if got == 0 {
            break;
        }
        captured.extend_from_slice(&stereo[..got * 2]);
    }

    let input_frames = pair.frames.load(Ordering::Acquire);
    let input_dropped = pair.dropped.load(Ordering::Acquire);
    if input_dropped > 0 {
        return Err(format!(
            "the probe's capture ring dropped {input_dropped} frames; the frame index is discontinuous, so the round trip is refused"
        ));
    }
    if captured.len() < 2 {
        return Err("the probe captured no frames".to_string());
    }

    // Left channel only: the callback duplicated mono into the ring.
    let mono: Vec<f32> = captured.chunks_exact(2).map(|frame| frame[0]).collect();
    // Start a little in: the stream's own first blocks are not a click.
    let from = (pair.rate as usize / 20).min(mono.len());
    let best = rt::best_click(pair.rate, &mono, from)
        .ok_or_else(|| "the probe captured less than one chirp".to_string())?;
    let heard = match rt::find_click(pair.rate, &mono, from) {
        Some(hit) => hit,
        None => {
            return Err(format!(
                "the probe heard no click (best correlation {:.3}, floor {:.3}); the speaker/microphone path may be too quiet or too coloured",
                best.score, rt::MIN_SCORE
            ))
        }
    };

    let input_stamp = input_stamp
        .ok_or_else(|| "the input stream did not report a CLOCK_MONOTONIC timestamp".to_string())?;
    let output_stamp = output_stamp
        .ok_or_else(|| "the output stream did not report a CLOCK_MONOTONIC timestamp".to_string())?;

    // The two streams' timestamps are only useful if their positions are in the
    // same frame space as the counters this probe keeps. A timestamp from a
    // different base would extrapolate to a plausible-looking wrong number, so
    // a mismatch is a refusal, not a measurement.
    let slack = ((input_buffer + input_burst + output_buffer + output_burst) * 4) as i64;
    if (input_stamp.frame - input_count_at_stamp as i64).abs() > slack {
        return Err(format!(
            "the input timestamp position {} is not in this probe's frame space ({} frames captured); refusing the measurement",
            input_stamp.frame, input_count_at_stamp
        ));
    }
    if (output_stamp.frame - output_count_at_stamp as i64).abs() > slack {
        return Err(format!(
            "the output timestamp position {} is not in this probe's frame space ({} frames written); refusing the measurement",
            output_stamp.frame, output_count_at_stamp
        ));
    }

    let trip = rt::measure(
        output_stamp,
        pair.click_frame,
        input_stamp,
        heard.offset as i64,
    )?;

    Ok(RoundTripReport {
        device_in: device_label(device_in),
        device_out: device_label(device_out),
        rate: pair.rate,
        input_channels,
        output_channels,
        input_buffer_frames: input_buffer,
        output_buffer_frames: output_buffer,
        input_burst,
        output_burst,
        sharing_input,
        sharing_output,
        performance_input,
        performance_output,
        xruns_input: pair.input.get_xrun_count().unwrap_or(0).max(0) as u32,
        xruns_output: pair.output.get_xrun_count().unwrap_or(0).max(0) as u32,
        input_frames,
        output_frames: pair.output_frames.load(Ordering::Acquire),
        input_dropped,
        click_frame: pair.click_frame,
        heard_frame: heard.offset as i64,
        score: heard.score,
        method: "getTimestamp(CLOCK_MONOTONIC)".to_string(),
        round_trip_ms: trip.round_trip_ms,
        round_trip_frames: trip.round_trip_frames,
    })
}

struct ProbePair {
    input: oboe::AudioStreamAsync<Input, ProbeInput>,
    output: oboe::AudioStreamAsync<Output, ProbeOutput>,
    consumer: Consumer,
    frames: Arc<AtomicU64>,
    dropped: Arc<AtomicU64>,
    enabled: Arc<AtomicBool>,
    played: Arc<AtomicBool>,
    output_frames: Arc<AtomicU64>,
    click_frame: i64,
    rate: u32,
}

struct ProbeInput {
    producer: Producer,
    scratch: Vec<f32>,
    frames: Arc<AtomicU64>,
    dropped: Arc<AtomicU64>,
    enabled: Arc<AtomicBool>,
}

impl ProbeInput {
    fn new(
        producer: Producer,
        frames: Arc<AtomicU64>,
        dropped: Arc<AtomicU64>,
        enabled: Arc<AtomicBool>,
    ) -> Self {
        ProbeInput {
            producer,
            scratch: vec![0.0f32; MAX_CALLBACK_FRAMES * 2],
            frames,
            dropped,
            enabled,
        }
    }
}

impl AudioInputCallback for ProbeInput {
    type FrameType = (f32, Mono);

    fn on_audio_ready(
        &mut self,
        _audio_stream: &mut dyn AudioInputStreamSafe,
        audio_data: &[f32],
    ) -> DataCallbackResult {
        if self.enabled.load(Ordering::Relaxed) {
            let capacity = self.scratch.len() / 2;
            let count = audio_data.len().min(capacity);
            for (index, sample) in audio_data[..count].iter().enumerate() {
                self.scratch[index * 2] = *sample;
                self.scratch[index * 2 + 1] = *sample;
            }
            let overflow = self.producer.push(&self.scratch[..count * 2]);
            if overflow > 0 {
                self.dropped.fetch_add(overflow as u64, Ordering::Relaxed);
            }
            self.frames.fetch_add(count as u64, Ordering::Relaxed);
        }
        DataCallbackResult::Continue
    }
}

struct ProbeOutput {
    click: Vec<f32>,
    click_frame: i64,
    position: i64,
    played: Arc<AtomicBool>,
    frames: Arc<AtomicU64>,
}

impl ProbeOutput {
    fn new(
        click: Vec<f32>,
        click_frame: i64,
        played: Arc<AtomicBool>,
        frames: Arc<AtomicU64>,
    ) -> Self {
        ProbeOutput {
            click,
            click_frame,
            position: 0,
            played,
            frames,
        }
    }
}

impl AudioOutputCallback for ProbeOutput {
    type FrameType = (f32, Mono);

    fn on_audio_ready(
        &mut self,
        _audio_stream: &mut dyn AudioOutputStreamSafe,
        audio_data: &mut [f32],
    ) -> DataCallbackResult {
        for (index, slot) in audio_data.iter_mut().enumerate() {
            let at = self.position + index as i64;
            let offset = at - self.click_frame;
            *slot = if offset >= 0 && (offset as usize) < self.click.len() {
                self.click[offset as usize]
            } else {
                0.0
            };
        }
        self.position += audio_data.len() as i64;
        self.frames.store(self.position as u64, Ordering::Relaxed);
        if self.position >= self.click_frame + self.click.len() as i64 {
            self.played.store(true, Ordering::Release);
        }
        DataCallbackResult::Continue
    }
}

fn open_probe_input(
    device_id: Option<i32>,
    sharing: SharingMode,
    callback: ProbeInput,
) -> Result<oboe::AudioStreamAsync<Input, ProbeInput>, String> {
    let mut builder = AudioStreamBuilder::default()
        .set_direction::<Input>()
        .set_performance_mode(PerformanceMode::LowLatency)
        .set_sharing_mode(sharing)
        .set_sample_rate(REQUESTED_RATE as i32)
        .set_channel_count::<Mono>()
        .set_format::<f32>();
    if let Some(id) = device_id {
        builder = builder.set_device_id(id);
    }
    builder
        .set_callback(callback)
        .open_stream()
        .map_err(|error| error.to_string())
}

fn open_probe_output(
    device_id: Option<i32>,
    sharing: SharingMode,
    callback: ProbeOutput,
) -> Result<oboe::AudioStreamAsync<Output, ProbeOutput>, String> {
    let mut builder = AudioStreamBuilder::default()
        .set_direction::<Output>()
        .set_performance_mode(PerformanceMode::LowLatency)
        .set_sharing_mode(sharing)
        .set_sample_rate(REQUESTED_RATE as i32)
        .set_channel_count::<Mono>()
        .set_format::<f32>();
    if let Some(id) = device_id {
        builder = builder.set_device_id(id);
    }
    builder
        .set_callback(callback)
        .open_stream()
        .map_err(|error| error.to_string())
}

/// Build and open one input stream. The builder is consumed by `open_stream`,
/// so the caller retries with a fresh callback for the shared fallback.
fn open_stream(
    device_id: Option<i32>,
    sharing: SharingMode,
    callback: CaptureCallback,
) -> Result<oboe::AudioStreamAsync<Input, CaptureCallback>, String> {
    let mut builder = AudioStreamBuilder::default()
        .set_direction::<Input>()
        .set_performance_mode(PerformanceMode::LowLatency)
        .set_sharing_mode(sharing)
        .set_sample_rate(REQUESTED_RATE as i32)
        .set_channel_count::<Mono>()
        .set_format::<i16>();
    if let Some(id) = device_id {
        builder = builder.set_device_id(id);
    }
    builder
        .set_callback(callback)
        .open_stream()
        .map_err(|error| error.to_string())
}

/// The audio callback's only state. Everything it touches is fixed-size or
/// atomic; see the module docs.
struct CaptureCallback {
    producer: Producer,
    /// Interleaved stereo scratch, allocated once at setup. Mono is duplicated
    /// so the ring's existing stereo shape is reused unchanged.
    scratch: Vec<f32>,
    peak: Arc<AtomicU32>,
    frames: Arc<AtomicU64>,
    callbacks: Arc<AtomicU64>,
    /// Frames dropped because one callback exceeded the scratch capacity.
    dropped_callback: Arc<AtomicU64>,
    /// Frames the ring refused because it was full; `ingest` counts the
    /// `Producer::push` return value, which it used to discard.
    dropped_ring: Arc<AtomicU64>,
    enabled: Arc<AtomicBool>,
}

impl CaptureCallback {
    fn new(
        producer: Producer,
        peak: Arc<AtomicU32>,
        frames: Arc<AtomicU64>,
        callbacks: Arc<AtomicU64>,
        dropped_callback: Arc<AtomicU64>,
        dropped_ring: Arc<AtomicU64>,
        enabled: Arc<AtomicBool>,
    ) -> Self {
        Self {
            producer,
            scratch: vec![0.0f32; MAX_CALLBACK_FRAMES * 2],
            peak,
            frames,
            callbacks,
            dropped_callback,
            dropped_ring,
            enabled,
        }
    }

    /// The audio path proper, split out so the tests can drive it without an
    /// Oboe stream (an input stream cannot exist off a phone). No allocation,
    /// no lock, no log.
    fn ingest(&mut self, audio_data: &[i16]) {
        if !self.enabled.load(Ordering::Relaxed) {
            return;
        }

        let capacity = self.scratch.len() / 2;
        let count = audio_data.len().min(capacity);
        let mut loudest = 0.0f32;
        for (index, &sample) in audio_data[..count].iter().enumerate() {
            let value = f32::from(sample) / 32768.0;
            let magnitude = value.abs();
            if magnitude > loudest {
                loudest = magnitude;
            }
            // Mono in, stereo ring: the monitor bus's shape, unchanged.
            self.scratch[index * 2] = value;
            self.scratch[index * 2 + 1] = value;
        }
        if count > 0 {
            // The ring drops the newest frames when the drain falls behind;
            // `push` returns how many it refused, so time it here rather than
            // letting the loss vanish into `frames_captured - frames_written`.
            let overflow = self.producer.push(&self.scratch[..count * 2]);
            if overflow > 0 {
                self.dropped_ring
                    .fetch_add(overflow as u64, Ordering::Relaxed);
            }
        }
        if audio_data.len() > count {
            self.dropped_callback
                .fetch_add((audio_data.len() - count) as u64, Ordering::Relaxed);
        }
        self.frames.fetch_add(count as u64, Ordering::Relaxed);
        self.callbacks.fetch_add(1, Ordering::Relaxed);
        note_peak(&self.peak, loudest);
    }
}

impl AudioInputCallback for CaptureCallback {
    type FrameType = (i16, Mono);

    fn on_audio_ready(
        &mut self,
        _audio_stream: &mut dyn AudioInputStreamSafe,
        audio_data: &[i16],
    ) -> DataCallbackResult {
        self.ingest(audio_data);
        DataCallbackResult::Continue
    }
}

/// Max a non-negative f32 through an atomic, with no lock. `>=` on the bit
/// pattern is numeric order for non-negative IEEE floats.
fn note_peak(slot: &AtomicU32, value: f32) {
    let mut current = slot.load(Ordering::Relaxed);
    loop {
        if value.to_bits() <= current {
            return;
        }
        match slot.compare_exchange_weak(
            current,
            value.to_bits(),
            Ordering::Relaxed,
            Ordering::Relaxed,
        ) {
            Ok(_) => return,
            Err(next) => current = next,
        }
    }
}

/// What one drain thread got out of the ring. `written` is what the WAV holds;
/// `dropped` is what the disk queue refused on the way there.
struct Drained {
    written: u64,
    dropped: u64,
}

/// The non-audio side of the take: pull the ring into fixed buffers and hand
/// whole blocks to the WAV writer. Allocation and file I/O happen here, never
/// in the callback. A plan's [`Channel`] is built and prepared here too, on
/// this thread, so the strip runs once per block after capture rather than in
/// the audio callback.
fn drain_ring(
    consumer: Consumer,
    mut disk: Option<DiskWriter>,
    period: usize,
    stop: &AtomicBool,
    plan: Option<ChannelPlan>,
    rate: u32,
) -> Result<Drained, crate::wav::WavError> {
    let period = period.max(1);
    let mut stereo = vec![0.0f32; period * 2];
    let mut mono = vec![0i16; period];
    let mut strip = Strip::new(plan, rate, period);
    loop {
        let got = consumer.pop(&mut stereo);
        if got > 0 {
            push_block(&mut disk, &mut strip, &mut mono, &stereo, got);
            continue;
        }
        if stop.load(Ordering::Acquire) {
            break;
        }
        thread::sleep(Duration::from_millis(1));
    }
    // The stream is stopped, so this is the last of the ring.
    loop {
        let got = consumer.pop(&mut stereo);
        if got == 0 {
            break;
        }
        push_block(&mut disk, &mut strip, &mut mono, &stereo, got);
    }
    match disk {
        Some(writer) => {
            // Read the queue's own drop count before `finish` consumes the
            // handle; without it the ring overflow and the disk overflow are
            // indistinguishable in the take's shortfall.
            let dropped = writer.dropped_frames();
            let written = writer.finish()?;
            Ok(Drained { written, dropped })
        }
        None => Ok(Drained {
            written: 0,
            dropped: 0,
        }),
    }
}

/// The take's optional strip lives in `plan::Strip`, beside the plan that
/// builds it, so its raw/mono behaviour is unit-tested without the Oboe
/// feature.

fn push_block(
    disk: &mut Option<DiskWriter>,
    strip: &mut Strip,
    mono: &mut [i16],
    stereo: &[f32],
    got: usize,
) {
    strip.process(stereo, mono, got);
    if let Some(writer) = disk.as_mut() {
        writer.push(&mono[..got]);
    }
}

/// f32 back to S16. The strip in `plan` owns this conversion; the Oboe module
/// reads the WAV's counts, not the samples.

// --- the plain-C ABI the app's service loads ---------------------------------

/// The service's view of the one take this process may run. The audio path
/// never touches this lock; only start, stop and status do.
struct Control {
    stop: Option<Arc<AtomicBool>>,
    handle: Option<JoinHandle<()>>,
    status: String,
}

fn control() -> &'static Mutex<Control> {
    static CONTROL: OnceLock<Mutex<Control>> = OnceLock::new();
    CONTROL.get_or_init(|| {
        Mutex::new(Control {
            stop: None,
            handle: None,
            status: "{\"ok\":false,\"error\":\"no take has started\"}".to_string(),
        })
    })
}

fn lock_control() -> std::sync::MutexGuard<'static, Control> {
    control()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// One JSON object, matching the engine's existing status style.
fn report_json(report: &OboeReport, take: &str) -> String {
    format!(
        "{{\"ok\":true,\"backend\":\"oboe\",\"device\":\"{}\",\"rate\":{},\"frames\":{},\"buffer\":{},\"channels\":{},\"sharing\":\"{}\",\"performance\":\"{}\",\"xruns\":{},\"frames_captured\":{},\"frames_written\":{},\"dropped\":{},\"dropped_ring\":{},\"dropped_disk\":{},\"dropped_callback\":{},\"peak\":{:.6},\"plan\":\"{}\",\"take\":\"{}\"}}",
        json_escape(&report.device),
        report.rate,
        report.frames,
        report.buffer_frames,
        report.channels,
        json_escape(&report.sharing),
        json_escape(&report.performance),
        report.xruns,
        report.frames_captured,
        report.frames_written,
        report.dropped,
        report.dropped_ring,
        report.dropped_disk,
        report.dropped_callback,
        report.peak,
        json_escape(&report.plan),
        json_escape(take),
    )
}

fn error_json(error: &str) -> String {
    format!("{{\"ok\":false,\"error\":\"{}\"}}", json_escape(error))
}

fn json_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn into_c_string(text: String) -> *mut c_char {
    // `CString::new` fails only on an interior NUL, which JSON cannot carry.
    match CString::new(text) {
        Ok(text) => text.into_raw(),
        Err(_) => CString::new("{\"ok\":false,\"error\":\"status text\"}")
            .expect("static JSON has no NUL")
            .into_raw(),
    }
}

/// Start a take on a worker thread and return a JSON status immediately.
/// `device_id < 0` asks the HAL to pick; a null `out` runs without a WAV.
/// No plan means the raw path.
///
/// The returned string belongs to the caller and is freed with
/// [`jawn_audio_free`].
///
/// # Safety
/// `out` must be null or a valid NUL-terminated C string.
#[no_mangle]
pub unsafe extern "C" fn jawn_audio_start(
    device_id: i32,
    seconds: f64,
    out: *const c_char,
) -> *mut c_char {
    start_take(device_id, seconds, out, None)
}

/// Start the same take through one Channel plan (docs/studio-oboe-slice.md §9
/// item 3). A null or empty plan is exactly [`jawn_audio_start`]; the plan is
/// validated before any stream opens, so a refused plan leaves no take armed.
///
/// # Safety
/// `out` and `plan_json` must be null or valid NUL-terminated C strings.
#[no_mangle]
pub unsafe extern "C" fn jawn_audio_start_plan(
    device_id: i32,
    seconds: f64,
    out: *const c_char,
    plan_json: *const c_char,
) -> *mut c_char {
    let text = if plan_json.is_null() {
        None
    } else {
        Some(CStr::from_ptr(plan_json).to_string_lossy().into_owned())
    };
    let plan = match crate::plan::parse_plan(text.as_deref()) {
        Ok(plan) => plan,
        Err(error) => {
            return into_c_string(error_json(&format!("the take plan was refused: {error}")))
        }
    };
    start_take(device_id, seconds, out, plan)
}

/// The one fixture plan the Linux test and the phone both run. The app asks the
/// engine for these bytes rather than keeping a second copy, so the sidecar's
/// `plan` and the `Channel` the test drives cannot drift.
#[no_mangle]
pub extern "C" fn jawn_audio_fixture_plan() -> *mut c_char {
    into_c_string(crate::plan::FIXTURE_PLAN.to_string())
}

/// The shared body of both start entry points. `plan` is already validated.
unsafe fn start_take(
    device_id: i32,
    seconds: f64,
    out: *const c_char,
    plan: Option<ChannelPlan>,
) -> *mut c_char {
    let take = if out.is_null() {
        None
    } else {
        Some(CStr::from_ptr(out).to_string_lossy().into_owned())
    };
    let plan_label = plan
        .as_ref()
        .map(|plan| plan.label())
        .unwrap_or_else(|| "raw".to_string());
    let mut current = lock_control();
    if current.handle.is_some() {
        return into_c_string(error_json("a take is already running"));
    }
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let take_label = take.clone();
    let device = if device_id < 0 { None } else { Some(device_id) };
    let status = match take.as_deref() {
        Some(path) => format!(
            "{{\"ok\":true,\"state\":\"started\",\"backend\":\"oboe\",\"plan\":\"{}\",\"take\":\"{}\"}}",
            json_escape(&plan_label),
            json_escape(path)
        ),
        None => format!(
            "{{\"ok\":true,\"state\":\"started\",\"backend\":\"oboe\",\"plan\":\"{}\"}}",
            json_escape(&plan_label)
        ),
    };
    current.status = status;
    current.stop = Some(Arc::clone(&stop));
    match thread::Builder::new()
        .name("jawn-audio-oboe-take".to_string())
        .spawn(move || {
            let result =
                run_capture_plan(device, seconds, take_label.as_deref(), &thread_stop, plan);
            let json = match result {
                Ok(report) => report_json(&report, take_label.as_deref().unwrap_or("")),
                Err(error) => error_json(&error),
            };
            let mut current = lock_control();
            current.status = json;
            // The take is over; drop our own handle so a later start is not
            // refused as "already running". A concurrent `stop` that already
            // took the handle is joining this thread and is unaffected.
            current.handle = None;
            current.stop = None;
        }) {
        Ok(handle) => current.handle = Some(handle),
        Err(error) => {
            current.stop = None;
            current.status = error_json(&format!("cannot start the take thread: {error}"));
            let failed = current.status.clone();
            drop(current);
            return into_c_string(failed);
        }
    }
    let status = current.status.clone();
    drop(current);
    into_c_string(status)
}

/// End a running take (if any) and return the final JSON status. Joins the
/// worker, which stops the stream first, so the WAV is closed when this
/// returns.
#[no_mangle]
pub extern "C" fn jawn_audio_stop() -> *mut c_char {
    let (stop, handle) = {
        let mut current = lock_control();
        (current.stop.take(), current.handle.take())
    };
    if let Some(stop) = stop {
        stop.store(true, Ordering::Release);
    }
    if let Some(handle) = handle {
        let _ = handle.join();
    }
    let status = lock_control().status.clone();
    into_c_string(status)
}

/// The last status this process reported: the running take's start sentence or
/// its final report. Returns a caller-owned string; free it with
/// [`jawn_audio_free`].
#[no_mangle]
pub extern "C" fn jawn_audio_status() -> *mut c_char {
    into_c_string(lock_control().status.clone())
}

/// The same one-line JSON `--backends --json` prints, for the app's page. The
/// JNI shim calls it so the phone can say `oboe:true` without a CLI
/// (docs/studio-oboe-slice.md §9 item 2).
#[no_mangle]
pub extern "C" fn jawn_audio_backends() -> *mut c_char {
    into_c_string(crate::backends::json(&crate::backends::availability()))
}

/// Free a string returned by any of the functions above.
///
/// # Safety
/// `text` must be a pointer this module returned and not already freed.
#[no_mangle]
pub unsafe extern "C" fn jawn_audio_free(text: *mut c_char) {
    if !text.is_null() {
        drop(CString::from_raw(text));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_peak_helper_keeps_the_loudest_value() {
        let slot = AtomicU32::new(0);
        note_peak(&slot, 0.25);
        note_peak(&slot, 0.5);
        note_peak(&slot, 0.125);
        assert_eq!(f32::from_bits(slot.load(Ordering::Relaxed)), 0.5);
    }

    #[test]
    fn the_callback_pushes_whole_frames_and_counts_them() {
        let (producer, consumer) = monbus::new(4096);
        let peak = Arc::new(AtomicU32::new(0));
        let frames = Arc::new(AtomicU64::new(0));
        let callbacks = Arc::new(AtomicU64::new(0));
        let dropped_callback = Arc::new(AtomicU64::new(0));
        let dropped_ring = Arc::new(AtomicU64::new(0));
        let enabled = Arc::new(AtomicBool::new(true));
        let mut callback = CaptureCallback::new(
            producer,
            Arc::clone(&peak),
            Arc::clone(&frames),
            Arc::clone(&callbacks),
            Arc::clone(&dropped_callback),
            Arc::clone(&dropped_ring),
            enabled,
        );
        let block = [16_384i16, -16_384, 0];
        callback.ingest(&block);
        assert_eq!(frames.load(Ordering::Acquire), 3);
        assert_eq!(callbacks.load(Ordering::Acquire), 1);
        assert_eq!(dropped_callback.load(Ordering::Acquire), 0);
        assert_eq!(dropped_ring.load(Ordering::Acquire), 0);
        assert_eq!(f32::from_bits(peak.load(Ordering::Acquire)), 0.5);

        let mut out = [0.0f32; 6];
        assert_eq!(consumer.pop(&mut out), 3);
        assert_eq!(out[0], 0.5);
        assert_eq!(out[1], 0.5, "mono is duplicated into the stereo ring");
    }

    #[test]
    fn the_callback_counts_ring_overflow() {
        // A ring no one drains: the callback must measure what `push` refused
        // instead of letting it disappear between captured and written.
        let (producer, _consumer) = monbus::new(monbus::MIN_FRAMES);
        let peak = Arc::new(AtomicU32::new(0));
        let frames = Arc::new(AtomicU64::new(0));
        let callbacks = Arc::new(AtomicU64::new(0));
        let dropped_callback = Arc::new(AtomicU64::new(0));
        let dropped_ring = Arc::new(AtomicU64::new(0));
        let mut callback = CaptureCallback::new(
            producer,
            Arc::clone(&peak),
            Arc::clone(&frames),
            Arc::clone(&callbacks),
            Arc::clone(&dropped_callback),
            Arc::clone(&dropped_ring),
            Arc::new(AtomicBool::new(true)),
        );

        let block = vec![1i16; monbus::MIN_FRAMES + 16];
        callback.ingest(&block);

        assert_eq!(frames.load(Ordering::Acquire), (monbus::MIN_FRAMES + 16) as u64);
        assert_eq!(dropped_ring.load(Ordering::Acquire), 16);
        assert_eq!(dropped_callback.load(Ordering::Acquire), 0);
    }

    #[test]
    fn a_disabled_callback_does_no_work() {
        let (producer, consumer) = monbus::new(64);
        let peak = Arc::new(AtomicU32::new(0));
        let frames = Arc::new(AtomicU64::new(0));
        let callbacks = Arc::new(AtomicU64::new(0));
        let dropped_callback = Arc::new(AtomicU64::new(0));
        let dropped_ring = Arc::new(AtomicU64::new(0));
        let mut callback = CaptureCallback::new(
            producer,
            Arc::clone(&peak),
            Arc::clone(&frames),
            Arc::clone(&callbacks),
            Arc::clone(&dropped_callback),
            Arc::clone(&dropped_ring),
            Arc::new(AtomicBool::new(false)),
        );
        callback.ingest(&[100, 200, 300, 400]);
        assert_eq!(frames.load(Ordering::Acquire), 0);
        let mut out = [1.0f32; 8];
        assert_eq!(consumer.pop(&mut out), 0);
        assert!(out.iter().all(|sample| *sample == 1.0));
    }

    #[test]
    fn the_report_json_names_the_granted_shape() {
        let report = OboeReport {
            device: "device 7".to_string(),
            rate: 48_000,
            frames: 192,
            buffer_frames: 960,
            channels: 1,
            sharing: "Exclusive".to_string(),
            performance: "LowLatency".to_string(),
            xruns: 0,
            frames_captured: 288_000,
            frames_written: 288_000,
            dropped: 0,
            dropped_ring: 0,
            dropped_disk: 0,
            dropped_callback: 0,
            peak: 0.31,
            plan: "tone+delay".to_string(),
        };
        let text = report_json(&report, "/data/take.wav");
        for needle in [
            "\"ok\":true",
            "\"backend\":\"oboe\"",
            "\"rate\":48000",
            "\"frames\":192",
            "\"buffer\":960",
            "\"sharing\":\"Exclusive\"",
            "\"performance\":\"LowLatency\"",
            "\"frames_captured\":288000",
            "\"frames_written\":288000",
            "\"dropped\":0",
            "\"dropped_ring\":0",
            "\"dropped_disk\":0",
            "\"dropped_callback\":0",
            "\"plan\":\"tone+delay\"",
            "\"take\":\"/data/take.wav\"",
        ] {
            assert!(text.contains(needle), "{needle} missing from {text}");
        }
    }

    #[test]
    fn the_fixture_engine_exports_its_own_plan_bytes() {
        let pointer = jawn_audio_fixture_plan();
        let text = unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .expect("the fixture is UTF-8")
            .to_string();
        unsafe { jawn_audio_free(pointer) };
        assert_eq!(text, crate::plan::FIXTURE_PLAN);
        let plan = crate::plan::parse_plan(Some(&text))
            .expect("valid")
            .expect("not raw");
        assert_eq!(plan.label(), "tone+delay");
    }

    #[test]
    fn error_text_is_escaped() {
        let text = error_json("a \"quoted\"\nline");
        assert_eq!(text, "{\"ok\":false,\"error\":\"a \\\"quoted\\\"\\nline\"}");
    }
}
