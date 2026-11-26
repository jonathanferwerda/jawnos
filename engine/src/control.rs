//! The one process-wide take slot and the JSON helpers every backend shares.
//!
//! `jawn_audio_start` (Oboe) and `jawn_audio_start_usb` (direct usbfs) each arm
//! a take, but a process may run only one: the app's `jawn_audio_stop` and
//! `jawn_audio_status` have to reach whichever backend armed it. So the slot
//! lives here, once, and both modules lock the same mutex instead of keeping
//! two that would each answer for a different take.
//!
//! The audio path never touches this lock; only start, stop and status do.

#![allow(dead_code)]

use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::atomic::AtomicBool;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};
use std::thread::JoinHandle;

/// The service's view of the one take this process may run.
pub(crate) struct Control {
    pub(crate) stop: Option<Arc<AtomicBool>>,
    pub(crate) handle: Option<JoinHandle<()>>,
    pub(crate) status: String,
}

pub(crate) fn control() -> &'static Mutex<Control> {
    static CONTROL: OnceLock<Mutex<Control>> = OnceLock::new();
    CONTROL.get_or_init(|| {
        Mutex::new(Control {
            stop: None,
            handle: None,
            status: "{\"ok\":false,\"error\":\"no take has started\"}".to_string(),
        })
    })
}

pub(crate) fn lock_control() -> MutexGuard<'static, Control> {
    control()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// One JSON object, matching the engine's existing status style.
pub(crate) fn error_json(error: &str) -> String {
    format!("{{\"ok\":false,\"error\":\"{}\"}}", json_escape(error))
}

pub(crate) fn json_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

pub(crate) fn into_c_string(text: String) -> *mut c_char {
    // `CString::new` fails only on an interior NUL, which JSON cannot carry.
    match CString::new(text) {
        Ok(text) => text.into_raw(),
        Err(_) => CString::new("{\"ok\":false,\"error\":\"status text\"}")
            .expect("static JSON has no NUL")
            .into_raw(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_text_is_escaped() {
        let text = error_json("a \"quoted\"\nline");
        assert_eq!(text, "{\"ok\":false,\"error\":\"a \\\"quoted\\\"\\nline\"}");
    }

    #[test]
    fn a_path_with_a_backslash_survives_json() {
        assert_eq!(json_escape("a\\b\tc"), "a\\\\b\\tc");
    }
}
