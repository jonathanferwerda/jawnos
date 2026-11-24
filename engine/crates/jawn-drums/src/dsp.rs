//! The offline renderer: one voice spec into a finite mono buffer.
//!
//! This is the Rust equivalent of `studioDrumsRenderVoice` in
//! `public/js/manager/studio/11_drums.js`. It runs when a kit is loaded, never
//! in the engine's audio callback, so it may allocate freely.
//!
//! The timing model follows the browser's offline context:
//!
//! - a tone starts at the first sample at or after `at` and stops at
//!   `at + max(dur, env) + 0.02`;
//! - its frequency sweeps exponentially from `from_hz` to `to_hz` over `dur` and
//!   holds `to_hz` afterwards;
//! - its gain envelope rises from `0.0001` to the peak over 3 ms, then falls
//!   exponentially to `0.0001` over `env` (at least 4 ms), and stays at that
//!   near-zero tail until the oscillator stops;
//! - each noise burst plays the same seeded noise sequence from its start,
//!   through its own biquad and its own envelope.
//!
//! The noise stream is a fixed SplitMix64 generator. Changing [`DEFAULT_SEED`]
//! or [`voice_seed`] changes the rendered audio but nothing else, which is why
//! the determinism test can pin it.

use crate::{FilterKind, NoiseSpec, ToneSpec, Voice, VoiceSpec, Wave};
use std::f64::consts::TAU;

/// The seed [`render_voice`] uses when the caller does not name one.
pub const DEFAULT_SEED: u64 = 0x4A41_574E_4F53_0001;

/// The noise seed for one voice of a kit.
///
/// Each voice draws from its own stream so that, for example, a snare and a hat
/// in the same kit do not share the same noise. The values are stable: a kit
/// rendered on any machine with this crate always produces the same samples.
pub fn voice_seed(voice: Voice) -> u64 {
    DEFAULT_SEED.wrapping_add(
        (voice.index() as u64 + 1).wrapping_mul(0x9E37_79B9_7F4A_7C15),
    )
}

/// Render a voice spec at `rate` hertz using [`DEFAULT_SEED`].
///
/// The returned buffer is `ceil(rate * length_seconds)` samples long, or empty
/// when `rate` is zero. A non-positive or non-finite length falls back to 0.6
/// seconds, mirroring the browser's `spec.length || 0.6`.
pub fn render_voice(spec: &VoiceSpec, rate: u32) -> Vec<f32> {
    render_voice_with_seed(spec, rate, DEFAULT_SEED)
}

/// Render a voice spec with an explicit noise seed.
///
/// [`Machine::load_kit`](crate::Machine::load_kit) passes [`voice_seed`] so the
/// eight voices of a kit each get their own noise; [`render_voice`] is the
/// single-spec convenience with [`DEFAULT_SEED`].
pub fn render_voice_with_seed(spec: &VoiceSpec, rate: u32, seed: u64) -> Vec<f32> {
    if rate == 0 {
        return Vec::new();
    }
    let rate_f = rate as f32;
    let length = sanitise_length(spec.length_seconds);
    let frames = sample_index(length, rate_f);
    let mut out = vec![0.0f32; frames];
    if frames == 0 {
        return out;
    }

    for tone in &spec.tones {
        render_tone(&mut out, tone, rate_f);
    }

    if !spec.noise.is_empty() {
        // The browser makes one noise buffer per voice and plays every burst
        // from its beginning. Generate it once so the bursts share the stream.
        let mut rng = SplitMix64::new(seed);
        let mut noise = Vec::with_capacity(frames);
        for _ in 0..frames {
            noise.push(rng.next_bipolar());
        }
        for burst in &spec.noise {
            render_noise(&mut out, &noise, burst, rate_f, length);
        }
    }

    out
}

/// Add one tone into `out`.
fn render_tone(out: &mut [f32], tone: &ToneSpec, rate: f32) {
    let at = sanitise_offset(tone.at);
    let dur = sanitise_time(tone.dur);
    let env = effective_env(tone);
    let start = sample_index(at, rate).min(out.len());
    // The browser stops the oscillator a little after the envelope's end.
    let stop_at = at + dur.max(tone.env.max(0.0)) + 0.02;
    let end = sample_index(stop_at, rate).min(out.len());
    if start >= end {
        return;
    }
    let from_hz = sanitise_from(tone.from_hz);
    let to_hz = sanitise_to(tone.to_hz);
    let peak = sanitise_gain(tone.gain);
    let mut phase = 0.0f32;
    for i in start..end {
        let t = i as f32 / rate;
        let hz = sweep_hz(from_hz, to_hz, at, dur, t);
        let sample = wave_value(tone.wave, phase) * envelope(t, at, peak, env);
        out[i] += sample;
        phase = (phase + hz / rate).fract();
    }
}

/// Add one filtered noise burst into `out`. `noise` is the voice's noise buffer,
/// read from offset zero for every burst, as the browser does.
fn render_noise(
    out: &mut [f32],
    noise: &[f32],
    burst: &NoiseSpec,
    rate: f32,
    length: f32,
) {
    let at = sanitise_offset(burst.at);
    let dur = sanitise_time(burst.dur);
    let start = sample_index(at, rate).min(out.len());
    if start >= out.len() {
        return;
    }
    // The source plays for `dur + 0.02`, but never past the voice's length.
    let play_for = (dur + 0.02).min(length);
    let end = sample_index(at + play_for, rate).min(out.len());
    if start >= end {
        return;
    }
    let mut filter = Biquad::new(burst.filter, burst.freq, burst.q, rate);
    let peak = sanitise_gain(burst.gain);
    for i in start..end {
        let t = i as f32 / rate;
        let input = noise[i - start] as f64;
        let filtered = filter.process(input);
        out[i] += (filtered as f32) * envelope(t, at, peak, dur);
    }
}

/// The browser's `spec.length || 0.6`, with non-finite values treated as zero.
fn sanitise_length(seconds: f32) -> f32 {
    if seconds.is_finite() && seconds > 0.0 {
        seconds
    } else {
        0.6
    }
}

fn sanitise_time(seconds: f32) -> f32 {
    if seconds.is_finite() && seconds > 0.0 {
        seconds
    } else {
        0.0
    }
}

fn sanitise_offset(seconds: f32) -> f32 {
    if seconds.is_finite() && seconds > 0.0 {
        seconds
    } else {
        0.0
    }
}

fn sanitise_from(hz: f32) -> f32 {
    if hz.is_finite() {
        hz.max(0.001)
    } else {
        0.001
    }
}

fn sanitise_to(hz: f32) -> f32 {
    if hz.is_finite() {
        hz.max(20.0)
    } else {
        20.0
    }
}

fn sanitise_gain(gain: f32) -> f32 {
    if gain.is_finite() {
        gain.max(0.0002)
    } else {
        0.0002
    }
}

/// `tone.env || tone.dur` in the browser: zero and invalid values fall back.
fn effective_env(tone: &ToneSpec) -> f32 {
    if tone.env.is_finite() && tone.env > 0.0 {
        tone.env
    } else {
        sanitise_time(tone.dur)
    }
}

/// The sample index at or after `seconds`.
fn sample_index(seconds: f32, rate: f32) -> usize {
    if !seconds.is_finite() || seconds <= 0.0 {
        return 0;
    }
    let index = (seconds as f64 * rate as f64).ceil();
    if index >= usize::MAX as f64 {
        usize::MAX
    } else {
        index as usize
    }
}

/// The exponential frequency sweep; the browser holds `from` before `at` and
/// `to` after `at + dur`.
fn sweep_hz(from: f32, to: f32, at: f32, dur: f32, t: f32) -> f32 {
    if t <= at || dur <= 0.0 {
        return from;
    }
    let fraction = ((t - at) / dur).clamp(0.0, 1.0);
    from * (to / from).powf(fraction)
}

/// The browser's three-point exponential gain envelope.
fn envelope(t: f32, at: f32, peak: f32, env: f32) -> f32 {
    const FLOOR: f32 = 0.0001;
    const RISE: f32 = 0.003;
    let rise_end = at + RISE;
    let fall_end = at + env.max(0.004);
    if t < at {
        0.0
    } else if t <= rise_end {
        let fraction = (t - at) / RISE;
        FLOOR * (peak / FLOOR).powf(fraction)
    } else if t <= fall_end {
        let span = fall_end - rise_end;
        let fraction = (t - rise_end) / span;
        peak * (FLOOR / peak).powf(fraction)
    } else {
        FLOOR
    }
}

/// One sample of a naive oscillator at `phase` in `0.0..1.0`.
///
/// These are not band-limited; see the crate docs for the deliberate
/// divergence from the browser's `PeriodicWave`s.
fn wave_value(wave: Wave, phase: f32) -> f32 {
    match wave {
        Wave::Sine => (TAU as f32 * phase).sin(),
        Wave::Triangle => {
            if phase < 0.25 {
                phase * 4.0
            } else if phase < 0.75 {
                2.0 - phase * 4.0
            } else {
                phase * 4.0 - 4.0
            }
        }
        Wave::Square => {
            if phase < 0.5 {
                1.0
            } else {
                -1.0
            }
        }
        Wave::Sawtooth => phase * 2.0 - 1.0,
    }
}

/// A fixed, dependency-free SplitMix64 stream.
struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    fn new(seed: u64) -> Self {
        SplitMix64 { state: seed }
    }

    fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A value in `-1.0..1.0` from the top 24 bits.
    fn next_bipolar(&mut self) -> f32 {
        let value = (self.next_u64() >> 40) as u32 as f32 / 16_777_216.0;
        value * 2.0 - 1.0
    }
}

/// A direct-form-I RBJ biquad.
///
/// Q is linear for every filter type. Frequencies are clamped to
/// `10 Hz ..= 0.45 * rate` so a bad spec cannot make the filter unstable.
struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

impl Biquad {
    fn new(kind: FilterKind, freq: f32, q: f32, rate: f32) -> Self {
        let rate = rate as f64;
        let freq = if freq.is_finite() {
            (freq as f64).clamp(10.0, rate * 0.45)
        } else {
            10.0
        };
        let q = if q.is_finite() {
            (q as f64).max(0.05)
        } else {
            1.0
        };
        let w0 = TAU * freq / rate;
        let cos = w0.cos();
        let sin = w0.sin();
        let alpha = sin / (2.0 * q);
        let (b0, b1, b2, a0, a1, a2) = match kind {
            FilterKind::Lowpass => {
                let b1 = 1.0 - cos;
                ((1.0 - cos) / 2.0, b1, (1.0 - cos) / 2.0, 1.0 + alpha, -2.0 * cos, 1.0 - alpha)
            }
            FilterKind::Highpass => {
                let b1 = -(1.0 + cos);
                ((1.0 + cos) / 2.0, b1, (1.0 + cos) / 2.0, 1.0 + alpha, -2.0 * cos, 1.0 - alpha)
            }
            FilterKind::Bandpass => {
                // Constant 0 dB peak gain, like the browser's bandpass.
                (alpha, 0.0, -alpha, 1.0 + alpha, -2.0 * cos, 1.0 - alpha)
            }
        };
        let inv = 1.0 / a0;
        Biquad {
            b0: b0 * inv,
            b1: b1 * inv,
            b2: b2 * inv,
            a1: a1 * inv,
            a2: a2 * inv,
            x1: 0.0,
            x2: 0.0,
            y1: 0.0,
            y2: 0.0,
        }
    }

    fn process(&mut self, x: f64) -> f64 {
        let y = self.b0 * x
            + self.b1 * self.x1
            + self.b2 * self.x2
            - self.a1 * self.y1
            - self.a2 * self.y2;
        self.x2 = self.x1;
        self.x1 = x;
        self.y2 = self.y1;
        self.y1 = y;
        if y.is_finite() {
            y
        } else {
            self.x1 = 0.0;
            self.x2 = 0.0;
            self.y1 = 0.0;
            self.y2 = 0.0;
            0.0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{NoiseSpec, ToneSpec, VoiceSpec, Wave};

    fn tone_spec() -> VoiceSpec {
        VoiceSpec::new(0.2).with_tones(vec![ToneSpec::new(
            Wave::Sine,
            200.0,
            100.0,
            0.05,
            0.8,
            0.1,
        )])
    }

    #[test]
    fn a_rendered_voice_has_the_spec_length() {
        let spec = VoiceSpec::new(0.55);
        let rendered = render_voice(&spec, 44_100);
        assert_eq!(rendered.len(), (0.55f64 * 44_100.0).ceil() as usize);
    }

    #[test]
    fn rendering_is_deterministic() {
        let spec = VoiceSpec::new(0.2).with_noise(vec![NoiseSpec::new(
            FilterKind::Bandpass,
            1200.0,
            1.2,
            0.1,
            0.7,
        )]);
        let a = render_voice(&spec, 44_100);
        let b = render_voice(&spec, 44_100);
        assert_eq!(a, b);
        assert!(a.iter().any(|sample| sample.abs() > 0.01));
    }

    #[test]
    fn a_different_seed_makes_different_noise() {
        let spec = VoiceSpec::new(0.2).with_noise(vec![NoiseSpec::new(
            FilterKind::Highpass,
            5000.0,
            1.0,
            0.1,
            0.7,
        )]);
        let a = render_voice_with_seed(&spec, 44_100, 1);
        let b = render_voice_with_seed(&spec, 44_100, 2);
        assert_ne!(a, b);
    }

    #[test]
    fn a_delayed_tone_is_silent_before_its_offset() {
        let spec = VoiceSpec::new(0.2).with_tones(vec![ToneSpec::new(
            Wave::Square,
            400.0,
            400.0,
            0.02,
            0.5,
            0.02,
        )
        .with_at(0.1)]);
        let rendered = render_voice(&spec, 44_100);
        let offset = (0.1f32 * 44_100.0).ceil() as usize;
        assert!(rendered[..offset].iter().all(|sample| *sample == 0.0));
        assert!(rendered[offset..].iter().any(|sample| sample.abs() > 0.001));
    }

    #[test]
    fn every_sample_is_finite() {
        let spec = VoiceSpec::new(0.3)
            .with_tones(vec![ToneSpec::new(
                Wave::Sawtooth,
                90.0,
                28.0,
                0.2,
                1.2,
                0.3,
            )])
            .with_noise(vec![NoiseSpec::new(
                FilterKind::Lowpass,
                20_000.0,
                4.0,
                0.3,
                1.0,
            )]);
        let rendered = render_voice(&spec, 48_000);
        assert!(rendered.iter().all(|sample| sample.is_finite()));
    }

    #[test]
    fn a_zero_rate_renders_nothing() {
        assert!(render_voice(&tone_spec(), 0).is_empty());
    }
}
