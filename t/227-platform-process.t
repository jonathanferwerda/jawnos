# tests-for: lib/JawnOS/Platform/Process.pm
# covers:    the process identity/state seam: /proc stat parsing when "(comm)"
#            holds spaces and parens, exists vs. running (a zombie), the
#            pid-reuse start token, the command line, CPU ticks, the
#            process-group descendant scan, and the safe empty answers a
#            platform without /proc gives.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use POSIX ();
use Time::HiRes qw(sleep);
use JawnOS::Platform::Process qw(
	parse_stat state running pid_exists same_process start_time
	command_line cpu_ticks descendants signal
);

my $linux = ($^O eq 'linux') ? 1 : 0;

# ------------------------------------------------------------ the stat parser
# The fields begin after the last ')' because "(comm)" may itself hold spaces
# and parentheses. Index 19 is field 22 (start time), 11/12 are utime/stime.
my $line = "4242 (a (b) c) S 1 4242 4242 0 -1 4194560 100 0 0 0 12 34 0 0 20 0 1 0 98765 123456 789 0 0\n";
my $stat = parse_stat($line);
is(ref $stat, 'HASH', 'a stat line parses to a hash');
is($stat->{'state'}, 'S', 'state is the first field after the comm');
is($stat->{'ppid'}, 1, 'ppid is field 4');
is($stat->{'pgrp'}, 4242, 'pgrp is field 5');
is($stat->{'utime'}, 12, 'utime is field 14');
is($stat->{'stime'}, 34, 'stime is field 15');
is($stat->{'start'}, 98765, 'start time is field 22');

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
}
else {
	is(start_time($$), '', 'a platform without /proc has no start token');
	is(command_line($$), '', 'a platform without /proc has no command line');
	is(cpu_ticks($$), undef, 'a platform without /proc has no CPU ticks');
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

done_testing();
