//! The `vibrato` pedal: a modulated short delay with no dry path.
//!
//! # The model
//!
//! ```text
//!              sin(2π · rate · t)
//!                       │
//!                       ▼
//! delay = 7 ms + 5 ms · depth · lfo            (2 .. 12 ms)
//! in ──► delay line tap ──► out
//! ```
//!
//! A delay line whose length is swept makes the read pointer move, and a moving
//! read pointer is a pitch bend: that is the whole pedal. Unlike a chorus there
//! is **no dry path**, so the output is only the swept copy and the pitch
//! modulation is not diluted by the unchanged signal. `depth` scales the swing
//! and `rate` is the LFO.
//!
//! `rate` is Hz (0.1..20) and `depth` is 0..1. The page resolves tempo sync
//! into `rate` before sending, so there is no `sync` control.
//!
//! # The honest approximation
//!
//! * The delay is linearly interpolated, so the sweep is continuous, but the
//!   pitch bend is only as clean as a fractional delay is: at full depth and a
//!   fast rate the copy carries a little extra flutter. That is the analogue
//!   pedal's behaviour too, not a hidden smoothing.
//! * At `depth = 0` the delay is a fixed 7 ms, so the pedal is a plain 7 ms
//!   latency rather than a bypass. There is no dry path to remove it.
//! * Knob moves are one-pole smoothed; the LFO advances per sample. Silence
//!   stays exactly silent, because a delay line fed zero returns zero.

use super::{one_pole, Effect, SMOOTH_SECONDS};
use std::f32::consts::TAU;

const MIN_DELAY_SECONDS: f32 = 0.002;
const MAX_DELAY_SECONDS: f32 = 0.012;
const LINE_SECONDS: f32 = 0.014;

#[derive(Debug)]
pub struct Vibrato {
    rate: u32,
    target_hz: f32,
    hz: f32,
    target_depth: f32,
    depth: f32,
    buffer: Vec<f32>,
    write: usize,
    phase: f32,
    smooth: f32,
}

impl Vibrato {
    pub const MIN_RATE_HZ: f32 = 0.1;
    pub const MAX_RATE_HZ: f32 = 20.0;
    pub const MIN_DELAY_SECONDS: f32 = MIN_DELAY_SECONDS;
    pub const MAX_DELAY_SECONDS: f32 = MAX_DELAY_SECONDS;

    pub fn new(rate_hz: f32, depth: f32) -> Self {
        let hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        Vibrato {
            rate: 48_000,
            target_hz: hz,
            hz,
            target_depth: depth,
            depth,
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

impl Effect for Vibrato {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let length = (self.rate as f32 * LINE_SECONDS) as usize + 2;
        self.buffer = vec![0.0; length.max(4)];
        self.write = 0;
        self.hz = self.target_hz;
        self.depth = self.target_depth;
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

            let lfo = (TAU * self.phase).sin();
            let delay = (centre + half_swing * self.depth * lfo).clamp(0.000_1, LINE_SECONDS);
            self.buffer[self.write] = *sample;
            *sample = Self::tap(&self.buffer, self.write, delay * rate);
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
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "vibrato"
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

    fn render(vibrato: &mut Vibrato, input: &[f32]) -> Vec<f32> {
        vibrato.prepare(RATE, input.len());
        let mut block = input.to_vec();
        vibrato.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut vibrato = Vibrato::new(5.0, 0.4);
        let output = render(&mut vibrato, &vec![0.0f32; 4096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn zero_depth_is_a_fixed_centre_delay() {
        // The centre is 7 ms, exactly 336 samples at 48 kHz, and there is no
        // dry path to hide behind.
        let input = sine(440.0, 0.4, 4096);
        let mut vibrato = Vibrato::new(5.0, 0.0);
        let output = render(&mut vibrato, &input);
        let delay = ((MIN_DELAY_SECONDS + MAX_DELAY_SECONDS) * 0.5 * RATE as f32) as usize;
        assert_eq!(delay, 336);
        for index in delay..input.len() {
            assert!(
                (output[index] - input[index - delay]).abs() < 1e-6,
                "the fixed delay was not the centre at {index}"
            );
        }
    }

    #[test]
    fn depth_moves_the_pitch() {
        let input = sine(440.0, 0.4, 8192);
        let mut flat = Vibrato::new(5.0, 0.0);
        let flat = render(&mut flat, &input);
        let mut bent = Vibrato::new(5.0, 1.0);
        let bent = render(&mut bent, &input);
        assert_ne!(flat, bent, "depth did not bend the pitch");
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 8192);
        let mut vibrato = Vibrato::new(20.0, 1.0);
        vibrato.prepare(RATE, input.len());
        let mut first = input.clone();
        vibrato.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));

        vibrato.reset();
        let mut second = input.clone();
        vibrato.process(&mut second);
        assert_eq!(first, second, "reset did not return to the first run");
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut vibrato = Vibrato::new(5.0, 0.4);
        assert!(vibrato.set("rate", 100.0));
        assert_eq!(vibrato.target_hz, Vibrato::MAX_RATE_HZ);
        assert!(vibrato.set("rate", 0.0));
        assert_eq!(vibrato.target_hz, Vibrato::MIN_RATE_HZ);
        assert!(vibrato.set("depth", 10.0));
        assert_eq!(vibrato.target_depth, 1.0);
        assert!(vibrato.set("depth", f32::NAN));
        assert_eq!(vibrato.target_depth, 1.0, "NaN moved a knob");
        assert!(!vibrato.set("mix", 0.5), "vibrato has no dry path");
        assert!(!vibrato.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("vibrato"), Some(InsertKind::Vibrato));
        assert_eq!(InsertKind::Vibrato.name(), "vibrato");
        assert_eq!(InsertKind::Vibrato.controls(), &["rate", "depth"]);
        assert_eq!(InsertKind::Vibrato.code(), 26);
        assert_eq!(InsertKind::from_code(26), Some(InsertKind::Vibrato));
        assert_eq!(InsertKind::Vibrato.build().name(), "vibrato");
    }
}
