# tests-for: lib/JawnOS/Manager/Part05.pm lib/JawnOS/Domain/Edt.pm lib/JawnOS/Controller/manager_misc4.pm
# covers:    appointment_writer hands a written row to the peers over the relay,
#            and a caller that already distributed the press (or a row that just
#            arrived on the relay) is not sent a second time.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();
require "$root/lib/JawnOS/Manager/Part05.pm";

sub source { my $text = read_file("$root/$_[0]"); return defined $text ? $text : ''; }

# A controller with a request shape: the relay only needs `req` to exist. The
# relay itself is mocked, so no HTTP is made.
{ package RelayCtx;
  sub new { bless {}, shift }
  sub param { return undef }
  sub req { return bless {}, 'RelayReq' }
}

my (@inserted, @updates, @pushed, @relay, @audio, @automation, @ledger);
our $RECORD_SETTING = 'system';
{
	no warnings 'redefine';
	no warnings 'once';
	local *subs::rightNow = sub { return 1_700_000_500_000 };
	local *subs::signatorial_designer = sub { return 'origin-signal' };
	local *subs::controller_builder = sub { return RelayCtx->new };
	local *subs::database_grabber = sub { return (undef, undef, undef) };
	local *subs::setting_initializer = sub { return { app => $_[0], duration => 0 } };
	local *subs::typesetter = sub { return ($_[0], undef) };
	local *subs::settings_grabber = sub { return {} };
	local *subs::setting_grabber = sub {
		my ($want) = @_;
		return { record => $RECORD_SETTING } if (($want->{'setting'} // '') eq 'record');
		return {};
	};
	local *subs::usual_appointment_maker = sub { return ({}, {}, undef, undef) };
	local *subs::source_parent_link = sub { return undef };
	local *subs::db_insert = sub { push @inserted, { %{$_[1]} }; return 1 };
	local *subs::db_update = sub { push @updates, { set => { %{$_[1]} }, where => { %{$_[2]} } }; return 1 };
	local *subs::appt_header_printer = sub { return ('header', []) };
	local *subs::source_header_printer = sub { return 1 };
	local *subs::unformat_name = sub { return $_[0] };
	local *subs::ago_calc = sub { return 1 };
	local *subs::appointment_theme_push = sub { return 1 };
	local *subs::visibility_cache_clear = sub { return 1 };
	local *subs::lockdown_sweep = sub { return 1 };
	local *subs::silence_appointment_settle = sub { return 1 };
	local *subs::clock_appointment_sync = sub { return 1 };
	local *subs::stop_target_row = sub { return undef };
	local *subs::subprocessor = sub { my ($body) = @_; eval { $body->() }; return 1 };
	local *subs::remote_relay_request = sub { push @relay, { %{ $_[1] || {} } }; return 1 };
	local *Manager::warranty_resolve = sub { return 1 };
	local *Manager::warehouse_money_mirror = sub { push @ledger, $_[0]->{'app'}; return 1 };
	local *Manager::record_source_param = sub { return undef };
	local *Manager::record_audio = sub { push @audio, $_[0]->{'app'}; return 1 };
	local *Manager::budget_runner = sub { return 1 };
	local *subs::intelligent_automation_toggle = sub { push @automation, $_[0]->{'state'}; return 1 };
	local *Websocket::send = sub { push @pushed, $_[1]; return 1 };
	local *Websocket::console_command = sub { return [ @_ ] };

	sub write_row {
		my (%extra) = @_;
		@inserted = ();
		@relay = ();
		Manager::appointment_writer(RelayCtx->new, {
			app => 'relay_test',
			type => 'stop',
			timestamp => 1_700_000_100_000,
			server_time => 1_700_000_100_000,
			duration => 5000,
			stop_seen => 'yes',
			seen => 'yes',
			uuid => '1700000100000-relay',
			quiet_child => 1,
			completed_row => 1,
			%extra,
		});
	}

	# A written row goes out now, not only at the next sync.
	write_row();
	is(scalar @inserted, 1, 'the row is written');
	is(scalar @relay, 1, 'and handed to the relay once');
	is($relay[0]{'override'}, 'manual', 'through the manual relay');
	is($relay[0]{'url'}, '/manager/appointment/writer', 'to the writer route');
	is($relay[0]{'dissemination'}, 'yes', 'as a broadcast');
	is($relay[0]{'params'}{'uuid'}, '1700000100000-relay', 'carrying the row uuid');
	is($relay[0]{'params'}{'app'}, 'relay_test', 'and its app');
	is($relay[0]{'params'}{'remote_signatorial'}, 'origin-signal',
		'and names the origin as the capture machine');
	ok(!exists $inserted[0]{'remote_signatorial'}, 'which never reaches SQL');
	is($relay[0]{'params'}{'mirror'}, 'yes', 'and marks the row as a mirror for the peer');

	# A caller that already sent the movement says so.
	write_row(relayed => 'yes');
	is(scalar @relay, 0, 'a caller that already sent is not sent again');
	ok(!exists $inserted[0]{'relayed'}, 'and the flag never reaches SQL');

	# A row that arrived on the relay is already there.
	write_row(dissemination => 'yes', source_signatorial => 'peer');
	is(scalar @relay, 0, 'a relayed row is not relayed again');
	ok(!exists $inserted[0]{'dissemination'} && !exists $inserted[0]{'source_signatorial'},
		'and the relay keys never reach SQL');

	# A relayed record row is written for the record: the origin already
	# started the recorder, so a peer must not start its own.
	sub write_record {
		my (%extra) = @_;
		@inserted = ();
		@relay = ();
		@audio = ();
		@automation = ();
		@ledger = ();
		Manager::appointment_writer(RelayCtx->new, {
			app => 'relay_rec',
			type => 'record',
			timestamp => 1_700_000_100_000,
			server_time => 1_700_000_100_000,
			uuid => '1700000100000-rec',
			quiet_child => 1,
			%extra,
		});
	}
	$RECORD_SETTING = 'system';
	write_record(mirror => 'yes', dissemination => 'yes', source_signatorial => 'peer');
	ok(!@audio, 'a mirrored record starts no recorder on the peer');
	ok(!@automation, 'and toggles no device');
	ok(!@ledger, 'and writes no ledger entry');
	is(scalar @inserted, 1, 'the mirrored row is still written');
	is($inserted[0]{'seen'}, 'yes', 'and is not left unseen for the Alarm');

	# The same row on the machine that pressed it still runs the press.
	write_record();
	ok(@audio, 'a local record press starts the recorder');
	ok(@automation, 'and toggles the device');
	ok(@ledger, 'and writes the ledger entry');
}

# The two writers that distribute a press themselves mark it.
like(source('lib/JawnOS/Domain/Edt.pm'), qr/\$db_data->\{'relayed'\} = 'yes' if \$sent_away/,
	'the decoder marks a movement destination_relay already sent');
like(source('lib/JawnOS/Controller/manager_misc4.pm'), qr/relayed => 'yes'/,
	'the NFC tag marks the request relay that carries its row');

done_testing();
