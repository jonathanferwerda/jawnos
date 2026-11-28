# tests-for: lib/JawnOS/Domain/VoiceFunnel.pm lib/JawnOS/Domain/Loader.pm
# covers:    A spoken history/visit question is answered from the person's own
#           appointments without a model. The resolver names the record's app
#           through help_search, reads only that app's rows, and reports the
#           past-only last, the next, the first, a stop's duration and a count.
#           An entity it cannot resolve is left to the Guide, a bare "next
#           appointment" is not claimed, and the weather fast path still owns a
#           weather question.

use strict;
use warnings;
use utf8;
$| = 1;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;
use Mojo::SQLite;
use Time::Piece;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

require 'JawnOS/Domain/VoiceFunnel.pm';

# A throwaway database holds only the appointments this resolver reads.
my $dbfile = "$JawnOSTest::SANDBOX/history-visit-unit.sqlite";
unlink $dbfile if -e $dbfile;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db = $sql->db;
$db->query('create table appointments (uuid text, app text, type text, timestamp text, duration integer, notes text)');

my $now = &subs::rightNow();
my $day = 86400000;
my %ts = (
	first => $now - 30 * $day,
	last  => $now - 2 * $day,
	next  => $now + 3 * $day,
);

my $i = 0;
my $insert = sub {
	my ($app, $type, $timestamp, $duration, $notes) = @_;
	$db->query('insert into appointments (uuid, app, type, timestamp, duration, notes) values (?, ?, ?, ?, ?, ?)',
		'u' . ++$i, $app, $type, $timestamp, $duration, $notes);
};

# Person rows: an old start, a recent start, and a future appointment. The
# future one must never be spoken as "last".
$insert->('brian_coulbeck', 'start', $ts{'first'}, undef, 'saw Brian Coulbeck');
$insert->('brian_coulbeck', 'start', $ts{'last'},  undef, 'saw Brian Coulbeck');
$insert->('brian_coulbeck', 'start', $ts{'next'},  undef, 'Brian Coulbeck appointment');

# Place rows: two completed stops; the recent stop is -1076406 ms (17m 56s).
$insert->('white_pine_trail', 'stop', $now - 9 * $day, -1200000, 'White Pine Trail');
$insert->('white_pine_trail', 'stop', $now - 7 * $day, -1076406, 'White Pine Trail');

my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;

# The resolver uses the same date shape as help_search; mirror it here.
my $when = sub {
	my ($ms) = @_;
	my $s = localtime($ms / 1000)->strftime('%A %B %d, %Y at %I:%M%p');
	$s =~ s/\b0(\d:)/$1:/;
	$s =~ s/(\d)([AP]M)\b/$1 $2/;
	return $s;
};

&subs::preload('appointment_private_now');

{
	# The resolver names the app through help_search; this stub keeps the test
	# off the live records while the resolver's own db_query reads the rows.
	local *Manager::help_search = sub {
		my ($q) = @_;
		my %app_for = (
			'brian coulbeck'   => 'brian_coulbeck',
			'white pine trail' => 'white_pine_trail',
		);
		my $app = $app_for{ lc(defined $q ? $q : '') };
		return { apps => [] } unless $app;
		return { apps => [ { app => $app, count => 1 } ] };
	};
	local *Manager::help_app_visible = sub { return 1 };
	local *subs::appointment_private_now = sub { return 0 };

	# ------------------------------------------------------------ last
	my $last = &subs::voice_funnel_history_answer('when did i last see brian coulbeck', { chip_id => 'x' });
	ok($last && $last->{'handled'}, 'a last-seen question is handled');
	is($last->{'kind'}, 'history', 'the answer is a history answer');
	is($last->{'app'}, 'brian_coulbeck', 'the app is the person');
	is($last->{'which'}, 'last', 'the question is a last');
	like($last->{'speech'}, qr/^You last saw Brian Coulbeck on /, 'the speech names the person');
	like($last->{'speech'}, qr/\Q@{[ $when->($ts{'last'}) ]}\E/, 'last is the most recent past row');
	unlike($last->{'speech'}, qr/\Q@{[ $when->($ts{'next'}) ]}\E/, 'a future row is never last');

	# ------------------------------------------------------------ next
	my $next = &subs::voice_funnel_history_answer('when is the next time i see brian coulbeck', { chip_id => 'x' });
	ok($next, 'a next-seen question is handled');
	is($next->{'which'}, 'next', 'the question is a next');
	like($next->{'speech'}, qr/^You next see Brian Coulbeck on /, 'the speech names the next meeting');
	like($next->{'speech'}, qr/\Q@{[ $when->($ts{'next'}) ]}\E/, 'next is the first future row');
	unlike($next->{'speech'}, qr/\Q@{[ $when->($ts{'last'}) ]}\E/, 'next is not a past row');

	# ------------------------------------------------------------ first
	my $first = &subs::voice_funnel_history_answer('when did i first see brian coulbeck', { chip_id => 'x' });
	ok($first, 'a first-seen question is handled');
	is($first->{'which'}, 'first', 'the question is a first');
	like($first->{'speech'}, qr/^You first saw Brian Coulbeck on /, 'the speech says first');
	like($first->{'speech'}, qr/\Q@{[ $when->($ts{'first'}) ]}\E/, 'first is the oldest row');

	# ------------------------------------------------------------ duration
	my $duration = &subs::voice_funnel_history_answer('how long was my last visit to white pine trail', { chip_id => 'x' });
	ok($duration, 'a visit duration question is handled');
	is($duration->{'which'}, 'duration', 'the question is a duration');
	like($duration->{'speech'}, qr/^Your last visit to White Pine Trail lasted /, 'the speech names the visit');
	like($duration->{'speech'}, qr/17 minutes 56 seconds/, 'the stop duration is read from its ms accrual');
	like($duration->{'speech'}, qr/\Q@{[ $when->($now - 7 * $day) ]}\E/, 'the duration names the stop date');

	# ------------------------------------------------------------ last at a place
	my $at = &subs::voice_funnel_history_answer('when was i last at white pine trail', { chip_id => 'x' });
	ok($at, 'a last-at-place question is handled');
	is($at->{'which'}, 'last', 'the question is a last');
	like($at->{'speech'}, qr/^You were last at White Pine Trail on /, 'the speech uses the place form');
	like($at->{'speech'}, qr/for 17 minutes 56 seconds/, 'the last place stop carries its duration');

	# A future start at a place is still its next visit.
	$insert->('white_pine_trail', 'start', $now + 5 * $day, undef, 'White Pine Trail');
	my $next_visit = &subs::voice_funnel_history_answer('when is the next time i visit white pine trail', { chip_id => 'x' });
	ok($next_visit, 'a next-visit question is handled');
	is($next_visit->{'which'}, 'next', 'the question is a next');
	like($next_visit->{'speech'}, qr/^Your next visit to White Pine Trail is on /,
		'a future start is the next visit');

	# ------------------------------------------------------------ count
	my $count = &subs::voice_funnel_history_answer('how many times have i been to white pine trail', { chip_id => 'x' });
	ok($count, 'a count question is handled');
	is($count->{'which'}, 'count', 'the question is a count');
	like($count->{'speech'}, qr/^You have been to White Pine Trail 2 times\.$/, 'the stop rows are counted');

	# ------------------------------------------------------------ open start
	$insert->('white_pine_trail', 'start', $now - 10 * 60 * 1000, undef, 'White Pine Trail');
	my $open = &subs::voice_funnel_history_answer('how long did i stay at white pine trail', { chip_id => 'x' });
	ok($open, 'an open visit is still handled');
	like($open->{'speech'}, qr/still open/, 'an open start reports no invented length');
	unlike($open->{'speech'}, qr/minutes|seconds/, 'an open start invents no duration');

	my $open_at = &subs::voice_funnel_history_answer('when was i last at white pine trail', { chip_id => 'x' });
	ok($open_at, 'a last-at question with a recent open start is handled');
	like($open_at->{'speech'}, qr/^You are at White Pine Trail now, since /,
		'a recent open start reads as where the person is now');

	my $mail = &subs::voice_funnel_history_answer('when did i last message brian coulbeck', { chip_id => 'x' });
	ok(!defined $mail, 'a mail question is left to the Guide, not read from appointments');

	# ------------------------------------------------------------ unresolvable
	my $unknown = &subs::voice_funnel_history_answer('when did i last see nobody nowhere', { chip_id => 'x' });
	ok(!defined $unknown, 'an unresolvable entity is left to the model');

	my $bare = &subs::voice_funnel_history_answer('when is the next appointment', { chip_id => 'x' });
	ok(!defined $bare, 'a bare next appointment is left to the Guide');

	{
		local *Manager::help_search = sub {
			return { apps => [ { app => 'a_one', count => 2 }, { app => 'a_two', count => 2 } ] };
		};
		my $tie = &subs::voice_funnel_history_answer('when did i last see someone', { chip_id => 'x' });
		ok(!defined $tie, 'a tie between apps is left to the model');
	}

	# ------------------------------------------------------------ fast path
	my $fast = &subs::voice_funnel_fast('when did i last see brian coulbeck', { chip_id => 'x' });
	ok($fast && $fast->{'handled'}, 'the fast path claims a history question');
	is($fast->{'kind'}, 'history', 'the fast path reports a history answer');

	local *subs::signatorial_designer = sub { return 'test-device' };
	local *subs::weather_device_fix = sub { return { lat => 42.97, lon => -82.40 } };
	local *subs::weather_fetch = sub {
		return {
			current => { temperature => 4, condition => 'Cloudy' },
			daily => [], hourly => [],
		};
	};
	my $weather = &subs::voice_funnel_fast("what's the weather", { chip_id => 'x' });
	ok($weather && $weather->{'kind'} eq 'weather', 'a weather question still takes the weather path');
}

done_testing();
