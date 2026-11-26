# tests-for: public/js/manager/studio.js public/js/manager/studio/06_controls.js public/js/manager/studio/10_master.js
# covers:    An engine take arms its live input only when a track is actually
#            monitored. A stale app-wide Monitor setting left at "yes" must not
#            turn a Monitor-off recording into a dry monitored one. This runs
#            studioEngineStartNow in node with the AJAX call captured, so the
#            request body is checked directly. It also checks the direct-USB
#            listen's plan: the input channel, the track's pedals with their
#            values, a bypassed pedal and the song's master rack (always the
#            five slots, each with its footswitch), that the picker answers
#            `usb` only when the app bridge and a device are there, that the
#            house-engine Listen carries the same rack, that a re-arm builds
#            the new plan before stopping the running take, clears a stale one
#            and retries once, and that the Configure Listen re-arms on its own
#            input while an Out pedal does not.

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
	'#studio_engine_inserts': '',
	'#studio_listen_gain': '2',
	'#studio_monitor_backend': 'usb'
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
	// A function's own `length` is its arity and is not writable; the fake needs
	// a match count, so define it.
	Object.defineProperty(f, 'length', { value: (sel === '#studio_monitor_backend') ? 1 : 0 });
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

// The app bridge the page sees in the WebView. `usbTake` answers the same
// shape the Java side does: accepted, with the interface still opening.
sandbox.JawnAudioEngine = {
	usbTake: function (seconds, plan) { captured.length = 0; captured.push({ usb: plan }); return '{"ok":true,"state":"detecting"}'; },
	usbTakeStatus: function () { return '{"ok":true,"state":"started","frames_in":0}'; },
	usbTakeStop: function () { return '{"ok":true}'; },
	usbAudioDevice: function () { return '{"ok":true,"device":{"name":"UM2"}}'; }
};

// The effects part's mapping. Identity is enough here: the test is which names
// and values reach the plan, not how a slider becomes a native unit.
sandbox.studioEffectKind = function (name) { return String(name); };
sandbox.studioEffectBuilder = function (name) { return true; };
sandbox.studioEffectBrowserOnly = function (name) { return String(name) === 'stereowidener'; };
sandbox.studioEffectNatural = function (kind, control, value) { return value; };
sandbox.studioEngineMasterValues = function () {
	return [
		{ name: 'master_comp', control: 'bypass', value: 0 },
		{ name: 'master_comp', control: 'thresh', value: -18 },
		{ name: 'master_limiter', control: 'bypass', value: 1 },
		{ name: 'master_eq', control: 'bypass', value: 1 },
		{ name: 'master_reverb', control: 'bypass', value: 1 },
		{ name: 'master_maximizer', control: 'bypass', value: 1 }
	];
};
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

// One monitored track: the take's live input is armed.
var on = requestFor({ 1: 1 });
ok(on, 'the Monitor-on take made a request');
ok(on.monitor_input === 'true', 'Monitor on sends monitor_input true (got ' + on.monitor_input + ')');

// The direct-USB listen's plan: the input channel, the track's pedals with
// their values, a bypassed pedal, and the song's rack with its footswitches.
sandbox.mixer = { admin: { master: [] } };
sandbox.studioAudio.channels = {
	1: { inserts: [
		{ name: 'fuzz', bypassed: false, values: { gain: 50, tone: 50, level: 50 } },
		{ name: 'delay', bypassed: true, values: { time: 40 } },
		{ name: 'stereowidener', bypassed: false, values: { width: 50 } }
	] }
};
var plan = sandbox.studioUsbListenPlan('1', '1');
ok(plan.channel === 1, 'the plan names the instrument channel (got ' + plan.channel + ')');
ok(plan.gain === 2, 'the plan carries the listen trim (got ' + plan.gain + ')');
ok(plan.fuzz && plan.fuzz.gain === 50 && plan.fuzz.level === 50, 'the fuzz travels with its knobs');
ok(plan.delay && plan.delay.bypass === 1 && plan.delay.time === undefined,
	'a bypassed pedal travels as a bypass, without its knobs (got ' + JSON.stringify(plan.delay) + ')');
ok(plan.stereowidener === undefined, 'the browser-only widener is left out');
ok(Array.isArray(plan.master) && plan.master.length === 5,
	'the rack is always the five slots (got ' + JSON.stringify(plan.master) + ')');
ok(plan.master.indexOf('master_stereowidener') < 0, 'the widener is not a rack slot');
ok(plan.master_comp && plan.master_comp.thresh === -18, 'an enabled slot carries its knobs');
ok(plan.master_limiter && plan.master_limiter.bypass === 1,
	'a switched-off slot travels as bypass (got ' + JSON.stringify(plan.master_limiter) + ')');
ok(sandbox.studioMonitorBackend() === 'usb',
	'the picker answers usb when the bridge and a device are there (got ' + sandbox.studioMonitorBackend() + ')');

// The house-engine Listen carries the same rack the transport does.
values['#studio_monitor_backend'] = 'engine';
captured.length = 0;
sandbox.studioListenStart(false);
var listen = captured.length ? captured[0] : null;
ok(listen && listen.action === 'listen_start', 'the engine Listen made a request');
ok(listen.master_json && JSON.parse(listen.master_json).length === 5,
	'and carries the rack (got ' + listen.master_json + ')');
ok(listen.master_values_json && JSON.parse(listen.master_values_json).length === 6,
	'with its footswitches and knobs (got ' + listen.master_values_json + ')');

// A re-arm: the new plan is built before the running take is stopped, and a
// stale take that answers "already running" is cleared and the start retried.
values['#studio_monitor_backend'] = 'usb';
var starts = 0, stops = 0;
sandbox.JawnAudioEngine = {
	usbTake: function (seconds, json) {
		starts++;
		if (starts === 1) { return '{"ok":false,"error":"a USB take is already running; stop it first"}'; }
		return '{"ok":true,"state":"detecting"}';
	},
	usbTakeStop: function () { stops++; return '{"ok":true}'; },
	usbTakeStatus: function () { return '{"ok":true,"state":"started"}'; },
	usbAudioDevice: function () { return '{"ok":true,"device":{"vendorId":2235,"productId":10498}}'; }
};
sandbox.studioUsbListening = false;
sandbox.studioUsbListenStart(false, '1');
ok(starts === 2, 'a stale take is cleared and the start retried (got ' + starts + ')');
ok(stops === 1, 'and the retry stops it exactly once (got ' + stops + ')');

// A plan that cannot be built leaves the monitor that is already running alone.
var wasStops = stops;
sandbox.studioUsbListenPlan = function () { throw new Error('boom'); };
sandbox.studioUsbListening = true;
sandbox.studioUsbListenStart(false, '1');
ok(stops === wasStops, 'a plan that cannot be built stops nothing (got ' + stops + ')');
sandbox.studioUsbListening = false;

// A pedal added while the Configure Listen (no track Monitor) is live re-arms
// that listen too, using its own chosen input.
var rearmed = [];
var realStop = sandbox.studioListenStop;
sandbox.studioListenStop = function (next_channel, ch) { rearmed.push(String(next_channel)); };
sandbox.mixer = { admin: { master: [] } };
sandbox.studioListenActive = true;
sandbox.studioListenChannel = 1;
var realTimeout = sandbox.setTimeout;
sandbox.setTimeout = function (fn) { fn(); return 0; };
sandbox.studioListenRearm('1', 'in');
sandbox.setTimeout = realTimeout;
ok(rearmed.length === 1 && rearmed[0] === '1',
	'the standalone Listen re-arms on its own input (got ' + JSON.stringify(rearmed) + ')');
rearmed.length = 0;
sandbox.setTimeout = function (fn) { fn(); return 0; };
sandbox.studioListenRearm('1', 'out');
sandbox.setTimeout = realTimeout;
ok(rearmed.length === 0, 'an Out pedal is playback, not the monitor');
sandbox.studioListenStop = realStop;

console.log('ok');
JS
close $fh;

my $out = `$node $script $studio $controls 2>&1`;
my $rc = $? >> 8;
is($rc, 0, 'the take request runs') or diag($out);
like($out, qr/^ok$/m, 'both Monitor states, the USB plan, the re-arm and the engine Listen send the right request');

done_testing();
