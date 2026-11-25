//! The `overdrive` pedal: a valve-like soft overdrive.
//!
//! # The model
//!
//! ```text
//! in ──► 720 Hz highpass ──► ×gain ──► asymmetric soft clip ──► tone lowpass ──► ×level ──► out
//!                    (drive: 1..~50)            (600 Hz .. 6 kHz)
//! ```
//!
//! The input is first stripped of its low end, as an overdrive's coupling
//! capacitor and the pedal's voicing do, so the clipper is not asked to distort
//! bass that would only muddy the result. `drive` lifts the signal into a soft,
//! asymmetric valve curve: the positive half is compressed by `tanh`, the
//! negative half by a slightly hotter `tanh`, which adds even harmonics rather
//! than the RAT's hard, symmetric diode clip. `tone` is a lowpass from roughly
//! 600 Hz to 6 kHz, and `level` is the output trim.
//!
//! `drive`, `tone` and `level` are the normalised 0..1 knobs the control path
//! sends; there is no `sync` control.
//!
//! # The honest approximation
//!
//! * The valve is a transfer curve, not a solved triode: there is no bias point,
//!   no grid current and no interstage coupling. It is the soft, mid-focused
//!   overdrive the contract asks for, not a SPICE amp.
//! * The tone control is one lowpass, not a tone stack; the pedal's own tone
//!   network has interaction this single knob does not.
//! * The asymmetric curve can leave a small DC offset, so a 20 Hz one-pole
//!   removes it before the output.
//! * Knob moves are one-pole smoothed and the tone filter is redesigned once
//!   per block, so a drag is continuous; `process` allocates nothing. Silence
//!   stays exactly silent because every stage is linear except the clipper,
//!   whose output at zero is zero.

use super::{highpass, lowpass, one_pole, one_pole_block, Biquad, Effect, SMOOTH_SECONDS};

/// The input coupling highpass, near a valve pedal's first-stage roll-off.
const INPUT_HIGHPASS_HZ: f64 = 720.0;
const TONE_MIN_HZ: f64 = 600.0;
const TONE_MAX_HZ: f64 = 6_000.0;
/// The DC blocker after the asymmetric clip.
const DC_BLOCK_HZ: f64 = 20.0;
const MIN_GAIN: f32 = 1.0;
const MAX_GAIN: f32 = 50.0;

#[derive(Debug)]
pub struct Overdrive {
    rate: u32,
    target_drive: f32,
    drive: f32,
    target_tone: f32,
    tone: f32,
    target_level: f32,
    level: f32,
    input_highpass: Biquad,
    tone_lowpass: Biquad,
    dc_x1: f32,
    dc_y1: f32,
    dc_coefficient: f32,
    smooth: f32,
}

impl Overdrive {
    pub fn new(drive: f32, tone: f32, level: f32) -> Self {
        Overdrive {
            rate: 48_000,
            target_drive: drive.clamp(0.0, 1.0),
            drive: drive.clamp(0.0, 1.0),
            target_tone: tone.clamp(0.0, 1.0),
            tone: tone.clamp(0.0, 1.0),
            target_level: level.clamp(0.0, 1.0),
            level: level.clamp(0.0, 1.0),
            input_highpass: Biquad::identity(),
            tone_lowpass: Biquad::identity(),
            dc_x1: 0.0,
            dc_y1: 0.0,
            dc_coefficient: 0.0,
            smooth: 0.0,
        }
    }

    /// The tone knob's lowpass corner, logarithmically placed in its band.
    fn tone_hz(tone: f32) -> f64 {
        TONE_MIN_HZ * (TONE_MAX_HZ / TONE_MIN_HZ).powf(f64::from(tone.clamp(0.0, 1.0)))
    }

    #[inline]
    fn gain(drive: f32) -> f32 {
        MIN_GAIN + drive * (MAX_GAIN - MIN_GAIN)
    }

    /// The asymmetric valve curve: both halves soft, the negative half hotter.
    #[inline]
    fn clip(x: f32) -> f32 {
        if x >= 0.0 {
            x.tanh()
        } else {
            (1.3 * x).tanh() / 1.3
        }
    }
}

impl Effect for Overdrive {
    fn prepare(&mut self, rate: u32, _max_frames: usize) {
        self.rate = rate.max(1);
        self.drive = self.target_drive;
        self.tone = self.target_tone;
        self.level = self.target_level;
        let rate_f = f64::from(self.rate);
        self.input_highpass = Biquad::identity();
        self.input_highpass
            .set(highpass(rate_f, INPUT_HIGHPASS_HZ, 0.707));
        self.tone_lowpass = Biquad::identity();
        self.tone_lowpass.set(lowpass(rate_f, Self::tone_hz(self.tone)));
        self.dc_x1 = 0.0;
        self.dc_y1 = 0.0;
        self.dc_coefficient = 1.0 - (std::f64::consts::TAU * DC_BLOCK_HZ / rate_f) as f32;
        self.smooth = one_pole(SMOOTH_SECONDS, self.rate) as f32;
    }

    fn process(&mut self, block: &mut [f32]) {
        if block.is_empty() || self.rate == 0 {
            return;
        }
        let block_smooth = one_pole_block(SMOOTH_SECONDS, self.rate, block.len()) as f32;
        self.drive += (self.target_drive - self.drive) * block_smooth;
        self.tone += (self.target_tone - self.tone) * block_smooth;
        self.level += (self.target_level - self.level) * block_smooth;
        self.tone_lowpass
            .set(lowpass(f64::from(self.rate), Self::tone_hz(self.tone)));

        let gain = Self::gain(self.drive);
        let level = self.level;
        for sample in block.iter_mut() {
            let shaped = self.input_highpass.process(*sample);
            let clipped = Self::clip(shaped * gain);
            let toned = self.tone_lowpass.process(clipped);
            let blocked = toned - self.dc_x1 + self.dc_coefficient * self.dc_y1;
            self.dc_x1 = toned;
            self.dc_y1 = blocked;
            *sample = blocked * level;
        }
    }

    fn reset(&mut self) {
        self.drive = self.target_drive;
        self.tone = self.target_tone;
        self.level = self.target_level;
        self.input_highpass.reset();
        self.tone_lowpass.reset();
        self.dc_x1 = 0.0;
        self.dc_y1 = 0.0;
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let usable = value.is_finite();
        match name {
            "drive" => {
                if usable {
                    self.target_drive = value.clamp(0.0, 1.0);
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
        "overdrive"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| {
                (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude
            })
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    fn peak(block: &[f32]) -> f32 {
        block
            .iter()
            .fold(0.0f32, |high, sample| high.max(sample.abs()))
    }

    fn render(overdrive: &mut Overdrive, input: &[f32]) -> Vec<f32> {
        overdrive.prepare(RATE, input.len());
        let mut block = input.to_vec();
        overdrive.process(&mut block);
        block
    }

    #[test]
    fn silence_in_stays_silence() {
        let mut overdrive = Overdrive::new(0.8, 0.5, 1.0);
        let output = render(&mut overdrive, &vec![0.0f32; 4096]);
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn drive_compresses_the_crest_factor() {
        // A 1 kHz tone is inside the input highpass's passband. At low drive the
        // curve is nearly linear; at high drive the peaks flatten.
        let input = sine(1_000.0, 0.2, 8192);
        let mut soft = Overdrive::new(0.0, 1.0, 1.0);
        let soft_out = render(&mut soft, &input);
        let mut hard = Overdrive::new(1.0, 1.0, 1.0);
        let hard_out = render(&mut hard, &input);
        let soft_crest = peak(&soft_out[2_048..]) / rms(&soft_out[2_048..]);
        let hard_crest = peak(&hard_out[2_048..]) / rms(&hard_out[2_048..]);
        assert!(
            hard_crest < soft_crest - 0.1,
            "drive did not flatten the peaks: {soft_crest} -> {hard_crest}"
        );
    }

    #[test]
    fn the_tone_knob_opens_the_top_end() {
        let input = sine(8_000.0, 0.02, 8192);
        let mut dark = Overdrive::new(0.2, 0.0, 1.0);
        let dark_out = rms(&render(&mut dark, &input)[2_048..]);
        let mut bright = Overdrive::new(0.2, 1.0, 1.0);
        let bright_out = rms(&render(&mut bright, &input)[2_048..]);
        assert!(
            bright_out > dark_out * 2.0,
            "the tone knob did not move the top end: {dark_out} -> {bright_out}"
        );
    }

    #[test]
    fn level_zero_is_silent() {
        let mut overdrive = Overdrive::new(0.8, 0.5, 0.0);
        let output = render(&mut overdrive, &sine(1_000.0, 0.4, 4096));
        assert!(output.iter().all(|sample| *sample == 0.0));
    }

    #[test]
    fn full_scale_input_stays_finite_and_reset_is_repeatable() {
        let input = sine(997.0, 1.0, 8192);
        let mut overdrive = Overdrive::new(1.0, 0.5, 1.0);
        overdrive.prepare(RATE, input.len());
        let mut first = input.clone();
        overdrive.process(&mut first);
        assert!(first.iter().all(|sample| sample.is_finite()));

        overdrive.reset();
        let mut second = input.clone();
        overdrive.process(&mut second);
        assert_eq!(first, second, "reset did not return to the first run");
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut overdrive = Overdrive::new(0.5, 0.5, 0.5);
        assert!(overdrive.set("drive", 10.0));
        assert_eq!(overdrive.target_drive, 1.0);
        assert!(overdrive.set("drive", -1.0));
        assert_eq!(overdrive.target_drive, 0.0);
        assert!(overdrive.set("tone", 10.0));
        assert_eq!(overdrive.target_tone, 1.0);
        assert!(overdrive.set("level", 0.0));
        assert_eq!(overdrive.target_level, 0.0);
        assert!(overdrive.set("level", f32::NAN));
        assert_eq!(overdrive.target_level, 0.0);
        assert!(!overdrive.set("gain", 1.0));
        assert!(!overdrive.set("sync", 1.0), "sync is not an engine control");
    }

    #[test]
    fn the_insert_name_round_trips() {
        assert_eq!(InsertKind::parse("overdrive"), Some(InsertKind::Overdrive));
        assert_eq!(InsertKind::Overdrive.name(), "overdrive");
        assert_eq!(
            InsertKind::Overdrive.controls(),
            &["drive", "tone", "level"]
        );
        assert_eq!(InsertKind::Overdrive.code(), 23);
        assert_eq!(InsertKind::from_code(23), Some(InsertKind::Overdrive));
        assert_eq!(InsertKind::Overdrive.build().name(), "overdrive");
    }
}
