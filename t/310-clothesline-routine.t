# tests-for: lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Domain/Hang.pm lib/JawnOS/Manager/Part14.pm lib/JawnOS/Manager/Part32.pm lib/JawnOS/Controller/manager_misc12.pm templates/apps/clothesline.html.ep templates/apps/clothesline/schedules.html.ep templates/apps/clothesline/settings.html.ep public/js/manager/manager/09_app_back.js public/js/manager/clothesline.js public/js/manager/clothesline/01_timeline.js
# covers:    The clothesline leads with the most common recent day's sequence,
#            not the latest day: a step moved earlier or later leaves the rest
#            in order, a step done twice is one pill at its next turn, and the
#            cadence may be every second, third, fifth ... day up to a month.
#            The day is read as waves - a long pause between steps starts the
#            next one - and the line shows the wave under way plus one ahead,
#            never two, and the head moves by the order the person takes the day
#            in, never by the hour on the clock. A routine keeps the day it began past midnight, and
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
my $trow = [ { app => 'wake_up', wave => 0 }, { app => 'noon_b', wave => 2 },
	{ app => 'late', wave => 2 }, { app => 'noon_a', wave => 1 } ];
my $tie_rows = subs::clothesline_anticipatory_habits($trow, $tie);
is($tie_rows->[1]{'app'}, 'yogurt', 'the habit still sits by the noon steps');
is($tie_rows->[1]{'wave'}, 2, 'and joins the routine the day reaches first');
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

# --- every press re-hangs the line, and the reply carries it ----------------
my $part32 = read_file(repo_root() . '/lib/JawnOS/Manager/Part32.pm');
like($part32, qr/clothesline_slot_now/, 'the Configure slots are counted on the house clock too');

my $part14 = read_file(repo_root() . '/lib/JawnOS/Manager/Part14.pm');
like($part14, qr/&subs::hang_to_dry\(reuse_head =>/, 'a press re-hangs the line at once');
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

done_testing();
