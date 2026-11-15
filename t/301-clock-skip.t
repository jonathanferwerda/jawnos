# tests-for: lib/JawnOS/Domain/Clock.pm lib/JawnOS/Domain/Clock3.pm lib/JawnOS/Controller/manager_clock.pm
# covers:    Skip for today is one local day, not "everything before this moment".
#            The ring path, the phone's next-wake search and the row's countdown
#            all read the same skip, a stale notice cannot name the wrong day,
#            and two Skip taps cannot overwrite each other's request file.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use RepoSource;

my $root = repo_root();
my $clock = read_file("$root/lib/JawnOS/Domain/Clock.pm");
my $tick  = read_file("$root/lib/JawnOS/Domain/Clock3.pm");
my $route = read_file("$root/lib/JawnOS/Controller/manager_clock.pm");

# --- the skipped occurrence does not sound, the same time tomorrow does ------
my $alarm = { hour => 9, minute => 25, days => [0 .. 6], enabled => 1, uuid => 'skip-test' };
my $eight = ts(2026, 11, 14, 8, 0, 0);   # Saturday, 8am
my $fire  = subs::clock_alarm_next_ms($alarm, $eight);
is($fire, ts(2026, 11, 14, 9, 25, 0), 'the next run is today at 9:25');

$alarm->{'skip_fire'} = $fire;
# The firing loop looks back two minutes, so it computes the same occurrence.
my $candidate = subs::clock_alarm_next_ms($alarm, $eight - 120000);
is($candidate, $fire, 'the firing loop computes the skipped occurrence');
ok(subs::clock_alarm_skip_covers($alarm, $candidate),
	'the skipped occurrence is covered');
ok(!subs::clock_alarm_skip_covers($alarm, $fire + 86400000),
	'the same time the next day still rings');

# --- the whole local day is skipped, and the next search starts past it ------
is(subs::clock_alarm_skip_from($alarm, $eight), ts(2026, 11, 15, 0, 0, 0) - 1,
	'the search resumes just before the next local midnight');
is(subs::clock_alarm_next_ms($alarm, subs::clock_alarm_skip_from($alarm, $eight)),
	ts(2026, 11, 15, 9, 25, 0), 'the phone is armed for tomorrow, not today');

# An edit later the same day is still the day that was skipped.
my $later = { %$alarm, hour => 10, minute => 0 };
ok(subs::clock_alarm_skip_covers($later, ts(2026, 11, 14, 10, 0, 0)),
	'a time edited to later the same day stays skipped');
ok(!subs::clock_alarm_skip_covers($later, ts(2026, 11, 15, 10, 0, 0)),
	'and tomorrow at the edited time rings');

# --- a skip named for a later day resumes after it ---------------------------
my $friday = ts(2026, 11, 13, 12, 0, 0);
my $monday = ts(2026, 11, 16, 9, 25, 0);
my $weekday = { hour => 9, minute => 25, days => [1, 2, 3, 4, 5], enabled => 1, skip_fire => $monday };
is(subs::clock_alarm_skip_from($weekday, $friday), $monday,
	'a future skip is where the search starts');
is(subs::clock_alarm_next_ms($weekday, subs::clock_alarm_skip_from($weekday, $friday)),
	ts(2026, 11, 17, 9, 25, 0), 'skipping Monday arms Tuesday');

# --- a spend skip is not reused ---------------------------------------------
my $spent = { %$alarm, skip_fire => ts(2026, 11, 13, 9, 25, 0) };
is(subs::clock_alarm_skip_from($spent, $eight), $eight,
	'an old skip does not move the search');
ok(!subs::clock_alarm_skip_covers($spent, $fire), 'nor does it cover today');

# --- the skip target is a real occurrence -----------------------------------
my $ringing = { hour => 9, minute => 25, days => [0 .. 6], enabled => 1 };
is(subs::clock_alarm_skip_target($ringing, 0, ts(2026, 11, 14, 9, 25, 30)),
	ts(2026, 11, 14, 9, 25, 0), 'skip while ringing names today');

# A pre-notice posted before the alarm was rescheduled carries the old moment;
# trusting it would skip a day that has no fire at that time.
my $stale_at = ts(2026, 11, 14, 7, 0, 0);
is(subs::clock_alarm_skip_target($ringing, $stale_at, $eight),
	ts(2026, 11, 14, 9, 25, 0), 'a stale notice at is replaced by the real occurrence');

is(subs::clock_alarm_skip_target($ringing, $fire, $eight), $fire,
	'a notice that still matches the schedule is kept');

# A snooze is the occurrence a skip should take.
my $snoozed = { %$ringing, snooze_until => ts(2026, 11, 14, 9, 40, 0) };
is(subs::clock_alarm_skip_target($snoozed, 0, $eight),
	ts(2026, 11, 14, 9, 40, 0), 'the pending snooze is the occurrence skipped');

# --- the firing loop and the route use the shared helpers -------------------
like($tick, qr/next if &clock_alarm_skip_covers\(\$alarm, \$fire_at\);/,
	'the firing loop asks the shared day matcher');
unlike($tick, qr/\$fire_at <= \$alarm->\{'skip_fire'\}/,
	'the old "everything before this moment" test is gone');
like($route, qr/clock_alarm_skip_target\(\$alarm, 0, \$now\)/,
	'the browser skip names a real occurrence');
unlike($route, qr/\$next = \$now;/, 'the route no longer stores "now" as a skip');

# --- skip requests are queued, not overwritten ------------------------------
like($clock, qr/sub clock_skip_dir \{/,
	'the phone has a queue directory');
like($clock, qr/readdir\(\$dh\)/, 'every request file is read');
like($clock, qr/rename\(\$file, \$work\)/,
	'a request is taken before it is read, so a concurrent write survives');
like($clock, qr/clock_alarm_skip_target\(\$alarm, \$data->\{'at'\}, \$now\)/,
	'the worker validates the moment the phone named');

done_testing();
