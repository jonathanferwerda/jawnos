# tests-for: scripts/jawn-bt
# covers:    A device record carries the watch's Bluetooth address bare
#            (64E8334B3839) while the daemon answers with AA:BB:CC:DD:EE:FF.
#            The client compared the two forms, so an idempotent connect waited
#            its full 20 s and a send its full 15 s even though the write had
#            already landed - the words reached the watch, and the reply was
#            reported late. A bare MAC must be matched, not timed out.

use strict;
use warnings;
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use IO::Socket::INET ();
use JSON::PP ();
use Time::HiRes ();

my $WATCH = '64:E8:33:4B:38:39';
my $BARE  = '64E8334B3839';

# A one-answer daemon on a free port: it reads the client's command line, writes
# the event the real daemon would write, and stays up until the test kills it.
sub fake_daemon {
	my ($reply) = @_;
	my $srv = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5,
		ReuseAddr => 1, Proto => 'tcp',
	) or die "fake daemon: $!";
	my $port = $srv->sockport;
	my $pid = fork();
	die 'fake daemon fork failed' unless defined $pid;
	if (!$pid) {
		my $client = $srv->accept() or exit 1;
		$client->autoflush(1);
		my $line = <$client>;   # the command
		print {$client} JSON::PP->new->encode($reply) . "\n";
		select(undef, undef, undef, 5);
		exit 0;
	}
	close $srv;
	return ($pid, $port);
}

sub run_client {
	my ($port, @args) = @_;
	local $ENV{'JAWNOS_BT_PORT'} = $port;
	my $start = Time::HiRes::time();
	open(my $fh, '-|', $^X, root() . '/scripts/jawn-bt', @args)
		or die "cannot run jawn-bt: $!";
	local $/;
	my $out = <$fh> // '';
	close $fh;
	my $code = $? >> 8;
	return ($code, $out, Time::HiRes::time() - $start);
}

sub stop_daemon {
	my ($pid) = @_;
	kill 'KILL', $pid;
	waitpid($pid, 0);
}

# --- an idempotent connect answers at once ---------------------------------
{
	my ($pid, $port) = fake_daemon({
		event => 'status', connected => JSON::PP::true, mac => $WATCH,
		links => [ { mac => $WATCH, connected => JSON::PP::true } ],
	});
	my ($code, $out, $secs) = run_client($port, 'connect', $BARE, '--timeout', '3');
	is($code, 0, 'a connect by bare MAC is accepted');
	cmp_ok($secs, '<', 2, 'and does not wait out the 20 s connect deadline');
	stop_daemon($pid);
}

# --- a send sees its own acknowledgement -----------------------------------
{
	my ($pid, $port) = fake_daemon({ event => 'sent', mac => $WATCH });
	my ($code, $out, $secs) = run_client($port, 'send', 'hello', '--mac', $BARE, '--timeout', '3');
	is($code, 0, 'a send by bare MAC finds the sent event');
	cmp_ok($secs, '<', 2, 'and does not wait out the 15 s send deadline');
	stop_daemon($pid);
}

# --- the colon form keeps working ------------------------------------------
{
	my ($pid, $port) = fake_daemon({
		event => 'status', connected => JSON::PP::true, mac => $WATCH,
		links => [ { mac => $WATCH, connected => JSON::PP::true } ],
	});
	my ($code, $out, $secs) = run_client($port, 'connect', $WATCH, '--timeout', '3');
	is($code, 0, 'a connect by colon MAC still works');
	cmp_ok($secs, '<', 2, 'quickly');
	stop_daemon($pid);
}

done_testing();
