//! The `modulator` pedal: an LFO ring modulator with a depth control.
//!
//! # The model
//!
//! ```text
//!              sin(2π · rate · t)
//!                       │
//!                       ▼
//! wet = in · ((1 − depth) + depth · sin)
//! out = dry · (1 − mix) + wet · mix
//! ```
//!
//! It is the ring modulator's sum-and-difference sound, softened by `depth`:
//! at `depth = 1` the input is multiplied by a full-swing carrier, so the
//! output holds only the sidebands; at `depth = 0` the carrier term is a plain
//! gain of one and the pedal is transparent. `mix` blends the modulated copy
//! with the dry signal.
//!
//! `rate` is Hz (0.1..20), `depth` and `mix` are the normalised 0..1 knobs the
//! control path sends. The contract's page owns tempo sync: a note division is
//! resolved to Hz before it arrives, so there is no `sync` control here.
//!
//! # The honest approximation
//!
//! * The carrier is a low-frequency sine, not an audio-rate oscillator. That is
//!   the contract's `rate` range, so the sound is a slow amplitude "wobble" with
//!   sidebands around a held note rather than a classic guitar ring mod; the
//!   formula is the real one either way.
//! * The carrier restarts at phase zero on every `prepare`/`reset`, so a
//!   restarted block is repeatable; there is no free-running oscillator to sync
//!   to other inserts.
//! * Knob moves are one-pole smoothed; the carrier itself advances per sample,
//!   so the modulation is continuous.
//!
//! Silence stays exactly silent: the pedal only multiplies, and it holds no
//! state in the signal path beyond the carrier phase.

use super::{one_pole, Effect, SMOOTH_SECONDS};
use std::f32::consts::TAU;

#[derive(Debug)]
pub struct Modulator {
    rate: u32,
    target_hz: f32,
    hz: f32,
    target_depth: f32,
    depth: f32,
    target_mix: f32,
    mix: f32,
    phase: f32,
    smooth: f32,
}

impl Modulator {
    pub const MIN_RATE_HZ: f32 = 0.1;
    pub const MAX_RATE_HZ: f32 = 20.0;

    pub fn new(rate_hz: f32, depth: f32, mix: f32) -> Self {
        let hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        let mix = mix.clamp(0.0, 1.0);
        Modulator {
            rate: 48_000,
            target_hz: hz,
            hz,
            target_depth: depth,
            depth,
            target_mix: mix,
            mix,
            phase: 0.0,
            smooth: 0.0,
        }
    }
}

impl Effect for Modulator {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.mix = self.target_mix;
        self.phase = 0.0;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() || self.rate == 0 {
            return;
        }
        let rate = self.rate as f32;
        for sample in block.iter_mut() {
            self.hz += (self.target_hz - self.hz) * self.smooth;
            self.depth += (self.target_depth - self.depth) * self.smooth;
            self.mix += (self.target_mix - self.mix) * self.smooth;

            let carrier = (TAU * self.phase).sin();
            let dry = *sample;
            let wet = dry * ((1.0 - self.depth) + self.depth * carrier);
            *sample = dry * (1.0 - self.mix) + wet * self.mix;

            self.phase += (self.hz / rate).clamp(0.0, 0.5);
            if self.phase >= 1.0 {
                self.phase -= 1.0;
            }
        }
    }

    fn reset(&mut self) {
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
        "modulator"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| (TAU * hz * index as f32 / RATE as f32).sin() * amplitude)
            .collect()
    }

    fn render(modulator: &mut Modulator, input: &[f32]) -> Vec<f32> {
        modulator.prepare(RATE, input.len());
        let mut block = input.to_vec();
        modulator.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut modulator = Modulator::new(5.0, 1.0, 1.0);
        let output = render(&mut modulator, &vec![0.0f32; 4096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn zero_depth_is_transparent_at_full_mix() {
        let input = sine(440.0, 0.4, 4096);
        let mut modulator = Modulator::new(5.0, 0.0, 1.0);
        let output = render(&mut modulator, &input);
        for (out, dry) in output.iter().zip(input.iter()) {
            assert!((out - dry).abs() < 1e-6, "zero depth coloured the signal");
        }
    }

    #[test]
    fn full_depth_and_mix_is_the_carrier() {
        // A DC input makes the output the carrier itself, so one second at 4 Hz
        // passes four crests.
        let mut modulator = Modulator::new(4.0, 1.0, 1.0);
        let output = render(&mut modulator, &vec![1.0f32; RATE as usize]);
        let mut crests = 0;
        let mut above = output[0] > 0.5;
        for sample in output.iter().skip(1) {
            let now = *sample > 0.5;
            if now && !above {
                crests += 1;
            }
            above = now;
        }
        assert!((3..=5).contains(&crests), "saw {crests} crests in one second");
    }

    #[test]
    fn reset_matches_the_first_run() {
        let input = sine(440.0, 0.3, 4096);
        let mut modulator = Modulator::new(3.0, 0.7, 0.5);
        let first = render(&mut modulator, &input);
        modulator.reset();
        let mut second = input.clone();
        modulator.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut modulator = Modulator::new(5.0, 0.5, 0.5);
        assert!(modulator.set("rate", 100.0));
        assert_eq!(modulator.target_hz, Modulator::MAX_RATE_HZ);
        assert!(modulator.set("rate", 0.0));
        assert_eq!(modulator.target_hz, Modulator::MIN_RATE_HZ);
        assert!(modulator.set("depth", 10.0));
        assert_eq!(modulator.target_depth, 1.0);
        assert!(modulator.set("mix", f32::NAN));
        assert_eq!(modulator.target_mix, 0.5, "NaN moved a knob");
        assert!(!modulator.set("shape", 1.0));
        assert!(!modulator.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("modulator"), Some(InsertKind::Modulator));
        assert_eq!(InsertKind::Modulator.name(), "modulator");
        assert_eq!(
            InsertKind::Modulator.controls(),
            &["rate", "depth", "mix"]
        );
        assert_eq!(InsertKind::Modulator.code(), 19);
        assert_eq!(InsertKind::from_code(19), Some(InsertKind::Modulator));
        assert_eq!(InsertKind::Modulator.build().name(), "modulator");
    }
}
