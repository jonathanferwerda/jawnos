# tests-for: public/js/music_stream_worklet.js
# covers:    the remote-audio tap - 20 ms frames, clamping, stereo, reset, transfer

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Slurp qw(write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# The tap is what a remote machine hears: it turns the shared music graph's
# float samples into 20 ms frames of signed 16-bit stereo and hands each frame to
# the main thread. A wrong frame size, a reused buffer or an unclamped sample is
# audible on the far end, and none of it is visible from the main thread, so it
# is driven here in node against a stand-in AudioWorkletProcessor.

my $root = "$FindBin::Bin/..";
my $unit = "$root/public/js/music_stream_worklet.js";

plan skip_all => 'node is not installed' unless `command -v node 2>/dev/null`;

my $dir = tempdir(CLEANUP => 1);
write_file("$dir/harness.js", <<'JS');
const received = [];
let Registered = null;

global.AudioWorkletProcessor = class {
	constructor() {
		this.port = {
			onmessage: null,
			postMessage(msg, transfer) { received.push({ msg, transfer }); },
		};
	}
};
global.sampleRate = 48000;
global.currentTime = 0;
global.registerProcessor = (name, cls) => { Registered = { name, cls }; };

require(process.argv[2]);

console.log('name=' + Registered.name);

function tap(sampleRate) {
	global.sampleRate = sampleRate;
	global.currentTime = 0;
	return new Registered.cls();
}

// A frame of `n` samples on `channels` channels, filled by `fn(i)`.
function input(n, channels, fn) {
	const chans = [];
	for (let c = 0; c < channels; c++) {
		const buf = new Float32Array(n);
		for (let i = 0; i < n; i++) { buf[i] = fn(i, c); }
		chans.push(buf);
	}
	return [chans];
}

// --- silent until the main thread says a stream is running -----------------
{
	received.length = 0;
	const t = tap(48000);
	t.process(input(960, 2, () => 0.5));
	console.log('inactive_frames=' + received.length);
}

// --- a full 20 ms frame, mono promoted to stereo -----------------------------
{
	received.length = 0;
	const t = tap(48000);
	t.port.onmessage({ data: { active: true } });
	t.process(input(960, 1, () => 0.25));
	console.log('frames=' + received.length);
	if (received.length) {
		const msg = received[0].msg;
		console.log('pcm_len=' + msg.pcm.length);
		console.log('pcm_type=' + (msg.pcm instanceof Int16Array));
		console.log('left=' + msg.pcm[0] + ',right=' + msg.pcm[1]);
		console.log('transferred=' + (received[0].transfer.length === 1 && received[0].transfer[0] === msg.pcm.buffer));
	}
}

// --- accumulation: two half frames make one --------------------------------
{
	received.length = 0;
	const t = tap(48000);
	t.port.onmessage({ data: { active: true } });
	t.process(input(480, 2, () => 0));
	console.log('half_frames=' + received.length);
	t.process(input(480, 2, () => 0));
	console.log('after_second_half=' + received.length);
}

// --- clamping and stereo ----------------------------------------------------
{
	received.length = 0;
	const t = tap(48000);
	t.port.onmessage({ data: { active: true } });
	t.process(input(960, 2, (i, c) => (c === 0 ? 2.0 : -2.0)));
	const pcm = received[0].msg.pcm;
	console.log('clamped=' + pcm[0] + ',' + pcm[1]);
}

// --- reset drops a partial frame -------------------------------------------
{
	received.length = 0;
	const t = tap(48000);
	t.port.onmessage({ data: { active: true } });
	t.process(input(480, 2, () => 0));
	t.port.onmessage({ data: { reset: true } });
	t.process(input(480, 2, () => 0));
	console.log('after_reset=' + received.length);
	t.process(input(480, 2, () => 0));
	console.log('after_reset_fill=' + received.length);
}

// --- the frame floor --------------------------------------------------------
{
	received.length = 0;
	const t = tap(4000);            // 20 ms is 80 samples; the floor is 128
	t.port.onmessage({ data: { active: true } });
	t.process(input(128, 1, () => 0));
	console.log('floor_frames=' + received.length);
}

// --- the context time rides along ------------------------------------------
{
	received.length = 0;
	const t = tap(48000);
	global.currentTime = 12.5;
	t.port.onmessage({ data: { active: true } });
	t.process(input(960, 1, () => 0));
	console.log('time=' + received[0].msg.t);
}
JS

my $err = gensym;
my $pid = open3(my $in, my $out, $err, 'node', "$dir/harness.js", $unit);
close $in;
my $out_text = do { local $/; <$out> // '' };
my $err_text = do { local $/; <$err> // '' };
waitpid($pid, 0);

is($? >> 8, 0, 'the worklet loads against a stand-in AudioWorkletProcessor') or diag($err_text);
like($out_text, qr/^name=music-stream-tap$/m, 'it registers as music-stream-tap');

# 48 kHz * 20 ms = 960 frames, so two int16 samples per frame.
like($out_text, qr/^inactive_frames=0$/m, 'a paused stream produces no frames');
like($out_text, qr/^frames=1$/m, '960 samples make exactly one frame');
like($out_text, qr/^pcm_len=1920$/m, 'stereo int16: two per sample');
like($out_text, qr/^pcm_type=true$/m, 'the payload is an Int16Array');
like($out_text, qr/^left=8191,right=8191$/m, 'a mono input is promoted to both channels');
like($out_text, qr/^transferred=true$/m, 'and its buffer is transferred, not copied');

like($out_text, qr/^half_frames=0$/m, 'half a frame sends nothing');
like($out_text, qr/^after_second_half=1$/m, 'and the second half completes it');

like($out_text, qr/^clamped=32767,-32767$/m, 'samples beyond full scale are clamped');

like($out_text, qr/^after_reset=0$/m, 'reset throws the partial frame away');
# Without the reset, 480 + 480 would already have completed a frame. With it, the
# first 480 after the reset is half a frame and the second one completes it.
like($out_text, qr/^after_reset_fill=1$/m, 'so two fresh halves are needed to make one');

like($out_text, qr/^floor_frames=1$/m, 'the frame never drops below 128 samples');

like($out_text, qr/^time=12\.5$/m, 'the context time rides along so a backlog can be dropped');

done_testing();
