//! The binary is the seam the manager spawns, so it is tested the way it will be
//! used: as a process, with no device.

use std::process::{Command, Output};

fn run(args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_jawn-audio"))
        .args(args)
        .output()
        .expect("run jawn-audio")
}

fn json_number(text: &str, key: &str) -> f64 {
    let needle = format!("\"{key}\":");
    let start = text.find(&needle).unwrap_or_else(|| panic!("no {key} in {text}")) + needle.len();
    let rest = &text[start..];
    let end = rest
        .find(|c: char| c == ',' || c == '}')
        .unwrap_or_else(|| panic!("unterminated {key} in {text}"));
    rest[..end].parse().unwrap_or_else(|_| panic!("{key} is not a number in {text}"))
}

#[test]
fn check_names_the_null_device() {
    let out = run(&["--check"]);
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("null"), "stdout: {text}");
}

#[test]
fn run_reports_blocks_and_a_tone_peak() {
    let out = run(&[
        "--run", "--seconds", "0.1", "--rate", "48000", "--frames", "64", "--tone", "440",
        "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("\"device\":\"null\""), "stdout: {text}");
    assert_eq!(json_number(&text, "blocks"), 75.0, "stdout: {text}");
    assert_eq!(json_number(&text, "samples"), 9600.0, "stdout: {text}");
    assert!(
        json_number(&text, "peak") > 0.99,
        "the tone did not reach the meter: {text}"
    );
}

#[test]
fn silence_has_no_peak() {
    let out = run(&["--run", "--seconds", "0.1", "--json"]);
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "peak"), 0.0, "stdout: {text}");
}

#[test]
fn selftest_passes() {
    let out = run(&["--selftest"]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("header ok"), "stdout: {text}");
}

#[test]
fn an_unknown_option_is_a_usage_error() {
    let out = run(&["--not-an-option"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("unknown option"));
}

#[test]
fn no_arguments_prints_the_usage() {
    let out = run(&[]);
    assert!(out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("--selftest"));
}

#[test]
fn backends_json_is_one_line_and_always_has_null() {
    let out = run(&["--backends", "--json"]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(text.trim().lines().count(), 1, "stdout: {text}");
    for key in ["alsa", "pipewire", "jack", "null"] {
        assert!(text.contains(&format!("\"{key}\":")), "no {key} in {text}");
    }
    assert!(text.contains("\"null\":true"), "stdout: {text}");
}

#[test]
fn backends_prose_names_every_backend() {
    let out = run(&["--backends"]);
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    for name in ["alsa", "pipewire", "jack", "null"] {
        assert!(text.contains(name), "no {name} in {text}");
    }
}

#[test]
fn loopback_on_null_matches_the_contract() {
    let out = run(&["--loopback", "--backend", "null", "--json"]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(text.trim().lines().count(), 1, "stdout: {text}");
    assert!(text.contains("\"ok\":true"), "stdout: {text}");
    assert!(text.contains("\"backend\":\"null\""), "stdout: {text}");
    assert!(text.contains("\"method\":\"null\""), "stdout: {text}");
    assert!(text.contains("no signal path"), "stdout: {text}");
    assert_eq!(json_number(&text, "samples"), 0.0, "stdout: {text}");
    assert_eq!(json_number(&text, "ms"), 0.0, "stdout: {text}");
    assert_eq!(json_number(&text, "rate"), 48_000.0, "stdout: {text}");
    assert_eq!(json_number(&text, "period"), 64.0, "stdout: {text}");
    assert_eq!(json_number(&text, "buffer"), 256.0, "stdout: {text}");
}

#[test]
fn loopback_echoes_the_requested_period_and_buffer() {
    let out = run(&[
        "--loopback", "--backend", "null", "--period", "128", "--buffer", "512", "--json",
    ]);
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "period"), 128.0, "stdout: {text}");
    assert_eq!(json_number(&text, "buffer"), 512.0, "stdout: {text}");
}

#[test]
fn an_unknown_backend_is_a_usage_error() {
    let out = run(&["--run", "--backend", "banana"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(String::from_utf8_lossy(&out.stderr).contains("unknown backend"));
}

#[test]
fn a_zero_period_is_a_usage_error() {
    let out = run(&["--run", "--period", "0"]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("period"), "stderr: {stderr}");
}

#[test]
fn a_buffer_smaller_than_the_period_is_a_usage_error() {
    let out = run(&["--run", "--period", "256", "--buffer", "128"]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("buffer"), "stderr: {stderr}");
}

#[test]
fn period_is_an_alias_for_the_block_size() {
    let out = run(&["--run", "--period", "64", "--seconds", "0.1", "--json"]);
    assert!(out.status.success());
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "blocks"), 75.0, "stdout: {text}");
    assert_eq!(json_number(&text, "samples"), 9600.0, "stdout: {text}");
}

#[test]
fn the_null_backend_ignores_a_device_name() {
    let out = run(&[
        "--run", "--backend", "null", "--device", "hw:99,9", "--seconds", "0.1", "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("\"device\":\"null\""), "stdout: {text}");
}

#[test]
fn a_failed_loopback_is_exit_one_and_says_why() {
    // A PCM that cannot exist: without the feature the reason is the missing
    // backend, with it the reason is the failed open. Neither needs a card.
    let out = run(&[
        "--loopback", "--backend", "alsa", "--device", "hw:99,9", "--json",
    ]);
    assert_eq!(out.status.code(), Some(1));
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("\"ok\":false"), "stdout: {text}");
    assert!(text.contains("\"samples\":null"), "stdout: {text}");
    assert!(text.contains("\"ms\":null"), "stdout: {text}");
    assert!(text.contains("alsa"), "stdout: {text}");
}

// --- --record ---------------------------------------------------------------

use std::fs;
use std::path::PathBuf;

/// A take path under the system temp directory, removed however the test ends.
struct TempTake {
    path: PathBuf,
}

impl TempTake {
    fn new(name: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "jawn-audio-take-{}-{name}.wav",
            std::process::id()
        ));
        let _ = fs::remove_file(&path);
        TempTake { path }
    }

    fn text(&self) -> &str {
        self.path.to_str().expect("temp path is UTF-8")
    }
}

impl Drop for TempTake {
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
fn record_null_writes_a_stereo_48k_take_and_its_contract() {
    let take = TempTake::new("contract");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--rate", "48000", "--period", "64",
        "--out", take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );

    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(text.trim().lines().count(), 1, "stdout: {text}");
    assert!(text.contains("\"ok\":true"), "stdout: {text}");
    assert!(
        text.contains(&format!("\"path\":\"{}\"", take.text())),
        "stdout: {text}"
    );
    assert!(text.contains("\"backend\":\"null\""), "stdout: {text}");
    assert!(text.contains("\"device\":\"null\""), "stdout: {text}");
    assert_eq!(json_number(&text, "rate"), 48_000.0, "stdout: {text}");
    assert_eq!(json_number(&text, "frames"), 4_800.0, "stdout: {text}");
    assert_eq!(json_number(&text, "dropped"), 0.0, "stdout: {text}");
    assert_eq!(json_number(&text, "channels"), 2.0, "stdout: {text}");
    assert_eq!(json_number(&text, "start_sample"), 0.0, "stdout: {text}");
    assert_eq!(json_number(&text, "xruns"), 0.0, "stdout: {text}");
    assert!(text.contains("\"error\":\"\""), "stdout: {text}");
    let expected = format!(
        "{{\"ok\":true,\"path\":\"{}\",\"backend\":\"null\",\"device\":\"null\",\"rate\":48000,\"frames\":4800,\"dropped\":0,\"channels\":2,\"start_sample\":0,\"xruns\":0,\"inserts\":\"\",\"error\":\"\"}}",
        take.text()
    );
    assert_eq!(text.trim(), expected, "the JSON line is the contract");

    let bytes = fs::read(&take.path).expect("read the take");
    assert_eq!(&bytes[0..4], b"RIFF");
    assert_eq!(&bytes[8..12], b"WAVE");
    assert_eq!(&bytes[36..40], b"data");
    assert_eq!(u16_at(&bytes, 22), 2, "channels");
    assert_eq!(u32_at(&bytes, 24), 48_000, "rate");
    assert_eq!(u16_at(&bytes, 34), 16, "bits");
    assert_eq!(u32_at(&bytes, 40) as usize / 4, 4_800, "frames");
    assert_eq!(bytes.len(), 44 + 4_800 * 4);
}

#[test]
fn record_writes_the_last_partial_block_exactly() {
    // 0.1 s is 4800 frames: 37 full 128-frame blocks and a 64-frame tail.
    let take = TempTake::new("partial");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--rate", "48000", "--period", "128",
        "--buffer", "512", "--out", take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&take.path).expect("read the take");
    assert_eq!(u32_at(&bytes, 40) as usize / 4, 4_800, "frames");
    assert_eq!(bytes.len(), 44 + 4_800 * 4);
}

#[test]
fn a_take_that_cannot_be_written_fails_without_a_success_line() {
    let missing = std::env::temp_dir().join(format!(
        "jawn-audio-no-such-directory-{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&missing);
    let path = missing.join("take.wav");
    let out = run(&[
        "--record",
        "--backend",
        "null",
        "--seconds",
        "0.1",
        "--out",
        path.to_str().expect("temp path is UTF-8"),
        "--json",
    ]);
    assert_eq!(out.status.code(), Some(1));
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("\"ok\":false"), "stdout: {text}");
    assert!(!text.contains("\"ok\":true"), "stdout: {text}");
    assert!(!path.exists(), "a failed take left a file behind");
}

#[test]
fn the_transport_stamp_is_the_requested_start_sample() {
    let take = TempTake::new("start-at");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--start-at", "96000", "--out",
        take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "start_sample"), 96_000.0, "stdout: {text}");
    assert_eq!(json_number(&text, "frames"), 4_800.0, "stdout: {text}");
}

#[test]
fn a_take_that_cannot_open_its_device_does_not_touch_the_file() {
    let take = TempTake::new("busy-device");
    fs::write(&take.path, b"keep me").expect("seed the file");

    let out = run(&[
        "--record", "--backend", "alsa", "--device", "hw:99,9",
        "--seconds", "0.1", "--out", take.text(), "--json",
    ]);

    assert_eq!(out.status.code(), Some(1), "a device that cannot open fails");
    assert_eq!(
        fs::read(&take.path).expect("read the file back"),
        b"keep me",
        "an existing take must survive a failed start"
    );
}

#[test]
fn a_take_records_one_input_of_an_interface() {
    let take = TempTake::new("input-one");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--channel", "1",
        "--out", take.text(), "--json",
    ]);
    assert_eq!(out.status.code(), Some(0), "channel 1 is a valid input");

    let bad = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--channel", "2",
        "--out", take.text(), "--json",
    ]);
    assert_eq!(bad.status.code(), Some(2), "there are only two inputs");
}

#[test]
fn record_without_an_out_path_is_a_usage_error() {
    let out = run(&["--record", "--backend", "null", "--seconds", "0.1"]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("--out"), "stderr: {stderr}");
}

#[test]
fn record_refuses_to_pretend_a_take_is_not_stereo() {
    let take = TempTake::new("mono");
    let out = run(&[
        "--record", "--backend", "null", "--channels", "1", "--out", take.text(),
    ]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("stereo"), "stderr: {stderr}");
    assert!(!take.path.exists(), "a refused take created a file");
}

#[test]
fn record_reports_the_insert_chain_in_order() {
    let take = TempTake::new("inserts");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.05", "--out", take.text(),
        "--insert", "tone", "--insert", "distortion", "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(
        text.contains("\"inserts\":\"tone,distortion\""),
        "stdout: {text}"
    );
}

#[test]
fn record_gain_and_pan_reach_the_take() {
    // A 440 Hz sine at full scale, halved and panned hard left: the left
    // channel is 0.5, the right is the pan's silent edge.
    let take = TempTake::new("gain-pan");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--tone", "440",
        "--gain", "0.5", "--pan", "-1", "--out", take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&take.path).expect("read the take");
    let data = &bytes[44..];
    let mut left_peak = 0i32;
    let mut right_peak = 0i32;
    for frame in data.chunks_exact(4) {
        let left = i16::from_le_bytes([frame[0], frame[1]]) as i32;
        let right = i16::from_le_bytes([frame[2], frame[3]]) as i32;
        left_peak = left_peak.max(left.abs());
        right_peak = right_peak.max(right.abs());
    }
    let full = i16::MAX as i32;
    assert!(
        (left_peak - full / 2).abs() < full / 50,
        "left peak {left_peak} was not half scale"
    );
    assert!(right_peak < full / 100, "right peak {right_peak} was not silent");
}

#[test]
fn an_unknown_insert_is_a_usage_error() {
    let take = TempTake::new("unknown-insert");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--out", take.text(),
        "--insert", "reverb2",
    ]);
    assert_eq!(out.status.code(), Some(2));
    let text = String::from_utf8_lossy(&out.stderr);
    assert!(text.contains("unknown insert"), "stderr: {text}");
    assert!(!take.path.exists(), "a refused take created a file");
}

#[test]
fn channel_flags_outside_record_are_refused() {
    let out = run(&["--run", "--seconds", "0.1", "--gain", "2"]);
    assert_eq!(out.status.code(), Some(2));
    let text = String::from_utf8_lossy(&out.stderr);
    assert!(text.contains("only to --record"), "stderr: {text}");
}

#[test]
fn record_null_can_write_a_tone() {
    let take = TempTake::new("tone");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--tone", "440", "--out",
        take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let bytes = fs::read(&take.path).expect("read the take");
    let data = &bytes[44..];
    assert_eq!(data.len(), 4_800 * 4, "stereo samples");
    assert!(
        data.chunks_exact(2)
            .any(|sample| i16::from_le_bytes([sample[0], sample[1]]) != 0),
        "the take was silent despite --tone"
    );
}
