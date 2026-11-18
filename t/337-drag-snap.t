# tests-for: public/js/manager/windows/02_fit.js public/js/manager/windows.js public/css/manager.css
# covers:    a drag to either edge draws the half the window will take, from one
#            shared geometry, and a window dragged out of a half (or a maximize)
#            is re-anchored so it stays under the pointer instead of trailing it.

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
my $css     = read_file("$root/public/css/manager.css");

# --- one geometry for the snap and its highlight ----------------------------
like($fit, qr/function windowHalfRect\(side\)/, 'the half box is one helper');
like($fit, qr/var box = windowHalfRect\(to\);/, 'windowHalfski applies that box');
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

done_testing();
