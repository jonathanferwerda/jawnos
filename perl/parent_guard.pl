package parent_guard;

# No orphan workers.
#
# ./jawn is the master, perl/President.pl is the tree, and Mojo::Server::Prefork
# forks the workers from the tree. A graceful stop signals the tree, and Prefork
# ends the workers when the tree goes. But a master that is SIGKILLed - the
# Android app installing an APK did exactly that on the tablet - cannot signal
# anything, so the tree lived on with every worker under it, holding the ports
# and making the app's supervisor believe a master was still there.
#
# The watchdog is a small child of the tree. It polls the master the tree was
# born under and, when that master is gone, sends the tree the same SIGTERM a
# normal stop sends. Prefork then takes its one shutdown path (_term): the pool
# is killed and the manager exits. The watchdog leaves when the tree does, so it
# is not a new orphan.
#
# It is a child process rather than a Mojo::IOLoop timer on purpose: Prefork's
# manager loop polls its heartbeat pipe with Mojo::Util::_readable and never
# ticks the IOLoop, so a timer registered before run() would not fire there.

use strict;
use warnings;
use Config;
use POSIX ();
use Mojo::IOLoop;
use Time::HiRes qw(sleep);
BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../lib" if $dir && -d "$dir/../lib";
}
use JawnOS::Platform::Process ();

# start(tree => PID, master => PID, interval => SECONDS)
# Returns the watchdog pid in the tree, has no return in the watchdog, or
# returns undef when the fork fails.
sub start {
	my (%o) = @_;
	my $tree = $o{'tree'} || $$;
	my $master = $o{'master'} || getppid();
	return undef unless $tree =~ /^[0-9]+$/ && $master =~ /^[0-9]+$/;
	my $pid = fork();
	return undef unless defined $pid;
	return $pid if $pid;
	# ---- the watchdog ----
	$0 = 'jawn guard';
	$SIG{$_} = 'DEFAULT' for qw/INT TERM HUP CHLD PIPE/;
	my $interval = $o{'interval'} || 1;
	my $master_start = &start_time($master);
	while (1) {
		sleep $interval;
		# the tree is the reason we exist; with it gone there is nothing to do
		last unless &running($tree);
		next if &alive($master, $master_start);
		kill 'TERM', $tree;
		# Prefork's _term kills the pool and exits the manager. Give the tree
		# real time to run it (safe signals are deferred), then force what is
		# left; a bare `sleep 0.1` would truncate to zero and SIGKILL the tree
		# before it ever saw the TERM.
		for (1 .. 50) {
			sleep 0.1;
			last unless &running($tree);
		}
		kill 'KILL', $tree if &running($tree);
		last;
	}
	POSIX::_exit(0);
}

# The /proc reads live in JawnOS::Platform::Process, where the macOS and Windows
# backends can replace them without touching the guard's rules. The wrappers
# stay because the guard's names are part of its own shape.

# The process state (S, R, Z, ...), or '' when it cannot be read.
sub state { return JawnOS::Platform::Process::state($_[0]) }

# Exists and is not a zombie. This is the right test for the tree: a killed
# child stays visible to kill(0) until its parent reaps it.
sub running { return JawnOS::Platform::Process::running($_[0]) }

# The start token identifies the process rather than its name: the QA harness
# runs the tree under script(1), whose command line does not mention jawn, and
# that wrapper is as legitimate a master as ./jawn. A recycled pid starts later,
# so the time is what tells them apart.
sub start_time { return JawnOS::Platform::Process::start_time($_[0]) }

# The master is alive only when it exists, is not a zombie, and - where a start
# token can be read - is still the same process rather than an unrelated one
# that inherited the number in between polls.
sub alive {
	my ($pid, $start) = @_;
	return 0 unless &running($pid);
	if (defined $start && length $start) {
		my $now = &start_time($pid);
		return ($now ne '' && $now eq $start) ? 1 : 0;
	}
	# No start time was captured (no /proc): fall back to the name test.
	my $cmd = JawnOS::Platform::Process::command_line($pid);
	return 0 if length $cmd && $cmd !~ m{(?:^|/)jawn(?:\s|$)};
	return 1;
}

# prctl(PR_SET_PDEATHSIG, SIGKILL): the kernel kills a worker the instant its
# manager thread dies, even if a request has the event loop blocked. The
# syscall number is per architecture; an unknown platform falls back to the
# prefork heartbeat (now 1s) and the loop check below.
my %PRCTL = (
	x86_64  => 157,
	aarch64 => 167,
	arm     => 172,
	i386    => 172,
	i686    => 172,
	riscv64 => 167,
	ppc64   => 171,
	ppc64le => 171,
);

sub pdeathsig_supported {
	return 0 unless $^O eq 'linux';
	my ($arch) = $Config{'archname'} =~ /^([^-]+)/;
	return $PRCTL{$arch} ? 1 : 0;
}

sub pdeathsig {
	return 0 unless &pdeathsig_supported;
	my ($arch) = $Config{'archname'} =~ /^([^-]+)/;
	my $ok = eval { syscall($PRCTL{$arch}, 1, 9) };   # PR_SET_PDEATHSIG, SIGKILL
	return (defined $ok && $ok == 0) ? 1 : 0;
}

# A prefork worker must leave with the manager that forked it. The kernel does
# this at once where prctl exists; otherwise the worker's loop checks its parent
# every second, and the prefork heartbeat is the same fallback from the other
# side. This is what closes the old five-second window in which a SIGKILLed
# manager's workers still held the listening sockets.
sub worker {
	my ($manager) = @_;
	$manager ||= getppid();
	return 0 unless $manager && $manager =~ /^[0-9]+$/;
	my $direct = &pdeathsig();
	# the manager can die between fork and this call; prctl is too late then
	POSIX::_exit(0) if getppid() != $manager;
	unless ($direct) {
		Mojo::IOLoop->recurring(1 => sub {
			POSIX::_exit(0) if getppid() != $manager;
		});
	}
	return 1;
}

1;
