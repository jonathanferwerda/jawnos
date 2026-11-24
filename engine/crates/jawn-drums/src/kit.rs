//! The Studio kits: the acoustic base and the ten override tables.
//!
//! This module began as a transcription of `studioDrumsBaseSpec`,
//! `studioDrumsClapSpec` and `studioDrumsKitSpecs` in
//! `public/js/manager/studio/11_drums.js`, and keeps the wire names and row
//! order pinned by `perl/gb/05_abilities_and_studio.pl` (`drum_kits`) and the
//! browser's whole-voice override rule. The numbers, however, are no longer the
//! browser's.
//!
//! The browser's ten kits are one acoustic voice set with small EQ deltas: the
//! kick is nearly the same sweep in every kit and a hat is one high-passed noise
//! burst. This crate renders each voice offline, once, and can afford to layer
//! it, so the acoustic base and every kit here are an engine-side redesign for
//! character. A kick is a beater click plus a body plus a sub, a snare is a
//! shell tone under the wires, an 808 hat is an inharmonic sine stack under
//! noise, a clap can be five bursts. A kit should be recognisable by how its
//! voices are built, not by a one-number difference from its neighbour. Expect
//! these frequencies, gains and lengths to diverge from `11_drums.js`;
//! [`Kit::spec`] still applies an override as a whole, exactly as
//! `studioDrumsVoiceSpec` does.
//!
//! Every override table still names all eight voices, so a kit never disagrees
//! with the Studio about the row count. A table entry replaces the base voice's
//! length, tones and noise as a unit. The acoustic kit is the reference the
//! other nine are heard against, so it carries the plainest construction: a
//! body and a quiet octave on the kick and toms, one wire band under a shell
//! tone, and one beater or stick noise per drum.

use crate::{FilterKind, NoiseSpec, ToneSpec, Voice, VoiceSpec, Wave};

/// One of the ten Studio kits.
///
/// `Acoustic` is the base; every other kit is a set of overrides on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kit {
    /// The reference: a natural beater over a falling sine, a shell-and-wire
    /// snare, and noise hats. No kit-specific colour.
    Acoustic,
    /// Tight and synthetic: very short envelopes, high clicks and square grit
    /// under the kick.
    Electronic,
    /// Punchy and dry: a strong transient, a fast low body and almost no ring.
    Techno,
    /// Roomy and laid back: a long sub, a darker wire set and a low room bloom
    /// after the snare.
    Beats,
    /// Hand percussion: timbale-like high toms, a short kick, dry crisp rim and
    /// bright but short hats.
    Latin,
    /// Deep and round: low bodies, a resonant shell tone and long, even decays.
    Pearl,
    /// Bright and cutting: a high click, an assertive wire set and incisive
    /// toms.
    Tama,
    /// Woody: a papery beater, a warm low end, tom bodies that drop further in
    /// pitch, and a wood-shell tone under quieter wires.
    Gretsch,
    /// The electronic powerhouse: a long sine sub with a click that reads on
    /// small speakers, a pitched snare body, a wide long clap and metallic hats.
    EightOhEight,
    /// Gated and aggressive: a clicky kick, a cracky snare that stops dead, and
    /// cutting hats.
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
    /// override applied whole, as `studioDrumsVoiceSpec` applies it.
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

/// A low-pass burst: a room bloom under a snare or the woody part of a shell.
const fn lp(freq: f32, q: f32, dur: f32, gain: f32) -> NoiseSpec {
    NoiseSpec::new(FilterKind::Lowpass, freq, q, dur, gain)
}

/// The acoustic reference (`studioDrumsBaseSpec`, reworked).
///
/// The construction is deliberately plain so the other nine kits have something
/// neutral to differ from: a sine body and a second lower sine on the drums, a
/// beater or stick noise on the attack, a shell tone and a wire band on the
/// snare, and unfiltered-noise hats.
fn base_spec(voice: Voice) -> VoiceSpec {
    use Voice::*;
    match voice {
        Kick => VoiceSpec::new(0.52)
            .with_tones(vec![
                tone(Wave::Sine, 155.0, 48.0, 0.17, 0.95, 0.42),
                tone(Wave::Sine, 82.0, 46.0, 0.20, 0.28, 0.38).with_at(0.004),
            ])
            .with_noise(vec![hp(2800.0, 0.012, 0.20)]),
        Snare => VoiceSpec::new(0.36)
            .with_tones(vec![tone(Wave::Triangle, 195.0, 165.0, 0.10, 0.42, 0.15)])
            .with_noise(vec![
                bp(1800.0, 0.8, 0.16, 0.85),
                hp(4200.0, 0.05, 0.16),
            ]),
        ClosedHat => VoiceSpec::new(0.12).with_noise(vec![hp(7800.0, 0.045, 0.55)]),
        OpenHat => VoiceSpec::new(0.42).with_noise(vec![hp(6500.0, 0.30, 0.50)]),
        Clap => clap_spec(1200.0, 1.2, 0.6, 0.12),
        LowTom => VoiceSpec::new(0.44)
            .with_tones(vec![
                tone(Wave::Sine, 128.0, 72.0, 0.22, 0.85, 0.36),
                tone(Wave::Sine, 64.0, 60.0, 0.24, 0.18, 0.30).with_at(0.003),
            ])
            .with_noise(vec![bp(700.0, 1.2, 0.012, 0.10)]),
        HighTom => VoiceSpec::new(0.34)
            .with_tones(vec![
                tone(Wave::Sine, 215.0, 125.0, 0.17, 0.80, 0.28),
                tone(Wave::Sine, 108.0, 105.0, 0.18, 0.16, 0.22).with_at(0.003),
            ])
            .with_noise(vec![bp(1200.0, 1.2, 0.010, 0.09)]),
        Rim => VoiceSpec::new(0.11)
            .with_tones(vec![tone(Wave::Square, 900.0, 700.0, 0.018, 0.30, 0.04)])
            .with_noise(vec![bp(2500.0, 1.4, 0.018, 0.40)]),
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

/// Tight and synthetic: very short envelopes, high clicks and square grit under
/// the kick.
fn electronic(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.26)
            .tones(vec![
                tone(Wave::Sine, 200.0, 55.0, 0.055, 1.00, 0.16),
                tone(Wave::Square, 110.0, 60.0, 0.05, 0.12, 0.10).with_at(0.002),
            ])
            .noise(vec![hp(6000.0, 0.006, 0.22)]),
        Snare => Override::new(0.18)
            .tones(vec![tone(Wave::Triangle, 260.0, 210.0, 0.045, 0.32, 0.06)])
            .noise(vec![bp(2600.0, 1.2, 0.075, 0.88), hp(7000.0, 0.025, 0.15)]),
        ClosedHat => Override::new(0.08).noise(vec![hp(9500.0, 0.022, 0.50)]),
        OpenHat => Override::new(0.20).noise(vec![hp(9000.0, 0.14, 0.45)]),
        Clap => clap_override(2000.0, 1.6, 0.50, 0.06),
        LowTom => Override::new(0.24)
            .tones(vec![
                tone(Wave::Sine, 190.0, 115.0, 0.10, 0.75, 0.16),
                tone(Wave::Sine, 95.0, 92.0, 0.11, 0.12, 0.12).with_at(0.002),
            ]),
        HighTom => Override::new(0.18)
            .tones(vec![
                tone(Wave::Sine, 330.0, 205.0, 0.08, 0.70, 0.12),
                tone(Wave::Sine, 165.0, 160.0, 0.09, 0.10, 0.09).with_at(0.002),
            ]),
        Rim => Override::new(0.06)
            .tones(vec![tone(Wave::Square, 1500.0, 1300.0, 0.008, 0.26, 0.02)])
            .noise(vec![bp(4200.0, 1.8, 0.008, 0.32)]),
    }
}

/// Punchy and dry: a strong transient, a fast low body and almost no ring.
fn techno(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.36)
            .tones(vec![
                tone(Wave::Sine, 180.0, 45.0, 0.08, 1.08, 0.26),
                tone(Wave::Sine, 72.0, 44.0, 0.10, 0.28, 0.22).with_at(0.003),
            ])
            .noise(vec![hp(3200.0, 0.012, 0.30)]),
        Snare => Override::new(0.22)
            .tones(vec![tone(Wave::Triangle, 225.0, 165.0, 0.06, 0.45, 0.09)])
            .noise(vec![bp(1800.0, 0.7, 0.10, 0.90), hp(5000.0, 0.03, 0.13)]),
        ClosedHat => Override::new(0.07).noise(vec![hp(9000.0, 0.02, 0.52)]),
        OpenHat => Override::new(0.26).noise(vec![hp(7500.0, 0.17, 0.46)]),
        Clap => clap_override(1300.0, 1.1, 0.62, 0.08),
        LowTom => Override::new(0.34)
            .tones(vec![
                tone(Wave::Sine, 118.0, 62.0, 0.18, 0.92, 0.28),
                tone(Wave::Sine, 60.0, 58.0, 0.19, 0.15, 0.22).with_at(0.003),
            ])
            .noise(vec![bp(650.0, 1.2, 0.010, 0.10)]),
        HighTom => Override::new(0.26)
            .tones(vec![
                tone(Wave::Sine, 195.0, 112.0, 0.14, 0.86, 0.22),
                tone(Wave::Sine, 100.0, 98.0, 0.15, 0.13, 0.18).with_at(0.003),
            ]),
        Rim => Override::new(0.09)
            .tones(vec![tone(Wave::Square, 820.0, 620.0, 0.014, 0.34, 0.03)])
            .noise(vec![bp(2400.0, 1.3, 0.016, 0.45)]),
    }
}

/// Roomy and laid back: a long sub, a darker wire set and a low room bloom
/// after the snare.
fn beats(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.85)
            .tones(vec![
                tone(Wave::Sine, 120.0, 34.0, 0.42, 1.05, 0.66),
                tone(Wave::Sine, 55.0, 38.0, 0.40, 0.22, 0.55).with_at(0.006),
            ])
            .noise(vec![hp(2400.0, 0.014, 0.20)]),
        Snare => Override::new(0.34)
            .tones(vec![tone(Wave::Triangle, 200.0, 168.0, 0.11, 0.42, 0.16)])
            .noise(vec![
                bp(1750.0, 0.6, 0.19, 0.80),
                lp(900.0, 0.7, 0.22, 0.10).with_at(0.02),
                hp(4000.0, 0.04, 0.10),
            ]),
        ClosedHat => Override::new(0.13).noise(vec![hp(7200.0, 0.055, 0.48)]),
        OpenHat => Override::new(0.50).noise(vec![hp(6200.0, 0.36, 0.44)]),
        Clap => clap_override(1600.0, 1.3, 0.68, 0.10),
        LowTom => Override::new(0.62)
            .tones(vec![
                tone(Wave::Sine, 102.0, 50.0, 0.34, 0.95, 0.52),
                tone(Wave::Sine, 52.0, 48.0, 0.34, 0.18, 0.40).with_at(0.004),
            ])
            .noise(vec![bp(600.0, 1.1, 0.012, 0.08)]),
        HighTom => Override::new(0.44)
            .tones(vec![
                tone(Wave::Sine, 175.0, 100.0, 0.24, 0.85, 0.34),
                tone(Wave::Sine, 88.0, 86.0, 0.24, 0.15, 0.28).with_at(0.004),
            ]),
        Rim => Override::new(0.12)
            .tones(vec![tone(Wave::Square, 1050.0, 850.0, 0.016, 0.30, 0.035)])
            .noise(vec![bp(2800.0, 1.2, 0.02, 0.35)]),
    }
}

/// Hand percussion: timbale-like high toms, a short kick, dry crisp rim and
/// bright but short hats.
fn latin(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.24)
            .tones(vec![
                tone(Wave::Sine, 205.0, 90.0, 0.06, 0.72, 0.15),
                tone(Wave::Sine, 100.0, 88.0, 0.06, 0.12, 0.12).with_at(0.002),
            ])
            .noise(vec![hp(3000.0, 0.007, 0.12)]),
        Snare => Override::new(0.16)
            .tones(vec![tone(Wave::Triangle, 320.0, 280.0, 0.045, 0.30, 0.06)])
            .noise(vec![bp(3200.0, 2.0, 0.05, 0.52), hp(6000.0, 0.02, 0.10)]),
        ClosedHat => Override::new(0.12).noise(vec![hp(9500.0, 0.035, 0.38)]),
        OpenHat => Override::new(0.24).noise(vec![hp(8800.0, 0.16, 0.30)]),
        Clap => clap_override(2400.0, 2.4, 0.48, 0.05),
        LowTom => Override::new(0.32)
            .tones(vec![
                tone(Wave::Sine, 250.0, 190.0, 0.16, 0.72, 0.22),
                tone(Wave::Triangle, 500.0, 470.0, 0.10, 0.10, 0.10).with_at(0.002),
            ])
            .noise(vec![bp(1500.0, 1.5, 0.010, 0.10)]),
        HighTom => Override::new(0.26)
            .tones(vec![
                tone(Wave::Sine, 370.0, 300.0, 0.13, 0.68, 0.18),
                tone(Wave::Triangle, 740.0, 700.0, 0.08, 0.09, 0.09).with_at(0.002),
            ]),
        Rim => Override::new(0.08)
            .tones(vec![tone(Wave::Square, 1500.0, 1250.0, 0.012, 0.40, 0.025)])
            .noise(vec![bp(3800.0, 2.6, 0.012, 0.50)]),
    }
}

/// Deep and round: low bodies, a resonant shell tone and long, even decays.
fn pearl(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.58)
            .tones(vec![
                tone(Wave::Sine, 150.0, 44.0, 0.22, 0.98, 0.50),
                tone(Wave::Sine, 74.0, 42.0, 0.24, 0.26, 0.46).with_at(0.004),
            ])
            .noise(vec![hp(2200.0, 0.014, 0.18)]),
        Snare => Override::new(0.42)
            .tones(vec![
                tone(Wave::Triangle, 180.0, 150.0, 0.14, 0.48, 0.20),
                tone(Wave::Triangle, 355.0, 330.0, 0.10, 0.12, 0.14).with_at(0.002),
            ])
            .noise(vec![bp(2000.0, 1.1, 0.24, 0.85)]),
        ClosedHat => Override::new(0.15).noise(vec![hp(7400.0, 0.055, 0.50)]),
        OpenHat => Override::new(0.50).noise(vec![hp(6800.0, 0.36, 0.46)]),
        Clap => clap_override(1400.0, 1.2, 0.62, 0.12),
        LowTom => Override::new(0.55)
            .tones(vec![
                tone(Wave::Sine, 135.0, 68.0, 0.28, 0.90, 0.44),
                tone(Wave::Sine, 68.0, 62.0, 0.28, 0.22, 0.36).with_at(0.004),
            ])
            .noise(vec![bp(650.0, 1.1, 0.012, 0.08)]),
        HighTom => Override::new(0.44)
            .tones(vec![
                tone(Wave::Sine, 230.0, 128.0, 0.22, 0.85, 0.34),
                tone(Wave::Sine, 115.0, 112.0, 0.22, 0.18, 0.28).with_at(0.004),
            ]),
        Rim => Override::new(0.14)
            .tones(vec![tone(Wave::Square, 950.0, 780.0, 0.02, 0.30, 0.05)])
            .noise(vec![bp(2700.0, 1.6, 0.02, 0.40)]),
    }
}

/// Bright and cutting: a high click, an assertive wire set and incisive toms.
fn tama(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.34)
            .tones(vec![
                tone(Wave::Sine, 190.0, 52.0, 0.09, 1.00, 0.24),
                tone(Wave::Sine, 80.0, 48.0, 0.10, 0.18, 0.20).with_at(0.003),
            ])
            .noise(vec![hp(4500.0, 0.016, 0.36)]),
        Snare => Override::new(0.26)
            .tones(vec![tone(Wave::Triangle, 215.0, 175.0, 0.08, 0.45, 0.11)])
            .noise(vec![bp(2900.0, 0.8, 0.13, 0.85), hp(6500.0, 0.04, 0.18)]),
        ClosedHat => Override::new(0.09).noise(vec![hp(8800.0, 0.03, 0.52)]),
        OpenHat => Override::new(0.30).noise(vec![hp(7800.0, 0.20, 0.48)]),
        Clap => clap_override(1800.0, 1.3, 0.60, 0.09),
        LowTom => Override::new(0.40)
            .tones(vec![
                tone(Wave::Sine, 128.0, 68.0, 0.20, 0.90, 0.30),
                tone(Wave::Sine, 64.0, 60.0, 0.20, 0.16, 0.24).with_at(0.003),
            ])
            .noise(vec![bp(700.0, 1.2, 0.012, 0.09)]),
        HighTom => Override::new(0.30)
            .tones(vec![
                tone(Wave::Sine, 225.0, 130.0, 0.16, 0.85, 0.24),
                tone(Wave::Sine, 112.0, 108.0, 0.16, 0.14, 0.20).with_at(0.003),
            ]),
        Rim => Override::new(0.10)
            .tones(vec![tone(Wave::Square, 1050.0, 850.0, 0.016, 0.34, 0.035)])
            .noise(vec![bp(3000.0, 1.6, 0.018, 0.45)]),
    }
}

/// Woody: a papery beater, a warm low end, tom bodies that drop further in
/// pitch, and a wood-shell tone under quieter wires.
fn gretsch(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.62)
            .tones(vec![
                tone(Wave::Sine, 122.0, 48.0, 0.20, 0.98, 0.50),
                tone(Wave::Sine, 68.0, 44.0, 0.24, 0.26, 0.46).with_at(0.004),
            ])
            // A band around 1.4 kHz reads as a papery beater rather than the
            // bright high-pass crack the metal kit uses.
            .noise(vec![bp(1400.0, 0.9, 0.018, 0.18)]),
        Snare => Override::new(0.38)
            .tones(vec![
                tone(Wave::Triangle, 168.0, 143.0, 0.13, 0.52, 0.18),
                tone(Wave::Triangle, 258.0, 232.0, 0.09, 0.14, 0.12).with_at(0.002),
            ])
            .noise(vec![
                bp(1500.0, 0.6, 0.18, 0.62),
                lp(700.0, 0.8, 0.18, 0.10).with_at(0.005),
            ]),
        ClosedHat => Override::new(0.13).noise(vec![hp(5600.0, 0.05, 0.46)]),
        OpenHat => Override::new(0.46).noise(vec![hp(5000.0, 0.32, 0.44)]),
        Clap => clap_override(1000.0, 0.8, 0.50, 0.12),
        LowTom => Override::new(0.56)
            .tones(vec![
                // A wider pitch drop than the base tom (155 -> 58 rather than
                // 128 -> 72), with a longer low-mid body under it.
                tone(Wave::Sine, 155.0, 58.0, 0.28, 0.88, 0.50),
                tone(Wave::Sine, 78.0, 56.0, 0.30, 0.20, 0.44).with_at(0.004),
            ])
            .noise(vec![bp(600.0, 1.0, 0.012, 0.07)]),
        HighTom => Override::new(0.46)
            .tones(vec![
                tone(Wave::Sine, 255.0, 108.0, 0.24, 0.84, 0.42),
                tone(Wave::Sine, 124.0, 102.0, 0.24, 0.17, 0.36).with_at(0.004),
            ])
            .noise(vec![bp(900.0, 1.0, 0.010, 0.06)]),
        Rim => Override::new(0.13)
            .tones(vec![tone(Wave::Square, 700.0, 580.0, 0.02, 0.28, 0.04)])
            .noise(vec![bp(1400.0, 1.1, 0.022, 0.32)]),
    }
}

/// An inharmonic sine stack under an 808-style hat. The partials are not
/// harmonics of one fundamental, which is what makes a hat read as metal
/// rather than as a pitched note.
fn metal_hat_tones(env: f32) -> Vec<ToneSpec> {
    const PARTIALS: [(f32, f32); 5] = [
        (6_200.0, 0.10),
        (8_300.0, 0.08),
        (10_400.0, 0.07),
        (12_700.0, 0.05),
        (15_100.0, 0.04),
    ];
    PARTIALS
        .iter()
        .map(|&(hz, gain)| tone(Wave::Sine, hz, hz, 0.01, gain, env))
        .collect()
}

/// The electronic powerhouse: a long sine sub with a click that reads on small
/// speakers, a pitched snare body, a wide long clap and metallic hats.
fn eight_oh_eight(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(1.35)
            .tones(vec![
                // The long sub: 1.18 s of 90 -> 32 Hz, with a second low sine
                // for weight and a 6 ms click so it still reads on a phone.
                tone(Wave::Sine, 90.0, 32.0, 0.80, 1.18, 1.10),
                tone(Wave::Sine, 55.0, 36.0, 0.85, 0.18, 1.00).with_at(0.008),
            ])
            .noise(vec![hp(4500.0, 0.006, 0.14)]),
        Snare => Override::new(0.32)
            .tones(vec![
                tone(Wave::Triangle, 185.0, 160.0, 0.12, 0.45, 0.17),
                tone(Wave::Triangle, 240.0, 215.0, 0.09, 0.15, 0.12).with_at(0.002),
            ])
            .noise(vec![
                bp(2200.0, 0.9, 0.17, 0.75),
                hp(5000.0, 0.04, 0.10),
            ]),
        ClosedHat => Override::new(0.18)
            .tones(metal_hat_tones(0.045))
            .noise(vec![hp(9500.0, 0.045, 0.35)]),
        OpenHat => Override::new(0.70)
            .tones(metal_hat_tones(0.52))
            .noise(vec![hp(8500.0, 0.40, 0.32)]),
        // Wider and longer than the four-burst clap: three tight cracks, a long
        // ring and a broad airy tail under it.
        Clap => Override::new(0.42).noise(vec![
            bp(1500.0, 1.0, 0.022, 0.50),
            bp(1500.0, 1.0, 0.022, 0.50).with_at(0.013),
            bp(1500.0, 1.0, 0.022, 0.50).with_at(0.026),
            bp(1500.0, 1.0, 0.20, 0.34).with_at(0.036),
            bp(2400.0, 0.8, 0.24, 0.16).with_at(0.05),
        ]),
        LowTom => Override::new(0.85)
            .tones(vec![
                tone(Wave::Sine, 100.0, 45.0, 0.45, 0.95, 0.62),
                tone(Wave::Sine, 52.0, 42.0, 0.45, 0.18, 0.55).with_at(0.005),
            ]),
        HighTom => Override::new(0.55)
            .tones(vec![
                tone(Wave::Sine, 185.0, 85.0, 0.30, 0.85, 0.42),
                tone(Wave::Sine, 92.0, 80.0, 0.30, 0.15, 0.36).with_at(0.005),
            ]),
        Rim => Override::new(0.10)
            .tones(vec![
                tone(Wave::Square, 1700.0, 1400.0, 0.012, 0.30, 0.03),
                tone(Wave::Sine, 2600.0, 2600.0, 0.01, 0.08, 0.025).with_at(0.001),
            ])
            .noise(vec![bp(4500.0, 1.8, 0.012, 0.40)]),
    }
}

/// Gated and aggressive: a clicky kick, a cracky snare that stops dead, and
/// cutting hats.
fn metal(voice: Voice) -> Override {
    use Voice::*;
    match voice {
        Kick => Override::new(0.24)
            .tones(vec![
                tone(Wave::Sine, 205.0, 62.0, 0.05, 0.92, 0.12),
                tone(Wave::Sine, 100.0, 60.0, 0.05, 0.08, 0.08).with_at(0.002),
            ])
            .noise(vec![hp(6200.0, 0.018, 0.45)]),
        Snare => Override::new(0.20)
            .tones(vec![tone(Wave::Triangle, 285.0, 235.0, 0.055, 0.42, 0.08)])
            .noise(vec![
                bp(3500.0, 0.7, 0.09, 0.85),
                hp(7200.0, 0.05, 0.22),
            ]),
        ClosedHat => Override::new(0.09).noise(vec![hp(10500.0, 0.028, 0.62)]),
        OpenHat => Override::new(0.24).noise(vec![hp(10000.0, 0.16, 0.55)]),
        Clap => clap_override(2600.0, 1.9, 0.62, 0.07),
        LowTom => Override::new(0.30)
            .tones(vec![
                tone(Wave::Sine, 155.0, 78.0, 0.13, 0.90, 0.20),
                tone(Wave::Sine, 78.0, 74.0, 0.13, 0.12, 0.16).with_at(0.002),
            ])
            .noise(vec![bp(900.0, 1.3, 0.010, 0.12)]),
        HighTom => Override::new(0.24)
            .tones(vec![
                tone(Wave::Sine, 280.0, 150.0, 0.10, 0.85, 0.15),
                tone(Wave::Sine, 150.0, 145.0, 0.10, 0.10, 0.12).with_at(0.002),
            ]),
        Rim => Override::new(0.09)
            .tones(vec![tone(Wave::Square, 1500.0, 1200.0, 0.012, 0.34, 0.025)])
            .noise(vec![bp(4200.0, 1.9, 0.012, 0.50)]),
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
    use crate::{render_voice_with_seed, voice_seed};

    const RATE: u32 = 44_100;

    /// The lengths of the engine's ten kits, in `Voice::ALL` order. These are
    /// no longer `studioDrumsKitSpecs`: the redesign lengthens the acoustic ring
    /// and the 808 sub, and shortens the electronic and metal voices. The clap
    /// length is still its tail plus 0.2, as `studioDrumsClapSpec` builds it.
    const EXPECTED_LENGTHS: [(Kit, [f32; 8]); 10] = [
        (Kit::Acoustic, [0.52, 0.36, 0.12, 0.42, 0.32, 0.44, 0.34, 0.11]),
        (Kit::Electronic, [0.26, 0.18, 0.08, 0.20, 0.26, 0.24, 0.18, 0.06]),
        (Kit::Techno, [0.36, 0.22, 0.07, 0.26, 0.28, 0.34, 0.26, 0.09]),
        (Kit::Beats, [0.85, 0.34, 0.13, 0.50, 0.30, 0.62, 0.44, 0.12]),
        (Kit::Latin, [0.24, 0.16, 0.12, 0.24, 0.25, 0.32, 0.26, 0.08]),
        (Kit::Pearl, [0.58, 0.42, 0.15, 0.50, 0.32, 0.55, 0.44, 0.14]),
        (Kit::Tama, [0.34, 0.26, 0.09, 0.30, 0.29, 0.40, 0.30, 0.10]),
        (Kit::Gretsch, [0.62, 0.38, 0.13, 0.46, 0.32, 0.56, 0.46, 0.13]),
        (Kit::EightOhEight, [1.35, 0.32, 0.18, 0.70, 0.42, 0.85, 0.55, 0.10]),
        (Kit::Metal, [0.24, 0.20, 0.09, 0.24, 0.27, 0.30, 0.24, 0.09]),
    ];

    fn close(a: f32, b: f32) -> bool {
        (a - b).abs() < 1e-5
    }

    fn render(kit: Kit, voice: Voice) -> Vec<f32> {
        render_voice_with_seed(&kit.spec(voice), RATE, voice_seed(voice))
    }

    fn energy(samples: &[f32]) -> f64 {
        samples.iter().map(|&s| (s as f64) * (s as f64)).sum()
    }

    fn peak(samples: &[f32]) -> f32 {
        samples
            .iter()
            .fold(0.0f32, |loudest, sample| loudest.max(sample.abs()))
    }

    fn prefix(samples: &[f32], seconds: f32) -> &[f32] {
        let frames = (seconds as f64 * RATE as f64) as usize;
        &samples[..frames.min(samples.len())]
    }

    /// A one-pole low-pass: the cheap, stable band measure the character tests
    /// use instead of a spectrum.
    fn lowpassed(samples: &[f32], cutoff_hz: f32) -> Vec<f32> {
        let coefficient =
            1.0 - (-std::f64::consts::TAU * cutoff_hz as f64 / RATE as f64).exp();
        let mut state = 0.0f64;
        samples
            .iter()
            .map(|&sample| {
                state += coefficient * (sample as f64 - state);
                state as f32
            })
            .collect()
    }

    /// Energy below (`high == false`) or above a cutoff, by subtracting a
    /// one-pole low-pass from the signal for the high band.
    fn band_energy(samples: &[f32], cutoff_hz: f32, high: bool) -> f64 {
        let low = lowpassed(samples, cutoff_hz);
        if high {
            let high: Vec<f32> = samples
                .iter()
                .zip(&low)
                .map(|(&sample, &bass)| sample - bass)
                .collect();
            energy(&high)
        } else {
            energy(&low)
        }
    }

    /// The last sample above -60 dB of the voice's own peak, as seconds.
    fn tail_seconds(samples: &[f32]) -> f64 {
        let threshold = (peak(samples) as f64 * 0.001).max(1e-4);
        let last = samples
            .iter()
            .rposition(|sample| sample.abs() as f64 > threshold)
            .unwrap_or(0);
        last as f64 / RATE as f64
    }

    /// Zero-crossing rate over the whole slice: a cheap pitch/brightness proxy.
    fn zero_crossing_rate(samples: &[f32]) -> f64 {
        if samples.len() < 2 {
            return 0.0;
        }
        let crossings = samples
            .windows(2)
            .filter(|pair| (pair[0] >= 0.0) != (pair[1] >= 0.0))
            .count();
        crossings as f64 / samples.len() as f64
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
    fn lengths_match_the_engine_kit_table() {
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

    /// The browser's 808 kick was a 90 -> 28 Hz sine over 0.70 s. The engine's
    /// powerhouse starts at the same 90 Hz but falls to 32 Hz over 0.80 s with
    /// a 1.10 s envelope, adds a second low sine for weight and a 6 ms click so
    /// it still reads on a small speaker. `the_808_kick_has_more_sub` measures
    /// that this is audible, not just a table entry.
    #[test]
    fn the_808_kick_is_the_long_sub() {
        let spec = Kit::EightOhEight.spec(Voice::Kick);
        let sub = &spec.tones[0];
        assert!(close(sub.from_hz, 90.0));
        assert!(close(sub.to_hz, 32.0));
        assert!(close(sub.dur, 0.80));
        assert!(close(sub.gain, 1.18));
        assert!(close(sub.env, 1.10));
        assert!(spec.tones.len() >= 2, "the 808 kick lost its second low body");
        let click = &spec.noise[0];
        assert_eq!(click.filter, FilterKind::Highpass);
        assert!(close(click.freq, 4500.0));
        assert!(close(click.dur, 0.006));
        assert!(close(click.gain, 0.14));
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

    #[test]
    fn a_kit_override_replaces_the_base_voice_whole() {
        let spec = Kit::Techno.spec(Voice::Snare);
        assert!(close(spec.length_seconds, 0.22));
        assert_eq!(spec.tones.len(), 1);
        assert!(close(spec.tones[0].from_hz, 225.0));
        assert!(close(spec.tones[0].to_hz, 165.0));
        assert!(close(spec.tones[0].gain, 0.45));
        assert!(close(spec.noise[0].freq, 1800.0));
        assert!(close(spec.noise[0].q, 0.7));
        assert!(close(spec.noise[0].gain, 0.90));
        assert_eq!(spec.noise.len(), 2);
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

    /// Every voice of every kit must be audible and bounded. The bound is
    /// deliberately above 1.0 because a kick layers a body and a sub and a
    /// snare layers a wire set and a crack, so the sum can pass full scale
    /// before the engine's master chain, as the browser's destination would
    /// clip it there. The loudest measured voice in the redesigned data is
    /// 1.29, so 1.5 remains the guarantee.
    #[test]
    fn every_kit_renders_audible_finite_bounded_audio() {
        const PEAK_BOUND: f32 = 1.5;
        for kit in Kit::ALL {
            for voice in Voice::ALL {
                let rendered = render(kit, voice);
                assert!(!rendered.is_empty(), "{} {}", kit.name(), voice.name());
                assert!(
                    rendered.iter().all(|sample| sample.is_finite()),
                    "{} {} has a non-finite sample",
                    kit.name(),
                    voice.name()
                );
                let loudest = peak(&rendered);
                assert!(
                    loudest > 0.01,
                    "{} {} is silent (peak {loudest})",
                    kit.name(),
                    voice.name()
                );
                assert!(
                    loudest <= PEAK_BOUND,
                    "{} {} peak {loudest} exceeds {PEAK_BOUND}",
                    kit.name(),
                    voice.name()
                );
            }
        }
    }

    /// The first regression: if a future edit collapses two kits back onto the
    /// same voice table, two kicks render the identical buffer.
    #[test]
    fn every_kits_kick_is_its_own() {
        for (index, first) in Kit::ALL.iter().enumerate() {
            for second in &Kit::ALL[index + 1..] {
                assert_ne!(
                    render(*first, Voice::Kick),
                    render(*second, Voice::Kick),
                    "{} and {} render the same kick",
                    first.name(),
                    second.name()
                );
            }
        }
    }

    /// A kit that only shades one voice is not a kit. Every override table must
    /// change at least two of the eight rendered voices relative to Acoustic.
    #[test]
    fn every_kit_changes_at_least_two_voices_from_acoustic() {
        for kit in Kit::ALL {
            if kit == Kit::Acoustic {
                continue;
            }
            let changed = Voice::ALL
                .iter()
                .filter(|&&voice| render(kit, voice) != render(Kit::Acoustic, voice))
                .count();
            assert!(
                changed >= 2,
                "{} changes only {changed} voice(s) from acoustic",
                kit.name()
            );
        }
    }

    /// The 808's declared character: substantially more energy under 100 Hz and
    /// a longer tail than the acoustic kick. Measured over the first half
    /// second, which both buffers cover, so the longer 808 buffer does not win
    /// on length alone.
    #[test]
    fn the_808_kick_has_more_sub_and_a_longer_tail() {
        let acoustic = render(Kit::Acoustic, Voice::Kick);
        let eight = render(Kit::EightOhEight, Voice::Kick);
        let sub = |samples: &[f32]| band_energy(prefix(samples, 0.50), 100.0, false);
        let ratio = sub(&eight) / sub(&acoustic);
        assert!(
            ratio > 1.5,
            "808 kick sub energy is only {ratio:.2}x acoustic"
        );
        let acoustic_tail = tail_seconds(&acoustic);
        let eight_tail = tail_seconds(&eight);
        assert!(
            eight_tail > acoustic_tail + 0.25,
            "808 kick tail {eight_tail:.3}s is not clearly longer than acoustic {acoustic_tail:.3}s"
        );
    }

    /// Gretsch is the woody kit: its beater is a soft 1.4 kHz band, not the
    /// metal kit's high-pass crack. Metal's click energy in the first 50 ms
    /// must stay well above Gretsch's, and Gretsch must carry the low body.
    #[test]
    fn the_gretsch_kick_is_woodier_than_the_metal_kick() {
        let gretsch = render(Kit::Gretsch, Voice::Kick);
        let metal = render(Kit::Metal, Voice::Kick);
        let click = |samples: &[f32]| band_energy(prefix(samples, 0.05), 3000.0, true);
        let body = |samples: &[f32]| band_energy(prefix(samples, 0.24), 150.0, false);
        let gretsch_click = click(&gretsch);
        let metal_click = click(&metal);
        assert!(
            gretsch_click * 2.0 < metal_click,
            "gretsch click energy {gretsch_click:.4} is not well below metal {metal_click:.4}"
        );
        let gretsch_body = body(&gretsch);
        let metal_body = body(&metal);
        assert!(
            gretsch_body > metal_body * 1.5,
            "gretsch low body {gretsch_body:.4} is not warmer than metal {metal_body:.4}"
        );
    }

    /// The woody kit's toms drop further in pitch and ring longer than the
    /// acoustic reference. This catches a tom that keeps the base sweep.
    #[test]
    fn the_gretsch_toms_drop_further_and_ring_longer() {
        for voice in [Voice::LowTom, Voice::HighTom] {
            let acoustic = Kit::Acoustic.spec(voice);
            let gretsch = Kit::Gretsch.spec(voice);
            let drop = |spec: &VoiceSpec| spec.tones[0].from_hz / spec.tones[0].to_hz;
            assert!(
                drop(&gretsch) > drop(&acoustic) * 1.3,
                "{}: gretsch drop {:.2} is not clearly wider than acoustic {:.2}",
                voice.name(),
                drop(&gretsch),
                drop(&acoustic)
            );
            let acoustic_tail = tail_seconds(&render(Kit::Acoustic, voice));
            let gretsch_tail = tail_seconds(&render(Kit::Gretsch, voice));
            assert!(
                gretsch_tail > acoustic_tail + 0.05,
                "{}: gretsch tail {gretsch_tail:.3}s does not ring past acoustic {acoustic_tail:.3}s",
                voice.name()
            );
        }
    }

    /// The 808 snare has a pitched body and a long ring; the metal snare is
    /// gated and must stop clearly sooner, measured to -60 dB.
    #[test]
    fn the_metal_snare_is_tighter_than_the_808_snare() {
        let metal = render(Kit::Metal, Voice::Snare);
        let eight = render(Kit::EightOhEight, Voice::Snare);
        let metal_tail = tail_seconds(&metal);
        let eight_tail = tail_seconds(&eight);
        assert!(
            metal_tail * 1.3 < eight_tail,
            "metal snare tail {metal_tail:.3}s is not clearly tighter than 808 {eight_tail:.3}s"
        );
        assert!(
            Kit::Metal.spec(Voice::Snare).length_seconds
                < Kit::EightOhEight.spec(Voice::Snare).length_seconds
        );
        assert!(
            Kit::EightOhEight.spec(Voice::Snare).tones.len() >= 2,
            "the 808 snare lost its pitched body"
        );
    }

    /// The 808 clap is wide and long: more bursts than the four-burst base, the
    /// final tail starting late, and a longer -60 dB ring than the acoustic clap.
    #[test]
    fn the_808_clap_is_wide_and_long() {
        let eight = Kit::EightOhEight.spec(Voice::Clap);
        let acoustic = Kit::Acoustic.spec(Voice::Clap);
        assert!(eight.noise.len() > acoustic.noise.len());
        let last = eight.noise.last().expect("the 808 clap has no bursts");
        assert!(
            last.at >= 0.04,
            "the 808 clap's last burst starts at {:.3}s",
            last.at
        );
        assert!(eight.length_seconds >= 0.40);
        let eight_tail = tail_seconds(&render(Kit::EightOhEight, Voice::Clap));
        let acoustic_tail = tail_seconds(&render(Kit::Acoustic, Voice::Clap));
        assert!(
            eight_tail > acoustic_tail + 0.05,
            "808 clap tail {eight_tail:.3}s is not longer than acoustic {acoustic_tail:.3}s"
        );
    }

    /// The 808 hats are a metallic inharmonic stack under noise, not one noise
    /// burst. If the stack is removed the hats collapse back to the base sound.
    #[test]
    fn the_808_hats_are_metallic() {
        for voice in [Voice::ClosedHat, Voice::OpenHat] {
            let spec = Kit::EightOhEight.spec(voice);
            assert!(
                spec.tones.len() >= 4,
                "{} lost its inharmonic tone stack",
                voice.name()
            );
            let mut frequencies: Vec<f32> = spec.tones.iter().map(|t| t.from_hz).collect();
            frequencies.sort_by(|a, b| a.partial_cmp(b).unwrap());
            frequencies.dedup();
            assert!(frequencies.len() >= 4, "{} has repeated partials", voice.name());
            assert!(spec.noise.iter().any(|n| n.filter == FilterKind::Highpass));
        }
        assert!(Kit::EightOhEight.spec(Voice::OpenHat).length_seconds >= 0.60);
    }

    /// Latin reads as hand percussion: its low tom sits well above the
    /// acoustic low tom, its kick is short, and its rim is dry.
    #[test]
    fn the_latin_kit_is_high_and_dry() {
        let latin_tom = zero_crossing_rate(prefix(&render(Kit::Latin, Voice::LowTom), 0.12));
        let acoustic_tom =
            zero_crossing_rate(prefix(&render(Kit::Acoustic, Voice::LowTom), 0.12));
        assert!(
            latin_tom > acoustic_tom * 1.3,
            "latin low tom zcr {latin_tom:.4} is not clearly above acoustic {acoustic_tom:.4}"
        );
        assert!(
            Kit::Latin.spec(Voice::Kick).length_seconds
                < Kit::Acoustic.spec(Voice::Kick).length_seconds
        );
        let latin_rim = tail_seconds(&render(Kit::Latin, Voice::Rim));
        let acoustic_rim = tail_seconds(&render(Kit::Acoustic, Voice::Rim));
        assert!(
            latin_rim < acoustic_rim,
            "latin rim tail {latin_rim:.3}s is not drier than acoustic {acoustic_rim:.3}s"
        );
    }

    /// Pearl is the deep one, Tama the cutting one: the same kick comparison
    /// across the two kits must show Pearl heavier below 100 Hz and Tama
    /// brighter above 3 kHz.
    #[test]
    fn pearl_is_deep_and_tama_is_cutting() {
        let pearl = render(Kit::Pearl, Voice::Kick);
        let tama = render(Kit::Tama, Voice::Kick);
        let sub = |samples: &[f32]| band_energy(prefix(samples, 0.24), 100.0, false);
        let click = |samples: &[f32]| band_energy(prefix(samples, 0.05), 3000.0, true);
        assert!(
            sub(&pearl) > sub(&tama) * 1.3,
            "pearl sub {:.4} is not deeper than tama {:.4}",
            sub(&pearl),
            sub(&tama)
        );
        assert!(
            click(&tama) > click(&pearl) * 1.3,
            "tama click {:.4} is not cutting past pearl {:.4}",
            click(&tama),
            click(&pearl)
        );
    }

    /// Beats is the roomy, laid-back kit: both its kick and its snare must ring
    /// clearly longer than Techno's dry ones.
    #[test]
    fn beats_is_roomier_than_techno() {
        let beats_kick = tail_seconds(&render(Kit::Beats, Voice::Kick));
        let techno_kick = tail_seconds(&render(Kit::Techno, Voice::Kick));
        assert!(
            beats_kick > techno_kick + 0.20,
            "beats kick tail {beats_kick:.3}s is not roomier than techno {techno_kick:.3}s"
        );
        let beats_snare = tail_seconds(&render(Kit::Beats, Voice::Snare));
        let techno_snare = tail_seconds(&render(Kit::Techno, Voice::Snare));
        assert!(
            beats_snare > techno_snare,
            "beats snare tail {beats_snare:.3}s does not ring past techno {techno_snare:.3}s"
        );
    }

    /// Electronic is the synthetic, tight kit: its kick and its closed hat must
    /// be clearly shorter-lived than the acoustic ones.
    #[test]
    fn electronic_is_tight() {
        let electronic_kick = tail_seconds(&render(Kit::Electronic, Voice::Kick));
        let acoustic_kick = tail_seconds(&render(Kit::Acoustic, Voice::Kick));
        assert!(
            electronic_kick + 0.15 < acoustic_kick,
            "electronic kick tail {electronic_kick:.3}s is not tighter than acoustic {acoustic_kick:.3}s"
        );
        let electronic_hat = tail_seconds(&render(Kit::Electronic, Voice::ClosedHat));
        let acoustic_hat = tail_seconds(&render(Kit::Acoustic, Voice::ClosedHat));
        assert!(
            electronic_hat < acoustic_hat,
            "electronic hat tail {electronic_hat:.3}s is not tighter than acoustic {acoustic_hat:.3}s"
        );
    }
}
