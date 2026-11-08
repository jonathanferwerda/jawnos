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

# --- the tile and find-space mode ------------------------------------------
like($windows, qr/function windowIsTiled\(win\)/, 'one predicate says which windows the tile owns');
like($tiling, qr/function windowFindSpacePositions\(windows, obstacles, view/, 'find-space has one place that hands out slots');
like($fit, qr/\$\(document\)\.on\('dblclick', '\.top_navbar'/, 'double-pressing a title bar toggles find-space mode');
like($fit, qr/win\.attr\('tile', 'off'\)/, 'a dragged window leaves the tile');
like($fit, qr/ui\.originalPosition/, 'a click that started a drag and ended where it began is not a move');
like($windows, qr/windowFindSpaceActive\(\)/, 'the open path lays find-space mode out');
like($stack, qr/windowFindSpaceRefresh\(\)/, 'closing a window closes the gap it leaves');

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

function J(els) {
	els = els || [];
	const j = { length: els.length };
	els.forEach(function (el, i) { j[i] = el; });
	j.each = function (fn) { els.forEach(function (el, i) { fn.call(el, i, el); }); return j; };
	j.on = function () { return j; };
	j.width = function () { return els[0] === windowStub ? windowStub.width : (els[0] && els[0].width ? els[0].width() : 0); };
	j.height = function () { return els[0] === windowStub ? windowStub.height : 0; };
	j.attr = function (k, v) { return els[0] ? els[0].attr(k, v) : undefined; };
	j.css = function (k, v) { return els[0] ? els[0].css(k, v) : j; };
	j.find = function (sel) { return els[0] ? J([els[0].find(sel)]) : J([]); };
	j.outerHeight = function () { return 0; };
	j.show = function () { return j; };
	j.val = function () { return j; };
	return j;
}

const documentStub = { getElementById: function () { return null; } };

function $(arg) {
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

function open(windows, id) {
	dom = windows.map(function (w) {
		return new El(w.id, { pre_dimensioned: w.pinned ? '1' : '0' });
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

// --- the tile's membership --------------------------------------------------
function member(attrs) { return new El('window_x', attrs); }
eq(ctx.windowIsTiled(member({ pre_dimensioned: '0' })), true, 'an unpinned window is in the tile');
eq(ctx.windowIsTiled(member({ pre_dimensioned: '1' })), false, 'a pinned window is not');
eq(ctx.windowIsTiled(member({ pre_dimensioned: '0', tile: 'off' })), false, 'a dragged window is not');
eq(ctx.windowIsTiled(member({ pre_dimensioned: '0', view: 'max' })), false, 'a maximized window is not');

// --- find-space slots --------------------------------------------------------
function overlaps(a, b) {
	return a.left < b.left + b.width && b.left < a.left + a.width &&
	       a.top < b.top + b.height && b.top < a.top + a.height;
}
function barsClear(positions, specs) {
	for (let i = 0; i < positions.length; i++) {
		for (let j = i + 1; j < positions.length; j++) {
			const a = { left: positions[i].left, top: positions[i].top, width: specs[i].width, height: specs[i].bar };
			const b = { left: positions[j].left, top: positions[j].top, width: specs[j].width, height: specs[j].bar };
			if (overlaps(a, b)) { return false; }
		}
	}
	return true;
}
function framesClear(positions, specs, obstacles) {
	for (let i = 0; i < positions.length; i++) {
		const frame = { left: positions[i].left, top: positions[i].top, width: specs[i].width, height: specs[i].height };
		for (const obstacle of obstacles) {
			if (overlaps(frame, obstacle)) { return false; }
		}
	}
	return true;
}

const view = { width: 1920, height: 1080 };
const specs = [];
for (let i = 0; i < 6; i++) { specs.push({ width: 450, height: 300, bar: 40 }); }

const free = ctx.windowFindSpacePositions(specs, [], view, 0, 0, 50);
eq(free.length, 6, 'every tiled window finds a slot');
eq(free[0].left, 0, 'the first slot is at the top left');
eq(free[0].top, 0, 'at the top');
eq(free[1].left, 450, 'the next bar clears the first across');
eq(free[1].top, 0, 'on the same row');
eq(barsClear(free, specs), true, 'no two title bars share a slot');

const anchored = [{ left: 0, top: 0, width: 400, height: 1080 }];
const around = ctx.windowFindSpacePositions(specs, anchored, view, 0, 0, 50);
eq(around[0].left, 400, 'the tile starts to the right of the anchored window');
eq(around[0].top, 0, 'at the top of the free space');
eq(framesClear(around, specs, anchored), true, 'no tiled frame is placed over the anchored window');
eq(barsClear(around, specs), true, 'and every bar keeps its own slot around the anchor');

const short_anchor = [{ left: 0, top: 0, width: 400, height: 280 }];
const narrow = { width: 800, height: 1080 };
const below = ctx.windowFindSpacePositions([{ width: 450, height: 300, bar: 40 }], short_anchor, narrow, 0, 0, 50);
eq(below[0].left, 0, 'a short anchor does not push the tile sideways');
eq(below[0].top, 280, 'the tile takes the space under it');

// --- the switch --------------------------------------------------------------
let arranged = 0;
let tiled = 0;
ctx.windowFindSpaceArrange = function () { arranged++; };
ctx.windowTileArrange = function () { tiled++; };
eq(ctx.windowFindSpaceActive(), false, 'the desk starts in tiling mode');
eq(ctx.windowFindSpaceToggle(), true, 'a title-bar double-press switches to find-space');
eq(arranged, 1, 'and lays the tile out');
eq(ctx.windowFindSpaceToggle(), false, 'a second press returns to tiling');
eq(tiled, 1, 'and cascades it again');

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness_file" "$root/public/js/manager/windows.js" "$root/public/js/manager/windows/05_tiling.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'an anchored window does not take a slot in the tile');
}

done_testing();
