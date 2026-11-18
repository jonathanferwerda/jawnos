# tests-for: public/js/manager/windows/02_fit.js public/js/manager/windows.js public/js/manager/windows/03_stack.js public/css/manager.css
# covers:    a drag to either edge draws the half the window will take, from one
#            shared geometry, and a window dragged out of a half (or a maximize)
#            is re-anchored so it stays under the pointer instead of trailing it.
#            A snap's stretch is a transform, so the box the view is read from is
#            the window's style position, not the transformed rect. The band that
#            owns a drop is a short reach in from the edge, not a share of the
#            desk, and the highlight and the drop ask the same helper.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

my $root = repo_root();
my $fit     = read_file("$root/public/js/manager/windows/02_fit.js");
my $windows = read_file("$root/public/js/manager/windows.js");
my $stack   = read_file("$root/public/js/manager/windows/03_stack.js");
my $css     = read_file("$root/public/css/manager.css");

# --- one geometry for the snap and its highlight ----------------------------
like($fit, qr/function windowHalfRect\(side\)/, 'the half box is one helper');
like($fit, qr/var box = windowHalfRect\(to\);/, 'windowHalfski applies that box');
like($fit, qr/function windowHalfEdgeAt\(x\)/, 'the band that owns a drop is one helper');
like($fit, qr/var to = side \|\| windowHalfEdgeAt\(mouse\.x\)/, 'the drop asks the band');
like($fit, qr/var edge = windowHalfEdgeAt\(d\.x\) !== ''/, 'the drag stop asks the band');
like($windows, qr/windowHalfEdgeAt\(at\.x\)/, 'the highlight asks that same band');
like($fit, qr/var JAWNOS_HALF_EDGE = 32;/, 'the band is a short reach in from the edge');
unlike($fit, qr{ww \) / 10}, 'not a share of the desk (fit)');
unlike($windows, qr{ww \) / 10}, 'not a share of the desk (preview)');
like($windows, qr/var half = windowHalfRect\(edge\);/, 'the drag preview draws that same box');
like($windows, qr/box\.attr\('snap', 'half'\)/, 'marked so the highlight can read differently');
like($css, qr/#window_tile_preview\[snap="half"\] \{/, 'the half highlight is its own style');
like($css, qr/#window_tile_preview\[snap="half"\] \{[^}]*border-style: solid;/s, 'a solid edge rather than the slot hint');

# --- an edge no longer hides the preview ------------------------------------
unlike($windows, qr/if \(at\.x < \(ww \/ 10\) \|\| at\.x > \(ww - \(ww \/ 10\)\)\) \{ box\.hide\(\); return; \}/,
	'the edge branch no longer hides the outline');

# --- the restored window is re-anchored on the pointer ----------------------
like($fit, qr/var home_left = parseFloat\(win\.css\('left'\)\) \|\| 0;/, 'the old left is read before the resize');
like($fit, qr/var inst = win\.data\('ui-draggable'\);/, 'the live draggable is in reach');
like($fit, qr/inst\.offset\.click\.left \+= home_left - left;/, 'its grab anchor moves to the restored width');
like($fit, qr/'left': left \}\);/, 'the window is put under the pointer at once');
like($fit, qr/Math\.max\(0, Math\.min\(view_w - wide, left\)\)/, 'and the first frame is kept on the desk');

# --- the geometry itself, played in a bare context --------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to play the half box', 1 unless $node && -x $node;

	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
'use strict';
const fs = require('fs');
const vm = require('vm');

let bottom = 0;
let dock_search = false;
const windowStub = { width: 1920, height: 1080, visualViewport: null };
const documentStub = {};

function chain() {
	return {
		length: 0,
		on: function () { return this; },
		closest: function () { return { length: 0 }; },
		offset: function () { return { top: 0 }; },
		width: function () { return 0; },
		height: function () { return 0; }
	};
}
function $(sel) {
	if (sel === windowStub) {
		return {
			on: function () { return this; },
			width: function () { return windowStub.width; },
			height: function () { return windowStub.height; }
		};
	}
	if (sel === documentStub) { return chain(); }
	if (sel === '#search_entanglement') {
		return { closest: function () { return { length: dock_search ? 1 : 0 }; } };
	}
	if (sel === '#pseudonym_home') {
		return { length: dock_search ? 1 : 0, offset: function () { return { top: 900 }; } };
	}
	return chain();
}

const sandbox = {
	window: windowStub,
	document: documentStub,
	navigator: { userAgent: 'test' },
	$: $,
	setTimeout: setTimeout,
	clearTimeout: clearTimeout,
	console: console,
	headerHeight: 40,
	windowBottomClearance: function () { return bottom; }
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox);

let failures = 0;
function eq(name, got, want) {
	if (got !== want) { failures++; console.log('not ok - ' + name + ': ' + got + ' != ' + want); }
	else { console.log('ok - ' + name); }
}

let r = sandbox.windowHalfRect('left');
eq('the left half starts at the edge', r.left, 0);
eq('the half is half the desk wide', r.width, 960);
eq('it starts under the header', r.top, 40);
eq('it reaches the foot', r.height, 1040);
eq('and knows its side', r.side, 'left');

r = sandbox.windowHalfRect('right');
eq('the right half starts at the middle', r.left, 960);
eq('the right half is half the desk wide', r.width, 960);
eq('and knows its side', r.side, 'right');

// the band that turns a drop into the half: a short reach, so moving a window
// toward a side to sit nearer it is not read as asking for half the screen
eq('the band is a short reach in from the edge', sandbox.JAWNOS_HALF_EDGE, 32);
eq('the left edge is the left band', sandbox.windowHalfEdgeAt(8), 'left');
eq('a hand near the left edge is still the band', sandbox.windowHalfEdgeAt(30), 'left');
eq('a hand just inside the band is not', sandbox.windowHalfEdgeAt(33), '');
eq('a tenth of the desk in is not the band', sandbox.windowHalfEdgeAt(192), '');
eq('the middle is not the band', sandbox.windowHalfEdgeAt(960), '');
eq('a tenth in from the right is not the band', sandbox.windowHalfEdgeAt(1728), '');
eq('the right edge is the right band', sandbox.windowHalfEdgeAt(1912), 'right');
eq('a hand 33 in from the right is not', sandbox.windowHalfEdgeAt(1887), '');
eq('a phone or a missing point is no band', sandbox.windowHalfEdgeAt(null), '');

bottom = 50;
r = sandbox.windowHalfRect('left');
eq('a bottom bar shortens the half', r.height, 990);

// with the search riding a bottom dock, the foot stops at the dock's top
bottom = 0;
dock_search = true;
sandbox.jawnosDockTop = function () { return false; };
sandbox.jawnosSideDock = function () { return false; };
sandbox.jawnosDockHidden = function () { return false; };
r = sandbox.windowHalfRect('right');
eq('the dock top is the foot when the search rides it', r.height, 860);

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/windows/02_fit.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'windowHalfRect draws the box the window will take');
}

# --- an effect's transform cannot change the view a window wears ------------
# The snap's stretch is a scale, and offset() is the transformed rect: its first
# frame read an 800-wide half as a shifted free window, so windowDimensionSetter
# wrote the half box over free_dimensions and the drag out of a half had nothing
# left to restore. The view is classified on the style box, which no transform
# touches.
like($stack, qr/var off = w\.offset\(\);/, 'the setter still reads the live offset');
like($stack, qr/if \(!off\) \{ return; \}/, 'a hidden window has no box to measure and keeps its view');
like($stack, qr/var top = parseFloat\(w\.css\('top'\)\);/, 'the top is the style position');
like($stack, qr/var left = parseFloat\(w\.css\('left'\)\);/, 'and the left is too');
like($stack, qr/if \(isNaN\(top\)\) \{ top = off\.top; \}/, 'a style position that is not a length falls back to offset');
like($stack, qr/if \(isNaN\(left\)\) \{ left = off\.left; \}/, 'both edges fall back');

# --- the classification, played against a stretched box --------------------
SKIP: {
	skip 'node is needed to play the dimension setter', 1 unless $node && -x $node;

	my ($sfh, $setter_harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $sfh <<'JS';
'use strict';
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync(process.argv[2], 'utf8');

// 1600 wide: a half is 800 at 0 or 800, its foot under an empty header.
const windowStub = { width: 1600, height: 1000 };

function El(attrs, style, offset) {
	this.length = 1;
	this.attrs = attrs || {};
	this.style = style || {};
	this.off = offset;
}
El.prototype.attr = function (k, v) {
	if (v === undefined) { return this.attrs[k]; }
	this.attrs[k] = v;
	return this;
};
El.prototype.css = function (k) {
	return (this.style[k] === undefined) ? '' : String(this.style[k]);
};
El.prototype.width = function () { return parseFloat(this.style.width) || 0; };
El.prototype.height = function () { return parseFloat(this.style.height) || 0; };
El.prototype.offset = function () { return this.off; };

function chain() {
	return { on: function () { return this; }, width: function () { return 0; }, height: function () { return 0; } };
}
function $(sel) {
	if (sel === windowStub) {
		return { on: function () { return this; }, width: function () { return windowStub.width; }, height: function () { return windowStub.height; } };
	}
	return chain();
}

const sandbox = {
	window: windowStub,
	document: {},
	$: $,
	JSON: JSON,
	Math: Math,
	Date: Date,
	console: console,
	windowPhoneChecker: function () { return false; },
	reservedSpots: { header: 0 },
	clothesLinePos: { exists: 0 },
	clothesLineHeight: 0
};
vm.createContext(sandbox);
vm.runInContext(source, sandbox);

let failures = 0;
function eq(name, got, want) {
	if (got === want) { console.log('ok - ' + name); }
	else { failures++; console.log('not ok - ' + name + ': ' + got + ' != ' + want); }
}

// scale(.93,.96) around the middle: the half's 0/44 box measures as 28/60.
let w = new El({ view: 'left', free_dimensions: '{"width":480,"height":640}' },
	{ left: '0px', top: '44px', width: '800px', height: '798px' }, { left: 28, top: 60 });
sandbox.windowDimensionSetter(w);
eq('a stretched left half stays the left half', w.attrs.view, 'left');
eq('and its last free box is not overwritten', w.attrs.free_dimensions, '{"width":480,"height":640}');

w = new El({ view: 'right' },
	{ left: '800px', top: '44px', width: '800px', height: '798px' }, { left: 828, top: 60 });
sandbox.windowDimensionSetter(w);
eq('a stretched right half stays the right half', w.attrs.view, 'right');

// a free window is recorded from its style box, not the transformed rect
w = new El({ view: '' },
	{ left: '200px', top: '100px', width: '480px', height: '640px' }, { left: 228, top: 116 });
sandbox.windowDimensionSetter(w);
eq('a free window is measured by its style box', w.attrs.free_dimensions,
	'{"width":480,"height":640,"top":100,"left":200,"vw":1600,"vh":1000}');

// a hidden window has no offset at all: it keeps the view and the box it has
w = new El({ view: 'left', free_dimensions: '{"width":480,"height":640}' },
	{ left: '0px', top: '44px', width: '800px', height: '798px' }, undefined);
sandbox.windowDimensionSetter(w);
eq('a hidden window keeps its view', w.attrs.view, 'left');
eq('and its saved box', w.attrs.free_dimensions, '{"width":480,"height":640}');

process.exit(failures ? 1 : 0);
JS
	close $sfh;

	my $setter_out = `$node "$setter_harness" "$root/public/js/manager/windows/03_stack.js" 2>&1`;
	my $setter_rc = $? >> 8;
	diag($setter_out) if $setter_rc;
	is($setter_rc, 0, 'a transform does not change the half a window wears');
}

# --- a bar change re-fits the window that owns the foot ---------------------
# The dock's Transparent row and a bars pass both call one helper, which re-fits
# only a visible half or maximized window through the helper that placed it, and
# leaves a window whose foot is already right alone.
like($fit, qr/function windowMaxRect\(\)/, 'the maximized box is one helper');
like($fit, qr/var box = windowMaxRect\(\);/, 'the maximizer applies that box');
like($fit, qr/function jawnosWindowFootApply\(\)/, 'a bar change has one re-fit');
like($fit, qr/if \(view != 'max' && view != 'left' && view != 'right'\) \{ return; \}/,
	'only a half or a maximize owns the foot');
like($fit, qr/if \(!win\.is\(':visible'\) \|\| win\.hasClass\('window_full_viewport'\)\) \{ return; \}/,
	'a hidden or whole-glass window keeps its box');
like($fit, qr/windowMaximizer\(win\.attr\('timestamp'\), win\.attr\('app'\)\)/,
	'a maximized window takes its box again');
like($fit, qr/else \{ windowHalfski\(win, view\); \}/, 'a half takes its box again');

SKIP: {
	skip 'node is needed to play the foot re-fit', 1 unless $node && -x $node;

	my ($ffh, $foot_harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $ffh <<'JS';
'use strict';
const fs = require('fs');
const vm = require('vm');

function El(opts) {
	this.length = 1;
	this.attrs = { view: opts.view, timestamp: opts.timestamp || '7', app: opts.app || 'app' };
	this.visible = opts.visible !== false;
	this.full = !!opts.full;
	this[0] = { style: { height: opts.height } };
}
El.prototype.attr = function (k, v) {
	if (v === undefined) { return this.attrs[k]; }
	this.attrs[k] = v;
	return this;
};
El.prototype.is = function () { return this.visible; };
El.prototype.hasClass = function () { return this.full; };

const windows = [];
function $(sel) {
	if (sel === '.wind') {
		return {
			length: windows.length,
			each: function (fn) { windows.forEach(function (w, i) { fn.call(w, i, w); }); }
		};
	}
	if (sel instanceof El) { return sel; }
	return { length: 0, on: function () { return this; }, closest: function () { return this; } };
}

const calls = { max: [], half: [] };
const sandbox = {
	window: { width: 1600, height: 1000 },
	document: {},
	$: $,
	Math: Math,
	JSON: JSON,
	console: console,
	windowPhoneChecker: function () { return false; },
	reservedSpots: { header: 0 },
	clothesLinePos: { exists: 0 },
	clothesLineHeight: 0
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox);

// stand in for the two appliers, so a call is visible and the box it writes is
// the box the next pass must read
sandbox.windowMaxRect = function () { return { height: '1000px' }; };
sandbox.windowHalfRect = function (view) { return { height: view == 'left' ? 960 : 970 }; };
sandbox.windowMaximizer = function (ts, app) {
	calls.max.push(ts + '/' + app);
	windows.forEach(function (w) {
		if (w.attrs.timestamp == ts && w.attrs.app == app && w.attrs.view == 'max') { w[0].style.height = '1000px'; }
	});
};
sandbox.windowHalfski = function (w, view) {
	calls.half.push(view);
	w[0].style.height = (view == 'left') ? '960px' : '970px';
};

let failures = 0;
function eq(name, got, want) {
	if (got === want) { console.log('ok - ' + name); }
	else { failures++; console.log('not ok - ' + name + ': ' + got + ' != ' + want); }
}

windows.push(
	new El({ view: 'max', height: '940px' }),
	new El({ view: 'max', height: '1000px' }),
	new El({ view: 'left', height: '900px' }),
	new El({ view: 'right', height: '970px' }),
	new El({ view: '', height: '500px' }),
	new El({ view: 'left', height: '900px', visible: false }),
	new El({ view: 'left', height: '900px', full: true }),
	new El({ view: 'minimized', height: '900px' })
);

sandbox.jawnosWindowFootApply();
eq('the stale maximize takes its box again', calls.max.join(','), '7/app');
eq('and only the stale half does', calls.half.join(','), 'left');

calls.max = [];
calls.half = [];
sandbox.jawnosWindowFootApply();
eq('a second pass changes nothing', calls.max.length + calls.half.length, 0);

process.exit(failures ? 1 : 0);
JS
	close $ffh;

	my $foot_out = `$node "$foot_harness" "$root/public/js/manager/windows/02_fit.js" 2>&1`;
	my $foot_rc = $? >> 8;
	diag($foot_out) if $foot_rc;
	is($foot_rc, 0, 'a bar change re-fits the half and the maximize');
}

done_testing();
