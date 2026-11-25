//! The `chorus` pedal: one modulated short delay, mixed with dry.
//!
//! # The model
//!
//! ```text
//!              sin(2π · rate · t)
//!                       │
//!                       ▼
//! delay = 17.5 ms + 12.5 ms · depth · lfo      (5 .. 30 ms)
//! in ──► delay line tap ──► × mix ──┐
//!   │                               ├──► out
//!   └────────── × (1 − mix) ────────┘
//! ```
//!
//! The delayed copy is swept by a slow LFO, and summing it with the dry path
//! gives the moving comb and the gentle detune that a chorus is. `depth` scales
//! the delay swing (0 leaves a fixed 17.5 ms delay) and `mix` sets how much of
//! the wet copy is heard. One voice only: the engine's insert chain is mono, so
//! this is a single swept tap rather than the two or three a stereo chorus
//! spreads across the field.
//!
//! `rate` is Hz in the contract's chorus band (0.05..5), `depth` and `mix` are
//! 0..1. The page resolves tempo sync into `rate`, so there is no `sync` control.
//!
//! # The honest approximation
//!
//! * One voice, mono. A stereo chorus needs an L/R pair the insert chain does
//!   not hold; a native take gets one sweep where the browser can spread two.
//! * The delay is linearly interpolated, so the sweep is continuous, but a deep
//!   fast sweep still bends the pitch of the copy — the same artefact a real
//!   analogue chorus has, not a bug hidden behind smoothing.
//! * Knob moves are one-pole smoothed; the LFO advances per sample. Silence
//!   stays exactly silent, because a delay line fed zero returns zero.

use super::{one_pole, Effect, SMOOTH_SECONDS};
use std::f32::consts::TAU;

const MIN_DELAY_SECONDS: f32 = 0.005;
const MAX_DELAY_SECONDS: f32 = 0.030;
const LINE_SECONDS: f32 = 0.035;

#[derive(Debug)]
pub struct Chorus {
    rate: u32,
    target_hz: f32,
    hz: f32,
    target_depth: f32,
    depth: f32,
    target_mix: f32,
    mix: f32,
    buffer: Vec<f32>,
    write: usize,
    phase: f32,
    smooth: f32,
}

impl Chorus {
    pub const MIN_RATE_HZ: f32 = 0.05;
    pub const MAX_RATE_HZ: f32 = 5.0;
    pub const MIN_DELAY_SECONDS: f32 = MIN_DELAY_SECONDS;
    pub const MAX_DELAY_SECONDS: f32 = MAX_DELAY_SECONDS;

    pub fn new(rate_hz: f32, depth: f32, mix: f32) -> Self {
        let hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        let mix = mix.clamp(0.0, 1.0);
        Chorus {
            rate: 48_000,
            target_hz: hz,
            hz,
            target_depth: depth,
            depth,
            target_mix: mix,
            mix,
            buffer: Vec::new(),
            write: 0,
            phase: 0.0,
            smooth: 0.0,
        }
    }

    #[inline]
    fn tap(buffer: &[f32], write: usize, delay: f32) -> f32 {
        let length = buffer.len();
        if length < 2 {
            return 0.0;
        }
        let reach = (length - 2) as f32;
        let back = delay.clamp(0.0, reach);
        let base = back.floor();
        let fraction = back - base;
        let first = (write as isize - base as isize).rem_euclid(length as isize) as usize;
        let second = (first + length - 1) % length;
        buffer[first] * (1.0 - fraction) + buffer[second] * fraction
    }
}

impl Effect for Chorus {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let length = (self.rate as f32 * LINE_SECONDS) as usize + 2;
        self.buffer = vec![0.0; length.max(4)];
        self.write = 0;
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.mix = self.target_mix;
        self.phase = 0.0;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if self.buffer.len() < 4 {
            return;
        }
        let rate = self.rate as f32;
        let length = self.buffer.len();
        let centre = (MIN_DELAY_SECONDS + MAX_DELAY_SECONDS) * 0.5;
        let half_swing = (MAX_DELAY_SECONDS - MIN_DELAY_SECONDS) * 0.5;
        for sample in block.iter_mut() {
            self.hz += (self.target_hz - self.hz) * self.smooth;
            self.depth += (self.target_depth - self.depth) * self.smooth;
            self.mix += (self.target_mix - self.mix) * self.smooth;

            let lfo = (TAU * self.phase).sin();
            let delay = (centre + half_swing * self.depth * lfo).clamp(0.000_1, LINE_SECONDS);
            let dry = *sample;
            self.buffer[self.write] = dry;
            let wet = Self::tap(&self.buffer, self.write, delay * rate);
            *sample = dry * (1.0 - self.mix) + wet * self.mix;
            self.write = (self.write + 1) % length;

            self.phase += (self.hz / rate).clamp(0.0, 0.5);
            if self.phase >= 1.0 {
                self.phase -= 1.0;
            }
        }
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
        self.write = 0;
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.mix = self.target_mix;
        self.phase = 0.0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "rate" => {
                if usable {
                    self.target_hz = value.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
                }
                true
            }
            "depth" => {
                if usable {
                    self.target_depth = value.clamp(0.0, 1.0);
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
        "chorus"
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

    fn render(chorus: &mut Chorus, input: &[f32]) -> Vec<f32> {
        chorus.prepare(RATE, input.len());
        let mut block = input.to_vec();
        chorus.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut chorus = Chorus::new(0.8, 0.5, 0.5);
        let output = render(&mut chorus, &vec![0.0f32; 4096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn zero_mix_is_transparent() {
        let input = sine(440.0, 0.4, 4096);
        let mut chorus = Chorus::new(0.8, 0.5, 0.0);
        let output = render(&mut chorus, &input);
        assert_eq!(output, input, "mix 0 coloured the signal");
    }

    #[test]
    fn zero_depth_is_a_fixed_centre_delay() {
        // The centre is 17.5 ms, which is exactly 840 samples at 48 kHz.
        let input = sine(440.0, 0.4, 4096);
        let mut chorus = Chorus::new(0.8, 0.0, 1.0);
        let output = render(&mut chorus, &input);
        let delay = ((MIN_DELAY_SECONDS + MAX_DELAY_SECONDS) * 0.5 * RATE as f32) as usize;
        assert_eq!(delay, 840);
        for index in delay..input.len() {
            assert!(
                (output[index] - input[index - delay]).abs() < 1e-6,
                "the fixed delay was not the centre at {index}"
            );
        }
    }

    #[test]
    fn depth_moves_the_delay() {
        let input = sine(440.0, 0.4, 8192);
        let mut flat = Chorus::new(1.0, 0.0, 0.5);
        let flat = render(&mut flat, &input);
        let mut swept = Chorus::new(1.0, 1.0, 0.5);
        let swept = render(&mut swept, &input);
        assert_ne!(flat, swept, "depth did not move the sweep");
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 8192);
        let mut chorus = Chorus::new(5.0, 1.0, 1.0);
        chorus.prepare(RATE, input.len());
        let mut first = input.clone();
        chorus.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));

        chorus.reset();
        let mut second = input.clone();
        chorus.process(&mut second);
        assert_eq!(first, second, "reset did not return to the first run");
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut chorus = Chorus::new(0.8, 0.5, 0.5);
        assert!(chorus.set("rate", 100.0));
        assert_eq!(chorus.target_hz, Chorus::MAX_RATE_HZ);
        assert!(chorus.set("rate", 0.0));
        assert_eq!(chorus.target_hz, Chorus::MIN_RATE_HZ);
        assert!(chorus.set("depth", 10.0));
        assert_eq!(chorus.target_depth, 1.0);
        assert!(chorus.set("mix", 10.0));
        assert_eq!(chorus.target_mix, 1.0);
        assert!(chorus.set("depth", f32::NAN));
        assert_eq!(chorus.target_depth, 1.0, "NaN moved a knob");
        assert!(!chorus.set("feedback", 1.0));
        assert!(!chorus.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("chorus"), Some(InsertKind::Chorus));
        assert_eq!(InsertKind::Chorus.name(), "chorus");
        assert_eq!(InsertKind::Chorus.controls(), &["rate", "depth", "mix"]);
        assert_eq!(InsertKind::Chorus.code(), 25);
        assert_eq!(InsertKind::from_code(25), Some(InsertKind::Chorus));
        assert_eq!(InsertKind::Chorus.build().name(), "chorus");
    }
}
