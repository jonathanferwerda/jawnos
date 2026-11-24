//! Oscillator shapes and the phase accumulator.
//!
//! The four harmonic tables are copied verbatim from `HARMONICS` in
//! `public/js/manager/synth/01_engine.js`. The browser hands them to
//! `createPeriodicWave`, which band-limits and peak-normalises them; here they
//! are summed directly and divided by the sum of the absolute coefficients,
//! which is a safe upper bound rather than a peak normalisation. See the crate
//! docs for that difference.
//!
//! The sawtooth and square are band-limited with polyBLEP; the aliasing the
//! browser avoids with its wavetables would otherwise be clearly audible on
//! high notes. Triangle and the harmonic tables are summed as written.

use crate::patch::Wave;
use std::f32::consts::TAU;

/// `HARMONICS.piano` in `01_engine.js:25`.
const PIANO: [f32; 11] = [1.0, 0.62, 0.42, 0.29, 0.2, 0.14, 0.1, 0.07, 0.05, 0.035, 0.025];
/// `HARMONICS.organ` in `01_engine.js:26`.
const ORGAN: [f32; 7] = [1.0, 0.0, 0.5, 0.0, 0.35, 0.0, 0.25];
/// `HARMONICS.bell` in `01_engine.js:27`.
const BELL: [f32; 12] = [1.0, 0.0, 0.0, 0.55, 0.0, 0.0, 0.0, 0.35, 0.0, 0.0, 0.0, 0.25];
/// `HARMONICS.strings` in `01_engine.js:28`.
const STRINGS: [f32; 8] = [1.0, 0.7, 0.55, 0.45, 0.35, 0.28, 0.22, 0.16];

/// The harmonic recipe for a table wave, if `wave` is one.
fn harmonics(wave: Wave) -> Option<&'static [f32]> {
    match wave {
        Wave::Piano => Some(&PIANO),
        Wave::Organ => Some(&ORGAN),
        Wave::Bell => Some(&BELL),
        Wave::Strings => Some(&STRINGS),
        _ => None,
    }
}

/// A phase accumulator for one oscillator.
pub(crate) struct Oscillator {
    phase: f32,
}

impl Oscillator {
    /// A silent oscillator at phase zero.
    pub fn new() -> Self {
        Oscillator { phase: 0.0 }
    }

    /// Restart at phase zero, as a freshly created browser oscillator does.
    pub fn reset(&mut self) {
        self.phase = 0.0;
    }

    /// Produce one sample and advance the phase.
    pub fn next(&mut self, wave: Wave, freq: f32, rate: f32) -> f32 {
        let dt = (freq / rate).clamp(0.0, 0.45);
        let value = sample(wave, self.phase, dt);
        self.phase += dt;
        if self.phase >= 1.0 {
            self.phase -= 1.0;
        }
        value
    }
}

/// One sample of `wave` at phase `t` (0..1), with phase step `dt`.
fn sample(wave: Wave, t: f32, dt: f32) -> f32 {
    match wave {
        Wave::Sine => (TAU * t).sin(),
        Wave::Sawtooth => 2.0 * t - 1.0 - poly_blep(t, dt),
        Wave::Square => {
            let mut v = if t < 0.5 { 1.0 } else { -1.0 };
            v += poly_blep(t, dt);
            v -= poly_blep(if t < 0.5 { t + 0.5 } else { t - 0.5 }, dt);
            v
        }
        Wave::Triangle => 1.0 - 4.0 * (t - 0.5).abs(),
        Wave::Piano | Wave::Organ | Wave::Bell | Wave::Strings => {
            let table = harmonics(wave).unwrap_or(&[]);
            let mut sum = 0.0;
            let mut norm = 0.0;
            for (i, &h) in table.iter().enumerate() {
                sum += h * (TAU * (i + 1) as f32 * t).sin();
                norm += h.abs();
            }
            if norm > 0.0 {
                sum / norm
            } else {
                sum
            }
        }
    }
}

/// The polyBLEP correction for a discontinuity at phase 0.
fn poly_blep(t: f32, dt: f32) -> f32 {
    if dt <= 0.0 {
        return 0.0;
    }
    if t < dt {
        let x = t / dt;
        2.0 * x - x * x - 1.0
    } else if t > 1.0 - dt {
        let x = (t - 1.0) / dt;
        x * x + 2.0 * x + 1.0
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::{poly_blep, sample};
    use crate::patch::Wave;

    #[test]
    fn shapes_are_finite_and_bounded() {
        for wave in Wave::ALL {
            for i in 0..100 {
                let v = sample(wave, i as f32 / 100.0, 0.01);
                assert!(v.is_finite(), "{} at {i}", wave.name());
                assert!(v.abs() < 4.0, "{} at {i}: {v}", wave.name());
            }
        }
    }

    #[test]
    fn blep_is_silent_in_the_middle() {
        assert_eq!(poly_blep(0.5, 0.01), 0.0);
        assert!(poly_blep(0.0001, 0.01).is_finite());
    }

    #[test]
    fn table_waves_start_at_zero() {
        for wave in [Wave::Piano, Wave::Organ, Wave::Bell, Wave::Strings] {
            assert!(sample(wave, 0.0, 0.01).abs() < 1e-6);
        }
    }
}
