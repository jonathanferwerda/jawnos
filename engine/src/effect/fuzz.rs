//! The `fuzz` pedal: a hard, gated distortion.
//!
//! The signal is driven into a hard clip, then toned down with a lowpass. What
//! makes it a fuzz rather than a distortion is the gate: below a quiet
//! threshold the output is muted, so the tail of a decaying note stops dead
//! instead of hissing. The gate is an envelope follower with a fast attack and
//! an 80 ms release, smoothed again so closing it cannot click.
//!
//! `gain`, `tone` and `level` are the normalised 0..1 knobs. `gain` is a
//! 0..36 dB preamp, `tone` sweeps the lowpass over 800 Hz..8 kHz, `level` is the
//! output trim.

use super::{lowpass, one_pole, one_pole_block, Biquad, Effect};

#[derive(Debug)]
pub struct Fuzz {
    rate: u32,
    target_gain: f32,
    drive: f32,
    target_tone: f32,
    tone: f32,
    target_level: f32,
    level: f32,
    filter: Biquad,
    tone_designed: f32,
    envelope: f32,
    gate: f32,
    smooth: f32,
}

impl Fuzz {
    /// The quietest input that keeps the gate open, about −50 dBFS.
    pub const GATE_THRESHOLD: f32 = 0.003;
    pub const MAX_PREAMP_DB: f32 = 36.0;
    pub const MIN_TONE_HZ: f32 = 800.0;
    pub const MAX_TONE_HZ: f32 = 8_000.0;

    pub fn new(gain: f32, tone: f32, level: f32) -> Self {
        let gain = gain.clamp(0.0, 1.0);
        let tone = tone.clamp(0.0, 1.0);
        let level = level.clamp(0.0, 1.0);
        Fuzz {
            rate: 48_000,
            target_gain: gain,
            drive: Self::preamp(gain),
            target_tone: tone,
            tone,
            target_level: level,
            level,
            filter: Biquad::identity(),
            tone_designed: -1.0,
            envelope: 0.0,
            gate: 1.0,
            smooth: 0.0,
        }
    }

    fn preamp(knob: f32) -> f32 {
        10f32.powf(knob.clamp(0.0, 1.0) * Self::MAX_PREAMP_DB / 20.0)
    }

    fn cutoff(knob: f32) -> f32 {
        Self::MIN_TONE_HZ * 10f32.powf(knob.clamp(0.0, 1.0))
    }
}

impl Effect for Fuzz {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.drive = Self::preamp(self.target_gain);
        self.tone = self.target_tone;
        self.level = self.target_level;
        self.filter.set(lowpass(f64::from(self.rate), f64::from(Self::cutoff(self.tone))));
        self.filter.reset();
        self.tone_designed = self.tone;
        self.envelope = 0.0;
        self.gate = 1.0;
        self.smooth = one_pole(0.01, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() {
            return;
        }
        // A lowpass needs a fresh design when the tone knob has moved; doing it
        // once per block keeps the transcendental work off the sample loop.
        let alpha = one_pole_block(0.02, self.rate, block.len()) as f32;
        self.tone += (self.target_tone - self.tone) * alpha;
        if (self.tone - self.tone_designed).abs() > 1e-4 {
            self.filter
                .set(lowpass(f64::from(self.rate.max(1)), f64::from(Self::cutoff(self.tone))));
            self.tone_designed = self.tone;
        }

        let attack = one_pole(0.001, self.rate) as f32;
        let release = one_pole(0.08, self.rate) as f32;
        let gate_smooth = one_pole(0.005, self.rate) as f32;
        // The preamp is smoothed in linear gain, so the knob's exponential dB
        // curve costs one `powf` per block instead of one per sample.
        let target_drive = Self::preamp(self.target_gain);

        for sample in block.iter_mut() {
            self.drive += (target_drive - self.drive) * self.smooth;
            self.level += (self.target_level - self.level) * self.smooth;

            let input = *sample;
            let magnitude = input.abs();
            let envelope_rate = if magnitude > self.envelope {
                attack
            } else {
                release
            };
            self.envelope += (magnitude - self.envelope) * envelope_rate;
            let gate_target = if self.envelope < Self::GATE_THRESHOLD {
                0.0
            } else {
                1.0
            };
            self.gate += (gate_target - self.gate) * gate_smooth;

            let driven = (input * self.drive).clamp(-1.0, 1.0);
            *sample = self.filter.process(driven) * self.level * self.gate;
        }
    }

    fn reset(&mut self) {
        self.filter.reset();
        self.envelope = 0.0;
        self.gate = 1.0;
        self.drive = Self::preamp(self.target_gain);
        self.tone = self.target_tone;
        self.level = self.target_level;
        self.tone_designed = -1.0;
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

    #[test]
    fn silence_in_stays_silence() {
        let mut fuzz = Fuzz::new(0.8, 0.5, 0.8);
        fuzz.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        fuzz.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn more_gain_drives_the_signal_harder() {
        let input = sine(220.0, 0.1, 8192);

        let mut gentle = Fuzz::new(0.1, 0.6, 0.5);
        gentle.prepare(RATE, 8192);
        let mut soft = input.clone();
        gentle.process(&mut soft);

        let mut hot = Fuzz::new(0.95, 0.6, 0.5);
        hot.prepare(RATE, 8192);
        let mut hard = input.clone();
        hot.process(&mut hard);

        assert!(
            rms(&hard[4096..]) > rms(&soft[4096..]) * 2.0,
            "gain did not drive the fuzz: {} against {}",
            rms(&hard[4096..]),
            rms(&soft[4096..])
        );
    }

    #[test]
    fn the_gate_closes_below_the_threshold() {
        let mut fuzz = Fuzz::new(1.0, 0.5, 1.0);
        fuzz.prepare(RATE, 16_384);
        let mut block = sine(220.0, 0.000_5, 16_384);
        fuzz.process(&mut block);
        let tail = &block[8192..];
        assert!(rms(tail) < 1e-4, "the gate let a whisper through: {}", rms(tail));
    }

    #[test]
    fn the_tone_knob_cuts_the_top() {
        let input = sine(8_000.0, 0.2, 8192);

        let mut dark = Fuzz::new(0.5, 0.0, 0.5);
        dark.prepare(RATE, 8192);
        let mut dark_block = input.clone();
        dark.process(&mut dark_block);

        let mut bright = Fuzz::new(0.5, 1.0, 0.5);
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
