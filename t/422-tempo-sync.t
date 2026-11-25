# tests-for: public/js/manager/studio/08_effects.js engine/src/effect.rs engine/src/effect/tremolo.rs engine/src/effect/flanger.rs
# covers:    Tempo-synced time controls. The division parser (n/d, whole notes,
#            dotted, triplet, manual ms, off), the sync control on delay,
#            flanger, tremolo and stereo_panner, the tremolo effect on both
#            sides, the native stereo panner, the 8 s delay line and the
#            typed text field in the pedal template.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource qw(repo_root);

my $root = repo_root();
my $js     = read_file("$root/public/js/manager/studio/08_effects.js");
my $rack   = read_file("$root/public/js/manager/studio/09_pedals.js");
my $ctrl   = read_file("$root/public/js/manager/studio/06_controls.js");
my $planjs = read_file("$root/public/js/manager/studio/01_transport.js");
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $plan   = read_file("$root/lib/JawnOS/Audio/Plan.pm");
my $effect = read_file("$root/engine/src/effect.rs");
my $trem   = read_file("$root/engine/src/effect/tremolo.rs");
my $flange = read_file("$root/engine/src/effect/flanger.rs");
my $docs   = read_file("$root/docs/studio-effects.md");

# --- the page's parser ------------------------------------------------------
like($js, qr/function studioTempoDivision\(text\)/, 'the division parser has one home');
like($js, qr/function studioTempoManualMs\(text\)/, 'a manual millisecond value has its own reader');
like($js, qr/function studioTempoResolveValue\(kind, sync, bpm\)/, 'one resolver turns a division into seconds or hertz');
like($js, qr/function studioTempoSyncAll\(\)/, 'every synced insert is re-applied in one pass');
like($js, qr/var studioTempoControls = \{[\s\S]*?delay: 'time'[\s\S]*?flanger: 'rate'[\s\S]*?phaser: 'rate'[\s\S]*?tremolo: 'rate'[\s\S]*?stereo_panner: 'rate'/,
	'the five synced controls are the delay time and four LFO rates');
like($js, qr/function studioEffectTyped\(kind, control\)/, 'a typed control is stored as text, not a number');
like($js, qr/\\\.sync\$\/\.test/,
	'the engine never receives the sync string');

# --- the sync control on each effect ---------------------------------------
for my $kind (qw(delay flanger phaser tremolo stereo_panner)) {
	like($studio, qr/\b\Q$kind\E\s*=>\s*\{[\s\S]{0,600}?control\s*=>\s*'sync'/,
		"$kind carries a sync control in the contract table");
	like($studio, qr/control\s*=>\s*'sync',[^}]*?typed\s*=>\s*1/s,
		"$kind\'s sync is the typed path");
}
like($studio, qr/tempo_divisions\s*=>/, 'the common divisions are one shared list');
for my $division (qw(1/16 1/8 1/4 1/2 3/4 1 2 3 4 1/8d 1/8t 250ms off)) {
	like($studio, qr/\b\Q$division\E\b/, "the datalist offers $division");
}

# --- the two new effects ----------------------------------------------------
like($studio, qr/tremolo\s*=>\s*\{ label => 'Tremolo'/, 'the palette names Tremolo');
like($studio, qr/stereo_panner\s*=>\s*\{ label => 'Stereo Panner'/, 'the palette names Stereo Panner');
like($studio, qr/palette\s*=>\s*\[ qw\([^)]*\btremolo\b[^)]*\bstereo_panner\b/, 'both join the Add list');
like($js, qr/tremolo:\s*'tremolo'/, 'studioInsert has a tremolo alias');
like($js, qr/stereo_panner:\s*'stereo_panner'/, 'studioInsert has a stereo panner alias');
like($js, qr/tremolo:\s*studioEffectTremolo/, 'the tremolo builder is registered');
like($js, qr/stereo_panner:\s*studioEffectStereoPanner/, 'the stereo panner builder is registered');
like($js, qr/function studioEffectTremolo\(ctx, name\)/, 'the browser has a tremolo');
like($js, qr/function studioEffectStereoPanner\(ctx, name\)/, 'the browser has a stereo panner');
like($js, qr/createStereoPanner\(\)/, 'the stereo panner is a real StereoPannerNode');
like($js, qr/createDelay\(8\)/, 'the browser delay line is 8 seconds');
like($js, qr/studioEffectClamp\(hz, 0\.05, 8\)/, 'a synced flanger rate is clamped to 8 Hz');
like($js, qr/studioEffectClamp\(hz, 0\.1, 20\)/, 'a synced tremolo rate is clamped to 20 Hz');

# --- the engine -------------------------------------------------------------
like($effect, qr/MAX_SECONDS: f32 = 8\.5/, 'the engine delay line is 8.5 s');
like($effect, qr/MAX_TIME: f32 = 8\.0/, 'a synced engine delay may reach 8 s');
like($effect, qr/\bTremolo\b/, 'InsertKind names Tremolo');
like($effect, qr/InsertKind::Tremolo => &\["rate", "depth", "shape"\]/,
	'the engine tremolo controls are the numeric ones only');
like($trem, qr/MIN_RATE_HZ: f32 = 0\.1/, 'the tremolo rate starts at 0.1 Hz');
like($trem, qr/MAX_RATE_HZ: f32 = 20\.0/, 'the tremolo rate stops at 20 Hz');
like($trem, qr/"shape" =>/, 'the engine tremolo takes a shape');
like($trem, qr/1 => 1\.0 - 4\.0 \* \(phase - 0\.5\)\.abs\(\)/, 'shape 1 is a triangle');
like($trem, qr/phase < 0\.5/, 'shape 2 is a square');
like($trem, qr/silence_in_stays_silence/, 'the tremolo keeps silence silent');
like($flange, qr/MAX_RATE_HZ: f32 = 8\.0/, 'the flanger cap is 8 Hz');
like($effect, qr/("stereo_panner", InsertKind::StereoPanner)/,
	'a native take accepts the stereo panner');

# --- the plan vocabulary ----------------------------------------------------
like($plan, qr/\btremolo\b/, 'a source plan may name tremolo');
like($plan, qr/tremolo\s*=>\s*\[qw\(rate depth shape\)\]/, 'the plan keeps the tremolo numeric controls');
like($plan, qr/tremolo\s*=>\s*\{\s*shape\s*=>\s*1\s*\}/, 'the tremolo shape is a whole index in a plan');
like($plan, qr/^\s*stereo_panner\b/m, 'the plan names the native stereo panner');
unlike($plan, qr/^\s*sync\b/m, 'the plan never lists sync');

# --- the typed pedal control ------------------------------------------------
like($markup, qr/class="studio_pedal_text pedal_text"/, 'the template renders a visible text field');
like($markup, qr/<datalist id="studio_tempo_/, 'the template renders a datalist beside it');
like($markup, qr/\$k->\{'typed'\}/, 'the typed path is data-driven');
like($markup, qr/studio_tempo_<%= &subs::html_name\(\$ch\) %>_sync/, 'the Delay shelf tile carries the sync row');
like($rack, qr/control\['typed'\]/, 'the fallback tile knows the typed path');
like($rack, qr/studio_tempo_tile_/, 'a cloned tile gets its own datalist id');
like($rack, qr/studioTempoSyncApply\(ins, ch, chain !== 'out'\)/, 'a restored tile resolves its sync on the right chain');
like($ctrl, qr/'input change', '\.studio_pedal_text'/, 'a typed field forwards input and change');
like($js, qr/studioTempoSyncApply\(ins, ch, false\)/, 'an Out insert is resolved locally and never posted to a take');
like($js, qr/studioTempoSyncApply\(ins, ch, true\)/, 'an In insert reaches the engine with its resolved value');
like($ctrl, qr/studioTempoSyncAll\(\)/, 'a BPM change re-applies every synced insert');
like($planjs, qr/studioTempoSyncAll\(\)/, 'the engine plan resolves the same value before sending');
like($style, qr/\.pedal_text\s*\{/, 'the typed field has its own row style');
like($docs, qr/## Tempo-synced time controls/, 'the contract documents the sync control');
like($docs, qr/browser-only/i, 'the contract says which effects are browser only');

# --- run the parser ---------------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my ($fh, $harness) = tempfile(SUFFIX => '.js');
	print $fh <<'JS';
const fs = require('fs');
const vm = require('vm');
const sandbox = {
  console, Math, JSON, parseFloat, parseInt, isNaN, isFinite,
  String, Number, Object, Array,
  mixer: { time: { bpm: 120 } },
  window: {},
  jawnosT: function (text) { return text; },
  $: function () { return { on() { return this; }, each() { return this; },
    val() { return undefined; }, attr() { return undefined; } }; }
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox);
function say(name, value) { console.log(name + '=' + JSON.stringify(value)); }
say('div_14', sandbox.studioTempoDivision('1/4'));
say('div_18', sandbox.studioTempoDivision('1/8'));
say('div_116', sandbox.studioTempoDivision('1/16'));
say('div_12', sandbox.studioTempoDivision('1/2'));
say('div_34', sandbox.studioTempoDivision('3/4'));
say('div_1', sandbox.studioTempoDivision('1'));
say('div_2', sandbox.studioTempoDivision('2'));
say('div_4', sandbox.studioTempoDivision('4'));
say('div_18d', sandbox.studioTempoDivision('1/8d'));
say('div_18t', sandbox.studioTempoDivision('1/8t'));
say('div_off', sandbox.studioTempoDivision('off'));
say('div_blank', sandbox.studioTempoDivision(''));
say('div_ms', sandbox.studioTempoDivision('250ms'));
say('div_decimal', sandbox.studioTempoDivision('250.0'));
say('ms_250', sandbox.studioTempoManualMs('250ms'));
say('ms_decimal', sandbox.studioTempoManualMs('250.0'));
say('ms_integer', sandbox.studioTempoManualMs('250'));
say('ms_off', sandbox.studioTempoManualMs('off'));
say('delay_14', sandbox.studioTempoResolveValue('delay', '1/4', 120));
say('delay_12', sandbox.studioTempoResolveValue('delay', '1/2', 120));
say('delay_4', sandbox.studioTempoResolveValue('delay', '4', 120));
say('delay_4_fast', sandbox.studioTempoResolveValue('delay', '4', 240));
say('delay_ms', sandbox.studioTempoResolveValue('delay', '250ms', 120));
say('delay_off', sandbox.studioTempoResolveValue('delay', 'off', 120));
say('flanger_116', sandbox.studioTempoResolveValue('flanger', '1/16', 120));
say('flanger_14', sandbox.studioTempoResolveValue('flanger', '1/4', 120));
say('tremolo_18', sandbox.studioTempoResolveValue('tremolo', '1/8', 120));
say('panner_ms', sandbox.studioTempoResolveValue('stereo_panner', '250ms', 120));
say('natural_rate_low', sandbox.studioEffectNatural('tremolo', 'rate', 0));
say('natural_rate_high', sandbox.studioEffectNatural('tremolo', 'rate', 100));
say('natural_shape', sandbox.studioEffectNatural('stereo_panner', 'shape', 2.6));
say('browser_only_panner', sandbox.studioEffectBrowserOnly('stereo_panner'));
say('browser_only_delay', sandbox.studioEffectBrowserOnly('delay'));
JS
	close $fh;

	my $output = `$node "$harness" "$root/public/js/manager/studio/08_effects.js" 2>&1`;
	my %got = map { /^([a-z0-9_]+)=(.*)$/ ? ($1, $2) : () } split /\n/, $output;

	is($got{'div_14'}, '1', '1/4 is one beat');
	is($got{'div_18'}, '0.5', '1/8 is half a beat');
	is($got{'div_116'}, '0.25', '1/16 is a quarter beat');
	is($got{'div_12'}, '2', '1/2 is two beats');
	is($got{'div_34'}, '3', '3/4 is three beats');
	is($got{'div_1'}, '4', 'a bare 1 is a whole note, four beats');
	is($got{'div_2'}, '8', 'a bare 2 is eight beats');
	is($got{'div_4'}, '16', 'a bare 4 is sixteen beats');
	is($got{'div_18d'}, '0.75', 'dotted 1/8 is 1.5 times the division');
	ok(defined $got{'div_18t'} && abs($got{'div_18t'} - (2 / 3) * 0.5) < 1e-9,
		'triplet 1/8 is 2/3 of the division');
	is($got{'div_off'}, 'null', 'off is not a division');
	is($got{'div_blank'}, 'null', 'a blank field is not a division');
	is($got{'div_ms'}, 'null', 'a millisecond value is not a division');
	is($got{'div_decimal'}, 'null', 'a decimal value is not a division');
	is($got{'ms_250'}, '250', '250ms is 250 milliseconds');
	is($got{'ms_decimal'}, '250', '250.0 is 250 milliseconds');
	is($got{'ms_integer'}, 'null', 'a bare integer is a whole note, not milliseconds');
	is($got{'ms_off'}, 'null', 'off has no millisecond value');
	is($got{'delay_14'}, '0.5', '1/4 at 120 BPM is a half-second delay');
	is($got{'delay_12'}, '1', '1/2 at 120 BPM is a one-second delay');
	is($got{'delay_4'}, '8', 'four bars at 120 BPM is eight seconds');
	is($got{'delay_4_fast'}, '4', 'four bars at 240 BPM is four seconds');
	is($got{'delay_ms'}, '0.25', '250ms is a quarter-second delay');
	is($got{'delay_off'}, 'null', 'off returns to the manual knob');
	is($got{'flanger_116'}, '8', '1/16 at 120 BPM is an 8 Hz flanger rate');
	is($got{'flanger_14'}, '2', '1/4 at 120 BPM is a 2 Hz flanger rate');
	is($got{'tremolo_18'}, '4', '1/8 at 120 BPM is a 4 Hz tremolo rate');
	is($got{'panner_ms'}, '4', 'a 250ms period is 4 Hz');
	is($got{'natural_rate_low'}, '0.1', 'the tremolo rate knob starts at 0.1 Hz');
	is($got{'natural_rate_high'}, '20', 'the tremolo rate knob ends at 20 Hz');
	is($got{'natural_shape'}, '2', 'a shape above 2 clamps to square');
	is($got{'browser_only_panner'}, 'false', 'the stereo panner is native');
	is($got{'browser_only_delay'}, 'false', 'the delay is not browser only');
}
else {
	diag('node is not installed; the parser checks are skipped');
}

done_testing();
