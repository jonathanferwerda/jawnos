# tests-for: lib/JawnOS/Domain/Presence.pm lib/JawnOS/Domain/Loader.pm perl/jobs.pl templates/configure/me_setting_list.html.ep public/js/manager/configure/11_vacation.js lib/JawnOS/Controller/manager_configure4.pm lib/JawnOS/Routes/manager_configure4.pm perl/help/topics_configure.pl
# covers:    presence simulation while away: the house-wide setting, the tick
#            that replays a learned remote once at a jittered on and off time,
#            the overnight window, the retry after a failed send, the ledger's
#            prune, and the card/job wiring. remote_send is stubbed, so nothing
#            is ever sent.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JSON::PP qw(encode_json);
use POSIX ();
use JawnOSTest;
use RepoSource;

my $root = repo_root();
my $CHIP = 'presence-chip-1';
my $REMOTE = 'Lamp';

# The actuator is replaced for the whole test. Loading Remotes first is what
# keeps the module's own definition from overwriting the stub later.
subs::preload('remote_send');
subs::preload('signatorial_designer');
subs::preload('device_setter');
my (@SEND_CALLS, @SEND_REPLIES);
{
	no warnings 'redefine';
	*subs::remote_send = sub {
		my ($data) = @_;
		push @SEND_CALLS, $data;
		return @SEND_REPLIES ? shift(@SEND_REPLIES) : { ok => 1, sent => 1 };
	};
	# The tick is gated to the machine that saved the card; every case below is
	# this machine unless it says otherwise.
	*subs::signatorial_designer = sub { 'test-machine' };
	*subs::device_setter = sub { 'server' };
}

sub reset_sends {
	@SEND_CALLS = ();
	@SEND_REPLIES = ();
	return;
}

sub set_presence {
	my (%fields) = @_;
	my $json = encode_json({ %{ &subs::presence_defaults() }, machine => 'test-machine', %fields });
	# setting_setter is also the memo flush, so a read straight after this
	# cannot answer with the row the previous case wrote.
	&subs::setting_setter({
		app     => '__president',
		setting => 'presence',
		device  => 'all',
		value   => $json,
	});
	return;
}

sub clear_presence {
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?',
		'__president', 'presence', 'all');
	&subs::setting_setter({
		app => '__president', setting => 'presence', device => 'all', value => '',
	});
	return;
}

sub set_remote {
	my (%remotes) = @_;
	&subs::db_query('delete from settings where app = ? and setting = ? and subsetting = ?',
		'microcontroller', 'remotes', $CHIP);
	&subs::remote_store_save('microcontroller', $CHIP, \%remotes);
	return;
}

sub set_vacation {
	my ($from, $to, $state) = @_;
	my $json = encode_json({
		version => 1,
		periods => [ {
			uuid => 'away-presence', from => $from,
			(defined $to ? (to => $to) : ()),
			state => $state || 'active', kind => 'vacation',
		} ],
		policy => {},
		auto => { detect => 0, after_hours => 24 },
	});
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?',
		'__president', 'vacation', 'all');
	&subs::db_query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
		'vacation', $json, '__president', 'all', 'vacation-presence', &subs::rightNow());
	&subs::vacation_forget();
	return;
}

sub clear_vacation {
	&subs::db_query('delete from settings where app = ? and setting = ? and device = ?',
		'__president', 'vacation', 'all');
	&subs::vacation_forget();
	return;
}

# --- defaults and normalization ---------------------------------------------
clear_presence();
my $settings = &subs::presence_settings();
is($settings->{'enabled'}, 'no', 'a missing row reads as disabled');
is($settings->{'on'}, '19:00', 'the default on time is 19:00');
is($settings->{'off'}, '23:00', 'the default off time is 23:00');
is($settings->{'jitter'}, 20, 'the default jitter is 20 minutes');
is($settings->{'chip_id'}, '', 'no board is chosen by default');
is($settings->{'remote'}, '', 'no remote is chosen by default');
is($settings->{'machine'}, '', 'no machine owns the tick by default');
is_deeply($settings->{'last'}, {}, 'the ledger starts empty');

# Malformed JSON must not die or take the row down with it.
&subs::setting_setter({
	app => '__president', setting => 'presence', device => 'all', value => 'not json at all',
});
$settings = &subs::presence_settings();
is($settings->{'enabled'}, 'no', 'a malformed row still reads as the defaults');
is($settings->{'on'}, '19:00', 'and keeps the default on time');

my %last_nine;
$last_nine{ sprintf('2026-01-%02d', $_) } = { on => 1, off => 1 } for 1 .. 9;
my $normal = &subs::presence_normalize({
	version => 9,
	enabled => 'on',
	chip_id => '  board-7  ',
	remote  => '  Living Room TV  ',
	on      => '7:05',
	off     => '25:00',
	jitter  => 999,
	machine => '  machine-9  ',
	last    => \%last_nine,
});
is($normal->{'enabled'}, 'yes', 'on normalizes to yes');
is($normal->{'chip_id'}, 'board-7', 'the board id is trimmed');
is($normal->{'remote'}, 'Living Room TV', 'the remote name is trimmed');
is($normal->{'on'}, '07:05', 'a one-digit hour normalizes to HH:MM');
is($normal->{'off'}, '23:00', 'an impossible off time falls back to the default');
is($normal->{'jitter'}, 120, 'jitter is clamped to 120');
is($normal->{'machine'}, 'machine-9', 'the owning machine is trimmed');
is(scalar(keys %{ $normal->{'last'} }), 7, 'the ledger keeps only the newest seven dates');
ok($normal->{'last'}->{'2026-01-09'}, 'the newest date survives the prune');
ok(!$normal->{'last'}->{'2026-01-02'}, 'the eighth-oldest date is pruned');

# --- disabled is a no-op -----------------------------------------------------
my $now = ts(2026, 11, 15, 19, 30, 0);
set_remote($REMOTE => { seq => '100,200', pin => 1 });
set_vacation($now - 86400000, $now + 86400000);
set_presence(enabled => 'no', chip_id => $CHIP, remote => $REMOTE,
	on => '19:00', off => '23:00', jitter => 0);
reset_sends();
my $result = &subs::presence_tick($now);
is(scalar @SEND_CALLS, 0, 'a disabled setting sends nothing');
is_deeply($result->{'fired'}, [], 'and reports nothing fired');

# --- an active away period gates the tick -----------------------------------
set_presence(enabled => 'yes', chip_id => $CHIP, remote => $REMOTE,
	on => '19:00', off => '23:00', jitter => 0);
clear_vacation();
reset_sends();
$result = &subs::presence_tick($now);
is(scalar @SEND_CALLS, 0, 'with no active away period the tick is a no-op');

set_vacation($now - 86400000, $now + 86400000);
set_presence(enabled => 'yes', chip_id => $CHIP, remote => 'Missing remote',
	on => '19:00', off => '23:00', jitter => 0);
reset_sends();
$result = &subs::presence_tick($now);
is(scalar @SEND_CALLS, 0, 'a remote the board does not hold is a no-op');

# --- deterministic jitter ----------------------------------------------------
my $j1 = &subs::presence_jitter('2026-11-15', $CHIP, $REMOTE, 'on', 20);
my $j2 = &subs::presence_jitter('2026-11-15', $CHIP, $REMOTE, 'on', 20);
is($j1, $j2, 'the same date, board, remote and action gives the same jitter');
cmp_ok($j1, '>=', -20, 'the jitter is bounded below');
cmp_ok($j1, '<=', 20, 'the jitter is bounded above');
is(&subs::presence_jitter('2026-11-15', $CHIP, $REMOTE, 'on', 0), 0,
	'a jitter of 0 is exact');

# --- once per day -----------------------------------------------------------
my $day1 = ts(2026, 11, 15, 19, 30, 0);
set_presence(enabled => 'yes', chip_id => $CHIP, remote => $REMOTE,
	on => '19:00', off => '23:00', jitter => 0);
reset_sends();
$result = &subs::presence_tick($day1);
is(scalar @SEND_CALLS, 1, 'the on action fires once inside its window');
is_deeply($result->{'fired'}, [ 'on' ], 'and the tick reports the on');
is($SEND_CALLS[0]->{'name'}, $REMOTE, 'the learned remote is the one replayed');
is($SEND_CALLS[0]->{'chip_id'}, $CHIP, 'on the chosen board');

$result = &subs::presence_tick($day1 + 5 * 60 * 1000);
is(scalar @SEND_CALLS, 1, 'a later tick the same day does not fire on again');
is_deeply($result->{'fired'}, [], 'and reports nothing fired');

my $day_key = ymd($day1);
my $ledger = &subs::presence_settings()->{'last'};
ok($ledger->{$day_key}->{'on'}, 'the ledger marks the day on done');

$result = &subs::presence_tick(ts(2026, 11, 15, 23, 30, 0));
is(scalar @SEND_CALLS, 2, 'the off action fires inside its own window');
is_deeply($result->{'fired'}, [ 'off' ], 'and the tick reports the off');

$result = &subs::presence_tick(ts(2026, 11, 15, 23, 35, 0));
is(scalar @SEND_CALLS, 2, 'the off action is not repeated');

# --- a failed send is retried ------------------------------------------------
set_presence(enabled => 'yes', chip_id => $CHIP, remote => $REMOTE,
	on => '19:00', off => '23:00', jitter => 0);
reset_sends();
push @SEND_REPLIES, { ok => 1, sent => 0 }, { ok => 1, sent => 1 };
$result = &subs::presence_tick($day1);
is(scalar @SEND_CALLS, 1, 'a send that the board did not accept is attempted');
is_deeply($result->{'fired'}, [], 'but is not marked done');
ok(!&subs::presence_settings()->{'last'}->{$day_key}->{'on'}, 'the ledger stays unmarked');
$result = &subs::presence_tick($day1 + 5 * 60 * 1000);
is(scalar @SEND_CALLS, 2, 'the next tick retries the failed action');
is_deeply($result->{'fired'}, [ 'on' ], 'and marks it once the send succeeds');
ok(&subs::presence_settings()->{'last'}->{$day_key}->{'on'}, 'the ledger is marked on success');

# --- one machine fires -------------------------------------------------------
# A card saved on another machine must not replay the remote here: two sends of
# a toggle would turn the light on and straight back off.
my $other_day = ts(2026, 12, 1, 19, 30, 0);
set_vacation($other_day - 86400000, $other_day + 86400000);
set_presence(enabled => 'yes', chip_id => $CHIP, remote => $REMOTE,
	on => '19:00', off => '23:00', jitter => 0, machine => 'other-machine', last => {});
reset_sends();
$result = &subs::presence_tick($other_day);
is(scalar @SEND_CALLS, 0, 'a tick owned by another machine sends nothing');
is_deeply($result->{'fired'}, [], 'and reports nothing fired');

my $saved = &subs::presence_save({ enabled => 'yes', chip_id => $CHIP, remote => $REMOTE,
	on => '19:00', off => '23:00', jitter => 0, last => {} });
is($saved->{'machine'}, 'test-machine', 'a save names the machine that owns the tick');

# --- an overnight window -----------------------------------------------------
my $night_on = ts(2026, 11, 20, 23, 30, 0);
set_vacation(ts(2026, 11, 20, 0, 0, 0), ts(2026, 11, 22, 0, 0, 0));
set_presence(enabled => 'yes', chip_id => $CHIP, remote => $REMOTE,
	on => '23:00', off => '01:00', jitter => 0);
reset_sends();
$result = &subs::presence_tick($night_on);
is_deeply($result->{'fired'}, [ 'on' ], 'the on fires on the session day');
my $session_day = ymd($night_on);
$result = &subs::presence_tick(ts(2026, 11, 21, 1, 30, 0));
is_deeply($result->{'fired'}, [ 'off' ], 'the off fires after midnight');
my $overnight = &subs::presence_settings()->{'last'};
ok($overnight->{$session_day}->{'off'},
	'and the off is recorded on the previous day session, not the calendar day');
ok(!($overnight->{'2026-11-21'} && $overnight->{'2026-11-21'}->{'off'}),
	'the new calendar day has no off of its own');
$result = &subs::presence_tick(ts(2026, 11, 21, 1, 35, 0));
is_deeply($result->{'fired'}, [], 'the overnight off does not repeat');

# --- the ledger is pruned ----------------------------------------------------
my %ledger_nine;
$ledger_nine{ sprintf('2026-02-%02d', $_) } = { on => 1 } for 1 .. 9;
set_presence(enabled => 'yes', chip_id => $CHIP, remote => $REMOTE,
	on => '19:00', off => '23:00', jitter => 0, last => \%ledger_nine);
my $pruned = &subs::presence_settings()->{'last'};
is(scalar(keys %{$pruned}), 7, 'a stored ledger is pruned to seven dates');
ok($pruned->{'2026-02-09'} && !$pruned->{'2026-02-02'}, 'the newest dates are kept');

# --- wiring ------------------------------------------------------------------
like(read_file("$root/perl/jobs.pl"), qr/name\s*=>\s*'presence simulate'.*presence_tick/s,
	'the slow loops carry a presence simulate row that calls the tick');
my $template = read_file("$root/templates/configure/me_setting_list.html.ep");
like($template, qr/id="me_presence_card"/, 'the Away card carries the presence section');
like($template, qr/class="presence_enabled"/, 'with the Simulate presence checkbox');
like($template, qr/class="presence_board"/, 'a board select');
like($template, qr/class="presence_remote"/, 'a remote select');
like($template, qr/type="time" class="presence_on"/, 'an on time input');
like($template, qr/class="presence_jitter"/, 'a jitter input');
like($template, qr/A learned IR remote is sent at a slightly different time each evening while an away period is active\./,
	'and the note the person reads');

my $js = read_file("$root/public/js/manager/configure/11_vacation.js");
like($js, qr#/manager/embedded/remotes#, 'the remote list refreshes from the embedded route');
like($js, qr#/manager/vacation/presence#, 'the card saves through the vacation presence route');
like($js, qr/presence_board/, 'and the board change is wired');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_configure4.pm");
like($controller, qr/sub action_60006\b/, 'the presence save action exists');
like($controller, qr/subs::presence_save/, 'and calls the domain save');
my $routes = read_file("$root/lib/JawnOS/Routes/manager_configure4.pm");
like($routes, qr#\[60006, 'post', '/manager/vacation/presence', 'action_60006'\]#,
	'the route row reaches it');

like(read_file("$root/perl/help/topics_configure.pl"), qr/Presence simulation sits under Away/,
	'the Configure help topic explains the section');

clear_presence();
clear_vacation();

done_testing();
