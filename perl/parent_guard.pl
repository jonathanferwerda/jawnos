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
use POSIX ();
use Time::HiRes qw(sleep);

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
	while (1) {
		sleep $interval;
		# the tree is the reason we exist; with it gone there is nothing to do
		last unless &running($tree);
		next if &alive($master);
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

# The process state from /proc/<pid>/stat (S, R, Z, ...), or '' when it cannot
# be read. The second field is "(comm)", which can hold spaces and parentheses,
# so cut through its closing paren first.
sub state {
	my ($pid) = @_;
	open(my $fh, '<', "/proc/$pid/stat") or return '';
	my $line = <$fh>;
	close $fh;
	return '' unless defined $line;
	$line =~ s/^.*\)\s+//;
	my ($state) = split /\s+/, $line;
	return defined $state ? $state : '';
}

# Exists and is not a zombie. This is the right test for the tree: a killed
# child stays visible to kill(0) until its parent reaps it.
sub running {
	my ($pid) = @_;
	return 0 unless $pid && $pid =~ /^[0-9]+$/;
	return 0 unless kill 0, $pid;
	my $state = &state($pid);
	return 0 if $state eq 'Z' || $state eq 'X' || $state eq 'x';
	return 1;
}

# The master is alive only when it exists, is not a zombie, and - where /proc
# can be read - still runs the master rather than an unrelated process that
# inherited the number in between polls.
sub alive {
	my ($pid) = @_;
	return 0 unless &running($pid);
	if (open(my $fh, '<', "/proc/$pid/cmdline")) {
		local $/;
		my $cmd = <$fh>;
		close $fh;
		$cmd = '' unless defined $cmd;
		$cmd =~ s/\0/ /g;
		return 0 if length $cmd && $cmd !~ m{(?:^|/)jawn(?:\s|$)};
	}
	return 1;
}

1;
