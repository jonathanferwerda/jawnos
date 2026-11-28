# tests-for: lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Controller/manager_misc6.pm lib/JawnOS/Manager/Part05.pm
# covers:    a task completion reaches appointment_writer's peer relay immediately
#            (the row, not only the next sync), and the tasks route asks for its
#            own request relay so the checklist change is carried too; the writer
#            is never told the row was already sent.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Mojo::JSON qw(decode_json encode_json);

require "$FindBin::Bin/../lib/JawnOS/Manager/Part05.pm";
require "$FindBin::Bin/../lib/JawnOS/Domain/Warehouse.pm";
require "$FindBin::Bin/../lib/JawnOS/Controller/manager_misc6.pm";

{ package ProbeReq; sub new { bless {}, shift } }
{ package ProbeCtx;
  sub new { my ($class, %param) = @_; return bless { param => { %param } }, $class }
  sub param {
		my ($self, $key, $value) = @_;
		$self->{'param'}{$key} = $value if @_ > 2;
		return $self->{'param'}{$key};
	}
  sub req { return ProbeReq->new }
  sub render { my ($self, %args) = @_; $self->{'rendered'} = $args{'json'}; return 1 }
}
{ package ProbeRows; sub hashes { return $_[0]->{'rows'} } sub hash { return $_[0]->{'rows'}[0] } }
{ package ProbeTaskRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
  sub hashes { return $_[0]->{'rows'} }
}

# ---------------------------------------------------------------- the writer
# Drive the real task_writer into the real appointment_writer. A completion is a
# finished row (completed_row), so the writer inserts it and must hand it to the
# peers at once instead of waiting for the next sync.
{
	my (@inserted, @relay);
	my %lists = (
		'shower' => [ { uuid => 'tw', task => 'washing', appt => 'on', occurences => 1,
			duration => '5m', colour => '#abc', completed => 'off' } ],
	);

	no warnings 'redefine';
	no warnings 'once';
	local *subs::rightNow = sub { return 1_700_000_900_000 };
	local *subs::signatorial_designer = sub { return 'origin-signal' };
	local *subs::controller_builder = sub { return ProbeCtx->new };
	local *subs::database_grabber = sub { return (undef, undef, undef) };
	local *subs::setting_initializer = sub { return { app => $_[0], duration => 0 } };
	local *subs::typesetter = sub { return ($_[0], undef) };
	local *subs::settings_grabber = sub { return {} };
	local *subs::setting_grabber = sub {
		my ($want) = @_;
		return encode_json($lists{ $want->{'app'} } || []) if (($want->{'setting'} // '') eq 'tasks');
		return '';
	};
	local *subs::setting_setter = sub { return 1 };
	local *subs::usual_appointment_maker = sub { return ({}, {}, undef, undef) };
	local *subs::source_parent_link = sub { return undef };
	local *subs::db_insert = sub { push @inserted, { %{$_[1]} }; return 1 };
	local *subs::db_update = sub { return 1 };
	local *subs::db_query = sub { return ProbeTaskRows->new([]) };
	local *subs::db_select = sub { return ProbeTaskRows->new([]) };
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
	local *subs::session_duration_learn = sub { return 1 };
	local *subs::subprocessor = sub { my ($body) = @_; eval { $body->() }; return 1 };
	local *subs::remote_relay_request = sub { push @relay, { %{ $_[1] || {} } }; return 1 };
	local *Manager::warranty_resolve = sub { return 1 };
	local *Manager::warehouse_money_mirror = sub { return 1 };
	local *Manager::record_source_param = sub { return undef };
	local *Manager::record_audio = sub { return 1 };
	local *Manager::budget_runner = sub { return 1 };
	local *subs::intelligent_automation_toggle = sub { return 1 };
	local *subs::evaluation_run_trigger = sub { return 1 };
	local *Websocket::send = sub { return 1 };
	local *Websocket::console_command = sub { return [ @_ ] };

	my $tasks = &subs::task_writer(ProbeCtx->new, {
		papp => 'shower',
		app => 'shower',
		timestamp => 1_700_000_100_000,
		uuid => 'tw',
		name => 'completed',
		value => 'on',
		project => '', account => '', movement => '',
		server_time => 1_700_000_050_000,
	});

	is(scalar @inserted, 1, 'the completion writes one appointment row');
	is($inserted[0]{'type'}, 'stop', 'the finished row is a stop');
	is($inserted[0]{'source'}, 'task', 'and says a task wrote it');
	ok(!exists $inserted[0]{'completed_row'}, 'the completed_row flag never reaches SQL');

	is(scalar @relay, 1, 'the row is handed to the peers immediately, not only at the next sync');
	is($relay[0]{'override'}, 'manual', 'through the manual relay');
	is($relay[0]{'url'}, '/manager/appointment/writer', 'to the writer route');
	is($relay[0]{'dissemination'}, 'yes', 'as a broadcast');
	is($relay[0]{'params'}{'uuid'}, $inserted[0]{'uuid'}, 'carrying the row uuid');
	is($relay[0]{'params'}{'app'}, 'washing', 'and its app');
	is($relay[0]{'params'}{'completed_row'}, 1, 'the peer recognises it as a finished row');
	is($relay[0]{'params'}{'mirror'}, 'yes', 'and writes it as a mirror, not a second press');
	is($relay[0]{'params'}{'source'}, 'task', 'the peer keeps the task provenance');

	my ($entry) = grep { ($_->{'uuid'} // '') eq 'tw' } @{$tasks};
	is($entry->{'completed'}, 'on', 'the checklist is marked completed');
	is($entry->{'last_appt_uuid'}, $inserted[0]{'uuid'}, 'and remembers the row it wrote');

	# The invoice, ledger, tab, render, budget and evaluation work that follows
	# the insert is best-effort: a throw in any of it must not keep a written row
	# from the peers. (This is why the relay runs before it.)
	{
		@inserted = ();
		@relay = ();
		local *subs::evaluation_run_trigger = sub { die "no minion queue\n" };
		eval {
			&subs::task_writer(ProbeCtx->new, {
				papp => 'shower',
				app => 'shower',
				timestamp => 1_700_000_200_000,
				uuid => 'tw',
				name => 'completed',
				value => 'on',
				project => '', account => '', movement => '',
				server_time => 1_700_000_150_000,
			});
		};
		is(scalar @inserted, 1, 'the row is still written when a later hook throws');
		is(scalar @relay, 1, 'and it still reaches the peers');
	}
}

# ------------------------------------------------------------- the whole route
# POST /manager/tasks, end to end with the real task_writer and appointment_writer:
# the route relays its request (so a peer updates the checklist) AND the writer
# hands the finished row to the peers. Both are on the wire in the same request.
{
	my (@relay, @inserted);
	my $home = tempdir(CLEANUP => 1);
	make_path("$home/.president");
	my %lists = (
		'shower' => [ { uuid => 'tw', task => 'washing', appt => 'on', occurences => 1,
			duration => '5m', colour => '#abc', completed => 'off' } ],
	);

	no warnings 'redefine';
	no warnings 'once';
	local *subs::rightNow = sub { return 1_700_000_900_000 };
	local *subs::home = sub { my ($p) = @_; $p =~ s{^~/}{}; return "$home/$p" };
	local *subs::shorthand_name = sub { my ($name) = @_; $name =~ s/[^A-Za-z0-9_.-]/_/g; return substr($name, 0, 20) };
	local *subs::unformat_name = sub { return $_[0] };
	local *subs::subprocessor = sub { my ($body) = @_; eval { $body->() }; return 1 };
	local *subs::remote_relay_request = sub { push @relay, { %{ $_[1] || {} } }; return 1 };
	local *Manager::remote_relay_request = sub { push @relay, { %{ $_[1] || {} } }; return 1 };
	local *subs::setting_grabber = sub {
		my ($want) = @_;
		return encode_json($lists{ $want->{'app'} } || []) if (($want->{'setting'} // '') eq 'tasks');
		return '';
	};
	local *subs::setting_setter = sub { return 1 };
	local *subs::task_grabber = sub { return {} };
	local *subs::signatorial_designer = sub { return 'origin-signal' };
	local *subs::controller_builder = sub { return ProbeCtx->new };
	local *subs::database_grabber = sub { return (undef, undef, undef) };
	local *subs::setting_initializer = sub { return { app => $_[0], duration => 0 } };
	local *subs::typesetter = sub { return ($_[0], undef) };
	local *subs::settings_grabber = sub { return {} };
	local *subs::usual_appointment_maker = sub { return ({}, {}, undef, undef) };
	local *subs::source_parent_link = sub { return undef };
	local *subs::db_insert = sub { push @inserted, { %{$_[1]} }; return 1 };
	local *subs::db_update = sub { return 1 };
	local *subs::db_query = sub { return ProbeTaskRows->new([]) };
	local *subs::db_select = sub { return ProbeTaskRows->new([]) };
	local *subs::appt_header_printer = sub { return ('header', []) };
	local *subs::source_header_printer = sub { return 1 };
	local *subs::ago_calc = sub { return 1 };
	local *subs::appointment_theme_push = sub { return 1 };
	local *subs::visibility_cache_clear = sub { return 1 };
	local *subs::lockdown_sweep = sub { return 1 };
	local *subs::silence_appointment_settle = sub { return 1 };
	local *subs::clock_appointment_sync = sub { return 1 };
	local *subs::stop_target_row = sub { return undef };
	local *subs::session_duration_learn = sub { return 1 };
	local *Manager::warranty_resolve = sub { return 1 };
	local *Manager::warehouse_money_mirror = sub { return 1 };
	local *Manager::record_source_param = sub { return undef };
	local *Manager::record_audio = sub { return 1 };
	local *Manager::budget_runner = sub { return 1 };
	local *subs::intelligent_automation_toggle = sub { return 1 };
	local *subs::evaluation_run_trigger = sub { return 1 };
	local *Websocket::send = sub { return 1 };
	local *Websocket::console_command = sub { return [ @_ ] };

	my $c = ProbeCtx->new(
		papp => 'shower', app => 'shower', name => 'completed', value => 'on',
		uuid => 'tw', timestamp => 1_700_000_100_000,
		project => '', account => '', movement => '',
	);
	Manager::action_25364($c);

	is(scalar @inserted, 1, 'the route writes the completion row');
	is(scalar @relay, 2, 'the same request puts two things on the wire');
	is($relay[0]{'dissemination'}, 'yes', 'first the request relay, so the peer updates its checklist');
	is($relay[1]{'override'}, 'manual', 'and the writer hands the finished row itself');
	is($relay[1]{'url'}, '/manager/appointment/writer', 'to the writer route');
	is($relay[1]{'params'}{'uuid'}, $inserted[0]{'uuid'}, 'with the row uuid');
	is($relay[1]{'params'}{'completed_row'}, 1, 'recognised as a finished row on the peer');
}

done_testing();
