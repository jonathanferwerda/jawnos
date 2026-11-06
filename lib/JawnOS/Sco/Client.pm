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
#
# The Phone app's ivr_machine names the same puck by its signatorial: a phone
# with no helper of its own reads it, finds the machine in remote_machines, and
# dials its sco_port. Resolution is settings and one roster read - no fork, no
# network - because every route that answers "where is the gateway?" builds one.
use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Socket::INET;
use IO::Select;
use Mojo::JSON qw(decode_json encode_json);

# One value for the house. sco_port and sco_token belong to the gateway, not to
# the device reading them, so a phone must read the device => 'all' row; a
# per-device misc_setting would miss it and answer with the defaults forever.
sub _house_setting {
	my ($setting) = @_;
	my $value = eval { &subs::setting_grabber({ app => 'misc', setting => $setting, device => 'all', benign => 1 }) };
	return $value if defined $value && length $value;
	# an older build stored these per device; keep reading that row until the
	# house one exists
	my $legacy = eval { &subs::misc_setting($setting) };
	return (defined $legacy && length $legacy) ? $legacy : '';
}

# The Phone app's IVR pane writes phone.ivr_machine as a house row too.
sub _ivr_machine {
	my $machine = eval { &subs::phone_ivr_grab('ivr_machine') };
	return $machine if defined $machine && length $machine;
	my $value = eval { &subs::setting_grabber({ app => 'phone', setting => 'ivr_machine', device => 'all', benign => 1 }) };
	return (defined $value && length $value) ? $value : '';
}

# A host this client can dial: a tailnet/MagicDNS name or a v4 address. The
# roster also carries rows whose ip is empty (a machine seen on its own
# manager port), and those cannot stand in for a gateway.
sub _usable_host {
	my ($host) = @_;
	return '' unless defined $host && length $host;
	return ($host =~ /^[A-Za-z0-9._-]+$/) ? $host : '';
}

# remote_machines by signatorial, then by ip - the same lookup the IVR pane
# uses, so a selected machine resolves to the same row it was shown from.
sub _machine_row {
	my ($machine) = @_;
	foreach my $column (qw(signatorial ip)) {
		my $row = eval { &subs::db_select('remote_machines', undef, { $column => $machine })->hashes->[0] };
		return $row if ref $row eq 'HASH' && length(&_usable_host($row->{'ip'}));
	}
	return undef;
}

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
	# this house points at. A caller that named a path means this machine.
	$self->_resolve() if !$self->{'host'} && !defined $args{'path'};
	return $self;
}

sub _resolve {
	my ($self) = @_;
	# An address named outright still wins: it is the older puck setting, and
	# an operator who filled it meant exactly that machine.
	my $named = &_house_setting('sco_gateway');
	if ($named =~ /^([A-Za-z0-9._-]+):(\d{1,5})$/) {
		$self->{'host'} = $1;
		$self->{'port'} = int($2);
		$self->{'token'} = &_house_setting('sco_token');
		return;
	}
	my $machine = &_ivr_machine();
	return unless length $machine;
	my $self_sig = eval { &subs::signatorial_designer() } || '';
	# the machine in front of you is the local socket, with no secret
	return if length $self_sig && $machine eq $self_sig;
	my $row = &_machine_row($machine);
	my $ip = ref $row eq 'HASH' ? &_usable_host($row->{'ip'}) : '';
	unless (length $ip) {
		# Falling back to the local socket here would answer "no gateway
		# socket" on a phone that was told which machine to use. Name the
		# machine instead, once, where the error is built.
		$self->{'note'} = 'the gateway machine ' . $machine
			. ' has no address in remote_machines';
		return;
	}
	my $port = &_house_setting('sco_port');
	$port = 45700 unless $port =~ /^\d{1,5}$/ && $port > 0 && $port < 65536;
	$self->{'host'} = $ip;
	$self->{'port'} = int($port);
	$self->{'token'} = &_house_setting('sco_token');
	$self->{'machine'} = $machine;
	return;
}

sub path { $_[0]->{'path'} }

sub remote {
	my ($self) = @_;
	return length($self->{'host'}) ? 1 : 0;
}

# The machine the IVR pane named, before the roster resolved it, for a log line.
sub machine { $_[0]->{'machine'} || '' }

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
	unless ($path && -S $path) {
		# a phone told to use another machine has a reason worth reading
		return (undef, { ok => 0, error => $self->{'note'} }) if length($self->{'note'} || '');
		return (undef, { ok => 0, error => 'no gateway socket' });
	}
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
