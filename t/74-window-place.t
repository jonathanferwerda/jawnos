# tests-for: lib/JawnOS/Manager/Part22.pm public/css/manager.css public/js/manager/windows.js public/js/manager/windows/02_fit.js public/js/manager/windows/03_stack.js public/js/manager/windows/05_tiling.js
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
my $tiling = read_file("$root/public/js/manager/windows/05_tiling.js");
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

# --- the rail and find-space mode ------------------------------------------
like($windows, qr/function windowIsTiled\(win\)/, 'one predicate says which windows the tile owns');
like($tiling, qr/function windowTileRailLayout\(windows, obstacles, view/, 'the tile has one place that hands out rail and focus places');
like($tiling, qr/tiled\.sort\(function/, 'the front window is the one shown in full');
like($tiling, qr/function windowTileClick\(win\)/, 'a press brings a window out of the rail');
like($tiling, qr/function windowTileRelease\(win\)/, 'pinning a rail bar restores its whole size');
like($tiling, qr/addClass\('tile_rail'\)/, 'unfocused windows become title-bar rows');
like($tiling, qr/removeClass\('tile_rail'\)/, 'the focused window leaves the rail');
like($tiling, qr/function windowTileRememberSize\(win\)/, 'a focused resize is what the rail restores');
like($css, qr/\.wind\.tile_rail \.window_contents/, 'a rail bar hides the window body');
like($css, qr/\.wind\.tile_focus \.top_navbar \{[^}]*bottom: 0/s, 'the title bar rides the foot of a stacked window');
like($tiling, qr/rowsPerColumn/, 'a full stack starts a second stack');
like($fit, qr/\$\(document\)\.on\('dblclick', '\.top_navbar'/, 'double-pressing a title bar toggles find-space mode');
unlike($fit, qr/win\.attr\('tile'/, 'a drag no longer takes a window out of the tile');
like($windows, qr/windowFindSpaceActive\(\)/, 'the open path lays find-space mode out');
like($stack, qr/windowTileRefresh\(\)/, 'closing a window leaves its rail row behind');

# --- the rail and its focus -------------------------------------------------
# The layout functions are played in a bare context: the rail is a pure list of
# places, the membership is read from the window attributes, and the switch is
# the only state.
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
	this.classNames = [];
}
El.prototype.attr = function (k, v) {
	if (v === undefined) { return this.attrs[k]; }
	this.attrs[k] = v;
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
El.prototype.is = function () { return true; };
El.prototype.width = function () { return parseFloat(this.style.width) || 0; };
El.prototype.height = function () { return parseFloat(this.style.height) || 0; };
El.prototype.addClass = function (name) { if (this.classNames.indexOf(name) < 0) { this.classNames.push(name); } return this; };
El.prototype.removeClass = function (name) { this.classNames = this.classNames.filter(function (c) { return c !== name; }); return this; };
El.prototype.hasClass = function (name) { return this.classNames.indexOf(name) >= 0; };

function J(els) {
	els = els || [];
	const j = { length: els.length, els: els };
	els.forEach(function (el, i) { j[i] = el; });
	j.each = function (fn) { els.forEach(function (el, i) { fn.call(el, i, el); }); return j; };
	j.on = function () { return j; };
	j.width = function () { return els[0] === windowStub ? windowStub.width : (els[0] && els[0].width ? els[0].width() : 0); };
	j.height = function () { return els[0] === windowStub ? windowStub.height : (els[0] && els[0].height ? els[0].height() : 0); };
	j.attr = function (k, v) { return els[0] ? els[0].attr(k, v) : undefined; };
	j.css = function (k, v) { return els[0] ? els[0].css(k, v) : j; };
	j.find = function (sel) { return els[0] ? J([els[0].find(sel)]) : J([]); };
	j.outerHeight = function () { return 0; };
	j.show = function () { return j; };
	j.val = function () { return j; };
	j.addClass = function (name) { els.forEach(function (el) { if (el.addClass) { el.addClass(name); } }); return j; };
	j.removeClass = function (name) { els.forEach(function (el) { if (el.removeClass) { el.removeClass(name); } }); return j; };
	j.hasClass = function (name) { return els.length > 0 && els[0].hasClass ? els[0].hasClass(name) : false; };
	return j;
}

const documentStub = { getElementById: function () { return null; } };

function $(arg) {
	if (arg && arg.els) { return J(arg.els); }
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
vm.runInContext(fs.readFileSync(process.argv[3], 'utf8'), ctx);

let failures = 0;
function eq(actual, want, label) {
	if (actual === want) { console.log('ok ' + label); }
	else { failures++; console.log('not ok ' + label + ': got ' + actual + ', want ' + want); }
}

// --- the tile's membership --------------------------------------------------
function member(attrs) { return new El('window_x', attrs); }
eq(ctx.windowIsTiled(member({ pre_dimensioned: '0' })), true, 'an unpinned window is in the tile');
eq(ctx.windowIsTiled(member({ pre_dimensioned: '1' })), false, 'a pinned window is not');
eq(ctx.windowIsTiled(member({ pre_dimensioned: '0', view: 'max' })), true, 'a maximized window stays in the tile');
eq(ctx.windowIsTiled(member({ pre_dimensioned: '0', tile: 'off' })), true, 'a dragged window stays in the tile');

// --- the rail and the focused frame -----------------------------------------
const view = { width: 1920, height: 1080 };
function specs(n) {
	const list = [];
	for (let i = 0; i < n; i++) { list.push({ width: 480, height: 640, bar: 40 }); }
	return list;
}
function overlaps(a, b) {
	return a.left < b.left + b.width && b.left < a.left + a.width &&
	       a.top < b.top + b.height && b.top < a.top + a.height;
}
function framesClear(rects, obstacles) {
	for (const rect of rects) {
		for (const obstacle of obstacles) {
			if (overlaps(rect, obstacle)) { return false; }
		}
	}
	return true;
}

const layout = ctx.windowTileRailLayout(specs(3), [], view, 0, 0, 320, false);
eq(layout.rail.length, 2, 'the two unfocused windows take rail rows');
eq(layout.focus.left, 332, 'the focused frame sits beside the rail');
eq(layout.focus.top, 0, 'at the top');
eq(layout.focus.width, 480, 'at the size it had before it joined the rail');
eq(layout.focus.height, 640, 'in full');
eq(layout.rail[0].left, 0, 'the rail starts at the left edge');
eq(layout.rail[0].top, 0, 'with the first title bar at the top');
eq(layout.rail[0].width, 320, 'the rail has its own width');
eq(layout.rail[0].height, 40, 'and each row is one title bar');
eq(layout.rail[1].top, 40, 'the next row is one bar lower');

const anchored = [{ left: 0, top: 0, width: 400, height: 1080 }];
const tiled_mode = ctx.windowTileRailLayout(specs(3), anchored, view, 0, 0, 320, false);
eq(tiled_mode.rail[0].left, 400, 'the rail steps around an anchor in tiling mode too');
const around = ctx.windowTileRailLayout(specs(3), anchored, view, 0, 0, 320, true);
eq(around.rail[0].left, 400, 'the rail starts right of the anchored window');
eq(around.focus.left, 732, 'the focused frame takes the space beyond it');
eq(framesClear([around.focus], anchored), true, 'the focused frame never covers the anchor');
eq(framesClear(around.rail, anchored), true, 'and neither does the rail');

const right_anchor = [{ left: 1520, top: 0, width: 400, height: 1080 }];
const cleared = ctx.windowTileRailLayout(specs(3), right_anchor, view, 0, 0, 320, true);
eq(cleared.focus.left, 332, 'a right-hand anchor stops the focused frame');
eq(framesClear([cleared.focus], right_anchor), true, 'and the frame stays clear of it');

const wide = ctx.windowTileRailLayout([{ width: 2000, height: 1400, bar: 40 }], [], view, 0, 0, 320, false);
eq(wide.focus.width, 1920, 'a frame wider than the desk is fitted');
eq(wide.focus.height, 1080, 'and so is one taller than it');
eq(ctx.windowTileRailWidth(view), 360, 'the rail has a readable width on a wide desk');
eq(ctx.windowTileRailWidth({ width: 800, height: 600 }), 240, 'and narrows with the desk');
eq(ctx.windowTileRailWidth({ width: 400, height: 600 }), 160, 'down to a readable minimum');

const short = { width: 1920, height: 200 };
const stacked = ctx.windowTileRailLayout(specs(7), [], short, 0, 0, 320, false);
eq(stacked.rail[5].left, 326, 'a full stack starts a second stack');
eq(stacked.rail[5].top, 0, 'at the top of the desk');
eq(stacked.focus.left, 658, 'the focused frame moves past both stacks');
const docked = ctx.windowTileRailLayout(specs(6), [], short, 0, 40, 320, false);
eq(docked.rail[4].left, 326, 'the dock and taskbar count as the foot of a stack');

const rail_win = new El('window_r', { pre_dimensioned: '0' }, { width: '120px', height: '40px' });
rail_win.classNames = ['tile_rail'];
rail_win.attrs.tile_w = '480';
rail_win.attrs.tile_h = '640';
ctx.windowTileRelease(rail_win);
eq(rail_win.style.width, 480, 'pinning a rail bar restores its whole width');
eq(rail_win.style.height, 640, 'and height');
eq(rail_win.hasClass('tile_rail'), false, 'and takes it out of the rail');

const pinned_focus = new El('window_pf', { pre_dimensioned: '0' }, { width: '700px', height: '500px' });
pinned_focus.classNames = ['tile_focus'];
ctx.windowTileRelease(pinned_focus);
eq(pinned_focus.hasClass('tile_focus'), false, 'pinning the focused window returns its bar to the top');
eq(parseFloat(pinned_focus.style.width), 700, 'and keeps the size it was showing');

const focused = new El('window_f', { pre_dimensioned: '0' }, { width: '600px', height: '500px' });
ctx.windowTileRememberSize(focused);
eq(focused.attr('tile_w'), 600, 'a focused frame remembers its width');
eq(focused.attr('tile_h'), 500, 'and height for the rail to restore');

// --- a press -----------------------------------------------------------------
let pressed = 0;
ctx.windowTileArrange = function () { pressed++; };
ctx.windowTileClick(new El('window_x', { pre_dimensioned: '0' }));
eq(pressed, 1, 'a press on a tiled window lays the rail out again');
ctx.windowTileClick(new El('window_y', { pre_dimensioned: '1' }));
eq(pressed, 1, 'a press on an anchored window does not');

// --- the switch --------------------------------------------------------------
let arranged = 0;
let tiled = 0;
ctx.windowFindSpaceArrange = function () { arranged++; };
ctx.windowTileArrange = function () { tiled++; };
eq(ctx.windowFindSpaceActive(), false, 'the desk starts in tiling mode');
eq(ctx.windowFindSpaceToggle(), true, 'a title-bar double-press switches to find-space');
eq(arranged, 1, 'and lays the rail around the anchors');
eq(ctx.windowFindSpaceToggle(), false, 'a second press returns to tiling');
eq(tiled, 1, 'and puts the rail back at the left edge');

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness_file" "$root/public/js/manager/windows.js" "$root/public/js/manager/windows/05_tiling.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'the rail and its switch play out');
}

done_testing();
