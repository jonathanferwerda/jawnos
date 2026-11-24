//! One voice: a subtractive synth or a Karplus-Strong string.
//!
//! A voice snapshots the whole [`Patch`] when it starts, the way `newVoice()`
//! creates its own Web Audio nodes with the values current at that moment.
//! `set_patch` therefore changes the LFO and the master drive of every running
//! voice, and every parameter of the next one, but it does not rewrite a voice
//! already sounding. That is the browser's behaviour.
//!
//! The voice's sample rate never changes after construction; [`crate::Synth`]
//! owns it and passes it in.

use crate::env::{Adsr, FilterEnv};
use crate::filter::{clamp_cutoff, one_pole_delay, OnePole, Svf};
use crate::osc::Oscillator;
use crate::patch::{Engine, Patch};
use crate::rng::Rng;
use crate::synth::midi_to_hz;

/// The duration of the subtractive noise strike, in seconds
/// (`nlen = sampleRate * 0.06` in `newVoice`).
const NOISE_SECONDS: f32 = 0.06;
/// The longest period the pluck delay line accepts, in seconds. The browser
/// creates its delay with `createDelay(0.05)`, so it cannot hold a longer
/// period either.
pub(crate) const MAX_PLUCK_SECONDS: f32 = 0.05;

/// One playing (or silent, reusable) voice.
pub(crate) struct Voice {
    /// Whether the voice should be rendered at all.
    pub active: bool,
    /// The MIDI note this voice was started for.
    pub note: u8,
    /// Monotonic note-on order, for oldest-first stealing.
    pub age: u64,
    /// Whether `note_off` has begun the release.
    pub released: bool,

    /// The patch as it was when this voice started.
    patch: Patch,
    /// Amplitude envelope.
    amp: Adsr,
    /// Note-on velocity, clamped to 0..1.
    velocity: f32,

    // ---- subtractive state ----
    osc: [Oscillator; 2],
    noise_left: u32,
    noise_total: u32,
    filter: Svf,
    fenv: FilterEnv,

    // ---- glide ----
    freq: f32,
    target_freq: f32,
    glide_left: u32,
    glide_ratio: f32,

    // ---- pluck state ----
    delay: Box<[f32]>,
    write: usize,
    period: f32,
    lp: OnePole,
    lp_coef: f32,
    feedback: f32,
    rng: Rng,
}

impl Voice {
    /// An idle voice whose pluck delay line holds `delay_len` samples.
    pub fn silent(delay_len: usize) -> Self {
        Voice {
            active: false,
            note: 0,
            age: 0,
            released: true,
            patch: Patch::default(),
            amp: Adsr::new(),
            velocity: 0.0,
            osc: [Oscillator::new(), Oscillator::new()],
            noise_left: 0,
            noise_total: 1,
            filter: Svf::new(),
            fenv: FilterEnv::new(),
            freq: 440.0,
            target_freq: 440.0,
            glide_left: 0,
            glide_ratio: 1.0,
            delay: vec![0.0; delay_len].into_boxed_slice(),
            write: 0,
            period: 100.0,
            lp: OnePole::new(),
            lp_coef: 0.5,
            feedback: 0.5,
            rng: Rng::new(1),
        }
    }

    /// The capacity of this voice's pluck delay line.
    pub fn delay_len(&self) -> usize {
        self.delay.len()
    }

    /// Start a note. `from_freq` is the previous note's frequency, used only by
    /// a subtractive voice when the patch has a glide time.
    pub fn trigger(
        &mut self,
        note: u8,
        velocity: f32,
        patch: Patch,
        rate: f32,
        age: u64,
        from_freq: f32,
        seed: u64,
    ) {
        self.active = true;
        self.released = false;
        self.note = note;
        self.age = age;
        self.velocity = velocity;
        self.patch = patch;
        self.rng = Rng::new(seed);
        self.osc[0].reset();
        self.osc[1].reset();
        self.filter.reset();
        self.fenv.reset();
        self.noise_left = 0;

        let target = midi_to_hz(note as f32 + patch.transpose);
        self.target_freq = target;

        let peak = match patch.engine {
            Engine::Pluck => 0.5 + velocity * 0.5,
            Engine::Subtractive => 0.25 + velocity * 0.6,
        };
        self.amp.trigger(&patch.amp, peak, rate);

        if patch.engine == Engine::Subtractive && patch.glide > 0.0 && from_freq > 0.0 {
            let start = from_freq.max(1.0);
            self.freq = start;
            let steps = (patch.glide * rate).max(1.0) as u32;
            self.glide_ratio = (target / start).powf(1.0 / steps as f32);
            self.glide_left = steps;
        } else {
            self.freq = target;
            self.glide_left = 0;
            self.glide_ratio = 1.0;
        }

        match patch.engine {
            Engine::Subtractive => {
                if patch.noise > 0.0 {
                    self.noise_total = (rate * NOISE_SECONDS).max(1.0) as u32;
                    self.noise_left = self.noise_total;
                }
                self.start_filter_env(target, rate);
            }
            Engine::Pluck => self.start_pluck(target, rate),
        }
    }

    /// Start the release, from the amp envelope's current level.
    pub fn release(&mut self, rate: f32) {
        if !self.active || self.released {
            return;
        }
        self.released = true;
        self.amp.release(&self.patch.amp, rate);
    }

    /// Silence the voice at once, as immediate voice stealing does.
    pub fn kill(&mut self) {
        self.active = false;
        self.released = true;
        self.amp.hard_stop();
        self.noise_left = 0;
        self.glide_left = 0;
    }

    /// Render one sample. `lfo` is the shared LFO's current value in `-1..1`.
    pub fn render(&mut self, lfo: f32, rate: f32) -> f32 {
        if !self.active {
            return 0.0;
        }
        let out = match self.patch.engine {
            Engine::Subtractive => self.render_subtractive(lfo, rate),
            Engine::Pluck => self.render_pluck(),
        };
        let level = self.amp.next();
        if self.amp.is_idle() {
            self.active = false;
        }
        out * level
    }

    fn render_subtractive(&mut self, lfo: f32, rate: f32) -> f32 {
        if self.glide_left > 0 {
            self.freq *= self.glide_ratio;
            self.glide_left -= 1;
            if self.glide_left == 0 {
                self.freq = self.target_freq;
            }
        }

        // The browser's lfoPitch gain is `pitch * 1200` cents, so one patch
        // unit is one octave.
        let base = self.freq * 2f32.powf(lfo * self.patch.lfo.pitch);
        let count = (self.patch.osc_count as usize).clamp(1, 2);
        let scale = 1.0 / count as f32;
        let mut mix = 0.0;
        for (index, osc) in self.patch.osc.iter().take(count).enumerate() {
            let octave = 2f32.powf(osc.octave as f32);
            let detune = 2f32.powf(osc.detune / 1200.0);
            let value = self.osc[index].next(self.patch.wave, base * octave * detune, rate);
            mix += value * osc.level * scale;
        }
        // `mix.gain.value = 0.5` in newVoice().
        mix *= 0.5;

        if self.noise_left > 0 {
            let fade = self.noise_left as f32 / self.noise_total as f32;
            mix += self.rng.next_bipolar() * fade * fade * self.patch.noise;
            self.noise_left -= 1;
        }

        // lfoCutoff is connected straight to the filter frequency, so its
        // patch value is already Hz.
        let cutoff = self.fenv.next() + lfo * self.patch.lfo.cutoff;
        self.filter.process(
            mix,
            cutoff,
            self.patch.filter.q,
            rate,
            self.patch.filter.kind,
        )
    }

    fn render_pluck(&mut self) -> f32 {
        let out = self.read_delay();
        let filtered = self.lp.process(out, self.lp_coef);
        self.write_delay(filtered * self.feedback);
        out
    }

    /// The `filterEnv()` math: a velocity-scaled, keytracked cutoff, an
    /// envelope peak at `cutoff * (1 + env * 6)`, and a sustain target of
    /// `cutoff * (0.2 + s * 0.8)`.
    fn start_filter_env(&mut self, freq: f32, rate: f32) {
        let filter = self.patch.filter;
        let key = 1.0 + filter.keytrack * (freq / 261.63 - 1.0);
        let base = clamp_cutoff(filter.cutoff * (0.6 + 0.7 * self.velocity) * key, rate);
        let peak = clamp_cutoff(base * (1.0 + filter.env * 6.0), rate);
        let sustain = clamp_cutoff(base * (0.2 + self.patch.fenv.s * 0.8), rate);
        self.fenv.trigger(
            peak,
            sustain,
            self.patch.fenv.a,
            self.patch.fenv.d,
            rate,
        );
    }

    /// Build a Karplus-Strong string: a noise-filled delay line, a one-pole in
    /// the feedback path, and a delay length corrected for the filter's phase
    /// delay. Mirrors the `engine === 'pluck'` branch of `newVoice()`.
    fn start_pluck(&mut self, freq: f32, rate: f32) {
        let len = self.delay.len();
        if len == 0 {
            // prepare() has not sized the delay lines; never panic in a note.
            self.active = false;
            return;
        }

        let frequency = freq.max(1.0);
        let filter_hz = (frequency
            * (2.0 + self.patch.brightness * 12.0)
            * (0.6 + 0.8 * self.velocity))
            .min(18000.0);
        let coefficient = OnePole::coefficient(filter_hz, rate);
        let period = rate / frequency;
        let max_period = len as f32 - 2.0;
        let delay = (period - one_pole_delay(coefficient)).clamp(1.5, max_period);
        self.period = delay;
        self.lp.reset();
        self.lp_coef = coefficient;
        self.feedback = (0.8 + self.patch.damping * 0.199).min(0.999);

        for sample in self.delay.iter_mut() {
            *sample = 0.0;
        }
        let strike = (period.round() as usize).min(len);
        for sample in self.delay.iter_mut().take(strike) {
            *sample = self.rng.next_bipolar();
        }
        self.write = strike % len;
    }

    fn read_delay(&self) -> f32 {
        let len = self.delay.len();
        if len == 0 {
            return 0.0;
        }
        let len_f = len as f32;
        let mut position = self.write as f32 - self.period;
        if position < 0.0 {
            position += len_f;
        }
        if position >= len_f {
            position -= len_f;
        }
        let floor = position.floor();
        let first = (floor as usize) % len;
        let second = (first + 1) % len;
        let fraction = position - floor;
        self.delay[first] * (1.0 - fraction) + self.delay[second] * fraction
    }

    fn write_delay(&mut self, value: f32) {
        let len = self.delay.len();
        if len == 0 {
            return;
        }
        self.delay[self.write] = value;
        self.write += 1;
        if self.write >= len {
            self.write = 0;
        }
    }
}
