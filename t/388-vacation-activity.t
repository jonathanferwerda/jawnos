# tests-for: lib/JawnOS/Domain/VacationActivity.pm lib/JawnOS/Domain/Vacation.pm perl/jobs.pl
# covers:    the quiet-period detector reads activity from the whole house, not
#            one machine's local sockets: a phone and a laptop in use are not a
#            quiet house, and a gap is measured across usage sessions, window
#            events, appointment writes and this machine's own sockets.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempfile);
use Mojo::SQLite;
use JawnOSTest;

my $root = JawnOSTest::root();
require "$root/lib/JawnOS/Domain/VacationActivity.pm";

my $now = ts(2026, 11, 22, 12, 0, 0);
my $hour = 3600000;
my $day = 86400000;

my ($fh, $dbfile) = tempfile('jawnos-vacation-activity-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table usage_sessions (started_at text, ended_at text, device text, server_time text)');
$db->query('create table window_events (timestamp text, server_time text, device_id text)');
$db->query('create table appointments (timestamp text, stop_timestamp text, server_time text, device text)');
$db->query('create table websockets (connected text, timestamp text, server_time text, type text)');
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

my $usage = sub {
	my ($start, $end, $device) = @_;
	$db->query('insert into usage_sessions (started_at, ended_at, device, server_time) values (?,?,?,?)',
		$start, $end, ($device || 'phone'), $end);
};
my $window = sub {
	my ($at) = @_;
	$db->query('insert into window_events (timestamp, server_time, device_id) values (?,?,?)', $at, $at, 'browser-1');
};
my $appt = sub {
	my ($at, $stop, $seen) = @_;
	$db->query('insert into appointments (timestamp, stop_timestamp, server_time, device) values (?,?,?,?)',
		$at, $stop, ($seen || $at), 'laptop');
};
my $socket = sub {
	my ($connected, $end, $type) = @_;
	$db->query('insert into websockets (connected, timestamp, server_time, type) values (?,?,?,?)',
		$connected, $end, $end, ($type || ''), );
};
my $clear = sub {
	$db->query('delete from usage_sessions');
	$db->query('delete from window_events');
	$db->query('delete from appointments');
	$db->query('delete from websockets');
};

my $gaps = sub {
	my ($after_hours, %opt) = @_;
	return &subs::vacation_house_gaps($now, ($after_hours || 24) * $hour, %opt);
};

# A phone and a laptop in use are not a quiet house, even when the tablet and
# the desk were never opened.
$clear->();
$usage->($now - 20 * $hour, $now - 18 * $hour, 'phone');
$usage->($now - 3 * $hour, $now - 1 * $hour, 'laptop');
is(scalar @{ $gaps->(24) }, 0, 'phone and laptop activity leaves no quiet gap');

# The gap is measured across devices: twenty hours on the phone, then two on
# the laptop, is not thirty hours on the tablet.
$clear->();
$usage->($now - 50 * $hour, $now - 48 * $hour, 'phone');
$usage->($now - 20 * $hour, $now - 18 * $hour, 'laptop');
my $between = $gaps->(24);
is(scalar @{ $between }, 1, 'a 28-hour gap between two devices is found once');
is($between->[0]->{'from'}, $now - 48 * $hour, 'the gap starts where the last house activity ended');
is($between->[0]->{'to'}, $now - 20 * $hour, 'and ends where the next activity began');
ok(!$between->[0]->{'ongoing'}, 'a gap between two activities is not ongoing');

# A window event and a later session both count, so the long gap is broken.
$clear->();
$usage->($now - 50 * $hour, $now - 48 * $hour, 'desk');
$window->($now - 30 * $hour);
$usage->($now - 10 * $hour, $now - 9 * $hour, 'phone');
is(scalar @{ $gaps->(24) }, 0, 'a window event on another device fills the gap');

# An appointment write is activity too, even when the appointment itself was
# dated for later.
$clear->();
$usage->($now - 50 * $hour, $now - 48 * $hour, 'desk');
$appt->($now + 5 * 86400000, undef, $now - 30 * $hour);
$usage->($now - 2 * $hour, $now - 1 * $hour, 'phone');
my $appt_gap = $gaps->(24);
is(scalar @{ $appt_gap }, 1, 'the appointment write leaves only the shorter gap');
is($appt_gap->[0]->{'from'}, $now - 30 * $hour,
	'the gap starts at the appointment write, so a future date still counts as use');

# An appointment that ran across the time is one interval, not a gap.
$clear->();
$appt->($now - 30 * $hour, $now - 1 * $hour, $now - 30 * $hour);
is(scalar @{ $gaps->(24) }, 0, 'an appointment interval covers the hours it ran');

# The ongoing gap is marked open ended.
$clear->();
$usage->($now - 30 * $hour, $now - 28 * $hour, 'phone');
my $ongoing = $gaps->(24);
is(scalar @{ $ongoing }, 1, 'a quiet stretch to now is found');
ok($ongoing->[0]->{'ongoing'}, 'and marked ongoing');
is($ongoing->[0]->{'to'}, $now, 'its end is now, for the caller to leave open');

# The prefix before the first activity is not a gap: a fresh house is not away.
$clear->();
$usage->($now - 2 * $hour, $now - 1 * $hour, 'phone');
is(scalar @{ $gaps->(24) }, 0, 'the empty prefix before the first activity is not a proposal');

# This machine's own socket is one more source, not the only one.
$clear->();
$socket->($now - 40 * $hour, $now - 30 * $hour, 'closed');
$usage->($now - 5 * $hour, $now - 4 * $hour, 'phone');
my $from_socket = $gaps->(24);
is(scalar @{ $from_socket }, 1, 'a local socket contributes its own span');
is($from_socket->[0]->{'from'}, $now - 30 * $hour, 'the gap starts after the socket closed');

# The quiet length is the caller's, so a 12-hour setting sees a shorter gap.
$clear->();
$usage->($now - 30 * $hour, $now - 28 * $hour, 'phone');
$usage->($now - 10 * $hour, $now - 9 * $hour, 'laptop');
is(scalar @{ $gaps->(24) }, 0, 'an 18-hour gap is not a 24-hour one');
is(scalar @{ $gaps->(12) }, 1, 'but it is a 12-hour one');

done_testing();
