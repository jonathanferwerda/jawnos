# tests-for: public/js/manager/windows/06_emerge.js public/js/manager/windows.js public/js/manager/leaderboardprinter.js public/js/manager/lazy.js public/css/manager.css
# covers:    a new window pours out of the control that opened it - the press
#            records a viewport rectangle and richer app metadata, pointerdown
#            draws the chrome preview at once, windowMaker hands the real
#            rectangle over, and the preview is retargeted or put away. Also
#            the pile preview exception for a drag carrying its pile.

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
like($lazy, qr/jawnosWindowOriginFromElement\(target\[0\], app\); \}\s*target\.trigger\('click'\)/,
	'the lazy replay stamps the origin again before the click');

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
like($emerge, qr/jawnosWindowEffectsLevel/, 'the level is read when it exists');
like($emerge, qr/prefers-reduced-motion/, 'reduced motion is honoured');
unlike($emerge, qr/\bgetContext\s*\(/, 'no canvas or WebGL context is created');
unlike($emerge, qr/\.filter\s*=/, 'no filter animation');

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
	if (x === sandboxDocument) {
		return { length: 1, on: function (ev, fn) { handlers[ev] = fn; } };
	}
	if (x && x.nodeType === 1) { return wrap(x); }
	return { length: 0 };
}

let effects_on = true;
let reduced = false;
let level = 'medium';

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
	windowTileDefaultWidth: 480,
	windowTileDefaultHeight: 640,
	windowTiledDefaultStack: '0',
	windowTiledAnchor: function () { return { left: 0, top: 40 }; },
	windowNextTileSlot: function () { return 0; },
	windowTopLimit: function () { return 40; }
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
