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
like($windows, qr/function windowTiledJoinOrLeave\(win, at, home, from, group\)/, 'a drop either joins a pile, starts one, or leaves');
like($windows, qr/function windowTiledInsertSlot\(at, skip, stack\)/, 'the dragged title bar names the slot in the pile under it');
like($windows, qr/function windowTiledInsertAt\(win, to, stack\)/, 'a restored window inserts at its saved slot');
like($windows, qr/function windowTiledFront\(\)/, 'the pile front follows the slots');
like($windows, qr/function windowTiledStackRaise\(stack\)/, 'working in a pile raises it, and a restore does not');
like($windows, qr/jawnosWindowFocusApply/, 'the front title-bar cue follows the pile');
like($windows, qr/function windowTiledBump\(win\)/, 'a title-bar press walks a tiled window to the foot');
like($windows, qr/function windowTiledPress\(win\)/, 'a press is tiled-aware');
like($back, qr/pressWindow\(/, 'the title-bar handler presses through the tile');
like($stack, qr/windowTiledPress\(clicked\)/, 'a press in a tiled body brings it forward through the pile');
like($windows, qr/windowTiledPendingApp\[window_app\]/, 'a bespoke opener claims the latest press for its app');
like($windows, qr/isJson\(jws\).*pre_dimensioned'\) == 1/, 'a saved view places only a pinned window');
like($windows, qr/function windowTiledPreview\(win, at, home, from, group\)/, 'a drag draws the slot it would join');
like($windows, qr/windowTiledOverArea\(win, home, from, group, at\)/, 'the pile ground is each window it covers, with the box the drag left');
like($fit, qr/windowTiledPreview\(win, mouse_position\(\), dragFromTile, dragFromStack, dragGroup\)/, 'the drag shows the preview from where it was picked up');
like($fit, qr/windowTiledJoinOrLeave\(win, \{ x: d\.x, y: d\.y \}, dragFromTile, dragFromStack, dragGroup\)/, 'a drag joins or leaves the pile where it is dropped');
like($css, qr/#window_tile_preview/, 'the preview slot has a look');
like($fit, qr/windowTiledLeave\(win, true\)/, 'a drag to an edge leaves the tile to the half snap');
like($fit, qr/windowTiledLeave\(win, false\)/, 'pinning takes it out of the tile without making it free');
like($storage, qr/tile: \$\(v\)\.attr\('tile'\)/, 'the tile slot is saved with the window');
like($storage, qr/stack: \$\(v\)\.attr\('stack'\)/, 'the pile id is saved with the window');
like($storage, qr/stack_at: \$\(v\)\.attr\('stack_at'\)/, 'and the pile anchor, so a pile away from the corner comes back');
like($storage, qr/free: \$\(v\)\.attr\('free'\)/, 'a dragged-out window is saved as free');
like($storage, qr/if \(v\.tile !== undefined \|\| v\.stack !== undefined \|\| v\.free == 1\)/, 'a restore hands its pile and slot to the window that opens');

# --- a desk can hold more than one pile ---------------------------------
# A drop lands in the pile whose ground is under the pointer (the front one when
# two overlap), starts a pile on a window that is not in one, or floats free.
like($windows, qr/var windowTiledDefaultStack = '0';/, 'the desk has a default pile');
like($windows, qr/function windowTiledStackId\(win\)/, 'a window names its pile');
like($windows, qr/function windowTiledAnchor\(stack\)/, 'a pile stands on an anchor');
like($windows, qr/function windowTiledDropTarget\(at, skip, home, from, group\)/, 'a drop finds the pile or the window under it');
like($windows, qr/var over = \(id === from\)/, 'the carried block is measured against its own pile only');
like($windows, qr/: windowTiledOverArea\(null, null, id, null, at\);/, 'another pile is measured by its own windows');
like($windows, qr/function windowTiledWindowAt\(at, skip, group\)/, 'a drop can land on a window that is not in a pile');
like($windows, qr/function windowTiledStackStart\(win, head, group\)/, 'dropping on such a window starts a pile there');
like($windows, qr/function windowTiledBlockStart\(win, group\)/, 'a block put down on open desk stays a pile');
like($windows, qr/if \(els\.indexOf\(head\[0\]\) >= 0\) \{ return; \}/, 'a carried window is never mistaken for the pile head');
like($windows, qr/carried\.indexOf\(this\) >= 0/, 'and the hit test skips every window the drag carries');
like($windows, qr/function windowTiledStackJoin\(win, stack, at, group\)/, 'a drop joins the pile at the slot its bar is over');
like($windows, qr/windowTiledStackJoin\(win, target\.stack, at, group\)/, 'the drop target is the pile it found');
like($windows, qr/if \(typeof windowAnchorRelease === 'function'\)/, 'the tile releases a pin through the one helper');
like($fit, qr/function windowAnchorRelease\(win\) \{/, 'the pin release is one helper');
like($fit, qr/if \(button\.attr\('status'\) == 'on'\) \{\n\t\t\/\/ let it tile again.*\n\t\twindowAnchorRelease\(win\);/, 'the pin button uses the same release');

# --- a drag leaves the pile in the hand ---------------------------------
# The pile steps up as soon as the pointer is off its ground; the drop only
# decides where the window lands.
like($windows, qr/function windowTiledDragLeave\(win, at, home, from, group\)/, 'a drag leaves the pile as soon as it is away');
like($windows, qr/windowTiledDragLeave\(win, at, home, from, group\);\n\tvar target = windowTiledDropTarget/, 'the drop takes that leave before it chooses a target');
like($windows, qr/\/\/ the drag takes the window out of its pile as soon as it is away from it\n\twindowTiledDragLeave/, 'so does the preview');
like($windows, qr/function windowTiledPreview\(win, at, home, from, group\)/, 'the preview shows the pile or the new pile it would join');

# --- a drag carries the windows below it ---------------------------------
# The windows under the held one in the same pile travel with it, so a pile is
# moved whole instead of being cut in half.
like($windows, qr/function windowTiledBlockEls\(win, group\)/, 'the drag names the block it carries');
like($windows, qr/function windowTiledBlockLeave\(win, group\)/, 'the block leaves together');
like($fit, qr/dragGroup\.push\(\{ el: this, left:/, 'the drag picks up the windows below the held one');
like($fit, qr/if \(\(parseFloat\(\$\(this\)\.css\('top'\)\) \|\| 0\) <= startTop\) \{ return; \}/, 'the block is the cascade below the held window on the y axis');
like($fit, qr/dragGroup\.sort\(function\(a, b\) \{ return a\.top - b\.top; \}\);/, 'and is carried in y order');
like($fit, qr/\$\(g\.el\)\.css\(\{ 'left': g\.left \+ dx, 'top': g\.top \+ dy \}\)/, 'and moves them by the held window\'s own delta');
like($fit, qr/if \(edge && !dragGroup\.length\)/, 'a pile move is not the half snap');

# --- joining a pile is the standard size, and the piles come back ----------
# A window that joins shrinks to the size a fresh window opens at; the saved
# pile map is replayed after the restore burst so every pile comes back whole,
# in slot order, with the piles in the depth order they had.
like($windows, qr/var windowTileDefaultWidth = (\d+);\nvar windowTileDefaultHeight = (\d+);/, 'the joiner takes the standard window size');
my ($tile_w, $tile_h) = $windows =~ /var windowTileDefaultWidth = (\d+);\s*\n\s*var windowTileDefaultHeight = (\d+);/;
my ($server_w, $server_h) = $maker =~ /my \$default_width = (\d+);\s*\n\s*my \$default_height = (\d+);/;
is($tile_w, $server_w, 'the tile default width is the window maker default width');
is($tile_h, $server_h, 'and the height');
like($windows, qr/function windowTiledSizeReset\(win\)/, 'and the reset is one helper');
like($windows, qr/windowTiledSizeReset\(w\);/, 'every window in the joined block is resized');
like($windows, qr/function windowTiledIdentity\(el\)/, 'a window is found again by app and instance');
like($storage, qr/storage\['window_stacks'\] = \{ piles: pile_map \};/, 'the pile map is saved with the windows');
like($windows, qr/function windowStacksApply\(\)/, 'and replayed after a reload');
like($windows, qr/if \(windowTiledStacksPending\) \{ windowTiledStacksPending = false; windowStacksApply\(\); \}/, 'the settle applies it once');
like($storage, qr/windowStacksRestoreSoon\(\)/, 'the retriever asks for the replay');

# --- a press holds its slot before the window arrives ---------------------
# Clicking down the clothesline fires several opens; their responses can land in
# any order. The slot is reserved at the press, so the stack keeps the order the
# presses were made in.
like($windows, qr/function windowTiledReserve\(timestamp, app\)/, 'a press reserves its slot');
like($windows, qr/windowTiledPress\(open\)/, 'a press on an app that is already open walks its window to the foot');
like($windows, qr/el\.attr\('data-terminal-id'\)/, 'a session window does not answer a press that makes another');
like($windows, qr/windowTiledPending\[window_stamp\]/, 'the window claims the slot reserved for its stamp');
like($windows, qr/var pending_stamp = windowTiledPendingApp\[window_app\]/, 'a bespoke opener that changes its stamp claims the latest press for its app');
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
	return { val: function () { return this; }, css: function () { return '0px'; }, outerHeight: function () { return 0; }, attr: function () { return this; }, show: function () { return this; }, hide: function () { return this; } };
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
	j.hide = function () { return j; };
	j.val = function () { return j; };
	return j;
}

	// Pinned place released: the real helper lives in windows/02_fit.js; the
	// harness plays its effect so the tile's half of the agreement is tested.
	function anchorReleaseStub(w) {
		if (w.attr('pre_dimensioned') == 1) {
			w.attr('pre_dimensioned', 0);
			w.attr('place_released', 1);
		}
	}

	const documentStub = { getElementById: function () { return null; } };

	// the storage windowSaver writes and windowStacksApply reads
	const sessionStore = {};
	const sessionStub = {
		getItem: function (k) { return (sessionStore[k] === undefined) ? null : sessionStore[k]; },
		setItem: function (k, v) { sessionStore[k] = String(v); },
		removeItem: function (k) { delete sessionStore[k]; }
	};

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
	// gate.js provides this in the page; the harness is a stub for it
	isJson: function (s) { try { JSON.parse(s); return true; } catch (e) { return false; } },
	topLevelNow: function () {},
	taskbarDisplayer: function () {},
	jawnosAppFieldGet: function () { return ''; },
	windowAnchorRelease: anchorReleaseStub,
	sessionStorage: sessionStub,
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

// Two presses for one app: a bespoke opener must claim the latest press, never
// an older reservation that would drop it back into an earlier slot.
ctx.windowTiledPending = {};
ctx.windowTiledPendingApp = {};
dom = [];
ctx.windowTiledReserve('301', 'help');
ctx.windowTiledReserve('302', 'help');
const help_late = new El('window_999', { pre_dimensioned: '0', app: 'help' });
dom.push(help_late);
ctx.windowReorganizer('window_999');
eq(help_late.attr('tile'), '1', 'a bespoke opener claims the latest press, not an older one');
eq(ctx.windowTiledPending['301'] !== undefined, true, 'the older press is left to time out');

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

// The pile's depth is its slot order: the foot of the pile is the front, and
// pressing a tiled title bar walks that window down to the foot.
let pile = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
let focus_calls = 0;
ctx.jawnosWindowFocusApply = function () { focus_calls++; };
ctx.windowTiledFront();
let z0 = Number(pile[0].style['z-index']);
let z1 = Number(pile[1].style['z-index']);
let z2 = Number(pile[2].style['z-index']);
eq(z1 > z0 && z2 > z1, true, 'z climbs with the slot, so the foot of the pile is in front');
eq(focus_calls > 0, true, 'the front title-bar cue follows the pile');

let bumped = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
ctx.windowTiledBump('#window_a');
eq(bumped[0].attr('tile'), '2', 'a pressed tiled window walks to the foot of the pile');
eq(bumped[1].attr('tile'), '0', 'the windows above it close up');
eq(bumped[2].attr('tile'), '1', 'and keep their order');
eq(bumped[0].style.top, 80, 'the pressed window sits at the foot');
eq(Number(bumped[0].style['z-index']) > Number(bumped[1].style['z-index']), true, 'and wears the front');
ctx.windowTiledBump('#window_a');
eq(bumped[0].attr('tile'), '2', 'pressing the foot window leaves the pile alone');

// Pressing an app that is already on the desk makes no new window, so the press
// is a press on that window: it walks to the foot at the press, and holds no
// slot for a window that will never be made.
let reopened = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
ctx.windowTiledPending = {};
ctx.windowTiledPendingApp = {};
ctx.windowTiledReserve('901', 'window_a');
eq(reopened[0].attr('tile'), '2', 'pressing an open app walks its window to the foot');
eq(reopened[1].attr('tile'), '0', 'the windows it passed close up');
eq(reopened[2].attr('tile'), '1', 'and keep their order');
eq(Object.keys(ctx.windowTiledPending).length, 0, 'an open app holds no slot for a window it will not make');

// A press that arrives while a new window is still on its way takes the slot
// after that window's reservation, so the two keep press order.
let press_order = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
ctx.windowTiledPending = {};
ctx.windowTiledPendingApp = {};
ctx.windowTiledReserve('902', 'window_a');
ctx.windowTiledReserve('903', 'window_new');
eq(press_order[0].attr('tile'), '2', 'the reopened window walks to the foot');
eq(ctx.windowTiledPending['903'].slot, 3, 'the window pressed after it takes the next slot');

// A terminal session is one of several of its app, so a press on it makes a new
// window: it reserves a slot and leaves the open session where it is.
let session = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 }
]);
session[0].attr('data-terminal-id', 't1');
ctx.windowTiledPending = {};
ctx.windowTiledPendingApp = {};
ctx.windowTiledReserve('904', 'window_a');
eq(session[0].attr('tile'), '0', 'a press that makes another window leaves the open one in place');
eq(ctx.windowTiledPending['904'].slot, 2, 'and reserves the next slot for the new one');
ctx.windowTiledPending = {};
ctx.windowTiledPendingApp = {};

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

// The tab's saved view of an app is not a place for a fresh unpinned window: that
// window belongs to the tile, and using the view gave it a fixed place and no
// slot, so it stood outside the pile.
let saved_view = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 }
]);
ctx.windowTiledPending = {};
ctx.windowTiledPendingApp = {};
ctx.windowTiledRestore = {};
let saved_fresh = new El('window_c', { pre_dimensioned: '0' });
dom.push(saved_fresh);
ctx.jws = JSON.stringify({ window_c: { top: 700, left: 900, height: 300, width: 400 } });
ctx.windowReorganizer('window_c');
eq(saved_fresh.attr('tile'), '2', 'a fresh window takes a slot even when the app has a saved view');
eq(saved_fresh.style.top, 80, 'and sits in that step, not at the saved pixels');
eq(saved_fresh.style.left, 100, 'nor across at the saved pixels');

// the same saved view on a pinned window is the place it keeps
let saved_pin = desk([{ id: 'window_a', top: 0, left: 0 }]);
ctx.windowTiledRestore = {};
let pinned_saved = new El('window_b', { pre_dimensioned: '1' });
dom.push(pinned_saved);
ctx.jws = JSON.stringify({ window_b: { top: 700, left: 900, height: 300, width: 400 } });
ctx.windowReorganizer('window_b');
eq(pinned_saved.attr('tile'), undefined, 'a pinned window takes no slot');
eq(pinned_saved.style.top, 700, 'and keeps the place the saved view holds');
ctx.jws = undefined;

// Carrying a tiled window off its pile takes it out at once: the pile closes the
// gap while the pointer is still down, so letting go is not what resets it.
let carried = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
ctx.windowTiledDragLeave('#window_b', { x: 1400, y: 800 }, { left: 50, top: 40, width: 400, height: 300 });
eq(carried[1].attr('tile'), undefined, 'a drag off the pile takes the window out at once');
eq(carried[1].attr('free'), '1', 'and floats it free');
eq(carried[0].style.top, '0px', 'the window above keeps its place');
eq(carried[2].attr('tile'), '1', 'the window below closes the gap while the pointer is down');
eq(carried[2].style.top, 40, 'and steps up in the hand');

// a drag that stays over the pile keeps the slot it holds
let steady = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 }
]);
ctx.windowTiledDragLeave('#window_b', { x: 100, y: 60 }, { left: 50, top: 40, width: 400, height: 300 });
eq(steady[1].attr('tile'), '1', 'a drag still over its pile keeps the slot');

// An anchored window dropped over a pile joins it at the bar's place, and is
// anchored no longer.
let anchor_desk = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 }
]);
let anchored = new El('window_c', { pre_dimensioned: '1' });
anchored.style.left = '60px';
anchored.style.top = '0px';
dom.push(anchored);
ctx.windowTiledJoinOrLeave('#window_c', { x: 100, y: 0 }, { left: 60, top: 0, width: 400, height: 300 });
eq(anchored.attr('tile'), '0', 'an anchored window dropped over a pile joins at the bar slot');
eq(anchored.attr('pre_dimensioned'), 0, 'and is anchored no longer');
eq(anchored.attr('place_released'), 1, 'its pin is released the way the button releases it');
eq(anchor_desk[0].attr('tile'), '1', 'the window it landed above steps down');
eq(anchored.style.width, '480px', 'a window that joins takes the standard width');
eq(anchored.style.height, '640px', 'and the standard height');

// Dropping a window over one that is not in a pile starts a pile there: the
// window under stays the head where it stood, so a desk can hold several piles.
let lone_head = desk([{ id: 'window_a', free: true, top: 300, left: 1100 }]);
let starter = new El('window_b', { pre_dimensioned: '0' });
starter.attr('free', '1');
starter.style.left = '1150px';
starter.style.top = '330px';
dom.push(starter);
ctx.windowTiledJoinOrLeave('#window_b', { x: 1200, y: 330 }, { left: 1150, top: 330, width: 400, height: 300 });
let new_pile = lone_head[0].attr('stack');
eq(typeof new_pile, 'string', 'a drop on a lone window starts a pile with an id');
eq(starter.attr('stack'), new_pile, 'and the dropped window joins it');
eq(lone_head[0].attr('tile'), '0', 'the window that was there is the pile head');
eq(lone_head[0].style.left, 1100, 'the head stays where it stood');
eq(starter.attr('tile'), '1', 'the dropped window joins at the foot');
eq(starter.style.left, 1150, 'and steps across from that pile');
eq(starter.style.top, 340, 'and down one bar from it');

// a later drop joins the pile that is already there, at its own foot
let third = new El('window_c', { pre_dimensioned: '0' });
third.attr('free', '1');
third.style.left = '1200px';
third.style.top = '380px';
dom.push(third);
ctx.windowTiledJoinOrLeave('#window_c', { x: 1250, y: 380 }, { left: 1200, top: 380, width: 400, height: 300 });
eq(third.attr('stack'), new_pile, 'a later drop joins the pile that is there');
eq(third.attr('tile'), '2', 'at its foot');
eq(third.style.left, 1200, 'laid out from the pile anchor');
eq(third.style.top, 380, 'not from the desk corner');

// each pile closes only its own gap
let two_piles = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 }
]);
let far_head = new El('window_x', { pre_dimensioned: '0' });
far_head.attr('free', '1');
far_head.style.left = '1200px';
far_head.style.top = '500px';
dom.push(far_head);
let far_foot = new El('window_y', { pre_dimensioned: '0' });
far_foot.attr('free', '1');
far_foot.style.left = '1250px';
far_foot.style.top = '540px';
dom.push(far_foot);
ctx.windowTiledJoinOrLeave('#window_y', { x: 1300, y: 540 }, { left: 1250, top: 540, width: 400, height: 300 });
eq(far_foot.attr('tile'), '1', 'a second pile is formed beside the first');
ctx.windowTiledGapClose('#window_x');
eq(far_foot.attr('tile'), '0', 'a close closes only that pile');
eq(far_foot.style.top, 500, 'stepping its own foot up');
eq(two_piles[0].style.top, '0px', 'and leaves the other pile alone');
eq(two_piles[1].style.top, '40px', 'both of its windows');

// A pile away from the corner comes back where it stood: each member carries the
// pile's anchor as well as its slot.
ctx.windowTiledRestore = {};
ctx.windowTiledPending = {};
ctx.windowTiledPendingApp = {};
ctx.jws = undefined;
dom = [];
let pile_head = new El('window_a', { pre_dimensioned: '0' });
pile_head.style.left = '1100px';
pile_head.style.top = '300px';
pile_head.attr('tile', '0').attr('stack', 's7').attr('stack_at', '1100,300');
dom.push(pile_head);
let restored_foot = new El('window_b', { pre_dimensioned: '0' });
dom.push(restored_foot);
ctx.windowTiledRestore = { window_b: { tile: '1', stack: 's7', stack_at: '1100,300' } };
ctx.windowReorganizer('window_b');
eq(restored_foot.attr('stack'), 's7', 'a restored window rejoins its own pile');
eq(restored_foot.style.left, 1150, 'at the anchor it saved');
eq(restored_foot.style.top, 340, 'and the slot it saved');
eq(pile_head.style.left, 1100, 'the head it rejoined is not moved');

// A drag carries the windows below the held one: the block leaves together and
// joins the next pile whole, in its own cascade order.
let block_desk = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
let far = new El('window_x', { pre_dimensioned: '0' });
far.attr('free', '1');
far.style.left = '1200px';
far.style.top = '500px';
dom.push(far);
let far2 = new El('window_y', { pre_dimensioned: '0' });
far2.attr('free', '1');
far2.style.left = '1250px';
far2.style.top = '540px';
dom.push(far2);
ctx.windowTiledJoinOrLeave('#window_y', { x: 1300, y: 540 }, { left: 1250, top: 540, width: 400, height: 300 });
let far_pile = far.attr('stack');
let drag_group = [{ el: block_desk[1] }, { el: block_desk[2] }];
block_desk[0].style.left = '1300px';
block_desk[0].style.top = '560px';
ctx.windowTiledJoinOrLeave('#window_a', { x: 1350, y: 560 }, { left: 0, top: 0, width: 400, height: 300 }, '0', drag_group);
eq(block_desk[0].attr('stack'), far_pile, 'the held window joins the pile under it');
eq(block_desk[1].attr('stack'), far_pile, 'and the windows below it come with it');
eq(block_desk[2].attr('stack'), far_pile, 'all of them');
eq(block_desk[1].attr('tile'), '3', 'in their own order after the pile head');
eq(block_desk[2].attr('tile'), '4', 'keeping the cascade');
eq(block_desk[1].attr('free'), undefined, 'and none is left free');
eq(block_desk[1].style.top, 620, 'laid out from the new pile anchor');

// A block reorders within its own pile as a block: dropped at the head it keeps
// its order, and the window it passed steps below the whole block.
let reorder = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 },
	{ id: 'window_d', top: 120, left: 150 }
]);
let reorder_group = [{ el: reorder[2] }, { el: reorder[3] }];
reorder[1].style.left = '200px';
reorder[1].style.top = '0px';
ctx.windowTiledJoinOrLeave('#window_b', { x: 250, y: 0 }, { left: 50, top: 40, width: 400, height: 300 }, '0', reorder_group);
eq(reorder[1].attr('tile'), '0', 'a block dropped at the head takes the first slot');
eq(reorder[2].attr('tile'), '1', 'keeping its own order');
eq(reorder[3].attr('tile'), '2', 'and both its windows');
eq(reorder[0].attr('tile'), '3', 'the window it passed steps below the block');
eq(reorder[0].style.top, 120, 'and down the cascade');

// A block dropped on a window that sits on its own starts a pile there too: the
// carried windows are under the pointer as well, and must never be mistaken for
// the head of the new pile.
let block_start = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
let alone = new El('window_x', { pre_dimensioned: '0' });
alone.attr('free', '1');
alone.style.left = '1200px';
alone.style.top = '600px';
dom.push(alone);
let start_group = [
	{ el: block_start[1], left: 50, top: 40, width: 400, height: 300 },
	{ el: block_start[2], left: 100, top: 80, width: 400, height: 300 }
];
block_start[0].style.left = '1250px';
block_start[0].style.top = '600px';
block_start[1].style.left = '1300px';
block_start[1].style.top = '640px';
block_start[2].style.left = '1350px';
block_start[2].style.top = '680px';
ctx.windowTiledJoinOrLeave('#window_a', { x: 1300, y: 620 }, { left: 0, top: 0, width: 400, height: 300 }, '0', start_group);
let started = alone.attr('stack');
eq(typeof started, 'string', 'a block dropped on a lone window starts a pile there');
eq(alone.attr('tile'), '0', 'the lone window is the pile head');
eq(block_start[0].attr('stack'), started, 'the held window joins it');
eq(block_start[1].attr('stack'), started, 'and the windows it carries come too');
eq(block_start[2].attr('stack'), started, 'all of them');
eq(block_start[1].attr('tile'), '2', 'in their own order after the head');
eq(block_start[0].style.top, 640, 'laid out from the lone window');

// A drag carrying the block leaves the whole block when the pointer is off the
// pile, so no tail is stranded behind.
let block_leave = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
let leave_group = [{ el: block_leave[1] }, { el: block_leave[2] }];
ctx.windowTiledDragLeave('#window_a', { x: 1400, y: 800 }, { left: 0, top: 0, width: 400, height: 300 }, '0', leave_group);
eq(block_leave[0].attr('tile'), undefined, 'the held window leaves the pile');
eq(block_leave[1].attr('tile'), undefined, 'the windows below it leave with it');
eq(block_leave[2].attr('free'), '1', 'and the block floats together');

// A block put down on open desk stays a pile there, so grabbing its top next
// time takes it whole again.
let block_open = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 },
	{ id: 'window_c', top: 80, left: 100 }
]);
let open_group = [
	{ el: block_open[1], left: 50, top: 40, width: 400, height: 300 },
	{ el: block_open[2], left: 100, top: 80, width: 400, height: 300 }
];
block_open[0].style.left = '800px';
block_open[0].style.top = '400px';
block_open[1].style.left = '850px';
block_open[1].style.top = '440px';
block_open[2].style.left = '900px';
block_open[2].style.top = '480px';
ctx.windowTiledJoinOrLeave('#window_a', { x: 830, y: 430 }, { left: 0, top: 0, width: 400, height: 300 }, '0', open_group);
eq(typeof block_open[0].attr('stack'), 'string', 'a block dropped on open desk stays a pile');
eq(block_open[0].attr('tile'), '0', 'with the held window as its head');
eq(block_open[1].attr('tile'), '1', 'and the carried windows below it');
eq(block_open[2].attr('tile'), '2', 'in order');
eq(block_open[0].style.left, 800, 'standing where it was dropped');
eq(block_open[1].style.left, 850, 'laid out from the head');
eq(block_open[0].attr('free'), undefined, 'none of it is left free');
eq(block_open[0].attr('stack'), block_open[2].attr('stack'), 'all of it in one pile');

// The pile's ground is the windows themselves, not their bounding box: the empty
// corner a stagger leaves is the desk, and a drop there does not join.
let corner = desk([
	{ id: 'window_a', top: 0, left: 0 },
	{ id: 'window_b', top: 40, left: 50 }
]);
let passing = new El('window_c', { pre_dimensioned: '0' });
passing.attr('free', '1');
passing.style.left = '900px';
passing.style.top = '900px';
dom.push(passing);
ctx.windowTiledJoinOrLeave('#window_c', { x: 430, y: 20 }, { left: 900, top: 900, width: 400, height: 300 });
eq(passing.attr('tile'), undefined, 'a drop in the empty corner of a pile does not join it');
eq(passing.attr('free'), '1', 'and the window stays free');
eq(corner[0].attr('tile'), '0', 'the pile is left as it was');

// The boxes a dragged block left behind belong to the pile it came from. A pile
// that is in front must not catch the drag by borrowing them, so grabbing a
// right-hand pile and putting it down over itself stays in that pile.
let leak = desk([{ id: 'window_a', top: 0, left: 0 }]);
leak[0].style['z-index'] = 900;
let right_head = new El('window_x', { pre_dimensioned: '0' });
right_head.style.left = '1200px';
right_head.style.top = '600px';
right_head.style['z-index'] = 100;
right_head.attr('tile', '0').attr('stack', 's9').attr('stack_at', '1200,600');
let right_foot = new El('window_y', { pre_dimensioned: '0' });
right_foot.style.left = '1250px';
right_foot.style.top = '640px';
right_foot.style['z-index'] = 101;
right_foot.attr('tile', '1').attr('stack', 's9').attr('stack_at', '1200,600');
dom.push(right_head, right_foot);
let leak_group = [{ el: right_foot, left: 1250, top: 640, width: 400, height: 300 }];
ctx.windowTiledJoinOrLeave('#window_x', { x: 1300, y: 700 }, { left: 1200, top: 600, width: 400, height: 300 }, 's9', leak_group);
eq(right_head.attr('stack'), 's9', 'a right-hand pile put down over itself stays in that pile');
eq(right_foot.attr('stack'), 's9', 'with the windows it carries');
eq(leak[0].attr('tile'), '0', 'the pile in front is not the drop target');
eq(leak[0].style.top, '0px', 'nor moved');

// The saved pile map is replayed after the restore burst: every window comes
// back to its own pile and slot, and the piles keep the depth order they had.
ctx.windowTiledRestore = {};
ctx.windowTiledPending = {};
ctx.windowTiledPendingApp = {};
dom = [];
let map_a = new El('window_a', { pre_dimensioned: '0' });
let map_b = new El('window_b', { pre_dimensioned: '0' });
let map_x = new El('window_x', { pre_dimensioned: '0' });
let map_y = new El('window_y', { pre_dimensioned: '0' });
dom.push(map_a, map_b, map_x, map_y);
sessionStore['window_storage'] = JSON.stringify({ window_stacks: { piles: [
	{ id: '0', at: '', members: ['window_a|', 'window_b|'] },
	{ id: 's1', at: '1200,500', members: ['window_x|', 'window_y|'] }
] } });
ctx.windowTiledStacksPending = true;
ctx.windowTiledSettle();
eq(map_a.attr('tile'), '0', 'the map puts the head back on its slot');
eq(map_b.attr('tile'), '1', 'and the second window on its own');
eq(map_x.attr('stack'), 's1', 'a pile away from the corner comes back as its own pile');
eq(map_y.attr('stack'), 's1', 'with its members');
eq(map_y.style.left, 1250, 'laid out from the pile anchor');
eq(map_y.style.top, 540, 'and its saved slot');
eq(Number(map_x.style['z-index']) > Number(map_a.style['z-index']), true, 'the pile that was in front is in front again');

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness_file" "$root/public/js/manager/windows.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'an anchored window does not take a slot in the tile');
}

done_testing();
