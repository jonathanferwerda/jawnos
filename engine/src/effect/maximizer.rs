//! The `master_maximizer`: drive, then the same 1176-style FET detector the
//! master limiter uses.
//!
//! A maximizer is loudness with a promise: raise the level into a ceiling and
//! let the peaks be caught, so quiet material comes up without the loud parts
//! going over. `loudness` is the normalised 0..1 knob behind a 0..18 dB drive;
//! `ceiling` is dBFS. It exists as its own kind because the contract gives the
//! master rack a maximizer and a limiter as two separate inserts — the limiter
//! is the safety net, the maximizer is the level.
//!
//! The detector is [`FetDetector`](super::limiter::FetDetector), so the
//! maximizer inherits the limiter's fast attack, program-dependent release,
//! soft knee and hard ceiling. Its controls are unchanged.

use super::limiter::{release_times, FetDetector};
use super::{one_pole, one_pole_block, Effect};

#[derive(Debug)]
pub struct Maximizer {
    rate: u32,
    target_ceiling_db: f32,
    ceiling_db: f32,
    target_loudness: f32,
    drive: f32,
    detector: FetDetector,
    smooth: f32,
}

impl Maximizer {
    pub const MAX_DRIVE_DB: f32 = 18.0;
    pub const MIN_CEILING_DB: f32 = -60.0;
    /// A maximizer's release wants to be quicker than a limiter's: it is
    /// raising average level, not catching an occasional stray peak.
    pub const RELEASE_SECONDS: f32 = 0.1;

    pub fn new(ceiling_db: f32, loudness: f32) -> Self {
        let ceiling_db = ceiling_db.clamp(Self::MIN_CEILING_DB, 0.0);
        let loudness = loudness.clamp(0.0, 1.0);
        Maximizer {
            rate: 48_000,
            target_ceiling_db: ceiling_db,
            ceiling_db,
            target_loudness: loudness,
            drive: Self::drive(loudness),
            detector: FetDetector::new(),
            smooth: 0.0,
        }
    }

    fn drive(loudness: f32) -> f32 {
        10f32.powf(loudness.clamp(0.0, 1.0) * Self::MAX_DRIVE_DB / 20.0)
    }
}

impl Effect for Maximizer {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.ceiling_db = self.target_ceiling_db;
        self.drive = Self::drive(self.target_loudness);
        self.detector.reset();
        self.smooth = one_pole(0.01, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() {
            return;
        }
        let alpha = one_pole_block(0.02, self.rate, block.len()) as f32;
        self.ceiling_db += (self.target_ceiling_db - self.ceiling_db) * alpha;
        let target_drive = Self::drive(self.target_loudness);
        let ceiling = 10f32.powf(self.ceiling_db / 20.0);
        let times = release_times(Self::RELEASE_SECONDS, self.rate);
        for sample in block.iter_mut() {
            self.drive += (target_drive - self.drive) * self.smooth;
            *sample =
                self.detector
                    .process(*sample * self.drive, ceiling, self.ceiling_db, times);
        }
    }

    fn reset(&mut self) {
        self.ceiling_db = self.target_ceiling_db;
        self.drive = Self::drive(self.target_loudness);
        self.detector.reset();
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "ceiling" => {
                if usable {
                    self.target_ceiling_db = value.clamp(Self::MIN_CEILING_DB, 0.0);
                }
                true
            }
            "loudness" => {
                if usable {
                    self.target_loudness = value.clamp(0.0, 1.0);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "maximizer"
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

    fn peak(block: &[f32]) -> f32 {
        block.iter().fold(0.0f32, |highest, sample| highest.max(sample.abs()))
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut maximizer = Maximizer::new(-1.0, 0.7);
        maximizer.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        maximizer.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn loudness_raises_a_quiet_signal() {
        let input = sine(220.0, 0.05, 8192);
        let mut maximizer = Maximizer::new(-1.0, 1.0);
        maximizer.prepare(RATE, 8192);
        let mut block = input.clone();
        maximizer.process(&mut block);
        assert!(
            rms(&block[4096..]) > rms(&input[4096..]) * 3.0,
            "loudness did not lift the signal"
        );
    }

    #[test]
    fn a_peak_above_the_ceiling_is_caught_on_the_sample() {
        // Drive 0 dB (loudness 0) and a 0 dB ceiling make the arithmetic exact.
        let mut maximizer = Maximizer::new(0.0, 0.0);
        maximizer.prepare(RATE, 2);
        let mut block = vec![2.0, -2.0];
        maximizer.process(&mut block);
        assert_eq!(block[0], 1.0);
        assert_eq!(block[1], -1.0);
    }

    #[test]
    fn the_ceiling_still_bounds_the_driven_peak() {
        let input = sine(220.0, 1.0, 8192);
        let mut maximizer = Maximizer::new(-6.0, 1.0);
        maximizer.prepare(RATE, 8192);
        let mut block = input.clone();
        maximizer.process(&mut block);
        let ceiling = 10f32.powf(-6.0 / 20.0);
        assert!(
            peak(&block) <= ceiling + 1e-4,
            "the maximizer let {} through a {ceiling} ceiling",
            peak(&block)
        );
    }

    #[test]
    fn reset_matches_the_first_run() {
        let input = sine(440.0, 0.3, 4096);
        let mut maximizer = Maximizer::new(-1.0, 0.8);
        maximizer.prepare(RATE, 4096);
        let mut first = input.clone();
        maximizer.process(&mut first);
        maximizer.reset();
        let mut second = input.clone();
        maximizer.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut maximizer = Maximizer::new(-1.0, 0.5);
        assert!(maximizer.set("loudness", 10.0));
        assert_eq!(maximizer.target_loudness, 1.0);
        assert!(maximizer.set("ceiling", -100.0));
        assert_eq!(maximizer.target_ceiling_db, Maximizer::MIN_CEILING_DB);
        assert!(maximizer.set("ceiling", f32::NAN));
        assert_eq!(maximizer.target_ceiling_db, Maximizer::MIN_CEILING_DB);
        assert!(!maximizer.set("release", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("maximizer"), Some(InsertKind::Maximizer));
        assert_eq!(InsertKind::Maximizer.name(), "maximizer");
        assert_eq!(
            InsertKind::parse("master_maximizer"),
            Some(InsertKind::Maximizer)
        );
    }
}
