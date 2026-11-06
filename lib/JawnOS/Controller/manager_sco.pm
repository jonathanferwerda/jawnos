package Manager;

# The SCO gateway's four faces: what it is doing, arm it for the next call,
# put it down, and the name a caller left.
#
# Nothing here touches Bluetooth. Each action is one line to the daemon on
# ~/.president/sco.sock (perl/Sco.pl), which owns the helper; a machine with
# no adapter and no helper answers "the SCO helper is not built on this
# machine" and that is the whole failure mode.
use strict;
use warnings;

# Required at call time, not compile time: the guard compiles a changed file on
# its own, without lib/ on @INC, and a controller that uses a lib module has to
# survive that (the app itself has lib/ loaded long before a route runs).
sub sco_client {
	require JawnOS::Sco::Client;
	return JawnOS::Sco::Client->new();
}

sub sco_render {
	require JawnOS::Sco::Render;
	return 'JawnOS::Sco::Render';
}

# GET /manager/sco/status
sub action_52001 {
	my $c = shift;
	$c->render(json => &sco_client()->call({ cmd => 'status' }));
}

# POST /manager/sco/arm
#
# The prompts are rendered on the machine that owns the gateway, not on the
# phone. A local arm renders here and sends the paths, as it always has; a
# remote one sends the words and the voice, because a path from this machine
# does not exist on the gateway (and a phone has no Piper either). Rendering is
# cached by the words and the voice, so the second caller waits on nothing.
sub action_52002 {
	my $c = shift;
	my $voice = $c->param('voice') || '';
	my %words;
	foreach my $key (qw(greeting prompt thanks)) {
		$words{$key} = $c->param($key) || '';
	}
	my $client = &sco_client();
	my %clips;
	unless ($client->remote()) {
		foreach my $key (keys %words) {
			next unless length $words{$key};
			my $raw = &sco_render()->render($words{$key}, $voice);
			$clips{$key} = $raw if $raw;
		}
	}
	my $ms = $c->param('ms');
	my %record = (
		ms => ($ms && $ms =~ /^\d+$/) ? int($ms) : 20000,
		# a name ends on this much pause, and only after this much speech
		silence_ms => 2000,
		min_ms => 400,
	);
	$c->render(json => $client->call({
		cmd => 'arm',
		peer => $c->param('peer') || '',
		# the adapter to listen on: the gateway machine's own setting is the
		# default, and a caller that knows better can name it
		local => $c->param('local') || '',
		call_id => $c->param('call_id') || '',
		words => \%words,
		voice => $voice,
		clips => \%clips,
		record => \%record,
	}));
}

# POST /manager/sco/cancel
sub action_52003 {
	my $c = shift;
	$c->render(json => &sco_client()->call({ cmd => 'cancel' }));
}

# GET /manager/sco/result
#
# What the phone polls after hanging up: the state, and the newest recording
# with the name it was filed under.
sub action_52004 {
	my $c = shift;
	my $status = &sco_client()->call({ cmd => 'status' });
	my ($latest) = @{ $status->{'recordings'} || [] };
	$c->render(json => {
		%{$status},
		recording => $latest || undef,
	});
}

# GET /manager/sco/recording
#
# The caller saying their name is a WAV in the gateway's own directory. The
# name is checked against a bare file name - no separators, no leading dot -
# so a crafted value cannot walk out of the directory.
sub action_52005 {
	my $c = shift;
	my $name = $c->param('name') || '';
	unless ($name =~ /^[A-Za-z0-9._-]+\.wav$/ && $name !~ /^\./) {
		$c->rendered(404);
		return;
	}
	my $file = &subs::home('~/.president/sco') . '/' . $name;
	unless (-s $file) {
		$c->rendered(404);
		return;
	}
	open(my $fh, '<', $file) or do { $c->rendered(404); return; };
	binmode $fh;
	local $/;
	my $bytes = <$fh>;
	close $fh;
	$c->res->headers->content_type('audio/wav');
	$c->res->headers->cache_control('no-store');
	$c->render(data => $bytes);
}


# POST /manager/sco/rtc
#
# The "Connect me" signalling hop. The browser's offer, its ICE candidates and
# the stop travel to the gateway daemon over the socket that already owns the
# call; the answer and the gateway's candidates come back on the phone's
# websocket, not in this reply, because they arrive after the offer has left.
sub action_52006 {
	my $c = shift;
	my $action = $c->param('action') || '';
	return $c->render(json => { ok => 0, error => 'unknown bridge action' })
		unless $action =~ /^(?:start|signal|stop)$/;
	my %message;
	if ($action eq 'signal') {
		my $sdp = $c->param('sdp') || '';
		my $candidate = $c->param('candidate') || '';
		if (length $sdp) {
			%message = (sdp => $sdp, type => ($c->param('sdp_type') || 'offer'));
		}
		elsif (length $candidate) {
			%message = (candidate => {
				candidate => $candidate,
				sdpMid => ($c->param('sdp_mid') || '0'),
				sdpMLineIndex => 0 + ($c->param('sdp_mline_index') || 0),
			});
		}
		else {
			return $c->render(json => { ok => 0, error => 'nothing to signal' });
		}
	}
	$c->render(json => &sco_client()->call({
		cmd => 'rtc',
		action => $action,
		message => \%message,
	}));
}

1;
