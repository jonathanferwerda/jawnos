# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Hang.pm lib/JawnOS/Domain/Backup.pm lib/JawnOS/Manager/Part14.pm lib/JawnOS/Manager/Part32.pm lib/JawnOS/Controller/manager_misc6.pm lib/JawnOS/Controller/manager_misc8.pm lib/JawnOS/Controller/manager_misc12.pm templates/apps/clothesline.html.ep templates/apps/clothesline/schedules.html.ep templates/apps/clothesline/settings.html.ep public/js/manager/manager/09_app_back.js public/js/manager/clothesline.js public/js/manager/clothesline/01_timeline.js
# covers:    The clothesline leads with the most common recent day's sequence,
#            not the latest day: a step moved earlier or later leaves the rest
#            in order, a step done twice is one pill at its next turn, and the
#            cadence may be every second, third, fifth ... day up to a month.
#            The day is read as waves - a long pause between steps starts the
#            next one - and the line shows the wave under way plus one ahead,
#            never two, and the head moves by the order the person takes the day
#            in, never by the hour on the clock. A day is the night's own end:
#            the learned rests place it, a short night counts, a brief waking in
#            the night is a blip, and a long daytime gap is not a day. Each day
#            carries its profile (a day shift and a night shift are two shapes),
#            and the most recent rest selects the shape the line leads with. The
#            sockets say whether the house was up or out: a night the house was
#            out for is one inferred day, a house never seen at all invents
#            nothing, and a long house-up afternoon is only a data gap. A
#            routine keeps the day it began past midnight, and
#            every press re-hangs the line in the reply instead of waiting for
#            the poll. Only the appointments the person starts and stops
#            themselves are learned; a task or default step stays with its
#            parent. The days are the ground the person is on (home, a friend's,
#            a hotel), read on the house clock, not the box's UTC. The
#            alphabetical tail carries only an app whose own time slots or
#            budget say it is on now, plus a running app that has time slots
#            of its own; an app with no registration never hangs there. A step
#            that is running sits where the routine usually stops it, so the
#            pill at the left is always the next one to press. The settings
#            dialog walks the whole week: each day drawn as the routines it
#            runs, read in the order of the day and named for the hours their
#            pills happen, with the habits the one learned day missed put back
#            by their hour, a typed find box and a routine picker to add a pill,
#            Reset to learned to put the day back, and the near two months read
#            once for all seven.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::Collection;
use JawnOSTest ();
use RepoSource;

require JawnOS::Domain::Appointment;
require JawnOS::Domain::Hang;
require JawnOS::Domain::Backup;

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

# `->hashes` hands back a Mojo::Collection, which is array-like but is not an
# ARRAY: the scan used to discard it as no rows, leaving the line with nothing
my $collection = Mojo::Collection->new(
	row('wake_up', JawnOSTest::ts(2026, 11, 16, 8, 0), 'stop'),
	row('pee',     JawnOSTest::ts(2026, 11, 16, 8, 5), 'stop'),
);
my $from_collection = subs::clothesline_routine_scan($collection, $monday, window_days => 60, session_days => 14);
ok($from_collection->{'apps'}{'wake_up'}, 'rows from ->hashes (a Mojo::Collection) are read, not discarded');

# --- the most common day, not the latest one --------------------------------
my $canonical = subs::clothesline_sequence_canonical($scan->{'sessions'}, $scan->{'start_app'});
ok($canonical && @{$canonical->{'seq'}}, 'a canonical day was found');
is_deeply([ @{$canonical->{'seq'}}[0 .. 7] ],
	[qw(wake_up pee water coffee vape dump facebook breakfast)],
	'the majority day leads, not the reordered last two days');
is_deeply(subs::clothesline_sequence_canonical([{ seq => [qw(phone weather wake_up pee water)] }], 'wake_up')->{'seq'},
	[qw(wake_up pee water)], 'a step checked before the routine is not made its head');

# --- a step moved earlier still leaves the rest in order --------------------
delete $scan->{'done'};
my $pre = subs::clothesline_sequence_anticipate($scan, $monday, limit => 8);
is_deeply([ map { $_->{'app'} } @{$pre->{'list'}} ], [qw(wake_up pee water coffee vape dump facebook breakfast)],
	'from the start, the common day leads');

$scan->{'done'} = { wake_up => 1 };
my $next = subs::clothesline_sequence_anticipate($scan, $monday, limit => 8);
is_deeply([ map { $_->{'app'} } @{$next->{'list'}} ], [qw(pee water coffee vape dump facebook breakfast make_up_bed)],
	'after the first step: the sequence in order, one coffee and one water, and the later step still follows');
is(scalar(grep { $_->{'app'} eq 'coffee' } @{$next->{'list'}}), 1, 'the second coffee is not a second pill');
is(scalar(grep { $_->{'app'} eq 'water' } @{$next->{'list'}}), 1, 'nor is the second water');

$scan->{'done'} = { map { $_ => 1 } qw(wake_up pee water coffee vape dump facebook breakfast make_up_bed) };
my $early_bed = subs::clothesline_sequence_anticipate($scan, $monday, limit => 8);
is_deeply([ map { $_->{'app'} } @{$early_bed->{'list'}} ], [qw(water coffee vape)],
	'a bed made before the second coffee leaves the rest in order and does not repeat');

# --- the day runs in waves, and the line shows one wave ahead ---------------
# one session with the step times: the wake-up wave at 8, the lunch wave four
# hours later, and the evening wave five hours after that.
my $base = JawnOSTest::ts(2026, 11, 16, 8, 0);
my @wt = (map { $base + ($_ * 60000) } (0, 5, 10, 15));
push @wt, $base + (4 * 3600000), $base + (5 * 3600000);
push @wt, $base + (10 * 3600000);
my $wseq = [{ seq => [qw(wake_up pee water coffee lunch tea bed)], times => \@wt, start => $base }];
my $wcanon = subs::clothesline_sequence_canonical($wseq, 'wake_up', 90 * 60 * 1000);
is_deeply($wcanon->{'waves'}, [0, 0, 0, 0, 1, 1, 2],
	'a long pause between steps starts a new wave');

# with no gap pinned, the day's own longer breaks are the boundaries: five
# minutes and under, then twenty and sixty, then four hours - only the last
# is beyond the top fifth of these gaps (sixty minutes), so it alone splits
my $ad = JawnOSTest::ts(2026, 11, 16, 8, 0);
my @ad_t = ($ad, $ad + 5 * 60000, $ad + 10 * 60000, $ad + 15 * 60000, $ad + 35 * 60000, $ad + 95 * 60000, $ad + 335 * 60000);
my $adcanon = subs::clothesline_sequence_canonical([{ seq => [qw(a b c d e f g)], times => \@ad_t }], undef);
is_deeply($adcanon->{'waves'}, [0, 0, 0, 0, 0, 0, 1],
	'the default wave gap follows the day\'s own longer breaks');

my $wscan = { sessions => $wseq, start_app => 'wake_up' };
my $wone = subs::clothesline_sequence_anticipate($wscan, $base + 60000);
is_deeply([ map { $_->{'app'} } @{$wone->{'list'}} ], [qw(wake_up pee water coffee lunch tea)],
	'the line shows the wave under way and the one after, never two ahead');
is($wone->{'current_wave'}, 0, 'the wave under way is the one the last finished step sits in');

$wscan->{'done'} = { wake_up => 1, pee => 1, water => 1, coffee => 1 };
my $wtwo = subs::clothesline_sequence_anticipate($wscan, $base + 60000);
is_deeply([ map { $_->{'app'} } @{$wtwo->{'list'}} ], [qw(lunch tea)],
	'the finished wake-up wave leaves the lunch wave, and the evening waits');

$wscan->{'done'} = { map { $_ => 1 } qw(wake_up pee water coffee lunch tea) };
my $wthree = subs::clothesline_sequence_anticipate($wscan, $base + 60000);
is_deeply([ map { $_->{'app'} } @{$wthree->{'list'}} ], [qw(bed)],
	'the evening wave arrives once the lunch wave is done');

my $wall = subs::clothesline_sequence_anticipate($wscan, $base + 60000, all_waves => 1);
is_deeply([ map { $_->{'app'} } @{$wall->{'list'}} ], [qw(wake_up pee water coffee lunch tea bed)],
	'the whole day can be asked for: every wave, nothing taken out for what is done');
is_deeply([ map { $_->{'wave'} } @{$wall->{'list'}} ], [0, 0, 0, 0, 1, 1, 2],
	'and each step still knows the wave it belongs to');

# --- a step the day keeps twice is not pulled to its far occurrence --------
# The learned day brushes its teeth in the morning and again at night. Pressing
# the morning one twice (or adding a noon one) must not consume the night's
# occurrence and carry the head to the evening with it.
my $bseq = [qw(wake_up toothbrushing lunch work toothbrushing dinner bed)];
my $btimes = [
	$base,
	$base + (10 * 60000),
	$base + (270 * 60000),
	$base + (300 * 60000),
	$base + (810 * 60000),
	$base + (840 * 60000),
	$base + (870 * 60000),
];
my $bcanon = { seq => $bseq, waves => [ 0, 0, 1, 1, 2, 2, 3 ], times => $btimes };
my $bscan = {
	apps => { map { $_ => { due => 1 } } @{$bseq} },
	current => { start => $base },
	done => { wake_up => 1, toothbrushing => 2, lunch => 1, work => 1 },
	done_ms => {
		wake_up => [$base],
		toothbrushing => [ $base + (10 * 60000), $base + (180 * 60000) ],
		lunch => [ $base + (270 * 60000) ],
		work => [ $base + (300 * 60000) ],
	},
};
my $bhead = subs::clothesline_sequence_anticipate($bscan, $base + (310 * 60000),
	limit => 10, canonical => $bcanon);
is($bhead->{'current_wave'}, 1,
	'two morning toothbrushings leave the head at the lunch wave, not the night');
ok(!(grep { $_->{'app'} eq 'bed' } @{$bhead->{'list'}}),
	'and the bed is not named as a next step while the day is still at lunch');

# A bed made at nine in the morning is a morning position, not the night's.
$bscan->{'done'} = { wake_up => 1, bed => 1 };
$bscan->{'done_ms'} = { wake_up => [$base], bed => [ $base + (60 * 60000) ] };
my $bearly = subs::clothesline_sequence_anticipate($bscan, $base + (60 * 60000),
	limit => 10, canonical => $bcanon);
is($bearly->{'current_wave'}, 0, 'a bed made at nine does not carry the head to the night');
ok(!(grep { $_->{'app'} eq 'bed' } @{$bearly->{'list'}}), 'and the finished bed is taken out');

# The same progress earlier or later on the clock sits in the same wave: the
# clock is not what places the day.
my $latebase = $base + (3 * 3600000);
my $late = {
	apps => { map { $_ => { due => 1 } } @{$bseq} },
	current => { start => $latebase },
	done => { wake_up => 1, toothbrushing => 2, lunch => 1, work => 1 },
	done_ms => {
		wake_up => [$latebase],
		toothbrushing => [ $latebase + (10 * 60000), $latebase + (180 * 60000) ],
		lunch => [ $latebase + (270 * 60000) ],
		work => [ $latebase + (300 * 60000) ],
	},
};
my $latecanon = { seq => $bseq, waves => [ 0, 0, 1, 1, 2, 2, 3 ],
	times => [ map { $_ + (3 * 3600000) } @{$btimes} ] };
my $lhead = subs::clothesline_sequence_anticipate($late, $latebase + (310 * 60000),
	limit => 10, canonical => $latecanon);
is($lhead->{'current_wave'}, $bhead->{'current_wave'},
	'the same progress at a later hour sits in the same wave');

# --- a night ends the day, however short it is ------------------------------
# Six hours of quiet was a guess. The day is now the learned night's own end: a
# five-hour night opens a day as surely as a nine-hour one, and what was
# finished before it is not today's. The steps come in bursts here because a day
# of lone presses is a day of blips, which the rest learning absorbs into one
# long quiet - a burst is what the house's own day looks like.
sub burst {
	my ($rows, $app, $y, $m, $d, $h, $mi, $n) = @_;
	$n = 8 unless defined $n;
	push @{$rows}, row($app, JawnOSTest::ts($y, $m, $d, $h, $mi + 5 * $_)) for 0 .. $n - 1;
	return $rows;
}

# A five-hour night (22:55 -> 04:00) over four nights, every daytime gap shorter.
my @quiet5;
for my $day (1 .. 4) {
	burst(\@quiet5, 'first',   2026, 11, $day, 4,  0);
	burst(\@quiet5, 'second',  2026, 11, $day, 8,  0);
	burst(\@quiet5, 'third',   2026, 11, $day, 12, 0);
	burst(\@quiet5, 'fourth',  2026, 11, $day, 16, 0);
	burst(\@quiet5, 'fifth',   2026, 11, $day, 19, 0);
	burst(\@quiet5, 'evening', 2026, 11, $day, 22, 20);
}
burst(\@quiet5, 'first', 2026, 11, 5, 4, 0);
my $q5 = subs::clothesline_routine_scan(\@quiet5, JawnOSTest::ts(2026, 11, 5, 4, 40),
	window_days => 60, session_days => 14);
is($q5->{'day'}{'start'}, JawnOSTest::ts(2026, 11, 5, 4, 0),
	'a five-hour night opens the day at its wake');
is_deeply([ sort keys %{ $q5->{'done'} } ], ['first'],
	'and the evening before the night is not today\'s');

# A nine-hour night (22:55 -> 08:00) with one day's seven-hour daytime gap, the
# house up all through it: idle time, not a night, so the day goes on across it.
my @quiet7;
for my $day (1 .. 3) {
	burst(\@quiet7, 'first',   2026, 11, $day, 8,  0);
	burst(\@quiet7, 'second',  2026, 11, $day, 10, 0);
	burst(\@quiet7, 'third',   2026, 11, $day, 12, 0);
	burst(\@quiet7, 'fourth',  2026, 11, $day, 14, 0);
	burst(\@quiet7, 'fifth',   2026, 11, $day, 16, 0);
	burst(\@quiet7, 'sixth',   2026, 11, $day, 19, 0);
	burst(\@quiet7, 'evening', 2026, 11, $day, 22, 20);
}
burst(\@quiet7, 'first', 2026, 11, 4, 8,  0);
burst(\@quiet7, 'fifth', 2026, 11, 4, 16, 0);
my $q7 = subs::clothesline_routine_scan(\@quiet7, JawnOSTest::ts(2026, 11, 4, 17, 0),
	window_days => 60, session_days => 14, live => { down => [], up => 1 });
is($q7->{'day'}{'start'}, JawnOSTest::ts(2026, 11, 4, 8, 0),
	'a seven-hour daytime gap with the house up does not open a day');
is(scalar keys %{ $q7->{'done'} }, 2, 'the day keeps both of its stretches of steps');
ok($q7->{'done'}{'first'} && $q7->{'done'}{'fifth'},
	'the steps on both sides of the gap are still today\'s');

# --- a curated day hands in its own order, and still advances ---------------
# The person put lunch first, then the morning; the coffee is already taken, and
# the tea is not due today by the learned cadence. The day keeps its order, the
# done step leaves, and the pill the person placed stays.
my $cscan = { done => { coffee => 1 }, running => {},
	apps => { lunch => { due => 1 }, coffee => { due => 1 }, water => { due => 1 }, tea => { due => 0 } } };
my $cday = subs::clothesline_sequence_anticipate($cscan, $base + 60000,
	limit => 10, sequence => [qw(lunch coffee water tea)], waves => [ 1, 0, 0, 1 ], force_due => 1);
is_deeply([ map { $_->{'app'} } @{$cday->{'list'}} ], [qw(lunch water tea)],
	'a curated day keeps its order and leaves the step already taken');
is_deeply([ map { $_->{'wave'} } @{$cday->{'list'}} ], [1, 0, 1],
	'and each step keeps the routine it was put in');
my $cnow = subs::clothesline_sequence_anticipate($cscan, $base + 60000,
	limit => 10, sequence => [qw(lunch coffee water tea)], waves => [ 1, 0, 0, 1 ],
	force_due => 1, next_wave => 0);
is_deeply([ map { $_->{'app'} } @{$cnow->{'list'}} ], [qw(water)],
	'with the next routine off, only the routine under way remains');
my $ckeep = subs::clothesline_sequence_anticipate($cscan, $base + 60000,
	limit => 10, sequence => [qw(lunch coffee water tea guitar)], waves => [ 1, 0, 0, 1, 0 ],
	force_due => 1, keep => ['guitar'], next_wave => 0);
is(scalar(grep { $_->{'app'} eq 'guitar' } @{$ckeep->{'list'}}), 1,
	'a hand-added pill is not left behind by the wave limit');

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

# --- a recognized night closes the day; an unlearned quiet does not ---------
# The quiet above is not a night the person keeps (one rest is not a shape), so
# the old rule still carries their day past midnight. Once the house has learned
# their nights, the day closes at the night's first step: at three in the
# morning the evening is finished and the new day has not begun, so the line
# waits for the wake instead of offering yesterday's leftovers.
my @closed;
for my $day (1 .. 4) {
	my $n = 0;
	for (my $h = 7; $h <= 19; $h += 2) { burst(\@closed, 'step' . (++$n), 2026, 11, $day, $h, 0); }
	burst(\@closed, 'evening', 2026, 11, $day, 22, 20);
}
my $night_scan = subs::clothesline_routine_scan(\@closed, JawnOSTest::ts(2026, 11, 5, 3, 0),
	window_days => 60, session_days => 14);
is(scalar keys %{ $night_scan->{'done'} }, 0, 'at three in the morning nothing is finished');
ok(!$night_scan->{'current'}{'active'}, 'and the routine is not under way');
ok(!defined $night_scan->{'current'}{'start'}, 'and the run has no start');
ok($night_scan->{'day'}{'resting'}, 'the day is closed at its night');
is($night_scan->{'day'}{'closed_at'}, JawnOSTest::ts(2026, 11, 4, 22, 55),
	'at the first step of the night');
ok(!$night_scan->{'done'}{'evening'} && !$night_scan->{'done'}{'step7'},
	'and none of the finished day is carried over');
my $night_head = subs::clothesline_sequence_anticipate($night_scan, JawnOSTest::ts(2026, 11, 5, 3, 0), limit => 5);
is($night_head->{'list'}[0]{'app'}, 'step1', 'the head waits at the day\'s first step');
# the same still an hour before the morning's first step
my $before_wake = subs::clothesline_routine_scan(\@closed, JawnOSTest::ts(2026, 11, 5, 6, 50),
	window_days => 60, session_days => 14);
is(scalar keys %{ $before_wake->{'done'} }, 0, 'and it is still closed just before the wake');
ok(!$before_wake->{'current'}{'active'}, 'with nothing under way yet');
# the wake - the new day's first step - opens the day, and yesterday stays behind
my @woken = @closed;
burst(\@woken, 'step1', 2026, 11, 5, 7, 0);
my $wake_scan = subs::clothesline_routine_scan(\@woken, JawnOSTest::ts(2026, 11, 5, 7, 40),
	window_days => 60, session_days => 14);
is($wake_scan->{'day'}{'start'}, JawnOSTest::ts(2026, 11, 5, 7, 0), 'the wake opens the new day');
ok(!$wake_scan->{'day'}{'resting'}, 'and the day is no longer resting');
is_deeply([ sort keys %{ $wake_scan->{'done'} } ], ['step1'],
	'with only the new day\'s steps finished');
ok($wake_scan->{'current'}{'active'}, 'and the routine under way again');

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

# --- a step that runs a while sits down where the routine stops it ----------
# Two weeks of mornings: the wake-up opens the day and is stopped after the
# breakfast, while the pee, the water and the coffee come and go inside it. The
# head leads with those short steps, not with the wake-up that is in hand.
sub long_row {
	my ($app, $start, $mins) = @_;
	return {
		app => $app,
		type => 'stop',
		timestamp => $start,
		stop_timestamp => $start + ($mins * 60000),
		source_uuid => '',
	};
}
my @long;
for my $day ( 2 .. 13 ) {
	my $base = JawnOSTest::ts(2026, 11, $day, 8, 0);
	push @long, long_row('wake_up', $base, 90);
	push @long, long_row('pee',     $base + (5 * 60000), 3);
	push @long, long_row('water',   $base + (10 * 60000), 2);
	push @long, long_row('coffee',  $base + (15 * 60000), 10);
}
my $lscan = subs::clothesline_routine_scan(\@long, JawnOSTest::ts(2026, 11, 16, 7, 0), window_days => 60, session_days => 14);
is($lscan->{'apps'}{'wake_up'}{'length'}, 90 * 60000, 'a step carries the length its own stops show');
is($lscan->{'apps'}{'coffee'}{'length'}, 10 * 60000, 'and so does a short one');
my $lcanon = subs::clothesline_sequence_canonical($lscan->{'sessions'}, $lscan->{'start_app'});
is_deeply($lcanon->{'seq'}, [qw(wake_up pee water coffee)], 'the day is read in the order the steps begin');
my $quiet = subs::clothesline_sequence_anticipate($lscan, JawnOSTest::ts(2026, 11, 16, 7, 0), limit => 8, canonical => $lcanon);
is_deeply([ map { $_->{'app'} } @{$quiet->{'list'}} ], [qw(wake_up pee water coffee)],
	'with nothing running the day leads with its first step');
$lscan->{'running'} = { wake_up => JawnOSTest::ts(2026, 11, 16, 8, 0) };
my $during = subs::clothesline_sequence_anticipate($lscan, JawnOSTest::ts(2026, 11, 16, 8, 5), limit => 8, canonical => $lcanon);
is_deeply([ map { $_->{'app'} } @{$during->{'list'}} ], [qw(pee water coffee wake_up)],
	'a running step moves down the head to where the routine usually stops it');

# --- an open session is the step in hand, a forgotten one is not ------------
my $start_scan = subs::clothesline_routine_scan(
	[ { app => 'wake_up', type => 'start', timestamp => JawnOSTest::ts(2026, 11, 16, 8, 0), source_uuid => '' } ],
	JawnOSTest::ts(2026, 11, 16, 8, 30), window_days => 60, session_days => 14);
is_deeply($start_scan->{'running'}, { wake_up => JawnOSTest::ts(2026, 11, 16, 8, 0) },
	'an open session is read as the step running now');
my $forgot_scan = subs::clothesline_routine_scan(
	[ { app => 'wake_up', type => 'start', timestamp => JawnOSTest::ts(2026, 11, 16, 8, 0), source_uuid => '' } ],
	JawnOSTest::ts(2026, 11, 16, 20, 0), window_days => 60, session_days => 14);
ok(!exists $forgot_scan->{'running'}{'wake_up'},
	'a session left open past the routine pause is not the step in hand');

# --- only an own registration wears in the tail -----------------------------
my @one_am = (0, 0, 1, 16, 'Nov', 2026, 'Mon', 319, 0);
ok(subs::clothesline_slot_wears({ time_plinko => { hour => ['1am'] } }, \@one_am),
	'a slot registered for this hour wears');
ok(!subs::clothesline_slot_wears({ time_plinko => { hour => ['6am'] } }, \@one_am),
	'a slot registered for another hour does not');
ok(subs::clothesline_slot_wears({ time_plinko => { hour => ['all'] } }, \@one_am),
	'an all-hours slot wears at any hour');
ok(!subs::clothesline_slot_wears({ time_plinko => {} }, \@one_am),
	'an app with no registration never hangs itself');
ok(!subs::clothesline_slot_wears({}, \@one_am),
	'and nor does a registration with no time slots at all');
ok(!subs::clothesline_slot_wears({ time_plinko => { hour => ['1am'], wday => ['Sun'] } }, \@one_am),
	'a multi-slot registration needs every slot to match');
ok(subs::clothesline_slot_wears({ time_plinko => { hour => ['1am'], wday => ['Mon'] } }, \@one_am),
	'and wears when they all do');
ok(subs::clothesline_slot_wears({ time_plinko => { hour => ['12pm'] } }, [0, 0, 12, 16, 'Nov', 2026, 'Mon', 319, 0]),
	'noon reads as 12pm');
ok(subs::clothesline_slot_wears({ time_plinko => { hour => ['12am'] } }, [0, 0, 0, 16, 'Nov', 2026, 'Mon', 319, 0]),
	'midnight reads as 12am');

ok(subs::clothesline_registered({ time_plinko => { hour => ['1am'] } }),
	'an app with a chosen time slot is registered');
ok(!subs::clothesline_registered({ time_plinko => { hour => [] } }),
	'but an empty slot list is no registration');
ok(!subs::clothesline_registered({ time_plinko => {} }),
	'and neither is an empty time_plinko');
ok(!subs::clothesline_registered({ duration_budget => ['neglected'] }),
	'a budget alone does not keep a running app on the line');
ok(!subs::clothesline_registered({}), 'nor does no clothesline setting at all');

# --- the person's own say over the anticipatory head -------------------------
my $head = [
	{ app => 'coffee', formatted_name => 'Coffee' },
	{ app => 'water',  formatted_name => 'Water' },
];
my ($kept, $included) = subs::clothesline_anticipation_apply($head,
	{ coffee => 'exclude', laundry => 'include', water => 'default' });
is_deeply([ map { $_->{'app'} } @{$kept} ], ['water'],
	'an excluded step leaves the anticipatory head');
is_deeply($included, ['laundry'],
	'an included app the routine has not learned is named for the front');
my ($all, $none) = subs::clothesline_anticipation_apply($head, {});
is_deeply([ map { $_->{'app'} } @{$all} ], [qw(coffee water)],
	'with no say the learned head is untouched');
is_deeply($none, [], 'and nothing is added to it');

# --- a phrase the Guide read is a registration of its own -------------------
ok(subs::clothesline_registered({ schedule_rule => { days => { '2026-12-25' => 1 } } }),
	'a phrase read by the Guide registers the app');
ok(!subs::clothesline_registered({ schedule_rule => { days => {} } }),
	'an empty phrase is no registration');

# --- the phrase's days and hours --------------------------------------------
my $yule = subs::clothesline_schedule_expand(
	{ plans => [ { kind => 'annual', month => 12, day => 25 }, { kind => 'annual', month => 12, day => 26 } ], hours => [15, 16, 17] },
	JawnOSTest::ts(2026, 12, 20, 18, 0));
ok($yule->{'days'}{'2026-12-25'}, 'Christmas is one of the phrase\'s days');
ok($yule->{'days'}{'2026-12-26'}, 'Boxing Day too');
is_deeply($yule->{'hours'}, [15, 16, 17], 'and the hour span is kept');
my $all_day = subs::clothesline_schedule_expand(
	{ plans => [ { kind => 'annual', month => 2, day => 14 } ] }, JawnOSTest::ts(2026, 2, 1, 18, 0));
is_deeply($all_day->{'hours'}, [], 'a phrase that names no hours hangs all day');
ok($all_day->{'days'}{'2026-02-14'}, 'and its day is named');

# --- the day and hour the phrase matches ------------------------------------
my $yule_moment = JawnOSTest::ts(2026, 12, 25, 20, 0);
my ($yule_day, $yule_hour) = subs::clothesline_house_day($yule_moment);
ok(subs::clothesline_schedule_wears({ schedule_rule => { days => { $yule_day => 1 }, hours => [ $yule_hour ] } }, $yule_moment),
	'a phrase wears on its day, in its hours');
ok(!subs::clothesline_schedule_wears({ schedule_rule => { days => { $yule_day => 1 }, hours => [ ($yule_hour + 1) % 24 ] } }, $yule_moment),
	'but not outside them');
ok(!subs::clothesline_schedule_wears({ schedule_rule => { days => { '1900-01-01' => 1 } } }, $yule_moment),
	'and not on a day it does not name');
ok(subs::clothesline_schedule_wears({ schedule_rule => { days => { $yule_day => 1 }, hours => [] } }, $yule_moment),
	'a day with no hours hangs all day');

# --- a phrase past its window is read again from its own plan ---------------
my $stale = { schedule_rule => { days => { '2020-12-25' => 1 }, plan => { plans => [ { kind => 'annual', month => 12, day => 25 } ] } } };
ok(subs::clothesline_schedule_renew($stale, JawnOSTest::ts(2026, 12, 20, 18, 0)),
	'a phrase whose last day has passed is read again');
ok($stale->{'schedule_rule'}{'days'}{'2026-12-25'}, 'and its next day is back');
my $done = { schedule_rule => { days => { '2020-12-25' => 1 },
	plan => { plans => [ { kind => 'annual', month => 12, day => 25, until => '2021-01-01' } ] } } };
ok(!subs::clothesline_schedule_renew($done, JawnOSTest::ts(2026, 12, 20, 18, 0)),
	'a phrase that named its end is left to expire');

my $status = subs::clothesline_schedule_status({ schedule_rule => {
	days => { '2026-12-25' => 1, '2026-12-26' => 1 }, hours => [15, 16, 17] } });
like($status, qr/\b2\b/, 'the status counts the days');
like($status, qr/2026-12-26/, 'and names the last of them');
like($status, qr/3pm/, 'and the first hour of the span');

# --- the phrase reader: no model, no appointment history --------------------
# The house's config carries the owner's written birthday; the sandbox config is
# minimal, so it is set here for the "my birthday" case.
local $subs::config = { %{ $subs::config || {} }, birthday => 'Jan. 1 2000 12pm' };
subs::setting_setter({ app => 'mom', setting => 'birthday', value => 'aug 26 1961' });
my $reader_now = JawnOSTest::ts(2026, 11, 16, 12, 0);

my $week = subs::clothesline_schedule_parse(
	'every weekday afternoon, sundays in the mornings, saturday all day', now => $reader_now);
is(scalar @{ $week->{'schedules'} || [] }, 3, 'comma-separated times of day are three schedules');
is_deeply($week->{'schedules'}[0]{'hours'}, [ 12 .. 16 ], 'the weekday card keeps its own afternoon hours');
is_deeply($week->{'schedules'}[1]{'hours'}, [ 6 .. 11 ], 'and Sunday its own morning hours');
is_deeply($week->{'schedules'}[2]{'hours'}, [], 'Saturday is all day');
is_deeply($week->{'schedules'}[1]{'plans'}, [ { kind => 'weekdays', weekdays => ['sun'] } ],
	'each schedule carries its own recurrence');

my $evening = subs::clothesline_schedule_parse('every day between 4pm and 6pm', now => $reader_now);
is_deeply($evening->{'schedules'}[0]{'hours'}, [16, 17],
	'4pm to 6pm is the 4pm and 5pm hours, not an until-date');
like($evening->{'schedules'}[0]{'say'}, qr/4pm/, 'and the card says the span in words');

my $dinner = subs::clothesline_schedule_parse('During dinner time on Sundays', now => $reader_now);
is_deeply($dinner->{'schedules'}[0]{'plans'}, [ { kind => 'weekdays', weekdays => ['sun'] } ],
	'dinner on Sundays is the Sunday recurrence');
is_deeply($dinner->{'schedules'}[0]{'hours'}, [17, 18, 19], 'dinner is the early evening hours');

my $third = subs::clothesline_schedule_parse('Each third wednesday of the month all day', now => $reader_now);
is($third->{'schedules'}[0]{'plans'}[0]{'kind'}, 'monthly_nth_weekday',
	'the third Wednesday is its own recurrence');
is($third->{'schedules'}[0]{'plans'}[0]{'nth'}, 3, 'the named third is kept');
is_deeply($third->{'schedules'}[0]{'hours'}, [], 'and it hangs all day');

my $mine = subs::clothesline_schedule_parse('On my birthday in the morning', now => $reader_now);
is_deeply($mine->{'schedules'}[0]{'plans'}, [ { kind => 'annual', month => 1, day => 1 } ],
	'my birthday reads the house birthday');
is_deeply($mine->{'schedules'}[0]{'hours'}, [ 6 .. 11 ], 'in the morning is the morning hours');
my $born = subs::clothesline_schedule_expand(
	{ plans => $mine->{'schedules'}[0]{'plans'}, hours => [6] }, $reader_now);
ok($born->{'days'}{'2027-01-01'}, 'and the birthday expands to its next date');

my $mom = subs::clothesline_schedule_parse("On Mom's birthday around dinner time", now => $reader_now);
is($mom->{'schedules'}[0]{'plans'}[0]{'kind'}, 'birthday',
	"a named person's birthday is the birthday recurrence");
is($mom->{'schedules'}[0]{'plans'}[0]{'person'}, 'mom', 'and the person is kept');

my $half = subs::clothesline_schedule_parse('9pm on saturdays for the first half hour of the hour', now => $reader_now);
is_deeply($half->{'schedules'}[0]{'hours'}, [21], '9pm is the nine o\'clock hour');
is_deeply($half->{'schedules'}[0]{'minutes'}, [ 0 .. 29 ], 'and the first half hour is the first thirty minutes');
my ($minute_day, $minute_hour, $minute) = subs::clothesline_house_day($reader_now);
ok(subs::clothesline_schedule_wears({ schedules => [ { days => { $minute_day => 1 }, hours => [ $minute_hour ], minutes => [ $minute ] } ] }, $reader_now),
	'a minute range is matched too');
ok(!subs::clothesline_schedule_wears({ schedules => [ { days => { $minute_day => 1 }, hours => [ $minute_hour ], minutes => [ ($minute + 30) % 60 ] } ] }, $reader_now),
	'and a minute outside it does not wear');

# a model that lists every minute means the whole hour, not a minute range
my $whole_hour = subs::clothesline_schedule_expand(
	{ plans => [ { kind => 'weekdays', weekdays => ['sun'] } ], hours => [9, 10, 11], minutes => [ 0 .. 59 ] }, $reader_now);
is_deeply($whole_hour->{'minutes'}, [], 'a full minute range is no minute restriction');
is_deeply($whole_hour->{'hours'}, [9, 10, 11], 'and the clock hours are kept');

# a model that answers a span with its two ends means the hours between them
my $ends = subs::clothesline_schedule_expand(
	{ plans => [ { kind => 'weekdays', weekdays => ['sun'] } ], hours => [9, 12] }, $reader_now);
is_deeply($ends->{'hours'}, [9, 10, 11], 'a span answered as 9 and 12 covers 9, 10 and 11');

# --- the anticipatory settings ---------------------------------------------
my $as = subs::clothesline_anticipatory_settings();
is($as->{'on'}, 1, 'the anticipatory head is on by default');
is($as->{'next_wave'}, 1, 'the next routine rides along by default');
is($as->{'on_reset'}, 1, 'a press recomputes the head by default');
is_deeply($as->{'days'}, {}, 'with no curated day');

subs::clothesline_anticipatory_save({
	on => 0, next_wave => 0, on_reset => 0,
	days => { '2026-11-16' => [ 'coffee', 'water' ], '2026-11-17' => undef },
});
my $saved = subs::clothesline_anticipatory_settings();
is($saved->{'on'}, 0, 'the head switch is stored');
is($saved->{'next_wave'}, 0, 'the next-routine switch is stored');
is($saved->{'on_reset'}, 0, 'the press switch is stored');
is_deeply($saved->{'days'}{'2026-11-16'}, [ 'coffee', 'water' ], 'a curated day is stored in order');
ok(!exists $saved->{'days'}{'2026-11-17'}, 'a null day returns to the learned routine');

subs::clothesline_anticipatory_save({ days => { '2026-11-18' => {
	apps => [ 'coffee', 'yogurt', 'banana' ],
	sections => { banana => 'w2', yogurt => 'w1', coffee => 'nonsense' } } } });
my $placed_day = subs::clothesline_anticipatory_settings()->{'days'}{'2026-11-18'};
is_deeply($placed_day->{'apps'}, [qw(coffee yogurt banana)],
	'a day keeps its pills in the order the dialog showed them');
is($placed_day->{'sections'}{'banana'}, 'w2', 'and the routine each pill was put in');
is($placed_day->{'sections'}{'yogurt'}, 'w1', 'for every pill that was placed');
ok(!exists $placed_day->{'sections'}{'coffee'}, 'a section that is not one is dropped');

# --- the head's settings and the line belong to the House -------------------
my $house_head = subs::setting_grabber({ app => '__president', setting => 'clothesline_anticipatory', device => 'all' });
ok(defined $house_head && length $house_head, 'the switches and days are saved on the House row');
ok(!defined subs::setting_grabber({ app => '__president', setting => 'clothesline_anticipatory' }),
	'and not on this device\'s own row');

subs::setting_setter({ app => 'soap', setting => 'clothesline', value => '{"hidden":"1"}',
	device => 'mobile', server_time => 100 });
subs::setting_setter({ app => 'soap', setting => 'clothesline', value => '{"hidden":"0"}',
	device => 'computer', server_time => 200 });
is(subs::clothesline_app_setting('soap'), '{"hidden":"0"}',
	'with no House row, the newest per-device copy is the one the line reads');
subs::setting_setter({ app => 'soap', setting => 'clothesline', value => '{"hidden":"all"}',
	device => 'all', server_time => 50 });
is(subs::clothesline_app_setting('soap'), '{"hidden":"all"}',
	'the House row wins over a newer per-device copy');
subs::setting_setter({ app => '__president', setting => 'clothesline', value => 'house-rail', device => 'all' });
is(subs::clothesline_house_setting('__president', 'clothesline'), 'house-rail',
	'the rail reads the House row');

my $week = subs::clothesline_anticipatory_week();
is(scalar @{$week}, 7, 'the dialog walks seven days');
like($week->[0]{'key'}, qr/^\d{4}-\d{2}-\d{2}$/, 'each day carries its date');
ok(ref $week->[0]{'learned'} eq 'ARRAY', 'and the learned list it would show');
ok(ref $week->[0]{'apps'} eq 'ARRAY', 'and the list the person would edit');
ok(ref $week->[0]{'phases'} eq 'ARRAY', 'and the routines the day runs, as sections');
ok(ref $week->[0]{'learned_phases'} eq 'ARRAY', 'with the learned day kept for Reset to learned');

# --- a day drawn as the routines it runs ------------------------------------
# the morning at seven, the midday at one, the evening at seven; the last pill
# no wave knows, because the person added it
my $pscan = { apps => {
	soap => { hour => 7 }, coffee => { hour => 8 },
	lunch => { hour => 13 }, dinner => { hour => 19 } } };
my $prows = [
	{ app => 'soap', wave => 0 }, { app => 'coffee', wave => 0 },
	{ app => 'lunch', wave => 1 }, { app => 'dinner', wave => 2 } ];
my $phases = subs::clothesline_anticipatory_phases(
	[qw(soap coffee lunch dinner guitar)], $prows, $pscan);
is_deeply([ map { $_->{'label'} } @{$phases} ], [qw(Morning Midday Evening Added)],
	'each routine is named for the hour its first pill happens');
is_deeply([ map { $_->{'apps'} } @{$phases} ], [ [qw(soap coffee)], ['lunch'], ['dinner'], ['guitar'] ],
	'a pill no routine names keeps its own last section');
is_deeply([ map { $_->{'hour'} } @{$phases} ], [7, 13, 19, undef],
	'each routine carries the first hour of its pills');
# a routine is named for the hour most of its pills happen, not the first one's:
# a single 2am step must not name the morning the night
my $early = { apps => { come => { hour => 2 }, soap => { hour => 7 }, coffee => { hour => 8 },
	water => { hour => 9 }, tea => { hour => 9 } } };
my $mixed = subs::clothesline_anticipatory_phases([qw(come soap coffee water tea)],
	[ map { { app => $_, wave => 0 } } qw(come soap coffee water tea) ], $early);
is($mixed->[0]{'hour'}, 9, 'a routine takes the hour most of its pills happen');
is($mixed->[0]{'label'}, 'Morning', 'so one odd step does not move it to the night');

# the day runs into the small hours: one in the morning ends the day, it does
# not open it
my $nscan = { apps => { sleep => { hour => 2 }, soap => { hour => 7 } } };
my $night = subs::clothesline_anticipatory_phases([qw(sleep soap)],
	[ { app => 'sleep', wave => 0 }, { app => 'soap', wave => 1 } ], $nscan);
is_deeply([ map { $_->{'apps'} } @{$night} ], [ ['soap'], ['sleep'] ],
	'the small hours sort after the morning rather than before it');
my $curated = subs::clothesline_anticipatory_phases([qw(lunch soap)], $prows, $pscan);
is_deeply([ map { $_->{'apps'} } @{$curated} ], [ ['soap'], ['lunch'] ],
	'a curated day keeps its own pills, each in its routine');
my $only = subs::clothesline_anticipatory_phases([qw(guitar)], $prows, $pscan);
is($only->[0]{'key'}, 'more', 'a day of added pills only is one section');

# The pauses that end a routine can fall out of clock order - a day that opens
# with dinner and reaches the morning later. The dialog still reads the day the
# way it is lived.
my $late = [ { app => 'dinner', wave => 0 }, { app => 'soap', wave => 1 }, { app => 'lunch', wave => 2 } ];
my $sorted = subs::clothesline_anticipatory_phases([qw(dinner soap lunch)], $late, $pscan);
is_deeply([ map { $_->{'apps'} } @{$sorted} ], [ ['soap'], ['lunch'], ['dinner'] ],
	'the routines are sorted by the time of day, not by where the pause fell');

# A pill the person put in a routine is in that routine, whatever the day learned.
my $placed = subs::clothesline_anticipatory_phases([qw(soap guitar)], $prows, $pscan, { guitar => 'w1' });
is_deeply([ map { $_->{'apps'} } @{$placed} ], [ ['soap'], ['guitar'] ],
	'a pill the person put in a routine stays there');
is($placed->[1]{'key'}, 'w1', 'and keeps that routine, not the day\'s last section');
my $moved = subs::clothesline_anticipatory_phases([qw(lunch)], $prows, $pscan, { lunch => 'more' });
is($moved->[0]{'key'}, 'more', 'a pill moved to the added section says so');

# --- the habits the one day read can leave out ------------------------------
# the routine comes from the day most like the others, so a step done most days
# but not on that day would otherwise never show
my $hscan = { apps => {
	soap => { hour => 7, due => 1, recent_days => 12 },
	lunch => { hour => 13, due => 1, recent_days => 12 },
	yogurt => { hour => 12, due => 1, recent_days => 9 },
	rare => { hour => 12, due => 1, recent_days => 4 },
	off_today => { hour => 12, due => 0, recent_days => 9 } } };
my $hrows = [ { app => 'soap', wave => 0 }, { app => 'lunch', wave => 1 } ];
my $merged = subs::clothesline_anticipatory_habits($hrows, $hscan);
is_deeply([ map { $_->{'app'} } @{$merged} ], [qw(soap yogurt lunch)],
	'a habit the chosen day missed is put back by its hour');
is_deeply([ map { $_->{'wave'} } @{$merged} ], [0, 1, 1],
	'in the routine of the step it sits beside');

# the day's order can wander - a 2am step sits at its end - so a habit is placed
# by the hour it happens, not by the next step down the order
my $wander = { apps => {
	wake_up => { hour => 8 }, sleep => { hour => 2 }, lunch => { hour => 12 },
	dinner => { hour => 18 }, yogurt => { hour => 11, due => 1, recent_days => 9 } } };
my $wrow = [ { app => 'wake_up', wave => 0 }, { app => 'sleep', wave => 1 },
	{ app => 'lunch', wave => 2 }, { app => 'dinner', wave => 3 } ];
my $placed_rows = subs::clothesline_anticipatory_habits($wrow, $wander);
is_deeply([ map { $_->{'app'} } @{$placed_rows} ], [qw(wake_up sleep yogurt lunch dinner)],
	'a habit sits beside the hour it happens, not at the end of the order');
is_deeply([ map { $_->{'wave'} } @{$placed_rows} ], [0, 1, 2, 2, 3],
	'and takes the routine of the step beside it');

# a habit in the hour before another routine is that routine's run-up: the
# eleven o'clock yogurt belongs with the noon lunch, not the eleven o'clock steps
my $runup = { apps => {
	wake_up => { hour => 10 }, wash => { hour => 11 }, lunch => { hour => 12 },
	yogurt => { hour => 11, due => 1, recent_days => 9 } } };
my $rrow = [ { app => 'wake_up', wave => 0 }, { app => 'wash', wave => 0 }, { app => 'lunch', wave => 1 } ];
my $runup_rows = subs::clothesline_anticipatory_habits($rrow, $runup);
is($runup_rows->[2]{'app'}, 'yogurt', 'the habit sits just before the routine it leads into');
is($runup_rows->[2]{'wave'}, 1, 'and joins that routine, not the one an hour earlier');

# two routines may both carry a noon step; the habit joins the one the day
# reaches first
my $tie = { apps => {
	wake_up => { hour => 10 }, noon_a => { hour => 12 }, noon_b => { hour => 12 }, late => { hour => 17 },
	yogurt => { hour => 11, due => 1, recent_days => 9 } } };
my $trow = [ { app => 'wake_up', wave => 0 }, { app => 'noon_a', wave => 1 },
	{ app => 'noon_b', wave => 2 }, { app => 'late', wave => 2 } ];
my $tie_rows = subs::clothesline_anticipatory_habits($trow, $tie);
is($tie_rows->[1]{'app'}, 'yogurt', 'the habit still sits by the noon steps');
is($tie_rows->[1]{'wave'}, 1, 'and joins the routine the day reaches first');
is(subs::clothesline_anticipatory_wave_name(3), 'Night', 'the small hours are the night');
is(subs::clothesline_anticipatory_wave_name(undef), 'Routine', 'a wave with no clock is a routine');

# the week reads the near two months once, and can be handed that history
# --- what started a step ----------------------------------------------------
# a press or a tag is the person's own step, even as a child of a session they
# pressed (the banana taken with lunch); a task's checkbox, a default option and
# a schedule's repeat belong to whatever started them
my @origin_rows = (
	{ app => 'lunch', timestamp => JawnOSTest::ts(2026, 11, 15, 12, 0), type => 'stop', source => 'press' },
	{ app => 'banana', timestamp => JawnOSTest::ts(2026, 11, 15, 12, 1), type => 'stop', source => 'press', source_uuid => 'lunch-parent' },
	{ app => 'milk', timestamp => JawnOSTest::ts(2026, 11, 15, 12, 2), type => 'stop', source => 'default', source_uuid => 'tea-parent' },
	{ app => 'brushing_hair', timestamp => JawnOSTest::ts(2026, 11, 15, 12, 3), type => 'usual', source => 'task', source_uuid => 'task-parent' },
	{ app => 'repeat', timestamp => JawnOSTest::ts(2026, 11, 15, 12, 4), type => 'stop', source => 'schedule', source_uuid => 'base' },
	{ app => 'tagged', timestamp => JawnOSTest::ts(2026, 11, 15, 12, 5), type => 'stop', source => 'nfc' },
	{ app => 'legacy_child', timestamp => JawnOSTest::ts(2026, 11, 15, 12, 6), type => 'stop', source_uuid => 'old-parent' },
);
my $oscan = subs::clothesline_routine_scan(\@origin_rows, JawnOSTest::ts(2026, 11, 15, 13, 0),
	window_days => 60, session_days => 14);
ok($oscan->{'apps'}{'lunch'}, 'a pressed step is learned');
ok($oscan->{'apps'}{'banana'}, 'and a child the person pressed is their own step too');
ok($oscan->{'apps'}{'tagged'}, 'a tag is the person\'s hand as well');
ok(!$oscan->{'apps'}{'milk'}, 'a default option is not the person\'s step');
ok(!$oscan->{'apps'}{'brushing_hair'}, 'nor is a task\'s checkbox');
ok(!$oscan->{'apps'}{'repeat'}, 'nor a schedule\'s repeat');
ok(!$oscan->{'apps'}{'legacy_child'}, 'a child with no origin still belongs to its parent');

# --- what never belongs on the line ----------------------------------------
# a caller's number is filed as its own app; a named contact with a number is a
# person. The list is read once per request, so this seeds it before the first
# question.
subs::setting_setter({ app => '9052885933', setting => 'phone', value => '9052885933' });
subs::setting_setter({ app => 'matt_olson', setting => 'phone', value => '12268862001' });
%subs::clothesline_number_cache = ();
is(subs::clothesline_number_app('9052885933'), 1, 'a number filed as its own app is a caller');
is(subs::clothesline_number_app('28849'), 0, 'a number the house never filed is not one');
is(subs::clothesline_number_app('matt_olson'), 0, 'a named contact with a number is a person');

subs::setting_setter({ app => 'secret_thing', setting => 'visible', value => 'private', device => 'all' });
subs::visibility_cache_clear();
is(subs::clothesline_app_off_line('secret_thing'), 1, 'a private app is never on the line');
is(subs::clothesline_app_off_line('coffee'), 0, 'a public app still is');
is(subs::clothesline_app_off_line('9052885933'), 1, 'and neither is a spam caller');

my $quiet = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 16, 12, 0),
	history => [ [ row('hush', JawnOSTest::ts(2026, 11, 15, 9, 0), 'stop'),
		row('coffee', JawnOSTest::ts(2026, 11, 15, 9, 5), 'stop') ], 60, 14 ]);
subs::setting_setter({ app => 'hush', setting => 'visible', value => 'private', device => 'all' });
subs::visibility_cache_clear();
$quiet = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 16, 12, 0),
	history => [ [ row('hush', JawnOSTest::ts(2026, 11, 15, 9, 0), 'stop'),
		row('coffee', JawnOSTest::ts(2026, 11, 15, 9, 5), 'stop') ], 60, 14 ]);
ok(!$quiet->{'apps'}{'hush'}, 'a private step never reaches the routine');
ok($quiet->{'apps'}{'coffee'}, 'and the public steps still do');

# a private app is not a habit either, however often it happens
subs::setting_setter({ app => 'hush', setting => 'visible', value => 'private', device => 'all' });
subs::visibility_cache_clear();
my $hush_scan = { apps => {
	soap => { hour => 7, due => 1, recent_days => 12 },
	hush => { hour => 9, due => 1, recent_days => 12 } } };
my $hush_rows = subs::clothesline_anticipatory_habits([ { app => 'soap', wave => 0 } ], $hush_scan);
is_deeply([ map { $_->{'app'} } @{$hush_rows} ], [qw(soap)],
	'a private step the routine missed is not put back');

# a day curated before the app was made private must not carry it now
my $today_key = subs::day_key(subs::rightNow());
subs::clothesline_anticipatory_save({ days => { $today_key => [ 'coffee', 'secret_thing' ] } });
my ($today_card) = grep { $_->{'key'} eq $today_key } @{ subs::clothesline_anticipatory_week() };
ok($today_card, 'the week carries today');
ok(!grep { $_ eq 'secret_thing' } @{ $today_card->{'apps'} }, 'a curated private app is left out of the day');
ok(grep { $_ eq 'coffee' } @{ $today_card->{'apps'} }, 'and the public one is kept');
subs::clothesline_anticipatory_save({ days => { $today_key => undef } });

my $handed = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 16, 12, 0),
	history => [ [ row('handed_app', JawnOSTest::ts(2026, 11, 15, 9, 0)) ], 60, 14 ]);
ok($handed->{'apps'}{'handed_app'}, 'the history handed in is the one the day reads');
my $nothing = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 16, 12, 0), history => [ [], 60, 14 ]);
is(scalar(keys %{ $nothing->{'apps'} || {} }), 0,
	'an empty history is read as empty, not re-read from the database');

my $till = subs::clothesline_schedule_parse('every thursday between 3-6pm until July 24 2027', now => $reader_now);
is_deeply($till->{'schedules'}[0]{'hours'}, [15, 16, 17], 'a 3-6pm span runs from three to six');
ok($till->{'schedules'}[0]{'plans'}[0]{'until'}, 'and the until date is kept');

my $cards = subs::clothesline_schedule_cards({ schedules => [ {
	text => 'x', days => { '2026-12-25' => 1 }, hours => [16, 17], minutes => [],
	plan => { plans => [ { kind => 'annual', month => 12, day => 25 } ] } } ] });
is($cards->[0]{'count'}, 1, 'a card counts its days');
like($cards->[0]{'plans'}, qr/Dec 25/, 'and names the recurrence');
like($cards->[0]{'hours'}, qr/4pm/, 'and the hours');


# --- the wiring ------------------------------------------------------------
my $appointment = read_file(repo_root() . '/lib/JawnOS/Domain/Appointment.pm');
like($appointment, qr/next if defined \$r->\{'source_uuid'\}/,
	'the scan leaves a spawned step out');
like($appointment, qr/sub clothesline_sequence_canonical/,
	'the most common day is what the line reads');
like($appointment, qr/\$cadence = 30/,
	'the cadence reaches a month');
like($appointment, qr/sub clothesline_current_place/, 'the ground the person is on decides which days are read');
like($appointment, qr/sub clothesline_place_history/, 'a place away is learned from all its visits, however far back');
like($appointment, qr/\$opt\{'all_waves'\}/, 'the whole day can be asked for, not only the head');
like($appointment, qr/ref \$opt\{'history'\} eq 'ARRAY'/, 'a day can be handed the history already read');
like($appointment, qr/foreach my \$in \( \@in \)/, 'the place averages both axes, not just the longitude');
like($appointment, qr/clock_zone_house/, 'the scan runs on the house clock, not the box clock');

my $hang = read_file(repo_root() . '/lib/JawnOS/Domain/Hang.pm');
like($hang, qr/my \$history = \[ &clothesline_place_history\(\$now\) \]/,
	'the settings dialog reads the history once for the whole week');
like($hang, qr/phases => &clothesline_anticipatory_phases/,
	'and hands the template the day drawn as routines');
my $settings_ep = read_file(repo_root() . '/templates/apps/clothesline/settings.html.ep');
like($settings_ep, qr/class="clothes_day_find"/, 'the add box is typed into, not a list of every app a day');
like($settings_ep, qr/id="clothes_apps"/, 'the whole app list is carried once for the dialog');
like($settings_ep, qr/class="clothes_day_section"/, 'each day offers the routine a new pill joins');
unlike($settings_ep, qr/class="clothes_day_add"/, 'no day card carries the whole list its own');
like($hang, qr/clothesline_schedule_wears\(\$cl, \$server_time\)/,
	'the tail asks the phrase as well as the slots');
like($hang, qr/if \(\$cl->\{'hidden'\}\)/, 'a removed pill never hangs');
like($hang, qr/clothesline_anticipation_apply/, 'the head honours the anticipatory say');
like($hang, qr/clothesline_schedule_renew\(\$cl, \$server_time\)/, 'an expired phrase is read again');
like($hang, qr/clothesline_sequence_anticipate\(\$daily/, 'the rail hangs the anticipatory head');
like($hang, qr/clothesline_line_order/, 'the head leads and the tail is alphabetised');
like($hang, qr/clothesline_slot_wears\(\$cl, \\\@slot\)/, 'the tail asks the app\'s own registration');
like($hang, qr/clothesline_slot_now\(\$server_time\)/, 'the registration is read through the house-clock slot');
like($hang, qr/clock_zone_adopt/, 'the slot read adopts the house zone, not the box UTC');
like($hang, qr/clothesline_registered\(\$cl\)/, 'a running session is read for an app with its own time slots');
like($hang, qr/type = \? or type = \?/, 'and its running appointments are what keep it up');
unlike($hang, qr/clothesline_daily_auto/, 'no automatic hang fills the tail');
unlike($hang, qr/clothesline_hang_slots/, 'the per-slot repeat helper is gone');
like($hang, qr/\$item->\{'head'\} = 1/, 'the anticipatory head is marked for the divider');
like($hang, qr/\$item->\{'wave'\} = \$row->\{'wave'\}/, 'each anticipatory step carries its wave');
unlike($hang, qr/\@\{\$anticipated\} = grep \{ \$_->\{'app'\} ne \$running \}/,
	'a running step is not pulled to the head of the line');

my $clothesline_js = read_file(repo_root() . '/public/js/manager/clothesline.js');
like($clothesline_js, qr/headCount/, 'the rail finds where the anticipatory head ends');
like($clothesline_js, qr/divider/, 'the rail draws the divider there');
unlike($clothesline_js, qr/centred/, 'the line no longer opens on the divider');
like($clothesline_js, qr/clothesLinePos\['opened'\]/, 'the line opens at its own beginning');
like($clothesline_js, qr/clothesLinePos\['x'\] = 0;/, 'so the first pill sits at the left of the view');
like($clothesline_js, qr/ctx\.fillRect\(barX - 2, barTop, 4, barHeight\)/,
	'the divider between the head and the tail is four pixels wide');
like($clothesline_js, qr/v\['wave'\] != clothes\[i - 1\]\['wave'\]/, 'the rail draws a soft bar between waves');

# The band starts on headerHeight, so the room taskbar.js reserves for a top bar
# (a taskbar's own height, a top dock's box) moves the line without the band ever
# drawing under it. The press test reads the same two figures back.
like($clothesline_js, qr/var minHeight = headerHeight;/, 'the band starts on the desk\'s top line');
like($clothesline_js, qr/y <= clothesLinePos\['maxHeight'\] && y >= clothesLinePos\['minHeight'\]/,
	'and a press is judged against the band it was drawn in');

# --- every press re-hangs the line, and the reply carries it ----------------
my $part32 = read_file(repo_root() . '/lib/JawnOS/Manager/Part32.pm');
like($part32, qr/clothesline_slot_now/, 'the Configure slots are counted on the house clock too');

my $part14 = read_file(repo_root() . '/lib/JawnOS/Manager/Part14.pm');
like($part14, qr/&subs::hang_to_dry\(reuse_head =>/, 'a press re-hangs the line at once');
like($part14, qr/name => 'reset tail'/, 'the re-hang is forked, so the header reply does not wait for it');
like($part14, qr/type => 'clothesline'/, 'and the finished line is pushed when it is ready');
unlike($part14, qr/\$returner->\{'clothesline'\}/, 'the reply does not wait for the re-hang');
like($part14, qr/console_command\('calculator'\)/, 'the other managers are told to refresh');
my $app_back = read_file(repo_root() . '/public/js/manager/manager/09_app_back.js');
like($app_back, qr/response\['clothesline'\]/, 'the pressing page redraws the rail from the reply');

# --- the editor and the right-press menu ------------------------------------
my $template = read_file(repo_root() . '/templates/apps/clothesline.html.ep');
like($template, qr/setting="anticipatory"/, 'the editor carries the anticipatory select');
like($template, qr/class="clothes_schedule"/, 'and the phrase box');
like($template, qr/class="clothes_hidden"/, 'and the show-on-the-clothesline tick');
like($template, qr/schedule_status/, 'the editor prints what the Guide read');

my $timeline_js = read_file(repo_root() . '/public/js/manager/clothesline/01_timeline.js');
like($timeline_js, qr/clothesline_menu_row/, 'a right-press builds the rail menu');
like($timeline_js, qr/command == 'edit'/, 'with Edit');
like($timeline_js, qr/command == 'remove'/, 'Remove');
like($timeline_js, qr/command == 'bump'/, 'and Bump');
like($timeline_js, qr/manager\/clothesline\/schedule/, 'the phrase box asks the Guide');
like($timeline_js, qr/\.clothes_hidden/, 'the show tick hides and restores a pill');
like($timeline_js, qr/clothes_day_find_match/, 'a match in the find box adds its pill');
like($timeline_js, qr/sections\[app\] = phase/, 'a day saves the routine each pill was put in');
like($timeline_js, qr/clothes_day_section/, 'the picker chooses the routine a new pill joins');
like($timeline_js, qr/clothes_day_learned'\)\.html\(\)/, 'Reset to learned restores the routines, not a flat list');

my $misc12 = read_file(repo_root() . '/lib/JawnOS/Controller/manager_misc12.pm');
like($misc12, qr/sub action_41750/, 'the phrase has a route of its own');
like($misc12, qr/clothesline_schedule_read/, 'read by the house reader');
like($misc12, qr/clothesline_schedule_status/, 'and its answer is what the editor prints');
like($misc12, qr/clothesline_schedule_cards/, 'and the cards it read');
like($misc12, qr/param\('forget'\)/, 'a card can be forgotten');
like($misc12, qr/sub action_41751/, 'the anticipatory settings have a dialog route');
like($misc12, qr/sub action_41752/, 'and a save route');

my $settings_tpl = read_file(repo_root() . '/templates/apps/clothesline/settings.html.ep');
like($settings_tpl, qr/clothes_anticipatory_on/, 'the dialog carries the head switch');
like($settings_tpl, qr/clothes_anticipatory_next/, 'the next-routine switch');
like($settings_tpl, qr/clothes_anticipatory_reset/, 'the press switch');
like($settings_tpl, qr/clothes_day_card/, 'and a card per day of the week');
like($settings_tpl, qr/clothes_day_learned/, 'each keeping the learned list for a reset');
like($timeline_js, qr/clotheslineSettings/, 'the right-press menu opens it');
like($timeline_js, qr/clothes_day_find/, 'and a day is added to by typing its name');
like($timeline_js, qr/clothes_day_drop/, 'or dropped from');
like($timeline_js, qr/clothes_settings_save/, 'and saved');

# the slot list is the clock and the calendar, not the appointment history
my $part32 = read_file(repo_root() . '/lib/JawnOS/Manager/Part32.pm');
unlike($part32, qr/order by timestamp desc limit 1000/,
	'the slot list no longer reads the appointment history');
like($part32, qr/'values'/, 'it offers every value a slot can take');
like($part32, qr/clothesline_hour_word/, 'with the hours in the clock words the rail matches');
like($template, qr/\$td->\{'values'\}/, 'the editor draws every value');
unlike($template, qr/scalar \@\{\$td->\{'reoccuring'\}->\{\$re\}\}/,
	'and no appointment count');

my $card_tpl = read_file(repo_root() . '/templates/apps/clothesline/schedules.html.ep');
like($card_tpl, qr/clothes_schedule_card/, 'each schedule has its own card');
like($card_tpl, qr/clothes_schedule_forget/, 'with a Forget button');
like($card_tpl, qr/\$card->\{'count'\}/, 'and its day count');

# The rail is a cache, not a trigger: a house-wide rail must not make every
# machine pull the settings table on each five-minute hang.
like(subs::durable_settings_where(), qr/not \(app = '__president' and setting = 'clothesline'\)/,
	'the rail cache never starts a sync pull');

my $misc6 = read_file(repo_root() . '/lib/JawnOS/Controller/manager_misc6.pm');
like($misc6, qr/clothesline_house_setting\('__president', 'clothesline'\)/,
	'the desk and rail routes read the House line');
my $misc8 = read_file(repo_root() . '/lib/JawnOS/Controller/manager_misc8.pm');
like($misc8, qr/clothesline_house_setting/,
	'and so does the home status');
like($misc12, qr/clothesline_app_setting/, 'an app hang is read through the House row');
like($misc12, qr/device => 'all'/, 'and saved to it');
ok(index($hang, 'sequence => \@apps') >= 0, 'a curated day hands its own order to the advance');
like($hang, qr/force_due => 1/, 'and keeps a pill the learned cadence would skip');
like($hang, qr/if \(\$day_apps && !\$reused && \$daily\)/,
	'a reused head keeps the list already hung');
like($hang, qr/\$curated_running/, 'a step started again is put back in a curated head');

# --- the day's rests are learned from shape, not names ----------------------
# Four opaque apps and a steady day: the night is the day's longest quiet, and
# its window is learned from where that quiet falls, never from an app's name.
my @day_rows;
for my $day (1 .. 14) {
	for my $h ( 7 .. 21 ) {
		for my $m ( 0, 30 ) { push @day_rows, row('alpha', JawnOSTest::ts(2026, 11, $day, $h, $m)); }
	}
	push @day_rows, row('delta', JawnOSTest::ts(2026, 11, $day, 22, 0));
}
my $learned = subs::clothesline_rest_episodes(\@day_rows, JawnOSTest::ts(2026, 11, 14, 23, 0),
	window_days => 60);
ok(scalar @{ $learned->{'rests'} } >= 12, 'a rest is found for each day the activity closes');
ok(abs($learned->{'window'}{'start_hour'} - 22) < 1,
	'the rest window starts where the longest quiet starts');
ok(abs($learned->{'window'}{'stop_hour'} - 7) < 1,
	'and ends where the next day opens');
is(scalar @{ $learned->{'profiles'} }, 1, 'a steady day is one profile');

# A short night (three hours) is still a rest: the floor is the shape, not six
# hours. The wake day's steps stay close after it.
my @short_rows;
for my $day (1 .. 3) {
	for my $h ( 12 .. 22 ) { push @short_rows, row('alpha', JawnOSTest::ts(2026, 11, $day, $h, 0)); }
	for my $h ( 1 .. 12 ) { push @short_rows, row('beta', JawnOSTest::ts(2026, 11, $day + 1, $h, 0)); }
}
my $short = subs::clothesline_rest_episodes(\@short_rows, JawnOSTest::ts(2026, 11, 4, 23, 0),
	window_days => 60);
my ($short_rest) = grep { abs($_->{'length'} - (3 * 3600000)) < 60000 } @{ $short->{'rests'} };
ok($short_rest, 'a three-hour night is still a rest');
ok($short_rest && abs($short_rest->{'stop_hour'} - 1) < 1, 'and its wake is the day it opens');

# A five-minute phone check in the night is a blip: the rest stays one night.
my @blip_rows;
for my $day (1 .. 2) {
	for my $h ( 7 .. 21 ) {
		for my $m ( 0, 30 ) { push @blip_rows, row('alpha', JawnOSTest::ts(2026, 11, $day, $h, $m)); }
	}
	push @blip_rows, row('delta', JawnOSTest::ts(2026, 11, $day, 22, 0));
}
push @blip_rows, row('alpha', JawnOSTest::ts(2026, 11, 1, 23, 30));
push @blip_rows, row('beta',  JawnOSTest::ts(2026, 11, 1, 23, 35));
my $blipped = subs::clothesline_rest_episodes(\@blip_rows, JawnOSTest::ts(2026, 11, 2, 13, 0),
	window_days => 60);
my ($blip_rest) = grep { abs($_->{'length'} - (9 * 3600000)) < 60000 } @{ $blipped->{'rests'} };
ok($blip_rest, 'a night with a brief waking is still one nine-hour rest');
ok($blip_rest && scalar @{ $blip_rest->{'blips'} }, 'and the waking is recorded as a blip');

# Two shapes: a day shift and a night shift are two profiles, and the most
# recent rest selects the one the person is living now.
my @shift_rows;
for my $day (1 .. 7) {
	for my $h ( 6 .. 21 ) {
		for my $m ( 0, 30 ) { push @shift_rows, row('alpha', JawnOSTest::ts(2026, 11, $day, $h, $m)); }
	}
	push @shift_rows, row('alpha', JawnOSTest::ts(2026, 11, $day, 22, 0));
}
for my $day (8 .. 14) {
	for my $h ( 17 .. 23 ) { push @shift_rows, row('beta', JawnOSTest::ts(2026, 11, $day, $h, 0)); }
	for my $h ( 0 .. 9 ) { push @shift_rows, row('beta', JawnOSTest::ts(2026, 11, $day + 1, $h, 0)); }
}
my $shifts = subs::clothesline_rest_episodes(\@shift_rows, JawnOSTest::ts(2026, 11, 15, 12, 0),
	window_days => 60);
cmp_ok(scalar @{ $shifts->{'profiles'} }, '>=', 2,
	'a day shift and a night shift are at least two profiles (a transition day can be its own)');
ok($shifts->{'profile'} && abs($shifts->{'profile'}{'start_hour'} - 9) < 2,
	'the most recent rest selects the night-shift profile');

# --- the day is the night's own end, and each shape keeps its own day -------
# The rest learning says where the quiet was; the day segments say what it
# means: the wake that ends a night opens a day, a short night is still a
# night, a brief waking inside one is a blip, and a quiet the house was up for
# is idle time, not a boundary. Each segment carries its steps, the waves they
# fell into and where those waves paused, and the profile (the shape of the
# day) the rest that opened it belongs to.

# A steady day: bursts every two hours from 04:00, an evening burst at 22:20,
# and a five-hour night to the next 04:00. Five days, the last one only its wake.
my @steady;
for my $day (1 .. 4) {
	my $n = 0;
	for (my $h = 4; $h <= 20; $h += 2) { burst(\@steady, 'step' . (++$n), 2026, 11, $day, $h, 0); }
	burst(\@steady, 'evening', 2026, 11, $day, 22, 20);
}
burst(\@steady, 'step1', 2026, 11, 5, 4, 0);
my $days = subs::clothesline_day_segments(\@steady, undef, JawnOSTest::ts(2026, 11, 5, 4, 40),
	window_days => 60);
is($days->{'source'}, 'model', 'a week of nights is learned as days');
is(scalar @{ $days->{'segments'} }, 5, 'one day per night, and the day the last one opened');
my ($day4) = grep { $_->{'start'} == JawnOSTest::ts(2026, 11, 4, 4, 0) } @{ $days->{'segments'} };
ok($day4, 'a five-hour night opens its day at the wake');
is($day4->{'stop'}, JawnOSTest::ts(2026, 11, 5, 4, 0), 'and it runs to the next night\'s wake');
is($day4->{'day'}, subs::clothesline_day_index(JawnOSTest::ts(2026, 11, 4, 4, 0)),
	'and keeps the local day it opened on');
is(scalar @{ $day4->{'seq'} }, 80, 'the day holds exactly its own steps');
is_deeply($day4->{'waves'}, [ map { my $w = $_; ($w) x 8 } 0 .. 9 ],
	'each stretch of the day is its own wave');
is(scalar @{ $day4->{'pauses'} }, 9, 'and the day knows where its waves paused');
cmp_ok($day4->{'pauses'}[0]{'gap'}, '>', $day4->{'gap'}, 'a pause is a gap longer than the day\'s own');
is($day4->{'profile'}{'start_app'}, 'step1', 'the shape opens with the step its days open with');
is($day4->{'profile'}{'canonical'}{'seq'}[0], 'step1', 'and keeps its own canonical day');
ok(defined $day4->{'profile'}{'pause'} && $day4->{'profile'}{'pause'} > 0,
	'and the pause it runs in');
is($days->{'profile'}{'id'}, $day4->{'profile'}{'id'},
	'the most recent rest selects the shape the day runs in');

# A three-hour night (00:55 -> 04:00) ends the day just as a long one does: the
# late burst before it is yesterday's, not today's.
my @short;
for my $day (1 .. 4) {
	my $n = 0;
	for (my $h = 4; $h <= 20; $h += 2) { burst(\@short, 'step' . (++$n), 2026, 11, $day, $h, 0); }
	burst(\@short, 'evening', 2026, 11, $day, 22, 20);
	burst(\@short, 'late',    2026, 11, $day + 1, 0, 20);
}
burst(\@short, 'step1', 2026, 11, 5, 4, 0);
my $short_day = subs::clothesline_routine_scan(\@short, JawnOSTest::ts(2026, 11, 5, 4, 40),
	window_days => 60, session_days => 14);
is($short_day->{'day'}{'start'}, JawnOSTest::ts(2026, 11, 5, 4, 0),
	'a three-hour night still opens the day');
is(scalar keys %{ $short_day->{'done'} }, 1, 'and only today\'s steps are finished');
ok($short_day->{'done'}{'step1'} && !$short_day->{'done'}{'late'},
	'the late burst before the short night is yesterday\'s');

# A five-minute waking at 03:10 inside a seven-hour night is a blip: the night
# stays one rest, and what came before it is not a new day.
my @blip;
for my $day (1 .. 4) {
	my $n = 0;
	for (my $h = 6; $h <= 20; $h += 2) { burst(\@blip, 'step' . (++$n), 2026, 11, $day, $h, 0); }
	burst(\@blip, 'evening', 2026, 11, $day, 22, 20);
}
burst(\@blip, 'waking', 2026, 11, 2, 3, 10, 2);
burst(\@blip, 'waking', 2026, 11, 3, 3, 10, 2);
burst(\@blip, 'waking', 2026, 11, 4, 3, 10, 2);
burst(\@blip, 'step1',  2026, 11, 5, 6, 0);
my $blipped_day = subs::clothesline_day_segments(\@blip, undef, JawnOSTest::ts(2026, 11, 5, 6, 40),
	window_days => 60);
my ($blip_night) = grep { $_->{'start'} == JawnOSTest::ts(2026, 11, 3, 22, 55) } @{ $blipped_day->{'rests'} };
ok($blip_night, 'a five-minute waking does not split the night');
ok($blip_night && $blip_night->{'stop'} == JawnOSTest::ts(2026, 11, 4, 6, 0),
	'and the night keeps its own length');
ok($blip_night && scalar @{ $blip_night->{'blips'} }, 'with the waking kept as a blip');
my $blip_scan = subs::clothesline_routine_scan(\@blip, JawnOSTest::ts(2026, 11, 5, 6, 40),
	window_days => 60, session_days => 14);
is($blip_scan->{'day'}{'start'}, JawnOSTest::ts(2026, 11, 5, 6, 0),
	'and the day opens at the night\'s end, not at the waking');
ok(!$blip_scan->{'done'}{'waking'}, 'the night waking is not a step of today');

# A shortened night: four hours instead of nine, and the day still turns over
# at the early wake.
my @early;
for my $day (1 .. 3) {
	my $n = 0;
	for (my $h = 8; $h <= 20; $h += 2) { burst(\@early, 'step' . (++$n), 2026, 11, $day, $h, 0); }
	burst(\@early, 'evening', 2026, 11, $day, 22, 20);
}
my $n4 = 0;
for (my $h = 3; $h <= 19; $h += 2) { burst(\@early, 'early' . (++$n4), 2026, 11, 4, $h, 0); }
burst(\@early, 'evening', 2026, 11, 4, 22, 20);
my $early_day = subs::clothesline_routine_scan(\@early, JawnOSTest::ts(2026, 11, 4, 23, 0),
	window_days => 60, session_days => 14);
is($early_day->{'day'}{'start'}, JawnOSTest::ts(2026, 11, 4, 3, 0),
	'a shortened night opens its day at the early wake');
ok(!$early_day->{'done'}{'step5'}, 'and the long night\'s last day is not carried over');
ok($early_day->{'done'}{'evening'}, 'while the early day\'s own evening is');

# A seven-hour outage across the night is one inferred day: nothing was seen,
# but the day happened, and its wake is the morning's.
my @outage = @steady;
# one device was seen in the window: a sighting is what makes `down` mean the
# house was out rather than that nothing was ever retained (see the fresh-house
# case below)
my $outage_live = {
	devices => { 'test|house' => { background => 0, span_ms => 4 * 3600 * 1000, sessions => 1 } },
	down => [ [ JawnOSTest::ts(2026, 11, 4, 22, 55), JawnOSTest::ts(2026, 11, 5, 4, 0) ] ],
	up => 1,
	night => { start_hour => 22, end_hour => 4 },
};
my $out = subs::clothesline_day_segments(\@outage, $outage_live, JawnOSTest::ts(2026, 11, 5, 5, 0),
	window_days => 60);
my ($out_day) = grep { $_->{'start'} == JawnOSTest::ts(2026, 11, 5, 4, 0) } @{ $out->{'segments'} };
ok($out_day, 'an outage across the night still opens the day at its wake');
ok($out_day && $out_day->{'inferred'}, 'and that day is marked inferred');
is(scalar(grep { $_->{'start'} > JawnOSTest::ts(2026, 11, 4, 21, 0) && $_->{'start'} < JawnOSTest::ts(2026, 11, 5, 9, 0) } @{ $out->{'segments'} }), 1,
	'one day, not two: the outage opens one boundary');

# The same seven hours of no steps with the house up is idle time, not a day.
my $up_live = {
	devices => { 'test|house' => { background => 0, span_ms => 8 * 3600 * 1000, sessions => 1 } },
	down => [],
	up => 1,
};
my $idle = subs::clothesline_day_segments(\@outage, $up_live, JawnOSTest::ts(2026, 11, 5, 5, 0),
	window_days => 60);
is($idle->{'source'}, 'model', 'a quiet day with the house up is still a day');
ok(!grep({ $_->{'inferred'} } @{ $idle->{'segments'} }), 'but none of its days is inferred');

# the daily hours route hands the liveness (and a pinned pause) to the scan
my $hours = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 5, 5, 0),
	history => [ \@outage, 60, 14 ], live => $outage_live);
ok($hours->{'day'} && $hours->{'day'}{'inferred'}, 'the daily hours hand the liveness to the day');
my $pinned_hours = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 5, 5, 0),
	history => [ \@outage, 60, 14 ], pause => 6 * 3600 * 1000);
ok(!$pinned_hours->{'day'}, 'and a pinned pause keeps the old split there too');

# The house-up daytime gap is a data gap through the wired route too: the daily
# hours open no day at the burst after it.
my $gap_hours = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 4, 17, 0),
	history => [ \@quiet7, 60, 14 ], live => $up_live);
is($gap_hours->{'day'}{'start'}, JawnOSTest::ts(2026, 11, 4, 8, 0),
	'a seven-hour house-up daytime gap opens no day through the daily hours');
ok($gap_hours->{'done'}{'first'} && $gap_hours->{'done'}{'fifth'},
	'and both of its stretches of steps are still today\'s');

# A house whose sockets were never retained is not a house that was out. The
# daily hours read the liveness themselves here (no `live` handed in), get no
# sighting, and let the rests decide - so a fresh house opens no day it did not
# learn and marks none inferred.
&subs::db_query('delete from websockets');
my $fresh = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 5, 5, 0),
	history => [ \@outage, 60, 14 ]);
ok($fresh->{'day'} && $fresh->{'day'}{'start'} == JawnOSTest::ts(2026, 11, 5, 4, 0),
	'a fresh house still opens its day at the learned wake');
ok(!$fresh->{'day'}{'inferred'}, 'and no day is called inferred with no socket ever seen');
my $fresh_gap = subs::clothesline_daily_hours(JawnOSTest::ts(2026, 11, 4, 17, 0),
	history => [ \@quiet7, 60, 14 ]);
is($fresh_gap->{'day'}{'start'}, JawnOSTest::ts(2026, 11, 4, 8, 0),
	'and a daytime gap with no sighting at all still opens no day');

# Two shapes again, now through the days: the most recent rest picks the shape,
# and the shape keeps its own canonical day and its own opener.
my (@day_shift, @night_shift);
for my $day (1 .. 7) {
	my $n = 0;
	for my $h ( 6, 9, 12, 15, 18, 20 ) { burst(\@day_shift, 'day' . (++$n), 2026, 11, $day, $h, 0); }
	burst(\@day_shift, 'day_home', 2026, 11, $day, 22, 20);
}
for my $day (8 .. 14) {
	my $n = 0;
	for my $h ( 17, 19, 21, 23 ) { burst(\@night_shift, 'shift' . (++$n), 2026, 11, $day, $h, 0); }
	for my $h ( 1, 3, 5, 7 ) { burst(\@night_shift, 'shift' . (++$n), 2026, 11, $day + 1, $h, 0); }
}
my @shapes = (@day_shift, @night_shift);
my $shaped = subs::clothesline_day_segments(\@shapes, undef, JawnOSTest::ts(2026, 11, 15, 12, 0),
	window_days => 60);
cmp_ok(scalar @{ $shaped->{'profiles'} }, '>=', 2, 'the day shift and the night shift are two shapes');
ok($shaped->{'profile'} && abs($shaped->{'profile'}{'stop_hour'} - 17) < 2,
	'the most recent rest selects the night-shift day');
is($shaped->{'profile'}{'start_app'}, 'shift1', 'which opens with its own first step');
is($shaped->{'profile'}{'canonical'}{'seq'}[0], 'shift1', 'and keeps its own canonical day');
my $tagbase = JawnOSTest::ts(2026, 11, 16, 8, 0);
my $tagged = [
	{ seq => [qw(a b)], times => [ $tagbase - 86400000, $tagbase - 86400000 + 60000 ], start => $tagbase - 86400000, profile => 1 },
	{ seq => [qw(c d)], times => [ $tagbase, $tagbase + 60000 ], start => $tagbase, profile => 2 },
	{ seq => [qw(a b)], times => [ $tagbase + 86400000, $tagbase + 86400000 + 60000 ], start => $tagbase + 86400000, profile => 1 },
];
is_deeply(subs::clothesline_sequence_canonical($tagged, undef, undef, profile => 2)->{'seq'}, [qw(c d)],
	'the canonical day can be read for the selected profile alone');
is_deeply(subs::clothesline_sequence_canonical($tagged, undef, undef, profile => 1)->{'seq'}, [qw(a b)],
	'and each profile keeps its own day');
my $day_scan = subs::clothesline_routine_scan(\@day_shift, JawnOSTest::ts(2026, 11, 7, 23, 0),
	window_days => 60, session_days => 14);
is($day_scan->{'start_app'}, 'day1', 'the day-shift week keeps the day-shift opener');
is($day_scan->{'profile'}{'start_app'}, 'day1', 'and its own shape');

# --- a skipped wave does not hold the day back ------------------------------
# The same step opens the morning and the midday; only the midday one was
# pressed. The head moves to the midday wave and does not offer the morning
# again. A press at the morning's own hour still answers the morning, so a step
# the day keeps twice is never pulled to its far occurrence.
my $rbase = JawnOSTest::ts(2026, 11, 16, 8, 0);
my $rseq = [qw(water b c water d e)];
my $rtimes = [ $rbase, $rbase + 300000, $rbase + 600000,
	$rbase + (4 * 3600000), $rbase + (4 * 3600000) + 300000, $rbase + (4 * 3600000) + 600000 ];
my $rcanon = subs::clothesline_sequence_canonical([{ seq => $rseq, times => $rtimes, start => $rbase }], undef);
is_deeply($rcanon->{'waves'}, [ 0, 0, 0, 1, 1, 1 ], 'the morning and the midday are two waves');
my $rscan = {
	apps => { map { $_ => { due => 1 } } @{$rseq} },
	current => { start => $rbase },
	done => { water => 1 },
	done_ms => { water => [ $rbase + (4 * 3600000) ] },
	running => {},
};
my $rmid = subs::clothesline_sequence_anticipate($rscan, $rbase + (4 * 3600000) + 60000, canonical => $rcanon);
is($rmid->{'current_wave'}, 1, 'the midday wave starts when the morning was never done');
is_deeply([ map { $_->{'app'} } @{ $rmid->{'list'} } ], [qw(water d e)],
	'and the morning steps are not offered again');
my $rmorning = { %{$rscan}, done_ms => { water => [$rbase] } };
my $ram = subs::clothesline_sequence_anticipate($rmorning, $rbase + 60000, canonical => $rcanon);
is($ram->{'current_wave'}, 0, 'a press at the morning\'s own hour keeps the morning wave');
is_deeply([ map { $_->{'app'} } @{ $ram->{'list'} } ], [qw(b c water d e)],
	'and the midday occurrence is still to come');

# --- the fixed pause is still a caller's to pin -----------------------------
# A pinned pause keeps the old split exactly: the day model is not consulted.
my $pinned_scan = subs::clothesline_routine_scan(\@steady, JawnOSTest::ts(2026, 11, 5, 4, 40),
	window_days => 60, session_days => 14, pause => 6 * 3600 * 1000);
ok(!$pinned_scan->{'day'}, 'a pinned pause answers the old question, with no learned day');
is($pinned_scan->{'pause'}, 6 * 3600 * 1000, 'and keeps the pause it was given');

# One rest is not a shape: with nothing to compare it to, the old six-hour quiet
# still stands (a house that has only ever been seen asleep once has no day).
my @one_night = (
	row('only', JawnOSTest::ts(2026, 11, 16, 5, 0)),
	row('only', JawnOSTest::ts(2026, 11, 16, 8, 0)),
);
my $one = subs::clothesline_routine_scan(\@one_night, JawnOSTest::ts(2026, 11, 16, 8, 30),
	window_days => 60, session_days => 14);
ok(!$one->{'day'}, 'a single quiet is not a learned day');
is($one->{'done'}{'only'}, 2, 'and the old split still keeps its run');

# --- the wind-down closes the day, not only the middle of the sleep ----------
# A night shift's nights begin near eight in the morning and wake near four.
# The quiet that is still running is young, so its computed middle is pulled
# toward its own start; read at the other end, the quiet's start hour sits on
# the learned night's start, and that is the same clue the night test uses. The
# four cases below pin both ends: the wind-down closes a night shift's day, a
# quiet under rest_min still closes nothing, a day shift's afternoon gap begins
# nowhere near their night and closes nothing, and a quiet that begins at the
# learned bedtime closes the day at its first step.
sub burst_to {
	my ($rows, $app, $y, $m, $d, $h, $mi, $end_mi) = @_;
	my $base = JawnOSTest::ts($y, $m, $d, $h, $mi);
	my $n = int(($end_mi - $mi) / 5) + 1;
	push @{$rows}, row($app, $base + 5 * 60 * 1000 * $_) for 0 .. $n - 1;
	return $rows;
}

my @wind_rows;
for my $day (10 .. 14) {
	for my $h (16, 18, 20, 22) { burst(\@wind_rows, 'evening' . $h, 2026, 11, $day, $h, 0); }
	for my $h (0, 2, 4, 6) { burst(\@wind_rows, 'small' . $h, 2026, 11, $day + 1, $h, 0); }
	burst_to(\@wind_rows, 'wind_down', 2026, 11, $day + 1, 7, 35, 70);
}
my $wind_down = subs::clothesline_day_segments(\@wind_rows, undef, JawnOSTest::ts(2026, 11, 15, 9, 45),
	window_days => 60);
cmp_ok(scalar @{ $wind_down->{'segments'} }, '>=', 2, 'a night shift\'s nights are learned as days');
is($wind_down->{'segments'}[-1]{'closed_at'}, JawnOSTest::ts(2026, 11, 15, 8, 10),
	'the running quiet closes the day at the first step of its wind-down');
ok($wind_down->{'segments'}[-1]{'resting'}, 'and the day is resting');

# The same quiet seventy minutes old is still short of a rest, so it closes
# nothing however close its start sits to the learned night.
my $wind_short = subs::clothesline_day_segments(\@wind_rows, undef, JawnOSTest::ts(2026, 11, 15, 9, 20),
	window_days => 60);
ok(!defined $wind_short->{'segments'}[-1]{'closed_at'},
	'a quiet under rest_min closes nothing, however it started');
ok(!$wind_short->{'segments'}[-1]{'resting'}, 'and the day is not resting');

# A day shift: nights from 23:05 to seven, every daytime gap under rest_min.
my @day_clock_rows;
for my $day (10 .. 13) {
	for my $h (7, 9, 11, 13, 15, 17, 19, 21) { burst(\@day_clock_rows, 'day' . $h, 2026, 11, $day, $h, 0); }
	burst_to(\@day_clock_rows, 'late', 2026, 11, $day, 22, 30, 65);
}
my @afternoon_gap = @day_clock_rows;
for my $h (7, 9, 11, 13, 15, 17) { burst(\@afternoon_gap, 'day' . $h, 2026, 11, 14, $h, 0); }
burst_to(\@afternoon_gap, 'day_home', 2026, 11, 14, 18, 25, 60);
my $afternoon = subs::clothesline_day_segments(\@afternoon_gap, undef, JawnOSTest::ts(2026, 11, 14, 21, 0),
	window_days => 60);
ok(!defined $afternoon->{'segments'}[-1]{'closed_at'},
	'a day shift\'s afternoon gap begins nowhere near their night, so it closes nothing');

# The trade the second signal makes: a quiet that merely begins at the learned
# bedtime closes the day at its first step, even though it is only an hour and
# a half old - the clock says it is their night.
my @bedtime = @day_clock_rows;
for my $h (7, 9, 11, 13, 15, 17, 19, 21) { burst(\@bedtime, 'day' . $h, 2026, 11, 14, $h, 0); }
burst_to(\@bedtime, 'late', 2026, 11, 14, 22, 30, 65);
my $at_bedtime = subs::clothesline_day_segments(\@bedtime, undef, JawnOSTest::ts(2026, 11, 15, 0, 45),
	window_days => 60);
is($at_bedtime->{'segments'}[-1]{'closed_at'}, JawnOSTest::ts(2026, 11, 14, 23, 5),
	'a quiet that begins at the learned bedtime closes the day at its first step');
ok($at_bedtime->{'segments'}[-1]{'resting'}, 'and the day is resting');

# The learned hour is the clock's hour and nothing else. Two fortnights with the
# same shape, one early in the month and one late, must read the same hour: a
# profile is placed on the clock, so a rest that slid with the date would drift
# in and out of its radius as the month advanced.
sub month_rows {
	my ($first_day) = @_;
	my @out;
	for my $day ($first_day .. $first_day + 3) {
		push @out, row('morning', JawnOSTest::ts(2026, 11, $day, 7, 5), 'stop');
		push @out, row('midday', JawnOSTest::ts(2026, 11, $day, 12, 30), 'stop');
		push @out, row('evening', JawnOSTest::ts(2026, 11, $day, 19, 0), 'stop');
		push @out, row('evening_two', JawnOSTest::ts(2026, 11, $day, 22, 55), 'stop');
	}
	return \@out;
}
my $early_rests = subs::clothesline_rest_episodes(month_rows(2), JawnOSTest::ts(2026, 11, 6, 12, 0), window_days => 60);
my $late_rests = subs::clothesline_rest_episodes(month_rows(20), JawnOSTest::ts(2026, 11, 24, 12, 0), window_days => 60);
is(scalar @{ $early_rests->{'rests'} }, scalar @{ $late_rests->{'rests'} },
	'both fortnights learn the same number of rests');
is(sprintf('%.4f', $early_rests->{'rests'}[0]{'start_hour'}), sprintf('%.4f', $late_rests->{'rests'}[0]{'start_hour'}),
	'a rest at the same clock hour reads the same on the second as on the twentieth');
is(sprintf('%.4f', $early_rests->{'rests'}[0]{'stop_hour'}), sprintf('%.4f', $late_rests->{'rests'}[0]{'stop_hour'}),
	'and its wake reads the same too');

done_testing();

