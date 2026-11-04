# tests-for: lib/JawnOS/Domain/Evaluation.pm lib/JawnOS/Domain/Run.pm
# covers:    automatic evaluations start on the server only; a phone, tablet or
#            laptop still runs one on demand but never schedules or claims one.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

require JawnOS::Domain::Evaluation;

ok( subs::provides('evaluation_auto_here'), 'the domain loader maps evaluation_auto_here' );

# The machine class decides. Measured on the phone, a run is seconds of
# gathering and then minutes of one core while the model call is in flight.
foreach my $case ( [ 'server', 1 ], [ 'mobile', 0 ], [ 'computer', 0 ] ) {
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

# A phone loses any schedule it had, even when a cadence is applied there: the
# wish is stored (it is house-wide) but the schedule is the server's.
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

# The dispatch tick belongs to the server.
{
	local *subs::device_setter = sub { 'mobile' };
	is( subs::evaluation_dispatch_tick(), 0, 'a phone does not dispatch' );
}

# A job left in the queue from before the change stands down rather than run.
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
	like( $job->{'finished'}->{'skipped'}, qr/server/, 'and says why' );
}

done_testing();
