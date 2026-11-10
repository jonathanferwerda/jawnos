# Part of perl/President.pl (package President). The index requires this file
# at the line where this sub used to be defined. `use vars` names the package
# globals the moved code reads; `no warnings` reproduces the index's pragma
# state, so the code compiles and runs exactly as it did in place.
package President;
use strict;
use warnings;
no warnings qw(uninitialized once);
use vars qw($log);

# ---- add a main worker when they are all busy --------------------------------
# A worker serves one request at a time, and a model answer or a mail fetch can
# hold it for minutes. Every main worker keeps a marker under
# ~/.president/busy while it is inside a request (subs::request_busy_change).
# This supervisor watches those markers: when every worker in the pool has been
# busy for two seconds it sends TTIN, which Mojo::Server::Prefork's manager
# answers by adding a worker; when the pool has been quiet for half a minute it
# sends TTOU and retires one. Every machine may grow by two (a phone included:
# a gallery or music window can open a burst of files at once, and letting the
# phone grow while a burst is on screen beats pinning four idle workers all day).
# The supervisor is a child of the prefork manager (the process that becomes the
# manager when run() is called), so its signal names the manager directly and it
# retires with it.
#
# It does not keep its own worker count. TTIN and TTOU are plain signals: two
# sent together coalesce in the kernel, so a grow the manager answered with one
# worker was booked here as two. The next quiet window then sent TTOU for a
# worker that did not exist, `workers` fell to zero, and a manager at zero
# spawns nothing at all (Mojo::Server::Prefork::_manage) - the listening socket
# stayed open with no worker behind it until the master's watchdog restarted
# the whole tree. The manager publishes its own `workers` to
# ~/.president/pool instead (prefork_pool_write in perl/President.pl), and this
# process reads that number every sample. Below the floor it signals TTIN and
# never TTOU: a pool at zero cannot grow back on its own.
sub prefork_autoscale {
	my ($prefork, %opt) = @_;
	my $min = $opt{'min'} || $prefork->workers;
	my $max = $opt{'max'} || $min + 2;
	return $prefork if $max <= $min;
	my $dir = &subs::home('~/.president/busy');
	eval { mkdir $dir unless -d $dir; };
	my $parent = $$;
	# Before the fork, so the supervisor's first sample already has this
	# manager's number and never a previous tree's.
	&prefork_pool_write($prefork);
	my $pid = fork();
	unless (defined $pid) {
		$log->error('autoscale: cannot fork: ' . $!);
		return $prefork;
	}
	return $prefork if $pid;   # the prefork manager carries on
	# ---- supervisor child ----
	$0 = 'jawn autoscale';
	$SIG{$_} = 'DEFAULT' for qw/INT TERM HUP CHLD/;
	my ($high, $low) = (0, 0);
	my $settle = 0;
	# A worker that has just finished still says the person is moving: the marker
	# carries `start` while the request runs and `end` when it finishes, and an
	# `end` inside this window counts as activity. Without it a burst of short
	# page loads never holds every worker at one sample and the pool never grows.
	my $recent_ms = 3000;
	my $grow_after = 1;
	my $grow_by = 3;
	my $shrink_after = 20;
	my $shrink_by = 2;
	my $pool_file = &subs::home('~/.president/pool');
	while (1) {
		# Twice a second: a burst should be wider before the next request
		# arrives, not a second later.
		select(undef, undef, undef, 0.5);
		last unless kill 0, $parent;
		# The manager's target, not our own tally (see the note above). A
		# write caught mid-truncate, or a file naming another manager, is
		# unknown: send nothing that sample rather than shrink blind.
		my $current = &prefork_pool_read($pool_file, $parent);
		if (!defined $current) { $high = 0; $low = 0; next; }
		# Let the manager answer the last TTIN/TTOU and publish it before
		# deciding again, or one action is counted twice against a number
		# that has not moved yet.
		if ($settle) { $settle--; next; }
		my $now = &subs::rightNow();
		my $busy = 0;
		if (opendir(my $dh, $dir)) {
			foreach my $name ( grep { /^\d+$/ } readdir $dh ) {
				my $pid = int($name);
				my $file = "$dir/$name";
				my $state = '';
				if (open my $fh, '<', $file) { $state = <$fh> // ''; close $fh; }
				my ($kind, $at) = $state =~ /^(start|end)\s+(\d+)/;
				# a worker that died leaves its marker; an old finish is not
				# activity, and neither is a marker from an older tree
				unless (kill 0, $pid) { unlink $file; next; }
				if ($kind eq 'start') { $busy++; next; }
				if ($kind eq 'end' && $now - $at <= $recent_ms) { $busy++; next; }
				unlink $file;
			}
			closedir $dh;
		}
		# A pool below its floor (zero included) cannot grow back on its
		# own: the manager spawns only up to `workers`, and it has none left
		# to replace. This is the outage the master's watchdog restarts the
		# whole tree for, so ask for the floor before anything else.
		if ($current < $min) {
			my $add = $min - $current;
			kill 'TTIN', $parent for 1 .. $add;
			$log->info('autoscale: main pool at ' . $current . ', below its floor of ' . $min . '; raising');
			($high, $low, $settle) = (0, 0, 2);
			next;
		}
		if ($busy >= $current) { $high++ } else { $high = 0 }
		if ($high >= $grow_after && $current < $max) {
			my $add = $grow_by;
			$add = $max - $current if $current + $add > $max;
			kill 'TTIN', $parent for 1 .. $add;
			my $was = $current;
			($high, $low, $settle) = (0, 0, 2);
			$log->info('autoscale: all ' . $was . ' main workers active; raising to ' . ($was + $add));
			next;
		}
		if ($busy <= $current - 1) { $low++ } else { $low = 0 }
		if ($low >= $shrink_after && $current > $min) {
			my $drop = $shrink_by;
			$drop = $current - $min if $current - $drop < $min;
			kill 'TTOU', $parent for 1 .. $drop;
			($high, $low, $settle) = (0, 0, 2);
			$log->info('autoscale: main workers quiet; back to ' . ($current - $drop));
		}
	}
	POSIX::_exit(0);
}

# The manager's own worker target, published for the supervisor. The pid leads
# the line so a file left by a previous tree is not read as this one's. Only a
# change is written: a heartbeat arrives for every worker every second and the
# number is the same.
our $prefork_pool_last;
sub prefork_pool_write {
	my ($prefork) = @_;
	return unless $prefork;
	my $line = $$ . ' ' . $prefork->workers;
	my $file = &subs::home('~/.president/pool');
	return if defined $prefork_pool_last && $prefork_pool_last eq $line && -e $file;
	open(my $fh, '>', $file) or return;
	print $fh $line . "\n";
	close $fh;
	$prefork_pool_last = $line;
	return;
}

# The published target, or undef when the file is missing, half-written or
# names another manager. undef means "cannot tell", which the caller answers
# by sending no signal at all.
sub prefork_pool_read {
	my ($file, $manager) = @_;
	open(my $fh, '<', $file) or return undef;
	my $line = <$fh>;
	close $fh;
	return undef unless defined $line && $line =~ /^([0-9]+) ([0-9]+)\s*$/;
	return $1 == $manager ? $2 + 0 : undef;
}

1;
