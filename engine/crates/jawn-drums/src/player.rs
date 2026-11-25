//! Drummers: named players who each have a way of sitting on the chart.
//!
//! A [`Pattern`](crate::Pattern) and a chart are the skeleton: which sixteenths
//! sound and how hard the grid says they are. A [`Player`] is the person playing
//! that skeleton. A player moves each hit behind the grid, widens or narrows the
//! velocities, swings the offbeats, and adds ghost notes or flams of their own,
//! so the same chart stops sounding stamped out of a machine.
//!
//! [`Style`] is the second axis: the same player can play timid, soft, moderate,
//! cool, hard or aggressive, and the style scales the whole performance. Naming
//! a player and leaving the style alone uses the player's own style (see
//! [`Player::style`]); naming only a style plays it through [`Player::Studio`],
//! the uncoloured house player.
//!
//! Everything here is deterministic. [`Performance::play`] is a pure function of
//! the chart cell, the absolute step and the player/style, so a chart renders
//! identically on every machine, each pass of a loop differs from the last, and
//! the audio thread allocates nothing.

use crate::Voice;

/// How a player is playing, from the quietest and most hesitant to the loudest
/// and most forward.
///
/// The style sets the level (a fraction of the chart's velocity), how wide the
/// dynamics are, how much a strong beat is accented, how far behind the grid the
/// player sits, how much the offbeats swing, and how often a ghost note or a
/// flam is added. A player then tints those numbers with their own habits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Style {
    /// Barely there: very soft, hesitant, late, and almost no accent.
    Timid,
    /// Brushes and a quiet foot: rounder, softer, sitting back.
    Soft,
    /// A middle setting: even hands, a normal backbeat, a little air.
    Moderate,
    /// Relaxed and swung: a loose pocket with ghost notes under it.
    Cool,
    /// A firm, even backbeat that keeps its place.
    Hard,
    /// Leaning into the kit: wide dynamics and heavy accents.
    Aggressive,
}

impl Style {
    /// Every style, from the quietest to the loudest.
    pub const ALL: [Style; 6] = [
        Style::Timid,
        Style::Soft,
        Style::Moderate,
        Style::Cool,
        Style::Hard,
        Style::Aggressive,
    ];

    /// The wire name the socket and a saved song use.
    pub const fn name(self) -> &'static str {
        match self {
            Style::Timid => "timid",
            Style::Soft => "soft",
            Style::Moderate => "moderate",
            Style::Cool => "cool",
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
            Style::Timid => Profile {
                level: 0.60,
                spread: 3.0,
                accent: 1.0,
                lateness: 0.018,
                time_spread: 0.0030,
                swing: 0.0,
                ghost_chance: 0.00,
                ghost_level: 0.15,
                ghost_delay: 0.024,
                flam_chance: 0.00,
                flam_level: 0.25,
                flam_delay: 0.014,
            },
            Style::Soft => Profile {
                level: 0.75,
                spread: 6.0,
                accent: 3.0,
                lateness: 0.011,
                time_spread: 0.0022,
                swing: 0.0,
                ghost_chance: 0.06,
                ghost_level: 0.18,
                ghost_delay: 0.026,
                flam_chance: 0.00,
                flam_level: 0.25,
                flam_delay: 0.014,
            },
            Style::Moderate => Profile {
                level: 0.88,
                spread: 10.0,
                accent: 6.0,
                lateness: 0.006,
                time_spread: 0.0018,
                swing: 0.0,
                ghost_chance: 0.10,
                ghost_level: 0.20,
                ghost_delay: 0.024,
                flam_chance: 0.04,
                flam_level: 0.28,
                flam_delay: 0.013,
            },
            Style::Cool => Profile {
                level: 0.92,
                spread: 9.0,
                accent: 4.0,
                lateness: 0.014,
                time_spread: 0.0032,
                swing: 0.28,
                ghost_chance: 0.18,
                ghost_level: 0.22,
                ghost_delay: 0.030,
                flam_chance: 0.05,
                flam_level: 0.28,
                flam_delay: 0.014,
            },
            Style::Hard => Profile {
                level: 1.00,
                spread: 14.0,
                accent: 9.0,
                lateness: 0.0025,
                time_spread: 0.0012,
                swing: 0.0,
                ghost_chance: 0.08,
                ghost_level: 0.22,
                ghost_delay: 0.018,
                flam_chance: 0.08,
                flam_level: 0.30,
                flam_delay: 0.012,
            },
            Style::Aggressive => Profile {
                level: 1.08,
                spread: 26.0,
                accent: 16.0,
                lateness: 0.0005,
                time_spread: 0.0010,
                swing: 0.0,
                ghost_chance: 0.10,
                ghost_level: 0.25,
                ghost_delay: 0.018,
                flam_chance: 0.20,
                flam_level: 0.35,
                flam_delay: 0.011,
            },
        }
    }
}

/// One of the players who can sit on a drum chart.
///
/// [`Player::Studio`] is the uncoloured house player: no swing, no timing
/// habit, no voice bias. The rest are characters with a default style and a way
/// of playing, in the spirit of a Drummer in GarageBand:
///
/// | Player | Style | How they play |
/// | --- | --- | --- |
/// | [`Player::Tuck`] | soft | Brushes and a lazy backbeat: far behind the click, quiet ghost snares. |
/// | [`Player::Wren`] | cool | Swings the offbeat sixteenths and rolls quiet ghost hits under the snare. |
/// | [`Player::Odile`] | hard | On the grid and dry: a tight backbeat that never rushes. |
/// | [`Player::Moxie`] | hard | Steady four-on-the-floor; the kick leads and the hats stay even. |
/// | [`Player::Bram`] | aggressive | Leans into the kit: a big snare, kick on the click, hard flams. |
/// | [`Player::Dov`] | aggressive | Punk energy: wide dynamics, heavy accents, a flam on every other hit. |
/// | [`Player::Marla`] | cool | Loose and busy: swung offbeats, ghost notes and flams under a light backbeat. |
/// | [`Player::Ines`] | timid | Timid and late: soft hands, few accents, a breath behind the click. |
/// | [`Player::Juno`] | moderate | Relaxed in the pocket: a loose kick, a lazy snare, low ghost notes. |
/// | [`Player::Sable`] | aggressive | Heavy and wide: big snare flams, hard accents, no ghost notes. |
/// | [`Player::Nell`] | moderate | Steady and even: a plain backbeat with a few quiet ghosts. |
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Player {
    /// The house player: the grid with no colour, for a style on its own.
    Studio,
    /// Soft, far behind the beat, quiet ghost snares.
    Tuck,
    /// Cool, swinging offbeat hats and ghost hits.
    Wren,
    /// Hard, dry and on the grid.
    Odile,
    /// Hard, steady four-on-the-floor.
    Moxie,
    /// Aggressive, right on the click, hard flams.
    Bram,
    /// Aggressive, wide and loud.
    Dov,
    /// Cool, loose and busy, ghost notes and flams.
    Marla,
    /// Timid, very soft and late.
    Ines,
    /// Moderate, relaxed in the pocket.
    Juno,
    /// Aggressive, heavy and wide.
    Sable,
    /// Moderate, steady and even.
    Nell,
}

impl Player {
    /// Every player, house player first.
    pub const ALL: [Player; 12] = [
        Player::Studio,
        Player::Tuck,
        Player::Wren,
        Player::Odile,
        Player::Moxie,
        Player::Bram,
        Player::Dov,
        Player::Marla,
        Player::Ines,
        Player::Juno,
        Player::Sable,
        Player::Nell,
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
            Player::Marla => "marla",
            Player::Ines => "ines",
            Player::Juno => "juno",
            Player::Sable => "sable",
            Player::Nell => "nell",
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
            Player::Tuck => Style::Soft,
            Player::Wren | Player::Marla => Style::Cool,
            Player::Bram | Player::Dov | Player::Sable => Style::Aggressive,
            Player::Ines => Style::Timid,
            Player::Juno | Player::Nell => Style::Moderate,
        }
    }

    /// One sentence on how this player plays, for a picker or a help line.
    pub const fn character(self) -> &'static str {
        match self {
            Player::Studio => "The house player: on the grid, no swing. The style alone shapes the hit.",
            Player::Tuck => "Brushes and a lazy backbeat. Far behind the click, with quiet ghost snares.",
            Player::Wren => "Swings the offbeat sixteenths and rolls quiet ghost hits under the snare.",
            Player::Odile => "On the grid and dry. A tight backbeat that never rushes.",
            Player::Moxie => "Steady four-on-the-floor. The kick leads and the hats stay even.",
            Player::Bram => "Leans into the kit: a big snare, a kick on the click, hard flams.",
            Player::Dov => "Punk energy. Wide dynamics, heavy accents, a flam on every other hit.",
            Player::Marla => "Loose and busy: swung offbeats, ghost notes and flams under a light backbeat.",
            Player::Ines => "Timid and late: soft hands, few accents, a breath behind the click.",
            Player::Juno => "Relaxed in the pocket: a loose kick, a lazy snare, low ghost notes.",
            Player::Sable => "Heavy and wide: big snare flams, hard accents, no ghost notes.",
            Player::Nell => "Steady and even: a plain backbeat with a few quiet ghosts.",
        }
    }

    /// This player's habits, applied on top of the style's numbers.
    const fn tweak(self) -> Tweak {
        match self {
            Player::Studio => Tweak::NEUTRAL,
            // Far behind the click, light hands, quiet ghosts on the snare.
            Player::Tuck => Tweak {
                level: 0.94,
                accent: 0.80,
                spread: 0.90,
                lateness: 0.010,
                time: 1.25,
                ghost_chance: 0.18,
                ghost_level: 0.02,
                ghost_delay: 0.004,
                snare: -2.0,
                hat: -4.0,
                ..Tweak::NEUTRAL
            },
            // The offbeat sixteenth waits a long way; the hats carry ghosts.
            Player::Wren => Tweak {
                level: 0.95,
                accent: 0.85,
                spread: 1.15,
                lateness: 0.008,
                time: 1.35,
                swing: 0.12,
                ghost_chance: 0.22,
                ghost_level: 0.02,
                ghost_delay: 0.002,
                kick: -1.0,
                snare: -1.0,
                hat: -1.0,
                ..Tweak::NEUTRAL
            },
            // A metronome with a pulse: almost no timing wobble, no extras.
            Player::Odile => Tweak {
                accent: 1.10,
                spread: 0.85,
                lateness: -0.002,
                time: 0.50,
                ghost_chance: -0.08,
                flam_chance: -0.08,
                kick: 1.0,
                snare: 3.0,
                ..Tweak::NEUTRAL
            },
            // The kick carries it; the sixteenths stay even.
            Player::Moxie => Tweak {
                spread: 0.90,
                lateness: -0.002,
                time: 0.70,
                ghost_chance: -0.08,
                kick: 4.0,
                snare: 1.0,
                hat: -2.0,
                ..Tweak::NEUTRAL
            },
            // Big backbeat, right on the click, a hard flam now and then.
            Player::Bram => Tweak {
                level: 1.04,
                accent: 1.20,
                spread: 1.20,
                lateness: -0.002,
                time: 0.90,
                flam_chance: 0.08,
                flam_level: 0.03,
                kick: 2.0,
                snare: 5.0,
                hat: -1.0,
                ..Tweak::NEUTRAL
            },
            // Loud and unsubtle: toms in the room, a flam on many hits.
            Player::Dov => Tweak {
                level: 1.05,
                accent: 1.25,
                spread: 1.30,
                lateness: -0.0003,
                time: 1.0,
                flam_chance: 0.15,
                flam_level: 0.08,
                kick: 2.0,
                snare: 4.0,
                hat: -2.0,
                other: 2.0,
                ..Tweak::NEUTRAL
            },
            // Loose and busy: big swing, ghost notes, flams, the rim in the room.
            Player::Marla => Tweak {
                level: 0.97,
                accent: 0.95,
                spread: 1.10,
                lateness: 0.006,
                time: 1.45,
                swing: 0.14,
                ghost_chance: 0.20,
                ghost_level: 0.03,
                ghost_delay: 0.004,
                flam_chance: 0.10,
                flam_level: 0.02,
                snare: 2.0,
                hat: 1.0,
                other: 4.0,
                ..Tweak::NEUTRAL
            },
            // Barely there, and always a breath late.
            Player::Ines => Tweak {
                level: 0.90,
                accent: 0.70,
                spread: 0.75,
                lateness: 0.012,
                time: 1.60,
                ghost_chance: 0.06,
                ghost_level: -0.03,
                ghost_delay: 0.006,
                flam_chance: -0.04,
                kick: -1.0,
                snare: -2.0,
                hat: -4.0,
                ..Tweak::NEUTRAL
            },
            // A loose pocket: a lazy kick, a snare that sits back, quiet ghosts.
            Player::Juno => Tweak {
                level: 0.98,
                accent: 0.90,
                spread: 1.10,
                lateness: 0.010,
                time: 1.50,
                swing: 0.08,
                ghost_chance: 0.15,
                ghost_level: 0.01,
                ghost_delay: 0.002,
                kick: 2.0,
                snare: -1.0,
                ..Tweak::NEUTRAL
            },
            // Heavy and wide, with a big flam on the backbeat.
            Player::Sable => Tweak {
                level: 1.02,
                accent: 1.15,
                spread: 1.15,
                lateness: -0.0003,
                time: 0.90,
                ghost_chance: -0.06,
                flam_chance: 0.12,
                flam_level: 0.06,
                kick: 3.0,
                snare: 6.0,
                hat: -2.0,
                other: 1.0,
                ..Tweak::NEUTRAL
            },
            // Steady, honest, with a few quiet ghost notes under it.
            Player::Nell => Tweak {
                level: 0.96,
                lateness: 0.004,
                time: 1.15,
                ghost_chance: 0.08,
                kick: 1.0,
                snare: 1.0,
                ..Tweak::NEUTRAL
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
    /// this engine does not schedule ahead of the block it is rendering. A
    /// player may add a second, quieter hit ([`Played::extra`]) as a ghost note
    /// or a flam; it is the same voice, a few milliseconds after the main hit.
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
                extra: None,
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
            // Half the requested fraction: 0.28 is a shade under a triplet.
            f64::from(profile.swing) * (step_frames / f64::from(rate)) * 0.5
        } else {
            0.0
        };
        let seconds = (f64::from(profile.lateness) + f64::from(jitter) + swing).max(0.0);
        let offset_frames = (seconds * f64::from(rate)).round() as usize;

        Played {
            velocity,
            offset_frames,
            extra: self.extra_hit(
                profile,
                voice,
                velocity,
                step,
                metric_step,
                offset_frames,
                rate,
            ),
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
            time_spread: base.time_spread * tweak.time,
            swing: (base.swing + tweak.swing).clamp(0.0, 0.6),
            ghost_chance: (base.ghost_chance + tweak.ghost_chance).clamp(0.0, 0.9),
            ghost_level: (base.ghost_level + tweak.ghost_level).clamp(0.0, 0.8),
            ghost_delay: (base.ghost_delay + tweak.ghost_delay).max(0.006),
            flam_chance: (base.flam_chance + tweak.flam_chance).clamp(0.0, 0.9),
            flam_level: (base.flam_level + tweak.flam_level).clamp(0.0, 0.8),
            flam_delay: (base.flam_delay + tweak.flam_delay).max(0.006),
        }
    }

    /// A ghost note or a flam, when this player and this cell call for one.
    ///
    /// Ghost notes prefer the offbeat sixteenths and land on the snare, clap,
    /// hats and rim. Flams prefer the backbeat and land on the kick, snare,
    /// clap, toms and rim. A cell gets one extra hit at most: the ghost wins
    /// where a player carries both habits, because two extra hits would make a
    /// machine-gun of a single chart step.
    fn extra_hit(
        &self,
        profile: Profile,
        voice: Voice,
        main: u8,
        step: u64,
        metric_step: usize,
        main_offset: usize,
        rate: u32,
    ) -> Option<ExtraHit> {
        if main <= 2 || rate == 0 {
            return None;
        }
        let metric = metric_step % 16;
        let offbeat = metric % 2 == 1;
        let ghost_chance = (profile.ghost_chance * if offbeat { 1.35 } else { 0.75 }).min(0.9);
        if ghostable(voice) && hash_unit(step, voice, 0x6051_0000_0000_0001) < ghost_chance {
            return Some(make_extra(
                main,
                profile.ghost_level,
                profile.ghost_delay,
                step,
                voice,
                main_offset,
                rate,
                0x6052_0000_0000_0001,
            ));
        }
        let on_beat = metric % 4 == 0 || metric % 4 == 2;
        let flam_chance = (profile.flam_chance * if on_beat { 1.25 } else { 0.7 }).min(0.9);
        if flamable(voice) && hash_unit(step, voice, 0xF1A3_0000_0000_0001) < flam_chance {
            return Some(make_extra(
                main,
                profile.flam_level,
                profile.flam_delay,
                step,
                voice,
                main_offset,
                rate,
                0xF1A4_0000_0000_0001,
            ));
        }
        None
    }
}

/// One chart cell after the player has touched it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Played {
    /// The velocity to trigger, `1..=100`.
    pub velocity: u8,
    /// How many frames after the step boundary the hit lands.
    pub offset_frames: usize,
    /// A ghost note or flam this player adds, if any.
    pub extra: Option<ExtraHit>,
}

/// A second, quieter hit by the same voice: a ghost note or a flam.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ExtraHit {
    /// The extra hit's velocity, always below the main hit's.
    pub velocity: u8,
    /// Frames after the step boundary; later than the main hit.
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
    /// Chance of a ghost note, before the offbeat weighting.
    ghost_chance: f32,
    /// A ghost note's velocity as a fraction of the main hit.
    ghost_level: f32,
    /// How far after the main hit a ghost lands, in seconds.
    ghost_delay: f32,
    /// Chance of a flam, before the backbeat weighting.
    flam_chance: f32,
    /// A flam's velocity as a fraction of the main hit.
    flam_level: f32,
    /// How far after the main hit a flam lands, in seconds.
    flam_delay: f32,
}

/// A player's additions to a style's profile.
#[derive(Debug, Clone, Copy)]
struct Tweak {
    level: f32,
    accent: f32,
    spread: f32,
    lateness: f32,
    time: f32,
    swing: f32,
    ghost_chance: f32,
    ghost_level: f32,
    ghost_delay: f32,
    flam_chance: f32,
    flam_level: f32,
    flam_delay: f32,
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
        time: 1.0,
        swing: 0.0,
        ghost_chance: 0.0,
        ghost_level: 0.0,
        ghost_delay: 0.0,
        flam_chance: 0.0,
        flam_level: 0.0,
        flam_delay: 0.0,
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

/// Whether this voice takes a ghost note.
fn ghostable(voice: Voice) -> bool {
    matches!(
        voice,
        Voice::Snare | Voice::Clap | Voice::ClosedHat | Voice::OpenHat | Voice::Rim
    )
}

/// Whether this voice takes a flam.
fn flamable(voice: Voice) -> bool {
    matches!(
        voice,
        Voice::Kick
            | Voice::Snare
            | Voice::Clap
            | Voice::LowTom
            | Voice::HighTom
            | Voice::Rim
    )
}

/// Build the extra hit a ghost or flam adds.
fn make_extra(
    main: u8,
    level: f32,
    delay: f32,
    step: u64,
    voice: Voice,
    main_offset: usize,
    rate: u32,
    salt: u64,
) -> ExtraHit {
    let jitter = (hash_unit(step, voice, salt) * 2.0 - 1.0) * delay * 0.35;
    let seconds = (delay + jitter).max(0.004);
    let offset_frames = main_offset + (f64::from(seconds) * f64::from(rate)).round() as usize;
    let cap = main.saturating_sub(1).max(1);
    let velocity = ((main as f32 * level).round() as u8).clamp(1, cap);
    ExtraHit {
        velocity,
        offset_frames,
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

/// Whether this voice feels the swing. The hats, the rim and the clap carry it;
/// the feet and the backbeat stay where the chart put them.
fn swings(voice: Voice) -> bool {
    matches!(
        voice,
        Voice::ClosedHat | Voice::OpenHat | Voice::Rim | Voice::Clap | Voice::Snare
    )
}

/// A deterministic value in `0..1` from a step, a voice and a salt.
///
/// SplitMix64's finalizer: cheap, stable across platforms, and no state to carry
/// between blocks. The salt keeps the velocity, timing, ghost and flam streams
/// independent.
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

    fn mean_velocity(player: Player, style: Style, voice: Voice) -> f32 {
        let performance = Performance::new(player, style);
        let mut total = 0.0;
        let mut count = 0.0;
        for step in 0..64u64 {
            let played = performance.play(voice, 70, step, step as usize, 6_000.0, 48_000);
            total += played.velocity as f32;
            count += 1.0;
        }
        total / count
    }

    fn mean_offset_ms(player: Player, style: Style, voice: Voice) -> f32 {
        let performance = Performance::new(player, style);
        let mut total = 0.0;
        let mut count = 0.0;
        for step in 0..64u64 {
            let played = performance.play(voice, 70, step, step as usize, 6_000.0, 48_000);
            total += played.offset_frames as f32 / 48.0;
            count += 1.0;
        }
        total / count
    }

    fn extras(player: Player, style: Style, voice: Voice) -> usize {
        let performance = Performance::new(player, style);
        (0..128u64)
            .filter(|step| {
                performance
                    .play(voice, 80, *step, *step as usize, 6_000.0, 48_000)
                    .extra
                    .is_some()
            })
            .count()
    }

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
    fn every_player_has_a_style_and_a_face() {
        for player in Player::ALL {
            let style = player.style();
            assert!(Style::ALL.contains(&style));
            assert!(!player.character().is_empty());
        }
    }

    #[test]
    fn styles_are_ordered_from_quiet_to_loud() {
        // Same cell, no accent (kick off the pulse), so the style's level is the
        // only thing that should move the mean.
        let mut means = Vec::new();
        for style in Style::ALL {
            means.push(mean_velocity(Player::Studio, style, Voice::Kick));
        }
        for pair in means.windows(2) {
            assert!(
                pair[1] > pair[0] + 1.0,
                "styles are not ordered quiet to loud: {means:?}"
            );
        }
    }

    #[test]
    fn players_are_measurably_different() {
        // A player that is only a few velocity points from another is the bug
        // this change fixes: the roster must spread across level and time.
        let velocities: Vec<f32> = Player::ALL
            .iter()
            .map(|player| mean_velocity(*player, player.style(), Voice::Snare))
            .collect();
        let low = velocities.iter().cloned().fold(f32::MAX, f32::min);
        let high = velocities.iter().cloned().fold(f32::MIN, f32::max);
        assert!(high - low > 22.0, "velocity spread too small: {velocities:?}");

        let offsets: Vec<f32> = Player::ALL
            .iter()
            .map(|player| mean_offset_ms(*player, player.style(), Voice::Kick))
            .collect();
        let early = offsets.iter().cloned().fold(f32::MAX, f32::min);
        let late = offsets.iter().cloned().fold(f32::MIN, f32::max);
        assert!(
            late - early > 12.0,
            "timing spread too small: {offsets:?}"
        );
    }

    #[test]
    fn ghosts_and_flams_add_a_quieter_second_hit() {
        let performance = Performance::of(Player::Marla);
        let mut found = None;
        for step in 0..128u64 {
            let played = performance.play(
                Voice::Snare,
                90,
                step,
                step as usize,
                6_000.0,
                48_000,
            );
            if let Some(extra) = played.extra {
                found = Some((played, extra));
                break;
            }
        }
        let (played, extra) = found.expect("Marla never ghosted or flammed a snare");
        assert!(extra.velocity < played.velocity, "{played:?}");
        assert!(extra.offset_frames > played.offset_frames, "{played:?}");
        let gap = (extra.offset_frames - played.offset_frames) as f32 / 48.0;
        assert!((4.0..=70.0).contains(&gap), "the extra was {gap} ms late");
    }

    #[test]
    fn a_timid_house_performance_adds_no_extra_hit() {
        for voice in Voice::ALL {
            assert_eq!(extras(Player::Studio, Style::Timid, voice), 0);
        }
        assert!(extras(Player::Marla, Style::Cool, Voice::Snare) > 0);
        assert!(extras(Player::Sable, Style::Aggressive, Voice::Snare) > 0);
    }

    #[test]
    fn a_player_sits_behind_the_grid_by_their_own_amount() {
        // Ines is the late one, Odile the metronome.
        let ines = mean_offset_ms(Player::Ines, Player::Ines.style(), Voice::Kick);
        let odile = mean_offset_ms(Player::Odile, Player::Odile.style(), Voice::Kick);
        assert!(ines - odile > 15.0, "Ines {ines} ms vs Odile {odile} ms");
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
        assert_ne!(first, second);
    }

    #[test]
    fn an_empty_step_stays_empty_and_on_the_grid() {
        for player in Player::ALL {
            for style in Style::ALL {
                let played =
                    Performance::new(player, style).play(Voice::Kick, 0, 5, 5, 6_000.0, 48_000);
                assert_eq!(played.velocity, 0);
                assert_eq!(played.offset_frames, 0);
                assert_eq!(played.extra, None);
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
                        // A player may sit back but never schedules ahead, and
                        // no feel should push a hit more than a step late.
                        assert!(played.offset_frames <= 48_000 / 15, "over 66 ms late");
                        if let Some(extra) = played.extra {
                            assert!((1..=100).contains(&extra.velocity));
                            assert!(extra.velocity < played.velocity);
                            assert!(extra.offset_frames > played.offset_frames);
                            assert!(extra.offset_frames <= 48_000 / 12);
                        }
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
        // Marla is the hardest swinger in the roster.
        let performance = Performance::of(Player::Marla);
        let straight = performance.play(Voice::ClosedHat, 40, 0, 0, 6_000.0, 48_000);
        let swung = performance.play(Voice::ClosedHat, 40, 1, 1, 6_000.0, 48_000);
        let extra = swung.offset_frames as f32 / 48.0 - straight.offset_frames as f32 / 48.0;
        assert!(extra >= 12.0, "only {extra} ms of swing");
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
            assert!((base.swing - studio.swing).abs() < 1e-6);
            assert!((base.ghost_chance - studio.ghost_chance).abs() < 1e-6);
            assert!((base.flam_chance - studio.flam_chance).abs() < 1e-6);
        }
    }
}
