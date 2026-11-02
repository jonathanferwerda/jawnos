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
sub prefork_autoscale {
	my ($prefork, %opt) = @_;
	my $min = $opt{'min'} || $prefork->workers;
	my $max = $opt{'max'} || $min + 2;
	return $prefork if $max <= $min;
	my $dir = &subs::home('~/.president/busy');
	eval { mkdir $dir unless -d $dir; };
	my $parent = $$;
	my $pid = fork();
	unless (defined $pid) {
		$log->error('autoscale: cannot fork: ' . $!);
		return $prefork;
	}
	return $prefork if $pid;   # the prefork manager carries on
	# ---- supervisor child ----
	$0 = 'jawn autoscale';
	$SIG{$_} = 'DEFAULT' for qw/INT TERM HUP CHLD/;
	my ($current, $high, $low) = ($min, 0, 0);
	while (1) {
		sleep 1;
		last unless kill 0, $parent;
		my $busy = 0;
		if (opendir(my $dh, $dir)) {
			foreach my $name ( grep { /^\d+$/ } readdir $dh ) {
				my $file = "$dir/$name";
				my $age = time - ((stat($file))[9] || 0);
				# a worker that died leaves its marker; a request lost by a live
				# worker is aged out rather than left to keep a worker forever
				unless (kill 0, int($name)) { unlink $file; next; }
				if ($age > 1800) { unlink $file; next; }
				$busy++;
			}
			closedir $dh;
		}
		# Mojo's `spare` only widens the pool while a worker is stopping
		# gracefully; in steady state the pool is exactly `workers`.
		my $pool = $current;
		if ($busy >= $pool) { $high++ } else { $high = 0 }
		if ($high >= 2 && $current < $max) {
			kill 'TTIN', $parent;
			$current++;
			$high = 0;
			$low = 0;
			$log->info('autoscale: all ' . $pool . ' main workers busy; raising to ' . $current);
		}
		if ($busy <= $current - 1) { $low++ } else { $low = 0 }
		if ($low >= 30 && $current > $min) {
			kill 'TTOU', $parent;
			$current--;
			$low = 0;
			$high = 0;
			$log->info('autoscale: main workers quiet; back to ' . $current);
		}
	}
	POSIX::_exit(0);
}

1;
