//! The `equalizer` pedal: a Baxandall bass/treble tone network with a mid
//! control, separate from the channel's own `tone` stack.
//!
//! A real hi-fi tone control is not three filters added together: the bass and
//! treble knobs move two shelving arms of one feedback network, so each knob
//! also re-shapes the other arm's transition and the middle of the band moves
//! with both. This pedal models that network as one coupled second-order
//! section (the bass/treble pair) followed by a peaking section for the mid
//! knob.
//!
//! ## The circuit
//!
//! The bass/treble pair is the idealised transfer of an active Baxandall
//! stage: a first-order low shelf and a first-order high shelf that share the
//! same feedback loop. Its analog prototype is
//!
//! ```text
//!         (s + wL*B) * (T*s + wH)
//! H(s) = --------------------------
//!         (s + pL) * (s + pH)
//! ```
//!
//! where `B = 10^(low_db/20)` is the DC gain, `T = 10^(high_db/20)` the
//! high-frequency gain, and `wL`, `wH` are the bass and treble corners. At
//! `low = high = 0` the numerator and denominator are identical, so the
//! section is exactly transparent.
//!
//! In the real network the two arms load each other through the shared
//! feedback node. We model that as a shift of the two poles by the bass/treble
//! *balance*, keeping their product `wL*wH` so the plateaus stay exactly `B`
//! and `T`:
//!
//! ```text
//! r = (B/T)^(LOOP_COUPLING/2)   pL = wL*r   pH = wH/r
//! ```
//!
//! `LOOP_COUPLING` is a tuning constant, not a component value: at 0 the arms
//! are independent, and a larger value makes the middle of the band react more
//! strongly to the bass/treble pair. The section is converted to the digital
//! domain with the bilinear transform, corners prewarped at the sample rate.
//!
//! The mid knob is a separate RBJ peaking section at [`MID_HZ`] with
//! [`MID_Q`], the same node the browser's tone control uses. It rides on the
//! overlapping skirts of the bass/treble shelves, so the three controls still
//! interact: boosting both bass and treble lifts the middle a little and
//! leaves a shallow "smile", which the mid knob fills or deepens.
//!
//! ## The approximation
//!
//! This is a musical model of the network's shape, not a component-level
//! simulator: it has no insertion loss, no pot law and no resistor tolerance.
//! The mid section is independent in the analog sense, but because the
//! bass/treble corners are only a few octaves apart their skirts cross the
//! middle, which is the interaction a graphic pedal has. The result is mono,
//! allocates only in `prepare`, and clamps its knobs to +-[`MAX_DB`].
//!
//! The knobs are dB, not the slider's 0..100: the control path maps them
//! (`docs/studio-effects.md`) and this type clamps them.

use std::f64::consts::PI;

use super::{clamp_hz, one_pole_block, peaking, Biquad, Effect, SMOOTH_SECONDS};

/// How strongly the shared feedback loop couples the bass and treble arms.
/// 0 leaves the two shelves independent; 0.3 gives the gentle smile a hi-fi
/// tone control has when both ends are boosted.
const LOOP_COUPLING: f64 = 0.3;

/// A Baxandall bass/treble pair plus a mid bell.
#[derive(Debug)]
pub struct Equalizer {
    rate: u32,
    target_db: [f32; 3],
    current_db: [f32; 3],
    /// The coupled bass/treble section: both knobs design one biquad.
    shelf: Biquad,
    /// The mid bell that rides on the shelf skirts.
    mid: Biquad,
    designed: bool,
}

impl Equalizer {
    pub const LOW_HZ: f32 = 200.0;
    pub const MID_HZ: f32 = 1_000.0;
    pub const HIGH_HZ: f32 = 4_000.0;
    /// Wider than the strip's ±12 dB, because a pedal has to be able to rescue
    /// a badly placed microphone as well as colour a good one.
    pub const MAX_DB: f32 = 12.0;
    /// The mid bell is as broad as the browser's peaking node.
    pub const MID_Q: f64 = 1.0;

    /// Gains in dB, the natural units behind the three 0..100 knobs.
    pub fn new(low_db: f32, mid_db: f32, high_db: f32) -> Self {
        let clamp = |value: f32| {
            if value.is_finite() {
                value.clamp(-Self::MAX_DB, Self::MAX_DB)
            } else {
                0.0
            }
        };
        let gains = [clamp(low_db), clamp(mid_db), clamp(high_db)];
        Equalizer {
            rate: 48_000,
            target_db: gains,
            current_db: gains,
            shelf: Biquad::identity(),
            mid: Biquad::identity(),
            designed: false,
        }
    }

    fn design(&mut self) {
        let rate = f64::from(self.rate.max(1));
        self.shelf.set(baxandall(
            rate,
            f64::from(self.current_db[0]),
            f64::from(self.current_db[2]),
        ));
        self.mid.set(peaking(
            rate,
            f64::from(Self::MID_HZ),
            Self::MID_Q,
            f64::from(self.current_db[1]),
        ));
        self.designed = true;
    }
}

/// The analog Baxandall prototype, bilinear-transformed to one biquad.
///
/// `H(s) = (s + wL*B)(T*s + wH) / ((s + pL)(s + pH))`, with prewarped corners
/// `wL`, `wH` and `pL*pH = wL*wH`. Returns the `(b0, b1, b2, a0, a1, a2)` set
/// [`Biquad::set`] expects.
fn baxandall(rate: f64, low_db: f64, high_db: f64) -> (f64, f64, f64, f64, f64, f64) {
    let bass = 10f64.powf(low_db / 20.0);
    let treble = 10f64.powf(high_db / 20.0);
    let w_low = 2.0 * rate * (PI * clamp_hz(rate, f64::from(Equalizer::LOW_HZ)) / rate).tan();
    let w_high = 2.0 * rate * (PI * clamp_hz(rate, f64::from(Equalizer::HIGH_HZ)) / rate).tan();

    // One zero per arm, at the corner scaled by that arm's plateau gain.
    let bass_zero = w_low * bass;
    let treble_zero = w_high;
    // Shared feedback loop: the balance shifts the two poles, but their
    // product stays `wL*wH`, so the DC and HF plateaus remain exact.
    let shift = (bass / treble).powf(LOOP_COUPLING / 2.0);
    let pole_low = w_low * shift;
    let pole_high = w_high / shift;

    let n2 = treble;
    let n1 = treble_zero + bass_zero * treble;
    let n0 = bass_zero * treble_zero;
    let d1 = pole_low + pole_high;
    let d0 = pole_low * pole_high;

    // Bilinear transform: s = 2*rate*(1 - z^-1)/(1 + z^-1).
    let k = 2.0 * rate;
    let (n0d, n1d, n2d) = (
        n2 * k * k + n1 * k + n0,
        -2.0 * n2 * k * k + 2.0 * n0,
        n2 * k * k - n1 * k + n0,
    );
    let (d0d, d1d, d2d) = (
        k * k + d1 * k + d0,
        -2.0 * k * k + 2.0 * d0,
        k * k - d1 * k + d0,
    );
    (n0d, n1d, n2d, d0d, d1d, d2d)
}

impl Effect for Equalizer {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.current_db = self.target_db;
        self.design();
        self.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.designed {
            return;
        }
        // Coefficients are nonlinear in gain, so the control walks to its target
        // in block-sized steps; the filters themselves never see a jump.
        let alpha = one_pole_block(SMOOTH_SECONDS, self.rate, block.len());
        let mut changed = false;
        for band in 0..3 {
            let target = self.target_db[band];
            let current = self.current_db[band];
            if target != current {
                if (target - current).abs() < 1e-4 {
                    self.current_db[band] = target;
                } else {
                    self.current_db[band] =
                        (f64::from(current) + f64::from(target - current) * alpha) as f32;
                }
                changed = true;
            }
        }
        if changed {
            self.design();
        }
        for sample in block.iter_mut() {
            *sample = self.mid.process(self.shelf.process(*sample));
        }
    }

    fn reset(&mut self) {
        self.shelf.reset();
        self.mid.reset();
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let band = match name {
            "low" => 0,
            "mid" => 1,
            "high" => 2,
            _ => return false,
        };
        if value.is_finite() {
            self.target_db[band] = value.clamp(-Self::MAX_DB, Self::MAX_DB);
        }
        true
    }

    fn name(&self) -> &'static str {
        "equalizer"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;
    const FRAMES: usize = 16_384;
    const SETTLE: usize = 8_192;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude)
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    /// Steady-state magnitude through a fresh pedal at `hz`, as a linear gain.
    fn gain_at(hz: f32, low_db: f32, mid_db: f32, high_db: f32) -> f32 {
        let mut eq = Equalizer::new(low_db, mid_db, high_db);
        eq.prepare(RATE, FRAMES);
        let input = sine(hz, 0.25, FRAMES);
        let mut output = input.clone();
        eq.process(&mut output);
        rms(&output[SETTLE..]) / rms(&input[SETTLE..])
    }

    #[test]
    fn each_knob_moves_its_own_region() {
        let flat = gain_at(1_000.0, 0.0, 0.0, 0.0);
        assert!((flat - 1.0).abs() < 0.01, "flat was not unity: {flat}");

        let low = gain_at(80.0, 12.0, 0.0, 0.0);
        let mid = gain_at(1_000.0, 0.0, 12.0, 0.0);
        let high = gain_at(8_000.0, 0.0, 0.0, 12.0);
        assert!(low > 2.5, "80 Hz was not lifted: {low}");
        assert!(mid > 2.5, "1 kHz was not lifted: {mid}");
        assert!(high > 2.5, "8 kHz was not lifted: {high}");

        let low_cut = gain_at(80.0, -12.0, 0.0, 0.0);
        let mid_cut = gain_at(1_000.0, 0.0, -12.0, 0.0);
        let high_cut = gain_at(8_000.0, 0.0, 0.0, -12.0);
        assert!(low_cut < 0.5, "80 Hz was not cut: {low_cut}");
        assert!(mid_cut < 0.5, "1 kHz was not cut: {mid_cut}");
        assert!(high_cut < 0.5, "8 kHz was not cut: {high_cut}");

        // A tone control's skirts are gentle: the far end stays near unity.
        assert!(gain_at(8_000.0, 12.0, 0.0, 0.0) < 1.2, "the bass knob moved 8 kHz");
        assert!(gain_at(80.0, 0.0, 0.0, 12.0) < 1.2, "the treble knob moved 80 Hz");
        assert!(gain_at(80.0, 0.0, 12.0, 0.0) < 1.2, "the mid knob moved 80 Hz");
        assert!(gain_at(8_000.0, 0.0, 12.0, 0.0) < 1.2, "the mid knob moved 8 kHz");
    }

    #[test]
    fn flat_settings_are_transparent() {
        let mut eq = Equalizer::new(0.0, 0.0, 0.0);
        eq.prepare(RATE, 4_096);
        let input = sine(997.0, 0.5, 4_096);
        let mut output = input.clone();
        eq.process(&mut output);
        for (dry, wet) in input.iter().zip(&output) {
            assert!((dry - wet).abs() < 1e-5, "flat changed the signal: {dry} -> {wet}");
        }
    }

    #[test]
    fn the_mid_moves_with_the_bass_and_treble_like_a_tone_stack() {
        let flat_mid = gain_at(1_000.0, 0.0, 0.0, 0.0);
        let both_ends = gain_at(1_000.0, 12.0, 0.0, 12.0);
        let low_end = gain_at(80.0, 12.0, 0.0, 12.0);
        let high_end = gain_at(8_000.0, 12.0, 0.0, 12.0);
        let filled = gain_at(1_000.0, 12.0, 12.0, 12.0);

        // The shelves' skirts reach the middle: it rises when both ends rise...
        assert!(
            both_ends > flat_mid * 1.2,
            "the mid ignored the shelves: {both_ends}"
        );
        // ...but less than either end, which is the smile of a real stack.
        assert!(
            both_ends < low_end * 0.75,
            "no smile: mid {both_ends}, low {low_end}"
        );
        assert!(
            both_ends < high_end * 0.75,
            "no smile: mid {both_ends}, high {high_end}"
        );
        // The mid knob fills that smile rather than acting as a separate band.
        assert!(
            filled > both_ends * 3.0,
            "the mid knob did not fill the smile: {filled} vs {both_ends}"
        );
    }

    #[test]
    fn full_scale_input_stays_finite() {
        let mut eq = Equalizer::new(12.0, 12.0, 12.0);
        eq.prepare(RATE, 4_096);

        let mut alternating = vec![0.0f32; 4_096];
        for (index, sample) in alternating.iter_mut().enumerate() {
            *sample = if index % 2 == 0 { 1.0 } else { -1.0 };
        }
        eq.process(&mut alternating);
        assert!(
            alternating.iter().all(|sample| sample.is_finite() && sample.abs() < 32.0),
            "Nyquist full scale ran away"
        );

        let mut full = sine(997.0, 1.0, 4_096);
        eq.process(&mut full);
        assert!(
            full.iter().all(|sample| sample.is_finite() && sample.abs() < 32.0),
            "full-scale sine ran away"
        );
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut eq = Equalizer::new(12.0, -12.0, 12.0);
        eq.prepare(RATE, 256);
        let mut block = vec![0.0f32; 256];
        eq.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn reset_matches_the_first_run() {
        let mut eq = Equalizer::new(6.0, -6.0, 3.0);
        eq.prepare(RATE, 512);
        let input = sine(440.0, 0.3, 512);
        let mut first = input.clone();
        eq.process(&mut first);
        eq.reset();
        let mut second = input.clone();
        eq.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut eq = Equalizer::new(0.0, 0.0, 0.0);
        assert!(eq.set("low", 100.0));
        assert_eq!(eq.target_db[0], Equalizer::MAX_DB);
        assert!(eq.set("mid", -100.0));
        assert_eq!(eq.target_db[1], -Equalizer::MAX_DB);
        assert!(eq.set("high", f32::NAN));
        assert_eq!(eq.target_db[2], 0.0, "NaN moved a knob");
        assert!(!eq.set("bass", 1.0));
        assert!(!eq.set("loww", 1.0));

        // A new pedal ignores junk too, rather than carrying NaN into the
        // coefficient design.
        let junk = Equalizer::new(f32::NAN, f32::INFINITY, -f32::INFINITY);
        assert_eq!(junk.target_db, [0.0; 3]);
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("equalizer"), Some(InsertKind::Equalizer));
        assert_eq!(InsertKind::Equalizer.name(), "equalizer");
        assert_eq!(InsertKind::parse("master_eq"), Some(InsertKind::Equalizer));
    }
}
