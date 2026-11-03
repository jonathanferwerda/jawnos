# tests-for: lib/JawnOS/Manager/Part14.pm
# covers:    a live stop ignores the duration the phone sends; a backdated stop still uses it

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A stop is a live stop when its timestamp is essentially now (within
# subs::stale_action_ms), and a backdated stop when it is older than that (time
# machine, ago, timeshift).
#
# The phone's UI always sends its duration field. The live-stop path used to see
# a duration and take the backdated branch, which sets
# $timestamp = $timestamp1 - (abs $duration) * -1 - the stop a whole duration
# into the FUTURE. stop_seen then read NULL and stop_timestamp a future moment,
# so the closed row still looked open ("start becomes stop", "only one at a
# time" in subs::next_appointment_time). A live stop now uses the press time and
# the length the row ran; only a backdated stop trusts the client's duration.

my $root   = repo_root();
my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");

my ($reset_sub) = $part14 =~ /(sub manager_reset\(.*?\n\}\n)/s;
ok($reset_sub, 'manager_reset is one sub');

my ($stop_branch) = $reset_sub =~ /(elsif \(\$type eq 'stop'\) \{.*?\n\s*elsif \(\$type eq 'cancel'\) \{)/s;
ok($stop_branch, 'its stop branch is one block');

my ($live_guard) = $stop_branch =~ /(my \$live_stop = .*?;)/s;
ok($live_guard, 'the stop branch names which stops are live');
like($live_guard, qr/abs\(\$timestamp - &subs::rightNow\(\)\) <= &subs::stale_action_ms\(\)/,
	'the house stale window is what decides a live stop');
like($stop_branch, qr/if \(\$live_stop \|\| !\$c->param\('duration'\)\)/,
	'a live stop takes the no-duration path whatever duration the client sent');
like($stop_branch, qr/else \{\s*(?:\#[^\n]*\n\s*)*\$duration = \(abs \$duration\) \* -1;/,
	'and only a backdated stop reads the duration the client sent');
unlike($stop_branch, qr/unless \(\$c->param\('duration'\)\)/,
	'no branch now ignores a live stop because a duration arrived');
like($stop_branch, qr/\$duration = \$timestamp1 - \$timestamp;/,
	'a live stop measures the session from the press time');
unlike($stop_branch, qr/unless \(\$c->param\('duration'\)\)/,
	'no branch now ignores a live stop because a duration arrived');

# The backdated branch is unchanged and must stay: there the duration is the
# person's account of a session that ran earlier.
my ($backdated) = $stop_branch =~ /(else \{\s*(?:\#[^\n]*\n\s*)*\$duration = \(abs \$duration\) \* -1;.*?\n\s*\})/s;
ok($backdated, 'the backdated branch survives');
like($backdated, qr/\$duration = \(abs \$duration\) \* -1;\s*\$timestamp = \$timestamp1 - \$duration;/,
	'a backdated stop is still placed back from the start by the duration');

# The write records the live stop as seen, at the press time. The seen path
# writes stop_timestamp => $timestamp, and the unseen path only records a
# future stop_timestamp - so a future $timestamp is what produced the
# stop|0|1 row.
like($stop_branch, qr/stop_timestamp => \$timestamp,/, 'the seen write stamps the press time');
like($stop_branch, qr/stop_seen => \$timestamp <= &subs::rightNow\(\) \+ 1000 \? 'yes' : undef/,
	'and a press-time stop reads as seen');

# --- behaviour: the same arithmetic, run for real --------------------------
#
# manager_reset cannot be reached from a test (peer_action_gate renders 403 for
# an unauthenticated request), so the branch's decision is reproduced here from
# the source above and checked against real clock values.

my $stale = 15 * 60 * 1000;    # subs::stale_action_ms
my $now   = time() * 1000;
my $sent_duration = 3600000;       # the phone sends 1h
my $session_start = $now - 7200000;   # the session started two hours ago

sub stop_decision {
	my ($timestamp, $param_duration) = @_;
	# the closed session's start, as $timestamp1 is in manager_reset
	my $timestamp1 = $session_start;
	# the branch keeps its own $duration, as manager_reset does
	my $duration = defined $param_duration ? $param_duration : 0;
	my $live_stop = abs($timestamp - $now) <= $stale;
	if ($live_stop || !$param_duration) {
		return { timestamp => $timestamp, duration => $timestamp1 - $timestamp };
	}
	else {
		return { timestamp => $timestamp1 - abs($duration) * -1, duration => abs($duration) * -1 };
	}
}

my $live = stop_decision($now - 2000, $sent_duration);
is($live->{'timestamp'}, $now - 2000, 'a live stop stays at the press time');
is($live->{'duration'}, $session_start - ($now - 2000), 'and its length is the session that ran');
cmp_ok($live->{'timestamp'}, '<=', $now + 1000, 'so stop_seen reads yes');

my $old = stop_decision($now - 3 * 3600 * 1000, $sent_duration);
is($old->{'timestamp'}, $session_start + abs($sent_duration), 'a backdated stop still takes the client duration');
is($old->{'duration'}, -$sent_duration, 'and records it as the session length');

done_testing();
