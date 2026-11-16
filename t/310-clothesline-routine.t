# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Hang.pm lib/JawnOS/Manager/Part14.pm public/js/manager/manager/09_app_back.js public/js/manager/clothesline.js
# covers:    The clothesline leads with the most common recent day's sequence,
#            not the latest day: a step moved earlier or later leaves the rest
#            in order, a step done twice is one pill at its next turn, and the
#            cadence may be every second, third, fifth ... day up to a month.
#            A routine keeps the day it began past midnight, and every press
#            re-hangs the line in the reply instead of waiting for the poll.
#            Only the appointments the person starts and stops themselves are
#            learned; a task or default step stays with its parent.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest ();
use RepoSource;

require JawnOS::Domain::Appointment;
require JawnOS::Domain::Hang;

sub row {
	my ($app, $ms, $type, $src) = @_;
	return { app => $app, timestamp => $ms, type => $type || 'stop', source_uuid => defined $src ? $src : '' };
}

# The common day: coffee and water happen twice, and a bed made early or late
# does not move the rest. The last two days are a reordered outlier, so a test
# that picks the latest day instead of the most common one fails.
my @common = qw(wake_up pee water coffee vape dump facebook breakfast water coffee vape make_up_bed);
my @outlier = qw(wake_up pee coffee water vape dump facebook breakfast make_up_bed water coffee vape);

my @rows;
for my $day (6 .. 13) {
	my $hour = 8 + ($day % 3);
	for my $i (0 .. $#common) {
		push @rows, row($common[$i], JawnOSTest::ts(2026, 11, $day, $hour, $i), 'stop');
		push @rows, row('cream', JawnOSTest::ts(2026, 11, $day, $hour, $i), 'stop', 'coffee-parent');
	}
}
for my $day (14 .. 15) {
	my $hour = 8 + ($day % 3);
	for my $i (0 .. $#outlier) {
		push @rows, row($outlier[$i], JawnOSTest::ts(2026, 11, $day, $hour, $i), 'stop');
	}
}
# a Sunday-only step, seen on two Sundays, so its day is knowable
push @rows, row('laundry', JawnOSTest::ts(2026, 11, 8,  10, 5), 'stop');
push @rows, row('laundry', JawnOSTest::ts(2026, 11, 15, 10, 5), 'stop');

my $monday = JawnOSTest::ts(2026, 11, 16, 9, 0);
my $scan = subs::clothesline_routine_scan(\@rows, $monday, window_days => 60, session_days => 14);

# --- only the person's own steps are learned --------------------------------
ok($scan->{'apps'}{'coffee'}, 'a step the person starts and stops is learned');
ok(!$scan->{'apps'}{'cream'}, 'a step a task or default started is left to its parent');
is($scan->{'apps'}{'laundry'}{'due'}, 0, 'a Sunday habit is not due on a Monday');
is($scan->{'start_app'}, 'wake_up', 'the routine starts at its common first step');

# --- the most common day, not the latest one --------------------------------
my $canonical = subs::clothesline_sequence_canonical($scan->{'sessions'}, $scan->{'start_app'});
ok($canonical && @{$canonical}, 'a canonical day was found');
is_deeply([ @{$canonical}[0 .. 7] ],
	[qw(wake_up pee water coffee vape dump facebook breakfast)],
	'the majority day leads, not the reordered last two days');
is_deeply(subs::clothesline_sequence_canonical([{ seq => [qw(phone weather wake_up pee water)] }], 'wake_up'),
	[qw(wake_up pee water)], 'a step checked before the routine is not made its head');

# --- a step moved earlier still leaves the rest in order --------------------
delete $scan->{'done'};
my $pre = subs::clothesline_sequence_anticipate($scan, $monday, limit => 8);
is_deeply($pre, [qw(wake_up pee water coffee vape dump facebook breakfast)],
	'from the start, the common day leads');

$scan->{'done'} = { wake_up => 1 };
my $next = subs::clothesline_sequence_anticipate($scan, $monday, limit => 8);
is_deeply($next, [qw(pee water coffee vape dump facebook breakfast make_up_bed)],
	'after the first step: the sequence in order, one coffee and one water, and the later step still follows');
is(scalar(grep { $_ eq 'coffee' } @{$next}), 1, 'the second coffee is not a second pill');
is(scalar(grep { $_ eq 'water' } @{$next}), 1, 'nor is the second water');

$scan->{'done'} = { map { $_ => 1 } qw(wake_up pee water coffee vape dump facebook breakfast make_up_bed) };
my $early_bed = subs::clothesline_sequence_anticipate($scan, $monday, limit => 8);
is_deeply($early_bed, [qw(water coffee vape)],
	'a bed made before the second coffee leaves the rest in order and does not repeat');

# --- a cadence of any length up to a month ----------------------------------
sub due_for {
	my ($app, $days, $now) = @_;
	my @r = map { row($app, JawnOSTest::ts(2026, 11, $_, 9, 0)) } @{$days};
	my $s = subs::clothesline_routine_scan(\@r, $now, window_days => 60, session_days => 14);
	return $s->{'apps'}{$app}{'due'};
}
sub due_on {
	my ($app, $days, $y, $m, $d) = @_;
	return due_for($app, $days, JawnOSTest::ts($y, $m, $d, 12, 0));
}

# every other day: 2, 4, ... 14, so 16 is its turn and 15 is not
is(due_on('every_2', [2, 4, 6, 8, 10, 12, 14], 2026, 11, 16), 1, 'every second day is due on its turn');
is(due_on('every_2', [2, 4, 6, 8, 10, 12, 14], 2026, 11, 15), 0, 'and off the day between');

# every third day: 1, 4, 7, 10, 13, so 16 is due and 15 is not
is(due_on('every_3', [1, 4, 7, 10, 13], 2026, 11, 16), 1, 'every third day is due on its turn');
is(due_on('every_3', [1, 4, 7, 10, 13], 2026, 11, 15), 0, 'and off the days between');

# every fifth day: 1, 6, 11, so 16 is due and 15 is not
is(due_on('every_5', [1, 6, 11], 2026, 11, 16), 1, 'every fifth day is due on its turn');
is(due_on('every_5', [1, 6, 11], 2026, 11, 15), 0, 'and off the days between');

# every thirtieth day, the far end of the range
my @monthly = (
	row('every_30', JawnOSTest::ts(2026, 10, 17, 9, 0)),
	row('every_30', JawnOSTest::ts(2026, 11, 16, 9, 0)),
);
my $m30 = subs::clothesline_routine_scan(\@monthly, JawnOSTest::ts(2026, 11, 16, 12, 0), window_days => 60, session_days => 14);
is($m30->{'apps'}{'every_30'}{'due'}, 1, 'a monthly step is due on its day');
is($m30->{'apps'}{'every_30'}{'cadence'}, 30, 'the month is the cadence it learned');
my $m30b = subs::clothesline_routine_scan(\@monthly, JawnOSTest::ts(2026, 11, 17, 12, 0), window_days => 60, session_days => 14);
is($m30b->{'apps'}{'every_30'}{'due'}, 0, 'and off the rest of the month');

# --- the routine keeps its own day past midnight ----------------------------
my @night = (
	row('wake_up', JawnOSTest::ts(2026, 11, 15, 14, 0)),
	row('pee',     JawnOSTest::ts(2026, 11, 15, 14, 5)),
	row('lunch',   JawnOSTest::ts(2026, 11, 15, 18, 0)),
	row('dinner',  JawnOSTest::ts(2026, 11, 15, 23, 0)),
	row('bed',     JawnOSTest::ts(2026, 11, 16, 2, 0)),
);
my $night = subs::clothesline_routine_scan(\@night, JawnOSTest::ts(2026, 11, 16, 3, 0), window_days => 60, session_days => 14);
is($night->{'done'}{'wake_up'}, 1, 'the morning is still finished after midnight');
is($night->{'done'}{'dinner'}, 1, 'the evening steps are finished too');
is($night->{'current'}{'active'}, 1, 'the routine is still under way');
my $next_morning = subs::clothesline_routine_scan(\@night, JawnOSTest::ts(2026, 11, 16, 15, 0), window_days => 60, session_days => 14);
ok(!$next_morning->{'done'}{'wake_up'}, 'a new morning starts with nothing finished');

# --- the head keeps its order, the rest follows alphabetically ---------------
my $head = [
	{ app => 'water', formatted_name => 'Water' },
	{ app => 'pee',   formatted_name => 'Pee' },
];
my $tail = [
	{ app => 'water',     formatted_name => 'Water' },
	{ app => 'coffee',    formatted_name => 'Coffee' },
	{ app => 'breakfast', formatted_name => 'Breakfast' },
];
my $line = subs::clothesline_line_order($head, $tail);
is_deeply([ map { $_->{'app'} } @{$line} ], [qw(water pee breakfast coffee)],
	'the anticipatory head keeps its order, the tail is alphabetical, and no app repeats');

# --- the wiring ------------------------------------------------------------
my $appointment = read_file(repo_root() . '/lib/JawnOS/Domain/Appointment.pm');
like($appointment, qr/next if defined \$r->\{'source_uuid'\}/,
	'the scan leaves a spawned step out');
like($appointment, qr/sub clothesline_sequence_canonical/,
	'the most common day is what the line reads');
like($appointment, qr/\$cadence = 30/,
	'the cadence reaches a month');

my $hang = read_file(repo_root() . '/lib/JawnOS/Domain/Hang.pm');
like($hang, qr/clothesline_sequence_anticipate\(\$daily/, 'the rail hangs the anticipatory head');
like($hang, qr/clothesline_line_order/, 'the head leads and the tail is alphabetised');
like($hang, qr/\$cadence >= 2 \|\| \$hourly/, 'a cadence past daily reaches the tail on its day');
unlike($hang, qr/clothesline_hang_slots/, 'the per-slot repeat helper is gone');
like($hang, qr/\$item->\{'head'\} = 1/, 'the anticipatory head is marked for the divider');

my $clothesline_js = read_file(repo_root() . '/public/js/manager/clothesline.js');
like($clothesline_js, qr/headCount/, 'the rail finds where the anticipatory head ends');
like($clothesline_js, qr/divider/, 'the rail draws the divider there');
like($clothesline_js, qr/clothesLinePos\['centred'\]/, 'the divider opens at the middle on the first draw');

# --- every press re-hangs the line, and the reply carries it ----------------
my $part14 = read_file(repo_root() . '/lib/JawnOS/Manager/Part14.pm');
like($part14, qr/&subs::hang_to_dry\(\);/, 'a press re-hangs the line at once');
like($part14, qr/\$returner->\{'clothesline'\}/, 'the reply carries the new line');
like($part14, qr/console_command\('calculator'\)/, 'the other managers are told to refresh');
my $app_back = read_file(repo_root() . '/public/js/manager/manager/09_app_back.js');
like($app_back, qr/response\['clothesline'\]/, 'the pressing page redraws the rail from the reply');

done_testing();
