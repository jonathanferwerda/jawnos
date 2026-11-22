//! P4's live input: a capture device feeding the sender.
//!
//! D14 says the peer owns its take, so the capture thread writes every block to
//! the local WAV **before** the same frames are offered to the sender's ring.
//! The clock loop only pops whole frames from that ring, so a slow disk or a
//! late device is a counted gap in an otherwise steady send loop, never a stall
//! in it (docs/studio-audio-roadmap.md P4).
//!
//! The ring is fixed-size and lock-free, like [`crate::monbus`]. Each slot
//! carries the capture sequence number of its frame, which is what lets the
//! sender stay on its own clock: a window that has already been padded with
//! silence discards the late frames that belong to it instead of sending them a
//! block behind. A full ring drops the **newest** frames and counts them.
//!
//! The null backend has no input, so this module does not pretend it does. A
//! [`SyntheticSource`] is the test source; real hardware is the existing ALSA
//! capture seam ([`crate::alsa_device::run_capture`]) behind the same sink
//! contract `--record` uses.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::backends::BackendKind;
use crate::wav::WavWriter;

/// Frames the capture thread may run ahead of the sender: 341 ms at 48 kHz.
/// That rides out a scheduler hiccup or one disk stall without delaying the
/// send loop; beyond it the oldest frames are still kept and the newest are
/// dropped, because the live edge is the part worth sending.
pub const LIVE_RING_FRAMES: usize = 16_384;

/// How often the local take's header is synced while it records. The samples
/// are written every block; only the sizes wait, so a killed take is a valid,
/// shorter WAV rather than a header that promises missing samples.
const SYNC_SECONDS: u64 = 2;

/// One source of live frames.
///
/// A real device paces itself; [`SyntheticSource`] paces itself the same way so
/// the sender's clock loop sees the same cadence in a test. `read` returning 0
/// means the source is finished. A full or short ring is the sender's business,
/// not the source's.
pub trait LiveSource: Send {
    fn rate(&self) -> u32;
    /// Fill up to `out.len()` mono frames; return how many were produced.
    fn read(&mut self, out: &mut [i16]) -> usize;
}

/// One deterministic sample of the synthetic take at `index`.
///
/// It is a 220 Hz sine at 12 000 of full scale: smooth enough that linear
/// resampling of a nearby sample is a fair check, distinct enough that a
/// reordered or restarted source is visible. The test recomputes it to compare
/// the local WAV exactly.
pub fn synthetic_sample(rate: u32, index: u64) -> i16 {
    let phase = std::f64::consts::TAU * 220.0 * index as f64 / rate as f64;
    (12_000.0 * phase.sin()).round() as i16
}

/// A known-signal input for the tests: no hardware, same contract as a device.
pub struct SyntheticSource {
    rate: u32,
    period: usize,
    total: u64,
    produced: u64,
    /// The pacing reference. It starts on the first read, not at construction,
    /// so a slow handshake is not mistaken for a source that is behind.
    started: Option<Instant>,
}

impl SyntheticSource {
    pub fn new(rate: u32, total: u64, period: usize) -> Self {
        SyntheticSource {
            rate,
            period: period.max(1),
            total,
            produced: 0,
            started: None,
        }
    }
}

impl LiveSource for SyntheticSource {
    fn rate(&self) -> u32 {
        self.rate
    }

    fn read(&mut self, out: &mut [i16]) -> usize {
        if out.is_empty() || self.produced >= self.total {
            return 0;
        }
        let started = *self.started.get_or_insert_with(Instant::now);
        // Frame `n` is due `n / rate` seconds after the source started. If the
        // sender is behind, the source catches up without sleeping, the way a
        // device fills the ring it was given.
        let nanos = (u128::from(self.produced) * 1_000_000_000 / u128::from(self.rate)) as u64;
        let due = started + Duration::from_nanos(nanos);
        let now = Instant::now();
        if due > now {
            thread::sleep(due - now);
        }

        let count = (self.total - self.produced)
            .min(self.period as u64)
            .min(out.len() as u64) as usize;
        for (offset, slot) in out.iter_mut().take(count).enumerate() {
            *slot = synthetic_sample(self.rate, self.produced + offset as u64);
        }
        self.produced += count as u64;
        count
    }
}

/// One slot's sample and its capture sequence number, both atomic so the
/// capture thread and the clock loop share the ring without a lock.
#[derive(Debug)]
struct RingInner {
    samples: Box<[AtomicI32]>,
    seqs: Box<[AtomicU64]>,
    mask: usize,
    /// Accepted frame counter, not an index into `samples`.
    write: AtomicUsize,
    read: AtomicUsize,
    /// Every frame the source produced, including ones the ring refused.
    produced: AtomicU64,
    /// Frames the ring refused because it was full.
    overflow: AtomicU64,
}

/// A capture-to-sender ring of `frames` mono i16 frames, rounded up to a power
/// of two. The producer side is moved to the capture thread; this handle stays
/// with the caller for its counters.
pub fn live_ring(frames: usize) -> (LiveProducer, LiveConsumer) {
    let frames = frames.max(2).next_power_of_two();
    let inner = Arc::new(RingInner {
        samples: (0..frames).map(|_| AtomicI32::new(0)).collect(),
        seqs: (0..frames).map(|_| AtomicU64::new(0)).collect(),
        mask: frames - 1,
        write: AtomicUsize::new(0),
        read: AtomicUsize::new(0),
        produced: AtomicU64::new(0),
        overflow: AtomicU64::new(0),
    });
    (
        LiveProducer {
            inner: Arc::clone(&inner),
        },
        LiveConsumer { inner },
    )
}

/// The capture thread's handle to the ring. Never blocks; a full ring returns
/// the number of frames dropped from the block.
#[derive(Clone, Debug)]
pub struct LiveProducer {
    inner: Arc<RingInner>,
}

impl LiveProducer {
    /// Offer one mono block. Returns the frames refused because the ring was
    /// full; the newest frames are the ones dropped.
    pub fn push(&self, block: &[i16]) -> usize {
        if block.is_empty() {
            return 0;
        }
        let base = self
            .inner
            .produced
            .fetch_add(block.len() as u64, Ordering::Relaxed);
        let write = self.inner.write.load(Ordering::Relaxed);
        let read = self.inner.read.load(Ordering::Acquire);
        let capacity = self.inner.mask + 1;
        let free = capacity.saturating_sub(write.wrapping_sub(read));
        let accepted = block.len().min(free);

        for (offset, sample) in block.iter().take(accepted).enumerate() {
            let slot = write.wrapping_add(offset) & self.inner.mask;
            self.inner.samples[slot].store(i32::from(*sample), Ordering::Relaxed);
            self.inner.seqs[slot].store(base + offset as u64, Ordering::Relaxed);
        }
        if accepted > 0 {
            self.inner
                .write
                .store(write.wrapping_add(accepted), Ordering::Release);
        }
        let dropped = block.len() - accepted;
        if dropped > 0 {
            self.inner
                .overflow
                .fetch_add(dropped as u64, Ordering::Relaxed);
        }
        dropped
    }

    /// Every frame the source produced and handed over, including ring drops.
    pub fn produced(&self) -> u64 {
        self.inner.produced.load(Ordering::Relaxed)
    }

    /// Frames the ring refused because it was full.
    pub fn overflow(&self) -> u64 {
        self.inner.overflow.load(Ordering::Relaxed)
    }
}

/// What one sender window took from the ring.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct WindowReport {
    /// Captured frames placed in the window.
    pub used: usize,
    /// Silence inserted where the capture had no frame (the stated rule).
    pub padded: usize,
    /// Captured frames discarded because their window had already passed.
    pub stale: usize,
}

/// The sender's handle to the ring.
#[derive(Clone, Debug)]
pub struct LiveConsumer {
    inner: Arc<RingInner>,
}

impl LiveConsumer {
    /// Frames still in the ring, including ones the next window will discard as
    /// stale.
    pub fn pending(&self) -> usize {
        let write = self.inner.write.load(Ordering::Acquire);
        let read = self.inner.read.load(Ordering::Relaxed);
        write.wrapping_sub(read)
    }

    /// The capture sequence of the oldest frame still in the ring.
    pub fn next_seq(&self) -> Option<u64> {
        let write = self.inner.write.load(Ordering::Acquire);
        let read = self.inner.read.load(Ordering::Relaxed);
        if write == read {
            None
        } else {
            Some(self.inner.seqs[read & self.inner.mask].load(Ordering::Relaxed))
        }
    }

    /// Fill exactly `out.len()` source frames for the window starting at the
    /// sender's `local` position.
    ///
    /// A frame whose sequence is older than `local` is dropped: its span was
    /// already padded, so sending it now would place audio a block late. A
    /// frame newer than the window stays in the ring. The gaps are zeroed, which
    /// is the concealment rule — the sender keeps the master timeline whole and
    /// the report counts what it had to invent.
    pub fn window(&self, local: u64, out: &mut [i16]) -> WindowReport {
        out.fill(0);
        if out.is_empty() {
            return WindowReport::default();
        }
        let end = local.saturating_add(out.len() as u64);
        let write = self.inner.write.load(Ordering::Acquire);
        let mut read = self.inner.read.load(Ordering::Relaxed);
        let mut stale = 0usize;

        // Frames from a span the sender has already passed are not late audio
        // any more; they are a gap that was concealed.
        while read != write {
            let seq = self.inner.seqs[read & self.inner.mask].load(Ordering::Relaxed);
            if seq < local {
                stale += 1;
                read = read.wrapping_add(1);
            } else {
                break;
            }
        }

        let mut used = 0usize;
        while read != write {
            let slot = read & self.inner.mask;
            let seq = self.inner.seqs[slot].load(Ordering::Relaxed);
            if seq >= end {
                break;
            }
            if seq >= local {
                let at = (seq - local) as usize;
                out[at] = self.inner.samples[slot].load(Ordering::Relaxed) as i16;
                used += 1;
            } else {
                stale += 1;
            }
            read = read.wrapping_add(1);
        }

        self.inner.read.store(read, Ordering::Release);
        WindowReport {
            used,
            padded: out.len() - used,
            stale,
        }
    }
}

/// A running capture thread.
pub struct CaptureHandle {
    stop: Arc<AtomicBool>,
    started: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
    error: Arc<Mutex<Option<String>>>,
    handle: Option<JoinHandle<()>>,
}

impl CaptureHandle {
    /// Ask the capture to stop. The thread finishes its current block and then
    /// closes the local take; the sender keeps draining the ring until
    /// [`CaptureHandle::finished`] and the ring is empty.
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
    }

    /// True once the first captured block is on disk and in the ring. The
    /// sender anchors its clock here, so a source that opens a moment later
    /// cannot make the send window run permanently ahead of the capture.
    pub fn started(&self) -> bool {
        self.started.load(Ordering::Acquire)
    }

    /// Wait a bounded time for the first block, or until the capture ends.
    /// A device that is slow to open is not an error; the sender pads until its
    /// first block arrives and the report says so.
    pub fn wait_started(&self, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        while !self.started() && !self.finished() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(1));
        }
    }

    pub fn finished(&self) -> bool {
        self.finished.load(Ordering::Acquire)
    }

    /// The first failure the capture thread saw, if any. Locked only after the
    /// run, never on the audio path.
    pub fn error(&self) -> Option<String> {
        self.error.lock().ok().and_then(|error| error.clone())
    }

    /// Stop and wait for the thread. Safe to call when already finished.
    pub fn join(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

fn record_error(slot: &Mutex<Option<String>>, message: String) {
    if let Ok(mut error) = slot.lock() {
        if error.is_none() {
            *error = Some(message);
        }
    }
}

/// The shared thread body for a software source. It owns the local WAV, so
/// every frame is on disk before the same frame is offered to the ring (D14).
pub fn start_source(
    mut source: Box<dyn LiveSource>,
    rate: u32,
    period: usize,
    out: &Path,
    producer: LiveProducer,
) -> Result<CaptureHandle, String> {
    if source.rate() != rate {
        return Err(format!(
            "the live source is {} Hz, but --rate is {rate} Hz: a live capture is not resampled to another rate",
            source.rate()
        ));
    }
    let writer = WavWriter::create(out, rate, 1, period.max(1))
        .map_err(|error| format!("cannot write {}: {error}", out.display()))?;
    let stop = Arc::new(AtomicBool::new(false));
    let started = Arc::new(AtomicBool::new(false));
    let finished = Arc::new(AtomicBool::new(false));
    let error = Arc::new(Mutex::new(None));

    let thread_stop = Arc::clone(&stop);
    let thread_started = Arc::clone(&started);
    let thread_finished = Arc::clone(&finished);
    let thread_error = Arc::clone(&error);
    let handle = thread::Builder::new()
        .name("jawn-audio-live-capture".to_string())
        .spawn(move || {
            let sync_frames = (u64::from(rate) / SYNC_SECONDS).max(1);
            let mut writer = writer;
            let mut block = vec![0i16; period.max(1)];
            let mut since_sync = 0u64;
            loop {
                if thread_stop.load(Ordering::Acquire) {
                    break;
                }
                let frames = source.read(&mut block);
                if frames == 0 {
                    break;
                }
                let block = &block[..frames];
                // D14: the peer's take first, then the send ring.
                if let Err(error) = writer.write_i16_unsynced(block) {
                    record_error(&thread_error, format!("write the local take: {error}"));
                    break;
                }
                since_sync += frames as u64;
                if since_sync >= sync_frames {
                    if let Err(error) = writer.sync() {
                        record_error(&thread_error, format!("sync the local take: {error}"));
                        break;
                    }
                    since_sync = 0;
                }
                producer.push(block);
                // The first block anchors the sender's clock.
                thread_started.store(true, Ordering::Release);
            }
            if let Err(error) = writer.finish() {
                record_error(&thread_error, format!("finish the local take: {error}"));
            }
            thread_finished.store(true, Ordering::Release);
        })
        .map_err(|error| format!("cannot start the capture thread: {error}"))?;

    Ok(CaptureHandle {
        stop,
        started,
        finished,
        error,
        handle: Some(handle),
    })
}

/// Start the existing ALSA capture seam for `device`.
pub fn start_hardware(
    backend: BackendKind,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
    out: &Path,
    producer: LiveProducer,
) -> Result<CaptureHandle, String> {
    match backend {
        BackendKind::Null => {
            return Err(
                "the null backend has no capture input; pass --backend alsa (or pipewire)"
                    .to_string(),
            )
        }
        BackendKind::Jack => {
            return Err("no JACK capture backend yet; use --backend alsa".to_string())
        }
        BackendKind::Alsa | BackendKind::PipeWire => {}
    }
    #[cfg(not(feature = "alsa"))]
    {
        let _ = (device, rate, period, buffer, out, producer);
        Err("this build has no ALSA/PipeWire backend; rebuild with --features alsa".to_string())
    }
    #[cfg(feature = "alsa")]
    {
        // Open and close the device before the file, as `--record` does: a busy
        // or missing input must not truncate a take the caller already named.
        let granted = crate::alsa_device::check_capture(device, rate, period, buffer, 1)
            .map_err(|error| format!("cannot capture: {error}"))?;
        if granted == 0 {
            return Err("the capture device granted no channels".to_string());
        }
        let writer = WavWriter::create(out, rate, 1, period.max(1))
            .map_err(|error| format!("cannot write {}: {error}", out.display()))?;
        let stop = Arc::new(AtomicBool::new(false));
        let started = Arc::new(AtomicBool::new(false));
        let finished = Arc::new(AtomicBool::new(false));
        let error = Arc::new(Mutex::new(None));

        let sink = HardwareSink {
            writer: Some(writer),
            producer,
            mono: Vec::new(),
            channels: 0,
            expected_rate: rate,
            since_sync: 0,
            sync_frames: 1,
            stop: Arc::clone(&stop),
            started: Arc::clone(&started),
            error: Arc::clone(&error),
        };
        let thread_stop = Arc::clone(&stop);
        let thread_finished = Arc::clone(&finished);
        let thread_error = Arc::clone(&error);
        let device = device.to_string();
        let handle = thread::Builder::new()
            .name("jawn-audio-live-capture".to_string())
            .spawn(move || {
                // No wall-clock limit: the stop flag is checked in every block,
                // so the sender's deadline (or the end of the run) is what ends
                // the capture, and the local take still closes cleanly.
                let result = crate::alsa_device::run_capture(
                    &device,
                    rate,
                    period,
                    buffer,
                    1,
                    f64::INFINITY,
                    sink,
                );
                if let Err(message) = result {
                    if !thread_stop.load(Ordering::Acquire) {
                        record_error(&thread_error, format!("{device}: {message}"));
                    }
                }
                thread_finished.store(true, Ordering::Release);
            })
            .map_err(|error| format!("cannot start the capture thread: {error}"))?;

        Ok(CaptureHandle {
            stop,
            started,
            finished,
            error,
            handle: Some(handle),
        })
    }
}

/// The hardware sink: mono channel 0 of the granted capture, written locally
/// first and then offered to the send ring. Its buffers are allocated once in
/// `prepared`; `block` does no allocation and no locking.
#[cfg(feature = "alsa")]
struct HardwareSink {
    /// `None` only after `Drop` has taken it to close the take.
    writer: Option<WavWriter>,
    producer: LiveProducer,
    mono: Vec<i16>,
    channels: usize,
    expected_rate: u32,
    since_sync: u64,
    sync_frames: u64,
    stop: Arc<AtomicBool>,
    /// Set after the first block reaches the WAV and the ring.
    started: Arc<AtomicBool>,
    error: Arc<Mutex<Option<String>>>,
}

#[cfg(feature = "alsa")]
impl crate::alsa_device::CaptureSink for HardwareSink {
    fn prepared(&mut self, rate: u32, period: usize, channels: usize) -> Result<(), String> {
        if rate != self.expected_rate {
            return Err(format!(
                "the device granted {rate} Hz, but --rate is {} Hz: a live capture is not resampled to another rate",
                self.expected_rate
            ));
        }
        if channels == 0 {
            return Err("the device granted no capture channels".to_string());
        }
        self.channels = channels;
        self.mono.resize(period.max(1), 0);
        self.sync_frames = (u64::from(rate) / SYNC_SECONDS).max(1);
        Ok(())
    }

    fn block(&mut self, block: &[i16]) -> Result<(), String> {
        if self.stop.load(Ordering::Acquire) {
            // The sender has drained its deadline; `run_capture` turns this
            // into a returned error, which the thread reports as a clean stop.
            return Err("live capture stopped".to_string());
        }
        let channels = self.channels.max(1);
        let frames = (block.len() / channels).min(self.mono.len());
        if frames == 0 {
            return Ok(());
        }
        for (index, slot) in self.mono.iter_mut().take(frames).enumerate() {
            *slot = block[index * channels];
        }
        let mono = &self.mono[..frames];
        let writer = self
            .writer
            .as_mut()
            .ok_or_else(|| "the local take is already closed".to_string())?;
        // D14: the peer's take first, then the send ring.
        writer
            .write_i16_unsynced(mono)
            .map_err(|error| format!("write the local take: {error}"))?;
        self.since_sync += frames as u64;
        if self.since_sync >= self.sync_frames {
            writer
                .sync()
                .map_err(|error| format!("sync the local take: {error}"))?;
            self.since_sync = 0;
        }
        self.producer.push(mono);
        // The first block anchors the sender's clock.
        self.started.store(true, Ordering::Release);
        Ok(())
    }
}

#[cfg(feature = "alsa")]
impl Drop for HardwareSink {
    fn drop(&mut self) {
        if let Some(writer) = self.writer.take() {
            if let Err(error) = writer.finish() {
                record_error(&self.error, format!("finish the local take: {error}"));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_window_pads_a_gap_and_counts_it() {
        let (producer, consumer) = live_ring(64);
        assert_eq!(producer.push(&[1, 2, 3]), 0);
        let mut out = [9i16; 5];
        let report = consumer.window(0, &mut out);
        assert_eq!(report.used, 3);
        assert_eq!(report.padded, 2);
        assert_eq!(&out, &[1, 2, 3, 0, 0]);
        assert_eq!(consumer.pending(), 0);
    }

    #[test]
    fn a_frame_whose_span_was_padded_is_dropped_not_sent_late() {
        let (producer, consumer) = live_ring(64);
        let mut out = [0i16; 4];
        // Nothing captured yet: the window is silence.
        assert_eq!(consumer.window(0, &mut out), WindowReport { used: 0, padded: 4, stale: 0 });
        // The late frames for that span arrive afterwards and must not be sent
        // as if they were the next block.
        producer.push(&[10, 11, 12, 13]);
        let report = consumer.window(4, &mut out);
        assert_eq!(report, WindowReport { used: 0, padded: 4, stale: 4 });
        assert_eq!(consumer.pending(), 0);
    }

    #[test]
    fn an_overflow_keeps_the_oldest_and_counts_the_newest() {
        let (producer, consumer) = live_ring(8);
        let block: Vec<i16> = (0..12).collect();
        assert_eq!(producer.push(&block), 4, "four newest frames are refused");
        assert_eq!(producer.produced(), 12);
        assert_eq!(producer.overflow(), 4);
        let mut out = [0i16; 8];
        let report = consumer.window(0, &mut out);
        assert_eq!(report.used, 8);
        assert_eq!(&out, &[0, 1, 2, 3, 4, 5, 6, 7]);
    }

    #[test]
    fn a_newer_window_keeps_the_frames_it_does_not_own() {
        let (producer, consumer) = live_ring(32);
        producer.push(&[0, 1, 2, 3, 4, 5]);
        let mut out = [0i16; 3];
        let report = consumer.window(0, &mut out);
        assert_eq!(report.used, 3);
        assert_eq!(&out, &[0, 1, 2]);
        assert_eq!(consumer.next_seq(), Some(3));
        let report = consumer.window(3, &mut out);
        assert_eq!(report.used, 3);
        assert_eq!(&out, &[3, 4, 5]);
        assert_eq!(consumer.pending(), 0);
    }

    #[test]
    fn the_synthetic_source_produces_its_known_pattern_and_ends() {
        let mut source = SyntheticSource::new(48_000, 6, 4);
        let mut out = [0i16; 4];
        assert_eq!(source.read(&mut out), 4);
        assert_eq!(&out, &[
            synthetic_sample(48_000, 0),
            synthetic_sample(48_000, 1),
            synthetic_sample(48_000, 2),
            synthetic_sample(48_000, 3),
        ]);
        assert_eq!(source.read(&mut out), 2);
        assert_eq!(out[0], synthetic_sample(48_000, 4));
        assert_eq!(out[1], synthetic_sample(48_000, 5));
        assert_eq!(source.read(&mut out), 0, "the source is finished");
    }
}
