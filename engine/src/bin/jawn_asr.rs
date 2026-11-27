//! `jawn-asr`: one JSON object per recognition result.
//!
//! Built only with `--features sherpa` (`required-features` in Cargo.toml), so
//! the default engine and its suite never link the C libraries. The Perl side
//! calls this for a file; `--pcm-stdin` is the streaming start. The output is
//! one `{"text":"…","final":true|false}` line per result and the last line is
//! final (docs/engine-asr.md).

use std::io::{self, Read, Write};
use std::path::Path;
use std::process::ExitCode;

use jawn_audio::asr_args::{self, json_line, wav_samples, Command, Input};
use jawn_audio::sherpa::Recognizer;

/// 0.2 s at 16 kHz: enough for a streaming model to decode, small enough that
/// a live line appears promptly.
const CHUNK: usize = 3_200;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("jawn-asr: {error}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<(), String> {
    let command = asr_args::parse_args(std::env::args().skip(1))?;
    let args = match command {
        Command::Help => {
            print!("{}", asr_args::USAGE);
            return Ok(());
        }
        Command::Run(args) => args,
    };

    let recognizer = Recognizer::new(&args.model_dir, args.threads)?;
    let stdout = io::stdout();
    let mut out = stdout.lock();
    match args.input {
        Input::Wav(path) => transcribe_file(&recognizer, &path, &mut out),
        Input::PcmStdin => transcribe_stdin(&recognizer, &mut out),
    }
}

fn transcribe_file<W: Write>(
    recognizer: &Recognizer,
    path: &Path,
    out: &mut W,
) -> Result<(), String> {
    let (samples, rate) = wav_samples(path)?;
    let stream = recognizer.stream()?;
    let mut last = String::new();
    let mut wrote = false;

    for chunk in samples.chunks(CHUNK) {
        stream.accept_at(rate, chunk);
        stream.decode_ready();
        let text = stream.text();
        if text != last && !text.is_empty() {
            emit(out, &text, false)?;
            last = text;
            wrote = true;
        }
        if stream.is_endpoint() {
            // A file may hold several utterances. Endpoint detection closes
            // each one; report it as final and start a fresh stream state.
            let text = stream.text();
            if !text.is_empty() {
                emit(out, &text, true)?;
                wrote = true;
            }
            stream.reset();
            last.clear();
        }
    }

    // The tail is decoded only after the input is known to be complete.
    stream.input_finished();
    stream.decode_ready();
    let text = stream.text();
    if !text.is_empty() || !wrote {
        emit(out, &text, true)?;
    }
    out.flush().map_err(|error| format!("cannot write: {error}"))
}

fn transcribe_stdin<W: Write>(recognizer: &Recognizer, out: &mut W) -> Result<(), String> {
    let stream = recognizer.stream()?;
    let stdin = io::stdin();
    let mut stdin = stdin.lock();
    let mut bytes = vec![0u8; CHUNK * 2];
    let mut carry: Option<u8> = None;
    let mut last = String::new();
    let mut wrote = false;

    loop {
        let read = stdin
            .read(&mut bytes)
            .map_err(|error| format!("cannot read stdin: {error}"))?;
        if read == 0 {
            break;
        }

        // Only whole little-endian i16 pairs are samples; an odd byte waits
        // for the next read, and a single dangling byte at EOF is discarded.
        let mut pcm = Vec::with_capacity((read + usize::from(carry.is_some())) / 2);
        let mut at = 0usize;
        if let Some(first) = carry.take() {
            pcm.push(i16::from_le_bytes([first, bytes[0]]) as f32 / 32_768.0);
            at = 1;
        }
        while at + 1 < read {
            pcm.push(i16::from_le_bytes([bytes[at], bytes[at + 1]]) as f32 / 32_768.0);
            at += 2;
        }
        if at < read {
            carry = Some(bytes[at]);
        }
        if pcm.is_empty() {
            continue;
        }

        stream.accept_16k(&pcm);
        stream.decode_ready();
        let text = stream.text();
        if text != last && !text.is_empty() {
            emit(out, &text, false)?;
            last = text;
            wrote = true;
        }
        if stream.is_endpoint() {
            let text = stream.text();
            if !text.is_empty() {
                emit(out, &text, true)?;
                wrote = true;
            }
            stream.reset();
            last.clear();
        }
    }

    stream.input_finished();
    stream.decode_ready();
    let text = stream.text();
    if !text.is_empty() || !wrote {
        emit(out, &text, true)?;
    }
    out.flush().map_err(|error| format!("cannot write: {error}"))
}

fn emit<W: Write>(out: &mut W, text: &str, is_final: bool) -> Result<(), String> {
    writeln!(out, "{}", json_line(text, is_final))
        .map_err(|error| format!("cannot write: {error}"))
}
