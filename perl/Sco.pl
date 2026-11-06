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
# line - with the verbs the manager needs:
#
#   {"cmd":"status"}                     -> the state, the last recording, ...
#   {"cmd":"arm","peer":"..:..","clips":{"greeting":"/..raw", ...},
#    "words":{"greeting":"...", ...},"voice":"piper-a",
#    "record":{"ms":20000}}              -> spawn the helper and listen
#   {"cmd":"arm","flows":{"receptionist":{...},"night":{...}}}
#                                        -> one step list per flow; the call's
#                                           flow is chosen when it is answered
#   {"cmd":"flow","bucket":"unknown"}   -> which flow this call belongs to
#    or {"cmd":"flow","flow":"night"}      (settable before the link is up)
#   {"cmd":"voicemail","text":"..."}    -> send the call to voicemail now
#   {"cmd":"hangup"}                     -> end the plan and the call
#   {"cmd":"cancel"}                     -> drop the link and forget the plan
#   {"cmd":"ping"}                       -> {"ok":1,"pong":<time>}
#
# A phone has no clips to send, so it sends the words and the voice: this side
# renders only the entries it was not given a playable file for. A flow that
# carries `steps` gets the same treatment per flow, from its own words and
# clips.
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
require JawnOS::Sco::Render;

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
		# The phone's caller id is the only place the number exists; its status
		# poll carries it while it is fresh. An empty poll keeps the last one.
		my $number = ref $request eq 'HASH' ? ($request->{'number'} // '') : '';
		$gateway->note_caller($number) if length $number;
		return $gateway->status();
	}
	if ($cmd eq 'arm') {
		my %args = %{$request};
		delete $args{'cmd'};
		# Every flow gets its clips filled in here, on the machine that owns the
		# voice: a phone sends words, not paths, and a path rendered on the phone
		# does not exist on the gateway. A local manager's paths win.
		my $flows = $args{'flows'};
		if (ref $flows eq 'HASH' && %{$flows}) {
			my %built;
			foreach my $key (keys %{$flows}) {
				next unless defined $key && $key =~ /^[a-z0-9_]{1,30}$/;
				my $def = $flows->{$key};
				next unless ref $def eq 'HASH';
				my %flow = %{$def};
				my %words = map { $_ => ($flow{$_} // '') } qw(greeting prompt thanks voicemail);
				my $voice = $flow{'voice'} || '';
				$flow{'clips'} = &JawnOS::Sco::Render::merge_clips(
					(ref $flow{'clips'} eq 'HASH' ? $flow{'clips'} : {}),
					\%words, $voice);
				# merge_clips carries the three words the older plan spoke; a flow
				# may also use its voicemail greeting in its own steps
				my $vm = $flow{'clips'}->{'voicemail'} || '';
				unless (length $vm && -s $vm) {
					my $raw = &JawnOS::Sco::Render::render($words{'voicemail'}, $voice);
					$flow{'clips'}->{'voicemail'} = $raw if $raw;
				}
				$built{$key} = \%flow;
			}
			$args{'flows'} = \%built;
			# What a call with no word from the phone hears: the unknown
			# bucket's flow, which may be ring/reject (then there is no plan).
			unless (exists $args{'default_flow'}) {
				my $resolved = eval { &subs::phone_ivr_flow_for_bucket('unknown') };
				# a settings read that failed is not the same as `ring`: leave the
				# gateway's own default rather than deciding no plan runs
				$args{'default_flow'} = $resolved if defined $resolved;
			}
		}
		else {
			delete $args{'flows'};
			$args{'clips'} = &JawnOS::Sco::Render::merge_clips(
				$args{'clips'}, $args{'words'}, $args{'voice'});
		}
		return $gateway->arm(%args);
	}
	if ($cmd eq 'flow') {
		# Which flow this call belongs to. The phone knows the caller's kind (a
		# bucket) or names a flow outright; the socket holds it until the link
		# is accepted.
		my %args = ref $request eq 'HASH' ? %{$request} : ();
		my $key = defined $args{'flow'} ? $args{'flow'} : undef;
		unless (defined $key) {
			my $bucket = $args{'bucket'};
			$bucket = 'unknown'
				unless defined $bucket && $bucket =~ /^(?:unknown|blacklisted|self|friend|stranger|enemy)$/;
			my $resolved = eval { &subs::phone_ivr_flow_for_bucket($bucket) };
			return { ok => 0, error => 'cannot resolve the caller\'s flow' }
				unless defined $resolved;
			$key = $resolved;
		}
		return $gateway->set_flow($key);
	}
	if ($cmd eq 'voicemail') {
		my %args = ref $request eq 'HASH' ? %{$request} : ();
		delete $args{'cmd'};
		return $gateway->to_voicemail(%args);
	}
	if ($cmd eq 'hangup') {
		return $gateway->hangup();
	}
	if ($cmd eq 'hold') {
		my %args = %{$request};
		return $gateway->set_hold(on => ($args{'action'} || '') eq 'start' ? 1 : 0);
	}
	if ($cmd eq 'recording') {
		# the pane may be on another machine; the WAV lives here
		my %args = %{$request};
		my $name = $args{'name'} || '';
		return { ok => 0, error => 'bad name' }
			unless $name =~ /^[A-Za-z0-9._-]+\.wav$/ && $name !~ /^\./;
		my $dir = &subs::home('~/.president/sco');
		my $file = "$dir/kept/$name";
		$file = "$dir/$name" unless -s $file;
		return { ok => 0, error => 'no such recording' } unless -s $file;
		open(my $fh, '<', $file) or return { ok => 0, error => 'cannot open the recording' };
		binmode $fh;
		local $/;
		my $bytes = <$fh>;
		close $fh;
		require MIME::Base64;
		return { ok => 1, wav => MIME::Base64::encode_base64($bytes, '') };
	}
	if ($cmd eq 'say') {
		my %args = %{$request};
		delete $args{'cmd'};
		return $gateway->say_to_caller(%args);
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
