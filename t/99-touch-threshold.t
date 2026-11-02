# tests-for: public/js/touch-threshold.js
# covers:    the touch threshold - a tap still clicks, a real drag stops it

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Slurp qw(write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# Stock jQuery UI Touch Punch calls any touchmove a drag, so a finger that moved
# a pixel or two while tapping lost the click: the buttons stopped answering.
# touch-threshold.js keeps the shim but only counts travel past 12px as a drag.
# The behaviour is all that matters here - below the threshold the page must not
# move and the click must survive; past it the drag must begin.

my $root = "$FindBin::Bin/..";
my $unit = "$root/public/js/touch-threshold.js";

plan skip_all => 'node is not installed' unless `command -v node 2>/dev/null`;

my $dir = tempdir(CLEANUP => 1);
write_file("$dir/harness.js", <<'JS');
const fs = require('fs');

// The page the shim checks for, and a jQuery with just enough UI to patch.
global.document = { ontouchend: null };
const proto = {};
proto._touchStart = function () { this.started = true; };
proto._touchMove  = function () { this._touchMoved = true; };
proto._touchEnd   = function () { return this._touchMoved ? 'drag' : 'click'; };

function jQuery() {}
jQuery.ui = { mouse: { prototype: proto } };
global.jQuery = jQuery;

require(process.argv[2]);

function touch(x, y) {
	const event = {
		originalEvent: { changedTouches: [{ clientX: x, clientY: y }] },
		prevented: false,
		preventDefault() { this.prevented = true; },
	};
	return event;
}

const state = {};
proto._touchStart.call(state, touch(10, 10));

// 2px of travel is a tap, not a drag.
const small = touch(12, 11);
proto._touchMove.call(state, small);
console.log('small_prevented=' + small.prevented);
console.log('small_dragging=' + (state._touchMoved === true));

// 30px is a real drag.
const big = touch(40, 10);
proto._touchMove.call(state, big);
console.log('big_prevented=' + big.prevented);
console.log('big_dragging=' + (state._touchMoved === true));

// A second gesture starts clean: the origin is forgotten on touchend.
proto._touchEnd.call(state, touch(40, 10));
const again = touch(12, 11);
const fresh = {};
proto._touchStart.call(fresh, touch(10, 10));
proto._touchMove.call(fresh, again);
console.log('fresh_prevented=' + again.prevented);
JS

my $err = gensym;
my $pid = open3(my $in, my $out, $err, 'node', "$dir/harness.js", $unit);
close $in;
local $/;
my $stdout = <$out> // '';
my $stderr = <$err> // '';
waitpid($pid, 0);

is($? >> 8, 0, 'the shim loads and runs against a stand-in jQuery') or diag($stderr);
like($stdout, qr/^small_prevented=true$/m, 'a tap holds the page still');
like($stdout, qr/^small_dragging=false$/m, 'and does not start a drag');
like($stdout, qr/^big_prevented=false$/m, 'a real drag lets Touch Punch move the element');
like($stdout, qr/^big_dragging=true$/m, 'and does start the drag');
like($stdout, qr/^fresh_prevented=true$/m, 'the next gesture starts from its own origin');

done_testing();
