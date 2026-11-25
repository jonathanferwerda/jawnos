//! The `slider` pedal: a hard-cutting square tremolo ("chopper").
//!
//! # The model
//!
//! ```text
//!              phase < duty ?
//!                    │
//!        ┌───────────┴───────────┐
//!        ▼ yes                   ▼ no
//!     gain 1               gain 1 − depth
//!        └───────────┬───────────┘
//!                    ▼
//! in ───────────────►×──────────► out
//! ```
//!
//! The LFO is a square and its edge is the pedal: one instant at unity, the
//! next at `1 − depth`, exactly like the tremolo's square shape but with a
//! `duty` control so the open fraction of the cycle can be set from 5% to 95%.
//! Only the knob moves are one-pole smoothed; smearing the gain itself would
//! turn the chopper back into a tremolo and lose what it is for.
//!
//! `rate` is Hz (0.1..20), `depth` is 0..1, and `duty` is the open fraction
//! (0.05..0.95). The page resolves tempo sync into `rate` before sending, so
//! there is no `sync` control here. Silence stays exactly silent: the pedal is
//! a multiplication with no state in the signal path.

use super::{one_pole, Effect, SMOOTH_SECONDS};

#[derive(Debug)]
pub struct Slider {
    rate: u32,
    target_hz: f32,
    hz: f32,
    target_depth: f32,
    depth: f32,
    target_duty: f32,
    duty: f32,
    phase: f32,
    smooth: f32,
}

impl Slider {
    pub const MIN_RATE_HZ: f32 = 0.1;
    pub const MAX_RATE_HZ: f32 = 20.0;
    pub const MIN_DUTY: f32 = 0.05;
    pub const MAX_DUTY: f32 = 0.95;

    pub fn new(rate_hz: f32, depth: f32, duty: f32) -> Self {
        let hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        let duty = duty.clamp(Self::MIN_DUTY, Self::MAX_DUTY);
        Slider {
            rate: 48_000,
            target_hz: hz,
            hz,
            target_depth: depth,
            depth,
            target_duty: duty,
            duty,
            phase: 0.0,
            smooth: 0.0,
        }
    }
}

impl Effect for Slider {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.duty = self.target_duty;
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
            self.duty += (self.target_duty - self.duty) * self.smooth;

            let gain = if self.phase < self.duty {
                1.0
            } else {
                1.0 - self.depth
            };
            *sample *= gain;

            self.phase += (self.hz / rate).clamp(0.0, 0.5);
            if self.phase >= 1.0 {
                self.phase -= 1.0;
            }
        }
    }

    fn reset(&mut self) {
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.duty = self.target_duty;
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
            "duty" => {
                if usable {
                    self.target_duty = value.clamp(Self::MIN_DUTY, Self::MAX_DUTY);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "slider"
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

    fn render(slider: &mut Slider, input: &[f32]) -> Vec<f32> {
        slider.prepare(RATE, input.len());
        let mut block = input.to_vec();
        slider.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut slider = Slider::new(6.0, 0.8, 0.5);
        let output = render(&mut slider, &vec![0.0f32; 4096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn zero_depth_is_transparent() {
        let input = sine(440.0, 0.4, 4096);
        let mut slider = Slider::new(6.0, 0.0, 0.25);
        let output = render(&mut slider, &input);
        assert_eq!(output, input, "a zero-depth slider changed the signal");
    }

    #[test]
    fn the_output_is_two_levels() {
        // A DC input makes the output the gain itself: only 1 and 1 − depth.
        let mut slider = Slider::new(6.0, 1.0, 0.5);
        let output = render(&mut slider, &vec![1.0f32; RATE as usize]);
        let middle = output
            .iter()
            .filter(|sample| **sample > 1e-6 && **sample < 0.999_999)
            .count();
        assert_eq!(middle, 0, "the edge was smoothed into a ramp");
    }

    #[test]
    fn duty_sets_the_open_fraction() {
        let input = vec![1.0f32; RATE as usize];
        let mut slider = Slider::new(10.0, 1.0, 0.25);
        let output = render(&mut slider, &input);
        let open = output.iter().filter(|sample| **sample > 0.5).count();
        let fraction = open as f32 / output.len() as f32;
        assert!(
            (fraction - 0.25).abs() < 0.02,
            "duty 0.25 opened {fraction} of the run"
        );
    }

    #[test]
    fn the_rate_sets_the_chop_count() {
        let mut slider = Slider::new(4.0, 1.0, 0.5);
        let output = render(&mut slider, &vec![1.0f32; RATE as usize]);
        let mut opens = 0;
        let mut open = output[0] > 0.5;
        for sample in output.iter().skip(1) {
            let now = *sample > 0.5;
            if now && !open {
                opens += 1;
            }
            open = now;
        }
        assert!((3..=5).contains(&opens), "saw {opens} chops in one second");
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut slider = Slider::new(6.0, 0.8, 0.5);
        assert!(slider.set("rate", 100.0));
        assert_eq!(slider.target_hz, Slider::MAX_RATE_HZ);
        assert!(slider.set("rate", 0.0));
        assert_eq!(slider.target_hz, Slider::MIN_RATE_HZ);
        assert!(slider.set("depth", 10.0));
        assert_eq!(slider.target_depth, 1.0);
        assert!(slider.set("duty", 0.0));
        assert_eq!(slider.target_duty, Slider::MIN_DUTY);
        assert!(slider.set("duty", 2.0));
        assert_eq!(slider.target_duty, Slider::MAX_DUTY);
        assert!(slider.set("duty", f32::NAN));
        assert_eq!(slider.target_duty, Slider::MAX_DUTY);
        assert!(!slider.set("shape", 1.0));
        assert!(!slider.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("slider"), Some(InsertKind::Slider));
        assert_eq!(InsertKind::Slider.name(), "slider");
        assert_eq!(
            InsertKind::Slider.controls(),
            &["rate", "depth", "duty"]
        );
        assert_eq!(InsertKind::Slider.code(), 22);
        assert_eq!(InsertKind::from_code(22), Some(InsertKind::Slider));
        assert_eq!(InsertKind::Slider.build().name(), "slider");
    }
}
