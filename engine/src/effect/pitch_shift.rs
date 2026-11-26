//! The `pitch_shift` pedal: a fixed-interval granular shifter.
//!
//! # The model
//!
//! ```text
//! in ──► history ring ──► a stream of resampled grains ──► wet
//!   │                     (read speed 2^(semitones/12))     │
//!   └────────────► aligned dry (BASE_SECONDS) ──────────────┤
//!                                                          ▼
//!                                        dry + mix · (wet − dry)
//! ```
//!
//! No detector: the interval is the knob. `semitones` is −24..+24, rounded to
//! a whole semitone, and every grain's read pointer advances at
//! `ratio = 2^(semitones/12)` through a short history window. Grains are laid
//! end to end with a small overlap; each has a flat top and a short raised
//! cosine fade at its edges, so only the seam crossfades the two grains. Read
//! speed, and therefore pitch, is the ratio at every sample inside a grain.
//!
//! The earlier two-tap design kept both taps audible all the time with a
//! triangular crossfade. At the larger intervals (+/−24) the two taps sit
//! nearly antiphase, so they cancel the shifted carrier and leave only the
//! crossfade sidebands: a nominal octave could come out almost a semitone
//! flat. Fading only at the seam keeps the carrier, so the interval is exact.
//!
//! `semitones` and `mix` are the contract's natural units
//! (`docs/studio-effects.md`); there is no `sync` control.
//!
//! # The honest approximation
//!
//! * **Granular, not phase-vocoder.** A sweeping tap is a resampler, so a large
//!   shift adds a little warble and loses some clarity; there is no phase
//!   locking and no formant preservation. An octave is clean, two octaves the
//!   rough end of its range.
//! * **Latency, not zero.** A grain reads about [`BASE_SECONDS`] behind the
//!   write head (up to twice that at the end of a downshift grain), and the dry
//!   leg is delayed to match so `mix` cannot comb. It is an insert, not a
//!   look-ahead tool.
//! * **Monophonic in practice.** Like every shifter of this kind it treats the
//!   signal as one voice; a chord is shifted as a whole and can beat against
//!   itself. Nothing here pretends to separate voices.
//! * **Seam artefacts.** The grain seam is a short crossfade between two copies
//!   at different delays. A pure tone very close to the null of that crossfade
//!   can still warble; the seam is short and the rest of the grain is exact.

use super::autotune::{grain_tap, MIN_RING, RING_SECONDS};
use super::{one_pole, Effect, SMOOTH_SECONDS};

/// How far behind the write head a grain starts, in seconds. It is also the
/// aligned dry leg's delay, so `mix` cannot comb. A longer base lengthens the
/// grain for a downshift, which keeps the seam small against a low note: at
/// −24 semitones a 15 ms base measured about half a semitone flat.
const BASE_SECONDS: f32 = 0.04;
/// The longest grain (near ratio 1, where `base / |1 − ratio|` would be huge).
const MAX_GRAIN_SECONDS: f32 = 0.12;
/// The shortest grain, a floor for the scheduler.
const MIN_GRAIN: usize = 64;
/// The seam crossfade as a fraction of the grain, with a small sample floor.
const FADE_FRACTION: f32 = 0.1;
const MIN_FADE: usize = 16;

/// One resampled grain. `start` is the output sample it begins on, `base` the
/// delay at its first sample, and `ratio` the read speed inside it. The delay
/// at offset `p` is `base + p · (1 − ratio)`: for an upshift it shortens to
/// zero by the grain's end, for a downshift it lengthens.
#[derive(Debug, Clone)]
struct Grain {
    start: usize,
    length: usize,
    fade: usize,
    base: f32,
    ratio: f32,
}

#[derive(Debug)]
pub struct PitchShift {
    rate: u32,
    target_semitones: f32,
    semitones: f32,
    target_mix: f32,
    mix: f32,
    ring: Vec<f32>,
    write: usize,
    base: f32,
    ratio: f32,
    current_ratio: f32,
    grains: Vec<Grain>,
    next_grain: usize,
    position: usize,
    smooth: f32,
    prepared: bool,
}

impl PitchShift {
    pub const MIN_SEMITONES: f32 = -24.0;
    pub const MAX_SEMITONES: f32 = 24.0;

    pub fn new(semitones: f32, mix: f32) -> Self {
        let semitones = semitones.round().clamp(Self::MIN_SEMITONES, Self::MAX_SEMITONES);
        PitchShift {
            rate: 48_000,
            target_semitones: semitones,
            semitones,
            target_mix: mix.clamp(0.0, 1.0),
            mix: mix.clamp(0.0, 1.0),
            ring: Vec::new(),
            write: 0,
            base: 0.0,
            ratio: Self::ratio(semitones),
            current_ratio: Self::ratio(semitones),
            grains: Vec::new(),
            next_grain: 0,
            position: 0,
            smooth: 0.0,
            prepared: false,
        }
    }

    fn ratio(semitones: f32) -> f32 {
        2f32.powf(semitones / 12.0)
    }

    /// Size and place the next grain from the current ratio. A ratio exactly
    /// one has no span; the grain then just reads the aligned look-back.
    fn grain_shape(&self, ratio: f32) -> (usize, usize) {
        let max_length = ((self.rate as f32 * MAX_GRAIN_SECONDS) as usize)
            .max(MIN_GRAIN)
            .min(self.ring.len() / 4);
        let span = (1.0 - ratio).abs();
        let length = if span < 1e-4 {
            max_length
        } else {
            ((self.base / span) as usize).clamp(MIN_GRAIN, max_length)
        };
        let fade = ((length as f32 * FADE_FRACTION) as usize)
            .max(MIN_FADE)
            .min(length / 2);
        (length, fade)
    }

    /// Lay grains until the queue reaches `end`. The ratio is sampled here, at
    /// the block edge: a knob move takes effect on the next grain.
    fn schedule(&mut self, end: usize, ratio: f32) {
        let (length, fade) = self.grain_shape(ratio);
        let hop = (length - fade).max(1);
        let mut guard = 0;
        while self.next_grain < end && guard < 4096 {
            self.grains.push(Grain {
                start: self.next_grain,
                length,
                fade,
                base: self.base,
                ratio,
            });
            self.next_grain += hop;
            guard += 1;
        }
    }
}

impl Effect for PitchShift {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let ring_len = ((self.rate as f32 * RING_SECONDS) as usize).max(MIN_RING);
        self.ring = vec![0.0; ring_len];
        self.write = 0;
        self.base = (self.rate as f32 * BASE_SECONDS).max(64.0);
        self.semitones = self.target_semitones;
        self.mix = self.target_mix;
        self.ratio = Self::ratio(self.semitones);
        self.current_ratio = self.ratio;
        self.grains.clear();
        self.next_grain = 0;
        self.position = 0;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
        self.prepared = true;
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared || self.ring.len() < 64 {
            return;
        }
        let ring_len = self.ring.len();
        let block_start = self.position;
        let block_end = block_start + block.len();
        // The grains laid for this block use the ratio it starts with. The
        // smoothed ratio still moves per sample for the next block's grains.
        self.schedule(block_end, self.current_ratio);
        self.grains.retain(|grain| grain.start + grain.length > block_start);

        for (index, sample) in block.iter_mut().enumerate() {
            let position = block_start + index;
            self.ring[self.write] = *sample;
            self.semitones += (self.target_semitones - self.semitones) * self.smooth;
            self.mix += (self.target_mix - self.mix) * self.smooth;
            self.ratio = Self::ratio(self.semitones);
            self.current_ratio += (self.ratio - self.current_ratio) * self.smooth;

            let mut wet = 0.0;
            let mut weight = 0.0;
            for grain in &self.grains {
                if position < grain.start || position >= grain.start + grain.length {
                    continue;
                }
                let p = (position - grain.start) as f32;
                let length = grain.length as f32;
                let fade = grain.fade as f32;
                let w = if p < fade {
                    0.5 - 0.5 * (std::f32::consts::PI * p / fade).cos()
                } else if p > length - fade {
                    0.5 - 0.5 * (std::f32::consts::PI * (length - p) / fade).cos()
                } else {
                    1.0
                };
                let delay = grain.base + p * (1.0 - grain.ratio);
                if delay < 0.0 {
                    continue;
                }
                wet += grain_tap(&self.ring, self.write, delay) * w;
                weight += w;
            }
            if weight > 1e-6 {
                wet /= weight;
            }
            let dry = grain_tap(&self.ring, self.write, self.base);
            *sample = dry + (wet - dry) * self.mix;

            self.write = (self.write + 1) % ring_len;
        }
        self.position = block_end;
    }

    fn reset(&mut self) {
        if !self.ring.is_empty() {
            self.ring.fill(0.0);
        }
        self.write = 0;
        self.semitones = self.target_semitones;
        self.mix = self.target_mix;
        self.ratio = Self::ratio(self.semitones);
        self.current_ratio = self.ratio;
        self.grains.clear();
        self.next_grain = 0;
        self.position = 0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "semitones" => {
                if usable {
                    self.target_semitones =
                        value.round().clamp(Self::MIN_SEMITONES, Self::MAX_SEMITONES);
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
        "pitch_shift"
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

    fn render(shifter: &mut PitchShift, input: &[f32]) -> Vec<f32> {
        shifter.prepare(RATE, input.len());
        let mut block = input.to_vec();
        shifter.process(&mut block);
        block
    }

    fn count_zero_crossings(block: &[f32]) -> usize {
        block
            .windows(2)
            .filter(|pair| pair[0] <= 0.0 && pair[1] > 0.0)
            .count()
    }

    /// The shifted tone's zero-crossing interval, measured away from the short
    /// crossfade seams. The median ignores a seam's extra crossing.
    fn median_hz(block: &[f32]) -> f32 {
        let mut crossings = Vec::new();
        		for (index, pair) in block.windows(2).enumerate() {
        			if pair[0] <= 0.0 && pair[1] > 0.0 {
        				let fraction = pair[0] / (pair[0] - pair[1]);
        				crossings.push(index as f32 + fraction);
        			}
        		}
        let mut gaps: Vec<f32> = crossings.windows(2).map(|w| w[1] - w[0]).collect();
        gaps.sort_by(|a, b| a.partial_cmp(b).unwrap());
        if gaps.is_empty() {
            return 0.0;
        }
        RATE as f32 / gaps[gaps.len() / 2]
    }

    fn zero_crossing_ratio(semitones: f32, hz: f32) -> f32 {
        let input = sine(hz, 0.4, RATE as usize);
        let mut shifter = PitchShift::new(semitones, 1.0);
        let output = render(&mut shifter, &input);
        // Skip the first 200 ms: the grains need to settle and the ring fills.
        let settled = &output[9_600..];
        let source = &input[9_600..];
        count_zero_crossings(settled) as f32 / count_zero_crossings(source) as f32
    }

    fn assert_interval(semitones: f32, hz: f32, tolerance: f32) {
        let expected = 2f32.powf(semitones / 12.0);
        let got = zero_crossing_ratio(semitones, hz);
        assert!(
            (expected * (1.0 - tolerance)..=expected * (1.0 + tolerance)).contains(&got),
            "{semitones} semitones was {got}, expected {expected}"
        );
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut shifter = PitchShift::new(7.0, 1.0);
        let output = render(&mut shifter, &vec![0.0f32; 8192]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn an_octave_up_doubles_the_zero_crossings() {
        assert_interval(12.0, 220.0, 0.1);
    }

    #[test]
    fn an_octave_down_halves_the_zero_crossings() {
        assert_interval(-12.0, 440.0, 0.1);
    }

    #[test]
    fn two_octaves_reaches_plus_or_minus_twenty_four() {
        assert_interval(24.0, 220.0, 0.1);
        assert_interval(-24.0, 880.0, 0.1);
    }

    #[test]
    fn the_shifted_tone_is_the_asked_for_interval() {
        // A zero-crossing count near a seam can be off; the median interval of
        // a settled tone is the pitch a person hears.
        for &(semitones, hz) in &[(24.0, 220.0), (12.0, 220.0), (-12.0, 440.0), (-24.0, 880.0)] {
            let input = sine(hz, 0.4, RATE as usize);
            let mut shifter = PitchShift::new(semitones, 1.0);
            let output = render(&mut shifter, &input);
            let expected = hz * 2f32.powf(semitones / 12.0);
            let got = median_hz(&output[9_600..]);
            assert!(
                (got / expected - 1.0).abs() < 0.04,
                "{semitones} semitones on {hz} Hz: got {got} Hz, expected {expected} Hz"
            );
        }
    }

    #[test]
    fn mix_zero_is_the_aligned_dry_leg() {
        let input = sine(440.0, 0.4, 4096);
        let mut shifter = PitchShift::new(7.0, 0.0);
        let output = render(&mut shifter, &input);
        let half = (RATE as f32 * BASE_SECONDS) as usize;
        for index in half + 8..input.len() {
            assert!(
                (output[index] - input[index - half]).abs() < 1e-5,
                "mix 0 was not the aligned dry at {index}"
            );
        }
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 8192);
        let mut shifter = PitchShift::new(24.0, 1.0);
        shifter.prepare(RATE, input.len());
        let mut first = input.clone();
        shifter.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));

        shifter.reset();
        let mut second = input.clone();
        shifter.process(&mut second);
        assert_eq!(first, second, "reset did not return to the first run");
    }

    #[test]
    fn semitones_round_and_clamp() {
        let mut shifter = PitchShift::new(0.0, 1.0);
        assert!(shifter.set("semitones", 7.4));
        assert_eq!(shifter.target_semitones, 7.0);
        assert!(shifter.set("semitones", 99.0));
        assert_eq!(shifter.target_semitones, PitchShift::MAX_SEMITONES);
        assert!(shifter.set("semitones", -99.0));
        assert_eq!(shifter.target_semitones, PitchShift::MIN_SEMITONES);
        assert!(shifter.set("semitones", f32::NAN));
        assert_eq!(shifter.target_semitones, PitchShift::MIN_SEMITONES);
        assert!(shifter.set("mix", 2.0));
        assert_eq!(shifter.target_mix, 1.0);
        assert!(!shifter.set("rate", 1.0));
        assert!(!shifter.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(
            InsertKind::parse("pitch_shift"),
            Some(InsertKind::PitchShift)
        );
        assert_eq!(InsertKind::PitchShift.name(), "pitch_shift");
        assert_eq!(
            InsertKind::PitchShift.controls(),
            &["semitones", "mix"]
        );
        assert_eq!(InsertKind::PitchShift.code(), 20);
        assert_eq!(InsertKind::from_code(20), Some(InsertKind::PitchShift));
        assert_eq!(InsertKind::PitchShift.build().name(), "pitch_shift");
    }
}
