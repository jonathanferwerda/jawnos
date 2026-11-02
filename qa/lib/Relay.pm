package Relay;

# The l4 fence hole: a unix socket that both namespaces can see.
#
# The QA tree runs in its own net namespace, so its port is reachable only on
# that namespace's loopback. `adb reverse` connects to the *host's* 127.0.0.1,
# which is a different loopback, so the emulator's WebView can never reach the
# QA house - it sits on android_asset/splash.html.
#
# Unix sockets are filesystem objects, not network interfaces, so a relay socket
# placed in the run root is visible from inside the namespace and from the host.
# The path must NOT be under /tmp: the fence mounts a private tmpfs there, so a
# socket in /tmp exists twice and the two ends never meet. That is the mistake
# this module refuses to make.
#
#   upstream   (inside the netns)  unix socket  ->  https://127.0.0.1:<port>
#   downstream (on the host)       127.0.0.1:<port> -> unix socket
#
# Ports are the same number on both sides on purpose: the instance's port is
# free on the host because the instance lives in another net namespace, so
# `adb reverse tcp:P tcp:P` and the ticket URL need no rewriting.
#
# The relay is a byte pump attached to the QA instance: qa/run.pl's audit still
# proves no instance process references the live database, and the HTTP hop
# keeps the QA tree's own session/ticket gate. Nothing here listens on 0.0.0.0
# and nothing here adds a route to the LAN.

use strict;
use warnings;

use Cwd qw(abs_path);
use File::Basename qw(basename dirname);
use IO::Select;
use IO::Socket::INET;
use IO::Socket::UNIX;
use POSIX ();
use Socket ();

our $VERSION = '1';

my $BLOCK = 65536;

# ---------------------------------------------------------------------------
# the path rule
# ---------------------------------------------------------------------------

# A socket path the fence can actually share. Refusals are load-bearing:
#   * /tmp is a private tmpfs inside the fence - the host and the instance each
#     get their own /tmp, so a relay there is two dead sockets with one name.
#   * the live repo is bind-mounted read-only, and a socket is a write.
sub check_socket_path {
	my ($path, %opt) = @_;
	die "Relay: no socket path\n" unless defined $path && length $path;

	my $dir = dirname($path);
	my $real_dir = abs_path($dir);
	die "Relay: socket directory $dir does not exist\n" unless defined $real_dir;
	my $real = "$real_dir/" . basename($path);

	die "Relay: $real is under /tmp, which the QA fence makes a private tmpfs;"
		. " put the socket in the run root\n"
		if $real_dir eq '/tmp' || index($real_dir, '/tmp/') == 0;

	for my $dir (@{ $opt{'forbid'} || [] }) {
		next unless defined $dir && length $dir;
		my $live = abs_path($dir) || $dir;
		die "Relay: $real is inside $live, which the fence binds read-only;"
			. " choose a path in the QA run root\n"
			if $real eq $live || index($real, "$live/") == 0;
	}

	die 'Relay: socket path is ' . length($real) . ' bytes;'
		. " unix sockets are limited to about 107, pick a shorter run root\n"
		if length($real) > 100;

	return $real;
}

sub socket_path {
	my ($dir, $name, $port) = @_;
	$name = 'relay' unless defined $name && length $name;
	$name =~ s/[^A-Za-z0-9_-]//g;
	return "$dir/$name-$port.sock";
}

# ---------------------------------------------------------------------------
# the listeners
# ---------------------------------------------------------------------------

# Inside the netns: listen on the shared unix socket, forward to the QA port.
sub run_upstream {
	my (%opt) = @_;
	my $path = check_socket_path($opt{'socket'}, forbid => $opt{'forbid'});
	unlink $path if -S $path;
	die "Relay: $path exists and is not a socket\n" if -e $path;

	my $listen = IO::Socket::UNIX->new(
		Type => Socket::SOCK_STREAM(),
		Local => $path,
		Listen => 64,
	) or die "Relay: cannot listen on $path: $!\n";
	chmod 0600, $path;

	my $port = $opt{'port'} or die "Relay: upstream needs a target port\n";
	_log($opt{'log'}, "upstream $path -> 127.0.0.1:$port");
	return _serve($listen, sub {
		return IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => $port,
			Proto => 'tcp',
			Timeout => 10,
		);
	}, \%opt, $path);
}

# On the host: listen on 127.0.0.1 only, forward into the shared unix socket.
sub run_downstream {
	my (%opt) = @_;
	my $path = check_socket_path($opt{'socket'}, forbid => $opt{'forbid'});
	my $port = $opt{'port'} or die "Relay: downstream needs a listen port\n";

	my $listen = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Proto => 'tcp',
		Listen => 64,
		ReuseAddr => 1,
	) or die "Relay: cannot listen on 127.0.0.1:$port: $!\n";

	_log($opt{'log'}, "downstream 127.0.0.1:$port -> $path");
	return _serve($listen, sub {
		return IO::Socket::UNIX->new(
			Type => Socket::SOCK_STREAM(),
			Peer => $path,
			Timeout => 10,
		);
	}, \%opt);
}

# Accept and fork one bridge per connection. The listener exits when the
# process that started it is gone, so a crashed harness cannot leave a socket
# accepting connections into a dead instance.
sub _serve {
	my ($listen, $connect, $opt, $path) = @_;

	my $parent = $opt->{'parent'} || getppid();
	my $log = $opt->{'log'};
	$listen->blocking(0);
	my $sel = IO::Select->new($listen);

	while (getppid() == $parent) {
		my @ready = $sel->can_read(1);
		next unless @ready;
		my $client = $listen->accept();
		next unless $client;

		my $upstream = $connect->();
		unless ($upstream) {
			_log($log, "connect failed: $!");
			close $client;
			next;
		}

		$client->blocking(0);
		$upstream->blocking(0);

		my $pid = fork();
		if (!defined $pid) {
			_log($log, "fork failed: $!");
			close $client;
			close $upstream;
			next;
		}
		if (!$pid) {
			close $listen;
			_bridge($client, $upstream, getppid());
			POSIX::_exit(0);
		}
		close $client;
		close $upstream;
		while (waitpid(-1, POSIX::WNOHANG()) > 0) { }
	}

	close $listen;
	unlink $path if defined $path;
	return 0;
}

# ---------------------------------------------------------------------------
# the byte pump
# ---------------------------------------------------------------------------

# Both directions at once, half-closes propagated, so a request/response pair
# finishes instead of deadlocking on a client that shuts down its write side.
sub _bridge {
	my ($a, $b, $parent) = @_;

	my %sock = (fileno($a) => $a, fileno($b) => $b);
	my %peer = (fileno($a) => $b, fileno($b) => $a);
	my %read = (fileno($a) => 1, fileno($b) => 1);
	my %pending;    # fd => buffer still to write to that socket
	my %write_end;  # fd => 1 once the write side has been shut down

	while (1) {
		last if $parent && getppid() != $parent;
		my @writable = grep { length $pending{$_} } keys %pending;
		my @readable = keys %read;
		last unless @readable || @writable;

		my ($r, $w) = IO::Select->select(
			(@readable ? IO::Select->new(@sock{@readable}) : undef),
			(@writable ? IO::Select->new(@sock{@writable}) : undef),
			undef,
			5,
		);
		next unless $r || $w;

		for my $s (@{ $r || [] }) {
			my $fd = fileno($s);
			my $n = sysread($s, my $buf, $BLOCK);
			if (!defined $n) {
				next if $!{'EAGAIN'} || $!{'EWOULDBLOCK'} || $!{'EINTR'};
				return;    # a broken socket ends the pair
			}
			if ($n == 0) {
				delete $read{$fd};
				my $to = $peer{$fd};
				_shut($to, \%write_end) unless length $pending{fileno($to)};
				next;
			}
			my $to = $peer{$fd};
			$pending{fileno($to)} = ($pending{fileno($to)} // '') . $buf;
		}

		for my $s (@{ $w || [] }) {
			my $fd = fileno($s);
			my $buf = $pending{$fd} // '';
			next unless length $buf;
			my $n = syswrite($s, $buf);
			if (!defined $n) {
				next if $!{'EAGAIN'} || $!{'EWOULDBLOCK'} || $!{'EINTR'};
				return;
			}
			substr($buf, 0, $n, '');
			if (length $buf) {
				$pending{$fd} = $buf;
			}
			else {
				delete $pending{$fd};
				# the source has finished and its bytes are delivered
				_shut($s, \%write_end) unless $read{fileno($peer{$fd})};
			}
		}
	}
	return 1;
}

sub _shut {
	my ($s, $done) = @_;
	my $fd = fileno($s);
	return if $done->{$fd};
	$done->{$fd} = 1;
	shutdown($s, Socket::SHUT_WR());
}

sub _log {
	my ($path, $line) = @_;
	return unless defined $path && length $path;
	if (open(my $fh, '>>', $path)) {
		printf $fh "%s\t%s\n", scalar POSIX::strftime('%Y-%m-%dT%H:%M:%S', localtime), $line;
		close $fh;
	}
}

# ---------------------------------------------------------------------------
# processes
# ---------------------------------------------------------------------------

# Fork an exec'd listener, so the child carries none of the caller's END blocks
# or state, and dies when the caller is gone (the parent check above).
sub _spawn {
	my ($mode, %opt) = @_;
	my $path = $opt{'socket'};
	my $port = $opt{'port'};

	my $pid = fork();
	die "Relay: fork: $!\n" unless defined $pid;
	return $pid if $pid;

	POSIX::setsid();
	if ($opt{'log'}) {
		open(STDOUT, '>>', $opt{'log'}) or POSIX::_exit(127);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(127);
	}
	else {
		open(STDOUT, '>', '/dev/null') or POSIX::_exit(127);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(127);
	}
	exec($^X, '-I', dirname(abs_path(__FILE__)), '-MRelay', '-e',
		'exit Relay::cli(@ARGV)', $mode,
		'--socket', $path, '--port', $port, '--parent', getppid());
	POSIX::_exit(127);
}

sub spawn_upstream   { _spawn('up',   @_) }
sub spawn_downstream { _spawn('down', @_) }

sub stop {
	my ($pid, $socket) = @_;
	return 0 unless $pid;
	# spawned with setsid(), so the pid is also its process group: killing the
	# group takes the per-connection bridges with it. A CLI listener started by
	# a shell is not a leader - then only its pid is killed, never a group that
	# happens to share the number.
	kill 'KILL', -$pid if getpgrp($pid) == $pid;
	kill 'KILL', $pid;
	waitpid($pid, 0);
	unlink $socket if defined $socket && length $socket;
	return 1;
}

# ---------------------------------------------------------------------------
# command line (qa/android/run.sh starts the host half this way)
# ---------------------------------------------------------------------------

sub cli {
	my (@argv) = @_;
	my $usage = "usage: Relay.pm up|down --socket PATH --port N [--log PATH] [--parent PID]\n";
	my $mode = shift @argv;
	die $usage unless defined $mode && ($mode eq 'up' || $mode eq 'down');
	my %opt;
	while (@argv) {
		my $key = shift @argv;
		die $usage unless $key =~ /^--(socket|port|log|parent)$/;
		my $value = shift @argv;
		die $usage unless defined $value;
		$opt{$1} = $value;
	}
	die $usage unless $opt{'socket'} && $opt{'port'};

	my $code = eval {
		$mode eq 'up' ? run_upstream(%opt) : run_downstream(%opt);
	};
	if (my $err = $@) {
		print STDERR $err;
		return 1;
	}
	return $code;
}

1;
