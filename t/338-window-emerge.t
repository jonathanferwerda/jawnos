# tests-for: public/js/manager/windows/06_emerge.js public/js/manager/windows.js public/js/manager/leaderboardprinter.js public/js/manager/lazy.js public/css/manager.css public/css/universal.css templates/layouts/manager.html.ep lib/JawnOS/Domain/Contrast.pm lib/JawnOS/Domain/Loader.pm
# covers:    a new window pours out of the control that opened it - the press
#            records a viewport rectangle and richer app metadata, pointerdown
#            draws the chrome preview at once, windowMaker hands the real
#            rectangle over, and the preview is retargeted or put away. The
#            preview wears the app's real saved colour/ink and a skeleton body
#            chosen by archetype, and the prediction follows the placer's
#            geometry. Also the pile preview exception for a drag.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

my $root   = repo_root();
my $emerge = read_file("$root/public/js/manager/windows/06_emerge.js");
my $index  = read_file("$root/public/js/manager/windows.js");
my $board  = read_file("$root/public/js/manager/leaderboardprinter.js");
my $lazy   = read_file("$root/public/js/manager/lazy.js");
my $css    = read_file("$root/public/css/manager.css");
my $universal = read_file("$root/public/css/universal.css");
my $layout = read_file("$root/templates/layouts/manager.html.ep");
my $contrast = read_file("$root/lib/JawnOS/Domain/Contrast.pm");
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");

# --- the part is named and reached -------------------------------------------
like($index, qr/06_emerge\.js\s+-\s+a new window pouring/, 'windows.js names the emerge part');
like($index, qr/var made = 0;/, 'windowMaker counts only a window it appended');
like($index, qr/made = 1;/, 'the append marks the window as made');
like($index, qr/if \(made && typeof jawnosWindowEmerge === 'function'\) \{ jawnosWindowEmerge\(\$\('#' \+ window_id\)\); \}/,
	'and the motion is handed the finished window');
like($index, qr/if \(edge && !\(group && group\.length\)\)/,
	'a drag carrying its pile does not draw the half preview');

# --- the press sources -------------------------------------------------------
like($board, qr/jawnosWindowOriginFromPoint[\s\S]{0,1600}appointmentGrabber\(o\[4\]\['name'\],timestamp\)/,
	'the canvas pill records its rectangle and preview before the opener');
like($board, qr/jawnosWindowOriginFromPoint[\s\S]{0,1600}jawnosWindowEmergeGhostStart\(origin\)/,
	'the canvas starts the preview from the hit path');
like($board, qr/jawnosWindowEmergeOpen\(origin_app\)/,
	'but not when the app already has a window on the desk');
like($lazy, qr/jawnosWindowOriginFromElement\(target\[0\], app\); \}\s*target\.trigger\('click'\)/,
	'the lazy replay stamps the origin again before the click');
like($emerge, qr/jawnosWindowEmergeRaise\(jawnosWindowEmergeControl\(el, \{ reopen: true \}\)\)/,
	'a press for an app already on the desk is answered as a raise');
like($emerge, qr/function jawnosWindowEmergeRaise\(control\)[\s\S]{0,700}windowTiledPress\(win\)/,
	'which goes through windowTiledPress, the one path that jiggles');
like($emerge, qr/el\.closest\('\.window_toggle'\)\) && jawnosWindowEmergeRaise/,
	'a taskbar tile is left to its own raise/minimise');

# --- the sheet and its constraints -------------------------------------------
like($css, qr/\.jawnos_emerge_sheet\s*\{[^}]*position:\s*fixed[^}]*z-index:\s*2147482890[^}]*pointer-events:\s*none/s,
	'the sheet is fixed, click-through and above the windows');
like($css, qr/\@media \(prefers-reduced-motion: reduce\) \{\s*\.jawnos_emerge_sheet \{ display: none; \}\s*\}/s,
	'reduced motion also hides a sheet already in flight');
ok(index($css, '.jawnos_emerge_sheet') > index($css, '@keyframes jawnos_window_lock'),
	'the emerge styles are appended after the class effects');

# --- the press-time preview's styles ----------------------------------------
like($css, qr/\.jawnos_emerge_ghost\s*\{[^}]*position:\s*fixed[^}]*z-index:\s*2147482891[^}]*pointer-events:\s*none/s,
	'the ghost is fixed, click-through and above the windows');
like($css, qr/\.jawnos_emerge_ghost \.jawnos_emerge_bar\s*\{[^}]*height:\s*var\(--navbar_h, 36px\)/s,
	'its title bar is the height of a real one');
like($css, qr/\.jawnos_emerge_ghost \.jawnos_emerge_button\s*\{/,
	'the chrome draws the standard window controls');
like($css, qr/\.jawnos_emerge_ghost \.jawnos_emerge_name\s*\{[^}]*font-size:\s*20px/s,
	'the title uses .appointment_name\'s 20px size');
like($css, qr/\.jawnos_emerge_skeleton_grid\s*\{/, 'the skeleton bodies have their own shapes');
like($css, qr/\.jawnos_emerge_skeleton_terminal\s*\{/, 'including a terminal body');
like($css, qr/body\.dark_theme \.jawnos_emerge_ghost \.jawnos_emerge_bar/,
	'a dark desk keeps the theme ink on the preview bar');
like($universal, qr/body\.dark_theme \[data-appt-tint\]\s*\{[^}]*background-color:\s*var\(--appt-dark\)\s*!important/s,
	'the shared dark rule repaints an appointment tint with --appt-dark');
like($css, qr/body\.dark_theme \.jawnos_emerge_ghost \.jawnos_emerge_bar,\s*body\.dark_theme \.jawnos_emerge_ghost \.jawnos_emerge_name,\s*body\.dark_theme \.jawnos_emerge_ghost \.jawnos_emerge_button \{ color: var\(--ink\) !important; \}/s,
	'and the bar, name and controls take the theme ink, as top_navbar does');
like($emerge, qr/bar\.setAttribute\('data-appt-tint', 'yes'\)/,
	'the ghost bar carries the real data-appt-tint hook');
like($css, qr/body\[data-window-effects="off"\] \.jawnos_emerge_ghost \{ display: none !important; \}/,
	'turning the effects off hides a preview already in flight');
like($css, qr/\@media \(prefers-reduced-motion: reduce\) \{\s*\.jawnos_emerge_ghost \{ display: none; \}\s*\}/s,
	'reduced motion hides the preview too');
ok(index($css, '.jawnos_emerge_ghost') > index($css, '.jawnos_emerge_sheet'),
	'the preview styles follow the sheet block at the very end');

# --- the implementation stays on the plan ------------------------------------
like($emerge, qr/function jawnosWindowOriginFromElement\(/, 'a DOM control can be captured');
like($emerge, qr/function jawnosWindowOriginFromPoint\(/, 'a canvas pill can be captured');
like($emerge, qr/function jawnosWindowOriginTake\(/, 'the press is taken once');
like($emerge, qr/function jawnosWindowEmergeKeyframes\(/, 'the shape is pure geometry');
like($emerge, qr/function jawnosWindowEmergeCssRect\(/, 'a zoomed rectangle is put back into layout units');
like($emerge, qr/function jawnosWindowEmerge\(win, origin\)/, 'the motion takes the window and an origin');
like($emerge, qr/function jawnosWindowEmergeGhostStart\(origin\)/, 'the press can start a preview');
like($emerge, qr/function jawnosWindowEmergeGhostRetarget\(/, 'the preview is retargeted to the real frame');
like($emerge, qr/function jawnosWindowEmergeGhostCancel\(/, 'the preview can be put away');
like($emerge, qr/function jawnosWindowEmergePredict\(/, 'the frame is predicted from the cascade');
like($emerge, qr/function jawnosWindowEmergeAppColour\(/, 'the real app colour is read, not guessed');
like($emerge, qr/function jawnosWindowEmergeArchetype\(/, 'an app chooses a skeleton archetype');
like($emerge, qr/function jawnosWindowEmergeSkeleton\(/, 'the skeleton body is built');
like($emerge, qr/jawnosWindowEffectsLevel/, 'the level is read when it exists');
like($emerge, qr/prefers-reduced-motion/, 'reduced motion is honoured');
unlike($emerge, qr/\bgetContext\s*\(/, 'no canvas or WebGL context is created');
unlike($emerge, qr/\.filter\s*=/, 'no filter animation');
unlike($emerge, qr/hsla?\(/, 'no hash tint is used for the app colour');
like($layout, qr/var jawnos_app_colours = .*app_colour_map\(\[ sort keys %\{\$gb::known_appts\} \]\)/,
	'the layout seeds the app colour map from the known apps');
like($contrast, qr/sub app_colour_map \{/, 'the domain builds the colour map in one read');
like($contrast, qr/&contrast_ink\(\$light\)/, 'the map uses the real contrast ink');
like($loader, qr/app_colour_map/, 'the domain map registers app_colour_map');
like($layout, qr/var jawnos_app_places = .*app_window_places/, 'the layout seeds pinned window places');
like($emerge, qr/function jawnosWindowEmergeAppPlace\(/, 'the ghost reads a pinned place');
like($emerge, qr/function jawnosWindowEmergePlaceRect\(/, 'and scales it like windowPlaceRestore');

# --- played in a bare context ------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to play the emerge motion', 1 unless $node && -x $node;

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

function hasClass(node, cls) {
	return !!node && (' ' + (node.className || '') + ' ').indexOf(' ' + cls + ' ') >= 0;
}
function selectorTokens(sel) { return String(sel || '').split(',').map((s) => s.trim()); }
function ancestorId(node, id) {
	let p = node;
	while (p) { if (p.id === id) { return true; } p = p.parentNode; }
	return false;
}
function matchSimple(node, token) {
	if (!node || node.nodeType !== 1) { return false; }
	if (token.charAt(0) === '.') { return hasClass(node, token.slice(1)); }
	if (token.charAt(0) === '#') { return node.id === token.slice(1); }
	return false;
}
function findDescendant(root, sel) {
	const tokens = selectorTokens(sel);
	const stack = (root.children || []).slice();
	while (stack.length) {
		const n = stack.shift();
		for (const t of tokens) {
			if (t === '#app_switcher .app') {
				if (hasClass(n, 'app') && ancestorId(n, 'app_switcher')) { return n; }
			}
			else if (matchSimple(n, t)) { return n; }
		}
		if (n.children) { stack.push.apply(stack, n.children); }
	}
	return null;
}
function closestMatch(node, sel) {
	const tokens = selectorTokens(sel);
	let p = node;
	while (p && p.nodeType === 1) {
		for (const t of tokens) {
			if (t === '#app_switcher .app') {
				if (hasClass(p, 'app') && ancestorId(p, 'app_switcher')) { return p; }
			}
			else if (matchSimple(p, t)) { return p; }
		}
		p = p.parentNode;
	}
	return null;
}
function findClass(root, cls) {
	if (!root) { return null; }
	if (hasClass(root, cls)) { return root; }
	const kids = root.children || [];
	for (let i = 0; i < kids.length; i++) {
		const found = findClass(kids[i], cls);
		if (found) { return found; }
	}
	return null;
}
function textIn(root) {
	if (!root) { return ''; }
	let text = root.textContent || '';
	const kids = root.children || [];
	for (let i = 0; i < kids.length; i++) { text += textIn(kids[i]); }
	return text;
}
function rectFromStyle(el) {
	const px = (v) => { const n = parseFloat(v); return isFinite(n) ? n : 0; };
	return {
		left: px(el.style.left), top: px(el.style.top),
		width: px(el.style.width), height: px(el.style.height),
		radius: px(el.style.borderRadius)
	};
}
function makeElement(tag, className) {
	const el = {
		nodeType: 1,
		tagName: String(tag || 'DIV').toUpperCase(),
		className: className || '',
		style: { setProperty: function (k, v) { this[k] = v; } },
		children: [],
		attributes: {},
		parentNode: null,
		textContent: '',
		animations: [],
		offsetWidth: 0,
		appendChild: function (child) { if (child) { child.parentNode = this; this.children.push(child); } return child; },
		removeChild: function (child) {
			const i = this.children.indexOf(child);
			if (i >= 0) { this.children.splice(i, 1); }
			if (child) { child.parentNode = null; }
		},
		setAttribute: function (k, v) { this.attributes[k] = String(v); if (k === 'id') { this.id = String(v); } },
		getAttribute: function (k) {
			if (this.attributes[k] !== undefined) { return this.attributes[k]; }
			if (this[k] !== undefined) { return this[k]; }
			return null;
		},
		getBoundingClientRect: function () { return rectFromStyle(this); },
		getClientRects: function () { return [this.getBoundingClientRect()]; },
		querySelector: function (sel) { return findDescendant(this, sel); },
		closest: function (sel) { return closestMatch(this, sel); },
		animate: function (keys, options) {
			const a = {
				owner: this, keys: keys, options: options, cancelled: 0,
				finished: { then: function () {} },
				cancel: function () { this.cancelled = 1; }
			};
			this.animations.push(a);
			// A ghost's box follows its final key, so the retarget reads the
			// frame the open animation has reached. Other elements keep their
			// inline start values (the fallback sheet is asserted that way).
			if (keys && keys.length && (this.className || '').indexOf('jawnos_emerge_ghost') === 0) {
				const last = keys[keys.length - 1];
				['left', 'top', 'width', 'height', 'borderRadius', 'opacity'].forEach((p) => {
					if (last[p] !== undefined) { this.style[p] = last[p]; }
				});
			}
			return a;
		}
	};
	return el;
}

function El(app) {
	const el = makeElement('DIV');
	el.app = app || '';
	el.rect = { left: 300, top: 100, width: 400, height: 300 };
	el.getBoundingClientRect = function () { return this.rect; };
	el.getClientRects = function () { return [this.rect]; };
	return el;
}

function wrap(el) {
	return {
		jquery: 1, length: 1, 0: el,
		attr: function (name) {
			if (!el) { return undefined; }
			if (el.attributes && el.attributes[name] !== undefined) { return el.attributes[name]; }
			return (el[name] !== undefined) ? el[name] : undefined;
		}
	};
}
const handlers = {};
const winds = [];
const startMenuIcons = {};
const created = [];
const body = makeElement('BODY');
const documentElement = makeElement('HTML');
documentElement.clientWidth = 1200;
documentElement.clientHeight = 900;
const sandboxDocument = {
	createElement: function (tag) { const el = makeElement(tag); created.push(el); return el; },
	body: body,
	documentElement: documentElement,
	querySelector: function () { return null; },
	querySelectorAll: function () { return []; },
	getElementById: function (id) { return startMenuIcons[id] || null; },
	addEventListener: function () {}
};
function $(x) {
	if (x && x.jquery) { return x; }
	if (x === '.wind') {
		return { each: function (fn) { winds.forEach(function (el, i) { fn.call(el, i, el); }); } };
	}
	if (x === sandboxDocument) {
		return { length: 1, on: function (ev, fn) { handlers[ev] = fn; } };
	}
	if (x && x.nodeType === 1) { return wrap(x); }
	return { length: 0 };
}

let effects_on = true;
let reduced = false;
let level = 'medium';
let viewWidth = 1200;
let viewHeight = 900;
let rootZoom = 1;
let phone = false;
const cssVars = { '--navbar_h': '36px', '--window_border': '3px', '--window_radius': '12px' };

const sandbox = {
	$, setTimeout: fakeSetTimeout, clearTimeout: fakeClearTimeout, console,
	document: sandboxDocument,
	window: {
		matchMedia: function () { return { matches: reduced }; },
		innerWidth: 1200, innerHeight: 900,
		PointerEvent: function () {}
	},
	startMenuIconApps: { terminal_toggle: 'terminal', clock_toggle: 'clock' },
	jawnosWindowEffectsOn: function () { return effects_on; },
	jawnosWindowEffectsLevel: function () { return level; },
	jawnos_app_colours: {},
	jawnos_app_places: {},
	jawnosBars: { navbar: 36, border: 3 },
	windowTileDefaultWidth: 480,
	windowTileDefaultHeight: 640,
	windowTileAcrossStep: 50,
	windowTiledDefaultStack: '0',
	windowTiledPending: {},
	windowTiledPendingApp: {},
	windowTiledAnchor: function () { return { left: 0, top: 40 }; },
	windowNextTileSlot: function () { return 0; },
	windowTopLimit: function () { return 40; },
	windowPhoneChecker: function () { return phone; },
	windowViewport: function () { return { width: viewWidth, height: viewHeight }; },
	getComputedStyle: function () {
		return {
			zoom: String(rootZoom),
			getPropertyValue: function (name) { return cssVars[name] || ''; }
		};
	}
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox);

let failures = 0;
function check(name, cond) {
	if (!cond) { failures++; console.log('not ok - ' + name); }
	else { console.log('ok - ' + name); }
}
function press(el) {
	if (!handlers.pointerdown) { throw new Error('the press handler was not installed'); }
	handlers.pointerdown({ button: 0, target: el });
}
function startIcon(id, app, src, hint, left, top, w, h) {
	const img = makeElement('IMG');
	img.id = id;
	img.setAttribute('src', src);
	img.setAttribute('hint', hint);
	img.style.left = (left === undefined ? 10 : left) + 'px';
	img.style.top = (top === undefined ? 20 : top) + 'px';
	img.style.width = (w === undefined ? 40 : w) + 'px';
	img.style.height = (h === undefined ? 40 : h) + 'px';
	startMenuIcons[id] = img;
	return img;
}

// --- levels, defaults and the pure shapes -----------------------------------
check('the level defaults to medium when 05_effects has no reader',
	typeof sandbox.jawnosWindowEmergeLevel === 'function' && sandbox.jawnosWindowEmergeLevel() === 'medium');

const from = sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'notes', 1000);
check('a point origin is centred on the press',
	from.left === 100 && from.top === 200 && from.width === 80 && from.height === 30 && from.radius === 15);
const taken = sandbox.jawnosWindowOriginTake('notes', 1100);
check('the app key gives its origin back', taken && taken.app === 'notes');
check('and it is consumed once', sandbox.jawnosWindowOriginTake('notes', 1100) === null);

sandbox.jawnosWindowOriginFromPoint(10, 10, 20, 20, 10, 'notes', 100);
sandbox.jawnosWindowOriginFromPoint(50, 50, 20, 20, 10, 'clock', 100);
check('origins are keyed by app', sandbox.jawnosWindowOriginTake('clock', 200).app === 'clock'
	&& sandbox.jawnosWindowOriginTake('notes', 200).app === 'notes');

sandbox.jawnosWindowOriginFromPoint(0, 0, 20, 20, 10, 'old', 0);
check('an expired app origin is dropped', sandbox.jawnosWindowOriginTake('old', 20000) === null);

sandbox.jawnosWindowOriginFromPoint(0, 0, 20, 20, 10, '', 0);
check('an app-less press answers a fresh window', !!sandbox.jawnosWindowOriginTake('anything', 1000));
sandbox.jawnosWindowOriginFromPoint(0, 0, 20, 20, 10, '', 0);
check('but never a late one', sandbox.jawnosWindowOriginTake('anything', 3000) === null);

// --- an already-open press is a raise, not a preview ------------------------
const reopen_wind = El('clock');
reopen_wind.setAttribute('app', 'clock');
const reopen_icon = startIcon('clock_toggle', 'clock', '/clock.png', 'Clock');
const reopen_raised = [];
sandbox.windowTiledPress = function (win) { reopen_raised.push(win); };
const reopen_saved_qsa = sandboxDocument.querySelectorAll;
sandboxDocument.querySelectorAll = function (sel) { return sel === '.wind' ? [reopen_wind] : []; };
delete sandbox.jawnosWindowOrigins['clock'];
press(reopen_icon);
check('an already-open control raises the window on the desk',
	reopen_raised.length === 1 && reopen_raised[0] === reopen_wind);
check('and draws no preview for it', !sandbox.jawnosWindowEmergeGhost);
check('and records no origin for a later open', !sandbox.jawnosWindowOrigins['clock']);

const reopen_tile = makeElement('SPAN', 'window_toggle');
reopen_tile.setAttribute('app', 'clock');
reopen_raised.length = 0;
press(reopen_tile);
check('a taskbar tile press is left to its own raise/minimise', reopen_raised.length === 0);

delete sandbox.windowTiledPress;
sandboxDocument.querySelectorAll = reopen_saved_qsa;

const to = { left: 300, top: 100, width: 400, height: 300 };
const shrunk = sandbox.jawnosWindowEmergeCssRect(
	{ left: 150, top: 75, width: 120, height: 45, radius: 22.5 }, 1.5);
check('a zoomed rect is put back into layout pixels',
	shrunk.left === 100 && shrunk.top === 50 && shrunk.width === 80
	&& shrunk.height === 30 && shrunk.radius === 15);
const medium = sandbox.jawnosWindowEmergeKeyframes(
	{ left: 100, top: 200, width: 80, height: 30 }, to, 'medium');
check('medium is 340ms', medium.duration === 340);
check('the overshoot frame travels 72% of 360x35',
	medium.sheet[1].transform === 'translate(259.2px, 25.2px) scale(5.3, 10.6)');
check('the sheet lands exactly on the window rect',
	medium.sheet[2].transform === 'translate(360px, 35px) scale(5, 10)');
check('the window starts invisible and ends natural',
	medium.window[0].opacity === 0 && medium.window[1].opacity === 1);
const light = sandbox.jawnosWindowEmergeKeyframes(
	{ left: 100, top: 200, width: 80, height: 30 }, to, 'light');
const maximum = sandbox.jawnosWindowEmergeKeyframes(
	{ left: 100, top: 200, width: 80, height: 30 }, to, 'maximum');
check('light is shorter and subtler', light.duration < medium.duration
	&& light.sheet[1].transform.indexOf('scale(5.075, 10.15)') >= 0);
check('maximum is longer and overshoots more', maximum.duration > medium.duration
	&& maximum.sheet[1].transform.indexOf('scale(5.5, 11)') >= 0);

// --- the prediction follows the placer's geometry ---------------------------
const saved_anchor = sandbox.windowTiledAnchor;
const saved_slot = sandbox.windowNextTileSlot;
const saved_bars = sandbox.jawnosBars;
const saved_top_limit = sandbox.windowTopLimit;
sandbox.windowTiledAnchor = function () { return { left: 10, top: 55 }; };
sandbox.windowNextTileSlot = function () { return 2; };
sandbox.jawnosBars = { navbar: 44, border: 4 };
viewWidth = 1000;
viewHeight = 700;
const predicted = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
check('the prediction uses the placer anchor and the counted slot',
	predicted.left === 110 && predicted.top === 135);
check('the cascade step is jawnosBars.navbar less jawnosBars.border', 55 + 2 * 40 === predicted.top);
check('the prediction shrinks the height to the viewport, not the top',
	predicted.width === 480 && predicted.height === 565 && predicted.top === 135);

viewWidth = 500;
const narrowed = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
check('a frame wider than the room shrinks to the fit room',
	narrowed.width === 390 && narrowed.left === 110);
viewWidth = 1000;

sandbox.windowNextTileSlot = function () { return 0; };
sandbox.windowTiledPendingApp = { clock: 'press-stamp' };
sandbox.windowTiledPending = { 'press-stamp': { slot: 3, stack: '0' } };
const reserved = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
check('a reservation this press already made is counted',
	reserved.left === 10 + 3 * 50 && reserved.top === 55 + 3 * 40);
sandbox.windowTiledPendingApp = {};
sandbox.windowTiledPending = {};

// the measured table: 1366x703, top limit 54, step = 44 - 2 = 42
sandbox.windowTiledAnchor = function () { return { left: 0, top: 54 }; };
sandbox.jawnosBars = { navbar: 44, border: 2 };
viewWidth = 1366;
viewHeight = 703;
const measured_table = [0, 1, 2, 3].map(function (slot) {
	sandbox.windowNextTileSlot = function () { return slot; };
	return sandbox.jawnosWindowEmergePredict({ app: 'clock' });
});
check('the measured 1366x703 table predicts the four real slots',
	measured_table[0].left === 0 && measured_table[0].top === 54
	&& measured_table[0].width === 480 && measured_table[0].height === 640
	&& measured_table[1].left === 50 && measured_table[1].top === 96
	&& measured_table[1].width === 480 && measured_table[1].height === 607
	&& measured_table[2].left === 100 && measured_table[2].top === 138
	&& measured_table[2].width === 480 && measured_table[2].height === 565
	&& measured_table[3].left === 150 && measured_table[3].top === 180
	&& measured_table[3].width === 480 && measured_table[3].height === 523);

// a display-zoomed desk: the press rect is reported zoomed, the ghost is laid
// out in the root's own units
rootZoom = 1.25;
const zoom_icon = startIcon('clock_toggle', 'clock', '/images/clock.png', 'Clock', 125, 250, 100, 50);
press(zoom_icon);
const zoom_ghost = sandbox.jawnosWindowEmergeGhost;
check('a zoomed press rectangle is put into layout units',
	!!zoom_ghost && zoom_ghost.el.animations[0].keys[0].left === '100px'
	&& zoom_ghost.el.animations[0].keys[0].top === '200px'
	&& zoom_ghost.el.animations[0].keys[0].width === '80px'
	&& zoom_ghost.el.animations[0].keys[0].height === '40px');
sandbox.jawnosWindowEmergeGhostCancel(zoom_ghost);
advance(5000);
rootZoom = 1;

// a pinned window's saved place: windowPlaceRestore's scale, edge keeping and
// 240x160 floors, then the same viewport clamp
sandbox.jawnos_app_places = {
	clock: { left: 100, top: 80, width: 500, height: 600, vw: 1000, vh: 1000 }
};
viewWidth = 500;
viewHeight = 500;
const pinned = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
check('a pinned place is scaled onto this screen',
	pinned.left === 50 && pinned.top === 40 && pinned.width === 250 && pinned.height === 300);
sandbox.jawnos_app_places = {
	clock: { left: 600, top: 700, width: 300, height: 200, vw: 1000, vh: 1000 }
};
const pinned_right = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
check('a place near the right and bottom keeps those edges',
	pinned_right.left === 160 && pinned_right.top === 240
	&& pinned_right.width === 240 && pinned_right.height === 160);
sandbox.jawnos_app_places = {
	clock: { left: 0, top: 0, width: 100, height: 100, vw: 1000, vh: 1000 }
};
const pinned_floor = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
check('a tiny saved box keeps the 240x160 floors',
	pinned_floor.width === 240 && pinned_floor.height === 160);
sandbox.jawnos_app_places = {};
sandbox.windowNextTileSlot = function () { return 0; };
const unpinned = sandbox.jawnosWindowEmergePredict({ app: 'notes' });
check('an app with no place still cascades',
	unpinned.left === 0 && unpinned.top === 54
	&& unpinned.width === 480 && unpinned.height === 446);

// a phone's pile steps by the bar's outer height less its border; the count is
// the windows already on the desk plus presses still in flight
phone = true;
viewWidth = 412;
viewHeight = 915;
sandbox.windowTopLimit = function () { return 0; };
sandbox.windowTiledAnchor = function () { return { left: 0, top: 0 }; };
sandbox.jawnosBars = { navbar: 44, border: 2 };
winds.length = 0;
sandbox.windowTiledPending = {};
const phone_0 = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
winds.push(new El('one'));
const phone_1 = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
winds.push(new El('two'));
const phone_2 = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
check('a phone preview still uses the layout viewport',
	phone_0.width === 412 && phone_0.height === 652);
check('the phone pile steps by vAdvance',
	phone_0.top === 0 && phone_1.top === 42 && phone_2.top === 84);
winds.length = 1;
sandbox.windowTiledPending = { pending: { stack: '0', at: Date.now(), slot: 0 } };
const phone_pending = sandbox.jawnosWindowEmergePredict({ app: 'clock' });
check('a press still waiting for its window takes the next step',
	phone_pending.top === 84);
phone = false;
winds.length = 0;
sandbox.windowTiledPending = {};
sandbox.jawnos_app_places = {};

sandbox.windowTiledAnchor = saved_anchor;
sandbox.windowNextTileSlot = saved_slot;
sandbox.jawnosBars = saved_bars;
sandbox.windowTopLimit = saved_top_limit;
viewWidth = 1200;
viewHeight = 900;

// --- a control's rectangle, its app and its picture --------------------------
const icon = startIcon('terminal_toggle', 'terminal', '/images/terminal.png', 'Terminal');
const icon_origin = sandbox.jawnosWindowOriginFromElement(icon);
check('a start-menu icon is filed under its app', icon_origin.app === 'terminal');
check('and its rectangle is the icon box', icon_origin.left === 10 && icon_origin.width === 40);
check('and it carries the icon and name into the preview',
	icon_origin.icon === '/images/terminal.png' && icon_origin.name === 'Terminal');

const tile = makeElement('SPAN', 'taskbar_pin taskbar_app_pin');
tile.setAttribute('app', 'music');
tile.setAttribute('hint', 'Music');
tile.style.left = '5px'; tile.style.top = '6px'; tile.style.width = '50px'; tile.style.height = '30px';
const tile_icon = makeElement('IMG', 'taskbar_app_pin_icon');
tile_icon.setAttribute('src', '/images/music.png');
tile.appendChild(tile_icon);
const tile_origin = sandbox.jawnosWindowOriginFromElement(tile);
check('a taskbar pin names its app itself', tile_origin.app === 'music');
check('and it carries its own icon and hint',
	tile_origin.icon === '/images/music.png' && tile_origin.name === 'Music');

const table = makeElement('TABLE');
table.id = 'app_switcher';
const cell = makeElement('TD', 'app');
cell.style.left = '30px'; cell.style.top = '40px'; cell.style.width = '60px'; cell.style.height = '60px';
const toggle = makeElement('SPAN', 'window_toggle');
toggle.setAttribute('app', 'notes');
toggle.setAttribute('formatted_name', 'Notes');
const toggle_icon = makeElement('IMG', 'window_toggle_icon');
toggle_icon.setAttribute('src', '/images/notes.png');
toggle.appendChild(toggle_icon);
cell.appendChild(toggle);
table.appendChild(cell);
const switch_origin = sandbox.jawnosWindowOriginFromElement(cell);
check('an app switcher cell names the window app', switch_origin.app === 'notes');
check('and it carries the tile icon and formatted name',
	switch_origin.icon === '/images/notes.png' && switch_origin.name === 'Notes');

// a canvas painter can hand over its own icon/name with the pill
const canvas_origin = sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'notes',
	{ icon: '/images/notes.png', name: 'Notes' });
check('a point origin can carry the preview metadata',
	canvas_origin.icon === '/images/notes.png' && canvas_origin.name === 'Notes');
sandbox.jawnosWindowOriginTake('notes', Date.now());

// --- the press-time preview --------------------------------------------------
level = 'medium';
sandbox.jawnos_app_colours = {
	clock: { colour: '#123456', dark: '#0a0a0a', ink: '#ffffff', dark_ink: '#ffffff' }
};
const press_icon = startIcon('clock_toggle', 'clock', '/images/clock.png', 'Clock');
press(press_icon);
const ghost = sandbox.jawnosWindowEmergeGhost;
check('pointerdown creates the preview at once', !!ghost && ghost.el.parentNode === body);
check('the preview is the body-level ghost',
	!!ghost && ghost.el.className === 'jawnos_emerge_ghost');
check('it starts at the pressed control',
	!!ghost && ghost.el.animations[0].keys[0].left === '10px'
	&& ghost.el.animations[0].keys[0].top === '20px'
	&& ghost.el.animations[0].keys[0].width === '40px');
check('and grows to the predicted cascade frame',
	!!ghost && ghost.el.animations[0].keys[1].left === '0px'
	&& ghost.el.animations[0].keys[1].top === '40px'
	&& ghost.el.animations[0].keys[1].width === '480px'
	&& ghost.el.animations[0].keys[1].height === '640px');
check('the preview growth follows the medium level',
	!!ghost && ghost.el.animations[0].options.duration === 280);
const chrome = !!ghost && findClass(ghost.el, 'jawnos_emerge_chrome');
check('the preview already wears a window chrome', !!chrome);
const bar = !!chrome && findClass(chrome, 'jawnos_emerge_bar');
check('with a title bar', !!bar);
const chrome_icon = !!chrome && findClass(chrome, 'jawnos_emerge_icon');
check('the pressed icon is drawn in the bar',
	!!chrome_icon && chrome_icon.getAttribute('src') === '/images/clock.png');
const chrome_name = !!chrome && findClass(chrome, 'jawnos_emerge_name');
check('and the app name', !!chrome_name && chrome_name.textContent === 'Clock');
const chrome_buttons = !!chrome && findClass(chrome, 'jawnos_emerge_buttons');
check('and the three standard controls',
	!!chrome_buttons && chrome_buttons.children.length === 3
	&& hasClass(chrome_buttons.children[0], 'jawnos_emerge_button_minimize')
	&& hasClass(chrome_buttons.children[1], 'jawnos_emerge_button_maximize')
	&& hasClass(chrome_buttons.children[2], 'jawnos_emerge_button_close'));
const bar_el = findClass(chrome, 'jawnos_emerge_bar');
check('the bar carries the real appointment-tint hook',
	!!bar_el && bar_el.getAttribute('data-appt-tint') === 'yes');
check('the bar wears the app\'s saved colour',
	!!bar_el && bar_el.style.backgroundColor === '#123456');
check('and its real contrast ink', !!bar_el && bar_el.style.color === '#ffffff');
const clock_body = findClass(chrome, 'jawnos_emerge_body_calendar');
check('the clock gets a calendar skeleton', !!clock_body && !!findClass(chrome, 'jawnos_emerge_calendar'));
check('the skeleton has no words', textIn(clock_body) === '');

check('the archetype map follows the app',
	sandbox.jawnosWindowEmergeArchetype('gallery') === 'grid'
	&& sandbox.jawnosWindowEmergeArchetype('music') === 'media'
	&& sandbox.jawnosWindowEmergeArchetype('travel') === 'map'
	&& sandbox.jawnosWindowEmergeArchetype('chat') === 'chat'
	&& sandbox.jawnosWindowEmergeArchetype('notes') === 'list'
	&& sandbox.jawnosWindowEmergeArchetype('mystery') === 'generic');
function archetype_chrome(app) { return sandbox.jawnosWindowEmergeChrome({ app: app, name: app }); }
const list_chrome = archetype_chrome('notes');
check('a list app gets rows, dot and lines',
	!!findClass(list_chrome, 'jawnos_emerge_body_list')
	&& !!findClass(list_chrome, 'jawnos_emerge_row')
	&& !!findClass(list_chrome, 'jawnos_emerge_dot')
	&& !!findClass(list_chrome, 'jawnos_emerge_line')
	&& textIn(findClass(list_chrome, 'jawnos_emerge_body')) === '');
const grid_chrome = archetype_chrome('gallery');
check('a gallery gets a grid of tiles',
	!!findClass(grid_chrome, 'jawnos_emerge_body_grid')
	&& !!findClass(grid_chrome, 'jawnos_emerge_tile'));
const media_chrome = archetype_chrome('music');
check('music gets a player skeleton',
	!!findClass(media_chrome, 'jawnos_emerge_body_media')
	&& !!findClass(media_chrome, 'jawnos_emerge_media_art')
	&& !!findClass(media_chrome, 'jawnos_emerge_media_bar'));
const map_chrome = archetype_chrome('travel');
check('travel gets a map skeleton',
	!!findClass(map_chrome, 'jawnos_emerge_body_map')
	&& !!findClass(map_chrome, 'jawnos_emerge_map_route'));
const chat_chrome = archetype_chrome('chat');
check('chat gets bubbles',
	!!findClass(chat_chrome, 'jawnos_emerge_body_chat')
	&& !!findClass(chat_chrome, 'jawnos_emerge_bubble'));
const generic_chrome = archetype_chrome('mystery');
check('an unknown app gets the neutral generic body',
	!!findClass(generic_chrome, 'jawnos_emerge_body_generic')
	&& !!findClass(generic_chrome, 'jawnos_emerge_block'));

// --- the real window takes the preview over ---------------------------------
const win = new El('clock');
win.rect = { left: 12, top: 44, width: 480, height: 640 };
check('the window takes the preview', sandbox.jawnosWindowEmerge(win) === true);
check('the real window fades in exactly once', win.animations.length === 1);
const retarget = ghost.el.animations[ghost.el.animations.length - 1];
check('the preview is retargeted, not snapped',
	retarget.keys.length === 3 && retarget.keys[2].left === '12px'
	&& retarget.keys[2].top === '44px' && retarget.keys[2].width === '480px');
check('the retarget follows the medium level', retarget.options.duration === 220);
check('the real window is faded over the same beat', win.animations[0].options.duration === 220);
const ghost_el = ghost.el;
advance(1000);
check('the preview is removed once the window owns the frame',
	ghost_el.parentNode === null && win.jawnosEmergeGhost === null);
check('and the window animation is put down', win.jawnosEmergeWindowAnim === null);

// a window measured mid-enter is at scale(0.985); the retarget must use its
// layout box, not 472.8x630.4, or the ghost lands 1.5% small
level = 'medium';
press(press_icon);
const scaled_ghost = sandbox.jawnosWindowEmergeGhost;
const scaled_ghost_el = scaled_ghost.el;
const enter_win = new El('clock');
enter_win.style.left = '12px';
enter_win.style.top = '44px';
enter_win.style.width = '480px';
enter_win.style.height = '640px';
enter_win.rect = { left: 12, top: 44, width: 472.8, height: 630.4 };
check('a window mid-enter still hands over its layout box',
	sandbox.jawnosWindowEmerge(enter_win) === true);
const enter_target = scaled_ghost.el.animations[scaled_ghost.el.animations.length - 1].keys[2];
check('the retarget lands on 480x640, not the 0.985 rect',
	enter_target.left === '12px' && enter_target.top === '44px'
	&& enter_target.width === '480px' && enter_target.height === '640px');
advance(1000);
check('the mid-enter preview is put away', scaled_ghost_el.parentNode === null);

// --- a press that opens nothing is put away ---------------------------------
level = 'medium';
press(press_icon);
const idle = sandbox.jawnosWindowEmergeGhost;
check('a second press starts a second preview', !!idle && idle.el.parentNode === body);
const idle_el = idle.el;
advance(3100);
check('the unsent preview is put away by its TTL',
	idle_el.parentNode === null && sandbox.jawnosWindowEmergeGhost === null);

// --- off, reduced motion and the effects switch -----------------------------
level = 'off';
press(press_icon);
check('off draws no preview', sandbox.jawnosWindowEmergeGhost === null);
level = 'medium';
reduced = true;
press(press_icon);
check('reduced motion draws no preview', sandbox.jawnosWindowEmergeGhost === null);
reduced = false;
effects_on = false;
press(press_icon);
check('the effects switch stops the preview', sandbox.jawnosWindowEmergeGhost === null);
effects_on = true;

// --- the level scales the growth and the retarget ---------------------------
const scales = {
	light: { ghost: 180, retarget: 140 },
	medium: { ghost: 280, retarget: 220 },
	maximum: { ghost: 400, retarget: 300 }
};
Object.keys(scales).forEach(function (name) {
	level = name;
	press(press_icon);
	const scaled = sandbox.jawnosWindowEmergeGhost;
	const scaled_el = scaled.el;
	check(name + ' scales the preview growth',
		!!scaled && scaled.el.animations[0].options.duration === scales[name].ghost);
	const scaled_win = new El('clock');
	scaled_win.rect = { left: 16, top: 48, width: 480, height: 640 };
	sandbox.jawnosWindowEmerge(scaled_win);
	const scaled_retarget = scaled.el.animations[scaled.el.animations.length - 1];
	check(name + ' scales the retarget',
		scaled_retarget.options.duration === scales[name].retarget);
	sandbox.jawnosWindowEmergeCancel(scaled_win);
	check(name + ' cleans the preview away',
		scaled_el.parentNode === null && sandbox.jawnosWindowEmergeGhost === null);
});

// --- closing or hiding a window takes its preview ---------------------------
level = 'medium';
press(press_icon);
const closing = sandbox.jawnosWindowEmergeGhost;
const closing_el = closing.el;
const close_win = new El('clock');
close_win.rect = { left: 12, top: 44, width: 480, height: 640 };
sandbox.jawnosWindowEmerge(close_win);
sandbox.jawnosWindowEmergeCancel(close_win);
check('a close or hide takes the preview with it',
	closing_el.parentNode === null && sandbox.jawnosWindowEmergeGhost === null);

// an opener can hide a window it did not ask to show, straight after the maker
const hidden_after = new El('hushed');
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'hushed');
check('the maker can start the fallback motion', sandbox.jawnosWindowEmerge(hidden_after) === true);
const hushed_sheet = created[created.length - 1];
hidden_after.getClientRects = function () { return []; };
advance(0);
check('a window hidden straight after takes its sheet with it',
	hidden_after.jawnosEmergeSheet === null && hushed_sheet.parentNode === null);

// --- the fallback sheet still plays -----------------------------------------
level = 'medium';
const win_fallback = new El('notes');
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'notes');
check('a window with an origin and no preview emerges',
	sandbox.jawnosWindowEmerge(win_fallback) === true);
check('the window fades in on its own geometry',
	win_fallback.animations.length === 1 && win_fallback.animations[0].options.duration === 240
	&& win_fallback.animations[0].options.delay === 90);
const sheet = created[created.length - 1];
check('the sheet is the pressed pill',
	sheet.className === 'jawnos_emerge_sheet' && sheet.style.left === '100px'
	&& sheet.style.top === '200px' && sheet.style.width === '80px' && sheet.style.height === '30px'
	&& sheet.style.borderRadius === '15px');
check('the sheet plays the medium stretch',
	sheet.animations.length === 1 && sheet.animations[0].options.duration === 340);
advance(1000);
check('the sheet is put away', win_fallback.jawnosEmergeSheet === null && sheet.parentNode === null);
check('and both animations are cancelled',
	sheet.animations[0].cancelled === 1 && win_fallback.animations[0].cancelled === 1);

level = 'off';
const off_win = new El('notes');
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'notes');
check('off does not animate', sandbox.jawnosWindowEmerge(off_win) === false && off_win.animations.length === 0);

level = 'medium';
reduced = true;
const calm_win = new El('clock');
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'clock');
check('reduced motion does not animate', sandbox.jawnosWindowEmerge(calm_win) === false && calm_win.animations.length === 0);
reduced = false;

const no_origin = new El('nothing');
check('no origin means no animation', sandbox.jawnosWindowEmerge(no_origin) === false);

sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'once');
const once_win = new El('once');
check('the first window takes the press', sandbox.jawnosWindowEmerge(once_win) === true);
const again_win = new El('once');
check('a second window does not reuse it', sandbox.jawnosWindowEmerge(again_win) === false);

const hidden_win = new El('hidden');
hidden_win.getClientRects = function () { return []; };
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'hidden');
check('a hidden window is left alone', sandbox.jawnosWindowEmerge(hidden_win) === false);

effects_on = false;
const off_desk = new El('desk');
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'desk');
check('the effects switch stops the motion', sandbox.jawnosWindowEmerge(off_desk) === false);
effects_on = true;

sandbox.jawnosWindowEmergeGhostCancel();
advance(5000);
process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/windows/06_emerge.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'the emerge captures, previews, retargets, scales by level and cleans up');
}

# --- and every touched script parses ----------------------------------------
if ($node && -x $node) {
	foreach my $file (qw(
		public/js/manager/windows/06_emerge.js
		public/js/manager/windows.js
		public/js/manager/leaderboardprinter.js
		public/js/manager/lazy.js
	)) {
		my $out = `$node --check "$root/$file" 2>&1`;
		my $rc = $? >> 8;
		diag($out) if $rc;
		is($rc, 0, "node --check accepts $file");
	}
}

done_testing();
