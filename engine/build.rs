//! Link the prebuilt sherpa-onnx C API when `--features sherpa` is on.
//!
//! The default engine has no build script work and no C dependency. With the
//! feature on, `SHERPA_ONNX_LIB_DIR` must name the directory that holds the
//! shared libraries from a v2.0.3 asset (`libsherpa-onnx-c-api.so` and
//! `libonnxruntime.so`); this script emits the search path and the two link
//! names. There is deliberately no download and no crate: docs/engine-asr.md.
//!
//! A missing variable or library is a loud, one-line failure. Falling through
//! to a build without the feature would stage a recogniser that cannot load
//! its model.

use std::env;
use std::path::{Path, PathBuf};

fn main() {
    // Off is the ordinary case: emit nothing, so the default build and the
    // offline suite are byte-for-byte what they were before this script.
    if env::var_os("CARGO_FEATURE_SHERPA").is_none() {
        return;
    }

    println!("cargo:rerun-if-env-changed=SHERPA_ONNX_LIB_DIR");

    let value = match env::var_os("SHERPA_ONNX_LIB_DIR") {
        Some(value) if !value.is_empty() => PathBuf::from(value),
        _ => fail(
            "SHERPA_ONNX_LIB_DIR is unset: point it at the lib/ directory of a \
             sherpa-onnx-v2.0.3 shared asset (docs/engine-asr.md)",
        ),
    };

    let api = has_library(&value, "sherpa-onnx-c-api");
    let onnxruntime = has_library(&value, "onnxruntime");
    if !api || !onnxruntime {
        fail(&format!(
            "{} has no {}: point SHERPA_ONNX_LIB_DIR at the lib/ directory of a \
             sherpa-onnx-v2.0.3 shared asset (docs/engine-asr.md)",
            value.display(),
            if api {
                "libonnxruntime.so"
            } else if onnxruntime {
                "libsherpa-onnx-c-api.so"
            } else {
                "libsherpa-onnx-c-api.so or libonnxruntime.so"
            }
        ));
    }

    println!("cargo:rustc-link-search=native={}", value.display());
    println!("cargo:rustc-link-lib=dylib=sherpa-onnx-c-api");
    println!("cargo:rustc-link-lib=dylib=onnxruntime");
}

/// `lib<name>.so`, a versioned `lib<name>.so.N`, or a dylib. Only the shared
/// assets are wired: `scripts/build_engine.pl` stages the sibling `.so`s beside
/// `jawn-asr` and runs it through an `$ORIGIN` rpath (docs/engine-asr.md).
fn has_library(dir: &Path, name: &str) -> bool {
    let lib = format!("lib{name}");
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return false,
    };
    entries.flatten().any(|entry| {
        let file = entry.file_name();
        let file = file.to_string_lossy();
        file == format!("{lib}.so")
            || file.starts_with(&format!("{lib}.so."))
            || file == format!("{lib}.dylib")
    })
}

/// A build-script failure that reads as one actionable line rather than a
/// panic and a backtrace.
fn fail(message: &str) -> ! {
    eprintln!("{message}");
    std::process::exit(1)
}
