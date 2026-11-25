# tests-for: engine/Cargo.toml engine/crates/jawn-synth/ engine/crates/jawn-drums/
# covers:    the app voices are crates of their own (docs/studio-audio-roadmap.md
#            P5). The synth and the drum machine are pure Rust, have no
#            dependencies, and are workspace members so `cargo test --workspace`
#            runs their DSP tests in the suite (t/332). The drum crate names the
#            same eight rows and ten kits the browser and Studio save, so a later
#            wiring step speaks one vocabulary rather than two.

use strict;
use warnings;

use Cwd qw(abs_path);
use FindBin;
use File::Slurp qw(read_file);
use Test::More;

my $root = abs_path("$FindBin::Bin/..");

my $workspace  = read_file("$root/engine/Cargo.toml");
my $synth_toml = read_file("$root/engine/crates/jawn-synth/Cargo.toml");
my $drums_toml = read_file("$root/engine/crates/jawn-drums/Cargo.toml");
my $synth      = read_file("$root/engine/crates/jawn-synth/src/lib.rs");
my $synth_voice = read_file("$root/engine/crates/jawn-synth/src/synth.rs");
my $drums      = read_file("$root/engine/crates/jawn-drums/src/lib.rs");
my $kit        = read_file("$root/engine/crates/jawn-drums/src/kit.rs");
my $machine    = read_file("$root/engine/crates/jawn-drums/src/machine.rs");
my $pattern    = read_file("$root/engine/crates/jawn-drums/src/pattern.rs");
my $player     = read_file("$root/engine/crates/jawn-drums/src/player.rs");
my $build_test = read_file("$root/t/332-engine-build.t");
my $roadmap    = read_file("$root/docs/studio-audio-roadmap.md");

ok( length $workspace,  'the engine manifest is found' );
ok( length $synth_toml, 'the synth crate has a manifest' );
ok( length $drums_toml, 'the drums crate has a manifest' );

# --- the crates are part of the engine's workspace ---------------------------
like( $workspace, qr/^members\s*=\s*\[[^\]]*"crates\/jawn-synth"[^\]]*"crates\/jawn-drums"[^\]]*\]/ms,
	'both voice crates are workspace members' );
like( $workspace, qr/^jawn-synth\s*=\s*\{\s*path\s*=\s*"crates\/jawn-synth"\s*\}/m,
	'the engine links the synth crate' );
like( $workspace, qr/^jawn-drums\s*=\s*\{\s*path\s*=\s*"crates\/jawn-drums"\s*\}/m,
	'and the drums crate' );
like( $build_test, qr/'--workspace'/, 'the suite runs every member crate\'s tests, not just the binary\'s' );

# --- pure Rust, no dependencies ---------------------------------------------
like( $synth_toml, qr/^name\s*=\s*"jawn-synth"/m, 'the synth crate is named for the engine' );
like( $drums_toml, qr/^name\s*=\s*"jawn-drums"/m, 'the drums crate is named for the engine' );
like( $synth_toml, qr/^publish\s*=\s*false/m, 'the synth crate is never published' );
like( $drums_toml, qr/^publish\s*=\s*false/m, 'the drums crate is never published' );
for my $manifest ( [ synth => $synth_toml ], [ drums => $drums_toml ] ) {
	my ( $name, $text ) = @$manifest;
	my ($deps) = $text =~ /^\[dependencies\]\s*(.*)\z/ms;
	is( $deps // '', '', "$name has no dependencies, so it builds offline with no C" );
}

# --- the public shape a wiring step will use --------------------------------
like( $synth, qr/^#!\[forbid\(unsafe_code\)\]/m, 'the synth forbids unsafe' );
like( $synth, qr/pub use patch::\{[^}]*\bPatch\b[^}]*\}/s, 'the patch is public' );
like( $synth, qr/pub use patch::\{[^}]*\bWave\b[^}]*\}/s, 'and the waveform vocabulary' );
like( $synth, qr/pub use synth::\{[^}]*\bSynth\b[^}]*\}/s, 'the synth itself is public' );
like( $synth_voice, qr/pub fn render\(&mut self, left: &mut \[f32\], right: &mut \[f32\]\)/,
	'render takes two f32 blocks' );
like( $synth_voice, qr/pub fn note_on\(/, 'note_on is the event a transport sends' );
like( $synth_voice, qr/pub fn set_patch\(/, 'a live patch change needs no re-arm' );

like( $drums, qr/^#!\[forbid\(unsafe_code\)\]/m, 'the drums crate forbids unsafe' );
like( $drums, qr/pub const ALL: \[Voice; 8\]/, 'eight rows, the Studio chart' );
like( $kit, qr/pub const ALL: \[Kit; 10\]/, 'ten kits, the Studio table' );
like( $machine, qr/pub fn trigger_at\(&mut self, slot: usize, velocity: u8, offset_frames: usize\)/,
	'a hit can be scheduled inside a block' );
like( $machine, qr/pub fn render\(&mut self, left: &mut \[f32\], right: &mut \[f32\]\)/,
	'render takes two f32 blocks' );
like( $pattern, qr/pub fn events_at\(/, 'a chart names its events for a block' );
like( $drums, qr/pub use player::\{[^}]*\bPlayer\b[^}]*\bStyle\b[^}]*\}/s,
	'the players and styles are public' );
like( $drums, qr/pub use player::\{[^}]*\bExtraHit\b[^}]*\}/s,
	'a ghost note or flam is part of the public shape' );
like( $player, qr/pub const ALL: \[Player; 12\]/, 'twelve players, the house player first' );
like( $player, qr/pub const ALL: \[Style; 6\]/,
	'timid, soft, moderate, cool, hard and aggressive' );
like( $player, qr/ghost_chance: f32/, 'a player can add a ghost note' );
like( $player, qr/flam_chance: f32/, 'and a flam' );
# The player's own style is the same mapping the panel's table carries (t/346):
# choosing a player there moves the Style list to this setting.
like( $player, qr/Player::Tuck => Style::Soft/, 'Tuck plays soft' );
like( $player, qr/Player::Wren \| Player::Marla => Style::Cool/, 'Wren and Marla play cool' );
like( $player, qr/Player::Studio \| Player::Odile \| Player::Moxie => Style::Hard/,
	'Session, Odile and Moxie play hard' );
like( $player, qr/Player::Bram \| Player::Dov \| Player::Sable => Style::Aggressive/,
	'Bram, Dov and Sable play aggressive' );
like( $player, qr/Player::Ines => Style::Timid/, 'Ines plays timid' );
like( $player, qr/Player::Juno \| Player::Nell => Style::Moderate/,
	'Juno and Nell play moderate' );

# The wire names are the ones a saved song and the browser already use.
for my $name (qw(kick snare closed_hat open_hat clap low_tom high_tom rim)) {
	like( $drums, qr/Voice::\w+\s*=>\s*"$name"/, "the voice wire name $name is kept" );
}
for my $name (qw(acoustic electronic techno beats latin pearl tama gretsch 808 metal)) {
	like( $kit, qr/Kit::\w+\s*=>\s*"$name"/, "the kit wire name $name is kept" );
}
for my $name (qw(studio tuck wren odile moxie bram dov marla ines juno sable nell)) {
	like( $player, qr/Player::\w+\s*=>\s*"$name"/, "the player wire name $name is kept" );
}
for my $name (qw(timid soft moderate cool hard aggressive)) {
	like( $player, qr/Style::\w+\s*=>\s*"$name"/, "the style wire name $name is kept" );
}

# --- the roadmap says what these crates are for -----------------------------
like( $roadmap, qr/jawn-synth/, 'the roadmap names the synth crate' );
like( $roadmap, qr/jawn-drums/, 'the roadmap names the drums crate' );

done_testing();
