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
    AudioInputCallback, AudioInputStreamSafe, AudioStream, AudioStreamBase, AudioStreamBuilder,
    AudioStreamSafe, DataCallbackResult, Input, Mono, PerformanceMode, SharingMode,
};

use crate::disk::DiskWriter;
use crate::monbus::{self, Consumer, Producer};

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
    pub peak: f32,
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
/// flag is set".
pub fn run_capture(
    device_id: Option<i32>,
    seconds: f64,
    out: Option<&str>,
    stop: &AtomicBool,
) -> Result<OboeReport, String> {
    let peak = Arc::new(AtomicU32::new(0));
    let frames = Arc::new(AtomicU64::new(0));
    let callbacks = Arc::new(AtomicU64::new(0));
    let dropped = Arc::new(AtomicU64::new(0));
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
            Arc::clone(&dropped),
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
        .spawn(move || drain_ring(consumer, disk, period, &thread_stop))
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
    sink.join()
        .map_err(|_| "the Oboe disk thread panicked".to_string())?
        .map_err(|error| format!("cannot finish the Oboe take: {error}"))?;

    Ok(OboeReport {
        device: device_label(device_id),
        rate,
        frames: frames_per_burst,
        buffer_frames,
        channels,
        sharing,
        performance,
        xruns,
        frames_captured: frames.load(Ordering::Acquire),
        peak: f32::from_bits(peak.load(Ordering::Acquire)),
    })
}

/// A device id is the Android HAL's own label; without one, the HAL picks.
fn device_label(device_id: Option<i32>) -> String {
    match device_id {
        Some(id) => format!("device {id}"),
        None => "default".to_string(),
    }
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
    dropped: Arc<AtomicU64>,
    enabled: Arc<AtomicBool>,
}

impl CaptureCallback {
    fn new(
        producer: Producer,
        peak: Arc<AtomicU32>,
        frames: Arc<AtomicU64>,
        callbacks: Arc<AtomicU64>,
        dropped: Arc<AtomicU64>,
        enabled: Arc<AtomicBool>,
    ) -> Self {
        Self {
            producer,
            scratch: vec![0.0f32; MAX_CALLBACK_FRAMES * 2],
            peak,
            frames,
            callbacks,
            dropped,
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
            self.producer.push(&self.scratch[..count * 2]);
        }
        if audio_data.len() > count {
            self.dropped
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

/// The non-audio side of the take: pull the ring into fixed buffers and hand
/// whole blocks to the WAV writer. Allocation and file I/O happen here, never
/// in the callback.
fn drain_ring(
    consumer: Consumer,
    mut disk: Option<DiskWriter>,
    period: usize,
    stop: &AtomicBool,
) -> Result<u64, crate::wav::WavError> {
    let period = period.max(1);
    let mut stereo = vec![0.0f32; period * 2];
    let mut mono = vec![0i16; period];
    loop {
        let got = consumer.pop(&mut stereo);
        if got > 0 {
            push_block(&mut disk, &mut mono, &stereo, got);
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
        push_block(&mut disk, &mut mono, &stereo, got);
    }
    match disk {
        Some(writer) => writer.finish(),
        None => Ok(0),
    }
}

fn push_block(disk: &mut Option<DiskWriter>, mono: &mut [i16], stereo: &[f32], got: usize) {
    for (slot, frame) in mono.iter_mut().zip(stereo.chunks_exact(2)).take(got) {
        *slot = to_i16(frame[0]);
    }
    if let Some(writer) = disk.as_mut() {
        writer.push(&mono[..got]);
    }
}

/// f32 back to S16. The capture divided by 32768, so multiplying by the same
/// undoes it exactly for every i16 value.
fn to_i16(value: f32) -> i16 {
    (value * 32768.0).round().clamp(-32768.0, 32767.0) as i16
}

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
        "{{\"ok\":true,\"backend\":\"oboe\",\"device\":\"{}\",\"rate\":{},\"frames\":{},\"buffer\":{},\"channels\":{},\"sharing\":\"{}\",\"performance\":\"{}\",\"xruns\":{},\"frames_captured\":{},\"peak\":{:.6},\"take\":\"{}\"}}",
        json_escape(&report.device),
        report.rate,
        report.frames,
        report.buffer_frames,
        report.channels,
        json_escape(&report.sharing),
        json_escape(&report.performance),
        report.xruns,
        report.frames_captured,
        report.peak,
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
    let take = if out.is_null() {
        None
    } else {
        Some(CStr::from_ptr(out).to_string_lossy().into_owned())
    };
    let mut current = lock_control();
    if current.handle.is_some() {
        return into_c_string(error_json("a take is already running"));
    }
    let stop = Arc::new(AtomicBool::new(false));
    let thread_stop = Arc::clone(&stop);
    let take_label = take.clone();
    let device = if device_id < 0 { None } else { Some(device_id) };
    let status = if let Some(path) = take.as_deref() {
        format!(
            "{{\"ok\":true,\"state\":\"started\",\"backend\":\"oboe\",\"take\":\"{}\"}}",
            json_escape(path)
        )
    } else {
        "{\"ok\":true,\"state\":\"started\",\"backend\":\"oboe\"}".to_string()
    };
    current.status = status;
    current.stop = Some(Arc::clone(&stop));
    match thread::Builder::new()
        .name("jawn-audio-oboe-take".to_string())
        .spawn(move || {
            let result = run_capture(device, seconds, take_label.as_deref(), &thread_stop);
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
    fn s16_round_trips_through_the_ring_conversion() {
        for sample in [i16::MIN, -32767, -1, 0, 1, 12345, i16::MAX] {
            let value = f32::from(sample) / 32768.0;
            assert_eq!(to_i16(value), sample, "{sample} did not round trip");
        }
    }

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
        let dropped = Arc::new(AtomicU64::new(0));
        let enabled = Arc::new(AtomicBool::new(true));
        let mut callback = CaptureCallback::new(
            producer,
            Arc::clone(&peak),
            Arc::clone(&frames),
            Arc::clone(&callbacks),
            Arc::clone(&dropped),
            enabled,
        );
        let block = [16_384i16, -16_384, 0];
        callback.ingest(&block);
        assert_eq!(frames.load(Ordering::Acquire), 3);
        assert_eq!(callbacks.load(Ordering::Acquire), 1);
        assert_eq!(dropped.load(Ordering::Acquire), 0);
        assert_eq!(f32::from_bits(peak.load(Ordering::Acquire)), 0.5);

        let mut out = [0.0f32; 6];
        assert_eq!(consumer.pop(&mut out), 3);
        assert_eq!(out[0], 0.5);
        assert_eq!(out[1], 0.5, "mono is duplicated into the stereo ring");
    }

    #[test]
    fn a_disabled_callback_does_no_work() {
        let (producer, consumer) = monbus::new(64);
        let peak = Arc::new(AtomicU32::new(0));
        let frames = Arc::new(AtomicU64::new(0));
        let callbacks = Arc::new(AtomicU64::new(0));
        let dropped = Arc::new(AtomicU64::new(0));
        let mut callback = CaptureCallback::new(
            producer,
            Arc::clone(&peak),
            Arc::clone(&frames),
            Arc::clone(&callbacks),
            Arc::clone(&dropped),
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
            peak: 0.31,
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
            "\"take\":\"/data/take.wav\"",
        ] {
            assert!(text.contains(needle), "{needle} missing from {text}");
        }
    }

    #[test]
    fn error_text_is_escaped() {
        let text = error_json("a \"quoted\"\nline");
        assert_eq!(text, "{\"ok\":false,\"error\":\"a \\\"quoted\\\"\\nline\"}");
    }
}
