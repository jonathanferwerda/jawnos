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
# The prompts are rendered here, on the machine that owns the gateway, not on
# the phone: the phone sends words, the gateway sends 8 kHz PCM down the link.
# Rendering is cached by the words and the voice, so the second caller waits
# on nothing.
sub action_52002 {
	my $c = shift;
	my $voice = $c->param('voice') || '';
	my %clips;
	foreach my $key (qw(greeting prompt thanks)) {
		my $text = $c->param($key) || '';
		next unless length $text;
		my $raw = &sco_render()->render($text, $voice);
		$clips{$key} = $raw if $raw;
	}
	my $ms = $c->param('ms');
	my %record = (
		ms => ($ms && $ms =~ /^\d+$/) ? int($ms) : 20000,
		silence_ms => 1200,
		min_ms => 400,
	);
	$c->render(json => &sco_client()->call({
		cmd => 'arm',
		peer => $c->param('peer') || '',
		# the adapter to listen on: the gateway machine's own setting is the
		# default, and a caller that knows better can name it
		local => $c->param('local') || '',
		call_id => $c->param('call_id') || '',
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

1;
