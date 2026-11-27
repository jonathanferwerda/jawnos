//! The `jawn-asr` command line, the model files it expects, and its output.
//!
//! None of this needs the sherpa-onnx libraries, so it is compiled by the
//! default crate and its unit tests run in the ordinary offline suite. The
//! C ABI itself lives in [`crate::sherpa`], behind `feature = "sherpa"`
//! (docs/engine-asr.md).

use std::fs;
use std::path::{Path, PathBuf};

/// The sample rate every bundled streaming model uses. The C API resamples a
/// WAV that arrives at another rate, so a file is never refused for this.
pub const SAMPLE_RATE: i32 = 16_000;

/// Where the audio comes from. The file path is the one the Perl side calls;
/// stdin is the streaming start.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Input {
    Wav(PathBuf),
    PcmStdin,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AsrArgs {
    pub model_dir: PathBuf,
    pub input: Input,
    pub threads: i32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Command {
    /// `--help` asks for the usage text and nothing else.
    Help,
    Run(AsrArgs),
}

pub const USAGE: &str = "\
jawn-asr — streaming speech recognition through sherpa-onnx

  jawn-asr --model-dir DIR -f FILE.wav      recognise a 16-bit PCM WAV
  jawn-asr --model-dir DIR --pcm-stdin      recognise raw mono 16 kHz s16le
  jawn-asr --help                           this text

options:
  --model-dir DIR   an extracted sherpa-onnx streaming transducer model
  -f, --file FILE   read a mono or stereo 16-bit PCM WAV; it is downmixed
  --pcm-stdin       read raw little-endian i16 mono at 16 kHz from stdin
  --threads N       ONNX Runtime threads (default 1)

One JSON object is printed per line: {\"text\":\"…\",\"final\":true|false}.
The last line is final. Configuration errors go to stderr with exit status 2.
";

/// Parse the arguments after the program name.
pub fn parse_args<I, S>(args: I) -> Result<Command, String>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut args = args.into_iter().map(|arg| arg.as_ref().to_string());
    let mut model_dir: Option<PathBuf> = None;
    let mut wav: Option<PathBuf> = None;
    let mut pcm_stdin = false;
    let mut threads = 1i32;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--help" | "-h" => return Ok(Command::Help),
            "--model-dir" => {
                model_dir = Some(PathBuf::from(value(&mut args, "--model-dir")?));
            }
            "-f" | "--file" => {
                wav = Some(PathBuf::from(value(&mut args, "--file")?));
            }
            "--pcm-stdin" => pcm_stdin = true,
            "--threads" => {
                let text = value(&mut args, "--threads")?;
                threads = parse_threads(&text)?;
            }
            other => {
                if let Some(rest) = other.strip_prefix("--model-dir=") {
                    model_dir = Some(PathBuf::from(rest));
                } else if let Some(rest) = other.strip_prefix("--file=") {
                    wav = Some(PathBuf::from(rest));
                } else if let Some(rest) = other.strip_prefix("--threads=") {
                    threads = parse_threads(rest)?;
                } else {
                    return Err(format!("unknown argument `{other}` (try --help)"));
                }
            }
        }
    }

    let model_dir = model_dir.ok_or_else(|| "--model-dir DIR is required (try --help)")?;
    let input = match (wav, pcm_stdin) {
        (Some(_), true) => {
            return Err("choose one input: -f FILE or --pcm-stdin, not both".to_string())
        }
        (Some(path), false) => Input::Wav(path),
        (None, true) => Input::PcmStdin,
        (None, false) => {
            return Err("an input is required: -f FILE or --pcm-stdin (try --help)".to_string())
        }
    };

    Ok(Command::Run(AsrArgs {
        model_dir,
        input,
        threads,
    }))
}

fn value<I: Iterator<Item = String>>(args: &mut I, flag: &str) -> Result<String, String> {
    args.next()
        .ok_or_else(|| format!("{flag} wants a value (try --help)"))
}

fn parse_threads(text: &str) -> Result<i32, String> {
    let threads: i32 = text
        .parse()
        .map_err(|_| format!("--threads wants a positive number, got `{text}`"))?;
    if threads < 1 {
        return Err(format!("--threads wants a positive number, got `{text}`"));
    }
    Ok(threads)
}

/// The four files a streaming transducer model directory must contain.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelFiles {
    pub encoder: PathBuf,
    pub decoder: PathBuf,
    pub joiner: PathBuf,
    pub tokens: PathBuf,
}

/// Find the model files in `dir`.
///
/// Names follow the sherpa-onnx bundles: `encoder*.onnx`, `decoder*.onnx`,
/// `joiner*.onnx` and `tokens.txt`. Encoder and joiner prefer the int8
/// weights; the decoder keeps the full-precision file, which is what the
/// model page's int8 recipe uses (docs/engine-asr.md).
pub fn find_model_files(dir: &Path) -> Result<ModelFiles, String> {
    let entries = fs::read_dir(dir)
        .map_err(|error| format!("cannot read model dir {}: {error}", dir.display()))?;
    let mut names: Vec<(String, PathBuf)> = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().to_ascii_lowercase();
        names.push((name, path));
    }

    let pick = |role: &str, prefer_int8: bool| -> Result<PathBuf, String> {
        let mut best: Option<(u8, PathBuf)> = None;
        for (lower, path) in &names {
            if !lower.starts_with(role) || !lower.ends_with(".onnx") {
                continue;
            }
            let is_int8 = lower.contains(".int8.");
            let score = if is_int8 == prefer_int8 { 0 } else { 1 };
            let replace = match &best {
                None => true,
                Some((best_score, best_path)) => {
                    score < *best_score || (score == *best_score && path < best_path)
                }
            };
            if replace {
                best = Some((score, path.clone()));
            }
        }
        best.map(|(_, path)| path).ok_or_else(|| {
            format!(
                "model dir {} has no {role}*.onnx: point --model-dir at an \
                 extracted sherpa-onnx streaming transducer model \
                 (docs/engine-asr.md)",
                dir.display()
            )
        })
    };

    let encoder = pick("encoder", true)?;
    let decoder = pick("decoder", false)?;
    let joiner = pick("joiner", true)?;
    let tokens = dir.join("tokens.txt");
    if !tokens.is_file() {
        return Err(format!(
            "model dir {} has no tokens.txt: point --model-dir at an extracted \
             sherpa-onnx streaming transducer model (docs/engine-asr.md)",
            dir.display()
        ));
    }

    Ok(ModelFiles {
        encoder,
        decoder,
        joiner,
        tokens,
    })
}

/// A WAV as the mono f32 timeline the recogniser takes, plus its rate.
///
/// [`crate::wav_read`] refuses anything that is not uncompressed 16-bit PCM
/// with one or two channels, so a float or 24-bit file is a sentence rather
/// than noise. A stereo take is summed to mono exactly as playback does.
pub fn wav_samples(path: &Path) -> Result<(Vec<f32>, i32), String> {
    let audio = crate::wav_read::read_wav(path).map_err(|error| error.to_string())?;
    let rate = i32::try_from(audio.rate)
        .map_err(|_| format!("{} has an impossible sample rate {}", path.display(), audio.rate))?;
    Ok((audio.mono(), rate))
}

/// The streaming model's front-end drops the opening of a take unless silence
/// precedes it; sherpa's own CLI prepends this much. Without it the first words
/// of every clip never reach the decoder (docs/engine-asr.md).
pub const LEAD_SILENCE_SECONDS: f32 = 0.5;

/// The same after the last sample, or the final phoneme is clipped. The CLI's
/// own tail is 0.8 s.
pub const TAIL_SILENCE_SECONDS: f32 = 0.8;

/// Silence to feed before a take at `rate`, so its opening words are kept.
pub fn lead_silence(rate: i32) -> Vec<f32> {
    silence(rate, LEAD_SILENCE_SECONDS)
}

/// Silence to feed after a take at `rate`, so its last word is not clipped.
pub fn tail_silence(rate: i32) -> Vec<f32> {
    silence(rate, TAIL_SILENCE_SECONDS)
}

fn silence(rate: i32, seconds: f32) -> Vec<f32> {
    let seconds = if seconds.is_finite() && seconds > 0.0 {
        seconds
    } else {
        0.0
    };
    let rate = rate.max(0) as f32;
    vec![0.0f32; (seconds * rate).round() as usize]
}

/// One output line, exactly `{"text":"…","final":true|false}`.
///
/// Text is UTF-8 from the recogniser; quotes, backslashes and control
/// characters are escaped so a line can never break the stream.
pub fn json_line(text: &str, is_final: bool) -> String {
    let mut line = String::with_capacity(text.len() + 32);
    line.push_str("{\"text\":\"");
    for ch in text.chars() {
        match ch {
            '"' => line.push_str("\\\""),
            '\\' => line.push_str("\\\\"),
            '\n' => line.push_str("\\n"),
            '\r' => line.push_str("\\r"),
            '\t' => line.push_str("\\t"),
            '\u{08}' => line.push_str("\\b"),
            '\u{0c}' => line.push_str("\\f"),
            ch if (ch as u32) < 0x20 => {
                line.push_str(&format!("\\u{:04x}", ch as u32));
            }
            ch => line.push(ch),
        }
    }
    line.push_str("\",\"final\":");
    line.push_str(if is_final { "true" } else { "false" });
    line.push('}');
    line
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wav::WavWriter;
    use std::env;
    use std::process;

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new(name: &str) -> Self {
            let path = env::temp_dir().join(format!(
                "jawn-asr-args-{}-{name}",
                process::id()
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).expect("create temp dir");
            TempDir { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    #[test]
    fn a_wav_file_and_a_model_dir_parse() {
        let command = parse_args([
            "--model-dir",
            "/models/en",
            "-f",
            "/tmp/take.wav",
            "--threads",
            "2",
        ])
        .expect("parse");
        assert_eq!(
            command,
            Command::Run(AsrArgs {
                model_dir: PathBuf::from("/models/en"),
                input: Input::Wav(PathBuf::from("/tmp/take.wav")),
                threads: 2,
            })
        );
    }

    #[test]
    fn pcm_stdin_parses_and_equals_forms_work() {
        let command = parse_args(["--model-dir=/models/en", "--pcm-stdin"]).expect("parse");
        assert_eq!(
            command,
            Command::Run(AsrArgs {
                model_dir: PathBuf::from("/models/en"),
                input: Input::PcmStdin,
                threads: 1,
            })
        );
        let command =
            parse_args(["--model-dir=/m", "--file=/tmp/a.wav", "--threads=4"]).expect("parse");
        assert_eq!(
            command,
            Command::Run(AsrArgs {
                model_dir: PathBuf::from("/m"),
                input: Input::Wav(PathBuf::from("/tmp/a.wav")),
                threads: 4,
            })
        );
    }

    #[test]
    fn help_wins_even_without_other_arguments() {
        assert_eq!(parse_args(["--help"]).expect("parse"), Command::Help);
        assert_eq!(parse_args(std::iter::empty::<&str>()).expect_err("no model"), "--model-dir DIR is required (try --help)");
    }

    #[test]
    fn both_inputs_are_refused() {
        let error = parse_args(["--model-dir", "/m", "-f", "a.wav", "--pcm-stdin"])
            .expect_err("two inputs");
        assert!(error.contains("not both"), "{error}");
    }

    #[test]
    fn a_missing_input_is_refused() {
        let error = parse_args(["--model-dir", "/m"]).expect_err("no input");
        assert!(error.contains("an input is required"), "{error}");
    }

    #[test]
    fn an_unknown_flag_is_named() {
        let error = parse_args(["--model-dir", "/m", "--wat"]).expect_err("unknown");
        assert_eq!(error, "unknown argument `--wat` (try --help)");
    }

    #[test]
    fn bad_thread_counts_are_refused() {
        assert!(parse_args(["--model-dir", "/m", "--pcm-stdin", "--threads", "0"]).is_err());
        assert!(parse_args(["--model-dir", "/m", "--pcm-stdin", "--threads", "x"]).is_err());
        assert!(parse_args(["--model-dir", "/m", "--pcm-stdin", "--threads"]).is_err());
    }

    #[test]
    fn json_escapes_quotes_backslashes_and_controls() {
        assert_eq!(
            json_line("he said \"hi\"\n\\path\t", true),
            r#"{"text":"he said \"hi\"\n\\path\t","final":true}"#
        );
        assert_eq!(
            json_line("\u{01}", false),
            r#"{"text":"\u0001","final":false}"#
        );
        assert_eq!(json_line("", true), r#"{"text":"","final":true}"#);
    }

    #[test]
    fn the_model_files_prefer_int8_encoder_and_joiner_but_a_plain_decoder() {
        let dir = TempDir::new("model-files");
        for name in [
            "encoder-epoch-99-avg-1.int8.onnx",
            "encoder-epoch-99-avg-1.onnx",
            "decoder-epoch-99-avg-1.int8.onnx",
            "decoder-epoch-99-avg-1.onnx",
            "joiner-epoch-99-avg-1.int8.onnx",
            "joiner-epoch-99-avg-1.onnx",
            "tokens.txt",
        ] {
            fs::write(dir.path.join(name), b"fixture").expect("write fixture");
        }

        let files = find_model_files(&dir.path).expect("find");
        assert_eq!(
            files.encoder.file_name().expect("name"),
            "encoder-epoch-99-avg-1.int8.onnx"
        );
        assert_eq!(
            files.decoder.file_name().expect("name"),
            "decoder-epoch-99-avg-1.onnx"
        );
        assert_eq!(
            files.joiner.file_name().expect("name"),
            "joiner-epoch-99-avg-1.int8.onnx"
        );
        assert_eq!(files.tokens, dir.path.join("tokens.txt"));
    }

    #[test]
    fn a_model_dir_with_no_encoder_or_tokens_says_which_is_missing() {
        let dir = TempDir::new("model-missing");
        fs::write(dir.path.join("decoder.onnx"), b"fixture").expect("write");
        fs::write(dir.path.join("joiner.onnx"), b"fixture").expect("write");
        fs::write(dir.path.join("tokens.txt"), b"fixture").expect("write");
        let error = find_model_files(&dir.path).expect_err("no encoder");
        assert!(error.contains("no encoder*.onnx"), "{error}");
        assert!(error.contains("docs/engine-asr.md"), "{error}");

        fs::write(dir.path.join("encoder.onnx"), b"fixture").expect("write");
        fs::remove_file(dir.path.join("tokens.txt")).expect("remove");
        let error = find_model_files(&dir.path).expect_err("no tokens");
        assert!(error.contains("no tokens.txt"), "{error}");
    }

    #[test]
    fn a_stereo_wav_is_downmixed_to_the_mono_timeline() {
        let dir = TempDir::new("wav");
        let path = dir.path.join("take.wav");
        let samples: Vec<i16> = vec![1000, 3000, -1000, -3000];
        let mut writer = WavWriter::create(&path, 16_000, 2, 8).expect("create");
        writer.write_i16(&samples).expect("write");
        writer.finish().expect("finish");

        let (mono, rate) = wav_samples(&path).expect("read");
        assert_eq!(rate, 16_000);
        assert_eq!(mono.len(), 2);
        assert!((mono[0] - 4000.0 / 32_768.0).abs() < 1e-9, "{mono:?}");
        assert!((mono[1] + 4000.0 / 32_768.0).abs() < 1e-9, "{mono:?}");
    }

    #[test]
    fn a_file_that_is_not_pcm_names_the_file() {
        let dir = TempDir::new("not-wav");
        let path = dir.path.join("notes.txt");
        fs::write(&path, b"not audio").expect("write");
        let error = wav_samples(&path).expect_err("refuse");
        assert!(error.contains("notes.txt"), "{error}");
        assert!(error.contains("RIFF"), "{error}");
    }

    #[test]
    fn the_stream_is_padded_at_both_ends() {
        // Half a second in front and 0.8 s behind: the streaming front-end
        // drops the opening words and clips the last one without them.
        assert_eq!(lead_silence(16_000).len(), 8_000);
        assert_eq!(lead_silence(8_000).len(), 4_000);
        assert_eq!(tail_silence(16_000).len(), 12_800);
        assert!(lead_silence(16_000).iter().all(|sample| *sample == 0.0));
        assert!(tail_silence(16_000).iter().all(|sample| *sample == 0.0));
        // A nonsense rate must not ask for a huge or negative pad.
        assert!(lead_silence(-1).is_empty());
        assert!(tail_silence(0).is_empty());
    }
}
