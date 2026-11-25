//! The `phaser` pedal: an MXR Phase 90, approximated.
//!
//! # Why the Phase 90
//!
//! The Phase 90 is four JFET allpass stages swept together by an LFO, summed
//! with the dry signal at a fixed 50/50 blend: the blend is what turns the
//! allpasses' phase shift into the moving notches the pedal is bought for. Its
//! one knob is Speed, which is the contract's `rate`. The contract also carries
//! `depth`, `feedback` and `mix`; the real pedal has none of those (the sweep
//! span, the notch sharpness and the blend are fixed), so those three are
//! documented mods (`docs/pedal-audit.md`): `depth` sets how far the LFO moves
//! the corner, `feedback` returns the last stage to the input for resonance on
//! the notches, and `mix` moves the fixed 50/50 blend.
//!
//! # The circuit
//!
//! ```text
//!              lfo (0.05..5 Hz) sweeps every allpass corner
//!                              │
//!                              ▼
//! in ──┬──► AP1 ──► AP2 ──► AP3 ──► AP4 ──┬──► × mix ──┐
//!      │                                │             ├──► out
//!      │                                └──► fb ──────┘
//!      │                                           (last stage to input)
//!      └────────────────────── × (1 − mix) ────────────┘
//! ```
//!
//! Each stage is the first-order allpass
//!
//! ```text
//! y[n] = a·x[n] + x[n−1] − a·y[n−1],
//! a = (1 − tan(π·fc/fs)) / (1 + tan(π·fc/fs))
//! ```
//!
//! At `fc → 0` the coefficient is `+1` and the stage is transparent; at
//! `fc → Nyquist` it is `−1` and the stage inverts. Sweeping `fc` therefore
//! sweeps the phase, and summing that against the dry signal moves a comb of
//! notches. Four stages give the Phase 90's two audible notches in the band.
//!
//! # The honest approximation
//!
//! * The four stages share one corner, as the Phase 90's matched JFET stages
//!   do; the browser staggers its four biquads slightly for a wider sweep, so
//!   the two sides agree on the sound, not on the exact notch positions.
//! * The JFET is a first-order allpass, not a solved transistor. There is no
//!   JFET pinch-off or control-voltage law: the corner follows the LFO
//!   linearly in hertz.
//! * `feedback` is a documented mod. The real pedal has none, and the loop is
//!   clamped below unity (`MAX_FEEDBACK`) so a swept allpass cannot build into
//!   a runaway.
//! * The knobs are one-pole smoothed once per block ([`SMOOTH_SECONDS`]), so a
//!   live knob or socket move cannot click. The LFO still advances per sample,
//!   so the sweep itself is smooth.
//!
//! `rate` is Hz (the manual knob's 0.05..5 band), `depth`, `feedback` and `mix`
//! are the normalised 0..1 knobs the control path sends. At `mix = 0.5` the
//! dry and wet sums give the classic notches; `mix = 1` is the allpass alone.

use super::{one_pole_block, Effect, SMOOTH_SECONDS};
use std::f32::consts::{PI, TAU};

/// The Phase 90's four JFET allpass stages.
const STAGES: usize = 4;

#[derive(Debug)]
pub struct Phaser {
    rate: u32,
    target_hz: f32,
    hz: f32,
    target_depth: f32,
    depth: f32,
    target_feedback: f32,
    feedback: f32,
    target_mix: f32,
    mix: f32,
    phase: f32,
    /// Each stage's `x[n−1]` and `y[n−1]`.
    x1: [f32; STAGES],
    y1: [f32; STAGES],
    /// The last stage's output, returned to the input for resonance.
    last: f32,
}

impl Phaser {
    pub const MIN_RATE_HZ: f32 = 0.05;
    /// The manual knob stops at 5 Hz; the page's tempo limits use the same band,
    /// so a synced rate never asks for more.
    pub const MAX_RATE_HZ: f32 = 5.0;
    /// The band the one corner sweeps over at full depth: the Phase 90's own
    /// low-mid range, where a guitar's notches are heard.
    pub const MIN_FREQ_HZ: f32 = 200.0;
    pub const MAX_FREQ_HZ: f32 = 2_000.0;
    /// Feedback is a mod and stops short of unity: an allpass has unit
    /// magnitude, so a loop gain below 1 is stable at every corner.
    pub const MAX_FEEDBACK: f32 = 0.9;

    pub fn new(rate_hz: f32, depth: f32, feedback: f32, mix: f32) -> Self {
        let hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        let feedback = feedback.clamp(0.0, Self::MAX_FEEDBACK);
        let mix = mix.clamp(0.0, 1.0);
        Phaser {
            rate: 48_000,
            target_hz: hz,
            hz,
            target_depth: depth,
            depth,
            target_feedback: feedback,
            feedback,
            target_mix: mix,
            mix,
            phase: 0.0,
            x1: [0.0; STAGES],
            y1: [0.0; STAGES],
            last: 0.0,
        }
    }

    /// The allpass coefficient for a corner, in hertz.
    #[inline]
    fn coefficient(rate: f32, corner_hz: f32) -> f32 {
        let tangent = (PI * corner_hz / rate).tan();
        (1.0 - tangent) / (1.0 + tangent)
    }
}

impl Effect for Phaser {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.feedback = self.target_feedback;
        self.mix = self.target_mix;
        self.phase = 0.0;
        self.x1 = [0.0; STAGES];
        self.y1 = [0.0; STAGES];
        self.last = 0.0;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() || self.rate == 0 {
            return;
        }
        // The knobs move once per block; the LFO moves every sample. A knob
        // jump therefore travels over several blocks instead of stepping.
        let smooth = one_pole_block(SMOOTH_SECONDS, self.rate, block.len()) as f32;
        self.hz += (self.target_hz - self.hz) * smooth;
        self.depth += (self.target_depth - self.depth) * smooth;
        self.feedback += (self.target_feedback - self.feedback) * smooth;
        self.mix += (self.target_mix - self.mix) * smooth;

        let rate = self.rate as f32;
        let centre = (Self::MIN_FREQ_HZ + Self::MAX_FREQ_HZ) * 0.5;
        let half_span = (Self::MAX_FREQ_HZ - Self::MIN_FREQ_HZ) * 0.5;
        let top = rate * 0.45;
        let mix = self.mix;
        let feedback = self.feedback;

        for sample in block.iter_mut() {
            let lfo = (TAU * self.phase).sin();
            let corner = (centre + half_span * self.depth * lfo).clamp(20.0, top);
            let a = Self::coefficient(rate, corner);

            let dry = *sample;
            let mut value = dry + feedback * self.last;
            for stage in 0..STAGES {
                let output = a * value + self.x1[stage] - a * self.y1[stage];
                self.x1[stage] = value;
                self.y1[stage] = output;
                value = output;
            }
            self.last = value;

            *sample = dry * (1.0 - mix) + value * mix;

            self.phase += self.hz / rate;
            self.phase -= self.phase.floor();
        }
    }

    fn reset(&mut self) {
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.feedback = self.target_feedback;
        self.mix = self.target_mix;
        self.phase = 0.0;
        self.x1 = [0.0; STAGES];
        self.y1 = [0.0; STAGES];
        self.last = 0.0;
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
        "phaser"
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

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    fn render(phaser: &mut Phaser, input: &[f32]) -> Vec<f32> {
        phaser.prepare(RATE, input.len());
        let mut block = input.to_vec();
        phaser.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut phaser = Phaser::new(1.04, 1.0, 0.9, 1.0);
        let output = render(&mut phaser, &vec![0.0f32; 4_096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn full_wet_is_all_pass_and_level_sane() {
        // With no feedback and mix 1 the pedal is the allpass alone, whose
        // magnitude is exactly 1, so a settled tone keeps its level.
        let input = sine(440.0, 0.3, 48_000);
        let mut phaser = Phaser::new(1.04, 0.5, 0.0, 1.0);
        let output = render(&mut phaser, &input);
        let before = rms(&input[4_096..]);
        let after = rms(&output[4_096..]);
        let ratio = after / before;
        assert!(
            (0.95..=1.05).contains(&ratio),
            "the allpass changed the level: {ratio}"
        );
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 4_096);
        let mut phaser = Phaser::new(5.0, 1.0, 0.9, 1.0);
        phaser.prepare(RATE, 4_096);
        let mut first = input.clone();
        phaser.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));
        assert!(rms(&first) > 0.0);

        phaser.reset();
        let mut second = input.clone();
        phaser.process(&mut second);
        assert_eq!(first, second, "reset did not return to the first run");
    }

    #[test]
    fn every_control_is_recognised_and_junk_is_not() {
        let mut phaser = Phaser::new(1.04, 0.5, 0.25, 0.5);
        for name in ["rate", "depth", "feedback", "mix"] {
            assert!(phaser.set(name, 0.25), "phaser.{name} was not recognised");
        }
        assert!(!phaser.set("shape", 1.0));
        assert!(!phaser.set("sync", 1.0), "sync is not an engine control");
        assert!(phaser.set("mix", f32::NAN));
        assert_eq!(phaser.target_mix, 0.25, "NaN moved a knob");
    }

    #[test]
    fn knobs_clamp_to_their_ranges() {
        let mut phaser = Phaser::new(1.04, 0.5, 0.25, 0.5);
        phaser.set("rate", 100.0);
        assert_eq!(phaser.target_hz, Phaser::MAX_RATE_HZ);
        phaser.set("rate", 0.0);
        assert_eq!(phaser.target_hz, Phaser::MIN_RATE_HZ);
        phaser.set("depth", -1.0);
        assert_eq!(phaser.target_depth, 0.0);
        phaser.set("feedback", 10.0);
        assert_eq!(phaser.target_feedback, Phaser::MAX_FEEDBACK);
        phaser.set("mix", 10.0);
        assert_eq!(phaser.target_mix, 1.0);
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("phaser"), Some(InsertKind::Phaser));
        assert_eq!(InsertKind::Phaser.name(), "phaser");
        assert_eq!(
            InsertKind::Phaser.controls(),
            &["rate", "depth", "feedback", "mix"]
        );
        assert_eq!(InsertKind::Phaser.code(), 16);
        assert_eq!(InsertKind::from_code(16), Some(InsertKind::Phaser));
        assert_eq!(InsertKind::Phaser.build().name(), "phaser");
    }
}
