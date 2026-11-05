#!/usr/bin/perl

# The house's Bluetooth gateway: one SCO link, one call, a small JSON socket.
#
# Started by perl/President.pl on a machine where scripts/build_sco.pl has
# produced the helper (the laptop today, the puck in the bag tomorrow). The phone
# is the HFP Audio Gateway; this side is the Hands-Free unit, so the caller's
# voice arrives here and the prompts go back out on the same link.
#
# When the adapter is in the bag the house drives this same daemon over the
# tailnet: --listen HOST:PORT adds a network face, and --token names the secret
# every line on it must carry. The local socket is unchanged, so one machine
# still needs no secret, and the audio never crosses the network.
#
# The socket answers the shape ~/.president/control uses - one JSON object per
# line - with the five verbs the manager needs:
#
#   {"cmd":"status"}                     -> the state, the last recording, ...
#   {"cmd":"arm","peer":"..:..","clips":{"greeting":"/..raw", ...},
#    "record":{"ms":20000}}              -> spawn the helper and listen
#   {"cmd":"cancel"}                     -> drop the link and forget the plan
#   {"cmd":"ping"}                       -> {"ok":1,"pong":<time>}
use strict;
use warnings;
use lib './lib';
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Log;
use File::Path qw(make_path);
use File::Slurp qw(read_file);

require './perl/subroutines.pl';
require JawnOS::Sco::Gateway;

my $config_file = './config.json';
my $config = -e $config_file ? eval { decode_json(read_file($config_file)) } : {};
my $logfile = &subs::home(($config && $config->{'logfile'}) || '~/manager.log');
my $log = Mojo::Log->new(path => $logfile);

my $dir = &subs::home('~/.president/sco');
make_path($dir) unless -d $dir;
my $sock_path = &subs::home('~/.president/sco.sock');
unlink $sock_path if -e $sock_path;

my $gateway = JawnOS::Sco::Gateway->new();

# The network face is opt-in and fails closed: an address without a token would
# let any other device on the tailnet arm this gateway.
my ($tcp_host, $tcp_port, $token) = ('', 0, '');
my @args = @ARGV;
while (@args) {
	my $arg = shift @args;
	if ($arg eq '--listen') {
		my $addr = shift @args // '';
		$addr =~ /^([A-Za-z0-9._-]+):(\d{1,5})$/ or die "--listen wants HOST:PORT\n";
		($tcp_host, $tcp_port) = ($1, int($2));
	}
	elsif ($arg eq '--token') {
		$token = shift @args // '';
	}
	else {
		die "unknown argument: $arg\n";
	}
}
die "--listen needs --token\n" if $tcp_host && !length $token;

sub answer {
	my ($request) = @_;
	my $cmd = ref $request eq 'HASH' ? ($request->{'cmd'} || '') : '';
	if ($cmd eq 'status') {
		return $gateway->status();
	}
	if ($cmd eq 'arm') {
		my %args = %{$request};
		delete $args{'cmd'};
		return $gateway->arm(%args);
	}
	if ($cmd eq 'cancel') {
		return $gateway->cancel();
	}
	if ($cmd eq 'rtc') {
		my %args = %{$request};
		delete $args{'cmd'};
		return $gateway->rtc(\%args);
	}
	if ($cmd eq 'ping') {
		return { ok => 1, pong => time };
	}
	return { ok => 0, error => 'unknown command' };
}

# Both faces share one reader: the local socket has no secret, and a line that
# arrives on the tailnet must carry the token this daemon was started with.
sub serve {
	my ($stream, $remote) = @_;
	$stream->handle->autoflush(1);
	my $buffer = '';
	$stream->on(read => sub {
		my ($stream, $bytes) = @_;
		$buffer .= $bytes;
		while ($buffer =~ s/^(.*?)\n//) {
			my $line = $1;
			next unless $line =~ /\S/;
			my $request = eval { decode_json($line) };
			my $reply;
			if ($remote && (!ref $request || (($request->{'token'} // '') ne $token))) {
				$reply = { ok => 0, error => 'bad token' };
			}
			else {
				$reply = eval { answer($request) };
				$reply = { ok => 0, error => "gateway: $@" } unless ref $reply eq 'HASH';
			}
			$stream->write(encode_json($reply) . "\n");
		}
	});
	$stream->on(close => sub { $stream->close });
}

my $server = Mojo::IOLoop->server({ path => $sock_path } => sub {
	my ($loop, $stream) = @_;
	serve($stream, 0);
});

if ($tcp_host) {
	Mojo::IOLoop->server({ address => $tcp_host, port => $tcp_port } => sub {
		my ($loop, $stream) = @_;
		serve($stream, 1);
	});
	$log->info("sco gateway reachable at $tcp_host:$tcp_port");
	print "SCO gateway reachable at $tcp_host:$tcp_port\n";
}

$SIG{'TERM'} = sub { Mojo::IOLoop->stop };
$SIG{'INT'} = sub { Mojo::IOLoop->stop };
$SIG{'HUP'} = sub { Mojo::IOLoop->stop };

$log->info("sco gateway listening on $sock_path");
print "SCO gateway listening on $sock_path\n";
Mojo::IOLoop->start;

$gateway->cancel();
$gateway->write_status();
unlink $sock_path;
$log->info('sco gateway stopped');
