# tests-for: lib/JawnOS/Manager/Part14.pm lib/JawnOS/Controller/manager_misc12.pm public/js/manager/manager/09_app_back.js public/js/manager/manager/07_timeshift.js
# covers:    a live stop uses a duration the person typed, schedules a future stop for one longer than the session, ignores one the window restored; a backdated stop still uses its duration; editing a closed row's duration moves its stop

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
# The stop's duration field has two meanings. A person who types a length beside
# the stop button means "this session runs that long": the stop belongs at
# start + length, in the past when the session already ran longer, or in the
# future as a scheduled stop the Alarm applies at that moment. A window that
# restores a remembered duration into the same field means nothing about this
# session - the phone measured an app's 47d default arriving on a live stop,
# which used to move the stop into the FUTURE by itself, leave stop_seen NULL
# and keep the row reading as open ("start becomes stop", "only one at a time").
# The panel now flags a typed duration, so the server can tell the two apart
# instead of guessing from the value alone.

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

my ($typed_guard) = $stop_branch =~ /(my \$typed_duration = .*?;)/s;
ok($typed_guard, 'and which durations the person typed');
like($typed_guard, qr/duration_typed/,
	'the typed flag the panel sends is what marks a personal length');
unlike($typed_guard, qr/rightNow/,
	'a typed length is taken whatever moment it names, behind or ahead of the press');

like($stop_branch, qr/if \(!\$c->param\('duration'\) \|\| \(\$live_stop && !\$typed_duration\)\)/,
	'a live stop still ignores the duration unless the person typed it');
like($stop_branch, qr/\$duration = \$timestamp1 - \$timestamp;/,
	'a live stop measures the session from the press time');

# The backdated branch is unchanged and must stay: there the duration is the
# person's account of a session that ran earlier, and the typed live press takes
# the same path.
my ($backdated) = $stop_branch =~ /(else \{\s*(?:\#[^\n]*\n\s*)*\$duration = \(abs \$duration\) \* -1;.*?\n\s*\})/s;
ok($backdated, 'the backdated branch survives');
like($backdated, qr/\$duration = \(abs \$duration\) \* -1;\s*\$timestamp = \$timestamp1 - \$duration;/,
	'a backdated stop is still placed back from the start by the duration');

# A typed length that lands after the press is a scheduled stop: the row stays an
# open start/record with a future stop_timestamp and stop_seen NULL, which is the
# shape Alarm.pl applies when the stop time arrives. Retiring the row (and its
# children) at the press instead would close a session that is still running - and
# the Alarm only reads stops from start/record rows, never from type=stop.
like($stop_branch, qr/\$scheduled_stop = \$timestamp > &subs::rightNow\(\) \+ 1000 \? 1 : 0;/,
	'the stop branch names a scheduled stop');
like($stop_branch, qr/if \(\$scheduled_stop\) \{\s*\$type = \$o->\{'type'\};/,
	'a scheduled stop keeps the row an open start/record for the Alarm');
like($stop_branch, qr/unless \(\$scheduled_stop\) \{/,
	'while the stop work itself waits for the Alarm');
like($stop_branch, qr/\$seen eq 'yes' && !\$scheduled_stop && \$stop_row/,
	'and the twin sweep waits with it');
my ($defer_guard) = $stop_branch =~ /(my \$schedules_stop = .*?;)/s;
ok($defer_guard, 'a typed future length is recognised before a recording is ended');
like($defer_guard, qr/duration_typed/, 'by the same typed flag');
like($defer_guard, qr/\(\$timestamp1 \+ abs\(\$duration\)\) > &subs::rightNow\(\) \+ 1000/,
	'and only when it lands after the press');

# The write records the stop at $timestamp. The seen path writes
# stop_timestamp => $timestamp, and the unseen path only records a future
# stop_timestamp - so a future $timestamp is what produced the stop|0|1 row.
like($stop_branch, qr/stop_timestamp => \$timestamp,/, 'the seen write stamps $timestamp');
like($stop_branch, qr/stop_seen => \$timestamp <= &subs::rightNow\(\) \+ 1000 \? 'yes' : undef/,
	'and a press-time stop reads as seen');

# --- the panel: who says the duration was typed -----------------------------
my $app_back = read_file("$root/public/js/manager/manager/09_app_back.js");
like($app_back, qr/jawnosAppFieldGet\(app, 'duration_typed'\)/,
	'managerReset reads the typed mark stored beside the duration');
like($app_back, qr/duration_typed: duration_typed,/,
	'and sends it with the press');
like($app_back, qr/jawnosAppFieldRemove\(app, 'duration_typed'\)/,
	'and clears it once the press is away');

my $timeshift = read_file("$root/public/js/manager/manager/07_timeshift.js");
like($timeshift, qr/\$\(document\)\.on\('keyup', '\.duration'/,
	'a keypress in the duration field is what sets the typed mark');
like($timeshift, qr/jawnosAppFieldSet\(appointment, 'duration_typed', 'yes'\)/,
	'and the mark is stored with the value it belongs to');

# --- the edit form: changing a closed session's length moves its stop --------
# A stop, then a hand-set duration in the record editor, must leave a row whose
# stop and duration still describe the same session. The stop is the start plus
# the length, so the length the form saves moves the stop to match.
my $misc12  = read_file("$root/lib/JawnOS/Controller/manager_misc12.pm");
my ($edit_sub) = $misc12 =~ /(sub action_41468 \{.*?\n\}\n)/s;
ok($edit_sub, 'the appointment edit route is one sub');
like($edit_sub, qr/\$data->\{'stop_timestamp'\} = \(0 \+ \$start\) \+ abs\(\$duration\);/,
	'a negative duration on a closed row moves stop_timestamp with it');
like($edit_sub, qr/\$appt->\{'stop_timestamp'\} ne ''/,
	'only a row that already has a stop is re-stamped');

my $edited_start = time() * 1000 - 7200000;
my $edited_stop  = (0 + $edited_start) + abs(-1800000);
is($edited_stop - $edited_start, abs(-1800000),
	'a hand-set half hour ends the session half an hour after its start');

# --- behaviour: the same arithmetic, run for real ---------------------------
#
# manager_reset cannot be reached from a test (peer_action_gate renders 403 for
# an unauthenticated request), so the branch's decision is reproduced here from
# the source above and checked against real clock values.

my $stale = 15 * 60 * 1000;            # subs::stale_action_ms
my $now   = time() * 1000;
my $session_start = $now - 7200000;    # the session started two hours ago

sub stop_decision {
	my ($timestamp, $param_duration, $typed) = @_;
	# the closed session's start, as $timestamp1 is in manager_reset
	my $timestamp1 = $session_start;
	# the branch keeps its own $duration, as manager_reset does
	my $duration = defined $param_duration ? $param_duration : 0;
	my $live_stop = abs($timestamp - $now) <= $stale;
	my $typed_duration = $typed && $duration;
	my ($out_ts, $out_dur);
	if (!$param_duration || ($live_stop && !$typed_duration)) {
		$out_ts  = $timestamp;
		$out_dur = $timestamp1 - $timestamp;
	}
	else {
		$out_dur = -abs($duration);
		$out_ts  = $timestamp1 - $out_dur;
	}
	my $scheduled = $out_ts > $now + 1000 ? 1 : 0;
	return {
		timestamp => $out_ts,
		duration  => $out_dur,
		scheduled => $scheduled,
		type      => $scheduled ? 'start' : 'stop',
		stop_seen => $out_ts <= $now + 1000 ? 'yes' : undef,
	};
}

my $sent_duration = 3600000;    # the person typed 1h

my $remembered = stop_decision($now - 2000, $sent_duration, 0);
is($remembered->{'timestamp'}, $now - 2000,
	'a live stop still closes at the press time when the duration was only restored');
is($remembered->{'duration'}, $session_start - ($now - 2000),
	'and takes the length the session actually ran');
is($remembered->{'scheduled'}, 0, 'a remembered default never schedules a stop');
is($remembered->{'stop_seen'}, 'yes', 'and the row closes as seen');

my $typed = stop_decision($now - 2000, $sent_duration, 1);
is($typed->{'timestamp'}, $session_start + $sent_duration,
	'a typed duration places the stop at the start plus the length named');
is($typed->{'duration'}, -$sent_duration, 'and records that length');
is($typed->{'timestamp'} - $session_start, abs($typed->{'duration'}),
	'so the stop and the duration add up');
is($typed->{'scheduled'}, 0, 'a length inside the session closes now');
is($typed->{'stop_seen'}, 'yes', 'and the row closes as seen');

my $later = stop_decision($now - 2000, 3 * 3600000, 1);
is($later->{'timestamp'}, $session_start + 3 * 3600000,
	'a typed length longer than the session ends it that long after the start');
cmp_ok($later->{'timestamp'}, '>', $now + 1000, 'which is in the future');
is($later->{'duration'}, -3 * 3600000, 'the duration still names the whole session');
is($later->{'scheduled'}, 1, 'so the stop is scheduled');
is($later->{'type'}, 'start', 'the row stays open for the Alarm to close');
is($later->{'stop_seen'}, undef, 'and stop_seen waits for the Alarm');

my $default_long = stop_decision($now - 2000, 3 * 3600000, 0);
is($default_long->{'timestamp'}, $now - 2000,
	'an untyped length longer than the session cannot schedule anything');
is($default_long->{'scheduled'}, 0, 'so the remembered default still closes now');

my $old = stop_decision($now - 3 * 3600 * 1000, $sent_duration, 0);
is($old->{'timestamp'}, $session_start + abs($sent_duration),
	'a backdated stop still takes the client duration');
is($old->{'duration'}, -$sent_duration, 'and records it as the session length');

# --- presses can be faster than the manager answers --------------------------
# A start and a stop are one story. The panel used to fire each press as its
# own request: two in flight can be answered out of order, and a stop clicked
# before the start's reply carries the header's old session uuid. The presses
# are queued per app, one in flight, and a stop resolves its session when it is
# actually sent.
my $app_back = read_file("$root/public/js/manager/manager/09_app_back.js");
like($app_back, qr/var appointmentResetQueue = \{\};/, 'presses are queued per app');
like($app_back, qr/q\.push\(\{ type: type, data: data, done: done, fail: fail \}\);/, 'a press keeps what it was when it was clicked');
like($app_back, qr/if \(q\.length === 1\) \{ appointmentResetDrain\(key\); \}/, 'only one press is in flight');
like($app_back, qr/if \(item\.type == 'stop'\) \{/, 'a stop is the press that re-reads its session');
like($app_back, qr/\.appointment_header_background'\)\.attr\('running_uuid'\)/, 'from the header the press before it wrote');
like($app_back, qr/appointmentResetSend\(app, type, data,/, 'managerReset sends through the queue');
like($app_back, qr/timeout: 20000/, 'a press the server never answers cannot hold the queue forever');
my $reset_urls = () = $app_back =~ /url: '\/manager\/reset'/g;
is($reset_urls, 1, 'there is one reset request, inside the queue');

done_testing();

