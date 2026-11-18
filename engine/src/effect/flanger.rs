//! The `flanger` pedal: a short delay swept by an LFO, with feedback.
//!
//! A flanger and a chorus are the same machine with different delay ranges; this
//! one sweeps 0.5..5 ms, which is the range whose comb notches sit in the
//! audible band. The LFO is a sine, the feedback is taken from the delayed
//! signal before the dry/wet mix, and the delay is read with linear
//! interpolation so a moving sweep bends rather than steps.
//!
//! `rate` is Hz, `depth`, `feedback` and `mix` are the normalised 0..1 knobs
//! the control path sends. Feedback stops at [`MAX_FEEDBACK`], short of unity,
//! so a swept comb cannot build into a runaway.

use super::{one_pole, Effect};

#[derive(Debug)]
pub struct Flanger {
    rate: u32,
    buffer: Vec<f32>,
    write: usize,
    target_lfo_hz: f32,
    lfo_hz: f32,
    target_depth: f32,
    depth: f32,
    target_feedback: f32,
    feedback: f32,
    target_mix: f32,
    mix: f32,
    phase: f32,
    smooth: f32,
}

impl Flanger {
    pub const MIN_RATE_HZ: f32 = 0.05;
    pub const MAX_RATE_HZ: f32 = 5.0;
    /// The shortest delay, which is what makes a flanger a comb rather than a
    /// slapback.
    pub const MIN_DELAY: f32 = 0.000_5;
    /// How far the sweep can add to [`MIN_DELAY`].
    pub const MAX_SWEEP: f32 = 0.004_5;
    pub const MAX_FEEDBACK: f32 = 0.9;
    /// The line is longer than any sweep, plus room for the interpolator.
    pub const LINE_SECONDS: f32 = 0.02;

    pub fn new(rate_hz: f32, depth: f32, feedback: f32, mix: f32) -> Self {
        let lfo_hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        let feedback = feedback.clamp(0.0, Self::MAX_FEEDBACK);
        let mix = mix.clamp(0.0, 1.0);
        Flanger {
            rate: 48_000,
            buffer: Vec::new(),
            write: 0,
            target_lfo_hz: lfo_hz,
            lfo_hz,
            target_depth: depth,
            depth,
            target_feedback: feedback,
            feedback,
            target_mix: mix,
            mix,
            phase: 0.0,
            smooth: 0.0,
        }
    }

    #[inline]
    fn tap(&self, delay: f32) -> f32 {
        let length = self.buffer.len();
        let reach = (length - 2) as f32;
        let back = delay.clamp(0.0, reach);
        let base = back.floor();
        let fraction = back - base;
        let first = (self.write as isize - base as isize).rem_euclid(length as isize) as usize;
        let second = (first + 1) % length;
        self.buffer[first] * (1.0 - fraction) + self.buffer[second] * fraction
    }
}

impl Effect for Flanger {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let length = (f64::from(self.rate) * f64::from(Self::LINE_SECONDS)) as usize + 2;
        self.buffer = vec![0.0; length.max(4)];
        self.write = 0;
        self.lfo_hz = self.target_lfo_hz;
        self.depth = self.target_depth;
        self.feedback = self.target_feedback;
        self.mix = self.target_mix;
        self.smooth = one_pole(0.01, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if self.buffer.len() < 4 {
            return;
        }
        let rate = self.rate.max(1) as f32;
        for sample in block.iter_mut() {
            self.lfo_hz += (self.target_lfo_hz - self.lfo_hz) * self.smooth;
            self.depth += (self.target_depth - self.depth) * self.smooth;
            self.feedback += (self.target_feedback - self.feedback) * self.smooth;
            self.mix += (self.target_mix - self.mix) * self.smooth;

            let sweep = 0.5 - 0.5 * (std::f32::consts::TAU * self.phase).cos();
            let delay = Self::MIN_DELAY + Self::MAX_SWEEP * self.depth * sweep;
            let delayed = self.tap(delay * rate);

            let input = *sample;
            *sample = input * (1.0 - self.mix) + delayed * self.mix;
            self.buffer[self.write] = input + delayed * self.feedback;
            self.write = (self.write + 1) % self.buffer.len();

            self.phase += self.lfo_hz / rate;
            if self.phase >= 1.0 {
                self.phase -= 1.0;
            }
        }
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
        self.write = 0;
        self.phase = 0.0;
        self.lfo_hz = self.target_lfo_hz;
        self.depth = self.target_depth;
        self.feedback = self.target_feedback;
        self.mix = self.target_mix;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "rate" => {
                if usable {
                    self.target_lfo_hz = value.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
                }
                true
            }
            "depth" => {
                if usable {
                    self.target_depth = value.clamp(0.0, 1.0);
                }
                true
            }
            "feedback" => {
                if usable {
                    self.target_feedback = value.clamp(0.0, Self::MAX_FEEDBACK);
                }
                true
            }
            "mix" => {
                if usable {
                    self.target_mix = value.clamp(0.0, 1.0);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "flanger"
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
        let mut flanger = Flanger::new(0.3, 0.8, 0.5, 1.0);
        flanger.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        flanger.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn the_mix_and_depth_move_the_sound() {
        let input = sine(220.0, 0.2, 8192);

        let mut dry = Flanger::new(0.7, 0.8, 0.4, 0.0);
        dry.prepare(RATE, 8192);
        let mut dry_block = input.clone();
        dry.process(&mut dry_block);
        assert_eq!(dry_block, input, "mix 0 must be the dry signal");

        let mut wet = Flanger::new(0.7, 0.8, 0.4, 0.8);
        wet.prepare(RATE, 8192);
        let mut wet_block = input.clone();
        wet.process(&mut wet_block);

        let difference = wet_block
            .iter()
            .zip(&input)
            .map(|(a, b)| (a - b) * (a - b))
            .sum::<f32>();
        assert!(difference > 1.0, "the flanger did not change the sound");
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 4096);
        let mut flanger = Flanger::new(2.5, 1.0, 0.9, 1.0);
        flanger.prepare(RATE, 4096);
        let mut first = input.clone();
        flanger.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));
        flanger.reset();
        let mut second = input.clone();
        flanger.process(&mut second);
        assert_eq!(first, second);
        assert!(rms(&first) > 0.0);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut flanger = Flanger::new(0.3, 0.5, 0.3, 0.5);
        assert!(flanger.set("rate", 100.0));
        assert_eq!(flanger.target_lfo_hz, Flanger::MAX_RATE_HZ);
        assert!(flanger.set("depth", -1.0));
        assert_eq!(flanger.target_depth, 0.0);
        assert!(flanger.set("feedback", 10.0));
        assert_eq!(flanger.target_feedback, Flanger::MAX_FEEDBACK);
        assert!(flanger.set("mix", f32::NAN));
        assert_eq!(flanger.target_mix, 0.5, "NaN moved a knob");
        assert!(!flanger.set("vol", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("flanger"), Some(InsertKind::Flanger));
        assert_eq!(InsertKind::Flanger.name(), "flanger");
    }
}
