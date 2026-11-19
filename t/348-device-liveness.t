# tests-for: lib/JawnOS/Domain/Misc.pm
# covers:    The clothesline's device liveness read from the retained sockets.
#            Two devices: one up through every night (infrastructure, so
#            background), one with short daytime sessions (company, not
#            background). A two-hour hole with no socket at all is `down` - the
#            house was out, not the person quiet - while a quiet night with the
#            background device up is not. A closed row spans connect to the close
#            moment (server_time), not to its last client beat, and a live row's
#            span ends at the later of the two clocks, with a grace after it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest ();

# House hours are what a night is read in, so pin the house zone to UTC: the
# times below are then both JawnOSTest's ts() and the sub's hour buckets. The
# setting's writer also sets the host clock, so the documented dry run answers
# that instead of asking polkit (a test must not move the machine's time zone).
{
	local $ENV{'JAWNOS_TIMEZONE_DRY_RUN'} = 1;
	&subs::setting_setter({ app => 'misc', setting => 'clock_timezone', value => 'UTC' });
}

my $now = JawnOSTest::ts(2026, 11, 17, 12, 0);
my $at = sub { return JawnOSTest::ts(2026, 11, $_[0], $_[1], $_[2] || 0) };
my $hour = 3600000;

my $bg_key = '10.9.0.5|liveness-bg/1';
my $person_key = '10.9.0.9|liveness-person/1';
my $prefix = 'devliveness-' . $$ . '-';

# The sandbox database is a throwaway copy and may carry the live house's
# retained sockets. This test asserts totals and whole `down` intervals, so it
# starts from none of them.
&subs::db_query('delete from websockets');

my $seq = 0;
my $add = sub {
	my (%row) = @_;
	$seq++;
	&subs::db_insert('websockets', {
		uuid => $prefix . $seq,
		app => 'tab',
		browser_tab_id => 'devliveness-tab-' . $$,
		type => 'stayingAlive',
		warranty => &subs::ago_calc('-1d', $now),
		%row,
	});
	return $prefix . $seq;
};

# Infrastructure: up since the evening before the first observed day, through
# three nights, then a two-hour outage on Nov 16 and up again to now. The first
# row is closed: its close moment is 16:00, its last client beat 15:55.
$add->(
	remote_address => '10.9.0.5', user_agent => 'liveness-bg/1',
	connected => $at->(13, 22), timestamp => $at->(16, 15, 55),
	server_time => $at->(16, 16), type => 'closed',
);
$add->(
	remote_address => '10.9.0.5', user_agent => 'liveness-bg/1',
	connected => $at->(16, 18), timestamp => $now, server_time => $now - 3000,
);

# Company: short daytime sessions, one per waking hour, with the 16:00 and
# 17:00 hours of Nov 16 left out so the house itself goes quiet with the
# background device.
foreach my $day ( 15, 16, 17 ) {
	my $last = $day == 17 ? 11 : 22;   # Nov 17 is observed only up to noon
	foreach my $hour_of_day ( 7 .. $last ) {
		next if $day == 16 && ($hour_of_day == 16 || $hour_of_day == 17);
		my $from = $at->($day, $hour_of_day);
		my $to = $at->($day, $hour_of_day + 1);
		$add->(
			remote_address => '10.9.0.9', user_agent => 'liveness-person/1',
			connected => $from, timestamp => $to, server_time => $to,
		);
	}
}

# grace_ms => 0 makes a live span exactly connected -> max(timestamp,
# server_time); the default grace is asserted on its own below.
my $live = &subs::clothesline_device_liveness($now, grace_ms => 0);
is($live->{'now'}, $now, 'the answer says which moment it is about');
is($live->{'up'}, 1, 'a device is up at now');

is_deeply($live->{'night'}, { start_hour => 23, end_hour => 7 },
	'the night is the longest run of hours only infrastructure was up');

my $background = $live->{'devices'}{$bg_key};
ok($background, 'the background device has an entry');
is($background->{'sessions'}, 2, 'one row per socket it opened');
is($background->{'span_ms'}, 84 * $hour,
	'both sessions unioned: 66h before the outage, 18h after');
is($background->{'background'}, 1, 'up through the night is infrastructure');
is($background->{'last_seen'}, $now, 'its live session reaches now');

my $person = $live->{'devices'}{$person_key};
ok($person, 'the person-facing device has an entry');
is($person->{'sessions'}, 35, 'its short daytime sessions are all counted');
is($person->{'span_ms'}, 35 * $hour, 'and union into the daytime spans');
is($person->{'background'}, 0, 'a daytime device is not infrastructure');
is($person->{'last_seen'}, $now, 'its last session reaches now');
cmp_ok($person->{'coverage'}, '>', 0.04, 'coverage is its share of the month');
cmp_ok($person->{'coverage'}, '<', 0.06, 'not a count of every row');

is(scalar @{ $live->{'down'} }, 2, 'two gaps: before the first socket and the outage');
is($live->{'down'}[0][0], &subs::ago_calc('30d', $now), 'the window starts a month back');
is($live->{'down'}[0][1], $at->(13, 22), 'and runs to the first socket');
is_deeply($live->{'down'}[1], [ $at->(16, 16), $at->(16, 18) ],
	'the outage starts at the close moment, not the last client beat');

# Asked during the outage: nothing is up, and the gap runs to that moment.
my $during = &subs::clothesline_device_liveness($at->(16, 17), grace_ms => 0);
is($during->{'up'}, 0, 'no device is up during the outage');
my $bg_alone = $during->{'devices'}{$bg_key};
is($bg_alone->{'sessions'}, 1, 'only the closed session is in this window');
is($bg_alone->{'last_seen'}, $at->(16, 16),
	'a closed row spans connect to the close moment, not to its last beat');
is($bg_alone->{'span_ms'}, 66 * $hour, 'and that is its whole span');
is_deeply($during->{'down'}[-1], [ $at->(16, 16), $at->(16, 17) ],
	'the down interval is the outage up to the moment asked about');

# A live row keeps counting for a minute after its last beat, which is what
# makes `up` useful between heartbeats; with no grace it stops at the beat.
my $later = $now + 30000;
is(&subs::clothesline_device_liveness($later)->{'up'}, 1,
	'a live session is still up inside the beat grace');
is(&subs::clothesline_device_liveness($later)->{'devices'}{$bg_key}{'last_seen'}, $later,
	'and its span is carried to that moment');
my $strict = &subs::clothesline_device_liveness($later, grace_ms => 0);
is($strict->{'up'}, 0, 'with no grace it is down once its last beat passes');
is($strict->{'devices'}{$bg_key}{'last_seen'}, $now, 'and its span ends at the beat');

&subs::db_query('delete from websockets where uuid like ?', $prefix . '%');

# Nothing retained is not "nothing to say": no device was seen, so the whole
# window is down. That is the same shape an outage has, and the caller can tell
# it apart from a quiet person only by knowing the house is new.
my $empty = &subs::clothesline_device_liveness($now);
is($empty->{'up'}, 0, 'with no sockets nothing is up');
is_deeply($empty->{'devices'}, {}, 'and no device is invented');
is_deeply($empty->{'down'}, [ [ &subs::ago_calc('30d', $now), $now ] ],
	'while the whole analysis window is down');

done_testing();
