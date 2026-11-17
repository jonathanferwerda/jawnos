# Part of perl/President.pl (package President). The index requires this file
# at the line where this sub used to be defined. `use vars` names the package
# globals the moved code reads; `no warnings` reproduces the index's pragma
# state, so the code compiles and runs exactly as it did in place.
package President;
use strict;
use warnings;
no warnings qw(uninitialized once);
use vars qw($log);

# ---- add a worker when they are all busy --------------------------------
# A worker serves one request at a time, and a model answer or a mail fetch can
# hold it for minutes. Every worker in a pool with a dynamic range keeps a
# marker under ~/.president/busy/<pool> while it is inside a request
# (subs::request_busy_change). This supervisor watches those markers: when
# every worker in the pool has been busy for two seconds it sends TTIN, which
# Mojo::Server::Prefork's manager answers by adding a worker; when the pool has
# been quiet for half a minute it sends TTOU and retires one. The range comes
# from Configure -> Sys -> Workers, where a phone and a controller keep their
# maximum equal to their resting count (every extra worker is another full copy
# of the tree, and that spike is what tripped Android's killer), while a desktop
# and a server may grow by two. The supervisor is a child of the prefork manager
# (the process that becomes the manager when run() is called), so its signal
# names the manager directly and it retires with it.
#
# The pool it reasons about is read from the manager, never assumed. TTIN and
# TTOU are ordinary signals, so a burst of them is coalesced by the kernel into
# one delivery: a grow burst of three can leave the manager with one extra
# worker while this side believes it has three. A later shrink then retires
# workers that were never created. It used to reach zero, and a manager asked
# for zero workers never starts one again - it keeps the listening socket and
# answers nothing until the watchdog restarts the tree.
sub prefork_autoscale {
	my ($prefork, %opt) = @_;
	my $min = $opt{'min'} || $prefork->workers;
	my $max = $opt{'max'} || $min + 2;
	return $prefork if $max <= $min;
	# One folder per pool: every manager runs a supervisor, and a shared folder
	# would let the socket server's supervisor count the main server's busy
	# workers and grow a pool nobody was waiting on.
	my $pool = $opt{'pool'} || 'main';
	$pool = 'main' unless $pool =~ /^[a-z0-9_]+$/;
	my $dir = &subs::home('~/.president/busy/' . $pool);
	eval { mkdir $dir unless -d $dir; };
	my $parent = $$;
	my $started = &prefork_parent_start($parent);
	my $pid = fork();
	unless (defined $pid) {
		$log->error('autoscale: cannot fork: ' . $!);
		return $prefork;
	}
	return $prefork if $pid;   # the prefork manager carries on
	# ---- supervisor child ----
	$0 = 'jawn autoscale ' . $pool;
	$SIG{$_} = 'DEFAULT' for qw/INT TERM HUP CHLD/;
	my ($current, $high, $low) = ($min, 0, 0);
	# A worker that has just finished still says the person is moving: the marker
	# carries `start` while the request runs and `end` when it finishes, and an
	# `end` inside this window counts as activity. Without it a burst of short
	# page loads never holds every worker at one sample and the pool never grows.
	my $recent_ms = 3000;
	my $grow_after = 1;
	my $grow_by = 3;
	my $shrink_after = 20;
	my $shrink_by = 2;
	while (1) {
		# Twice a second: a burst should be wider before the next request
		# arrives, not a second later.
		select(undef, undef, undef, 0.5);
		last unless &prefork_parent_alive($parent, started => $started);
		# The manager's own children are its workers plus this supervisor. Reading
		# them every tick keeps `$current` in step with the pool a signal burst
		# really produced; where the platform cannot tell (no /proc, a just-forked
		# manager) fall back to the last target.
		my $live = &prefork_live_workers($parent);
		$live = $current unless defined $live;
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
		# A pool nobody can see is not a busy pool: `busy >= live` was also
		# true for 0 >= 0, so an unreadable pool grew and logged every tick.
		if ($live && $busy >= $live) { $high++ } else { $high = 0 }
		if ($high >= $grow_after && $live && $live < $max) {
			my $add = $grow_by;
			$add = $max - $live if $live + $add > $max;
			kill 'TTIN', $parent for 1 .. $add;
			$current = $live + $add;
			$high = 0;
			$low = 0;
			$log->info('autoscale ' . $pool . ': all ' . $live . ' workers active; raising to ' . $current);
		}
		if ($busy <= $live - 1) { $low++ } else { $low = 0 }
		if ($low >= $shrink_after && $live > $min) {
			my $drop = $shrink_by;
			$drop = $live - $min if $live - $drop < $min;
			kill 'TTOU', $parent for 1 .. $drop;
			$current = $live - $drop;
			$low = 0;
			$high = 0;
			$log->info('autoscale ' . $pool . ': workers quiet; back to ' . $current);
		}
	}
	POSIX::_exit(0);
}

# Is the manager that forked this supervisor still the same process? A PID is
# only a number: once the manager dies the kernel hands it out again, and
# `kill 0` then reports a live manager that is really an unrelated process -
# two supervisors outlived a restart that way and kept raising a pool no one
# owned. Reparenting is the first evidence (an orphan's parent becomes init),
# and the start time captured at fork is the second (a reused PID cannot share
# it). `live_start` is read here unless a caller passes one; undef means the
# platform cannot tell, and then the kill check is all that is left.
sub prefork_parent_alive {
	my ($parent, %opt) = @_;
	return 0 unless defined $parent && $parent =~ /^[0-9]+$/;
	my $ppid = exists $opt{'ppid'} ? $opt{'ppid'} : getppid();
	return 0 unless $ppid == $parent;
	my $started = $opt{'started'};
	my $now = exists $opt{'live_start'} ? $opt{'live_start'} : &prefork_parent_start($parent);
	return 0 if defined $started && defined $now && $started ne $now;
	return 1 if kill 0, $parent;
	return 0;
}

# A process's start time (field 22 of /proc/<pid>/stat). Two samples that differ
# mean the PID now names a different process. undef where /proc is absent, so
# the caller falls back to the reparenting check alone.
sub prefork_parent_start {
	my ($pid) = @_;
	return undef unless defined $pid && $pid =~ /^[0-9]+$/;
	open(my $fh, '<', "/proc/$pid/stat") or return undef;
	my $line = <$fh>;
	close $fh;
	return undef unless defined $line;
	# the command name is parenthesised and may itself hold spaces
	$line =~ s/^.*\)\s+// or return undef;
	my @field = split /\s+/, $line;
	return $field[19];
}

# How many workers the manager actually has. It lists its direct children in one
# file on Linux (and on the Android it runs on); the supervisor itself is one of
# them and is not a worker. undef means "cannot tell", so the caller keeps its
# last target rather than shrinking a pool it cannot see.
sub prefork_live_workers {
	my ($parent) = @_;
	return undef unless defined $parent && $parent =~ /^[0-9]+$/;
	open(my $fh, '<', "/proc/$parent/task/$parent/children") or return undef;
	local $/;
	my $text = <$fh>;
	close $fh;
	return undef unless defined $text;
	my @children = grep { /^[0-9]+$/ } split /\s+/, $text;
	return scalar grep { $_ != $$ } @children;
}

# ---- a manager that cannot be asked for zero workers -------------------------
# Mojo::Server::Prefork answers TTOU by lowering `workers` by one with no floor,
# and `_manage` starts workers only while that target is above zero:
# `(workers - live) + spare`, where spare is added only for workers already
# shutting down. So a target of zero is permanent - the manager keeps the
# listening socket and never spawns again. Counting children keeps the
# supervisor honest, but a replacement the manager started while two graceful
# workers were still in its pool makes the count read high, and a platform
# without /proc gives no count at all. The floor is the guarantee: the manager is
# the only process that knows its own target, so it refuses to lower it below
# the resting pool. A stray TTOU then retires one worker and is replaced, but
# the pool never bottoms out.
package President::PoolPrefork;
use Mojo::Base 'Mojo::Server::Prefork';

has 'min_workers';

sub workers {
	my $self = shift;
	my $floor = $self->min_workers;
	return $self->SUPER::workers unless @_;
	my $want = shift;
	$want = $floor if defined $floor && $want < $floor;
	return $self->SUPER::workers($want);
}

1;
