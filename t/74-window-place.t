# tests-for: lib/JawnOS/Manager/Part22.pm public/css/manager.css public/js/manager/windows.js public/js/manager/windows/01_storage.js public/js/manager/windows/02_fit.js public/js/manager/windows/03_stack.js public/js/manager/manager/09_app_back.js
# covers:    A window's place used to be saved automatically and invisibly, so a desk full of windows became a memory of wh...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

# A window's place used to be saved automatically and invisibly, so a desk full
# of windows became a memory of where they all were. The pin in the title bar is
# now the whole choice: pinned keeps its size and position, unpinned has none and
# cascades in. A place is saved with the screen it was saved on, so it can be
# rescaled onto a smaller one instead of hanging off the edge.

my $root = repo_root();
my $maker = read_file("$root/lib/JawnOS/Manager/Part22.pm");
my $fit = read_file("$root/public/js/manager/windows/02_fit.js");
my $stack = read_file("$root/public/js/manager/windows/03_stack.js");
my $storage = read_file("$root/public/js/manager/windows/01_storage.js");
my $back = read_file("$root/public/js/manager/manager/09_app_back.js");
my $windows = read_file("$root/public/js/manager/windows.js");
my $css = read_file("$root/public/css/manager.css");

# --- the setting the window reads -------------------------------------------
like($maker, qr/my \$window_settings = \[[^\]]*'place'/, 'the window reads a place setting');
like($maker, qr/my \$place_locked = \(\(\$settings->\{'place'\} \|\| ''\) eq 'lock'\)/,
	'a place is kept only when it is locked');
like($maker, qr/if \(\$place_locked && \$settings->\{'dimensions'\}/,
	'the saved geometry is only applied to a locked window');
like($maker, qr/my \$place_screen = '';/, 'the screen a place was saved on travels with it');
like($maker, qr{place_vw="' \. \$pv \. '" place_vh=}, 'the saved screen is on the window element');
like($maker, qr{pre_dimensioned="' \. \$pre_dimensioned \. '"}, 'an unpinned window is not pre-dimensioned, so it cascades');

# --- the pin ---------------------------------------------------------------
like($maker, qr{_place_button window_action place_button" status="}, 'every window wears a pin in its title bar');
like($maker, qr{\(\$place_locked \? 'on' : 'off'\)}, 'the pin shows whether this window keeps its place');
like($css, qr/\.place_button\[status="on"\]/, 'a kept place is visible without reading the hint');
like($fit, qr/\$\(document\)\.on\('click', '\.place_button', function/, 'the pin is the toggle');

# --- pinning and unpinning -------------------------------------------------
like($fit, qr/settingDeleter\(\{ 'app': app, 'setting': 'dimensions' \}\)/,
	'unpinning forgets the window\'s place');
like($fit, qr/settingSetter\(\{ 'app': app, 'setting': 'place', 'value': 'lock' \}\)/,
	'pinning keeps it');
like($fit, qr/settingSetter\(\{ 'app': app, 'setting': 'place', 'value': 'tile' \}\)/,
	'and unpinning lets it tile again');

# --- moving an unpinned window must not pin it -----------------------------
like($stack, qr/if \(typeof windowPlaceIsLocked === 'function' && windowPlaceIsLocked\(w\)\)/,
	'only a pinned window has its geometry written');
like($stack, qr/'vw': \$\(window\)\.width\(\), 'vh': \$\(window\)\.height\(\)/,
	'the screen is saved with the place');
like($stack, qr/if \(w\.attr\('place_restoring'\) == '1'\) \{ return; \}/,
	'a place being rescaled onto this screen is not saved again');

# --- the open path ---------------------------------------------------------
like($fit, qr/function windowPlaceRestore\(win\)/, 'a pinned place is restored');
like($fit, qr/var from_right = saved_w - \(left \+ width\);/, 'the edge a window sits nearest is the edge it keeps');
like($fit, qr/var scale = Math\.min\(now_w \/ saved_w, now_h \/ saved_h\);/, 'the place is scaled to this screen');
like($fit, qr/win\.attr\('place_restoring', '1'\)/, 'restoring does not ratchet the saved place down');
like($windows, qr/windowPlaceRestore\(\$\('#' \+ window_id\)\)/, 'the open path restores a pinned place');

# --- the tile is an ordered stack, not a page order -------------------------
# The tile steps a window out of its slot when one closes, and a reload restores
# the windows in whatever order their responses arrive: a slot kept on the window
# is what lets the stack act on the right windows either way.
like($stack, qr/windowTiledGapClose\(win\)/, 'closing a window steps the tiled windows below it up');
like($windows, qr/function windowTiledGapClose\(win\) \{\n\tif \(windowPhoneChecker\(\)\) \{ return; \}/,
	'the gap closer leaves a phone to its own pile');
like($windows, qr/slot \* windowTileAcrossStep/, 'a window is placed with the tile across step');
like($windows, qr/function windowTiledLeave\(win, float\)/, 'a window can leave the tile');
like($windows, qr/\$\(this\)\.attr\('tile', String\(s - 1\)\)/, 'a step up brings the slot number down with it');
like($windows, qr/function windowTiledJoinOrLeave\(win, at, home\)/, 'a drop either joins the stack or leaves it');
like($windows, qr/function windowTiledInsertSlot\(at, skip\)/, 'the dragged title bar names the slot');
like($windows, qr/function windowTiledInsertAt\(win, to\)/, 'a restored window inserts at its saved slot');
like($windows, qr/function windowTiledPreview\(win, at, home\)/, 'a drag draws the slot it would join');
like($windows, qr/windowTiledArea\(win, slot >= 0 \? home : null\)/, 'the stack ground uses the box the window left, not where it is');
like($fit, qr/windowTiledPreview\(win, mouse_position\(\), dragFromTile\)/, 'the drag shows the preview from where it was picked up');
like($fit, qr/windowTiledJoinOrLeave\(win, \{ x: d\.x, y: d\.y \}, dragFromTile\)/, 'a drag joins or leaves the stack where it is dropped');
like($css, qr/#window_tile_preview/, 'the preview slot has a look');
like($fit, qr/windowTiledLeave\(win, true\)/, 'a drag to an edge leaves the tile to the half snap');
like($fit, qr/windowTiledLeave\(win, false\)/, 'pinning takes it out of the tile without making it free');
like($storage, qr/tile: \$\(v\)\.attr\('tile'\)/, 'the tile slot is saved with the window');
like($storage, qr/free: \$\(v\)\.attr\('free'\)/, 'a dragged-out window is saved as free');
like($storage, qr/if \(v\.tile !== undefined \|\| v\.free == 1\)/, 'a restore hands its slot to the window that opens');

# --- a press holds its slot before the window arrives ---------------------
# Clicking down the clothesline fires several opens; their responses can land in
# any order. The slot is reserved at the press, so the stack keeps the order the
# presses were made in.
like($windows, qr/function windowTiledReserve\(timestamp, app\)/, 'a press reserves its slot');
like($windows, qr/windowTiledPending\[window_stamp\]/, 'the window claims the slot reserved for its stamp');
like($windows, qr/candidate\.app === window_app/, 'a bespoke opener that changes its stamp still claims the press');
like($windows, qr/if \(taken\) \{/, 'a filled slot steps its occupant down');
like($storage, qr/windowTiledReserve\(timestamp, i\)/, 'the app opener reserves the press slot');
like($back, qr/windowTiledReserve\(timestamp, app\)/, 'the clothesline grabber reserves the press slot');
like($back, qr/windowTiledRelease\(timestamp\)/, 'a grabber that never answers frees its slot');

# --- the tile does not count an anchored window ----------------------------
# The live tiler is exercised in a bare context: windows.js needs jQuery for
# two document handlers at load, and nothing else to reach windowReorganizer.
# An anchored window keeps its place, so the next unpinned window must take the
# slot it would have taken anyway rather than step around the pin.
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to play the tiling rules', 1 unless $node && -x $node;

	my ($fh, $harness_file) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
'use strict';

const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');

function numeral(value) {
	const n = parseFloat(value);
	return {
		format: function () { return String(isNaN(n) ? 0 : n); },
		value: function () { return isNaN(n) ? 0 : n; }
	};
}

const windowStub = { width: 1920, height: 1080 };
let dom = [];

function El(id, attrs, style) {
	this.id = id;
	this.attrs = Object.assign({ id: id, app: id }, attrs || {});
	this.style = Object.assign({ left: '0px', top: '0px', width: '400px', height: '300px' }, style || {});
	this.classes = ['wind'];
}
El.prototype.attr = function (k, v) {
	if (v === undefined) { return this.attrs[k]; }
	this.attrs[k] = v;
	return this;
};
El.prototype.removeAttr = function (k) {
	delete this.attrs[k];
	return this;
};
El.prototype.css = function (k, v) {
	if (typeof k === 'object') { Object.assign(this.style, k); return this; }
	if (v === undefined) { return this.style[k] === undefined ? '' : String(this.style[k]); }
	this.style[k] = v;
	return this;
};
El.prototype.find = function (sel) {
	if (sel === '.top_navbar') {
		return { outerHeight: function () { return 40; }, css: function () { return '0px'; } };
	}
	return { val: function () { return this; }, css: function () { return '0px'; }, outerHeight: function () { return 0; } };
};
El.prototype.show = function () { return this; };

function J(els) {
	els = els || [];
	const j = { length: els.length, __jq: 1 };
	els.forEach(function (el, i) { j[i] = el; });
	j.each = function (fn) { els.forEach(function (el, i) { fn.call(el, i, el); }); return j; };
	j.on = function () { return j; };
	j.width = function () { return els[0] === windowStub ? windowStub.width : (els[0] && els[0].width ? els[0].width() : 0); };
	j.height = function () { return els[0] === windowStub ? windowStub.height : 0; };
	j.attr = function (k, v) { return els[0] ? els[0].attr(k, v) : undefined; };
	j.removeAttr = function (k) { els.forEach(function (el) { if (el.removeAttr) { el.removeAttr(k); } }); return j; };
	j.css = function (k, v) { return els[0] ? els[0].css(k, v) : j; };
	j.find = function (sel) { return els[0] ? J([els[0].find(sel)]) : J([]); };
	j.outerHeight = function () { return 0; };
	j.show = function () { return j; };
	j.val = function () { return j; };
	return j;
}

const documentStub = { getElementById: function () { return null; } };

function $(arg) {
	if (arg && arg.__jq) { return arg; }
	if (arg === windowStub) { return J([windowStub]); }
	if (arg === documentStub) { return J([documentStub]); }
	if (typeof arg === 'string') {
		if (arg.charAt(0) === '#') {
			const id = arg.slice(1);
			return J(dom.filter(function (el) { return el.id === id; }));
		}
		return J(dom.slice());
	}
	if (arg instanceof El) { return J([arg]); }
	return J([]);
}
$.each = function (list, fn) { (list || []).forEach(function (v, i) { fn.call(v, i, v); }); };

const ctx = {
	$: $,
	jQuery: $,
	document: documentStub,
	window: windowStub,
	numeral: numeral,
	console: console,
	JSON: JSON,
	Math: Math,
	Date: Date,
	reservedSpots: { header: 0 },
	clothesLinePos: { exists: 0 },
	clothesLineHeight: 0,
	windowPhoneChecker: function () { return false; },
	windowFit: function () {},
	topLevelNow: function () {},
	taskbarDisplayer: function () {},
	jawnosAppFieldGet: function () { return ''; },
	setTimeout: function () {},
	clearTimeout: function () {},
	setInterval: function () { return 0; },
	clearInterval: function () {}
};
vm.createContext(ctx);
vm.runInContext(source, ctx);

let failures = 0;
function eq(actual, want, label) {
	if (actual === want) { console.log('ok ' + label); }
	else { failures++; console.log('not ok ' + label + ': got ' + actual + ', want ' + want); }
}

function open(windows, id) {
	ctx.windowTiledRestore = {};
	var next = 0;
	dom = windows.map(function (w) {
		var el = new El(w.id, { pre_dimensioned: w.pinned ? '1' : '0' });
		if (!w.pinned) { el.attr('tile', String(next)); next++; }
		return el;
	});
	const fresh = new El(id, { pre_dimensioned: '0' });
	dom.push(fresh);
	ctx.winLine = 0;
	ctx.fullXCount = 0;
	ctx.fullYCount = 0;
	ctx.windowReorganizer(id);
	return { fresh: fresh, windows: dom };
}

let r = open([{ id: 'window_a', pinned: true }], 'window_c');
eq(r.fresh.style.left, 0, 'an anchored window does not push the first tiled window across');
eq(r.fresh.style.top, 0, 'nor down');
eq(r.windows[0].style.left, '0px', 'the anchored window keeps its place');

let with_pin = open([{ id: 'window_a', pinned: true }, { id: 'window_b', pinned: false }], 'window_c');
let without_pin = open([{ id: 'window_b', pinned: false }], 'window_c');
eq(with_pin.fresh.style.left, without_pin.fresh.style.left, 'a pin beside a tiled window does not move the next slot across');
eq(with_pin.fresh.style.top, without_pin.fresh.style.top, 'nor down');

let three_with = open([{ id: 'window_a', pinned: true }, { id: 'window_b', pinned: false }, { id: 'window_c', pinned: false }], 'window_d');
eq(three_with.fresh.style.left, 100, 'the third tiled window still steps twice');
eq(three_with.fresh.style.top, 80, 'down two bars');

// Opening a row of windows: each new one joins at the end of the stack, one bar
// down and one step across, so the fourth never lands on the third.
ctx.windowTiledRestore = {};
dom = [];
for (let n = 0; n < 7; n++) {
	const fresh = new El('window_' + n, { pre_dimensioned: '0' });
	dom.push(fresh);
	ctx.windowReorganizer('window_' + n);
	eq(fresh.attr('tile'), String(n), 'open ' + (n + 1) + ' takes the next slot');
	eq(fresh.style.top, 40 * n, 'open ' + (n + 1) + ' steps down ' + n);
	eq(fresh.style.left, 50 * n, 'open ' + (n + 1) + ' steps across ' + n);
}

// Clicking down the clothesline fires the opens faster than their responses:
// the second press's window can land first. The press reserves its slot, so the
// first press still settles above it and nothing is covered.
ctx.windowTiledRestore = {};
ctx.windowTiledPending = {};
dom = [];
ctx.windowTiledReserve('101', 'app_a');
ctx.windowTiledReserve('102', 'app_b');
const second = new El('window_102', { pre_dimensioned: '0' });
dom.push(second);
ctx.windowReorganizer('window_102');
eq(second.attr('tile'), '1', 'the second press answers into its reserved slot');
const first = new El('window_101', { pre_dimensioned: '0' });
dom.push(first);
ctx.windowReorganizer('window_101');
eq(first.attr('tile'), '0', 'the first press takes the slot it reserved');
eq(second.attr('tile'), '1', 'and does not push the second down a place');
eq(first.style.top, 0, 'the first press sits at the head of the cascade');
eq(second.style.top, 40, 'and the second one step below it');
eq(Object.keys(ctx.windowTiledPending).length, 0, 'both reservations are claimed');

// a bespoke opener (Help) renders a window with a timestamp of its own; the
// reservation still names the app, so the window claims it by app
ctx.windowTiledPending = {};
dom = [];
ctx.windowTiledReserve('201', 'help');
const help_win = new El('window_999', { pre_dimensioned: '0', app: 'help' });
dom.push(help_win);
ctx.windowReorganizer('window_999');
eq(help_win.attr('tile'), '0', 'a bespoke opener claims the press by app when the stamp differs');
eq(Object.keys(ctx.windowTiledPending).length, 0, 'the press is spent after the bespoke window lands');

// A desk built by hand: tiled windows get their slot the way the app gives it,
// a pinned or dragged-out window has none.
function desk(specs) {
	ctx.windowTiledRestore = {};
	var next = 0;
	dom = specs.map(function (w) {
		var el = new El(w.id, { pre_dimensioned: w.pinned ? '1' : '0' });
		el.style.left = (w.left === undefined ? 0 : w.left) + 'px';
		el.style.top = (w.top === undefined ? 0 : w.top) + 'px';
		if (w.pinned) {
			// a pinned window has a place of its own, not a slot
		}
		else if (w.free) {
			el.attr('free', '1');
		}
		else {
			var slot = (w.tile === undefined) ? next : w.tile;
			el.attr('tile', String(slot));
			next = slot + 1;
		}
		return el;
	});
	return dom;
}

// closing a tiled window closes the step it leaves: the windows below it in the
// stack step back up into its slot, one bar and one across-step, and everything
// above the closed window stays where it was.
let closed = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 },
	{ id: 'window_d', top: 120, left: 150 }
]);
ctx.windowTiledGapClose('#window_c');
eq(closed[0].style.top, '0px', 'a window above the closed one stays put');
eq(closed[1].style.left, '50px', 'and keeps its step across');
eq(closed[3].style.top, 80, 'the window below steps up one bar');
eq(closed[3].style.left, 100, 'and across one step');
eq(closed[3].attr('tile'), '2', 'and its slot comes down with it');

let pinned_closed = desk([
	{ id: 'window_a', pinned: true, top: 20, left: 20 },
	{ id: 'window_b', top: 60, left: 60 },
	{ id: 'window_c', top: 100, left: 100 }
]);
ctx.windowTiledGapClose('#window_a');
eq(pinned_closed[1].style.top, '60px', 'closing a pinned window leaves the tile alone');
eq(pinned_closed[2].style.top, '100px', 'so nothing steps up');

let pinned_below = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', pinned: true, top: 30, left: 300 },
	{ id: 'window_c', top: 80, left: 100 }
]);
ctx.windowTiledGapClose('#window_a');
eq(pinned_below[1].style.top, '30px', 'a pinned window below the closed one keeps its place');
eq(pinned_below[2].style.top, 40, 'an unpinned window after it steps up');

// a window dragged out of the stack is free: the tile steps it neither way
let dragged_out = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 30, left: 300, free: true },
	{ id: 'window_c', top: 40, left: 50 }
]);
ctx.windowTiledGapClose('#window_a');
eq(dragged_out[1].style.top, '30px', 'a dragged-out window is not stepped by a close');
eq(dragged_out[2].style.top, 0, 'the tiled window after it closes the slot');

let free_closed = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 30, left: 300, free: true },
	{ id: 'window_c', top: 40, left: 50 }
]);
ctx.windowTiledGapClose('#window_b');
eq(free_closed[2].style.top, '40px', 'closing a dragged-out window leaves the tile alone');

// a drag takes the window out of the tile and the ones below close the slot
let dragged = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
ctx.windowTiledLeave('#window_b', true);
eq(dragged[1].attr('tile'), undefined, 'a dragged window leaves the tile');
eq(dragged[1].attr('free'), '1', 'and floats as a free window');
eq(dragged[0].style.top, '0px', 'the window above it stays put');
eq(dragged[2].style.top, 40, 'the window below closes the slot it held');
eq(dragged[2].attr('tile'), '1', 'and its slot comes down');

// a restore brings the slot it held before the reload, so the stack keeps its
// order even when the windows arrive in another order
let arriving = desk([
	{ id: 'window_a', tile: 0, top: 0, left: 0 },
	{ id: 'window_d', tile: 2, top: 80, left: 100 }
]);
let late = new El('window_c', { pre_dimensioned: '0' });
dom.push(late);
ctx.windowTiledRestore = { window_c: { tile: '1' } };
ctx.windowReorganizer('window_c');
eq(late.attr('tile'), '1', 'a restored window keeps the slot it held before the reload');
eq(late.style.top, 40, 'and lands in that step of the cascade');
eq(arriving[1].attr('tile'), '2', 'the window below keeps its slot - the hole was the place');
ctx.windowTiledSettle();
eq(arriving[1].attr('tile'), '2', 'and the settle leaves it there');
eq(arriving[1].style.top, 80, 'with the window back on its own step');

// A drag dropped off the stack leaves the tile, and the stack closes behind it.
// The window's present box is not the stack ground: dragging away is measured
// against the other windows and the box this one left, not where it is now.
let dropped_out = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 }
]);
dropped_out[1].style.left = '900px';
dropped_out[1].style.top = '900px';
ctx.windowTiledJoinOrLeave('#window_b', { x: 1000, y: 900 }, { left: 50, top: 40, width: 400, height: 300 });
eq(dropped_out[1].attr('tile'), undefined, 'a window dropped off the stack leaves the tile');
eq(dropped_out[1].attr('free'), '1', 'and floats free');
eq(dropped_out[0].attr('tile'), '0', 'the window above stays in its slot');

// a free window dropped on the stack joins at the bar's place
let joined = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 }
]);
let floater = new El('window_c', { pre_dimensioned: '0' });
floater.attr('free', '1');
floater.style.left = '100px';
floater.style.top = '27px';
dom.push(floater);
ctx.windowTiledJoinOrLeave('#window_c', { x: 100, y: 45 }, null);
eq(floater.attr('tile'), '1', 'a free window dropped on the stack joins at the bar slot');
eq(floater.attr('free'), undefined, 'and is no longer free');
eq(floater.style.top, 40, 'and sits in that step of the cascade');
eq(joined[1].attr('tile'), '2', 'the window below it steps down a slot');
eq(joined[1].style.top, 80, 'and down a step');

// a window already in the stack can be dragged to another place in it
let dropped_low = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 },
	{ id: 'window_d', top: 120, left: 150 }
]);
dropped_low[1].style.left = '200px';
dropped_low[1].style.top = '130px';
ctx.windowTiledJoinOrLeave('#window_b', { x: 250, y: 130 }, { left: 50, top: 40, width: 400, height: 300 });
eq(dropped_low[1].attr('tile'), '3', 'a stacked window dropped at the foot takes the last slot');
eq(dropped_low[1].style.top, 120, 'and the foot of the cascade');
eq(dropped_low[2].attr('tile'), '1', 'the window it passed steps up a slot');
eq(dropped_low[2].style.top, 40, 'and up a step');
eq(dropped_low[3].attr('tile'), '2', 'the next one too');

let dropped_high = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 },
	{ id: 'window_d', top: 120, left: 150 }
]);
dropped_high[3].style.left = '150px';
dropped_high[3].style.top = '0px';
ctx.windowTiledJoinOrLeave('#window_d', { x: 200, y: 0 }, { left: 150, top: 120, width: 400, height: 300 });
eq(dropped_high[3].attr('tile'), '0', 'a stacked window dropped at the head takes the first slot');
eq(dropped_high[3].style.top, 0, 'and the head of the cascade');
eq(dropped_high[0].attr('tile'), '1', 'the first window steps down a slot');
eq(dropped_high[0].style.top, 40, 'and down a step');

// the title bar's place, not the finger on it, decides the slot: a grip 30px
// down the bar still joins at the head when the bar itself is at the head
let grip = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
grip[2].style.left = '200px';
grip[2].style.top = '0px';
ctx.windowTiledJoinOrLeave('#window_c', { x: 250, y: 30 }, { left: 100, top: 80, width: 400, height: 300 });
eq(grip[2].attr('tile'), '0', 'the bar, not the finger on it, picks the slot');
eq(grip[0].attr('tile'), '1', 'and the window it passed steps down');

// a lone tiled window put back down over its own place keeps its slot
let lone = desk([{ id: 'window_a', top: 100, left: 100 }]);
ctx.windowTiledJoinOrLeave('#window_a', { x: 200, y: 150 }, { left: 0, top: 0, width: 400, height: 300 });
eq(lone[0].attr('tile'), '0', 'a lone tiled window dropped on itself stays in the tile');
eq(lone[0].attr('free'), undefined, 'and is not made free');

// a restored window inserts at its saved slot, and a window already there steps
// down - so an in-flight restore never leaves two windows in one slot
let restore_race = desk([
	{ id: 'window_a', tile: 0, top: 0, left: 0 },
	{ id: 'window_b', tile: 1, top: 40, left: 50 }
]);
let came_late = new El('window_c', { pre_dimensioned: '0' });
dom.push(came_late);
ctx.windowTiledRestore = { window_c: { tile: '1' } };
ctx.windowReorganizer('window_c');
eq(came_late.attr('tile'), '1', 'a restored window takes the slot it saved');
eq(came_late.style.top, 40, 'and lands in that step of the cascade');
eq(restore_race[1].attr('tile'), '2', 'the window already in that slot steps down');
eq(restore_race[1].style.top, 80, 'and down a step');

// and once the restore settles, the slots have no holes left in them
ctx.windowTiledSettle();
eq(restore_race[0].attr('tile'), '0', 'the settle leaves the head alone');
eq(came_late.attr('tile'), '1', 'and the restored window on its slot');
eq(restore_race[1].attr('tile'), '2', 'and the stepped window where it landed');

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness_file" "$root/public/js/manager/windows.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'an anchored window does not take a slot in the tile');
}

done_testing();
