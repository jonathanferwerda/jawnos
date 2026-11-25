# tests-for: public/js/manager/studio/10_master.js engine/src/effect/graphic_eq.rs
# covers:    The master rack's ten-band graphic equaliser and the rack it lives
#            in: the band map (32 Hz .. 16 kHz), the engine's GraphicEq and the
#            legacy low/mid/high aliases, the optional vertical faders and dB
#            readouts, the level meter, and the chassis/unit/rail markup and
#            styles. The insert name, the rack order and the classes the rest of
#            the studio depends on are pinned so a restyle cannot redraw the
#            rack out from under studioMasterApply/Render.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $perl   = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $master = read_file("$root/public/js/manager/studio/10_master.js");
my $engine = read_file("$root/engine/src/effect/graphic_eq.rs");
my $effect = read_file("$root/engine/src/effect.rs");

# --- the band map -----------------------------------------------------------
# docs/studio-effects.md, "Master rack": one fader per octave, -12..+12 dB.
my ($eq) = $perl =~ /\{\s*name\s*=>\s*'master_eq'[^}]*controls\s*=>\s*\[(.*?)\n\t\t\]\s*\}/s;
ok(defined $eq, 'the studio data carries the master_eq spec');
like($perl, qr/name\s*=>\s*'master_eq',\s*label\s*=>\s*'Equaliser',\s*layout\s*=>\s*'graphic'/,
	'the master EQ is the graphic layout');

my @bands = (
	[ b32  => '32' ],
	[ b64  => '64' ],
	[ b125 => '125' ],
	[ b250 => '250' ],
	[ b500 => '500' ],
	[ b1k  => '1k' ],
	[ b2k  => '2k' ],
	[ b4k  => '4k' ],
	[ b8k  => '8k' ],
	[ b16k => '16k' ],
);
is(scalar @bands, 10, 'the band map has ten bands');
for my $band (@bands) {
	my ($control, $label) = @{$band};
	like($eq // '', qr/control\s*=>\s*'\Q$control\E'\s*,\s*label\s*=>\s*'\Q$label\E'/,
		"the master EQ has the $label band ($control)");
}
unlike($eq // '', qr/control\s*=>\s*'low'/, 'the old Low knob is no longer a control');
unlike($eq // '', qr/control\s*=>\s*'mid'/, 'the old Mid knob is no longer a control');
unlike($eq // '', qr/control\s*=>\s*'high'/, 'the old High knob is no longer a control');

# --- the engine model -------------------------------------------------------
like($engine, qr/pub const CONTROLS: &'static \[&'static str\] =\s*&\["b32", "b64", "b125", "b250", "b500", "b1k", "b2k", "b4k", "b8k", "b16k"\]/,
	'GraphicEq names the ten control keys');
like($engine, qr/pub const CENTRES: \[f32; BANDS\] = \[\s*32\.0, 64\.0, 125\.0, 250\.0, 500\.0, 1_000\.0, 2_000\.0, 4_000\.0, 8_000\.0, 16_000\.0,?\s*\]/,
	'GraphicEq centres the bells at 32 Hz .. 16 kHz');
like($engine, qr/pub const MAX_DB: f32 = 12\.0;/, 'each fader is +/-12 dB');
like($engine, qr/pub const Q: f64 = 1\.4;/, 'the bells have the graphic EQ Q');
like($engine, qr/filter\.set\(peaking\(/, 'each band is an RBJ peaking section');
like($engine, qr/fn name\(&self\) -> &'static str \{\s*"master_eq"\s*\}/,
	'the effect reports the master_eq name');
# The three legacy names map to 125 Hz / 1 kHz / 8 kHz.
like($engine, qr/"low" => Some\(2\)/, 'low is the 125 Hz band');
like($engine, qr/"mid" => Some\(5\)/, 'mid is the 1 kHz band');
like($engine, qr/"high" => Some\(8\)/, 'high is the 8 kHz band');

like($effect, qr/mod graphic_eq;/, 'effect.rs owns the graphic_eq module');
like($effect, qr/"master_eq" => Some\(InsertKind::MasterEq\)/, 'master_eq parses to MasterEq');
like($effect, qr/InsertKind::MasterEq => GraphicEq::CONTROLS/,
	'the insert kind lists exactly the ten bands');
like($effect, qr/InsertKind::MasterEq => Box::new\(GraphicEq::new\(\)\)/,
	'the insert kind builds the graphic EQ');
like($effect, qr/InsertKind::MasterEq => Some\("master_eq"\)/, 'master_eq is a master prefix');
like($effect, qr/\(InsertKind::MasterEq, "low"\) => "b125"/, 'low is a legacy alias of b125');
like($effect, qr/\(InsertKind::MasterEq, "mid"\) => "b1k"/, 'mid is a legacy alias of b1k');
like($effect, qr/\(InsertKind::MasterEq, "high"\) => "b8k"/, 'high is a legacy alias of b8k');

# --- the rack markup --------------------------------------------------------
like($markup, qr/id="studio_master_rack"/, 'the master rack is still one rack');
like($markup, qr/my \$unit = 0; foreach my \$m \( @\{\$gb::studio->\{'master'\}\} \)/,
	'each master effect is numbered a rack unit');
like($markup, qr/data-unit="<%= \$unit %>"/, 'the unit number is on the block');
like($markup, qr/studio_master_graphic/, 'the graphic EQ gets its own class');
like($markup, qr/id="studio_master_meter"/, 'the rack carries a level meter');
like($markup, qr/studio_master_label studio_master_band/, 'each graphic fader is a band');
like($markup, qr/studio_master_band_hz/, 'a band has its readable frequency label');
like($markup, qr/studio_master_band_db/, 'a band has its dB readout');
like($markup, qr/class="studio_master_toggle hover"[^>]*effect="<%= \$m->\{'name'\} %>"/,
	'the footswitch keeps its class and effect attributes');
like($markup, qr/class="studio_master_controls"/, 'the controls keep their block');
like($markup, qr/class="studio_master_effect/, 'the units keep the effect class');

# --- the rack styles --------------------------------------------------------
like($style, qr/\.studio_master_rack \{/, 'the rack has its chassis rule');
like($style, qr/\.studio_master_rack::before,\s*\n\s*\.studio_master_rack::after/,
	'a grip rail runs down each side');
like($style, qr/\.studio_master_effect::before,\s*\n\s*\.studio_master_effect::after/,
	'each unit has drilled rails');
like($style, qr/\.studio_master_unit_no \{/, 'each unit carries its number');
like($style, qr/\.studio_master_meter \{/, 'the meter is styled');
like($style, qr/\.studio_master_led\.lit/, 'the meter segments light');
like($style, qr/grid-template-columns: repeat\(10, minmax\(0, 1fr\)\)/,
	'the ten bands share one wide row');
like($style, qr/-webkit-appearance: slider-vertical/, 'the faders are vertical');
like($style, qr/writing-mode: vertical-lr/, 'the vertical slider also works via writing-mode');
like($style, qr/\.studio_master_band_hz,/, 'the band labels are laid out with the faders');

# --- the page keeps the classes the studio drives ---------------------------
like($master, qr/var studioMasterOrder = \[ 'master_comp', 'master_eq'/,
	'the insert name and rack order are unchanged');
like($master, qr/\.studio_master_effect\[effect="/, 'the module still finds a unit by effect');
like($master, qr/\.studio_master_toggle/, 'the module still drives the footswitch');
like($master, qr/\.studio_master_control/, 'the module still drives the controls');

# --- the fader readouts and the meter ---------------------------------------
like($master, qr/function studioMasterBandDb\(value\)/, 'a fader value becomes dB');
like($master, qr/function studioMasterBandReadout\(input\)/, 'the readout follows its fader');
like($master, qr/\.studio_master_band_db/, 'the readout targets the band dB label');
like($master, qr/studioMasterBandReadout\(el\)/, 'a render moves every fader readout');
like($master, qr/function studioMasterMeterPaint\(analyser\)/, 'the meter reads an analyser');
like($master, qr/#studio_master_meter \.studio_master_led/, 'the meter lights the rack LEDs');
like($master, qr/function studioMasterMeterStep\(now\)/, 'the meter runs on one frame loop');
like($master, qr/studioMasterMeterStart\(\);/,
	'a render starts the meter and the studio window gets it for free');

done_testing();
