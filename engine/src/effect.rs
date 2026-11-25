//! The channel strip's effects: four real pedals, modelled from their circuits,
//! and the pedals added for the Studio effects contract.
//!
//! Every effect is built and [`prepare`](Effect::prepare)d before the first
//! block; from then on `process` only reads and writes memory it already owns.
//! That matters because the audio thread has one period (1.33 ms at 64 frames)
//! between the device and its next deadline: an allocation, a lock or a panic
//! there is a dropout, not an error message. Parameters move through one-pole
//! smoothing so a knob turned between blocks cannot step a filter or a delay
//! line into a click.
//!
//! The four pedals the core strip has always carried are no longer generic
//! shapers. Each is a circuit model, documented on its type:
//!
//! * [`Distortion`] is a ProCo RAT: an LM308 gain stage with its gain-dependent
//!   bandwidth and slew limit, silicon diodes clipping to ground, and the RAT's
//!   post-clip low-pass.
//! * [`Delay`] is a Boss DM-2-style bucket-brigade delay: input companding, a
//!   bandwidth that narrows with the clock, an output expander, and a low-pass
//!   in the feedback path so repeats darken.
//! * [`Compressor`] is an MXR Dyna Comp-style OTA compressor: a soft-knee
//!   detector, the OTA's level-dependent squash, and the unit's fast-attack /
//!   slow-release character, with the contract's six knobs mapped onto it.
//! * [`ToneStack`] is a Fender/Marshall passive tone stack (Marshall JMP50
//!   values), solved as a small linear network rather than three independent
//!   shelves, so bass, mid and treble interact.
//!
//! The browser remains the WebAudio reference for the *contract* in
//! `docs/studio-effects.md`; these are the same pedals, controls and natural
//! units, not sample-identical copies. The pedals added for the Studio effects
//! contract — flanger, fuzz, amp, limiter, autotune, equalizer, the maximizer
//! the master rack borrows and the tremolo — live in the `effect/` submodules;
//! each one documents its own approximation and its own natural units.

use std::f64::consts::{FRAC_1_SQRT_2, PI, SQRT_2};

use crate::graph::{mix_mono_into_stereo_with_gains, pan_coefficients, GraphError, Strip};
use crate::reverb::Reverb;

mod amp;
mod autotune;
mod equalizer;
mod flanger;
mod fuzz;
mod graphic_eq;
mod limiter;
mod maximizer;
mod tremolo;

pub use amp::Amp;
pub use autotune::Autotune;
pub use equalizer::Equalizer;
pub use flanger::Flanger;
pub use fuzz::Fuzz;
pub use graphic_eq::GraphicEq;
pub use limiter::Limiter;
pub use maximizer::Maximizer;
pub use tremolo::Tremolo;

/// How long a control takes to travel most of the way to a new value.
const SMOOTH_SECONDS: f32 = 0.02;

/// One effect in a channel's insert chain. `prepare` is the only place an
/// implementation may allocate; `process` must not allocate, lock or panic.
///
/// `Send` lets a compiled [`EffectChain`] travel with the patchbay it belongs
/// to: the patch graph is built on the control thread and moved to its worker,
/// and every effect is plain state with no shared interior mutability.
pub trait Effect: Send {
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

/// The channel's bass / mid / treble as a Fender/Marshall passive tone stack.
///
/// # The circuit
///
/// This is the classic FMV (Fender/Marshall/Vox) network, using the Marshall
/// JMP50 "Plexi" values: a 470 pF treble cap, a 33 kΩ slope resistor, 22 nF bass
/// and mid caps, a 250 kΩ treble pot, a 1 MΩ bass pot, a 25 kΩ mid pot and the
/// 1 MΩ load the next stage presents. The input drives the treble cap and the
/// slope resistor; the slope resistor feeds the bass and mid branches; the
/// treble pot blends the top (treble) and bottom (bass/mid) terminals; its wiper
/// is the output. The bass branch is `C2 + bass pot` to the mid node, the mid
/// branch is `C3` to the same node, and the mid pot returns that node to ground.
/// Every branch shares the mid pot, which is why the controls interact.
///
/// # The approximation
///
/// A passive stack cannot boost; it only removes, and its insertion loss is part
/// of the sound. Rather than pretend otherwise, the network is solved exactly
/// (trapezoidal companion models for the three capacitors, a 5×5 nodal solve at
/// the block edge) and followed by the fixed makeup gain a following stage would
/// supply, `MAKEUP`, calibrated so the noon setting is unity at
/// [`MID_HZ`]. The `gain` control remains an independent output trim.
///
/// The contract's knobs are dB positions, but the real pots are not calibrated
/// dB shelves: `-12..+12` maps linearly across each pot's travel (noon is 0 dB),
/// then the circuit decides what that position does. The low end of a real stack
/// is broad and the bass control is deliberately gentle around [`BASS_HZ`]; the
/// treble and mid controls also load one another, which the tests exercise. The
/// constants [`BASS_HZ`], [`MID_HZ`] and [`TREBLE_HZ`] are the contract's
/// reference frequencies (and the old biquads' corners); they are no longer
/// three independent filter designs.
#[derive(Debug)]
pub struct ToneStack {
    rate: u32,
    target_db: [f32; 3],
    current_db: [f32; 3],
    /// The pedal's own output level: the browser's `tone` insert has a Gain
    /// knob, and the contract lists it with the three bands. Unity is 1.0.
    target_gain: f32,
    gain: f32,
    /// The solved 5×5 network, rows and columns T, out, B, M, BP.
    inverse: [[f64; 5]; 5],
    /// Capacitor history currents J1 (C1), J2 (C2), J3 (C3).
    history: [f64; 3],
    g1: f64,
    g2: f64,
    g3: f64,
    slope: f64,
    designed: bool,
}

/// Invert a 5×5 real matrix by Gauss-Jordan with partial pivoting.
///
/// The tone network is passive, so the matrix is positive definite and this
/// always succeeds with the clamped pot values; `None` is only the numerical
/// guard that keeps a bad design from reaching the audio thread.
fn invert_5(matrix: [[f64; 5]; 5]) -> Option<[[f64; 5]; 5]> {
    let mut augmented = [[0.0f64; 10]; 5];
    for row in 0..5 {
        for column in 0..5 {
            augmented[row][column] = matrix[row][column];
        }
        augmented[row][5 + row] = 1.0;
    }
    for column in 0..5 {
        let mut pivot = column;
        for row in (column + 1)..5 {
            if augmented[row][column].abs() > augmented[pivot][column].abs() {
                pivot = row;
            }
        }
        let value = augmented[pivot][column];
        if !value.is_finite() || value.abs() < 1e-18 {
            return None;
        }
        if pivot != column {
            augmented.swap(pivot, column);
        }
        let divisor = augmented[column][column];
        for entry in 0..10 {
            augmented[column][entry] /= divisor;
        }
        for row in 0..5 {
            if row == column {
                continue;
            }
            let factor = augmented[row][column];
            if factor != 0.0 {
                for entry in 0..10 {
                    augmented[row][entry] -= factor * augmented[column][entry];
                }
            }
        }
    }
    let mut inverse = [[0.0f64; 5]; 5];
    for row in 0..5 {
        for column in 0..5 {
            let value = augmented[row][5 + column];
            if !value.is_finite() {
                return None;
            }
            inverse[row][column] = value;
        }
    }
    Some(inverse)
}

impl ToneStack {
    pub const BASS_HZ: f32 = 220.0;
    pub const MID_HZ: f32 = 1_000.0;
    pub const TREBLE_HZ: f32 = 3_500.0;
    /// The knobs stop at ±12 dB, Studio's range.
    pub const MAX_DB: f32 = 12.0;

    // Marshall JMP50 tone-stack values. The Fender 5F6-A/Bassman uses 250 pF,
    // 100 kΩ, 100 nF and 47 nF; the JMP50's lower slope resistor and larger
    // treble cap give the contract's ±12 dB knobs a little more range and less
    // insertion loss while keeping the same FMV topology.
    const C1: f64 = 470e-12;
    const R1: f64 = 33_000.0;
    const C2: f64 = 22e-9;
    const C3: f64 = 22e-9;
    const R_TREBLE: f64 = 250_000.0;
    const R_BASS: f64 = 1_000_000.0;
    const R_MID: f64 = 25_000.0;
    const R_LOAD: f64 = 1_000_000.0;
    /// The fixed gain of the stage that follows the passive network. It makes
    /// the noon setting unity at `MID_HZ`; the stack itself still has the
    /// circuit's insertion loss and mid scoop.
    const MAKEUP: f64 = 2.676;

    /// Gains in dB, the same ±12 dB range Studio's three knobs cover.
    pub fn new(bass_db: f32, mid_db: f32, treble_db: f32) -> Self {
        ToneStack {
            rate: 48_000,
            target_db: [bass_db, mid_db, treble_db],
            current_db: [bass_db, mid_db, treble_db],
            target_gain: 1.0,
            gain: 1.0,
            inverse: [[0.0; 5]; 5],
            history: [0.0; 3],
            g1: 0.0,
            g2: 0.0,
            g3: 0.0,
            slope: 0.0,
            designed: false,
        }
    }

    /// Move the three controls. The audio thread reads the new target at its
    /// next block and walks to it over [`SMOOTH_SECONDS`]; call only from the
    /// setup thread or the audio thread itself.
    pub fn set_gains(&mut self, bass_db: f32, mid_db: f32, treble_db: f32) {
        self.target_db = [bass_db, mid_db, treble_db];
    }

    /// A `-12..+12` dB knob position across a pot's travel: `-12` is the bottom
    /// stop, `0` is noon, `+12` is the top stop. The circuit, not this mapping,
    /// decides what a position sounds like.
    fn position(db: f32) -> f64 {
        let db = f64::from(db.clamp(-Self::MAX_DB, Self::MAX_DB));
        0.5 + 0.5 * db / f64::from(Self::MAX_DB)
    }

    fn design(&mut self) {
        let rate = f64::from(self.rate.max(1));
        let treble = Self::position(self.current_db[2]);
        let bass = Self::position(self.current_db[0]);
        let mid = Self::position(self.current_db[1]);

        let upper_treble = ((1.0 - treble) * Self::R_TREBLE).max(1.0);
        let lower_treble = (treble * Self::R_TREBLE).max(1.0);
        let bass_pot = (bass * Self::R_BASS).max(1.0);
        let mid_pot = (mid * Self::R_MID).max(10.0);

        // Trapezoidal companion conductances for C1, C2 and C3. They do not
        // depend on the pots, so the history currents survive a redesign.
        let g1 = 2.0 * Self::C1 * rate;
        let g2 = 2.0 * Self::C2 * rate;
        let g3 = 2.0 * Self::C3 * rate;
        let slope = 1.0 / Self::R1;
        let g_upper = 1.0 / upper_treble;
        let g_lower = 1.0 / lower_treble;
        let g_load = 1.0 / Self::R_LOAD;
        let g_bass = 1.0 / bass_pot;
        let g_mid = 1.0 / mid_pot;

        let mut network = [[0.0f64; 5]; 5];
        // T: (C1 to the source) and the upper treble leg.
        network[0][0] = g1 + g_upper;
        network[0][1] = -g_upper;
        // out: the two treble legs and the 1 MΩ load.
        network[1][0] = -g_upper;
        network[1][1] = g_upper + g_lower + g_load;
        network[1][2] = -g_lower;
        // B: slope resistor, lower treble leg, and C2/C3 toward the mid node.
        network[2][1] = -g_lower;
        network[2][2] = slope + g_lower + g2 + g3;
        network[2][3] = -g3;
        network[2][4] = -g2;
        // M: C3, the bass pot and the mid pot to ground.
        network[3][2] = -g3;
        network[3][3] = g3 + g_bass + g_mid;
        network[3][4] = -g_bass;
        // BP: the node between the bass cap and the bass pot.
        network[4][2] = -g2;
        network[4][3] = -g_bass;
        network[4][4] = g2 + g_bass;

        match invert_5(network) {
            Some(inverse) => {
                self.inverse = inverse;
                self.g1 = g1;
                self.g2 = g2;
                self.g3 = g3;
                self.slope = slope;
                self.designed = true;
            }
            None => self.designed = false,
        }
    }
}

impl Effect for ToneStack {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.designed {
            return;
        }
        let alpha = one_pole_block(SMOOTH_SECONDS, self.rate, block.len());
        self.gain = (f64::from(self.gain)
            + f64::from(self.target_gain - self.gain) * alpha) as f32;
        let level = f64::from(self.gain);
        // One control step per block: the pot positions are nonlinear in dB,
        // so moving them in bounded steps keeps the network stable.
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
            if !self.designed {
                return;
            }
        }

        let inverse = self.inverse;
        let (g1, g2, g3) = (self.g1, self.g2, self.g3);
        let slope = self.slope;
        for sample in block.iter_mut() {
            let input = f64::from(*sample);
            let (j1, j2, j3) = (self.history[0], self.history[1], self.history[2]);
            // The output node's right-hand side is zero (no source there), so
            // its inverse column is not needed in the per-sample product.
            let r0 = g1 * input - j1;
            let r2 = slope * input + j2 + j3;
            let r3 = -j3;
            let r4 = -j2;
            let v_t = inverse[0][0] * r0
                + inverse[0][2] * r2
                + inverse[0][3] * r3
                + inverse[0][4] * r4;
            let v_out = inverse[1][0] * r0
                + inverse[1][2] * r2
                + inverse[1][3] * r3
                + inverse[1][4] * r4;
            let v_b = inverse[2][0] * r0
                + inverse[2][2] * r2
                + inverse[2][3] * r3
                + inverse[2][4] * r4;
            let v_m = inverse[3][0] * r0
                + inverse[3][2] * r2
                + inverse[3][3] * r3
                + inverse[3][4] * r4;
            let v_bp = inverse[4][0] * r0
                + inverse[4][2] * r2
                + inverse[4][3] * r3
                + inverse[4][4] * r4;
            self.history[0] = 2.0 * g1 * (input - v_t) - j1;
            self.history[1] = 2.0 * g2 * (v_b - v_bp) - j2;
            self.history[2] = 2.0 * g3 * (v_b - v_m) - j3;
            *sample = (v_out * Self::MAKEUP * level) as f32;
        }
    }

    fn reset(&mut self) {
        self.current_db = self.target_db;
        self.gain = self.target_gain;
        self.history = [0.0; 3];
        self.design();
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

/// The ProCo RAT, built around the LM308 gain stage and its silicon diodes.
///
/// # The circuit
///
/// The RAT's `Distortion` pot is the feedback resistor of an LM308 non-inverting
/// stage, so the drive knob sets the stage's gain. The op-amp's 1 MHz gain-
/// bandwidth product then sets the closed-loop corner: at low drive the stage is
/// wide open, and at high drive its corner falls into the low kilohertz, which is
/// the RAT's slew-limited, mid-focused character. A pair of 1N914 silicon
/// diodes clip the stage to ground at about 0.7 V, hard enough to produce the
/// RAT's square-ish edge. After the clipper, the pedal's Filter control is a
/// first-order low-pass (a 4.7 kΩ pot into 0.022 µF), here fixed at a musical
/// mid setting because the contract's single control is `drive`.
///
/// # The approximation
///
/// The gain range (2..200), the op-amp's exact pole, and the diode knee are
/// chosen to reproduce the circuit's behaviour rather than its SPICE model;
/// the diode clip is a hard linear region with a short exponential shoulder, not
/// a full Shockley solve. The filter is two one-pole sections at 4 kHz instead
/// of one, both to approximate the RAT's dark top end and to keep the 4×
/// oversampler's decimation clean. The output is trimmed by `OUTPUT_LEVEL` so
/// the pedal sits at a usable level in the strip; the contract has no volume
/// knob.
#[derive(Debug)]
pub struct Distortion {
    rate: u32,
    target_amount: f32,
    amount: f32,
    /// The last high-passed input, for the 4× linear interpolation.
    previous: f32,
    /// The input coupling high-pass (one pole at `INPUT_HIGHPASS_HZ`).
    highpass: f32,
    highpass_alpha: f32,
    /// The LM308's output after its bandwidth pole and slew limit.
    op_amp: f32,
    slew: f32,
    slew_step: f32,
    /// The two post-clip low-pass sections.
    post: [f32; 2],
    post_alpha: f32,
}

impl Distortion {
    /// The LM308 stage's gain at drive 0 and at drive 100.
    const GAIN_MIN: f32 = 2.0;
    const GAIN_MAX: f32 = 200.0;
    /// The LM308's gain-bandwidth product, and its datasheet slew rate.
    const OPAMP_GBW_HZ: f32 = 1_000_000.0;
    const OPAMP_SLEW_V_PER_S: f32 = 0.3e6;
    /// The silicon diode's forward voltage and the short exponential shoulder.
    const DIODE_VF: f32 = 0.7;
    const DIODE_KNEE: f32 = 0.04;
    /// The RAT's Filter knob, fixed at a musical mid setting.
    const POST_HZ: f32 = 4_000.0;
    /// The strip's level trim; the contract has no RAT volume knob.
    const OUTPUT_LEVEL: f32 = 0.7;
    const INPUT_HIGHPASS_HZ: f32 = 10.0;

    /// `drive` is the web knob's 0..100 amount.
    pub fn new(drive: f32) -> Self {
        let amount = drive.clamp(0.0, 100.0);
        Distortion {
            rate: 48_000,
            target_amount: amount,
            amount,
            previous: 0.0,
            highpass: 0.0,
            highpass_alpha: 0.0,
            op_amp: 0.0,
            slew: 0.0,
            slew_step: 0.0,
            post: [0.0; 2],
            post_alpha: 0.0,
        }
    }

    /// Move the drive knob; the next blocks walk to it over 10 ms.
    pub fn set_drive(&mut self, drive: f32) {
        if drive.is_finite() {
            self.target_amount = drive.clamp(0.0, 100.0);
        }
    }

    /// The RAT's distortion pot is a variable feedback resistor, so the gain
    /// rises faster than the knob. The squared travel is a useful fit to the
    /// reverse-log pot and keeps the low half of the knob usable.
    fn gain(drive: f32) -> f32 {
        let travel = drive.clamp(0.0, 100.0) / 100.0;
        Self::GAIN_MIN + travel * travel * (Self::GAIN_MAX - Self::GAIN_MIN)
    }

    /// A silicon diode to ground: linear below its forward voltage, then a short
    /// exponential shoulder that clamps the stage instead of letting it grow.
    #[inline]
    fn diode_clip(x: f32) -> f32 {
        let magnitude = x.abs();
        if magnitude <= Self::DIODE_VF {
            x
        } else {
            x.signum()
                * (Self::DIODE_VF
                    + Self::DIODE_KNEE
                        * (1.0 - (-(magnitude - Self::DIODE_VF) / Self::DIODE_KNEE).exp()))
        }
    }
}

impl Effect for Distortion {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.amount = self.target_amount;
        self.previous = 0.0;
        self.highpass = 0.0;
        self.op_amp = 0.0;
        self.slew = 0.0;
        self.post = [0.0; 2];
        let rate = self.rate as f32;
        let oversampled = 4.0 * rate;
        let two_pi = 2.0 * PI as f32;
        self.highpass_alpha = 1.0 - (-two_pi * Self::INPUT_HIGHPASS_HZ / rate).exp();
        self.post_alpha = 1.0 - (-two_pi * Self::POST_HZ / oversampled).exp();
        self.slew_step = Self::OPAMP_SLEW_V_PER_S / oversampled;
    }

    fn process(&mut self, block: &mut [f32]) {
        const OVERSAMPLE: usize = 4;
        let blend = one_pole_block(0.01, self.rate, block.len()) as f32;
        self.amount += (self.target_amount - self.amount) * blend;
        let gain = Self::gain(self.amount);
        let rate = self.rate as f32;
        let oversampled = 4.0 * rate;
        // The LM308's closed-loop corner is its gain-bandwidth product divided
        // by the stage gain; above the oversampled Nyquist it is effectively
        // bypassed.
        let cutoff = (Self::OPAMP_GBW_HZ / gain).clamp(20.0, oversampled * 0.45);
        let op_alpha = 1.0 - (-2.0 * PI as f32 * cutoff / oversampled).exp();

        for sample in block.iter_mut() {
            let input = *sample;
            // The RAT's input coupling cap, and a little DC blocking.
            self.highpass += (input - self.highpass) * self.highpass_alpha;
            let highpassed = input - self.highpass;
            let mut shaped = highpassed;
            for step in 1..=OVERSAMPLE {
                let t = step as f32 / OVERSAMPLE as f32;
                let sub = self.previous + (highpassed - self.previous) * t;
                // LM308 stage: gain, slew limit, then its closed-loop pole.
                let amplified = sub * gain;
                let delta = (amplified - self.slew).clamp(-self.slew_step, self.slew_step);
                self.slew += delta;
                self.op_amp += (self.slew - self.op_amp) * op_alpha;
                // Diodes to ground, then the RAT's post-clip filter.
                let clipped = Self::diode_clip(self.op_amp);
                self.post[0] += (clipped - self.post[0]) * self.post_alpha;
                self.post[1] += (self.post[0] - self.post[1]) * self.post_alpha;
                shaped = self.post[1];
            }
            self.previous = highpassed;
            *sample = shaped * Self::OUTPUT_LEVEL;
        }
    }

    fn reset(&mut self) {
        self.previous = 0.0;
        self.amount = self.target_amount;
        self.highpass = 0.0;
        self.op_amp = 0.0;
        self.slew = 0.0;
        self.post = [0.0; 2];
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

/// A Boss DM-2-style analog delay: a bucket-brigade line with companding.
///
/// # The circuit
///
/// The DM-2 uses a bucket-brigade device (BBD) clocked at a variable rate, with
/// an NE570-style compandor around it: the input is compressed about 2:1 above a
/// threshold before the BBD, and expanded back after it, which keeps the noise
/// of the bucket line below the signal. The BBD also band-limits: its clock and
/// its sample-and-hold response make the repeats progressively darker, and a
/// low-pass in the feedback path turns each pass through the line into another
/// generation of that roll-off. The DM-2's actual time range is about 20–300 ms;
/// the contract keeps the existing 0..1.5 s range, so the model stretches the
/// clock and narrows the bandwidth as if it were a slower, longer BBD.
///
/// # The approximation
///
/// The compandor is a feed-forward envelope encoder (`sqrt(threshold / level)`
/// above the threshold) and a complementary expander on the delayed signal, both
/// with a 5 ms attack and an 80 ms release. The BBD is a delay line with an
/// anti-alias one-pole before it and a reconstruction one-pole after it; the same
/// output filter feeds the feedback path, so repeats darken. A tiny deterministic
/// clock-feedthrough noise is added in proportion to the signal, so a silent
/// input stays silent (the contract's tests require that) while a live line has
/// the BBD's texture. The dry path is immediate: the only latency is the delay
/// time itself, and the compander has no look-ahead.
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
    /// Input coupling high-pass (the compandor's input cap).
    input_highpass: f32,
    input_highpass_alpha: f32,
    /// Compandor detectors, on the input and on the delayed signal.
    input_env: f32,
    output_env: f32,
    attack: f32,
    release: f32,
    /// BBD anti-alias and reconstruction one-poles.
    input_lp: f32,
    output_lp: f32,
    /// A deterministic clock-feedthrough dither.
    noise: u32,
}

impl Delay {
    pub const DRY: f32 = 0.7;
    /// The line is long enough for four bars of 4/4 at 120 BPM: sixteen beats
    /// is 8.0 s, and the extra half second is the interpolator's headroom.
    pub const MAX_SECONDS: f32 = 8.5;
    /// The manual `time` knob still maps to 0..1.5 s (the browser's contract).
    /// A tempo-synced value may run to four bars, so the line accepts up to 8 s
    /// even though no slider reaches it.
    pub const MAX_TIME: f32 = 8.0;
    /// The `feedback` knob stops short of unity, so the line cannot run away.
    pub const MAX_FEEDBACK: f32 = 0.9;

    /// The compandor's threshold, attack and release. The NE570's external
    /// capacitor sets these; the values sit in the DM-2's audible range.
    const COMP_THRESHOLD: f32 = 0.03;
    const COMP_ATTACK_S: f32 = 0.005;
    const COMP_RELEASE_S: f32 = 0.080;
    const MAX_EXPANDER: f32 = 12.0;
    const MIN_ENCODER: f32 = 0.02;
    /// The BBD's widest bandwidth (at the shortest delay) and the reference
    /// delay that reaches it. The clock's bandwidth falls as the square root of
    /// the delay time, as a BBD's does when it is clocked more slowly.
    const BBD_BW_HZ: f32 = 8_000.0;
    const BBD_REF_SECONDS: f32 = 0.02;
    const BBD_MIN_HZ: f32 = 700.0;
    const INPUT_HIGHPASS_HZ: f32 = 20.0;
    const CLOCK_NOISE: f32 = 1e-4;
    const NOISE_SEED: u32 = 0x9E37_79B9;

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
            input_highpass: 0.0,
            input_highpass_alpha: 0.0,
            input_env: 0.0,
            output_env: 0.0,
            attack: 0.0,
            release: 0.0,
            input_lp: 0.0,
            output_lp: 0.0,
            noise: Self::NOISE_SEED,
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

    /// The BBD's bandwidth at the current clock. The DM-2's clock runs faster at
    /// short delays; the square-root law is the band-limiting that makes long
    /// repeats dark and short ones brighter.
    fn bandwidth_hz(time_seconds: f32) -> f32 {
        let time = time_seconds.max(0.001);
        (Self::BBD_BW_HZ * (Self::BBD_REF_SECONDS / time).sqrt())
            .clamp(Self::BBD_MIN_HZ, Self::BBD_BW_HZ)
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
        self.attack = one_pole(Self::COMP_ATTACK_S, self.rate) as f32;
        self.release = one_pole(Self::COMP_RELEASE_S, self.rate) as f32;
        self.input_highpass_alpha = 1.0
            - (-2.0 * PI as f32 * Self::INPUT_HIGHPASS_HZ / self.rate as f32).exp();
        self.reset();
    }

    fn process(&mut self, block: &mut [f32]) {
        let length = self.buffer.len();
        if length < 4 {
            return;
        }
        let rate = self.rate.max(1) as f32;
        let reach = (length - 2) as f32;
        // The BBD bandwidth follows the smoothed delay time. A block-rate
        // coefficient is enough: the time moves through a 10 ms one-pole, so
        // the corner cannot step audibly at a block edge.
        let bbd = 1.0
            - (-2.0 * PI as f32 * Self::bandwidth_hz(self.time) / rate).exp();

        for sample in block.iter_mut() {
            self.time += (self.target_time - self.time) * self.smooth;
            self.feedback += (self.target_feedback - self.feedback) * self.smooth;
            self.wet += (self.target_wet - self.wet) * self.smooth;

            let input = *sample;
            let dry = input * Self::DRY;

            // The compandor's input coupling cap, then its 2:1 compressor.
            self.input_highpass += (input - self.input_highpass) * self.input_highpass_alpha;
            let highpassed = input - self.input_highpass;
            let rectified = highpassed.abs();
            let detector = if rectified > self.input_env {
                self.attack
            } else {
                self.release
            };
            self.input_env += (rectified - self.input_env) * detector;
            let encoder = if self.input_env > Self::COMP_THRESHOLD {
                (Self::COMP_THRESHOLD / self.input_env)
                    .sqrt()
                    .max(Self::MIN_ENCODER)
            } else {
                1.0
            };
            let compressed = highpassed * encoder;

            // The BBD's input anti-alias filter; this is what is stored.
            self.input_lp += (compressed - self.input_lp) * bbd;
            let line_input = self.input_lp;

            let delay_samples = (self.time * rate).clamp(1.0, reach);
            let back = self.write as f32 - delay_samples;
            let base = back.floor();
            let fraction = back - base;
            let first = (base as isize).rem_euclid(length as isize) as usize;
            let second = (first + 1) % length;
            let delayed = self.buffer[first] * (1.0 - fraction) + self.buffer[second] * fraction;

            // The reconstruction filter is also the feedback low-pass: every
            // pass through the line darkens the next repeat.
            self.output_lp += (delayed - self.output_lp) * bbd;
            let bandlimited = self.output_lp;

            // The complementary expander, on the delayed compressed signal.
            let rectified = bandlimited.abs();
            let detector = if rectified > self.output_env {
                self.attack
            } else {
                self.release
            };
            self.output_env += (rectified - self.output_env) * detector;
            let expander = if self.output_env > Self::COMP_THRESHOLD {
                (self.output_env / Self::COMP_THRESHOLD).min(Self::MAX_EXPANDER)
            } else {
                1.0
            };
            let wet = bandlimited * expander;

            // Clock feedthrough, gated by the signal so silence stays silent.
            self.noise ^= self.noise << 13;
            self.noise ^= self.noise >> 17;
            self.noise ^= self.noise << 5;
            let white = (self.noise as f32 / u32::MAX as f32) * 2.0 - 1.0;
            let clock = white * Self::CLOCK_NOISE * (self.input_env + bandlimited.abs());

            *sample = dry + wet * self.wet;
            self.buffer[self.write] = line_input + clock + bandlimited * self.feedback;
            self.write += 1;
            if self.write == length {
                self.write = 0;
            }
        }
    }

    fn reset(&mut self) {
        self.buffer.fill(0.0);
        self.write = 0;
        self.time = self.target_time;
        self.feedback = self.target_feedback;
        self.wet = self.target_wet;
        self.input_highpass = 0.0;
        self.input_env = 0.0;
        self.output_env = 0.0;
        self.input_lp = 0.0;
        self.output_lp = 0.0;
        self.noise = Self::NOISE_SEED;
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

/// The MXR Dyna Comp: an OTA compressor with the pedal's level-dependent squash.
///
/// # The circuit
///
/// The Dyna Comp is a CA3080 operational transconductance amplifier whose gain is
/// set by a full-wave detector, followed by a fixed output stage. Its attack is
/// fast and its release is slow (roughly 5 ms and 150 ms around the unit's
/// capacitor values). The OTA's control current is linear in the detector's
/// output, so the gain reduction grows faster at high levels than a fixed-ratio
/// compressor's — that level-dependent extra slope is the Dyna Comp's "squash",
/// and it is why the pedal breathes and pumps rather than limiting cleanly. The
/// real pedal has only Output and Sensitivity; it has no ratio, knee or mix.
///
/// # The approximation
///
/// The contract exposes six controls, so the circuit's fixed values are mapped
/// onto them rather than ignored: `thresh` is the detector threshold, `attack`
/// and `release` move the detector around the unit's ~5 ms / ~150 ms values,
/// `ratio` sets the OTA's base slope, `knee` its soft turn-on, and `mix` is a
/// parallel blend. The squash adds up to 0.25 dB of reduction per dB over the
/// chosen ratio at 24 dB over threshold, capped at 60 dB. The output stage is a
/// `tanh`, the OTA's finite output swing. The detector is a full-wave rectifier
/// with the attack/release one-pole, not the exact NE570 RC.
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
    /// The OTA's extra slope, in dB of reduction per dB over threshold at
    /// `SQUASH_REFERENCE_DB` past the knee. This is the circuit's squash.
    const SQUASH: f32 = 0.25;
    const SQUASH_REFERENCE_DB: f32 = 24.0;
    /// The OTA can only turn off so far; beyond this the output would vanish.
    const MAX_REDUCTION_DB: f32 = 60.0;

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
        let base_slope = 1.0 - 1.0 / ratio;

        for sample in block.iter_mut() {
            self.mix += (self.target_mix - self.mix) * self.smooth;
            let x = *sample;
            // Full-wave rectifier: the detector sees |x|, and the attack and
            // release smooth its gain reduction.
            let level_db = 20.0 * x.abs().max(1e-9).log10();
            let over = level_db - self.threshold_db;
            // The OTA's control is linear in the detector current, so the slope
            // itself grows with the overdrive. That is the Dyna Comp's squash.
            let slope = base_slope
                + Self::SQUASH * (over.max(0.0) / Self::SQUASH_REFERENCE_DB);
            let target = if over <= -half_knee {
                0.0
            } else if over >= half_knee {
                (over * slope).min(Self::MAX_REDUCTION_DB)
            } else {
                // Quadratic knee: continuous with both linear regions.
                let t = over + half_knee;
                (slope * t * t / (2.0 * knee.max(1e-9))).min(Self::MAX_REDUCTION_DB)
            };
            let coefficient = if target > self.reduction_db {
                attack
            } else {
                release
            };
            self.reduction_db += (target - self.reduction_db) * coefficient;
            let gain = 10f32.powf(-self.reduction_db / 20.0);
            // The OTA's finite output swing; the dry side of a parallel mix is
            // not saturated.
            let wet = (x * gain).tanh();
            *sample = x * (1.0 - self.mix) + wet * self.mix;
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
/// Most `master_` names (`master_comp`, `master_reverb`, `master_maximizer`,
/// `master_limiter`) parse to the same implementations as their channel
/// counterparts: the prefix says where the insert belongs, not what it does.
/// `master_eq` is the exception: the master rack's ten-band graphic equaliser
/// is its own [`GraphicEq`], because a mastering EQ has a band per octave where
/// the channel pedal has three broad tone knobs. [`Mixer](crate::mixer::Mixer)
/// owns the master rack that uses them; this enum only selects the
/// implementation.
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
///
/// `stereo_panner` is browser-only for the same reason: a true panner places a
/// mono source across an L/R pair, and this chain hands the pair only to the
/// channel's own static pan after the inserts. A mono pass-through would not
/// pan anything, so `parse` refuses the name and a native take omits it.
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
    MasterEq,
    Maximizer,
    Tremolo,
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
            "equalizer" => Some(InsertKind::Equalizer),
            "master_eq" => Some(InsertKind::MasterEq),
            "maximizer" | "master_maximizer" => Some(InsertKind::Maximizer),
            "tremolo" => Some(InsertKind::Tremolo),
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
            InsertKind::MasterEq => "master_eq",
            InsertKind::Maximizer => "maximizer",
            InsertKind::Tremolo => "tremolo",
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
            InsertKind::MasterEq => GraphicEq::CONTROLS,
            InsertKind::Maximizer => &["ceiling", "loudness"],
            // `sync` is a tempo division held by the page, not an engine knob.
            InsertKind::Tremolo => &["rate", "depth", "shape"],
        }
    }

    /// The master rack's prefix for an implementation, for the five effects the
    /// rack holds. `None` for an effect the rack does not build.
    pub const fn master_prefix(self) -> Option<&'static str> {
        match self {
            InsertKind::Compressor => Some("master_comp"),
            InsertKind::MasterEq => Some("master_eq"),
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
            // The master EQ's first three faders were three knobs; a song saved
            // then still names them Low/Mid/High, so they land on the same
            // 125 Hz / 1 kHz / 8 kHz bands the pedal moved.
            (InsertKind::MasterEq, "low") => "b125",
            (InsertKind::MasterEq, "mid") => "b1k",
            (InsertKind::MasterEq, "high") => "b8k",
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
    /// Everything else already is its natural unit (dB, Hz, 0..1, an index) —
    /// including the master EQ's ten bands, which arrive in dB.
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
            InsertKind::MasterEq => 13,
            InsertKind::Tremolo => 14,
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
            13 => InsertKind::MasterEq,
            14 => InsertKind::Tremolo,
            _ => return None,
        })
    }

    /// Build the pedal at its defaults: the tone stack at noon (0 dB on each
    /// knob, which is the passive stack's scooped centre, not a wire), the RAT
    /// at drive 50, the DM-2 at 0.525 s / 0.27 / 0.4, the Dyna Comp at −25 dB /
    /// 6:1 / 5 ms attack / 150 ms release / 6 dB knee / 0.5 mix, and `reverb2`
    /// at mix 35 / volume 35. The new pedals start where the browser's pedals
    /// start: flanger 1.05 Hz / 0.6 depth / 0.225 feedback / 0.5 mix, fuzz
    /// 0.65 gain / 0.45 tone / 0.6 level, amp 0.5 gain (0 dB) / flat tone /
    /// Combo 1x12, limiter −3 dBFS / 0.2 s, autotune 0.4 speed / full amount /
    /// C major, equalizer flat, maximizer −0.8 dBFS / 0.2 loudness, the master
    /// rack's graphic EQ flat on all ten bands, and tremolo 5 Hz / 0.5 depth /
    /// sine.
    pub fn build(self) -> Box<dyn Effect> {
        match self {
            InsertKind::Tone => Box::new(ToneStack::new(0.0, 0.0, 0.0)),
            InsertKind::Distortion => Box::new(Distortion::new(50.0)),
            InsertKind::Delay => Box::new(Delay::new(0.525, 0.27, 0.4)),
            InsertKind::Compressor => {
                Box::new(Compressor::new(-25.0, 6.0, 0.005, 0.15, 6.0, 0.5))
            }
            InsertKind::Reverb => Box::new(Reverb::new()),
            InsertKind::Flanger => Box::new(Flanger::new(1.05, 0.6, 0.225, 0.5)),
            InsertKind::Fuzz => Box::new(Fuzz::new(0.65, 0.45, 0.6)),
            InsertKind::Amp => Box::new(Amp::new(0.5, 0.0, 0.0, 0.0, 0)),
            InsertKind::Limiter => Box::new(Limiter::new(-3.0, 0.2)),
            InsertKind::Autotune => Box::new(Autotune::new(0.4, 1.0, 0, 0)),
            InsertKind::Equalizer => Box::new(Equalizer::new(0.0, 0.0, 0.0)),
            InsertKind::Maximizer => Box::new(Maximizer::new(-0.8, 0.2)),
            InsertKind::MasterEq => Box::new(GraphicEq::new()),
            InsertKind::Tremolo => Box::new(Tremolo::new(5.0, 0.5, 0)),
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

/// A bare insert chain, with no strip around it.
///
/// A Studio channel runs `trim -> inserts -> pan`; a patchbay source has its
/// own gain and its routes already carry the pan, so it needs only the middle
/// stage. This is the same [`InsertSlot`] list a [`Channel`] owns, exposed so a
/// source's inserts are built, prepared and driven by exactly the code a take's
/// inserts use.
pub struct EffectChain {
    inserts: Vec<InsertSlot>,
    /// The largest block [`process`](EffectChain::process) will accept. Set by
    /// [`prepare`](EffectChain::prepare), so a longer block is refused rather
    /// than reallocating on the audio thread.
    max_frames: usize,
}

impl EffectChain {
    pub fn new() -> Self {
        EffectChain {
            inserts: Vec::new(),
            max_frames: 0,
        }
    }

    /// Add one insert at the end of the chain.
    pub fn push(&mut self, kind: InsertKind) {
        self.push_effect(kind.build());
    }

    /// Add an already-built effect, for a caller that owns it (a take's
    /// [`Channel`] and a test's double).
    pub fn push_effect(&mut self, effect: Box<dyn Effect>) {
        self.inserts.push(InsertSlot {
            effect,
            bypassed: false,
        });
    }

    /// Add one insert in the position it was declared in, optionally bypassed.
    /// A source plan can carry two pedals of the same kind with different
    /// footswitches, so the flag belongs to the slot rather than to a later
    /// `bypass` by name.
    pub fn push_bypassed(&mut self, kind: InsertKind, bypassed: bool) {
        self.inserts.push(InsertSlot {
            effect: kind.build(),
            bypassed,
        });
    }

    /// Add one insert with the controls a plan declared, in its own slot. The
    /// controls are applied before the chain is prepared, so an effect starts
    /// at the declared value rather than at its web default; this is also the
    /// only way to configure two inserts of the same kind differently, because
    /// [`set_insert`](EffectChain::set_insert) addresses the first by name.
    pub fn push_configured(
        &mut self,
        kind: InsertKind,
        bypassed: bool,
        controls: &[(String, f32)],
    ) {
        let mut effect = kind.build();
        for (control, value) in controls {
            effect.set(control, kind.native_value(control, *value));
        }
        self.inserts.push(InsertSlot { effect, bypassed });
    }

    /// Move one insert's knob by the effect's own prefix.
    pub fn set_insert(&mut self, prefix: &str, knob: &str, value: f32) -> bool {
        for slot in &mut self.inserts {
            if slot.effect.name() == prefix {
                return slot.effect.set(knob, value);
            }
        }
        false
    }

    /// Bypass or restore the first insert whose [`name`](Effect::name) is
    /// `prefix`. Returns false when no such insert is in the chain.
    pub fn bypass(&mut self, prefix: &str, bypassed: bool) -> bool {
        for slot in &mut self.inserts {
            if slot.effect.name() == prefix {
                slot.bypassed = bypassed;
                return true;
            }
        }
        false
    }

    /// Size every insert. Allocation happens here and nowhere else.
    pub fn prepare(&mut self, rate: u32, max_frames: usize) {
        self.max_frames = max_frames;
        for slot in &mut self.inserts {
            slot.effect.prepare(rate, max_frames);
        }
    }

    /// Run the chain in place. A block longer than the prepared one is an
    /// error, never a reallocation.
    pub fn process(&mut self, block: &mut [f32]) -> Result<(), GraphError> {
        if block.len() > self.max_frames {
            return Err(GraphError::BlockTooLong {
                max_frames: self.max_frames,
                found: block.len(),
            });
        }
        for slot in &mut self.inserts {
            if !slot.bypassed {
                slot.effect.process(block);
            }
        }
        Ok(())
    }

    pub fn reset(&mut self) {
        for slot in &mut self.inserts {
            slot.effect.reset();
        }
    }

    /// The chain order, for a status line: `tone,distortion`. Bypassed inserts
    /// are still in the rack, so they are still named.
    pub fn insert_names(&self) -> String {
        self.inserts
            .iter()
            .map(|slot| slot.effect.name())
            .collect::<Vec<&str>>()
            .join(",")
    }
}

impl Default for EffectChain {
    fn default() -> Self {
        Self::new()
    }
}

impl std::fmt::Debug for EffectChain {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("EffectChain")
            .field("inserts", &self.insert_names())
            .field("max_frames", &self.max_frames)
            .finish()
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
    chain: EffectChain,
    scratch: Vec<f32>,
}

impl Channel {
    /// The `gain` knob stops at +12 dB, a recording trim rather than a fader.
    pub const MAX_GAIN: f32 = 4.0;

    pub fn new(gain: f32, pan: f32) -> Self {
        Channel {
            strip: Strip::new(gain, pan),
            chain: EffectChain::new(),
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
        self.chain.set_insert(prefix, knob, value)
    }

    /// Add one insert at the end of the chain.
    pub fn push(&mut self, effect: Box<dyn Effect>) {
        self.chain.push_effect(effect);
    }

    /// Bypass or restore the first insert whose [`name`](Effect::name) is
    /// `prefix`. The insert stays in the chain and keeps its controls; a
    /// bypassed insert is simply not run. Returns false when no such insert is
    /// in the rack.
    pub fn bypass(&mut self, prefix: &str, bypassed: bool) -> bool {
        self.chain.bypass(prefix, bypassed)
    }

    /// Size the scratch buffer and every insert. Allocation happens here and
    /// nowhere else.
    pub fn prepare(&mut self, rate: u32, max_frames: usize) {
        self.scratch = vec![0.0; max_frames];
        self.chain.prepare(rate, max_frames);
    }

    /// Run the trim and the insert chain over one mono block, in place, and
    /// stop before the pan. This is the tap a channel send takes: the
    /// destination's strip receives what the source's pedals made, and the
    /// destination's own pan places it, exactly as the page's send leaves a
    /// channel before its `playPan`. Longer than the prepared block is an
    /// error, never a reallocation.
    pub fn process_mono(&mut self, block: &mut [f32]) -> Result<(), GraphError> {
        let max_frames = self.scratch.len();
        if block.len() > max_frames {
            return Err(GraphError::BlockTooLong {
                max_frames,
                found: block.len(),
            });
        }
        let gain = self.strip.gain.get();
        for sample in block.iter_mut() {
            *sample *= gain;
        }
        self.chain.process(block)
    }

    /// Place one prepared mono block with the channel's equal-power pan.
    /// `stereo` is overwritten and must be twice the block's length.
    pub fn pan_into(&self, mono: &[f32], stereo: &mut [f32]) -> Result<(), GraphError> {
        if stereo.len() != mono.len() * 2 {
            return Err(GraphError::BadBlock {
                expected: mono.len() * 2,
                found: stereo.len(),
            });
        }
        let (left, right) = pan_coefficients(self.strip.pan.get());
        stereo.fill(0.0);
        mix_mono_into_stereo_with_gains(stereo, mono, left, right)
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
        self.scratch[..input.len()].copy_from_slice(input);
        let frames = input.len();
        let gain = self.strip.gain.get();
        for sample in self.scratch[..frames].iter_mut() {
            *sample *= gain;
        }
        self.chain
            .process(&mut self.scratch[..frames])
            .expect("a prepared channel block is never too long");
        // Gain was applied before the inserts; the output only needs the pan.
        self.pan_into(&self.scratch[..frames], stereo)
    }

    pub fn reset(&mut self) {
        self.chain.reset();
    }

    /// The chain order, for a take report: `tone,distortion`. Bypassed inserts
    /// are still in the rack, so they are still named.
    pub fn insert_names(&self) -> String {
        self.chain.insert_names()
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

    /// The steady-state gain a tone stack gives a quiet sine at `hz`, including
    /// the fixed makeup gain and the output trim.
    fn tone_gain(tone: &mut ToneStack, hz: f32, frames: usize) -> f32 {
        tone.prepare(RATE, frames);
        let input = sine(hz, 0.05, frames);
        let mut output = input.clone();
        tone.process(&mut output);
        rms(&output[frames / 2..]) / rms(&input[frames / 2..])
    }

    /// The total harmonic distortion of the RAT for a 220 Hz, 0.1 sine. The
    /// final 4800 samples are exactly 22 cycles, so a single-bin DFT recovers
    /// the fundamental without a window.
    fn rat_thd(drive: f32) -> f32 {
        const FRAMES: usize = 16_384;
        const MEASURE: usize = 4_800;
        let mut rat = Distortion::new(drive);
        rat.prepare(RATE, FRAMES);
        let mut output = sine(220.0, 0.1, FRAMES);
        rat.process(&mut output);
        let start = FRAMES - MEASURE;
        let segment = &output[start..];
        let mean = segment.iter().sum::<f32>() / MEASURE as f32;
        let mut sin_sum = 0.0f64;
        let mut cos_sum = 0.0f64;
        let mut total = 0.0f64;
        for (offset, sample) in segment.iter().enumerate() {
            let value = f64::from(sample - mean);
            let phase = 2.0 * std::f64::consts::PI * 220.0 * (start + offset) as f64
                / f64::from(RATE);
            sin_sum += value * phase.sin();
            cos_sum += value * phase.cos();
            total += value * value;
        }
        let fundamental = 2.0 * (sin_sum * sin_sum + cos_sum * cos_sum).sqrt() / MEASURE as f64;
        let total_power = total / MEASURE as f64;
        let residual = (total_power - fundamental * fundamental / 2.0).max(0.0);
        (residual.sqrt() / (fundamental / std::f64::consts::SQRT_2)) as f32
    }

    /// One DFT bin of `hz` over a window that is an integer number of cycles.
    fn dft_amplitude(block: &[f32], hz: f32, start: usize, len: usize) -> f32 {
        let mut sin_sum = 0.0f64;
        let mut cos_sum = 0.0f64;
        for offset in 0..len {
            let sample = f64::from(block[start + offset]);
            let phase = 2.0 * std::f64::consts::PI * f64::from(hz) * (start + offset) as f64
                / f64::from(RATE);
            sin_sum += sample * phase.sin();
            cos_sum += sample * phase.cos();
        }
        (2.0 * (sin_sum * sin_sum + cos_sum * cos_sum).sqrt() / len as f64) as f32
    }

    #[test]
    fn every_effect_turns_silence_into_silence() {
        let mut graphic = GraphicEq::new();
        for (band, control) in GraphicEq::CONTROLS.iter().enumerate() {
            assert!(graphic.set(control, if band % 2 == 0 { 9.0 } else { -9.0 }));
        }
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
            Box::new(Tremolo::new(8.0, 1.0, 2)),
            Box::new(graphic),
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
        let mut graphic = GraphicEq::new();
        for (band, control) in GraphicEq::CONTROLS.iter().enumerate() {
            assert!(graphic.set(control, if band % 2 == 0 { 12.0 } else { -12.0 }));
        }
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
            Box::new(Tremolo::new(20.0, 1.0, 2)),
            Box::new(graphic),
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
    fn the_tone_stack_moves_its_three_bands() {
        // The passive network is not a set of calibrated shelves; the knob's
        // travel is the pot's travel. These are the circuit's real extremes.
        let bass_boost = tone_gain(&mut ToneStack::new(12.0, 0.0, 0.0), 100.0, 16_384);
        let bass_cut = tone_gain(&mut ToneStack::new(-12.0, 0.0, 0.0), 100.0, 16_384);
        assert!(
            bass_boost > bass_cut * 1.2,
            "the bass pot did not move 100 Hz: {bass_boost} against {bass_cut}"
        );

        let treble_boost = tone_gain(&mut ToneStack::new(0.0, 0.0, 12.0), 8_000.0, 16_384);
        let treble_cut = tone_gain(&mut ToneStack::new(0.0, 0.0, -12.0), 8_000.0, 16_384);
        assert!(
            treble_boost > treble_cut * 2.5,
            "the treble pot did not move 8 kHz: {treble_boost} against {treble_cut}"
        );

        let mid_boost = tone_gain(&mut ToneStack::new(0.0, 12.0, 0.0), 1_000.0, 16_384);
        let mid_cut = tone_gain(&mut ToneStack::new(0.0, -12.0, 0.0), 1_000.0, 16_384);
        assert!(
            mid_boost > mid_cut * 2.0,
            "the mid pot did not move 1 kHz: {mid_boost} against {mid_cut}"
        );

        // Noon is the passive stack's scooped centre, made unity at 1 kHz by
        // the fixed makeup gain, not a wire.
        let noon = tone_gain(&mut ToneStack::new(0.0, 0.0, 0.0), 1_000.0, 16_384);
        assert!(
            (0.9..=1.1).contains(&noon),
            "the noon mid band was not unity: {noon}"
        );
    }

    #[test]
    fn the_tone_stack_controls_interact() {
        // In the FMV network the treble pot returns through the bass/mid
        // branches. Changing treble therefore changes the mid band, which no
        // independent three-shelf cascade can do.
        let treble_up = tone_gain(&mut ToneStack::new(0.0, 0.0, 12.0), 1_000.0, 16_384);
        let treble_down = tone_gain(&mut ToneStack::new(0.0, 0.0, -12.0), 1_000.0, 16_384);
        assert!(
            treble_up > treble_down * 1.3,
            "treble did not load the mid band: {treble_up} against {treble_down}"
        );

        // The mid pot is the ground return of the treble branch, so it moves
        // the top end as well as the middle.
        let mid_up = tone_gain(&mut ToneStack::new(0.0, 12.0, 0.0), 8_000.0, 16_384);
        let mid_down = tone_gain(&mut ToneStack::new(0.0, -12.0, 0.0), 8_000.0, 16_384);
        assert!(
            mid_up > mid_down * 1.3,
            "mid did not load the top band: {mid_up} against {mid_down}"
        );
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
    fn the_rat_hard_clips_and_filters() {
        // A hot sine at full drive is bounded and flat-topped: the diodes clamp
        // it, so its crest factor falls below a sine's 1.414.
        let mut rat = Distortion::new(100.0);
        rat.prepare(RATE, 16_384);
        let mut output = sine(220.0, 0.5, 16_384);
        rat.process(&mut output);
        let segment = &output[8192..];
        let peak = segment.iter().cloned().fold(0.0f32, f32::max);
        let crest = peak / rms(segment);
        assert!(peak < 0.8, "the RAT did not clamp the output: peak {peak}");
        assert!(
            crest < 1.35,
            "the clipped wave still looked like a sine: crest {crest}"
        );

        // At low drive the stage is clean, so the fixed post-clip filter is
        // visible: 6 kHz is well above the RAT's corner, 500 Hz is not.
        let low = {
            let mut rat = Distortion::new(0.0);
            rat.prepare(RATE, 16_384);
            let input = sine(500.0, 0.02, 16_384);
            let mut output = input.clone();
            rat.process(&mut output);
            rms(&output[8192..]) / rms(&input[8192..])
        };
        let high = {
            let mut rat = Distortion::new(0.0);
            rat.prepare(RATE, 16_384);
            let input = sine(6_000.0, 0.02, 16_384);
            let mut output = input.clone();
            rat.process(&mut output);
            rms(&output[8192..]) / rms(&input[8192..])
        };
        assert!(
            high < low * 0.5,
            "the RAT filter did not darken the top: 500 Hz {low}, 6 kHz {high}"
        );
    }

    #[test]
    fn the_rat_hard_clip_adds_harmonics() {
        let clean = rat_thd(5.0);
        let clipped = rat_thd(95.0);
        assert!(clean < 0.05, "low drive was already distorted: {clean}");
        assert!(
            clipped > 0.25,
            "high drive did not add harmonics: {clipped}"
        );
    }

    #[test]
    fn the_delay_echoes_at_its_time_and_not_before() {
        // 0.01 s at 48 kHz is exactly 480 samples. The DM-2's companding and
        // band-limiting shape the first echo, but they add no latency: the dry
        // sample is immediate and the wet path begins exactly at 480.
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
            block[480].abs() > 0.1,
            "the echo at 480 was only {}",
            block[480]
        );
    }

    fn delay_wet_ratio(amplitude: f32) -> f32 {
        // The dry path is identical with vol 0 and vol 1, so subtracting the
        // output powers isolates the wet path. 997 Hz over 0.0523 s is not an
        // integer number of cycles, so the dry/wet cross term averages away.
        let input = sine(997.0, amplitude, 48_000);
        let input_rms = rms(&input[24_000..]);

        let mut dry_only = Delay::new(0.0523, 0.0, 0.0);
        dry_only.prepare(RATE, 48_000);
        let mut dry_block = input.clone();
        dry_only.process(&mut dry_block);
        let dry_power = rms(&dry_block[24_000..]).powi(2);

        let mut wet = Delay::new(0.0523, 0.0, 1.0);
        wet.prepare(RATE, 48_000);
        let mut wet_block = input;
        wet.process(&mut wet_block);
        let wet_power = rms(&wet_block[24_000..]).powi(2);

        (wet_power - dry_power).max(0.0).sqrt() / input_rms
    }

    #[test]
    fn the_dm2_compander_keeps_the_wet_level() {
        // The NE570 compressor attenuates a loud input before the line and the
        // expander restores it after; a quiet and a loud sine should therefore
        // come back at about the same wet level, not 26 dB apart.
        let quiet = delay_wet_ratio(0.02);
        let loud = delay_wet_ratio(0.4);
        assert!(
            (0.5..=1.5).contains(&quiet),
            "the quiet wet level was {quiet}"
        );
        assert!(
            (0.5..=1.5).contains(&loud),
            "the loud wet level was {loud}"
        );
        assert!(
            (quiet - loud).abs() < 0.35,
            "companding did not track the level: quiet {quiet}, loud {loud}"
        );
    }

    #[test]
    fn the_dm2_repeats_darken() {
        const FRAMES: usize = 48_000;
        const BURST: usize = 1_920; // 40 ms
        const WINDOW: usize = 1_920; // 40 ms: 20 cycles at 500 Hz, 240 at 6 kHz
        let mut delay = Delay::new(0.05, 0.8, 1.0);
        delay.prepare(RATE, FRAMES);
        let mut block = vec![0.0f32; FRAMES];
        for (index, sample) in block.iter_mut().take(BURST).enumerate() {
            let t = index as f32 / RATE as f32;
            *sample = 0.05 * (std::f32::consts::TAU * 500.0 * t).sin()
                + 0.05 * (std::f32::consts::TAU * 6_000.0 * t).sin();
        }
        delay.process(&mut block);

        let first = (0.05 * RATE as f32) as usize + 100;
        let second = (0.10 * RATE as f32) as usize + 100;
        let low_first = dft_amplitude(&block, 500.0, first, WINDOW);
        let high_first = dft_amplitude(&block, 6_000.0, first, WINDOW);
        let low_second = dft_amplitude(&block, 500.0, second, WINDOW);
        let high_second = dft_amplitude(&block, 6_000.0, second, WINDOW);

        let first_ratio = high_first / low_first.max(1e-9);
        let second_ratio = high_second / low_second.max(1e-9);
        assert!(
            second_ratio < first_ratio * 0.8,
            "the second repeat did not darken: {first_ratio} then {second_ratio}"
        );
        assert!(
            low_second < low_first * 0.9,
            "feedback did not decay the second repeat: {low_first} then {low_second}"
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

    #[test]
    fn the_dyna_comp_squashes_with_level() {
        // The OTA's gain control is linear in the detector, so the reduction
        // grows faster than a fixed ratio. A 6 dB louder sine should not come
        // out 6 dB louder; at this setting it is actually quieter (the squash).
        let mut gentle = Compressor::new(-30.0, 12.0, 0.005, 0.15, 6.0, 1.0);
        gentle.prepare(RATE, 16_384);
        let mut quiet = sine(220.0, 0.4, 16_384);
        gentle.process(&mut quiet);
        let quiet_rms = rms(&quiet[8192..]);

        let mut squash = Compressor::new(-30.0, 12.0, 0.005, 0.15, 6.0, 1.0);
        squash.prepare(RATE, 16_384);
        let mut loud = sine(220.0, 0.8, 16_384);
        squash.process(&mut loud);
        let loud_rms = rms(&loud[8192..]);

        assert!(
            loud_rms < quiet_rms * 1.05,
            "the Dyna Comp did not squash: 0.4 -> {quiet_rms}, 0.8 -> {loud_rms}"
        );

        // Below threshold the detector is off and the output passes untouched.
        let mut clean = Compressor::new(-30.0, 12.0, 0.005, 0.15, 6.0, 1.0);
        clean.prepare(RATE, 16_384);
        let input = sine(220.0, 0.02, 16_384);
        let mut passed = input.clone();
        clean.process(&mut passed);
        let ratio = rms(&passed[8192..]) / rms(&input[8192..]);
        assert!(
            (ratio - 1.0).abs() < 0.02,
            "a below-threshold sine was changed: {ratio}"
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
            ("tremolo", InsertKind::Tremolo),
        ] {
            assert_eq!(InsertKind::parse(word), Some(kind));
            assert_eq!(kind.name(), word);
        }
        // The web calls it `reverb2`; the report uses the engine's name.
        assert_eq!(InsertKind::parse("reverb2"), Some(InsertKind::Reverb));
        assert_eq!(InsertKind::Reverb.name(), "reverb");
        // The master prefix selects the same implementation; placement is the
        // caller's business, so the canonical name has no prefix. The master EQ
        // is the exception: it is a ten-band GraphicEq, not the channel pedal.
        for (word, kind) in [
            ("master_comp", InsertKind::Compressor),
            ("master_eq", InsertKind::MasterEq),
            ("master_reverb", InsertKind::Reverb),
            ("master_maximizer", InsertKind::Maximizer),
            ("master_limiter", InsertKind::Limiter),
        ] {
            assert_eq!(InsertKind::parse(word), Some(kind), "{word}");
        }
        assert_eq!(InsertKind::Maximizer.name(), "maximizer");
        assert_eq!(InsertKind::MasterEq.name(), "master_eq");
        assert_eq!(InsertKind::MasterEq.master_prefix(), Some("master_eq"));
        assert_eq!(
            InsertKind::Equalizer.master_prefix(),
            None,
            "the channel equalizer is not the master EQ"
        );
        // The ten faders, and the three old master-EQ knob names as aliases.
        assert_eq!(InsertKind::MasterEq.controls(), GraphicEq::CONTROLS);
        assert_eq!(InsertKind::MasterEq.controls().len(), 10);
        assert_eq!(InsertKind::MasterEq.control_index("b32"), Some(0));
        assert_eq!(InsertKind::MasterEq.control_index("b16k"), Some(9));
        assert_eq!(InsertKind::MasterEq.control_index("low"), Some(2));
        assert_eq!(InsertKind::MasterEq.control_index("mid"), Some(5));
        assert_eq!(InsertKind::MasterEq.control_index("high"), Some(8));
        assert_eq!(InsertKind::MasterEq.control_index("bass"), None);
        // The wire unit is dB, unchanged by native_value.
        assert_eq!(InsertKind::MasterEq.native_value("b2k", 6.0), 6.0);
        assert_eq!(InsertKind::MasterEq.code(), 13);
        assert_eq!(InsertKind::from_code(13), Some(InsertKind::MasterEq));
        assert_eq!(InsertKind::MasterEq.build().name(), "master_eq");
        assert_eq!(InsertKind::Tremolo.code(), 14);
        assert_eq!(InsertKind::from_code(14), Some(InsertKind::Tremolo));
        // Stereo Widener is browser only: the insert chain is mono, so there
        // is no kind to build and a native take omits the pedal (see
        // `InsertKind`). Both the track and the rack spelling are refused.
        assert_eq!(InsertKind::parse("stereowidener"), None);
        assert_eq!(InsertKind::parse("master_stereowidener"), None);
        // Stereo Panner is browser only for the same reason.
        assert_eq!(InsertKind::parse("stereo_panner"), None);
        assert_eq!(InsertKind::parse("banana"), None);
    }

    #[test]
    fn the_delay_line_reaches_four_bars() {
        // Four bars of 4/4 at 120 BPM is 16 beats, 8.0 s. The line is 8.5 s so
        // the interpolator's top tap is never the write head itself.
        let mut delay = Delay::new(0.0, 0.0, 1.0);
        delay.prepare(RATE, 1);
        assert!(delay.buffer.len() >= (RATE as f32 * 8.5) as usize);
        assert!(delay.set("time", 8.0));
        assert_eq!(delay.target_time, 8.0);
        assert!(delay.set("time", 9.0));
        assert_eq!(delay.target_time, Delay::MAX_TIME);
    }

    #[test]
    fn a_channel_taps_after_the_inserts_and_before_the_pan() {
        let mut channel = Channel::new(0.5, 1.0);
        channel.prepare(RATE, 4);
        let mut mono = [0.5f32, -0.5, 0.25, 0.0];
        channel.process_mono(&mut mono).expect("mono tap");
        // Trim is applied; the pan has not been.
        assert_eq!(mono, [0.25, -0.25, 0.125, 0.0]);
        let mut stereo = [9.0f32; 8];
        channel.pan_into(&mono, &mut stereo).expect("pan");
        // Hard right: the prepared block lands in the right speaker only.
        for frame in 0..4 {
            assert!(stereo[frame * 2].abs() < 1e-6);
            assert!((stereo[frame * 2 + 1] - mono[frame]).abs() < 1e-6);
        }
    }

    #[test]
    fn a_mono_tap_refuses_a_block_longer_than_prepared() {
        let mut channel = Channel::new(1.0, 0.0);
        channel.prepare(RATE, 2);
        assert_eq!(
            channel.process_mono(&mut [0.0f32; 3]),
            Err(GraphError::BlockTooLong {
                max_frames: 2,
                found: 3,
            })
        );
    }
}
