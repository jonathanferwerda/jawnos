# `jawn-asr` — the streaming recogniser

`jawn-asr` is a second binary in the engine crate. It runs sherpa-onnx's
streaming transducer through the public C API and prints one JSON object per
result:

```json
{"text":" AFTER EARLY NIGHTFALL","final":false}
{"text":" AFTER EARLY NIGHTFALL THE YELLOW LAMPS","final":true}
```

The Perl side calls it for a file; `--pcm-stdin` is the streaming start.

It is behind `--features sherpa`, off by default. The default engine and its
offline suite do not link a C library, and `Cargo.lock` gains no crate: the
library is linked by `engine/build.rs` from a directory you point at.

## Why a separate process

- **The audio engine keeps running.** A model load that runs out of memory,
  a C library that faults, or a restart after a model swap cannot take the
  device, the graph or a live monitor with it. The audio engine and `jawn-asr`
  share no address space.
- **The default stays the default.** Every machine that cannot host the model
  builds and tests exactly as before. `cargo test --offline` never needs a
  downloadable asset.
- **The model is an argument, not a build.** `--model-dir` swaps bundles; the
  engine binary is not rebuilt.
- **The languages stay separate.** The bundled model is English (`en`); the
  other fifteen interface languages keep whisper, which already has their
  models. A small English streaming model is faster and smaller than making
  whisper cover the live path for every language.

## Assets (sherpa-onnx v2.0.3)

Download one shared asset and note its `lib/` directory. That directory is
`SHERPA_ONNX_LIB_DIR`; it contains `libsherpa-onnx-c-api.so`,
`libonnxruntime.so` and the sibling libraries.

| Host | Asset |
| --- | --- |
| Linux x86-64 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-linux-x64-shared.tar.bz2` |
| Linux aarch64 (CPU) | `https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-linux-aarch64-shared-cpu.tar.bz2` |
| Android / Termux aarch64 | `https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-android-aarch64-termux-shared.tar.bz2` |
| Linux aarch64 static | `https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-linux-aarch64-static.tar.bz2` |

`engine/build.rs` accepts the shared pair only (`.so` / versioned `.so.N`),
because `scripts/build_engine.pl` stages the sibling `.so`s and runs the
binary through an `$ORIGIN` rpath. The `static` asset is listed for a
fully-static deployment that supplies its own link line; it is not what the
staging helper copies.

The Linux shared assets are built in the `manylinux2014` images (CentOS 7,
devtoolset-11), so their floor is **glibc 2.17**. The Android/Termux shared
libraries are built with the runner's current NDK (r30 in this tree's
toolchain) against Termux's API floor, which is below the app's
`minSdkVersion 26`; API 26 is the floor that matters here and it clears it.

### The model

`https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2`

Apache-2.0, English only (LibriSpeech). It is a 20M-parameter streaming
transducer with endpoint detection built in. Extract it and point
`--model-dir` at the directory; the int8 set is:

```text
encoder-epoch-99-avg-1.int8.onnx   41 MB
decoder-epoch-99-avg-1.onnx       2.0 MB
joiner-epoch-99-avg-1.int8.onnx   253 KB
tokens.txt
```

`jawn-asr` discovers `encoder*.onnx`, `decoder*.onnx`, `joiner*.onnx` and
`tokens.txt`. Encoder and joiner prefer `.int8.`; the decoder keeps the
full-precision file, which is what the model page's int8 recipe uses. A
missing file is a sentence naming it, not a crash.

## Proof commands

### 1. The default build and suite (no libraries, no network)

```sh
cd engine
cargo test --offline
```

The default feature set is empty; `build.rs` returns without emitting
anything and `jawn-asr` is not built (`required-features`).

### 2. A feature build with the libraries

```sh
cd engine
export SHERPA_ONNX_LIB_DIR="$PWD/../vendor/sherpa-onnx-v2.0.3-linux-x64-shared/lib"
cargo build --offline --release --features sherpa --bin jawn-asr
```

`SHERPA_ONNX_LIB_DIR` must be an absolute or correct relative path to the
extracted asset's `lib/`. If it is unset, missing, or lacks either
`libsherpa-onnx-c-api.so` or `libonnxruntime.so`, the build stops with one
actionable line and does not fall back to a smaller engine.

The house staging path does the same and copies the recogniser and its
siblings together:

```sh
perl scripts/build_engine.pl --features sherpa
```

This stages `perl/audio/jawn-asr` and the `lib*.so*` files beside it, with
`-Wl,-rpath,$ORIGIN`, so the pair can move without `LD_LIBRARY_PATH`. A
requested `sherpa` is never dropped from the fallback attempts; only `alsa`
and `jack` may be retried with fewer backends. `--android` adds
`--features oboe,sherpa` only when `SHERPA_ONNX_LIB_DIR` already contains the
Android aarch64 libraries, and copies them into `jniLibs/arm64-v8a/`.

### 3. A WAV through `jawn-asr`

Any 10-second, mono or stereo, 16-bit PCM WAV with speech works. (The model
archive's `test_wavs/0.wav` is 6.6 s and also works.)

```sh
export MODEL_DIR="$PWD/vendor/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"
export SHERPA_ONNX_LIB_DIR="$PWD/vendor/sherpa-onnx-v2.0.3-linux-x64-shared/lib"

# manual build: the loader needs the directory
LD_LIBRARY_PATH="$SHERPA_ONNX_LIB_DIR" \
  ./engine/target/release/jawn-asr --model-dir "$MODEL_DIR" -f ./ten-seconds.wav

# staged build: the $ORIGIN rpath finds the siblings
./perl/audio/jawn-asr --model-dir "$MODEL_DIR" -f ./ten-seconds.wav
```

A stereo file is summed to mono exactly as playback does. A rate other than
16 kHz is passed to the C API, which resamples; a file that is not
uncompressed 16-bit PCM with one or two channels is refused by name before
the recogniser sees it.

Live input is raw little-endian signed 16-bit mono at 16 kHz:

```sh
arecord -q -f S16_LE -r 16000 -c 1 -t raw | \
  ./perl/audio/jawn-asr --model-dir "$MODEL_DIR" --pcm-stdin
```

The last line is `final:true`; a configuration or model error exits 2 and
prints `jawn-asr: …` on stderr.

## What is verified without the libraries

- The default `cargo build --offline` and `cargo test --offline` (argument,
  WAV, model-discovery and JSON tests included).
- The feature path type-checks with two empty files standing in for the
  libraries; the build script's missing-variable and missing-library failures.
- The v2.0.3 C ABI used here (prefixed `SherpaOnnx*` symbols and the
  `SherpaOnnxOnlineRecognizerConfig` layout) is transcribed from that
  release's `sherpa-onnx/c-api/c-api.h`.

Not verified on a machine without the assets: the actual link, loading the
model, and the text a take produces. Commands 2 and 3 above are the proof.

## Files

- `engine/build.rs` — link search and `-l` names from `SHERPA_ONNX_LIB_DIR`.
- `engine/src/sherpa.rs` — the hand-written C declarations and safe wrapper.
- `engine/src/asr_args.rs` — the command line, model discovery, WAV/JSON rules.
- `engine/src/bin/jawn_asr.rs` — the executable.
- `scripts/build_engine.pl` — staging, `$ORIGIN` rpath, feature fallback.
