# tests-for: jawn perl/probe.pl
# covers:    probe.pl answers the master's liveness question for ./jawn's watchdog.

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
require "$root/perl/probe.pl";
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

# ---- which ports a machine must answer on --------------------------------
# The phone regression: its working_port answered and its dock (3000) did not,
# because a handheld binds no dock listener. Requiring both called a healthy
# tree dead and the boot watch restarted it every 90 seconds.
is_deeply([ probe::required_ports({ device => 'computer', port => 3000, working_port => 45545 }) ],
	[3000, 45545], 'a computer answers for its dock and its manager');
is_deeply([ probe::required_ports({ device => 'mobile', port => 3000, working_port => 45545 }) ],
	[45545], 'a handheld answers for its manager, and not a dock it never binds');
is_deeply([ probe::required_ports({ device => 'mobile', port => 3000 }) ],
	[3000], 'a handheld that names no working_port still probes the one port it has');
is_deeply([ probe::required_ports({ device => 'computer', port => 3000, working_port => 3000 }) ],
	[3000], 'a port named twice is asked once');
is_deeply([ probe::required_ports({}) ], [], 'no ports named, none required');

# End to end over real sockets: a mobile tree whose manager answers but whose
# dock is closed is serving; the same pair on a computer is not.
my ($serving_pid, $serving_port) = start_stub('ok');
my $closed_port = free_port();
ok $serving_port && $closed_port, 'found a live stub and a closed port';
my @mobile_ports = probe::required_ports({ device => 'mobile', port => $closed_port, working_port => $serving_port });
is_deeply(\@mobile_ports, [ $serving_port ], 'the handheld list is the manager alone');
ok(!grep({ !probe::serving($_, 'timeout' => 1) } @mobile_ports), 'every required handheld port answers');
my @desktop_ports = probe::required_ports({ device => 'computer', port => $closed_port, working_port => $serving_port });
ok(scalar(grep({ !probe::serving($_, 'timeout' => $timeout) } @desktop_ports)), 'a computer with a closed dock is not serving');
stop_stub($serving_pid);

done_testing();
