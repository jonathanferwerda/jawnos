//! The `wah` pedal: an LFO-swept resonant bandpass.
//!
//! # The model
//!
//! ```text
//!              sin(2π · rate · t)
//!                       │
//!                       ▼
//! centre = 1400 + 1100 · depth · lfo          (300 .. 2500 Hz)
//! in ──► bandpass (Q ≈ 4) ──► × mix ──┐
//!   │                                 ├──► out
//!   └──────────── × (1 − mix) ────────┘
//! ```
//!
//! A state-variable filter's bandpass output is swept by the LFO. The centre
//! sits at 300 Hz when the LFO is at its trough and 2500 Hz at its crest, scaled
//! by `depth`; `Q` is fixed at 4, the peaky resonance that makes a wah speak.
//! `mix` blends the swept band with the dry signal, so the pedal can sit behind
//! the note or take it over.
//!
//! `rate` is Hz (0.1..20), `depth` and `mix` are 0..1. Tempo sync is the page's
//! business; it resolves a division into `rate`, so there is no `sync` control.
//!
//! # The honest approximation
//!
//! * A real wah is a variable-gain feedback filter around a transistor, with
//!   the sweep coming from the treadle's own law; this is a swept state-variable
//!   bandpass with a sine LFO. It has the moving resonance, not the treadle.
//! * The cutoff coefficient uses `f ≈ 2π·fc/fs`, the small-angle form, which is
//!   within a fraction of a percent at these corners and 48 kHz and keeps the
//!   per-sample sweep free of trigonometry. It is clamped below the stability
//!   limit at any rate.
//! * `depth = 0` parks the filter at the centre; it does not remove the pedal,
//!   because the band and its Q are still there.
//! * Knob moves are one-pole smoothed; the LFO advances per sample. Silence
//!   stays exactly silent: the filter is fed zero and the mix is linear.

use super::{one_pole, Effect, SMOOTH_SECONDS};
use std::f32::consts::TAU;

const MIN_CENTRE_HZ: f32 = 300.0;
const MAX_CENTRE_HZ: f32 = 2_500.0;
/// `1/Q` for the state variable: Q 4 is the pedal's resonant peak.
const DAMPING: f32 = 0.25;

#[derive(Debug)]
pub struct Wah {
    rate: u32,
    target_hz: f32,
    hz: f32,
    target_depth: f32,
    depth: f32,
    target_mix: f32,
    mix: f32,
    low: f32,
    band: f32,
    phase: f32,
    smooth: f32,
}

impl Wah {
    pub const MIN_RATE_HZ: f32 = 0.1;
    pub const MAX_RATE_HZ: f32 = 20.0;

    pub fn new(rate_hz: f32, depth: f32, mix: f32) -> Self {
        let hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        let mix = mix.clamp(0.0, 1.0);
        Wah {
            rate: 48_000,
            target_hz: hz,
            hz,
            target_depth: depth,
            depth,
            target_mix: mix,
            mix,
            low: 0.0,
            band: 0.0,
            phase: 0.0,
            smooth: 0.0,
        }
    }
}

impl Effect for Wah {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.mix = self.target_mix;
        self.low = 0.0;
        self.band = 0.0;
        self.phase = 0.0;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() || self.rate == 0 {
            return;
        }
        let rate = self.rate as f32;
        let centre = (MIN_CENTRE_HZ + MAX_CENTRE_HZ) * 0.5;
        let half_span = (MAX_CENTRE_HZ - MIN_CENTRE_HZ) * 0.5;
        let top = (rate * 0.45).min(MAX_CENTRE_HZ);
        // Normalise the SVF's band output so its peak is near unity.
        let wet_gain = DAMPING;
        for sample in block.iter_mut() {
            self.hz += (self.target_hz - self.hz) * self.smooth;
            self.depth += (self.target_depth - self.depth) * self.smooth;
            self.mix += (self.target_mix - self.mix) * self.smooth;

            let lfo = (TAU * self.phase).sin();
            let corner = (centre + half_span * self.depth * lfo).clamp(20.0, top);
            let f = (TAU * corner / rate).clamp(0.0, 1.0);

            let dry = *sample;
            let high = dry - self.low - DAMPING * self.band;
            self.band += f * high;
            self.low += f * self.band;
            let wet = self.band * wet_gain;

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
        self.low = 0.0;
        self.band = 0.0;
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
        "wah"
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

    fn render(wah: &mut Wah, input: &[f32]) -> Vec<f32> {
        wah.prepare(RATE, input.len());
        let mut block = input.to_vec();
        wah.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut wah = Wah::new(2.0, 0.7, 1.0);
        let output = render(&mut wah, &vec![0.0f32; 4096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn zero_mix_is_the_dry_signal() {
        let input = sine(440.0, 0.4, 4096);
        let mut wah = Wah::new(2.0, 0.7, 0.0);
        let output = render(&mut wah, &input);
        assert_eq!(output, input, "mix 0 coloured the signal");
    }

    #[test]
    fn the_resonance_sits_near_the_centre_at_zero_depth() {
        // With depth 0 the corner is 1400 Hz, so a tone there passes the band
        // far better than one an octave below.
        let source = sine(1_400.0, 0.3, 24_000);
        let mut wah = Wah::new(0.1, 0.0, 1.0);
        let at_centre = rms(&render(&mut wah, &source)[4_800..]);
        let source = sine(400.0, 0.3, 24_000);
        let mut wah = Wah::new(0.1, 0.0, 1.0);
        let below = rms(&render(&mut wah, &source)[4_800..]);
        assert!(
            at_centre > below * 2.0,
            "the band did not pass its centre: {at_centre} against {below}"
        );
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 8192);
        let mut wah = Wah::new(20.0, 1.0, 1.0);
        wah.prepare(RATE, input.len());
        let mut first = input.clone();
        wah.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));

        wah.reset();
        let mut second = input.clone();
        wah.process(&mut second);
        assert_eq!(first, second, "reset did not return to the first run");
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut wah = Wah::new(2.0, 0.7, 0.5);
        assert!(wah.set("rate", 100.0));
        assert_eq!(wah.target_hz, Wah::MAX_RATE_HZ);
        assert!(wah.set("rate", 0.0));
        assert_eq!(wah.target_hz, Wah::MIN_RATE_HZ);
        assert!(wah.set("depth", 10.0));
        assert_eq!(wah.target_depth, 1.0);
        assert!(wah.set("mix", 10.0));
        assert_eq!(wah.target_mix, 1.0);
        assert!(wah.set("mix", f32::NAN));
        assert_eq!(wah.target_mix, 1.0, "NaN moved a knob");
        assert!(!wah.set("feedback", 1.0));
        assert!(!wah.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("wah"), Some(InsertKind::Wah));
        assert_eq!(InsertKind::Wah.name(), "wah");
        assert_eq!(InsertKind::Wah.controls(), &["rate", "depth", "mix"]);
        assert_eq!(InsertKind::Wah.code(), 24);
        assert_eq!(InsertKind::from_code(24), Some(InsertKind::Wah));
        assert_eq!(InsertKind::Wah.build().name(), "wah");
    }
}
