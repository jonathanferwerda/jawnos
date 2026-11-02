use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The Clock app used to arm two fixed timers at page load: a 5 s poll of
# /manager/clock/state whether or not a Clock window existed, and a 250 ms tick
# of jawnosClockTick, which returns immediately unless a window is open. The wake
# itself was the cost. Both are recursive setTimeout loops now: idle work drops to
# 1 s (tick) and 60 s (state backstop), 4 Hz runs only while a window is open.
#
# This test reads the index only, so a fixed interval cannot quietly come back.

my $root  = repo_root();
my $index = "$root/public/js/manager/clock.js";
ok(-f $index, 'clock.js is on disk');
my $src = read_file($index);

# --- the tick loop ------------------------------------------------------------
unlike($src, qr/setInterval\s*\(\s*jawnosClockTick\s*,\s*250\s*\)/,
	'the fixed 250 ms jawnosClockTick interval is gone');

like($src, qr/jawnosClockTickTimer\s*=\s*setTimeout/,
	'the tick loop assigns jawnosClockTickTimer from setTimeout');
like($src, qr/clockTickSchedule\(\s*1000\s*\)/,
	'an idle tick reschedules in 1 s (hidden, or no Clock window)');
like($src, qr/clockTickSchedule\(\s*250\s*\)/,
	'an open Clock window still ticks at 4 Hz');
like($src, qr/document\.hidden\s*\|\|\s*!\$\('\.clock_app'\)\.length/,
	'the tick skips both a hidden tab and a missing Clock window');

# --- the state poll -----------------------------------------------------------
like($src, qr/jawnosClockPollTimer\s*=\s*setTimeout/,
	'the poll loop assigns jawnosClockPollTimer from setTimeout');
like($src, qr/\.clock_app'\)\.length\s*>\s*0/,
	'the poll asks whether a Clock window is open');
like($src, qr/:\s*60000\b/,
	'the poll falls back to a 60 s idle interval');
like($src, qr/open\s*\?\s*5000\s*:\s*60000/,
	'an open window keeps 5 s; an idle page polls every 60 s');
like($src, qr/jawnosClockRefresh\(\)/,
	'the idle poll still fetches state, so a ring is still noticed');
like($src, qr/clockPollSchedule\(5000\)/, 'the first poll is scheduled at ready');
like($src, qr/clockTickSchedule\(250\)/, 'the first tick is scheduled at ready');

# --- and the file still parses ------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my $out = `$node --check "$index" 2>&1`;
	my $status = $?;
	diag($out) if $status != 0;
	is($status, 0, 'node --check accepts public/js/manager/clock.js');
}
else {
	diag('node is not installed; the syntax check is skipped');
}

done_testing();
