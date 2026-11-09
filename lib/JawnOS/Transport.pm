package JawnOS::Transport;

# Where the master's private control surfaces live, and how a client reaches
# them. Native POSIX keeps the UNIX sockets; portable/Windows uses loopback TCP.
# The wire protocols do not change: control and log are one JSON line each way,
# the process watch and the app sockets are a length-prefixed Sereal record, and
# the alarm is one JSON line. This module only picks the address and carries
# the token.
#
# The worker-to-worker surfaces are here too: the alarm poke, the memory duty
# socket, the websocket worker's per-app fan-out and the mail fan-out. On TCP a
# single ws port carries every app (the payload names its app), so the offset
# table is fixed rather than one port per app name.
#
# The tree's stop channel lives here as well. Windows cannot signal a child
# cleanly (the runner's stop is TerminateProcess), so the master asks the tree
# to leave over a socket it serves, the same way it asks itself to restart over
# the control socket.
#
# The master owns two small files under ~/.president:
#
#   transport_base    working_port (or port) the transport offsets are based on
#   transport_token   a per-boot secret; 0600; required on every TCP request
#
# A client reads both, so restart.pl, a worker and the error watch all reach the
# same listener without an environment handshake. UNIX mode ignores them.

use strict;
use warnings;

use Socket ();
use JawnOS::Platform ();

my %KIND = (
	control => { offset => 7, file => 'control' },
	log     => { offset => 8, file => 'log' },
	watch   => { offset => 9, file => '.process_watch', home => 1 },
	alarm   => { offset => 10, file => 'alarm' },
	memory  => { offset => 11, file => 'memory' },
	ws      => { offset => 12, file => 'ws' },
	mailws  => { offset => 13, file => 'ws/mailws' },
	tree    => { offset => 14, file => 'tree' },
);

# The highest offset the base has to leave room for. set_base refuses a base
# that would push any listener past 65535.
my $MAX_OFFSET = (sort { $b <=> $a } map { $_->{'offset'} } values %KIND)[0];

sub tcp { return JawnOS::Platform::transport() eq 'tcp' ? 1 : 0 }

sub base_file  { return JawnOS::Platform::data_dir() . '/transport_base' }
sub token_file { return JawnOS::Platform::data_dir() . '/transport_token' }

sub _read_file {
	my ($path) = @_;
	return '' unless defined $path && -f $path;
	open(my $fh, '<', $path) or return '';
	my $text = do { local $/; <$fh> };
	close $fh;
	$text = '' unless defined $text;
	$text =~ s/\s+\z//;
	return $text;
}

sub _write_file {
	my ($path, $text) = @_;
	return 0 unless defined $path && length $path;
	require File::Basename;
	require File::Path;
	require Fcntl;
	File::Path::make_path(File::Basename::dirname($path));
	my $flags = Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_TRUNC();
	sysopen(my $fh, $path, $flags, 0600) or return 0;
	binmode($fh);
	my $ok = print {$fh} $text;
	close $fh;
	chmod 0600, $path;
	return $ok ? 1 : 0;
}

# The base is the manager's working port when config.json names one; otherwise
# the locker port, and finally the house default. The master writes it before
# the tree starts, so the tree and every client read one value.
sub base {
	my $base = _read_file(base_file());
	$base = $ENV{'JAWNOS_TRANSPORT_BASE'}
		unless defined $base && length $base && $base =~ /^\d+$/;
	$base = 45545 unless defined $base && $base =~ /^\d+$/ && $base > 1024;
	return int($base);
}

sub set_base {
	my ($base) = @_;
	return 0 unless defined $base && $base =~ /^\d+$/ && $base > 1024
		&& $base + $MAX_OFFSET <= 65535;
	$ENV{'JAWNOS_TRANSPORT_BASE'} = int($base);
	return _write_file(base_file(), int($base) . "\n");
}

sub port_for {
	my ($kind) = @_;
	my $spec = $KIND{$kind} or return undef;
	my $port = base() + $spec->{'offset'};
	return ($port > 1024 && $port <= 65535) ? $port : undef;
}

sub path_for {
	my ($kind) = @_;
	my $spec = $KIND{$kind} or return undef;
	my $home = JawnOS::Platform::home();
	my $root = $spec->{'home'} ? $home : JawnOS::Platform::data_dir();
	return length($root) ? "$root/$spec->{'file'}" : "./$spec->{'file'}";
}

# Which listener a filesystem path names. The workers still compute their paths
# (one per app, under the ws folder), so the sender maps a path it is handed
# back to a kind instead of guessing from the payload. Backslashes are accepted
# because a portable caller may hand over a Windows path.
sub kind_for_path {
	my ($path) = @_;
	return undef unless defined $path && length $path;
	(my $p = $path) =~ s{\\}{/}g;
	return 'watch' if $p =~ m{(?:^|/)\.process_watch$};
	return 'memory' if $p =~ m{(?:^|/)memory$};
	return 'alarm' if $p =~ m{(?:^|/)alarm$};
	return 'mailws' if $p =~ m{(?:^|/)ws/mailws$};
	# ws is matched before tree: an app may be called "tree", and its path must
	# still name the shared ws port, not the stop channel.
	return 'ws' if $p =~ m{(?:^|/)ws/[^/]+$};
	return 'tree' if $p =~ m{(?:^|/)tree$};
	return undef;
}

sub label {
	my ($kind) = @_;
	return tcp() ? '127.0.0.1:' . (port_for($kind) // '?') : path_for($kind);
}

sub token {
	my $token = _read_file(token_file());
	return $token if defined $token && length $token;
	return $ENV{'JAWNOS_TRANSPORT_TOKEN'} || '';
}

sub write_token {
	my ($token) = @_;
	return 0 unless defined $token && length $token;
	return _write_file(token_file(), $token);
}

sub rotate_token {
	my $token = eval {
		require Crypt::PRNG;
		Crypt::PRNG::random_bytes_hex(32);
	};
	if (!defined $token || !length $token) {
		$token = join '', map { sprintf '%02x', int rand 256 } 1 .. 32;
	}
	write_token($token);
	$ENV{'JAWNOS_TRANSPORT_TOKEN'} = $token;
	return $token;
}

# A token comparison that does not return early on the first differing byte.
# Loopback is not a hostile network, but a restart is worth a constant time.
sub token_ok {
	my ($given) = @_;
	my $want = token();
	return 0 unless defined $given && length $given && length $want;
	return 0 unless length($given) == length($want);
	my $diff = 0;
	for my $i (0 .. length($want) - 1) {
		$diff |= ord(substr($given, $i, 1)) ^ ord(substr($want, $i, 1));
	}
	return $diff == 0 ? 1 : 0;
}

sub client_unix_socket {
	my ($path, %opt) = @_;
	return undef unless defined $path && length $path;
	require IO::Socket::UNIX;
	return IO::Socket::UNIX->new(Type => Socket::SOCK_STREAM(), Peer => $path);
}

sub client_socket {
	my ($kind, %opt) = @_;
	my $timeout = (defined $opt{'timeout'} && $opt{'timeout'} > 0) ? $opt{'timeout'} : 3;
	if (tcp()) {
		my $port = port_for($kind) or return undef;
		require IO::Socket::INET;
		return IO::Socket::INET->new(
			PeerAddr => '127.0.0.1',
			PeerPort => $port,
			Proto    => 'tcp',
			Timeout  => $timeout,
		);
	}
	my $path = $opt{'path'} || path_for($kind) or return undef;
	require IO::Socket::UNIX;
	return IO::Socket::UNIX->new(Type => Socket::SOCK_STREAM(), Peer => $path);
}

sub server_args {
	my ($kind, %opt) = @_;
	if (tcp()) {
		my $port = port_for($kind) or return undef;
		return { address => '127.0.0.1', port => $port };
	}
	my $path = $opt{'path'} || path_for($kind) or return undef;
	return { path => $path };
}

1;
