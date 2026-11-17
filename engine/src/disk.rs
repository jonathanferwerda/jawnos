//! The audio block loop's hand-off to disk.
//!
//! A capture deadline of one period (1.33 ms at 64 frames / 48 kHz) cannot
//! afford a seek, a header rewrite or a stalled filesystem: a missed deadline
//! is a glitch in the take. So the audio side only copies a block into a
//! bounded queue and returns; a writer thread owns the [`WavWriter`] and does
//! every write, seek and sync. [`DiskWriter::push`] never blocks.
//!
//! Dropping is deliberate. If the queue is full — the disk fell behind, the
//! page cache is being written back, the machine stalled — the block is
//! **dropped** and its frames are counted ([`DiskWriter::dropped_frames`]).
//! A gap in a take is bad; blocking the audio thread past its deadline is
//! worse, because it costs every later block too. The take report carries the
//! count so the person learns the take has a gap, rather than the engine
//! pretending a late block arrived on time.
//!
//! The writer thread rewrites the header sizes on a cadence (~0.5 s of audio,
//! not per block) and again in [`DiskWriter::finish`]. Between syncs the header
//! describes an older, shorter prefix of the file: never more samples than are
//! actually on disk, so a killed take is still a valid WAV. The tail since the
//! last sync is not counted in its sizes, which is the price of not seeking on
//! every block; a clean take always ends with an exact header.

use std::fs;
use std::io;
use std::path::Path;
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::thread::{self, JoinHandle};

use crate::wav::{WavError, WavWriter};

/// Frames per header sync: half a second of audio, so the seek cost is paid
/// a couple of times a second instead of once per block (~750/s at 64 frames).
const SYNC_HALF_SECONDS: u64 = 2;

/// A block as it crosses the queue: interleaved i16 samples, already the
/// on-disk format, so the writer thread does no conversion.
type Block = Vec<i16>;

/// The audio side's handle to a writer thread. See the module docs for the
/// drop policy and the header sync cadence.
pub struct DiskWriter {
    sender: SyncSender<Block>,
    channels: u16,
    dropped: u64,
    handle: JoinHandle<Result<u64, WavError>>,
}

impl DiskWriter {
    /// Start a writer thread for `path`. `queue_blocks` is how many blocks may
    /// be waiting before the audio side starts dropping.
    ///
    /// The WAV is created here, on the caller's thread, so a bad path or an
    /// unwritable directory fails before any audio is captured.
    pub fn spawn(
        path: &Path,
        rate: u32,
        channels: u16,
        period: usize,
        queue_blocks: usize,
    ) -> Result<DiskWriter, WavError> {
        if queue_blocks == 0 {
            return Err(WavError::BadShape(
                "the disk queue needs room for at least one block",
            ));
        }
        let writer = WavWriter::create(path, rate, channels, period)?;
        let sync_frames = (u64::from(rate) / SYNC_HALF_SECONDS).max(1);

        // A bounded mpsc channel is the queue: `try_send` is the non-blocking
        // hand-off and `recv` is the writer's pull.
        let (sender, receiver) = mpsc::sync_channel::<Block>(queue_blocks);
        let handle = match thread::Builder::new()
            .name("jawn-audio-disk".to_string())
            .spawn(move || writer_thread(writer, receiver, sync_frames))
        {
            Ok(handle) => handle,
            Err(error) => {
                // No thread, no take: do not leave an empty WAV behind.
                let _ = fs::remove_file(path);
                return Err(WavError::Io(error));
            }
        };

        Ok(DiskWriter {
            sender,
            channels,
            dropped: 0,
            handle,
        })
    }

    /// Hand one block of interleaved i16 samples to the thread. Never blocks:
    /// if the queue is full the block is dropped and its frames counted.
    /// Returns the number of frames dropped from this block (0 = all accepted).
    ///
    /// A block that is not a whole number of frames is refused the same way —
    /// counted, not queued — so one malformed block cannot poison the take.
    ///
    /// Each push copies the block into an owned `Vec`: that copy is what lets
    /// ownership cross to the thread without a lock. A block the queue refuses
    /// has paid for its copy too, but it never waits.
    pub fn push(&mut self, samples: &[i16]) -> usize {
        let channels = usize::from(self.channels);
        if channels == 0 {
            // Unreachable: `spawn` refuses a zero-channel WAV. Divide only
            // after this guard so a bad shape cannot panic the audio thread.
            return 0;
        }
        let frames = samples.len() / channels;
        if samples.len() % channels != 0 {
            self.dropped += frames as u64;
            return frames;
        }
        match self.sender.try_send(samples.to_vec()) {
            Ok(()) => 0,
            Err(_) => {
                // Full queue (or the writer is already gone). Either way the
                // block did not reach the file; report it as dropped frames.
                self.dropped += frames as u64;
                frames
            }
        }
    }

    /// Frames dropped since the writer started because the queue was full.
    ///
    /// Read it before [`DiskWriter::finish`], which consumes the handle.
    pub fn dropped_frames(&self) -> u64 {
        self.dropped
    }

    /// Close the queue, join the thread, finish the WAV and return the frames
    /// written.
    ///
    /// Safe after any number of drops: the frames written plus
    /// [`DiskWriter::dropped_frames`] account for every frame pushed. The
    /// header is always synced before the file is closed.
    pub fn finish(self) -> Result<u64, WavError> {
        let DiskWriter { sender, handle, .. } = self;
        // Dropping the sender closes the channel, which ends the thread's loop
        // and lets it finish the WAV.
        drop(sender);
        match handle.join() {
            Ok(result) => result,
            Err(_) => Err(WavError::Io(io::Error::new(
                io::ErrorKind::Other,
                "the disk writer thread panicked",
            ))),
        }
    }
}

/// The writer thread: drain the queue, write with the header sync deferred to
/// a cadence, and finish the WAV when the sender is closed.
fn writer_thread(
    mut writer: WavWriter,
    receiver: Receiver<Block>,
    sync_frames: u64,
) -> Result<u64, WavError> {
    let channels = usize::from(writer.channels());
    let mut since_sync = 0u64;
    while let Ok(block) = receiver.recv() {
        if let Err(error) = writer.write_i16_unsynced(&block) {
            // Best effort: keep the header honest about what did reach disk,
            // then report the failure to `finish`.
            let _ = writer.sync();
            return Err(error);
        }
        since_sync += (block.len() / channels) as u64;
        if since_sync >= sync_frames {
            writer.sync()?;
            since_sync = 0;
        }
    }
    writer.finish()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::mpsc::channel;

    /// A path under the system temp directory, removed however the test ends.
    struct TempWav {
        path: PathBuf,
    }

    impl TempWav {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "jawn-audio-disk-{}-{name}.wav",
                std::process::id()
            ));
            let _ = fs::remove_file(&path);
            TempWav { path }
        }
    }

    impl Drop for TempWav {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.path);
        }
    }

    fn u32_at(bytes: &[u8], offset: usize) -> u32 {
        u32::from_le_bytes([
            bytes[offset],
            bytes[offset + 1],
            bytes[offset + 2],
            bytes[offset + 3],
        ])
    }

    /// The deterministic drop test: a consumer held at the gate cannot drain
    /// the queue, so the second push must find it full. No timing involved.
    #[test]
    fn a_full_queue_drops_the_block_and_counts_its_frames() {
        let temp = TempWav::new("full-queue");
        let writer = WavWriter::create(&temp.path, 48_000, 2, 4).expect("create");
        let (sender, receiver) = mpsc::sync_channel::<Block>(1);
        let (gate_tx, gate_rx) = channel::<()>();
        let handle = thread::spawn(move || {
            gate_rx.recv().expect("gate");
            writer_thread(writer, receiver, 1_000_000)
        });
        let mut disk = DiskWriter {
            sender,
            channels: 2,
            dropped: 0,
            handle,
        };

        assert_eq!(disk.push(&[1, 2, 3, 4]), 0, "one block queued");
        // The writer is still at the gate, so the queue of one is full.
        assert_eq!(disk.push(&[5, 6, 7, 8]), 2, "two frames dropped");
        assert_eq!(disk.dropped_frames(), 2);

        gate_tx.send(()).expect("open gate");
        drop(gate_tx);
        let frames = disk.finish().expect("finish");
        assert_eq!(frames, 2, "only the accepted block was written");

        let bytes = fs::read(&temp.path).expect("read");
        assert_eq!(u32_at(&bytes, 40), 2 * 2 * 2, "header covers one block");
        assert_eq!(bytes.len(), crate::wav::HEADER_LEN + 8);
    }

    #[test]
    fn a_block_that_is_not_whole_frames_is_refused_and_counted() {
        let temp = TempWav::new("malformed");
        let mut disk = DiskWriter::spawn(&temp.path, 48_000, 2, 4, 4).expect("spawn");
        assert_eq!(disk.push(&[1, 2, 3]), 1, "one whole frame exists");
        assert_eq!(disk.dropped_frames(), 1);
        assert_eq!(disk.finish().expect("finish"), 0);
    }
}
