//! The `reverb2` pedal: the web's impulse, convolved without adding latency.
//!
//! `studioInsert(ctx, 'reverb2')` is a `ConvolverNode` over
//! `studioImpulse(ctx, 2.4, 2.6)` — 2.4 s of uniform noise under a
//! `(1 - i/length)^2.6` envelope — mixed with the dry signal
//! (`wet = mix/100 * 0.9`, `dry = 1 - mix/100 * 0.4`). That impulse *is* the
//! sound; a Freeverb or a Schroeder network would be a different reverb, so
//! this is honest convolution, only arranged so the engine's own fixed block
//! does not become a block of delay.
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

/// The web's impulse length in seconds: `studioImpulse(ctx, 2.4, 2.6)`.
pub const SECONDS: f32 = 2.4;

/// The exponential decay applied across the impulse.
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
    let length = ((f64::from(rate) * f64::from(seconds)).floor() as usize).max(1);
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
    /// The effective impulse: generated, then scaled as the browser scales it.
    impulse: Vec<f32>,
    /// Length of `impulse`, kept so `prepare` does not re-derive it.
    ir_len: usize,
    /// Partition 0, reversed, so each output sample is one contiguous dot
    /// product with `buf[r + 1 .. r + 1 + PARTITION]`.
    head_rev: Vec<f32>,
    /// FFTs of partitions 1..`partitions`, each a zero-padded 2048-point window.
    spectra: Vec<Cpx>,
    /// The frequency-domain delay line: the last `partitions - 1` two-block
    /// input windows, indexed by `block % ring_len`.
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
    /// through `setters['mix'](35)`.
    pub fn new() -> Self {
        let wet = MIX_DEFAULT * WET_SCALE;
        let dry = 1.0 - MIX_DEFAULT * DRY_SCALE;
        Reverb {
            impulse: Vec::new(),
            ir_len: 0,
            head_rev: Vec::new(),
            spectra: Vec::new(),
            windows: Vec::new(),
            buf: Vec::new(),
            acc: Vec::new(),
            scratch: Vec::new(),
            out_part: Vec::new(),
            fft: Fft::new(FFT_LEN),
            partitions: 0,
            ring_len: 0,
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
    /// and decay times the convolver's normalization. Empty before `prepare`.
    pub fn impulse(&self) -> &[f32] {
        &self.impulse
    }

    /// The wet gain the knobs currently ask for, before block smoothing.
    pub fn wet_gain(&self) -> f32 {
        self.target_wet
    }

    /// The dry gain the mix knob currently asks for, before block smoothing.
    pub fn dry_gain(&self) -> f32 {
        self.target_dry
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
        for partition in 1..self.partitions {
            // Partition `k` multiplies the window ending at block `next - k`.
            let window_slot = (next + ring_len - (partition % ring_len)) % ring_len;
            let h = &self.spectra[partition * n..(partition + 1) * n];
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

        self.impulse = studio_impulse(rate, SECONDS, DECAY);
        let scale = normalization_scale(&self.impulse, rate);
        for sample in &mut self.impulse {
            *sample *= scale;
        }
        self.ir_len = self.impulse.len();
        // A very low rate makes an impulse shorter than one partition; the ring
        // is still sized for at least one partition past the head.
        self.partitions = ((self.ir_len + PARTITION - 1) / PARTITION).max(2);
        self.ring_len = self.partitions - 1;

        self.head_rev = vec![0.0; PARTITION];
        for (index, sample) in self.impulse.iter().take(PARTITION).enumerate() {
            self.head_rev[PARTITION - 1 - index] = *sample;
        }

        self.spectra = vec![Cpx::ZERO; self.partitions * FFT_LEN];
        let mut work = vec![Cpx::ZERO; FFT_LEN];
        for partition in 1..self.partitions {
            for value in work.iter_mut() {
                *value = Cpx::ZERO;
            }
            let start = partition * PARTITION;
            let end = (start + PARTITION).min(self.ir_len);
            for index in start..end {
                work[index - start].re = self.impulse[index];
            }
            self.fft.run(&mut work, false);
            let base = partition * FFT_LEN;
            self.spectra[base..base + FFT_LEN].copy_from_slice(&work);
        }

        self.windows = vec![Cpx::ZERO; self.ring_len * FFT_LEN];
        self.acc = vec![Cpx::ZERO; FFT_LEN];
        self.scratch = vec![Cpx::ZERO; FFT_LEN];
        self.buf = vec![0.0; 2 * PARTITION];
        self.out_part = vec![0.0; PARTITION];

        self.smooth = one_pole_block(SMOOTH_SECONDS, rate, PARTITION) as f32;
        self.prepared = true;
        self.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared
            || self.buf.len() < 2 * PARTITION
            || self.out_part.len() < PARTITION
            || self.head_rev.len() < PARTITION
        {
            return;
        }

        for sample in block.iter_mut() {
            if self.phase == 0 {
                self.move_gains();
            }

            let input = *sample;
            self.buf[PARTITION + self.phase] = input;

            // Partition 0, in the time domain: every tap up to and including the
            // current sample, which is why no block of latency is added.
            let start = self.phase + 1;
            let mut direct = 0.0f32;
            for (tap, value) in self
                .head_rev
                .iter()
                .zip(&self.buf[start..start + PARTITION])
            {
                direct += tap * value;
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
    fn an_unprepared_reverb_is_a_wire() {
        let mut reverb = Reverb::new();
        let mut block = vec![0.5f32, -0.25, 1.0];
        reverb.process(&mut block);
        assert_eq!(block, vec![0.5, -0.25, 1.0]);
    }
}
