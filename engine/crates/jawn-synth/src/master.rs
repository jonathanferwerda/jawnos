//! The master stage: drive, compressor, and a final safety clip.
//!
//! The browser chain is `voices -> out gain -> WaveShaper -> DynamicsCompressor
//! -> destination` (`attach()` in `01_engine.js`). This module mirrors it:
//!
//! * [`drive`] applies the same curve `applyDrive()` builds, evaluated
//!   continuously instead of through a 1024-point table with linear
//!   interpolation.
//! * [`Compressor`] is a feed-forward peak compressor with threshold -12 dBFS,
//!   ratio 4, a 3 ms attack and a 250 ms release. Web Audio's compressor has a
//!   knee and a more elaborate detector; this is deliberately simpler, which
//!   the crate docs note.
//! * [`soft_clip`] is the native safety net. The browser relies on the device
//!   to clip; a native engine fed a hot patch must not emit NaN or samples past
//!   full scale, so everything above 0.8 is bent asymptotically toward 0.99.
//!
//! A compressor with ratio 4 does not itself bound its output, which is exactly
//! why the final clip exists.

/// Threshold in linear amplitude: -12 dBFS.
const THRESHOLD: f32 = 0.251_188_64;
/// The compressor ratio, 4:1.
const RATIO: f32 = 4.0;
/// The level where the safety clip starts to bend.
const CLIP_KNEE: f32 = 0.8;
/// The level the safety clip approaches but never reaches.
const CLIP_CEILING: f32 = 0.99;

/// The drive curve from `applyDrive()`, evaluated on one sample.
pub(crate) fn drive(x: f32, amount: f32) -> f32 {
    if amount <= 0.001 {
        return x;
    }
    let k = amount * 40.0;
    ((1.0 + k) * x) / (1.0 + k * x.abs())
}

/// A feed-forward peak compressor.
pub(crate) struct Compressor {
    env: f32,
    attack: f32,
    release: f32,
}

impl Compressor {
    /// A compressor whose detector is at rest.
    pub fn new(rate: f32) -> Self {
        let mut c = Compressor { env: 0.0, attack: 0.0, release: 0.0 };
        c.configure(rate);
        c
    }

    /// Recompute the detector coefficients for a sample rate.
    pub fn configure(&mut self, rate: f32) {
        self.attack = (-1.0 / (0.003 * rate)).exp();
        self.release = (-1.0 / (0.25 * rate)).exp();
        self.env = 0.0;
    }

    /// Compress one sample.
    pub fn process(&mut self, x: f32) -> f32 {
        if !x.is_finite() {
            return 0.0;
        }
        let level = x.abs();
        let coefficient = if level > self.env { self.attack } else { self.release };
        self.env = coefficient * self.env + (1.0 - coefficient) * level;

        if self.env > THRESHOLD {
            let over_db = 20.0 * (self.env / THRESHOLD).log10();
            let reduction_db = over_db * (1.0 - 1.0 / RATIO);
            x * 10f32.powf(-reduction_db / 20.0)
        } else {
            x
        }
    }
}

/// Bend anything above the knee toward the ceiling; replace non-finite input
/// with silence. The result is always finite and below 1.0 in magnitude.
pub(crate) fn soft_clip(x: f32) -> f32 {
    if !x.is_finite() {
        return 0.0;
    }
    let magnitude = x.abs();
    if magnitude <= CLIP_KNEE {
        return x;
    }
    let bent = CLIP_KNEE
        + (CLIP_CEILING - CLIP_KNEE) * ((magnitude - CLIP_KNEE) / (1.0 - CLIP_KNEE)).tanh();
    if x < 0.0 {
        -bent
    } else {
        bent
    }
}

/// The LFO's tremolo shape: `1 + sin * depth * 0.5`, the master-gain swing the
/// browser gets by connecting `lfoAmp` (gain `amp * 0.5`) to `out.gain`.
pub(crate) fn tremolo_gain(lfo: f32, depth: f32) -> f32 {
    (1.0 + lfo * depth * 0.5).max(0.0)
}

#[cfg(test)]
mod tests {
    use super::{drive, soft_clip, tremolo_gain, Compressor};

    #[test]
    fn drive_is_bounded_and_odd() {
        for i in -100..=100 {
            let x = i as f32 / 100.0;
            let y = drive(x, 1.0);
            assert!(y.is_finite());
            assert!((y + drive(-x, 1.0)).abs() < 1e-6);
            assert!(y.abs() < 1.1);
        }
        assert_eq!(drive(0.5, 0.0), 0.5);
    }

    #[test]
    fn clip_never_reaches_full_scale() {
        for i in 0..1000 {
            let x = i as f32 / 10.0;
            let y = soft_clip(x);
            assert!(y.abs() < 1.0);
            assert_eq!(soft_clip(-x), -y);
        }
        assert_eq!(soft_clip(0.5), 0.5);
        assert_eq!(soft_clip(f32::NAN), 0.0);
        assert_eq!(soft_clip(f32::INFINITY), 0.0);
    }

    #[test]
    fn tremolo_matches_the_browser_swing() {
        assert!((tremolo_gain(0.0, 1.0) - 1.0).abs() < 1e-6);
        assert!((tremolo_gain(1.0, 1.0) - 1.5).abs() < 1e-6);
    }

    #[test]
    fn compressor_reduces_a_hot_signal() {
        let mut c = Compressor::new(48000.0);
        let mut peak = 0.0f32;
        for i in 0..48000 {
            let y = c.process(4.0);
            // The detector has an attack; check the settled second half.
            if i > 24000 {
                peak = peak.max(y);
            }
        }
        assert!(peak < 4.0);
        assert!(peak > 0.0);
    }
}
