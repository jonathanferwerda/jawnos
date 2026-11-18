# tests-for: public/js/manager/windows/05_effects.js public/js/manager/windows/02_fit.js public/js/manager/windows/03_stack.js public/js/manager/windows.js public/js/manager/taskbar_edit.js public/css/manager.css templates/configure/misc_setting_list.html.ep templates/layouts/manager.html.ep public/js/manager/taskbar/01_inputs.js perl/help/topics_configure.pl
# covers:    the desk's window effects - a soft-sheet lean while dragging, a
#            stretch into the half or the whole screen, a bounce out and back
#            (into the window's own tile when it has one), a settle from the
#            top edge when the clothesline snaps a window, a kick on the pin,
#            and a close that fades, crumbles or bursts before the teardown -
#            with one per-device level (off, light, medium, maximum) setting
#            their amplitude.

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
like($index, qr/if \(open\) \{\s*\/\/[^\n]*\n(?:\s*\/\/[^\n]*\n)*\s*if \(typeof jawnosWindowEffect === 'function'\) \{ jawnosWindowEffect\(open, 'jiggle'\); \}[\s\S]{0,200}windowTiledPress\(open\)/,
	'an opener asked for an app already on the desk jiggles the window it raises');
unlike($index, qr/function windowTiledPress\(win\) \{[^}]*jawnosWindowEffect/s,
	'but a press on a window\'s own body only raises - no jiggle per click');
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

# --- into the control, and out of it ----------------------------------------
like($effects, qr/function jawnosWindowEffectControl\(win\)/,
	'the effects part finds the control a window answers for');
like($effects, qr/function jawnosWindowEffectControlShown\(node\)/,
	'and asks whether that control has a box on screen');
like($effects, qr/if \(cx < 0 \|\| cy < 0 \|\| cx > vw \|\| cy > vh\)/,
	'a control off the viewport - an autohide tile - is no control at all');
like($effects, qr/function jawnosWindowEffectAim\(win\)/,
	'the offset and the size are measured from the two rects');
like($effects, qr/setProperty\('--je-out-x'.*?setProperty\('--je-out-y'.*?setProperty\('--je-in-y'.*?setProperty\('--je-out-sx'.*?setProperty\('--je-out-sy'/s,
	'and written on the window for the keyframes');
like($effects, qr/function jawnosWindowEffectToControl\(win, name\)/,
	'one aimed one-shot measures before the class and marks the window after it');
like($effects, qr/jawnosWindowEffectToControl\(win, 'out'\)/, 'minimizing aims at the control');
like($effects, qr/jawnosWindowEffectToControl\(win, 'in'\)/, 'restoring comes out of it');
like($effects, qr/jawnos_effect_control/, 'the marker is cleaned up with the other one-shots');
like($css, qr/\@keyframes jawnos_window_into_control \{.*?var\(--je-out-x.*?var\(--je-out-sx.*?\}/s,
	'the out motion travels to the control and shrinks to its size');
like($css, qr/\@keyframes jawnos_window_from_control \{.*?var\(--je-out-x.*?var\(--je-in-y.*?var\(--je-out-sx/s,
	'the in motion starts at the control');
like($css, qr/\.wind\.jawnos_effect_in\.jawnos_effect_control \{[^}]*transform-origin: 50% 0%/s,
	'the in motion still hangs from the title bar');
like($css, qr/--je-travel:/, 'the level sets how far a window travels');
like($css, qr/--je-collapse:/, 'and how far it shrinks');
like($css, qr/body\[data-window-effects="light"\] \{[^}]*--je-travel: \.5[^}]*\}/s,
	'light travels half the way');
like($css, qr/body\[data-window-effects="maximum"\] \{[^}]*--je-travel: 1\.35[^}]*\}/s,
	'maximum overshoots the control');
like($css, qr/prefers-reduced-motion: reduce\) \{[\s\S]*\.wind\.jawnos_effect_in\.jawnos_effect_control[\s\S]*?animation-duration: 1ms/,
	'reduced motion still finishes the control motions at once');

# --- the close --------------------------------------------------------------
like($effects, qr/function jawnosWindowCloseEffect\(win, done\)/, 'one entry point for the close motion');
like($effects, qr/'close_fade' : \(\(level === 'maximum'\) \? 'close_burst' : 'close_crumble'\)/,
	'light fades, medium crumbles, maximum bursts');
like($effects, qr/function jawnosWindowCloseShards\(el, rect, level\)/, 'the pieces are cut from the window rect');
like($effects, qr/if \(name !== 'close_fade'[\s\S]*?jawnosWindowCloseShards\(el, rect, level\)/,
	'light fades with no pieces at all');
like($effects, qr/setTimeout\(finish, 300\)/, 'the bookkeeping waits at most 300 ms');
like($effects, qr/if \(this\.jawnosCloseEnd\) \{ this\.jawnosCloseEnd\(\); \}/,
	'turning the effects off finishes a close already playing');
foreach my $name (qw(close_fade close_crumble close_burst shard shard_burst flash)) {
	like($css, qr/\@keyframes jawnos_window_$name \{/, "manager.css defines the $name keyframes");
}
foreach my $class (qw(close_fade close_crumble close_burst)) {
	like($css, qr/\.wind\.jawnos_effect_$class \{ animation:/, "the $class class plays a keyframe");
}
# The close is half its old length, so a press answers at once at every level.
like($css, qr/\.wind\.jawnos_effect_close_fade \{ animation: jawnos_window_close_fade calc\(110ms/,
	'light fades in half the old time');
like($css, qr/\.wind\.jawnos_effect_close_crumble \{ animation: jawnos_window_close_crumble calc\(170ms/,
	'medium crumbles in half the old time');
like($css, qr/\.wind\.jawnos_effect_close_burst \{ animation: jawnos_window_close_burst calc\(170ms/,
	'maximum bursts in half the old time');
like($css, qr/animation: jawnos_window_shard calc\(160ms/, 'the pieces leave on the same shorter beat');
like($css, qr/animation: jawnos_window_flash calc\(90ms/, 'and so does the flash');
like($css, qr/\.jawnos_close_shards \{ pointer-events: none; \}/, 'the shard overlay cannot swallow a press');
like($css, qr/\.jawnos_close_shard \{[^}]*pointer-events: none/s, 'nor can a shard');
like($css, qr/\.jawnos_close_flash \{[^}]*pointer-events: none/s, 'nor the flash');
like($stack, qr/function windowCloseTearDown\(timestamp, win, done\) \{.*?\$\('#window_' \+ timestamp \)\.remove\(\);/s,
	'the removal lives in the teardown the close hands the motion');
like($stack, qr/function closeWindow\(timestamp, done\) \{.*?jawnosWindowCloseEffect\(win, tearDown\)[\s\S]{0,40}?tearDown\(\);\s*\}/s,
	'the close motion plays first, and effects off tears down at once');
like($stack, qr/if \(win\.length && win\[0\]\.jawnosCloseToken\)/, 'a second close waits for the one in flight');
like($stack, qr/windowTiledCloseSlot\(win\)/,
	'the pile reorients at the press, so the next close lands on the next window');
like($stack, qr/jawnosCloseWaits/, 'and its caller is called when the first finishes');

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
	this.style = { setProperty: function (k, v) { this[k] = v; } };
	this.offsetWidth = 100;
	this.parentNode = {};
	this.hidden = false;
	this.listeners = {};
	this.attrs = {};
	this.rect = { left: 0, top: 0, width: 0, height: 0 };
}
Win.prototype.getAttribute = function (k) { return this.attrs[k] === undefined ? null : this.attrs[k]; };
Win.prototype.getBoundingClientRect = function () { return this.rect; };
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
		css: function () { return '1000'; },
		hide: function () { el.hidden = true; return this; }
	};
}

const windows = [];
const controls = [];

// A tile or pin: the effects part asks it for its app and its box.
function Control(app, rect) {
	this.attrs = { app: app };
	this.rect = rect;
}
Control.prototype.getAttribute = function (k) { return this.attrs[k] === undefined ? null : this.attrs[k]; };
Control.prototype.getBoundingClientRect = function () { return this.rect; };

function rowSet(rows) {
	const j = { length: rows.length };
	rows.forEach((r, i) => { j[i] = r; });
	j.each = function (fn) { rows.forEach((r, i) => fn.call(r, i, r)); return j; };
	return j;
}

function $(sel) {
	if (sel && sel.jquery) { return sel; }
	if (sel instanceof Win) { return wrap(sel); }
	if (sel === '.wind') {
		const j = { length: windows.length };
		windows.forEach((w, i) => { j[i] = w; });
		j.each = function (fn) { windows.forEach((w, i) => fn.call(w, i, w)); return j; };
		return j;
	}
	if (sel === '.window_toggle') { return rowSet(controls); }
	if (sel === '.taskbar_pin') { return rowSet([]); }
	return { length: 0, each: function () { return this; } };
}

let adjuster = 0;
const bodyAttrs = {};
// The close builds its shard overlay on the body; a bare node is all it needs.
function FakeNode(tag) {
	this.tagName = tag;
	this.children = [];
	this.attrs = {};
	this.style = { setProperty: function (k, v) { this[k] = v; } };
	this.parentNode = null;
}
FakeNode.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
FakeNode.prototype.appendChild = function (n) { n.parentNode = this; this.children.push(n); return n; };
FakeNode.prototype.removeChild = function (n) {
	const i = this.children.indexOf(n);
	if (i >= 0) { this.children.splice(i, 1); }
	n.parentNode = null;
	return n;
};
const fakeBody = new FakeNode('body');
fakeBody.setAttribute = function (k, v) { bodyAttrs[k] = v; };
const sandbox = {
	$,
	setTimeout: fakeSetTimeout, clearTimeout: fakeClearTimeout,
	requestAnimationFrame: fakeRaf, cancelAnimationFrame: fakeCancelRaf,
	performance: { now: function () { return now; } },
	window: { matchMedia: function () { return { matches: false }; }, innerWidth: 1000, innerHeight: 800 },
	document: { body: fakeBody, createElement: function (tag) { return new FakeNode(tag); } },
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

// --- into the control, and out of it ---------------------------------------
// a 400x300 window at (100,100) and a 40x40 tile at (10,600)
sandbox.jawnosWindowEffectsSet('on');
const aimed = new Win('window_aim');
aimed.rect = { left: 100, top: 100, width: 400, height: 300 };
aimed.offsetWidth = 400;
aimed.attrs.app = 'gallery';
windows.push(aimed);
controls.push(new Control('gallery', { left: 10, top: 600, width: 40, height: 40 }));
check('a minimising window plays its out motion', sandbox.jawnosWindowMinimizeOut(aimed) === true);
check('and wears the control marker', aimed.classes['jawnos_effect_control'] === 1);
check('the travel to the tile is written on the window',
	aimed.style['--je-out-x'] === '-270.0px' && aimed.style['--je-out-y'] === '370.0px');
check('so is the size it shrinks to',
	aimed.style['--je-out-sx'] === '0.1000' && aimed.style['--je-out-sy'] === '0.1333');
check('and the title-bar offset the in motion starts from', aimed.style['--je-in-y'] === '500.0px');
aimed.fire('animationend');
sandbox.jawnosWindowRestoreIn(aimed);
check('a restored window comes out of the control',
	aimed.classes['jawnos_effect_in'] === 1 && aimed.classes['jawnos_effect_control'] === 1);
aimed.fire('animationend');

// an autohidden tile past the edge is no control: the centre bounce stays
const tucked = new Win('window_tucked');
tucked.rect = { left: 100, top: 100, width: 400, height: 300 };
tucked.offsetWidth = 400;
tucked.attrs.app = 'gallery';
windows.push(tucked);
controls.length = 0;
controls.push(new Control('gallery', { left: -200, top: 600, width: 40, height: 40 }));
sandbox.jawnosWindowMinimizeOut(tucked);
check('a tile off the viewport does not pull the window after it', tucked.classes['jawnos_effect_control'] === undefined);
check('but the centre bounce is still there', tucked.classes['jawnos_effect_out'] === 1);
tucked.fire('animationend');

// --- the close --------------------------------------------------------------
sandbox.jawnosWindowEffectsSet('medium');
function boxed(win) { win.rect = { left: 100, top: 100, width: 400, height: 300 }; win.offsetWidth = 400; }

const medium_close = new Win('window_close_medium');
boxed(medium_close);
windows.push(medium_close);
let medium_done = 0;
check('a medium close plays', sandbox.jawnosWindowCloseEffect(medium_close, function () { medium_done++; }) === true);
check('it crumbles', medium_close.classes['jawnos_effect_close_crumble'] === 1);
check('into a small handful of shards',
	fakeBody.children.length === 1 && fakeBody.children[0].className === 'jawnos_close_shards'
	&& fakeBody.children[0].children.length === 7);
medium_close.fire('animationend');
check('and the teardown runs when the motion ends', medium_done === 1);
check('the shards go with the window', fakeBody.children.length === 0);
check('and the class is given back', medium_close.classes['jawnos_effect_close_crumble'] === undefined);

sandbox.jawnosWindowEffectsSet('light');
const light_close = new Win('window_close_light');
boxed(light_close);
windows.push(light_close);
let light_done = 0;
sandbox.jawnosWindowCloseEffect(light_close, function () { light_done++; });
check('light only fades', light_close.classes['jawnos_effect_close_fade'] === 1);
check('with no shards', fakeBody.children.length === 0);
advance(500);
check('and the ceiling still tears it down', light_done === 1);

sandbox.jawnosWindowEffectsSet('maximum');
const burst_close = new Win('window_close_burst');
boxed(burst_close);
windows.push(burst_close);
let burst_done = 0;
sandbox.jawnosWindowCloseEffect(burst_close, function () { burst_done++; });
check('maximum bursts', burst_close.classes['jawnos_effect_close_burst'] === 1);
check('with every shard and a flash',
	fakeBody.children.length === 1 && fakeBody.children[0].children.length === 9);
check('the flash is one of them',
	fakeBody.children[0].children[8].className === 'jawnos_close_flash');
sandbox.jawnosWindowEffectsSet('off');
check('switching the effects off finishes a close in flight', burst_done === 1);
check('and clears its shards', fakeBody.children.length === 0);

sandbox.jawnosWindowEffectsSet('on');
sandbox.window.matchMedia = function () { return { matches: true }; };
check('reduced motion tears the window down at once',
	sandbox.jawnosWindowCloseEffect(burst_close, function () {}) === false);
sandbox.window.matchMedia = function () { return { matches: false }; };
check('a window with no box is torn down at once too',
	sandbox.jawnosWindowCloseEffect(new Win('window_hidden'), function () {}) === false);

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
