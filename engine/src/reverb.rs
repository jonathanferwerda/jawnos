//! The `reverb` pedal: five modelled mechanical tails, convolved without adding
//! latency.
//!
//! `studioInsert(ctx, 'reverb2')` is a `ConvolverNode` mixed with the dry signal
//! (`wet = mix/100 * 0.9`, `dry = 1 - mix/100 * 0.4`). The engine does the same
//! arithmetic — an impulse convolved with the signal — but the impulse is no
//! longer noise reshaped by a handful of filters. Each model is the impulse
//! response of a small *mechanical* model of the thing that rings. One delay
//! network, five parameter sets: the models are the same instrument played at
//! five scales, not five unrelated textures.
//!
//! # The models, and what rings
//!
//! * **Spring (1)** is a Fender 6G15-style spring tank. Two coiled springs are
//!   driven at one end and picked up at the other. The torsional wave in a coil
//!   is dispersive, so the tank is two delay lines (the springs, 29.3 ms and
//!   34.1 ms of travel) whose feedback passes through a cascade of first-order
//!   allpass sections. An allpass changes no magnitude, only the delay of each
//!   band; the cascade therefore turns every echo into a chirp (the high "drip"
//!   ahead of the low "boing"), and the two loop periods give the metallic comb.
//!   A mild one-pole damping in each loop is the wire and transducer loss, and
//!   the loop gains are set for the contract's 1.8 s.
//! * **Plate (2)** is an EMT 140-style plate. A tensioned steel plate has
//!   thousands of densely packed, inharmonic modes, so its response is dense
//!   from the first millisecond and has no discrete early gap. It is modelled as
//!   a bank of twelve short delay lines (1.1-4.1 ms) mixed by an orthogonal
//!   Householder feedback matrix, preceded by four Schroeder diffusers. The
//!   short loops build echo density immediately; the damping corner is high
//!   (14 kHz), so the plate stays bright for the contract's 2.2 s.
//! * **Room (0)**, **Hall (3)** and **Cave (4)** are the same network at larger
//!   scales: six short lines and discrete wall bounces for the room, eight
//!   metre-scale lines with a dark loop for the hall, and the longest, darkest,
//!   low-mid-heaviest set for the cave. They are not sampled spaces; the
//!   mechanical picture is a box whose walls are the delay lines and whose air
//!   and surface loss are the damping.
//!
//! # The real circuit, and the honest approximation
//!
//! The spring's dispersion is a *lumped* allpass cascade, not a solution of the
//! helical spring's wave equation: it gets the chirp and the comb, but not the
//! coil's exact dispersion curve, the transducer's nonlinearity or its
//! mechanical hum. The plate is a feedback delay network whose echo density
//! stands in for the plate's thousands of modes; it does not solve the plate
//! equation, and the EMT's driver, pickup and frame are not modelled. Room,
//! Hall and Cave are parameter studies of the same network, not measurements.
//! What is real is the structure: delay, dispersion, diffusion, damping, and
//! the decay each physical object would have.
//!
//! The generated lengths are in [`MODEL_SECONDS`] and the names in
//! [`MODEL_NAMES`]; the order is shared with the browser.
//!
//! Every model's impulse and its partition spectra are built in `prepare`, so
//! `set("model", ...)` only swaps an index at the next 1024-sample boundary:
//! no allocation and no FFT work on the audio thread. The bank costs about
//! 18 MB at 48 kHz (the six-second Cave alone is 4.6 MB of spectra). That memory
//! is the price of a model switch that cannot glitch, and it is paid once per
//! prepared reverb.
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
//! The browser still generates a `studioImpulse`-style noise shape per model and
//! plays it through a `ConvolverNode`; the engine's impulse now comes from the
//! tank simulation above. The two therefore share the model indices, the lengths
//! and the character table — not the bytes. The WebAudio convolver normalizes by
//! default, so [`Reverb::impulse`] returns the simulated impulse times the spec's
//! equal-power scale, the same level convention the page uses.

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

/// The browser's reference generator (`studioImpulse(ctx, 2.4, 2.6)`) and its
/// envelope exponent. The engine no longer generates noise, but the constants
/// stay public because the shared shape predates the physical models and the
/// integration tests pin them for the browser mirror.
pub const SECONDS: f32 = 2.4;

/// The exponential decay applied across the browser's reference impulse.
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

/// The fixed seed the simulated sign patterns are drawn from, so a take and a
/// test meet the same tank. Any non-zero value would sound the same; this one is
/// only a name for "the house's reverb".
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

/// A first-order allpass section. A cascade of these is the spring's
/// dispersion model: every frequency passes at unit gain, but the band near the
/// pole is delayed more than the rest, so one echo becomes a chirp instead of a
/// click.
struct Allpass1 {
    a: f32,
    x1: f32,
    y1: f32,
}

impl Allpass1 {
    fn new(a: f32) -> Self {
        Allpass1 {
            a: a.clamp(-0.999, 0.999),
            x1: 0.0,
            y1: 0.0,
        }
    }

    /// `H(z) = (a + z^-1) / (1 + a z^-1)`, the stable first-order allpass.
    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let y = self.a * x + self.x1 - self.a * self.y1;
        self.x1 = x;
        self.y1 = y;
        y
    }
}

/// A Schroeder allpass, used as a diffuser in front of a tank. It smears the
/// first few milliseconds without changing the magnitude, which is how a plate
/// loses its discrete early gap while a hall keeps one.
struct Diffuser {
    buf: Vec<f32>,
    pos: usize,
    gain: f32,
}

impl Diffuser {
    fn new(delay: usize, gain: f32) -> Self {
        Diffuser {
            buf: vec![0.0; delay.max(1)],
            pos: 0,
            gain: gain.clamp(0.0, 0.95),
        }
    }

    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let delayed = self.buf[self.pos];
        let write = x + self.gain * delayed;
        let out = delayed - self.gain * write;
        self.buf[self.pos] = write;
        self.pos += 1;
        if self.pos == self.buf.len() {
            self.pos = 0;
        }
        out
    }
}

/// One delay line of the tank. `gain` is the amplitude the loop keeps per pass,
/// chosen so the line decays by 60 dB in the model's tail time.
struct DelayLine {
    buf: Vec<f32>,
    pos: usize,
    gain: f32,
}

impl DelayLine {
    fn new(delay: usize, gain: f32) -> Self {
        DelayLine {
            buf: vec![0.0; delay.max(1)],
            pos: 0,
            gain,
        }
    }

    #[inline]
    fn read(&self) -> f32 {
        self.buf[self.pos]
    }

    #[inline]
    fn write(&mut self, value: f32) {
        self.buf[self.pos] = value;
        self.pos += 1;
        if self.pos == self.buf.len() {
            self.pos = 0;
        }
    }
}

/// One mechanical model, in the vocabulary of the network: how far the wave
/// travels, how much of it comes back, what the medium passes, and where the
/// first wall bounces land.
struct TankParams {
    /// Delay-line lengths in seconds. Two for the spring tank; more for the
    /// rooms and plates, where they stand for a wall or a mode cluster.
    lines: &'static [f32],
    /// RT60, the time the loop takes to fall 60 dB. This is the contract's
    /// model length, so the tail ends where the model says it does.
    rt60: f32,
    /// One-pole loop damping corner: the air and surface loss.
    damping_hz: f64,
    /// First-order allpass sections in each loop, and their coefficient. Zero
    /// sections means no dispersion (everything except the spring).
    dispersion_sections: usize,
    dispersion: f32,
    /// Schroeder diffusers in front of the tank: (seconds, gain).
    diffusers: &'static [(f32, f32)],
    /// Mix the lines with an orthogonal Householder matrix (a dense tank) or
    /// leave them independent (two springs).
    coupling: bool,
    /// Discrete wall/floor bounces, added as delayed copies of the input:
    /// (seconds, gain).
    early: &'static [(f32, f32)],
    /// Output shaping applied once the impulse has been simulated.
    highpass_hz: f64,
    lowpass_hz: f64,
    low_boost_hz: f64,
    low_boost_gain: f64,
    high_boost_hz: f64,
    high_boost_gain: f64,
}

const ROOM_LINES: [f32; 6] = [0.0041, 0.0059, 0.0083, 0.0117, 0.0157, 0.0211];
const SPRING_LINES: [f32; 2] = [0.0293, 0.0341];
const PLATE_LINES: [f32; 12] = [
    0.00113, 0.00137, 0.00161, 0.00179, 0.00211, 0.00239, 0.00271, 0.00293, 0.00323,
    0.00353, 0.00383, 0.00409,
];
const HALL_LINES: [f32; 8] = [
    0.0311, 0.0367, 0.0421, 0.0473, 0.0533, 0.0591, 0.0667, 0.0731,
];
const CAVE_LINES: [f32; 8] = [
    0.0413, 0.0529, 0.0661, 0.0787, 0.0911, 0.1033, 0.1169, 0.1307,
];

const PLATE_DIFFUSERS: [(f32, f32); 4] = [
    (0.0007, 0.70),
    (0.0011, 0.65),
    (0.0017, 0.60),
    (0.0023, 0.55),
];
const ROOM_DIFFUSERS: [(f32, f32); 2] = [(0.0007, 0.50), (0.0013, 0.40)];
const HALL_DIFFUSERS: [(f32, f32); 2] = [(0.0009, 0.35), (0.0017, 0.30)];
const CAVE_DIFFUSERS: [(f32, f32); 2] = [(0.0013, 0.30), (0.0023, 0.25)];

/// The spring's dispersion: a cascade of first-order allpasses. Eight sections
/// at `-0.5` delay the low band by about 24 samples while the high band takes
/// three, enough for an audible chirp without smearing the comb away.
const SPRING_DISPERSION_SECTIONS: usize = 8;
const SPRING_DISPERSION: f32 = -0.5;

const ROOM_EARLY: [(f32, f32); 4] = [
    (0.003, 0.8),
    (0.007, -0.55),
    (0.013, 0.4),
    (0.023, -0.3),
];
const NO_EARLY: [(f32, f32); 0] = [];

/// The five tanks. The order is the contract's model order, and each entry is
/// the same network with a different physical scale.
static TANK_MODELS: [TankParams; MODEL_COUNT] = [
    TankParams {
        lines: &ROOM_LINES,
        rt60: MODEL_SECONDS[0],
        damping_hz: 7_000.0,
        dispersion_sections: 0,
        dispersion: 0.0,
        diffusers: &ROOM_DIFFUSERS,
        coupling: true,
        early: &ROOM_EARLY,
        highpass_hz: 200.0,
        lowpass_hz: 9_000.0,
        low_boost_hz: 0.0,
        low_boost_gain: 0.0,
        high_boost_hz: 0.0,
        high_boost_gain: 0.0,
    },
    TankParams {
        lines: &SPRING_LINES,
        rt60: MODEL_SECONDS[1],
        damping_hz: 10_000.0,
        dispersion_sections: SPRING_DISPERSION_SECTIONS,
        dispersion: SPRING_DISPERSION,
        diffusers: &NO_EARLY,
        coupling: false,
        early: &NO_EARLY,
        highpass_hz: 350.0,
        lowpass_hz: 8_000.0,
        low_boost_hz: 0.0,
        low_boost_gain: 0.0,
        high_boost_hz: 2_500.0,
        high_boost_gain: 0.5,
    },
    TankParams {
        lines: &PLATE_LINES,
        rt60: MODEL_SECONDS[2],
        damping_hz: 14_000.0,
        dispersion_sections: 0,
        dispersion: 0.0,
        diffusers: &PLATE_DIFFUSERS,
        coupling: true,
        early: &NO_EARLY,
        highpass_hz: 90.0,
        lowpass_hz: 0.0,
        low_boost_hz: 0.0,
        low_boost_gain: 0.0,
        high_boost_hz: 2_000.0,
        high_boost_gain: 0.35,
    },
    TankParams {
        lines: &HALL_LINES,
        rt60: MODEL_SECONDS[3],
        damping_hz: 6_000.0,
        dispersion_sections: 0,
        dispersion: 0.0,
        diffusers: &HALL_DIFFUSERS,
        coupling: true,
        early: &NO_EARLY,
        highpass_hz: 90.0,
        lowpass_hz: 4_500.0,
        low_boost_hz: 0.0,
        low_boost_gain: 0.0,
        high_boost_hz: 0.0,
        high_boost_gain: 0.0,
    },
    TankParams {
        lines: &CAVE_LINES,
        rt60: MODEL_SECONDS[4],
        damping_hz: 2_500.0,
        dispersion_sections: 0,
        dispersion: 0.0,
        diffusers: &CAVE_DIFFUSERS,
        coupling: true,
        early: &NO_EARLY,
        highpass_hz: 60.0,
        lowpass_hz: 2_500.0,
        low_boost_hz: 150.0,
        low_boost_gain: 0.8,
        high_boost_hz: 0.0,
        high_boost_gain: 0.0,
    },
];

/// The amplitude a loop of `delay_seconds` keeps per pass so it is 60 dB down
/// after `rt60` seconds: `10^(-3 * delay / rt60)`.
fn loop_gain(delay_seconds: f32, rt60: f32) -> f32 {
    let rt60 = rt60.max(1e-3);
    (-std::f32::consts::LN_10 * 3.0 * delay_seconds / rt60).exp()
}

/// Simulate one tank for one impulse: a bank of delay lines with an orthogonal
/// feedback matrix (or independent loops for the spring), loop damping,
/// optional dispersion in each loop, and input diffusion.
fn tank_impulse(rate: u32, seconds: f32, params: &TankParams) -> Vec<f32> {
    let rate = rate.max(1);
    let length = ((f64::from(rate) * f64::from(seconds)).round() as usize).max(1);
    let lines_count = params.lines.len().max(1);

    let mut lines: Vec<DelayLine> = params
        .lines
        .iter()
        .map(|&delay_seconds| {
            let delay = ((f64::from(rate) * f64::from(delay_seconds)).round() as usize).max(1);
            DelayLine::new(delay, loop_gain(delay_seconds, params.rt60))
        })
        .collect();
    if lines.is_empty() {
        lines.push(DelayLine::new(1, 0.0));
    }

    // Fixed signs, so the model is reproducible; the norm keeps the injected
    // power independent of the line count.
    let mut rng = XorShift32::new(RNG_SEED);
    let norm = 1.0 / (lines_count as f32).sqrt();
    let input_weights: Vec<f32> = (0..lines_count)
        .map(|_| if rng.next_u32() & 1 == 0 { norm } else { -norm })
        .collect();
    let output_weights: Vec<f32> = (0..lines_count)
        .map(|_| if rng.next_u32() & 1 == 0 { 1.0 } else { -1.0 })
        .collect();

    let mut diffusers: Vec<Diffuser> = params
        .diffusers
        .iter()
        .map(|&(delay_seconds, gain)| {
            let delay = ((f64::from(rate) * f64::from(delay_seconds)).round() as usize).max(1);
            Diffuser::new(delay, gain)
        })
        .collect();
    let mut damp_state = vec![0.0f32; lines_count];
    let damp = shape_coefficient(f64::from(rate), params.damping_hz) as f32;
    let mut dispersion: Vec<Vec<Allpass1>> = (0..lines_count)
        .map(|_| {
            (0..params.dispersion_sections)
                .map(|_| Allpass1::new(params.dispersion))
                .collect()
        })
        .collect();
    let mut feedback = vec![0.0f32; lines_count];

    let mut impulse = vec![0.0f32; length];
    for index in 0..length {
        let mut input = if index == 0 { 1.0 } else { 0.0 };
        for diffuser in &mut diffusers {
            input = diffuser.process(input);
        }

        let mut sum = 0.0f32;
        for line in 0..lines_count {
            let read = lines[line].read();
            damp_state[line] += damp * (read - damp_state[line]);
            let mut value = damp_state[line];
            for allpass in &mut dispersion[line] {
                value = allpass.process(value);
            }
            feedback[line] = value;
            sum += value * output_weights[line];
        }

        // Householder reflection: y = x - (2/N) * sum(x). Orthogonal, so the
        // only loss in the loop is the per-line gain and the damping.
        let mean = feedback.iter().sum::<f32>() / lines_count as f32;
        for line in 0..lines_count {
            let mixed = if params.coupling {
                feedback[line] - 2.0 * mean
            } else {
                feedback[line]
            };
            let gain = lines[line].gain;
            lines[line].write(input * input_weights[line] + mixed * gain);
        }
        impulse[index] = sum;
    }

    // A room's first wall bounces are discrete copies of the input, not part of
    // the diffuse loop. The other models have none: their response is dense from
    // the start (plate) or begins at the first line-length (hall/cave).
    let rate_f = f64::from(rate);
    for &(delay_seconds, gain) in params.early {
        let delay = ((rate_f * f64::from(delay_seconds)).round() as usize).max(1);
        if delay < impulse.len() {
            impulse[delay] += gain;
        }
    }

    impulse
}

/// The simulated impulse for one model, before the convolver's normalization.
///
/// The spring is two dispersive loops; the plate is a dense short-loop network
/// with input diffusion; the room, hall and cave are the same network at
/// successively larger scales. None adds a pre-delay, so a note's reverb starts
/// with the note.
fn model_impulse(rate: u32, model: usize) -> Vec<f32> {
    let model = model.min(MODEL_COUNT - 1);
    let params = &TANK_MODELS[model];
    let rate_hz = rate.max(1);
    let rate_f = f64::from(rate_hz);
    let mut impulse = tank_impulse(rate_hz, MODEL_SECONDS[model], params);
    if params.highpass_hz > 0.0 {
        highpass_shape(&mut impulse, rate_f, params.highpass_hz);
    }
    if params.lowpass_hz > 0.0 {
        lowpass_shape(&mut impulse, rate_f, params.lowpass_hz);
    }
    if params.high_boost_gain > 0.0 {
        high_boost_shape(
            &mut impulse,
            rate_f,
            params.high_boost_hz,
            params.high_boost_gain,
        );
    }
    if params.low_boost_gain > 0.0 {
        low_boost_shape(
            &mut impulse,
            rate_f,
            params.low_boost_hz,
            params.low_boost_gain,
        );
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

    fn energy(samples: &[f32]) -> f64 {
        samples
            .iter()
            .map(|sample| f64::from(*sample) * f64::from(*sample))
            .sum()
    }

    fn rms(samples: &[f32]) -> f64 {
        (energy(samples) / samples.len().max(1) as f64).sqrt()
    }

    fn zero_crossings(samples: &[f32]) -> usize {
        samples
            .windows(2)
            .filter(|pair| (pair[0] >= 0.0) != (pair[1] >= 0.0))
            .count()
    }

    /// Energy in the first difference relative to the signal: a cheap,
    /// scale-free brightness measure.
    fn brightness(samples: &[f32]) -> f64 {
        let difference: f64 = samples
            .windows(2)
            .map(|pair| {
                let delta = f64::from(pair[1] - pair[0]);
                delta * delta
            })
            .sum();
        difference / energy(samples).max(f64::MIN_POSITIVE)
    }

    /// Normalised self-similarity at one lag, over the first `window` samples.
    fn autocorrelation(samples: &[f32], lag: usize, window: usize) -> f64 {
        let length = window.min(samples.len().saturating_sub(lag));
        if length == 0 {
            return 0.0;
        }
        let mut dot = 0.0;
        let mut left = 0.0;
        let mut right = 0.0;
        for index in 0..length {
            let a = f64::from(samples[index]);
            let b = f64::from(samples[index + lag]);
            dot += a * b;
            left += a * a;
            right += b * b;
        }
        if left == 0.0 || right == 0.0 {
            0.0
        } else {
            dot / (left.sqrt() * right.sqrt())
        }
    }

    /// Where a signal's energy sits in time, in samples.
    fn energy_center(samples: &[f32]) -> f64 {
        let mut weighted = 0.0;
        let mut total = 0.0;
        for (index, sample) in samples.iter().enumerate() {
            let value = f64::from(*sample);
            weighted += index as f64 * value * value;
            total += value * value;
        }
        if total == 0.0 {
            0.0
        } else {
            weighted / total
        }
    }

    fn one_pole(samples: &[f32], coefficient: f32) -> Vec<f32> {
        let mut state = 0.0f32;
        samples
            .iter()
            .map(|&sample| {
                state += coefficient * (sample - state);
                state
            })
            .collect()
    }

    /// The impulse response of the same allpass cascade the spring uses.
    fn dispersion_impulse(sections: usize, coefficient: f32, length: usize) -> Vec<f32> {
        let mut chain: Vec<Allpass1> = (0..sections)
            .map(|_| Allpass1::new(coefficient))
            .collect();
        (0..length)
            .map(|index| {
                let mut sample = if index == 0 { 1.0 } else { 0.0 };
                for allpass in &mut chain {
                    sample = allpass.process(sample);
                }
                sample
            })
            .collect()
    }

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
    fn every_model_tail_decays_by_its_contract_length() {
        let rate = 48_000u32;
        for (model, seconds) in MODEL_SECONDS.iter().enumerate() {
            let impulse = model_impulse(rate, model);
            assert_eq!(impulse.len(), (rate as f32 * seconds) as usize);
            assert!(
                impulse.iter().all(|sample| sample.is_finite()),
                "{} produced a non-finite sample",
                MODEL_NAMES[model]
            );

            let head = rms(&impulse[..4_800.min(impulse.len())]);
            let tail = rms(&impulse[impulse.len() - 4_800..]);
            assert!(head > 0.0, "{} is silent", MODEL_NAMES[model]);
            assert!(
                tail < head * 0.1,
                "{} did not decay: tail {tail} against head {head}",
                MODEL_NAMES[model]
            );
        }
    }

    #[test]
    fn the_spring_is_a_dispersive_comb_with_a_finite_decay() {
        let rate = 48_000u32;
        let spring = model_impulse(rate, 1);

        let head = rms(&spring[..4_800]);
        let tail = rms(&spring[spring.len() - 4_800..]);
        assert!(tail < head * 0.1, "the spring tail did not decay");

        // Metallic comb: each spring repeats at its own loop period. The
        // allpass cascade adds a few samples of group delay, so the loop repeats
        // just after the bare line length; look there and require a clear peak.
        for &seconds in &SPRING_LINES {
            let delay = (f64::from(rate) * f64::from(seconds)).round() as usize;
            let best = (delay..=delay + 64)
                .map(|lag| autocorrelation(&spring, lag, 16_000))
                .fold(f64::MIN, f64::max);
            assert!(
                best > 0.2,
                "the spring has no metallic comb near {seconds} s: {best}"
            );
        }

        // Chirp: the loop's allpass cascade delays low frequencies more than
        // high ones, so the low band of one dispersed echo arrives later than
        // the high band. That frequency-dependent arrival *is* the chirp.
        let dispersed = dispersion_impulse(SPRING_DISPERSION_SECTIONS, SPRING_DISPERSION, 1_024);
        let low = one_pole(&dispersed, 0.123);
        let high: Vec<f32> = dispersed.windows(2).map(|pair| pair[1] - pair[0]).collect();
        let low_center = energy_center(&low);
        let high_center = energy_center(&high);
        assert!(
            low_center > high_center + 10.0,
            "the spring is not dispersive: low at {low_center}, high at {high_center}"
        );
    }

    #[test]
    fn the_plate_is_denser_and_brighter_than_the_hall() {
        let rate = 48_000u32;
        let plate = model_impulse(rate, 2);
        let hall = model_impulse(rate, 3);

        // No early gap: the plate has returned energy within 10 ms, while the
        // hall's shortest line is 31 ms, so it is still exactly silent.
        let early = rate as usize / 100;
        assert!(rms(&plate[..early]) > 0.0, "the plate left an early gap");
        assert_eq!(rms(&hall[..early]), 0.0, "the hall has a 31 ms line and yet spoke early");

        // Denser: the plate's millimetre-scale loops cross zero far more often
        // in the first tenth of a second than the hall's metre-scale ones.
        let window = rate as usize / 10;
        let plate_crossings = zero_crossings(&plate[..window]);
        let hall_crossings = zero_crossings(&hall[..window]);
        assert!(
            plate_crossings > hall_crossings * 2,
            "the plate is not denser: {plate_crossings} crossings against {hall_crossings}"
        );

        // Brighter: the plate's damping corner is 14 kHz, the hall's is 6 kHz
        // with a 4.5 kHz output cut, so more of the plate's energy is in the
        // first difference.
        let plate_brightness = brightness(&plate);
        let hall_brightness = brightness(&hall);
        assert!(
            plate_brightness > hall_brightness * 1.5,
            "the plate is not brighter: {plate_brightness} against {hall_brightness}"
        );
    }

    #[test]
    fn the_simulation_is_reproducible() {
        for model in 0..MODEL_COUNT {
            assert_eq!(
                model_impulse(48_000, model),
                model_impulse(48_000, model),
                "{} is not reproducible",
                MODEL_NAMES[model]
            );
        }
    }

    #[test]
    fn silence_in_is_silence_out_for_every_model() {
        let mut reverb = Reverb::new();
        reverb.prepare(48_000, PARTITION);
        for model in 0..MODEL_COUNT {
            reverb.set("model", model as f32);
            for _ in 0..2 {
                let mut block = vec![0.0f32; PARTITION];
                reverb.process(&mut block);
                assert!(
                    block.iter().all(|sample| *sample == 0.0),
                    "{} rang on silence",
                    MODEL_NAMES[model]
                );
            }
            assert_eq!(reverb.model(), model);
        }
    }

    #[test]
    fn switching_models_mid_stream_is_safe_and_finite() {
        let rate = 48_000u32;
        let mut reverb = Reverb::new();
        reverb.prepare(rate, 512);
        for (step, &model) in [4usize, 1, 3, 0, 2].iter().enumerate() {
            reverb.set("model", model as f32);
            for block_index in 0..4 {
                let mut block: Vec<f32> = (0..PARTITION)
                    .map(|index| {
                        let sample = (step * 4 + block_index) * PARTITION + index;
                        (std::f32::consts::TAU * 220.0 * sample as f32 / rate as f32).sin() * 0.3
                    })
                    .collect();
                reverb.process(&mut block);
                assert_eq!(reverb.model(), model, "the switch did not land at the block edge");
                assert!(
                    block.iter().all(|sample| sample.is_finite()),
                    "{} produced a non-finite sample",
                    MODEL_NAMES[model]
                );
            }
        }
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
