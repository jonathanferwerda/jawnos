//! A take on disk: 16-bit PCM WAV, written by hand.
//!
//! The engine records the format its interface speaks (48 kHz, stereo, 16-bit)
//! and nothing else, so the file layout is fixed and small enough to own rather
//! than pull in a crate. The writer's file handle stays here, which lets it keep
//! the RIFF and `data` sizes honest after every block: a take that is interrupted
//! is still a valid WAV of the frames that reached the disk, never a header that
//! promises samples that are not there (docs/studio-audio-roadmap.md §7, P2).
//!
//! The audio loop must not allocate, so the conversion scratch buffer is
//! allocated once by [`WavWriter::create`] and reused for every block.

use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Seek, SeekFrom, Write};
use std::path::Path;

/// `RIFF` (12) + `fmt ` (24) + `data` (8): the header every PCM16 WAV starts
/// with. Samples begin at this byte offset.
pub const HEADER_LEN: usize = 44;
/// The one sample format the interface and this writer agree on.
pub const BITS_PER_SAMPLE: u16 = 16;
/// WAVE format tag 1: uncompressed PCM.
pub const FORMAT_PCM: u16 = 1;

#[derive(Debug)]
pub enum WavError {
    /// The file could not be created, written, seeked or flushed.
    Io(io::Error),
    /// The requested shape cannot be expressed in a WAV header.
    BadShape(&'static str),
    /// A block was not a whole number of interleaved frames.
    BadBlock { channels: usize, found: usize },
    /// The take outgrew the 32-bit RIFF/data sizes (4 GiB of samples).
    TooLong { frames: u64 },
}

impl fmt::Display for WavError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WavError::Io(error) => write!(f, "{error}"),
            WavError::BadShape(reason) => f.write_str(reason),
            WavError::BadBlock { channels, found } => write!(
                f,
                "a block of {found} samples is not a whole number of {channels}-channel frames"
            ),
            WavError::TooLong { frames } => write!(
                f,
                "{frames} frames is more than a WAV's 4 GiB data chunk"
            ),
        }
    }
}

impl std::error::Error for WavError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            WavError::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for WavError {
    fn from(error: io::Error) -> Self {
        WavError::Io(error)
    }
}

/// Quantise one `f32` sample to 16-bit PCM, clamping out-of-range input.
///
/// `-1.0` maps to `-32767` rather than `i16::MIN`: `-32768` has no positive
/// counterpart, and the asymmetry would put a one-LSB DC offset in every take.
pub fn to_i16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
}

/// The 44-byte header for a take of `data_len` bytes.
fn header_bytes(rate: u32, channels: u16, data_len: u32) -> Result<[u8; HEADER_LEN], WavError> {
    if rate == 0 {
        return Err(WavError::BadShape("a WAV needs a non-zero sample rate"));
    }
    if channels == 0 {
        return Err(WavError::BadShape("a WAV needs at least one channel"));
    }
    let block_align = channels
        .checked_mul(BITS_PER_SAMPLE / 8)
        .ok_or(WavError::BadShape("the channel count is too large for a WAV"))?;
    let byte_rate = (rate as u64)
        .checked_mul(block_align as u64)
        .filter(|value| *value <= u32::MAX as u64)
        .ok_or(WavError::BadShape("the byte rate does not fit a WAV header"))?;
    let riff_size = 36u32
        .checked_add(data_len)
        .ok_or(WavError::TooLong {
            frames: u64::from(data_len) / u64::from(block_align),
        })?;

    let mut out = [0u8; HEADER_LEN];
    out[0..4].copy_from_slice(b"RIFF");
    out[4..8].copy_from_slice(&riff_size.to_le_bytes());
    out[8..12].copy_from_slice(b"WAVE");
    out[12..16].copy_from_slice(b"fmt ");
    out[16..20].copy_from_slice(&16u32.to_le_bytes());
    out[20..22].copy_from_slice(&FORMAT_PCM.to_le_bytes());
    out[22..24].copy_from_slice(&channels.to_le_bytes());
    out[24..28].copy_from_slice(&rate.to_le_bytes());
    out[28..32].copy_from_slice(&(byte_rate as u32).to_le_bytes());
    out[32..34].copy_from_slice(&block_align.to_le_bytes());
    out[34..36].copy_from_slice(&BITS_PER_SAMPLE.to_le_bytes());
    out[36..40].copy_from_slice(b"data");
    out[40..44].copy_from_slice(&data_len.to_le_bytes());
    Ok(out)
}

/// One open WAV take. Samples are streamed as they arrive; the sizes in the
/// header are rewritten after every block.
pub struct WavWriter {
    file: File,
    rate: u32,
    channels: u16,
    frames: u64,
    scratch: Vec<u8>,
}

impl WavWriter {
    /// Create `path` and write a valid, empty WAV header.
    ///
    /// `block_frames` sizes the conversion scratch buffer, so a writer created
    /// for the engine's period never allocates again while recording. A larger
    /// block is written in scratch-sized chunks, not by growing the buffer.
    pub fn create(
        path: impl AsRef<Path>,
        rate: u32,
        channels: u16,
        block_frames: usize,
    ) -> Result<Self, WavError> {
        let path = path.as_ref();
        let scratch_len = block_frames
            .checked_mul(usize::from(channels))
            .and_then(|samples| samples.checked_mul(usize::from(BITS_PER_SAMPLE / 8)))
            .filter(|len| *len > 0)
            .ok_or(WavError::BadShape("the block size is too large for a WAV writer"))?;
        let header = header_bytes(rate, channels, 0)?;

        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(path)?;
        if let Err(error) = file.write_all(&header) {
            // A file we cannot even header is not a take; do not leave an
            // empty file that could be mistaken for one.
            drop(file);
            let _ = fs::remove_file(path);
            return Err(WavError::Io(error));
        }

        Ok(WavWriter {
            file,
            rate,
            channels,
            frames: 0,
            scratch: vec![0u8; scratch_len],
        })
    }

    pub fn rate(&self) -> u32 {
        self.rate
    }

    pub fn channels(&self) -> u16 {
        self.channels
    }

    /// Frames actually written and reflected in the header.
    pub fn frames(&self) -> u64 {
        self.frames
    }

    /// Correct the header's rate after a backend negotiated a different one
    /// than it was asked for. The samples are already at the granted rate, so
    /// the header must follow them; the sizes are left alone.
    pub fn set_rate(&mut self, rate: u32) -> Result<(), WavError> {
        if rate == 0 {
            return Err(WavError::BadShape("a WAV needs a non-zero sample rate"));
        }
        let block_align = u32::from(self.channels) * u32::from(BITS_PER_SAMPLE / 8);
        let byte_rate = (rate as u64)
            .checked_mul(u64::from(block_align))
            .filter(|value| *value <= u32::MAX as u64)
            .ok_or(WavError::BadShape("the byte rate does not fit a WAV header"))?;
        self.rate = rate;
        self.file.seek(SeekFrom::Start(24))?;
        self.file.write_all(&rate.to_le_bytes())?;
        self.file.seek(SeekFrom::Start(28))?;
        self.file.write_all(&(byte_rate as u32).to_le_bytes())?;
        let data_len = self.data_len()?;
        self.file.seek(SeekFrom::Start(
            HEADER_LEN as u64 + u64::from(data_len),
        ))?;
        Ok(())
    }

    /// Append interleaved `f32` samples, quantising each to 16-bit.
    pub fn write_f32(&mut self, block: &[f32]) -> Result<(), WavError> {
        let channels = usize::from(self.channels);
        if block.len() % channels != 0 {
            return Err(WavError::BadBlock {
                channels,
                found: block.len(),
            });
        }

        let samples_per_chunk = self.scratch.len() / 2;
        let mut done = 0usize;
        while done < block.len() {
            let take = (block.len() - done).min(samples_per_chunk);
            for (index, sample) in block[done..done + take].iter().enumerate() {
                let bytes = to_i16(*sample).to_le_bytes();
                self.scratch[index * 2] = bytes[0];
                self.scratch[index * 2 + 1] = bytes[1];
            }
            self.write_scratch(take)?;
            done += take;
        }
        Ok(())
    }

    /// Append interleaved 16-bit samples exactly as a capture backend produced
    /// them, so a hardware take is not quantised twice.
    pub fn write_i16(&mut self, block: &[i16]) -> Result<(), WavError> {
        let channels = usize::from(self.channels);
        if block.len() % channels != 0 {
            return Err(WavError::BadBlock {
                channels,
                found: block.len(),
            });
        }

        let samples_per_chunk = self.scratch.len() / 2;
        let mut done = 0usize;
        while done < block.len() {
            let take = (block.len() - done).min(samples_per_chunk);
            for (index, sample) in block[done..done + take].iter().enumerate() {
                let bytes = sample.to_le_bytes();
                self.scratch[index * 2] = bytes[0];
                self.scratch[index * 2 + 1] = bytes[1];
            }
            self.write_scratch(take)?;
            done += take;
        }
        Ok(())
    }

    fn write_scratch(&mut self, samples: usize) -> Result<(), WavError> {
        self.file.write_all(&self.scratch[..samples * 2])?;
        self.frames += (samples / usize::from(self.channels)) as u64;
        self.sync_sizes()
    }

    fn data_len(&self) -> Result<u32, WavError> {
        let bytes = self
            .frames
            .checked_mul(u64::from(self.channels))
            .and_then(|samples| samples.checked_mul(u64::from(BITS_PER_SAMPLE / 8)))
            .ok_or(WavError::TooLong {
                frames: self.frames,
            })?;
        if bytes > u64::from(u32::MAX - 36) {
            return Err(WavError::TooLong {
                frames: self.frames,
            });
        }
        Ok(bytes as u32)
    }

    /// Rewrite the two 32-bit sizes for the frames that are actually on disk,
    /// then leave the cursor at the end of the samples.
    fn sync_sizes(&mut self) -> Result<(), WavError> {
        let data_len = self.data_len()?;
        let riff_size = 36u32
            .checked_add(data_len)
            .ok_or(WavError::TooLong {
                frames: self.frames,
            })?;
        self.file.seek(SeekFrom::Start(4))?;
        self.file.write_all(&riff_size.to_le_bytes())?;
        self.file.seek(SeekFrom::Start(40))?;
        self.file.write_all(&data_len.to_le_bytes())?;
        self.file.seek(SeekFrom::Start(
            HEADER_LEN as u64 + u64::from(data_len),
        ))?;
        Ok(())
    }

    /// Flush the header and the samples, and return the frame count.
    pub fn finish(mut self) -> Result<u64, WavError> {
        self.sync_sizes()?;
        self.file.flush()?;
        self.file.sync_all()?;
        Ok(self.frames)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    /// A path under the system temp directory, removed however the test ends.
    struct TempWav {
        path: PathBuf,
    }

    impl TempWav {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "jawn-audio-wav-{}-{name}.wav",
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

    #[test]
    fn the_header_is_riff_wave_fmt_data_with_every_size_in_place() {
        let temp = TempWav::new("layout");
        let mut writer = WavWriter::create(&temp.path, 48_000, 2, 4).expect("create");
        writer.write_f32(&[0.0, 0.0, 0.25, -0.25]).expect("write");
        assert_eq!(writer.finish().expect("finish"), 2);

        let bytes = fs::read(&temp.path).expect("read");
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(u32_at(&bytes, 4) as usize, bytes.len() - 8);
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(&bytes[12..16], b"fmt ");
        assert_eq!(u32_at(&bytes, 16), 16, "fmt chunk is 16 bytes");
        assert_eq!(u16_at(&bytes, 20), FORMAT_PCM);
        assert_eq!(u16_at(&bytes, 22), 2, "channels");
        assert_eq!(u32_at(&bytes, 24), 48_000, "rate");
        assert_eq!(u32_at(&bytes, 28), 48_000 * 2 * 2, "byte rate");
        assert_eq!(u16_at(&bytes, 32), 4, "block align");
        assert_eq!(u16_at(&bytes, 34), 16, "bits per sample");
        assert_eq!(&bytes[36..40], b"data");
        assert_eq!(u32_at(&bytes, 40) as usize, 2 * 2 * 2, "data length");
        assert_eq!(bytes.len(), HEADER_LEN + 8, "two stereo frames");
    }

    #[test]
    fn mono_and_stereo_change_the_align_and_byte_rate() {
        let mono = TempWav::new("mono");
        let stereo = TempWav::new("stereo");
        WavWriter::create(&mono.path, 8_000, 1, 4)
            .expect("mono create")
            .finish()
            .expect("mono finish");
        WavWriter::create(&stereo.path, 48_000, 2, 4)
            .expect("stereo create")
            .finish()
            .expect("stereo finish");

        let mono = fs::read(&mono.path).expect("read mono");
        let stereo = fs::read(&stereo.path).expect("read stereo");
        assert_eq!(u16_at(&mono, 22), 1);
        assert_eq!(u16_at(&mono, 32), 2);
        assert_eq!(u32_at(&mono, 28), 8_000 * 2);
        assert_eq!(u32_at(&mono, 40), 0);
        assert_eq!(u32_at(&mono, 4), 36);
        assert_eq!(u16_at(&stereo, 22), 2);
        assert_eq!(u16_at(&stereo, 32), 4);
        assert_eq!(u32_at(&stereo, 28), 48_000 * 4);
        assert_eq!(stereo.len(), HEADER_LEN);
    }

    #[test]
    fn sixteen_bit_samples_round_trip() {
        let temp = TempWav::new("round-trip");
        let samples = [-1.0f32, -0.5, 0.0, 0.5, 1.0];
        let mut writer = WavWriter::create(&temp.path, 48_000, 1, 8).expect("create");
        writer.write_f32(&samples).expect("write");
        writer.finish().expect("finish");

        let bytes = fs::read(&temp.path).expect("read");
        let data = &bytes[HEADER_LEN..];
        assert_eq!(data.len(), samples.len() * 2);
        for (index, expected) in samples.iter().enumerate() {
            let written = i16::from_le_bytes([data[index * 2], data[index * 2 + 1]]);
            assert_eq!(written, to_i16(*expected), "sample {index}");
        }
        assert_eq!(to_i16(2.0), i16::MAX, "clamped above full scale");
        assert_eq!(to_i16(-2.0), -i16::MAX, "clamped below full scale");
    }

    #[test]
    fn a_short_take_still_has_the_sizes_of_what_was_written() {
        let temp = TempWav::new("short");
        {
            let mut writer = WavWriter::create(&temp.path, 48_000, 2, 64).expect("create");
            // One planned block of 64 frames, but only three reached the disk:
            // the interruption case, where the header must stay truthful.
            writer
                .write_i16(&[1, -1, 2, -2, 3, -3])
                .expect("partial block");
        }

        let bytes = fs::read(&temp.path).expect("read");
        assert_eq!(u32_at(&bytes, 40), 3 * 2 * 2, "data length");
        assert_eq!(u32_at(&bytes, 4) as usize, bytes.len() - 8, "RIFF length");
        assert_eq!(bytes.len(), HEADER_LEN + 12);
    }

    #[test]
    fn a_negotiated_rate_rewrites_the_rate_and_byte_rate() {
        let temp = TempWav::new("rate-change");
        let mut writer = WavWriter::create(&temp.path, 48_000, 2, 4).expect("create");
        writer.write_i16(&[0, 0, 1, 1]).expect("write");
        writer.set_rate(44_100).expect("granted rate");
        assert_eq!(writer.finish().expect("finish"), 2);

        let bytes = fs::read(&temp.path).expect("read");
        assert_eq!(u32_at(&bytes, 24), 44_100, "rate");
        assert_eq!(u32_at(&bytes, 28), 44_100 * 4, "byte rate");
        assert_eq!(u32_at(&bytes, 40), 8, "data length unchanged");
        assert_eq!(bytes.len(), HEADER_LEN + 8);
    }

    #[test]
    fn a_block_that_is_not_whole_frames_is_refused() {
        let temp = TempWav::new("bad-block");
        let mut writer = WavWriter::create(&temp.path, 48_000, 2, 4).expect("create");
        let error = writer.write_f32(&[0.0, 0.0, 0.0]).expect_err("half a frame");
        assert!(matches!(
            error,
            WavError::BadBlock {
                channels: 2,
                found: 3
            }
        ));
    }

    #[test]
    fn a_block_larger_than_the_scratch_is_written_in_chunks() {
        let temp = TempWav::new("chunked");
        let mut writer = WavWriter::create(&temp.path, 48_000, 2, 4).expect("create");
        // 12 frames through a writer created for 4: no growth, three chunks.
        let block: Vec<i16> = (0..24).map(|sample| sample as i16).collect();
        writer.write_i16(&block).expect("write");
        writer.finish().expect("finish");

        let bytes = fs::read(&temp.path).expect("read");
        assert_eq!(u32_at(&bytes, 40), 12 * 2 * 2);
        assert_eq!(bytes.len(), HEADER_LEN + 48);
    }
}
