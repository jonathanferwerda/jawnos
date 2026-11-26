# tests-for: engine/src/effect.rs engine/src/effect/harmonizer.rs engine/src/effect/de_esser.rs engine/src/effect/modulator.rs engine/src/effect/pitch_shift.rs engine/src/effect/gate.rs engine/src/effect/slider.rs engine/src/effect/overdrive.rs engine/src/effect/wah.rs engine/src/effect/chorus.rs engine/src/effect/vibrato.rs engine/src/effect/autotune.rs public/js/manager/studio/08_effects.js lib/JawnOS/Audio/Plan.pm perl/gb/05_abilities_and_studio.pl lib/JawnOS/Controller/manager_misc9.pm perl/help/topics_apps.pl
# covers:    The ten newer Studio pedals on all three sides. The Perl table
#            (label, control order, dropdowns, the Sync field on the five LFOs,
#            the palette and its knob colours), the native allowlist, the engine
#            InsertKind (names, controls, codes, defaults, the gate's ms->s
#            conversion, one module per pedal implementing Effect), Plan.pm's
#            vocabulary, the browser builders and their natural-unit mapping,
#            the typed tempo-sync wiring, and the help/docs prose.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $effect = read_file("$root/engine/src/effect.rs");
my $plan   = read_file("$root/lib/JawnOS/Audio/Plan.pm");
my $studio = read_file("$root/perl/gb/05_abilities_and_studio.pl");
my $take   = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my $js     = read_file("$root/public/js/manager/studio/08_effects.js");
my $pitch  = read_file("$root/engine/src/effect/pitch_shift.rs");
my $help   = read_file("$root/perl/help/topics_apps.pl");
my $doc    = read_file("$root/docs/studio-effects.md");
my $audit  = read_file("$root/docs/pedal-audit.md");

# name, variant, label, controls in wire order, the sync control's presence,
# the browser builder suffix, and the build() default expression.
my @pedals = (
	{ name => 'harmonizer', variant => 'Harmonizer', label => 'Harmonizer',
	  controls => [qw(key scale degree mix)], sync => 0, builder => 'Harmonizer',
	  build => 'Harmonizer::new(0, 0, Harmonizer::DEFAULT_DEGREE, 0.35)' },
	{ name => 'de_esser', variant => 'DeEsser', label => 'De-esser',
	  controls => [qw(thresh freq amount)], sync => 0, builder => 'DeEsser',
	  build => 'DeEsser::new(-28.0, 6_500.0, 0.6)' },
	{ name => 'modulator', variant => 'Modulator', label => 'Modulator',
	  controls => [qw(rate depth mix)], sync => 1, builder => 'Modulator',
	  build => 'Modulator::new(5.0, 0.7, 0.5)' },
	{ name => 'pitch_shift', variant => 'PitchShift', label => 'Pitch Shift',
	  controls => [qw(semitones mix)], sync => 0, builder => 'PitchShift',
	  build => 'PitchShift::new(7.0, 1.0)' },
	{ name => 'gate', variant => 'Gate', label => 'Gate',
	  controls => [qw(thresh attack hold release range)], sync => 0, builder => 'Gate',
	  build => 'Gate::new(-45.0, 0.001, 0.05, 0.15, -60.0)' },
	{ name => 'slider', variant => 'Slider', label => 'Slider',
	  controls => [qw(rate depth duty)], sync => 1, builder => 'Slider',
	  build => 'Slider::new(6.0, 0.8, 0.5)' },
	{ name => 'overdrive', variant => 'Overdrive', label => 'Overdrive',
	  controls => [qw(drive tone level)], sync => 0, builder => 'Overdrive',
	  build => 'Overdrive::new(0.5, 0.5, 0.6)' },
	{ name => 'wah', variant => 'Wah', label => 'Wah',
	  controls => [qw(rate depth mix)], sync => 1, builder => 'Wah',
	  build => 'Wah::new(2.0, 0.7, 1.0)' },
	{ name => 'chorus', variant => 'Chorus', label => 'Chorus',
	  controls => [qw(rate depth mix)], sync => 1, builder => 'Chorus',
	  build => 'Chorus::new(0.8, 0.5, 0.5)' },
	{ name => 'vibrato', variant => 'Vibrato', label => 'Vibrato',
	  controls => [qw(rate depth)], sync => 1, builder => 'Vibrato',
	  build => 'Vibrato::new(5.0, 0.4)' },
);

# --- the Perl table: label, control order, and the Sync last -----------------
my %knob_count;
for my $p (@pedals) {
	my $name = $p->{name};
	my $label = $p->{label};
	my ($block) = $studio =~ /\b\Q$name\E\s*=>\s*\{\s*label\s*=>\s*'\Q$label\E',\s*controls\s*=>\s*\[(.*?)\n\t\t\]\s*\}/s;
	ok(defined $block, "$name is in the effect table with the label $label");
	next unless defined $block;
	my @controls = $block =~ /\{\s*control\s*=>\s*'([a-z0-9_]+)'/g;
	my @want = (@{ $p->{controls} }, ($p->{sync} ? ('sync') : ()));
	is_deeply(\@controls, \@want, "$name's controls are @want in order");
	if ($p->{sync}) {
		like($block, qr/control\s*=>\s*'sync',[^}]*?typed\s*=>\s*1/s, "$name's Sync is the typed path");
	}
	# The drawn tile has one knob per control that is not a dropdown.
	my @rows = $block =~ /(\{\s*control\s*=>\s*'[^}]*\})/g;
	$knob_count{$name} = scalar grep { !/options\s*=>/ } @rows;
}

# The harmonizer's three musical choices are dropdowns, not sliders.
like($studio, qr/harmonizer\s*=>\s*\{[\s\S]*?control\s*=>\s*'key'[^}]*?options\s*=>/,
	'the harmonizer key is a dropdown');
like($studio, qr/harmonizer\s*=>\s*\{[\s\S]*?control\s*=>\s*'degree'[^}]*?4th Below[\s\S]*?4th Above/,
	'the harmonizer degree names the seven intervals');
like($studio, qr/harmonizer\s*=>\s*\{[\s\S]*?control\s*=>\s*'scale'[^}]*?Pentatonic/,
	'the harmonizer scale shares the autotune four');

# --- the palette and its drawn colours --------------------------------------
my ($palette) = $studio =~ /palette\s*=>\s*\[\s*qw\(([^)]*)\)\s*\]/s;
my @palette = split ' ', ($palette // '');
my @tail = map { $_->{name} } @pedals;
is_deeply([ @palette[ -scalar(@tail) .. -1 ] ], \@tail,
	'the ten pedals close the Add list in the spec order');
like($palette // '', qr/\bstereowidener\b[\s\S]*?\bharmonizer\b/, 'they follow the widener');
for my $p (@pedals) {
	like($palette // '', qr/(?:^|\s)\Q$p->{name}\E(?:\s|$)/, "the palette offers $p->{name}");
	my ($art) = $studio =~ /\b\Q$p->{name}\E\s*=>\s*\[\s*qw\(([^)]*)\)\s*\]/s;
	ok(defined $art, "$p->{name} has a palette_art colour list");
	next unless defined $art;
	my @colours = split ' ', $art;
	is(scalar(@colours), $knob_count{ $p->{name} },
		"$p->{name} has one knob colour per non-dropdown control");
}

# --- the native allowlist ---------------------------------------------------
my ($take_list) = $take =~ /studio_take_inserts\s*=\s*map\s*\{\s*\$_\s*=>\s*1\s*\}\s*qw\(([^)]*)\)/s;
my %take = map { $_ => 1 } split ' ', ($take_list // '');
for my $p (@pedals) {
	ok($take{ $p->{name} }, "a native take may carry $p->{name}");
}

# --- the engine: names, controls, codes, defaults ---------------------------
my $controls_block = ($effect =~ /(pub const fn controls\(self\).*?\n\s{4}\})/s)[0] // '';
unlike($controls_block, qr/"sync"/, 'no engine control list carries the page-only sync string');

my ($plan_names_block) = $plan =~ /audio_plan_insert_names\s*=\s*qw\(([^)]*)\)/s;
my %plan_names = map { $_ => 1 } split ' ', ($plan_names_block // '');

my $code = 16;
for my $p (@pedals) {
	$code++;
	my $variant = $p->{variant};
	my $name = $p->{name};
	my $quoted = join('", "', @{ $p->{controls} });
	like($effect, qr/InsertKind::$variant => "$name"/, "InsertKind::$variant is the wire name $name");
	like($effect, qr/InsertKind::$variant => &\["\Q$quoted\E"\]/, "$name's engine controls are @{ $p->{controls} }");
	like($effect, qr/"$name" => Some\(InsertKind::$variant\)/, "the parser accepts $name");
	like($effect, qr/InsertKind::$variant => $code,/, "$name's parameter code is $code");
	like($effect, qr/^\s{12}$code => InsertKind::$variant,/m, "code $code reads back as $name");
	like($effect, qr/InsertKind::$variant => [\s\S]{0,60}?\Q$p->{build}\E/, "$name starts at its contract default");
	like($effect, qr/\b$variant\b/, "the engine module exposes $variant");

	ok($plan_names{$name}, "the plan vocabulary names $name");
	my $control_list = join(' ', @{ $p->{controls} });
	like($plan, qr/\b\Q$name\E\s*=>\s*\[qw\(\Q$control_list\E\)\]/,
		"the plan keeps the controls of $name");
}

like($effect, qr/\(InsertKind::Gate, "attack" \| "hold" \| "release"\)/,
	'the gate converts the contract ms to its internal seconds');
like($plan, qr/harmonizer\s*=>\s*\{\s*key\s*=>\s*1,\s*scale\s*=>\s*1,\s*degree\s*=>\s*1\s*\}/,
	'the harmonizer choices are whole indexes in a plan');
unlike($plan, qr/^\s*sync\b/m, 'the plan never lists sync');

# --- one engine module per pedal, each a real Effect ------------------------
for my $p (@pedals) {
	my $path = "$root/engine/src/effect/$p->{name}.rs";
	ok(-f $path, "$p->{name}.rs exists");
	next unless -f $path;
	my $src = read_file($path);
	like($src, qr/pub struct \Q$p->{variant}\E\b/, "$p->{name}.rs declares the struct");
	like($src, qr/impl Effect for \Q$p->{variant}\E/, "$p->{name}.rs implements Effect");
	like($src, qr/fn prepare\(&mut self/, "$p->{name}.rs allocates in prepare");
	like($src, qr/fn process\(&mut self/, "$p->{name}.rs processes a block");
	like($src, qr/fn set\(&mut self, name: &str, value: f32\)/, "$p->{name}.rs clamps a knob");
	like($src, qr/fn name\(&self\) -> &'static str \{\s*\n\s*"\Q$p->{name}\E"/, "$p->{name}.rs names itself");
	like($src, qr/silence/, "$p->{name}.rs pins silence in and silence out in a test");
}

# --- the browser: aliases, builders and setters -----------------------------
for my $p (@pedals) {
	my $name = $p->{name};
	my $fn = 'studioEffect' . $p->{builder};
	like($js, qr/(?:^|\n)\s*\Q$name\E\s*:\s*'\Q$name\E'/, "studioInsert has a $name alias");
	like($js, qr/(?:^|\n)\s*\Q$name\E\s*:\s*\Q$fn\E/, "the builder table registers $fn");
	like($js, qr/^function \Q$fn\E\(ctx, name\)/m, "$fn takes a context and a name");
	my ($body) = $js =~ /function \Q$fn\E\(ctx, name\) \{([\s\S]*?)\n\}/;
	ok(defined $body, "$fn has a body");
	next unless defined $body;
	for my $control (@{ $p->{controls} }) {
		like($body, qr/fx\.setters\['\Q$control\E'\]\s*=/, "$fn has a setter for $control");
	}
	like($body, qr/fx\.set\('/, "$fn sets its defaults through fx.set");
}

# The harmonizer and pitch shifter are the granular pair.
like($js, qr/^function studioEffectGrain\(ctx, input, wet, settings\)/m,
	'the two pitch pedals share one grain runner');
like($js, qr/^function studioHarmonizerTarget\(hz, key, scale, degree\)/m,
	'the harmonizer moves the detected note by scale steps');
like($js, qr/A fixed ratio \(pitch_shift\)/, 'the grain block documents the fixed ratio');

# The pitch shifter is exact from -24 to +24 on both sides: a stream of grains
# reads at the ratio, with only the seam crossfaded. Two always-audible taps
# cancel the shifted carrier at the extremes and leave the interval flat.
like($pitch, qr/MIN_SEMITONES: f32 = -24\.0/, 'the engine floor is -24 semitones');
like($pitch, qr/MAX_SEMITONES: f32 = 24\.0/, 'the engine ceiling is +24 semitones');
like($pitch, qr/struct Grain\b/, 'the engine schedules resampled grains');
like($pitch, qr/let delay = grain\.base \+ p \* \(1\.0 - grain\.ratio\);/,
	'each engine grain reads at the ratio');
like($js, qr/function studioPitchShiftBlock\(state, event, settings\)/,
	'the browser has a fixed-ratio block of its own');
like($js, qr/var delay = grain\.base \+ p \* \(1 - grain\.ratio\);/, 'each browser grain reads at the ratio');
like($js, qr/var STUDIO_PITCH_BASE_SECONDS = 0\.04;/, 'the browser bases its look-back on the dry delay');

# --- the browser: natural units --------------------------------------------
like($js, qr/'harmonizer\.key': 11,\s*\n\s*'harmonizer\.scale': 3,\s*\n\s*'harmonizer\.degree': 6/,
	'the harmonizer choices are whole indexes');
like($js, qr/case 'de_esser\.thresh':\s*\n\s*case 'gate\.thresh':\s*\n\s*return -60 \+ amount \* 60;/,
	'the de-esser and gate thresholds share the dB band');
like($js, qr/case 'gate\.range':\s*\n\s*return -80 \+ amount \* 80;/, 'the gate floor runs -80..0 dB');
like($js, qr/case 'de_esser\.freq':\s*\n\s*return 4000 \+ amount \* 8000;/, 'the split runs 4..12 kHz');
like($js, qr/case 'pitch_shift\.semitones':\s*\n\s*return Math\.round\(-24 \+ amount \* 48\);/,
	'a pitch shift is a whole semitone from -24 to +24');
like($js, qr/case 'gate\.attack':\s*\n\s*return 0\.1 \+ amount \* 49\.9;/, 'the gate attack starts at 0.1 ms');
like($js, qr/case 'gate\.hold':\s*\n\s*return amount \* 500;/, 'the gate hold reaches 500 ms');
like($js, qr/case 'gate\.release':\s*\n\s*return 20 \+ amount \* 980;/, 'the gate release runs 20..1000 ms');
like($js, qr/case 'slider\.duty':\s*\n\s*return 0\.05 \+ amount \* 0\.9;/, 'duty runs 5..95 percent');
like($js, qr/case 'chorus\.rate':\s*\n\s*return 0\.05 \+ amount \* 4\.95;/, 'chorus is the slow LFO');
like($js, qr/case 'modulator\.rate':\s*\n\s*case 'slider\.rate':\s*\n\s*case 'wah\.rate':\s*\n\s*case 'vibrato\.rate':\s*\n\s*return 0\.1 \+ amount \* 19\.9;/,
	'modulator, slider, wah and vibrato share the 0.1..20 Hz band');

# --- the browser: tempo sync -------------------------------------------------
for my $p (grep { $_->{sync} } @pedals) {
	like($js, qr/(?:^|\n)\s*\Q$p->{name}\E\s*:\s*'rate'/, "$p->{name} syncs its rate");
	like($js, qr/'\Q$p->{name}\E\.sync': 1/, "$p->{name}'s sync field is typed");
}
like($js, qr/studioTempoLimits = \{[\s\S]*?chorus: \{ min: 0\.05, max: 5 \}/, 'chorus caps a synced rate at 5 Hz');
like($js, qr/studioTempoLimits = \{[\s\S]*?modulator: \{ min: 0\.1, max: 20 \}/, 'modulator reaches 20 Hz');
like($js, qr/studioTempoLimits = \{[\s\S]*?slider: \{ min: 0\.1, max: 20 \}/, 'slider reaches 20 Hz');
like($js, qr/studioTempoLimits = \{[\s\S]*?wah: \{ min: 0\.1, max: 20 \}/, 'wah reaches 20 Hz');
like($js, qr/studioTempoLimits = \{[\s\S]*?vibrato: \{ min: 0\.1, max: 20 \}/, 'vibrato reaches 20 Hz');

# --- the prose ---------------------------------------------------------------
for my $p (@pedals) {
	like($doc, qr/\|\s*`\Q$p->{name}\E`\s*\|/, "the contract doc lists $p->{name}");
	like($audit, qr/\|\s*`\Q$p->{name}\E`\s*\|/, "the audit doc names $p->{name} and its circuit");
}
like($help, qr/Harmonizer sings one diatonic harmony/, 'the help says what the harmonizer does');
like($help, qr/De-esser tames harsh highs/, 'the help says what the de-esser does');
like($help, qr/Vibrato wobbles the pitch/, 'the help says what the vibrato does');
like($help, qr/Modulator, Slider, Wah, Chorus and Vibrato - has a Sync field/,
	'the help names the synced pedals');

done_testing();
