package Monitor;

# A sampler for the QA layers: CPU and memory for the instance's process tree,
# plus the host pressure the tree is actually living under.
#
# Samples go to one JSON-lines file, one line per tick, so a crashed run still
# leaves usable evidence. The parent never reads /proc for the instance - the
# child does, once a second, and stays out of the request path.
#
# Inside the PID namespace /proc holds only the instance, so the tree scan is
# cheap and sees nothing of the live house.

use strict;
use warnings;

use Time::HiRes qw(time sleep);
use JSON::PP;
use POSIX ();

our $VERSION = '1';

sub start {
	my ($class, %opt) = @_;
	my $out  = $opt{'out'}  or die "Monitor: no output path\n";
	my $tree = $opt{'tree'} or die "Monitor: no tree\n";
	my $db   = $opt{'db'} || "$tree/database/jawnos.db";
	my $every = $opt{'every'} || 1;

	my $pid = fork();
	die "Monitor: fork: $!\n" unless defined $pid;
	if (!$pid) {
		POSIX::setsid();
		open(my $fh, '>>', $out) or POSIX::_exit(1);
		$fh->autoflush(1);
		my $json = JSON::PP->new->canonical;
		my $page = 4096;
		my %last;
		my $prev = time;

		while (1) {
			my $now = time;
			my $dt  = $now - $prev;
			$dt = 1 if $dt <= 0;
			$prev = $now;

			my %row = (t => $now, dt => $dt);

			# host memory and pressure
			my %mem;
			if (open(my $m, '<', '/proc/meminfo')) {
				while (my $line = <$m>) {
					$mem{$1} = $2 if $line =~ /^(\w+):\s+(\d+)/;
				}
				close $m;
			}
			$row{'mem_total_kb'}     = $mem{'MemTotal'};
			$row{'mem_available_kb'} = $mem{'MemAvailable'};
			$row{'swap_free_kb'}     = $mem{'SwapFree'};

			if (open(my $p, '<', '/proc/pressure/memory')) {
				my $line = <$p>;
				close $p;
				$row{'psi_memory'} = $1 if defined $line && $line =~ /some\s+avg10=([\d.]+)/;
			}
			if (open(my $l, '<', '/proc/loadavg')) {
				my $line = <$l>;
				close $l;
				$row{'load1'} = $1 if defined $line && $line =~ /^([\d.]+)/;
			}

			# the instance's own processes
			my @procs;
			my $rss_total = 0;
			my $pss_total = 0;
			my $cpu_total = 0;
			my $threads   = 0;
			for my $dir (glob '/proc/[0-9]*') {
				my $cwd = readlink "$dir/cwd";
				next unless defined $cwd && index($cwd, $tree) == 0;
				my ($n) = $dir =~ m{/proc/(\d+)};
				next unless $n;

				my $stat = '';
				if (open(my $s, '<', "/proc/$n/stat")) { $stat = <$s> // ''; close $s }
				next unless length $stat;
				my $rest = $stat;
				$rest =~ s/^.*\)\s+//;
				my @f = split ' ', $rest;
				my $ticks = ($f[11] || 0) + ($f[12] || 0);
				my $rss_pages = 0;
				if (open(my $st, '<', "/proc/$n/statm")) {
					my $line = <$st>;
					close $st;
					my @m = split ' ', ($line // '');
					$rss_pages = $m[1] || 0;
				}
				my $rss_kb = int($rss_pages * $page / 1024);
				# RSS double-counts every page two forked workers share, which
				# makes a Perl prefork tree look like several GB. PSS is the
				# additive number; "Pss" in smaps_rollup is one read per process.
				my $pss_kb = 0;
				if (open(my $sm, '<', "/proc/$n/smaps_rollup")) {
					while (my $line = <$sm>) {
						$pss_kb = $1 if $line =~ /^Pss:\s+(\d+) kB/;
					}
					close $sm;
				}
				$pss_kb = $rss_kb unless $pss_kb;
				my $thr = 0;
				if (open(my $st, '<', "/proc/$n/status")) {
					while (my $line = <$st>) { $thr = $1 if $line =~ /^Threads:\s+(\d+)/ }
					close $st;
				}
				my $delta = defined $last{$n} ? $ticks - $last{$n} : 0;
				$last{$n} = $ticks;
				my $cpu = $delta / 100 / $dt;   # ticks (100/s) -> cores used
				$rss_total += $rss_kb;
				$pss_total += $pss_kb;
				$cpu_total += $cpu;
				$threads   += $thr;
				push @procs, {
					pid => int($n), cpu => sprintf('%.3f', $cpu),
					rss_kb => $rss_kb, threads => $thr,
				};
			}
			@procs = sort { $b->{'cpu'} <=> $a->{'cpu'} } @procs;
			$row{'procs'}     = scalar @procs;
			$row{'rss_kb'}    = $rss_total;
			$row{'pss_kb'}    = $pss_total;
			$row{'cpu_cores'} = sprintf('%.3f', $cpu_total);
			$row{'threads'}   = $threads;
			$row{'top'}       = [ @procs[0 .. ($#procs < 4 ? $#procs : 4)] ];

			my @st = stat($db);
			$row{'db_bytes'} = $st[7] if @st;
			my @wl = stat("$db-wal");
			$row{'wal_bytes'} = $wl[7] if @wl;

			print $fh $json->encode(\%row), "\n";
			sleep $every;
		}
		POSIX::_exit(0);
	}

	return $pid;
}

sub stop {
	my ($class, $pid) = @_;
	return unless $pid;
	kill 'KILL', -$pid;
	kill 'KILL', $pid;
	# Do not waitpid an already-reaped sampler: that sets $? to -1 and can turn
	# a clean exit into 255 when this runs again from an END block.
	waitpid($pid, 0) if kill(0, $pid);
	return 1;
}

sub summarise {
	my ($class, $path) = @_;
	return { samples => 0 } unless -f $path;
	open(my $fh, '<', $path) or return { samples => 0 };
	my $json = JSON::PP->new;
	my @rows;
	while (my $line = <$fh>) {
		my $r = eval { $json->decode($line) };
		push @rows, $r if ref $r eq 'HASH';
	}
	close $fh;
	return { samples => 0 } unless @rows;

	my ($rss_max, $pss_max, $cpu_max, $procs_max, $mem_min) = (0, 0, 0, 0);
	my $cpu_sum = 0;
	for my $r (@rows) {
		$rss_max   = $r->{'rss_kb'}    if ($r->{'rss_kb'}    || 0) > $rss_max;
		$pss_max   = $r->{'pss_kb'}    if ($r->{'pss_kb'}    || 0) > $pss_max;
		$cpu_max   = $r->{'cpu_cores'} if ($r->{'cpu_cores'} || 0) > $cpu_max;
		$procs_max = $r->{'procs'}     if ($r->{'procs'}     || 0) > $procs_max;
		$cpu_sum  += ($r->{'cpu_cores'} || 0) * ($r->{'dt'} || 1);
		$mem_min   = $r->{'mem_available_kb'}
			if defined $r->{'mem_available_kb'}
			&& (!$mem_min || $r->{'mem_available_kb'} < $mem_min);
	}
	my $sum = {
		samples      => scalar @rows,
		seconds      => $rows[-1]->{'t'} - $rows[0]->{'t'},
		rss_peak_kb  => $rss_max,
		pss_peak_kb  => $pss_max,
		cpu_peak     => $cpu_max,
		cpu_seconds  => $cpu_sum,
		procs_peak   => $procs_max,
		mem_min_kb   => $mem_min,
		first        => $rows[0],
		last         => $rows[-1],
	};
	return $sum;
}

1;
