//! P4's live input: a capture device feeding the sender.
//!
//! D14 says the peer owns its take, so the capture thread writes every block to
//! the local WAV **before** the same frames are offered to the sender's ring.
//! The clock loop only pops whole frames from that ring, so a slow disk or a
//! late device is a counted gap in an otherwise steady send loop, never a stall
//! in it (docs/studio-audio-roadmap.md P4).
//!
//! The ring is fixed-size and lock-free, like [`crate::monbus`]. Each slot is a
//! single atomic that holds the capture sequence number and the sample together,
//! so a producer overwriting the oldest frame can never tear a sample away from
//! its sequence. The window discards frames whose span the sender has already
//! passed and, when the sender has fallen behind the whole ring, resynchronises
//! to the live edge instead of stalling. A full ring **overwrites the oldest**
//! frames and counts them: the live edge is the part worth sending.
//!
//! The null backend has no input, so this module does not pretend it does. A
//! [`SyntheticSource`] is the test source; real hardware is the existing ALSA
//! capture seam ([`crate::alsa_device::run_capture`]) behind the same sink
//! contract `--record` uses.

use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use crate::backends::BackendKind;
use crate::wav::WavWriter;

/// Frames the capture thread may run ahead of the sender: 341 ms at 48 kHz.
/// That rides out a scheduler hiccup or one disk stall without delaying the
/// send loop. A full ring overwrites its oldest frames, so the ring always holds
/// the newest audio and the sender can resynchronise to it.
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
    /// The sample rate the samples are numbered at. It is also the rate the
    /// sender expects in `--rate`.
    rate: u32,
    /// Frames the source actually produces per wall second. Equal to `rate`
    /// unless a test injects a device rate error, which is exactly how a real
    /// crystal differs from the host.
    cadence_hz: u32,
    period: usize,
    total: u64,
    produced: u64,
    /// The pacing reference. It starts on the first read, not at construction,
    /// so a slow handshake is not mistaken for a source that is behind.
    started: Option<Instant>,
}

impl SyntheticSource {
    pub fn new(rate: u32, total: u64, period: usize) -> Self {
        Self::with_cadence(rate, rate, total, period)
    }

    /// A source whose samples are at `rate` but which produces `cadence_hz`
    /// frames per wall second. A cadence below the rate models a capture device
    /// that runs slow; the sender must clock it by the frames it actually
    /// produces, not by the wall.
    pub fn with_cadence(rate: u32, cadence_hz: u32, total: u64, period: usize) -> Self {
        SyntheticSource {
            rate,
            cadence_hz: cadence_hz.max(1),
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
        // Frame `n` is due `n / cadence` seconds after the source started. If
        // the sender is behind, the source catches up without sleeping, the way
        // a device fills the ring it was given.
        let nanos =
            (u128::from(self.produced) * 1_000_000_000 / u128::from(self.cadence_hz)) as u64;
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

/// One ring slot: the capture sequence in the high 48 bits and the sample in
/// the low 16, stored as one atomic. A single store is what makes overwriting
/// the oldest frame safe: a consumer cannot read a sample torn away from the
/// sequence it belongs to. At 48 kHz the sequence takes about 186 years to
/// outgrow 48 bits.
fn pack(seq: u64, sample: i16) -> u64 {
    (seq << 16) | u64::from(sample as u16)
}

fn unpack(value: u64) -> (u64, i16) {
    (value >> 16, value as u16 as i16)
}

/// The capture thread and the clock loop share one fixed ring without a lock.
#[derive(Debug)]
struct RingInner {
    /// `pack(seq, sample)` per frame.
    slots: Box<[AtomicU64]>,
    mask: u64,
    /// Frames written (and therefore the next sequence), not an index.
    write: AtomicU64,
    /// Oldest frame the consumer may still read, not an index.
    read: AtomicU64,
    /// Every frame the source produced, including ones the ring overwrote.
    produced: AtomicU64,
    /// Frames overwritten before the consumer read them.
    overflow: AtomicU64,
}

/// A capture-to-sender ring of `frames` mono i16 frames, rounded up to a power
/// of two. The producer side is moved to the capture thread; this handle stays
/// with the caller for its counters.
pub fn live_ring(frames: usize) -> (LiveProducer, LiveConsumer) {
    let frames = frames.max(2).next_power_of_two();
    let inner = Arc::new(RingInner {
        slots: (0..frames).map(|_| AtomicU64::new(0)).collect(),
        mask: (frames - 1) as u64,
        write: AtomicU64::new(0),
        read: AtomicU64::new(0),
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

/// The capture thread's handle to the ring. Never blocks; a full ring
/// overwrites the oldest frames and returns how many it discarded.
#[derive(Clone, Debug)]
pub struct LiveProducer {
    inner: Arc<RingInner>,
}

impl LiveProducer {
    /// Offer one mono block. Returns the frames this push discarded (the oldest
    /// frames in the ring), so a caller that wants its own count can read it;
    /// the running total is also in [`LiveProducer::overflow`].
    ///
    /// The ring keeps the **newest** frames. A producer that outruns the sender
    /// overwrites the oldest, which is the audio a live send wants to skip
    /// rather than send a second late.
    pub fn push(&self, block: &[i16]) -> usize {
        if block.is_empty() {
            return 0;
        }
        let capacity = self.inner.mask + 1;
        // Claim the sequence range before publishing any slot: two pushes from
        // one thread are ordered, and the consumer never relies on `produced`
        // to read a slot (it uses `write`).
        let base = self
            .inner
            .produced
            .fetch_add(block.len() as u64, Ordering::Relaxed);
        let write = self.inner.write.load(Ordering::Relaxed);
        for (offset, sample) in block.iter().enumerate() {
            let slot = ((write + offset as u64) & self.inner.mask) as usize;
            self.inner.slots[slot].store(pack(base + offset as u64, *sample), Ordering::Relaxed);
        }
        let new_write = write + block.len() as u64;
        self.inner.write.store(new_write, Ordering::Release);

        // The ring now holds the newest `capacity` frames. Any unread frame
        // older than that was overwritten by this push; move the consumer's
        // cursor over it and count it.
        let oldest_valid = new_write.saturating_sub(capacity);
        let before = self.inner.read.fetch_max(oldest_valid, Ordering::AcqRel);
        let overwritten = oldest_valid.saturating_sub(before);
        if overwritten > 0 {
            self.inner
                .overflow
                .fetch_add(overwritten, Ordering::Relaxed);
        }
        overwritten as usize
    }

    /// Every frame the source produced and handed over, including overwritten
    /// ones. This is the report's `captured`.
    pub fn produced(&self) -> u64 {
        self.inner.produced.load(Ordering::Relaxed)
    }

    /// The next frame sequence, i.e. the live edge. `written - 1` is the newest
    /// frame the ring holds.
    pub fn written(&self) -> u64 {
        self.inner.write.load(Ordering::Acquire)
    }

    /// Frames overwritten before the consumer read them.
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
    /// Set when the sender's `local` was behind the whole ring: the window was
    /// filled from this capture sequence instead, and the caller must adopt it
    /// as its next local position. A resynchronised window never leaves the
    /// consumer stalled and the producer overflowing forever.
    pub resync: Option<u64>,
}

/// The sender's handle to the ring.
#[derive(Clone, Debug)]
pub struct LiveConsumer {
    inner: Arc<RingInner>,
}

impl LiveConsumer {
    /// The read cursor, clamped to the oldest frame a full ring can still hold.
    /// A producer overlay can advance `read` between the two atomics; the clamp
    /// keeps a window from reading a slot that is already a newer frame.
    fn read_cursor(&self, write: u64) -> u64 {
        let capacity = self.inner.mask + 1;
        let read = self.inner.read.load(Ordering::Relaxed);
        read.max(write.saturating_sub(capacity))
    }

    /// Frames still in the ring, including ones the next window will discard as
    /// stale.
    pub fn pending(&self) -> usize {
        let write = self.inner.write.load(Ordering::Acquire);
        let read = self.read_cursor(write);
        write.saturating_sub(read) as usize
    }

    /// The capture sequence of the oldest frame still in the ring.
    pub fn next_seq(&self) -> Option<u64> {
        let write = self.inner.write.load(Ordering::Acquire);
        let read = self.read_cursor(write);
        if read == write {
            None
        } else {
            Some(unpack(self.inner.slots[(read & self.inner.mask) as usize].load(Ordering::Relaxed)).0)
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
    ///
    /// If even the oldest frame in the ring is newer than this window, the
    /// sender has fallen behind the whole ring. Rather than break without
    /// advancing `read` — which leaves the producer overwriting forever — the
    /// window is filled from the newest full window in the ring and
    /// [`WindowReport::resync`] names its start. The caller adopts that as its
    /// local position, so the stalled span is skipped, not replayed late.
    pub fn window(&self, local: u64, out: &mut [i16]) -> WindowReport {
        out.fill(0);
        if out.is_empty() {
            return WindowReport::default();
        }
        let write = self.inner.write.load(Ordering::Acquire);
        let mut read = self.read_cursor(write);
        let mut start = local;
        let mut resync = None;

        let requested_end = local.saturating_add(out.len() as u64);
        if read != write {
            let (oldest_seq, _) = unpack(
                self.inner.slots[(read & self.inner.mask) as usize].load(Ordering::Relaxed),
            );
            if oldest_seq >= requested_end {
                // Nothing in the ring belongs to this window. The newest full
                // window ends at the live edge (`write`), and is wholly in the
                // ring unless the ring itself is shorter than one window.
                let target = write
                    .saturating_sub(out.len() as u64)
                    .max(oldest_seq);
                if target > local {
                    start = target;
                    resync = Some(target);
                }
            }
        }
        let end = start.saturating_add(out.len() as u64);
        let mut stale = 0usize;

        // Frames from a span the sender has already passed are not late audio
        // any more; they are a gap that was concealed.
        while read != write {
            let (seq, _) = unpack(
                self.inner.slots[(read & self.inner.mask) as usize].load(Ordering::Relaxed),
            );
            if seq < start {
                stale += 1;
                read += 1;
            } else {
                break;
            }
        }

        let mut used = 0usize;
        while read != write {
            let (seq, sample) = unpack(
                self.inner.slots[(read & self.inner.mask) as usize].load(Ordering::Relaxed),
            );
            if seq >= end {
                break;
            }
            if seq >= start {
                out[(seq - start) as usize] = sample;
                used += 1;
            } else {
                stale += 1;
            }
            read += 1;
        }

        // Never move the cursor backwards: a producer overlay may have advanced
        // it past the local copy while this window was reading.
        self.inner.read.fetch_max(read, Ordering::AcqRel);
        WindowReport {
            used,
            padded: out.len() - used,
            stale,
            resync,
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
        assert_eq!(
            consumer.window(0, &mut out),
            WindowReport {
                used: 0,
                padded: 4,
                stale: 0,
                resync: None,
            }
        );
        // The late frames for that span arrive afterwards and must not be sent
        // as if they were the next block.
        producer.push(&[10, 11, 12, 13]);
        let report = consumer.window(4, &mut out);
        assert_eq!(
            report,
            WindowReport {
                used: 0,
                padded: 4,
                stale: 4,
                resync: None,
            }
        );
        assert_eq!(consumer.pending(), 0);
    }

    #[test]
    fn an_overflow_keeps_the_newest_and_counts_the_overwritten() {
        let (producer, consumer) = live_ring(8);
        let block: Vec<i16> = (0..12).collect();
        assert_eq!(producer.push(&block), 4, "four oldest frames are overwritten");
        assert_eq!(producer.produced(), 12);
        assert_eq!(producer.written(), 12);
        assert_eq!(producer.overflow(), 4);
        let mut out = [0i16; 8];
        let report = consumer.window(0, &mut out);
        assert_eq!(report.used, 4, "only the newest half of the window survives");
        assert_eq!(report.padded, 4);
        assert_eq!(&out, &[0, 0, 0, 0, 4, 5, 6, 7]);
        assert_eq!(consumer.next_seq(), Some(8), "the ring holds the live edge");
    }

    #[test]
    fn a_full_ring_resynchronises_to_the_live_edge_instead_of_stalling() {
        // The old failure: a producer far ahead of the window left `read` stuck
        // at the first frame past the window, so `used` was 0 forever and the
        // ring overflowed. Now the window jumps to the newest full window.
        let (producer, consumer) = live_ring(8);
        let block: Vec<i16> = (0..32).collect();
        producer.push(&block);
        let mut out = [0i16; 8];
        let report = consumer.window(0, &mut out);
        assert_eq!(
            report,
            WindowReport {
                used: 8,
                padded: 0,
                stale: 0,
                resync: Some(24),
            }
        );
        assert_eq!(&out, &[24, 25, 26, 27, 28, 29, 30, 31]);
        assert_eq!(consumer.pending(), 0, "the stale span is behind us");

        // The next live block is consumed normally from the adopted position.
        producer.push(&[32, 33, 34, 35, 36, 37, 38, 39]);
        let report = consumer.window(32, &mut out);
        assert_eq!(report.resync, None);
        assert_eq!(report.used, 8);
        assert_eq!(&out, &[32, 33, 34, 35, 36, 37, 38, 39]);
    }

    #[test]
    fn a_window_never_stalls_while_the_ring_wraps() {
        let (producer, consumer) = live_ring(8);
        let mut out = [0i16; 8];
        let mut local = 0u64;
        for batch in 0..6u64 {
            let block: Vec<i16> = (0..16).map(|offset| (batch * 16 + offset) as i16).collect();
            producer.push(&block);
            let report = consumer.window(local, &mut out);
            assert_eq!(report.used + report.padded, out.len());
            assert!(
                report.used > 0 || report.resync.is_some(),
                "window stalled at {local}: {report:?}"
            );
            let next = report.resync.unwrap_or(local + out.len() as u64);
            assert!(next > local, "the cursor must move forward: {next} <= {local}");
            local = next;
        }
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
