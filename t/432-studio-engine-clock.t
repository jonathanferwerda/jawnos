# tests-for: public/js/manager/studio/01_transport.js public/js/manager/studio/11_drums.js
# covers:    The engine's transport is projected onto the page's audio clock
#            between status polls: the socket round trip and the two output
#            latencies are removed, the ratio of the two clocks is measured and
#            smoothed, a loop wrap lands on the loop in-point, and the drum
#            scheduler, a recorded pad hit and the lit column all read that one
#            position. This runs the real functions in node with only the page's
#            browser globals stubbed.

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
plan skip_all => 'node is not installed; the clock projection cannot be executed'
	unless $node && -x $node;

my $transport = "$root/public/js/manager/studio/01_transport.js";
my $drums = "$root/public/js/manager/studio/11_drums.js";
ok(-f $transport, 'the transport part is found');
ok(-f $drums, 'the drum part is found');

my ($fh, $script) = tempfile(SUFFIX => '.js', UNLINK => 1);
print $fh <<'JS';
var fs = require('fs');
var vm = require('vm');

function fake() {
	var f = function () { return f; };
	f.on = function () { return f; };
	f.each = function (obj, fn) {
		if (obj) { for (var k in obj) { fn(k, obj[k]); } }
		return f;
	};
	f.val = f.attr = function () { return undefined; };
	f.text = function () { return ''; };
	f.length = 0;
	f.find = f.closest = f.append = f.appendTo = f.hide = f.show = f.css = function () { return f; };
	f.addClass = f.removeClass = f.toggleClass = f.is = f.prop = function () { return f; };
	return f;
}
var jq = function () { return fake(); };
jq.each = function (obj, fn) { if (obj) { for (var k in obj) { fn(k, obj[k]); } } };
jq.extend = function (a, b) { for (var k in b) { a[k] = b[k]; } return a; };
jq.ajax = function () { return {}; };

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
	numeral: function (v) {
		return { value: function () { var n = parseFloat(v); return isNaN(n) ? null : n; } };
	},
	studioAudio: { ctx: { currentTime: 10, sampleRate: 48000, outputLatency: 0.02 }, playSeg: null },
	mixer: { time: { engine_transport: true, position: 0, bpm: 120, status: 'play' } },
	studioKnobNumber: function (v, fallback) {
		var n = parseFloat(v);
		return (n === null || n === undefined || isNaN(n)) ? fallback : n;
	},
	studioAudioLabel: function (text) { return text; },
	studioTimeAt: function (pos, p0, ctx0) { return ctx0 + (pos - p0); }
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox, { filename: '01_transport.js' });
vm.runInContext(fs.readFileSync(process.argv[3], 'utf8'), sandbox, { filename: '11_drums.js' });

function near(got, want, eps, message) {
	if (!(Math.abs(got - want) <= eps)) {
		console.log('FAIL ' + message + ': got ' + got + ', want ' + want);
		process.exit(1);
	}
}
function ok(cond, message) {
	if (!cond) { console.log('FAIL ' + message); process.exit(1); }
}

// A sample is projected to the moment it was taken, not the reply.
sandbox.studioAudio.ctx.currentTime = 10;
sandbox.studioEngineClockSet(5, 10, 0, 0, 0.005);
near(sandbox.studioEngineClockNow(), 5.005, 1e-9, 'the sample is projected');
sandbox.studioAudio.ctx.currentTime = 10.5;
near(sandbox.studioEngineClockNow(), 5.505, 1e-9, 'the clock advances between polls');

// A measured 2% fast engine clock is smoothed into the ratio and applied.
sandbox.studioEngineClock.rate = 1;
sandbox.studioEngineClockSet(5.50, 10.5, 0, 0, 0.005);
sandbox.studioEngineClockSet(6.01, 11.0, 0, 0, 0.005);
near(sandbox.studioEngineClock.rate, 1.005, 1e-9, 'the ratio is smoothed');
sandbox.studioAudio.ctx.currentTime = 11.5;
near(sandbox.studioEngineClockNow(), 6.01 + 0.5 * 1.005 + 0.005, 1e-9, 'the ratio is applied');

// A loop wrap lands on the in-point instead of running past the end.
sandbox.studioEngineClock.rate = 1;
sandbox.studioEngineClockSet(1.9, 20, 0, 2, 0);
sandbox.studioAudio.ctx.currentTime = 20.3;
near(sandbox.studioEngineClockNow(), 0.2, 1e-9, 'the projection wraps at the loop');

// The drums, a recorded hit and the lit column read the one position.
sandbox.studioDrums.running = true;
sandbox.studioDrums.stepDur = 0.125;
sandbox.mixer.time.engine_transport = true;
sandbox.mixer.time.position = 0;
near(sandbox.studioDrumsSongPosition(), 0.2, 1e-9, 'the drums read the projected clock');
ok(sandbox.studioDrumsCurrentStep() === 1, 'the recorded step follows the projected clock');

// Without the engine the browser's own segment is still the source.
sandbox.mixer.time.engine_transport = false;
sandbox.studioAudio.ctx.currentTime = 30;
sandbox.studioAudio.playSeg = { pos0: 4, ctx0: 29.5 };
near(sandbox.studioDrumsPosition(), 4.5, 1e-9, 'the browser segment is the fallback');

// The scheduler places a Browser drum on the engine's clock even when the
// browser's own segment is 50 ms off it: the two clocks are one.
sandbox.mixer.time.engine_transport = true;
sandbox.mixer.time.loop = 'off';
sandbox.mixer.time.duration = 0;
sandbox.mixer.time.status = 'play';
sandbox.mixer.time.bpm = 120;
sandbox.mixer.time.position = 0;
sandbox.studioLoopRegion = function () { return null; };
sandbox.studioAudio.ctx.currentTime = 30.15;
sandbox.studioAudio.playSeg = { pos0: 4.95, ctx0: 30.0 };
sandbox.studioEngineClock.rate = 1;
sandbox.studioEngineClockSet(5.0, 30.1, 0, 0, 0);
sandbox.studioDrums.sound = 'browser';
sandbox.studioDrums.running = false;
sandbox.studioDrums.loop = true;
sandbox.studioDrums.lengthSteps = 16;
sandbox.studioDrums.stepDur = 0.125;
sandbox.studioDrums.seg = null;
sandbox.studioDrums.schedIndex = 0;
sandbox.studioDrums.nextPos = 0;
sandbox.studioDrums.timer = 0;
var plays = [];
sandbox.studioDrumsPlayRow = function (step, when) { plays.push({ step: step, when: when }); };
sandbox.studioDrumsBus = function () { return { currentTime: sandbox.studioAudio.ctx.currentTime }; };
sandbox.studioDrumsTransport(true);
near(plays.length, 1, 0, 'one step is placed in the lookahead');
near(plays[0].when, 30.225, 1e-9, 'the Browser drum is scheduled on the engine clock');
ok(plays[0].step === 9, 'the step is the engine grid step');

console.log('ok');
JS
close $fh;

my $out = `$node $script $transport $drums 2>&1`;
my $rc = $? >> 8;
is($rc, 0, 'the clock projection runs') or diag($out);
like($out, qr/^ok$/m, 'every projection check passed');

done_testing();
