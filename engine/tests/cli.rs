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
