//! The `limiter` pedal: a peak limiter with an instant attack and a release
//! you can hear.
//!
//! There is no look-ahead. A look-ahead limiter is a delay line, and this plan
//! does not add latency to a pedal silently (the autotune pedal, which does add
//! latency, says so in its own comments). Instead the gain is computed from the
//! sample in hand: anything above the ceiling is scaled to it immediately, and
//! the gain recovers with the release time once the peak has passed. The output
//! therefore cannot exceed the ceiling, which is the property a mixing engineer
//! buys a limiter for.
//!
//! `ceiling` is dBFS (−60..0), `release` is seconds (0.001..2). The maximizer
//! shares [`PeakLimiter`] rather than growing a second detector.

use super::{one_pole, one_pole_block, Effect};

/// The gain computer both this pedal and the maximizer use. It owns one number:
/// the current linear gain, which never rises above 1.
#[derive(Debug)]
pub(super) struct PeakLimiter {
    gain: f32,
}

impl PeakLimiter {
    pub(super) fn new() -> Self {
        PeakLimiter { gain: 1.0 }
    }

    pub(super) fn reset(&mut self) {
        self.gain = 1.0;
    }

    /// `ceiling` and `release` are already in their natural units: a linear
    /// peak and a one-pole coefficient.
    #[inline]
    pub(super) fn process(&mut self, sample: f32, ceiling: f32, release: f32) -> f32 {
        let magnitude = sample.abs();
        let needed = if magnitude > ceiling && magnitude > 0.0 {
            ceiling / magnitude
        } else {
            1.0
        };
        if needed < self.gain {
            self.gain = needed;
        } else {
            self.gain += (1.0 - self.gain) * release;
            // The release may recover the gain, but never past what this
            // sample's own peak allows: the ceiling is a hard promise, not an
            // approximate one.
            self.gain = self.gain.min(needed);
        }
        sample * self.gain
    }
}

#[derive(Debug)]
pub struct Limiter {
    rate: u32,
    target_ceiling_db: f32,
    ceiling_db: f32,
    target_release: f32,
    release_s: f32,
    limiter: PeakLimiter,
}

impl Limiter {
    pub const MIN_CEILING_DB: f32 = -60.0;
    pub const MIN_RELEASE: f32 = 0.001;
    pub const MAX_RELEASE: f32 = 2.0;

    pub fn new(ceiling_db: f32, release_s: f32) -> Self {
        let ceiling_db = ceiling_db.clamp(Self::MIN_CEILING_DB, 0.0);
        let release_s = release_s.clamp(Self::MIN_RELEASE, Self::MAX_RELEASE);
        Limiter {
            rate: 48_000,
            target_ceiling_db: ceiling_db,
            ceiling_db,
            target_release: release_s,
            release_s,
            limiter: PeakLimiter::new(),
        }
    }
}

impl Effect for Limiter {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.ceiling_db = self.target_ceiling_db;
        self.release_s = self.target_release;
        self.limiter.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() {
            return;
        }
        // Two knobs, both smooth enough at the block's edge: a ceiling move is a
        // level change, not a filter coefficient, and a release move only
        // changes how fast a recovering gain travels.
        let alpha = one_pole_block(0.02, self.rate, block.len()) as f32;
        self.ceiling_db += (self.target_ceiling_db - self.ceiling_db) * alpha;
        self.release_s += (self.target_release - self.release_s) * alpha;
        let ceiling = 10f32.powf(self.ceiling_db / 20.0);
        let release = one_pole(self.release_s.max(Self::MIN_RELEASE), self.rate) as f32;
        for sample in block.iter_mut() {
            *sample = self.limiter.process(*sample, ceiling, release);
        }
    }

    fn reset(&mut self) {
        self.ceiling_db = self.target_ceiling_db;
        self.release_s = self.target_release;
        self.limiter.reset();
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
            "release" => {
                if usable {
                    self.target_release = value.clamp(Self::MIN_RELEASE, Self::MAX_RELEASE);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "limiter"
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

    fn peak(block: &[f32]) -> f32 {
        block.iter().fold(0.0f32, |highest, sample| highest.max(sample.abs()))
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut limiter = Limiter::new(-6.0, 0.1);
        limiter.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        limiter.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn the_ceiling_bounds_every_peak() {
        let input = sine(220.0, 1.0, 8192);
        let mut limiter = Limiter::new(-6.0, 0.2);
        limiter.prepare(RATE, 8192);
        let mut block = input.clone();
        limiter.process(&mut block);
        let ceiling = 10f32.powf(-6.0 / 20.0);
        assert!(
            peak(&block) <= ceiling + 1e-4,
            "the limiter let {} through a {ceiling} ceiling",
            peak(&block)
        );

        // A quiet signal below the ceiling is not touched.
        limiter.reset();
        let quiet = sine(220.0, 0.25, 4096);
        let mut block = quiet.clone();
        limiter.process(&mut block);
        assert_eq!(block, quiet);
    }

    #[test]
    fn reset_matches_the_first_run() {
        let input = sine(440.0, 1.0, 4096);
        let mut limiter = Limiter::new(-3.0, 0.1);
        limiter.prepare(RATE, 4096);
        let mut first = input.clone();
        limiter.process(&mut first);
        limiter.reset();
        let mut second = input.clone();
        limiter.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut limiter = Limiter::new(-1.0, 0.2);
        assert!(limiter.set("ceiling", 10.0));
        assert_eq!(limiter.target_ceiling_db, 0.0);
        assert!(limiter.set("ceiling", -100.0));
        assert_eq!(limiter.target_ceiling_db, Limiter::MIN_CEILING_DB);
        assert!(limiter.set("release", 100.0));
        assert_eq!(limiter.target_release, Limiter::MAX_RELEASE);
        assert!(limiter.set("release", f32::NAN));
        assert_eq!(limiter.target_release, Limiter::MAX_RELEASE);
        assert!(!limiter.set("threshold", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("limiter"), Some(InsertKind::Limiter));
        assert_eq!(InsertKind::Limiter.name(), "limiter");
        assert_eq!(InsertKind::parse("master_limiter"), Some(InsertKind::Limiter));
    }
}
