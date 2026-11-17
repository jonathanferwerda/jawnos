//! The block graph: sum mono inputs into an interleaved stereo bus.
//!
//! Everything here is allocation-free and lock-free once the block is handed in:
//! the buffers a channel needs are built at startup, never in the callback. A
//! pan is equal-power, so a centred source sits at 1/√2 in each speaker and a
//! moving source does not change the mix's total level.

use std::f32::consts::FRAC_PI_4;

use crate::params::Param;

#[derive(Debug, PartialEq, Eq)]
pub enum GraphError {
    /// The output block was not `input.len() * 2` samples long.
    BadBlock { expected: usize, found: usize },
}

/// One channel strip's contribution: a gain and a pan position in
/// `-1.0` (hard left) ..= `1.0` (hard right). Both are `Param`s, so the UI can
/// move them between blocks without a lock.
#[derive(Debug)]
pub struct Strip {
    pub gain: Param,
    pub pan: Param,
}

impl Strip {
    pub const fn new(gain: f32, pan: f32) -> Self {
        Strip {
            gain: Param::new(gain),
            pan: Param::new(pan),
        }
    }

    /// The left and right gains this strip contributes right now.
    pub fn coefficients(&self) -> (f32, f32) {
        let pan = self.pan.get().clamp(-1.0, 1.0);
        let gain = self.gain.get();
        // -1 -> 0 rad, 0 -> π/4, 1 -> π/2: an equal-power sweep.
        let angle = (pan + 1.0) * FRAC_PI_4;
        (gain * angle.cos(), gain * angle.sin())
    }
}

/// Add one mono block into an interleaved stereo bus. `out` must be exactly
/// `input.len() * 2` samples; its previous contents are summed into, so several
/// strips can share one bus.
pub fn mix_mono_into_stereo(
    out: &mut [f32],
    input: &[f32],
    strip: &Strip,
) -> Result<(), GraphError> {
    if out.len() != input.len() * 2 {
        return Err(GraphError::BadBlock {
            expected: input.len() * 2,
            found: out.len(),
        });
    }
    let (left_gain, right_gain) = strip.coefficients();
    for (frame, sample) in input.iter().enumerate() {
        out[frame * 2] += sample * left_gain;
        out[frame * 2 + 1] += sample * right_gain;
    }
    Ok(())
}

/// The loudest absolute sample in a block, for a meter. Silence is 0.0.
pub fn peak(block: &[f32]) -> f32 {
    block.iter().fold(0.0f32, |loudest, sample| loudest.max(sample.abs()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::FRAC_1_SQRT_2;

    const EPSILON: f32 = 1e-6;

    fn close(a: f32, b: f32) -> bool {
        (a - b).abs() < EPSILON
    }

    #[test]
    fn hard_left_puts_everything_in_the_left_speaker() {
        let strip = Strip::new(1.0, -1.0);
        let mut out = vec![0.0f32; 6];
        mix_mono_into_stereo(&mut out, &[0.5, 0.25, -1.0], &strip).expect("mix");
        assert!(close(out[0], 0.5) && close(out[2], 0.25) && close(out[4], -1.0));
        assert!(close(out[1], 0.0) && close(out[3], 0.0) && close(out[5], 0.0));
    }

    #[test]
    fn hard_right_puts_everything_in_the_right_speaker() {
        let strip = Strip::new(1.0, 1.0);
        let mut out = vec![0.0f32; 2];
        mix_mono_into_stereo(&mut out, &[0.5], &strip).expect("mix");
        assert!(close(out[0], 0.0));
        assert!(close(out[1], 0.5));
    }

    #[test]
    fn centre_is_equal_power() {
        let strip = Strip::new(1.0, 0.0);
        let (left, right) = strip.coefficients();
        assert!(close(left, FRAC_1_SQRT_2));
        assert!(close(right, FRAC_1_SQRT_2));
    }

    #[test]
    fn strips_sum_into_the_same_bus() {
        let mut out = vec![0.0f32; 2];
        mix_mono_into_stereo(&mut out, &[0.5], &Strip::new(1.0, -1.0)).expect("first");
        mix_mono_into_stereo(&mut out, &[0.25], &Strip::new(1.0, 1.0)).expect("second");
        assert!(close(out[0], 0.5));
        assert!(close(out[1], 0.25));
    }

    #[test]
    fn gain_scales_the_strip() {
        let mut out = vec![0.0f32; 2];
        mix_mono_into_stereo(&mut out, &[1.0], &Strip::new(0.25, 1.0)).expect("mix");
        assert!(close(out[1], 0.25));
    }

    #[test]
    fn a_pan_past_the_end_behaves_like_the_end() {
        let (left, right) = Strip::new(1.0, 9.0).coefficients();
        assert!(close(left, 0.0) && close(right, 1.0));
    }

    #[test]
    fn a_wrong_length_is_an_error() {
        let mut out = vec![0.0f32; 3];
        assert_eq!(
            mix_mono_into_stereo(&mut out, &[0.0; 2], &Strip::new(1.0, 0.0)),
            Err(GraphError::BadBlock {
                expected: 4,
                found: 3
            })
        );
    }

    #[test]
    fn peak_finds_the_loudest_sample() {
        assert!(close(peak(&[0.1, -0.8, 0.3]), 0.8));
        assert_eq!(peak(&[]), 0.0);
        assert_eq!(peak(&[0.0, 0.0]), 0.0);
    }
}
