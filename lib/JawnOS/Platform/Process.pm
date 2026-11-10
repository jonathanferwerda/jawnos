package JawnOS::Platform::Process;

# Process identity, state, process-group and machine-load reads behind one
# interface, so the master, the parent guard, the subprocessor reaper, the BLE
# guard and the request-side monitors stop reading /proc in a dozen places.
#
# Linux reads /proc directly. Windows reads the same facts from `tasklist` and
# `Get-CimInstance` (see the Windows section at the bottom), lazily, so a Unix
# box never loads a Win32 module and never runs a Windows command. macOS
# (ps/sysctl) still lands in its roadmap phase: docs/platform-roadmap.md P2.
#
# A platform that cannot answer gives the empty answer instead of dying ('' or
# undef or an empty list), which is what those callers already do when a read
# fails. That convention holds on every platform: Windows never throws just
# because powershell.exe is missing.
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
	table tree kill_tree ppid_closure
	meminfo uptime loadavg cpu_times
	parse_tasklist parse_cim parse_windows_os parse_windows_cpu
	cim_epoch windows_rows windows_snapshot windows_os windows_signal
	windows_pid_exists reset_cache
);

# The /proc mount. Tests point this at a fixture tree; nothing else changes it.
our $PROC_ROOT = '/proc';

# The Windows snapshot cache: seconds a tasklist/CIM read stays usable. A
# Monitor poll is two seconds apart and calls table() once, but the field reads
# (comm, rss_kib, start_time) call back into the seam per pid; without the cache
# each of those would enumerate every process again. A pid the snapshot does not
# have makes pid_exists() refresh once (a child may have just started); every
# other read keeps the cache. reset_cache() is the documented way to force a
# fresh read unconditionally (tests).
our $CACHE_TTL = 5;
our %CACHE;

# Test hook: when set, answers a Windows command instead of starting it, so the
# parsers and the empty-answer paths run on Linux. Nothing in a house sets it.
our $RUN;

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
	return _win_field($pid, 'comm') if $^O eq 'MSWin32';
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'comm'}) ? $stat->{'comm'} : '';
}

# The process state from /proc/<pid>/stat, or '' when it cannot be read.
sub state {
	my ($pid) = @_;
	return _win_field($pid, 'state') if $^O eq 'MSWin32';
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'state'}) ? $stat->{'state'} : '';
}

# The parent pid, or '' when it cannot be read.
sub ppid {
	my ($pid) = @_;
	return _win_field($pid, 'ppid') if $^O eq 'MSWin32';
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'ppid'}) ? $stat->{'ppid'} : '';
}

# The process group, or '' when it cannot be read.
sub pgrp {
	my ($pid) = @_;
	return _win_field($pid, 'pgrp') if $^O eq 'MSWin32';
	my $stat = parse_stat(_stat_line($pid));
	return (defined $stat && defined $stat->{'pgrp'}) ? $stat->{'pgrp'} : '';
}

# Exists and can be signalled. A killed child stays visible to kill(0) until its
# parent reaps it, so this is the "the number is still taken" test, not the
# "the process is working" test.
sub pid_exists {
	my ($pid) = @_;
	return 0 unless _is_pid($pid);
	return windows_pid_exists($pid) if $^O eq 'MSWin32';
	return kill(0, $pid) ? 1 : 0;
}

# Exists and is not a zombie. This is the right test for a supervisor: a killed
# child is not working just because its pid answers.
sub running {
	my ($pid) = @_;
	# Windows has no zombie state to detect: a pid is in the snapshot and
	# answers CIM, or it is gone. Nothing lingers the way a POSIX zombie does.
	return pid_exists($pid) if $^O eq 'MSWin32';
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
	return _win_field($pid, 'start') if $^O eq 'MSWin32';
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
	return _win_field($pid, 'cmdline') if $^O eq 'MSWin32';
	return _nul_joined(_proc_path("$pid/cmdline"));
}

# The environment with NUL separators turned into spaces, or '' when it cannot
# be read. Same shape as command_line: a name test sees nothing rather than
# dying on a platform that does not expose its processes.
sub environ {
	my ($pid) = @_;
	# Windows does not let one process read another's environment. P1
	# condition 2: identity comes from the command line or JAWNOS_TREE, so a
	# caller's name test is skipped rather than run against a made-up value.
	return '' if $^O eq 'MSWin32';
	return '' unless _is_pid($pid);
	return _nul_joined(_proc_path("$pid/environ"));
}

# Where the process is working, '' when it cannot be read (another user, or no
# /proc). readlink on /proc/<pid>/cwd is the same answer the process monitor and
# the BLE guard compare against their own root.
sub cwd {
	my ($pid) = @_;
	# Windows does not expose another process's working directory cheaply. P1
	# condition 2 says identity comes from the command line or JAWNOS_TREE, not
	# a cwd trick, so this stays empty instead of guessing.
	return '' if $^O eq 'MSWin32';
	return '' unless _is_pid($pid);
	my $path = readlink(_proc_path("$pid/cwd"));
	return defined $path ? $path : '';
}

# The executable, '' when it cannot be read. A deleted binary comes back with
# the kernel's " (deleted)" suffix; that is left on, since it is what the kernel
# reports.
sub exe {
	my ($pid) = @_;
	return _win_field($pid, 'exe') if $^O eq 'MSWin32';
	return '' unless _is_pid($pid);
	my $path = readlink(_proc_path("$pid/exe"));
	return defined $path ? $path : '';
}

# utime + stime in clock ticks, or undef when the platform cannot read them.
# CLK_TCK is 100 on Linux and Android; a caller comparing a delta to a core
# divides by its own hz, as JawnOS::Ble::Guard::cpu_hog does.
sub cpu_ticks {
	my ($pid) = @_;
	if ($^O eq 'MSWin32') {
		my $row = _win_row($pid);
		return undef unless $row;
		return undef unless defined $row->{'utime'} && defined $row->{'stime'};
		return $row->{'utime'} + $row->{'stime'};
	}
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
	if ($^O eq 'MSWin32') {
		my $row = _win_row($pid);
		return undef unless $row;
		return $row->{'rss'} * 4;   # pages of 4096 bytes; *4 is KiB
	}
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
	return _windows_table(%opt) if $^O eq 'MSWin32';
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
	return ppid_closure(table(), $pid);
}

# The closure itself, over rows already read in one pass. Shared by tree() on
# both platforms and called directly by the tests with a Windows fixture, so
# the fixture proves the same code the live tree runs.
sub ppid_closure {
	my ($rows, $pid) = @_;
	my @found;
	return \@found unless _is_pid($pid) && $pid > 1;
	my %children;
	foreach my $row ( @{ $rows || [] } ) {
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
	# Windows has no process groups; a caller's group scan finds nothing and
	# keeps its own rule rather than reading a group that does not exist.
	return \@found if $^O eq 'MSWin32';
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
# returns. Windows has no signals; both TERM and KILL terminate the process
# through TerminateProcess, which is what taskkill /F invokes. The Windows
# branch refuses pid < 8 (System, the registry writer and the idle process)
# and any non-numeric target.
sub signal {
	my ($sig, $target) = @_;
	return 0 unless defined $sig && defined $target;
	return windows_signal($target) if $^O eq 'MSWin32';
	return kill($sig, $target);
}

# MemTotal and MemAvailable in KiB, 0 when /proc/meminfo is unavailable (as the
# Monitor has always shown them).
sub meminfo {
	return _windows_meminfo() if $^O eq 'MSWin32';
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
	return _windows_uptime() if $^O eq 'MSWin32';
	open(my $fh, '<', _proc_path('uptime')) or return undef;
	my $line = <$fh>;
	close $fh;
	return (defined $line && $line =~ /^([\d.]+)/) ? $1 : undef;
}

# The three load averages as one space-separated string, '' when unavailable.
sub loadavg {
	# Windows has no load average: no API this seam can read exposes one, and
	# the Monitor shows nothing rather than a made-up number.
	return '' if $^O eq 'MSWin32';
	open(my $fh, '<', _proc_path('loadavg')) or return '';
	my $line = <$fh>;
	close $fh;
	return (defined $line && $line =~ /^([\d.]+ [\d.]+ [\d.]+)/) ? $1 : '';
}

# Per-core cumulative jiffies as [{t => total, i => idle + iowait}, ...]. The
# aggregate `cpu` line is skipped, so the caller gets one entry per core and
# diffs them in the browser. An unavailable file is an empty list.
sub cpu_times {
	return _windows_cpu_times() if $^O eq 'MSWin32';
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

# ------------------------------------------------------------------ Windows
#
# Windows has no /proc. Every sub above reaches this section only through a
# `$^O eq 'MSWin32'` branch, so a Unix box never runs a Windows command and
# never loads a Win32 module. (None is needed: the two commands below supply
# every read, so no Win32::* module is used at all.)
#
#   tasklist /FO CSV /NH          Image Name, PID, Session Name, Session# and
#                                 Mem Usage in KB - the name and the size
#   Get-CimInstance Win32_Process ParentProcessId, CommandLine, ExecutablePath,
#                                 CreationDate, kernel/user 100ns time and the
#                                 working set
#
# wmic is deliberately not used: it is removed from recent Windows 11 builds.
# Commands run through open($fh, '-|', @argv), list form, so no shell parses an
# argument. A missing or refusing command answers ''; every public sub then
# returns the same empty answer it already returns on a failed /proc read.
#
# Units are chosen so the existing consumers need no change:
#   rss         = WorkingSetSize / 4096, in pages, because monitor.js does
#                 r * 4 for KiB (tasklist's KB is the fallback)
#   utime/stime = the 100ns counters / 100,000, i.e. 100 Hz ticks like Linux
#   start       = (CreationDate - LastBootUpTime) in 0.01s, i.e. 100 Hz ticks
#                 since boot, because manager_misc.pm computes the age as
#                 uptime - start/100
#   state       = 'R' for a row in the snapshot; Windows has no zombie to
#                 report, and callers only special-case Z/X
#   pgrp        = 0; Windows has no process groups and descendants() is []

my $PS = 'powershell.exe';

# Emit UTC, culture-free timestamps and UTF-8, so a non-ASCII command line and
# a fixed date format survive both the pipe and the locale.
my $CIM_PROCESS = q<[Console]::OutputEncoding=[Text.Encoding]::UTF8; >
	. q<Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId,CommandLine,ExecutablePath,>
	. q<@{Name='CreationDate';Expression={if ($_.CreationDate) { $_.CreationDate.ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff') } else { '' }}},>
	. q<KernelModeTime,UserModeTime,WorkingSetSize | ConvertTo-Csv -NoTypeInformation>;

my $CIM_OS = q<[Console]::OutputEncoding=[Text.Encoding]::UTF8; >
	. q<Get-CimInstance Win32_OperatingSystem | Select-Object >
	. q<@{Name='LastBootUpTime';Expression={if ($_.LastBootUpTime) { $_.LastBootUpTime.ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff') } else { '' }}},>
	. q<TotalVisibleMemorySize,FreePhysicalMemory | ConvertTo-Csv -NoTypeInformation>;

my $CIM_CPU = q<[Console]::OutputEncoding=[Text.Encoding]::UTF8; >
	. q<Get-CimInstance Win32_PerfRawData_PerfOS_Processor | >
	. q<Select-Object Name,Timestamp_Sys100NS,PercentIdleTime | ConvertTo-Csv -NoTypeInformation>;

# A Windows command's stdout as text, or '' when it cannot run. The list form
# hands the argument vector to CreateProcess as-is.
sub _capture {
	my (@argv) = @_;
	return '' unless @argv;
	if ($RUN) {
		my $text = eval { $RUN->(@argv) };
		return defined $text ? $text : '';
	}
	open(my $fh, '-|', @argv) or return '';
	# The PowerShell commands set their console encoding to UTF-8; tasklist
	# writes the OEM codepage, so it is left as bytes rather than decoded as
	# something it is not.
	binmode($fh, ':encoding(UTF-8)') if $^O eq 'MSWin32' && $argv[0] eq $PS;
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

# CSV rows as arrays of fields: enough of RFC 4180 for ConvertTo-Csv and
# tasklist. Every field may be quoted, a quote inside one is doubled, and a
# quoted field may hold commas and newlines.
sub _csv_rows {
	my ($text) = @_;
	my @rows;
	return \@rows unless defined $text && length $text;
	$text =~ s/^\x{FEFF}//;   # a UTF-8 BOM from a redirected pipe
	my @field;
	my $field = '';
	my $quoted = 0;
	my $len = length $text;
	for (my $i = 0; $i < $len; $i++) {
		my $ch = substr($text, $i, 1);
		if ($quoted) {
			if ($ch eq '"') {
				if (substr($text, $i + 1, 1) eq '"') { $field .= '"'; $i++ }
				else { $quoted = 0 }
			}
			else { $field .= $ch }
			next;
		}
		if ($ch eq '"') { $quoted = 1 }
		elsif ($ch eq ',') { push @field, $field; $field = '' }
		elsif ($ch eq "\r") { }   # ConvertTo-Csv ends its lines CRLF
		elsif ($ch eq "\n") {
			push @field, $field;
			push @rows, [@field];
			@field = ();
			$field = '';
		}
		else { $field .= $ch }
	}
	push @field, $field if length $field || @field;
	push @rows, [@field] if @field;
	return \@rows;
}

# The digits in a Windows number string, as a number, or undef. tasklist writes
# '123,456 K' and CIM writes a bare integer; a missing value is 'N/A' or ''.
sub _digits {
	my ($value) = @_;
	return undef unless defined $value;
	my $digits = $value;
	$digits =~ s/[^0-9]//g;
	return undef unless length $digits;
	return $digits + 0;
}

# The last component of a Windows path, for an image name CIM knows but
# tasklist did not list.
sub _basename {
	my ($path) = @_;
	return '' unless defined $path && length $path;
	$path =~ s{.*[\\/]}{};
	return $path;
}

# One CSV field by column name, '' when the column is absent or the field
# empty.
sub _field {
	my ($row, $at, $name) = @_;
	return '' unless exists $at->{$name};
	my $value = $row->[ $at->{$name} ];
	return defined $value ? $value : '';
}

# A CIM timestamp as UTC epoch seconds, fraction included, or undef. The
# PowerShell above formats CreationDate and LastBootUpTime as
# ToUniversalTime().ToString('yyyyMMddHHmmss.ffffff'), so both sides are UTC
# and the machine's date order never enters.
sub cim_epoch {
	my ($stamp) = @_;
	return undef unless defined $stamp;
	return undef unless $stamp =~ /^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})(?:\.([0-9]+))?$/;
	my ($year, $mon, $day, $hour, $min, $sec, $frac) = ($1, $2, $3, $4, $5, $6, $7);
	require Time::Local;
	my $epoch = eval { Time::Local::timegm($sec, $min, $hour, $day, $mon - 1, $year) };
	return undef unless defined $epoch;
	$epoch += "0.$frac" if defined $frac && length $frac;
	return $epoch;
}

# tasklist /FO CSV /NH, keyed by pid: comm is the Image Name, mem_kib the Mem
# Usage with its thousands separator removed. A row that is not five CSV
# fields is an INFO line, not a process.
sub parse_tasklist {
	my ($text) = @_;
	my %by;
	foreach my $row ( @{ _csv_rows($text) } ) {
		next unless @{$row} >= 5;
		my ($image, $pid, $session, $session_no, $mem) = @{$row};
		next unless _is_pid($pid);
		$by{$pid} = {
			comm       => $image,
			session    => $session,
			session_no => $session_no,
			mem_kib    => _digits($mem),
		};
	}
	return \%by;
}

# Get-CimInstance Win32_Process CSV, keyed by pid. Counters stay in their raw
# 100ns units here; windows_rows() converts them once, for every consumer.
sub parse_cim {
	my ($text) = @_;
	my $rows = _csv_rows($text);
	my $header = shift @{$rows};
	return {} unless $header && @{$header};
	my %at;
	$at{ lc $header->[$_] } = $_ for 0 .. $#{$header};
	return {} unless exists $at{'processid'};
	my %by;
	foreach my $row (@{$rows}) {
		my $pid = $row->[ $at{'processid'} ];
		next unless _is_pid($pid);
		my $ppid = exists $at{'parentprocessid'} ? $row->[ $at{'parentprocessid'} ] : undef;
		$by{$pid} = {
			ppid    => (defined $ppid && $ppid =~ /^[0-9]+$/) ? $ppid + 0 : undef,
			cmdline => _field($row, \%at, 'commandline'),
			exe     => _field($row, \%at, 'executablepath'),
			created => _field($row, \%at, 'creationdate'),
			kernel  => _digits(_field($row, \%at, 'kernelmodetime')),
			user    => _digits(_field($row, \%at, 'usermodetime')),
			ws      => _digits(_field($row, \%at, 'workingsetsize')),
		};
	}
	return \%by;
}

# Win32_OperatingSystem CSV: boot time, and the two memory numbers in KiB
# (TotalVisibleMemorySize and FreePhysicalMemory are already KiB).
sub parse_windows_os {
	my %info = (boot => undef, total => 0, available => 0);
	my $rows = _csv_rows($_[0]);
	my $header = shift @{$rows};
	return \%info unless $header && @{$header};
	my %at;
	$at{ lc $header->[$_] } = $_ for 0 .. $#{$header};
	my $row = $rows->[0];
	return \%info unless $row;
	$info{'boot'} = cim_epoch(_field($row, \%at, 'lastbootuptime'));
	$info{'total'} = _digits(_field($row, \%at, 'totalvisiblememorysize')) || 0;
	$info{'available'} = _digits(_field($row, \%at, 'freephysicalmemory')) || 0;
	return \%info;
}

# Win32_PerfRawData_PerfOS_Processor CSV as [{t => Timestamp_Sys100NS,
# i => PercentIdleTime}, ...], one entry per core in Name order. _Total is
# skipped: monitor.js diffs the cores and computes 1 - di/dt itself.
sub parse_windows_cpu {
	my $rows = _csv_rows($_[0]);
	my $header = shift @{$rows};
	my @cpus;
	return \@cpus unless $header && @{$header};
	my %at;
	$at{ lc $header->[$_] } = $_ for 0 .. $#{$header};
	return \@cpus unless exists $at{'name'}
		&& exists $at{'timestamp_sys100ns'} && exists $at{'percentidletime'};
	my @found;
	foreach my $row (@{$rows}) {
		my $name = $row->[ $at{'name'} ];
		next unless defined $name && $name =~ /^[0-9]+$/;   # skips _Total
		my $t = _digits($row->[ $at{'timestamp_sys100ns'} ]);
		my $i = _digits($row->[ $at{'percentidletime'} ]);
		next unless defined $t && defined $i;
		push @found, [ $name + 0, $t, $i ];
	}
	@found = sort { $a->[0] <=> $b->[0] } @found;
	push @cpus, { t => $_->[1], i => $_->[2] } for @found;
	return \@cpus;
}

# The merge of the two sources into Linux-shaped rows. $boot is the epoch from
# windows_os(); without it start is '' (unknown), never a guess.
sub windows_rows {
	my ($tasklist_text, $cim_text, $boot) = @_;
	my $tl = parse_tasklist($tasklist_text);
	my $cim = parse_cim($cim_text);
	my %pids;
	$pids{$_} = 1 for keys %{$tl}, keys %{$cim};
	my @rows;
	foreach my $pid (sort { $a <=> $b } keys %pids) {
		my $t = $tl->{$pid} || {};
		my $c = $cim->{$pid} || {};
		my $comm = (defined $t->{'comm'} && length $t->{'comm'}) ? $t->{'comm'} : _basename($c->{'exe'});
		my $exe = (defined $c->{'exe'} && length $c->{'exe'}) ? $c->{'exe'} : $comm;
		my $rss = 0;
		if (defined $c->{'ws'} && $c->{'ws'} > 0) { $rss = int($c->{'ws'} / 4096) }
		elsif (defined $t->{'mem_kib'}) { $rss = int($t->{'mem_kib'} / 4) }
		my $start = '';
		if (defined $boot) {
			my $created = cim_epoch($c->{'created'});
			if (defined $created) {
				$start = int(($created - $boot) * 100 + 0.5);
				$start = 0 if $start < 0;   # clock skew between the two queries
			}
		}
		push @rows, {
			pid     => "$pid",
			ppid    => defined $c->{'ppid'} ? $c->{'ppid'} : 0,
			pgrp    => 0,
			state   => 'R',
			start   => $start,
			utime   => defined $c->{'user'} ? int($c->{'user'} / 100000) : 0,
			stime   => defined $c->{'kernel'} ? int($c->{'kernel'} / 100000) : 0,
			rss     => $rss,
			comm    => defined $comm ? $comm : '',
			cmdline => defined $c->{'cmdline'} ? $c->{'cmdline'} : '',
			cwd     => '',
			exe     => defined $exe ? $exe : '',
		};
	}
	return \@rows;
}

# The cached snapshot every Windows field read shares. The cache is what keeps
# a Monitor poll to one tasklist and one CIM call rather than one per pid.
# `force => 1` replaces the cache even inside the TTL; only the liveness test
# asks for that, because a child started after the snapshot was taken is not in
# it yet. The field readers (comm, state, start_time, ...) never force: they
# describe a pid the snapshot already has.
sub windows_snapshot {
	my (%opt) = @_;
	my $now = time;
	my $cached = $CACHE{'snapshot'};
	return $cached->{'rows'}
		if !$opt{'force'} && $cached && ($now - $cached->{'at'}) < $CACHE_TTL;
	my $tasklist = _capture('tasklist', '/FO', 'CSV', '/NH');
	my $cim = _capture($PS, '-NoProfile', '-NonInteractive', '-Command', $CIM_PROCESS);
	my $os = windows_os();
	my $rows = windows_rows($tasklist, $cim, $os->{'boot'});
	$CACHE{'snapshot'} = { at => $now, rows => $rows };
	return $rows;
}

# The operating-system snapshot: boot time, total and available memory. It is
# cached as well, so uptime() and meminfo() in one poll share a query.
sub windows_os {
	my $now = time;
	my $cached = $CACHE{'os'};
	return $cached->{'info'} if $cached && ($now - $cached->{'at'}) < $CACHE_TTL;
	my $text = _capture($PS, '-NoProfile', '-NonInteractive', '-Command', $CIM_OS);
	my $info = parse_windows_os($text);
	$CACHE{'os'} = { at => $now, info => $info };
	return $info;
}

sub _windows_table {
	my (%opt) = @_;
	my @rows;
	foreach my $row ( @{ windows_snapshot() } ) {
		push @rows, {
			%{$row},
			cwd => '',
			exe => $opt{'exe'} ? $row->{'exe'} : '',
		};
	}
	return \@rows;
}

sub _windows_meminfo {
	my $os = windows_os();
	return {
		total     => $os->{'total'} || 0,
		available => $os->{'available'} || 0,
	};
}

sub _windows_uptime {
	my $os = windows_os();
	return undef unless defined $os->{'boot'};
	my $seconds = int(time() - $os->{'boot'});
	return $seconds < 0 ? 0 : $seconds;
}

sub _windows_cpu_times {
	my $text = _capture($PS, '-NoProfile', '-NonInteractive', '-Command', $CIM_CPU);
	return parse_windows_cpu($text);
}

# TerminateProcess through taskkill /F. Windows has no signals, so TERM and
# KILL are the same request: the process is ended, not asked. Returns 1 only
# when taskkill reports success. pid < 8 is refused because those are System,
# the registry-critical pids and the idle process: stopping them is a machine
# stop.
sub windows_signal {
	my ($target) = @_;
	return 0 unless _is_pid($target);
	return 0 if $target < 8;
	my $pid = open(my $fh, '-|', 'taskkill', '/PID', $target, '/F');
	return 0 unless defined $pid;
	local $/;
	<$fh>;   # drain its message; the exit status is the answer
	close $fh;
	return ($? == 0) ? 1 : 0;
}

# The Windows liveness test. A pid the cached snapshot does not have is looked
# for once more in a freshly read snapshot, then answered from that one: a
# child started after the last snapshot exists even though the cache has not
# seen it yet, which is what the supervisor loops and the just-spawned-child
# check in Domain/Process.pm need. A pid that is present keeps the cached
# answer, so a Monitor poll stays one query. Exactly one refresh per call.
sub windows_pid_exists {
	my ($pid) = @_;
	return 0 unless _is_pid($pid);
	return 1 if _win_row($pid);
	windows_snapshot(force => 1);
	return _win_row($pid) ? 1 : 0;
}

# The cached snapshot row for a pid, or undef.
sub _win_row {
	my ($pid) = @_;
	return undef unless _is_pid($pid);
	my $wanted = $pid + 0;
	foreach my $row ( @{ windows_snapshot() } ) {
		return $row if $row->{'pid'} == $wanted;
	}
	return undef;
}

sub _win_field {
	my ($pid, $field) = @_;
	my $row = _win_row($pid);
	return '' unless $row;
	my $value = $row->{$field};
	return defined $value ? $value : '';
}

# Drop the cached snapshot and OS reads. Tests use it so a fixture is not
# answered by an earlier live read; nothing in a running house calls it.
sub reset_cache {
	%CACHE = ();
	return 1;
}

1;
