# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Hang.pm
# covers:    The clothesline learns the sequence the person starts and stops
#            themselves, not a clock: a routine begun at eight or at ten puts
#            pee before water before coffee. Steps a task, default option or
#            default model started are left out. A step done twice is one pill
#            in the anticipatory head and the later steps still follow, and the
#            rest of the line is alphabetical. Weekday and every-other-day
#            habits are due only on their own days.

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

# The routine the person gave: coffee and water happen twice in it, and a step a
# parent starts (cream) sits beside coffee but is not the person's own click.
my @routine = qw(wake_up pee water coffee vape dump facebook breakfast water coffee vape make_up_bed);

my @rows;
# eight days of the same sequence, begun at a different hour each day: the order
# is what the line learns, not the clock
for my $day (8 .. 15) {
	my $hour = 8 + ($day % 3);
	for my $i (0 .. $#routine) {
		push @rows, row($routine[$i], JawnOSTest::ts(2026, 11, $day, $hour, $i), 'stop');
		# the cream behind the coffee: started by its parent, so not learned
		push @rows, row('cream', JawnOSTest::ts(2026, 11, $day, $hour, $i), 'stop', 'coffee-parent');
	}
}
# a Sunday-only step, seen on two Sundays, so its day is knowable
push @rows, row('laundry', JawnOSTest::ts(2026, 11, 8,  10, 5), 'stop');
push @rows, row('laundry', JawnOSTest::ts(2026, 11, 15, 10, 5), 'stop');

my $monday = JawnOSTest::ts(2026, 11, 16, 9, 0);
my $scan = subs::clothesline_routine_scan(\@rows, $monday, window_days => 14);

# --- only the person's own steps are learned --------------------------------
ok($scan->{'apps'}{'coffee'}, 'a step the person starts and stops is learned');
ok(!$scan->{'apps'}{'cream'}, 'a step a task or default started is left to its parent');
is($scan->{'apps'}{'laundry'}{'due'}, 0, 'a Sunday habit is not due on a Monday');

# --- the order is the sequence, independent of the hour --------------------
my $pre = subs::clothesline_sequence_anticipate($scan, $monday, limit => 8);
is_deeply($pre, [qw(wake_up pee water coffee vape dump facebook breakfast)],
	'the routine leads from its first step, at nine in the morning as at eight');

$scan->{'current'} = { active => 1, seq => ['wake_up'], start => 0, running => undef };
my $next = subs::clothesline_sequence_anticipate($scan, $monday, limit => 8);
is_deeply($next, [qw(pee water coffee vape dump facebook breakfast make_up_bed)],
	'after the first step: the sequence in order, one coffee and one water, and the later step still follows');
is(scalar(grep { $_ eq 'coffee' } @{$next}), 1, 'the second coffee is not a second pill');
is(scalar(grep { $_ eq 'water' } @{$next}), 1, 'nor is the second water');

# the same routine read on the next day has the same order
my $tuesday = JawnOSTest::ts(2026, 11, 17, 9, 0);
my $tuesday_scan = subs::clothesline_routine_scan(\@rows, $tuesday, window_days => 14);
$tuesday_scan->{'current'} = { active => 1, seq => ['wake_up'], start => 0, running => undef };
my $tuesday_next = subs::clothesline_sequence_anticipate($tuesday_scan, $tuesday, limit => 8);
is_deeply($tuesday_next, $next, 'the day changes, the order does not');
my $sunday_scan = subs::clothesline_routine_scan(\@rows, JawnOSTest::ts(2026, 11, 15, 15, 0), window_days => 14);
is($sunday_scan->{'apps'}{'laundry'}{'due'}, 1, 'the Sunday habit is due on its Sunday');

# --- every other day keeps its own parity -----------------------------------
my @alternate;
for my $d (2, 4, 6, 8, 10, 12, 14) {
	push @alternate, row('due_today', JawnOSTest::ts(2026, 11, $d, 9, 0));
}
for my $d (1, 3, 5, 7, 9, 11, 13, 15) {
	push @alternate, row('off_today', JawnOSTest::ts(2026, 11, $d, 9, 0));
}
my $alternating = subs::clothesline_routine_scan(\@alternate, $monday, window_days => 14);
is($alternating->{'apps'}{'due_today'}{'due'}, 1,
	'an every-other-day step whose turn is today is due');
is($alternating->{'apps'}{'off_today'}{'due'}, 0,
	'the one that ran yesterday is the day off, not due again');

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
like($appointment, qr/sub clothesline_sequence_anticipate/,
	'the anticipatory walk is the learned sequence');

my $hang = read_file(repo_root() . '/lib/JawnOS/Domain/Hang.pm');
like($hang, qr/clothesline_sequence_anticipate\(\$daily/, 'the rail hangs the anticipatory head');
like($hang, qr/clothesline_line_order/, 'the head leads and the tail is alphabetised');
unlike($hang, qr/clothesline_hang_slots/, 'the per-slot repeat helper is gone');

done_testing();
