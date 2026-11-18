# tests-for: public/js/manager/windows/05_effects.js public/js/manager/windows/02_fit.js public/js/manager/windows/03_stack.js public/js/manager/windows.js public/js/manager/taskbar_edit.js public/css/manager.css templates/configure/misc_setting_list.html.ep templates/layouts/manager.html.ep public/js/manager/taskbar/01_inputs.js perl/help/topics_configure.pl
# covers:    the desk's window effects - a lean while dragging, a stretch into
#            the half or the whole screen, a bounce out and back, and a kick on
#            the pin - all transient transform classes behind one Misc switch.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

my $root = repo_root();
my $effects  = read_file("$root/public/js/manager/windows/05_effects.js");
my $fit      = read_file("$root/public/js/manager/windows/02_fit.js");
my $stack    = read_file("$root/public/js/manager/windows/03_stack.js");
my $edit_bar = read_file("$root/public/js/manager/taskbar_edit.js");
my $index    = read_file("$root/public/js/manager/windows.js");
my $css      = read_file("$root/public/css/manager.css");
my $misc     = read_file("$root/templates/configure/misc_setting_list.html.ep");
my $layout   = read_file("$root/templates/layouts/manager.html.ep");
my $inputs   = read_file("$root/public/js/manager/taskbar/01_inputs.js");
my $help     = read_file("$root/perl/help/topics_configure.pl");

# --- one switch, seeded for this device -------------------------------------
like($misc, qr/\[ 'window_effects', &subs::ui\('Window Effects'\), \[ 'on', 'off' \] \]/,
	'Misc carries the Window Effects switch');
like($layout, qr/window_effects: '<%= &subs::misc_setting\('window_effects'\) \|\| 'on' %>'/,
	'the manager seeds it for this device, on unless turned off');
like($inputs, qr/setting == 'window_effects'.*?jawnosWindowEffectsSet/,
	'the panel switch reaches the live desk');
like($help, qr/Window Effects turns the desk\\?'s window motions on or off/,
	'the Configure help names the switch and what it does');

# --- the manifest names the new part ----------------------------------------
like($index, qr/05_effects\.js/, 'windows.js names its effects part');
like($effects, qr/function jawnosWindowEffectsOn\(\)/, 'the switch has one reader');
like($effects, qr/\['window_effects'\] === 'off'/, 'only the stored off turns the effects off');
like($effects, qr/function jawnosWindowEffectsSet\(value\)/, 'and one live setter');

# --- the motions are transform-only classes ---------------------------------
foreach my $name (qw(wobble settle stretch bounce_in bounce_out lock)) {
	like($css, qr/\@keyframes jawnos_window_$name \{/, "manager.css defines $name");
}
foreach my $class (qw(wobble settle stretch in out lock)) {
	like($css, qr/\.wind\.jawnos_effect_$class \{ animation:/, "the $class class plays a keyframe");
}
like($css, qr/prefers-reduced-motion: reduce/, 'reduced motion shortens every effect');
unlike($css, qr/\.wind\.jawnos_effect_[a-z_]+ \{[^}]*\b(left|top|width|height):/s,
	'no effect writes layout geometry');

# --- every action the person asked for is hooked ----------------------------
like($fit, qr/function windowMaximizer.*?jawnosWindowEffect\(win, 'stretch'\)/s, 'maximize stretches');
like($fit, qr/function windowHalfski.*?jawnosWindowEffect\(win, 'stretch'\)/s, 'a half snap stretches');
like($fit, qr/function windowRestore\(.*?jawnosWindowEffect\(win, 'in'\)/s, 'restore bounces in');
like($fit, qr/function windowMinimizer.*?jawnosWindowMinimizeOut\(win\)/s, 'minimize bounces out');
like($fit, qr/function windowRestorer.*?jawnosWindowRestoreIn\(win\)/s, 'the tile toggle bounces in');
like($fit, qr/function windowRestorer.*?jawnosWindowMinimizeOut\(win\)/s, 'and bounces out on its own hide');
like($fit, qr/jawnosWindowWobbleStart\(win\)/, 'a drag starts the lean');
like($fit, qr/jawnosWindowWobbleStop\(win\)/, 'and the drop settles it');
like($fit, qr/jawnosWindowEffect\(win, 'lock'\)/, 'the pin gives the window a kick');
like($index, qr/jawnosWindowRestoreIn\(tw\)/, 'a named window shown from the bar bounces in');
like($index, qr/jawnosWindowMinimizeOut\(tw\)/, 'and one hidden from the bar bounces out');
like($index, qr/jawnosWindowEffectLeaving\(tw\)/, 'a tile pressed mid-out brings the window back');
like($fit, qr/jawnosWindowEffectLeaving\(win\)/, 'the tile toggle does the same');
like($edit_bar, qr/jawnosWindowEffectLeaving\(win\)/, 'the editable bar does too');
like($fit, qr/function windowMinimizer.*?jawnosWindowRestoreIn\(win\)/s, 'the desktop bar widget bounces a window back in');
like($stack, qr/function topWindow.*?jawnosWindowEffectLeaving\(v\)/s, 'a leaving window is no longer the front');

# --- the switch and the hide/restore race, played in a bare context ---------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to play the effects', 1 unless $node && -x $node;

	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
'use strict';
const fs = require('fs');
const vm = require('vm');

let now = 0;
let seq = 0;
const timers = {};
function fakeSetTimeout(fn, ms) { const id = ++seq; timers[id] = { fn, at: now + (ms || 0) }; return id; }
function fakeClearTimeout(id) { delete timers[id]; }
function advance(ms) {
	now += ms;
	let due;
	do {
		due = Object.keys(timers).filter((id) => timers[id].at <= now);
		due.forEach((id) => { const t = timers[id]; delete timers[id]; t.fn(); });
	} while (due.length);
}

function Win(id) {
	this.id = id;
	this.classes = {};
	this.offsetWidth = 100;
	this.hidden = false;
	this.listeners = {};
}
Win.prototype.addEventListener = function (type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); };
Win.prototype.removeEventListener = function (type, fn) {
	const a = this.listeners[type] || [];
	const i = a.indexOf(fn);
	if (i >= 0) { a.splice(i, 1); }
};
Win.prototype.fire = function (type) {
	(this.listeners[type] || []).slice().forEach((fn) => fn({ target: this }));
};

function wrap(el) {
	if (!el) { return { length: 0 }; }
	return {
		jquery: 1,
		length: 1,
		0: el,
		addClass: function (c) { c.split(/\s+/).forEach((x) => { if (x) { el.classes[x] = 1; } }); return this; },
		removeClass: function (c) { c.split(/\s+/).forEach((x) => { delete el.classes[x]; }); return this; },
		hide: function () { el.hidden = true; return this; }
	};
}

const windows = [];
function $(sel) {
	if (sel && sel.jquery) { return sel; }
	if (sel instanceof Win) { return wrap(sel); }
	if (sel === '.wind') {
		const j = { length: windows.length };
		windows.forEach((w, i) => { j[i] = w; });
		j.each = function (fn) { windows.forEach((w, i) => fn.call(w, i, w)); return j; };
		return j;
	}
	return { length: 0 };
}

let adjuster = 0;
const sandbox = {
	$, setTimeout: fakeSetTimeout, clearTimeout: fakeClearTimeout,
	jawnos_bar_settings: { window_effects: 'on' },
	windowBackgroundAdjuster: function () { adjuster++; },
	console
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox);

let failures = 0;
function check(name, cond) {
	if (!cond) { failures++; console.log('not ok - ' + name); }
	else { console.log('ok - ' + name); }
}

const w = new Win('window_1');
windows.push(w);

check('effects default on', sandbox.jawnosWindowEffectsOn() === true);

// the switch reaches the live desk and stops what is running
sandbox.jawnosWindowEffect(w, 'stretch');
check('the effect adds its class', w.classes['jawnos_effect_stretch'] === 1);
sandbox.jawnosWindowEffectsSet('off');
check('the stored off turns effects off', sandbox.jawnosWindowEffectsOn() === false);
check('turning off clears the classes', !w.classes['jawnos_effect_stretch']);
check('an off desk does not animate', sandbox.jawnosWindowMinimizeOut(w) === false && !w.classes['jawnos_effect_out']);
sandbox.jawnosWindowEffectsSet('on');
check('the switch comes back on', sandbox.jawnosWindowEffectsOn() === true);

// one effect cleans itself up after its motion
sandbox.jawnosWindowEffect(w, 'stretch');
advance(1000);
check('the effect class does not outlive the motion', !w.classes['jawnos_effect_stretch']);

// the lean lasts only while held, then settles
sandbox.jawnosWindowWobbleStart(w);
check('a held title bar leans', w.classes['jawnos_effect_wobble'] === 1);
sandbox.jawnosWindowWobbleStop(w);
check('the drop stops the lean and settles', !w.classes['jawnos_effect_wobble'] && w.classes['jawnos_effect_settle'] === 1);

// minimizing out hides when the animation ends
const out = new Win('window_2');
windows.push(out);
check('the out effect takes the hide', sandbox.jawnosWindowMinimizeOut(out) === true);
check('and starts the animation', out.classes['jawnos_effect_out'] === 1);
check('a leaving window is known to the tiles', sandbox.jawnosWindowEffectLeaving(out) === true);
out.fire('animationend');
check('the window hides when the motion ends', out.hidden === true);
check('and stops being a leaving window', sandbox.jawnosWindowEffectLeaving(out) === false);
check('and the desk adjusts once', adjuster === 1);

// a restore that lands mid-flight cancels the pending hide
const back = new Win('window_3');
windows.push(back);
sandbox.jawnosWindowMinimizeOut(back);
sandbox.jawnosWindowRestoreIn(back);
check('a restored window cancels its hide', back.classes['jawnos_effect_out'] === undefined && back.classes['jawnos_effect_in'] === 1);
check('and is no longer leaving', sandbox.jawnosWindowEffectLeaving(back) === false);
back.fire('animationend');
advance(1000);
check('and never vanishes after it comes back', back.hidden === false);
check('so the desk was not adjusted by a stale hide', adjuster === 1);

// turning the switch off mid-minimize still finishes the hide
const falling = new Win('window_4');
windows.push(falling);
sandbox.jawnosWindowMinimizeOut(falling);
sandbox.jawnosWindowEffectsSet('off');
check('the switch finishes a hide already in flight', falling.hidden === true);
check('and its adjustment still lands', adjuster === 2);

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/windows/05_effects.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'the effects play, clean up and cancel a hide on restore');
}

# --- and the file parses ----------------------------------------------------
if ($node && -x $node) {
	my $out = `$node --check "$root/public/js/manager/windows/05_effects.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'node --check accepts the effects part');
}

done_testing();
