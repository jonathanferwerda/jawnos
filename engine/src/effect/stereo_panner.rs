//! The `stereo_panner` insert: a channel pan LFO configured from the chain.
//!
//! # The model
//!
//! The insert chain is mono — an insert hands one channel to the next — and the
//! L/R pair exists only at the channel's pan stage. A true panner therefore
//! cannot live *inside* the chain without a second buffer and a fake mono fold.
//! Instead this insert is a transparent pass-through that carries an LFO
//! configuration, and [`Channel`](super::Channel) applies that LFO to the
//! channel's own equal-power pan:
//!
//! ```text
//! in ──► inserts (stereo_panner passes through) ──► pan stage ──► L, R
//!                                                      ▲
//!                                    pan + depth · lfo(rate, shape)
//! ```
//!
//! `rate` is Hz (0.1..20), `depth` is the normalised 0..1 knob the control path
//! sends, and `shape` is the shared whole index 0 sine, 1 triangle, 2 square
//! (`docs/studio-effects.md`). The LFO swings around the channel's static pan
//! and is clamped to the -1..1 field, so a centred channel reaches both
//! speakers and a hard-left one reaches the middle. At `depth = 0` the channel
//! takes its plain-pan path untouched, so the pedal is bit-identically
//! transparent.
//!
//! The effect itself is stateless: the phase lives in the channel, the only
//! place that knows the sample rate and the block boundary. That keeps
//! `prepare` allocation-free and `process` a no-op. When the rack holds more
//! than one panner, the last one in chain order wins; a bypassed panner is not
//! run, so it configures nothing, like every bypassed insert.
//!
//! Tempo sync is a page concern: the browser resolves a note division into Hz
//! and sends that as `rate`, so there is no `sync` control here.

use super::Effect;

/// The LFO a `stereo_panner` insert hands to its channel. It is a plain value,
/// not state: the channel owns the phase and advances it per sample.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PanLfo {
    /// The resolved LFO rate in hertz (the browser's `sync` already resolved).
    pub rate_hz: f32,
    /// The swing in the -1..1 pan field, 0..1.
    pub depth: f32,
    /// 0 sine, 1 triangle, 2 square.
    pub shape: u8,
}

impl PanLfo {
    /// The LFO at `phase`, in turns (`0..1`): -1 at the trough, +1 at the crest.
    #[inline]
    pub fn value(&self, phase: f32) -> f32 {
        let phase = phase - phase.floor();
        match self.shape {
            1 => 1.0 - 4.0 * (phase - 0.5).abs(),
            2 => {
                if phase < 0.5 {
                    1.0
                } else {
                    -1.0
                }
            }
            _ => (std::f32::consts::TAU * phase).sin(),
        }
    }

    /// How far the phase travels in one sample at `sample_rate`. The clamp
    /// mirrors the tremolo so a corrupt rate can never run the LFO backwards
    /// or leap farther than half a cycle in one sample.
    #[inline]
    pub fn phase_step(&self, sample_rate: u32) -> f32 {
        if sample_rate == 0 {
            0.0
        } else {
            (self.rate_hz / sample_rate as f32).clamp(0.0, 0.5)
        }
    }
}

/// The insert. It does not touch the mono signal; it only says how the channel
/// should move its pan.
#[derive(Debug)]
pub struct StereoPanner {
    hz: f32,
    depth: f32,
    shape: u8,
}

impl StereoPanner {
    pub const MIN_RATE_HZ: f32 = 0.1;
    pub const MAX_RATE_HZ: f32 = 20.0;
    /// The shape indexes both implementations share (`docs/studio-effects.md`).
    pub const SHAPES: [&'static str; 3] = ["sine", "triangle", "square"];

    pub fn new(rate_hz: f32, depth: f32, shape: u8) -> Self {
        StereoPanner {
            hz: rate_hz.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ),
            depth: depth.clamp(0.0, 1.0),
            shape: shape.min(2),
        }
    }

    /// The configuration the channel reads after the chain has run.
    pub fn lfo(&self) -> PanLfo {
        PanLfo {
            rate_hz: self.hz,
            depth: self.depth,
            shape: self.shape,
        }
    }
}

impl Effect for StereoPanner {
    fn prepare(&mut self, _rate: u32, _max_frames: usize) {
        // Nothing to size: the channel owns the phase and the pan applies the
        // LFO itself. Kept so the chain's prepare contract holds.
    }

    fn process(&mut self, _block: &mut [f32]) {
        // A pass-through by design: the pan is a channel stage, not a mono
        // per-sample operation.
    }

    fn reset(&mut self) {
        // Stateless. The channel resets its own phase, which is what restarts
        // the sweep.
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "rate" => {
                if usable {
                    self.hz = value.clamp(Self::MIN_RATE_HZ, Self::MAX_RATE_HZ);
                }
                true
            }
            "depth" => {
                if usable {
                    self.depth = value.clamp(0.0, 1.0);
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
        "stereo_panner"
    }

    fn pan_lfo(&self) -> Option<PanLfo> {
        Some(self.lfo())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shapes as the channel would sample them over one full cycle:
    /// 64 points, so every shape is exercised at the same phases.
    fn cycle(lfo: PanLfo) -> Vec<f32> {
        (0..64).map(|index| lfo.value(index as f32 / 64.0)).collect()
    }

    fn shape(shape: u8) -> PanLfo {
        PanLfo {
            rate_hz: 1.0,
            depth: 1.0,
            shape,
        }
    }

    #[test]
    fn the_sine_shape_starts_and_ends_at_zero() {
        let sine = shape(0);
        assert!(sine.value(0.0).abs() < 1e-6);
        assert!(sine.value(0.5).abs() < 1e-6);
        assert!((sine.value(0.25) - 1.0).abs() < 1e-6);
        assert!((sine.value(0.75) + 1.0).abs() < 1e-6);
        assert!(sine.value(1.0).abs() < 1e-6, "the turn must wrap to the start");
    }

    #[test]
    fn the_triangle_shape_is_linear_between_the_edges() {
        let triangle = shape(1);
        assert!((triangle.value(0.0) + 1.0).abs() < 1e-6);
        assert!(triangle.value(0.25).abs() < 1e-6);
        assert!((triangle.value(0.5) - 1.0).abs() < 1e-6);
        assert!(triangle.value(0.75).abs() < 1e-6);
        assert!((triangle.value(1.0) + 1.0).abs() < 1e-6);
    }

    #[test]
    fn the_square_shape_is_two_levels() {
        let square = cycle(shape(2));
        assert!(square.iter().all(|sample| *sample == 1.0 || *sample == -1.0));
        assert!(square[..32].iter().all(|sample| *sample == 1.0));
        assert!(square[32..].iter().all(|sample| *sample == -1.0));
    }

    #[test]
    fn the_three_shapes_are_distinct() {
        let sine = cycle(shape(0));
        let triangle = cycle(shape(1));
        let square = cycle(shape(2));
        assert_ne!(sine, triangle);
        assert_ne!(sine, square);
        assert_ne!(triangle, square);
    }

    #[test]
    fn the_rate_sets_the_phase_step() {
        let lfo = PanLfo {
            rate_hz: 4.0,
            depth: 1.0,
            shape: 0,
        };
        // 4 Hz at 48 kHz is 4/48000 of a turn per sample.
        assert!((lfo.phase_step(48_000) - 4.0 / 48_000.0).abs() < 1e-9);
        assert_eq!(lfo.phase_step(0), 0.0);
        // A nonsense rate cannot advance more than half a cycle per sample.
        let fast = PanLfo {
            rate_hz: 1.0e9,
            depth: 1.0,
            shape: 0,
        };
        assert_eq!(fast.phase_step(48_000), 0.5);
        assert_eq!(fast.phase_step(1), 0.5);
    }

    #[test]
    fn the_insert_is_a_pass_through_and_exposes_its_lfo() {
        let mut panner = StereoPanner::new(2.5, 0.75, 1);
        panner.prepare(48_000, 64);
        let input = vec![0.1f32, -0.2, 0.3];
        let mut block = input.clone();
        panner.process(&mut block);
        assert_eq!(block, input, "the insert changed the mono signal");
        assert_eq!(
            panner.pan_lfo(),
            Some(PanLfo {
                rate_hz: 2.5,
                depth: 0.75,
                shape: 1
            })
        );
    }

    #[test]
    fn the_lfo_survives_prepare_and_reset() {
        let mut panner = StereoPanner::new(6.0, 0.4, 2);
        panner.prepare(48_000, 64);
        panner.reset();
        assert_eq!(panner.lfo().rate_hz, 6.0);
        assert_eq!(panner.lfo().depth, 0.4);
        assert_eq!(panner.lfo().shape, 2);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut panner = StereoPanner::new(5.0, 0.5, 0);
        assert!(panner.set("rate", 100.0));
        assert_eq!(panner.lfo().rate_hz, StereoPanner::MAX_RATE_HZ);
        assert!(panner.set("rate", 0.0));
        assert_eq!(panner.lfo().rate_hz, StereoPanner::MIN_RATE_HZ);
        assert!(panner.set("depth", 10.0));
        assert_eq!(panner.lfo().depth, 1.0);
        assert!(panner.set("depth", -1.0));
        assert_eq!(panner.lfo().depth, 0.0);
        assert!(panner.set("shape", 9.0));
        assert_eq!(panner.lfo().shape, 2);
        assert!(panner.set("shape", -1.0));
        assert_eq!(panner.lfo().shape, 0);
        panner.set("rate", 5.0);
        assert!(panner.set("rate", f32::NAN));
        assert_eq!(panner.lfo().rate_hz, 5.0, "NaN moved the rate");
        assert!(!panner.set("sync", 1.0), "sync is not an engine control");
        assert!(!panner.set("mix", 1.0));
    }
}
