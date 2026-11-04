package JawnOS::Sco::Client;

# The web process's end of the SCO gateway socket.
#
# The gateway is one daemon per machine (perl/Sco.pl) holding a Bluetooth SCO
# link, so a request is a line of JSON in and a line of JSON back, the same
# shape as ~/.president/control. A caller that finds no socket (the gateway is
# not built or not running on this machine) gets undef and a reason rather
# than an exception, because "no gateway here" is an ordinary answer on a
# desktop without an adapter.
use strict;
use warnings;
use IO::Socket::UNIX;
use IO::Select;
use Mojo::JSON qw(decode_json encode_json);

sub new {
	my ($class, %args) = @_;
	my $path = $args{'path'};
	$path = &subs::home('~/.president/sco.sock') if !defined $path && defined &subs::home;
	return bless {
		path => $path || '',
		timeout => $args{'timeout'} || 6,
	}, $class;
}

sub path { $_[0]->{'path'} }

sub call {
	my ($self, $request) = @_;
	my $path = $self->{'path'};
	return { ok => 0, error => 'no gateway socket' } unless $path && -S $path;
	my $sock = IO::Socket::UNIX->new(Peer => $path, Type => SOCK_STREAM);
	return { ok => 0, error => 'gateway refused the connection' } unless $sock;
	$sock->autoflush(1);
	my $sel = IO::Select->new($sock);
	my $line = encode_json($request);
	print {$sock} $line . "\n";
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

1;
