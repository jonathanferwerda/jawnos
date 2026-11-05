package JawnOS::Sco::Client;

# The web process's end of the SCO gateway socket.
#
# The gateway is one daemon per machine (perl/Sco.pl) holding a Bluetooth SCO
# link, so a request is a line of JSON in and a line of JSON back, the same
# shape as ~/.president/control. A caller that finds no socket (the gateway is
# not built or not running on this machine) gets undef and a reason rather
# than an exception, because "no gateway here" is an ordinary answer on a
# desktop without an adapter.
#
# The daemon need not be on this machine: when the house names a puck in the
# sco_gateway setting ("host:port"), the same line goes over TCP to the machine
# in the bag, and every line carries the token that machine requires. The phone
# still talks to the house and the house talks to the puck, so the flow and the
# prompts stay in one place and only the audio is local to the adapter.
use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Socket::INET;
use IO::Select;
use Mojo::JSON qw(decode_json encode_json);

sub new {
	my ($class, %args) = @_;
	my $path = $args{'path'};
	$path = &subs::home('~/.president/sco.sock') if !defined $path && defined &subs::home;
	my $self = bless {
		path => $path || '',
		timeout => $args{'timeout'} || 6,
		host => $args{'host'} || '',
		port => $args{'port'} || 0,
		token => $args{'token'} || '',
	}, $class;
	# A gateway on another machine is a setting, not an argument: every caller
	# (the routes, Reception.pl) asks for "the gateway" and gets whichever one
	# this house points at.
	if (!$self->{'host'} && !defined $args{'path'} && defined &subs::misc_setting) {
		my $remote = eval { &subs::misc_setting('sco_gateway') } || '';
		if ($remote =~ /^([A-Za-z0-9._-]+):(\d{1,5})$/) {
			$self->{'host'} = $1;
			$self->{'port'} = int($2);
			$self->{'token'} = eval { &subs::misc_setting('sco_token') } || '';
		}
	}
	return $self;
}

sub path { $_[0]->{'path'} }

sub remote {
	my ($self) = @_;
	return length($self->{'host'}) ? 1 : 0;
}

# Where the daemon is, for the pane and for a log line: a tailnet address when
# the puck owns the adapter, the local socket otherwise.
sub where {
	my ($self) = @_;
	return $self->{'host'} . ':' . $self->{'port'} if $self->remote();
	return $self->{'path'};
}

sub call {
	my ($self, $request) = @_;
	my ($sock, $error) = $self->remote() ? $self->_dial_tcp() : $self->_dial_unix();
	return $error if $error;
	$sock->autoflush(1);
	my $sel = IO::Select->new($sock);
	my %line = ref $request eq 'HASH' ? %{$request} : ();
	$line{'token'} = $self->{'token'} if length $self->{'token'};
	print {$sock} encode_json(\%line) . "\n";
	my $reply = '';
	my $deadline = time + $self->{'timeout'};
	while (1) {
		my $left = $deadline - time;
		last if $left <= 0;
		last unless $sel->can_read($left);
		my $read = sysread($sock, my $buf, 65536);
		last unless defined $read && $read > 0;
		$reply .= $buf;
		last if $reply =~ /\n/;
	}
	close $sock;
	$reply =~ s/\n.*//s;
	return { ok => 0, error => 'gateway did not answer' } unless length $reply;
	my $answer = eval { decode_json($reply) };
	return { ok => 0, error => 'gateway answered badly' } unless ref $answer eq 'HASH';
	return $answer;
}

sub _dial_unix {
	my ($self) = @_;
	my $path = $self->{'path'};
	return (undef, { ok => 0, error => 'no gateway socket' }) unless $path && -S $path;
	my $sock = IO::Socket::UNIX->new(Peer => $path, Type => SOCK_STREAM);
	return (undef, { ok => 0, error => 'gateway refused the connection' }) unless $sock;
	return ($sock);
}

sub _dial_tcp {
	my ($self) = @_;
	my $sock = IO::Socket::INET->new(
		PeerHost => $self->{'host'},
		PeerPort => $self->{'port'},
		Proto => 'tcp',
		Timeout => $self->{'timeout'},
	);
	return (undef, { ok => 0, error => 'gateway unreachable at ' . $self->where() }) unless $sock;
	return ($sock);
}

1;
