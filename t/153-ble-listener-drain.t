# tests-for: scripts/jawn-bt lib/JawnOS/Domain/Ble2.pm lib/JawnOS/Ble/Drain.pm
# covers:    the BLE listener drains a burst of events in one linear pass. Removing
#           each line with s/^(.*?)\n// copied the whole remaining buffer, so a
#           burst that ended with one large event was quadratic: a phone spent
#           minutes of CPU on a few megabytes. An unterminated line is kept as
#           chunks, so a stream with no newline costs one copy, not one per read.
#           Also pins the cap on an unterminated line and that the parent drops
#           only that tail.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";
use IO::Select;
use IO::Socket::INET;
use IPC::Open3;
use POSIX qw(sysconf _SC_CLK_TCK);
use Symbol qw(gensym);
use Test::More;
use Time::HiRes qw(time sleep);
use JawnOS::Ble::Drain qw(drain_new drain_feed);

my $root = "$FindBin::Bin/..";

# ---- the shipped shape ------------------------------------------------------
for my $file ("$root/scripts/jawn-bt", "$root/lib/JawnOS/Domain/Ble2.pm") {
	open(my $fh, '<', $file) or die "$file: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	ok(index($text, '$buf =~ s/^(.*?)\n//') < 0, "$file no longer removes one line by copying the rest");
	like($text, qr/drain_feed\(/, "$file drains complete lines through the shared helper");
}

open(my $bfh, '<', "$root/lib/JawnOS/Domain/Ble2.pm") or die $!;
my $ble = do { local $/; <$bfh> };
close $bfh;
my $drain_at = index($ble, 'drain_feed');
my $cap_at   = index($ble, 'BLE listener buffer overflow');
ok($drain_at >= 0 && $cap_at > $drain_at,
	'the parent handles complete lines before it drops an overlong tail');

# ---- the buffer helper ------------------------------------------------------
my $b = drain_new();
my ($l1) = drain_feed($b, "a\nb\nc", 1024);
is_deeply($l1, ['a', 'b'], 'complete lines are returned and the tail stays');
my ($l2) = drain_feed($b, "d\nrest", 1024);
is_deeply($l2, ['cd'], 'the buffered tail is completed by the next read');
my ($l3, $drop3) = drain_feed($b, "\n", 1024);
is_deeply($l3, ['rest'], 'a line that ends exactly on the buffer boundary');
ok(!$drop3, 'nothing was dropped');

my $cap = drain_new();
my ($cap_lines, $cap_drop) = drain_feed($cap, "ok\n" . ('x' x 20), 10);
is_deeply($cap_lines, ['ok'], 'complete lines survive the cap in the same read');
cmp_ok($cap_drop, '==', 20, 'only the unterminated tail is dropped');

# 256 reads with no newline used to copy the growing tail on every read (and
# Perl's string grow is not amortised): 8 MB of data cost hundreds of MB of
# copying. Here it must cost almost nothing.
my $nonl = drain_new();
my $chunk = 'x' x 65536;
my $t0 = time;
for (1 .. 256) { drain_feed($nonl, $chunk, 64 * 1024 * 1024) }
my $cheap = time - $t0;
cmp_ok($cheap, '<', 0.5, "256 unterminated reads cost \"${\ sprintf('%.3f', $cheap)}\" s");

# ---- the behaviour: a burst with one large event at the end -----------------
# A fake bridge emits a burst of short events and then one ~1 MB event. The
# quadratic reader copies the megabyte once per short line, so the large line
# arrives tens of seconds late; the linear reader prints it at once.
my $srv = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1', LocalPort => 0,
	Proto => 'tcp', Listen => 1, ReuseAddr => 1,
) or plan skip_all => "cannot bind a loopback port: $!";
my $port = $srv->sockport;

my $server = fork();
die "fork: $!" unless defined $server;
if (!$server) {
	my $c = $srv->accept or exit 0;
	$c->autoflush(1);
	print $c '{"event":"status","protocol":2,"connected":false,"mac":null,"mtu":23,"count":0,"links":[]}', "\n";
	my $short = '{"event":"x","n":1}' . "\n";
	print $c $short for 1 .. 100_000;
	print $c '{"event":"message","data":"ENDMARK' . ('x' x (2 * 1024 * 1024)) . '"}', "\n";
	sleep 60;
	exit 0;
}

local $ENV{'JAWNOS_BT_PORT'} = $port;
my $err = gensym;
my $client = open3(my $in, my $out, $err, $^X, "$root/scripts/jawn-bt", 'listen');
close $in;

my $sel = IO::Select->new($out);
my $got = '';
my $seen = 0;
my $begin = time;
my $deadline = $begin + 10;
while (time < $deadline) {
	my @ready = $sel->can_read(0.2);
	next unless @ready;
	my $chunk = '';
	my $n = sysread($out, $chunk, 65536);
	last unless defined $n && $n > 0;
	$got .= $chunk;
	if (index($got, 'ENDMARK') >= 0) { $seen = 1; last; }
}
my $elapsed = time - $begin;

ok($seen, 'the large event reaches the caller');
cmp_ok($elapsed, '<', 8, "the burst drained in ${\ sprintf('%.2f', $elapsed)}s (one pass, not per line)");

kill 'TERM', $client;
kill 'TERM', $server;
close $out; close $err;
waitpid($client, 0);
waitpid($server, 0);

# ---- an unterminated stream must not hold a core ---------------------------
# A bridge that streams one long event (no newline for megabytes) used to make
# every read copy the whole growing tail: the listener sat at ~70% of a core on
# this 16 MB/s stream while the socket queue grew. Reading it must stay cheap.
sub cpu_ticks {
	my ($pid) = @_;
	open(my $fh, '<', "/proc/$pid/stat") or return;
	my $line = <$fh>;
	close $fh;
	my $close = rindex($line, ')');
	return unless $close >= 0;
	my @f = split ' ', substr($line, $close + 2);
	return $f[11] + $f[12];
}

SKIP: {
	skip 'no /proc cpu accounting', 2 unless -r "/proc/$$/stat";
	my $srv2 = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0,
		Proto => 'tcp', Listen => 1, ReuseAddr => 1,
	) or skip "cannot bind a second loopback port: $!", 2;
	my $port2 = $srv2->sockport;
	my $server2 = fork();
	if (!$server2) {
		my $c = $srv2->accept or exit 0;
		$c->autoflush(1);
		print $c '{"event":"status","connected":false,"links":[]}', "\n";
		my $blob = 'x' x 65536;
		my $end = time + 2.4;
		while (time < $end) { print $c $blob; sleep 0.004 }   # ~16 MB/s, no newline
		close $c;
		exit 0;
	}
	local $ENV{'JAWNOS_BT_PORT'} = $port2;
	my $err2 = gensym;
	my $client2 = open3(my $in2, my $out2, $err2, $^X, "$root/scripts/jawn-bt", 'listen');
	close $in2;
	sleep 0.5;
	my $hz = sysconf(_SC_CLK_TCK) || 100;
	my $c0 = cpu_ticks($client2);
	my $w0 = time;
	sleep 1.5;
	my $c1 = cpu_ticks($client2);
	my $wall = time - $w0;
	my $pct = (defined $c0 && defined $c1) ? ($c1 - $c0) / $hz / $wall * 100 : 100;
	cmp_ok($pct, '<', 30, "an unterminated stream costs ${\ sprintf('%.1f', $pct)}% of a core");
	kill 'TERM', $client2;
	kill 'TERM', $server2;
	close $out2; close $err2;
	waitpid($client2, 0);
	waitpid($server2, 0);
}

done_testing();
