//! The `limiter` pedal: a peak limiter modelled on the UREI 1176's FET
//! detector.
//!
//! The 1176 is a field-effect-transistor compressor. Its FET is a shunt
//! variable resistor inside a high-gain feedback amplifier, so the gain
//! reduction is smooth, the attack is fixed and very short, and the release is
//! *program-dependent*: a short transient lets go quickly, while a sustained
//! passage holds the gain down for longer. Its output is a hard ceiling.
//!
//! This is an honest approximation of that circuit, not a schematic model:
//!
//! * **Attack** is fixed at 20 µs, the fast end of the 1176's 20–800 µs range.
//!   The contract gives this pedal no attack control.
//! * **Release** is program-dependent. The knob sets the slow time constant; a
//!   second, shorter constant (35 % of it) lets a short transient go sooner,
//!   and a sustain memory — charged by the depth of the reduction and bled at
//!   the slow rate — picks between them. A longer knob lengthens both.
//! * **Knee** is soft. The hardware's knee begins below its threshold; this
//!   pedal must be transparent at and below the ceiling (the contract's hard
//!   promise), so the knee is a 2.5 dB bow *above* the ceiling. It eases the
//!   onset of reduction, rejoins the hard law at +2.5 dB, and never lets the
//!   output rise above the ceiling.
//! * **Ceiling** is absolute. The gain is the smaller of the detector's and
//!   what this sample's own peak allows, and the result is clamped. There is
//!   no look-ahead, so the pedal adds no latency; a sample over the ceiling is
//!   caught on that sample, not after a delay line.
//!
//! `ceiling` is dBFS (−60..0) and `release` is seconds (0.001..2); the UI maps
//! its 0..100 sliders to the contract's −24..0 dB and 10..500 ms. The
//! maximizer shares [`FetDetector`] rather than growing a second detector.

use super::{one_pole, one_pole_block, Effect};

/// The fixed attack: the fast end of the 1176's 20–800 µs range.
const ATTACK_SECONDS: f32 = 20e-6;
/// A short transient releases at this fraction of the knob's time constant.
const FAST_RELEASE_SHARE: f32 = 0.35;
/// How quickly the sustain memory charges on a sustained reduction.
const SUSTAIN_ATTACK_SECONDS: f32 = 0.02;
/// The soft knee's width above the ceiling.
const KNEE_DB: f32 = 2.5;
/// Its greatest bow, in dB below the hard law. `KNEE_DB / 4` keeps the output
/// monotonic through the knee.
const KNEE_BOW_DB: f32 = KNEE_DB / 4.0;
/// `10^(KNEE_DB / 20)`: the envelope ratio at the knee's top.
const KNEE_TOP: f32 = 1.333_521_4;

/// The time constants the detector needs for one block, recomputed at the
/// block's edge from the smoothed release rather than per sample.
#[derive(Clone, Copy, Debug)]
pub(super) struct ReleaseTimes {
    attack: f32,
    fast: f32,
    slow: f32,
    sustain: f32,
}

pub(super) fn release_times(release_s: f32, rate: u32) -> ReleaseTimes {
    let release_s = release_s.max(1e-5);
    ReleaseTimes {
        attack: one_pole(ATTACK_SECONDS, rate) as f32,
        fast: one_pole(release_s * FAST_RELEASE_SHARE, rate) as f32,
        slow: one_pole(release_s, rate) as f32,
        sustain: one_pole(SUSTAIN_ATTACK_SECONDS, rate) as f32,
    }
}

/// The 1176-style detector both the limiter and the maximizer use. It owns the
/// rectified peak envelope and the sustain memory that makes the release
/// program-dependent.
#[derive(Debug)]
pub(super) struct FetDetector {
    /// The rectified peak envelope the gain computer reads.
    env: f32,
    /// 0..1: how long and how hard the reduction has been held. It picks the
    /// release constant, which is the program dependence.
    sustain: f32,
}

impl FetDetector {
    pub(super) fn new() -> Self {
        FetDetector {
            env: 0.0,
            sustain: 0.0,
        }
    }

    pub(super) fn reset(&mut self) {
        self.env = 0.0;
        self.sustain = 0.0;
    }

    /// One sample. `ceiling` is linear and `ceiling_db` its dBFS reading (both
    /// smoothed by the caller); `times` are this block's coefficients. No
    /// allocation, no lock and no panic.
    #[inline]
    pub(super) fn process(
        &mut self,
        sample: f32,
        ceiling: f32,
        ceiling_db: f32,
        times: ReleaseTimes,
    ) -> f32 {
        let magnitude = sample.abs();
        if !magnitude.is_finite() {
            // A corrupt sample must not poison the envelope or escape as NaN.
            return 0.0;
        }

        // Rectifier into a peak follower: the attack is the 1176's fixed fast
        // one; the release is the program-dependent one.
        if magnitude > self.env {
            self.env += (magnitude - self.env) * times.attack;
        } else {
            let release = times.fast + (times.slow - times.fast) * self.sustain;
            self.env += (magnitude - self.env) * release;
            if self.env < 0.0 {
                self.env = 0.0;
            }
        }

        let gain = detector_gain(self.env, ceiling, ceiling_db);

        // The sustain memory follows the depth of the reduction: it charges
        // fast while the FET is working and bleeds at the slow release, so a
        // long loud passage stays on the slower tail and a short transient
        // does not.
        let depth = 1.0 - gain;
        if depth > self.sustain {
            self.sustain += (depth - self.sustain) * times.sustain;
        } else {
            self.sustain += (depth - self.sustain) * times.slow;
        }

        // The detector eases the gain; this sample's own peak is the hard
        // promise. Whichever is lower wins, and the clamp absorbs rounding.
        let safe = if magnitude > ceiling {
            ceiling / magnitude
        } else {
            1.0
        };
        let gain = gain.min(safe);
        let mut out = sample * gain;
        if out > ceiling {
            out = ceiling;
        } else if out < -ceiling {
            out = -ceiling;
        }
        out
    }
}

/// The gain the FET's knee asks for at `env`, with the hard ceiling as its
/// asymptote. Below the ceiling it is unity; within 2.5 dB above it the
/// reduction bows in and out; beyond that it is the hard `ceiling / env`.
#[inline]
fn detector_gain(env: f32, ceiling: f32, ceiling_db: f32) -> f32 {
    if !(ceiling > 0.0) || !(env > 0.0) || env <= ceiling {
        return 1.0;
    }
    if env >= ceiling * KNEE_TOP {
        return ceiling / env;
    }
    // Inside the knee. The bow is zero at both edges, greatest in the middle,
    // and no larger than KNEE_DB / 4, so the output still rises with the input.
    let excess_db = 20.0 * env.log10() - ceiling_db;
    let u = (excess_db / KNEE_DB).clamp(0.0, 1.0);
    let reduction_db = excess_db + 4.0 * KNEE_BOW_DB * u * (1.0 - u);
    10f32.powf(-reduction_db / 20.0)
}

#[derive(Debug)]
pub struct Limiter {
    rate: u32,
    target_ceiling_db: f32,
    ceiling_db: f32,
    target_release: f32,
    release_s: f32,
    detector: FetDetector,
}

impl Limiter {
    pub const MIN_CEILING_DB: f32 = -60.0;
    pub const MIN_RELEASE: f32 = 0.001;
    pub const MAX_RELEASE: f32 = 2.0;

    pub fn new(ceiling_db: f32, release_s: f32) -> Self {
        let ceiling_db = ceiling_db.clamp(Self::MIN_CEILING_DB, 0.0);
        let release_s = release_s.clamp(Self::MIN_RELEASE, Self::MAX_RELEASE);
        Limiter {
            rate: 48_000,
            target_ceiling_db: ceiling_db,
            ceiling_db,
            target_release: release_s,
            release_s,
            detector: FetDetector::new(),
        }
    }
}

impl Effect for Limiter {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.ceiling_db = self.target_ceiling_db;
        self.release_s = self.target_release;
        self.detector.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() {
            return;
        }
        // Two knobs, both smooth enough at the block's edge: a ceiling move is a
        // level change, not a filter coefficient, and a release move only
        // changes how fast a recovering gain travels.
        let alpha = one_pole_block(0.02, self.rate, block.len()) as f32;
        self.ceiling_db += (self.target_ceiling_db - self.ceiling_db) * alpha;
        self.release_s += (self.target_release - self.release_s) * alpha;
        let ceiling = 10f32.powf(self.ceiling_db / 20.0);
        let times = release_times(self.release_s.max(Self::MIN_RELEASE), self.rate);
        for sample in block.iter_mut() {
            *sample = self
                .detector
                .process(*sample, ceiling, self.ceiling_db, times);
        }
    }

    fn reset(&mut self) {
        self.ceiling_db = self.target_ceiling_db;
        self.release_s = self.target_release;
        self.detector.reset();
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "ceiling" => {
                if usable {
                    self.target_ceiling_db = value.clamp(Self::MIN_CEILING_DB, 0.0);
                }
                true
            }
            "release" => {
                if usable {
                    self.target_release = value.clamp(Self::MIN_RELEASE, Self::MAX_RELEASE);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "limiter"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude)
            .collect()
    }

    fn peak(block: &[f32]) -> f32 {
        block.iter().fold(0.0f32, |highest, sample| highest.max(sample.abs()))
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut limiter = Limiter::new(-6.0, 0.1);
        limiter.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        limiter.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn a_peak_above_the_ceiling_is_caught_on_the_sample() {
        // A 0 dB ceiling makes the arithmetic exact: a 2.0 sample becomes 1.0.
        let mut limiter = Limiter::new(0.0, 0.1);
        limiter.prepare(RATE, 2);
        let mut block = vec![2.0, -2.0];
        limiter.process(&mut block);
        assert_eq!(block[0], 1.0);
        assert_eq!(block[1], -1.0);

        // And with a dB ceiling, nothing gets past it, even a full-scale
        // impulse on the very first sample.
        let mut limiter = Limiter::new(-6.0, 0.1);
        limiter.prepare(RATE, 4);
        let ceiling = 10f32.powf(-6.0 / 20.0);
        let mut block = vec![1.0, -1.0, 1.0, -1.0];
        limiter.process(&mut block);
        assert!(
            block.iter().all(|sample| sample.abs() <= ceiling + 1e-7),
            "the impulse got past the ceiling: {block:?}"
        );
    }

    #[test]
    fn a_loud_block_is_reduced_and_a_quiet_one_passes() {
        let mut limiter = Limiter::new(-6.0, 0.1);
        limiter.prepare(RATE, 4096);

        let mut loud = sine(220.0, 1.0, 4096);
        let loud_in = loud.clone();
        limiter.process(&mut loud);
        let ceiling = 10f32.powf(-6.0 / 20.0);
        assert!(
            rms(&loud) < rms(&loud_in) * 0.6,
            "the loud block was not reduced: {} vs {}",
            rms(&loud),
            rms(&loud_in)
        );
        assert!(peak(&loud) <= ceiling + 1e-6);

        // A quiet signal sits below the ceiling, so the pedal is transparent.
        limiter.reset();
        let mut quiet = sine(220.0, 0.1, 4096);
        let quiet_in = quiet.clone();
        limiter.process(&mut quiet);
        assert_eq!(quiet, quiet_in);
    }

    #[test]
    fn the_soft_knee_eases_in_above_the_ceiling() {
        let ceiling = 10f32.powf(-6.0 / 20.0);
        let mut limiter = Limiter::new(-6.0, 0.1);
        limiter.prepare(RATE, 4096);
        // 0.55 is only 0.8 dB over the ceiling: the knee pulls it below the
        // hard ceiling instead of pinning it there.
        let mut block = sine(220.0, 0.55, 4096);
        limiter.process(&mut block);
        let settled = peak(&block[2048..]);
        assert!(
            settled < ceiling * 0.99,
            "the knee did not ease in: {settled} against a {ceiling} ceiling"
        );
        assert!(
            settled > ceiling * 0.85,
            "the knee cut too far: {settled} against a {ceiling} ceiling"
        );
    }

    #[test]
    fn a_longer_release_recovers_more_slowly() {
        let loud = sine(220.0, 1.0, 4096);
        let probe = sine(220.0, 0.05, 4800);

        let mut quick = Limiter::new(-6.0, 0.02);
        quick.prepare(RATE, 8192);
        let mut block = loud.clone();
        quick.process(&mut block);
        let mut quick_tail = probe.clone();
        quick.process(&mut quick_tail);

        let mut slow = Limiter::new(-6.0, 0.4);
        slow.prepare(RATE, 8192);
        let mut block = loud.clone();
        slow.process(&mut block);
        let mut slow_tail = probe.clone();
        slow.process(&mut slow_tail);

        assert!(
            rms(&slow_tail) < rms(&quick_tail) * 0.9,
            "the longer release recovered too quickly: {} vs {}",
            rms(&slow_tail),
            rms(&quick_tail)
        );
    }

    #[test]
    fn full_scale_input_stays_finite() {
        let mut limiter = Limiter::new(-12.0, 0.001);
        limiter.prepare(RATE, 256);
        let ceiling = 10f32.powf(-12.0 / 20.0);
        let mut alternating = vec![0.0f32; 256];
        for (index, sample) in alternating.iter_mut().enumerate() {
            *sample = if index % 2 == 0 { 1.0 } else { -1.0 };
        }
        limiter.process(&mut alternating);
        assert!(alternating.iter().all(|sample| sample.is_finite()));
        assert!(alternating
            .iter()
            .all(|sample| sample.abs() <= ceiling + 1e-6));

        limiter.reset();
        let mut full = sine(997.0, 1.0, 256);
        limiter.process(&mut full);
        assert!(full.iter().all(|sample| sample.is_finite()));
        assert!(full.iter().all(|sample| sample.abs() <= ceiling + 1e-6));
    }

    #[test]
    fn reset_matches_the_first_run() {
        let input = sine(440.0, 1.0, 4096);
        let mut limiter = Limiter::new(-3.0, 0.1);
        limiter.prepare(RATE, 4096);
        let mut first = input.clone();
        limiter.process(&mut first);
        limiter.reset();
        let mut second = input.clone();
        limiter.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut limiter = Limiter::new(-1.0, 0.2);
        assert!(limiter.set("ceiling", 10.0));
        assert_eq!(limiter.target_ceiling_db, 0.0);
        assert!(limiter.set("ceiling", -100.0));
        assert_eq!(limiter.target_ceiling_db, Limiter::MIN_CEILING_DB);
        assert!(limiter.set("release", 100.0));
        assert_eq!(limiter.target_release, Limiter::MAX_RELEASE);
        assert!(limiter.set("release", f32::NAN));
        assert_eq!(limiter.target_release, Limiter::MAX_RELEASE);
        assert!(limiter.set("ceiling", f32::NAN));
        assert_eq!(limiter.target_ceiling_db, Limiter::MIN_CEILING_DB);
        assert!(!limiter.set("threshold", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("limiter"), Some(InsertKind::Limiter));
        assert_eq!(InsertKind::Limiter.name(), "limiter");
        assert_eq!(InsertKind::parse("master_limiter"), Some(InsertKind::Limiter));
    }
}
