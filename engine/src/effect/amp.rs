//! The `amp` pedal: a valve preamp, a power stage, and a real cabinet.
//!
//! This is the pedal that makes a DI guitar sound like an amplifier. The order
//! is the amplifier's: an input coupling cap, two single-ended valve gain
//! stages with an interstage highpass between them, the three-band tone stack
//! after the first gain stage, the power stage's sag, and last the speaker.
//!
//! # The valve stages
//!
//! A 12AX7 common-cathode stage is asymmetric: it clips the side that drives
//! the grid positive before the other side, and its cathode bypass rounds the
//! knee. [`tube`] is a soft `tanh` around the stage's bias with a second-order
//! term that gives the two halves different shapes, so the even harmonics are
//! not a by-product of a symmetric clipper. The first stage's gain is the
//! `gain` knob (±24 dB around unity, 0 dB at 0.5), the second is fixed per
//! cabinet; the interstage highpass is the coupling cap that keeps a valve
//! stage from passing DC.
//!
//! # The cabinets
//!
//! The four choices are the ones the contract pins: Combo 1x12 (0), Open 2x12
//! (1), Closed 4x12 (2) and Tweed 4x10 (3). Each also chooses the valve voice
//! that suits it — a 6V6 combo, a 6L6 open-back, an EL34 closed stack and a
//! tweed-era 4x10 — because the cabinet is not only a filter: the speaker, the
//! box and the amplifier's feedback are one voicing.
//!
//! The cabinet is a **short impulse response**, built in `prepare` from the
//! speaker's resonances, its baffle step, a mic-distance reflection and the
//! box's roll-off, then convolved directly. A real cabinet's impulse is longer
//! and messier; this is the same role with no sample to load and no allocation
//! in `process`. The four biquads the old model used could not make the
//! presence peak ring or the baffle step appear, which is why the cabinet read
//! as compression rather than a speaker.

use std::f64::consts::FRAC_1_SQRT_2;

use super::{highpass, lowpass, one_pole, peaking, Biquad, Effect, ToneStack};

/// The cabinet IR length. 256 taps is 5.3 ms at 48 kHz — long enough for the
/// box's low resonance and the mic reflection, short enough for direct
/// convolution on the audio thread.
const IR_TAPS: usize = 256;

/// The output trim after the cabinet. The convolution is normalised to a peak
/// of one, so this keeps a hot preamp from pushing the channel over.
const CABINET_TRIM: f32 = 2.0;

/// One cabinet's speaker, box, mic and valve voice.
#[derive(Clone, Copy)]
struct CabinetSpec {
    highpass: f64,
    lowpass: f64,
    peak1_hz: f64,
    peak1_db: f64,
    peak1_q: f64,
    peak2_hz: f64,
    peak2_db: f64,
    peak2_q: f64,
    reflection_ms: f64,
    reflection_gain: f32,
    drive: f32,
    stage2: f32,
    bias: f32,
    sag: f32,
}

#[derive(Debug)]
pub struct Amp {
    rate: u32,
    target_gain: f32,
    gain: f32,
    cabinet: usize,
    target_cabinet: usize,
    tone: ToneStack,
    input_hp: Biquad,
    interstage: Biquad,
    output_hp: Biquad,
    ir: Vec<f32>,
    history: Vec<f32>,
    write: usize,
    sag: f32,
    sag_attack: f32,
    sag_release: f32,
    smooth: f32,
    prepared: bool,
}

impl Amp {
    /// The knob reaches ±24 dB around unity, enough for a clean amp and a
    /// saturated one from the same control.
    pub const MAX_PREAMP_DB: f32 = 24.0;
    pub const CABINETS: [&'static str; 4] =
        ["Combo 1x12", "Open 2x12", "Closed 4x12", "Tweed 4x10"];

    pub fn new(gain: f32, bass_db: f32, mid_db: f32, treble_db: f32, cabinet: usize) -> Self {
        let gain = gain.clamp(0.0, 1.0);
        let cabinet = cabinet.min(Self::CABINETS.len() - 1);
        Amp {
            rate: 48_000,
            target_gain: gain,
            gain: Self::preamp(gain),
            cabinet,
            target_cabinet: cabinet,
            tone: ToneStack::new(bass_db, mid_db, treble_db),
            input_hp: Biquad::identity(),
            interstage: Biquad::identity(),
            output_hp: Biquad::identity(),
            ir: Vec::new(),
            history: Vec::new(),
            write: 0,
            sag: 0.0,
            sag_attack: 0.0,
            sag_release: 0.0,
            smooth: 0.0,
            prepared: false,
        }
    }

    fn preamp(knob: f32) -> f32 {
        let db = (knob.clamp(0.0, 1.0) - 0.5) * 2.0 * Self::MAX_PREAMP_DB;
        10f32.powf(db / 20.0)
    }

    /// The four cabinet/valve voices. Index order is the contract's.
    fn cabinet_spec(cabinet: usize) -> CabinetSpec {
        match cabinet {
            // 6V6 combo, open-backed 1x12: a little low cut, a bright presence.
            0 => CabinetSpec {
                highpass: 85.0,
                lowpass: 5_200.0,
                peak1_hz: 2_600.0,
                peak1_db: 2.0,
                peak1_q: 1.1,
                peak2_hz: 1_100.0,
                peak2_db: 2.0,
                peak2_q: 1.5,
                reflection_ms: 1.1,
                reflection_gain: 0.4,
                drive: 1.0,
                stage2: 2.2,
                bias: 0.05,
                sag: 0.12,
            },
            // 6L6 open-back 2x12: the cleanest and airiest of the four.
            1 => CabinetSpec {
                highpass: 70.0,
                lowpass: 6_000.0,
                peak1_hz: 3_000.0,
                peak1_db: 3.0,
                peak1_q: 1.0,
                peak2_hz: 1_400.0,
                peak2_db: 1.5,
                peak2_q: 1.4,
                reflection_ms: 1.5,
                reflection_gain: 0.35,
                drive: 0.9,
                stage2: 2.0,
                bias: 0.035,
                sag: 0.08,
            },
            // EL34 closed 4x12: the low-mid push and the tight top.
            2 => CabinetSpec {
                highpass: 55.0,
                lowpass: 4_500.0,
                peak1_hz: 2_200.0,
                peak1_db: 5.0,
                peak1_q: 0.9,
                peak2_hz: 900.0,
                peak2_db: 3.0,
                peak2_q: 1.8,
                reflection_ms: 2.2,
                reflection_gain: 0.5,
                drive: 1.2,
                stage2: 2.6,
                bias: 0.08,
                sag: 0.15,
            },
            // Tweed 4x10: early breakup, a small box and the darkest top.
            _ => CabinetSpec {
                highpass: 95.0,
                lowpass: 4_000.0,
                peak1_hz: 1_800.0,
                peak1_db: 4.0,
                peak1_q: 0.9,
                peak2_hz: 1_200.0,
                peak2_db: 2.0,
                peak2_q: 1.6,
                reflection_ms: 0.9,
                reflection_gain: 0.45,
                drive: 1.1,
                stage2: 2.4,
                bias: 0.06,
                sag: 0.20,
            },
        }
    }

    /// A single-ended valve stage: a soft knee around `bias`, with the second
    /// harmonic that keeps the positive and negative halves from matching.
    fn tube(x: f32, drive: f32, bias: f32) -> f32 {
        let y = (x * drive + bias).tanh() - bias.tanh();
        y + 0.08 * y * y
    }

    fn design_cabinet(&mut self) {
        let spec = Self::cabinet_spec(self.cabinet);
        let rate = f64::from(self.rate.max(1));

        // Build the speaker's impulse: an impulse through the cabinet's
        // resonances and roll-offs, then one mic-distance reflection.
        let mut ir = vec![0.0f32; IR_TAPS];
        ir[0] = 1.0;
        let mut hp = Biquad::identity();
        hp.set(highpass(rate, spec.highpass, FRAC_1_SQRT_2));
        let mut peak1 = Biquad::identity();
        peak1.set(peaking(rate, spec.peak1_hz, spec.peak1_q, spec.peak1_db));
        let mut peak2 = Biquad::identity();
        peak2.set(peaking(rate, spec.peak2_hz, spec.peak2_q, spec.peak2_db));
        let mut lp = Biquad::identity();
        lp.set(lowpass(rate, spec.lowpass));
        for sample in &mut ir {
            *sample = hp.process(*sample);
        }
        for sample in &mut ir {
            *sample = peak1.process(*sample);
        }
        for sample in &mut ir {
            *sample = peak2.process(*sample);
        }
        for sample in &mut ir {
            *sample = lp.process(*sample);
        }

        let delay = (spec.reflection_ms * rate / 1000.0).round() as usize;
        if delay > 0 && delay < IR_TAPS {
            for index in (delay..IR_TAPS).rev() {
                ir[index] += ir[index - delay] * spec.reflection_gain;
            }
        }

        // Normalise by the impulse's L1 norm, not its peak: a peak
        // normalisation would boost a cabinet with a strong resonance and
        // flatten the very top-end difference the four choices exist for. The
        // L1 norm bounds the convolution's gain at one, so the trim is safe.
        let sum = ir.iter().map(|sample| sample.abs()).sum::<f32>();
        if sum > 1e-9 {
            for sample in &mut ir {
                *sample /= sum;
            }
        }
        self.ir = ir;
        self.history = vec![0.0f32; IR_TAPS];
        self.write = 0;
    }
}

impl Effect for Amp {
    fn prepare(&mut self, rate: u32, max_frames: usize) {
        self.rate = rate.max(1);
        self.gain = Self::preamp(self.target_gain);
        self.cabinet = self.target_cabinet;
        self.tone.prepare(rate, max_frames);
        self.input_hp
            .set(highpass(f64::from(self.rate), 40.0, FRAC_1_SQRT_2));
        self.input_hp.reset();
        self.interstage
            .set(highpass(f64::from(self.rate), 80.0, FRAC_1_SQRT_2));
        self.interstage.reset();
        self.output_hp
            .set(highpass(f64::from(self.rate), 20.0, FRAC_1_SQRT_2));
        self.output_hp.reset();
        self.design_cabinet();
        self.sag = 0.0;
        self.smooth = one_pole(0.01, self.rate) as f32;
        self.sag_attack = one_pole(0.005, self.rate) as f32;
        self.sag_release = one_pole(0.15, self.rate) as f32;
        self.prepared = true;
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared || block.is_empty() {
            return;
        }
        // A cabinet is a choice, not a knob: switch it at the block edge and
        // clear the old impulse's tail.
        if self.target_cabinet != self.cabinet {
            self.cabinet = self.target_cabinet;
            self.design_cabinet();
        }

        let spec = Self::cabinet_spec(self.cabinet);
        let target_gain = Self::preamp(self.target_gain);
        for sample in block.iter_mut() {
            self.gain += (target_gain - self.gain) * self.smooth;
            let input = self.input_hp.process(*sample) * self.gain;

            // First valve stage, then its coupling cap.
            let mut stage = Self::tube(input, spec.drive, spec.bias);
            stage = self.interstage.process(stage);

            // Second valve stage: more gain, the other side of the bias.
            stage = Self::tube(stage * spec.stage2, spec.drive * 0.7, -spec.bias * 0.5);
            stage = self.interstage.process(stage);

            // Power-stage sag: the supply droops on the loud part of a note and
            // recovers when it lets go.
            let rectified = stage.abs();
            let coefficient = if rectified > self.sag {
                self.sag_attack
            } else {
                self.sag_release
            };
            self.sag += (rectified - self.sag) * coefficient;
            let sag_gain = 1.0 - spec.sag * self.sag.min(1.0);
            *sample = stage * sag_gain;
        }

        // The passive tone stack sees the distorted signal, as it does in the
        // amplifier, and smooths its own three gains at the block edge.
        self.tone.process(block);

        // The speaker: direct convolution with the cabinet's short impulse.
        for sample in block.iter_mut() {
            let input = self.output_hp.process(*sample);
            self.history[self.write] = input;
            let mut index = self.write;
            let mut output = 0.0f32;
            for tap in &self.ir {
                output += tap * self.history[index];
                index = if index == 0 {
                    self.ir.len() - 1
                } else {
                    index - 1
                };
            }
            self.write = (self.write + 1) % self.ir.len();
            *sample = output * CABINET_TRIM;
        }
    }

    fn reset(&mut self) {
        self.gain = Self::preamp(self.target_gain);
        self.cabinet = self.target_cabinet;
        self.design_cabinet();
        self.tone.reset();
        self.input_hp.reset();
        self.interstage.reset();
        self.output_hp.reset();
        self.sag = 0.0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        match name {
            "gain" => {
                if value.is_finite() {
                    self.target_gain = value.clamp(0.0, 1.0);
                }
                true
            }
            "bass" | "mid" | "treble" => self.tone.set(name, value),
            "cabinet" => {
                if value.is_finite() {
                    self.target_cabinet =
                        (value.round() as i32).clamp(0, Self::CABINETS.len() as i32 - 1) as usize;
                }
                true
            }
            _ => false,
        }
    }

    fn name(&self) -> &'static str {
        "amp"
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

    #[test]
    fn silence_in_stays_silence() {
        let mut amp = Amp::new(0.8, 6.0, -3.0, 3.0, 1);
        amp.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        amp.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn the_gain_knob_drives_the_amp() {
        let input = sine(220.0, 0.01, 8192);

        let mut clean = Amp::new(0.1, 0.0, 0.0, 0.0, 2);
        clean.prepare(RATE, 8192);
        let mut soft = input.clone();
        clean.process(&mut soft);

        let mut hot = Amp::new(0.95, 0.0, 0.0, 0.0, 2);
        hot.prepare(RATE, 8192);
        let mut hard = input.clone();
        hot.process(&mut hard);

        assert!(
            rms(&hard[4096..]) > rms(&soft[4096..]) * 2.0,
            "the preamp did not drive the amp"
        );
    }

    #[test]
    fn the_cabinet_choice_changes_the_top_end() {
        assert_eq!(
            Amp::CABINETS,
            ["Combo 1x12", "Open 2x12", "Closed 4x12", "Tweed 4x10"]
        );
        let input = sine(8_000.0, 0.2, 8192);

        // Index 1 is the open 2x12, the brightest of the four; index 3 is the
        // tweed 4x10, the darkest.
        let mut open = Amp::new(0.2, 0.0, 0.0, 0.0, 1);
        open.prepare(RATE, 8192);
        let mut open_block = input.clone();
        open.process(&mut open_block);

        let mut tweed = Amp::new(0.2, 0.0, 0.0, 0.0, 3);
        tweed.prepare(RATE, 8192);
        let mut tweed_block = input.clone();
        tweed.process(&mut tweed_block);

        assert!(
            rms(&tweed_block[4096..]) < rms(&open_block[4096..]) * 0.8,
            "Tweed 4x10 did not roll off the top against Open 2x12"
        );
    }

    #[test]
    fn the_closed_cabinet_has_more_low_end() {
        let input = sine(80.0, 0.2, 16_384);

        let mut open = Amp::new(0.2, 0.0, 0.0, 0.0, 1);
        open.prepare(RATE, 16_384);
        let mut open_block = input.clone();
        open.process(&mut open_block);

        let mut closed = Amp::new(0.2, 0.0, 0.0, 0.0, 2);
        closed.prepare(RATE, 16_384);
        let mut closed_block = input.clone();
        closed.process(&mut closed_block);

        assert!(
            rms(&closed_block[8192..]) > rms(&open_block[8192..]) * 1.1,
            "the closed 4x12 did not put more low end out than the open 2x12"
        );
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 4096);
        let mut amp = Amp::new(1.0, 12.0, 12.0, 12.0, 3);
        amp.prepare(RATE, 4096);
        let mut first = input.clone();
        amp.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));
        amp.reset();
        let mut second = input.clone();
        amp.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut amp = Amp::new(0.5, 0.0, 0.0, 0.0, 0);
        assert!(amp.set("gain", 10.0));
        assert_eq!(amp.target_gain, 1.0);
        assert!(amp.set("bass", 100.0));
        assert_eq!(amp.tone.target_db[0], ToneStack::MAX_DB);
        assert!(amp.set("cabinet", 99.0));
        assert_eq!(amp.target_cabinet, 3);
        assert!(amp.set("cabinet", -1.0));
        assert_eq!(amp.target_cabinet, 0);
        assert!(amp.set("cabinet", f32::NAN));
        assert_eq!(amp.target_cabinet, 0, "NaN moved the cabinet");
        assert!(!amp.set("presence", 1.0));
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("amp"), Some(InsertKind::Amp));
        assert_eq!(InsertKind::Amp.name(), "amp");
    }
}
