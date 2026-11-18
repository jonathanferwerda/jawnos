//! The `reverb` pedal: five generated tails, convolved without adding latency.
//!
//! `studioInsert(ctx, 'reverb2')` is a `ConvolverNode` over
//! `studioImpulse(ctx, 2.4, 2.6)` — 2.4 s of uniform noise under a
//! `(1 - i/length)^2.6` envelope — mixed with the dry signal
//! (`wet = mix/100 * 0.9`, `dry = 1 - mix/100 * 0.4`). That impulse *is* the
//! sound; a Freeverb or a Schroeder network would be a different reverb, so
//! this is honest convolution, only arranged so the engine's own fixed block
//! does not become a block of delay.
//!
//! The contract adds five models: Room (0.8 s), Spring (1.8 s), Plate (2.2 s),
//! Hall (3.4 s) and Cave (6.0 s). Each is the same generated noise reshaped — a
//! decay, a low/high cut and, for Spring, a pair of combs that give it the
//! metallic ring — which keeps them the same kind of sound as the web's
//! generated impulse rather than importing sampled rooms. The numbers are in
//! [`MODEL_SECONDS`] and the names in [`MODEL_NAMES`]; the order is shared with
//! the browser.
//!
//! Every model's impulse and its partition spectra are built in `prepare`, so
//! `set("model", ...)` only swaps an index at the next 1024-sample boundary:
//! no allocation and no FFT work on the audio thread. The bank costs about
//! 18 MB at 48 kHz (the six-second Cave alone is 4.6 MB of spectra), against
//! 4.2 MB for the old single tail. That memory is the price of a model switch
//! that cannot glitch, and it is paid once per prepared reverb.
//!
//! # Why there is no latency
//!
//! A uniform partitioned convolver normally pays one partition of latency: it
//! needs a whole input block before the FFT of that block can contribute. This
//! one splits the impulse at the first partition boundary instead.
//!
//! * Partition 0 (the first 1024 taps) is convolved **directly in the time
//!   domain**, sample by sample, as the input arrives. Sample `n` therefore
//!   already carries every one of its first-partition taps.
//! * Partitions 1..N use 2048-point FFTs, overlap-save: the window is the two
//!   most recent input blocks, the filter is the zero-padded partition, and the
//!   valid last 1024 samples of the circular convolution are added into the
//!   output block. Partition `k`'s output starts at `k * 1024` samples, so by
//!   the time output block `m` begins, every input block it reads (`m-k-1` and
//!   `m-k`) is already in the past. The spectra of those two-block windows are
//!   held in a ring of the last `N-1` of them — a frequency-domain delay line —
//!   and inverse-transformed before block `m`'s first sample is written.
//!
//! Consequently output sample `n` is a function of input samples `<= n` only,
//! and the result does not depend on how the host chops `process` calls: the
//! FFT path only ever turns on the engine's own 1024-sample boundaries, which
//! are a property of the sample count, not of the call sizes.
//!
//! # Cost
//!
//! At 48 kHz the generated impulse is 115 200 samples (2.4 s), so there are 113
//! partitions: 112 complex multiply-accumulates of 2048 bins per 1024 output
//! samples, plus one forward and one inverse FFT. The head is 1024 multiply-adds
//! **per sample** — the price of zero latency at this partition size — and the
//! frequency-domain half is about 100 MFLOP/s per channel here. Measured in
//! release: roughly 60-75 ms of CPU per second of audio (a two-second chunked run
//! and a ten-second full-scale run, both single channel), about 6-8% of one core
//! at 48 kHz.
//!
//! Memory is the impulse spectra plus the input-window ring,
//! `(2 * partitions - 1) * 2048` complex f32 ≈ 3.7 MB at 48 kHz, about 4.2 MB
//! with the impulse and the FFT scratch.
//!
//! # What it matches, and what it does not
//!
//! The generator is `studioImpulse`'s expression verbatim, with a fixed xorshift
//! seed instead of `Math.random`, and mono instead of the web's two independent
//! channels (the engine's strip is one input). The WebAudio `ConvolverNode`
//! normalizes its buffer by default (`normalize = true`), so the effective
//! impulse the page plays is the generated one times the spec's equal-power
//! scale; [`Reverb::impulse`] returns that effective impulse. The samples are
//! therefore the same shape and level as the browser's, not the same bytes.

use crate::effect::Effect;

/// The name the take report and the chain order use.
pub const NAME: &str = "reverb";

/// The five models, in the order both implementations must agree on.
pub const MODEL_NAMES: [&str; 5] = ["Room", "Spring", "Plate", "Hall", "Cave"];

/// Each model's tail length in seconds, from `docs/studio-effects.md`.
pub const MODEL_SECONDS: [f32; 5] = [0.8, 1.8, 2.2, 3.4, 6.0];

/// Plate: the closest model to the old 2.4 s diffuse impulse, so an old song
/// loads with the character it had rather than a much shorter room.
pub const DEFAULT_MODEL: usize = 2;

const MODEL_COUNT: usize = MODEL_NAMES.len();

/// The envelope's exponent per model. A larger value decays faster: Room is
/// short and tight, Cave is long enough that its low-mid energy needs a gentler
/// slope to stay audible beneath the length.
const MODEL_DECAY: [f32; MODEL_COUNT] = [3.4, 2.2, 2.6, 2.4, 2.9];

/// The reference shape the web generator was written for; the model table
/// reuses the same generator with its own length and decay.
pub const SECONDS: f32 = 2.4;

/// The exponential decay applied across the reference impulse.
pub const DECAY: f32 = 2.6;

/// The partition length in samples: 21.3 ms at 48 kHz, and the FFT's size is
/// twice this. The head is one partition long because it is convolved in the
/// time domain.
pub const PARTITION: usize = 1024;

/// The web's `setters['mix'](35)` default, as a normalised 0..1 knob.
pub const MIX_DEFAULT: f32 = 0.35;

/// The web's `volume` default, as a normalised 0..1 knob. In the page the volume
/// setter writes the same wet gain node the mix setter writes, so 35 is also the
/// wet gain the default mix leaves behind.
pub const VOLUME_DEFAULT: f32 = 0.35;

/// `rwet.gain = (v / 100) * 0.9`.
const WET_SCALE: f32 = 0.9;

/// `rdry.gain = 1 - (v / 100) * 0.4`.
const DRY_SCALE: f32 = 0.4;

/// How long a knob takes to travel most of the way to a new value.
const SMOOTH_SECONDS: f32 = 0.02;

/// The fixed seed the impulse is generated from, so a take and a test meet the
/// same noise. Any non-zero value would sound the same; this one is only a name
/// for "the house's reverb".
const RNG_SEED: u32 = 0x2545_f491;

/// Twice [`PARTITION`]: the FFT covers one previous block and the current one.
const FFT_LEN: usize = 2 * PARTITION;

/// A complex f32, the only arithmetic type the FFT and the spectra need.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct Cpx {
    re: f32,
    im: f32,
}

impl Cpx {
    const ZERO: Cpx = Cpx { re: 0.0, im: 0.0 };

    #[inline]
    fn mul(self, other: Cpx) -> Cpx {
        Cpx {
            re: self.re * other.re - self.im * other.im,
            im: self.re * other.im + self.im * other.re,
        }
    }

    #[inline]
    fn add(self, other: Cpx) -> Cpx {
        Cpx {
            re: self.re + other.re,
            im: self.im + other.im,
        }
    }

    #[inline]
    fn sub(self, other: Cpx) -> Cpx {
        Cpx {
            re: self.re - other.re,
            im: self.im - other.im,
        }
    }
}

/// A radix-2, in-place, decimation-in-time FFT of one fixed power-of-two size.
///
/// The bit-reversal permutation and the twiddles are built once in
/// [`prepare`](Effect::prepare); [`run`](Fft::run) only reads them, so the audio
/// path allocates nothing. The inverse is the same transform with conjugated
/// twiddles, scaled by `1/n`; there is no second table because a 2048-point
/// spectrum is small enough that one pass over `n/2` twiddles is free.
struct Fft {
    len: usize,
    twiddle: Vec<Cpx>,
    bitrev: Vec<u32>,
}

impl Fft {
    /// `len` must be a power of two and at least 2.
    fn new(len: usize) -> Self {
        let bits = len.trailing_zeros();
        let mut bitrev = vec![0u32; len];
        for (index, slot) in bitrev.iter_mut().enumerate() {
            let mut source = index as u32;
            let mut reversed = 0u32;
            for _ in 0..bits {
                reversed = (reversed << 1) | (source & 1);
                source >>= 1;
            }
            *slot = reversed;
        }
        let half = len / 2;
        let twiddle = (0..half)
            .map(|k| {
                let angle = -2.0 * std::f64::consts::PI * k as f64 / len as f64;
                Cpx {
                    re: angle.cos() as f32,
                    im: angle.sin() as f32,
                }
            })
            .collect();
        Fft {
            len,
            twiddle,
            bitrev,
        }
    }

    /// Transform `buf[..len]` in place. A short buffer is left alone rather than
    /// indexed, because the audio thread must not panic.
    fn run(&self, buf: &mut [Cpx], inverse: bool) {
        let n = self.len;
        if n < 2 || buf.len() < n {
            return;
        }
        for index in 0..n {
            let mirror = self.bitrev[index] as usize;
            if mirror > index {
                buf.swap(index, mirror);
            }
        }

        let mut span = 2;
        while span <= n {
            let half = span / 2;
            let stride = n / span;
            let mut base = 0;
            while base < n {
                for k in 0..half {
                    let w = self.twiddle[k * stride];
                    let w = if inverse {
                        Cpx {
                            re: w.re,
                            im: -w.im,
                        }
                    } else {
                        w
                    };
                    let u = buf[base + k];
                    let v = buf[base + k + half].mul(w);
                    buf[base + k] = u.add(v);
                    buf[base + k + half] = u.sub(v);
                }
                base += span;
            }
            span <<= 1;
        }

        if inverse {
            let scale = 1.0 / n as f32;
            for value in buf[..n].iter_mut() {
                value.re *= scale;
                value.im *= scale;
            }
        }
    }
}

/// A 32-bit xorshift, so the impulse is the same noise on every machine and in
/// every run. `Math.random` cannot be reproduced, and a test that cannot be
/// reproduced proves nothing.
struct XorShift32 {
    state: u32,
}

impl XorShift32 {
    fn new(seed: u32) -> Self {
        XorShift32 {
            state: if seed == 0 { 0x9e37_79b9 } else { seed },
        }
    }

    fn next_u32(&mut self) -> u32 {
        let mut value = self.state;
        value ^= value << 13;
        value ^= value >> 17;
        value ^= value << 5;
        self.state = value;
        value
    }

    /// Uniform in `[-1, 1)`, the range of `Math.random() * 2 - 1`.
    fn bipolar(&mut self) -> f64 {
        (f64::from(self.next_u32()) / 4_294_967_296.0) * 2.0 - 1.0
    }
}

/// `studioImpulse(rate, seconds, decay)` as written in `studio.js`, for one
/// channel: uniform noise times `(1 - i/length)^decay`.
fn studio_impulse(rate: u32, seconds: f32, decay: f32) -> Vec<f32> {
    // Round rather than floor: 1.8 as an f32 is a hair under 1.8, and the
    // contract's model lengths are written as whole sample counts at 48 kHz.
    let length = ((f64::from(rate) * f64::from(seconds)).round() as usize).max(1);
    let mut rng = XorShift32::new(RNG_SEED);
    let mut impulse = Vec::with_capacity(length);
    for index in 0..length {
        let across = index as f64 / length as f64;
        let envelope = (1.0 - across).powf(f64::from(decay));
        impulse.push((rng.bipolar() * envelope) as f32);
    }
    impulse
}

/// The scale WebAudio's `ConvolverNode` applies when `normalize` is left at its
/// default `true`, from the spec's normalization algorithm: the equal-power
/// (RMS) scale, calibrated to 0.00125 at 44.1 kHz, with a floor so a nearly
/// silent buffer cannot be amplified into noise.
fn normalization_scale(impulse: &[f32], rate: u32) -> f32 {
    const GAIN_CALIBRATION: f32 = 0.00125;
    const GAIN_CALIBRATION_RATE: f32 = 44_100.0;
    const MIN_POWER: f32 = 0.000125;

    let length = impulse.len().max(1);
    let energy: f64 = impulse
        .iter()
        .map(|sample| f64::from(*sample) * f64::from(*sample))
        .sum();
    let mut power = (energy / length as f64).sqrt() as f32;
    if !power.is_finite() || power < MIN_POWER {
        power = MIN_POWER;
    }
    let mut scale = 1.0 / power;
    scale *= GAIN_CALIBRATION;
    scale * (rate.max(1) as f32 / GAIN_CALIBRATION_RATE)
}

/// A one-pole lowpass coefficient for shaping a generated impulse at setup
/// time. These filters run once per model in `prepare`, never per block.
fn shape_coefficient(rate: f64, hz: f64) -> f64 {
    let rate = rate.max(1.0);
    1.0 - (-std::f64::consts::TAU * hz.clamp(10.0, rate * 0.45) / rate).exp()
}

fn lowpass_shape(impulse: &mut [f32], rate: f64, hz: f64) {
    let coefficient = shape_coefficient(rate, hz);
    let mut state = 0.0f64;
    for sample in impulse {
        let value = f64::from(*sample);
        state += coefficient * (value - state);
        *sample = state as f32;
    }
}

fn highpass_shape(impulse: &mut [f32], rate: f64, hz: f64) {
    let coefficient = shape_coefficient(rate, hz);
    let mut state = 0.0f64;
    for sample in impulse {
        let value = f64::from(*sample);
        state += coefficient * (value - state);
        *sample = (value - state) as f32;
    }
}

/// Add a scaled low band, up to `+6 dB` at DC when `gain` is 1.
fn low_boost_shape(impulse: &mut [f32], rate: f64, hz: f64, gain: f64) {
    let coefficient = shape_coefficient(rate, hz);
    let mut state = 0.0f64;
    for sample in impulse {
        let value = f64::from(*sample);
        state += coefficient * (value - state);
        *sample = (value + gain * state) as f32;
    }
}

/// Add a scaled high band, a bright shelf with no low-end change.
fn high_boost_shape(impulse: &mut [f32], rate: f64, hz: f64, gain: f64) {
    let coefficient = shape_coefficient(rate, hz);
    let mut state = 0.0f64;
    for sample in impulse {
        let value = f64::from(*sample);
        state += coefficient * (value - state);
        *sample = (value + gain * (value - state)) as f32;
    }
}

/// A feed-forward comb: the delayed copy gives the tail a metallic ring. The
/// gain stays below one, so the shape cannot run away.
fn comb_shape(impulse: &mut [f32], delay: usize, gain: f32) {
    if delay == 0 || delay >= impulse.len() {
        return;
    }
    for index in delay..impulse.len() {
        impulse[index] += gain * impulse[index - delay];
    }
}

/// A handful of discrete early reflections, which is what makes a small room
/// sound like a room rather than a short plate.
fn early_reflections(impulse: &mut [f32], rate: f64, taps: &[(f32, f32)]) {
    for &(seconds, gain) in taps {
        let delay = (rate * f64::from(seconds)) as usize;
        if delay == 0 || delay >= impulse.len() {
            continue;
        }
        for index in delay..impulse.len() {
            impulse[index] += gain * impulse[index - delay];
        }
    }
}

/// The generated impulse for one model, before the convolver's normalization.
///
/// The base is the same `studioImpulse` noise as the browser, then one of five
/// shapes: Room is cut low and given early reflections; Spring is narrowed to a
/// bright band and run through two combs; Plate is dense and bright with no
/// pre-delay; Hall has a dark 4.5 kHz top; Cave is darker still and low-mid
/// heavy. None of these shapes adds a pre-delay, so a note's reverb starts with
/// the note.
fn model_impulse(rate: u32, model: usize) -> Vec<f32> {
    let model = model.min(MODEL_COUNT - 1);
    let rate_hz = rate.max(1);
    let rate = f64::from(rate_hz);
    let mut impulse = studio_impulse(rate_hz, MODEL_SECONDS[model], MODEL_DECAY[model]);
    match model {
        0 => {
            highpass_shape(&mut impulse, rate, 200.0);
            early_reflections(
                &mut impulse,
                rate,
                &[(0.003, 0.8), (0.007, -0.55), (0.013, 0.4), (0.023, -0.3)],
            );
        }
        1 => {
            highpass_shape(&mut impulse, rate, 400.0);
            lowpass_shape(&mut impulse, rate, 6_000.0);
            high_boost_shape(&mut impulse, rate, 2_000.0, 0.5);
            comb_shape(&mut impulse, (rate * 0.0037) as usize, 0.65);
            comb_shape(&mut impulse, (rate * 0.0059) as usize, 0.45);
        }
        2 => {
            highpass_shape(&mut impulse, rate, 120.0);
            high_boost_shape(&mut impulse, rate, 1_500.0, 0.35);
        }
        3 => {
            highpass_shape(&mut impulse, rate, 90.0);
            lowpass_shape(&mut impulse, rate, 4_500.0);
        }
        _ => {
            highpass_shape(&mut impulse, rate, 60.0);
            lowpass_shape(&mut impulse, rate, 2_500.0);
            low_boost_shape(&mut impulse, rate, 150.0, 0.8);
        }
    }
    impulse
}

/// The fraction of the remaining distance a one-pole covers across one block.
fn one_pole_block(seconds: f32, rate: u32, frames: usize) -> f64 {
    if seconds <= 0.0 || rate == 0 || frames == 0 {
        return 1.0;
    }
    1.0 - (-(frames as f64) / (f64::from(seconds) * f64::from(rate))).exp()
}

/// Studio's `reverb2`: the generated 2.4 s impulse, convolved with no added
/// latency, mixed wet/dry with the same gains as the page.
///
/// Build it with [`Reverb::new`] and then [`prepare`](Effect::prepare) it at the
/// device rate. From then on [`process`](Effect::process) allocates nothing,
/// takes no lock and cannot panic; the knobs move through [`set_mix`](Reverb::set_mix)
/// and [`set_volume`](Reverb::set_volume) and are smoothed once per 1024-sample
/// block, so a moved knob cannot click and the output does not depend on how the
/// host chops its calls.
pub struct Reverb {
    /// Every model's effective impulse, so `impulse()` answers for the model
    /// that is actually convolving. About 2.7 MB of the bank at 48 kHz.
    impulses: Vec<Vec<f32>>,
    /// Each model's first partition, reversed, contiguous:
    /// `model * PARTITION .. (model + 1) * PARTITION`.
    heads: Vec<f32>,
    /// All models' spectra, packed: `spectra_at[model] + partition * FFT_LEN`.
    spectra: Vec<Cpx>,
    spectra_at: [usize; MODEL_COUNT],
    partition_counts: [usize; MODEL_COUNT],
    /// The frequency-domain delay line: the last `ring_len` two-block input
    /// windows, indexed by `block % ring_len`. The ring is model-independent
    /// because it holds input, not tail.
    windows: Vec<Cpx>,
    /// `[previous block | current block]` — the direct head's window and the
    /// next forward FFT's input.
    buf: Vec<f32>,
    /// Complex accumulator for the next block's spectrum.
    acc: Vec<Cpx>,
    /// Forward FFT workspace and the inverse's output.
    scratch: Vec<Cpx>,
    /// The next block's time-domain contribution from partitions 1..N.
    out_part: Vec<f32>,
    fft: Fft,
    partitions: usize,
    ring_len: usize,
    model: usize,
    target_model: usize,
    /// Position inside the current 1024-sample block.
    phase: usize,
    /// How many input blocks have been completed; indexes the window ring.
    finished_blocks: usize,
    prepared: bool,

    mix: f32,
    volume: f32,
    target_wet: f32,
    target_dry: f32,
    wet: f32,
    dry: f32,
    smooth: f32,
}

impl Reverb {
    /// The web defaults: `mix` at 35 and `volume` at 35, which the page reaches
    /// through `setters['mix'](35)`, and the Plate model.
    pub fn new() -> Self {
        let wet = MIX_DEFAULT * WET_SCALE;
        let dry = 1.0 - MIX_DEFAULT * DRY_SCALE;
        Reverb {
            impulses: Vec::new(),
            heads: Vec::new(),
            spectra: Vec::new(),
            spectra_at: [0; MODEL_COUNT],
            partition_counts: [2; MODEL_COUNT],
            windows: Vec::new(),
            buf: Vec::new(),
            acc: Vec::new(),
            scratch: Vec::new(),
            out_part: Vec::new(),
            fft: Fft::new(FFT_LEN),
            partitions: 0,
            ring_len: 0,
            model: DEFAULT_MODEL,
            target_model: DEFAULT_MODEL,
            phase: 0,
            finished_blocks: 0,
            prepared: false,
            mix: MIX_DEFAULT,
            volume: VOLUME_DEFAULT,
            target_wet: wet,
            target_dry: dry,
            wet,
            dry,
            smooth: 1.0,
        }
    }

    /// Select a model, quantised from the slider. The switch happens at the
    /// next 1024-sample boundary, so the bank is pre-built and this method only
    /// writes a target: it allocates nothing and does no FFT work.
    pub fn set_model(&mut self, value: f32) {
        if !value.is_finite() {
            return;
        }
        self.target_model = (value.round() as i32).clamp(0, MODEL_COUNT as i32 - 1) as usize;
    }

    /// The model whose tail is convolving now.
    pub fn model(&self) -> usize {
        self.model
    }

    /// The name of the current model, for a take report or a test.
    pub fn model_name(&self) -> &'static str {
        MODEL_NAMES[self.model.min(MODEL_COUNT - 1)]
    }

    /// Set the wet/dry mix, a normalised 0..1 version of the page's 0..100 knob:
    /// `mix` sets both legs, exactly as `setters['mix']` does
    /// (`wet = mix * 0.9`, `dry = 1 - mix * 0.4`). A non-finite value is ignored
    /// rather than turned into a NaN in the wet path.
    pub fn set_mix(&mut self, value: f32) {
        if !value.is_finite() {
            return;
        }
        self.mix = value.clamp(0.0, 1.0);
        self.target_wet = self.mix * WET_SCALE;
        self.target_dry = 1.0 - self.mix * DRY_SCALE;
    }

    /// Trim the wet signal, the page's `volume` knob normalised to 0..1.
    ///
    /// In `studio.js` the volume setter writes `rwet.gain` — the same node the
    /// mix setter writes — so this is the wet gain alone and does not move the
    /// dry leg. When both knobs are moved, the last call wins for the wet gain,
    /// which is also the page's behaviour.
    pub fn set_volume(&mut self, value: f32) {
        if !value.is_finite() {
            return;
        }
        self.volume = value.clamp(0.0, 1.0);
        self.target_wet = self.volume * WET_SCALE;
    }

    /// The impulse the wet path actually convolves with: `studioImpulse`'s noise
    /// and decay, the model's shaping and the convolver's normalization. Empty
    /// before `prepare`.
    pub fn impulse(&self) -> &[f32] {
        self.impulses
            .get(self.model)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    /// The wet gain the knobs currently ask for, before block smoothing.
    pub fn wet_gain(&self) -> f32 {
        self.target_wet
    }

    /// The dry gain the mix knob currently asks for, before block smoothing.
    pub fn dry_gain(&self) -> f32 {
        self.target_dry
    }

    /// Swap in the target model at the block edge. The input history in
    /// `windows` is model-independent, so the new tail takes over the same
    /// performance; only the block already assembled with the old model's
    /// spectra is dropped. A 21 ms seam is preferable to keeping every model's
    /// running state alive at once.
    fn sync_model(&mut self) {
        if !self.prepared || self.target_model == self.model {
            return;
        }
        self.model = self.target_model;
        self.partitions = self.partition_counts[self.model];
        self.acc.fill(Cpx::ZERO);
        self.out_part.fill(0.0);
    }

    /// Move the smoothed gains one block toward their targets. Called at the
    /// engine's own block boundary, not the host's call boundary, so a chunked
    /// stream and one long call see the same knob trajectory.
    fn move_gains(&mut self) {
        self.wet += (self.target_wet - self.wet) * self.smooth;
        self.dry += (self.target_dry - self.dry) * self.smooth;
    }

    /// Finish input block `m`: store its input window, then assemble the
    /// partitions' contribution to block `m + 1` in one inverse FFT.
    ///
    /// `buf` is `[block m-1 | block m]`, which is exactly the window partition
    /// `k` needs when the window ends at block `m - k`: the last `PARTITION`
    /// samples of a circular convolution with the zero-padded partition are the
    /// linear convolution's contribution to that later block.
    fn finish_block(&mut self) {
        let n = FFT_LEN;
        let p = PARTITION;
        if self.buf.len() < 2 * p
            || self.scratch.len() < n
            || self.acc.len() < n
            || self.out_part.len() < p
            || self.ring_len == 0
        {
            return;
        }

        let finished = self.finished_blocks;
        for index in 0..n {
            self.scratch[index] = Cpx {
                re: self.buf[index],
                im: 0.0,
            };
        }
        self.fft.run(&mut self.scratch, false);

        let ring_len = self.ring_len;
        let slot = finished % ring_len;
        self.windows[slot * n..(slot + 1) * n].copy_from_slice(&self.scratch[..n]);

        for value in self.acc.iter_mut() {
            *value = Cpx::ZERO;
        }
        let next = finished + 1;
        let spectra_at = self.spectra_at[self.model];
        for partition in 1..self.partitions {
            // Partition `k` multiplies the window ending at block `next - k`.
            let window_slot = (next + ring_len - (partition % ring_len)) % ring_len;
            let base = spectra_at + partition * n;
            let h = &self.spectra[base..base + n];
            let w = &self.windows[window_slot * n..(window_slot + 1) * n];
            let acc = &mut self.acc[..n];
            for index in 0..n {
                let sum = acc[index];
                let product = h[index].mul(w[index]);
                acc[index] = sum.add(product);
            }
        }
        self.fft.run(&mut self.acc, true);
        for index in 0..p {
            self.out_part[index] = self.acc[p + index].re;
        }

        // Block `m` becomes the previous block for the next window.
        self.buf.copy_within(p..2 * p, 0);
        for value in &mut self.buf[p..2 * p] {
            *value = 0.0;
        }
        self.finished_blocks = next;
    }
}

impl Default for Reverb {
    fn default() -> Self {
        Reverb::new()
    }
}

impl Effect for Reverb {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        let rate = rate.max(1);
        self.fft = Fft::new(FFT_LEN);

        // Build every model here, on the setup thread, where an allocation and
        // a few hundred FFTs are allowed. `set("model", ...)` then swaps an
        // index at a block boundary: no allocation and no impulse generation on
        // the audio thread.
        let mut impulses: Vec<Vec<f32>> = Vec::with_capacity(MODEL_COUNT);
        let mut partition_counts = [2usize; MODEL_COUNT];
        let mut total_partitions = 0usize;
        for model in 0..MODEL_COUNT {
            let mut impulse = model_impulse(rate, model);
            let scale = normalization_scale(&impulse, rate);
            for sample in &mut impulse {
                *sample *= scale;
            }
            partition_counts[model] = ((impulse.len() + PARTITION - 1) / PARTITION).max(2);
            total_partitions += partition_counts[model];
            impulses.push(impulse);
        }

        let mut spectra = vec![Cpx::ZERO; total_partitions * FFT_LEN];
        let mut heads = vec![0.0; MODEL_COUNT * PARTITION];
        let mut spectra_at = [0usize; MODEL_COUNT];
        let mut work = vec![Cpx::ZERO; FFT_LEN];
        let mut offset = 0usize;
        for model in 0..MODEL_COUNT {
            spectra_at[model] = offset;
            let impulse = &impulses[model];
            for (index, sample) in impulse.iter().take(PARTITION).enumerate() {
                heads[model * PARTITION + PARTITION - 1 - index] = *sample;
            }
            for partition in 1..partition_counts[model] {
                work.fill(Cpx::ZERO);
                let start = partition * PARTITION;
                let end = (start + PARTITION).min(impulse.len());
                for index in start..end {
                    work[index - start].re = impulse[index];
                }
                self.fft.run(&mut work, false);
                let base = offset + partition * FFT_LEN;
                spectra[base..base + FFT_LEN].copy_from_slice(&work);
            }
            offset += partition_counts[model] * FFT_LEN;
        }

        self.impulses = impulses;
        self.heads = heads;
        self.spectra = spectra;
        self.spectra_at = spectra_at;
        self.partition_counts = partition_counts;
        // The ring holds input windows, not tails, so one ring sized for the
        // longest model serves every model. It is still indexed by `ring_len`
        // below, which keeps the wrap arithmetic valid for a shorter model.
        self.ring_len = partition_counts.iter().copied().max().unwrap_or(2) - 1;
        self.windows = vec![Cpx::ZERO; self.ring_len * FFT_LEN];
        self.acc = vec![Cpx::ZERO; FFT_LEN];
        self.scratch = vec![Cpx::ZERO; FFT_LEN];
        self.buf = vec![0.0; 2 * PARTITION];
        self.out_part = vec![0.0; PARTITION];

        self.model = self.target_model.min(MODEL_COUNT - 1);
        self.partitions = self.partition_counts[self.model];
        self.smooth = one_pole_block(SMOOTH_SECONDS, rate, PARTITION) as f32;
        self.prepared = true;
        self.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared
            || self.buf.len() < 2 * PARTITION
            || self.out_part.len() < PARTITION
            || self.heads.len() < MODEL_COUNT * PARTITION
        {
            return;
        }

        for sample in block.iter_mut() {
            if self.phase == 0 {
                self.sync_model();
                self.move_gains();
            }

            let input = *sample;
            self.buf[PARTITION + self.phase] = input;

            // Partition 0, in the time domain: every tap up to and including the
            // current sample, which is why no block of latency is added.
            let head = self.model * PARTITION;
            let start = self.phase + 1;
            let mut direct = 0.0f32;
            for tap in 0..PARTITION {
                direct += self.heads[head + tap] * self.buf[start + tap];
            }

            let wet_part = direct + self.out_part[self.phase];
            *sample = input * self.dry + wet_part * self.wet;

            self.phase += 1;
            if self.phase == PARTITION {
                self.phase = 0;
                self.finish_block();
            }
        }
    }

    fn reset(&mut self) {
        self.buf.fill(0.0);
        self.windows.fill(Cpx::ZERO);
        self.acc.fill(Cpx::ZERO);
        self.scratch.fill(Cpx::ZERO);
        self.out_part.fill(0.0);
        self.phase = 0;
        self.finished_blocks = 0;
        if self.prepared {
            self.model = self.target_model.min(MODEL_COUNT - 1);
            self.partitions = self.partition_counts[self.model];
        }
        // Snap the smoothed gains so the next block sounds like the first one.
        self.wet = self.target_wet;
        self.dry = self.target_dry;
    }

    fn name(&self) -> &'static str {
        NAME
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        match name {
            "mix" => {
                self.set_mix(value);
                true
            }
            "volume" => {
                self.set_volume(value);
                true
            }
            "model" => {
                self.set_model(value);
                true
            }
            _ => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fft_matches_a_direct_dft_and_inverts() {
        let n = 16;
        let fft = Fft::new(n);
        let original: Vec<Cpx> = (0..n)
            .map(|index| Cpx {
                re: (index as f32 * 0.7).sin(),
                im: (index as f32 * 0.3).cos() * 0.25,
            })
            .collect();

        let mut spectrum = original.clone();
        fft.run(&mut spectrum, false);

        for k in 0..n {
            let mut expected = Cpx::ZERO;
            for t in 0..n {
                let angle = -2.0 * std::f64::consts::PI * (k * t) as f64 / n as f64;
                let twiddle = Cpx {
                    re: angle.cos() as f32,
                    im: angle.sin() as f32,
                };
                expected = expected.add(original[t].mul(twiddle));
            }
            assert!(
                (spectrum[k].re - expected.re).abs() < 1e-4
                    && (spectrum[k].im - expected.im).abs() < 1e-4,
                "bin {k} is {:?}, the DFT says {expected:?}",
                spectrum[k]
            );
        }

        fft.run(&mut spectrum, true);
        for index in 0..n {
            assert!(
                (spectrum[index].re - original[index].re).abs() < 1e-5
                    && (spectrum[index].im - original[index].im).abs() < 1e-5,
                "round trip changed sample {index}"
            );
        }
    }

    #[test]
    fn the_impulse_is_the_web_length_and_decay() {
        let rate = 48_000;
        let impulse = studio_impulse(rate, SECONDS, DECAY);
        assert_eq!(impulse.len(), (rate as f32 * SECONDS) as usize);

        let rms = |slice: &[f32]| {
            (slice.iter().map(|s| s * s).sum::<f32>() / slice.len() as f32).sqrt()
        };
        let first = rms(&impulse[..1_000]);
        let last = rms(&impulse[impulse.len() - 1_000..]);
        assert!(first > 0.2, "the head of the impulse is too quiet");
        assert!(
            last < first * 0.01,
            "the tail did not decay: {last} against {first}"
        );
        assert!(impulse.iter().all(|sample| sample.abs() <= 1.0));
    }

    #[test]
    fn the_normalization_is_the_specs_equal_power_scale() {
        // A single 0.5 s of ones at 44.1 kHz: power 1, so the scale is the
        // calibration constant alone.
        let flat = vec![1.0f32; 22_050];
        assert!((normalization_scale(&flat, 44_100) - 0.00125).abs() < 1e-9);
        // The scale follows the rate, as the spec's algorithm does.
        assert!((normalization_scale(&flat, 48_000) - 0.00125 * 48_000.0 / 44_100.0).abs() < 1e-9);
        // Silence is floored, not amplified to infinity.
        let silent = vec![0.0f32; 1_000];
        let scale = normalization_scale(&silent, 48_000);
        assert!(scale.is_finite() && scale > 0.0);
    }

    #[test]
    fn the_default_model_is_plate_and_every_model_keeps_its_length() {
        let rate = 48_000;
        let mut reverb = Reverb::new();
        assert_eq!(reverb.model_name(), "Plate");
        reverb.prepare(rate, 1024);
        assert_eq!(reverb.model(), DEFAULT_MODEL);

        // Each process call is one whole 1024-sample block, so the model switch
        // is applied at its first sample and silence stays silent.
        for (model, seconds) in MODEL_SECONDS.iter().enumerate() {
            reverb.set("model", model as f32);
            let mut block = vec![0.0f32; 1024];
            reverb.process(&mut block);
            assert_eq!(reverb.model(), model);
            assert_eq!(reverb.model_name(), MODEL_NAMES[model]);
            assert_eq!(reverb.impulse().len(), (rate as f32 * seconds) as usize);
            assert_eq!(reverb.partitions, reverb.partition_counts[model]);
            assert!(block.iter().all(|sample| *sample == 0.0));
        }
    }

    #[test]
    fn the_model_knob_clamps_and_ignores_junk() {
        let mut reverb = Reverb::new();
        reverb.prepare(48_000, 64);
        assert!(reverb.set("model", 99.0));
        assert_eq!(reverb.target_model, 4);
        assert!(reverb.set("model", -5.0));
        assert_eq!(reverb.target_model, 0);
        assert!(reverb.set("model", f32::NAN));
        assert_eq!(reverb.target_model, 0, "NaN moved the model");
        assert!(!reverb.set("wet", 1.0));
    }

    #[test]
    fn reset_returns_to_the_first_run() {
        let rate = 48_000;
        let input: Vec<f32> = (0..2_048)
            .map(|index| {
                (std::f32::consts::TAU * 220.0 * index as f32 / rate as f32).sin() * 0.3
            })
            .collect();
        let mut reverb = Reverb::new();
        reverb.prepare(rate, 2_048);
        let mut first = input.clone();
        reverb.process(&mut first);
        reverb.reset();
        let mut second = input.clone();
        reverb.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn an_unprepared_reverb_is_a_wire() {
        let mut reverb = Reverb::new();
        let mut block = vec![0.5f32, -0.25, 1.0];
        reverb.process(&mut block);
        assert_eq!(block, vec![0.5, -0.25, 1.0]);
    }
}
