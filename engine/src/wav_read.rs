//! Reading a take back: 16-bit PCM WAV, mono or stereo.
//!
//! Playback only has to understand what the engine records, so this reader is
//! deliberately narrow: an uncompressed 16-bit PCM `RIFF/WAVE` file with one or
//! two channels. Every other shape is refused with a sentence that names the
//! file and what was found, because a 24-bit take or a float file played as if
//! it were 16-bit is loud noise, not a degraded take.
//!
//! The whole file is read into memory. A take is a handful of minutes of
//! stereo, which is what makes the timeline simple; [`WavAudio::frames`] and
//! the interleaved `samples` are all a mixer needs. The sizes in the header are
//! what the reader trusts, so a file cut short is a clean [`WavReadError`],
//! never a slice past the end.

use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// The only sample width this engine records and plays.
pub const BITS_PER_SAMPLE: u16 = 16;
/// WAVE format tag 1: uncompressed PCM.
pub const FORMAT_PCM: u16 = 1;

/// One decoded WAV: its shape and its interleaved samples.
#[derive(Debug, Clone, PartialEq)]
pub struct WavAudio {
    pub rate: u32,
    /// 1 (mono) or 2 (stereo): the reader refuses anything else.
    pub channels: u16,
    pub frames: u64,
    /// `frames * channels` interleaved samples, exactly as the file held them.
    pub samples: Vec<i16>,
}

impl WavAudio {
    /// The file as one mono timeline, for a channel strip.
    ///
    /// A stereo take is the strip's panned output, so summing the pair is what
    /// restores the strip's input level: a centred source recorded at gain `g`
    /// is `g/√2` in each channel, and `g/√2 + g/√2 = √2·g` is exactly what the
    /// pan scales back down to `g`. Averaging instead would lose 6 dB on every
    /// round trip.
    pub fn mono(&self) -> Vec<f32> {
        match self.channels {
            1 => self
                .samples
                .iter()
                .map(|sample| f32::from(*sample) / 32_768.0)
                .collect(),
            _ => self
                .samples
                .chunks_exact(2)
                .map(|pair| (f32::from(pair[0]) + f32::from(pair[1])) / 32_768.0)
                .collect(),
        }
    }
}

#[derive(Debug)]
pub enum WavReadError {
    /// The file could not be opened or read.
    Io { path: PathBuf, error: io::Error },
    /// It is not a WAV this engine can play: wrong container, width, format or
    /// channel count.
    Refused { path: PathBuf, reason: String },
    /// The header promises bytes that are not in the file.
    Truncated { path: PathBuf, reason: String },
}

impl fmt::Display for WavReadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            WavReadError::Io { path, error } => {
                write!(f, "cannot read {}: {error}", path.display())
            }
            WavReadError::Refused { path, reason } => {
                write!(f, "{} cannot be played: {reason}", path.display())
            }
            WavReadError::Truncated { path, reason } => {
                write!(f, "{} is truncated: {reason}", path.display())
            }
        }
    }
}

impl std::error::Error for WavReadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            WavReadError::Io { error, .. } => Some(error),
            _ => None,
        }
    }
}

/// Read `path` as an uncompressed 16-bit PCM WAV with one or two channels.
pub fn read_wav(path: impl AsRef<Path>) -> Result<WavAudio, WavReadError> {
    let path = path.as_ref();
    let bytes = fs::read(path).map_err(|error| WavReadError::Io {
        path: path.to_path_buf(),
        error,
    })?;
    parse(&bytes, path)
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

/// What the `fmt ` chunk said, once it is known to be playable.
struct Format {
    channels: u16,
    rate: u32,
    block_align: usize,
}

fn parse(bytes: &[u8], path: &Path) -> Result<WavAudio, WavReadError> {
    let refused = |reason: String| WavReadError::Refused {
        path: path.to_path_buf(),
        reason,
    };
    let truncated = |reason: String| WavReadError::Truncated {
        path: path.to_path_buf(),
        reason,
    };

    if bytes.len() < 12 {
        return Err(truncated(format!(
            "it is {} bytes, too short for a RIFF header",
            bytes.len()
        )));
    }
    if &bytes[0..4] != b"RIFF" || &bytes[8..12] != b"WAVE" {
        let found = String::from_utf8_lossy(&bytes[0..4]);
        return Err(refused(format!(
            "it starts with `{found}` and {} rather than RIFF/WAVE",
            String::from_utf8_lossy(&bytes[8..12])
        )));
    }

    // Walk the chunks rather than assuming the writer's fixed 44-byte layout:
    // a file that carries a `LIST` or `fact` chunk before `data` is still a
    // WAV, and the offsets have to follow the sizes in the file.
    let mut offset = 12usize;
    let mut format: Option<Format> = None;
    let mut data: Option<(usize, usize)> = None;
    while offset + 8 <= bytes.len() {
        let id = &bytes[offset..offset + 4];
        let size = u32_at(bytes, offset + 4) as usize;
        let body = offset + 8;
        let end = body.checked_add(size).ok_or_else(|| {
            truncated(format!(
                "its `{}` chunk length does not fit this file",
                String::from_utf8_lossy(id)
            ))
        })?;
        if end > bytes.len() {
            return Err(truncated(format!(
                "its `{}` chunk ends {} bytes past the end of the file",
                String::from_utf8_lossy(id),
                end - bytes.len()
            )));
        }

        if id == b"fmt " && format.is_none() {
            format = Some(parse_format(bytes, body, size, &refused)?);
        } else if id == b"data" && data.is_none() {
            data = Some((body, size));
        }
        // Chunks are word-aligned: an odd body is followed by one pad byte.
        offset = end + (size & 1);
    }

    let format = format.ok_or_else(|| refused("it has no `fmt ` chunk".to_string()))?;
    let (start, size) = data.ok_or_else(|| refused("it has no `data` chunk".to_string()))?;
    if size % format.block_align != 0 {
        return Err(refused(format!(
            "its `data` chunk is {size} bytes, not a whole number of {}-byte frames",
            format.block_align
        )));
    }

    let frames = (size / format.block_align) as u64;
    let mut samples = Vec::with_capacity(size / 2);
    for pair in bytes[start..start + size].chunks_exact(2) {
        samples.push(i16::from_le_bytes([pair[0], pair[1]]));
    }
    Ok(WavAudio {
        rate: format.rate,
        channels: format.channels,
        frames,
        samples,
    })
}

fn parse_format(
    bytes: &[u8],
    body: usize,
    size: usize,
    refused: &impl Fn(String) -> WavReadError,
) -> Result<Format, WavReadError> {
    if size < 16 {
        return Err(refused(format!(
            "its `fmt ` chunk is {size} bytes, smaller than the 16-byte PCM header"
        )));
    }
    let tag = u16_at(bytes, body);
    let channels = u16_at(bytes, body + 2);
    let rate = u32_at(bytes, body + 4);
    let block_align = u16_at(bytes, body + 12) as usize;
    let bits = u16_at(bytes, body + 14);

    if tag != FORMAT_PCM {
        // Name the common compressed/float tags a caller is likely to have
        // produced, so the sentence says what was found rather than a number.
        let name = match tag {
            3 => "IEEE float".to_string(),
            6 => "A-law".to_string(),
            7 => "µ-law".to_string(),
            0xFFFE => "WAVE_FORMAT_EXTENSIBLE".to_string(),
            other => format!("format {other}"),
        };
        return Err(refused(format!(
            "it uses {name}, not uncompressed 16-bit PCM"
        )));
    }
    if bits != BITS_PER_SAMPLE {
        return Err(refused(format!(
            "it is {bits}-bit PCM; only 16-bit PCM can be played"
        )));
    }
    if channels != 1 && channels != 2 {
        return Err(refused(format!(
            "it has {channels} channels; only mono or stereo can be played"
        )));
    }
    if rate == 0 {
        return Err(refused("its sample rate is 0 Hz".to_string()));
    }
    let expected = usize::from(channels) * 2;
    if block_align != expected {
        return Err(refused(format!(
            "its frame size is {block_align} bytes, but {channels} channel(s) of 16-bit samples need {expected}"
        )));
    }
    Ok(Format {
        channels,
        rate,
        block_align,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wav::WavWriter;
    use std::fs;
    use std::path::PathBuf;

    /// A path under the system temp directory, removed however the test ends.
    struct TempWav {
        path: PathBuf,
    }

    impl TempWav {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "jawn-audio-wav-read-{}-{name}.wav",
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

    #[test]
    fn a_written_take_reads_back_sample_for_sample() {
        let temp = TempWav::new("round-trip");
        let samples: Vec<i16> = vec![
            -32768, 32767, -1, 1, 0, 0, 12_345, -12_345, 100, -100, 7, -7,
        ];
        let mut writer = WavWriter::create(&temp.path, 48_000, 2, 8).expect("create");
        writer.write_i16(&samples).expect("write");
        writer.finish().expect("finish");

        let audio = read_wav(&temp.path).expect("read");
        assert_eq!(audio.rate, 48_000);
        assert_eq!(audio.channels, 2);
        assert_eq!(audio.frames, 6);
        assert_eq!(audio.samples, samples);
    }

    #[test]
    fn a_mono_file_reads_back_as_one_channel() {
        let temp = TempWav::new("mono");
        let samples: Vec<i16> = vec![-1000, 0, 1000, 2000];
        let mut writer = WavWriter::create(&temp.path, 44_100, 1, 4).expect("create");
        writer.write_i16(&samples).expect("write");
        writer.finish().expect("finish");

        let audio = read_wav(&temp.path).expect("read");
        assert_eq!(audio.rate, 44_100);
        assert_eq!(audio.channels, 1);
        assert_eq!(audio.frames, 4);
        assert_eq!(audio.samples, samples);
        let mono = audio.mono();
        assert_eq!(mono.len(), 4);
        assert!((mono[2] - 1000.0 / 32_768.0).abs() < 1e-9);
    }

    #[test]
    fn a_stereo_take_downmixes_to_the_sum_of_its_pair() {
        let audio = WavAudio {
            rate: 48_000,
            channels: 2,
            frames: 2,
            samples: vec![1000, 3000, -1000, -3000],
        };
        let mono = audio.mono();
        assert_eq!(mono.len(), 2);
        assert!((mono[0] - 4000.0 / 32_768.0).abs() < 1e-9, "{mono:?}");
        assert!((mono[1] + 4000.0 / 32_768.0).abs() < 1e-9, "{mono:?}");
    }

    #[test]
    fn a_truncated_take_is_a_clean_error() {
        let temp = TempWav::new("truncated");
        let samples: Vec<i16> = (0..100).collect();
        let mut writer = WavWriter::create(&temp.path, 48_000, 2, 8).expect("create");
        writer.write_i16(&samples).expect("write");
        writer.finish().expect("finish");

        let bytes = fs::read(&temp.path).expect("read the take");
        // Cut the last ten bytes off, leaving a header that still promises
        // every frame: the reader must notice rather than index past the end.
        fs::write(&temp.path, &bytes[..bytes.len() - 10]).expect("truncate");
        let error = read_wav(&temp.path).expect_err("a truncated take must be refused");
        let message = error.to_string();
        assert!(message.contains("truncated"), "{message}");
        assert!(
            message.contains(temp.path.to_str().expect("UTF-8 path")),
            "the sentence names the file: {message}"
        );
    }

    #[test]
    fn a_24_bit_header_is_refused_and_says_so() {
        let temp = TempWav::new("24-bit");
        let mut writer = WavWriter::create(&temp.path, 48_000, 2, 4).expect("create");
        writer.write_i16(&[0, 0, 0, 0]).expect("write");
        writer.finish().expect("finish");

        // Rewrite the fmt chunk as 24-bit: bits per sample at offset 34, frame
        // size at offset 32. The data is still 16-bit on purpose.
        let mut bytes = fs::read(&temp.path).expect("read the take");
        bytes[34..36].copy_from_slice(&24u16.to_le_bytes());
        bytes[32..34].copy_from_slice(&6u16.to_le_bytes());
        fs::write(&temp.path, &bytes).expect("rewrite the header");

        let error = read_wav(&temp.path).expect_err("24-bit must be refused");
        let message = error.to_string();
        assert!(message.contains("24-bit"), "{message}");
        assert!(
            message.contains(temp.path.to_str().expect("UTF-8 path")),
            "the sentence names the file: {message}"
        );
    }

    #[test]
    fn a_float_header_is_refused_and_names_the_format() {
        let temp = TempWav::new("float");
        let mut writer = WavWriter::create(&temp.path, 48_000, 2, 4).expect("create");
        writer.write_i16(&[0, 0, 0, 0]).expect("write");
        writer.finish().expect("finish");

        let mut bytes = fs::read(&temp.path).expect("read the take");
        bytes[20..22].copy_from_slice(&3u16.to_le_bytes());
        fs::write(&temp.path, &bytes).expect("rewrite the header");

        let error = read_wav(&temp.path).expect_err("float must be refused");
        let message = error.to_string();
        assert!(message.contains("IEEE float"), "{message}");
    }

    #[test]
    fn a_file_that_is_not_a_wav_is_refused_by_name() {
        let temp = TempWav::new("not-a-wav");
        fs::write(&temp.path, b"this is not audio").expect("write");
        let error = read_wav(&temp.path).expect_err("not a WAV");
        let message = error.to_string();
        assert!(message.contains("cannot be played"), "{message}");
        assert!(message.contains("RIFF"), "{message}");
    }
}
