//! The resonant filter and the one-pole loop filter.
//!
//! The voice filter is a topology-preserving-transform state-variable filter
//! (Zavalishin's TPT SVF). It stays stable while its cutoff is swept every
//! sample by the filter envelope and the LFO, which a directly updated biquad
//! would not. Its lowpass response matches the browser's biquad `lowpass`; the
//! bandpass output is scaled by `1/Q` so the peak sits at 0 dB, as Web Audio's
//! `bandpass` does.
//!
//! The pluck loop uses a one-pole lowpass instead of the browser's biquad. A
//! one-pole is the classic Karplus-Strong filter; its phase delay is small and
//! the voice compensates for it when it tunes the delay line.

use crate::patch::FilterKind;
use std::f32::consts::PI;

/// The lowest cutoff the voice filter will use, in Hz.
pub(crate) const MIN_CUTOFF: f32 = 20.0;
/// The highest cutoff the voice filter will use, in Hz.
pub(crate) const MAX_CUTOFF: f32 = 18000.0;

/// Clamp a cutoff to a range that keeps `tan(pi * fc / rate)` finite.
pub(crate) fn clamp_cutoff(cutoff: f32, rate: f32) -> f32 {
    let high = MAX_CUTOFF.min(rate * 0.45);
    if cutoff.is_finite() {
        cutoff.clamp(MIN_CUTOFF.min(high), high)
    } else {
        1000.0
    }
}

/// A TPT state-variable filter.
pub(crate) struct Svf {
    ic1: f32,
    ic2: f32,
}

impl Svf {
    /// A filter with no stored energy.
    pub fn new() -> Self {
        Svf { ic1: 0.0, ic2: 0.0 }
    }

    /// Drop the filter state, as a freshly created browser filter node does.
    pub fn reset(&mut self) {
        self.ic1 = 0.0;
        self.ic2 = 0.0;
    }

    /// Filter one sample at `cutoff` Hz with resonance `q`.
    pub fn process(&mut self, x: f32, cutoff: f32, q: f32, rate: f32, kind: FilterKind) -> f32 {
        let fc = clamp_cutoff(cutoff, rate);
        let g = (PI * fc / rate).tan();
        let k = 1.0 / q.clamp(0.0001, 30.0);
        let a1 = 1.0 / (1.0 + g * (g + k));
        let a2 = g * a1;
        let a3 = g * a2;

        let v3 = x - self.ic2;
        let v1 = a1 * self.ic1 + a2 * v3;
        let v2 = self.ic2 + a2 * self.ic1 + a3 * v3;
        self.ic1 = 2.0 * v1 - self.ic1;
        self.ic2 = 2.0 * v2 - self.ic2;

        match kind {
            FilterKind::Lowpass => v2,
            // v1 peaks at Q; scaling by k puts the peak at unity.
            FilterKind::Bandpass => v1 * k,
        }
    }
}

/// A one-pole lowpass, the pluck loop's damping filter.
pub(crate) struct OnePole {
    y: f32,
}

impl OnePole {
    /// A filter at rest.
    pub fn new() -> Self {
        OnePole { y: 0.0 }
    }

    /// Forget the previous sample.
    pub fn reset(&mut self) {
        self.y = 0.0;
    }

    /// The coefficient for `cutoff` Hz at `rate`, in `0..1`.
    pub fn coefficient(cutoff: f32, rate: f32) -> f32 {
        let fc = clamp_cutoff(cutoff, rate);
        (1.0 - (-2.0 * PI * fc / rate).exp()).clamp(0.0, 1.0)
    }

    /// Filter one sample with a coefficient from [`OnePole::coefficient`].
    pub fn process(&mut self, x: f32, coefficient: f32) -> f32 {
        self.y += coefficient * (x - self.y);
        self.y
    }
}

/// The phase delay, in samples, of a one-pole at low frequencies.
///
/// The pluck voice subtracts this from its delay length so the loop still rings
/// at the requested pitch. Returns zero for a degenerate coefficient.
pub(crate) fn one_pole_delay(coefficient: f32) -> f32 {
    if coefficient <= 0.0 {
        return 0.0;
    }
    (1.0 - coefficient) / coefficient
}

#[cfg(test)]
mod tests {
    use super::{one_pole_delay, OnePole, Svf};
    use crate::patch::FilterKind;

    #[test]
    fn lowpass_passes_dc() {
        let mut f = Svf::new();
        let mut out = 0.0;
        for _ in 0..1000 {
            out = f.process(1.0, 5000.0, 0.707, 48000.0, FilterKind::Lowpass);
        }
        assert!((out - 1.0).abs() < 1e-3);
    }

    #[test]
    fn lowpass_rejects_high_frequencies() {
        let mut f = Svf::new();
        let mut sum = 0.0;
        for i in 0..48000 {
            let x = ((i as f32 / 48000.0) * 2.0 * std::f32::consts::PI * 10000.0).sin();
            sum += f.process(x, 200.0, 0.707, 48000.0, FilterKind::Lowpass).abs();
        }
        assert!(sum / 48000.0 < 0.1);
    }

    #[test]
    fn stays_finite_when_swept() {
        let mut f = Svf::new();
        for i in 0..48000 {
            let cutoff = 40.0 + 17000.0 * (i as f32 / 48000.0);
            let y = f.process(1.0, cutoff, 20.0, 48000.0, FilterKind::Bandpass);
            assert!(y.is_finite());
            assert!(y.abs() < 100.0);
        }
    }

    #[test]
    fn one_pole_settles() {
        let mut lp = OnePole::new();
        let c = OnePole::coefficient(4000.0, 48000.0);
        let mut y = 0.0;
        for _ in 0..1000 {
            y = lp.process(1.0, c);
        }
        assert!((y - 1.0).abs() < 1e-3);
        assert!((one_pole_delay(c) - (1.0 - c) / c).abs() < 1e-6);
    }
}
