package JawnOS::Platform::Process;

# Process identity, state, process-group and machine-load reads behind one
# interface, so the master, the parent guard, the subprocessor reaper, the BLE
# guard and the request-side monitors stop reading /proc in a dozen places.
#
# Linux reads /proc directly. A platform without it answers "cannot tell" ('' or
# undef or an empty list) instead of dying, which is what those callers already
# do when a read fails. macOS (ps/sysctl) and Windows (Win32::Process/tasklist)
# backends land in their roadmap phases: docs/platform-roadmap.md P2/P3.
#
# A pid is accepted only as digits. Nothing here starts a process, and only
# signal() and kill_tree() have a side effect.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
	pid_exists state running same_process start_time command_line
	cpu_ticks descendants parse_stat signal
	comm ppid pgrp cwd exe environ rss_kib
	table tree kill_tree
	meminfo uptime loadavg cpu_times
);

# The /proc mount. Tests point this at a fixture tree; nothing else changes it.
our $PROC_ROOT = '/proc';

sub _proc_path {
	my ($name) = @_;
	return "$PROC_ROOT/$name";
}

# The process state letter from /proc/<pid>/stat (S, R, Z, ...), or '' when it
# cannot be read. The second field is "(comm)", which can hold spaces and
# parentheses, so cut through its closing paren first.
#
# rss is field 24 in pages (the Monitor's `r`), and it is reported here rather
# than recomputed because that is exactly the number the process viewer shows.
sub parse_stat {
	my ($line) = @_;
	return undef unless defined $line;
	my $open = index($line, '(');
	my $close = rindex($line, ')');
	return undef if $open < 0 || $close < $open;
	my @field = split ' ', substr($line, $close + 2);
	return {
		comm  => substr($line, $open + 1, $close - $open - 1),
		state => $field[0],
		ppid  => $field[1],
		pgrp  => $field[2],
		utime => $field[11],
		stime => $field[12],
		start => $field[19],   # field 22; field 3 is state, so it is index 19
		rss   => $field[21],   # field 24, in pages
	};
}

sub _is_pid {
	my ($pid) = @_;
	return (defined $pid && $pid =~ /^[0-9]+$/) ? 1 : 0;
}

sub _stat_line {
	my ($pid) = @_;
	return undef unless _is_pid($pid);
	open(my $fh, '<', _proc_path("$pid/stat")) or return undef;
	my $line = <$fh>;
	close $fh;
	return $line;
}

# A /proc/<pid>/ field read as a whole file with NULs turned into spaces, or ''
# when it cannot be read. command_line, environ and their kin all have this
# shape: a caller's name test is simply skipped rather than run against nothing.
sub _nul_joined {
	my ($path) = @_;
	open(my $fh, '<', $path) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	$text = '' unless defined $text;
	$text =~ s/\0/ /g;
	return $text;
}

# The process name from stat, or '' when it cannot be read.
sub comm {
	my ($pid) = @_;
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'comm'}) ? $stat->{'comm'} : '';
}

# The process state from /proc/<pid>/stat, or '' when it cannot be read.
sub state {
	my ($pid) = @_;
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'state'}) ? $stat->{'state'} : '';
}

# The parent pid, or '' when it cannot be read.
sub ppid {
	my ($pid) = @_;
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'ppid'}) ? $stat->{'ppid'} : '';
}

# The process group, or '' when it cannot be read.
sub pgrp {
	my ($pid) = @_;
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'pgrp'}) ? $stat->{'pgrp'} : '';
}

# Exists and can be signalled. A killed child stays visible to kill(0) until its
# parent reaps it, so this is the "the number is still taken" test, not the
# "the process is working" test.
sub pid_exists {
	my ($pid) = @_;
	return 0 unless _is_pid($pid);
	return kill(0, $pid) ? 1 : 0;
}

# Exists and is not a zombie. This is the right test for a supervisor: a killed
# child is not working just because its pid answers.
sub running {
	my ($pid) = @_;
	return 0 unless pid_exists($pid);
	my $state = state($pid);
	return 0 if $state eq 'Z' || $state eq 'X' || $state eq 'x';
	return 1;
}

# /proc/<pid>/stat's start time (field 22). It identifies the process rather
# than its name: a recycled pid starts later, so the token is what tells them
# apart. '' when the platform cannot supply one.
sub start_time {
	my ($pid) = @_;
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'start'}) ? $stat->{'start'} : '';
}

# The pid is running and, where a start token was captured, is still the same
# process rather than an unrelated one that inherited the number. An empty
# token means no identity was captured, so liveness alone decides.
sub same_process {
	my ($pid, $start) = @_;
	return 0 unless running($pid);
	return 1 unless defined $start && length $start;
	my $now = start_time($pid);
	return ($now ne '' && $now eq $start) ? 1 : 0;
}

# The command line with NUL separators turned into spaces, or '' when it cannot
# be read. A platform without /proc returns '' so a caller's name test is simply
# skipped rather than run against nothing.
sub command_line {
	my ($pid) = @_;
	return '' unless _is_pid($pid);
	return _nul_joined(_proc_path("$pid/cmdline"));
}

# The environment with NUL separators turned into spaces, or '' when it cannot
# be read. Same shape as command_line: a name test sees nothing rather than
# dying on a platform that does not expose its processes.
sub environ {
	my ($pid) = @_;
	return '' unless _is_pid($pid);
	return _nul_joined(_proc_path("$pid/environ"));
}

# Where the process is working, '' when it cannot be read (another user, or no
# /proc). readlink on /proc/<pid>/cwd is the same answer the process monitor and
# the BLE guard compare against their own root.
sub cwd {
	my ($pid) = @_;
	return '' unless _is_pid($pid);
	my $path = readlink(_proc_path("$pid/cwd"));
	return defined $path ? $path : '';
}

# The executable, '' when it cannot be read. A deleted binary comes back with
# the kernel's " (deleted)" suffix; that is left on, since it is what the kernel
# reports.
sub exe {
	my ($pid) = @_;
	return '' unless _is_pid($pid);
	my $path = readlink(_proc_path("$pid/exe"));
	return defined $path ? $path : '';
}

# utime + stime in clock ticks, or undef when the platform cannot read them.
# CLK_TCK is 100 on Linux and Android; a caller comparing a delta to a core
# divides by its own hz, as JawnOS::Ble::Guard::cpu_hog does.
sub cpu_ticks {
	my ($pid) = @_;
	my $stat = parse_stat(_stat_line($pid));
	return undef unless $stat;
	return undef unless defined $stat->{'utime'} && defined $stat->{'stime'};
	return $stat->{'utime'} + $stat->{'stime'};
}

# Resident memory in KiB from /proc/<pid>/status, or undef when it cannot be
# read. The Monitor graph uses stat's rss (pages) instead; this is the value the
# worker-memory log prints, and it keeps its old unit and its old "?" on doubt.
sub rss_kib {
	my ($pid) = @_;
	return undef unless _is_pid($pid);
	open(my $fh, '<', _proc_path("$pid/status")) or return undef;
	my $rss;
	while (my $line = <$fh>) {
		if ($line =~ /VmRSS:\s+(\d+)/) {
			$rss = $1;
			last;
		}
	}
	close $fh;
	return $rss;
}

# One pass over /proc, as an arrayref of process records. A record is
#   {pid, ppid, pgrp, state, start, utime, stime, rss, comm, cmdline, cwd, exe}
# where pid is the directory name (a string, as the Monitor has always emitted
# it), rss is stat field 24 in pages, and cmdline is NUL-joined with spaces.
# Entries whose stat cannot be read (another user, a process that just exited)
# are skipped, since nothing else about them is trustworthy.
#
# cwd and exe are read only when asked for (`table(cwd => 1, exe => 1)`); they
# are '' otherwise, the same "cannot tell" a denied read gives. Each is one more
# symlink read per pid, which the monitor's two-second poll does not need.
sub table {
	my (%opt) = @_;
	my @rows;
	opendir(my $dh, $PROC_ROOT) or return \@rows;
	foreach my $pid (readdir $dh) {
		next unless $pid =~ /^[0-9]+$/;
		my $stat = parse_stat(_stat_line($pid));
		next unless $stat;
		push @rows, {
			pid     => $pid,
			ppid    => $stat->{'ppid'},
			pgrp    => $stat->{'pgrp'},
			state   => $stat->{'state'},
			start   => $stat->{'start'},
			utime   => $stat->{'utime'},
			stime   => $stat->{'stime'},
			rss     => $stat->{'rss'},
			comm    => $stat->{'comm'},
			cmdline => command_line($pid),
			cwd     => $opt{'cwd'} ? cwd($pid) : '',
			exe     => $opt{'exe'} ? exe($pid) : '',
		};
	}
	closedir $dh;
	@rows = sort { $a->{'pid'} cmp $b->{'pid'} } @rows;
	return \@rows;
}

# The pids that descend from $pid through ppid, not including $pid itself. This
# is the ppid closure a kill-tree or a supervisor needs; read from one table()
# pass, so a process that exits mid-scan cannot shift the answer.
sub tree {
	my ($pid) = @_;
	my @found;
	return \@found unless _is_pid($pid) && $pid > 1;
	my %children;
	foreach my $row ( @{ table() } ) {
		push @{ $children{ $row->{'ppid'} } }, $row->{'pid'};
	}
	my @queue = @{ $children{$pid} || [] };
	my %seen;
	while (@queue) {
		my $child = shift @queue;
		next if $seen{$child}++;
		push @found, $child;
		push @queue, @{ $children{$child} || [] };
	}
	return \@found;
}

# Signal $pid and everything under it, children before their parent. Returns how
# many pids accepted the signal (0 when /proc or kill is unavailable). pid 1 and
# non-numeric targets are refused: this is a subtree stop, not a machine stop.
sub kill_tree {
	my ($pid, $sig) = @_;
	return 0 unless _is_pid($pid) && $pid > 1;
	$sig = 'TERM' unless defined $sig;
	my $sent = 0;
	my $children = tree($pid);
	for my $child (reverse @{$children}) {
		$sent++ if signal($sig, $child);
	}
	$sent++ if signal($sig, $pid);
	return $sent;
}

# The pids in $pgid other than $pid itself, skipping zombies. This is the
# wrapper's grandchild scan: a live member of the process group extends its
# ancestor's warranty.
sub descendants {
	my ($pid, $pgid) = @_;
	my @found;
	return \@found unless defined $pgid && $pgid =~ /^[0-9]+$/ && $pgid > 1;
	opendir(my $dh, $PROC_ROOT) or return \@found;
	foreach my $entry (readdir $dh) {
		next unless $entry =~ /^[0-9]+$/;
		next if _is_pid($pid) && $entry == $pid;
		my $stat = parse_stat(_stat_line($entry));
		next unless $stat;
		next if defined $stat->{'state'} && $stat->{'state'} eq 'Z';
		push @found, $entry if defined $stat->{'pgrp'} && $stat->{'pgrp'} == $pgid;
	}
	closedir $dh;
	return \@found;
}

# Send a signal to a pid or a negative process group, returning what kill()
# returns. MSWin32's kill only reaches emulated fork children, so the Windows
# backend replaces this with TerminateProcess/Job Objects in P3; until then a
# real pid is refused rather than half-signalled.
sub signal {
	my ($sig, $target) = @_;
	return 0 unless defined $sig && defined $target;
	return 0 if $^O eq 'MSWin32';
	return kill($sig, $target);
}

# MemTotal and MemAvailable in KiB, 0 when /proc/meminfo is unavailable (as the
# Monitor has always shown them).
sub meminfo {
	my %info = (total => 0, available => 0);
	open(my $fh, '<', _proc_path('meminfo')) or return \%info;
	while (my $line = <$fh>) {
		$info{'total'} = $1 if $line =~ /^MemTotal:\s+(\d+)/;
		$info{'available'} = $1 if $line =~ /^MemAvailable:\s+(\d+)/;
		last if $info{'total'} && $info{'available'};
	}
	close $fh;
	return \%info;
}

# Seconds since boot as a string, or undef when the platform denies it (Android
# denies /proc/uptime to apps, and the Monitor shows an unknown age there).
sub uptime {
	open(my $fh, '<', _proc_path('uptime')) or return undef;
	my $line = <$fh>;
	close $fh;
	return (defined $line && $line =~ /^([\d.]+)/) ? $1 : undef;
}

# The three load averages as one space-separated string, '' when unavailable.
sub loadavg {
	open(my $fh, '<', _proc_path('loadavg')) or return '';
	my $line = <$fh>;
	close $fh;
	return (defined $line && $line =~ /^([\d.]+ [\d.]+ [\d.]+)/) ? $1 : '';
}

# Per-core cumulative jiffies as [{t => total, i => idle + iowait}, ...]. The
# aggregate `cpu` line is skipped, so the caller gets one entry per core and
# diffs them in the browser. An unavailable file is an empty list.
sub cpu_times {
	my @cpus;
	open(my $fh, '<', _proc_path('stat')) or return \@cpus;
	while (my $line = <$fh>) {
		next if $line =~ /^cpu\s/;
		last unless $line =~ /^cpu(\d+)\s+(.*)$/;
		my @v = split ' ', $2;
		my $idle = ($v[3] // 0) + ($v[4] // 0);
		my $total = 0;
		$total += ($_ // 0) for @v;
		push @cpus, { t => $total, i => $idle };
	}
	close $fh;
	return \@cpus;
}

1;
