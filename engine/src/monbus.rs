//! The live-input monitoring bus.
//!
//! A take's capture thread owns the producer and the monitor's playback thread
//! owns the consumer. The take must never wait on the monitor, so the ring is
//! fixed-size and lock-free: an overflow discards the *newest* frames and counts
//! them, and an underrun zero-fills rather than stalling. Both are measured,
//! never errors.
//!
//! Frames are interleaved stereo `f32`, the same shape the monitor's master bus
//! already has. The buffer is allocated once in [`MonitorBus::new`]; nothing on
//! the audio path allocates, locks or panics.

use std::sync::atomic::{AtomicU32, AtomicU64, AtomicUsize, Ordering};
use std::sync::Arc;

/// The smallest ring: about 85 ms of stereo at 48 kHz, enough to ride out a
/// scheduling hiccup between the capture and monitor threads.
pub const MIN_FRAMES: usize = 4096;

/// Create a producer/consumer pair sharing one ring of at least `frames`
/// stereo frames. `frames` is rounded up to a power of two because the ring
/// indexes with a mask.
pub fn new(frames: usize) -> (Producer, Consumer) {
    let frames = frames.max(MIN_FRAMES).next_power_of_two();
    let inner = Arc::new(Inner {
        samples: (0..frames * 2)
            .map(|_| AtomicU32::new(0))
            .collect::<Vec<_>>()
            .into_boxed_slice(),
        mask: frames - 1,
        write: AtomicUsize::new(0),
        read: AtomicUsize::new(0),
        drops: AtomicU64::new(0),
    });
    (
        Producer {
            inner: Arc::clone(&inner),
        },
        Consumer { inner },
    )
}

/// A named constructor, so a caller can read the module without a bare `new`.
pub struct MonitorBus;

impl MonitorBus {
    pub fn new(frames: usize) -> (Producer, Consumer) {
        new(frames)
    }
}

#[derive(Debug)]
struct Inner {
    /// Interleaved stereo samples; `frame * 2` is the left one.
    samples: Box<[AtomicU32]>,
    /// `capacity - 1`, because the capacity is a power of two.
    mask: usize,
    /// A monotonic frame counter, not an index into `samples`.
    write: AtomicUsize,
    read: AtomicUsize,
    /// Frames the producer discarded because the ring was full.
    drops: AtomicU64,
}

/// The capture side. It never blocks: a full ring is a short return value.
#[derive(Debug)]
pub struct Producer {
    inner: Arc<Inner>,
}

impl Producer {
    /// Push whole stereo frames. Returns the number of frames **dropped**
    /// because the ring was full; the oldest frames stay and the newest are
    /// discarded, so the monitor hears a gap at the live edge rather than
    /// delaying the take behind a late monitor.
    pub fn push(&self, block: &[f32]) -> usize {
        let frames = block.len() / 2;
        let write = self.inner.write.load(Ordering::Relaxed);
        let read = self.inner.read.load(Ordering::Acquire);
        let capacity = self.inner.mask + 1;
        let available = capacity.saturating_sub(write.wrapping_sub(read));
        let accepted = frames.min(available);

        let start = write & self.inner.mask;
        for index in 0..accepted {
            let slot = ((start + index) & self.inner.mask) * 2;
            self.inner.samples[slot].store(block[index * 2].to_bits(), Ordering::Relaxed);
            self.inner.samples[slot + 1]
                .store(block[index * 2 + 1].to_bits(), Ordering::Relaxed);
        }
        if accepted > 0 {
            self.inner
                .write
                .store(write.wrapping_add(accepted), Ordering::Release);
        }
        let dropped = frames - accepted;
        if dropped > 0 {
            self.inner.drops.fetch_add(dropped as u64, Ordering::Relaxed);
        }
        dropped
    }

    /// Frames discarded since the bus was created.
    pub fn dropped(&self) -> u64 {
        self.inner.drops.load(Ordering::Relaxed)
    }
}

/// The monitor side. It reads whole stereo frames and zero-fills the rest of a
/// requested buffer, so a late capture is a dropout rather than a stale tail.
#[derive(Debug)]
pub struct Consumer {
    inner: Arc<Inner>,
}

impl Consumer {
    /// Pop up to `out.len() / 2` whole stereo frames into `out`, zero-filling
    /// the remainder. Returns the number of frames actually read.
    pub fn pop(&self, out: &mut [f32]) -> usize {
        let wanted = out.len() / 2;
        let read = self.inner.read.load(Ordering::Relaxed);
        let write = self.inner.write.load(Ordering::Acquire);
        let available = write.wrapping_sub(read);
        let count = wanted.min(available);

        let start = read & self.inner.mask;
        for index in 0..count {
            let slot = ((start + index) & self.inner.mask) * 2;
            out[index * 2] = f32::from_bits(self.inner.samples[slot].load(Ordering::Relaxed));
            out[index * 2 + 1] =
                f32::from_bits(self.inner.samples[slot + 1].load(Ordering::Relaxed));
        }
        // The tail is silence: an underrun must not repeat the last frame.
        for sample in &mut out[count * 2..] {
            *sample = 0.0;
        }
        if count > 0 {
            self.inner
                .read
                .store(read.wrapping_add(count), Ordering::Release);
        }
        count
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    #[test]
    fn a_push_and_a_pop_round_trip_whole_frames() {
        let (producer, consumer) = MonitorBus::new(4096);
        let block = [0.25f32, -0.5, 0.75, -1.0];
        assert_eq!(producer.push(&block), 0);
        let mut out = vec![9.0f32; 4];
        assert_eq!(consumer.pop(&mut out), 2);
        assert_eq!(out, block);
    }

    #[test]
    fn a_full_ring_keeps_the_oldest_and_counts_the_drops() {
        let (producer, consumer) = MonitorBus::new(MIN_FRAMES);
        let frames = MIN_FRAMES + 16;
        let block: Vec<f32> = (0..frames)
            .flat_map(|frame| [frame as f32, -(frame as f32)])
            .collect();
        assert_eq!(producer.push(&block), 16, "the newest frames are dropped");
        assert_eq!(producer.dropped(), 16);

        let mut out = vec![0.0f32; MIN_FRAMES * 2];
        assert_eq!(consumer.pop(&mut out), MIN_FRAMES);
        for frame in 0..MIN_FRAMES {
            assert_eq!(out[frame * 2], frame as f32, "frame {frame} was not the oldest");
            assert_eq!(out[frame * 2 + 1], -(frame as f32));
        }
    }

    #[test]
    fn a_short_ring_zero_fills_the_rest() {
        let (producer, consumer) = MonitorBus::new(4096);
        producer.push(&[1.0, 2.0, 3.0, 4.0]);
        let mut out = vec![7.0f32; 12];
        assert_eq!(consumer.pop(&mut out), 2);
        assert_eq!(&out[0..4], &[1.0, 2.0, 3.0, 4.0]);
        assert!(out[4..].iter().all(|sample| *sample == 0.0), "{out:?}");
    }

    #[test]
    fn a_threaded_producer_and_consumer_keep_their_order() {
        const FRAMES: usize = 100_000;
        // Big enough that a fast producer cannot overflow while the consumer
        // is between pops; this test is about ordering, not drops.
        let (producer, consumer) = MonitorBus::new(FRAMES.next_power_of_two());
        let writer = thread::spawn(move || {
            for frame in 0..FRAMES {
                let value = frame as f32;
                producer.push(&[value, value]);
            }
        });

        let mut out = vec![0.0f32; 256];
        let mut expected = 0usize;
        while expected < FRAMES {
            let got = consumer.pop(&mut out);
            for frame in 0..got {
                assert_eq!(out[frame * 2], expected as f32, "frame {expected} out of order");
                assert_eq!(out[frame * 2 + 1], expected as f32);
                expected += 1;
            }
            if got == 0 {
                // The producer may not have reached this frame yet; the ring
                // holds every frame it has written, so nothing is lost by
                // waiting.
                thread::yield_now();
            }
        }
        writer.join().expect("producer thread");
        assert_eq!(expected, FRAMES, "the consumer lost frames");
    }

    #[test]
    fn the_capacity_rounds_up_to_a_power_of_two() {
        let (producer, consumer) = MonitorBus::new(5000);
        // 8192 frames fit without a drop; 8193 does not.
        let block = vec![0.0f32; 8192 * 2];
        assert_eq!(producer.push(&block), 0);
        let mut dump = vec![0.0f32; 8192 * 2];
        assert_eq!(consumer.pop(&mut dump), 8192);
        let block = vec![0.0f32; 8193 * 2];
        assert_eq!(producer.push(&block), 1);
    }
}
