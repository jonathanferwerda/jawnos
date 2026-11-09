package JawnOS::Platform::Process;

# Process identity, state and process-group scans behind one interface, so the
# master, the parent guard, the subprocessor reaper and the BLE guard stop
# reading /proc in four places.
#
# Linux reads /proc directly. A platform without it answers "cannot tell" ('' or
# undef or an empty list) instead of dying, which is what those callers already
# do when a read fails. macOS (ps/sysctl) and Windows (Win32::Process/tasklist)
# backends land in their roadmap phases: docs/platform-roadmap.md P2/P3.
#
# A pid is accepted only as digits. Nothing here starts a process, and only
# signal() has a side effect.

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(
	pid_exists state running same_process start_time command_line
	cpu_ticks descendants parse_stat signal
);

# The process state letter from /proc/<pid>/stat (S, R, Z, ...), or '' when it
# cannot be read. The second field is "(comm)", which can hold spaces and
# parentheses, so cut through its closing paren first.
sub parse_stat {
	my ($line) = @_;
	return undef unless defined $line;
	my $close = rindex($line, ')');
	return undef if $close < 0;
	my @field = split ' ', substr($line, $close + 2);
	return {
		state => $field[0],
		ppid  => $field[1],
		pgrp  => $field[2],
		utime => $field[11],
		stime => $field[12],
		start => $field[19],   # field 22; field 3 is state, so it is index 19
	};
}

sub _is_pid {
	my ($pid) = @_;
	return (defined $pid && $pid =~ /^[0-9]+$/) ? 1 : 0;
}

sub _stat_line {
	my ($pid) = @_;
	return undef unless _is_pid($pid);
	open(my $fh, '<', "/proc/$pid/stat") or return undef;
	my $line = <$fh>;
	close $fh;
	return $line;
}

# The process state from /proc/<pid>/stat, or '' when it cannot be read.
sub state {
	my ($pid) = @_;
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'state'}) ? $stat->{'state'} : '';
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
	open(my $fh, '<', "/proc/$pid/cmdline") or return '';
	local $/;
	my $cmd = <$fh>;
	close $fh;
	$cmd = '' unless defined $cmd;
	$cmd =~ s/\0/ /g;
	return $cmd;
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

# The pids in $pgid other than $pid itself, skipping zombies. This is the
# wrapper's grandchild scan: a live member of the process group extends its
# ancestor's warranty.
sub descendants {
	my ($pid, $pgid) = @_;
	my @found;
	return \@found unless defined $pgid && $pgid =~ /^[0-9]+$/ && $pgid > 1;
	opendir(my $dh, '/proc') or return \@found;
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

1;
