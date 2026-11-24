//! The Studio kits: the acoustic base and the ten override tables.
//!
//! This module is a transcription of `studioDrumsBaseSpec`,
//! `studioDrumsClapSpec` and `studioDrumsKitSpecs` in
//! `public/js/manager/studio/11_drums.js`, with the same wire names pinned by
//! `perl/gb/05_abilities_and_studio.pl` (`drum_kits`). The numbers are kept in
//! the JS's own order so a reviewer can hold the two side by side; every length,
//! frequency, gain and offset is part of the pinned kit test.
//!
//! A kit never has a different row count: each table overrides the same eight
//! voices. `Kit::spec` applies an override exactly as `studioDrumsVoiceSpec`
//! does, field by field.

use crate::{FilterKind, NoiseSpec, ToneSpec, Voice, VoiceSpec, Wave};

/// One of the ten Studio kits.
///
/// `Acoustic` is the base; every other kit is a set of overrides on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kit {
    /// The unfiltered base every other kit overrides.
    Acoustic,
    /// Tighter and brighter: a short synthetic kick, dry snare, glassy hats.
    Electronic,
    /// A hard kick with a click, tight hats and a gritty snare.
    Techno,
    /// Urban: a long sub under the kick, a snappy snare and clap.
    Beats,
    /// Hand percussion: higher toms and rim, shaker-like hats.
    Latin,
    /// Bright and resonant, with a ringing snare.
    Pearl,
    /// Punchy and deep: a short low kick and a deep snare.
    Tama,
    /// Warm and round: a softer click and darker, longer tails.
    Gretsch,
    /// The long sub kick, snappy snare and metallic hats of the 808.
    EightOhEight,
    /// Aggressive: a clicky, fast kick, a big snare and cutting hats.
    Metal,
}

impl Kit {
    /// Every kit, in the order the Studio's Kit list offers them.
    pub const ALL: [Kit; 10] = [
        Kit::Acoustic,
        Kit::Electronic,
        Kit::Techno,
        Kit::Beats,
        Kit::Latin,
        Kit::Pearl,
        Kit::Tama,
        Kit::Gretsch,
        Kit::EightOhEight,
        Kit::Metal,
    ];

    /// The acoustic base kit.
    pub const fn acoustic() -> Kit {
        Kit::Acoustic
    }

    /// The wire name the song saves and the browser compares.
    pub const fn name(self) -> &'static str {
        match self {
            Kit::Acoustic => "acoustic",
            Kit::Electronic => "electronic",
            Kit::Techno => "techno",
            Kit::Beats => "beats",
            Kit::Latin => "latin",
            Kit::Pearl => "pearl",
            Kit::Tama => "tama",
            Kit::Gretsch => "gretsch",
            Kit::EightOhEight => "808",
            Kit::Metal => "metal",
        }
    }

    /// The kit with this exact wire name, case-sensitive like the browser's
    /// `studioDrumsKitNames().indexOf(name)`. Unknown names return `None`.
    pub fn from_name(name: &str) -> Option<Kit> {
        Kit::ALL.iter().copied().find(|kit| kit.name() == name)
    }

    /// The browser's `studioDrumsKitName`: an unknown kit falls back to Acoustic
    /// rather than opening on silence.
    pub fn from_name_or_acoustic(name: &str) -> Kit {
        Kit::from_name(name).unwrap_or(Kit::Acoustic)
    }

    /// The shape of one voice in this kit: the acoustic base with this kit's
    /// override applied exactly as `studioDrumsVoiceSpec` applies it.
    pub fn spec(self, voice: Voice) -> VoiceSpec {
        let base = base_spec(voice);
        match override_spec(self, voice) {
            None => base,
            Some(over) => VoiceSpec {
                length_seconds: over.length.unwrap_or(base.length_seconds),
                tones: over.tones.unwrap_or(base.tones),
                noise: over.noise.unwrap_or(base.noise),
            },
        }
    }
}

/// A kit's override for one voice. `None` means "keep the base's value", which
/// is the JS's `if (change.tones) ... else if (base.tones) ...` fallback.
struct Override {
    length: Option<f32>,
    tones: Option<Vec<ToneSpec>>,
    noise: Option<Vec<NoiseSpec>>,
}

impl Override {
    fn new(length: f32) -> Self {
        Override {
            length: Some(length),
            tones: None,
            noise: None,
        }
    }

    fn tones(mut self, tones: Vec<ToneSpec>) -> Self {
        self.tones = Some(tones);
        self
    }

    fn noise(mut self, noise: Vec<NoiseSpec>) -> Self {
        self.noise = Some(noise);
        self
    }
}

/// A compact tone constructor so the tables read like the JS object literals.
const fn tone(
    wave: Wave,
    from_hz: f32,
    to_hz: f32,
    dur: f32,
    gain: f32,
    env: f32,
) -> ToneSpec {
    ToneSpec::new(wave, from_hz, to_hz, dur, gain, env)
}

/// A high-pass burst. The browser omits Q for these and keeps the node's
/// default; this crate transcribes that default as the linear value `1.0`.
const fn hp(freq: f32, dur: f32, gain: f32) -> NoiseSpec {
    NoiseSpec::new(FilterKind::Highpass, freq, 1.0, dur, gain)
}

/// A band-pass burst.
const fn bp(freq: f32, q: f32, dur: f32, gain: f32) -> NoiseSpec {
    NoiseSpec::new(FilterKind::Bandpass, freq, q, dur, gain)
}

/// The acoustic base (`studioDrumsBaseSpec`).
fn base_spec(voice: Voice) -> VoiceSpec {
    use Voice::*;
    match voice {
        Kick => VoiceSpec::new(0.55)
            .with_tones(vec![tone(Wave::Sine, 150.0, 45.0, 0.18, 1.0, 0.45)])
            .with_noise(vec![hp(3000.0, 0.012, 0.25)]),
        Snare => VoiceSpec::new(0.35)
            .with_tones(vec![tone(Wave::Triangle, 190.0, 160.0, 0.12, 0.45, 0.16)])
            .with_noise(vec![bp(1800.0, 0.8, 0.18, 0.9)]),
        ClosedHat => VoiceSpec::new(0.15).with_noise(vec![hp(7500.0, 0.055, 0.6)]),
        OpenHat => VoiceSpec::new(0.45).with_noise(vec![hp(6500.0, 0.32, 0.55)]),
        Clap => clap_spec(1200.0, 1.2, 0.6, 0.12),
        LowTom => {
            VoiceSpec::new(0.45).with_tones(vec![tone(Wave::Sine, 130.0, 75.0, 0.22, 0.9, 0.35)])
        }
        HighTom => {
            VoiceSpec::new(0.35).with_tones(vec![tone(Wave::Sine, 220.0, 130.0, 0.18, 0.85, 0.28)])
        }
        Rim => VoiceSpec::new(0.12)
            .with_tones(vec![tone(Wave::Square, 900.0, 700.0, 0.02, 0.3, 0.05)])
            .with_noise(vec![bp(2500.0, 1.4, 0.02, 0.4)]),
    }
}

/// `studioDrumsClapSpec`: the same four-burst shape in every kit. A kit names
/// only the band-pass colour and the length of the final ring.
fn clap_spec(freq: f32, q: f32, gain: f32, tail: f32) -> VoiceSpec {
    VoiceSpec::new(tail + 0.2).with_noise(clap_noise(freq, q, gain, tail))
}

/// The same clap shape as a kit override.
fn clap_override(freq: f32, q: f32, gain: f32, tail: f32) -> Override {
    Override::new(tail + 0.2).noise(clap_noise(freq, q, gain, tail))
}

/// The override for `(kit, voice)`, or `None` for the acoustic base.
fn override_spec(kit: Kit, voice: Voice) -> Option<Override> {
    Some(match kit {
        Kit::Acoustic => return None,
        Kit::Electronic => electronic(voice),
        Kit::Techno => techno(voice),
        Kit::Beats => beats(voice),
        Kit::Latin => latin(voice),
        Kit::Pearl => pearl(voice),
        Kit::Tama => tama(voice),
        Kit::Gretsch => gretsch(voice),
        Kit::EightOhEight => eight_oh_eight(voice),
        Kit::Metal => metal(voice),
    })
}

/// Tighter and brighter: a short synthetic kick, dry snare, glassy hats.
fn electronic(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.32)
            .tones(vec![tone(Wave::Sine, 180.0, 60.0, 0.10, 1.0, 0.22)])
            .noise(vec![hp(5000.0, 0.008, 0.18)]),
        Snare => Override::new(0.22)
            .tones(vec![tone(Wave::Triangle, 240.0, 200.0, 0.07, 0.35, 0.09)])
            .noise(vec![bp(2600.0, 1.1, 0.10, 0.85)]),
        ClosedHat => Override::new(0.10).noise(vec![hp(9000.0, 0.035, 0.55)]),
        OpenHat => Override::new(0.28).noise(vec![hp(8500.0, 0.20, 0.5)]),
        Clap => clap_override(1800.0, 1.5, 0.55, 0.07),
        LowTom => Override::new(0.28)
            .tones(vec![tone(Wave::Sine, 180.0, 110.0, 0.12, 0.8, 0.18)]),
        HighTom => Override::new(0.22)
            .tones(vec![tone(Wave::Sine, 320.0, 200.0, 0.10, 0.75, 0.14)]),
        Rim => Override::new(0.08)
            .tones(vec![tone(Wave::Square, 1200.0, 1000.0, 0.012, 0.28, 0.03)])
            .noise(vec![bp(3500.0, 1.6, 0.015, 0.35)]),
    }
}

/// A hard kick with a click, tight hats and a gritty snare.
fn techno(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.50)
            .tones(vec![tone(Wave::Sine, 170.0, 38.0, 0.14, 1.15, 0.34)])
            .noise(vec![hp(2200.0, 0.02, 0.35)]),
        Snare => Override::new(0.30)
            .tones(vec![tone(Wave::Triangle, 210.0, 150.0, 0.10, 0.5, 0.13)])
            .noise(vec![bp(1500.0, 0.6, 0.14, 0.95)]),
        ClosedHat => Override::new(0.09).noise(vec![hp(8500.0, 0.025, 0.5)]),
        OpenHat => Override::new(0.35).noise(vec![hp(6000.0, 0.22, 0.45)]),
        Clap => clap_override(1000.0, 1.0, 0.6, 0.10),
        LowTom => Override::new(0.40)
            .tones(vec![tone(Wave::Sine, 120.0, 65.0, 0.20, 0.95, 0.30)]),
        HighTom => Override::new(0.30)
            .tones(vec![tone(Wave::Sine, 200.0, 120.0, 0.16, 0.9, 0.24)]),
        Rim => Override::new(0.10)
            .tones(vec![tone(Wave::Square, 800.0, 600.0, 0.015, 0.32, 0.035)])
            .noise(vec![bp(2200.0, 1.2, 0.018, 0.45)]),
    }
}

/// Urban: a long sub under the kick, a snappy snare and clap.
fn beats(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.80)
            .tones(vec![tone(Wave::Sine, 110.0, 32.0, 0.40, 1.2, 0.60)])
            .noise(vec![hp(2500.0, 0.015, 0.3)]),
        Snare => Override::new(0.30)
            .tones(vec![tone(Wave::Triangle, 210.0, 180.0, 0.08, 0.4, 0.12)])
            .noise(vec![bp(2200.0, 0.7, 0.12, 1.0)]),
        ClosedHat => Override::new(0.12).noise(vec![hp(8000.0, 0.04, 0.5)]),
        OpenHat => Override::new(0.40).noise(vec![hp(7000.0, 0.26, 0.45)]),
        Clap => clap_override(1500.0, 1.4, 0.7, 0.08),
        LowTom => Override::new(0.60)
            .tones(vec![tone(Wave::Sine, 100.0, 55.0, 0.32, 1.0, 0.50)]),
        HighTom => Override::new(0.40)
            .tones(vec![tone(Wave::Sine, 180.0, 110.0, 0.22, 0.9, 0.32)]),
        Rim => Override::new(0.10)
            .tones(vec![tone(Wave::Square, 1000.0, 800.0, 0.015, 0.3, 0.035)])
            .noise(vec![bp(3000.0, 1.3, 0.018, 0.4)]),
    }
}

/// Hand percussion: higher toms and rim, shaker-like hats.
fn latin(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.30)
            .tones(vec![tone(Wave::Sine, 200.0, 90.0, 0.10, 0.8, 0.20)])
            .noise(vec![hp(3500.0, 0.008, 0.15)]),
        Snare => Override::new(0.18)
            .tones(vec![tone(Wave::Triangle, 300.0, 260.0, 0.06, 0.25, 0.07)])
            .noise(vec![bp(3000.0, 1.8, 0.06, 0.55)]),
        ClosedHat => Override::new(0.18).noise(vec![hp(9000.0, 0.10, 0.28)]),
        OpenHat => Override::new(0.50).noise(vec![hp(8500.0, 0.40, 0.22)]),
        Clap => clap_override(2200.0, 2.2, 0.55, 0.06),
        LowTom => Override::new(0.35)
            .tones(vec![tone(Wave::Sine, 240.0, 150.0, 0.18, 0.75, 0.22)]),
        HighTom => Override::new(0.25)
            .tones(vec![tone(Wave::Sine, 360.0, 240.0, 0.12, 0.7, 0.16)]),
        Rim => Override::new(0.14)
            .tones(vec![tone(Wave::Square, 1400.0, 1100.0, 0.02, 0.35, 0.04)])
            .noise(vec![bp(3200.0, 2.0, 0.025, 0.5)]),
    }
}

/// Bright and resonant, with a ringing snare.
fn pearl(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.50)
            .tones(vec![tone(Wave::Sine, 160.0, 52.0, 0.16, 1.0, 0.42)])
            .noise(vec![hp(3800.0, 0.015, 0.3)]),
        Snare => Override::new(0.40)
            .tones(vec![tone(Wave::Triangle, 210.0, 180.0, 0.14, 0.5, 0.20)])
            .noise(vec![bp(2400.0, 0.9, 0.22, 1.0)]),
        ClosedHat => Override::new(0.16).noise(vec![hp(8000.0, 0.06, 0.62)]),
        OpenHat => Override::new(0.50).noise(vec![hp(7500.0, 0.36, 0.55)]),
        Clap => clap_override(1400.0, 1.1, 0.6, 0.12),
        LowTom => Override::new(0.50)
            .tones(vec![tone(Wave::Sine, 150.0, 85.0, 0.26, 0.9, 0.40)]),
        HighTom => Override::new(0.40)
            .tones(vec![tone(Wave::Sine, 260.0, 150.0, 0.20, 0.85, 0.32)]),
        Rim => Override::new(0.13)
            .tones(vec![tone(Wave::Square, 1000.0, 800.0, 0.022, 0.32, 0.045)])
            .noise(vec![bp(2800.0, 1.5, 0.022, 0.45)]),
    }
}

/// Punchy and deep: a short low kick and a deep snare.
fn tama(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.42)
            .tones(vec![tone(Wave::Sine, 140.0, 40.0, 0.12, 1.1, 0.26)])
            .noise(vec![hp(2000.0, 0.018, 0.3)]),
        Snare => Override::new(0.30)
            .tones(vec![tone(Wave::Triangle, 175.0, 145.0, 0.09, 0.5, 0.10)])
            .noise(vec![bp(1600.0, 0.7, 0.13, 1.0)]),
        ClosedHat => Override::new(0.12).noise(vec![hp(7000.0, 0.04, 0.55)]),
        OpenHat => Override::new(0.40).noise(vec![hp(6200.0, 0.26, 0.5)]),
        Clap => clap_override(1100.0, 1.0, 0.6, 0.11),
        LowTom => Override::new(0.48)
            .tones(vec![tone(Wave::Sine, 115.0, 62.0, 0.24, 0.95, 0.34)]),
        HighTom => Override::new(0.36)
            .tones(vec![tone(Wave::Sine, 195.0, 110.0, 0.18, 0.9, 0.26)]),
        Rim => Override::new(0.12)
            .tones(vec![tone(Wave::Square, 850.0, 650.0, 0.02, 0.32, 0.04)])
            .noise(vec![bp(2300.0, 1.3, 0.02, 0.45)]),
    }
}

/// Warm and round: a softer click and darker, longer tails.
fn gretsch(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.60)
            .tones(vec![tone(Wave::Sine, 130.0, 42.0, 0.22, 0.95, 0.50)])
            .noise(vec![hp(1800.0, 0.01, 0.18)]),
        Snare => Override::new(0.38)
            .tones(vec![tone(Wave::Triangle, 165.0, 145.0, 0.14, 0.42, 0.20)])
            .noise(vec![bp(1400.0, 0.6, 0.20, 0.8)]),
        ClosedHat => Override::new(0.14).noise(vec![hp(6200.0, 0.05, 0.5)]),
        OpenHat => Override::new(0.48).noise(vec![hp(5600.0, 0.34, 0.48)]),
        Clap => clap_override(1000.0, 0.9, 0.55, 0.13),
        LowTom => Override::new(0.52)
            .tones(vec![tone(Wave::Sine, 115.0, 68.0, 0.28, 0.85, 0.42)]),
        HighTom => Override::new(0.42)
            .tones(vec![tone(Wave::Sine, 200.0, 120.0, 0.22, 0.8, 0.34)]),
        Rim => Override::new(0.13)
            .tones(vec![tone(Wave::Square, 780.0, 620.0, 0.022, 0.28, 0.045)])
            .noise(vec![bp(2000.0, 1.1, 0.024, 0.36)]),
    }
}

/// A long sub kick, a snappy snare and metallic hats.
fn eight_oh_eight(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(1.20)
            .tones(vec![tone(Wave::Sine, 90.0, 28.0, 0.70, 1.2, 0.90)])
            .noise(vec![hp(4000.0, 0.008, 0.12)]),
        Snare => Override::new(0.28)
            .tones(vec![tone(Wave::Triangle, 230.0, 200.0, 0.05, 0.4, 0.07)])
            .noise(vec![bp(2800.0, 1.2, 0.10, 1.0)]),
        ClosedHat => Override::new(0.20).noise(vec![hp(10000.0, 0.05, 0.5)]),
        OpenHat => Override::new(0.60).noise(vec![hp(9500.0, 0.38, 0.45)]),
        Clap => clap_override(1900.0, 1.6, 0.55, 0.09),
        LowTom => Override::new(0.80)
            .tones(vec![tone(Wave::Sine, 95.0, 40.0, 0.45, 0.95, 0.60)]),
        HighTom => Override::new(0.50)
            .tones(vec![tone(Wave::Sine, 180.0, 90.0, 0.28, 0.85, 0.40)]),
        Rim => Override::new(0.10)
            .tones(vec![tone(Wave::Square, 1600.0, 1300.0, 0.015, 0.3, 0.035)])
            .noise(vec![bp(4000.0, 1.7, 0.015, 0.4)]),
    }
}

/// Aggressive: a clicky, fast kick for a double-kick feel, a big snare and
/// cutting hats.
fn metal(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.30)
            .tones(vec![tone(Wave::Sine, 190.0, 55.0, 0.07, 1.1, 0.16)])
            .noise(vec![hp(5000.0, 0.02, 0.45)]),
        Snare => Override::new(0.45)
            .tones(vec![tone(Wave::Triangle, 260.0, 210.0, 0.12, 0.55, 0.18)])
            .noise(vec![bp(3300.0, 0.6, 0.25, 1.05)]),
        ClosedHat => Override::new(0.10).noise(vec![hp(9500.0, 0.03, 0.55)]),
        OpenHat => Override::new(0.30).noise(vec![hp(9000.0, 0.18, 0.5)]),
        Clap => clap_override(2400.0, 1.6, 0.6, 0.10),
        LowTom => Override::new(0.30)
            .tones(vec![tone(Wave::Sine, 150.0, 80.0, 0.14, 0.9, 0.20)]),
        HighTom => Override::new(0.24)
            .tones(vec![tone(Wave::Sine, 270.0, 150.0, 0.10, 0.85, 0.14)]),
        Rim => Override::new(0.10)
            .tones(vec![tone(Wave::Square, 1400.0, 1100.0, 0.015, 0.34, 0.03)])
            .noise(vec![bp(3800.0, 1.8, 0.015, 0.5)]),
    }
}

/// The noise bursts of `studioDrumsClapSpec`, reused by the kit overrides.
fn clap_noise(freq: f32, q: f32, gain: f32, tail: f32) -> Vec<NoiseSpec> {
    let burst = |at: f32, dur: f32, level: f32| bp(freq, q, dur, level).with_at(at);
    vec![
        burst(0.0, 0.02, gain),
        burst(0.011, 0.02, gain),
        burst(0.022, 0.02, gain),
        burst(0.03, tail, gain * 0.66),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The lengths in `studioDrumsKitSpecs`, in `Voice::ALL` order. The clap
    /// length is its tail plus 0.2, as `studioDrumsClapSpec` builds it.
    const EXPECTED_LENGTHS: [(Kit, [f32; 8]); 10] = [
        (Kit::Acoustic, [0.55, 0.35, 0.15, 0.45, 0.32, 0.45, 0.35, 0.12]),
        (Kit::Electronic, [0.32, 0.22, 0.10, 0.28, 0.27, 0.28, 0.22, 0.08]),
        (Kit::Techno, [0.50, 0.30, 0.09, 0.35, 0.30, 0.40, 0.30, 0.10]),
        (Kit::Beats, [0.80, 0.30, 0.12, 0.40, 0.28, 0.60, 0.40, 0.10]),
        (Kit::Latin, [0.30, 0.18, 0.18, 0.50, 0.26, 0.35, 0.25, 0.14]),
        (Kit::Pearl, [0.50, 0.40, 0.16, 0.50, 0.32, 0.50, 0.40, 0.13]),
        (Kit::Tama, [0.42, 0.30, 0.12, 0.40, 0.31, 0.48, 0.36, 0.12]),
        (Kit::Gretsch, [0.60, 0.38, 0.14, 0.48, 0.33, 0.52, 0.42, 0.13]),
        (Kit::EightOhEight, [1.20, 0.28, 0.20, 0.60, 0.29, 0.80, 0.50, 0.10]),
        (Kit::Metal, [0.30, 0.45, 0.10, 0.30, 0.30, 0.30, 0.24, 0.10]),
    ];

    fn close(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-5
    }

    #[test]
    fn every_kit_defines_every_voice() {
        for kit in Kit::ALL {
            for voice in Voice::ALL {
                let spec = kit.spec(voice);
                assert!(spec.length_seconds > 0.0, "{} {}", kit.name(), voice.name());
                assert!(
                    !spec.tones.is_empty() || !spec.noise.is_empty(),
                    "{} {} has no components",
                    kit.name(),
                    voice.name()
                );
            }
        }
    }

    #[test]
    fn lengths_match_the_studio_table() {
        for (kit, lengths) in EXPECTED_LENGTHS {
            for voice in Voice::ALL {
                let found = kit.spec(voice).length_seconds;
                let expected = lengths[voice.index()];
                assert!(
                    close(found, expected),
                    "{} {} length {found}, expected {expected}",
                    kit.name(),
                    voice.name()
                );
            }
        }
    }

    #[test]
    fn the_808_kick_matches_the_js() {
        let spec = Kit::EightOhEight.spec(Voice::Kick);
        let tone = &spec.tones[0];
        assert!(close(tone.from_hz, 90.0));
        assert!(close(tone.to_hz, 28.0));
        assert!(close(tone.dur, 0.70));
        assert!(close(tone.gain, 1.2));
        assert!(close(tone.env, 0.90));
        let noise = &spec.noise[0];
        assert_eq!(noise.filter, FilterKind::Highpass);
        assert!(close(noise.freq, 4000.0));
        assert!(close(noise.dur, 0.008));
        assert!(close(noise.gain, 0.12));
    }

    #[test]
    fn the_acoustic_clap_has_the_four_burst_shape() {
        let spec = Kit::Acoustic.spec(Voice::Clap);
        assert_eq!(spec.tones.len(), 0);
        assert_eq!(spec.noise.len(), 4);
        let offsets = [0.0, 0.011, 0.022, 0.03];
        let durations = [0.02, 0.02, 0.02, 0.12];
        let gains = [0.6, 0.6, 0.6, 0.6 * 0.66];
        for (index, burst) in spec.noise.iter().enumerate() {
            assert_eq!(burst.filter, FilterKind::Bandpass);
            assert!(close(burst.freq, 1200.0));
            assert!(close(burst.q, 1.2));
            assert!(close(burst.at, offsets[index]));
            assert!(close(burst.dur, durations[index]));
            assert!(close(burst.gain, gains[index]));
        }
    }

    /// Every voice of every kit must be audible and bounded. The bound is
    /// deliberately above 1.0 because a kick's tone gain is 1.2 and a snare's
    /// noise gain 1.05; the sum can pass full scale before the engine's master
    /// chain, and the browser's destination would clip it there as well. The
    /// loudest voice in the transcribed data is 1.396, so 1.5 is the guarantee.
    #[test]
    fn every_kit_renders_audible_finite_bounded_audio() {
        const PEAK_BOUND: f32 = 1.5;
        for kit in Kit::ALL {
            for voice in Voice::ALL {
                let spec = kit.spec(voice);
                let rendered = crate::render_voice_with_seed(
                    &spec,
                    44_100,
                    crate::voice_seed(voice),
                );
                assert!(!rendered.is_empty(), "{} {}", kit.name(), voice.name());
                assert!(
                    rendered.iter().all(|sample| sample.is_finite()),
                    "{} {} has a non-finite sample",
                    kit.name(),
                    voice.name()
                );
                let peak = rendered
                    .iter()
                    .fold(0.0f32, |loudest, sample| loudest.max(sample.abs()));
                assert!(
                    peak > 0.01,
                    "{} {} is silent (peak {peak})",
                    kit.name(),
                    voice.name()
                );
                assert!(
                    peak <= PEAK_BOUND,
                    "{} {} peak {peak} exceeds {PEAK_BOUND}",
                    kit.name(),
                    voice.name()
                );
            }
        }
    }

    #[test]
    fn a_kit_override_replaces_the_base_voice_whole() {
        let spec = Kit::Techno.spec(Voice::Snare);
        assert_eq!(spec.tones.len(), 1);
        assert!(close(spec.tones[0].from_hz, 210.0));
        assert!(close(spec.tones[0].to_hz, 150.0));
        assert!(close(spec.tones[0].gain, 0.5));
        assert!(close(spec.noise[0].freq, 1500.0));
        assert!(close(spec.noise[0].q, 0.6));
        assert!(close(spec.noise[0].gain, 0.95));
    }

    #[test]
    fn kit_names_are_case_sensitive_exactly_like_the_js() {
        assert_eq!(Kit::from_name("808"), Some(Kit::EightOhEight));
        assert_eq!(Kit::from_name("acoustic"), Some(Kit::Acoustic));
        assert_eq!(Kit::from_name("Acoustic"), None);
        assert_eq!(Kit::from_name("ELECTRONIC"), None);
        assert_eq!(Kit::from_name("nope"), None);
        assert_eq!(Kit::from_name_or_acoustic("nope"), Kit::Acoustic);
        assert_eq!(Kit::from_name_or_acoustic("Metal"), Kit::Acoustic);
        assert_eq!(Kit::from_name_or_acoustic("metal"), Kit::Metal);
    }

    #[test]
    fn every_name_round_trips() {
        for kit in Kit::ALL {
            assert_eq!(Kit::from_name(kit.name()), Some(kit));
        }
        for voice in Voice::ALL {
            assert_eq!(Voice::from_name(voice.name()), Some(voice));
        }
        assert_eq!(Kit::acoustic(), Kit::Acoustic);
    }
}
