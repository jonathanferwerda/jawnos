//! The `equalizer` pedal: three bands of tone shaping, separate from the
//! channel's own `tone` stack.
//!
//! Studio's strip already has a `tone` insert (a 220 Hz shelf, a 1 kHz peak and
//! a 3.5 kHz shelf). The equalizer is the general-purpose pedal: the same three
//! shapes at a wider reach, a 120 Hz low shelf, a 1 kHz peaking mid and a 6 kHz
//! high shelf, so a channel can place it anywhere in the chain and leave the
//! strip's own knobs for the mix. Its knobs are dB, not the slider's 0..100:
//! the control path maps them, and this type clamps them to ±[`MAX_DB`].

use super::{
    high_shelf, low_shelf, one_pole_block, peaking, Biquad, Effect, SMOOTH_SECONDS,
};

/// Three bands: low shelf, peaking mid, high shelf.
#[derive(Debug)]
pub struct Equalizer {
    rate: u32,
    target_db: [f32; 3],
    current_db: [f32; 3],
    bands: [Biquad; 3],
    designed: bool,
}

impl Equalizer {
    pub const LOW_HZ: f32 = 120.0;
    pub const MID_HZ: f32 = 1_000.0;
    pub const HIGH_HZ: f32 = 6_000.0;
    /// Wider than the strip's ±12 dB, because a pedal has to be able to rescue
    /// a badly placed microphone as well as colour a good one.
    pub const MAX_DB: f32 = 12.0;
    /// The mid band is broad enough to sound like tone shaping rather than a
    /// surgical notch.
    pub const MID_Q: f64 = 0.7;

    /// Gains in dB, the natural units behind the three 0..100 knobs.
    pub fn new(low_db: f32, mid_db: f32, high_db: f32) -> Self {
        let clamp = |value: f32| value.clamp(-Self::MAX_DB, Self::MAX_DB);
        Equalizer {
            rate: 48_000,
            target_db: [clamp(low_db), clamp(mid_db), clamp(high_db)],
            current_db: [clamp(low_db), clamp(mid_db), clamp(high_db)],
            bands: [Biquad::identity(); 3],
            designed: false,
        }
    }

    fn design(&mut self) {
        let rate = f64::from(self.rate.max(1));
        self.bands[0].set(low_shelf(rate, f64::from(Self::LOW_HZ), f64::from(self.current_db[0])));
        self.bands[1].set(peaking(
            rate,
            f64::from(Self::MID_HZ),
            Self::MID_Q,
            f64::from(self.current_db[1]),
        ));
        self.bands[2].set(high_shelf(
            rate,
            f64::from(Self::HIGH_HZ),
            f64::from(self.current_db[2]),
        ));
        self.designed = true;
    }
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
            for band in &mut self.bands {
                *sample = band.process(*sample);
            }
        }
    }

    fn reset(&mut self) {
        for band in &mut self.bands {
            band.reset();
        }
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

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude)
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
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
    fn the_bands_move_their_own_end_of_the_spectrum() {
        let mut eq = Equalizer::new(12.0, 0.0, -12.0);
        eq.prepare(RATE, 8192);

        let low_input = sine(80.0, 0.1, 8192);
        let mut low = low_input.clone();
        eq.process(&mut low);
        let low_ratio = rms(&low[4096..]) / rms(&low_input[4096..]);

        eq.reset();
        let high_input = sine(9_000.0, 0.1, 8192);
        let mut high = high_input.clone();
        eq.process(&mut high);
        let high_ratio = rms(&high[4096..]) / rms(&high_input[4096..]);

        assert!(low_ratio > 1.5, "80 Hz was not lifted: {low_ratio}");
        assert!(high_ratio < 0.5, "9 kHz was not cut: {high_ratio}");
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
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("equalizer"), Some(InsertKind::Equalizer));
        assert_eq!(InsertKind::Equalizer.name(), "equalizer");
        assert_eq!(InsertKind::parse("master_eq"), Some(InsertKind::Equalizer));
    }
}
