//! The `tremolo` insert: a mono amplitude modulator with three LFO shapes.
//!
//! # The model
//!
//! ```text
//!       lfo (sine | triangle | square)
//!              │
//!              ▼
//! in ────────►×────────► out
//!              ▲
//!        1 − depth/2 + (depth/2)·lfo
//! ```
//!
//! The gain sits between `1 − depth` and `1`: at `depth = 1` the sine and
//! triangle shapes reach silence at the trough, and the square shape hard
//! switches between unity and silence. That is the pedal's own full-depth
//! behaviour, so the square keeps its edges rather than being smoothed into a
//! triangle. Only the knob moves are smoothed ([`SMOOTH_SECONDS`]): a rate or
//! depth drag travels to its target instead of stepping at a block edge.
//!
//! `rate` is Hz (0.1..20), `depth` is the normalised 0..1 knob the control path
//! sends, and `shape` is the whole index 0 sine, 1 triangle, 2 square. Tempo
//! sync is a page concern: the browser resolves a note division into Hz and
//! sends that as `rate`, so there is no `sync` control here. Silence stays
//! exactly silent because the pedal is a multiplication and holds no state in
//! the signal path.

use super::{one_pole, Effect, SMOOTH_SECONDS};
use std::f32::consts::TAU;

#[derive(Debug)]
pub struct Tremolo {
    rate: u32,
    target_hz: f32,
    hz: f32,
    target_depth: f32,
    depth: f32,
    shape: u8,
    phase: f32,
    smooth: f32,
}

impl Tremolo {
    pub const MIN_RATE_HZ: f32 = 0.1;
    pub const MAX_RATE_HZ: f32 = 20.0;
    /// The shape indexes both implementations share (`docs/studio-effects.md`).
    pub const SHAPES: [&'static str; 3] = ["sine", "triangle", "square"];

    pub fn new(rate_hz: f32, depth: f32, shape: u8) -> Self {
        let hz = rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
        let depth = depth.clamp(0.0, 1.0);
        Tremolo {
            rate: 48_000,
            target_hz: hz,
            hz,
            target_depth: depth,
            depth,
            shape: shape.min(2),
            phase: 0.0,
            smooth: 0.0,
        }
    }

    /// The LFO at the current phase: -1 at the trough, +1 at the crest.
    #[inline]
    fn lfo(&self) -> f32 {
        let phase = self.phase - self.phase.floor();
        match self.shape {
            1 => 1.0 - 4.0 * (phase - 0.5).abs(),
            2 => {
                if phase < 0.5 {
                    1.0
                } else {
                    -1.0
                }
            }
            _ => (TAU * phase).sin(),
        }
    }
}

impl Effect for Tremolo {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.hz = self.target_hz;
        self.depth = self.target_depth;
        self.phase = 0.0;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() {
            return;
        }
        let rate = self.rate.max(1) as f32;
        for sample in block.iter_mut() {
            self.hz += (self.target_hz - self.hz) * self.smooth;
            self.depth += (self.target_depth - self.depth) * self.smooth;
            // A one-pole over the whole block would be cheaper, but the LFO's
            // phase must advance by the smoothed rate, so this loop is per
            // sample and does no allocation.
            let lfo = self.lfo();
            let gain = 1.0 - self.depth * 0.5 * (1.0 - lfo);
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
            "shape" => {
                if usable {
                    self.shape = value.round().clamp(0.0, 2.0) as u8;
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "tremolo"
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

    fn render(effect: &mut Tremolo, input: &[f32]) -> Vec<f32> {
        effect.prepare(RATE, input.len());
        let mut block = input.to_vec();
        effect.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut tremolo = Tremolo::new(5.0, 1.0, 0);
        let output = render(&mut tremolo, &vec![0.0f32; 4096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn depth_zero_is_unity() {
        let input = sine(220.0, 0.4, 1024);
        let mut tremolo = Tremolo::new(5.0, 0.0, 0);
        let output = render(&mut tremolo, &input);
        assert_eq!(output, input, "a zero-depth tremolo changed the signal");
    }

    #[test]
    fn the_rate_sets_the_lfo_frequency() {
        // A DC input makes the output the gain envelope itself. At 4 Hz a
        // one-second run passes the crest four times.
        let mut tremolo = Tremolo::new(4.0, 1.0, 0);
        let output = render(&mut tremolo, &vec![1.0f32; RATE as usize]);
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
    fn full_depth_reaches_silence_and_full_depth_inverts_nothing() {
        let mut tremolo = Tremolo::new(2.0, 1.0, 0);
        let output = render(&mut tremolo, &vec![1.0f32; RATE as usize]);
        let lowest = output.iter().fold(f32::INFINITY, |low, sample| low.min(*sample));
        let highest = output.iter().fold(-1.0f32, |high, sample| high.max(*sample));
        assert!(lowest < 0.01, "the trough did not reach silence: {lowest}");
        assert!(highest > 0.99, "the crest did not reach unity: {highest}");
        assert!(output.iter().all(|sample| *sample >= -1e-6));
    }

    #[test]
    fn the_three_shapes_are_distinct() {
        let input = vec![1.0f32; RATE as usize];
        let mut sine = Tremolo::new(1.0, 1.0, 0);
        let mut triangle = Tremolo::new(1.0, 1.0, 1);
        let mut square = Tremolo::new(1.0, 1.0, 2);
        let sine = render(&mut sine, &input);
        let triangle = render(&mut triangle, &input);
        let square = render(&mut square, &input);
        assert_ne!(sine, triangle, "the triangle matched the sine");
        assert_ne!(sine, square, "the square matched the sine");
        // The square is two levels; the sine between them is not.
        let square_levels = square
            .iter()
            .filter(|sample| **sample > 0.01 && **sample < 0.99)
            .count();
        let sine_levels = sine
            .iter()
            .filter(|sample| **sample > 0.01 && **sample < 0.99)
            .count();
        assert!(
            square_levels < sine_levels / 10,
            "the square was not two-level ({square_levels} against {sine_levels})"
        );
    }

    #[test]
    fn reset_matches_the_first_run() {
        let input = sine(440.0, 0.3, 4096);
        let mut tremolo = Tremolo::new(3.0, 0.7, 0);
        let first = render(&mut tremolo, &input);
        tremolo.reset();
        let mut second = input.clone();
        tremolo.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut tremolo = Tremolo::new(5.0, 0.5, 0);
        assert!(tremolo.set("rate", 100.0));
        assert_eq!(tremolo.target_hz, Tremolo::MAX_RATE_HZ);
        assert!(tremolo.set("rate", 0.0));
        assert_eq!(tremolo.target_hz, Tremolo::MIN_RATE_HZ);
        assert!(tremolo.set("depth", 10.0));
        assert_eq!(tremolo.target_depth, 1.0);
        assert!(tremolo.set("shape", 9.0));
        assert_eq!(tremolo.shape, 2);
        assert!(tremolo.set("rate", f32::NAN));
        assert_eq!(tremolo.target_hz, Tremolo::MIN_RATE_HZ);
        assert!(!tremolo.set("sync", 1.0), "sync is not an engine control");
        assert!(!tremolo.set("mix", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("tremolo"), Some(InsertKind::Tremolo));
        assert_eq!(InsertKind::Tremolo.name(), "tremolo");
        assert_eq!(
            InsertKind::Tremolo.controls(),
            &["rate", "depth", "shape"]
        );
        assert_eq!(InsertKind::Tremolo.code(), 14);
        assert_eq!(InsertKind::from_code(14), Some(InsertKind::Tremolo));
        assert_eq!(InsertKind::Tremolo.build().name(), "tremolo");
        // The panner is native, but configures the channel's pan stage.
        assert_eq!(
            InsertKind::parse("stereo_panner"),
            Some(InsertKind::StereoPanner)
        );
    }
}
