# tests-for: lib/JawnOS/Manager/Part05.pm lib/JawnOS/Domain/Warehouse.pm
# covers:    a task completion is a finished record whose type is stop, so
#           appointment_writer must insert it at its own moment instead of
#           treating it as the press that closes a session; a stop movement with
#           no open session still writes nothing, and a completed record moves
#           no theme, silence or lockdown.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = root();
require "$root/lib/JawnOS/Manager/Part05.pm";

# The completion hands the writer a row that is already finished and says so.
my $warehouse = read_file("$root/lib/JawnOS/Domain/Warehouse.pm");
like($warehouse, qr/type => 'stop',[\s\S]*?completed_row => 1,/,
	'a task completion names its row as a finished record');

{
	package WriterCtx;
	sub new { bless {}, shift }
	sub param { return undef }
}

my (@inserted, @updates, @pushed, @effects);
{
	no warnings 'redefine';
	local *subs::rightNow = sub { return 1_700_000_500_000 };
	local *subs::controller_builder = sub { return WriterCtx->new };
	local *subs::database_grabber = sub { return (undef, undef, undef) };
	local *subs::setting_initializer = sub { return { app => $_[0], duration => 0 } };
	local *subs::typesetter = sub { return ($_[0], undef) };
	local *subs::settings_grabber = sub { return {} };
	local *subs::db_insert = sub { push @inserted, { %{$_[1]} }; return 1 };
	local *subs::db_update = sub { push @updates, { set => { %{$_[1]} }, where => { %{$_[2]} } }; return 1 };
	local *subs::appt_header_printer = sub { return ('header', []) };
	local *subs::source_header_printer = sub { return 1 };
	local *subs::unformat_name = sub { return $_[0] };
	local *subs::ago_calc = sub { return 1 };
	local *subs::appointment_theme_push = sub { push @effects, 'theme'; return 1 };
	local *subs::visibility_cache_clear = sub { push @effects, 'visibility'; return 1 };
	local *subs::lockdown_sweep = sub { push @effects, 'lockdown'; return 1 };
	local *subs::silence_appointment_settle = sub { push @effects, 'silence'; return 1 };
	local *subs::stop_target_row = sub { return undef };
	local *Manager::warranty_resolve = sub { return 1 };
	local *Manager::warehouse_money_mirror = sub { return 1 };
	local *Manager::record_source_param = sub { return undef };
	local *Manager::budget_runner = sub { return 1 };
	local *Websocket::send = sub { push @pushed, $_[1]; return 1 };
	local *Websocket::console_command = sub { return [ @_ ] };

	my $written = Manager::appointment_writer(WriterCtx->new, {
		app => 'washing',
		type => 'stop',
		timestamp => 1_700_000_100_000,
		server_time => 1_700_000_100_000,
		duration => 5000,
		stop_seen => 'yes',
		seen => 'yes',
		source => 'task',
		source_uuid => 'shower-row',
		uuid => '1700000100000-abc',
		data => '{"task_list":"shower","task":"washing"}',
		quiet_child => 1,
		completed_row => 1,
	});

	is(scalar @inserted, 1, 'the completed task row is inserted');
	is($inserted[0]{'uuid'}, '1700000100000-abc', 'at the uuid the task derived');
	is($inserted[0]{'type'}, 'stop', 'and stays a stop');
	is($inserted[0]{'source_uuid'}, 'shower-row', 'still linked to the session it was done in');
	ok(!exists $inserted[0]{'completed_row'}, 'the flag never reaches SQL');
	is($written->{'uuid'}, '1700000100000-abc', 'the caller learns the row it wrote');
	is(scalar @effects, 0, 'the record moves no theme, silence or lockdown');
	ok(scalar @pushed > 0, 'the tab is still told to repaint the row');

	# A stop that closes a session keeps its old contract: no open row, no write.
	@inserted = ();
	@updates = ();
	my $movement = Manager::appointment_writer(WriterCtx->new, {
		app => 'washing',
		type => 'stop',
		uuid => 'nobody',
		timestamp => 1_700_000_200_000,
		server_time => 1_700_000_200_000,
	});
	is(scalar @inserted, 0, 'a stop that closes nothing writes no row');
	is(scalar @updates, 0, 'and changes nothing');
	is_deeply($movement, {}, 'the writer says it wrote nothing');
}

done_testing();
