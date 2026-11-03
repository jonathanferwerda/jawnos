# tests-for: qa/lib/
# covers:    The l4 relay is a deliberate hole in the fence, so it gets the same kind of test as the fence itself: the refu...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../qa/lib", "qa/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use IO::Select;
use IO::Socket::INET;
use POSIX ();
use Time::HiRes qw(time sleep);

use Relay;
use Harness;

# The l4 relay is a deliberate hole in the fence, so it gets the same kind of
# test as the fence itself: the refusal, the default, and a prover that bytes
# actually travel both ways through a unix socket and a loopback port.
#
# Nothing here boots a tree or enters a namespace: a relay is two listeners and
# a byte pump, and that is exactly what is exercised.

my $repo = abs_path("$FindBin::Bin/..");

# The relay refuses /tmp (the fence makes it a private tmpfs), so this suite
# cannot use File::Temp's default. Under the nightly's systemd fence $HOME is
# read-only too, so prefer the QA root, which the unit leaves writable.
my $sandbox = tempdir('qa-relay-XXXXXX',
	DIR => ($ENV{'JAWNOS_QA_ROOT'} || $ENV{'HOME'} || '.'), CLEANUP => 1);
my $relay_dir = "$sandbox/relay";
make_path($relay_dir);

my @pids;

sub _alive {
	my ($pid) = @_;
	return 0 unless $pid;
	return kill(0, $pid) ? 1 : 0;
}

sub _free_port {
	my $s = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
		Listen => 1, ReuseAddr => 1);
	my $port = $s ? $s->sockport : 0;
	close $s if $s;
	return $port;
}

sub _wait_socket {
	my ($path, $seconds) = @_;
	my $deadline = time + ($seconds || 5);
	while (time < $deadline) {
		return 1 if -S $path;
		sleep 0.05;
	}
	return 0;
}

sub _connect {
	my ($port) = @_;
	my $deadline = time + 5;
	while (time < $deadline) {
		my $s = IO::Socket::INET->new(
			PeerAddr => '127.0.0.1', PeerPort => $port,
			Proto => 'tcp', Timeout => 2);
		return $s if $s;
		sleep 0.1;
	}
	return undef;
}

sub _read_exact {
	my ($sock, $want, $seconds) = @_;
	my $buf = '';
	my $sel = IO::Select->new($sock);
	my $deadline = time + ($seconds || 10);
	while (length($buf) < $want) {
		my $left = $deadline - time;
		last if $left <= 0;
		next unless $sel->can_read($left);
		my $n = sysread($sock, my $chunk, 65536);
		last unless $n;
		$buf .= $chunk;
	}
	return $buf;
}

sub _write_all {
	my ($sock, $data) = @_;
	my $off = 0;
	while ($off < length $data) {
		my $n = syswrite($sock, $data, length($data) - $off, $off);
		return 0 unless defined $n;
		$off += $n;
	}
	return 1;
}

END {
	kill 'KILL', @pids if @pids;
}

# ---------------------------------------------------------------------------
# the path rule
# ---------------------------------------------------------------------------
{
	my $err;
	eval { Relay::check_socket_path('/tmp/qa-relay/qa.sock') };
	$err = $@;
	like($err, qr/private tmpfs/, 'a socket under /tmp is refused (the fence makes /tmp private)');
	ok(!-e '/tmp/qa-relay/qa.sock', 'and nothing was created there');

	my $ok = eval { Relay::check_socket_path("$relay_dir/qa-21000.sock") };
	is($@, '', 'a socket in the run root is accepted') or diag($@);
	is($ok, abs_path($relay_dir) . '/qa-21000.sock', 'the accepted path is normalised');

	eval { Relay::check_socket_path("$repo/qa/qa-relay.sock", forbid => [$repo]) };
	$err = $@;
	like($err, qr/read-only/, 'a socket inside the live repo is refused');
}

# ---------------------------------------------------------------------------
# the Harness default: off unless asked for
# ---------------------------------------------------------------------------
{
	my $root = "$sandbox/qa-off";
	my $h = Harness->new(repo => $repo, root => $root);
	my $run = $h->run;
	is($h->relay_enabled(), 0, 'Harness relays nothing by default');
	ok(!-d "$run/relay", 'and creates no relay directory');
	eval { $h->relay_socket(21000) };
	like($@, qr/relay is off/, 'asking for a relay socket while off is refused');
	is($h->relay_start(), 0, 'relay_start while off is a no-op');
	ok($h->{'relay_pids'} && !keys %{ $h->{'relay_pids'} }, 'and starts no listener');

	my $audit = $h->audit();
	is($audit->{'ok'}, 1, 'the audit is clean while relay is off');
	is(scalar @{ $audit->{'live_opens'} }, 0, 'no live-database reference with relay off');
}

{
	my $root = "$sandbox/qa-on";
	my $h = Harness->new(repo => $repo, root => $root, relay => 1);
	my $run = $h->run;
	is($h->relay_enabled(), 1, 'relay => 1 turns the socket relay on');
	ok(-d "$run/relay", 'the run root gets its relay directory');
	$h->pick_ports();
	my $sock = $h->relay_socket($h->{'ports'}->{'working'});
	like($sock, qr{\Q$run\E/relay/qa-}, 'the socket lives in the run root');
	unlike($sock, qr{^/tmp/}, 'never in /tmp');

	my $state = $h->relay_state();
	ok($state->{'enabled'}, 'relay_state reports the option');
	is(scalar keys %{ $state->{'sockets'} }, 2, 'both the working and dock ports get a socket');
	is(scalar keys %{ $state->{'pids'} }, 0, 'no listener until boot()');

	my $audit = $h->audit();
	is($audit->{'ok'}, 1, 'the audit is clean with the relay option on');
	is(scalar @{ $audit->{'live_opens'} }, 0, 'still no live-database reference');

	$h->relay_stop();
	pass('relay_stop is safe when nothing was started');
	ok(!-e $sock, 'no stale socket file');
}

# ---------------------------------------------------------------------------
# bytes both ways: backend <- upstream(unix) <- downstream(loopback) <- client
# ---------------------------------------------------------------------------
{
	my ($target, $front) = (0, 0);
	for (1 .. 20) {
		$target = _free_port();
		$front  = _free_port();
		last if $target && $front && $target != $front;
	}
	bail_out('no two free loopback ports') unless $target && $front && $target != $front;

	# G: greet (backend -> client). E: echo until EOF (both ways, bulk).
	my $server = fork();
	die "fork: $!\n" unless defined $server;
	if (!$server) {
		my $ls = IO::Socket::INET->new(
			LocalAddr => '127.0.0.1', LocalPort => $target,
			Proto => 'tcp', Listen => 8, ReuseAddr => 1);
		POSIX::_exit(1) unless $ls;
		for (1 .. 6) {
			my $c = $ls->accept() or next;
			my $mode = '';
			last unless sysread($c, $mode, 1);
			if ($mode eq 'G') {
				syswrite($c, "S-from-backend\n");
			}
			elsif ($mode eq 'E') {
				while (1) {
					my $buf;
					my $n = sysread($c, $buf, 65536);
					last unless $n;
					my $off = 0;
					while ($off < $n) {
						my $w = syswrite($c, $buf, $n - $off, $off);
						POSIX::_exit(1) unless defined $w;
						$off += $w;
					}
				}
			}
			close $c;
		}
		POSIX::_exit(0);
	}
	push @pids, $server;

	my $sock = "$relay_dir/qa-$target.sock";
	my $up = Relay::spawn_upstream(socket => $sock, port => $target, log => "$sandbox/up.log");
	push @pids, $up;
	ok(_wait_socket($sock, 5), 'the upstream listener created its unix socket');

	my $down = Relay::spawn_downstream(socket => $sock, port => $front, log => "$sandbox/down.log");
	push @pids, $down;
	ok(_alive($down), 'the downstream listener is running');

	# backend -> client through both halves
	my $a = _connect($front);
	ok($a, 'a client reaches the host loopback port') or diag("front $front, target $target");
	if ($a) {
		_write_all($a, 'G');
		my $greeting = _read_exact($a, length "S-from-backend\n", 5);
		is($greeting, "S-from-backend\n", 'bytes travel from the backend to the client');
		close $a;
	}

	# client -> backend and back, with enough to cross the 64K chunks
	my $b = _connect($front);
	ok($b, 'a second client connects');
	if ($b) {
		my $payload = 'qa-relay-' . ('x' x 200_000) . "\n";
		ok(_write_all($b, 'E' . $payload), 'the client writes 200 KB');
		my $echo = _read_exact($b, length $payload, 15);
		is(length $echo, length $payload, 'the echoed payload has the same length');
		is($echo, $payload, 'and the same bytes: the relay is transparent both ways');
		close $b;
	}

	# stopping the listeners closes the hole
	Relay::stop($down, $sock);    # also unlinks the socket
	is(_alive($down), 0, 'the downstream listener is stopped');
	ok(!-e $sock, 'and its socket file is gone');
	Relay::stop($up);
	my $after = IO::Socket::INET->new(
		PeerAddr => '127.0.0.1', PeerPort => $front, Proto => 'tcp', Timeout => 1);
	ok(!$after, 'the host loopback port is refused once the relay is stopped');
	close $after if $after;

	@pids = grep { _alive($_) } @pids;
}

done_testing();
