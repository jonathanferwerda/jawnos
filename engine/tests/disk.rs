//! The take reaches disk through a writer thread, so the tests read the file
//! the way a person's player will: header, sizes, then samples in order.

use std::fs;
use std::path::{Path, PathBuf};

use jawn_audio::disk::DiskWriter;
use jawn_audio::wav::{WavError, HEADER_LEN};

const RATE: u32 = 48_000;
const CHANNELS: u16 = 2;

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

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TempWav {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn u16_at(bytes: &[u8], offset: usize) -> u16 {
    u16::from_le_bytes([bytes[offset], bytes[offset + 1]])
}

fn u32_at(bytes: &[u8], offset: usize) -> u32 {
    u32::from_le_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

/// The samples for one block, distinct per block so an out-of-order write is
/// visible rather than merely suspected.
fn block(samples: usize, index: i16) -> Vec<i16> {
    (0..samples)
        .map(|offset| index.wrapping_mul(1_000).wrapping_add(offset as i16))
        .collect()
}

#[test]
fn every_block_reaches_the_file_in_order_with_an_honest_header() {
    let temp = TempWav::new("in-order");
    let period = 8usize;
    let blocks = 20i16;
    // Room for every block, so the queue itself cannot drop one here.
    let mut disk =
        DiskWriter::spawn(temp.path(), RATE, CHANNELS, period, blocks as usize).expect("spawn");
    for index in 0..blocks {
        assert_eq!(disk.push(&block(period * 2, index)), 0, "block {index}");
    }
    assert_eq!(disk.dropped_frames(), 0);
    let frames = disk.finish().expect("finish");
    assert_eq!(frames, u64::from(blocks as u32) * period as u64);

    let bytes = fs::read(temp.path()).expect("read");
    assert_eq!(&bytes[0..4], b"RIFF");
    assert_eq!(u32_at(&bytes, 4) as usize, bytes.len() - 8, "RIFF size");
    assert_eq!(&bytes[8..12], b"WAVE");
    assert_eq!(&bytes[12..16], b"fmt ");
    assert_eq!(u16_at(&bytes, 22), CHANNELS, "channels");
    assert_eq!(u32_at(&bytes, 24), RATE, "rate");
    assert_eq!(u16_at(&bytes, 32), 4, "block align");
    assert_eq!(u16_at(&bytes, 34), 16, "bits per sample");
    assert_eq!(&bytes[36..40], b"data");

    let expected_bytes = frames as usize * usize::from(CHANNELS) * 2;
    assert_eq!(u32_at(&bytes, 40) as usize, expected_bytes, "data size");
    assert_eq!(bytes.len(), HEADER_LEN + expected_bytes);

    let samples: Vec<i16> = bytes[HEADER_LEN..]
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    for index in 0..blocks {
        let expected = block(period * 2, index);
        let start = index as usize * period * 2;
        assert_eq!(
            &samples[start..start + expected.len()],
            &expected[..],
            "block {index} is out of order or altered"
        );
    }
}

#[test]
fn a_short_final_block_is_written_exactly_not_padded() {
    let temp = TempWav::new("short-final");
    let period = 8usize;
    let mut disk = DiskWriter::spawn(temp.path(), RATE, CHANNELS, period, 4).expect("spawn");
    disk.push(&block(period * 2, 0));
    disk.push(&block(period * 2, 1));
    // Three frames, six samples: the take ends mid-period.
    let tail = block(3 * 2, 2);
    assert_eq!(disk.push(&tail), 0);

    let frames = disk.finish().expect("finish");
    assert_eq!(frames, (2 * period + 3) as u64);

    let bytes = fs::read(temp.path()).expect("read");
    let expected_bytes = frames as usize * usize::from(CHANNELS) * 2;
    assert_eq!(u32_at(&bytes, 40) as usize, expected_bytes);
    assert_eq!(bytes.len(), HEADER_LEN + expected_bytes);
    let last: Vec<i16> = bytes[bytes.len() - tail.len() * 2..]
        .chunks_exact(2)
        .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
        .collect();
    assert_eq!(last, tail, "the short block was padded or truncated");
}

#[test]
fn a_small_queue_drops_blocks_but_the_file_still_accounts_for_every_frame() {
    let temp = TempWav::new("small-queue");
    let period = 8usize;
    let blocks = 200usize;
    // One waiting block: the audio side is deliberately given almost no room,
    // so many pushes must be dropped rather than block.
    let mut disk = DiskWriter::spawn(temp.path(), RATE, CHANNELS, period, 1).expect("spawn");
    let pushed = (blocks * period) as u64;
    for index in 0..blocks {
        disk.push(&block(period * 2, index as i16));
    }
    let dropped = disk.dropped_frames();
    assert!(dropped <= pushed, "cannot drop more than was pushed");

    let frames = disk.finish().expect("finish");
    assert_eq!(
        frames + dropped,
        pushed,
        "every frame is either on disk or reported dropped"
    );

    let bytes = fs::read(temp.path()).expect("read");
    let data_bytes = u32_at(&bytes, 40) as usize;
    assert_eq!(data_bytes as u64, frames * u64::from(CHANNELS) * 2);
    assert_eq!(bytes.len(), HEADER_LEN + data_bytes);
    assert_eq!(
        u32_at(&bytes, 4) as usize,
        bytes.len() - 8,
        "the header matches the file after a run with drops"
    );
}

#[test]
fn a_path_in_a_missing_directory_is_an_error_not_a_panic() {
    let dir = std::env::temp_dir().join(format!(
        "jawn-audio-disk-no-such-dir-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    let path = dir.join("take.wav");
    let error = DiskWriter::spawn(&path, RATE, CHANNELS, 64, 4).err().expect("no directory");
    assert!(matches!(error, WavError::Io(_)), "{error:?}");
}

#[test]
fn a_path_that_is_a_directory_is_an_error_not_a_panic() {
    let dir = std::env::temp_dir().join(format!(
        "jawn-audio-disk-is-a-dir-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("mkdir");
    let error = DiskWriter::spawn(&dir, RATE, CHANNELS, 64, 4).err().expect("path is a directory");
    let _ = fs::remove_dir_all(&dir);
    assert!(matches!(error, WavError::Io(_)), "{error:?}");
}

#[test]
fn a_queue_with_no_room_is_refused_before_the_file_is_created() {
    let temp = TempWav::new("zero-queue");
    let error = DiskWriter::spawn(temp.path(), RATE, CHANNELS, 64, 0).err().expect("zero queue");
    assert!(matches!(error, WavError::BadShape(_)), "{error:?}");
    assert!(!temp.path().exists(), "a refused spawn must not leave a file");
}
