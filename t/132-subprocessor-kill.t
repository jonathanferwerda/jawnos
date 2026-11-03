# tests-for: lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Process.pm
# covers:    a run_p child killed before it reports is named as a killed process,
#            not as a JSON error; and the reaper starts a deferred job's warranty
#            on the pass that first sees a live pid, not on the pass of the ask.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
# Before JawnOSTest: the harness makes its own temp dir, and File::Temp's END has
# to be registered first so the harness's cleanup (which uses it) is not.
use File::Temp qw(tempdir);
use IO::Socket::UNIX;
use POSIX ();
use Storable;
use File::Slurp qw(read_file);
use Mojo::IOLoop;
use JawnOSTest;

subs::preload('subprocessor');
subs::preload('subprocessor_failure_message');
subs::preload('subprocessor_warranty_at');
subs::preload('subprocessor_reap');

my $NOW = 1_700_000_000_000;

# The rejection Mojo::IOLoop::Subprocess hands back when the child's pipe closes
# empty. Its wording moves with the Mojo version and the deserializer, so assert
# on the class of error, not on one engine's string.
my $EMPTY_PIPE = 'Missing or empty input at offset 0 at Mojo/IOLoop/Subprocess.pm line 84.';
my $JSON_EMPTY = 'malformed JSON string, neither tag, array, object, number, string or atom, at character offset 0';

# A stand-in for the job object: Mojo keeps the child's pid there and, from
# `waitpid $pid, 0; $? >> 8`, the child's end in exit_code() - a signalled child
# arrives as a shell's 128+N.
sub fake_job {
	my ($pid, $status) = @_;
	my $job = bless({ pid => $pid, exit_code => $status }, 'FakeJob');
	no strict 'refs';
	*{'FakeJob::pid'} = sub { $_[0]->{'pid'} };
	*{'FakeJob::exit_code'} = sub { $_[0]->{'exit_code'} };
	return $job;
}

# ------------------------------------------------------------- the sentence
{
	my $msg = &subs::subprocessor_failure_message('budget runner',
		$JSON_EMPTY, fake_job(8974, 137));
	is($msg, 'subprocessor budget runner pid 8974 died without reporting (signal 9)',
		'a JSON error with a killed child is named as the kill it was');
	unlike($msg, qr/malformed JSON|JSON\.pm/i, 'and never mentions JSON');

	$msg = &subs::subprocessor_failure_message('appointment models', $EMPTY_PIPE, fake_job(4100, 143));
	is($msg, 'subprocessor appointment models pid 4100 died without reporting (signal 15)',
		'a TERM from the reaper reads as a TERM');

	$msg = &subs::subprocessor_failure_message('appointment models', $EMPTY_PIPE, fake_job(4100, 0));
	is($msg, 'subprocessor appointment models pid 4100 died without reporting (exit 0)',
		'a child that exits without a result is still named');

	$msg = &subs::subprocessor_failure_message('centre view', $EMPTY_PIPE, fake_job(77, 2));
	is($msg, 'subprocessor centre view pid 77 died without reporting (exit 2)',
		'a plain exit below 126 is named as an exit, never as signal 2');

	# A real job's own die goes down the pipe as a result, so a rejection with no
	# wait status is a failure to start (no fork, no pipe), not a death.
	$msg = &subs::subprocessor_failure_message('appt_header_printer',
		'Could not fork: Resource temporarily unavailable', fake_job(undef, undef));
	is($msg, 'subprocessor appt_header_printer could not start: Could not fork: Resource temporarily unavailable',
		'a rejection with no child keeps the honest start wording');

	$msg = &subs::subprocessor_failure_message('budget runner', $EMPTY_PIPE, undef);
	is($msg, 'subprocessor budget runner died without reporting (exit unknown)',
		'an unreachable job object loses the numbers, not the sentence');

	$msg = &subs::subprocessor_failure_message(undef, '', undef);
	is($msg, 'subprocessor ? could not start: no reason reported',
		'a rejection with no reason and no child is still honest about it');

	my $calendar = read_file(root() . '/lib/JawnOS/Domain/Calendar.pm');
	like($calendar, qr/my \$job = Mojo::IOLoop->subprocess;/, 'the wrapper keeps the job object');
	like($calendar, qr/subprocessor_failure_message\(\$name, \$why, \$job\)/,
		'and the catch reports through the honest message');
	unlike($calendar, qr/could not start: ' \. \$why/, 'the bare "could not start" is gone');
	}

# ------------------------------------------------------- a killed child
# This interpreter cannot let the forked child die of its own SIGKILL (the
# wrapper's work never begins), so the kill is asserted on the object the catch
# is handed: Mojo's pid(), and the wait status a SIGKILL leaves (128+9).
{
	# The wrapper still keeps the job object, which is what lets the catch name a pid.
	my $line = &subs::subprocessor_failure_message('t 132 doomed job',
		$EMPTY_PIPE, fake_job(4242, 137)) . "\n";
	like($line, qr/^subprocessor t 132 doomed job pid \d+ died without reporting \(signal 9\)$/,
		'a job whose child was SIGKILLed is named as a process that died without reporting');
	unlike($line, qr/malformed JSON|JSON\.pm|Missing or empty input/i, 'not as a JSON or deserializer fault');
}

# ------------------------------------------------------------ the reaper fix
sub tracked_record {
	my (%record) = @_;
	my $pid = $record{'pid'} || 200;
	my $record = {
		parent => 100, pid => $pid, name => 't 132 job', status => 'start',
		warranty => &subs::forever_warranty(), pgid => 0, %record,
	};
	return { 100 => { subprocesses => { $pid => $record } } };
}

# The bug: the master's pass after the ask saw the queued child, and - because
# /proc/<pid>/stat has no start time for a pid that has not been forked - stamped
# the deferred warranty there. The 60s ran out on the ask-to-fork wait, the term
# of its first check TERM'd the child 60s into its work, and the spec that was
# never cleared restamped on every later pass, moving the deadline for good.
{
	my $tracked = tracked_record(
		name => 'appointment models', pid => 90001,
		warranty => $NOW + 60_000, deferred_warranty_spec => '60s', pgid => 0);
	my $record = $tracked->{100}{subprocesses}{90001};
	my @kills;
	my $queued = &subs::subprocessor_reap($tracked,
		now => $NOW, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '0' }, descendants => sub { [] });
	is($record->{'warranty'}, $NOW + 60_000, 'a child still queued behind the request keeps the ask as a backstop');
	ok(!defined $record->{'warranty_started_at'}, 'and its warranty is not started yet');
	is($queued->{'expired'}, 0, 'a queued child is not expired');

	# The fork lands 40s later: this pass is the start.
	&subs::subprocessor_reap($tracked,
		now => $NOW + 40_000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '555' }, descendants => sub { [] });
	is($record->{'warranty'}, $NOW + 100_000, 'the warranty starts when the process appears');
	is($record->{'warranty_started_at'}, $NOW + 40_000, 'and the pass that saw it is named');

	# Its own minute is $NOW + 40_000 + 60_000 = $NOW + 100_000; nothing expires
	# before it, whatever the ask cost.
	my $early = &subs::subprocessor_reap($tracked,
		now => $NOW + 100_000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '555' }, descendants => sub { [] });
	is($early->{'expired'}, 0, 'a pass at exactly its deadline is not yet an expiry');
	my $late = &subs::subprocessor_reap($tracked,
		now => $NOW + 105_000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '555' }, descendants => sub { [] });
	is($late->{'expired'}, 1, 'past a minute of its own run it is expired');
	is(scalar @kills, 1, 'with one TERM, not a chain of them');

	my $moved = $record->{'warranty'};
	&subs::subprocessor_reap($tracked,
		now => $NOW + 200_000, alive => sub { 1 }, kill => sub { push @kills, [@_] },
		starttime => sub { '555' }, descendants => sub { [] });
	is($record->{'warranty'}, $moved, 'and a later pass does not restamp it');
}

# A queued job is not judged by its warranty until its process appears (that is
# the test above). A fork that never lands is not a licence to wait forever: the
# pass that first sees the pid can read /proc and finds no start time for a
# number the OS never gave, so a child that is really gone is still forgotten.
{
	my $tracked = tracked_record(
		name => 'budget runner', pid => 90002,
		warranty => $NOW + 60_000, deferred_warranty_spec => '60s', pgid => 0);
	my $record = $tracked->{100}{subprocesses}{90002};
	my @kills;
	my $report = &subs::subprocessor_reap($tracked,
		now => $NOW + 61_000, alive => sub { 0 }, kill => sub { push @kills, [@_] },
		starttime => sub { '0' }, descendants => sub { [] });
	is($report->{'reaped'}, 1, 'a pid that never existed is forgotten');
	is_deeply(\@kills, [], 'and never signalled');
	is($record->{'warranty'}, $NOW + 60_000, 'its ask deadline was never moved');
	is($report->{'expired'}, 0, 'and it was never counted as an expiry');
}

# The contract t/120 pins: both shapes of options, and a start time nobody
# reports (the /proc read failed) must not hold the stamp back for a whole run.
{
	for my $shape (qw(hashref list)) {
		my $tracked = tracked_record(
			name => 'centre view', pid => 90003,
			warranty => $NOW + 60_000, deferred_warranty_spec => '60s', pgid => 0);
		my $record = $tracked->{100}{subprocesses}{90003};
		my %opt = (now => $NOW + 2000, alive => sub { 1 }, kill => sub { 0 },
			starttime => sub { '' }, descendants => sub { [] });
		my $report = ($shape eq 'hashref')
			? &subs::subprocessor_reap($tracked, \%opt)
			: &subs::subprocessor_reap($tracked, %opt);
		is($record->{'warranty'}, $NOW + 2000 + 60_000, "an unreadable start time still starts the warranty ($shape)");
		is($report->{'reaped'}, 0, "and the live record is not forgotten ($shape)");
	}
}

done_testing();
