# tests-for: public/js/manager/studio/01_transport.js public/js/manager/studio.js public/js/manager/studio/03_editing.js
# covers:    The metronome on the real-time audio clock: a lookahead and click
#            burst long enough that a normal main-thread stall cannot empty the
#            queue, a past beat skipped alone so the absolute grid never shifts,
#            and a tempo/signature/metronome/loop/transport change that re-anchors
#            only the clicks (never the take sources). The native engine's
#            measured round trip feeds the take offset, not the click's schedule.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use Cwd qw(abs_path);

my $root      = abs_path("$FindBin::Bin/..");
my $transport = read_file("$root/public/js/manager/studio/01_transport.js");
my $studio    = read_file("$root/public/js/manager/studio.js");
my $editing   = read_file("$root/public/js/manager/studio/03_editing.js");

# One function body, from its opening line to the closing brace in column one.
# The parts are concatenated into one bundle, so the bodies are top-level.
sub body {
	my ($src, $name) = @_;
	my ($b) = $src =~ /^(?:async )?function \Q$name\E\([^)]*\) \{(.*?)^\}/ms;
	return defined $b ? $b : '';
}

# --- the horizon and the click burst outlast a stall -------------------------
my $tick = body($transport, 'studioScheduleTick');
ok(length $tick, 'the scheduler tick is one function');
like($tick, qr/studioAudio\.lookahead \|\| 2\.0/, 'the tick places audio two seconds ahead');
like($tick, qr/var step = studioAudio\.clickStep \|\| 2\.0;/, 'clicks are committed in two-second bursts');
unlike($tick, qr/var step = 0\.5;/, 'the old half-second click burst is gone');

my ($lookahead) = $studio =~ /lookahead:\s*([0-9.]+)/;
ok(defined $lookahead && $lookahead >= 1, 'the configured lookahead is at least one second');
my ($click_step) = $studio =~ /clickStep:\s*([0-9.]+)/;
ok(defined $click_step && $click_step >= 1, 'the configured click burst is at least one second');

my $window = body($studio, 'studioRebuildWindow');
ok(length $window, 'the window rebuild is found');
like($window, qr/lookahead: 2\.0,\s*clickStep: 2\.0/,
	'a rebuilt window keeps the same long horizon and burst');

# --- a past beat is skipped alone; the absolute grid never shifts -----------
my $clicks = body($transport, 'studioScheduleClicks');
ok(length $clicks, 'the click scheduler is one function');
like($clicks, qr/var pos = k \* beat;/, 'a beat is an absolute multiple of the grid');
like($clicks, qr/var when = studioTimeAt\(pos, p0, ctx0\);/, 'it is mapped through the segment anchor');
like($clicks, qr/for \(var k = k0;[\s\S]*?if \(when < ctx\.currentTime\) \{ continue; \}/,
	'a beat already behind the clock is skipped inside the loop');
unlike($clicks, qr/when\s*=\s*ctx\.currentTime/, 'a click is never moved later to catch up');
unlike($clicks, qr/baseLatency|outputLatency|studioRecordOffset/,
	'the click grid is not shifted to compensate for output latency');

# --- a settings change re-anchors only the clicks ----------------------------
my $key = body($transport, 'studioClickKey');
ok(length $key, 'the click key is one function');
for my $field (qw(bpm sig metronome loop status punch_in)) {
	like($key, qr/mixer\['time'\]\['\Q$field\E'\]/, "the click key watches $field");
}
unlike($key, qr/volume/, 'the volume knob does not retime the clicks');

like($tick, qr/var retimed = \(studioAudio\.clickKey !== key\);/, 'the tick compares the click key');
like($tick, qr/if \(retimed\) \{\s*studioAudio\.clickKey = key;\s*studioClickReanchor\(\);/, 'a changed key re-anchors the clicks');
like(
	$tick,
	qr/studioAudio\.engineGainKey !== engineGain[\s\S]{0,200}studioEngineTransportSync\(\)/,
	'a volume or on/off change retunes the engine without retiming the browser beats'
);
unlike($tick, qr/studioFlushSources\(\)/, 'a click retime never flushes the take sources');

my $reanchor = body($transport, 'studioClickReanchor');
ok(length $reanchor, 'the click re-anchor is one function');
like($reanchor, qr/studioFlushClicks\(\);/, 'it drops the scheduled clicks');
unlike($reanchor, qr/studioFlushSources\(\)/, 'and never the take sources');
like($reanchor, qr/studioAudio\.clickSeg = studioSegmentCopy\(studioSegmentFrom\(pos, now\)\)/,
	'it re-seeds the click cursor from the playhead with the same segment rule');

# --- the take sources survive a click re-anchor ------------------------------
my $flush = body($transport, 'studioFlushClicks');
ok(length $flush, 'the click-only flush is one function');
like($flush, qr/entry\.kind !== 'click'/, 'it keeps every source that is not a click');
like($flush, qr/studioAudio\.sources = keep;/, 'the kept take sources stay in the list');
unlike($flush, qr/studioAudio\.sources = \[\];/, 'it never empties the whole list');

my $track = body($transport, 'studioTrackSource');
ok(length $track, 'every scheduled source is parked in one place');
like($track, qr/kind: kind \|\| 'take'/, 'an untagged source defaults to a take');
like($clicks, qr/studioTrackSource\(osc, gain, 'click'\)/, 'the metronome tags its oscillators as clicks');

my $take = body($transport, 'studioScheduleTake');
ok(length $take, 'the take scheduler is one function');
like($take, qr/studioTrackSource\(src, g\);/, 'a take is parked untagged');

my @seeds = $transport =~ /studioAudio\.clickKey = studioClickKey\(\);/g;
cmp_ok(scalar @seeds, '>=', 2, 'the transport start and a take edit seed the key, not a re-anchor');

# --- the engine's measurement feeds the take offset -------------------------
my $offset = body($editing, 'studioRecordOffset');
ok(length $offset, 'the record offset is one function');
like($offset, qr/studioAudio\.engineLatency > 0/, 'a measured engine round trip is considered');
like($offset, qr/return studioAudio\.engineLatency;/, 'it becomes the whole offset');
like($offset, qr/backend !== 'browser'/, 'only while a native backend owns the interface');
like($offset, qr/m && m\.latency > 0/, 'the browser path still adds the input track latency');
like($studio, qr/studioAudio\.engineLatency = data\.ms \/ 1000;/,
	'the latency route stores the engine measurement in seconds');

done_testing();
