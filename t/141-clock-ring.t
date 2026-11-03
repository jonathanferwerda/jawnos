# tests-for: public/js/manager/clock.js public/js/manager/clock/02_stopwatch_world_ring.js lib/JawnOS/Domain/Clock2.pm lib/JawnOS/Controller/manager_clock.pm
# covers:    The ring card belongs to every open Manager window, and a ring on one machine reaches the others...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# The alarm's sound is local to the machines that carry it, but the answer is
# not. Two things used to keep the card to one window: the "seen" claim lived
# in localStorage, which every window on a machine shares, and the backstop
# filtered the ringing alarm by the machines that carry it. A ring also never
# left the machine that sounded it, so a Manager window on another machine
# could not offer Dismiss or Snooze. This test pins the three fixes.

my $root = repo_root();
my $clock = read_file("$root/public/js/manager/clock.js");
my $ring = read_file("$root/public/js/manager/clock/02_stopwatch_world_ring.js");
my $clock2 = read_file("$root/lib/JawnOS/Domain/Clock2.pm");
my $route = read_file("$root/lib/JawnOS/Controller/manager_clock.pm");

# --- the claim is per window ---------------------------------------------------
unlike($ring, qr/localStorage\.(?:get|set)Item\(\s*'jawnos_clock_ring_/,
	'the ring claim no longer lives in localStorage (shared by every window)');
like($ring, qr/var jawnosClockRingSeen = \{\};/,
	'each window keeps its own seen map');
like($ring, qr/jawnosClockRingSeen\[uuid\]/,
	'the per-window map still suppresses a duplicate notice for one alarm');

# --- every machine draws the card, and stale rows do not close it --------------
unlike($clock, qr/jawnosClockTargetsMe/,
	'the ring backstop no longer asks whether this machine carries the alarm');
like($clock, qr/var ringing = \$\.grep\(alarms, function \(a\) \{ return a\.ringing; \}\);/,
	'the backstop follows the shared ringing flag on every machine');
like($clock, qr/stopAt && at && stopAt >= at/,
	'only a stop at or after this ring closes a card from a stale shared row');
like($ring, qr/function jawnosClockRingGuardArm\(\)/,
	'the card carries its own five-minute guard');

# --- a ring notice reaches the other machines ---------------------------------
like($clock2, qr/clock_relay\('ring_notice',/,
	'ringing tells the peers that the alarm is sounding');
like($route, qr/if \(\$action eq 'ring_notice'\)/,
	'the clock route accepts a ring notice');
like($route, qr/&subs::clock_alarm_cmd\(\$alarm, \$at, \$now\);/,
	'a ring notice draws the same card through the standard ring payload');
like($route, qr/my \$everywhere = \(\$action eq 'stop_all' \|\| \$action eq 'dismiss' \|\| \$action eq 'snooze'\);/,
	'dismiss and snooze reach every machine showing the card, not only the ringers');

# --- the two scripts still parse ----------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	for my $file ("$root/public/js/manager/clock.js",
	              "$root/public/js/manager/clock/02_stopwatch_world_ring.js") {
		my $out = `$node --check "$file" 2>&1`;
		my $status = $?;
		diag($out) if $status != 0;
		is($status, 0, "node --check accepts $file");
	}
}
else {
	diag('node is not installed; the syntax check is skipped');
}

done_testing();
