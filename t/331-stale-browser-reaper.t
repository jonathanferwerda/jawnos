# tests-for: scripts/stale_browser_reaper.pl
# covers:    which processes are browser parents, every reap/skip rule, the
#           /proc scan, and the process-group kill

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use POSIX ();

# The reaper exists for one shape: a headless Chromium started with a private
# profile and a CDP port whose launcher died, leaving ppid 1 and a GPU child
# that never stops. The selection is pure, so every rule is pinned here without
# a browser; the scan and the kill are exercised against a fake proc root and a
# session leader this test starts itself.

my $root = "$FindBin::Bin/..";
require "$root/scripts/stale_browser_reaper.pl";

my %opt = (
	'min_age'   => 600,
	'max_age'   => 6 * 3600,
	'proc_root' => '/proc',
);

sub browser {
	my (%a) = @_;
	my @cmd = (
		'/usr/lib/chromium/chromium',
		'--headless=new', '--no-sandbox', '--disable-gpu',
		'--ozone-platform=headless',
		'--user-data-dir=' . ($a{'dir'} // '/tmp/cdp-world'),
		'--remote-debugging-port=' . ($a{'port'} // 9234),
		'about:blank',
	);
	push @cmd, $a{'extra'} if $a{'extra'};
	return {
		'pid'              => $a{'pid'} // 9001,
		'ppid'             => exists $a{'ppid'} ? $a{'ppid'} : 1,
		'age_s'            => exists $a{'age_s'} ? $a{'age_s'} : 3600,
		'cmdline'          => $a{'cmdline'} // \@cmd,
		'client_connected' => $a{'client_connected'} // 0,
	};
}

# --- the process shape --------------------------------------------------------

my @parent = qw(/usr/lib/chromium/chromium --headless=new --user-data-dir=/tmp/x
	--remote-debugging-port=9234 about:blank);
ok(browser_parent(\@parent), 'a headless browser with a profile and a CDP port is a candidate');
ok(browser_parent(join(' ', @parent)),
	'the same command line as a string is a candidate');

my @headed = grep { !/--headless/ } @parent;
ok(!browser_parent(\@headed), 'a headed browser is never a candidate');

my @child = (@parent, '--type=gpu-process');
ok(!browser_parent(\@child), 'a GPU child carrying the same switches is excluded by --type=');

ok(!browser_parent([ '/usr/bin/perl', 'scripts/manager_killer.pl' ]),
	'a non-browser process is never a candidate');

ok(!browser_parent([ '/usr/bin/QtWebEngineProcess', '--headless', '--user-data-dir=/tmp/q',
	'--remote-debugging-port=9333' ]), 'Qt WebEngine is excluded by name');

is(debug_port(\@parent), 9234, 'the debug port is read from --remote-debugging-port');
is(debug_port([ 'chromium', '--remote-debugging-port', '9244' ]), 9244,
	'the space-separated form is read too');
is(debug_port([ 'chromium', '--remote-debugging-port=0' ]), 0,
	'port 0 is reported as unprovable, not as absent');

# --- one selection, every rule ------------------------------------------------

my @records = (
	browser('pid' => 100),                                        # old orphan, no client
	browser('pid' => 200, 'age_s' => 60),                         # young orphan
	browser('pid' => 300, 'client_connected' => 1),               # client attached
	browser('pid' => 400, 'cmdline' => [ @headed ]),              # headed
	browser('pid' => 500, 'cmdline' => [ 'sleep', '600' ]),       # not a browser
	browser('pid' => 600, 'ppid' => 4242),                        # launcher alive, inside the ceiling
	browser('pid' => 700, 'ppid' => 4242, 'age_s' => 8 * 3600),   # launcher alive past the ceiling
	browser('pid' => 800, 'extra' => '--type=renderer'),          # renderer child
);

my ($reap, $keep) = select_reaps(\@records, \%opt);
is_deeply([ sort { $a <=> $b } map { $_->{'pid'} } @{$reap} ], [ 100, 700 ],
	'only the orphan and the browser past --max-age are selected');
is_deeply([ map { $_->{'reason'} } @{$reap} ], [ 'orphaned', 'past --max-age' ],
	'each selection carries the rule that made it');
is(scalar(@{$keep}), 6, 'the young, connected, headed, non-browser and child records are kept');

my %no_max = (%opt, 'max_age' => 0);
my ($off) = select_reaps([ browser('pid' => 900, 'ppid' => 4242, 'age_s' => 30 * 3600) ], \%no_max);
is(scalar(@{$off}), 0, '--max-age 0 leaves a live launcher alone however old the browser is');

my %young = (%opt, 'min_age' => 7200);
my ($strict) = select_reaps([ browser('pid' => 901, 'age_s' => 3600) ], \%young);
is(scalar(@{$strict}), 0, '--min-age is honoured');
my ($over) = select_reaps([ browser('pid' => 902, 'age_s' => 7300) ], \%young);
is(scalar(@{$over}), 1, 'a tree older than --min-age is still selected');

# --- the scan and the summary, against a fake proc root ------------------------

my $hz = POSIX::sysconf(POSIX::_SC_CLK_TCK()) || 100;
my $fake = tempdir(CLEANUP => 1);
my $UPTIME = 100_000;

sub write_proc {
	my ($pid, $ppid, $start_ticks, @cmd) = @_;
	make_path("$fake/$pid");
	open(my $s, '>', "$fake/$pid/stat") or die "stat: $!";
	# tokens after the comm are field 3 onward; index 19 is starttime (field 22)
	print $s "$pid (chromium) S $ppid $pid $pid 0 -1 4194560 0 0 0 0 0 0 0 0 0 20 0 0 $start_ticks 0 0 0\n";
	close $s;
	open(my $c, '>', "$fake/$pid/cmdline") or die "cmdline: $!";
	print $c join("\0", @cmd), "\0";
	close $c;
}

open(my $up, '>', "$fake/uptime") or die "uptime: $!";
print $up "$UPTIME.00 50000.00\n";
close $up;

# 4001: the leak. 4002: same shape, but a client holds 9241 (0x2419) ESTABLISHED.
my $hour_ago = ($UPTIME - 3600) * $hz;
write_proc(4001, 1, $hour_ago, '/usr/lib/chromium/chromium', '--headless=new',
	'--user-data-dir=/tmp/cdp-world', '--remote-debugging-port=9240', 'about:blank');
write_proc(4002, 1, $hour_ago, '/usr/lib/chromium/chromium', '--headless=new',
	'--user-data-dir=/tmp/cdp-world', '--remote-debugging-port=9241', 'about:blank');
write_proc(4003, 1, $hour_ago, '/usr/bin/perl', '-e', 'sleep 1');
make_path("$fake/net");
open(my $tcp, '>', "$fake/net/tcp") or die "net/tcp: $!";
print $tcp "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n";
print $tcp "   0: 0100007F:2419 0100007F:D431 01 00000000:00000000 00:00000000 00000000  1000        0 12345 1 0 100 0 0 10 0\n";
close $tcp;

my @scan_cmd = ($^X, "$root/scripts/stale_browser_reaper.pl",
	'--dry-run', '--proc-root', $fake);
open(my $out, '-|', @scan_cmd) or die "run reaper: $!";
my $text = do { local $/; <$out> // '' };
close $out;
my $status = $? >> 8;

is($status, 0, 'a dry run exits 0');
like($text, qr/stale_browser_reaper: dry run - would reap 1, skipped 1\b/,
	'the scan finds the orphan and spares the browser with a client');
is(scalar(() = $text =~ /^\s+pid \d+/mg), 1, 'the scan details exactly one tree');

# --- the kill, on a session leader this test starts ---------------------------

my $child = fork();
if (!defined $child) {
	skip('cannot fork a test child', 3);
}
elsif (!$child) {
	POSIX::setsid();
	exec 'sleep', '60';
	POSIX::_exit(127);
}
else {
	my $leader = 0;
	for (1 .. 50) {
		my $stat = read_stat('/proc', $child);
		if ($stat && $stat->{'pgid'} == $child) { $leader = 1; last }
		select undef, undef, undef, 0.05;
	}
	ok($leader, 'the test child became its own process-group leader');

	my $how = kill_tree(
		{ 'pid' => $child, 'pgid' => $child, 'cmdline' => [ 'sleep', '60' ] },
		{ 'proc_root' => '/proc', 'grace' => 1 });
	is($how, 'group', 'the group, not just the parent, was signalled');

	waitpid($child, 0);
	ok(!kill(0, -$child), 'nothing is left in the group');
}

done_testing();
