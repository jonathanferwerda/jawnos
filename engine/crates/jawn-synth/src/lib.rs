//! The JawnOS native synth.
//!
//! A deterministic, polyphonic instrument rendered by pure Rust, with no
//! device and no dependencies. The patch is the browser synth's patch JSON
//! (`public/js/manager/synth/01_engine.js` and `synth_presets.js`), field for
//! field, so a saved patch can be handed straight to a bridge later. The engine
//! owns the transport and the device; this crate only produces samples.
//!
//! # Shape
//!
//! * [`Patch`] mirrors the JSON, including the Grand Piano fallback as
//!   [`Patch::default`], and clamps every value to the browser's ranges.
//! * [`Synth::note_on`] / [`Synth::note_off`] allocate voices; [`Synth::render`]
//!   sums them and runs the master chain. `render` does not allocate, lock, or
//!   panic.
//! * [`Synth::prepare`] sizes the buffers (each voice owns a pluck delay line),
//!   and `render` accepts any slice length, not only the prepared block.
//!
//! # Deliberate divergences from the browser engine
//!
//! These are choices, not gaps; each is also noted at its use site.
//!
//! * **Waveforms.** Web Audio's `PeriodicWave` tables are band-limited and
//!   peak-normalised by the browser. Native sawtooth and square are limited
//!   with polyBLEP; the four `HARMONICS` waves are summed directly and divided
//!   by the sum of their coefficients. They are close, not sample-identical.
//! * **Release.** The amp release is a linear ramp to exactly zero, so a
//!   finished voice is provably silent. The browser's `setTargetAtTime`
//!   approaches a floor and then kills the voice on a timer.
//! * **Same-note retrigger replaces.** The browser lets a second `noteOn` for a
//!   held note stack another voice. This engine reuses the voice, per the
//!   engine brief.
//! * **Glide is polyphonic.** The browser passes a glide start frequency only
//!   in mono mode; here every subtractive note-on glides from the previous
//!   note's frequency when `patch.glide > 0`.
//! * **Pluck loop filter.** A one-pole replaces the browser's biquad, the
//!   classic Karplus-Strong choice; the delay line is shortened by the filter's
//!   phase delay so the pitch stays right.
//! * **Master safety.** A final soft clip bends anything above 0.8 toward 0.99,
//!   so a hot patch can never emit full-scale or non-finite samples. The
//!   browser leaves clipping to the device. The compressor is a simpler
//!   feed-forward peak detector than Web Audio's `DynamicsCompressorNode`.
//! * **Not implemented.** There is no arpeggiator, step sequencer, mono mode,
//!   pitch bend, mod wheel, MIDI, preset library, knob mapping or learn mode:
//!   those are transport/UI concerns in `01_engine.js`, not voice DSP.
//!
//! # Stereo
//!
//! The synth is mono. `render` writes the same sample to both channels, which
//! leaves a later stereo voice or pan law free to change only the output stage.

// The audio path must never be able to reach for unsafe: a fault there is a
// click in the house, not a failed request.
#![forbid(unsafe_code)]

mod env;
mod filter;
mod master;
mod osc;
mod patch;
mod rng;
mod synth;
mod voice;

#[cfg(test)]
mod tests;

pub use patch::{Engine, Envelope, Filter, FilterKind, Lfo, Osc, Patch, Wave};
pub use synth::{midi_to_hz, Synth, MAX_VOICES};
