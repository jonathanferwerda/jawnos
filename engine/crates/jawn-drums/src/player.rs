//! Drummers: named players who each have a way of sitting on the chart.
//!
//! A [`Pattern`](crate::Pattern) and a chart are the skeleton: which sixteenths
//! sound and how hard the grid says they are. A [`Player`] is the person playing
//! that skeleton. A player bends each hit a few milliseconds off the grid,
//! narrows or widens the velocities, and leans on the metre, so the same chart
//! stops sounding stamped out of a machine.
//!
//! [`Style`] is the second axis: the same player can play soft, hard or
//! aggressive, and the style scales the whole performance. Naming a player and
//! leaving the style alone uses the player's own style (see
//! [`Player::style`]); naming only a style plays it through [`Player::Studio`],
//! the uncoloured house player.
//!
//! Everything here is deterministic. [`Performance::play`] is a pure function of
//! the chart cell, the absolute step and the player/style, so a chart renders
//! identically on every machine, each pass of a loop differs from the last, and
//! the audio thread allocates nothing.

use crate::Voice;

/// How hard a player is playing: soft, hard or aggressive.
///
/// The style sets the level (a fraction of the chart's velocity), how wide the
/// dynamics are, how much a strong beat is accented, and how far behind the grid
/// the player sits. A player then tints those numbers with their own habits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Style {
    /// Brushes and a quiet foot: rounder, softer, sitting back.
    Soft,
    /// A firm, even backbeat that keeps its place.
    Hard,
    /// Leaning into the kit: wide dynamics and heavy accents.
    Aggressive,
}

impl Style {
    /// Every style, from the quietest to the loudest.
    pub const ALL: [Style; 3] = [Style::Soft, Style::Hard, Style::Aggressive];

    /// The wire name the socket and a saved song use.
    pub const fn name(self) -> &'static str {
        match self {
            Style::Soft => "soft",
            Style::Hard => "hard",
            Style::Aggressive => "aggressive",
        }
    }

    /// The style with this exact wire name, case-sensitive. Unknown names return
    /// `None`.
    pub fn from_name(name: &str) -> Option<Style> {
        Style::ALL.iter().copied().find(|style| style.name() == name)
    }

    /// The style's numbers before a player bends them.
    const fn base(self) -> Profile {
        match self {
            Style::Soft => Profile {
                level: 0.76,
                spread: 4.0,
                accent: 3.0,
                lateness: 0.009,
                time_spread: 0.0012,
                swing: 0.0,
            },
            Style::Hard => Profile {
                level: 0.91,
                spread: 7.0,
                accent: 6.0,
                lateness: 0.003,
                time_spread: 0.0009,
                swing: 0.0,
            },
            Style::Aggressive => Profile {
                level: 1.02,
                spread: 12.0,
                accent: 10.0,
                lateness: 0.0008,
                time_spread: 0.0007,
                swing: 0.0,
            },
        }
    }
}

/// One of the players who can sit on a drum chart.
///
/// [`Player::Studio`] is the uncoloured house player: no swing, no timing
/// habit, no voice bias. The other six are characters with a default style and
/// a way of playing, in the spirit of a Drummer in GarageBand:
///
/// | Player | Style | How they play |
/// | --- | --- | --- |
/// | [`Player::Tuck`] | soft | Brushes and a lazy backbeat: sits behind the click and rounds the snare. |
/// | [`Player::Wren`] | soft | Swings the offbeat sixteenths and keeps the hats light. |
/// | [`Player::Odile`] | hard | On the grid and dry: a tight backbeat that never rushes. |
/// | [`Player::Moxie`] | hard | Steady four-on-the-floor; the kick leads and the hats stay even. |
/// | [`Player::Bram`] | aggressive | Leans into the kit: a big snare and a kick right on the click. |
/// | [`Player::Dov`] | aggressive | Punk energy: wide dynamics and heavy accents, no patience for a soft bar. |
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Player {
    /// The house player: the grid with no colour, for a style on its own.
    Studio,
    /// Soft, behind the beat, warm.
    Tuck,
    /// Soft, swinging offbeat hats, light hands.
    Wren,
    /// Hard, dry and on the grid.
    Odile,
    /// Hard, steady four-on-the-floor.
    Moxie,
    /// Aggressive, right on the click.
    Bram,
    /// Aggressive, wide and loud.
    Dov,
}

impl Player {
    /// Every player, house player first.
    pub const ALL: [Player; 7] = [
        Player::Studio,
        Player::Tuck,
        Player::Wren,
        Player::Odile,
        Player::Moxie,
        Player::Bram,
        Player::Dov,
    ];

    /// The wire name the socket and a saved song use.
    pub const fn name(self) -> &'static str {
        match self {
            Player::Studio => "studio",
            Player::Tuck => "tuck",
            Player::Wren => "wren",
            Player::Odile => "odile",
            Player::Moxie => "moxie",
            Player::Bram => "bram",
            Player::Dov => "dov",
        }
    }

    /// The player with this exact wire name, case-sensitive. Unknown names
    /// return `None`.
    pub fn from_name(name: &str) -> Option<Player> {
        Player::ALL
            .iter()
            .copied()
            .find(|player| player.name() == name)
    }

    /// The style this player plays when the caller does not name one.
    pub const fn style(self) -> Style {
        match self {
            Player::Studio | Player::Odile | Player::Moxie => Style::Hard,
            Player::Tuck | Player::Wren => Style::Soft,
            Player::Bram | Player::Dov => Style::Aggressive,
        }
    }

    /// One sentence on how this player plays, for a picker or a help line.
    pub const fn character(self) -> &'static str {
        match self {
            Player::Studio => "The house player: on the grid, no swing. The style alone shapes the hit.",
            Player::Tuck => "Brushes and a lazy backbeat. Sits behind the click and rounds the snare.",
            Player::Wren => "Swings the offbeat sixteenths and keeps the hats light.",
            Player::Odile => "On the grid and dry. A tight backbeat that never rushes.",
            Player::Moxie => "Steady four-on-the-floor. The kick leads and the hats stay even.",
            Player::Bram => "Leans into the kit: a big snare and a kick right on the click.",
            Player::Dov => "Punk energy. Wide dynamics and heavy accents, no patience for a soft bar.",
        }
    }

    /// This player's habits, applied on top of the style's numbers.
    const fn tweak(self) -> Tweak {
        match self {
            Player::Studio => Tweak::NEUTRAL,
            // Sits back a touch and keeps the hats out of the way.
            Player::Tuck => Tweak {
                level: 0.96,
                accent: 0.85,
                spread: 0.85,
                lateness: 0.004,
                swing: 0.0,
                kick: 0.0,
                snare: -1.0,
                hat: -3.0,
                other: 0.0,
            },
            // The offbeat sixteenth waits; the hats are the tell.
            Player::Wren => Tweak {
                level: 0.97,
                accent: 0.90,
                spread: 1.10,
                lateness: 0.005,
                swing: 0.20,
                kick: -1.0,
                snare: -2.0,
                hat: -2.0,
                other: 0.0,
            },
            // A metronome with a pulse: almost no timing wobble.
            Player::Odile => Tweak {
                level: 1.02,
                accent: 1.10,
                spread: 0.80,
                lateness: -0.002,
                swing: 0.0,
                kick: 1.0,
                snare: 2.0,
                hat: 0.0,
                other: 0.0,
            },
            // The kick carries it; the sixteenths stay even.
            Player::Moxie => Tweak {
                level: 1.00,
                accent: 1.00,
                spread: 0.90,
                lateness: 0.0,
                swing: 0.0,
                kick: 3.0,
                snare: 1.0,
                hat: -2.0,
                other: 0.0,
            },
            // Big backbeat, right on the click.
            Player::Bram => Tweak {
                level: 1.05,
                accent: 1.20,
                spread: 1.15,
                lateness: -0.006,
                swing: 0.0,
                kick: 2.0,
                snare: 4.0,
                hat: -1.0,
                other: 1.0,
            },
            // Loud and unsubtle, with the toms in the room.
            Player::Dov => Tweak {
                level: 1.06,
                accent: 1.30,
                spread: 1.30,
                lateness: -0.002,
                swing: 0.0,
                kick: 2.0,
                snare: 3.0,
                hat: -2.0,
                other: 2.0,
            },
        }
    }
}

/// A player and the style they are playing, ready to shape a chart step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Performance {
    /// Who is playing.
    pub player: Player,
    /// How hard they are playing.
    pub style: Style,
}

impl Performance {
    /// A performance by `player` in `style`.
    pub const fn new(player: Player, style: Style) -> Self {
        Performance { player, style }
    }

    /// A player playing their own style.
    pub const fn of(player: Player) -> Self {
        Performance {
            player,
            style: player.style(),
        }
    }

    /// Shape one chart cell.
    ///
    /// `velocity` is the chart's own `1..=100`; `0` is an empty step and stays
    /// empty. `step` is the absolute sixteenth since the chart began, so each
    /// pass of a loop is a little different; `metric_step` is the position in
    /// the chart (a multiple of 16 is a bar) and sets where the accents fall.
    /// `step_frames` is the sixteenth's length at this tempo and `rate` the
    /// sample rate, which turn the timing feel into a frame offset.
    ///
    /// The offset is always at or after the grid: a player can sit back, but
    /// this engine does not schedule ahead of the block it is rendering.
    pub fn play(
        &self,
        voice: Voice,
        velocity: u8,
        step: u64,
        metric_step: usize,
        step_frames: f64,
        rate: u32,
    ) -> Played {
        if velocity == 0 || rate == 0 {
            return Played {
                velocity: 0,
                offset_frames: 0,
            };
        }
        let profile = self.profile();
        let unit = hash_unit(step, voice, 0x51ED_0000_0000_0001);
        let accent = accent_at(voice, metric_step) * profile.accent;
        let points = velocity as f32 * profile.level
            + voice_bias(self.player, voice)
            + (unit * 2.0 - 1.0) * profile.spread
            + accent;
        let velocity = points.round().clamp(1.0, 100.0) as u8;

        let timing = hash_unit(step, voice, 0xA11E_0000_0000_0001);
        let jitter = (timing * 2.0 - 1.0) * profile.time_spread;
        let swing = if swings(voice) && metric_step % 2 == 1 {
            // Half the requested fraction: 0.20 is a shade under a triplet.
            f64::from(profile.swing) * (step_frames / f64::from(rate)) * 0.5
        } else {
            0.0
        };
        let seconds = (f64::from(profile.lateness) + f64::from(jitter) + swing).max(0.0);
        let offset_frames = (seconds * f64::from(rate)).round() as usize;

        Played {
            velocity,
            offset_frames,
        }
    }

    /// The player's habits over the style's numbers.
    fn profile(self) -> Profile {
        let base = self.style.base();
        let tweak = self.player.tweak();
        Profile {
            level: base.level * tweak.level,
            spread: base.spread * tweak.spread,
            accent: base.accent * tweak.accent,
            lateness: (base.lateness + tweak.lateness).max(0.0),
            time_spread: base.time_spread,
            swing: base.swing.max(tweak.swing),
        }
    }
}

/// One chart cell after the player has touched it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Played {
    /// The velocity to trigger, `1..=100`.
    pub velocity: u8,
    /// How many frames after the step boundary the hit lands.
    pub offset_frames: usize,
}

/// The numeric feel of one performance.
#[derive(Debug, Clone, Copy)]
struct Profile {
    /// Multiplier on the chart's own velocity.
    level: f32,
    /// Pseudo-random velocity wobble, in velocity points either way.
    spread: f32,
    /// Velocity points added on a strong beat.
    accent: f32,
    /// How far behind the grid the player sits, in seconds.
    lateness: f32,
    /// Timing wobble either way, in seconds.
    time_spread: f32,
    /// How far the second sixteenth of a pair waits, as a fraction of a step.
    swing: f32,
}

/// A player's additions to a style's profile.
#[derive(Debug, Clone, Copy)]
struct Tweak {
    level: f32,
    accent: f32,
    spread: f32,
    lateness: f32,
    swing: f32,
    kick: f32,
    snare: f32,
    hat: f32,
    other: f32,
}

impl Tweak {
    /// No colour at all: the house player.
    const NEUTRAL: Tweak = Tweak {
        level: 1.0,
        accent: 1.0,
        spread: 1.0,
        lateness: 0.0,
        swing: 0.0,
        kick: 0.0,
        snare: 0.0,
        hat: 0.0,
        other: 0.0,
    };
}

/// The player's own voice balance, in velocity points.
fn voice_bias(player: Player, voice: Voice) -> f32 {
    let tweak = player.tweak();
    match voice {
        Voice::Kick => tweak.kick,
        Voice::Snare | Voice::Clap => tweak.snare,
        Voice::ClosedHat | Voice::OpenHat => tweak.hat,
        Voice::LowTom | Voice::HighTom | Voice::Rim => tweak.other,
    }
}

/// How much a voice wants an accent at this metrical position, `0..=1`.
///
/// The chart's own velocities are the skeleton, so this is deliberately
/// restrained: it marks the downbeat, the backbeat and the quarter pulse rather
/// than inventing a new pattern.
fn accent_at(voice: Voice, metric_step: usize) -> f32 {
    let step = metric_step % 16;
    let quarter = step % 4 == 0;
    match voice {
        Voice::Kick => {
            if step == 0 || step == 8 {
                1.0
            } else if quarter {
                0.5
            } else {
                0.0
            }
        }
        Voice::Snare | Voice::Clap => {
            if step == 4 || step == 12 {
                1.0
            } else if step % 2 == 0 {
                0.3
            } else {
                0.0
            }
        }
        Voice::Rim => {
            if step == 4 || step == 12 {
                0.5
            } else {
                0.0
            }
        }
        Voice::ClosedHat | Voice::OpenHat => {
            if quarter {
                0.35
            } else if step % 2 == 0 {
                0.15
            } else {
                0.0
            }
        }
        Voice::LowTom | Voice::HighTom => {
            if step % 8 == 0 {
                0.6
            } else {
                0.0
            }
        }
    }
}

/// Whether this voice feels the swing. The hats carry it; the feet and the
/// backbeat stay where the chart put them.
fn swings(voice: Voice) -> bool {
    matches!(voice, Voice::ClosedHat | Voice::OpenHat | Voice::Rim)
}

/// A deterministic value in `0..1` from a step, a voice and a salt.
///
/// SplitMix64's finalizer: cheap, stable across platforms, and no state to carry
/// between blocks. The salt keeps the velocity and timing streams independent.
fn hash_unit(step: u64, voice: Voice, salt: u64) -> f32 {
    let mut x = step
        .wrapping_mul(0x9E37_79B9_7F4A_7C15)
        .wrapping_add((voice.index() as u64).wrapping_mul(0xD1B5_4A32_D192_ED03))
        .wrapping_add(salt);
    x ^= x >> 30;
    x = x.wrapping_mul(0xBF58_476D_1CE4_E5B9);
    x ^= x >> 27;
    x = x.wrapping_mul(0x94D0_49BB_1331_11EB);
    x ^= x >> 31;
    // 24 bits is exact in an f32, and dividing by 2^24 only moves the exponent,
    // so the result is in [0, 1) without a rounding step that could reach 1.0.
    const SCALE: f32 = (1u64 << 24) as f32;
    ((x >> 40) as f32) / SCALE
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip() {
        for player in Player::ALL {
            assert_eq!(Player::from_name(player.name()), Some(player));
            assert!(!player.character().is_empty());
        }
        for style in Style::ALL {
            assert_eq!(Style::from_name(style.name()), Some(style));
        }
        assert_eq!(Player::from_name("Tuck"), None, "names are case-sensitive");
        assert_eq!(Style::from_name("loud"), None);
    }

    #[test]
    fn every_player_but_the_house_player_has_a_style_and_a_face() {
        for player in Player::ALL {
            let style = player.style();
            assert!(Style::ALL.contains(&style));
            assert!(!player.character().is_empty());
        }
    }

    #[test]
    fn soft_is_quieter_than_hard_than_aggressive_for_one_cell() {
        // Same step and voice, so all three share the same deterministic wobble:
        // only the style's level and accent move the answer.
        let cell = (Voice::Snare, 70u8, 4u64, 4usize);
        let soft = Performance::new(Player::Studio, Style::Soft).play(cell.0, cell.1, cell.2, cell.3, 6_000.0, 48_000);
        let hard = Performance::new(Player::Studio, Style::Hard).play(cell.0, cell.1, cell.2, cell.3, 6_000.0, 48_000);
        let aggressive = Performance::new(Player::Studio, Style::Aggressive).play(
            cell.0, cell.1, cell.2, cell.3, 6_000.0, 48_000,
        );
        assert!(
            soft.velocity < hard.velocity && hard.velocity < aggressive.velocity,
            "{} {} {}",
            soft.velocity,
            hard.velocity,
            aggressive.velocity
        );
    }

    #[test]
    fn a_softer_player_sits_further_behind_the_grid() {
        let soft = Performance::new(Player::Studio, Style::Soft).play(
            Voice::Kick, 100, 0, 0, 6_000.0, 48_000,
        );
        let aggressive = Performance::new(Player::Studio, Style::Aggressive).play(
            Voice::Kick, 100, 0, 0, 6_000.0, 48_000,
        );
        assert!(soft.offset_frames > aggressive.offset_frames);
        assert!(soft.offset_frames >= 48_000 / 200, "at least ~5 ms late");
    }

    #[test]
    fn the_same_cell_always_plays_the_same() {
        let performance = Performance::of(Player::Bram);
        let first = performance.play(Voice::Snare, 80, 9, 9, 6_000.0, 48_000);
        let second = performance.play(Voice::Snare, 80, 9, 9, 6_000.0, 48_000);
        assert_eq!(first, second);
    }

    #[test]
    fn each_pass_of_a_loop_gets_its_own_wobble() {
        let performance = Performance::of(Player::Dov);
        let first = performance.play(Voice::ClosedHat, 40, 3, 3, 6_000.0, 48_000);
        let second = performance.play(Voice::ClosedHat, 40, 3 + 16, 3, 6_000.0, 48_000);
        assert_ne!(first.velocity, second.velocity);
    }

    #[test]
    fn an_empty_step_stays_empty_and_on_the_grid() {
        for player in Player::ALL {
            for style in Style::ALL {
                let played = Performance::new(player, style).play(Voice::Kick, 0, 5, 5, 6_000.0, 48_000);
                assert_eq!(played.velocity, 0);
                assert_eq!(played.offset_frames, 0);
            }
        }
    }

    #[test]
    fn the_shape_stays_inside_one_to_a_hundred() {
        for player in Player::ALL {
            for style in Style::ALL {
                let performance = Performance::new(player, style);
                for velocity in [1u8, 50, 100] {
                    for step in 0..32u64 {
                        let played = performance.play(
                            Voice::Kick,
                            velocity,
                            step,
                            step as usize,
                            6_000.0,
                            48_000,
                        );
                        assert!((1..=100).contains(&played.velocity));
                        // A player may sit back but never schedules ahead.
                        assert!(played.offset_frames <= 48_000 / 40, "over 25 ms late");
                    }
                }
            }
        }
    }

    #[test]
    fn accents_land_on_the_downbeat_and_the_backbeat() {
        assert_eq!(accent_at(Voice::Kick, 0), 1.0);
        assert!(accent_at(Voice::Kick, 0) > accent_at(Voice::Kick, 1));
        assert!(accent_at(Voice::Kick, 4) > accent_at(Voice::Kick, 2));
        assert!(accent_at(Voice::Snare, 4) > accent_at(Voice::Snare, 2));
        assert!(accent_at(Voice::Snare, 4) > accent_at(Voice::ClosedHat, 4));
        assert_eq!(accent_at(Voice::Kick, 16), accent_at(Voice::Kick, 0));
    }

    #[test]
    fn swing_waits_the_second_sixteenth_of_a_pair() {
        let profile = Performance::new(Player::Wren, Style::Soft).profile();
        let show = profile.swing > 0.0;
        assert!(show, "Wren swings");
        let step = 6_000.0 / 48_000.0;
        let straight = Performance::new(Player::Wren, Style::Soft).play(
            Voice::ClosedHat,
            40,
            0,
            0,
            6_000.0,
            48_000,
        );
        let swung = Performance::new(Player::Wren, Style::Soft).play(
            Voice::ClosedHat,
            40,
            1,
            1,
            6_000.0,
            48_000,
        );
        // The swing alone is ~20 ms, far more than the timing wobble.
        let extra = swung.offset_frames as f32 / 48_000.0 - straight.offset_frames as f32 / 48_000.0;
        assert!(extra >= profile.swing * step * 0.5 * 0.5, "{extra}");
    }

    #[test]
    fn the_house_player_is_the_style_alone() {
        // Studio's tweak is neutral, so its profile is exactly the style's.
        for style in Style::ALL {
            let base = style.base();
            let studio = Performance::new(Player::Studio, style).profile();
            assert!((base.level - studio.level).abs() < 1e-6);
            assert!((base.spread - studio.spread).abs() < 1e-6);
            assert!((base.accent - studio.accent).abs() < 1e-6);
            assert!((base.lateness - studio.lateness).abs() < 1e-6);
        }
    }
}
