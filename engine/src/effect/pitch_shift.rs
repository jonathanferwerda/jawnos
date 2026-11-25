//! The `pitch_shift` pedal: a fixed-interval granular shifter.
//!
//! # The model
//!
//! ```text
//! in ──► history ring ──► two crossfaded grains ──► wet
//!   │                      (ratio 2^(semitones/12))    │
//!   └────────────► aligned dry (half a window) ────────┤
//!                                                      ▼
//!                                     dry + mix · (wet − dry)
//! ```
//!
//! No detector: the interval is the knob. `semitones` is −24..+24, rounded to
//! a whole semitone, and the grains' read pointer travels at
//! `ratio = 2^(semitones/12)` through the same [`SHIFT_SECONDS`] window the
//! corrector uses. The two taps sweep in opposite halves of the window and
//! their gains sum to one ([`grain_taps`]), so the copy is crossfaded rather
//! than spliced; `mix` blends it with the aligned dry leg.
//!
//! `semitones` and `mix` are the contract's natural units
//! (`docs/studio-effects.md`); there is no `sync` control.
//!
//! # The honest approximation
//!
//! * **Granular, not phase-vocoder.** A sweeping tap is a resampler, so a large
//!   shift adds a little warble and loses some clarity; there is no phase
//!   locking and no formant preservation. An octave is the clean end of its
//!   range, two octaves the rough end.
//! * **Latency, not zero.** A shifted grain reads on average half the
//!   [`SHIFT_SECONDS`] window back (15 ms at 48 kHz), and the dry leg is
//!   delayed to match so `mix` cannot comb. It is an insert, not a look-ahead
//!   tool.
//! * **Monophonic in practice.** Like every shifter of this kind it treats the
//!   signal as one voice; a chord is shifted as a whole and can beat against
//!   itself. Nothing here pretends to separate voices.
//! * **One window, not many.** Two grains are enough for a clean interval; a
//!   denser grain cloud would cost more for little audible gain on an insert.

use super::autotune::{grain_tap, grain_taps, MIN_RING, RING_SECONDS, SHIFT_SECONDS};
use super::{one_pole, Effect, SMOOTH_SECONDS};

#[derive(Debug)]
pub struct PitchShift {
    rate: u32,
    target_semitones: f32,
    semitones: f32,
    target_mix: f32,
    mix: f32,
    ring: Vec<f32>,
    write: usize,
    shift_window: usize,
    ratio: f32,
    current_ratio: f32,
    phase: f32,
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
            shift_window: 0,
            ratio: Self::ratio(semitones),
            current_ratio: Self::ratio(semitones),
            phase: 0.0,
            smooth: 0.0,
            prepared: false,
        }
    }

    fn ratio(semitones: f32) -> f32 {
        2f32.powf(semitones / 12.0)
    }
}

impl Effect for PitchShift {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let ring_len = ((self.rate as f32 * RING_SECONDS) as usize).max(MIN_RING);
        self.shift_window = ((self.rate as f32 * SHIFT_SECONDS) as usize).clamp(64, ring_len / 4);
        self.ring = vec![0.0; ring_len];
        self.write = 0;
        self.semitones = self.target_semitones;
        self.mix = self.target_mix;
        self.ratio = Self::ratio(self.semitones);
        self.current_ratio = self.ratio;
        self.phase = 0.0;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
        self.prepared = true;
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared || self.ring.len() < 64 || self.shift_window < 8 {
            return;
        }
        let window = self.shift_window as f32;
        let length = self.ring.len();
        for sample in block.iter_mut() {
            self.ring[self.write] = *sample;
            self.semitones += (self.target_semitones - self.semitones) * self.smooth;
            self.mix += (self.target_mix - self.mix) * self.smooth;
            self.ratio = Self::ratio(self.semitones);
            self.current_ratio += (self.ratio - self.current_ratio) * self.smooth;

            let (tap_a, gain_a, tap_b, gain_b) = grain_taps(self.phase);
            let wet = grain_tap(&self.ring, self.write, tap_a * window) * gain_a
                + grain_tap(&self.ring, self.write, tap_b * window) * gain_b;
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
        }
    }

    fn reset(&mut self) {
        self.ring.fill(0.0);
        self.write = 0;
        self.semitones = self.target_semitones;
        self.mix = self.target_mix;
        self.ratio = Self::ratio(self.semitones);
        self.current_ratio = self.ratio;
        self.phase = 0.0;
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

    #[test]
    fn silence_in_stays_silence() {
        let mut shifter = PitchShift::new(7.0, 1.0);
        let output = render(&mut shifter, &vec![0.0f32; 8192]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn an_octave_up_doubles_the_zero_crossings() {
        let input = sine(220.0, 0.4, RATE as usize);
        let mut shifter = PitchShift::new(12.0, 1.0);
        let output = render(&mut shifter, &input);
        // Skip the first 200 ms: the grains need to settle and the ring fills.
        let settled = &output[9_600..];
        let source = &input[9_600..];
        let before = count_zero_crossings(source);
        let after = count_zero_crossings(settled);
        let ratio = after as f32 / before as f32;
        assert!(
            (1.85..=2.15).contains(&ratio),
            "an octave was not an octave: {ratio}"
        );
    }

    #[test]
    fn an_octave_down_halves_the_zero_crossings() {
        let input = sine(440.0, 0.4, RATE as usize);
        let mut shifter = PitchShift::new(-12.0, 1.0);
        let output = render(&mut shifter, &input);
        let settled = &output[9_600..];
        let source = &input[9_600..];
        let ratio =
            count_zero_crossings(settled) as f32 / count_zero_crossings(source) as f32;
        assert!(
            (0.40..=0.60).contains(&ratio),
            "an octave down was not half: {ratio}"
        );
    }

    #[test]
    fn mix_zero_is_the_aligned_dry_leg() {
        let input = sine(440.0, 0.4, 4096);
        let mut shifter = PitchShift::new(7.0, 0.0);
        let output = render(&mut shifter, &input);
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
