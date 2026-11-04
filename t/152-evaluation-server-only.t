# tests-for: lib/JawnOS/Domain/Evaluation.pm lib/JawnOS/Domain/Run.pm
# covers:    automatic evaluations start on a server or a computer; a phone or
#            tablet still runs one on demand but never schedules or claims one.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use RepoSource;

require JawnOS::Domain::Evaluation;
require JawnOS::Domain::Run;

ok( subs::provides('evaluation_auto_here'), 'the domain loader maps evaluation_auto_here' );

# The machine class decides. Measured on the phone, a run is seconds of
# gathering and then minutes of one core while the model call is in flight. A
# computer is eligible so a house whose server cannot reach its model still gets
# the night's report; a phone or tablet is not.
foreach my $case ( [ 'server', 1 ], [ 'computer', 1 ], [ 'mobile', 0 ], [ 'tablet', 0 ] ) {
	my ($class, $want) = @{$case};
	local *subs::device_setter = sub { $class };
	is( subs::evaluation_auto_here(), $want, "$class " . ($want ? 'runs' : 'does not run') . ' automatic evaluations' );
}

# A fake queue: records what would be scheduled, unscheduled or enqueued.
{
	package FakeMinion;
	sub new { my ($class, %arg) = @_; return bless { %arg, scheduled => [], unscheduled => [], enqueued => [] }, $class; }
	sub schedule { my ($self, $name) = @_; push @{ $self->{'scheduled'} }, $name; return 1; }
	sub unschedule { my ($self, $name) = @_; push @{ $self->{'unscheduled'} }, $name; return 1; }
	sub list_schedules { my ($self) = @_; return { schedules => $self->{'list'} || [] }; }
	sub lock { return 1; }
	sub enqueue { my ($self, $task) = @_; push @{ $self->{'enqueued'} }, $task; return 1; }
}

# A stand-in for the query object db_select/db_query return.
{
	package FakeRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class; }
	sub hashes { return $_[0]->{'rows'} }
}

# A phone loses any schedule it had, even when a cadence is applied there: the
# wish is stored (it is house-wide) but the schedule is not the phone's.
{
	my $queue = FakeMinion->new();
	local *subs::device_setter = sub { 'mobile' };
	local *subs::minion_grabber = sub { $queue };
	local *subs::nightly_evaluation_name = sub { 'nightly_evaluation_tasks' };
	subs::evaluation_schedule_arrange('tasks');
	is_deeply( [ @{ $queue->{'unscheduled'} } ], ['nightly_evaluation_tasks'], 'a phone unschedules rather than schedules' );
	is( scalar @{ $queue->{'scheduled'} }, 0, 'and creates no schedule' );
}

# A server keeps it.
{
	my $queue = FakeMinion->new();
	local *subs::device_setter = sub { 'server' };
	local *subs::minion_grabber = sub { $queue };
	local *subs::nightly_evaluation_name = sub { 'nightly_evaluation_tasks' };
	local *subs::evaluation_schedule_cron = sub { '0 3 * * *' };
	subs::evaluation_schedule_arrange('tasks');
	is_deeply( [ @{ $queue->{'scheduled'} } ], ['nightly_evaluation_tasks'], 'the server schedules it' );
}

# A computer keeps it too: it may be the only machine in the house that can
# reach the model.
{
	my $queue = FakeMinion->new();
	local *subs::device_setter = sub { 'computer' };
	local *subs::minion_grabber = sub { $queue };
	local *subs::nightly_evaluation_name = sub { 'nightly_evaluation_tasks' };
	local *subs::evaluation_schedule_cron = sub { '0 3 * * *' };
	subs::evaluation_schedule_arrange('tasks');
	is_deeply( [ @{ $queue->{'scheduled'} } ], ['nightly_evaluation_tasks'], 'the computer schedules it' );
}

# The reconcile on a phone clears the nightly schedules and queues no catch-up.
{
	my $queue = FakeMinion->new(list => [ { name => 'nightly_evaluation_tasks' }, { name => 'other_job' } ]);
	local *subs::device_setter = sub { 'mobile' };
	local *subs::minion_grabber = sub { $queue };
	subs::nightly_evaluation_reconcile();
	is_deeply( [ @{ $queue->{'unscheduled'} } ], ['nightly_evaluation_tasks'], 'only the evaluation schedule is dropped' );
	is( scalar @{ $queue->{'enqueued'} }, 0, 'and nothing is run to catch up' );
}

# The each-run trigger is automatic too: a phone does not queue one.
{
	my $queue = FakeMinion->new();
	local *subs::device_setter = sub { 'mobile' };
	local *subs::minion_grabber = sub { $queue };
	local *subs::evaluation_cadence = sub { 'each_run' };
	ok( !subs::evaluation_run_trigger('tasks', { type => 'usual' }), 'a phone does not trigger an each-run evaluation' );
	is( scalar @{ $queue->{'enqueued'} }, 0, 'and queues nothing' );
}
{
	my $queue = FakeMinion->new();
	local *subs::device_setter = sub { 'server' };
	local *subs::minion_grabber = sub { $queue };
	local *subs::evaluation_cadence = sub { 'each_run' };
	ok( subs::evaluation_run_trigger('tasks', { type => 'usual' }), 'the server still triggers one' );
	is_deeply( [ @{ $queue->{'enqueued'} } ], ['appointment_evaluation'], 'and queues the job' );
}
{
	my $queue = FakeMinion->new();
	local *subs::device_setter = sub { 'computer' };
	local *subs::minion_grabber = sub { $queue };
	local *subs::evaluation_cadence = sub { 'each_run' };
	ok( subs::evaluation_run_trigger('tasks', { type => 'usual' }), 'a computer triggers one too' );
	is_deeply( [ @{ $queue->{'enqueued'} } ], ['appointment_evaluation'], 'and queues the job' );
}

# The dispatch tick belongs to a server or a computer, never a phone.
{
	local *subs::device_setter = sub { 'mobile' };
	is( subs::evaluation_dispatch_tick(), 0, 'a phone does not dispatch' );
}
{
	my $swept = 0;
	local *subs::device_setter = sub { 'computer' };
	local *subs::ai_house_me = sub { 'computer1' };
	local *subs::ai_house_dispatcher = sub { 'computer1' };
	local *subs::evaluation_dispatch_sweep = sub { $swept++; return 1 };
	local *subs::ai_house_server_known = sub { 1 };
	local *subs::db_query = sub { return FakeRows->new([]) };
	local *subs::minion_grabber = sub { FakeMinion->new() };
	is( subs::evaluation_dispatch_tick(), 1, 'a computer runs the tick' );
	is( $swept, 1, 'and sweeps the schedules it dispatches' );
}

# The class predicate the dispatcher and the election share.
{
	my @remote = (
		{ signatorial => 'server1',   device => 'server' },
		{ signatorial => 'computer1', device => 'computer' },
		{ signatorial => 'phone1',    device => 'mobile' },
	);
	local *subs::ai_house_me = sub { 'server1' };
	local *subs::device_setter = sub { 'server' };
	local *subs::db_select = sub {
		my ($table, $cols, $where) = @_;
		return FakeRows->new([]) unless $table eq 'remote_machines';
		if ($where && $where->{'signatorial'}) {
			my ($row) = grep { $_->{'signatorial'} eq $where->{'signatorial'} } @remote;
			return FakeRows->new($row ? [ $row ] : []);
		}
		return FakeRows->new(\@remote);
	};
	ok( subs::evaluation_auto_machine('server1'), 'a server may carry an automatic evaluation' );
	ok( subs::evaluation_auto_machine('computer1'), 'a computer may carry one' );
	ok( !subs::evaluation_auto_machine('phone1'), 'a phone may not' );
	ok( !subs::evaluation_auto_machine('unknown1'), 'an unlisted machine is not assumed capable' );
}

# The dispatcher addresses a ready computer even when the server that dispatches
# cannot reach its own model - the whole point of widening the class rule.
{
	my @remote = (
		{ signatorial => 'server1',   device => 'server' },
		{ signatorial => 'computer1', device => 'computer' },
		{ signatorial => 'phone1',    device => 'mobile' },
	);
	my @inserted;
	my $now = 1_700_000_000_000;
	my $queue = FakeMinion->new(list => [
		{ name => 'nightly_evaluation_tasks', next_run => ($now / 1000) + 300 },
	]);
	local *subs::ai_house_me = sub { 'server1' };
	local *subs::ai_house_dispatcher = sub { 'server1' };
	local *subs::ai_house_members = sub { return ( 'computer1', 'phone1' ) };
	local *subs::ai_house_eval_ready = sub { 0 };
	local *subs::evaluation_machine = sub { '' };
	local *subs::rightNow = sub { $now };
	local *subs::minion_grabber = sub { $queue };
	local *subs::db_select = sub {
		my ($table, $cols, $where) = @_;
		return FakeRows->new([]) unless $table eq 'remote_machines';
		return FakeRows->new(\@remote);
	};
	local *subs::db_delete = sub { return 1 };
	local *subs::db_insert = sub { my ($table, $row) = @_; push @inserted, { %{$row} } if $table eq 'ai_jobs'; return 1; };
	is( subs::evaluation_dispatch_sweep(), 1, 'the sweep writes one assignment' );
	is( scalar @inserted, 1, 'exactly one assignment is written' );
	is( $inserted[0]->{'owner'}, 'computer1', 'the dispatcher addresses the ready computer, not the phone' );
}

# A ready server is still preferred over a computer when there is one; the
# computer is the fallback for a house whose server cannot answer.
{
	my @remote = (
		{ signatorial => 'server1',   device => 'server' },
		{ signatorial => 'server2',   device => 'server' },
		{ signatorial => 'computer1', device => 'computer' },
	);
	my @inserted;
	my $now = 1_700_000_000_000;
	my $queue = FakeMinion->new(list => [
		{ name => 'nightly_evaluation_tasks', next_run => ($now / 1000) + 300 },
	]);
	local *subs::ai_house_me = sub { 'server1' };
	local *subs::ai_house_dispatcher = sub { 'server1' };
	local *subs::ai_house_members = sub { return ( 'server2', 'computer1' ) };
	local *subs::ai_house_eval_ready = sub { 0 };
	local *subs::evaluation_machine = sub { '' };
	local *subs::rightNow = sub { $now };
	local *subs::minion_grabber = sub { $queue };
	local *subs::db_select = sub { return FakeRows->new($_[0] eq 'remote_machines' ? \@remote : []) };
	local *subs::db_delete = sub { return 1 };
	local *subs::db_insert = sub { my ($table, $row) = @_; push @inserted, $row if $table eq 'ai_jobs'; return 1 };
	subs::evaluation_dispatch_sweep();
	is( $inserted[0]->{'owner'}, 'server2', 'a ready server is preferred over a computer' );
}

# A phone alone is still never addressed: the row would go unclaimed.
{
	my @remote = ( { signatorial => 'phone1', device => 'mobile' } );
	my @inserted;
	my $queue = FakeMinion->new(list => [
		{ name => 'nightly_evaluation_tasks', next_run => 1_700_000_300 },
	]);
	local *subs::ai_house_me = sub { 'server1' };
	local *subs::ai_house_dispatcher = sub { 'server1' };
	local *subs::ai_house_members = sub { return ('phone1') };
	local *subs::ai_house_eval_ready = sub { 0 };
	local *subs::evaluation_machine = sub { '' };
	local *subs::rightNow = sub { 1_700_000_000_000 };
	local *subs::minion_grabber = sub { $queue };
	local *subs::db_select = sub { return FakeRows->new($_[0] eq 'remote_machines' ? \@remote : []) };
	local *subs::db_delete = sub { return 1 };
	local *subs::db_insert = sub { push @inserted, $_[1]; return 1; };
	is( subs::evaluation_dispatch_sweep(), 0, 'a phone-only house gets no assignment' );
	is( scalar @inserted, 0, 'and nothing is written for it to miss' );
}

# The election is the fallback when no assignment exists (an asleep dispatcher,
# or a house with no server). It must name exactly one runner, and only a
# server or a computer, so a ready phone cannot take the night from under it.
{
	my @remote = (
		{ signatorial => 'server1',   device => 'server' },
		{ signatorial => 'computer1', device => 'computer' },
		{ signatorial => 'phone1',    device => 'mobile' },
	);
	local *subs::ai_house_me = sub { 'server1' };
	local *subs::device_setter = sub { 'server' };
	local *subs::ai_house_members = sub { return ( 'server1', 'computer1', 'phone1' ) };
	local *subs::rightNow = sub { 1_700_000_000_000 };
	local *subs::db_select = sub {
		my ($table, $cols, $where) = @_;
		return FakeRows->new([]) unless $table eq 'remote_machines';
		if ($where && $where->{'signatorial'}) {
			my ($row) = grep { $_->{'signatorial'} eq $where->{'signatorial'} } @remote;
			return FakeRows->new($row ? [ $row ] : []);
		}
		return FakeRows->new(\@remote);
	};
	my $first = subs::ai_job_runner('eval:tasks', 600_000, 1, 0);
	my $second = subs::ai_job_runner('eval:tasks', 600_000, 1, 0);
	is( $first, $second, 'the election is deterministic: exactly one runner, named twice' );
	ok( defined $first && $first ne 'phone1', 'and it is never the phone' );
	ok( $first eq 'server1' || $first eq 'computer1', 'a server or a computer carries it' );
}

# A ready computer may claim the run even when the server is not a candidate.
{
	my @remote = ( { signatorial => 'computer1', device => 'computer' } );
	my @inserted;
	local *subs::ai_house_me = sub { 'computer1' };
	local *subs::device_setter = sub { 'computer' };
	local *subs::ai_house_members = sub { return ('computer1') };
	local *subs::rightNow = sub { 1_700_000_000_000 };
	local *subs::db_select = sub { return FakeRows->new($_[0] eq 'remote_machines' ? \@remote : []) };
	local *subs::db_delete = sub { return 1 };
	local *subs::db_insert = sub { push @inserted, $_[1]; return 1; };
	ok( subs::ai_job_may_run('eval:tasks', 600_000, 1, 0), 'a ready computer may run the automatic evaluation' );
	is( scalar @inserted, 1, 'and writes its claim before the work starts' );
}

# A job left in the queue from before the change stands down rather than run on
# a phone.
{
	package FakeJob;
	sub new { return bless { finished => undef }, 'FakeJob'; }
	sub finish { my ($self, $note) = @_; $self->{'finished'} = $note; return 1; }
}
{
	my $job = FakeJob->new();
	local *subs::device_setter = sub { 'mobile' };
	subs::appointment_evaluation_job($job, { app => 'tasks' });
	ok( defined $job->{'finished'}, 'the phone finishes the job without running it' );
	like( $job->{'finished'}->{'skipped'}, qr/server|computer/, 'and says why' );
}

# Manual Evaluate is not gated: the button's route calls the agent directly, so
# a phone still runs one when a person asks.
{
	my $root = repo_root();
	my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc5.pm");
	my ($manual) = $controller =~ /(sub action_17913 \{.*?\n\}\n)/s;
	ok( $manual, 'the manual Evaluate action is one sub' );
	like( $manual, qr/&subs::evaluation_agent\(/, 'manual Evaluate reaches the evaluation agent' );
	unlike( $manual, qr/evaluation_auto_here/, 'and is never gated by the automatic class rule' );
}

done_testing();
