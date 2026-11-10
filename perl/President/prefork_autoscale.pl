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
	# A worker that has just finished still says the person is moving: the marker
	# carries `start` while the request runs and `end` when it finishes, and an
	# `end` inside this window counts as activity. Without it a burst of short
	# page loads never holds every worker at one sample and the pool never grows.
	my $recent_ms = 3000;
	my $grow_after = 1;
	my $grow_by = 2;
	my $shrink_after = 10;
	my $shrink_by = 2;
	while (1) {
		sleep 1;
		last unless kill 0, $parent;
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
		if ($busy >= $current) { $high++ } else { $high = 0 }
		if ($high >= $grow_after && $current < $max) {
			my $add = $grow_by;
			$add = $max - $current if $current + $add > $max;
			kill 'TTIN', $parent for 1 .. $add;
			my $was = $current;
			$current += $add;
			$high = 0;
			$low = 0;
			$log->info('autoscale: all ' . $was . ' main workers active; raising to ' . $current);
		}
		if ($busy <= $current - 1) { $low++ } else { $low = 0 }
		if ($low >= $shrink_after && $current > $min) {
			my $drop = $shrink_by;
			$drop = $current - $min if $current - $drop < $min;
			kill 'TTOU', $parent for 1 .. $drop;
			$current -= $drop;
			$low = 0;
			$high = 0;
			$log->info('autoscale: main workers quiet; back to ' . $current);
		}
	}
	POSIX::_exit(0);
}

1;
