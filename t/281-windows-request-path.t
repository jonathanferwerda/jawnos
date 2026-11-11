# tests-for: lib/JawnOS/Platform/Process.pm
# tests-for: lib/JawnOS/Manager/Part35.pm
# tests-for: lib/JawnOS/Domain/Misc.pm
# tests-for: lib/JawnOS/Platform/Net.pm
# covers:    the Windows request path starts no process. On Windows 11 a
#            tasklist + Get-CimInstance snapshot costs ~3.8 s and the
#            PowerShell/comd probes cost another second, so /manager/health
#            timed out and the master's watchdog restarted a healthy tree.
#            The health read now takes the process count from the snapshot the
#            worker already holds (`cached => 1`, bounded staleness), the
#            uptime from GetTickCount64, and the hostname from the memoised
#            platform seam; the Leave menu's power probes answer empty on
#            Windows instead of running `command -v` three times per render.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

use JawnOS::Platform::Process qw(windows_snapshot reset_cache uptime);

my $root = repo_root();

# A slice of source from one marker to the next, so an assertion sees the sub
# it names and not the rest of the file.
sub between {
	my ($src, $open, $close) = @_;
	my $at = index($src, $open);
	return '' if $at < 0;
	my $end = index($src, $close, $at + length $open);
	return $end < 0 ? substr($src, $at) : substr($src, $at, $end - $at);
}

my $tasklist = <<'CSV';
"present.exe","1234","Console","1","1,000 K"
CSV
my $cim = <<'CSV';
"ProcessId","ParentProcessId","CommandLine","ExecutablePath","CreationDate","KernelModeTime","UserModeTime","WorkingSetSize"
"1234","1","perl President.pl","C:\perl.exe","20261110093045.500000","12345678","2345678","104857600"
CSV
my $os = <<'CSV';
"LastBootUpTime","TotalVisibleMemorySize","FreePhysicalMemory"
"20261110090000.000000","8000000","4000000"
CSV

# ---------------------------------------------------------- the cached read
# A request (health, a page render) must answer from what the worker already
# read. A cold cache is empty, not an invitation to start tasklist.
{
	my @spawned;
	local $JawnOS::Platform::Process::RUN = sub { push @spawned, [@_]; return '' };
	reset_cache();
	is_deeply(windows_snapshot(cached => 1), [], 'a cold cache answers an empty list');
	is(scalar @spawned, 0, 'and starts no process to fill it');
}

# A polling read (the process monitor, the reaper) warms the snapshot; the
# request-path read then reuses it inside the TTL with no command at all.
{
	my $calls = 0;
	local $JawnOS::Platform::Process::RUN = sub {
		my ($command, @args) = @_;
		$calls++;
		return $tasklist if lc($command) eq 'tasklist';
		return $os if grep { /Win32_OperatingSystem/ } @args;
		return $cim;
	};
	local $JawnOS::Platform::Process::NOW = 1_700_000_000;
	reset_cache();
	my $warm = windows_snapshot();
	is($calls, 3, 'a polling read takes tasklist, CIM and the OS query once');
	is(scalar @{$warm}, 1, 'and parses the snapshot');

	$calls = 0;
	my $cached = windows_snapshot(cached => 1);
	is($calls, 0, 'a request-path read starts no process');
	is_deeply($cached, $warm, 'and answers the snapshot already in hand');
}

# The bound keeps a request from showing an hour-old process list forever.
{
	my $calls = 0;
	local $JawnOS::Platform::Process::RUN = sub {
		my ($command, @args) = @_;
		$calls++;
		return $tasklist if lc($command) eq 'tasklist';
		return $os if grep { /Win32_OperatingSystem/ } @args;
		return $cim;
	};
	local $JawnOS::Platform::Process::NOW = 1_700_000_000;
	reset_cache();
	windows_snapshot();
	$JawnOS::Platform::Process::NOW += $JawnOS::Platform::Process::CACHED_MAX_AGE + 1;
	$calls = 0;
	is_deeply(windows_snapshot(cached => 1), [],
		'a snapshot older than the cached bound is not frozen');
	is($calls, 0, 'and the stale read still starts no process');
}

# The Windows uptime reader is inert off Windows; on Windows it is a kernel
# read, so a request never falls back to the CIM OS query.
is(JawnOS::Platform::Process::_win_tick_uptime(), undef,
	'the GetTickCount64 reader is inert on this platform');
SKIP: {
	skip 'the /proc uptime read is Unix-only', 1 if $^O eq 'MSWin32';
	my $cached = uptime(cached => 1);
	my $plain  = uptime();
	ok(defined $cached && defined $plain && abs($cached - $plain) <= 1,
		'cached => 1 does not change the Unix uptime answer');
}

# ---------------------------------------------------------- health_report
my $part35 = read_file("$root/lib/JawnOS/Manager/Part35.pm");
my $report = between($part35, 'sub health_report {', 'sub health_allowed {');
ok(length $report, 'health_report is found');
unlike($report, qr/`/, 'health_report starts no shell command');
like($report, qr/&subs::machine_hostname\(\)/,
	'the hostname is the memoised in-process read');
like($report, qr/uptime\(cached => 1\)/,
	'the uptime read is the cached, process-free one on Windows');

my $count = between($part35, 'sub health_process_count {', 'sub health_report {');
ok(length $count, 'health_process_count is found');
like($count, qr/table\(cached => 1\)/,
	'the request-side process count reads the cached snapshot');
like($count, qr/\$windows/, 'and names the Windows branch explicitly');
like($count, qr/\$row->\{'cmdline'\}/,
	'the Windows branch identifies this tree by command line');

# ---------------------------------------------------------- the Leave menu
# power_actions runs from the start-menu include on every manager render.
my $misc = read_file("$root/lib/JawnOS/Domain/Misc.pm");
my $power = between($misc, 'sub power_actions() {', '# The session logind can end');
ok(length $power, 'power_actions is found');
like($power, qr/\^O eq 'MSWin32'/, 'power_actions names the Windows answer');
like($power, qr/return \@actions;/, 'and returns before probing');
my $win_at   = index($power, "MSWin32");
my $probe_at = index($power, 'my $systemctl =');
ok($win_at >= 0 && $probe_at > $win_at,
	'the Windows return comes before the first shell probe');

# ---------------------------------------------------------- the hostname
my $net  = read_file("$root/lib/JawnOS/Platform/Net.pm");
my $host = between($net, 'sub hostname {', 'sub parse_ifconfig {');
ok(length $host, 'hostname is found');
like($host, qr/COMPUTERNAME/, 'the Windows name comes from the environment');
like($host, qr/Win32::GetComputerName/, 'with a Win32 fallback');
my $fallback_at = index($host, 'require POSIX');
my $windows = substr($host, index($host, "MSWin32"), $fallback_at - index($host, "MSWin32"));
ok(length $windows && $windows =~ /return \$hostname_memo;/,
	'the Windows branch returns before the Sys::Hostname fallback runs');
unlike($windows, qr/Sys::Hostname/, 'and never reaches Sys::Hostname');

done_testing();
