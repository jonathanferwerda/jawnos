package Manager;

# The SCO gateway's five faces: what it is doing, arm it for the next call,
# put it down, and the name a caller left - plus which flow the call belongs
# to, sending it to voicemail now, and hanging it up.
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
#
# The gateway's own status, passed through untouched. The one answer this route
# shapes itself is "no gateway": a client that could not reach its puck (no
# socket, an address that does not dial, a token the gateway refused) returns
# only { ok => 0, error => ... }, and a panel that read the missing `state` as
# idle closed itself and drew no transcript - which reads as "the caller said
# nothing" when what happened is that this machine could not ask. Naming the
# failure keeps the panel up and says which machine did not answer.
sub action_52001 {
	my $c = shift;
	my %request = (cmd => 'status');
	my $number = $c->param('number') || '';
	$request{'number'} = $number if length $number;
	my $client = &sco_client();
	my $status = $client->call(\%request);
	unless (ref $status eq 'HASH' && defined $status->{'state'}) {
		my $why = ref $status eq 'HASH' ? ($status->{'error'} || '') : '';
		$status = {
			%{ ref $status eq 'HASH' ? $status : {} },
			ok => 0,
			state => 'unreachable',
			# an unreachable gateway has no lines to show, and the panel says so
			transcript => [],
			partial => '',
			gateway => $client->where(),
			transcript_note => &subs::ui('The gateway did not answer')
				. (length $why ? ': ' . $why : '.'),
		};
	}
	$c->render(json => $status);
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
	# One step list per flow, when the pane previews a house's flows: the daemon
	# merges each flow's words and clips on the machine with the voice, so this
	# route only carries the JSON through.
	my $flows_json = $c->param('flows') || '';
	my $flows;
	if (!ref $flows_json && length $flows_json) {
		require Mojo::JSON;
		$flows = eval { Mojo::JSON::decode_json($flows_json) };
	}
	elsif (ref $flows_json eq 'HASH') {
		$flows = $flows_json;
	}
	my %request = (
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
		# the music the caller waits through after the thanks; an arm that names
		# none keeps the saved choice
		hold => defined $c->param('hold') ? $c->param('hold') : &subs::phone_ivr_settings()->{'hold'},
	);
	$request{'flows'} = $flows if ref $flows eq 'HASH' && %{$flows};
	$c->render(json => $client->call(\%request));
}

# POST /manager/sco/flow
#
# Which flow this call belongs to. The phone knows the caller's kind and posts
# the bucket just before it answers; a flow key may be named instead. The daemon
# holds it until the link is accepted, and ignores it once the plan has started.
sub action_52009 {
	my $c = shift;
	my %request = (cmd => 'flow');
	my $bucket = $c->param('bucket') || '';
	my $flow = $c->param('flow') || '';
	$request{'bucket'} = $bucket if length $bucket;
	$request{'flow'} = $flow if length $flow;
	$c->render(json => &sco_client()->call(\%request));
}

# POST /manager/sco/voicemail
#
# The panel's Send to voicemail: the greeting plays and the message is recorded
# now, instead of after the rest of the flow.
sub action_52010 {
	my $c = shift;
	my %request = (cmd => 'voicemail');
	my $text = $c->param('text') || '';
	$request{'text'} = $text if length $text;
	$c->render(json => &sco_client()->call(\%request));
}

# POST /manager/sco/hangup
#
# The panel's hang up: the plan and the call are over.
sub action_52011 {
	my $c = shift;
	$c->render(json => &sco_client()->call({ cmd => 'hangup' }));
}

# POST /manager/sco/hold
#
# The app's call screen puts the caller on the house's music and takes them off
# it. `action=start|stop`; anything else counts as stop.
sub action_52008 {
	my $c = shift;
	my $action = ($c->param('action') || '') eq 'start' ? 'start' : 'stop';
	$c->render(json => &sco_client()->call({ cmd => 'hold', action => $action }));
}

# POST /manager/sco/say
#
# A person watching a screening types to the caller: the words are spoken on the
# gateway (the machine with the voice) and join the same transcript the caller's
# answer is read into.
sub action_52007 {
	my $c = shift;
	$c->render(json => &sco_client()->call({ cmd => 'say', text => $c->param('text') || '' }));
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
	my $file = &subs::home('~/.president/sco/kept') . '/' . $name;
	$file = &subs::home('~/.president/sco') . '/' . $name unless -s $file;
	# a pane on another machine asks the gateway, which holds the file
	unless (-s $file) {
		my $answer = &sco_client()->call({ cmd => 'recording', name => $name });
		unless ($answer && $answer->{'ok'} && length($answer->{'wav'} || '')) {
			$c->rendered(404);
			return;
		}
		require MIME::Base64;
		my $bytes = MIME::Base64::decode_base64($answer->{'wav'});
		$c->res->headers->content_type('audio/wav');
		$c->render(data => $bytes);
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


# GET /manager/sco/transcript
#
# The words a voicemail points at: the Chat note the phone filed when the call
# ended, by the uuid the kept index stored. The pane opens it beside the clip.
sub action_52012 {
	my $c = shift;
	$c->render(json => &phone_voicemail_transcript($c->param('uuid') || ''));
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
