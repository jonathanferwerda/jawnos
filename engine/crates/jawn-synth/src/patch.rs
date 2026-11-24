//! The patch: the browser synth's patch JSON, field for field.
//!
//! `public/js/manager/synth_presets.js` stores a patch as a plain object with
//! `engine`, `wave`, `noise`, `voices`, `transpose`, `glide`, `drive`,
//! `damping`, `brightness`, `osc`, `filter`, `amp`, `fenv` and `lfo`. The types
//! here keep those names so a bridge can copy one into the other without a
//! translation table. Two small Rust-only additions are documented where they
//! occur: [`Patch::osc_count`] (the JSON `osc` array may hold one or two
//! entries, while Rust needs a fixed array) and `filter.kind` (the JSON key is
//! `filter.type`, which is a Rust keyword).
//!
//! # Clamping
//!
//! Every range below mirrors a clamp the browser applies: `set()` and
//! `stealing()` in `public/js/manager/synth/01_engine.js` for the knob-backed
//! fields, and the use sites in `newVoice()`, `voiceEnv()` and `filterEnv()`
//! for the rest. A non-finite value becomes the lower bound of its range, which
//! keeps the oscillator and filter finite instead of poisoning them with NaN.
//! Fields the browser leaves unclamped are clamped here only as far as the DSP
//! needs; those cases are called out on the field.

/// Which voice engine renders a note.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Engine {
    /// Two oscillators into a resonant filter, with an amp envelope.
    Subtractive,
    /// Karplus-Strong: a noise strike into a delay line with a lowpass loop.
    Pluck,
}

impl Engine {
    /// The browser's `patch.engine` string, `"subtractive"` or `"pluck"`.
    pub fn name(self) -> &'static str {
        match self {
            Engine::Subtractive => "subtractive",
            Engine::Pluck => "pluck",
        }
    }

    /// Parse the browser's `patch.engine` string. Unknown names return `None`
    /// so a bridge can fall back to [`Engine::Subtractive`].
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "subtractive" => Some(Engine::Subtractive),
            "pluck" => Some(Engine::Pluck),
            _ => None,
        }
    }
}

/// An oscillator shape: four basic waves plus four harmonic tables.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wave {
    /// A pure sine.
    Sine,
    /// A band-limited (polyBLEP) sawtooth.
    Sawtooth,
    /// A band-limited (polyBLEP) square.
    Square,
    /// A triangle.
    Triangle,
    /// The `HARMONICS.piano` table from the browser engine.
    Piano,
    /// The `HARMONICS.organ` table from the browser engine.
    Organ,
    /// The `HARMONICS.bell` table from the browser engine.
    Bell,
    /// The `HARMONICS.strings` table from the browser engine.
    Strings,
}

impl Wave {
    /// Every shape, in the order the enum declares them. Used by the tests and
    /// handy for a UI that builds a waveform list.
    pub const ALL: [Wave; 8] = [
        Wave::Sine,
        Wave::Sawtooth,
        Wave::Square,
        Wave::Triangle,
        Wave::Piano,
        Wave::Organ,
        Wave::Bell,
        Wave::Strings,
    ];

    /// The browser's `patch.wave` string.
    pub fn name(self) -> &'static str {
        match self {
            Wave::Sine => "sine",
            Wave::Sawtooth => "sawtooth",
            Wave::Square => "square",
            Wave::Triangle => "triangle",
            Wave::Piano => "piano",
            Wave::Organ => "organ",
            Wave::Bell => "bell",
            Wave::Strings => "strings",
        }
    }

    /// Parse the browser's `patch.wave` string. Unknown names return `None`.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "sine" => Some(Wave::Sine),
            "sawtooth" => Some(Wave::Sawtooth),
            "square" => Some(Wave::Square),
            "triangle" => Some(Wave::Triangle),
            "piano" => Some(Wave::Piano),
            "organ" => Some(Wave::Organ),
            "bell" => Some(Wave::Bell),
            "strings" => Some(Wave::Strings),
            _ => None,
        }
    }
}

/// The filter response, the browser's `patch.filter.type`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FilterKind {
    /// A 12 dB/octave lowpass.
    Lowpass,
    /// A bandpass with a 0 dB peak at the cutoff.
    Bandpass,
}

impl FilterKind {
    /// The browser's `filter.type` string.
    pub fn name(self) -> &'static str {
        match self {
            FilterKind::Lowpass => "lowpass",
            FilterKind::Bandpass => "bandpass",
        }
    }

    /// Parse `filter.type`; unknown names return `None`.
    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "lowpass" => Some(FilterKind::Lowpass),
            "bandpass" => Some(FilterKind::Bandpass),
            _ => None,
        }
    }
}

/// One entry of the patch's `osc` array.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Osc {
    /// Octave offset in whole octaves, clamped to `-4..=4`. The browser does
    /// not clamp this field; the range keeps `2^octave` finite.
    pub octave: i8,
    /// Fine offset in cents, clamped to `-100..=100`. The browser does not
    /// clamp this field; the presets stay within a few cents.
    pub detune: f32,
    /// Mix level, clamped to `0..=1`. The browser does not clamp this field.
    pub level: f32,
}

/// The patch's `filter` object.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Filter {
    /// Lowpass or bandpass (the JSON field is `type`).
    pub kind: FilterKind,
    /// Cutoff in Hz, clamped to `40..=18000` (`set('filter.cutoff', …)`).
    pub cutoff: f32,
    /// Resonance, clamped to `0.0001..=30` (`set('filter.q', …)`).
    pub q: f32,
    /// Filter-envelope amount, clamped to `0..=1`. At the use site the browser
    /// scales it by six (`filterEnv`).
    pub env: f32,
    /// Keyboard tracking of the cutoff, clamped to `0..=1`. The browser does
    /// not clamp this field; the range matches every preset.
    pub keytrack: f32,
}

/// An ADSR in seconds and a sustain level, used for `amp` and `fenv`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Envelope {
    /// Attack time in seconds, clamped to `0..=10`.
    pub a: f32,
    /// Decay time in seconds, clamped to `0..=10`.
    pub d: f32,
    /// Sustain level, clamped to `0..=1`.
    pub s: f32,
    /// Release time in seconds, clamped to `0..=10`.
    pub r: f32,
}

/// The patch's `lfo` object. One shared LFO drives every voice.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Lfo {
    /// Rate in Hz, clamped to `0..=20`. Zero behaves as 5 Hz, as `applyLfo`
    /// does in the browser; it is only audible if an amount is non-zero.
    pub rate: f32,
    /// Pitch depth in octaves, clamped to `0..=1` (`1200` cents per octave).
    pub pitch: f32,
    /// Cutoff depth in Hz, clamped to `0..=2400`. The browser multiplies the
    /// patch value by 2400 before wiring it to the filter frequency.
    pub cutoff: f32,
    /// Tremolo depth, clamped to `0..=1`. Applied to the master gain as
    /// `1 + lfo * amp * 0.5`, matching `applyLfo`.
    pub amp: f32,
}

/// A complete synth patch, the shape of the browser's patch JSON.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Patch {
    /// Voice engine.
    pub engine: Engine,
    /// Oscillator shape (only read by the subtractive voice).
    pub wave: Wave,
    /// Noise-strike level, clamped to `0..=1`. The browser does not clamp it;
    /// the presets stay below 0.1.
    pub noise: f32,
    /// Maximum active voices, clamped to `1..=64` (`stealing()`).
    pub voices: u8,
    /// Semitone transpose, clamped to `-36..=36` (`set('transpose', …)`).
    pub transpose: f32,
    /// Glide time in seconds, clamped to `0..=3`. The browser only uses glide
    /// in mono mode; this synth glides every new voice (see the crate docs).
    pub glide: f32,
    /// Master drive, clamped to `0..=1` (`applyDrive`).
    pub drive: f32,
    /// Pluck damping, clamped to `0..=1`. The browser defaults it to 0.5 at
    /// the use site; the range matches that intent.
    pub damping: f32,
    /// Pluck brightness, clamped to `0..=1`. The browser defaults it to 0.5 at
    /// the use site.
    pub brightness: f32,
    /// The oscillator entries. When [`Patch::osc_count`] is 1 only `osc[0]`
    /// is rendered.
    pub osc: [Osc; 2],
    /// Length of the JSON `osc` array: 1 or 2, clamped to that range. Rust
    /// needs a fixed array, so the length travels beside it.
    pub osc_count: u8,
    /// Filter settings.
    pub filter: Filter,
    /// Amplitude ADSR.
    pub amp: Envelope,
    /// Filter ADSR used by the subtractive voice.
    pub fenv: Envelope,
    /// The shared LFO.
    pub lfo: Lfo,
}

impl Default for Patch {
    /// The browser's fallback "Grand Piano" (`01_engine.js:62`).
    fn default() -> Self {
        Patch {
            engine: Engine::Subtractive,
            wave: Wave::Piano,
            noise: 0.16,
            voices: 32,
            transpose: 0.0,
            glide: 0.0,
            drive: 0.0,
            damping: 0.5,
            brightness: 0.5,
            osc: [
                Osc { octave: 0, detune: 0.0, level: 1.0 },
                Osc { octave: 0, detune: 4.0, level: 0.5 },
            ],
            osc_count: 2,
            filter: Filter {
                kind: FilterKind::Lowpass,
                cutoff: 3800.0,
                q: 0.6,
                env: 0.25,
                keytrack: 0.35,
            },
            amp: Envelope { a: 0.004, d: 2.6, s: 0.0, r: 0.5 },
            fenv: Envelope { a: 0.002, d: 1.4, s: 0.0, r: 0.4 },
            lfo: Lfo { rate: 0.0, pitch: 0.0, cutoff: 0.0, amp: 0.0 },
        }
    }
}

impl Patch {
    /// Clamp every field into the range the browser engine accepts.
    pub fn clamp(&mut self) {
        self.noise = finite_clamp(self.noise, 0.0, 1.0);
        self.voices = self.voices.clamp(1, 64);
        self.transpose = finite_clamp(self.transpose, -36.0, 36.0);
        self.glide = finite_clamp(self.glide, 0.0, 3.0);
        self.drive = finite_clamp(self.drive, 0.0, 1.0);
        self.damping = finite_clamp(self.damping, 0.0, 1.0);
        self.brightness = finite_clamp(self.brightness, 0.0, 1.0);
        self.osc_count = self.osc_count.clamp(1, 2);

        for osc in &mut self.osc {
            osc.octave = osc.octave.clamp(-4, 4);
            osc.detune = finite_clamp(osc.detune, -100.0, 100.0);
            osc.level = finite_clamp(osc.level, 0.0, 1.0);
        }

        self.filter.cutoff = finite_clamp(self.filter.cutoff, 40.0, 18000.0);
        self.filter.q = finite_clamp(self.filter.q, 0.0001, 30.0);
        self.filter.env = finite_clamp(self.filter.env, 0.0, 1.0);
        self.filter.keytrack = finite_clamp(self.filter.keytrack, 0.0, 1.0);

        for env in [&mut self.amp, &mut self.fenv] {
            env.a = finite_clamp(env.a, 0.0, 10.0);
            env.d = finite_clamp(env.d, 0.0, 10.0);
            env.s = finite_clamp(env.s, 0.0, 1.0);
            env.r = finite_clamp(env.r, 0.0, 10.0);
        }

        self.lfo.rate = finite_clamp(self.lfo.rate, 0.0, 20.0);
        self.lfo.pitch = finite_clamp(self.lfo.pitch, 0.0, 1.0);
        self.lfo.cutoff = finite_clamp(self.lfo.cutoff, 0.0, 2400.0);
        self.lfo.amp = finite_clamp(self.lfo.amp, 0.0, 1.0);
    }

    /// Consume the patch and return it clamped. Convenience for a bridge that
    /// parses JSON into a `Patch`.
    pub fn clamped(mut self) -> Self {
        self.clamp();
        self
    }
}

/// `v.clamp(lo, hi)`, with non-finite values replaced by `lo`.
fn finite_clamp(v: f32, lo: f32, hi: f32) -> f32 {
    if v.is_finite() {
        v.clamp(lo, hi)
    } else {
        lo
    }
}
