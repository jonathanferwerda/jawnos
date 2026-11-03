# tests-for: lib/JawnOS/Domain/Remote.pm lib/JawnOS/Manager/Part10.pm
# covers:    A peer ticket mint retries without a stale stored session cookie.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use IO::Socket::INET;
use POSIX ();
use JawnOSTest;

# remote_manager_ticket rides the stored peer session cookie. When that session
# is stale the peer answers its Gate's denial (403), and the mint used to give
# up even though the same request freshly signed is accepted by the ticket desk
# (the Dev machine's Go was denied on VM 103's house for exactly this). The
# helper must try the stored session, then retry once without its cookie.

# The stub answers 403 to the first request and a ticket body to the second, so
# the only way to see 200 is that the retry happened.
sub start_stub {
	pipe(my $read, my $write) or die "pipe: $!";
	my $pid = fork();
	defined $pid or die "fork: $!";
	if (!$pid) {
		close $read;
		my $server = IO::Socket::INET->new(
			LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1);
		POSIX::_exit(1) unless $server;
		print $write $server->sockport . "\n";
		close $write;
		$SIG{ALRM} = sub { POSIX::_exit(0) };
		alarm 20;
		my $n = 0;
		while (my $conn = $server->accept) {
			$conn->autoflush(1);
			my $request = <$conn>;
			next unless defined $request;
			$n++;
			my ($code, $body) = $n == 1
				? ('403 Forbidden', 'denied')
				: ('200 OK', '{"url":"https:\/\/hub.example:45545\/box_office\/x?s=y"}');
			print $conn "HTTP/1.1 $code\r\n"
				. 'Content-Length: ' . length($body) . "\r\n"
				. "Connection: close\r\n\r\n" . $body;
			close $conn;
			last if $n >= 2;
		}
		POSIX::_exit(0);
	}
	close $write;
	my $port = <$read>;
	close $read;
	chomp $port if defined $port;
	return ($pid, $port);
}

my ($pid, $port) = start_stub();
ok($port, 'the ticket stub is listening');

# peer_sign_request needs this machine's key; the stub does not verify it.
local *subs::peer_sign_request = sub { };

my $url = "http://127.0.0.1:$port/manager/qrcode_generator?nic=hub.example";
my $ua = Mojo::UserAgent->new;
my $res = subs::peer_ticket_fetch($url, $ua);

ok($res, 'the helper returns a response');
is($res->code, 200, 'a stale-session 403 is retried without the cookie');
like($res->body, qr/box_office/, 'and the retry carries the ticket body');

kill 'TERM', $pid;
waitpid($pid, 0);

done_testing();
