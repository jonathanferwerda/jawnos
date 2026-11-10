package JawnOS::Platform::Job;

# One place that turns "run this named subprocessor job" into a child process.
#
# On a box with fork, subs::subprocessor still forks the job through
# Mojo::IOLoop::Subprocess, so nothing below runs. Windows has no fork -
# Strawberry's pseudofork makes Subprocess refuse outright - so subprocessor
# starts a registered job through JawnOS::Platform::Runner instead, and
# perl/subprocessor_worker.pl runs exactly one job in that process.
#
# The name is a domain key (subprocessor_warranty_for,
# subprocessor_heartbeat_for), so it must be the call site's exact string,
# never a random id: the warranty and lease tables are keyed by it.
#
# plan is pure: it names the interpreter, the lib include, the worker and the
# environment a job needs, and a test pins it. spawn is the impure half: it
# creates the runner, drains the child's output and starts it.

use strict;
use warnings;

use Cwd ();
use Mojo::JSON qw(encode_json);

sub plan {
	my ($name, $args, %opt) = @_;
	return undef unless defined $name && length $name;
	my $cwd = $opt{'cwd'} || Cwd::getcwd();
	$args = {} unless ref $args eq 'HASH';

	return {
		program      => $^X,
		program_args => [ '-I', "$cwd/lib", './perl/subprocessor_worker.pl', '--name', $name ],
		cwd          => $cwd,
		env          => { JAWNOS_JOB_ARGS => encode_json($args) },
	};
}

sub spawn {
	my ($name, $args) = @_;
	my $plan = &plan($name, $args);
	return undef unless $plan;

	require JawnOS::Platform::Runner;
	my $runner = JawnOS::Platform::Runner->new;
	$runner->conduit({ type => 'pipe' });

	# A resident job's log is the only place its own startup error is visible on
	# Windows, so drain the child instead of letting a full pipe stall it.
	my $log_file;
	eval {
		require JawnOS::Platform;
		require File::Path;
		my $dir = JawnOS::Platform::data_dir();
		File::Path::make_path($dir) unless -d $dir;
		(my $slug = $name) =~ s/[^A-Za-z0-9_.-]+/-/g;
		$log_file = "$dir/job-$slug.log";
	};
	my $read = sub {
		return unless $log_file;
		my ($runner, $bytes) = @_;
		if (open(my $fh, '>>', $log_file)) { print {$fh} $bytes; close $fh }
	};
	$runner->on(read => $read);
	$runner->on(close => sub { });

	my $pid;
	{
		# Runner::Windows ignores an env spec, and ReadWriteFork snapshots %ENV
		# when start is called, so the local covers both backends.
		local @ENV{ keys %{ $plan->{'env'} } } = values %{ $plan->{'env'} };
		$pid = $runner->start({
			program      => $plan->{'program'},
			program_args => $plan->{'program_args'},
			cwd          => $plan->{'cwd'},
		});
	}
	return { runner => $runner, pid => $pid };
}

1;
