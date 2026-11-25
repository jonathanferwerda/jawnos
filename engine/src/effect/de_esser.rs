//! The `de_esser` pedal: a band-split compressor that only touches the top end.
//!
//! # The model
//!
//! ```text
//!             ┌──────── lowpass (freq) ────────► low  (untouched) ─┐
//! in ─────────┤                                                    ├──► out
//!             └──► high = in − low ──► peak ──► gain ──► high ──────┘
//!                                            ▲
//!                              thresh, amount (0 .. 24 dB)
//! ```
//!
//! A copy of the signal is split at `freq` into a low band and the high band
//! that remains. Only the high band is compressed: a fast peak follower reads
//! it, `thresh` sets the dB level where reduction begins, and `amount` scales
//! the maximum reduction from 0 dB (transparent) to about 24 dB. The low band is
//! summed back untouched, so the body of a voice or a guitar keeps its level.
//!
//! `thresh` is dBFS, `freq` is Hz (4000..12000) and `amount` is 0..1. There is
//! no `sync` control.
//!
//! # The honest approximation
//!
//! * The split is a second-order Butterworth lowpass and its complement
//!   (`high = in − low`), not a linear-phase crossover; the two bands sum to the
//!   input, but the corner is not brick-wall, so a little upper-mid content
//!   shares the high band's gain.
//! * The fixed compression slope is about 4:1 inside the band; the contract's
//!   `amount` caps the maximum reduction rather than moving a ratio, which is
//!   how a de-esser's "amount" knob usually behaves.
//! * The peak follower's attack and release are fixed ([`DETECTOR_ATTACK_SECONDS`],
//!   [`DETECTOR_RELEASE_SECONDS`]); there is no look-ahead, so a very sudden
//!   sibilant can let a few milliseconds through.
//! * Knob moves are one-pole smoothed once per block and the split filter is
//!   redesigned there too. Silence stays exactly silent: a lowpass fed zero and
//!   the zero high band produce zero.

use super::{lowpass, one_pole, one_pole_block, Biquad, Effect, SMOOTH_SECONDS};

const MIN_THRESH_DB: f32 = -60.0;
const MAX_THRESH_DB: f32 = 0.0;
const MIN_FREQ_HZ: f32 = 4_000.0;
const MAX_FREQ_HZ: f32 = 12_000.0;
/// The reduction the amount knob can reach at its top.
const MAX_REDUCTION_DB: f32 = 24.0;
/// Inside the band the compressor is about 4:1, so three quarters of the
/// overshoot is removed before `amount` caps it.
const SLOPE: f32 = 0.75;
const DETECTOR_ATTACK_SECONDS: f32 = 0.001;
const DETECTOR_RELEASE_SECONDS: f32 = 0.04;

#[derive(Debug)]
pub struct DeEsser {
    rate: u32,
    target_thresh_db: f32,
    thresh_db: f32,
    target_freq: f32,
    freq: f32,
    target_amount: f32,
    amount: f32,
    split: Biquad,
    detector: f32,
    detector_attack: f32,
    detector_release: f32,
}

impl DeEsser {
    pub const MIN_THRESH_DB: f32 = MIN_THRESH_DB;
    pub const MAX_THRESH_DB: f32 = MAX_THRESH_DB;
    pub const MIN_FREQ_HZ: f32 = MIN_FREQ_HZ;
    pub const MAX_FREQ_HZ: f32 = MAX_FREQ_HZ;
    pub const MAX_REDUCTION_DB: f32 = MAX_REDUCTION_DB;

    pub fn new(thresh_db: f32, freq_hz: f32, amount: f32) -> Self {
        DeEsser {
            rate: 48_000,
            target_thresh_db: thresh_db.clamp(MIN_THRESH_DB, MAX_THRESH_DB),
            thresh_db: thresh_db.clamp(MIN_THRESH_DB, MAX_THRESH_DB),
            target_freq: freq_hz.clamp(MIN_FREQ_HZ, MAX_FREQ_HZ),
            freq: freq_hz.clamp(MIN_FREQ_HZ, MAX_FREQ_HZ),
            target_amount: amount.clamp(0.0, 1.0),
            amount: amount.clamp(0.0, 1.0),
            split: Biquad::identity(),
            detector: 0.0,
            detector_attack: 0.0,
            detector_release: 0.0,
        }
    }
}

impl Effect for DeEsser {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.thresh_db = self.target_thresh_db;
        self.freq = self.target_freq;
        self.amount = self.target_amount;
        self.split = Biquad::identity();
        self.split
            .set(lowpass(f64::from(self.rate), f64::from(self.freq)));
        self.detector = 0.0;
        self.detector_attack = one_pole(DETECTOR_ATTACK_SECONDS, self.rate) as f32;
        self.detector_release = one_pole(DETECTOR_RELEASE_SECONDS, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() || self.rate == 0 {
            return;
        }
        let block_smooth = one_pole_block(SMOOTH_SECONDS, self.rate, block.len()) as f32;
        self.thresh_db += (self.target_thresh_db - self.thresh_db) * block_smooth;
        self.freq += (self.target_freq - self.freq) * block_smooth;
        self.amount += (self.target_amount - self.amount) * block_smooth;
        self.split
            .set(lowpass(f64::from(self.rate), f64::from(self.freq)));

        let threshold = self.thresh_db;
        let max_reduction = MAX_REDUCTION_DB * self.amount;
        for sample in block.iter_mut() {
            let low = self.split.process(*sample);
            let high = *sample - low;

            let magnitude = high.abs();
            let coefficient = if magnitude > self.detector {
                self.detector_attack
            } else {
                self.detector_release
            };
            self.detector += (magnitude - self.detector) * coefficient;

            let level_db = 20.0 * self.detector.max(1e-9).log10();
            let over = level_db - threshold;
            let reduction_db = if over > 0.0 {
                (over * SLOPE).min(max_reduction)
            } else {
                0.0
            };
            let gain = 10f32.powf(-reduction_db / 20.0);
            *sample = low + high * gain;
        }
    }

    fn reset(&mut self) {
        self.thresh_db = self.target_thresh_db;
        self.freq = self.target_freq;
        self.amount = self.target_amount;
        self.split.reset();
        self.detector = 0.0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "thresh" => {
                if usable {
                    self.target_thresh_db = value.clamp(MIN_THRESH_DB, MAX_THRESH_DB);
                }
                true
            }
            "freq" => {
                if usable {
                    self.target_freq = value.clamp(MIN_FREQ_HZ, MAX_FREQ_HZ);
                }
                true
            }
            "amount" => {
                if usable {
                    self.target_amount = value.clamp(0.0, 1.0);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "de_esser"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| {
                (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude
            })
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    fn render(de_esser: &mut DeEsser, input: &[f32]) -> Vec<f32> {
        de_esser.prepare(RATE, input.len());
        let mut block = input.to_vec();
        de_esser.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut de_esser = DeEsser::new(-28.0, 6_500.0, 0.6);
        let output = render(&mut de_esser, &vec![0.0f32; 4096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn zero_amount_is_transparent() {
        let input = sine(8_000.0, 0.5, 8192);
        let mut de_esser = DeEsser::new(-50.0, 6_500.0, 0.0);
        let output = render(&mut de_esser, &input);
        for (out, dry) in output.iter().zip(input.iter()) {
            assert!(
                (out - dry).abs() < 1e-6,
                "a zero amount coloured the signal"
            );
        }
    }

    #[test]
    fn a_loud_high_band_is_reduced() {
        // A 10 kHz tone is well above a 4 kHz split, so most of it is in the
        // compressed band; the untouched low band is the only remainder.
        let input = sine(10_000.0, 0.5, 8192);
        let mut gentle = DeEsser::new(0.0, 4_000.0, 1.0);
        let open = rms(&render(&mut gentle, &input)[2_048..]);
        let mut working = DeEsser::new(-40.0, 4_000.0, 1.0);
        let reduced = rms(&render(&mut working, &input)[2_048..]);
        assert!(
            reduced < open * 0.5,
            "the high band was not compressed: {open} -> {reduced}"
        );
    }

    #[test]
    fn the_low_band_passes_untouched() {
        let input = sine(200.0, 0.4, 8192);
        let mut de_esser = DeEsser::new(-60.0, 6_500.0, 1.0);
        let output = render(&mut de_esser, &input);
        let ratio = rms(&output[2_048..]) / rms(&input[2_048..]);
        assert!(
            (0.98..=1.02).contains(&ratio),
            "the low band was moved: {ratio}"
        );
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(9_000.0, 1.0, 8192);
        let mut de_esser = DeEsser::new(-60.0, 4_000.0, 1.0);
        de_esser.prepare(RATE, input.len());
        let mut first = input.clone();
        de_esser.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));

        de_esser.reset();
        let mut second = input.clone();
        de_esser.process(&mut second);
        assert_eq!(first, second, "reset did not return to the first run");
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut de_esser = DeEsser::new(-28.0, 6_500.0, 0.6);
        assert!(de_esser.set("thresh", 10.0));
        assert_eq!(de_esser.target_thresh_db, DeEsser::MAX_THRESH_DB);
        assert!(de_esser.set("thresh", -200.0));
        assert_eq!(de_esser.target_thresh_db, DeEsser::MIN_THRESH_DB);
        assert!(de_esser.set("freq", 100.0));
        assert_eq!(de_esser.target_freq, DeEsser::MIN_FREQ_HZ);
        assert!(de_esser.set("freq", 30_000.0));
        assert_eq!(de_esser.target_freq, DeEsser::MAX_FREQ_HZ);
        assert!(de_esser.set("amount", 10.0));
        assert_eq!(de_esser.target_amount, 1.0);
        assert!(de_esser.set("amount", f32::NAN));
        assert_eq!(de_esser.target_amount, 1.0, "NaN moved a knob");
        assert!(!de_esser.set("mix", 1.0));
        assert!(!de_esser.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("de_esser"), Some(InsertKind::DeEsser));
        assert_eq!(InsertKind::DeEsser.name(), "de_esser");
        assert_eq!(
            InsertKind::DeEsser.controls(),
            &["thresh", "freq", "amount"]
        );
        assert_eq!(InsertKind::DeEsser.code(), 18);
        assert_eq!(InsertKind::from_code(18), Some(InsertKind::DeEsser));
        assert_eq!(InsertKind::DeEsser.build().name(), "de_esser");
    }
}
