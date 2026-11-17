# tests-for: public/js/manager/studio.js
# covers:    P0 of docs/studio-audio-roadmap.md measures the WebAudio path before
#            a native engine replaces it, so studioAudioReport() must read the
#            browser's own numbers (base/output latency, sample rate, the asked
#            hint and rate), keep the last round-trip probe result and the last
#            MediaRecorder start delay, and leave the graph untouched.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root);

my $root = repo_root();
my $js = read_file("$root/public/js/manager/studio.js");
my $inputs = read_file("$root/public/js/manager/studio/05_inputs.js");

# --- the report function is one call and is reachable from the console ------
my ($report) = $js =~ /(function studioAudioReport\(\) \{.*?\n\})/s;
ok(defined $report && length $report, 'studio.js defines studioAudioReport()');
like($js, qr/^window\.studioAudioReport = studioAudioReport;/m,
	'studioAudioReport is published on window');

# --- every field the roadmap's P0 needs is in the returned object -----------
for my $field (qw(userAgent state sampleRate sampleRateAsked latencyHintAsked
                  baseLatency outputLatency roundTrip recorderStartDelayMs capturedAt)) {
	like($report, qr/^\t\t\Q$field\E:/m, "the report exposes $field");
}

# --- the numbers come from the browser, not from the settings ---------------
like($report, qr/\bctx\.baseLatency\b/, 'the report reads ctx.baseLatency');
like($report, qr/\bctx\.outputLatency\b/, 'the report reads ctx.outputLatency');
like($report, qr/\bctx\.sampleRate\b/, 'the report reads ctx.sampleRate');
like($report, qr/\bstudioSampleRate\(\)/, 'the report carries the sample rate that was asked for');
like($report, qr/\bstudioLatencyHint\(\)/, 'the report carries the latency hint that was asked for');
like($report, qr/navigator\.userAgent/, 'the report names the engine through the user agent');

# --- a plain object, built without touching the audio graph -----------------
unlike($report, qr/new\s+(?:window\.)?(?:AudioContext|Ctor)\b/,
	'the report constructs no AudioContext');
unlike($report, qr/\.(?:createGain|createAnalyser|createBufferSource|connect)\b/,
	'the report builds and wires no audio nodes');

# --- the last round-trip probe is stored and surfaced -----------------------
like($js, qr/studioAudio\.probe = \{/s, 'the meter stores its result on studioAudio.probe');
like($report, qr/studioAudio\.probe \|\| null/, 'the report reads the stored probe result');
like($report, qr/'output \+ air \+ input'/, 'the report says what the probe measured');
like($report, qr/^\t\t\tseconds: probe\.seconds,/m, 'the report carries the raw probe number');
like($js, qr/console\.log\(JSON\.stringify\(studioAudioReport\(\)\)\);/,
	'the meter logs one JSON line of the report when it finishes');

# --- the last MediaRecorder start delay is stamped on the take --------------
like($inputs, qr/recorder\.onstart = function\(\)/,
	'the take stamps the recorder onstart event');
like($inputs, qr/take\.recorderStartDelayMs = now - recStartAt/,
	'the take stores the delay between start() and onstart');
like($inputs, qr/studioAudio\.recorderStartDelayMs = take\.recorderStartDelayMs/,
	'the latest recorder start delay is surfaced on studioAudio');

# --- the on-screen readout carries the numbers beside what it already had ---
my ($info) = $js =~ /(function studioUpdateLatencyInfo\(\) \{.*?\n\})/s;
ok(defined $info && length $info, 'studioUpdateLatencyInfo() is found');
like($info, qr/\bctx\.baseLatency\b/, 'the readout shows baseLatency');
like($info, qr/\bctx\.outputLatency\b/, 'the readout shows outputLatency');
like($info, qr/\bctx\.sampleRate\b/, 'the readout shows sampleRate');
like($info, qr/parts\.push\('hint ' \+ studioLatencyHint\(\)\)/,
	'the readout still shows the hint it already had');

done_testing();
