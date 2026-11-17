//! The patch-cable round trip: one click out, the same signal back in.
//!
//! The number this reports is the engine's monitoring latency, so the report
//! carries its own uncertainty in `precision_samples` instead of pretending a
//! sample-exact answer. Raw ALSA gives two unlinked streams (capture started
//! first, playback second), so the first captured click can land up to one
//! period either side of the playback start; JACK calls back on one boundary,
//! so its uncertainty is one sample (docs/studio-audio-roadmap.md P1).

use crate::backends::BackendKind;

/// A click at half scale is inaudible through a patched-back input and still
/// far above a quiet room.
pub const CLICK_AMPLITUDE: f32 = 0.5;
/// A half-sine bump, ~0.67 ms at 48 kHz: a few samples, not a tone.
pub const CLICK_FRAMES: usize = 32;
/// The quietest threshold we will trust when the room is silent.
///
/// Measured, not guessed: a headphone output at ~35% patched into the
/// instrument input at ~40% returns the click at about 0.004 of full scale,
/// while a silent input reads 0.0000. The old 0.02 floor sat 20 dB above the
/// signal and reported "no signal" for a cable that works.
pub const MIN_THRESHOLD: f32 = 0.001;
/// The loudest threshold we will use, so a hum cannot mask the click.
pub const MAX_THRESHOLD: f32 = 0.25;
/// Ten milliseconds is enough to learn a room's noise floor before the click.
pub const PRE_ROLL_MS: u32 = 10;
/// Give up after one second with no signal above the threshold.
pub const CAPTURE_SECONDS: u32 = 1;

/// The click, as mono `f32`. A half sine from zero to zero, so it has no DC
/// step into the interface and no audible tail.
pub fn click_frames() -> Vec<f32> {
    (0..CLICK_FRAMES)
        .map(|index| {
            let phase = std::f32::consts::PI * index as f32 / (CLICK_FRAMES - 1) as f32;
            CLICK_AMPLITUDE * phase.sin()
        })
        .collect()
}

/// Threshold four times the measured noise floor, bounded so silence still
/// gets a real threshold and a loud hum cannot hide the click.
pub fn threshold(noise_peak: f32) -> f32 {
    (noise_peak.abs() * 4.0).clamp(MIN_THRESHOLD, MAX_THRESHOLD)
}

/// Milliseconds for `samples` at `rate`, before display rounding.
pub fn milliseconds(samples: u64, rate: u32) -> f64 {
    if rate == 0 {
        return 0.0;
    }
    samples as f64 / rate as f64 * 1000.0
}

/// One `--loopback` result, in the exact shape the JSON contract names.
#[derive(Debug, Clone)]
pub struct LoopbackReport {
    pub ok: bool,
    pub backend: &'static str,
    pub device: String,
    pub rate: u32,
    pub period: usize,
    pub buffer: usize,
    pub samples: Option<u64>,
    pub ms: Option<f64>,
    pub precision_samples: u64,
    pub method: &'static str,
    pub error: String,
}

impl LoopbackReport {
    pub fn success(
        backend: &'static str,
        device: &str,
        rate: u32,
        period: usize,
        buffer: usize,
        samples: u64,
        precision_samples: u64,
        method: &'static str,
    ) -> Self {
        LoopbackReport {
            ok: true,
            backend,
            device: device.to_string(),
            rate,
            period,
            buffer,
            samples: Some(samples),
            ms: Some(milliseconds(samples, rate)),
            precision_samples,
            method,
            error: String::new(),
        }
    }

    pub fn failure(
        backend: &'static str,
        device: &str,
        rate: u32,
        period: usize,
        buffer: usize,
        precision_samples: u64,
        method: &'static str,
        error: impl Into<String>,
    ) -> Self {
        LoopbackReport {
            ok: false,
            backend,
            device: device.to_string(),
            rate,
            period,
            buffer,
            samples: None,
            ms: None,
            precision_samples,
            method,
            error: error.into(),
        }
    }

    /// The null backend: success, but with no signal path to measure. It exists
    /// so a machine without hardware can still exercise the command and its
    /// parser.
    pub fn null(rate: u32, period: usize, buffer: usize) -> Self {
        let mut report = LoopbackReport::success("null", "null", rate, period, buffer, 0, 0, "null");
        report.error =
            "no signal path exists: the null backend does not touch hardware".to_string();
        report
    }

    pub fn to_json(&self) -> String {
        format!(
            "{{\"ok\":{},\"backend\":\"{}\",\"device\":\"{}\",\"rate\":{},\"period\":{},\"buffer\":{},\"samples\":{},\"ms\":{},\"precision_samples\":{},\"method\":\"{}\",\"error\":\"{}\"}}",
            self.ok,
            json_escape(self.backend),
            json_escape(&self.device),
            self.rate,
            self.period,
            self.buffer,
            option_u64(self.samples),
            option_ms(self.ms),
            self.precision_samples,
            json_escape(self.method),
            json_escape(&self.error)
        )
    }

    pub fn prose(&self) -> String {
        if !self.ok {
            return format!(
                "loopback {} {}: failed: {}",
                self.backend, self.device, self.error
            );
        }
        if self.samples == Some(0) {
            return format!(
                "loopback {} {}: no measurement ({})",
                self.backend, self.device, self.error
            );
        }
        format!(
            "loopback {} {}: {} samples ({:.4} ms) round trip, precision +/- {} samples, method {}",
            self.backend,
            self.device,
            self.samples.unwrap_or(0),
            self.ms.unwrap_or(0.0),
            self.precision_samples,
            self.method
        )
    }
}

fn option_u64(value: Option<u64>) -> String {
    match value {
        Some(number) => number.to_string(),
        None => "null".to_string(),
    }
}

fn option_ms(value: Option<f64>) -> String {
    match value {
        Some(number) => format!("{number:.4}"),
        None => "null".to_string(),
    }
}

/// Minimal JSON string escaping: errors can carry a device name or an ALSA
/// sentence, and both may contain a quote or a backslash.
pub fn json_escape(text: &str) -> String {
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

/// Run the requested measurement. `period` and `buffer` reach the report as
/// requested; the real backend may grant different values, and says so through
/// `precision_samples` (and, for `--run`, through the reported frames).
pub fn measure(
    backend: BackendKind,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> LoopbackReport {
    match backend {
        BackendKind::Null => LoopbackReport::null(rate, period, buffer),
        BackendKind::Alsa => measure_alsa("alsa", device, rate, period, buffer),
        BackendKind::PipeWire => measure_alsa("pipewire", device, rate, period, buffer),
        BackendKind::Jack => measure_jack(device, rate, period, buffer),
    }
}

#[cfg(feature = "alsa")]
fn measure_alsa(
    backend: &'static str,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> LoopbackReport {
    crate::alsa_device::loopback(backend, device, rate, period, buffer)
}

#[cfg(not(feature = "alsa"))]
fn measure_alsa(
    backend: &'static str,
    device: &str,
    rate: u32,
    period: usize,
    buffer: usize,
) -> LoopbackReport {
    LoopbackReport::failure(
        backend,
        device,
        rate,
        period,
        buffer,
        period as u64,
        "unlinked",
        "this build has no ALSA backend; rebuild with --features alsa",
    )
}

#[cfg(feature = "jack")]
fn measure_jack(device: &str, rate: u32, period: usize, buffer: usize) -> LoopbackReport {
    crate::jack_device::loopback(device, rate, period, buffer)
}

#[cfg(not(feature = "jack"))]
fn measure_jack(device: &str, rate: u32, period: usize, buffer: usize) -> LoopbackReport {
    LoopbackReport::failure(
        "jack",
        device,
        rate,
        period,
        buffer,
        1,
        "callback",
        "this build has no JACK backend; rebuild with --features jack",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_click_is_a_half_sine_at_half_scale() {
        let click = click_frames();
        assert_eq!(click.len(), CLICK_FRAMES);
        assert!(click[0].abs() < 1e-6, "starts at zero");
        assert!(click[CLICK_FRAMES - 1].abs() < 1e-6, "ends at zero");
        let loudest = click.iter().fold(0.0f32, |peak, sample| peak.max(sample.abs()));
        assert!(loudest > 0.49 && loudest <= CLICK_AMPLITUDE, "peak {loudest}");
    }

    #[test]
    fn the_threshold_stays_above_the_noise_and_below_the_click() {
        assert_eq!(threshold(0.0), MIN_THRESHOLD);
        assert_eq!(threshold(0.001), 0.004);
        assert_eq!(threshold(10.0), MAX_THRESHOLD);
        assert!(threshold(10.0) < CLICK_AMPLITUDE);
    }

    #[test]
    fn milliseconds_divide_by_the_rate() {
        assert!((milliseconds(152, 48_000) - 3.166_666_7).abs() < 1e-6);
        assert_eq!(milliseconds(1, 0), 0.0);
    }

    #[test]
    fn the_null_report_is_the_contract_a_parser_can_rely_on() {
        let report = LoopbackReport::null(48_000, 64, 256);
        assert!(report.ok);
        assert_eq!(report.samples, Some(0));
        assert_eq!(report.precision_samples, 0);
        assert_eq!(report.method, "null");
        assert!(report.error.contains("no signal path"));
        let json = report.to_json();
        assert!(json.contains("\"ok\":true"), "{json}");
        assert!(json.contains("\"samples\":0"), "{json}");
        assert!(json.contains("\"method\":\"null\""), "{json}");
        assert_eq!(json.lines().count(), 1, "{json}");
    }

    #[test]
    fn a_failure_serialises_samples_and_ms_as_null() {
        let report = LoopbackReport::failure(
            "alsa",
            "hw:1,0",
            48_000,
            64,
            256,
            64,
            "unlinked",
            "device is busy",
        );
        let json = report.to_json();
        assert!(json.contains("\"ok\":false"), "{json}");
        assert!(json.contains("\"samples\":null"), "{json}");
        assert!(json.contains("\"ms\":null"), "{json}");
        assert!(json.contains("\"error\":\"device is busy\""), "{json}");
    }

    #[test]
    fn json_escapes_a_quote() {
        assert_eq!(json_escape("a \"b\" \\ c"), "a \\\"b\\\" \\\\ c");
    }
}
