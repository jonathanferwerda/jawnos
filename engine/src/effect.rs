//! The channel strip's effects, ported from Studio's WebAudio pedals.
//!
//! Every effect is built and [`prepare`](Effect::prepare)d before the first
//! block; from then on `process` only reads and writes memory it already owns.
//! That matters because the audio thread has one period (1.33 ms at 64 frames)
//! between the device and its next deadline: an allocation, a lock or a panic
//! there is a dropout, not an error message. Parameters move through one-pole
//! smoothing so a knob turned between blocks cannot step a filter or a delay
//! line into a click.
//!
//! The shapes follow `public/js/manager/studio.js`. Only the distortion curve
//! is the web formula verbatim; everything else is the same role and controls,
//! not a claim of a sample-identical copy (see each type's docs). The pedals
//! added for the Studio effects contract — flanger, fuzz, amp, limiter,
//! autotune, equalizer and the maximizer the master rack borrows — live in the
//! `effect/` submodules; each one documents its own approximation and its own
//! natural units.

use std::f64::consts::{FRAC_1_SQRT_2, PI, SQRT_2};

use crate::graph::{mix_mono_into_stereo_with_gains, pan_coefficients, GraphError, Strip};
use crate::reverb::Reverb;

mod amp;
mod autotune;
mod equalizer;
mod flanger;
mod fuzz;
mod limiter;
mod maximizer;

pub use amp::Amp;
pub use autotune::Autotune;
pub use equalizer::Equalizer;
pub use flanger::Flanger;
pub use fuzz::Fuzz;
pub use limiter::Limiter;
pub use maximizer::Maximizer;

/// How long a control takes to travel most of the way to a new value.
const SMOOTH_SECONDS: f32 = 0.02;

/// One effect in a channel's insert chain. `prepare` is the only place an
/// implementation may allocate; `process` must not allocate, lock or panic.
pub trait Effect {
    /// Size the effect for `rate` and the largest block it will see.
    fn prepare(&mut self, rate: u32, max_frames: usize);
    /// One mono channel, in place.
    fn process(&mut self, block: &mut [f32]);
    /// Clear the running state so the next block sounds like the first one.
    fn reset(&mut self);
    /// Move one of this effect's knobs. The name is the suffix the control
    /// path uses without the effect prefix (`drive`, not `distortion.drive`).
    ///
    /// Returns true when the name belongs to this effect, whether or not the
    /// value was usable: the caller has already recognised the parameter, and a
    /// non-finite value is ignored rather than turned into NaN. The value is
    /// clamped here, so a control thread cannot put the effect out of range.
    /// This only writes the smoothed target: it allocates nothing, takes no
    /// lock and cannot panic, because the audio thread calls it between blocks.
    fn set(&mut self, _name: &str, _value: f32) -> bool {
        false
    }
    /// The name the take report and the chain order use.
    fn name(&self) -> &'static str;
}

/// The fraction of the remaining distance a one-pole covers in one sample.
fn one_pole(seconds: f32, rate: u32) -> f64 {
    if seconds <= 0.0 || rate == 0 {
        1.0
    } else {
        1.0 - (-1.0 / (f64::from(seconds) * f64::from(rate))).exp()
    }
}

/// The same one-pole, sampled once per block: how far the control moves at
/// this block's edge.
fn one_pole_block(seconds: f32, rate: u32, frames: usize) -> f64 {
    if seconds <= 0.0 || rate == 0 || frames == 0 {
        1.0
    } else {
        1.0 - (-(frames as f64) / (f64::from(seconds) * f64::from(rate))).exp()
    }
}

fn clamp_hz(rate: f64, hz: f64) -> f64 {
    // A shelf at or above Nyquist folds back and a filter at 0 Hz has no
    // meaningful slope; both are refused to the nearest useful edge.
    hz.clamp(1.0, rate * 0.49)
}

/// One biquad, transposed direct form II, with f64 coefficients and state.
///
/// Studio's biquads are Chromium's, which are f32; double precision here costs
/// nothing at these rates and keeps a 220 Hz shelf from losing its shape to
/// rounding at 48 kHz.
#[derive(Clone, Copy, Debug)]
struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1: f64,
    z2: f64,
}

impl Biquad {
    const fn identity() -> Self {
        Biquad {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
            z1: 0.0,
            z2: 0.0,
        }
    }

    /// Apply a normalised `(b0, b1, b2, a0, a1, a2)` set, keeping the state.
    fn set(&mut self, (b0, b1, b2, a0, a1, a2): (f64, f64, f64, f64, f64, f64)) {
        let usable = a0.is_finite()
            && a0.abs() > 1e-12
            && [b0, b1, b2, a1, a2].iter().all(|value| value.is_finite());
        if !usable {
            *self = Biquad::identity();
            return;
        }
        self.b0 = b0 / a0;
        self.b1 = b1 / a0;
        self.b2 = b2 / a0;
        self.a1 = a1 / a0;
        self.a2 = a2 / a0;
    }

    #[inline]
    fn process(&mut self, sample: f32) -> f32 {
        let x = f64::from(sample);
        let y = self.b0 * x + self.z1;
        self.z1 = self.b1 * x - self.a1 * y + self.z2;
        self.z2 = self.b2 * x - self.a2 * y;
        y as f32
    }

    fn reset(&mut self) {
        self.z1 = 0.0;
        self.z2 = 0.0;
    }
}

/// RBJ low shelf, S = 1, the shape Studio's `bass` biquad uses.
fn low_shelf(rate: f64, hz: f64, gain_db: f64) -> (f64, f64, f64, f64, f64, f64) {
    let a = 10f64.powf(gain_db / 40.0);
    let w = 2.0 * PI * clamp_hz(rate, hz) / rate;
    let (sn, cs) = w.sin_cos();
    let alpha = sn / SQRT_2;
    let root = 2.0 * a.sqrt() * alpha;
    let b0 = a * ((a + 1.0) - (a - 1.0) * cs + root);
    let b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cs);
    let b2 = a * ((a + 1.0) - (a - 1.0) * cs - root);
    let a0 = (a + 1.0) + (a - 1.0) * cs + root;
    let a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cs);
    let a2 = (a + 1.0) + (a - 1.0) * cs - root;
    (b0, b1, b2, a0, a1, a2)
}

/// RBJ peaking filter, Q = 1, the shape Studio's `mid` biquad uses.
fn peaking(rate: f64, hz: f64, q: f64, gain_db: f64) -> (f64, f64, f64, f64, f64, f64) {
    let a = 10f64.powf(gain_db / 40.0);
    let w = 2.0 * PI * clamp_hz(rate, hz) / rate;
    let (sn, cs) = w.sin_cos();
    let alpha = sn / (2.0 * q.max(0.01));
    let b0 = 1.0 + alpha * a;
    let b1 = -2.0 * cs;
    let b2 = 1.0 - alpha * a;
    let a0 = 1.0 + alpha / a;
    let a1 = -2.0 * cs;
    let a2 = 1.0 - alpha / a;
    (b0, b1, b2, a0, a1, a2)
}

/// RBJ high shelf, S = 1, the shape Studio's `treble` biquad uses.
fn high_shelf(rate: f64, hz: f64, gain_db: f64) -> (f64, f64, f64, f64, f64, f64) {
    let a = 10f64.powf(gain_db / 40.0);
    let w = 2.0 * PI * clamp_hz(rate, hz) / rate;
    let (sn, cs) = w.sin_cos();
    let alpha = sn / SQRT_2;
    let root = 2.0 * a.sqrt() * alpha;
    let b0 = a * ((a + 1.0) + (a - 1.0) * cs + root);
    let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cs);
    let b2 = a * ((a + 1.0) + (a - 1.0) * cs - root);
    let a0 = (a + 1.0) - (a - 1.0) * cs + root;
    let a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cs);
    let a2 = (a + 1.0) - (a - 1.0) * cs - root;
    (b0, b1, b2, a0, a1, a2)
}

/// RBJ lowpass, Q = 1/√2 (Butterworth), used after the distortion shaper.
fn lowpass(rate: f64, hz: f64) -> (f64, f64, f64, f64, f64, f64) {
    let w = 2.0 * PI * clamp_hz(rate, hz) / rate;
    let (sn, cs) = w.sin_cos();
    let alpha = sn / (2.0 * FRAC_1_SQRT_2);
    let b0 = (1.0 - cs) / 2.0;
    let b1 = 1.0 - cs;
    let b2 = (1.0 - cs) / 2.0;
    let a0 = 1.0 + alpha;
    let a1 = -2.0 * cs;
    let a2 = 1.0 - alpha;
    (b0, b1, b2, a0, a1, a2)
}

/// RBJ highpass, Q selectable, used by the amp's cabinets.
fn highpass(rate: f64, hz: f64, q: f64) -> (f64, f64, f64, f64, f64, f64) {
    let w = 2.0 * PI * clamp_hz(rate, hz) / rate;
    let (sn, cs) = w.sin_cos();
    let alpha = sn / (2.0 * q.max(0.01));
    let b0 = (1.0 + cs) / 2.0;
    let b1 = -(1.0 + cs);
    let b2 = (1.0 + cs) / 2.0;
    let a0 = 1.0 + alpha;
    let a1 = -2.0 * cs;
    let a2 = 1.0 - alpha;
    (b0, b1, b2, a0, a1, a2)
}

/// The channel's bass / mid / treble, at the frequencies and Qs Studio sets:
/// a 220 Hz low shelf, a 1 kHz peaking mid, a 3.5 kHz high shelf.
#[derive(Debug)]
pub struct ToneStack {
    rate: u32,
    target_db: [f32; 3],
    current_db: [f32; 3],
    /// The pedal's own output level: the browser's `tone` insert has a Gain
    /// knob, and the contract lists it with the three bands. Unity is 1.0.
    target_gain: f32,
    gain: f32,
    bands: [Biquad; 3],
    designed: bool,
}

impl ToneStack {
    pub const BASS_HZ: f32 = 220.0;
    pub const MID_HZ: f32 = 1_000.0;
    pub const TREBLE_HZ: f32 = 3_500.0;
    /// The knobs stop at ±12 dB, Studio's range.
    pub const MAX_DB: f32 = 12.0;

    /// Gains in dB, the same ±12 dB range Studio's three knobs cover.
    pub fn new(bass_db: f32, mid_db: f32, treble_db: f32) -> Self {
        ToneStack {
            rate: 48_000,
            target_db: [bass_db, mid_db, treble_db],
            current_db: [bass_db, mid_db, treble_db],
            target_gain: 1.0,
            gain: 1.0,
            bands: [Biquad::identity(); 3],
            designed: false,
        }
    }

    /// Move the three controls. The audio thread reads the new target at its
    /// next block and walks to it over [`SMOOTH_SECONDS`]; call only from the
    /// setup thread or the audio thread itself.
    pub fn set_gains(&mut self, bass_db: f32, mid_db: f32, treble_db: f32) {
        self.target_db = [bass_db, mid_db, treble_db];
    }

    fn design(&mut self) {
        let rate = f64::from(self.rate.max(1));
        self.bands[0].set(low_shelf(rate, f64::from(Self::BASS_HZ), f64::from(self.current_db[0])));
        self.bands[1].set(peaking(
            rate,
            f64::from(Self::MID_HZ),
            1.0,
            f64::from(self.current_db[1]),
        ));
        self.bands[2].set(high_shelf(
            rate,
            f64::from(Self::TREBLE_HZ),
            f64::from(self.current_db[2]),
        ));
        self.designed = true;
    }
}

impl Effect for ToneStack {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.current_db = self.target_db;
        self.gain = self.target_gain;
        self.design();
        self.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.designed {
            return;
        }
        let gain_alpha = one_pole_block(SMOOTH_SECONDS, self.rate, block.len());
        self.gain = (f64::from(self.gain)
            + f64::from(self.target_gain - self.gain) * gain_alpha) as f32;
        let level = self.gain;
        // One control step per block: coefficients are nonlinear in gain, so
        // moving the control in bounded steps is what keeps the filter stable.
        let alpha = one_pole_block(SMOOTH_SECONDS, self.rate, block.len());
        let mut changed = false;
        for band in 0..3 {
            let target = self.target_db[band];
            let current = self.current_db[band];
            if target != current {
                if (target - current).abs() < 1e-4 {
                    self.current_db[band] = target;
                } else {
                    self.current_db[band] = (f64::from(current)
                        + f64::from(target - current) * alpha) as f32;
                }
                changed = true;
            }
        }
        if changed {
            self.design();
        }
        for sample in block.iter_mut() {
            for band in &mut self.bands {
                *sample = band.process(*sample);
            }
            *sample *= level;
        }
    }

    fn reset(&mut self) {
        for band in &mut self.bands {
            band.reset();
        }
        self.gain = self.target_gain;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        if name == "gain" {
            if value.is_finite() {
                self.target_gain = value.clamp(0.0, 2.0);
            }
            return true;
        }
        let band = match name {
            "bass" => 0,
            "mid" => 1,
            "treble" => 2,
            _ => return false,
        };
        if value.is_finite() {
            self.target_db[band] = value.clamp(-Self::MAX_DB, Self::MAX_DB);
        }
        true
    }

    fn name(&self) -> &'static str {
        "tone"
    }
}

/// Studio's `Distorjawn`: the `studioDistortionCurve` shaper, 4x oversampled,
/// into a 4.5 kHz lowpass.
///
/// The curve is the web formula, evaluated per sample instead of read from a
/// 44,100-entry table: `((3 + amount) * x * 20 * π/180) / (π + amount * |x|)`.
/// The browser's `oversample = '4x'` filters are implementation-defined; here
/// the input is linearly interpolated to 4x, shaped, lowpassed at 4x with an
/// RBJ Butterworth, then decimated. Same shape and role, not a sample-identical
/// copy.
#[derive(Debug)]
pub struct Distortion {
    rate: u32,
    target_amount: f32,
    amount: f32,
    previous: f32,
    lowpass: Biquad,
}

impl Distortion {
    /// `drive` is the web knob's 0..100 amount.
    pub fn new(drive: f32) -> Self {
        let amount = drive.clamp(0.0, 100.0);
        Distortion {
            rate: 48_000,
            target_amount: amount,
            amount,
            previous: 0.0,
            lowpass: Biquad::identity(),
        }
    }

    /// Move the drive knob; the next blocks walk to it over 10 ms.
    pub fn set_drive(&mut self, drive: f32) {
        if drive.is_finite() {
            self.target_amount = drive.clamp(0.0, 100.0);
        }
    }

    #[inline]
    fn shape(x: f32, amount: f32) -> f32 {
        const DEG: f32 = PI as f32 / 180.0;
        ((3.0 + amount) * x * 20.0 * DEG) / (PI as f32 + amount * x.abs())
    }
}

impl Effect for Distortion {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.amount = self.target_amount;
        self.previous = 0.0;
        self.lowpass.set(lowpass(f64::from(self.rate) * 4.0, 4_500.0));
        self.lowpass.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        const OVERSAMPLE: usize = 4;
        let alpha = one_pole_block(0.01, self.rate, block.len()) as f32;
        self.amount += (self.target_amount - self.amount) * alpha;

        for sample in block.iter_mut() {
            let x = *sample;
            let mut shaped = x;
            for step in 1..=OVERSAMPLE {
                let t = step as f32 / OVERSAMPLE as f32;
                let sub = self.previous + (x - self.previous) * t;
                shaped = self.lowpass.process(Self::shape(sub, self.amount));
            }
            self.previous = x;
            *sample = shaped;
        }
    }

    fn reset(&mut self) {
        self.previous = 0.0;
        self.amount = self.target_amount;
        self.lowpass.reset();
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        if name != "drive" {
            return false;
        }
        self.set_drive(value);
        true
    }

    fn name(&self) -> &'static str {
        "distortion"
    }
}

/// Studio's `Delayed`: a 2 s line, feedback, a fixed 0.7 dry and a wet control.
///
/// The controls are the same three knobs: `time` 0..1.5 s, `feedback` 0..0.9,
/// and `vol` as the wet gain. Time is smoothed per sample and read with linear
/// interpolation, so moving it bends the echo instead of clicking.
#[derive(Debug)]
pub struct Delay {
    rate: u32,
    buffer: Vec<f32>,
    write: usize,
    target_time: f32,
    time: f32,
    target_feedback: f32,
    feedback: f32,
    target_wet: f32,
    wet: f32,
    smooth: f32,
}

impl Delay {
    pub const DRY: f32 = 0.7;
    pub const MAX_SECONDS: f32 = 2.0;
    /// The `time` knob stops at 1.5 s; the line itself is 2 s long.
    pub const MAX_TIME: f32 = 1.5;
    /// The `feedback` knob stops short of unity, so the line cannot run away.
    pub const MAX_FEEDBACK: f32 = 0.9;

    pub fn new(time_seconds: f32, feedback: f32, wet: f32) -> Self {
        let time = time_seconds.clamp(0.0, Self::MAX_TIME);
        let feedback = feedback.clamp(0.0, Self::MAX_FEEDBACK);
        let wet = wet.clamp(0.0, 1.0);
        Delay {
            rate: 48_000,
            buffer: Vec::new(),
            write: 0,
            target_time: time,
            time,
            target_feedback: feedback,
            feedback,
            target_wet: wet,
            wet,
            smooth: 0.0,
        }
    }

    /// Move all three knobs at once. Named access for a control path goes
    /// through [`Effect::set`] (`time`, `feedback`, `mix`), which this is the
    /// bulk form of.
    pub fn set_knobs(&mut self, time_seconds: f32, feedback: f32, wet: f32) {
        self.target_time = time_seconds.clamp(0.0, Self::MAX_TIME);
        self.target_feedback = feedback.clamp(0.0, Self::MAX_FEEDBACK);
        self.target_wet = wet.clamp(0.0, 1.0);
    }
}

impl Effect for Delay {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        let length = (f64::from(self.rate) * f64::from(Self::MAX_SECONDS)) as usize + 2;
        self.buffer = vec![0.0; length.max(4)];
        self.write = 0;
        self.time = self.target_time;
        self.feedback = self.target_feedback;
        self.wet = self.target_wet;
        self.smooth = one_pole(0.01, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        let length = self.buffer.len();
        if length < 4 {
            return;
        }
        let rate = self.rate.max(1) as f32;
        let reach = (length - 2) as f32;
        for sample in block.iter_mut() {
            self.time += (self.target_time - self.time) * self.smooth;
            self.feedback += (self.target_feedback - self.feedback) * self.smooth;
            self.wet += (self.target_wet - self.wet) * self.smooth;

            let delay_samples = (self.time * rate).clamp(1.0, reach);
            let back = self.write as f32 - delay_samples;
            let base = back.floor();
            let fraction = back - base;
            let first = (base as isize).rem_euclid(length as isize) as usize;
            let second = (first + 1) % length;
            let delayed = self.buffer[first] * (1.0 - fraction) + self.buffer[second] * fraction;

            let input = *sample;
            *sample = input * Self::DRY + delayed * self.wet;
            self.buffer[self.write] = input + delayed * self.feedback;
            self.write += 1;
            if self.write == length {
                self.write = 0;
            }
        }
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
        self.write = 0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "time" => {
                if usable {
                    self.target_time = value.clamp(0.0, Self::MAX_TIME);
                }
                true
            }
            "feedback" => {
                if usable {
                    self.target_feedback = value.clamp(0.0, Self::MAX_FEEDBACK);
                }
                true
            }
            "mix" | "vol" => {
                if usable {
                    self.target_wet = value.clamp(0.0, 1.0);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "delay"
    }
}

/// A soft-knee compressor with the controls Studio's `CompressionX` exposes:
/// threshold, attack and mix. Ratio, release and knee stay at the browser's
/// defaults (12, 0.25 s, 30 dB).
///
/// Chromium's `DynamicsCompressor` is not a published algorithm, so this is a
/// standard feed-forward, peak-detecting compressor with the same controls and
/// the same job in the chain — not the same sound. There is deliberately **no
/// lookahead**: lookahead is latency, and this plan must not add latency
/// silently. The gain reduction is smoothed by attack and release, which is
/// also where the mix control is smoothed.
#[derive(Debug)]
pub struct Compressor {
    rate: u32,
    threshold_db: f32,
    ratio: f32,
    knee_db: f32,
    attack_s: f32,
    release_s: f32,
    target_mix: f32,
    mix: f32,
    smooth: f32,
    reduction_db: f32,
}

impl Compressor {
    pub fn new(
        threshold_db: f32,
        ratio: f32,
        attack_s: f32,
        release_s: f32,
        knee_db: f32,
        mix: f32,
    ) -> Self {
        Compressor {
            rate: 48_000,
            threshold_db,
            ratio: ratio.max(1.0),
            knee_db: knee_db.max(0.0),
            attack_s: attack_s.max(0.000_1),
            release_s: release_s.max(0.000_1),
            target_mix: mix.clamp(0.0, 1.0),
            mix: mix.clamp(0.0, 1.0),
            smooth: 0.0,
            reduction_db: 0.0,
        }
    }
}

impl Effect for Compressor {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.mix = self.target_mix;
        self.reduction_db = 0.0;
        self.smooth = one_pole(0.01, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        let attack = one_pole(self.attack_s, self.rate) as f32;
        let release = one_pole(self.release_s, self.rate) as f32;
        let ratio = self.ratio.max(1.0);
        let knee = self.knee_db.max(0.0);
        let half_knee = knee * 0.5;
        let slope = 1.0 - 1.0 / ratio;

        for sample in block.iter_mut() {
            self.mix += (self.target_mix - self.mix) * self.smooth;
            let x = *sample;
            let level_db = 20.0 * x.abs().max(1e-9).log10();
            let over = level_db - self.threshold_db;
            let target = if over <= -half_knee {
                0.0
            } else if over >= half_knee {
                over * slope
            } else {
                // Quadratic knee: continuous with both linear regions.
                let t = over + half_knee;
                slope * t * t / (2.0 * knee.max(1e-9))
            };
            let coefficient = if target > self.reduction_db {
                attack
            } else {
                release
            };
            self.reduction_db += (target - self.reduction_db) * coefficient;
            let gain = 10f32.powf(-self.reduction_db / 20.0);
            *sample = x * ((1.0 - self.mix) + self.mix * gain);
        }
    }

    fn reset(&mut self) {
        self.reduction_db = 0.0;
        self.mix = self.target_mix;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "threshold" | "thresh" => {
                if usable {
                    self.threshold_db = value.clamp(-100.0, 0.0);
                }
                true
            }
            "attack" => {
                if usable {
                    self.attack_s = value.clamp(0.000_1, 1.0);
                }
                true
            }
            // The browser exposes these three as knobs; without these arms the
            // control path would send a parameter the engine silently refuses.
            // They are block-rate controls, like the threshold: the gain
            // reduction itself is still smoothed by attack and release.
            "ratio" => {
                if usable {
                    self.ratio = value.clamp(1.0, 20.0);
                }
                true
            }
            "release" => {
                if usable {
                    self.release_s = value.clamp(0.01, 1.0);
                }
                true
            }
            "knee" => {
                if usable {
                    self.knee_db = value.clamp(0.0, 24.0);
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
        "compressor"
    }
}

/// The inserts `--insert` accepts, with the WebAudio defaults each pedal is
/// built with until a control path moves its knobs.
///
/// The `master_` names (`master_comp`, `master_eq`, `master_reverb`,
/// `master_maximizer`, `master_limiter`) parse to the same implementations as
/// their channel counterparts: the prefix says where the insert belongs, not
/// what it does. [`Mixer`](crate::mixer::Mixer) owns the master rack that uses
/// them; this enum only selects the implementation.
///
/// # Stereo Widener is browser only
///
/// The browser's pedalboard and master rack also offer `stereowidener` and
/// `master_stereowidener` (`perl/gb/05_abilities_and_studio.pl`,
/// `public/js/manager/studio/08_effects.js`). There is deliberately no variant
/// for them: an [`Effect`] is a mono processor, and a track runs one mono block
/// through its chain while the master rack runs two independent instances, one
/// per side. Either way an insert never holds an L/R pair, so there is nothing
/// to take a mid/side matrix from. Rather than ship a mono "widener" that
/// changes the sound without widening anything, [`parse`](InsertKind::parse)
/// answers `None`: a take omits the pedal, and the help topic says the native
/// take does not process it yet.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertKind {
    Tone,
    Distortion,
    Delay,
    Compressor,
    Reverb,
    Flanger,
    Fuzz,
    Amp,
    Limiter,
    Autotune,
    Equalizer,
    Maximizer,
}

impl InsertKind {
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "tone" => Some(InsertKind::Tone),
            "distortion" => Some(InsertKind::Distortion),
            "delay" => Some(InsertKind::Delay),
            "compressor" | "master_comp" => Some(InsertKind::Compressor),
            "reverb" | "reverb2" | "master_reverb" => Some(InsertKind::Reverb),
            "flanger" => Some(InsertKind::Flanger),
            "fuzz" => Some(InsertKind::Fuzz),
            "amp" => Some(InsertKind::Amp),
            "limiter" | "master_limiter" => Some(InsertKind::Limiter),
            "autotune" => Some(InsertKind::Autotune),
            "equalizer" | "master_eq" => Some(InsertKind::Equalizer),
            "maximizer" | "master_maximizer" => Some(InsertKind::Maximizer),
            _ => None,
        }
    }

    pub const fn name(self) -> &'static str {
        match self {
            InsertKind::Tone => "tone",
            InsertKind::Distortion => "distortion",
            InsertKind::Delay => "delay",
            InsertKind::Compressor => "compressor",
            InsertKind::Reverb => "reverb",
            InsertKind::Flanger => "flanger",
            InsertKind::Fuzz => "fuzz",
            InsertKind::Amp => "amp",
            InsertKind::Limiter => "limiter",
            InsertKind::Autotune => "autotune",
            InsertKind::Equalizer => "equalizer",
            InsertKind::Maximizer => "maximizer",
        }
    }

    /// The controls this effect's `set` accepts, in the order the control
    /// path numbers them. This is the one control list: [`ParamName::parse`]
    /// and the socket's validation both read it, so a new knob is one row here
    /// rather than a new enum variant and a second parser.
    ///
    /// The spelling is the contract's (`docs/studio-effects.md`): `thresh`, not
    /// `threshold`, and `vol` for the delay's wet level. Aliases are accepted
    /// by [`control_index`](InsertKind::control_index) but never listed.
    pub const fn controls(self) -> &'static [&'static str] {
        match self {
            InsertKind::Tone => &["bass", "mid", "treble", "gain"],
            InsertKind::Distortion => &["drive"],
            InsertKind::Delay => &["time", "feedback", "vol"],
            InsertKind::Compressor => &["thresh", "attack", "ratio", "release", "knee", "mix"],
            InsertKind::Reverb => &["mix", "volume", "model"],
            InsertKind::Flanger => &["rate", "depth", "feedback", "mix"],
            InsertKind::Fuzz => &["gain", "tone", "level"],
            InsertKind::Amp => &["gain", "bass", "mid", "treble", "cabinet"],
            InsertKind::Limiter => &["ceiling", "release"],
            InsertKind::Autotune => &["speed", "amount", "key", "scale"],
            InsertKind::Equalizer => &["low", "mid", "high"],
            InsertKind::Maximizer => &["ceiling", "loudness"],
        }
    }

    /// The master rack's prefix for an implementation, for the five effects the
    /// rack holds. `None` for an effect the rack does not build.
    pub const fn master_prefix(self) -> Option<&'static str> {
        match self {
            InsertKind::Compressor => Some("master_comp"),
            InsertKind::Equalizer => Some("master_eq"),
            InsertKind::Reverb => Some("master_reverb"),
            InsertKind::Maximizer => Some("master_maximizer"),
            InsertKind::Limiter => Some("master_limiter"),
            _ => None,
        }
    }

    /// The index of `control` in [`controls`](InsertKind::controls), accepting
    /// the two historical spellings the old wire used. `None` is an unknown
    /// control, which the socket refuses.
    pub fn control_index(self, control: &str) -> Option<u8> {
        if let Some(index) = self.controls().iter().position(|name| *name == control) {
            return Some(index as u8);
        }
        let canonical = match (self, control) {
            (InsertKind::Compressor, "threshold") => "thresh",
            (InsertKind::Delay, "mix") => "vol",
            _ => return None,
        };
        self.controls()
            .iter()
            .position(|name| *name == canonical)
            .map(|index| index as u8)
    }

    /// The control path speaks the contract's units; an effect's internal knob
    /// may be on another scale. Only the millisecond controls differ: the
    /// engine's compressor and limiter hold seconds, the wire says ms.
    /// Everything else already is its natural unit (dB, Hz, 0..1, an index).
    pub fn native_value(self, control: &str, value: f32) -> f32 {
        match (self, control) {
            (InsertKind::Compressor, "attack" | "release")
            | (InsertKind::Limiter, "release") => value / 1000.0,
            _ => value,
        }
    }

    /// The compact code the parameter word stores. 0 is reserved for the
    /// strip's own gain/pan, so a kind never shares a code with the strip.
    pub const fn code(self) -> u8 {
        match self {
            InsertKind::Tone => 1,
            InsertKind::Distortion => 2,
            InsertKind::Delay => 3,
            InsertKind::Compressor => 4,
            InsertKind::Reverb => 5,
            InsertKind::Flanger => 6,
            InsertKind::Fuzz => 7,
            InsertKind::Amp => 8,
            InsertKind::Limiter => 9,
            InsertKind::Autotune => 10,
            InsertKind::Equalizer => 11,
            InsertKind::Maximizer => 12,
        }
    }

    pub const fn from_code(code: u8) -> Option<Self> {
        Some(match code {
            1 => InsertKind::Tone,
            2 => InsertKind::Distortion,
            3 => InsertKind::Delay,
            4 => InsertKind::Compressor,
            5 => InsertKind::Reverb,
            6 => InsertKind::Flanger,
            7 => InsertKind::Fuzz,
            8 => InsertKind::Amp,
            9 => InsertKind::Limiter,
            10 => InsertKind::Autotune,
            11 => InsertKind::Equalizer,
            12 => InsertKind::Maximizer,
            _ => return None,
        })
    }

    /// Build the pedal at its web defaults: a flat tone stack (the knobs at
    /// 50), Distorjawn at drive 50, Delayed at 0.525 s / 0.27 / 0.4,
    /// CompressionX at −25 dB / 0.1 s attack / 0.5 mix, and `reverb2` at
    /// mix 35 / volume 35. The new pedals start where the browser's pedals
    /// start: flanger 1.05 Hz / 0.6 depth / 0.225 feedback / 0.5 mix, fuzz
    /// 0.65 gain / 0.45 tone / 0.6 level, amp 0.5 gain (0 dB) / flat tone /
    /// Combo 1x12, limiter −3 dBFS / 0.2 s, autotune 0.4 speed / full amount /
    /// C major, equalizer flat, and maximizer −0.8 dBFS / 0.2 loudness.
    pub fn build(self) -> Box<dyn Effect> {
        match self {
            InsertKind::Tone => Box::new(ToneStack::new(0.0, 0.0, 0.0)),
            InsertKind::Distortion => Box::new(Distortion::new(50.0)),
            InsertKind::Delay => Box::new(Delay::new(0.525, 0.27, 0.4)),
            InsertKind::Compressor => Box::new(Compressor::new(-25.0, 12.0, 0.1, 0.25, 30.0, 0.5)),
            InsertKind::Reverb => Box::new(Reverb::new()),
            InsertKind::Flanger => Box::new(Flanger::new(1.05, 0.6, 0.225, 0.5)),
            InsertKind::Fuzz => Box::new(Fuzz::new(0.65, 0.45, 0.6)),
            InsertKind::Amp => Box::new(Amp::new(0.5, 0.0, 0.0, 0.0, 0)),
            InsertKind::Limiter => Box::new(Limiter::new(-3.0, 0.2)),
            InsertKind::Autotune => Box::new(Autotune::new(0.4, 1.0, 0, 0)),
            InsertKind::Equalizer => Box::new(Equalizer::new(0.0, 0.0, 0.0)),
            InsertKind::Maximizer => Box::new(Maximizer::new(-0.8, 0.2)),
        }
    }
}

/// One insert in a rack. The effect is never removed when it is bypassed:
/// the footswitch is a flag here, so the controls and the chain position stay
/// exactly where the player left them.
struct InsertSlot {
    effect: Box<dyn Effect>,
    bypassed: bool,
}

/// One channel strip: trim, the inserts in order, then the equal-power pan.
///
/// Studio's channel is `trim -> bass -> mid -> treble -> inserts -> record`;
/// the tone stack is an insert here so a channel with no inserts is exactly a
/// wire (the web's three knobs sit at 0 dB by default). Pan is applied at the
/// stereo output, because a take is captured after the inserts and played
/// through the same strip.
pub struct Channel {
    strip: Strip,
    inserts: Vec<InsertSlot>,
    scratch: Vec<f32>,
}

impl Channel {
    /// The `gain` knob stops at +12 dB, a recording trim rather than a fader.
    pub const MAX_GAIN: f32 = 4.0;

    pub fn new(gain: f32, pan: f32) -> Self {
        Channel {
            strip: Strip::new(gain, pan),
            inserts: Vec::new(),
            scratch: Vec::new(),
        }
    }

    /// The trim the strip reads at its next block.
    pub fn gain(&self) -> f32 {
        self.strip.gain.get()
    }

    /// The pan the strip reads at its next block, -1 left ..= 1 right.
    pub fn pan(&self) -> f32 {
        self.strip.pan.get()
    }

    /// Clamp a gain the way [`set`](Channel::set) does, for a caller that keeps
    /// a copy of the strip (the control socket's `status`).
    pub fn clamp_gain(value: f32) -> f32 {
        value.clamp(0.0, Self::MAX_GAIN)
    }

    /// Clamp a pan the way [`set`](Channel::set) does.
    pub fn clamp_pan(value: f32) -> f32 {
        value.clamp(-1.0, 1.0)
    }

    /// Move one knob by name. `gain` and `pan` are the strip's own; anything
    /// with a `prefix.` names the first insert whose [`name`](Effect::name)
    /// is that prefix and moves its knob (`delay.mix`). The value is in the
    /// control path's units, so the millisecond knobs are converted before the
    /// effect sees them; the effect clamps. Returns false for a name this strip
    /// does not have.
    pub fn set(&mut self, name: &str, value: f32) -> bool {
        match name {
            "gain" => {
                if value.is_finite() {
                    self.strip.gain.set(Self::clamp_gain(value));
                }
                true
            }
            "pan" => {
                if value.is_finite() {
                    self.strip.pan.set(Self::clamp_pan(value));
                }
                true
            }
            _ => {
                let (prefix, knob) = match name.split_once('.') {
                    Some(pair) => pair,
                    None => return false,
                };
                let kind = match InsertKind::parse(prefix) {
                    Some(kind) => kind,
                    None => return false,
                };
                self.set_insert(kind.name(), knob, kind.native_value(knob, value))
            }
        }
    }

    /// Move one insert's knob by the effect's own prefix. The address has
    /// already been parsed into a kind and a control, so this does no string
    /// construction and stays usable from the audio thread between blocks.
    pub fn set_insert(&mut self, prefix: &str, knob: &str, value: f32) -> bool {
        for slot in &mut self.inserts {
            if slot.effect.name() == prefix {
                return slot.effect.set(knob, value);
            }
        }
        false
    }

    /// Add one insert at the end of the chain.
    pub fn push(&mut self, effect: Box<dyn Effect>) {
        self.inserts.push(InsertSlot {
            effect,
            bypassed: false,
        });
    }

    /// Bypass or restore the first insert whose [`name`](Effect::name) is
    /// `prefix`. The insert stays in the chain and keeps its controls; a
    /// bypassed insert is simply not run. Returns false when no such insert is
    /// in the rack.
    pub fn bypass(&mut self, prefix: &str, bypassed: bool) -> bool {
        for slot in &mut self.inserts {
            if slot.effect.name() == prefix {
                slot.bypassed = bypassed;
                return true;
            }
        }
        false
    }

    /// Size the scratch buffer and every insert. Allocation happens here and
    /// nowhere else.
    pub fn prepare(&mut self, rate: u32, max_frames: usize) {
        self.scratch = vec![0.0; max_frames];
        for slot in &mut self.inserts {
            slot.effect.prepare(rate, max_frames);
        }
    }

    /// `input` is one mono block; `stereo` must be twice as long and is
    /// overwritten. Longer than the prepared block is an error, never a
    /// reallocation.
    pub fn process(&mut self, input: &[f32], stereo: &mut [f32]) -> Result<(), GraphError> {
        if stereo.len() != input.len() * 2 {
            return Err(GraphError::BadBlock {
                expected: input.len() * 2,
                found: stereo.len(),
            });
        }
        if input.len() > self.scratch.len() {
            return Err(GraphError::BlockTooLong {
                max_frames: self.scratch.len(),
                found: input.len(),
            });
        }
        let scratch = &mut self.scratch[..input.len()];
        scratch.copy_from_slice(input);
        let gain = self.strip.gain.get();
        for sample in scratch.iter_mut() {
            *sample *= gain;
        }
        for slot in &mut self.inserts {
            if !slot.bypassed {
                slot.effect.process(scratch);
            }
        }
        // Gain was applied before the inserts; the output only needs the pan.
        let (left, right) = pan_coefficients(self.strip.pan.get());
        stereo.fill(0.0);
        mix_mono_into_stereo_with_gains(stereo, scratch, left, right)
    }

    pub fn reset(&mut self) {
        for slot in &mut self.inserts {
            slot.effect.reset();
        }
    }

    /// The chain order, for a take report: `tone,distortion`. Bypassed inserts
    /// are still in the rack, so they are still named.
    pub fn insert_names(&self) -> String {
        let mut names: Vec<&str> = Vec::with_capacity(self.inserts.len());
        for slot in &self.inserts {
            names.push(slot.effect.name());
        }
        names.join(",")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const RATE: u32 = 48_000;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude)
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    #[test]
    fn every_effect_turns_silence_into_silence() {
        let mut effects: Vec<Box<dyn Effect>> = vec![
            Box::new(ToneStack::new(9.0, -6.0, 6.0)),
            Box::new(Distortion::new(80.0)),
            Box::new(Delay::new(0.25, 0.5, 0.8)),
            Box::new(Compressor::new(-30.0, 4.0, 0.01, 0.2, 6.0, 1.0)),
            Box::new(Flanger::new(0.5, 0.8, 0.4, 0.7)),
            Box::new(Fuzz::new(0.8, 0.5, 0.7)),
            Box::new(Amp::new(0.8, 6.0, -3.0, 3.0, 1)),
            Box::new(Limiter::new(-3.0, 0.1)),
            Box::new(Autotune::new(1.0, 1.0, 0, 0)),
            Box::new(Equalizer::new(6.0, -6.0, 3.0)),
            Box::new(Maximizer::new(-3.0, 0.5)),
        ];
        for effect in &mut effects {
            effect.prepare(RATE, 256);
            let mut block = vec![0.0f32; 256];
            effect.process(&mut block);
            assert!(
                block.iter().all(|sample| *sample == 0.0),
                "{} was not silent",
                effect.name()
            );
        }
    }

    #[test]
    fn full_scale_input_stays_finite() {
        let mut effects: Vec<Box<dyn Effect>> = vec![
            Box::new(ToneStack::new(12.0, 12.0, 12.0)),
            Box::new(Distortion::new(100.0)),
            Box::new(Delay::new(0.1, 0.9, 1.0)),
            Box::new(Compressor::new(-40.0, 20.0, 0.001, 0.05, 0.0, 1.0)),
            Box::new(Flanger::new(5.0, 1.0, 0.9, 1.0)),
            Box::new(Fuzz::new(1.0, 1.0, 1.0)),
            Box::new(Amp::new(1.0, 12.0, 12.0, 12.0, 3)),
            Box::new(Limiter::new(-12.0, 0.001)),
            Box::new(Autotune::new(1.0, 1.0, 0, 0)),
            Box::new(Equalizer::new(15.0, 15.0, 15.0)),
            Box::new(Maximizer::new(-12.0, 1.0)),
        ];
        for effect in &mut effects {
            effect.prepare(RATE, 256);
            let mut alternating = vec![0.0f32; 256];
            for (index, sample) in alternating.iter_mut().enumerate() {
                *sample = if index % 2 == 0 { 1.0 } else { -1.0 };
            }
            effect.process(&mut alternating);
            assert!(
                alternating.iter().all(|sample| sample.is_finite()),
                "{} produced a non-finite sample",
                effect.name()
            );
            let mut full = sine(997.0, 1.0, 256);
            effect.process(&mut full);
            assert!(
                full.iter().all(|sample| sample.is_finite()),
                "{} produced a non-finite sample on a full-scale sine",
                effect.name()
            );
        }
    }

    #[test]
    fn the_tone_stack_boosts_lows_and_cuts_highs() {
        let mut tone = ToneStack::new(12.0, 0.0, -12.0);
        tone.prepare(RATE, 8192);

        let low_input = sine(100.0, 0.1, 8192);
        let mut low = low_input.clone();
        tone.process(&mut low);
        let low_ratio = rms(&low[4096..]) / rms(&low_input[4096..]);

        tone.reset();
        let high_input = sine(8_000.0, 0.1, 8192);
        let mut high = high_input.clone();
        tone.process(&mut high);
        let high_ratio = rms(&high[4096..]) / rms(&high_input[4096..]);

        assert!(low_ratio > 1.5, "100 Hz was not boosted: {low_ratio}");
        assert!(high_ratio < 0.5, "8 kHz was not cut: {high_ratio}");
        assert!(low_ratio > high_ratio * 3.0, "the shelves were too close");
    }

    #[test]
    fn the_distortion_raises_a_quiet_sine() {
        let mut distortion = Distortion::new(50.0);
        distortion.prepare(RATE, 8192);
        let input = sine(220.0, 0.05, 8192);
        let mut block = input.clone();
        distortion.process(&mut block);
        let before = rms(&input[2048..]);
        let after = rms(&block[2048..]);
        assert!(
            after > before * 2.0,
            "quiet sine was not driven: before {before}, after {after}"
        );
    }

    #[test]
    fn the_delay_echoes_at_its_time_and_not_before() {
        // 0.01 s at 48 kHz is exactly 480 samples.
        let mut delay = Delay::new(0.01, 0.0, 1.0);
        delay.prepare(RATE, 2048);
        let mut block = vec![0.0f32; 2048];
        block[0] = 1.0;
        delay.process(&mut block);

        assert!(
            (block[0] - Delay::DRY).abs() < 1e-6,
            "the dry sample was {}",
            block[0]
        );
        for (index, sample) in block[1..480].iter().enumerate() {
            assert!(
                sample.abs() < 1e-6,
                "an echo arrived early at sample {}",
                index + 1
            );
        }
        assert!(
            (block[480] - 1.0).abs() < 1e-4,
            "the echo at 480 was {}",
            block[480]
        );
    }

    #[test]
    fn the_compressor_attenuates_loud_and_passes_quiet() {
        let mut compressor = Compressor::new(-20.0, 4.0, 0.001, 0.1, 0.0, 1.0);
        compressor.prepare(RATE, 16_384);

        let loud_input = sine(220.0, 0.8, 16_384);
        let mut loud = loud_input.clone();
        compressor.process(&mut loud);
        let loud_ratio = rms(&loud[8192..]) / rms(&loud_input[8192..]);
        assert!(loud_ratio < 0.5, "the loud sine passed: {loud_ratio}");

        compressor.reset();
        let quiet_input = sine(220.0, 0.05, 16_384);
        let mut quiet = quiet_input.clone();
        compressor.process(&mut quiet);
        let quiet_ratio = rms(&quiet[8192..]) / rms(&quiet_input[8192..]);
        assert!(
            (quiet_ratio - 1.0).abs() < 0.01,
            "the quiet sine was changed: {quiet_ratio}"
        );
    }

    #[test]
    fn the_compressor_ratio_release_and_knee_move_the_reduction() {
        // A constant input keeps the detector steady, so the reduction is a
        // property of the knobs rather than of a sine's phase.
        let loud = vec![0.8f32; 4096];

        let mut gentle = Compressor::new(-30.0, 2.0, 0.001, 0.1, 0.0, 1.0);
        gentle.prepare(RATE, 4096);
        let mut block = loud.clone();
        gentle.process(&mut block);
        let gentle_reduction = gentle.reduction_db;

        let mut hard = Compressor::new(-30.0, 2.0, 0.001, 0.1, 0.0, 1.0);
        assert!(hard.set("ratio", 20.0));
        hard.prepare(RATE, 4096);
        let mut block = loud.clone();
        hard.process(&mut block);
        assert!(
            hard.reduction_db > gentle_reduction + 3.0,
            "ratio 20 reduced {} dB, ratio 2 only {} dB",
            hard.reduction_db,
            gentle_reduction
        );

        // A wide soft knee changes the reduction around the threshold.
        let steady = vec![0.1f32; 4096];
        let mut hard_knee = Compressor::new(-25.0, 4.0, 0.001, 0.1, 0.0, 1.0);
        hard_knee.prepare(RATE, 4096);
        let mut block = steady.clone();
        hard_knee.process(&mut block);

        let mut soft_knee = Compressor::new(-25.0, 4.0, 0.001, 0.1, 0.0, 1.0);
        assert!(soft_knee.set("knee", 24.0));
        soft_knee.prepare(RATE, 4096);
        let mut block = steady.clone();
        soft_knee.process(&mut block);
        assert!(
            (soft_knee.reduction_db - hard_knee.reduction_db).abs() > 0.25,
            "the knee did not change the reduction: {} against {}",
            soft_knee.reduction_db,
            hard_knee.reduction_db
        );

        // After a loud burst, a fast release lets go of the gain; a slow one
        // holds it. Both start from the same reduction.
        let mut fast = Compressor::new(-30.0, 20.0, 0.001, 0.1, 0.0, 1.0);
        assert!(fast.set("release", 0.01));
        fast.prepare(RATE, 4096);
        let mut block = loud.clone();
        fast.process(&mut block);
        let held = fast.reduction_db;
        let mut silent = vec![0.0f32; 1024];
        fast.process(&mut silent);
        let fast_after = fast.reduction_db;

        let mut slow = Compressor::new(-30.0, 20.0, 0.001, 0.1, 0.0, 1.0);
        assert!(slow.set("release", 1.0));
        slow.prepare(RATE, 4096);
        let mut block = loud.clone();
        slow.process(&mut block);
        slow.process(&mut silent);
        let slow_after = slow.reduction_db;

        assert!(
            fast_after < held * 0.5,
            "the fast release held {fast_after} dB of {held}"
        );
        assert!(
            slow_after > fast_after * 2.0,
            "the slow release let go too quickly: {slow_after} against {fast_after}"
        );
    }

    #[test]
    fn a_non_finite_compressor_knob_is_ignored() {
        let mut compressor = Compressor::new(-25.0, 12.0, 0.1, 0.25, 6.0, 0.5);
        assert!(compressor.set("ratio", f32::NAN));
        assert_eq!(compressor.ratio, 12.0, "NaN moved the ratio");
        assert!(compressor.set("release", f32::NAN));
        assert_eq!(compressor.release_s, 0.25, "NaN moved the release");
        assert!(compressor.set("knee", f32::NAN));
        assert_eq!(compressor.knee_db, 6.0, "NaN moved the knee");
    }

    fn reset_matches_the_first_run(mut effect: Box<dyn Effect>) {
        effect.prepare(RATE, 512);
        let input = sine(440.0, 0.4, 512);
        let mut first = input.clone();
        effect.process(&mut first);
        effect.reset();
        let mut second = input.clone();
        effect.process(&mut second);
        for (index, (a, b)) in first.iter().zip(&second).enumerate() {
            assert!(
                (a - b).abs() < 1e-6,
                "{} diverged after reset at sample {index}: {a} vs {b}",
                effect.name()
            );
        }
    }

    #[test]
    fn reset_returns_each_effect_to_its_first_run() {
        reset_matches_the_first_run(Box::new(ToneStack::new(6.0, -3.0, 9.0)));
        reset_matches_the_first_run(Box::new(Distortion::new(60.0)));
        reset_matches_the_first_run(Box::new(Delay::new(0.05, 0.4, 0.5)));
        reset_matches_the_first_run(Box::new(Compressor::new(-25.0, 8.0, 0.01, 0.1, 6.0, 0.7)));
        reset_matches_the_first_run(Box::new(Flanger::new(0.7, 0.7, 0.4, 0.6)));
        reset_matches_the_first_run(Box::new(Fuzz::new(0.8, 0.4, 0.6)));
        reset_matches_the_first_run(Box::new(Amp::new(0.6, 3.0, -3.0, 6.0, 2)));
        reset_matches_the_first_run(Box::new(Limiter::new(-6.0, 0.1)));
        reset_matches_the_first_run(Box::new(Autotune::new(1.0, 1.0, 0, 0)));
        reset_matches_the_first_run(Box::new(Equalizer::new(3.0, -3.0, 6.0)));
        reset_matches_the_first_run(Box::new(Maximizer::new(-3.0, 0.6)));
    }

    /// Test-only effects with a non-commuting pair of operations, so the order
    /// the channel runs its inserts in is observable.
    struct Add(f32);
    impl Effect for Add {
        fn prepare(&mut self, _rate: u32, _max_frames: usize) {}
        fn process(&mut self, block: &mut [f32]) {
            for sample in block.iter_mut() {
                *sample += self.0;
            }
        }
        fn reset(&mut self) {}
        fn name(&self) -> &'static str {
            "add"
        }
    }

    struct Multiply(f32);
    impl Effect for Multiply {
        fn prepare(&mut self, _rate: u32, _max_frames: usize) {}
        fn process(&mut self, block: &mut [f32]) {
            for sample in block.iter_mut() {
                *sample *= self.0;
            }
        }
        fn reset(&mut self) {}
        fn name(&self) -> &'static str {
            "multiply"
        }
    }

    #[test]
    fn the_channel_runs_gain_then_inserts_then_pan() {
        let mut channel = Channel::new(0.5, -1.0);
        channel.push(Box::new(Add(0.25)));
        channel.push(Box::new(Multiply(4.0)));
        channel.prepare(RATE, 64);

        let input = vec![0.2f32; 64];
        // Seeded with a sentinel: `process` must overwrite, not sum.
        let mut stereo = vec![99.0f32; 128];
        channel.process(&input, &mut stereo).expect("process");

        // 0.2 * gain 0.5 = 0.1; add 0.25 = 0.35; multiply 4 = 1.4; hard left.
        assert!((stereo[0] - 1.4).abs() < 1e-6, "left was {}", stereo[0]);
        assert!(stereo[1].abs() < 1e-6, "right was {}", stereo[1]);
        assert!((stereo[126] - 1.4).abs() < 1e-6);
    }

    #[test]
    fn a_block_longer_than_prepared_is_an_error() {
        let mut channel = Channel::new(1.0, 0.0);
        channel.prepare(RATE, 4);
        let mut stereo = vec![0.0f32; 10];
        assert_eq!(
            channel.process(&[0.0; 5], &mut stereo),
            Err(GraphError::BlockTooLong {
                max_frames: 4,
                found: 5
            })
        );
    }

    #[test]
    fn every_documented_parameter_is_recognised_and_junk_is_not() {
        let mut tone = ToneStack::new(0.0, 0.0, 0.0);
        for name in ["bass", "mid", "treble"] {
            assert!(tone.set(name, 1.0), "tone.{name} was not recognised");
        }
        assert!(!tone.set("drive", 1.0));
        assert!(!tone.set("basss", 1.0));

        let mut distortion = Distortion::new(50.0);
        assert!(distortion.set("drive", 10.0));
        assert!(!distortion.set("amount", 10.0));

        let mut delay = Delay::new(0.5, 0.2, 0.4);
        for name in ["time", "feedback", "mix"] {
            assert!(delay.set(name, 0.1), "delay.{name} was not recognised");
        }
        assert!(!delay.set("wet", 0.1));

        let mut compressor = Compressor::new(-25.0, 12.0, 0.1, 0.25, 30.0, 0.5);
        for name in ["threshold", "thresh", "attack", "ratio", "release", "knee", "mix"] {
            assert!(
                compressor.set(name, -10.0),
                "compressor.{name} was not recognised"
            );
        }
        assert!(!compressor.set("drive", 1.0));

        let mut reverb = crate::reverb::Reverb::new();
        for name in ["mix", "volume", "model"] {
            assert!(reverb.set(name, 0.2), "reverb.{name} was not recognised");
        }
        assert!(!reverb.set("wet", 0.2));

        let mut flanger = Flanger::new(0.3, 0.5, 0.3, 0.5);
        for name in ["rate", "depth", "feedback", "mix"] {
            assert!(flanger.set(name, 0.3), "flanger.{name} was not recognised");
        }
        assert!(!flanger.set("time", 0.3));

        let mut fuzz = Fuzz::new(0.5, 0.5, 0.5);
        for name in ["gain", "tone", "level"] {
            assert!(fuzz.set(name, 0.3), "fuzz.{name} was not recognised");
        }
        assert!(!fuzz.set("drive", 0.3));

        let mut amp = Amp::new(0.5, 0.0, 0.0, 0.0, 0);
        for name in ["gain", "bass", "mid", "treble", "cabinet"] {
            assert!(amp.set(name, 0.3), "amp.{name} was not recognised");
        }
        assert!(!amp.set("presence", 0.3));

        let mut limiter = Limiter::new(-1.0, 0.2);
        for name in ["ceiling", "release"] {
            assert!(limiter.set(name, -3.0), "limiter.{name} was not recognised");
        }
        assert!(!limiter.set("threshold", -3.0));

        let mut autotune = Autotune::new(0.5, 1.0, 0, 0);
        for name in ["speed", "amount", "key", "scale"] {
            assert!(
                autotune.set(name, 1.0),
                "autotune.{name} was not recognised"
            );
        }
        assert!(!autotune.set("thresh", 1.0));

        let mut equalizer = Equalizer::new(0.0, 0.0, 0.0);
        for name in ["low", "mid", "high"] {
            assert!(
                equalizer.set(name, 3.0),
                "equalizer.{name} was not recognised"
            );
        }
        assert!(!equalizer.set("bass", 3.0));

        let mut maximizer = Maximizer::new(-1.0, 0.3);
        for name in ["ceiling", "loudness"] {
            assert!(
                maximizer.set(name, 0.5),
                "maximizer.{name} was not recognised"
            );
        }
        assert!(!maximizer.set("release", 0.1));
    }

    #[test]
    fn every_parameter_clamps_to_its_knob_range() {
        let mut tone = ToneStack::new(0.0, 0.0, 0.0);
        tone.set("bass", 100.0);
        tone.set("mid", -100.0);
        assert_eq!(tone.target_db[0], ToneStack::MAX_DB);
        assert_eq!(tone.target_db[1], -ToneStack::MAX_DB);

        let mut distortion = Distortion::new(50.0);
        distortion.set("drive", 1_000.0);
        assert_eq!(distortion.target_amount, 100.0);
        distortion.set("drive", -1.0);
        assert_eq!(distortion.target_amount, 0.0);

        let mut delay = Delay::new(0.0, 0.0, 0.0);
        delay.set("time", 10.0);
        delay.set("feedback", 10.0);
        delay.set("mix", -1.0);
        assert_eq!(delay.target_time, Delay::MAX_TIME);
        assert_eq!(delay.target_feedback, Delay::MAX_FEEDBACK);
        assert_eq!(delay.target_wet, 0.0);

        let mut compressor = Compressor::new(-25.0, 12.0, 0.1, 0.25, 30.0, 0.5);
        compressor.set("threshold", 20.0);
        compressor.set("attack", 10.0);
        compressor.set("mix", 10.0);
        assert_eq!(compressor.threshold_db, 0.0);
        assert_eq!(compressor.attack_s, 1.0);
        assert_eq!(compressor.target_mix, 1.0);

        compressor.set("ratio", 100.0);
        assert_eq!(compressor.ratio, 20.0);
        compressor.set("ratio", 0.0);
        assert_eq!(compressor.ratio, 1.0);
        compressor.set("release", 0.000_1);
        assert_eq!(compressor.release_s, 0.01);
        compressor.set("release", 10.0);
        assert_eq!(compressor.release_s, 1.0);
        compressor.set("knee", 100.0);
        assert_eq!(compressor.knee_db, 24.0);
        compressor.set("knee", -1.0);
        assert_eq!(compressor.knee_db, 0.0);

        let mut reverb = crate::reverb::Reverb::new();
        reverb.set("mix", 10.0);
        assert!((reverb.wet_gain() - 0.9).abs() < 1e-6);
        assert!((reverb.dry_gain() - 0.6).abs() < 1e-6);
        reverb.set("volume", -1.0);
        assert_eq!(reverb.wet_gain(), 0.0);
    }

    #[test]
    fn a_non_finite_value_is_ignored_but_still_recognised() {
        let mut delay = Delay::new(0.5, 0.2, 0.4);
        assert!(delay.set("time", f32::NAN));
        assert_eq!(delay.target_time, 0.5, "NaN moved a knob");

        let mut channel = Channel::new(1.0, 0.0);
        assert!(channel.set("gain", f32::INFINITY));
        assert_eq!(channel.gain(), 1.0, "infinity moved the trim");
    }

    #[test]
    fn the_channel_recognises_its_own_knobs_and_its_inserts() {
        let mut channel = Channel::new(1.0, 0.0);
        assert!(channel.set("gain", 0.5));
        assert!(channel.set("pan", -0.5));
        assert!(!channel.set("bass", 1.0));
        assert!(!channel.set("nonsense", 1.0));
        assert!(
            !channel.set("delay.mix", 1.0),
            "a delay that is not in the chain cannot take a knob"
        );

        channel.push(InsertKind::Delay.build());
        assert!(channel.set("delay.mix", 1.0));
        assert!(channel.set("delay.time", 0.1));
        assert!(!channel.set("delay.drive", 1.0));
        assert!(!channel.set("tone.bass", 1.0));

        assert!(channel.set("gain", 9.0));
        assert!(channel.set("pan", -9.0));
        assert_eq!(channel.gain(), Channel::MAX_GAIN);
        assert_eq!(channel.pan(), -1.0);
    }

    #[test]
    fn a_parameter_after_reset_still_applies() {
        let mut channel = Channel::new(1.0, 0.0);
        channel.push(InsertKind::Delay.build());
        channel.prepare(RATE, 8);
        channel.reset();

        assert!(channel.set("gain", 0.5));
        assert!(channel.set("delay.mix", 0.0));
        let input = vec![1.0f32; 8];
        let mut stereo = vec![0.0f32; 16];
        channel.process(&input, &mut stereo).expect("process");

        // Trim 0.5, then the delay's 0.7 dry (the line is still empty), centred.
        let expected = 0.5 * Delay::DRY * std::f32::consts::FRAC_1_SQRT_2;
        assert!(
            (stereo[0] - expected).abs() < 1e-6,
            "left was {} not {expected}",
            stereo[0]
        );
    }

    #[test]
    fn a_bypassed_channel_insert_is_transparent() {
        let input = sine(220.0, 0.3, 256);

        let mut plain = Channel::new(1.0, 0.0);
        plain.prepare(RATE, 256);
        let mut plain_out = vec![0.0f32; 512];
        plain.process(&input, &mut plain_out).expect("process");

        let mut channel = Channel::new(1.0, 0.0);
        channel.push(InsertKind::Distortion.build());
        assert!(channel.bypass("distortion", true));
        channel.prepare(RATE, 256);
        let mut out = vec![0.0f32; 512];
        channel.process(&input, &mut out).expect("process");
        assert_eq!(out, plain_out, "a bypassed insert was not transparent");

        assert!(channel.bypass("distortion", false));
        channel.process(&input, &mut out).expect("process");
        assert_ne!(out, plain_out, "restoring the insert changed nothing");
        assert!(!channel.bypass("flanger", true));
    }

    #[test]
    fn insert_kinds_parse_and_report_their_names() {
        for (word, kind) in [
            ("tone", InsertKind::Tone),
            ("distortion", InsertKind::Distortion),
            ("delay", InsertKind::Delay),
            ("compressor", InsertKind::Compressor),
            ("reverb", InsertKind::Reverb),
            ("flanger", InsertKind::Flanger),
            ("fuzz", InsertKind::Fuzz),
            ("amp", InsertKind::Amp),
            ("limiter", InsertKind::Limiter),
            ("autotune", InsertKind::Autotune),
            ("equalizer", InsertKind::Equalizer),
            ("maximizer", InsertKind::Maximizer),
        ] {
            assert_eq!(InsertKind::parse(word), Some(kind));
            assert_eq!(kind.name(), word);
        }
        // The web calls it `reverb2`; the report uses the engine's name.
        assert_eq!(InsertKind::parse("reverb2"), Some(InsertKind::Reverb));
        assert_eq!(InsertKind::Reverb.name(), "reverb");
        // The master prefix selects the same implementation; placement is the
        // caller's business, so the canonical name has no prefix.
        for (word, kind) in [
            ("master_comp", InsertKind::Compressor),
            ("master_eq", InsertKind::Equalizer),
            ("master_reverb", InsertKind::Reverb),
            ("master_maximizer", InsertKind::Maximizer),
            ("master_limiter", InsertKind::Limiter),
        ] {
            assert_eq!(InsertKind::parse(word), Some(kind), "{word}");
        }
        assert_eq!(InsertKind::Maximizer.name(), "maximizer");
        // Stereo Widener is browser only: the insert chain is mono, so there
        // is no kind to build and a native take omits the pedal (see
        // `InsertKind`). Both the track and the rack spelling are refused.
        assert_eq!(InsertKind::parse("stereowidener"), None);
        assert_eq!(InsertKind::parse("master_stereowidener"), None);
        assert_eq!(InsertKind::parse("banana"), None);
    }
}
