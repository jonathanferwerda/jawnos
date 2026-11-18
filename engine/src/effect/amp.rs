//! The `amp` pedal: pre-gain, a valve-ish waveshaper, the three-band tone
//! stack, then a cabinet.
//!
//! This is the pedal that makes a DI guitar sound like an amplifier, so the
//! order matters: the tone stack shapes the *distorted* signal, as an amp's
//! tone stack sits after its first gain stage, and the cabinet's roll-off comes
//! last. The four cabinets are the ones the contract pins: Combo 1x12 (0),
//! Open 2x12 (1), Closed 4x12 (2) and Tweed 4x10 (3). Each is a highpass, a
//! lowpass and one or two presence/resonance peaks — a real cabinet's impulse is
//! far more detailed, but this is the same role and the same four choices, with
//! no samples to load and no allocation at run time.
//!
//! `gain` is the normalised 0..1 knob behind a ±15 dB preamp (0 dB at 0.5),
//! `bass`, `mid` and `treble` are dB and reuse [`ToneStack`], so an amp and the
//! strip agree about what a tone control is; `cabinet` is a whole number 0..3.

use std::f64::consts::FRAC_1_SQRT_2;

use super::{highpass, lowpass, one_pole, peaking, Biquad, Effect, ToneStack};

#[derive(Debug)]
pub struct Amp {
    rate: u32,
    target_gain: f32,
    gain: f32,
    cabinet: usize,
    target_cabinet: usize,
    cabinet_bands: [Biquad; 4],
    tone: ToneStack,
    prepared: bool,
    smooth: f32,
}

impl Amp {
    /// The knob reaches ±15 dB around unity, the web pedal's range.
    pub const MAX_PREAMP_DB: f32 = 15.0;
    pub const CABINETS: [&'static str; 4] =
        ["Combo 1x12", "Open 2x12", "Closed 4x12", "Tweed 4x10"];

    pub fn new(gain: f32, bass_db: f32, mid_db: f32, treble_db: f32, cabinet: usize) -> Self {
        let gain = gain.clamp(0.0, 1.0);
        Amp {
            rate: 48_000,
            target_gain: gain,
            gain: Self::preamp(gain),
            cabinet: cabinet.min(Self::CABINETS.len() - 1),
            target_cabinet: cabinet.min(Self::CABINETS.len() - 1),
            cabinet_bands: [Biquad::identity(); 4],
            tone: ToneStack::new(bass_db, mid_db, treble_db),
            prepared: false,
            smooth: 0.0,
        }
    }

    fn preamp(knob: f32) -> f32 {
        let db = (knob.clamp(0.0, 1.0) - 0.5) * 2.0 * Self::MAX_PREAMP_DB;
        10f32.powf(db / 20.0)
    }

    /// The four cabinet shapes, as (highpass, presence Hz, presence dB, Q,
    /// lowpass). The index is the contract's: 0 Combo 1x12, 1 Open 2x12,
    /// 2 Closed 4x12, 3 Tweed 4x10. Tweed adds a second upper-mid peak.
    fn cabinet_shape(cabinet: usize) -> (f64, f64, f64, f64, f64) {
        match cabinet {
            // Small closed combo: a little low cut and a bright presence.
            0 => (90.0, 2_600.0, 2.0, 1.1, 5_200.0),
            // Open back: less low end, more top, the airiest of the four.
            1 => (75.0, 3_000.0, 3.0, 1.0, 6_000.0),
            // Closed 4x12: fuller low end, a strong low-mid and a tight top.
            2 => (60.0, 2_200.0, 5.0, 0.9, 4_500.0),
            // Tweed 4x10: a small box, an early low cut and the darkest top.
            _ => (110.0, 1_800.0, 4.0, 0.9, 4_000.0),
        }
    }

    fn design_cabinet(&mut self) {
        let rate = f64::from(self.rate.max(1));
        let (hp, presence_hz, presence_db, q, lp) = Self::cabinet_shape(self.cabinet);
        self.cabinet_bands[0].set(highpass(rate, hp, FRAC_1_SQRT_2));
        self.cabinet_bands[1].set(peaking(rate, presence_hz, q, presence_db));
        if self.cabinet == 3 {
            self.cabinet_bands[2].set(peaking(rate, 3_200.0, 1.4, 2.0));
        } else {
            self.cabinet_bands[2] = Biquad::identity();
        }
        self.cabinet_bands[3].set(lowpass(rate, lp));
        for band in &mut self.cabinet_bands {
            band.reset();
        }
    }
}

impl Effect for Amp {
    fn prepare(&mut self, rate: u32, max_frames: usize) {
        self.rate = rate.max(1);
        self.gain = Self::preamp(self.target_gain);
        self.cabinet = self.target_cabinet;
        self.tone.prepare(rate, max_frames);
        self.design_cabinet();
        self.smooth = one_pole(0.01, self.rate) as f32;
        self.prepared = true;
    }

    fn process(&mut self, block: &mut [f32]) {
        if !self.prepared {
            return;
        }
        // A cabinet is a choice, not a knob: switch it at the block edge and
        // reset its filters so the old coefficients' state cannot ring on.
        if self.target_cabinet != self.cabinet {
            self.cabinet = self.target_cabinet;
            self.design_cabinet();
        }

        let target_gain = Self::preamp(self.target_gain);
        for sample in block.iter_mut() {
            self.gain += (target_gain - self.gain) * self.smooth;
            *sample = (*sample * self.gain).tanh();
        }
        // The tone stack smooths its own three gains and re-designs per block.
        self.tone.process(block);
        for sample in block.iter_mut() {
            for band in &mut self.cabinet_bands {
                *sample = band.process(*sample);
            }
        }
    }

    fn reset(&mut self) {
        self.gain = Self::preamp(self.target_gain);
        self.cabinet = self.target_cabinet;
        self.design_cabinet();
        self.tone.reset();
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
        let input = sine(220.0, 0.1, 8192);

        let mut clean = Amp::new(0.05, 0.0, 0.0, 0.0, 2);
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
