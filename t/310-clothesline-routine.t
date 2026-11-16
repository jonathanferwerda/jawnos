# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Hang.pm
# covers:    The clothesline reads a routine's times, not only its busiest hour:
#            a morning step hangs in the minute order it happens, a step done
#            twice hangs twice, a weekday habit and an every-other-day habit are
#            due only on their own days, and a configured hour still hangs once
#            when its history has nothing regular to place.

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

# JawnOSTest pins TZ to UTC, so every civil time below is the minute-of-day the
# scan sees. 2026-11-16 is a Monday.
my $monday = JawnOSTest::ts(2026, 11, 16, 10, 0);

sub scan_for {
	my ($rows, $now) = @_;
	return subs::clothesline_routine_scan($rows, $now || $monday, window_days => 14);
}

# --- the order is the minute order, not the alphabet -------------------------
my @order;
for my $d (2 .. 15) {
	push @order, { app => 'second', timestamp => JawnOSTest::ts(2026, 11, $d, 9, 10) };
	push @order, { app => 'first',  timestamp => JawnOSTest::ts(2026, 11, $d, 9, 40) };
	push @order, { app => 'third',  timestamp => JawnOSTest::ts(2026, 11, $d, 9, 25) };
}
my $ordered = scan_for(\@order);
is_deeply([ map { $_->{'minute'} } @{ $ordered->{'second'}{'slots'} } ], [550],
	'the step kept at ten past is placed at ten past');
is_deeply([ map { $_->{'minute'} } @{ $ordered->{'third'}{'slots'} } ], [565],
	'the step at twenty-five past is between the others');
is_deeply([ map { $_->{'minute'} } @{ $ordered->{'first'}{'slots'} } ], [580],
	'not at the alphabet its name falls under');
is($ordered->{'second'}{'minute'}, 550, 'its order key is that minute');
is($ordered->{'first'}{'minute'}, 580, 'and the later step keeps the later key');

# --- a step done twice is two slots -----------------------------------------
my @twice;
for my $d (2 .. 15) {
	push @twice, { app => 'coffee', timestamp => JawnOSTest::ts(2026, 11, $d, 9, 5) };
	push @twice, { app => 'coffee', timestamp => JawnOSTest::ts(2026, 11, $d, 9, 40) };
}
my $coffee = scan_for(\@twice);
is(scalar @{ $coffee->{'coffee'}{'slots'} }, 2, 'a step done twice in the hour is two slots');
is_deeply([ map { $_->{'minute'} } @{ $coffee->{'coffee'}{'slots'} } ], [545, 580],
	'each slot sits at its own time, in order');

# --- a repeated slot in another hour is not in this one ----------------------
my @spread;
for my $d (2 .. 15) {
	push @spread, { app => 'water', timestamp => JawnOSTest::ts(2026, 11, $d, 9, 5) };
	push @spread, { app => 'water', timestamp => JawnOSTest::ts(2026, 11, $d, 10, 5) };
}
my $water = scan_for(\@spread);
is(scalar @{ $water->{'water'}{'slots'} }, 2, 'the same step an hour later is its own slot');

# --- a habit on named days is due only on those days ------------------------
my @laundry = (
	{ app => 'laundry', timestamp => JawnOSTest::ts(2026, 11,  1, 9, 15) },  # Sun
	{ app => 'laundry', timestamp => JawnOSTest::ts(2026, 11,  8, 9, 15) },  # Sun
);
my $on_monday = scan_for(\@laundry, JawnOSTest::ts(2026, 11, 16, 10, 0));
is($on_monday->{'laundry'}{'slots'}[0]{'due'}, 0,
	'a Sunday habit is not due on a Monday');
my $on_sunday = scan_for(\@laundry, JawnOSTest::ts(2026, 11, 15, 10, 0));
is($on_sunday->{'laundry'}{'slots'}[0]{'due'}, 1,
	'it is due on the Sunday it keeps');

# --- every other day keeps its own parity -----------------------------------
my @alternate;
for my $d (2, 4, 6, 8, 10, 12, 14) {
	push @alternate, { app => 'due_today', timestamp => JawnOSTest::ts(2026, 11, $d, 9, 20) };
}
for my $d (1, 3, 5, 7, 9, 11, 13, 15) {
	push @alternate, { app => 'off_today', timestamp => JawnOSTest::ts(2026, 11, $d, 9, 20) };
}
my $alternating = scan_for(\@alternate);
is($alternating->{'due_today'}{'slots'}[0]{'due'}, 1,
	'an every-other-day step whose turn is today is due');
is($alternating->{'off_today'}{'slots'}[0]{'due'}, 0,
	'the one that ran yesterday is the day off, not due again');

# --- a daily routine is due every day ---------------------------------------
my @daily;
for my $d (2 .. 15) {
	push @daily, { app => 'daily', timestamp => JawnOSTest::ts(2026, 11, $d, 9, 30) };
}
my $daily = scan_for(\@daily);
is($daily->{'daily'}{'slots'}[0]{'due'}, 1, 'a daily routine is due on a Monday');

# --- the rail places one pill per due time, capped ---------------------------
my $routine = {
	minute => 545,
	slots => [
		{ minute => 545, hour => 9, days => 5, due => 1 },
		{ minute => 580, hour => 9, days => 5, due => 0 },
		{ minute => 605, hour => 10, days => 5, due => 1 },
	],
};
my $auto = subs::clothesline_hang_slots({ app => 'coffee', formatted_name => 'Coffee' }, $routine, 9);
is(scalar @{$auto}, 1, 'an automatic hang keeps only the due time in this hour');
is($auto->[0]{'minute'}, 545, 'and keeps its own minute for the order');

my $chosen = subs::clothesline_hang_slots({ app => 'coffee', formatted_name => 'Coffee' }, $routine, 9, all => 1, fallback => 1);
is(scalar @{$chosen}, 2, 'a configured hour hangs every time the routine keeps there');
is_deeply([ map { $_->{'minute'} } @{$chosen} ], [545, 580], 'in minute order, due or not');

my $nothing_here = subs::clothesline_hang_slots({ app => 'coffee', formatted_name => 'Coffee' }, $routine, 8, all => 1, fallback => 1);
is(scalar @{$nothing_here}, 1, 'a configured hour with no regular time still hangs once');
is($nothing_here->[0]{'minute'}, 510, 'at the start of that hour, so it is not misplaced');

my $many = {
	slots => [ map { { minute => 540 + ($_ * 5), hour => 9, days => 5, due => 1 } } 0 .. 5 ],
};
is(scalar @{ subs::clothesline_hang_slots({ app => 'vape' }, $many, 9) }, 3,
	'a step repeated all hour is capped at three pills');

# --- the automatic hang reads the due days, not a seven-day hour ------------
my $hang = read_file(repo_root() . '/lib/JawnOS/Domain/Hang.pm');
unlike($hang, qr/hour_days'\}\s*>=\s*7/, 'the automatic hang no longer needs seven days in the hour');
like($hang, qr/clothesline_hang_slots\(\$app_data, \$daily->\{\$app\}/, 'it hangs the slots the scan found');
like($hang, qr/\$ma <=> \$mb/, 'the rail is ordered by the minute, not the hour');

done_testing();
