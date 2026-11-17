# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Hang.pm lib/JawnOS/Manager/Part14.pm lib/JawnOS/Manager/Part32.pm lib/JawnOS/Controller/manager_misc12.pm templates/apps/clothesline.html.ep templates/apps/clothesline/schedules.html.ep public/js/manager/manager/09_app_back.js public/js/manager/clothesline.js public/js/manager/clothesline/01_timeline.js
# covers:    The clothesline leads with the most common recent day's sequence,
#            not the latest day: a step moved earlier or later leaves the rest
#            in order, a step done twice is one pill at its next turn, and the
#            cadence may be every second, third, fifth ... day up to a month.
#            The day is read as waves - a long pause between steps starts the
#            next one - and the line shows the wave under way plus one ahead,
#            never two. A routine keeps the day it began past midnight, and
#            every press re-hangs the line in the reply instead of waiting for
#            the poll. Only the appointments the person starts and stops
#            themselves are learned; a task or default step stays with its
#            parent. The days are the ground the person is on (home, a friend's,
#            a hotel), read on the house clock, not the box's UTC. The
#            alphabetical tail carries only an app whose own time slots or
#            budget say it is on now, plus a running app that has time slots
#            of its own; an app with no registration never hangs there. A step
#            that is running sits where the routine usually stops it, so the
#            pill at the left is always the next one to press.

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
like($appointment, qr/foreach my \$in \( \@in \)/, 'the place averages both axes, not just the longitude');
like($appointment, qr/clock_zone_house/, 'the scan runs on the house clock, not the box clock');

my $hang = read_file(repo_root() . '/lib/JawnOS/Domain/Hang.pm');
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

# --- every press re-hangs the line, and the reply carries it ----------------
my $part32 = read_file(repo_root() . '/lib/JawnOS/Manager/Part32.pm');
like($part32, qr/clothesline_slot_now/, 'the Configure slots are counted on the house clock too');

my $part14 = read_file(repo_root() . '/lib/JawnOS/Manager/Part14.pm');
like($part14, qr/&subs::hang_to_dry\(\);/, 'a press re-hangs the line at once');
like($part14, qr/\$returner->\{'clothesline'\}/, 'the reply carries the new line');
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

my $misc12 = read_file(repo_root() . '/lib/JawnOS/Controller/manager_misc12.pm');
like($misc12, qr/sub action_41750/, 'the phrase has a route of its own');
like($misc12, qr/clothesline_schedule_read/, 'read by the house reader');
like($misc12, qr/clothesline_schedule_status/, 'and its answer is what the editor prints');
like($misc12, qr/clothesline_schedule_cards/, 'and the cards it read');
like($misc12, qr/param\('forget'\)/, 'a card can be forgotten');

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

done_testing();
