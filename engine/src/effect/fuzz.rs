//! The `fuzz` pedal: a germanium two-transistor fuzz, after the JH-2.
//!
//! The JH-2 is a Fuzz Face-derived circuit. Its first stage is a common-emitter
//! NPN (Q1) biased by a 180 kΩ resistor and a 68 kΩ feedback resistor from Q2's
//! emitter; its second stage (Q2) drives a 10 kΩ collector load and a 1 kΩ
//! "fuzz" pot in the emitter, bypassed by 22 µF. The 2.2 µF input cap and the
//! 0.01 µF output cap set the low end, the 47 pF cap across the feedback
//! resistor sets the top, and a 9.1 V zener holds the supply. The published
//! schematic uses MPSA18 silicon devices; this model uses germanium transistor
//! parameters (low hFE, a soft, low knee and leakage-style reverse current),
//! because that is the voice the pedal is bought for.
//!
//! # The model
//!
//! The signal path is a static transfer curve solved from the circuit's own
//! direct-current equations, plus the coupling and tone filters around it:
//!
//! 1. [`Fuzz::solve`] runs a damped Newton iteration on the four circuit nodes
//!    (Q1 base, Q1 collector, Q2 emitter, Q2 collector) with Ebers-Moll
//!    transistors and the schematic's resistors. The result is the quiescent
//!    collector voltage for a given input voltage.
//! 2. `prepare` solves that curve once and stores it; `process` reads it with
//!    linear interpolation. The table is the only allocation, and it happens in
//!    `prepare`. The fuzz pot is the AC drive in `process`, not a second curve:
//!    the DC bias sees the whole 1 kΩ pot through the 22 µF bypass, and only
//!    the signal sees the bypassed part.
//! 3. The input highpass is the 2.2 µF coupling cap, the output highpass is the
//!    0.01 µF cap, and the tone lowpass moves the feedback cap's corner — the
//!    JH-2 has no tone knob, so `tone` is the feedback-cap mod, from dark to
//!    open. This is stated here rather than hidden: the pedal's two real knobs
//!    are Fuzz and Level.
//!
//! The curve is asymmetric between its positive and negative halves, and it
//! softens as the fuzz pot is turned down, which is the cleanup the circuit is
//! known for. It is a quasi-static model: the 22 µF bypass cap's 7 Hz corner
//! and the coupling caps are modelled as filters, not as extra solved nodes, and
//! neither the transistor's charge storage nor the zener's noise is modelled.
//! The approximation is deliberately honest about that.

use super::{lowpass, one_pole, Biquad, Effect};

/// The published supply: a 9 V battery behind a 470 Ω resistor and a 1N5239B
/// 9.1 V zener.
const VCC: f64 = 9.1;
/// Thermal voltage at room temperature.
const V_T: f64 = 0.025_852;
/// Germanium saturation current: low enough for a 0.2–0.3 V knee.
const IS: f64 = 2.0e-8;
/// Germanium ideality: a softer knee than silicon's 1.0.
const N: f64 = 1.45;
/// Germanium forward current gain.
const BETA_F: f64 = 75.0;
/// Germanium reverse current gain.
const BETA_R: f64 = 2.5;
const RC1: f64 = 43_000.0;
const RC2: f64 = 10_000.0;
const RFB: f64 = 68_000.0;
const R_BIAS: f64 = 180_000.0;
const R_IN: f64 = 100.0;
const R_FUZZ: f64 = 1_000.0;
/// The input voltage a full-scale sample represents. A guitar pickup is well
/// under a volt; 0.6 V leaves the curve saturated at the top of the range.
const INPUT_VOLTS: f64 = 0.12;
/// Samples per curve. 2049 is odd so the middle point is exactly 0 V.
const POINTS: usize = 2_049;

/// The four unknown node voltages, in volts.
type Nodes = [f64; 4];

/// One Ebers-Moll transistor and its derivatives at a bias point.
struct Currents {
    ib: f64,
    ic: f64,
    ie: f64,
    dib_dvbe: f64,
    dib_dvbc: f64,
    dic_dvbe: f64,
    dic_dvbc: f64,
    die_dvbe: f64,
    die_dvbc: f64,
}

/// A germanium NPN: the transport equations with a soft knee.
#[derive(Clone, Copy)]
struct Transistor {
    is: f64,
    nvt: f64,
    beta_f: f64,
    beta_r: f64,
}

impl Transistor {
    const GERMANIUM: Transistor = Transistor {
        is: IS,
        nvt: N * V_T,
        beta_f: BETA_F,
        beta_r: BETA_R,
    };

    fn currents(&self, vb: f64, ve: f64, vc: f64) -> Currents {
        // The clamp only keeps `exp` finite; the solved nodes stay well inside
        // the rails. It is not part of the device model.
        let vbe = (vb - ve).clamp(-2.0, 0.95);
        let vbc = (vb - vc).clamp(-2.0, 0.95);
        let ef = (vbe / self.nvt).exp();
        let er = (vbc / self.nvt).exp();
        let forward = self.is * (ef - 1.0);
        let reverse = self.is * (er - 1.0);
        let ic = forward - reverse * (1.0 + 1.0 / self.beta_r);
        let ib = forward / self.beta_f + reverse / self.beta_r;
        let ie = ic + ib;
        Currents {
            ib,
            ic,
            ie,
            dib_dvbe: self.is * ef / (self.beta_f * self.nvt),
            dib_dvbc: self.is * er / (self.beta_r * self.nvt),
            dic_dvbe: self.is * ef / self.nvt,
            dic_dvbc: -self.is * er / self.nvt * (1.0 + 1.0 / self.beta_r),
            die_dvbe: self.is * ef / self.nvt * (1.0 + 1.0 / self.beta_f),
            die_dvbc: -self.is * er / self.nvt,
        }
    }
}

/// Gaussian elimination with partial pivoting on a 4×4 system.
fn solve4(mut a: [[f64; 4]; 4], mut b: [f64; 4]) -> Option<[f64; 4]> {
    for col in 0..4 {
        let mut pivot = col;
        for row in col + 1..4 {
            if a[row][col].abs() > a[pivot][col].abs() {
                pivot = row;
            }
        }
        if a[pivot][col].abs() < 1e-18 {
            return None;
        }
        if pivot != col {
            a.swap(col, pivot);
            b.swap(col, pivot);
        }
        let inverse = 1.0 / a[col][col];
        for row in col + 1..4 {
            let factor = a[row][col] * inverse;
            if factor != 0.0 {
                for c in col..4 {
                    a[row][c] -= factor * a[col][c];
                }
                b[row] -= factor * b[col];
            }
        }
    }
    let mut x = [0.0; 4];
    for row in (0..4).rev() {
        let mut sum = b[row];
        for col in row + 1..4 {
            sum -= a[row][col] * x[col];
        }
        x[row] = sum / a[row][row];
    }
    Some(x)
}

#[derive(Debug)]
pub struct Fuzz {
    rate: u32,
    target_gain: f32,
    fuzz: f32,
    target_tone: f32,
    tone: f32,
    target_level: f32,
    level: f32,
    curves: Vec<f32>,
    tone_filter: Biquad,
    tone_designed: f32,
    input_lp: f32,
    output_lp: f32,
    smooth: f32,
    input_alpha: f32,
    output_alpha: f32,
    prepared: bool,
}

impl Fuzz {
    pub const MIN_TONE_HZ: f32 = 800.0;
    pub const MAX_TONE_HZ: f32 = 8_000.0;

    pub fn new(gain: f32, tone: f32, level: f32) -> Self {
        let gain = gain.clamp(0.0, 1.0);
        let tone = tone.clamp(0.0, 1.0);
        let level = level.clamp(0.0, 1.0);
        Fuzz {
            rate: 48_000,
            target_gain: gain,
            fuzz: gain,
            target_tone: tone,
            tone,
            target_level: level,
            level,
            curves: Vec::new(),
            tone_filter: Biquad::identity(),
            tone_designed: -1.0,
            input_lp: 0.0,
            output_lp: 0.0,
            smooth: 0.0,
            input_alpha: 0.0,
            output_alpha: 0.0,
            prepared: false,
        }
    }

    fn cutoff(knob: f32) -> f32 {
        Self::MIN_TONE_HZ * 10f32.powf(knob.clamp(0.0, 1.0))
    }

    /// Solve the four circuit nodes for one input voltage and fuzz position.
    ///
    /// `guess` carries the previous solution in and the new one out, which is
    /// both faster and more stable than starting from a cold guess for every
    /// point on the curve. The return value is false only when the iteration
    /// leaves the finite numbers; the caller keeps the previous point then.
    fn solve(&self, vin: f64, re: f64, r_in: f64, offset: f64, guess: &mut Nodes) -> bool {
        let transistor = Transistor::GERMANIUM;
        let mut v = *guess;
        for _ in 0..40 {
            let q1 = transistor.currents(v[0], 0.0, v[1]);
            let q2 = transistor.currents(v[1], v[2], v[3]);
            let residual = [
                (vin + offset - v[0]) / r_in - v[0] / R_BIAS + (v[2] - v[0]) / RFB - q1.ib,
                (VCC - v[1]) / RC1 - q1.ic - q2.ib,
                q2.ie - v[2] / re,
                (VCC - v[3]) / RC2 - q2.ic,
            ];

            let mut j = [[0.0f64; 4]; 4];
            // Q1 base.
            j[0][0] = -1.0 / r_in - 1.0 / R_BIAS - 1.0 / RFB - q1.dib_dvbe - q1.dib_dvbc;
            j[0][1] = q1.dib_dvbc;
            j[0][2] = 1.0 / RFB;
            // Q1 collector / Q2 base.
            j[1][0] = -q1.dic_dvbe - q1.dic_dvbc;
            j[1][1] = -1.0 / RC1 + q1.dic_dvbc - q2.dib_dvbe - q2.dib_dvbc;
            j[1][2] = q2.dib_dvbe;
            j[1][3] = q2.dib_dvbc;
            // Q2 emitter.
            j[2][1] = q2.die_dvbe + q2.die_dvbc;
            j[2][2] = -q2.die_dvbe - 1.0 / re;
            j[2][3] = -q2.die_dvbc;
            // Q2 collector.
            j[3][1] = -q2.dic_dvbe - q2.dic_dvbc;
            j[3][2] = q2.dic_dvbe;
            j[3][3] = -1.0 / RC2 + q2.dic_dvbc;

            let Some(dx) = solve4(
                j,
                [-residual[0], -residual[1], -residual[2], -residual[3]],
            ) else {
                return false;
            };
            let mut largest = 0.0f64;
            for (node, step) in v.iter_mut().zip(dx) {
                // A damped step: the exponentials are steep, and an undamped
                // Newton step can jump past the physical operating point.
                let step = (0.5 * step).clamp(-0.25, 0.25);
                *node += step;
                largest = largest.max(step.abs());
            }
            v[0] = v[0].clamp(-2.0, VCC + 0.5);
            v[1] = v[1].clamp(0.0, VCC);
            v[2] = v[2].clamp(0.0, VCC);
            v[3] = v[3].clamp(0.0, VCC);
            if !v.iter().all(|node| node.is_finite()) {
                return false;
            }
            if largest < 1e-8 {
                break;
            }
        }
        *guess = v;
        true
    }

    fn build_curves(&mut self) {
        // The fuzz pot is the AC gain in `process`, so the static curve is the
        // same for every position. Solve it once and fill the table: `prepare`
        // runs per chain and must not spend nine times the work on nine copies.
        let mut raw = vec![0.0f64; POINTS];
        let mut bias: Nodes = [0.3, 0.8, 0.42, 4.9];
        let _ = self.solve(0.0, R_FUZZ, 1.0e12, 0.0, &mut bias);
        let offset = bias[0];
        let mut guess = bias;
        for point in 0..POINTS {
            let vin = -INPUT_VOLTS
                + 2.0 * INPUT_VOLTS * point as f64 / (POINTS - 1) as f64;
            if self.solve(vin, R_FUZZ, R_IN, offset, &mut guess) {
                raw[point] = guess[3];
            } else {
                raw[point] = if point > 0 { raw[point - 1] } else { 0.0 };
            }
        }
        let baseline = raw[POINTS / 2];
        let sign = if raw[POINTS - 1] >= raw[0] { 1.0 } else { -1.0 };
        let mut peak = 0.0f64;
        for &value in &raw {
            peak = peak.max(((value - baseline) * sign).abs());
        }
        let scale = if peak > 1e-9 { 1.0 / peak } else { 0.0 };
        let mut line = vec![0.0f32; POINTS];
        for point in 0..POINTS {
            let value = (raw[point] - baseline) * sign * scale;
            line[point] = value.clamp(-1.0, 1.0) as f32;
        }
        self.curves = line;
    }

    #[inline]
    fn table(&self, point: usize) -> f32 {
        self.curves[point]
    }

    /// Read the curve at `x`, already in −1..1, with linear interpolation.
    fn curve_at(&self, x: f32) -> f32 {
        if self.curves.len() < POINTS {
            return 0.0;
        }
        let point = (x.clamp(-1.0, 1.0) + 1.0) * 0.5 * (POINTS - 1) as f32;
        let left = (point.floor() as usize).min(POINTS - 1);
        let right = (left + 1).min(POINTS - 1);
        let t = point - left as f32;
        self.table(left) * (1.0 - t) + self.table(right) * t
    }
}

impl Effect for Fuzz {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.build_curves();
        self.fuzz = self.target_gain;
        self.tone = self.target_tone;
        self.level = self.target_level;
        self.tone_filter.set(lowpass(
            f64::from(self.rate),
            f64::from(Self::cutoff(self.tone)),
        ));
        self.tone_filter.reset();
        self.tone_designed = self.tone;
        self.input_lp = 0.0;
        self.output_lp = 0.0;
        self.smooth = one_pole(0.02, self.rate) as f32;
        // 2.2 µF into the transistor's input impedance: about 7 Hz.
        self.input_alpha = one_pole(1.0 / (2.0 * std::f32::consts::PI * 7.0), self.rate) as f32;
        // 0.01 µF into the 500 kΩ level pot: about 32 Hz.
        self.output_alpha = one_pole(1.0 / (2.0 * std::f32::consts::PI * 30.0), self.rate) as f32;
        self.prepared = true;
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared || block.is_empty() {
            return;
        }
        // The tone knob only re-designs its lowpass at a block edge.
        let alpha = super::one_pole_block(0.02, self.rate, block.len()) as f32;
        self.tone += (self.target_tone - self.tone) * alpha;
        if (self.tone - self.tone_designed).abs() > 1e-4 {
            self.tone_filter.set(lowpass(
                f64::from(self.rate.max(1)),
                f64::from(Self::cutoff(self.tone)),
            ));
            self.tone_designed = self.tone;
        }

        for sample in block.iter_mut() {
            self.fuzz += (self.target_gain - self.fuzz) * self.smooth;
            self.level += (self.target_level - self.level) * self.smooth;

            // The input coupling cap: remove the DC the source carries.
            self.input_lp += (*sample - self.input_lp) * self.input_alpha;
            let input = (*sample - self.input_lp).clamp(-1.0, 1.0);

            // The fuzz pot bypasses more of the emitter as it turns up: the
            // same curve, driven harder. The pot is also what makes a Fuzz Face
            // clean up when the guitar volume drops, so it is a gain, not a
            // second clipper.
            let drive = 1.0 + self.fuzz * 8.0;
            let shaped = self.curve_at((input * drive).clamp(-1.0, 1.0));

            // The output coupling cap, then the feedback-cap tone control.
            self.output_lp += (shaped - self.output_lp) * self.output_alpha;
            let coupled = shaped - self.output_lp;
            *sample = self.tone_filter.process(coupled) * self.level;
        }
    }

    fn reset(&mut self) {
        self.tone_filter.reset();
        self.input_lp = 0.0;
        self.output_lp = 0.0;
        self.fuzz = self.target_gain;
        self.tone = self.target_tone;
        self.level = self.target_level;
        self.tone_filter.set(lowpass(
            f64::from(self.rate.max(1)),
            f64::from(Self::cutoff(self.tone)),
        ));
        self.tone_designed = self.tone;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "gain" => {
                if usable {
                    self.target_gain = value.clamp(0.0, 1.0);
                }
                true
            }
            "tone" => {
                if usable {
                    self.target_tone = value.clamp(0.0, 1.0);
                }
                true
            }
            "level" => {
                if usable {
                    self.target_level = value.clamp(0.0, 1.0);
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "fuzz"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude)
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    fn crest(block: &[f32]) -> f32 {
        let peak = block.iter().fold(0.0f32, |peak, sample| peak.max(sample.abs()));
        let level = rms(block);
        if level > 0.0 {
            peak / level
        } else {
            0.0
        }
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut fuzz = Fuzz::new(0.8, 0.5, 0.8);
        fuzz.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        fuzz.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn the_curve_is_monotonic_and_asymmetric() {
        let mut fuzz = Fuzz::new(0.8, 0.5, 0.5);
        fuzz.prepare(RATE, 512);
        let mut positive = 0.0f32;
        let mut negative = 0.0f32;
        for point in 1..POINTS {
            let previous = fuzz.table(point - 1);
            let current = fuzz.table(point);
            assert!(
                current >= previous - 1e-3,
                "the curve folds at point {point}: {previous} then {current}"
            );
        }
        // The two halves of the JH-2 are not the same size: a germanium stage
        // with this bias clips one side first.
        for point in POINTS / 2 + 1..POINTS {
            positive = positive.max(fuzz.table(point));
        }
        for point in 0..POINTS / 2 {
            negative = negative.max(-fuzz.table(point));
        }
        assert!(
            (positive - negative).abs() > 0.02,
            "the curve is symmetric: +{positive} against -{negative}"
        );
    }

    #[test]
    fn more_fuzz_makes_the_wave_harder() {
        let input = sine(220.0, 0.02, 16_384);

        let mut gentle = Fuzz::new(0.1, 0.7, 0.5);
        gentle.prepare(RATE, 16_384);
        let mut soft = input.clone();
        gentle.process(&mut soft);

        let mut hot = Fuzz::new(0.95, 0.7, 0.5);
        hot.prepare(RATE, 16_384);
        let mut hard = input.clone();
        hot.process(&mut hard);

        // A fuzz is not only louder: it squares the wave. The crest factor
        // (peak over RMS) falls as the fuzz pot turns up, which is what the
        // ear hears as "harder" even when the level knob is pulled back.
        let soft_crest = crest(&soft[8192..]);
        let hard_crest = crest(&hard[8192..]);
        assert!(
            hard_crest < soft_crest * 0.95,
            "the fuzz pot did not harden the wave: crest {hard_crest} against {soft_crest}"
        );
    }

    #[test]
    fn the_tone_knob_cuts_the_top() {
        let input = sine(8_000.0, 0.2, 8192);

        let mut dark = Fuzz::new(0.6, 0.0, 0.5);
        dark.prepare(RATE, 8192);
        let mut dark_block = input.clone();
        dark.process(&mut dark_block);

        let mut bright = Fuzz::new(0.6, 1.0, 0.5);
        bright.prepare(RATE, 8192);
        let mut bright_block = input.clone();
        bright.process(&mut bright_block);

        assert!(
            rms(&dark_block[4096..]) < rms(&bright_block[4096..]) * 0.5,
            "the tone knob did not darken the fuzz"
        );
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 4096);
        let mut fuzz = Fuzz::new(1.0, 1.0, 1.0);
        fuzz.prepare(RATE, 4096);
        let mut first = input.clone();
        fuzz.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));
        fuzz.reset();
        let mut second = input.clone();
        fuzz.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut fuzz = Fuzz::new(0.5, 0.5, 0.5);
        assert!(fuzz.set("gain", 10.0));
        assert_eq!(fuzz.target_gain, 1.0);
        assert!(fuzz.set("tone", -10.0));
        assert_eq!(fuzz.target_tone, 0.0);
        assert!(fuzz.set("level", f32::NAN));
        assert_eq!(fuzz.target_level, 0.5, "NaN moved a knob");
        assert!(!fuzz.set("drive", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("fuzz"), Some(InsertKind::Fuzz));
        assert_eq!(InsertKind::Fuzz.name(), "fuzz");
    }
}
