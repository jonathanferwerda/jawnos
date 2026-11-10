# tests-for: lib/JawnOS/Platform/Process.pm
# tests-for: jawn scripts/manager_killer.pl
# tests-for: lib/JawnOS/Manager/Part06.pm lib/JawnOS/Manager/Part35.pm
# tests-for: lib/JawnOS/Controller/manager_misc.pm
# tests-for: lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Ai.pm
# tests-for: lib/JawnOS/Domain/Pay2.pm lib/JawnOS/Domain/Coding.pm
# tests-for: perl/hooks.pl
# covers:    the process identity/state seam: /proc stat parsing when "(comm)"
#            holds spaces and parens, exists vs. running (a zombie), the
#            pid-reuse start token, the command line and environment, the
#            parent/group/cwd/exe reads, RSS, the one-pass table, the ppid
#            closure and kill-tree, the machine memory/uptime/load/CPU reads,
#            the safe empty answers a platform without /proc gives, the Windows
#            backend's tasklist/CIM/OS/CPU parsers and their units (pages,
#            100 Hz ticks, ticks since boot), its ppid closure, the cached
#            snapshot, and that the request-side call sites, the master's stop
#            sweep and the manager killer no longer open /proc themselves.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use POSIX ();
use Cwd ();
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);
use JawnOS::Platform::Process qw(
	parse_stat state running pid_exists same_process start_time
	command_line cpu_ticks descendants signal
	comm ppid pgrp cwd exe environ rss_kib
	table tree kill_tree ppid_closure
	meminfo uptime loadavg cpu_times
	parse_tasklist parse_cim parse_windows_os parse_windows_cpu
	cim_epoch windows_rows windows_snapshot windows_os windows_signal
	windows_pid_exists reset_cache
);

my $linux = ($^O eq 'linux') ? 1 : 0;

# ------------------------------------------------------------ the stat parser
# The fields begin after the last ')' because "(comm)" may itself hold spaces
# and parentheses. Index 19 is field 22 (start time), 11/12 are utime/stime,
# 21 is field 24 (rss, in pages).
my $line = "4242 (a (b) c) S 1 4242 4242 0 -1 4194560 100 0 0 0 12 34 0 0 20 0 1 0 98765 123456 789 0 0\n";
my $stat = parse_stat($line);
is(ref $stat, 'HASH', 'a stat line parses to a hash');
is($stat->{'comm'}, 'a (b) c', 'comm survives its own parens and spaces');
is($stat->{'state'}, 'S', 'state is the first field after the comm');
is($stat->{'ppid'}, 1, 'ppid is field 4');
is($stat->{'pgrp'}, 4242, 'pgrp is field 5');
is($stat->{'utime'}, 12, 'utime is field 14');
is($stat->{'stime'}, 34, 'stime is field 15');
is($stat->{'start'}, 98765, 'start time is field 22');
is($stat->{'rss'}, 789, 'rss is field 24, in pages');

is(parse_stat(undef), undef, 'no line parses to undef');
is(parse_stat("4242 no-comm-here\n"), undef, 'a line with no closing paren is not a stat line');

# ------------------------------------------------------------ this process
ok(pid_exists($$), 'the test process exists');
ok(running($$), 'the test process is running');
ok(!pid_exists(undef), 'an undef pid does not exist');
ok(!pid_exists('not-a-pid'), 'a non-numeric pid does not exist');
ok(!running('not-a-pid'), 'a non-numeric pid is not running');
is(state(undef), '', 'an unreadable state is empty, not an exception');
is(start_time(undef), '', 'an unreadable start token is empty');
is(command_line(undef), '', 'an unreadable command line is empty');
is(cpu_ticks(undef), undef, 'unreadable ticks are undef');
is_deeply(descendants(undef, undef), [], 'no pid and no group finds nothing');
is(comm(undef), '', 'an unreadable comm is empty');
is(ppid(undef), '', 'an unreadable ppid is empty');
is(pgrp(undef), '', 'an unreadable pgrp is empty');
is(cwd(undef), '', 'an unreadable cwd is empty');
is(exe(undef), '', 'an unreadable exe is empty');
is(environ(undef), '', 'an unreadable environment is empty');
is(rss_kib(undef), undef, 'an unreadable RSS is undef');

if ($linux) {
	my $start = start_time($$);
	like($start, qr/^[0-9]+$/, 'a live process has a numeric start token');
	is(start_time($$), $start, 'the start token is stable across reads');
	ok(same_process($$, $start), 'the same process with its own token is alive');
	ok(!same_process($$, 'not-the-token'), 'a recycled pid is not the same process');
	like(command_line($$), qr/227-platform-process/, 'the command line is space-joined and readable');
	unlike(command_line($$), qr/\0/, 'the command line has no NUL bytes left');
	ok(defined cpu_ticks($$), 'a live process reports CPU ticks');
	cmp_ok(cpu_ticks($$), '>=', 0, 'CPU ticks are not negative');
	ok(length comm($$), 'a live process has a name');
	like(ppid($$), qr/^[0-9]+$/, 'a live process has a numeric ppid');
	like(pgrp($$), qr/^[0-9]+$/, 'a live process has a numeric process group');
	is(cwd($$), Cwd::getcwd(), 'the live cwd is this checkout');
	like(exe($$), qr/perl/i, 'the live executable is perl');
	ok(defined rss_kib($$) && rss_kib($$) > 0, 'the live process reports RSS in KiB');
}
else {
	is(start_time($$), '', 'a platform without /proc has no start token');
	is(command_line($$), '', 'a platform without /proc has no command line');
	is(cpu_ticks($$), undef, 'a platform without /proc has no CPU ticks');
	is(comm($$), '', 'a platform without /proc has no process name');
	is(ppid($$), '', 'a platform without /proc has no ppid');
	is(pgrp($$), '', 'a platform without /proc has no process group');
	is(cwd($$), '', 'a platform without /proc has no cwd');
	is(exe($$), '', 'a platform without /proc has no executable');
	is(environ($$), '', 'a platform without /proc has no environment');
	is(rss_kib($$), undef, 'a platform without /proc has no RSS');
}

SKIP: {
	skip 'MSWin32 has no POSIX kill', 2 if $^O eq 'MSWin32';
	is(signal(0, $$), 1, 'a zero signal reaches a live pid');
	is(signal(undef, $$), 0, 'no signal is a refusal, not a kill');
}

# ------------------------------------------------------------ a zombie
# kill(0) still sees a child that has exited and not been reaped; running() must
# not. That distinction is why the guard and the reaper ask different questions.
SKIP: {
	skip 'needs /proc to read a zombie state', 4 unless $linux;
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	POSIX::_exit(0) if !$pid;
	for (1 .. 200) {
		last if state($pid) eq 'Z';
		sleep 0.01;
	}
	is(state($pid), 'Z', 'a child that exited is a zombie until it is reaped');
	ok(pid_exists($pid), 'kill 0 still sees the zombie');
	ok(!running($pid), 'running is false for a zombie');
	ok(!same_process($pid, start_time($pid)), 'a zombie is not a live process');
	waitpid($pid, 0);
}

# ------------------------------------------------------------ a reaped pid
SKIP: {
	skip 'needs fork', 3 if $^O eq 'MSWin32';
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	POSIX::_exit(0) if !$pid;
	waitpid($pid, 0);
	is(start_time($pid), '', 'a reaped pid has no start token');
	ok(!pid_exists($pid), 'a reaped pid does not exist');
	ok(!running($pid), 'a reaped pid is not running');
}

# ------------------------------------------------------------ the group scan
# The wrapper is its own group leader and its grandchild inherits the group;
# the reaper extends the wrapper for as long as that grandchild lives.
SKIP: {
	skip 'needs /proc and setpgrp', 2 unless $linux;
	pipe(my $rd, my $wr) or die "pipe: $!";
	my $child = fork();
	die "fork: $!" unless defined $child;
	if (!$child) {
		close $rd;
		setpgrp(0, 0) or POSIX::_exit(3);
		my $grand = fork();
		if (!defined $grand) {
			close $wr;
			POSIX::_exit(4);
		}
		if (!$grand) {
			sleep 30;
			POSIX::_exit(0);
		}
		print {$wr} "$grand\n";
		close $wr;
		sleep 30;
		POSIX::_exit(0);
	}
	close $wr;
	my $grand = <$rd>;
	close $rd;
	chomp $grand if defined $grand;
	ok(defined $grand && $grand =~ /^[0-9]+$/ && $grand > 0,
		'the child reports the grandchild in its process group');
	my $found = descendants($child, $child);
	ok(ref $found eq 'ARRAY' && grep({ $_ == ($grand || 0) } @{$found}),
		'the group scan finds the grandchild and skips the group leader');
	kill 'KILL', -$child;
	for (1 .. 100) {
		last if waitpid($child, POSIX::WNOHANG()) == $child;
		sleep 0.01;
	}
	kill 'KILL', $child;
}

# ------------------------------------------------------------ fixtures
# The live table cannot be shaped into a fixture, so $PROC_ROOT is pointed at a
# temp tree. Every read the module makes goes through it, which is also what
# proves the safe-empty answers.
sub write_bytes {
	my ($path, $bytes) = @_;
	open(my $fh, '>', $path) or die "write $path: $!";
	print {$fh} $bytes;
	close $fh;
}

# Fields after "(comm)": state ppid pgrp session tty tpgid flags minflt cminflt
# majflt cmajflt utime stime ... starttime vsize rss. The zeros in between are
# what put utime at index 11 and start at index 19.
sub fixture_stat {
	my ($pid, %o) = @_;
	my $comm  = defined $o{'comm'}  ? $o{'comm'}  : "proc$pid";
	my $state = defined $o{'state'} ? $o{'state'} : 'S';
	my $ppid  = defined $o{'ppid'}  ? $o{'ppid'}  : 1;
	my $pgrp  = defined $o{'pgrp'}  ? $o{'pgrp'}  : $pid;
	my $utime = defined $o{'utime'} ? $o{'utime'} : 11;
	my $stime = defined $o{'stime'} ? $o{'stime'} : 22;
	my $start = defined $o{'start'} ? $o{'start'} : 777;
	my $rss   = defined $o{'rss'}   ? $o{'rss'}   : 99;
	return "$pid ($comm) $state $ppid $pgrp 0 -1 0 0 0 0 0 0 $utime $stime 0 0 20 0 1 0 $start 1000 $rss 0 0\n";
}

sub fixture_proc {
	my ($root, $pid, %o) = @_;
	my $dir = "$root/$pid";
	make_path($dir);
	write_bytes("$dir/stat", fixture_stat($pid, %o));
	write_bytes("$dir/cmdline", $o{'cmdline'}) if defined $o{'cmdline'};
	write_bytes("$dir/environ", $o{'environ'}) if defined $o{'environ'};
	write_bytes("$dir/status", $o{'status'}) if defined $o{'status'};
	symlink($o{'cwd'}, "$dir/cwd") if defined $o{'cwd'};
	symlink($o{'exe'}, "$dir/exe") if defined $o{'exe'};
	return $dir;
}

my $fake = tempdir(CLEANUP => 1);
fixture_proc($fake, 1234,
	comm    => 'worker (one)',
	ppid    => 1,
	pgrp    => 1234,
	utime   => 12,
	stime   => 34,
	start   => 98765,
	rss     => 4321,
	cmdline => "alpha\0--flag\0",
	environ => "FOO=bar\0BAZ=qux\0",
	status  => "Name:\tworker\nVmRSS:\t 4242 kB\n",
	cwd     => '/srv/fixture',
	exe     => '/usr/bin/fixture',
);
fixture_proc($fake, 1240, ppid => 1234, cmdline => "child\0");
fixture_proc($fake, 1241, ppid => 1240, cmdline => "grand\0");
fixture_proc($fake, 1242, ppid => 1, cmdline => "other\0");
make_path("$fake/1300");   # a pid directory with no stat: skipped, not guessed
write_bytes("$fake/meminfo", "MemTotal:       8000000 kB\nMemAvailable:   4000000 kB\n");
write_bytes("$fake/uptime", "12345.67 999.00\n");
write_bytes("$fake/loadavg", "0.10 0.20 0.30 1/100 999\n");
write_bytes("$fake/stat",
	"cpu  1 2 3 4 5 6 7 8 9 10\n"
	. "cpu0 10 20 30 40 50 60 70 80\n"
	. "cpu1 1 2 3 4 5 6 7 8\n");

{
	local $JawnOS::Platform::Process::PROC_ROOT = $fake;

	is(comm(1234), 'worker (one)', 'comm comes from stat, parens included');
	is(ppid(1234), 1, 'ppid comes from stat');
	is(pgrp(1234), 1234, 'pgrp comes from stat');
	is(cwd(1234), '/srv/fixture', 'cwd follows the proc symlink');
	is(exe(1234), '/usr/bin/fixture', 'exe follows the proc symlink');
	is(environ(1234), 'FOO=bar BAZ=qux ', 'environ is space-joined');
	is(rss_kib(1234), 4242, 'rss_kib reads VmRSS from status');

	is(comm(9999), '', 'a pid with no stat has no comm');
	is(ppid(9999), '', 'a pid with no stat has no ppid');
	is(pgrp(9999), '', 'a pid with no stat has no pgrp');
	is(cwd(9999), '', 'a pid with no cwd symlink has an empty cwd');
	is(exe(9999), '', 'a pid with no exe symlink has an empty exe');
	is(environ(9999), '', 'a pid with no environ has an empty environment');
	is(rss_kib(9999), undef, 'a pid with no status has no RSS');

	my $rows = table();
	is(scalar @$rows, 4, 'the table skips a pid directory whose stat cannot be read');
	my ($row) = grep { $_->{'pid'} == 1234 } @$rows;
	ok($row, 'the fixture process is in the table');
	is($row->{'ppid'}, 1, 'the table carries ppid');
	is($row->{'pgrp'}, 1234, 'the table carries pgrp');
	is($row->{'state'}, 'S', 'the table carries state');
	is($row->{'start'}, 98765, 'the table carries the start token');
	is($row->{'utime'}, 12, 'the table carries utime');
	is($row->{'stime'}, 34, 'the table carries stime');
	is($row->{'rss'}, 4321, 'the table carries RSS in pages');
	is($row->{'comm'}, 'worker (one)', 'the table carries comm');
	is($row->{'cmdline'}, 'alpha --flag ', 'the table carries the command line');
	is($row->{'cwd'}, '', 'cwd is not read unless asked for');
	is($row->{'exe'}, '', 'exe is not read unless asked for');

	my ($full) = grep { $_->{'pid'} == 1234 } @{ table(cwd => 1, exe => 1) };
	is($full->{'cwd'}, '/srv/fixture', 'table(cwd => 1) reads cwd');
	is($full->{'exe'}, '/usr/bin/fixture', 'table(exe => 1) reads exe');

	is_deeply(tree(1234), [1240, 1241], 'tree is the ppid closure under the root');
	is_deeply(tree(1240), [1241], 'tree starts where it is asked');
	is_deeply(tree(1242), [], 'a leaf has no tree');
	is_deeply(tree(1), [], 'pid 1 is not treated as a machine stop');
	is_deeply(tree(undef), [], 'no pid has no tree');

	is_deeply(meminfo(), { total => 8000000, available => 4000000 },
		'meminfo reports KiB');
	is(uptime(), '12345.67', 'uptime reports seconds');
	is(loadavg(), '0.10 0.20 0.30', 'loadavg reports three values');
	is_deeply(cpu_times(),
		[ { t => 360, i => 90 }, { t => 36, i => 9 } ],
		'cpu_times skips the aggregate line and sums each core');

	is(kill_tree(1), 0, 'kill_tree refuses pid 1');
	is(kill_tree(undef), 0, 'kill_tree refuses a non-pid');
}

{
	local $JawnOS::Platform::Process::PROC_ROOT = "$fake/does-not-exist";
	is_deeply(table(), [], 'no proc root is an empty table');
	is_deeply(meminfo(), { total => 0, available => 0 }, 'no proc root has no memory numbers');
	is(uptime(), undef, 'no proc root has no uptime');
	is(loadavg(), '', 'no proc root has no load average');
	is_deeply(cpu_times(), [], 'no proc root has no CPU rows');
}

# ------------------------------------------------------------ the live tree
# kill_tree walks the real ppid graph: a child that forks a grandchild is one
# subtree, and both must be stopped.
SKIP: {
	skip 'needs /proc and fork', 4 unless $linux;
	pipe(my $rd, my $wr) or die "pipe: $!";
	my $child = fork();
	die "fork: $!" unless defined $child;
	if (!$child) {
		close $rd;
		my $grand = fork();
		if (!defined $grand) {
			close $wr;
			POSIX::_exit(4);
		}
		if (!$grand) {
			sleep 30;
			POSIX::_exit(0);
		}
		print {$wr} "$grand\n";
		close $wr;
		sleep 30;
		POSIX::_exit(0);
	}
	close $wr;
	my $grand = <$rd>;
	close $rd;
	chomp $grand if defined $grand;
	ok(defined $grand && $grand =~ /^[0-9]+$/, 'the child reports its own child');
	my $found = tree($child);
	ok(ref $found eq 'ARRAY' && grep({ $_ == ($grand || 0) } @{$found}),
		'the ppid closure finds the grandchild');
	is(kill_tree($child, 'KILL'), 2, 'kill_tree signals the child and the grandchild');
	waitpid($child, 0);
	my $deadline = time + 5;
	while (time < $deadline && running($grand)) {
		sleep 0.02;
	}
	ok(!running($grand), 'the grandchild is gone with the tree');
}

# ------------------------------------------------------------ the folded files
# The request-side readers must go through the platform seam, not reopen /proc.
# The regex looks for a quoted path, so the route name /manager/process_monitor
# in a comment is not a false positive.
my $repo = "$FindBin::Bin/..";
my @folded = qw(
	lib/JawnOS/Manager/Part06.pm
	lib/JawnOS/Manager/Part35.pm
	lib/JawnOS/Controller/manager_misc.pm
	lib/JawnOS/Domain/House.pm
	lib/JawnOS/Domain/Ai.pm
	lib/JawnOS/Domain/Pay2.pm
	lib/JawnOS/Domain/Coding.pm
	perl/hooks.pl
);
for my $rel (@folded) {
	open(my $fh, '<', "$repo/$rel") or die "read $rel: $!";
	my $src = do { local $/; <$fh> };
	close $fh;
	unlike($src, qr{['"]/proc['"/]}, "$rel reads processes through the platform module");
}

# The master and the killer read process state through the seam too. The
# quoted-path test above would also flag jawn's log-filter string
# ('cannot open /proc/net'), which is not a process read, so these look for the
# two shapes a process read actually takes.
my @process_folded = qw(jawn scripts/manager_killer.pl);
for my $rel (@process_folded) {
	open(my $fh, '<', "$repo/$rel") or die "read $rel: $!";
	my $src = do { local $/; <$fh> };
	close $fh;
	unlike($src, qr{opendir\([^)]*['"]/proc['"]}, "$rel does not scan /proc itself");
	unlike($src, qr{(?:open|readlink)\([^)]*['"]/proc/\$}, "$rel does not read /proc/<pid> itself");
	like($src, qr{JawnOS::Platform::Process::}, "$rel uses the platform process seam");
}

# ------------------------------------------------------------ the Windows backend
# The Windows commands cannot run here, so the parsers are fed the exact text
# tasklist and ConvertTo-Csv emit and are checked on Linux. These are pure
# readers: the $^O gate means they are reachable only through a Windows branch
# in a house, but the text they read is the same text on both boxes.

my $tasklist_text = <<'CSV';
"chrome.exe","1234","Console","1","123,456 K"
"a,b.exe","4321","Services","0","12,345 K"
"System","4","Services","0","144 K"
CSV

my $tl = parse_tasklist($tasklist_text);
is($tl->{1234}{'comm'}, 'chrome.exe', 'tasklist CSV: the image name is the comm');
is($tl->{1234}{'mem_kib'}, 123456, 'tasklist CSV: the thousands separator is removed');
is($tl->{4321}{'comm'}, 'a,b.exe', 'tasklist CSV: a comma inside a quoted name stays');
is($tl->{4}{'mem_kib'}, 144, 'tasklist CSV: a plain size is read');
is_deeply(parse_tasklist(''), {}, 'no tasklist text is no processes');

my $cim_text = <<'CSV';
"ProcessId","ParentProcessId","CommandLine","ExecutablePath","CreationDate","KernelModeTime","UserModeTime","WorkingSetSize"
"1234","1","""C:\Program Files\App\app.exe"" --flag,value ""a,b""","C:\Program Files\App\app.exe","20261110093045.500000","12345678","2345678","104857600"
CSV

my $cim = parse_cim($cim_text);
is($cim->{1234}{'ppid'}, 1, 'CIM CSV: the parent pid is a number');
is($cim->{1234}{'cmdline'}, '"C:\Program Files\App\app.exe" --flag,value "a,b"',
	'CIM CSV: a comma and a doubled quote survive the command line');
is($cim->{1234}{'exe'}, 'C:\Program Files\App\app.exe', 'CIM CSV: the executable path is read');
is($cim->{1234}{'ws'}, 104857600, 'CIM CSV: the working set is in bytes');
is_deeply(parse_cim(''), {}, 'no CIM text is no processes');

my $boot = cim_epoch('20261110090000.000000');
ok(defined $boot, 'a CIM timestamp parses to an epoch');
is(cim_epoch('not-a-stamp'), undef, 'a non-timestamp has no epoch');

my ($win) = grep { $_->{'pid'} eq '1234' } @{ windows_rows($tasklist_text, $cim_text, $boot) };
ok($win, 'the two Windows sources merge into one row');
is($win->{'pid'}, '1234', 'the Windows pid is a string, as the Monitor has always had it');
is($win->{'ppid'}, 1, 'the Windows ppid is a number');
is($win->{'comm'}, 'chrome.exe', 'the Windows comm is the tasklist image name');
is($win->{'cmdline'}, '"C:\Program Files\App\app.exe" --flag,value "a,b"',
	'the Windows row carries the command line');
is($win->{'exe'}, 'C:\Program Files\App\app.exe', 'the Windows row carries the executable');
is($win->{'state'}, 'R', 'a row in the snapshot is a live process');
is($win->{'pgrp'}, 0, 'Windows has no process group');
is($win->{'rss'}, 25600, 'WorkingSetSize/4096 is pages, so monitor.js r*4 is KiB');
is($win->{'utime'}, 23, 'UserModeTime 100ns units become 100 Hz ticks');
is($win->{'stime'}, 123, 'KernelModeTime 100ns units become 100 Hz ticks');
is($win->{'start'}, 184550, 'start is 100 Hz ticks since boot');

# tasklist alone still gives the name and a size; CIM adds the counters.
my $no_ws = <<'CSV';
"ProcessId","ParentProcessId","CommandLine","ExecutablePath","CreationDate","KernelModeTime","UserModeTime","WorkingSetSize"
"1234","1","chrome.exe","C:\Bin\chrome.exe","","0","0",""
CSV
my ($fallback) = grep { $_->{'pid'} eq '1234' } @{ windows_rows($tasklist_text, $no_ws, undef) };
is($fallback->{'rss'}, 30864, 'a missing working set falls back to tasklist KB / 4');
is($fallback->{'start'}, '', 'no boot time leaves the start token unknown, not guessed');
is($fallback->{'exe'}, 'C:\Bin\chrome.exe', 'CIM names the executable when the tasklist does not');

# The ppid closure is the same code tree() runs; a Windows fixture proves it.
my $tree_cim = <<'CSV';
"ProcessId","ParentProcessId","CommandLine","ExecutablePath","CreationDate","KernelModeTime","UserModeTime","WorkingSetSize"
"100","1","jawn","","","0","0","0"
"200","100","President.pl","","","0","0","0"
"300","200","Manager.pl","","","0","0","0"
"400","1","other","","","0","0","0"
CSV
my $tree_rows = windows_rows('', $tree_cim, undef);
is_deeply([ sort { $a <=> $b } @{ ppid_closure($tree_rows, 100) } ], [200, 300],
	'the Windows ppid closure finds the whole subtree from one snapshot');
is_deeply(ppid_closure($tree_rows, 1), [], 'pid 1 is not a Windows machine stop');

my $os_text = <<'CSV';
"LastBootUpTime","TotalVisibleMemorySize","FreePhysicalMemory"
"20261110090000.000000","8000000","4000000"
CSV
my $os = parse_windows_os($os_text);
is($os->{'boot'}, $boot, 'the OS query gives the boot epoch');
is($os->{'total'}, 8000000, 'TotalVisibleMemorySize is already KiB');
is($os->{'available'}, 4000000, 'FreePhysicalMemory is already KiB');
is_deeply(parse_windows_os(''), { boot => undef, total => 0, available => 0 },
	'an unavailable memory query is the zero answer');

my $cpu_text = <<'CSV';
"Name","Timestamp_Sys100NS","PercentIdleTime"
"0","133400000000000000","1200000000"
"1","133400000000000000","1300000000"
"_Total","133400000000000000","1250000000"
CSV
is_deeply(parse_windows_cpu($cpu_text),
	[ { t => 133400000000000000, i => 1200000000 },
	  { t => 133400000000000000, i => 1300000000 } ],
	'the CPU query skips _Total and keeps one entry per core');
is_deeply(parse_windows_cpu(''), [], 'no CPU text is no cores');

# Windows has no signals, so the refusal is the whole safe path here.
is(windows_signal(4), 0, 'windows_signal refuses System pid 4');
is(windows_signal(1), 0, 'windows_signal refuses pid 1');
is(windows_signal('not-a-pid'), 0, 'windows_signal refuses a non-numeric pid');

# The unavailable-command path and the cache, with the command hook.
{
	local $JawnOS::Platform::Process::RUN = sub { return '' };
	local $JawnOS::Platform::Process::CACHE_TTL = 0;
	reset_cache();
	is_deeply(windows_snapshot(), [], 'unavailable commands are an empty snapshot');
	is_deeply(windows_os(), { boot => undef, total => 0, available => 0 },
		'unavailable commands leave the OS answer at zero');
}
{
	my $calls = 0;
	local $JawnOS::Platform::Process::RUN = sub { $calls++; return '' };
	reset_cache();
	windows_snapshot();
	my $after_first = $calls;
	windows_snapshot();
	is($calls, $after_first, 'a second poll inside the TTL spawns nothing');
	reset_cache();
	windows_snapshot();
	cmp_ok($calls, '>', $after_first, 'reset_cache forces a fresh snapshot');
}
reset_cache();

# ------------------------------------------------------------ a pid that is new
# A supervisor checks a pid it has just spawned. A snapshot taken a moment
# earlier cannot have it, so pid_exists() refreshes once; a pid already in the
# snapshot must not cost another query.

my $live_tasklist = <<'CSV';
"present.exe","1234","Console","1","1,000 K"
CSV
my $live_cim = <<'CSV';
"ProcessId","ParentProcessId","CommandLine","ExecutablePath","CreationDate","KernelModeTime","UserModeTime","WorkingSetSize"
"1234","1","present.exe","C:\present.exe","","0","0",""
CSV
my $live_os = <<'CSV';
"LastBootUpTime","TotalVisibleMemorySize","FreePhysicalMemory"
"20261110090000.000000","8000000","4000000"
CSV

{
	my $calls = 0;
	local $JawnOS::Platform::Process::RUN = sub {
		my ($command, @args) = @_;
		$calls++;
		return $live_tasklist if lc($command) eq 'tasklist';
		return $live_os if grep { /Win32_OperatingSystem/ } @args;
		return $live_cim;
	};
	reset_cache();

	is(windows_pid_exists(1234), 1, 'a pid in the snapshot is alive');
	is($calls, 3, 'a present pid reads the snapshot once (tasklist, CIM, OS)');
	my $warm = $calls;
	is(windows_pid_exists(1234), 1, 'the cached pid is still alive');
	is($calls, $warm, 'a present pid does not refresh');

	$calls = 0;
	is(windows_pid_exists(9999), 0, 'a pid the snapshot and the refresh lack is dead');
	is($calls, 2, 'a missing pid refreshes exactly once (tasklist and CIM; the OS snapshot is still cached)');
}
reset_cache();

done_testing();
