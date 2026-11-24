//! The polyphonic instrument: voice allocation, the shared LFO and the render
//! loop.
//!
//! # Buffers and rate
//!
//! [`Synth::new`] fixes the sample rate and sizes every buffer by calling
//! [`Synth::prepare`]. The pluck delay lines are the only sizeable buffers:
//! each of the [`MAX_VOICES`] voices owns one, sized for the longest period a
//! pluck accepts (50 ms, the same limit `createDelay(0.05)` imposes in the
//! browser), so a note can never allocate in the audio callback. The rate is
//! clamped to 8 kHz..384 kHz.
//!
//! [`Synth::render`] does not require the lengths to match the `period` passed
//! to `prepare`. It processes `left.len().min(right.len())` samples and leaves
//! any excess in the longer slice untouched. That is deliberate: a host that
//! hands over an odd-sized final block keeps working, and no allocation or
//! copy is needed. `prepare` is still where the buffers are sized; re-preparing
//! at the same rate keeps the voices, and a different size resets them.
//!
//! # Voice allocation
//!
//! `note_on` retriggers a voice already playing the same note (the browser
//! stacks them; this engine replaces, as the crate's brief asks), takes a free
//! slot, or steals the oldest voice — preferring one already in its release so
//! a held note survives. Active voices never exceed `patch.voices`. The stolen
//! voice is silenced immediately, matching `stealing()`.
//!
//! `note_off` starts a release; with the sustain pedal down it instead marks
//! the note, and releasing the pedal releases every marked note.
//!
//! # Determinism
//!
//! Every note-on takes the next value of an internal counter as its voice seed,
//! so the same event sequence produces the same samples twice. See
//! [`crate::rng`] for the one caveat about libm and different architectures.

use crate::master::{drive, soft_clip, tremolo_gain, Compressor};
use crate::patch::Patch;
use crate::voice::{Voice, MAX_PLUCK_SECONDS};
use std::f32::consts::TAU;

/// The largest number of voices this synth can ever hold. `patch.voices` caps
/// the active count below this.
pub const MAX_VOICES: usize = 64;

/// The block size `new` prepares when the caller has not chosen one.
const DEFAULT_BLOCK: usize = 512;

/// Convert a (possibly fractional) MIDI note to Hz, the browser's
/// `midiToFreq`: A4 (69) is 440 Hz.
pub fn midi_to_hz(note: f32) -> f32 {
    440.0 * 2f32.powf((note - 69.0) / 12.0)
}

/// A polyphonic synth rendering one patch.
pub struct Synth {
    rate: f32,
    patch: Patch,
    voices: [Voice; MAX_VOICES],
    lfo_phase: f32,
    last_freq: f32,
    seed: u64,
    age: u64,
    sustain_on: bool,
    pedal: [bool; 128],
    block: usize,
    compressor: Compressor,
}

impl Synth {
    /// Build a synth for `patch` at `rate` Hz. The patch is clamped, every
    /// buffer is sized for the rate, and no voice is playing.
    pub fn new(patch: Patch, rate: f32) -> Self {
        let rate = if rate.is_finite() && rate >= 8000.0 {
            rate.min(384_000.0)
        } else {
            48_000.0
        };
        let patch = patch.clamped();
        let mut synth = Synth {
            rate,
            patch,
            voices: std::array::from_fn(|_| Voice::silent(0)),
            lfo_phase: 0.0,
            last_freq: 0.0,
            seed: 0,
            age: 0,
            sustain_on: false,
            pedal: [false; 128],
            block: DEFAULT_BLOCK,
            compressor: Compressor::new(rate),
        };
        synth.prepare(DEFAULT_BLOCK);
        synth
    }

    /// Size every buffer and record the host block length. `period` is clamped
    /// to at least one sample. Calling this again at the same rate is a no-op
    /// for the voices; if the voice buffers ever need a different size, the
    /// voices are reset, which can only happen if a future `set_rate` is added.
    pub fn prepare(&mut self, period: usize) {
        self.block = period.max(1);
        let needed = (self.rate * MAX_PLUCK_SECONDS) as usize + 4;
        if self.voices[0].delay_len() != needed {
            self.voices = std::array::from_fn(|_| Voice::silent(needed));
        }
        self.compressor.configure(self.rate);
    }

    /// The sample rate this synth renders at.
    pub fn sample_rate(&self) -> f32 {
        self.rate
    }

    /// The block length last passed to [`Synth::prepare`].
    pub fn block_len(&self) -> usize {
        self.block
    }

    /// The current (clamped) patch.
    pub fn patch(&self) -> &Patch {
        &self.patch
    }

    /// Replace the patch. It is clamped again. Running voices keep the patch
    /// they started with, except for the shared LFO and the master drive, which
    /// are read live — the same split the browser has. Lowering `voices`
    /// immediately steals down to the new cap.
    pub fn set_patch(&mut self, patch: Patch) {
        self.patch = patch.clamped();
        self.enforce_voice_cap();
    }

    /// Start a note with a velocity in `0..=1`. The note is clamped to
    /// `0..=127`; velocity is clamped to `0..=1`.
    pub fn note_on(&mut self, note: u8, velocity: f32) {
        let note = note.min(127);
        let velocity = if velocity.is_finite() {
            velocity.clamp(0.0, 1.0)
        } else {
            0.0
        };
        let patch = self.patch;
        let from_freq = self.last_freq;
        let frequency = midi_to_hz(note as f32 + patch.transpose);
        self.last_freq = frequency;

        self.age = self.age.wrapping_add(1);
        let age = self.age;
        self.seed = self.seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let seed = self.seed ^ ((note as u64) << 32);

        self.pedal[note as usize] = false;

        let retrigger = self
            .voices
            .iter()
            .position(|voice| voice.active && voice.note == note);
        let index = match retrigger {
            Some(index) => index,
            None => match self.voices.iter().position(|voice| !voice.active) {
                Some(index) => index,
                None => self.victim(),
            },
        };
        self.voices[index].trigger(
            note,
            velocity,
            patch,
            self.rate,
            age,
            from_freq,
            seed,
        );
        self.enforce_voice_cap();
    }

    /// Release every voice playing `note`, unless the sustain pedal is down; in
    /// that case the note is released when the pedal comes up.
    pub fn note_off(&mut self, note: u8) {
        let note = note.min(127);
        if self.sustain_on {
            self.pedal[note as usize] = true;
            return;
        }
        self.release_note(note);
    }

    /// Set the sustain pedal. Lifting it releases every note held by it.
    pub fn sustain(&mut self, on: bool) {
        self.sustain_on = on;
        if on {
            return;
        }
        for note in 0..128u8 {
            if self.pedal[note as usize] {
                self.pedal[note as usize] = false;
                self.release_note(note);
            }
        }
    }

    /// Release every voice and clear the pedal. Voices finish with their normal
    /// release, exactly as `allNotesOff()` schedules them in the browser.
    pub fn all_notes_off(&mut self) {
        for voice in &mut self.voices {
            if voice.active {
                voice.release(self.rate);
            }
        }
        self.pedal = [false; 128];
    }

    /// How many voices are still rendering, including voices in their release.
    pub fn active_voices(&self) -> usize {
        self.voices.iter().filter(|voice| voice.active).count()
    }

    /// Whether any active voice is playing `note`.
    pub fn note_active(&self, note: u8) -> bool {
        let note = note.min(127);
        self.voices
            .iter()
            .any(|voice| voice.active && voice.note == note)
    }

    /// Render into the two output slices. Both channels receive the same mono
    /// signal; the synth has no panning.
    ///
    /// Processes `left.len().min(right.len())` samples. Does not allocate,
    /// lock, or panic on empty or mismatched slices.
    pub fn render(&mut self, left: &mut [f32], right: &mut [f32]) {
        let frames = left.len().min(right.len());
        if frames == 0 {
            return;
        }
        let rate = self.rate;
        let lfo_rate = if self.patch.lfo.rate > 0.0 {
            self.patch.lfo.rate
        } else {
            5.0
        };
        let tremolo = self.patch.lfo.amp;

        for frame in 0..frames {
            let lfo = (TAU * self.lfo_phase).sin();
            self.lfo_phase += lfo_rate / rate;
            if self.lfo_phase >= 1.0 {
                self.lfo_phase -= 1.0;
            }

            let mut mixed = 0.0;
            for voice in &mut self.voices {
                if voice.active {
                    mixed += voice.render(lfo, rate);
                }
            }

            let staged = mixed * tremolo_gain(lfo, tremolo);
            let shaped = drive(staged, self.patch.drive);
            let compressed = self.compressor.process(shaped);
            let sample = soft_clip(compressed);
            left[frame] = sample;
            right[frame] = sample;
        }
    }

    /// The index of the voice to steal: the oldest released voice if there is
    /// one, otherwise the oldest voice of any kind.
    fn victim(&self) -> usize {
        let mut oldest_released: Option<(usize, u64)> = None;
        let mut oldest: Option<(usize, u64)> = None;
        for (index, voice) in self.voices.iter().enumerate() {
            if !voice.active {
                continue;
            }
            if oldest.map_or(true, |(_, age)| voice.age < age) {
                oldest = Some((index, voice.age));
            }
            if voice.released && oldest_released.map_or(true, |(_, age)| voice.age < age) {
                oldest_released = Some((index, voice.age));
            }
        }
        oldest_released.or(oldest).map(|(index, _)| index).unwrap_or(0)
    }

    /// Steal down to `patch.voices` active voices.
    fn enforce_voice_cap(&mut self) {
        let cap = (self.patch.voices as usize).clamp(1, MAX_VOICES);
        let mut active = self.active_voices();
        while active > cap {
            let index = self.victim();
            self.voices[index].kill();
            active -= 1;
        }
    }

    fn release_note(&mut self, note: u8) {
        for voice in &mut self.voices {
            if voice.active && !voice.released && voice.note == note {
                voice.release(self.rate);
            }
        }
    }
}
