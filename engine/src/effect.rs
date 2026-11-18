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
//! not a claim of a sample-identical copy (see each type's docs).

use std::f64::consts::{FRAC_1_SQRT_2, PI, SQRT_2};

use crate::graph::{mix_mono_into_stereo_with_gains, pan_coefficients, GraphError, Strip};
use crate::reverb::Reverb;

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

/// The channel's bass / mid / treble, at the frequencies and Qs Studio sets:
/// a 220 Hz low shelf, a 1 kHz peaking mid, a 3.5 kHz high shelf.
#[derive(Debug)]
pub struct ToneStack {
    rate: u32,
    target_db: [f32; 3],
    current_db: [f32; 3],
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
        self.design();
        self.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.designed {
            return;
        }
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
        }
    }

    fn reset(&mut self) {
        for band in &mut self.bands {
            band.reset();
        }
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
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
            "mix" => {
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
            "threshold" => {
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
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertKind {
    Tone,
    Distortion,
    Delay,
    Compressor,
    Reverb,
}

impl InsertKind {
    pub fn parse(word: &str) -> Option<Self> {
        match word {
            "tone" => Some(InsertKind::Tone),
            "distortion" => Some(InsertKind::Distortion),
            "delay" => Some(InsertKind::Delay),
            "compressor" => Some(InsertKind::Compressor),
            "reverb" | "reverb2" => Some(InsertKind::Reverb),
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
        }
    }

    /// Build the pedal at its web defaults: a flat tone stack (the knobs at
    /// 50), Distorjawn at drive 50, Delayed at 0.525 s / 0.27 / 0.4,
    /// CompressionX at −25 dB / 0.1 s attack / 0.5 mix, and `reverb2` at
    /// mix 35 / volume 35.
    pub fn build(self) -> Box<dyn Effect> {
        match self {
            InsertKind::Tone => Box::new(ToneStack::new(0.0, 0.0, 0.0)),
            InsertKind::Distortion => Box::new(Distortion::new(50.0)),
            InsertKind::Delay => Box::new(Delay::new(0.525, 0.27, 0.4)),
            InsertKind::Compressor => Box::new(Compressor::new(-25.0, 12.0, 0.1, 0.25, 30.0, 0.5)),
            InsertKind::Reverb => Box::new(Reverb::new()),
        }
    }
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
    inserts: Vec<Box<dyn Effect>>,
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
    /// is that prefix and moves its knob (`delay.mix`). The effect clamps the
    /// value. Returns false for a name this strip does not have.
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
                for effect in &mut self.inserts {
                    if effect.name() == prefix {
                        return effect.set(knob, value);
                    }
                }
                false
            }
        }
    }

    /// Add one insert at the end of the chain.
    pub fn push(&mut self, effect: Box<dyn Effect>) {
        self.inserts.push(effect);
    }

    /// Size the scratch buffer and every insert. Allocation happens here and
    /// nowhere else.
    pub fn prepare(&mut self, rate: u32, max_frames: usize) {
        self.scratch = vec![0.0; max_frames];
        for effect in &mut self.inserts {
            effect.prepare(rate, max_frames);
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
        for effect in &mut self.inserts {
            effect.process(scratch);
        }
        // Gain was applied before the inserts; the output only needs the pan.
        let (left, right) = pan_coefficients(self.strip.pan.get());
        stereo.fill(0.0);
        mix_mono_into_stereo_with_gains(stereo, scratch, left, right)
    }

    pub fn reset(&mut self) {
        for effect in &mut self.inserts {
            effect.reset();
        }
    }

    /// The chain order, for a take report: `tone,distortion`.
    pub fn insert_names(&self) -> String {
        let mut names: Vec<&str> = Vec::with_capacity(self.inserts.len());
        for effect in &self.inserts {
            names.push(effect.name());
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
        for name in ["threshold", "attack", "mix"] {
            assert!(
                compressor.set(name, -10.0),
                "compressor.{name} was not recognised"
            );
        }
        assert!(!compressor.set("ratio", 1.0));

        let mut reverb = crate::reverb::Reverb::new();
        for name in ["mix", "volume"] {
            assert!(reverb.set(name, 0.2), "reverb.{name} was not recognised");
        }
        assert!(!reverb.set("wet", 0.2));
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
    fn insert_kinds_parse_and_report_their_names() {
        for (word, kind) in [
            ("tone", InsertKind::Tone),
            ("distortion", InsertKind::Distortion),
            ("delay", InsertKind::Delay),
            ("compressor", InsertKind::Compressor),
            ("reverb", InsertKind::Reverb),
        ] {
            assert_eq!(InsertKind::parse(word), Some(kind));
            assert_eq!(kind.name(), word);
        }
        // The web calls it `reverb2`; the report uses the engine's name.
        assert_eq!(InsertKind::parse("reverb2"), Some(InsertKind::Reverb));
        assert_eq!(InsertKind::Reverb.name(), "reverb");
        assert_eq!(InsertKind::parse("flanger"), None);
    }
}
