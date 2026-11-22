# tests-for: lib/JawnOS/Domain/Vacation.pm lib/JawnOS/Domain/Budget.pm lib/JawnOS/Domain/Budget2.pm lib/JawnOS/Manager/Part20.pm lib/JawnOS/Domain/Web.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Appointment.pm perl/Alarm.pl templates/apps/budget_current_information.html.ep templates/configure/me_setting_list.html.ep lib/JawnOS/Controller/manager_configure4.pm lib/JawnOS/Routes/manager_configure4.pm public/js/manager/configure/11_vacation.js
# covers:    an away period is a lens on time: budgets prorate a floor rate, freeze
#            a ceiling and a fixed level, pause a whole away window, and never read
#            a missing measure as zero; notifications hold the non-urgent ones; and
#            the stock runway and an open session see the away time.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempfile);
use JSON::PP qw(encode_json);
use Mojo::SQLite;
use JawnOSTest;

my $now = ts(2026, 11, 15, 12, 0, 0);

my ($fh, $dbfile) = tempfile('jawnos-vacation-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, id integer primary key autoincrement, app text, server_time text, device text, browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table appointments (app text, timestamp text, stop_timestamp text, type text, duration text, total text, quantity text, measures text, source text, uuid text, server_time text, stop_seen text, seen text)');
$db->query('create table warehouse (item text, unit text, quantity text, kind text, type text, account text, timestamp text)');
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

sub set_vacation {
	my ($from, $to, $policy, $state) = @_;
	$policy ||= {};
	$state ||= 'active';
	my $json = encode_json({
		version => 1,
		periods => [ {
			uuid => 'away-1',
			from => $from,
			(defined $to ? (to => $to) : ()),
			state => $state,
			kind => 'vacation',
			place => 'away',
		} ],
		policy => $policy,
		auto => { detect => 0, after_hours => 24 },
	});
	$db->query('delete from settings where app = ? and setting = ? and device = ?', '__president', 'vacation', 'all');
	$db->query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
		'vacation', $json, '__president', 'all', 'vacation-row', $now);
	&subs::vacation_forget();
}

sub clear_appointments {
	$db->query('delete from appointments');
}

# --- the period itself ------------------------------------------------------
my $start = ts(2026, 11, 1, 0, 0, 0);
my $end   = ts(2026, 11, 8, 0, 0, 0);
set_vacation($start, $end);

ok(&subs::vacation_active(ts(2026, 11, 4, 12)), 'a moment inside the period is away');
ok(!&subs::vacation_active($end), 'the period is half-open at its end');
is(&subs::vacation_overlap(ts(2026, 11, 4), ts(2026, 11, 6)), 2 * 86400000,
	'two whole days of overlap are two days');
is(&subs::vacation_active_ms(ts(2026, 11, 4), ts(2026, 11, 6)), 0,
	'a window entirely inside the period has no active time');
is(&subs::vacation_active_ms(ts(2026, 11, 7), ts(2026, 11, 9)), 86400000,
	'the day after the period is active time');
is(&subs::vacation_day_away('2026-11-04'), 1, 'a whole day inside the period is an away day');
ok(!&subs::vacation_day_away('2026-11-08'), 'the day the period ends is not away');

# a proposed gap is a question, not an away span
set_vacation($start, $end, {}, 'proposed');
ok(!&subs::vacation_active(ts(2026, 11, 4, 12)), 'a proposed period does not pause a budget');
set_vacation($start, $end);

# a future period is planned, not current
set_vacation($now + 5 * 86400000, $now + 10 * 86400000);
my $planned = &subs::vacation_status($now);
ok(!$planned->{'active'}, 'a future period is not active yet');
ok($planned->{'next'} && $planned->{'next'}->{'from'} > $now, 'it is offered as the next away period');
set_vacation($start, $end);

# an ended period leaves a short return digest
set_vacation($now - 10 * 86400000, $now - 5 * 86400000, {}, 'ended');
my $ended = &subs::vacation_status($now);
ok($ended->{'last'}, 'the ended period is remembered');
ok($ended->{'digest'} && $ended->{'digest'}->{'days'} == 5, 'the digest counts the five days away');
is($ended->{'digest'}->{'notices'}, 0, 'a house with no notice table reads zero notices');
set_vacation($start, $end);

# --- the policy -------------------------------------------------------------
is(&subs::vacation_policy_for('walk', 'duration', 'floor', 0), 'prorate',
	'a floor rate is prorated');
is(&subs::vacation_policy_for('shop', 'total', 'ceiling', 0), 'freeze',
	'a ceiling keeps its target');
is(&subs::vacation_policy_for('weight', 'weight', 'floor', 1), 'freeze',
	'a fixed level keeps its target');
is(&subs::vacation_policy_for('medication', 'occurences', 'floor', 0), 'prorate',
	'a normal app prorates');
set_vacation($start, $end, {
	budgets => 'prorate',
	keep_apps => { budgets => [ 'medication' ], routines => [], notifications => [] },
});
is(&subs::vacation_policy_for('medication', 'occurences', 'floor', 0), 'count',
	'an app on the budget keep list keeps counting');
set_vacation($start, $end);

# --- notifications ----------------------------------------------------------
ok(&subs::vacation_notify_allowed('security', 'authentication', 0, ts(2026, 11, 4, 12)),
	'security still speaks while away');
ok(&subs::vacation_notify_allowed('phone', 'start', 1, ts(2026, 11, 4, 12)),
	'a call still speaks while away');
ok(!&subs::vacation_notify_allowed('shop', 'budget', 0, ts(2026, 11, 4, 12)),
	'a budget notice is held while away');
ok(!&subs::vacation_notify_allowed('market', 'budget', 0, ts(2026, 11, 4, 12)),
	'a market notice is held while away');
ok(&subs::vacation_notify_allowed('shop', 'budget', 1, ts(2026, 11, 4, 12)),
	'an urgent notice still speaks');

# --- the budget -------------------------------------------------------------
clear_appointments();

# a whole window away is paused, not abandoned
set_vacation($now - 7 * 86400000, $now);
my $whole = &subs::budget_calculator({
	app => 'walk', circumstance => 'duration', scope => 'week', budget => '10h/week',
	settings => { s_lock => 'off', s_calc => 'sum' }, timestamp => $now,
});
ok($whole->{'paused'}, 'a whole away window is paused');
is($whole->{'status'}, 'paused', 'and reads as paused');
ok(($whole->{'vacation_ms'} || 0) > 0, 'the away time is named on the reading');

# part of the window away: the floor target shrinks to the time that was lived
set_vacation($now - 3 * 86400000, $now);
my $part = &subs::budget_calculator({
	app => 'walk', circumstance => 'duration', scope => 'week', budget => '10h/week',
	settings => { s_lock => 'off', s_calc => 'sum' }, timestamp => $now,
});
is($part->{'vacation_ms'}, 3 * 86400000, 'three away days are three days');
is($part->{'active_scope'}, 4 * 86400000, 'the active part of the week is four days');
my $expected = 10 * 3600000 * (4 / 7);
cmp_ok(abs(($part->{'threshold'} || 0) - $expected), '<', 1000,
	'the target is ten hours times the four days that were lived');
ok(defined $part->{'formatted_target'} && length $part->{'formatted_target'},
	'the panel has an adjusted target to show');

# a ceiling keeps its full target; a zero is not a false accomplishment
set_vacation($now - 3 * 86400000, $now);
my $ceiling = &subs::budget_calculator({
	app => 'shop', circumstance => 'total', scope => 'month', budget => '<=$100/month',
	settings => { s_lock => 'off', s_calc => 'sum' }, timestamp => $now,
});
is($ceiling->{'vacation_mode'}, 'freeze', 'a ceiling freezes rather than prorates');
ok($ceiling->{'vacation_zero'}, 'a zero in an away window is marked, so it is not announced');
cmp_ok(abs(($ceiling->{'threshold'} || 0) - 100), '<', 0.01,
	'the ceiling target is still the whole hundred');

# a fixed measure with no reading is no data, not zero
set_vacation($now - 3 * 86400000, $now);
my $fixed = &subs::budget_calculator({
	app => 'health', circumstance => 'weight', scope => '', budget => '<=180weight',
	settings => { s_lock => 'off', s_calc => 'average', app_measures => '{"weight":{"type":"number","unit":"lb"}}' },
	timestamp => $now,
});
ok($fixed->{'no_data'}, 'a fixed measure with no reading is no data');
is($fixed->{'status'}, 'no data', 'not accomplished at zero');

# --- the stock runway -------------------------------------------------------
$db->query('delete from warehouse');
$db->query('insert into warehouse (item, unit, quantity, kind, type, account, timestamp) values (?,?,?,?,?,?,?)',
	'soap', 'each', '20', 'stock', 'purchase', '', $now - 5 * 86400000);
$db->query('insert into warehouse (item, unit, quantity, kind, type, account, timestamp) values (?,?,?,?,?,?,?)',
	'soap', 'each', '-10', 'stock', 'usage', '', $now - 2 * 86400000);
set_vacation($now - 20 * 86400000, $now - 10 * 86400000);
my $stock = &subs::stock_days_for('soap', $now, 'soap');
is($stock->{'away_days'}, 10, 'the stock reading names the ten away days');
my ($soap) = @{ $stock->{'units'} };
cmp_ok(abs(($soap->{'days_left'} || 0) - 20), '<', 0.01,
	'ten taken over twenty active days leaves twenty days of soap');

# --- an open session at the boundary ---------------------------------------
clear_appointments();
my $open_at = $now - 10 * 86400000;
$db->query('insert into appointments (app, timestamp, type, duration, stop_seen, uuid, server_time) values (?,?,?,?,?,?,?)',
	'walk', $open_at, 'start', 0, undef, 'open-1', $open_at);
set_vacation($now - 5 * 86400000, $now);
my $closed = &subs::vacation_close_open_sessions($now - 5 * 86400000);
is($closed, 1, 'the session open at the boundary is closed');
my $row = $db->query('select type, stop_timestamp, duration, stop_seen from appointments where uuid = ?', 'open-1')->hash;
is($row->{'type'}, 'stop', 'it is a stop row');
is($row->{'stop_timestamp'}, $now - 5 * 86400000, 'closed at the away boundary');
is($row->{'stop_seen'}, 'yes', 'the stop is seen');
cmp_ok(($row->{'duration'} || 0), '<', 0, 'the duration is the negative accrual every other close writes');

done_testing();
