//! Streaming speech recognition through the sherpa-onnx C API, v2.0.3.
//!
//! Only the streaming transducer path is declared: create a recogniser, create
//! a stream, accept mono f32 at a sample rate, decode while ready, read the
//! text, and destroy. The declarations are hand-written against
//! `sherpa-onnx/c-api/c-api.h` from that release; no crate binding and no
//! header are needed at build time (docs/engine-asr.md).
//!
//! Every pointer the C API returns is owned by the library. The safe wrapper
//! copies the text out before destroying the result, and destroys streams
//! before the recogniser that made them.

#![allow(non_camel_case_types)]

use std::ffi::{c_char, c_float, c_int, CStr, CString};
use std::marker::PhantomData;
use std::mem;
use std::path::Path;

use crate::asr_args::{find_model_files, SAMPLE_RATE};

// --- The C structs, in header order -----------------------------------------

#[repr(C)]
struct SherpaOnnxFeatureConfig {
    sample_rate: c_int,
    feature_dim: c_int,
}

#[repr(C)]
struct SherpaOnnxOnlineTransducerModelConfig {
    encoder: *const c_char,
    decoder: *const c_char,
    joiner: *const c_char,
}

#[repr(C)]
struct SherpaOnnxOnlineParaformerModelConfig {
    encoder: *const c_char,
    decoder: *const c_char,
}

#[repr(C)]
struct SherpaOnnxOnlineZipformer2CtcModelConfig {
    model: *const c_char,
}

#[repr(C)]
struct SherpaOnnxOnlineNemoCtcModelConfig {
    model: *const c_char,
}

#[repr(C)]
struct SherpaOnnxOnlineToneCtcModelConfig {
    model: *const c_char,
}

#[repr(C)]
struct SherpaOnnxOnlineModelConfig {
    transducer: SherpaOnnxOnlineTransducerModelConfig,
    paraformer: SherpaOnnxOnlineParaformerModelConfig,
    zipformer2_ctc: SherpaOnnxOnlineZipformer2CtcModelConfig,
    tokens: *const c_char,
    num_threads: c_int,
    provider: *const c_char,
    debug: c_int,
    model_type: *const c_char,
    modeling_unit: *const c_char,
    bpe_vocab: *const c_char,
    tokens_buf: *const c_char,
    tokens_buf_size: c_int,
    nemo_ctc: SherpaOnnxOnlineNemoCtcModelConfig,
    t_one_ctc: SherpaOnnxOnlineToneCtcModelConfig,
}

#[repr(C)]
struct SherpaOnnxOnlineCtcFstDecoderConfig {
    graph: *const c_char,
    max_active: c_int,
}

#[repr(C)]
struct SherpaOnnxHomophoneReplacerConfig {
    dict_dir: *const c_char,
    lexicon: *const c_char,
    rule_fsts: *const c_char,
}

#[repr(C)]
struct SherpaOnnxOnlineRecognizerConfig {
    feat_config: SherpaOnnxFeatureConfig,
    model_config: SherpaOnnxOnlineModelConfig,
    decoding_method: *const c_char,
    max_active_paths: c_int,
    enable_endpoint: c_int,
    rule1_min_trailing_silence: c_float,
    rule2_min_trailing_silence: c_float,
    rule3_min_utterance_length: c_float,
    hotwords_file: *const c_char,
    hotwords_score: c_float,
    ctc_fst_decoder_config: SherpaOnnxOnlineCtcFstDecoderConfig,
    rule_fsts: *const c_char,
    rule_fars: *const c_char,
    blank_penalty: c_float,
    hotwords_buf: *const c_char,
    hotwords_buf_size: c_int,
    hr: SherpaOnnxHomophoneReplacerConfig,
}

#[repr(C)]
struct SherpaOnnxOnlineRecognizerResult {
    text: *const c_char,
    tokens: *const c_char,
    tokens_arr: *const *const c_char,
    timestamps: *mut c_float,
    count: c_int,
    json: *const c_char,
}

#[repr(C)]
struct SherpaOnnxOnlineRecognizer {
    _private: [u8; 0],
}

#[repr(C)]
struct SherpaOnnxOnlineStream {
    _private: [u8; 0],
}

extern "C" {
    fn SherpaOnnxCreateOnlineRecognizer(
        config: *const SherpaOnnxOnlineRecognizerConfig,
    ) -> *const SherpaOnnxOnlineRecognizer;
    fn SherpaOnnxDestroyOnlineRecognizer(recognizer: *const SherpaOnnxOnlineRecognizer);

    fn SherpaOnnxCreateOnlineStream(
        recognizer: *const SherpaOnnxOnlineRecognizer,
    ) -> *const SherpaOnnxOnlineStream;
    fn SherpaOnnxDestroyOnlineStream(stream: *const SherpaOnnxOnlineStream);

    fn SherpaOnnxOnlineStreamAcceptWaveform(
        stream: *const SherpaOnnxOnlineStream,
        sample_rate: c_int,
        samples: *const c_float,
        n: c_int,
    );
    fn SherpaOnnxOnlineStreamInputFinished(stream: *const SherpaOnnxOnlineStream);
    fn SherpaOnnxOnlineStreamIsEndpoint(
        recognizer: *const SherpaOnnxOnlineRecognizer,
        stream: *const SherpaOnnxOnlineStream,
    ) -> c_int;
    fn SherpaOnnxOnlineStreamReset(
        recognizer: *const SherpaOnnxOnlineRecognizer,
        stream: *const SherpaOnnxOnlineStream,
    );

    fn SherpaOnnxIsOnlineStreamReady(
        recognizer: *const SherpaOnnxOnlineRecognizer,
        stream: *const SherpaOnnxOnlineStream,
    ) -> c_int;
    fn SherpaOnnxDecodeOnlineStream(
        recognizer: *const SherpaOnnxOnlineRecognizer,
        stream: *const SherpaOnnxOnlineStream,
    );
    fn SherpaOnnxGetOnlineStreamResult(
        recognizer: *const SherpaOnnxOnlineRecognizer,
        stream: *const SherpaOnnxOnlineStream,
    ) -> *const SherpaOnnxOnlineRecognizerResult;
    fn SherpaOnnxDestroyOnlineRecognizerResult(
        result: *const SherpaOnnxOnlineRecognizerResult,
    );
}

// --- The safe wrapper --------------------------------------------------------

/// A loaded streaming recogniser. Dropping it frees the model.
pub struct Recognizer {
    raw: *const SherpaOnnxOnlineRecognizer,
}

impl Recognizer {
    /// Load the streaming transducer model in `model_dir` with endpoint
    /// detection on, greedy decoding and the CPU provider.
    ///
    /// The C API copies every path during creation, so the strings made here
    /// can be released before this function returns.
    pub fn new(model_dir: &Path, threads: i32) -> Result<Self, String> {
        let files = find_model_files(model_dir)?;
        let encoder = cstring(&files.encoder, "encoder")?;
        let decoder = cstring(&files.decoder, "decoder")?;
        let joiner = cstring(&files.joiner, "joiner")?;
        let tokens = cstring(&files.tokens, "tokens")?;
        let provider = CString::new("cpu").expect("a literal has no NUL");
        let decoding = CString::new("greedy_search").expect("a literal has no NUL");

        // Zero first: every field this path does not use (paraformer, CTC,
        // hotwords, FSTs, homophones) is a null pointer or zero, which the C
        // API reads as "not configured".
        let mut config: SherpaOnnxOnlineRecognizerConfig = unsafe { mem::zeroed() };
        config.feat_config.sample_rate = SAMPLE_RATE;
        config.feat_config.feature_dim = 80;
        config.model_config.transducer.encoder = encoder.as_ptr();
        config.model_config.transducer.decoder = decoder.as_ptr();
        config.model_config.transducer.joiner = joiner.as_ptr();
        config.model_config.tokens = tokens.as_ptr();
        config.model_config.num_threads = threads;
        config.model_config.provider = provider.as_ptr();
        config.decoding_method = decoding.as_ptr();
        config.max_active_paths = 4;
        config.enable_endpoint = 1;
        // The house defaults from the C++ config; endpoint detection is what
        // makes a live stream emit a final line at the end of an utterance.
        config.rule1_min_trailing_silence = 2.4;
        config.rule2_min_trailing_silence = 1.2;
        config.rule3_min_utterance_length = 20.0;
        config.hotwords_score = 1.5;

        let raw = unsafe { SherpaOnnxCreateOnlineRecognizer(&config) };
        if raw.is_null() {
            return Err(format!(
                "sherpa-onnx could not load the model in {}; its stderr above \
                 says which file was refused (docs/engine-asr.md)",
                model_dir.display()
            ));
        }
        Ok(Recognizer { raw })
    }

    /// A fresh decoding state for one utterance.
    pub fn stream(&self) -> Result<Stream<'_>, String> {
        let raw = unsafe { SherpaOnnxCreateOnlineStream(self.raw) };
        if raw.is_null() {
            return Err("sherpa-onnx could not create a stream".to_string());
        }
        Ok(Stream {
            recognizer: self.raw,
            raw,
            _borrow: PhantomData,
        })
    }
}

impl Drop for Recognizer {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { SherpaOnnxDestroyOnlineRecognizer(self.raw) };
        }
    }
}

/// One decoding state, borrowed from its recogniser.
pub struct Stream<'a> {
    recognizer: *const SherpaOnnxOnlineRecognizer,
    raw: *const SherpaOnnxOnlineStream,
    _borrow: PhantomData<&'a Recognizer>,
}

impl Stream<'_> {
    /// Append mono f32 in `[-1, 1]`. The C API resamples when `sample_rate`
    /// differs from the model's 16 kHz, so a 44.1 kHz take is still valid.
    pub fn accept_at(&self, sample_rate: i32, samples: &[f32]) {
        if samples.is_empty() {
            return;
        }
        let n = samples.len().min(c_int::MAX as usize) as c_int;
        unsafe {
            SherpaOnnxOnlineStreamAcceptWaveform(self.raw, sample_rate, samples.as_ptr(), n);
        }
    }

    /// Append mono f32 already at 16 kHz.
    pub fn accept_16k(&self, samples: &[f32]) {
        self.accept_at(SAMPLE_RATE, samples);
    }

    /// Decode every chunk that is ready. Returns whether anything ran.
    pub fn decode_ready(&self) -> bool {
        let mut decoded = false;
        while (unsafe { SherpaOnnxIsOnlineStreamReady(self.recognizer, self.raw) }) != 0 {
            unsafe { SherpaOnnxDecodeOnlineStream(self.recognizer, self.raw) };
            decoded = true;
        }
        decoded
    }

    /// The recognized text so far, copied out of the result snapshot.
    pub fn text(&self) -> String {
        let result = unsafe { SherpaOnnxGetOnlineStreamResult(self.recognizer, self.raw) };
        if result.is_null() {
            return String::new();
        }
        let text = unsafe { (*result).text };
        let text = if text.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(text) }.to_string_lossy().into_owned()
        };
        unsafe { SherpaOnnxDestroyOnlineRecognizerResult(result) };
        text
    }

    /// Whether trailing silence or an utterance boundary fired.
    pub fn is_endpoint(&self) -> bool {
        (unsafe { SherpaOnnxOnlineStreamIsEndpoint(self.recognizer, self.raw) }) != 0
    }

    /// Clear the decoder for the next utterance after an endpoint.
    pub fn reset(&self) {
        unsafe { SherpaOnnxOnlineStreamReset(self.recognizer, self.raw) };
    }

    /// Signal end of input so the final chunk decodes completely.
    pub fn input_finished(&self) {
        unsafe { SherpaOnnxOnlineStreamInputFinished(self.raw) };
    }
}

impl Drop for Stream<'_> {
    fn drop(&mut self) {
        if !self.raw.is_null() {
            unsafe { SherpaOnnxDestroyOnlineStream(self.raw) };
        }
    }
}

fn cstring(path: &Path, role: &str) -> Result<CString, String> {
    let text = path
        .to_str()
        .ok_or_else(|| format!("the {role} path {} is not UTF-8", path.display()))?;
    CString::new(text).map_err(|_| format!("the {role} path {} contains a NUL", path.display()))
}

// --- The ABI gate ------------------------------------------------------------
//
// `engine/tests/sherpa_abi_probe.c` measures these same sizes and offsets
// against the v2.0.3 header, and `scripts/build_engine.pl` compiles the probe
// and compares its lines before staging. This block makes the same
// disagreement a compile error whenever the `sherpa` feature is built. The
// numbers are for a 64-bit target, which is the only shape the shared assets
// ship.
#[cfg(all(feature = "sherpa", target_pointer_width = "64"))]
const _: () = {
    use core::mem::{offset_of, size_of};

    assert!(size_of::<SherpaOnnxFeatureConfig>() == 8);
    assert!(offset_of!(SherpaOnnxFeatureConfig, sample_rate) == 0);
    assert!(offset_of!(SherpaOnnxFeatureConfig, feature_dim) == 4);

    assert!(size_of::<SherpaOnnxOnlineTransducerModelConfig>() == 24);
    assert!(offset_of!(SherpaOnnxOnlineTransducerModelConfig, encoder) == 0);
    assert!(offset_of!(SherpaOnnxOnlineTransducerModelConfig, decoder) == 8);
    assert!(offset_of!(SherpaOnnxOnlineTransducerModelConfig, joiner) == 16);

    assert!(size_of::<SherpaOnnxOnlineModelConfig>() == 136);
    assert!(offset_of!(SherpaOnnxOnlineModelConfig, transducer) == 0);
    assert!(offset_of!(SherpaOnnxOnlineModelConfig, tokens) == 48);
    assert!(offset_of!(SherpaOnnxOnlineModelConfig, num_threads) == 56);
    assert!(offset_of!(SherpaOnnxOnlineModelConfig, provider) == 64);

    assert!(size_of::<SherpaOnnxOnlineRecognizerConfig>() == 272);
    assert!(offset_of!(SherpaOnnxOnlineRecognizerConfig, feat_config) == 0);
    assert!(offset_of!(SherpaOnnxOnlineRecognizerConfig, model_config) == 8);
    assert!(offset_of!(SherpaOnnxOnlineRecognizerConfig, decoding_method) == 144);
    assert!(offset_of!(SherpaOnnxOnlineRecognizerConfig, max_active_paths) == 152);
    assert!(offset_of!(SherpaOnnxOnlineRecognizerConfig, enable_endpoint) == 156);
    assert!(offset_of!(SherpaOnnxOnlineRecognizerConfig, rule1_min_trailing_silence) == 160);
    assert!(offset_of!(SherpaOnnxOnlineRecognizerConfig, rule2_min_trailing_silence) == 164);
    assert!(
        offset_of!(SherpaOnnxOnlineRecognizerConfig, rule3_min_utterance_length) == 168
    );
    assert!(offset_of!(SherpaOnnxOnlineRecognizerConfig, hotwords_score) == 184);
};
