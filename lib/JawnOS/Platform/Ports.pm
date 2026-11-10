package JawnOS::Platform::Ports;

# Every port the house derives from one base, and every port a tunnel hub
# reserves, behind one seam. Linux keeps today's numbers exactly: the duty
# offsets, the peer overflow rule, the plain-WS loopback port and the private
# transport offsets are the same tables President.pl and Transport.pm used
# before they asked here.
#
# The tunnel range is config, not a hardcoded 50000-65000: tunnel_range reads
# tunnel_port_min/tunnel_port_max (default 50000-50127, 128 ports = 18 peers x
# 7 duties). reserve_tunnel_ports hands back the ports it chose or an
# exhaustion error; it never returns a port it could not check.
#
# This is a pure seam: no database and no log. A caller that needs a row
# checked passes `taken`; the controller's closure owns the query. The Linux
# in_use probe reads /proc/net/tcp{,6}; every other platform falls back to a
# loopback bind probe, so a caller never depends on netstat or ss output.

use strict;
use warnings;

use Socket ();

use Exporter 'import';
our @EXPORT_OK = qw(
	base valid_base offset port_for env_name duty_env_names max_offset
	in_use can_bind tunnel_range reserve_tunnel_ports
);

my $DEFAULT_BASE = 45545;
my $MAX_PORT     = 65535;
my $MIN_BASE     = 1024;

# The base-relative duties President exports as PORT_*. `coms` is the teletype
# websocket, one above `bestow`; `bell` and `alarm` are the same listener under
# the names President and the transport each use.
my %DUTY_OFFSET = (
	ahoy     => 0,
	ws       => 1,
	watch    => 2,
	bestow   => 3,
	tty      => 3,
	coms     => 4,
	bell     => 5,
	alarm    => 5,
	peer     => 6,
	ws_plain => 101,
);

my %DUTY_ENV = (
	ahoy     => 'PORT_AHOY',
	ws       => 'PORT_MSG',
	watch    => 'PORT_ARM',
	bestow   => 'PORT_BESTOW',
	tty      => 'PORT_BESTOW',
	coms     => 'PORT_COMS',
	bell     => 'PORT_BELL',
	alarm    => 'PORT_BELL',
	peer     => 'PORT_PEER',
	ws_plain => 'PORT_WS_PLAIN',
	dock     => 'PORT_DOCK',
	board    => 'PORT_BOARD',
);

# The order gb.pl has always published: the ports a tunnel reservation may not
# take because this tree already holds them.
my @DUTY_ENV_ORDER = qw(
	PORT_AHOY PORT_MSG PORT_BELL PORT_ARM PORT_BESTOW PORT_DOCK PORT_COMS
);

# The master's private worker transport. These live on the same base as the
# duties, which is why one base has to leave room for the highest one.
my %TRANSPORT_OFFSET = (
	control => 7,
	log     => 8,
	watch   => 9,
	alarm   => 10,
	memory  => 11,
	ws      => 12,
	mailws  => 13,
	tree    => 14,
);

my $DUTY_MAX_OFFSET      = 6;   # ws_plain is the +101 special case, not a base guard
my $TRANSPORT_MAX_OFFSET = 14;

my $TUNNEL_MIN = 50000;
my $TUNNEL_MAX = 50127;

# The base a caller starts from. President passes working_port and random => 1:
# an absent (or false) working_port picks a fresh base, a working_port below
# 60000 is used as-is, and anything else falls back to 45545. The ceiling and
# default are options because manager_killer starts at 3000. A non-numeric
# value falls back instead of becoming a numeric zero.
sub base {
	my (%opt) = @_;
	my $default = defined $opt{'default'} ? $opt{'default'} : $DEFAULT_BASE;
	my $ceiling = defined $opt{'ceiling'} ? $opt{'ceiling'} : 60000;
	my $given   = $opt{'working_port'};

	if ($given) {
		return int($given) if $given =~ /^[0-9]+$/ && $given < $ceiling;
		return $default;
	}
	return $default unless $opt{'random'};

	my $rand = $opt{'rand'} || sub { rand() };
	my $number = 0;
	until ($number > $MIN_BASE && $number < 60000) {
		$number = int($rand->() * 59999);
	}
	return $number;
}

# A base is valid when every offset a caller will add still lands on a real
# port: > 1024 and base + max_offset <= 65535. The default guard is the
# transport's, the longest table; a shorter table passes its own max_offset
# (jawn's config helper has always used 9).
sub valid_base {
	my ($value, %opt) = @_;
	my $max = defined $opt{'max_offset'} ? $opt{'max_offset'}
		: (defined $opt{'table'} ? max_offset(table => $opt{'table'}) : $TRANSPORT_MAX_OFFSET);
	my $min = defined $opt{'min'} ? $opt{'min'} : $MIN_BASE;
	return 0 unless defined $value && $value =~ /^[0-9]+$/;
	return 0 unless $value > $min;
	return 0 if $value + $max > $MAX_PORT;
	return 1;
}

# The offset table named by kind. `table` defaults to the duties; the transport
# asks with table => 'transport' because watch/alarm/ws mean different offsets
# in each table.
sub offset {
	my ($kind, %opt) = @_;
	return undef unless defined $kind && length $kind;
	my $table = defined $opt{'table'} ? $opt{'table'} : 'duty';
	my $map = $table eq 'transport' ? \%TRANSPORT_OFFSET : \%DUTY_OFFSET;
	return exists $map->{$kind} ? $map->{$kind} : undef;
}

# The highest offset the base must leave room for. ws_plain is excluded from
# the duty answer: it is derived from the ws port, not added to the base.
sub max_offset {
	my (%opt) = @_;
	my $table = defined $opt{'table'} ? $opt{'table'} : 'duty';
	return $table eq 'transport' ? $TRANSPORT_MAX_OFFSET : $DUTY_MAX_OFFSET;
}

# A kind's env name, for the readers that compose PORT_* lists. `tty` and
# `alarm` answer with the names President actually exports.
sub env_name {
	my ($kind) = @_;
	return undef unless defined $kind && length $kind;
	return $DUTY_ENV{$kind};
}

sub duty_env_names {
	return [ @DUTY_ENV_ORDER ];
}

# The port a kind lands on. The peer keeps its historical overflow: base + 6
# past 65535 is pulled back by 12. The plain ws port is derived from the ws
# port (the caller passes it when development has collapsed ws onto the base)
# and is pulled back by 100 when +100 would cross 60000.
sub port_for {
	my ($kind, %opt) = @_;
	return undef unless defined $kind && length $kind;
	my $table = defined $opt{'table'} ? $opt{'table'} : 'duty';
	my $base  = defined $opt{'base'} ? $opt{'base'} : base();
	return undef unless defined $base && $base =~ /^[0-9]+$/ && $base > 0;

	if ($table eq 'transport') {
		my $off = offset($kind, table => 'transport');
		return undef unless defined $off;
		my $port = $base + $off;
		return ($port > $MIN_BASE && $port <= $MAX_PORT) ? $port : undef;
	}

	my $off = offset($kind, table => 'duty');
	return undef unless defined $off;

	if ($kind eq 'peer') {
		my $port = $base + $off;
		$port -= 12 if $port > $MAX_PORT;
		return $port;
	}
	if ($kind eq 'ws_plain') {
		my $ws = defined $opt{'ws_port'} ? $opt{'ws_port'} : $base + offset('ws');
		return undef unless defined $ws && $ws =~ /^[0-9]+$/;
		my $port = $ws + 100;
		$port = $ws - 100 if $port > 60000;
		return $port;
	}

	my $port = $base + $off;
	return ($port > $MIN_BASE && $port <= $MAX_PORT) ? $port : undef;
}

# Bind and release the address the listener would use. This is the tunnel hub's
# own probe, so a port held by another worker is recognised the same way.
sub can_bind {
	my ($addr, $port) = @_;
	$addr = '127.0.0.1' unless defined $addr && length $addr;
	return 0 unless defined $port && $port =~ /^[0-9]+$/ && $port > 0 && $port <= $MAX_PORT;
	require IO::Socket::INET;
	my $socket = IO::Socket::INET->new(
		LocalAddr => $addr,
		LocalPort => $port,
		Proto     => 'tcp',
		Listen    => 5,
		ReuseAddr => 1,
	);
	return 0 unless $socket;
	close $socket;
	return 1;
}

# Every local TCP port Linux currently has a socket on, any state - the same
# breadth `ss -t` gave the old tunnel scan. undef means /proc could not answer.
sub _linux_tcp_ports {
	return undef unless $^O eq 'linux';
	my %ports;
	my $read = 0;
	foreach my $file ('/proc/net/tcp', '/proc/net/tcp6') {
		open(my $fh, '<', $file) or next;
		$read = 1;
		foreach my $line (<$fh>) {
			next unless $line =~ /^\s*\d+:\s+[0-9A-Fa-f]+:([0-9A-Fa-f]{4})\s/;
			$ports{hex($1)} = 1;
		}
		close $fh;
	}
	return $read ? \%ports : undef;
}

# Is anything holding this port? Linux answers from /proc; any other platform,
# or a Linux without /proc, asks whether the loopback address can still bind.
sub in_use {
	my ($port, %opt) = @_;
	return 0 unless defined $port && $port =~ /^[0-9]+$/ && $port > 0 && $port <= $MAX_PORT;
	unless ($opt{'force_probe'}) {
		my $ports = _linux_tcp_ports();
		return $ports->{ int($port) } ? 1 : 0 if $ports;
	}
	return can_bind('127.0.0.1', int($port)) ? 0 : 1;
}

# The configured tunnel range. A malformed pair falls back to the defaults
# rather than handing allocation an impossible span.
sub tunnel_range {
	my (%config) = @_;
	my $min = $config{'tunnel_port_min'};
	my $max = $config{'tunnel_port_max'};
	$min = $TUNNEL_MIN unless defined $min && $min =~ /^[0-9]+$/;
	$max = $TUNNEL_MAX unless defined $max && $max =~ /^[0-9]+$/;
	$min = int($min);
	$max = int($max);
	return [ $TUNNEL_MIN, $TUNNEL_MAX ]
		unless $min > $MIN_BASE && $max <= $MAX_PORT && $min <= $max;
	return [ $min, $max ];
}

# Reserve `count` ports inside the tunnel range. A port is skipped when the
# tree already exports it (`held`), when the caller's `taken` says a tunnel row
# still owns it, or when it is already in use. The scan rotates from a random
# point so restarts do not pile every peer on the lowest ports; `start` pins it
# for a test. Fewer free ports than asked for is an error, never a bogus last
# candidate.
sub reserve_tunnel_ports {
	my ($count, %opt) = @_;
	$count = (defined $count && $count =~ /^[0-9]+$/) ? int($count) : 0;
	return ([], undef) if $count == 0;

	my $range = ref $opt{'range'} eq 'ARRAY'
		? $opt{'range'}
		: tunnel_range(%{ $opt{'config'} || {} });
	my ($min, $max) = @{$range};
	return ([], 'tunnel port range is invalid')
		unless defined $min && defined $max && $min <= $max;

	my %held;
	foreach my $port (@{ $opt{'held'} || [] }) {
		next unless defined $port && $port =~ /^[0-9]+$/;
		$held{ int($port) } = 1;
	}

	my $taken = $opt{'taken'};
	my $probe = $opt{'in_use'} || sub { in_use($_[0]) };

	my @free;
	for my $port ($min .. $max) {
		next if $held{$port};
		next if $taken && $taken->($port);
		next if $probe->($port);
		push @free, $port;
	}

	if (@free < $count) {
		return ([], "tunnel ports exhausted: need $count in $min-$max, only "
			. scalar(@free) . ' free');
	}

	my $start;
	if (defined $opt{'start'}) {
		$start = int($opt{'start'}) % scalar(@free);
	}
	else {
		my $rand = $opt{'rand'} || sub { rand() };
		$start = int($rand->() * scalar(@free)) % scalar(@free);
	}
	my @picked = (@free[ $start .. $#free ], @free[ 0 .. $start - 1 ]);
	splice @picked, $count;
	return (\@picked, undef);
}

1;
