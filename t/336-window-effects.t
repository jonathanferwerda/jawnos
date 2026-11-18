# tests-for: public/js/manager/windows/05_effects.js public/js/manager/windows/02_fit.js public/js/manager/windows/03_stack.js public/js/manager/windows.js public/js/manager/taskbar_edit.js public/css/manager.css templates/configure/misc_setting_list.html.ep templates/layouts/manager.html.ep public/js/manager/taskbar/01_inputs.js perl/help/topics_configure.pl
# covers:    the desk's window effects - a soft-sheet lean while dragging, a
#            stretch into the half or the whole screen, a bounce out and back,
#            a settle from the top edge when the clothesline snaps a window, and
#            a kick on the pin - with one per-device level (off, light, medium,
#            maximum) setting their amplitude.

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

# --- one level, visible in Misc ---------------------------------------------
like($misc, qr/setting="window_effects" device="<%= \$dev %>"/,
	'Misc carries a Window Effects control in the device section');
like($misc, qr/value="off".*?value="light".*?value="medium".*?value="maximum"/s,
	'the four levels are offered in order');
unlike($misc, qr/\[ 'window_effects',/, 'the old Bars on/off entry is gone');
like($layout, qr/window_effects: '<%= \$window_effects_level %>'/,
	'the manager seeds the normalised level for this device');
like($layout, qr/data-window-effects="<%= \$window_effects_level %>"/,
	'and stamps it on the body for the CSS amplitudes');
like($inputs, qr/setting == 'window_effects'.*?jawnosWindowEffectsSet/,
	'the panel control reaches the live desk');
like($help, qr/Light, Medium or Maximum/, 'the Configure help names the levels');
like($help, qr/Medium is the default/, 'and the default');

# --- the manifest names the effects part ------------------------------------
like($index, qr/05_effects\.js/, 'windows.js names its effects part');
like($effects, qr/function jawnosWindowEffectsLevel\(\)/, 'one reader for the level');
like($effects, qr/function jawnosWindowEffectScale\(\)/, 'one amplitude reader');
like($effects, qr/function jawnosWindowEffectsSet\(value\)/, 'and one live setter');
like($effects, qr/raw === 'off'/, 'only off stops the effects');
like($effects, qr/function jawnosWindowMotionAllowed\(\)/, 'the physics asks reduced-motion first');
like($effects, qr/jawnosWindowEmergeCancel\(el\)/, 'a one-shot motion cancels an emerge sheet too');

# --- the motions are transform-only classes ---------------------------------
foreach my $name (qw(stretch bounce_in bounce_out lock snap jiggle)) {
	like($css, qr/\@keyframes jawnos_window_$name \{/, "manager.css defines $name");
}
foreach my $class (qw(stretch in out lock snap jiggle)) {
	like($css, qr/\.wind\.jawnos_effect_$class \{ animation:/, "the $class class plays a keyframe");
}
like($css, qr/\.wind\.jawnos_wobbling \{ transform-origin: 50% 0%/, 'the drag hangs from the title bar');
like($css, qr/body\[data-window-effects="light"\]/, 'the light level has its own amplitudes');
like($css, qr/body\[data-window-effects="maximum"\]/, 'so does maximum');
like($css, qr/var\(--je-(?:wobble|stretch|bounce|time)\)/, 'the keyframes read the level variables');
like($css, qr/\.wind\.jawnos_effect_snap \{[^}]*transform-origin: 50% 0%/s,
	'the top snap hangs from the window\'s top edge');
like($css, qr/\@keyframes jawnos_window_snap \{.*?var\(--je-bounce\)/s,
	'and its settle scales with the level');
like($css, qr/\.wind\.jawnos_effect_snap \{ animation: jawnos_window_snap calc\([^)]*var\(--je-time\)/,
	'and its time comes from the level too');
like($css, qr/prefers-reduced-motion: reduce/, 'reduced motion shortens every one-shot');
unlike($css, qr/\.wind\.jawnos_effect_[a-z_]+ \{[^}]*\b(left|top|width|height):/s,
	'no effect writes layout geometry');

# --- every action the person asked for is hooked ----------------------------
like($fit, qr/function windowMaximizer.*?jawnosWindowEffect\(win, 'stretch'\)/s, 'maximize stretches');
like($fit, qr/function windowHalfski.*?jawnosWindowEffect\(win, 'stretch'\)/s, 'a half snap stretches');
like($index, qr/function windowTiledPress\(win\).*?jawnosWindowEffect\(win, 'jiggle'\)/s,
	'an already-open press jiggles the window it raises');
like($css, qr/\.wind\.jawnos_effect_jiggle \{[^}]*animation: jawnos_window_jiggle calc\([^)]*var\(--je-time\)/s,
	'and the jiggle is a level-timed one-shot');
like($effects, qr/jawnos_effect_jiggle/, 'the jiggle is cleaned up with the other one-shots');
like($fit, qr/function windowRestore\(.*?jawnosWindowEffect\(win, 'in'\)/s, 'restore bounces in');
like($fit, qr/function windowMinimizer.*?jawnosWindowMinimizeOut\(win\)/s, 'minimize bounces out');
like($fit, qr/function windowRestorer.*?jawnosWindowRestoreIn\(win\)/s, 'the tile toggle bounces in');
like($fit, qr/function windowRestorer.*?jawnosWindowMinimizeOut\(win\)/s, 'and bounces out on its own hide');
like($fit, qr/jawnosWindowWobbleStart\(win\)/, 'a drag starts the lean');
like($fit, qr/jawnosWindowWobbleMove\(win, p\.pageX, p\.pageY\)/, 'each drag event feeds the spring');
like($fit, qr/jawnosWindowWobbleStop\(win\)/, 'and the drop lets it settle');
like($fit, qr/else if \(d\.y < windowTopLimit\(\) \+ 10\).*?var was = parseFloat\(pd\.css\('top'\)\);.*?pd\.css\(\{ 'top': ok \}\);.*?if \(Math\.abs\(was - ok\) > 0\.5 && typeof jawnosWindowEffect == 'function'\) \{\s*jawnosWindowEffect\(pd, 'snap'\);\s*\}/s,
	'a drop above the clothesline settles only when the top actually snapped');
like($effects, qr/jawnos_effect_snap/, 'the top snap is cleaned up with the other one-shots');
like($fit, qr/jawnosWindowEffect\(win, 'lock'\)/, 'the pin gives the window a kick');
like($index, qr/jawnosWindowRestoreIn\(tw\)/, 'a named window shown from the bar bounces in');
like($index, qr/jawnosWindowMinimizeOut\(tw\)/, 'and one hidden from the bar bounces out');
like($index, qr/jawnosWindowEffectLeaving\(tw\)/, 'a tile pressed mid-out brings the window back');
like($fit, qr/jawnosWindowEffectLeaving\(win\)/, 'the tile toggle does the same');
like($edit_bar, qr/jawnosWindowEffectLeaving\(win\)/, 'the editable bar does too');
like($fit, qr/function windowMinimizer.*?jawnosWindowRestoreIn\(win\)/s, 'the desktop bar widget bounces a window back in');
like($stack, qr/function topWindow.*?jawnosWindowEffectLeaving\(v\)/s, 'a leaving window is no longer the front');

# --- the levels, the physics and the hide/restore race ---------------------
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
let rafSeq = 0;
const timers = {};
const rafs = {};
function fakeSetTimeout(fn, ms) { const id = ++seq; timers[id] = { fn, at: now + (ms || 0) }; return id; }
function fakeClearTimeout(id) { delete timers[id]; }
function fakeRaf(fn) { const id = ++rafSeq; rafs[id] = fn; return id; }
function fakeCancelRaf(id) { delete rafs[id]; }
function advance(ms) {
	now += ms;
	let due;
	do {
		due = Object.keys(timers).filter((id) => timers[id].at <= now);
		due.forEach((id) => { const t = timers[id]; delete timers[id]; t.fn(); });
	} while (due.length);
}
function pump(frames) {
	for (let i = 0; i < frames; i++) {
		const ids = Object.keys(rafs);
		if (!ids.length) { break; }
		now += 16;
		ids.forEach((id) => { const fn = rafs[id]; delete rafs[id]; fn(now); });
	}
}

function Win(id) {
	this.id = id;
	this.classes = {};
	this.style = {};
	this.offsetWidth = 100;
	this.parentNode = {};
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
const bodyAttrs = {};
const sandbox = {
	$,
	setTimeout: fakeSetTimeout, clearTimeout: fakeClearTimeout,
	requestAnimationFrame: fakeRaf, cancelAnimationFrame: fakeCancelRaf,
	performance: { now: function () { return now; } },
	window: { matchMedia: function () { return { matches: false }; } },
	document: { body: { setAttribute: function (k, v) { bodyAttrs[k] = v; } } },
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

check('the old on value reads as medium', sandbox.jawnosWindowEffectsLevel() === 'medium');
check('and is on', sandbox.jawnosWindowEffectsOn() === true);
check('the seed stamps the body', bodyAttrs['data-window-effects'] === 'medium');

sandbox.jawnosWindowEffectsSet('light');
check('light is a level', sandbox.jawnosWindowEffectsLevel() === 'light');
check('light halves the amplitude', sandbox.jawnosWindowEffectScale() === 0.5);
check('and reaches the body', bodyAttrs['data-window-effects'] === 'light');

sandbox.jawnosWindowEffectsSet('maximum');
check('maximum is a level', sandbox.jawnosWindowEffectsLevel() === 'maximum');
check('maximum raises the amplitude', sandbox.jawnosWindowEffectScale() === 1.9);
check('and reaches the body', bodyAttrs['data-window-effects'] === 'maximum');

// the switch reaches the live desk and stops what is running
sandbox.jawnosWindowEffect(w, 'stretch');
check('the effect adds its class', w.classes['jawnos_effect_stretch'] === 1);
sandbox.jawnosWindowEffectsSet('off');
check('off stops the effects', sandbox.jawnosWindowEffectsOn() === false);
check('turning off clears the classes', !w.classes['jawnos_effect_stretch']);
check('an off desk does not animate', sandbox.jawnosWindowMinimizeOut(w) === false && !w.classes['jawnos_effect_out']);
sandbox.jawnosWindowEffectsSet('on');
check('the old on value comes back as medium', sandbox.jawnosWindowEffectsLevel() === 'medium');

// one effect cleans itself up after its motion
sandbox.jawnosWindowEffect(w, 'stretch');
advance(1000);
check('the effect class does not outlive the motion', !w.classes['jawnos_effect_stretch']);

// the clothesline snap is a one-shot like the rest, and the level owns it
sandbox.jawnosWindowEffect(w, 'snap');
check('the top snap adds its class', w.classes['jawnos_effect_snap'] === 1);
advance(1000);
check('and does not outlive its motion', !w.classes['jawnos_effect_snap']);
sandbox.jawnosWindowEffect(w, 'snap');
sandbox.jawnosWindowEffectsSet('off');
check('turning the level off clears the top snap', !w.classes['jawnos_effect_snap']);
sandbox.jawnosWindowEffectsSet('on');

// the lean is a spring: a rightward move shears the foot back, and the drop settles
const phys = new Win('window_phys');
windows.push(phys);
sandbox.jawnosWindowWobbleStart(phys);
check('the drag adds the hanging class', phys.classes['jawnos_wobbling'] === 1);
sandbox.jawnosWindowWobbleMove(phys, 10, 10);
sandbox.jawnosWindowWobbleMove(phys, 80, 10);
check('moving right sets a negative shear', phys.jawnosWobble.targetShear < 0);
pump(3);
check('the frame writes a shear', /skewX\(-/.test(phys.style.transform));
sandbox.jawnosWindowWobbleStop(phys);
pump(240);
check('the window settles and clears its transform', phys.style.transform === '');
check('and gives the class back', !phys.classes['jawnos_wobbling']);
check('and the state is gone', !phys.jawnosWobble);

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

// turning the level off mid-minimize still finishes the hide
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
	is($rc, 0, 'the levels, the physics and the hide/restore race all play');
}

# --- and the file parses ----------------------------------------------------
if ($node && -x $node) {
	my $out = `$node --check "$root/public/js/manager/windows/05_effects.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'node --check accepts the effects part');
}

done_testing();
