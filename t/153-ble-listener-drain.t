# tests-for: scripts/jawn-bt lib/JawnOS/Domain/Ble2.pm
# covers:    the BLE listener drains a burst of events in one linear pass. Removing
#           each line with s/^(.*?)\n// copied the whole remaining buffer, so a
#           burst that ended with one large event was quadratic: a phone spent
#           minutes of CPU on a few megabytes. Also pins the cap on an
#           unterminated line and that the parent drops only that tail.

use strict;
use warnings;

use FindBin;
use IO::Select;
use IO::Socket::INET;
use IPC::Open3;
use Symbol qw(gensym);
use Test::More;
use Time::HiRes qw(time);

my $root = "$FindBin::Bin/..";

# ---- the shipped shape ------------------------------------------------------
for my $file ("$root/scripts/jawn-bt", "$root/lib/JawnOS/Domain/Ble2.pm") {
	open(my $fh, '<', $file) or die "$file: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	ok(index($text, '$buf =~ s/^(.*?)\n//') < 0, "$file no longer removes one line by copying the rest");
	like($text, qr/split \/\\n\//, "$file drains complete lines in one pass");
}

open(my $bfh, '<', "$root/lib/JawnOS/Domain/Ble2.pm") or die $!;
my $ble = do { local $/; <$bfh> };
close $bfh;
my $drain_at = index($ble, 'split /\n/');
my $cap_at   = index($ble, 'BLE listener buffer overflow');
ok($drain_at >= 0 && $cap_at > $drain_at,
	'the parent handles complete lines before it drops an overlong tail');

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

done_testing();
