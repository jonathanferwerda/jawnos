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


# --- the watchdog's pace -----------------------------------------------------
# The regression this pins: the master probed every 30s and called the tree dead
# after TWO misses, so two isolated stalls thirty seconds apart - a slow request,
# a held database lock, a phone coming out of doze - restarted a tree that was
# answering. The policy is a slow resting poll plus a tight confirmation, and it
# takes three failures in a row.
my %policy = probe::watch_policy();
cmp_ok $policy{'strikes'}, '>=', 3,
	'three consecutive failures, not two isolated ones, call a tree down';
is probe::watch_delay(0), $policy{'rest'}, 'a tree that answers is polled at the resting pace';
is probe::watch_delay(1), $policy{'confirm'}, 'the first miss is confirmed in seconds, not half a minute';
is probe::watch_delay(2), $policy{'confirm'}, 'the second miss is confirmed as quickly';
cmp_ok $policy{'confirm'}, '<', $policy{'rest'}, 'confirmation is tighter than the resting poll';
cmp_ok $policy{'rest'}, '>=', 30, 'a healthy phone still pays for only one resting probe a half-minute';
cmp_ok $policy{'rest'} + ($policy{'strikes'} - 1) * $policy{'confirm'}, '<=', 60,
	'a tree that really is down is noticed no later than the old two-30s-probe rule';

# ./jawn must read that policy rather than carry its own copy of the numbers, or
# the two drift apart the next time someone tunes one of them.
my $master = do {
	local $/;
	open my $fh, '<', "$root/jawn" or die "$root/jawn: $!";
	<$fh>;
};
like $master, qr/&probe::watch_policy\(\)/, './jawn takes the pace from probe.pl';
like $master, qr/&probe::watch_delay\(/, './jawn asks probe.pl how long to wait before the next probe';
unlike $master, qr/\+\+\s*\$tree_misses\s*>=\s*2\b/, './jawn no longer calls the tree down after two misses';

done_testing();
