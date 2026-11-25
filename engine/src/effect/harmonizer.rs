//! The `harmonizer` pedal: one monophonic diatonic harmony above or below.
//!
//! # The model
//!
//! ```text
//!                     key · scale · degree
//!                              │
//! in ──► history ring ──► period detector ──► interval ratio
//!              │                                    │
//!              └────────► crossfaded grains ◄────────┘
//!                              │
//!                 dry (aligned) + mix · (wet − dry) ──► out
//! ```
//!
//! The pedal is a pitch shifter with a musical target. Every analysis hop it
//! estimates the played period with the same normalised autocorrelation the
//! corrector uses ([`PitchDetector`]), snaps that note to the nearest member of
//! `key`/`scale`, walks `degree − 3` scale steps up or down, and asks the grain
//! shifter for the ratio between the played pitch and that target. The two
//! crossfaded grains ([`grain_taps`]) then move the copy and `mix` blends it
//! with the aligned dry leg.
//!
//! `key` is the whole index 0..11 (C..B), `scale` is 0 Major, 1 Minor,
//! 2 Chromatic, 3 Pentatonic, `degree` is 0..6 (−3 … +3 scale steps, 5 being
//! a third above), and `mix` is 0..1. They are the contract's natural units
//! (`docs/studio-effects.md`); the page sends them already resolved, so there is
//! no `sync` control here.
//!
//! # The honest approximation
//!
//! * **One voice only.** Two notes at once give the detector a period that
//!   belongs to neither; it locks onto one or loses lock and holds the previous
//!   interval. There is no polyphonic separation and no plan to fake one.
//! * **Diatonic, not chromatic.** The interval is a scale step from the nearest
//!   in-scale note, which is what a harmonizer does when the player is in key.
//!   An out-of-key note is first snapped (at most a semitone), so the harmony is
//!   consonant with the scale, not with that one note.
//! * **Latency, not zero.** A shifted grain reads on average half the
//!   [`SHIFT_SECONDS`] window back (15 ms at 48 kHz) plus the detection window
//!   and hop; expect roughly 40 ms before a new note's harmony settles. It is an
//!   insert, not a look-ahead tool.
//! * **No formant preservation.** The whole spectrum moves with the grain, so a
//!   large interval on a voice can sound small or large with it. The contract
//!   caps the interval at three scale steps, which keeps that modest.
//! * **Crossfade artefacts.** A sweeping tap is a resampler; a fast interval
//!   change on a held note can make the crossfade audible. Interval changes are
//!   one-pole retuned at [`RETUNE_SECONDS`] so an ordinary move glides.

use super::autotune::{
    grain_tap, grain_taps, in_scale, nearest_in_scale, PitchDetector, HOP_SECONDS, MIN_RING,
    RING_SECONDS, SHIFT_SECONDS,
};
use super::{one_pole, Effect, SMOOTH_SECONDS};

/// How long the interval takes to travel to a new scale step. Long enough to
/// glide, short enough that a new note's harmony arrives with it.
const RETUNE_SECONDS: f32 = 0.02;

#[derive(Debug)]
pub struct Harmonizer {
    rate: u32,
    key: u8,
    scale: u8,
    degree: u8,
    target_mix: f32,
    mix: f32,
    ring: Vec<f32>,
    write: usize,
    shift_window: usize,
    hop: usize,
    since_analysis: usize,
    detector: PitchDetector,
    ratio: f32,
    current_ratio: f32,
    phase: f32,
    smooth: f32,
    retune: f32,
    prepared: bool,
}

impl Harmonizer {
    pub const MAX_KEY: u8 = 11;
    pub const SCALES: [&'static str; 4] = ["Major", "Minor", "Chromatic", "Pentatonic"];
    /// The contract's degree indexes: 0 is three steps below, 3 is unison,
    /// 6 is three steps above.
    pub const MAX_DEGREE: u8 = 6;
    /// The pedal is a third above by default, the interval a singer adds first.
    pub const DEFAULT_DEGREE: u8 = 5;

    pub fn new(key: u8, scale: u8, degree: u8, mix: f32) -> Self {
        Harmonizer {
            rate: 48_000,
            key: key.min(Self::MAX_KEY),
            scale: scale.min(Self::SCALES.len() as u8 - 1),
            degree: degree.min(Self::MAX_DEGREE),
            target_mix: mix.clamp(0.0, 1.0),
            mix: mix.clamp(0.0, 1.0),
            ring: Vec::new(),
            write: 0,
            shift_window: 0,
            hop: 0,
            since_analysis: 0,
            detector: PitchDetector::new(),
            ratio: 1.0,
            current_ratio: 1.0,
            phase: 0.0,
            smooth: 0.0,
            retune: 0.0,
            prepared: false,
        }
    }

    /// Move `steps` scale degrees from `note`, staying inside the key and
    /// scale. `note` itself is assumed to be in the scale. Chromatic has every
    /// semitone, so a step is always a semitone there.
    fn step(note: i32, key: u8, scale: u8, steps: i32) -> i32 {
        let direction = steps.signum();
        let mut current = note;
        for _ in 0..steps.abs() {
            // Every key and scale has a member within twelve semitones, so this
            // walk always terminates well before then.
            for _ in 0..12 {
                current += direction;
                if in_scale(key, scale, current) {
                    break;
                }
            }
        }
        current
    }

    /// Turn the detected pitch into the ratio for the asked-for degree. Zero is
    /// not a note; the previous ratio is held instead.
    fn interval_ratio(&self, hz: f32) -> f32 {
        if hz <= 0.0 {
            return self.ratio;
        }
        let midi = 69.0 + 12.0 * (hz / 440.0).log2();
        let base = nearest_in_scale(midi, self.key, self.scale) as i32;
        let target = Self::step(base, self.key, self.scale, i32::from(self.degree) - 3);
        let target_hz = 440.0 * 2f32.powf((target as f32 - 69.0) / 12.0);
        if target_hz.is_finite() && target_hz > 0.0 {
            // Three scale steps are at most a fifth (the minor pentatonic's
            // C–E♭–F–G); this clamp only catches a wild detector jump, never a
            // musical interval.
            (target_hz / hz).clamp(0.25, 4.0)
        } else {
            self.ratio
        }
    }
}

impl Effect for Harmonizer {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let ring_len = ((self.rate as f32 * RING_SECONDS) as usize).max(MIN_RING);
        self.shift_window = ((self.rate as f32 * SHIFT_SECONDS) as usize).clamp(64, ring_len / 4);
        self.hop = ((self.rate as f32 * HOP_SECONDS) as usize).max(64);
        self.ring = vec![0.0; ring_len];
        self.detector.prepare(self.rate, ring_len);
        self.write = 0;
        self.since_analysis = 0;
        self.mix = self.target_mix;
        self.ratio = 1.0;
        self.current_ratio = 1.0;
        self.phase = 0.0;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
        self.retune = one_pole(RETUNE_SECONDS, self.rate) as f32;
        self.prepared = true;
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared
            || self.ring.len() < 64
            || self.shift_window < 8
            || self.detector.analysis_len() < 64
        {
            return;
        }
        let window = self.shift_window as f32;
        let length = self.ring.len();
        for sample in block.iter_mut() {
            self.ring[self.write] = *sample;
            self.mix += (self.target_mix - self.mix) * self.smooth;
            self.current_ratio += (self.ratio - self.current_ratio) * self.retune;

            let (tap_a, gain_a, tap_b, gain_b) = grain_taps(self.phase);
            let wet = grain_tap(&self.ring, self.write, tap_a * window) * gain_a
                + grain_tap(&self.ring, self.write, tap_b * window) * gain_b;
            // The grains' weighted delay is half the window, so the dry leg is
            // aligned there and `mix` does not comb.
            let dry = grain_tap(&self.ring, self.write, window * 0.5);
            *sample = dry + (wet - dry) * self.mix;

            let increment = (1.0 - self.current_ratio) / window;
            self.phase += increment;
            if self.phase >= 1.0 {
                self.phase -= 1.0;
            } else if self.phase < 0.0 {
                self.phase += 1.0;
            }
            self.write = (self.write + 1) % length;

            self.since_analysis += 1;
            if self.since_analysis >= self.hop {
                self.since_analysis = 0;
                let hz = self.detector.detect(&self.ring, self.write);
                self.ratio = self.interval_ratio(hz);
            }
        }
    }

    fn reset(&mut self) {
        self.ring.fill(0.0);
        self.detector.reset();
        self.write = 0;
        self.since_analysis = 0;
        self.mix = self.target_mix;
        self.ratio = 1.0;
        self.current_ratio = 1.0;
        self.phase = 0.0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "key" => {
                if usable {
                    self.key = (value.round() as i32).clamp(0, i32::from(Self::MAX_KEY)) as u8;
                }
                true
            }
            "scale" => {
                if usable {
                    self.scale = (value.round() as i32)
                        .clamp(0, Self::SCALES.len() as i32 - 1)
                        as u8;
                }
                true
            }
            "degree" => {
                if usable {
                    self.degree = (value.round() as i32).clamp(0, i32::from(Self::MAX_DEGREE)) as u8;
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
        "harmonizer"
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

    fn render(harmonizer: &mut Harmonizer, input: &[f32]) -> Vec<f32> {
        harmonizer.prepare(RATE, input.len());
        let mut block = input.to_vec();
        harmonizer.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut harmonizer = Harmonizer::new(0, 0, Harmonizer::DEFAULT_DEGREE, 1.0);
        let output = render(&mut harmonizer, &vec![0.0f32; 8192]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn a_third_above_a_is_c() {
        // A4 (MIDI 69) is in C major. Two scale steps up is C5, a minor third,
        // so the ratio is 2^(3/12) = 1.1892.
        let input = sine(440.0, 0.5, RATE as usize);
        let mut harmonizer = Harmonizer::new(0, 0, 5, 1.0);
        render(&mut harmonizer, &input);
        assert!(
            (harmonizer.ratio - 1.189_207).abs() < 0.01,
            "the third was not C: ratio {}",
            harmonizer.ratio
        );
    }

    #[test]
    fn unison_is_ratio_one() {
        let input = sine(440.0, 0.5, RATE as usize);
        let mut harmonizer = Harmonizer::new(0, 0, 3, 1.0);
        render(&mut harmonizer, &input);
        assert!(
            (harmonizer.ratio - 1.0).abs() < 0.01,
            "unison moved the pitch: {}",
            harmonizer.ratio
        );
    }

    #[test]
    fn mix_zero_is_the_aligned_dry_leg() {
        let input = sine(440.0, 0.4, 4096);
        let mut harmonizer = Harmonizer::new(0, 0, 5, 0.0);
        let output = render(&mut harmonizer, &input);
        let half = (RATE as f32 * SHIFT_SECONDS) as usize / 2;
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
        let mut harmonizer = Harmonizer::new(0, 0, 5, 1.0);
        harmonizer.prepare(RATE, input.len());
        let mut first = input.clone();
        harmonizer.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));

        harmonizer.reset();
        let mut second = input.clone();
        harmonizer.process(&mut second);
        assert_eq!(first, second, "reset did not return to the first run");
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut harmonizer = Harmonizer::new(0, 0, 3, 0.5);
        assert!(harmonizer.set("key", 42.0));
        assert_eq!(harmonizer.key, Harmonizer::MAX_KEY);
        assert!(harmonizer.set("key", -4.0));
        assert_eq!(harmonizer.key, 0);
        assert!(harmonizer.set("scale", 9.0));
        assert_eq!(harmonizer.scale, 3);
        assert!(harmonizer.set("degree", 99.0));
        assert_eq!(harmonizer.degree, Harmonizer::MAX_DEGREE);
        assert!(harmonizer.set("mix", 2.0));
        assert_eq!(harmonizer.target_mix, 1.0);
        assert!(harmonizer.set("mix", f32::NAN));
        assert_eq!(harmonizer.target_mix, 1.0, "NaN moved a knob");
        assert!(!harmonizer.set("speed", 1.0));
        assert!(!harmonizer.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn two_steps_in_pentatonic_are_a_fourth() {
        // The contract's pentatonic is the minor pentatonic (C, E♭, F, G, B♭),
        // so two steps above C5 are E♭5 then F5: five semitones, 1.3348. The
        // walk skips the notes the scale does not contain.
        let input = sine(523.251, 0.5, RATE as usize);
        let mut harmonizer = Harmonizer::new(0, 3, 5, 1.0);
        render(&mut harmonizer, &input);
        assert!(
            (harmonizer.ratio - 1.334_84).abs() < 0.01,
            "the pentatonic step was not a fourth: {}",
            harmonizer.ratio
        );
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(
            InsertKind::parse("harmonizer"),
            Some(InsertKind::Harmonizer)
        );
        assert_eq!(InsertKind::Harmonizer.name(), "harmonizer");
        assert_eq!(
            InsertKind::Harmonizer.controls(),
            &["key", "scale", "degree", "mix"]
        );
        assert_eq!(InsertKind::Harmonizer.code(), 17);
        assert_eq!(InsertKind::from_code(17), Some(InsertKind::Harmonizer));
        assert_eq!(InsertKind::Harmonizer.build().name(), "harmonizer");
    }
}
