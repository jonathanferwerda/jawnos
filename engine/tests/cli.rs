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
