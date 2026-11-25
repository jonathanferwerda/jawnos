# tests-for: public/js/manager/studio.js public/js/manager/studio/06_controls.js
# covers:    An engine take arms its live input only when a track is actually
#            monitored. A stale app-wide Monitor setting left at "yes" must not
#            turn a Monitor-off recording into a dry monitored one. This runs
#            studioEngineStartNow in node with the AJAX call captured, so the
#            request body is checked directly.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempfile);
use Cwd qw(abs_path);

my $root = abs_path("$FindBin::Bin/..");

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
plan skip_all => 'node is not installed; the take request cannot be executed'
	unless $node && -x $node;

my $studio = "$root/public/js/manager/studio.js";
my $controls = "$root/public/js/manager/studio/06_controls.js";
ok(-f $studio, 'the studio index is found');
ok(-f $controls, 'the controls part is found');

my ($fh, $script) = tempfile(SUFFIX => '.js', UNLINK => 1);
print $fh <<'JS';
var fs = require('fs');
var vm = require('vm');
var captured = [];
var values = {
	'#studio_engine_seconds': '10',
	'#studio_engine_tracks': '1',
	'#studio_engine_inputs': '0',
	'#studio_engine_inserts': ''
};

function fake(sel) {
	var f = function () { return f; };
	f.on = function () { return f; };
	f.each = function () { return f; };
	f.val = function (v) {
		if (arguments.length) { values[sel] = v; return f; }
		return values[sel];
	};
	f.attr = function () { return undefined; };
	f.text = function () { return ''; };
	f.is = function () { return false; };
	f.length = 0;
	f.find = f.closest = f.append = f.appendTo = f.hide = f.show = f.css = function () { return f; };
	f.addClass = f.removeClass = f.toggleClass = f.prop = function () { return f; };
	return f;
}
var jq = function (sel) { return fake(sel); };
jq.each = function (obj, fn) { if (obj) { for (var k in obj) { fn(k, obj[k]); } } };
jq.extend = function (a, b) { for (var k in b) { a[k] = b[k]; } return a; };
jq.ajax = function (opts) { captured.push(opts.data); return {}; };

var sandbox = {
	$: jq,
	jQuery: jq,
	document: {
		getElementById: function () { return null; },
		createElement: function () { return { style: {}, classList: { add: function () {}, remove: function () {} } }; },
		addEventListener: function () {},
		querySelector: function () { return null; },
		hidden: true
	},
	console: console,
	setTimeout: function () { return 0; },
	clearTimeout: function () {},
	setInterval: function () { return 0; },
	clearInterval: function () {},
	performance: { now: function () { return 0; } },
	numeral: function (v) { return { value: function () { var n = parseFloat(v); return isNaN(n) ? null : n; } }; },
	studioAudio: { channels: {}, ctx: null },
	studioKnobNumber: function (v, fallback) {
		var n = parseFloat(v);
		return (n === null || n === undefined || isNaN(n)) ? fallback : n;
	},
	studioAudioLabel: function (text) { return text; }
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox, { filename: 'studio.js' });
vm.runInContext(fs.readFileSync(process.argv[3], 'utf8'), sandbox, { filename: '06_controls.js' });

function requestFor(monitor) {
	captured.length = 0;
	sandbox.mixer = {
		time: { metronome: 'no', monitor: 'yes', engine_transport: false, position: 0 },
		monitor: monitor,
		admin: { master: [] }
	};
	sandbox.studioEngineStartNow();
	return captured.length ? captured[0] : null;
}

function ok(cond, message) {
	if (!cond) { console.log('FAIL ' + message); process.exit(1); }
}

// Monitor off, but the stale app-wide seed still says yes: no live input.
var off = requestFor({});
ok(off, 'the Monitor-off take made a request');
ok(off.monitor_input === 'false', 'Monitor off sends monitor_input false (got ' + off.monitor_input + ')');

// One track monitored: the take's live input is armed.
var on = requestFor({ 1: 1 });
ok(on, 'the Monitor-on take made a request');
ok(on.monitor_input === 'true', 'Monitor on sends monitor_input true (got ' + on.monitor_input + ')');

console.log('ok');
JS
close $fh;

my $out = `$node $script $studio $controls 2>&1`;
my $rc = $? >> 8;
is($rc, 0, 'the take request runs') or diag($out);
like($out, qr/^ok$/m, 'both Monitor states send the right request');

done_testing();
