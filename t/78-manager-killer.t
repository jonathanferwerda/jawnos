# tests-for: jawn perl/Manager.pl perl/President.pl scripts/manager_killer.pl
# covers:    The killer used to shell out to pkill/pgrep four times per name, and a match was anything whose command line m...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
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

my $tmp = tempdir(CLEANUP => 1);

# The master hands the killer its own root on every stop, and places a pid in
# a checkout before sweeping.
my $master_src = read_file("$root/jawn");
like($master_src, qr/sub pid_in_tree/, 'the master places a pid in its own checkout');
like($master_src, qr/manager_killer\.pl --cwd=/, 'the stop hands the killer its own root');

# A real worker-shaped process: perl running a script named President.pl.
write_file("$tmp/President.pl", "sleep 60;\n");
my $fake = fork();
die "fork fake: $!\n" unless defined $fake;
if ($fake == 0) {
	chdir($tmp) or exit 126;
	exec($^X, "$tmp/President.pl");
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

system($^X, $script, "--scope=$tmp") == 0 or fail('the killer exited non-zero');

my $deadline = time + 3;
my $reaped = 0;
while (time < $deadline) {
	if (waitpid($fake, WNOHANG) == $fake) { $reaped = 1; last }
	sleep 0.05;
}
ok($reaped, 'the worker is stopped');
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
