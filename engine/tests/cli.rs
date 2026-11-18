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

/// A multi-track base path: every file the take derives from it is removed
/// with it, whether the test passes or not.
struct TempTracks {
    base: PathBuf,
    count: usize,
}

impl TempTracks {
    fn new(name: &str) -> Self {
        Self::with_count(name, 2)
    }

    fn with_count(name: &str, count: usize) -> Self {
        let base = std::env::temp_dir().join(format!(
            "jawn-audio-tracks-{}-{name}.wav",
            std::process::id()
        ));
        let tracks = TempTracks { base, count };
        let _ = fs::remove_file(tracks.base());
        for track in 1..=tracks.count {
            let _ = fs::remove_file(tracks.derived(track));
        }
        tracks
    }

    fn base(&self) -> &std::path::Path {
        &self.base
    }

    fn text(&self) -> &str {
        self.base.to_str().expect("temp path is UTF-8")
    }

    /// The path the engine writes for 1-based `track`.
    fn derived(&self, track: usize) -> PathBuf {
        let stem = self
            .base
            .file_stem()
            .expect("temp path has a stem")
            .to_string_lossy();
        self.base.with_file_name(format!("{stem}-ch{track}.wav"))
    }
}

impl Drop for TempTracks {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.base);
        for track in 1..=self.count {
            let _ = fs::remove_file(self.derived(track));
        }
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
fn a_mono_source_still_writes_a_stereo_take() {
    // The source is one device input; the strip's panned output is stereo, so
    // `--channels 1` is a legal one-track take and the WAV still has two
    // channels.
    let take = TempTake::new("mono-source");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.05", "--channels", "1",
        "--out", take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "channels"), 1.0, "stdout: {text}");

    let bytes = fs::read(&take.path).expect("read the take");
    assert_eq!(u16_at(&bytes, 22), 2, "the WAV is the strip's stereo output");
    assert_eq!(u32_at(&bytes, 40) as usize / 4, 2_400, "frames");
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
        "--insert", "flanger",
    ]);
    assert_eq!(out.status.code(), Some(2));
    let text = String::from_utf8_lossy(&out.stderr);
    assert!(text.contains("unknown insert"), "stderr: {text}");
    assert!(!take.path.exists(), "a refused take created a file");
}

#[test]
fn record_accepts_reverb_under_either_name_and_reports_it() {
    for (index, name) in ["reverb", "reverb2"].iter().enumerate() {
        let take = TempTake::new(&format!("reverb-{index}"));
        let out = run(&[
            "--record", "--backend", "null", "--seconds", "0.05", "--out", take.text(),
            "--insert", name, "--json",
        ]);
        assert!(
            out.status.success(),
            "--insert {name} was refused: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(
            text.contains("\"inserts\":\"reverb\""),
            "--insert {name} did not reach the report: {text}"
        );
        assert_eq!(json_number(&text, "frames"), 2_400.0, "stdout: {text}");
        assert_eq!(json_number(&text, "dropped"), 0.0, "stdout: {text}");
    }
}

#[test]
fn channel_flags_outside_record_are_refused() {
    let out = run(&["--run", "--seconds", "0.1", "--gain", "2"]);
    assert_eq!(out.status.code(), Some(2));
    let text = String::from_utf8_lossy(&out.stderr);
    assert!(text.contains("only to --record"), "stderr: {text}");
}

#[test]
fn record_two_tracks_writes_one_wav_per_input() {
    let takes = TempTracks::new("two");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--rate", "48000", "--tracks", "2",
        "--start-at", "96000", "--out", takes.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(text.trim().lines().count(), 1, "stdout: {text}");
    assert!(text.contains("\"ok\":true"), "stdout: {text}");
    // Both files share the take's transport stamp.
    assert_eq!(json_number(&text, "start_sample"), 96_000.0, "stdout: {text}");

    let first = takes.derived(1);
    let second = takes.derived(2);
    let first_text = first.to_str().expect("UTF-8 path");
    let second_text = second.to_str().expect("UTF-8 path");
    // The top-level contract describes track 1; the array names both files and
    // which input each one records.
    assert!(
        text.contains(&format!("\"path\":\"{first_text}\"")) &&
            text.contains(&format!("\"path\":\"{second_text}\"")),
        "both paths belong in the report: {text}"
    );
    assert!(text.contains("\"tracks\":["), "stdout: {text}");
    assert!(
        text.contains(&format!(
            "{{\"path\":\"{first_text}\",\"input\":0,\"frames\":4800,\"dropped\":0}}"
        )),
        "track 1 entry: {text}"
    );
    assert!(
        text.contains(&format!(
            "{{\"path\":\"{second_text}\",\"input\":1,\"frames\":4800,\"dropped\":0}}"
        )),
        "track 2 entry: {text}"
    );

    assert!(first.exists(), "track 1 file missing");
    assert!(second.exists(), "track 2 file missing");
    let first_bytes = fs::read(&first).expect("read track 1");
    let second_bytes = fs::read(&second).expect("read track 2");
    assert_eq!(u32_at(&first_bytes, 40) as usize / 4, 4_800, "track 1 frames");
    assert_eq!(u32_at(&second_bytes, 40) as usize / 4, 4_800, "track 2 frames");
    assert_eq!(first_bytes.len(), 44 + 4_800 * 4);
    assert_eq!(second_bytes.len(), 44 + 4_800 * 4);
}

#[test]
fn eight_tracks_share_one_start_sample_and_name_their_inputs() {
    let takes = TempTracks::with_count("eight", 8);
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--rate", "48000", "--channels",
        "8", "--tracks", "8", "--inputs", "0,1,2,3,4,5,6,7", "--start-at", "96000", "--out",
        takes.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "channels"), 8.0, "stdout: {text}");
    assert_eq!(json_number(&text, "start_sample"), 96_000.0, "stdout: {text}");
    assert_eq!(
        text.matches("\"start_sample\":96000").count(),
        1,
        "one take is one transport position: {text}"
    );

    for track in 1..=8 {
        let path = takes.derived(track);
        let path_text = path.to_str().expect("UTF-8 path");
        assert!(path.exists(), "track {track} file missing");
        assert!(
            text.contains(&format!(
                "{{\"path\":\"{path_text}\",\"input\":{},\"frames\":4800,\"dropped\":0}}",
                track - 1
            )),
            "track {track} entry: {text}"
        );
        let bytes = fs::read(&path).expect("read the track");
        assert_eq!(u16_at(&bytes, 22), 2, "track {track} is stereo");
        assert_eq!(u32_at(&bytes, 40) as usize / 4, 4_800, "track {track} frames");
    }
}

#[test]
fn inputs_choose_and_order_the_tracks() {
    let takes = TempTracks::new("input-order");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.05", "--tone", "440", "--channels",
        "4", "--tracks", "2", "--inputs", "2,0", "--out", takes.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    let first = text
        .find("\"input\":2")
        .unwrap_or_else(|| panic!("track 1 does not record input 2: {text}"));
    let second = text
        .find("\"input\":0")
        .unwrap_or_else(|| panic!("track 2 does not record input 0: {text}"));
    assert!(first < second, "the report must keep the given order: {text}");

    assert!(takes.derived(1).exists(), "track 1 file missing");
    assert!(takes.derived(2).exists(), "track 2 file missing");
    let first_bytes = fs::read(takes.derived(1)).expect("read track 1");
    let second_bytes = fs::read(takes.derived(2)).expect("read track 2");
    assert_eq!(u32_at(&first_bytes, 40) as usize / 4, 2_400, "track 1 frames");
    assert_eq!(u32_at(&second_bytes, 40) as usize / 4, 2_400, "track 2 frames");
}

#[test]
fn a_track_count_larger_than_the_device_is_a_usage_error() {
    let takes = TempTracks::with_count("nine-of-eight", 9);
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--channels", "8", "--tracks",
        "9", "--out", takes.text(),
    ]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("--tracks"), "stderr: {stderr}");
    assert!(stderr.contains("--channels"), "stderr: {stderr}");
    for track in 1..=9 {
        assert!(!takes.derived(track).exists(), "a refused take created a file");
    }
}

#[test]
fn a_one_channel_device_cannot_record_two_tracks() {
    let takes = TempTracks::new("two-on-one");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--channels", "1", "--tracks",
        "2", "--out", takes.text(),
    ]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("input channel"),
        "the refusal must be a sentence about inputs: {stderr}"
    );
    assert!(!takes.derived(1).exists(), "a refused take created a file");
    assert!(!takes.derived(2).exists(), "a refused take created a file");
}

#[test]
fn an_input_outside_the_granted_channels_is_a_usage_error() {
    let takes = TempTracks::new("input-outside");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--channels", "8", "--tracks",
        "2", "--inputs", "0,9", "--out", takes.text(),
    ]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("input 9"), "stderr: {stderr}");
    assert!(!takes.derived(1).exists(), "a refused take created a file");
    assert!(!takes.derived(2).exists(), "a refused take created a file");
}

#[test]
fn the_input_list_must_have_one_entry_per_track() {
    let take = TempTake::new("input-short-list");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--channels", "4", "--tracks",
        "2", "--inputs", "0", "--out", take.text(),
    ]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("--inputs"), "stderr: {stderr}");
    assert!(!take.path.exists(), "a refused take created a file");
}

#[test]
fn more_than_thirty_two_channels_is_a_usage_error() {
    let take = TempTake::new("too-many-channels");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--channels", "33", "--out",
        take.text(),
    ]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("--channels"), "stderr: {stderr}");
    assert!(!take.path.exists(), "a refused take created a file");
}

#[test]
fn three_tracks_is_a_usage_error() {
    let take = TempTake::new("three-tracks");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--tracks", "3", "--out",
        take.text(),
    ]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("--tracks"), "stderr: {stderr}");
    assert!(!take.path.exists(), "a refused take created a file");
}

#[test]
fn a_track_prefixed_insert_applies_to_that_track_only() {
    let takes = TempTracks::new("insert-one");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--tone", "440", "--tracks", "2",
        "--insert", "1:delay", "--out", takes.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    // Track 1 carries the delay; track 2 is still a wire.
    assert!(text.contains("\"inserts\":\"delay\""), "stdout: {text}");

    let first = fs::read(takes.derived(1)).expect("read track 1");
    let second = fs::read(takes.derived(2)).expect("read track 2");
    assert_ne!(
        first, second,
        "a prefix that applied to both tracks cannot explain different audio"
    );
}

#[test]
fn an_insert_naming_a_missing_track_is_a_usage_error() {
    let take = TempTake::new("insert-missing-track");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--tracks", "2", "--out",
        take.text(), "--insert", "3:delay",
    ]);
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("track 3"), "stderr: {stderr}");
    assert!(!take.path.exists(), "a refused take created a file");
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

// --- overdub: --record with a monitor ---------------------------------------

/// The loudest sample on each channel of a 16-bit stereo take.
fn stereo_peaks(path: &std::path::Path) -> (i32, i32) {
    let bytes = fs::read(path).expect("read the take");
    let data = &bytes[44..];
    let mut left = 0i32;
    let mut right = 0i32;
    for frame in data.chunks_exact(4) {
        left = left.max(i16::from_le_bytes([frame[0], frame[1]]).unsigned_abs() as i32);
        right = right.max(i16::from_le_bytes([frame[2], frame[3]]).unsigned_abs() as i32);
    }
    (left, right)
}

/// A silent 16-bit stereo WAV at an arbitrary rate, for the refusals that are
/// about the monitor's shape rather than its samples.
fn write_silent_wav_at(path: &std::path::Path, rate: u32, frames: u32) {
    let data_len = frames * 4;
    let mut bytes = Vec::with_capacity(44 + data_len as usize);
    bytes.extend_from_slice(b"RIFF");
    bytes.extend_from_slice(&(36 + data_len).to_le_bytes());
    bytes.extend_from_slice(b"WAVEfmt ");
    bytes.extend_from_slice(&16u32.to_le_bytes());
    bytes.extend_from_slice(&1u16.to_le_bytes());
    bytes.extend_from_slice(&2u16.to_le_bytes());
    bytes.extend_from_slice(&rate.to_le_bytes());
    bytes.extend_from_slice(&(rate * 4).to_le_bytes());
    bytes.extend_from_slice(&4u16.to_le_bytes());
    bytes.extend_from_slice(&16u16.to_le_bytes());
    bytes.extend_from_slice(b"data");
    bytes.extend_from_slice(&data_len.to_le_bytes());
    bytes.resize(44 + data_len as usize, 0);
    fs::write(path, bytes).expect("write the silent WAV");
}

#[test]
fn a_monitor_plays_beside_the_take_and_never_enters_it() {
    // The earlier take is silence; the new take records a 440 Hz sine. If the
    // monitor were summed into the capture, the take would be a mix of the two.
    let monitor = record_for_playback("overdub-silent", "0.05");
    let take = TempTake::new("overdub-tone");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.2", "--tone", "440",
        "--monitor", monitor.text(), "--out", take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "frames"), 9_600.0, "stdout: {text}");
    assert_eq!(json_number(&text, "playing"), 1.0, "stdout: {text}");
    assert!(
        json_number(&text, "monitor_frames") > 0.0,
        "the monitor was not reported: {text}"
    );
    assert!(
        !text.contains("monitor_error"),
        "the monitor failed: {text}"
    );

    let (left, right) = stereo_peaks(&take.path);
    assert!(
        left > i16::MAX as i32 / 10,
        "the take lost its input: peaks ({left}, {right})"
    );
}

#[test]
fn a_loud_monitor_stays_out_of_a_silent_take() {
    // The monitor is loud and the capture is silent: any energy in the take
    // would be the monitoring bus leaking into the recording.
    let loud = TempTake::new("overdub-loud");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.05", "--tone", "440", "--out",
        loud.text(), "--json",
    ]);
    assert!(out.status.success(), "the loud fixture failed");

    let take = TempTake::new("overdub-silent-take");
    // `--play --file` is the other spelling of `--monitor`.
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--play", "--file",
        loud.text(), "--out", take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "playing"), 1.0, "stdout: {text}");
    assert_eq!(stereo_peaks(&take.path), (0, 0), "the monitor entered the take");
}

#[test]
fn record_play_without_a_file_is_a_usage_error() {
    let take = TempTake::new("overdub-no-file");
    let out = run(&[
        "--record", "--play", "--backend", "null", "--seconds", "0.1", "--out", take.text(),
    ]);
    assert_eq!(out.status.code(), Some(2));
    let text = String::from_utf8_lossy(&out.stderr);
    assert!(text.contains("--file"), "stderr: {text}");
    assert!(!take.path.exists(), "a refused take created a file");
}

#[test]
fn monitor_without_record_is_a_usage_error() {
    let fixture = TempTake::new("monitor-no-record");
    write_silent_wav_at(&fixture.path, 48_000, 480);
    let out = run(&["--monitor", fixture.text(), "--backend", "null"]);
    assert_eq!(out.status.code(), Some(2));
    let text = String::from_utf8_lossy(&out.stderr);
    assert!(text.contains("--monitor"), "stderr: {text}");
}

#[test]
fn a_monitor_at_another_rate_is_refused_before_the_take_exists() {
    let monitor = TempTake::new("monitor-44k");
    write_silent_wav_at(&monitor.path, 44_100, 441);
    let take = TempTake::new("overdub-wrong-rate");
    let out = run(&[
        "--record", "--backend", "null", "--seconds", "0.1", "--monitor", monitor.text(),
        "--out", take.text(), "--json",
    ]);
    assert_eq!(out.status.code(), Some(1), "the take must not run");
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("\"ok\":false"), "stdout: {text}");
    assert!(text.contains("44100"), "the refusal names the rate: {text}");
    assert!(text.contains("48000"), "the refusal names the take's rate: {text}");
    assert!(!take.path.exists(), "a refused take created a file");
}

// --- --play -----------------------------------------------------------------

/// A take the engine recorded, for playback to read. `--record --backend null`
/// is the fixture: the null take is valid 48 kHz stereo silence, and the test
/// does not depend on any sound card.
fn record_for_playback(name: &str, seconds: &str) -> TempTake {
    let take = TempTake::new(name);
    let out = run(&[
        "--record", "--backend", "null", "--seconds", seconds, "--out", take.text(), "--json",
    ]);
    assert!(
        out.status.success(),
        "recording the fixture failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    take
}

#[test]
fn play_null_prints_the_contract_and_the_seconds_cap() {
    let take = record_for_playback("play-contract", "0.2");
    // No --json: the play mode's report is the JSON line either way.
    let out = run(&[
        "--play", "--file", take.text(), "--seconds", "0.1", "--backend", "null",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(text.trim().lines().count(), 1, "stdout: {text}");
    let expected = "{\"ok\":true,\"backend\":\"null\",\"files\":1,\"frames\":4800,\"rate\":48000,\"seconds\":0.100,\"xruns\":0,\"error\":\"\"}";
    assert_eq!(text.trim(), expected, "the JSON line is the contract");
}

#[test]
fn play_without_seconds_plays_every_frame() {
    let take = record_for_playback("play-whole", "0.2");
    let out = run(&[
        "--play", "--file", take.text(), "--backend", "null", "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "frames"), 9_600.0, "stdout: {text}");
    assert_eq!(json_number(&text, "files"), 1.0, "stdout: {text}");
    assert_eq!(json_number(&text, "rate"), 48_000.0, "stdout: {text}");
}

#[test]
fn play_accepts_json_as_a_no_op() {
    let take = record_for_playback("play-json", "0.1");
    let plain = run(&["--play", "--file", take.text(), "--backend", "null"]);
    let flagged = run(&[
        "--play", "--file", take.text(), "--backend", "null", "--json",
    ]);
    assert!(plain.status.success() && flagged.status.success());
    assert_eq!(plain.stdout, flagged.stdout, "--json is the same line");
}

#[test]
fn play_start_at_skips_frames_of_every_file() {
    let take = record_for_playback("play-start", "0.2");
    let out = run(&[
        "--play", "--file", take.text(), "--start-at", "4800", "--backend", "null", "--json",
    ]);
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "frames"), 4_800.0, "stdout: {text}");
}

#[test]
fn play_a_missing_file_is_exit_one_with_ok_false() {
    let missing = std::env::temp_dir().join(format!(
        "jawn-audio-no-such-take-{}.wav",
        std::process::id()
    ));
    let _ = fs::remove_file(&missing);
    let out = run(&[
        "--play",
        "--file",
        missing.to_str().expect("temp path is UTF-8"),
        "--backend",
        "null",
    ]);
    assert_eq!(out.status.code(), Some(1));
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("\"ok\":false"), "stdout: {text}");
    assert_eq!(json_number(&text, "frames"), 0.0, "stdout: {text}");
    assert!(
        text.contains(missing.to_str().expect("temp path is UTF-8")),
        "the refusal names the file: {text}"
    );
}

#[test]
fn play_gain_pan_and_insert_target_a_one_based_file() {
    let first = record_for_playback("play-target-1", "0.1");
    let second = record_for_playback("play-target-2", "0.1");

    let out = run(&[
        "--play",
        "--file",
        first.text(),
        "--file",
        second.text(),
        "--gain",
        "2:0.5",
        "--pan",
        "2:-1",
        "--insert",
        "1:delay",
        "--backend",
        "null",
        "--json",
    ]);
    assert!(
        out.status.success(),
        "a 2: target on two files must run: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(json_number(&text, "files"), 2.0, "stdout: {text}");

    // The same prefix on a file the playback does not have is a usage error.
    let out = run(&[
        "--play", "--file", first.text(), "--gain", "2:0.5", "--backend", "null",
    ]);
    assert_eq!(out.status.code(), Some(2), "there is only one file");
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("file 2"),
        "the refusal names the file"
    );

    let out = run(&[
        "--play", "--file", first.text(), "--file", second.text(), "--insert", "3:delay",
        "--backend", "null",
    ]);
    assert_eq!(out.status.code(), Some(2));
}

#[test]
fn play_refuses_the_record_only_shape_flags() {
    let take = record_for_playback("play-tracks", "0.1");
    let out = run(&[
        "--play", "--file", take.text(), "--tracks", "2", "--backend", "null",
    ]);
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("only to --record"),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn play_needs_a_file() {
    let out = run(&["--play", "--backend", "null"]);
    assert_eq!(out.status.code(), Some(2));
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("--file"),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
}
