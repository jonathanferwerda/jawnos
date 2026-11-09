# tests-for: lib/JawnOS/Transport.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Domain/Devicews.pm perl/Websocket.pl perl/Alarm.pl perl/President.pl lib/JawnOS/Manager/Core2_worker_boot.pm lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Sco/Client.pm
# covers:    the worker-to-worker tail over TCP: no source imports
#            IO::Socket::UNIX at compile time, and the memory, ws and alarm
#            clients reach a loopback listener with their token and payload.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file);
use File::Find ();
use File::Temp qw(tempdir);
use IO::Select;
use IO::Socket::INET;
use Mojo::JSON qw(decode_json);
use Sereal::Decoder ();
use JawnOSTest;
use JawnOS::Transport;

subs::preload('unix_socket_sender');
subs::preload('appt_alarm_setter');

my $sereal = Sereal::Decoder->new();

# ---------------------------------------------------------- the compile guard
# Windows has no IO::Socket::UNIX, so a compile-time import anywhere in the tree
# is a boot failure. The module itself, control.pl and the SCO client load it
# lazily; this is what keeps a new `use` from slipping back in.
my @bad;
File::Find::find({
	no_chdir => 1,
	wanted => sub {
		return unless /\.(?:pm|pl)$/;
		my $body = read_file($_);
		push @bad, $_ if defined $body && $body =~ /^use IO::Socket::UNIX;/m;
	},
}, "$FindBin::Bin/../lib", "$FindBin::Bin/../perl");
is_deeply(\@bad, [], 'no source file imports IO::Socket::UNIX at compile time');

my $sco = read_file("$FindBin::Bin/../lib/JawnOS/Sco/Client.pm");
like($sco, qr/^use Socket qw\(SOCK_STREAM\);/m, 'the SCO client takes SOCK_STREAM from Socket');
like($sco, qr/require IO::Socket::UNIX;/, 'the SCO client requires the UNIX module only when dialling');

# ---------------------------------------------------------- the TCP tail
my $dir = tempdir(CLEANUP => 1);
local $ENV{'HOME'} = $dir;
local $ENV{'JAWNOS_DATA_DIR'} = "$dir/data";
local $ENV{'JAWNOS_TRANSPORT'} = 'tcp';
local $ENV{'JAWNOS_TRANSPORT_BASE'} = '';
local $ENV{'JAWNOS_TRANSPORT_TOKEN'} = '';
local $gb::tmp_dir = $dir;

ok(JawnOS::Transport::tcp(), 'the tail runs in TCP mode');

sub listener {
	my $listener = IO::Socket::INET->new(
		LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
		Listen => 5, ReuseAddr => 1,
	) or die "listen: $!";
	return $listener;
}

sub accepted {
	my ($listener) = @_;
	my $select = IO::Select->new($listener);
	return undef unless $select->can_read(5);
	return $listener->accept;
}

sub frame {
	my ($socket) = @_;
	my $header = '';
	while (length($header) < 4) {
		my $got = sysread($socket, $header, 4 - length($header), length($header));
		return undef unless $got;
	}
	my $length = unpack('N', $header);
	my $body = '';
	while (length($body) < $length) {
		my $got = sysread($socket, $body, $length - length($body), length($body));
		return undef unless $got;
	}
	return $sereal->decode($body);
}

# memory: one Sereal frame with the duty and the token.
{
	my $listener = listener();
	ok(JawnOS::Transport::set_base($listener->sockport - 11), 'the memory port is set');
	JawnOS::Transport::write_token('secret');
	my $sent = subs::unix_socket_sender('memory', { duty => 'db_file_get' });
	ok($sent, 'the memory sender reports the frame went');
	my $client = accepted($listener);
	ok($client, 'the memory listener accepted the connection');
	my $msg = $client ? frame($client) : undef;
	is(ref $msg, 'HASH', 'the memory frame decodes');
	is($msg->{'duty'}, 'db_file_get', 'the memory duty survived the wire');
	is($msg->{'token'}, 'secret', 'the memory frame carries the token');
	close $client if $client;
	close $listener;
}

# ws: every app rides the one ws port, and the payload still names its app.
{
	my $listener = listener();
	ok(JawnOS::Transport::set_base($listener->sockport - 12), 'the ws port is set');
	JawnOS::Transport::write_token('secret');
	my $sent = subs::unix_socket_sender("$dir/ws/music", { app => 'music', message => 'hello' });
	ok($sent, 'the ws sender reports the frame went');
	my $client = accepted($listener);
	ok($client, 'the shared ws listener accepted the connection');
	my $msg = $client ? frame($client) : undef;
	is(ref $msg, 'HASH', 'the ws frame decodes');
	is($msg->{'app'}, 'music', 'the ws payload names its app');
	is($msg->{'token'}, 'secret', 'the ws frame carries the token');
	close $client if $client;
	close $listener;
}

# alarm: one JSON line, with the token in the payload rather than a prefix line.
{
	my $listener = listener();
	ok(JawnOS::Transport::set_base($listener->sockport - 10), 'the alarm port is set');
	JawnOS::Transport::write_token('secret');
	&subs::appt_alarm_setter({ timestamp => &subs::rightNow(), uuid => 'alarm-test' });
	my $client = accepted($listener);
	ok($client, 'the alarm listener accepted the poke');
	my $line = $client ? readline($client) : undef;
	my $poke = eval { decode_json($line || '') } || {};
	is($poke->{'uuid'}, 'alarm-test', 'the appointment reached the alarm');
	is($poke->{'__transport_token'}, 'secret', 'the alarm poke carries the token');
	close $client if $client;
	close $listener;
}

done_testing();
