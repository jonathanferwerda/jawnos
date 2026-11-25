//! The JawnOS native drum machine.
//!
//! The Studio drum machine is eight voices and ten kits, all synthesised from
//! oscillators and filtered noise. The browser renders each voice once into an
//! `AudioBuffer` (`public/js/manager/studio/11_drums.js`); this crate is the same
//! machine in Rust, with no samples, no files and no C dependency.
//!
//! The crate ships **inert**: the engine owns the transport and the device, and
//! this library is not yet wired into `engine/src/`. A later pass can load a kit
//! once, then call [`Machine::render`] from the audio callback. Nothing here
//! touches a device, allocates in the render path, or needs a clock.
//!
//! # Shape of the machine
//!
//! - [`VoiceSpec`] is the shape of one voice: an optional list of pitched
//!   [`ToneSpec`] sweeps and an optional list of [`NoiseSpec`] bursts.
//! - [`Kit::spec`] applies a kit's overrides to the acoustic base exactly as
//!   `studioDrumsVoiceSpec` does in the browser.
//! - [`render_voice`] renders a spec offline into a `Vec<f32>` with a fixed
//!   PRNG for the noise. It is allowed to allocate; [`Machine::render`] is not.
//! - [`Machine`] is the real-time player: eight rendered voice buffers, a fixed
//!   pool of overlapping hits, and an allocation-free block renderer.
//! - [`Pattern`] is an optional sixteenth-note chart a future transport can
//!   schedule against [`Machine::trigger_at`].
//! - [`Performance`] is the human on the kit: a named [`Player`] (Tuck, Wren,
//!   Odile, Moxie, Bram, Dov) in a [`Style`] (soft, hard, aggressive) turns a
//!   chart cell into a velocity and a small timing offset. It is a pure
//!   function of the cell and the absolute step, so each loop pass differs and
//!   the render path still allocates nothing.
//!
//! # Deliberate divergences from the browser
//!
//! - The browser's noise is `Math.random()`; here it is a fixed SplitMix64
//!   stream seeded per voice, so a kit renders identically every time.
//! - The browser's oscillator waveforms are band-limited `PeriodicWave`s. The
//!   shapes here are the naive sine/triangle/square/sawtooth functions, with no
//!   anti-aliasing. Drums are short, transient voices and the difference is
//!   below the level of the kit; keeping the renderer dependency-free matters
//!   more.
//! - The browser clamps the playback gain of a velocity to at least `0.1`
//!   (`Math.max(0.1, ...)`). Here velocity is a straight `0..=100` percent:
//!   `1` is `0.01` and `0` is silent, which the machine needs for an off step.
//! - The browser leaves `BiquadFilterNode.Q` at its default `1` dB for the
//!   high-pass and low-pass bursts. This crate treats Q as linear for every
//!   filter type, transcribed as `1.0` where the JS omits it, and implements the
//!   RBJ cookbook biquad.
//! - Overlapping hits are kept, like the browser's one-source-per-hit model; a
//!   same-slot retrigger starts a second voice rather than cutting the first.
//!   The fixed pool steals its oldest hit when all [`MAX_HITS`] slots are busy.
//!
//! # Velocity
//!
//! A trigger takes `0..=100`. `0` is off and does not allocate a voice; `1..=100`
//! is mapped to the linear gain `velocity / 100` and clamped to that range. A
//! plain Studio click is `70`, an accent is `100`. A [`Performance`] adjusts the
//! velocity a chart cell carries before it reaches [`Machine::trigger_at`]; the
//! machine itself still takes a plain `0..=100`.

#![forbid(unsafe_code)]

mod dsp;
mod kit;
mod machine;
mod pattern;
mod player;

pub use dsp::{render_voice, render_voice_with_seed, voice_seed, DEFAULT_SEED};
pub use kit::Kit;
pub use machine::{Machine, MAX_HITS};
pub use pattern::{sixteenth_frames, Pattern, PatternEvent};
pub use player::{ExtraHit, Performance, Played, Player, Style};

/// The waveform of a pitched drum voice.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Wave {
    /// A sine wave; the toms and the kick.
    Sine,
    /// A triangle wave; the snare body.
    Triangle,
    /// A square wave; the rim click.
    Square,
    /// A sawtooth wave. No current kit uses it, but the data model and the
    /// browser support it.
    Sawtooth,
}

/// The filter applied to a noise burst.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FilterKind {
    /// Passes everything above the cutoff; hats and the kick's click.
    Highpass,
    /// A resonant band around the centre frequency; the snare, clap and rim.
    Bandpass,
    /// Passes everything below the cutoff.
    Lowpass,
}

/// One of the eight Studio drum rows.
///
/// The order and wire names are pinned by `perl/gb/05_abilities_and_studio.pl`
/// (`drums`), and a slot index into [`Machine`] is [`Voice::index`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Voice {
    /// The kick drum.
    Kick,
    /// The snare drum.
    Snare,
    /// The closed hi-hat.
    ClosedHat,
    /// The open hi-hat.
    OpenHat,
    /// The hand clap.
    Clap,
    /// The low tom.
    LowTom,
    /// The high tom.
    HighTom,
    /// The rim click.
    Rim,
}

impl Voice {
    /// Every voice, in the Studio row order.
    pub const ALL: [Voice; 8] = [
        Voice::Kick,
        Voice::Snare,
        Voice::ClosedHat,
        Voice::OpenHat,
        Voice::Clap,
        Voice::LowTom,
        Voice::HighTom,
        Voice::Rim,
    ];

    /// The number of voices in a kit; also the number of slots a [`Machine`]
    /// accepts.
    pub const COUNT: usize = Voice::ALL.len();

    /// The row's position in the Studio chart and in a [`Machine`].
    pub const fn index(self) -> usize {
        match self {
            Voice::Kick => 0,
            Voice::Snare => 1,
            Voice::ClosedHat => 2,
            Voice::OpenHat => 3,
            Voice::Clap => 4,
            Voice::LowTom => 5,
            Voice::HighTom => 6,
            Voice::Rim => 7,
        }
    }

    /// The wire name used by the browser and saved in a song.
    pub const fn name(self) -> &'static str {
        match self {
            Voice::Kick => "kick",
            Voice::Snare => "snare",
            Voice::ClosedHat => "closed_hat",
            Voice::OpenHat => "open_hat",
            Voice::Clap => "clap",
            Voice::LowTom => "low_tom",
            Voice::HighTom => "high_tom",
            Voice::Rim => "rim",
        }
    }

    /// The voice with this exact wire name, case-sensitive like the browser's
    /// names. Unknown names return `None`.
    pub fn from_name(name: &str) -> Option<Voice> {
        Voice::ALL.iter().copied().find(|voice| voice.name() == name)
    }
}

/// One pitched component of a voice: an oscillator whose frequency sweeps
/// exponentially from `from_hz` to `to_hz` over `dur` seconds, shaped by an
/// exponential envelope.
///
/// This mirrors the browser's `{ type, from, to, dur, gain, env, at }` object.
#[derive(Debug, Clone, PartialEq)]
pub struct ToneSpec {
    /// The oscillator shape.
    pub wave: Wave,
    /// The starting frequency in hertz.
    pub from_hz: f32,
    /// The frequency at the end of the sweep, held afterwards. Frequencies below
    /// 20 Hz are clamped to 20 Hz at render time, as the browser does.
    pub to_hz: f32,
    /// The sweep time in seconds.
    pub dur: f32,
    /// The envelope's peak gain. Values above 1 are allowed and are how a kick
    /// gets its body.
    pub gain: f32,
    /// The time in seconds for the envelope to fall back to near zero. The
    /// browser falls back to `dur` when this is absent; every Studio tone names
    /// it, so this field is a plain number.
    pub env: f32,
    /// The offset within the voice at which the tone starts, in seconds.
    pub at: f32,
}

impl ToneSpec {
    /// A tone starting at the voice's origin with the given shape and envelope.
    pub const fn new(
        wave: Wave,
        from_hz: f32,
        to_hz: f32,
        dur: f32,
        gain: f32,
        env: f32,
    ) -> Self {
        ToneSpec {
            wave,
            from_hz,
            to_hz,
            dur,
            gain,
            env,
            at: 0.0,
        }
    }

    /// Move this tone's start within the voice, in seconds.
    pub const fn with_at(mut self, at: f32) -> Self {
        self.at = at;
        self
    }
}

/// One filtered noise component of a voice.
///
/// The browser creates a fresh noise buffer per voice and plays every burst
/// from offset zero of that buffer; this crate does the same, so two bursts in
/// one voice share a noise sequence before their own filters and envelopes.
#[derive(Debug, Clone, PartialEq)]
pub struct NoiseSpec {
    /// The filter shape.
    pub filter: FilterKind,
    /// The filter's cutoff or centre frequency in hertz.
    pub freq: f32,
    /// The filter's resonance, linear. The browser's high-pass and low-pass Q is
    /// in decibels; the JS leaves those at the default of 1, transcribed here as
    /// the linear value `1.0`.
    pub q: f32,
    /// The noise burst's duration in seconds.
    pub dur: f32,
    /// The envelope's peak gain.
    pub gain: f32,
    /// The offset within the voice at which the burst starts, in seconds.
    pub at: f32,
}

impl NoiseSpec {
    /// A burst starting at the voice's origin.
    pub const fn new(filter: FilterKind, freq: f32, q: f32, dur: f32, gain: f32) -> Self {
        NoiseSpec {
            filter,
            freq,
            q,
            dur,
            gain,
            at: 0.0,
        }
    }

    /// Move this burst's start within the voice, in seconds.
    pub const fn with_at(mut self, at: f32) -> Self {
        self.at = at;
        self
    }
}

/// The shape of one drum voice: how long its rendered buffer is, and the
/// pitched and noise components that fill it.
#[derive(Debug, Clone, PartialEq)]
pub struct VoiceSpec {
    /// The rendered buffer's length in seconds. Non-positive or non-finite
    /// values fall back to `0.6` at render time, matching the browser's
    /// `spec.length || 0.6`.
    pub length_seconds: f32,
    /// Pitched sweeps, mixed in order.
    pub tones: Vec<ToneSpec>,
    /// Filtered noise bursts, mixed in order.
    pub noise: Vec<NoiseSpec>,
}

impl VoiceSpec {
    /// A silent spec of the given length.
    pub const fn new(length_seconds: f32) -> Self {
        VoiceSpec {
            length_seconds,
            tones: Vec::new(),
            noise: Vec::new(),
        }
    }

    /// Set the spec's pitched components.
    pub fn with_tones(mut self, tones: Vec<ToneSpec>) -> Self {
        self.tones = tones;
        self
    }

    /// Set the spec's noise bursts.
    pub fn with_noise(mut self, noise: Vec<NoiseSpec>) -> Self {
        self.noise = noise;
        self
    }
}
