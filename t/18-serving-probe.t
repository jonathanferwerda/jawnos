use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use IO::Socket::INET;
use POSIX qw(_exit);

# probe.pl answers the master's liveness question for ./jawn's watchdog.
#
# The regression it guards: the watchdog used a bare connect(), and connect()
# completes against a tree whose event loop is blocked, because the kernel
# queues the handshake in the accept backlog. A wedged tree therefore read as
# healthy and was never recovered. Each case below is a different way a port
# can look open and still not serve.

my $root = abs_path("$FindBin::Bin/..");
require "$root/probe.pl";
ok defined &probe::serving, 'probe::serving is loaded';

# A port nothing is bound to: the ordinary "the tree is gone" answer.
sub free_port {
	my $sock = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 1, ReuseAddr => 1);
	return 0 unless $sock;
	my $port = $sock->sockport;
	close $sock;
	return $port;
}

# A stub listener in a child, so a port can be held open while it answers in a
# chosen way. Modes: 'ok' answers 200, 'error' answers 503, 'hang' accepts and
# never writes - the wedged tree, from the outside.
sub start_stub {
	my ($mode) = @_;
	pipe(my $read, my $write) or die "pipe: $!";
	my $pid = fork();
	defined $pid or die "fork: $!";
	if (!$pid) {
		close $read;
		my $server = IO::Socket::INET->new(
			LocalAddr => '127.0.0.1', LocalPort => 0, Listen => 5, ReuseAddr => 1);
		_exit(1) unless $server;
		print $write $server->sockport . "\n";
		close $write;
		# a stub must never outlive the test, even if the parent dies
		$SIG{ALRM} = sub { _exit(0) };
		alarm 20;
		while (my $conn = $server->accept) {
			$conn->autoflush(1);
			# the probe tries TLS first; a ClientHello has no line to read, so
			# this returns undef when the client gives up and we take the next
			my $request = <$conn>;
			next unless defined $request;
			if ($mode eq 'hang') { sleep 2; close $conn; next; }
			my ($code, $body) = $mode eq 'error'
				? ('503 Service Unavailable', 'no')
				: ('200 OK', 'ok');
			print $conn "HTTP/1.1 $code\r\n"
				. 'Content-Length: ' . length($body) . "\r\n"
				. "Connection: close\r\n\r\n" . $body;
			close $conn;
		}
		_exit(0);
	}
	close $write;
	my $port = <$read>;
	close $read;
	chomp $port if defined $port;
	$port = 0 unless defined $port && $port =~ /^[0-9]+$/;
	return ($pid, $port);
}

sub stop_stub {
	my ($pid) = @_;
	return unless $pid;
	kill 'TERM', $pid;
	waitpid($pid, 0);
}

my $timeout = 0.4;

is probe::serving('', 'timeout' => $timeout), 0, 'no port is not serving';
is probe::serving('not-a-port', 'timeout' => $timeout), 0, 'a non-numeric port is not serving';

my $closed = free_port();
ok $closed, 'found a closed port to probe';
is probe::serving($closed, 'timeout' => $timeout), 0, 'a closed port is not serving';

my ($ok_pid, $ok_port) = start_stub('ok');
ok $ok_port, 'the answering stub is listening';
is probe::serving($ok_port, 'timeout' => 1), 1,
	'a tree that answers is serving (and a plain-HTTP install still probes)';
stop_stub($ok_pid);

my ($error_pid, $error_port) = start_stub('error');
ok $error_port, 'the failing-handler stub is listening';
is probe::serving($error_port, 'timeout' => 1), 0,
	'a 5xx is a handler that failed, not a live tree - the health route fails this way when the database cannot be read';
stop_stub($error_pid);

my ($hang_pid, $hang_port) = start_stub('hang');
ok $hang_port, 'the wedged stub is listening';
is probe::serving($hang_port, 'timeout' => $timeout), 0,
	'an open port that never answers is not serving - exactly what a bare connect() called healthy';
stop_stub($hang_pid);

done_testing();
