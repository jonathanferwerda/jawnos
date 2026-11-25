# tests-for: public/js/manager/studio/12_tuner.js public/js/manager/studio/09_pedals.js public/js/manager/studio/04_knobs.js public/js/manager/studio/03_editing.js templates/studio/markup.html.ep templates/studio/style.html.ep perl/help/topics_apps.pl perl/gb/05_abilities_and_studio.pl t/357-studio-tuner.t
# covers:    Jtune is a listen-only pedal in the rack: dragged in, ordered and
#            bypassed like any insert, its analyser taps that insert's input, so
#            first in the chain is the clean input and after a pedal it hears that
#            pedal. Off is bypassed: the pass-through keeps the sound unchanged
#            and the tuner stops listening, and it opens no microphone. The yellow
#            panel names the nearest note with an upgrade/downgrade arrow either
#            side, and the lamp is grey (off), amber (listening) or green (in
#            tune). The pitch maths is run under node against guitar and bass
#            tones, so a change to the detector has to keep its answers. The drawn
#            pedals' frame and the stomp switch are pinned here too.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource qw(repo_root);

my $root = repo_root();
my $tuner  = read_file("$root/public/js/manager/studio/12_tuner.js");
my $rack   = read_file("$root/public/js/manager/studio/09_pedals.js");
my $knobs  = read_file("$root/public/js/manager/studio/04_knobs.js");
my $edit   = read_file("$root/public/js/manager/studio/03_editing.js");
my $markup = read_file("$root/templates/studio/markup.html.ep");
my $style  = read_file("$root/templates/studio/style.html.ep");
my $help   = read_file("$root/perl/help/topics_apps.pl");
my $gb     = read_file("$root/perl/gb/05_abilities_and_studio.pl");

# --- the frame the drawn pedals were missing -------------------------------
like($style, qr/\.pedal_graphic\s*\{[^}]*color-mix\(in srgb, var\(--panel-2\) 30%, #000\)/s,
	'a drawn pedal wears the artwork pedals\' dark case frame');
like($style, qr/\.pedal_graphic::before\s*\{[^}]*inset:\s*3px/s,
	'the case frame has its own bright rim');
like($style, qr/\.pedal_body\s*\{[^}]*inset:\s*4px/s, 'the drawn body sits inside the case frame');
like($style, qr/\.studio_pedal_foot\s*\{[^}]*border-radius:\s*11px/s, 'the footswitch is a rounded treadle');
like($style, qr/\.studio_pedal_foot\s*\{[^}]*transform:\s*translateX\(-50%\)/s, 'the treadle is centred in the case');
like($style, qr/\.studio_pedal_foot\[aria-pressed="true"\]\s*\{[\s\S]*?var\(--accent\)/,
	'the lit treadle takes the theme accent');

# --- the tuner's switch, screen and lamp -----------------------------------
like($markup, qr/data-tuner="yes"/, 'the Jtune library tile is marked a tuner');
like($markup, qr/class="studio_tuner"[^>]*aria-live="polite"/, 'the tile carries the tuner display');
like($markup, qr/studio_tuner_arrow studio_tuner_up/, 'the display has an arrow on the left');
like($markup, qr/studio_tuner_arrow studio_tuner_down/, 'the display has an arrow on the right');
like($markup, qr/studio_tuner_letter/, 'the display has the note');
like($markup, qr/studio_tuner_cents/, 'the display has the cents line');
like($gb, qr/control => 'automatic'[^\n]*hint => 'Start or stop the tuner'/,
	'the pink switch names itself as the tuner power');
like($style, qr/\.studio_tuner\s*\{[^}]*grid-template-columns:\s*18px minmax\(0, 1fr\) 18px/s,
	'the note sits between the two arrows');
like($style, qr/\.studio_tuner_arrow_on\s*\{/, 'the arrow that is telling you which way to turn lights up');
like($style, qr/\.studio_tuner_tuned \.studio_tuner_letter/, 'the tuned note is green');
like($style, qr/\.pedal\[data-tuner="yes"\] \.studio_pedal_led\s*\{[^}]*#6b7280/s,
	'the tuner lamp is grey when it is off');
like($style, qr/\.pedal\[data-tuner="yes"\] \.studio_pedal_led\.studio_tuner_listening\s*\{[^}]*#f0b429/s,
	'the tuner lamp is amber while it listens');
like($style, qr/\.pedal\[data-tuner="yes"\] \.studio_pedal_led\.studio_tuner_tuned\s*\{[^}]*#35e05a/s,
	'the tuner lamp is green in tune');

# --- one power switch, wired the same from every press ---------------------
like($knobs, qr/e\.stopPropagation\(\);[\s\S]*?studioTunerToggle\(tile\.attr\('chain'\)\)/,
	'the pink switch toggles the tuner on its own chain and stops the tile toggling it twice');
like($tuner, qr/studioTunerPaintLamp\(tile\);/, 'the tuner owns its lamp instead of the effect lamp');
like($rack, qr/if \(typeof studioTunerSync === 'function'\) \{ studioTunerSync\(\); \}/,
	'one lamp paint keeps the tuner in step with its insert');
like($tuner, qr/#studio_pedalboard_rack \.studio_rack_tile\[insert="Jtune"\]/, 'the board tile itself is the tuner');
like($tuner, qr/function studioTunerInsert\(ch\)/, 'the tuner reads its own insert');
like($tuner, qr/studioRackFind\(ch, 'Jtune'\)/, 'the tuner follows its place in the track\'s rack');
like($tuner, qr/ins\.input\.connect\(analyser\)/,
	'the tuner taps the insert\'s input, so first in the chain is the clean input');
like($tuner, qr/if \(!ins\) \{ studioSetInsert\(ch, 'Jtune', true, chain\); \}/,
	'a press adds the tuner to the chain its tile shows');
like($tuner, qr/studioSetInsertBypass\(ch, 'Jtune', !ins\.bypassed, chain\)/,
	'the next press bypasses it on that chain like any pedal');
like($tuner, qr/function studioTunerSync\(\)/, 'one function keeps the analyser on the insert');
like($tuner, qr/No live input/, 'a silent chain says why it cannot tune');
like($tuner, qr/function studioTunerFollow\(\)/, 'the tuner can move to another chain');
like($rack, qr/studioTunerFollow\(\)/, 'selecting a strip moves the listening tuner');
like($tuner, qr/gain\.value = 0/, 'the tuner is a listener, never a monitor');
unlike($tuner, qr/getUserMedia/, 'the tuner opens no microphone of its own');
unlike($edit, qr/studioTunerStop\(\)/, 'closing the pedalboard leaves the pedal on its chain');
like($knobs, qr/studioTunerStop\(\)/, 'a new window or song stops the listener');

# --- the help speaks in the tuner's words ----------------------------------
like($help, qr/listen-only pedal in a track.{0,3}s rack/, 'the help makes the tuner a rack pedal');
like($help, qr/put it first and it hears the clean input/, 'the help says first in the chain hears the clean input');
like($help, qr/off, it is bypassed, the signal still passes through untouched/,
	'the help says off bypasses it and leaves the sound alone');
like($help, qr/it opens no microphone of its own/, 'the help says it opens no microphone');
like($help, qr/the arrow on the left means tune up, the arrow on the right means tune down/,
	'the help names the arrows');
like($help, qr/within five cents/, 'the help states the tolerance');
unlike($help, qr/cannot be dragged into a rack/, 'the help no longer refuses to drag it');
unlike($help, qr/ignores that entry when it loads/, 'the help no longer drops a saved tuner');

# --- the maths, under node --------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;

SKIP: {
	skip 'node is not installed', 13 unless $node && -x $node;

	my $harness = <<'JS';
var fs = require('fs'), vm = require('vm');
var code = fs.readFileSync(process.argv[2], 'utf8');
function chain() {
	var o = { on: function () { return o; }, find: function () { return o; }, length: 0,
		attr: function () { return o; }, toggleClass: function () { return o; },
		text: function () { return o; }, closest: function () { return o; } };
	return o;
}
var sandbox = {
	console: console, Math: Math, isFinite: isFinite,
	Float32Array: Float32Array, Uint8Array: Uint8Array,
	setTimeout: setTimeout, clearTimeout: clearTimeout,
	jawnosT: function (s) { return s; },
	$: chain, document: {}, window: {}, navigator: {}
};
vm.createContext(sandbox);
vm.runInContext(code, sandbox);
function tone(hz, rate, n) {
	var a = new Float32Array(n);
	for (var i = 0; i < n; i++) { a[i] = 0.5 * Math.sin(2 * Math.PI * hz * i / rate); }
	return a;
}
function report(name, samples, rate) {
	var p = sandbox.studioTunerPitch(samples, rate);
	if (!p) { console.log(name + ' null'); return; }
	var n = sandbox.studioTunerNote(p.hz);
	console.log(name + ' ' + p.hz.toFixed(2) + ' ' + n.name + n.octave + ' ' + n.cents.toFixed(1));
}
var rate = 24000, n = 2048;
report('A4', tone(440, rate, n), rate);
report('flat', tone(440 * Math.pow(2, -20 / 1200), rate, n), rate);
report('sharp', tone(440 * Math.pow(2, 20 / 1200), rate, n), rate);
report('E2', tone(82.4069, rate, n), rate);
report('E1', tone(41.2034, rate, n), rate);
report('silence', new Float32Array(n), rate);
JS

	my ($hh, $harness_file) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $hh $harness;
	close $hh;
	my $part = "$root/public/js/manager/studio/12_tuner.js";
	my @out = split /\n/, `"$node" "$harness_file" "$part" 2>&1`;
	my %r;
	for my $line (@out) {
		my ($name, @rest) = split ' ', $line;
		next unless defined $name;
		$r{$name} = \@rest;
	}
	ok(scalar keys %r == 6, 'the detector answered every test tone')
		or diag join("\n", @out);

	is(($r{'A4'} || [])->[1], 'A4', 'a 440Hz tone is A4');
	ok(defined($r{'A4'}) && abs($r{'A4'}->[0] - 440) < 2, 'the A4 frequency is within 2Hz');
	ok(defined($r{'A4'}) && abs($r{'A4'}->[2]) < 1, 'an in-tune A4 reads zero cents');

	is(($r{'flat'} || [])->[1], 'A4', 'a 20-cent-flat tone is still A4');
	ok(defined($r{'flat'}) && $r{'flat'}->[2] < -8 && $r{'flat'}->[2] > -32,
		'and it reads flat by about 20 cents');

	is(($r{'sharp'} || [])->[1], 'A4', 'a 20-cent-sharp tone is still A4');
	ok(defined($r{'sharp'}) && $r{'sharp'}->[2] > 8 && $r{'sharp'}->[2] < 32,
		'and it reads sharp by about 20 cents');

	is(($r{'E2'} || [])->[1], 'E2', "a guitar's low E is E2");
	ok(defined($r{'E2'}) && abs($r{'E2'}->[2]) < 5, 'the low E reads in tune');
	is(($r{'E1'} || [])->[1], 'E1', "a bass's low E is E1");
	ok(defined($r{'E1'}) && abs($r{'E1'}->[2]) < 8, 'the bass low E reads in tune');
	is(($r{'silence'} || [])->[0], 'null', 'silence is not a note');
}

done_testing();
