# tests-for: jawn perl/Manager.pl perl/President.pl scripts/manager_killer.pl lib/JawnOS/Domain/Network.pm
# covers:    The killer used to shell out to pkill/pgrep four times per name, and a match was anything whose command line m...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use Time::HiRes qw(time sleep);
use POSIX qw(WNOHANG);
use RepoSource;

# The killer used to shell out to pkill/pgrep four times per name, and a match
# was anything whose command line mentioned the name. A real worker and an
# editor with Manager.pl open were the same thing to it. It now reads /proc
# once and signals exact pids whose executable is perl. This pins both: the
# selection, and the fact that decoys survive while the tree does not.

my $root = repo_root();
my $script = "$root/scripts/manager_killer.pl";
my $src = read_file($script);

# A child that has forked but not yet exec'd still wears this test's command
# line, and under a loaded parallel suite the exec can take a while. Waiting a
# fixed 0.5s made this file fail in the full run and pass alone; wait for the
# thing the scan actually reads instead.
sub wait_for_cmdline {
	my ($pid, $needle, $timeout) = @_;
	$timeout ||= 5;
	my $deadline = time + $timeout;
	while (time < $deadline) {
		if (open my $fh, '<', "/proc/$pid/cmdline") {
			local $/;
			my $cmd = <$fh>;
			close $fh;
			return 1 if defined $cmd && index($cmd, $needle) >= 0;
		}
		sleep 0.02;
	}
	return 0;
}

like($src, qr/sub scan_processes/, 'the killer scans /proc once');
unlike($src, qr/`\s*(?:pkill|pgrep)/, 'no pkill/pgrep in the code path');
like($src, qr/sub is_tree/, 'the tree is identified by executable and command line');
like($src, qr/--scope/, 'a scope keeps a test run away from the live tree');

# The scan itself no longer opens /proc: one table pass supplies the state, the
# command line, the executable and the cwd, and signals go through the same
# module. These shapes are how a process read appears; a comment that merely
# names /proc is not one.
unlike($src, qr{opendir\([^)]*['"]/proc['"]}, 'the killer does not scan /proc itself');
unlike($src, qr{(?:open|readlink)\([^)]*['"]/proc/\$}, 'the killer does not read /proc/<pid> itself');
unlike($src, qr{kill\s+0\s*,}, 'the killer does not test liveness with kill 0');
like($src, qr{JawnOS::Platform::Process::table\(cwd => 1, exe => 1\)}, 'one table pass carries cwd and exe');
like($src, qr{JawnOS::Platform::Process::signal}, 'signals go through the platform module');

# Windows has no getppid: the desktop's Stop/Restart runs this script, and the
# unguarded call there died before any signal was sent. Both callers now ask the
# platform seam, which is the real parent on POSIX and the runner's
# JAWNOS_PARENT_PID hint (or 0, "unknown") on Windows.
my $network_src = read_file("$root/lib/JawnOS/Domain/Network.pm");
for my $case (
	[ 'the killer' => $src ],
	[ 'Network.pm' => $network_src ],
) {
	my ($what, $text) = @$case;
	unlike($text, qr/\bgetppid\s*\(/, "$what never calls getppid");
	like($text, qr/JawnOS::Platform::parent_pid\(/, "$what asks the platform for its parent");
}
like($network_src, qr/JawnOS::Platform::fork_available\(/,
	'Network.pm does not enter the fork/exec supervisor without fork');

# The sweep names a process by its command line on every platform. Windows
# writes the interpreter as perl.exe and joins a path with a backslash, so a
# POSIX-only matcher finds nothing there and the Stop sweeps no straggler.
like($src, qr{\Q[\s/\\]\E}, 'the command-line match accepts a Windows backslash');
ok(index($src, 's/\.exe$//i') >= 0, 'a Windows perl.exe name is accepted as perl');

# The Windows Stop reads the command line, which is all the identity a worker
# has there: the runner ends the pty child, not the 12 subprocessor_worker.pl
# children it started. The utility scheduler and the Coding daemon have the same
# shape, so all three are in the script list.
for my $name (qw(subprocessor_worker.pl utility_jobs.pl Coding.pl)) {
	like($src, qr/my \@SCRIPTS = qw\([^)]*\Q$name\E/s,
		"$name is named by the command-line sweep");
}

# The Windows Stop path runs this file before it signals anything, so a stray
# POSIX call must fail here, not on the desktop.
my $compile = `$^X -c $script 2>&1`;
is($?, 0, 'the killer compiles') or diag($compile);

# On Windows parent_pid() answers 0. The publisher supervisor waits for its
# parent to change (POSIX reparents the orphan to 1), so a zero must return
# before the loop: waiting for a parent that can never change would spin. The
# loop body is observed by swapping its command builder for a counter.
require JawnOS::Platform;
my $network_loaded = eval { require 'JawnOS/Domain/Network.pm'; 1 };
ok($network_loaded, 'Network.pm loads for the parent-guard check') or diag($@);
SKIP: {
	skip 'Network.pm did not load', 2 unless $network_loaded;
	no warnings 'redefine';
	my $fake_parent = 0;
	my $built = 0;
	local *JawnOS::Platform::parent_pid = sub { $fake_parent };
	local *subs::house_advertise_command = sub { $built++; return () };
	subs::house_advertise_supervise();
	is($built, 0, 'a parent of 0 skips the publisher wait loop');
	$fake_parent = $$;
	subs::house_advertise_supervise();
	is($built, 1, 'a known parent enters the loop');
}

my $tmp = tempdir(CLEANUP => 1);

# The master hands the killer its own root on every stop, and places a pid in
# a checkout before sweeping.
my $master_src = read_file("$root/jawn");
like($master_src, qr/sub pid_in_tree/, 'the master places a pid in its own checkout');
like($master_src, qr/manager_killer\.pl --cwd=/, 'the stop hands the killer its own root');
unlike($master_src, qr{opendir\([^)]*['"]/proc['"]}, 'the master does not scan /proc itself');
unlike($master_src, qr{(?:open|readlink)\([^)]*['"]/proc/\$}, 'the master does not read /proc/<pid> itself');
unlike($master_src, qr{kill\s*\(\s*0\s*,}, 'the master does not test liveness with kill 0');
like($master_src, qr{JawnOS::Platform::Process::pid_exists}, 'the master asks the seam whether a pid exists');
like($master_src, qr{JawnOS::Platform::Process::table}, 'the master scans through the process table');

# A restart replaces only the President in the pty. Its workers are not in that
# pty: they outlived it (on Windows with the dead pid still in ParentProcessId)
# and kept the old listeners bound. The master takes the old pid before the fork
# is closed and walks its subtree after.
like($master_src, qr/sub restart_sweep/, 'the master carries a restart subtree sweep');
like($master_src, qr/my \$old_tree_pid = \$fork \? \$fork->pid : 0;/,
	'the restart takes the old tree pid before the fork is closed');
like($master_src, qr/&restart_sweep\(\$old_tree_pid\)/,
	'the restart sweeps the old subtree');
like($master_src, qr/\$keep_coding \? ' --keep-coding'/,
	'a restart tells the named sweep to keep the Coding daemon');
my ($sweep_sub) = $master_src =~ /(sub restart_sweep \{.*?\n\})/s;
ok($sweep_sub, 'restart_sweep is a self-contained helper');
like($sweep_sub, qr/JawnOS::Platform::Process::tree/, 'the sweep walks the ppid tree');
like($sweep_sub, qr/JawnOS::Platform::Process::signal/, 'the sweep signals exact pids');
like($sweep_sub, qr/reverse @\$kids/, 'the children go before the parent');

# Run the real extracted helper against a fixture: the decision and the order
# are what the restart depends on, not the live process table.
my $sweep_pkg = 'JawnOS::Test::RestartSweep';
{
	my $ok = eval "package $sweep_pkg; $sweep_sub\n1;";
	is($@, '', 'the extracted sweep compiles under strict');
	ok($ok, 'and loads');
}
my $sweep = $sweep_pkg->can('restart_sweep');
ok($sweep, 'the harness can call restart_sweep');
my @sent;
my $swept = $sweep->(4_900_000,
	tree   => sub { [ 4_900_001, 4_900_002, 4_900_003 ] },
	signal => sub { push @sent, [@_]; return 1 },
	alive  => sub { 1 },
	wait   => 0,
);
is($swept, 4, 'the sweep sends to every child and the old parent');
is_deeply([ map { $_->[1] } @sent ], [ 4_900_003, 4_900_002, 4_900_001, 4_900_000 ],
	'children are signalled before the parent');
is($sweep->(1, tree => sub { [2] }, signal => sub { 1 }, alive => sub { 1 }, wait => 0),
	0, 'pid 1 is not a subtree');
is($sweep->(undef, tree => sub { [2] }, signal => sub { 1 }), 0, 'no pid is not a subtree');

# A real worker-shaped process: perl running a script named President.pl.
write_file("$tmp/President.pl", "sleep 60;\n");
my $fake = fork();
die "fork fake: $!\n" unless defined $fake;
if ($fake == 0) {
	chdir($tmp) or exit 126;
	exec($^X, "$tmp/President.pl");
	exit 127;
}

# The two shapes a Windows Stop used to leave behind: a subprocessor job and the
# Coding daemon. Both are perl running a script from the checkout, exactly as the
# sweep reads them.
write_file("$tmp/subprocessor_worker.pl", "sleep 60;\n");
my $job = fork();
die "fork job: $!\n" unless defined $job;
if ($job == 0) {
	chdir($tmp) or exit 126;
	exec($^X, "$tmp/subprocessor_worker.pl");
	exit 127;
}
write_file("$tmp/Coding.pl", "sleep 60;\n");
my $coding = fork();
die "fork coding: $!\n" unless defined $coding;
if ($coding == 0) {
	chdir($tmp) or exit 126;
	exec($^X, "$tmp/Coding.pl");
	exit 127;
}

# Decoys: a shell that mentions Manager.pl, and a perl compile probe (which is
# exactly what an agent runs while editing).
my $shell = fork();
die "fork shell: $!\n" unless defined $shell;
if ($shell == 0) {
	exec('sh', '-c', 'sleep 60', "$tmp/Manager.pl");
	exit 127;
}
my $probe = fork();
die "fork probe: $!\n" unless defined $probe;
if ($probe == 0) {
	exec($^X, '-e', 'sleep 60', "$tmp/Manager.pl");
	exit 127;
}

ok(wait_for_cmdline($fake, 'President.pl'), 'the fake worker is running as President.pl');
ok(wait_for_cmdline($job, 'subprocessor_worker.pl'), 'the subprocessor worker is running');
ok(wait_for_cmdline($coding, 'Coding.pl'), 'the Coding daemon is running');

# One shot at --list was enough alone and occasionally empty in a loaded 8-job
# run (a transient fork failure, not a selection bug). Retry briefly; the
# assertions below still hold the killer to the same answer.
my $list = '';
for (1 .. 5) {
	$list = `$^X $script --list --scope=$tmp 2>&1`;
	last if $list =~ /^\Q$fake\E\t/m;
	sleep 0.2;
}
like($list, qr/^\Q$fake\E\t/m, 'the perl worker is selected');
like($list, qr/^\Q$job\E\t/m, 'a subprocessor worker is selected');
like($list, qr/^\Q$coding\E\t/m, 'the Coding daemon is selected');
my $kept = `$^X $script --list --keep-coding --scope=$tmp 2>&1`;
unlike($kept, qr/^\Q$coding\E\t/m, '--keep-coding leaves the Coding daemon alone');
like($kept, qr/^\Q$job\E\t/m, 'and still names the tree workers');
unlike($list, qr/^\Q$shell\E\t/m, 'a shell that merely mentions Manager.pl is not');
unlike($list, qr/^\Q$probe\E\t/m, 'a perl -e probe is not');

# Two checkouts on one box (the live house, a smoke worktree) start Presidents
# with the same command line; only their cwd tells them apart. The master chdirs
# to its own root first, so --cwd is that answer - and it is what keeps one
# tree's shutdown from stopping the other's.
my $other = tempdir(CLEANUP => 1);
write_file("$other/President.pl", "sleep 60;\n");
my $elsewhere = fork();
die "fork elsewhere: $!\n" unless defined $elsewhere;
if ($elsewhere == 0) {
	chdir($other) or exit 126;
	exec($^X, "$other/President.pl");
	exit 127;
}
ok(wait_for_cmdline($elsewhere, 'President.pl'), 'the second checkout runs the same command line');

my $here = `$^X $script --list --cwd=$tmp 2>&1`;
like($here, qr/^\Q$fake\E\t/m, '--cwd names the process in its own checkout');
unlike($here, qr/^\Q$elsewhere\E\t/m, 'a process in another checkout is left alone');

my $there = `$^X $script --list --cwd=$other 2>&1`;
like($there, qr/^\Q$elsewhere\E\t/m, 'the other checkout answers to its own cwd');
unlike($there, qr/^\Q$fake\E\t/m, 'and does not name this one');

# A checkout removed while its tree still runs: the kernel appends " (deleted)"
# to the cwd link, and the killer must still place the process in that checkout.
# That is the same rule the master's pid_in_tree keeps, and it is what the seam
# returns, so this proves the fold did not lose it.
my $gone = tempdir(CLEANUP => 1);
write_file("$gone/President.pl", "sleep 60;\n");
my $deleted = fork();
die "fork deleted: $!\n" unless defined $deleted;
if ($deleted == 0) {
	chdir($gone) or exit 126;
	exec($^X, "$gone/President.pl");
	exit 127;
}
ok(wait_for_cmdline($deleted, 'President.pl'), 'the worker in the removed checkout is running');
unlink("$gone/President.pl");
rmdir($gone);
my $gone_list = `$^X $script --list --cwd=$gone 2>&1`;
like($gone_list, qr/^\Q$deleted\E\t/m, '--cwd still places a worker whose checkout was removed');
kill 'KILL', $deleted;
waitpid($deleted, 0);

system($^X, $script, "--scope=$tmp") == 0 or fail('the killer exited non-zero');

my $deadline = time + 3;
my $reaped = 0;
while (time < $deadline) {
	if (waitpid($fake, WNOHANG) == $fake) { $reaped = 1; last }
	sleep 0.05;
}
ok($reaped, 'the worker is stopped');
&reap($job);
&reap($coding);
ok(kill(0, $shell), 'the shell decoy survives');
ok(kill(0, $probe), 'the compile probe survives');

# The scoped stop takes its own checkout's tree and leaves the other alone.
# --scope as well as --cwd here: without it a test run on the serving box would
# reach the host's shared helpers, which are deliberately not cwd-scoped.
system($^X, $script, "--cwd=$other", "--scope=$other") == 0 or fail('the scoped killer exited non-zero');
my $elsewhere_deadline = time + 3;
my $elsewhere_gone = 0;
while (time < $elsewhere_deadline) {
	if (waitpid($elsewhere, WNOHANG) == $elsewhere) { $elsewhere_gone = 1; last }
	sleep 0.05;
}
ok($elsewhere_gone, 'the other checkout is stopped from its own cwd');

kill 'KILL', $shell, $probe;
waitpid($shell, 0);
waitpid($probe, 0);

# The master is only taken when it is named, because ./jawn calls the killer
# with no argument and must not stop itself.
write_file("$tmp/jawn", "sleep 60;\n");
my $master = fork();
die "fork master: $!\n" unless defined $master;
if ($master == 0) {
	exec($^X, "$tmp/jawn");
	exit 127;
}
ok(wait_for_cmdline($master, 'jawn'), 'the fake master is running');

my $without = `$^X $script --list --scope=$tmp 2>&1`;
unlike($without, qr/^\Q$master\E\t/m, 'the master is left alone by default');
my $with = `$^X $script --list master --scope=$tmp 2>&1`;
like($with, qr/^\Q$master\E\tmaster/m, 'master mode names it');

system($^X, $script, 'master', "--scope=$tmp") == 0 or fail('master kill exited non-zero');
my $master_deadline = time + 3;
my $master_gone = 0;
while (time < $master_deadline) {
	if (waitpid($master, WNOHANG) == $master) { $master_gone = 1; last }
	sleep 0.05;
}
ok($master_gone, 'the master is stopped in master mode');

kill 'KILL', $master if kill(0, $master);

# --------------------------------------------------------------- the tree ask
# Stop now asks the tree to leave over ~/.president/tree before it signals
# anything. A scoped run stays off that channel (it is per-home, not per
# checkout) unless --ask-tree says so - which is exactly how this test drives it
# without touching the live house.
sub wait_for_socket {
	my ($path) = @_;
	my $bound_by = time + 20;
	sleep 0.01 until -S $path || time > $bound_by;
	return -S $path ? 1 : 0;
}

# A stand-in tree: accept once, record the request line, answer the stop. Its
# accept has a bound so a killer that never asks fails a test, not the suite.
sub fake_tree {
	my ($path, $record) = @_;
	my $pid = fork();
	die "fork tree: $!\n" unless defined $pid;
	if (!$pid) {
		require IO::Socket::UNIX;
		require IO::Select;
		my $server = IO::Socket::UNIX->new(Local => $path, Listen => 5) or exit 1;
		my $select = IO::Select->new($server);
		my $client = $select->can_read(15) ? $server->accept : undef;
		exit 2 unless $client;
		my $line = <$client>;
		if (defined $line && length $line) {
			write_file($record, $line);
			print $client '{"ok":1,"cmd":"stop"}', "\n";
		}
		close $client;
		close $server;
		exit 0;
	}
	return $pid;
}

sub reap {
	my ($pid) = @_;
	my $deadline = time + 20;
	while (1) {
		my $got = waitpid($pid, WNOHANG);
		return if $got == $pid || $got == -1;
		last if time > $deadline;
		sleep 0.02;
	}
	kill 'KILL', $pid;
	waitpid($pid, 0);
}

my $tree_dir = tempdir(CLEANUP => 1);
my $tree_record = "$tree_dir/request.json";
my $tree_server = &fake_tree("$tree_dir/tree", $tree_record);
ok(&wait_for_socket("$tree_dir/tree"), 'the stand-in tree bound its stop channel');

my $tree_rc;
{
	local $ENV{'JAWNOS_DATA_DIR'} = $tree_dir;
	local $ENV{'JAWNOS_TRANSPORT'} = 'unix';
	$tree_rc = system($^X, $script, "--scope=$tree_dir", '--ask-tree', "--cwd=$tree_dir");
}
my $got_by = time + 5;
while (time < $got_by) {
	last if -f $tree_record;
	sleep 0.02;
}
my $received = -f $tree_record ? read_file($tree_record) : '';
&reap($tree_server);
is($tree_rc, 0, 'the stop exits 0 after asking the tree');
like($received, qr/"cmd"\s*:\s*"stop"/, 'the tree is asked to stop over its channel');

# --list is a read-only answer and must not open the tree channel at all, even
# when --ask-tree is named.
my $list_dir = tempdir(CLEANUP => 1);
my $list_record = "$list_dir/request.json";
my $list_server = &fake_tree("$list_dir/tree", $list_record);
ok(&wait_for_socket("$list_dir/tree"), 'the stand-in tree for --list bound its channel');

my $list_rc;
{
	local $ENV{'JAWNOS_DATA_DIR'} = $list_dir;
	local $ENV{'JAWNOS_TRANSPORT'} = 'unix';
	$list_rc = system($^X, $script, '--list', "--scope=$list_dir", '--ask-tree', "--cwd=$list_dir");
}
sleep 0.3;
ok(!-f $list_record, '--list does not ask the tree to stop');
is($list_rc, 0, '--list still exits 0');
kill 'KILL', $list_server if kill(0, $list_server);
waitpid($list_server, 0);

done_testing();
