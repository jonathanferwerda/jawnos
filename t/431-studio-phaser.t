# tests-for: engine/src/effect.rs engine/src/effect/phaser.rs public/js/manager/studio/08_effects.js public/js/manager/studio/15_house_patch.js perl/gb/05_abilities_and_studio.pl perl/help/topics_apps.pl lib/JawnOS/Audio/Plan.pm lib/JawnOS/Controller/manager_misc9.pm docs/studio-effects.md docs/pedal-audit.md t/431-studio-phaser.t
# covers:    Phaser is one pedal on both sides of docs/studio-effects.md: the
#            palette offers it, the browser builds it as four allpass biquads
#            with an LFO, feedback and an internal dry/wet, and the engine parses
#            the name, numbers it 16, lists the same four controls and builds it
#            at the browser's defaults. `sync` is the page's tempo field, never
#            an engine control. The docs, the audit and the Studio help name it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root   = repo_root();
my $effect = read_file("$root/engine/src/effect.rs");
my $module = read_file("$root/engine/src/effect/phaser.rs");
my $fx     = read_file("$root/public/js/manager/studio/08_effects.js");
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $help   = read_file("$root/perl/help/topics_apps.pl");
my $plan   = read_file("$root/lib/JawnOS/Audio/Plan.pm");
my $take   = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $house  = read_file("$root/public/js/manager/studio/15_house_patch.js");
my $doc    = read_file("$root/docs/studio-effects.md");
my $audit  = read_file("$root/docs/pedal-audit.md");

# --- the palette and the effects table --------------------------------------
my ($palette) = $studio =~ /palette\s*=>\s*\[\s*qw\(([^)]*)\)\s*\]/s;
my %palette = map { $_ => 1 } split ' ', ($palette // '');
ok(defined $palette && length $palette, 'the studio data carries a palette list');
ok($palette{phaser}, 'the Add list palette offers phaser next to flanger');

my ($entry) = $studio =~ /phaser\s*=>\s*\{\s*label\s*=>\s*'Phaser',\s*controls\s*=>\s*\[(.*?)\]\s*\}/s;
ok(defined $entry, "the effects table names phaser as 'Phaser'");
my @palette_controls = ($entry // '') =~ /control\s*=>\s*'([a-z_]+)'/g;
is_deeply(
	\@palette_controls,
	[qw(rate depth feedback mix sync)],
	'the pedal offers the four controls and the UI-only sync field'
);
like($entry // '', qr/\{ control => 'sync', label => 'Sync', typed => 1/,
	'sync is the typed tempo field, shaped like the flanger');

# --- the browser wiring ------------------------------------------------------
like($fx, qr/\bphaser\s*:\s*'phaser'/, 'the alias table maps phaser to itself');
like($fx, qr/\bphaser\s*:\s*studioEffectPhaser/, 'the builder table builds it');
like($fx, qr/function studioEffectPhaser\(ctx, name\)/, 'the builder exists');
like($fx, qr/case 'flanger\.rate':\s*\n\s*case 'phaser\.rate':\s*\n\s*return 0\.05 \+ amount \* 4\.95;/,
	'phaser.rate shares the flanger 0.05..5 Hz mapping');
like($fx, qr/var studioTempoControls = \{[\s\S]*?\bphaser:\s*'rate'/,
	'the tempo control points at phaser.rate');
like($fx, qr/phaser:\s*\{\s*min:\s*0\.05,\s*max:\s*5\s*\}/,
	'the tempo limit is the same 0.05..5 Hz band');
like($fx, qr/'phaser\.sync':\s*1/, 'phaser.sync is a typed control');

like($fx, qr/function studioEffectPhaser[\s\S]*?stage\.type = 'allpass'/,
	'four allpass biquads stand in for the stages');
like($fx, qr/stages\[stages\.length - 1\]\.connect\(feedback\)/,
	'the last stage feeds the resonance loop');
like($fx, qr/studioPhaserBases = \[ 250, 400, 650, 1000 \]/,
	'the four corners are staggered for a wider sweep');
like($fx, qr/function studioEffectPhaser[\s\S]*?fx\.input\.connect\(dry\)\.connect\(fx\.wet\)/,
	'an internal dry/wet pair feeds the shell wet node');
like($fx, qr/fx\.destroy = function \(\) \{ try \{ lfo\.stop\(\); \} catch \(e\) \{\} \};/,
	'destroy stops the LFO');
like($fx, qr/fx\.set\('rate', 20\);\s*\n\s*fx\.set\('depth', 50\);\s*\n\s*fx\.set\('feedback', 25\);\s*\n\s*fx\.set\('mix', 50\);/,
	'the defaults are the engine build (rate 20 = 1.04 Hz, 0.5 / 0.25 / 0.5)');

# --- the native insert kind --------------------------------------------------
like($effect, qr/^\s*mod phaser;$/m, 'effect.rs declares the phaser module');
like($effect, qr/pub use phaser::Phaser;/, 'and re-exports the effect');
like($effect, qr/^\s*Phaser,$/m, 'InsertKind has a Phaser variant');
like($effect, qr/"phaser"\s*=>\s*Some\(InsertKind::Phaser\)/, 'parse accepts the wire name');
like($effect, qr/InsertKind::Phaser\s*=>\s*"phaser"/, 'and the engine reports the same name');
like($effect, qr/InsertKind::Phaser\s*=>\s*&\s*\["rate", "depth", "feedback", "mix"\]/,
	'the four controls are the contract');
like($effect, qr/InsertKind::Phaser\s*=>\s*16/, 'the wire code is 16, after the panner');
like($effect, qr/16\s*=>\s*InsertKind::Phaser/, 'and the code round-trips');
like($effect, qr/InsertKind::Phaser\s*=>\s*Box::new\(Phaser::new\(1\.04, 0\.5, 0\.25, 0\.5\)\)/,
	'the default build matches the browser');

# --- the effect module -------------------------------------------------------
like($module, qr/^\/\/! The `phaser` pedal: an MXR Phase 90/m, 'the module header names the Phase 90');
like($module, qr/pub struct Phaser/, 'the module owns a Phaser');
like($module, qr/const STAGES: usize = 4;/, 'four allpass stages');
like($module, qr/\(1\.0 - tangent\) \/ \(1\.0 \+ tangent\)/,
	'the allpass coefficient is the contract formula');
like($module, qr/one_pole_block\(SMOOTH_SECONDS/, 'the knobs are one-pole block smoothed');
like($module, qr/pub const MIN_RATE_HZ: f32 = 0\.05;/, 'the rate floor is 0.05 Hz');
like($module, qr/pub const MAX_RATE_HZ: f32 = 5\.0;/, 'the rate ceiling is 5 Hz');
like($module, qr/pub const MAX_FEEDBACK: f32 = 0\.9;/, 'feedback is clamped below unity');
like($module, qr/"rate"\s*=>\s*\{[\s\S]*?"depth"\s*=>\s*\{[\s\S]*?"feedback"\s*=>\s*\{[\s\S]*?"mix"\s*=>\s*\{/,
	'set recognises all four controls');

# --- the source plan speaks the same vocabulary ------------------------------
my ($controls_block) = $effect =~ /(pub const fn controls\(self\).*?\n\s{4}\})/s;
my ($engine_list) = ($controls_block // '') =~ /InsertKind::Phaser\s*=>\s*&\[(.*?)\]/s;
my @engine_controls = ($engine_list // '') =~ /"([a-z0-9_]+)"/g;
is_deeply(\@engine_controls, [qw(rate depth feedback mix)], 'the engine lists four controls');
is_deeply(
	[ grep { $_ ne 'sync' } @palette_controls ],
	\@engine_controls,
	'the palette and the engine agree on the control list'
);
like($plan, qr/our \@audio_plan_insert_names = qw\([\s\S]*?\bphaser\b/,
	'the source plan names phaser');
like($plan, qr/phaser\s*=>\s*\[qw\(rate depth feedback mix\)\]/,
	'with the same four controls');
like($take, qr/our %studio_take_inserts = map \{ \$_ => 1 \} qw\([\s\S]*?\bphaser\b/,
	'the engine-take whitelist accepts phaser');
like($house, qr/studioHouseInsertNames = \[[\s\S]*?'phaser'/,
	'the house patch offers phaser on a source');

# --- the docs and the in-app guide -------------------------------------------
like($doc, qr/^\| `phaser` \|/m, 'the insert-kinds table has a phaser row');
like($doc, qr/`phaser\.rate`/, 'the tempo section names phaser.rate');
like($doc, qr/phaser's Rate knob shares that `0\.05\.\.5 Hz` mapping/, 'and gives its band');

like($audit, qr/^\| `phaser` \|/m, 'the pedal audit has a phaser row');
like($audit, qr/MXR Phase 90/, 'and names the Phase 90');
like($audit, qr/engine\/src\/effect\/phaser\.rs/, 'and its native module');
like($audit, qr/those three are the documented mods/, 'and calls depth/feedback/mix mods');

like($help, qr/Every effect on the pedalboard is drawn in the theme/,
	'the help says every effect is drawn in the theme body');
like($help, qr/Phaser sweeps four allpass stages like an MXR Phase 90/,
	'and describes the pedal in on-screen words');
like($help, qr/Rate is the sweep speed \(0\.05 to 5 Hz\)/, 'naming Rate and its band');
like($help, qr/Its Sync field follows the song/, 'and the tempo sync field');

done_testing();
