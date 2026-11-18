# tests-for: public/js/manager/windows/06_emerge.js public/js/manager/windows.js public/js/manager/leaderboardprinter.js public/js/manager/lazy.js public/css/manager.css
# covers:    a new window pours out of the control that opened it - the press
#            records a viewport rectangle, windowMaker hands it over once, and a
#            fixed sheet plus the window's own fade-in play it. Also the pile
#            preview exception for a drag carrying its pile.

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
like($board, qr/jawnosWindowOriginFromPoint[\s\S]{0,900}appointmentGrabber\(o\[4\]\['name'\],timestamp\)/,
	'the canvas pill records its rectangle before the opener');
like($lazy, qr/jawnosWindowOriginFromElement\(target\[0\], app\); \}\s*target\.trigger\('click'\)/,
	'the lazy replay stamps the origin again before the click');

# --- the sheet and its constraints -------------------------------------------
like($css, qr/\.jawnos_emerge_sheet\s*\{[^}]*position:\s*fixed[^}]*z-index:\s*2147482890[^}]*pointer-events:\s*none/s,
	'the sheet is fixed, click-through and above the windows');
like($css, qr/\@media \(prefers-reduced-motion: reduce\) \{\s*\.jawnos_emerge_sheet \{ display: none; \}\s*\}/s,
	'reduced motion also hides a sheet already in flight');
ok(index($css, '.jawnos_emerge_sheet') > index($css, '@keyframes jawnos_window_lock'),
	'the emerge styles are appended after the class effects');

# --- the implementation stays on the plan ------------------------------------
like($emerge, qr/function jawnosWindowOriginFromElement\(/, 'a DOM control can be captured');
like($emerge, qr/function jawnosWindowOriginFromPoint\(/, 'a canvas pill can be captured');
like($emerge, qr/function jawnosWindowOriginTake\(/, 'the press is taken once');
like($emerge, qr/function jawnosWindowEmergeKeyframes\(/, 'the shape is pure geometry');
like($emerge, qr/function jawnosWindowEmergeCssRect\(/, 'a zoomed rectangle is put back into layout units');
like($emerge, qr/function jawnosWindowEmerge\(win, origin\)/, 'the motion takes the window and an origin');
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

function wrap(el) {
	return {
		jquery: 1, length: 1, 0: el,
		attr: function (name) { return (el && el[name] !== undefined) ? el[name] : ((el && el.app) || ''); }
	};
}
function $(x) {
	if (x && x.jquery) { return x; }
	if (x && x.nodeType === 1) { return wrap(x); }
	return { length: 0 };
}

function animated(owner) {
	const a = {
		owner: owner, keys: null, options: null, cancelled: 0,
		cancel: function () { this.cancelled = 1; }
	};
	return a;
}

function El(app) {
	this.nodeType = 1;
	this.tagName = 'DIV';
	this.app = app || '';
	this.rect = { left: 300, top: 100, width: 400, height: 300 };
	this.animations = [];
}
El.prototype.getBoundingClientRect = function () { return this.rect; };
El.prototype.getClientRects = function () { return [this.rect]; };
El.prototype.animate = function (keys, options) {
	const a = animated(this);
	a.keys = keys; a.options = options;
	this.animations.push(a);
	return a;
};

function Sheet() {
	this.nodeType = 1;
	this.tagName = 'DIV';
	this.className = '';
	this.style = {};
	this.parentNode = null;
	this.animations = [];
}
Sheet.prototype.animate = function (keys, options) {
	const a = animated(this);
	a.keys = keys; a.options = options;
	this.animations.push(a);
	return a;
};

const created = [];
const body = {
	appendChild: function (el) { el.parentNode = body; },
	removeChild: function (el) { el.parentNode = null; }
};
const sandboxDocument = {
	createElement: function () { const s = new Sheet(); created.push(s); return s; },
	body: body
};

let effects_on = true;
let reduced = false;

const sandbox = {
	$, setTimeout: fakeSetTimeout, clearTimeout: fakeClearTimeout, console,
	document: sandboxDocument,
	window: { matchMedia: function () { return { matches: reduced }; } },
	startMenuIconApps: { terminal_toggle: 'terminal' },
	jawnosWindowEffectsOn: function () { return effects_on; }
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox);

let failures = 0;
function check(name, cond) {
	if (!cond) { failures++; console.log('not ok - ' + name); }
	else { console.log('ok - ' + name); }
}

// --- levels, defaults and the pure shapes -----------------------------------
check('the level defaults to medium when 05_effects has no reader',
	sandbox.jawnosWindowEmergeLevel() === 'medium');

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

// --- a control's rectangle and its app ---------------------------------------
const icon = {
	nodeType: 1, tagName: 'IMG', id: 'terminal_toggle',
	getAttribute: function () { return null; },
	closest: function () { return null; },
	querySelector: function () { return null; },
	getBoundingClientRect: function () { return { left: 10, top: 20, width: 40, height: 40 }; }
};
const icon_origin = sandbox.jawnosWindowOriginFromElement(icon);
check('a start-menu icon is filed under its app', icon_origin.app === 'terminal');
check('and its rectangle is the icon box', icon_origin.left === 10 && icon_origin.width === 40);

const tile = {
	nodeType: 1, tagName: 'SPAN', id: '',
	getAttribute: function (n) { return n === 'app' ? 'music' : null; },
	closest: function () { return null; },
	querySelector: function () { return null; },
	getBoundingClientRect: function () { return { left: 5, top: 6, width: 50, height: 30 }; }
};
check('a taskbar tile names its app itself', sandbox.jawnosWindowOriginFromElement(tile).app === 'music');

// --- the motion itself -------------------------------------------------------
sandbox.jawnosWindowEffectsLevel = function () { return level; };
let level = 'medium';

const win = new El('notes');
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'notes');
check('a window with an origin emerges', sandbox.jawnosWindowEmerge(win) === true);
check('the window fades in on its own geometry',
	win.animations.length === 1 && win.animations[0].options.duration === 240 && win.animations[0].options.delay === 90);
const sheet = created[created.length - 1];
check('the sheet is the pressed pill',
	sheet.className === 'jawnos_emerge_sheet' && sheet.style.left === '100px'
	&& sheet.style.top === '200px' && sheet.style.width === '80px' && sheet.style.height === '30px'
	&& sheet.style.borderRadius === '15px');
check('the sheet plays the medium stretch',
	sheet.animations.length === 1 && sheet.animations[0].options.duration === 340);
const emerged = win;
advance(1000);
check('the sheet is put away', emerged.jawnosEmergeSheet === null && sheet.parentNode === null);
check('and both animations are cancelled',
	sheet.animations[0].cancelled === 1 && emerged.animations[0].cancelled === 1);

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

// an opener can hide a window it did not ask to show, straight after the maker
const hidden_after = new El('hushed');
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'hushed');
check('the maker can start the motion', sandbox.jawnosWindowEmerge(hidden_after) === true);
const hushed_sheet = created[created.length - 1];
hidden_after.getClientRects = function () { return []; };
advance(0);
check('a window hidden straight after takes its sheet with it',
	hidden_after.jawnosEmergeSheet === null && hushed_sheet.parentNode === null);

effects_on = false;
const off_desk = new El('desk');
sandbox.jawnosWindowOriginFromPoint(140, 215, 80, 30, 15, 'desk');
check('the effects switch stops the motion', sandbox.jawnosWindowEmerge(off_desk) === false);

advance(1000);
process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/windows/06_emerge.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'the emerge captures, plays, scales by level and cleans up');
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
