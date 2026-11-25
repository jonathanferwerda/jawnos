//! The master rack's ten-band graphic equaliser (`master_eq`).
//!
//! A graphic EQ is not a tone control: it is a bank of overlapping bells, one
//! per octave, so moving one fader leaves a smooth skirt under the next instead
//! of a step. This one has the ten bands a hardware graphic has, each a single
//! RBJ peaking section at the contract's frequencies:
//!
//! ```text
//! 32  64  125  250  500  1k  2k  4k  8k  16k   Hz
//! ```
//!
//! Every band takes ±[`GraphicEq::MAX_DB`] dB and uses the same
//! [`GraphicEq::Q`], the classic graphic-fader width. The bells are one octave
//! apart and overlap: a fully raised fader is heard a little under its
//! neighbours (about +2 dB at the adjacent centre) and is gone by the band
//! after next. That is why a zig-zag setting reads as a curve rather than as ten
//! isolated spikes, and why the sum of several raised neighbours is more than
//! any single fader asked for.
//!
//! ## The model
//!
//! The chain is ten peaking biquads in series, in band order. A flat bank is
//! **bit-exactly transparent**: at 0 dB the RBJ numerator and denominator are
//! the same numbers, so every section is an exact unity transfer and a flat
//! graphic EQ passes the mix untouched (the same property the channel
//! `Equalizer` relies on). The whole bank is mono, allocates only in
//! [`prepare`](Effect::prepare), clamps every knob to ±`MAX_DB` and ignores
//! NaN, exactly as the engine's other effects do.
//!
//! The knobs arrive in dB, not the browser's 0..100 slider: the control path
//! maps the slider (`docs/studio-effects.md`) before it posts. The three names
//! the old three-knob master EQ used — `low`, `mid`, `high` — are accepted as
//! aliases of the 125 Hz, 1 kHz and 8 kHz bands, so a song saved before the
//! faders existed still loads and still moves the part of the mix it used to.
//!
//! ## The browser mirror
//!
//! `studioEffectGraphicEq` in `public/js/manager/studio/08_effects.js` builds
//! the same ten bands from ten WebAudio `BiquadFilterNode`s (peaking, Q 1.4),
//! driven by the same control names. Neither side claims a sample-identical
//! filter; the band map, the range and the units are the shared contract.

use super::{one_pole_block, peaking, Biquad, Effect, SMOOTH_SECONDS};

/// How many bands the bank holds, one per octave from 32 Hz to 16 kHz.
pub const BANDS: usize = 10;

/// A ten-band graphic EQ, one peaking bell per octave.
#[derive(Debug)]
pub struct GraphicEq {
    rate: u32,
    target_db: [f32; BANDS],
    current_db: [f32; BANDS],
    bands: [Biquad; BANDS],
    designed: bool,
}

impl GraphicEq {
    /// The control names, in band order: the contract's spelling
    /// (`docs/studio-effects.md`, "Master rack").
    pub const CONTROLS: &'static [&'static str] =
        &["b32", "b64", "b125", "b250", "b500", "b1k", "b2k", "b4k", "b8k", "b16k"];

    /// The centre frequency of each band, in the same order as [`CONTROLS`].
    pub const CENTRES: [f32; BANDS] = [
        32.0, 64.0, 125.0, 250.0, 500.0, 1_000.0, 2_000.0, 4_000.0, 8_000.0, 16_000.0,
    ];

    /// The fader travel, in dB. The browser slider is 0..100 mapped onto this.
    pub const MAX_DB: f32 = 12.0;

    /// One octave wide, the bandwidth of a hardware graphic's faders.
    pub const Q: f64 = 1.4;

    /// A flat bank: every band at 0 dB, which is exactly transparent.
    pub fn new() -> Self {
        GraphicEq {
            rate: 48_000,
            target_db: [0.0; BANDS],
            current_db: [0.0; BANDS],
            bands: [Biquad::identity(); BANDS],
            designed: false,
        }
    }

    /// The band a control name addresses, including the three legacy aliases.
    /// `None` is not this effect's control.
    pub fn band_index(name: &str) -> Option<usize> {
        if let Some(index) = Self::CONTROLS.iter().position(|control| *control == name) {
            return Some(index);
        }
        // The old three-knob master EQ: Low was the low shelf, Mid the 1 kHz
        // bell and High the high shelf, so those are the centres they move to.
        match name {
            "low" => Some(2),  // 125 Hz
            "mid" => Some(5),  // 1 kHz
            "high" => Some(8), // 8 kHz
            _ => None,
        }
    }

    fn design(&mut self) {
        let rate = f64::from(self.rate.max(1));
        for (band, filter) in self.bands.iter_mut().enumerate() {
            filter.set(peaking(
                rate,
                f64::from(Self::CENTRES[band]),
                Self::Q,
                f64::from(self.current_db[band]),
            ));
        }
        self.designed = true;
    }
}

impl Default for GraphicEq {
    fn default() -> Self {
        Self::new()
    }
}

impl Effect for GraphicEq {
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
        // Only a fader that moved needs a new coefficient set; the walk is in
        // block-sized steps so a drag never jumps a bell into a click.
        let alpha = one_pole_block(SMOOTH_SECONDS, self.rate, block.len());
        let mut changed = false;
        for band in 0..BANDS {
            let target = self.target_db[band];
            let current = self.current_db[band];
            if target != current {
                if (target - current).abs() < 1e-4 {
                    self.current_db[band] = target;
                } else {
                    self.current_db[band] =
                        (f64::from(current) + f64::from(target - current) * alpha) as f32;
                }
                changed = true;
            }
        }
        if changed {
            self.design();
        }
        for sample in block.iter_mut() {
            let mut value = *sample;
            for filter in &mut self.bands {
                value = filter.process(value);
            }
            *sample = value;
        }
    }

    fn reset(&mut self) {
        for filter in &mut self.bands {
            filter.reset();
        }
    }

    fn set(&mut self, name: &str, value: f32) -> bool {
        let band = match Self::band_index(name) {
            Some(band) => band,
            None => return false,
        };
        if value.is_finite() {
            self.target_db[band] = value.clamp(-Self::MAX_DB, Self::MAX_DB);
        }
        true
    }

    fn name(&self) -> &'static str {
        "master_eq"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::effect::InsertKind;

    const RATE: u32 = 48_000;
    const FRAMES: usize = 16_384;
    const SETTLE: usize = 8_192;

    fn sine(hz: f32, amplitude: f32, frames: usize) -> Vec<f32> {
        (0..frames)
            .map(|index| (std::f32::consts::TAU * hz * index as f32 / RATE as f32).sin() * amplitude)
            .collect()
    }

    fn rms(block: &[f32]) -> f32 {
        (block.iter().map(|sample| sample * sample).sum::<f32>() / block.len() as f32).sqrt()
    }

    /// Steady-state gain through a bank whose `band` is set to `db`.
    fn gain_at(hz: f32, band: usize, db: f32) -> f32 {
        let mut eq = GraphicEq::new();
        assert!(eq.set(GraphicEq::CONTROLS[band], db));
        eq.prepare(RATE, FRAMES);
        let input = sine(hz, 0.25, FRAMES);
        let mut output = input.clone();
        eq.process(&mut output);
        rms(&output[SETTLE..]) / rms(&input[SETTLE..])
    }

    #[test]
    fn every_band_lifts_and_cuts_its_own_octave() {
        for (band, hz) in GraphicEq::CENTRES.iter().enumerate() {
            let boost = gain_at(*hz, band, 12.0);
            let cut = gain_at(*hz, band, -12.0);
            assert!(boost > 3.5, "{hz} Hz was not lifted: {boost}");
            assert!(cut < 0.32, "{hz} Hz was not cut: {cut}");
        }
    }

    #[test]
    fn the_bands_overlap_like_a_graphic_eq() {
        // The bells are one octave apart, so a fader leaves a small skirt under
        // its neighbour (about +2 dB at full boost) and is gone by the band
        // after next. That is why a zig-zag setting reads as a curve, not as
        // ten isolated spikes.
        let neighbour = gain_at(2_000.0, 5, 12.0); // 1 kHz fader, heard at 2 kHz
        let two_away = gain_at(4_000.0, 5, 12.0); // 1 kHz fader, heard at 4 kHz
        assert!(
            neighbour > 1.15 && neighbour < 1.6,
            "the octave neighbour was not a gentle skirt: {neighbour}"
        );
        assert!(
            two_away < 1.15,
            "a fader reached two octaves: {two_away}"
        );

        // The far ends stay out of each other's way.
        assert!(gain_at(16_000.0, 0, 12.0) < 1.05, "32 Hz moved 16 kHz");
        assert!(gain_at(32.0, 9, 12.0) < 1.05, "16 kHz moved 32 Hz");
    }

    #[test]
    fn a_flat_bank_is_bit_exactly_transparent() {
        let mut eq = GraphicEq::new();
        eq.prepare(RATE, 4_096);
        let input = sine(997.0, 0.5, 4_096);
        let mut output = input.clone();
        eq.process(&mut output);
        assert_eq!(input, output, "a flat graphic EQ changed the signal");
    }

    #[test]
    fn the_legacy_three_knob_names_move_the_named_bands() {
        assert_eq!(GraphicEq::band_index("low"), Some(2), "low is 125 Hz");
        assert_eq!(GraphicEq::band_index("mid"), Some(5), "mid is 1 kHz");
        assert_eq!(GraphicEq::band_index("high"), Some(8), "high is 8 kHz");
        assert_eq!(GraphicEq::band_index("b2k"), Some(6));
        assert_eq!(GraphicEq::band_index("bass"), None);

        let mut eq = GraphicEq::new();
        assert!(eq.set("low", 9.0));
        assert!(eq.set("mid", -6.0));
        assert!(eq.set("high", 3.0));
        assert_eq!(eq.target_db[2], 9.0);
        assert_eq!(eq.target_db[5], -6.0);
        assert_eq!(eq.target_db[8], 3.0);
        // The bands the aliases did not name are untouched.
        assert_eq!(eq.target_db[0], 0.0);
        assert_eq!(eq.target_db[9], 0.0);
    }

    #[test]
    fn knobs_clamp_and_junk_is_ignored() {
        let mut eq = GraphicEq::new();
        assert!(eq.set("b32", 100.0));
        assert_eq!(eq.target_db[0], GraphicEq::MAX_DB);
        assert!(eq.set("b16k", -100.0));
        assert_eq!(eq.target_db[9], -GraphicEq::MAX_DB);
        assert!(eq.set("b500", f32::NAN));
        assert_eq!(eq.target_db[4], 0.0, "NaN moved a fader");
        assert!(!eq.set("bass", 1.0));
        assert!(!eq.set("b33", 1.0));
    }

    #[test]
    fn full_scale_input_stays_finite() {
        let mut eq = GraphicEq::new();
        for control in GraphicEq::CONTROLS {
            assert!(eq.set(control, 12.0));
        }
        eq.prepare(RATE, 4_096);

        let mut alternating = vec![0.0f32; 4_096];
        for (index, sample) in alternating.iter_mut().enumerate() {
            *sample = if index % 2 == 0 { 1.0 } else { -1.0 };
        }
        eq.process(&mut alternating);
        assert!(
            alternating.iter().all(|sample| sample.is_finite() && sample.abs() < 64.0),
            "Nyquist full scale ran away"
        );

        let mut full = sine(997.0, 1.0, 4_096);
        eq.process(&mut full);
        assert!(
            full.iter().all(|sample| sample.is_finite() && sample.abs() < 64.0),
            "full-scale sine ran away"
        );
    }

    #[test]
    fn silence_and_reset_hold() {
        let mut eq = GraphicEq::new();
        for control in GraphicEq::CONTROLS {
            assert!(eq.set(control, 6.0));
        }
        eq.prepare(RATE, 512);
        let mut block = vec![0.0f32; 512];
        eq.process(&mut block);
        assert!(block.iter().all(|sample| *sample == 0.0));

        let input = sine(440.0, 0.3, 512);
        let mut first = input.clone();
        eq.process(&mut first);
        eq.reset();
        let mut second = input.clone();
        eq.process(&mut second);
        assert_eq!(first, second);
    }

    #[test]
    fn the_insert_name_builds_the_graphic_eq() {
        assert_eq!(InsertKind::parse("master_eq"), Some(InsertKind::MasterEq));
        assert_eq!(InsertKind::MasterEq.name(), "master_eq");
        assert_eq!(InsertKind::MasterEq.controls(), GraphicEq::CONTROLS);
        assert_eq!(InsertKind::MasterEq.master_prefix(), Some("master_eq"));
        assert_eq!(InsertKind::MasterEq.build().name(), "master_eq");
        // The channel pedal stays the three-band tone network.
        assert_eq!(InsertKind::parse("equalizer"), Some(InsertKind::Equalizer));
    }
}
