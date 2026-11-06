#!/usr/bin/perl

# Reception: keep the SCO gateway armed from the phone's own IVR settings.
#
# The phone decides whether a call rings (JawnPhoneBridge.ivrFlowFor); this
# worker makes sure that when the phone answers for the receptionist, there is
# a plan waiting on the other end of the Bluetooth link. It runs only on the
# machine that has the helper built, so a house with no gateway simply never
# starts it.
#
# Arming is cheap after the first call: JawnOS::Sco::Render caches each prompt
# as raw 8 kHz PCM by words and voice, so a re-arm is a file read and a spawn.
# The gateway is left alone while a call is up, and one that has finished a
# call is re-armed for the next.
use strict;
use warnings;
use lib './lib';
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Log;
use File::Slurp qw(read_file);

require './perl/subroutines.pl';
require JawnOS::Sco::Client;
require JawnOS::Sco::Render;
require JawnOS::Sco::Reconnect;

my $config = -e './config.json' ? eval { decode_json(read_file('./config.json')) } : {};
my $log = Mojo::Log->new(path => &subs::home(($config && $config->{'logfile'}) || '~/manager.log'));
my $client = JawnOS::Sco::Client->new();
my $helper = './perl/sco/sco_helper';
my $armed_at = 0;
my $armed_from = '';
# the phone's link, and the last thing that was said about it
my $reconnect;
my $reconnect_said = '';
# The phone's own Bluetooth link is what carries the call. A phone that walked
# out of range comes back without it, and nothing on a quiet table retries the
# dropped ACL: the next call then has no Hands-Free audio at all. While the
# gateway waits for a call, ask the phone to connect again.
sub keep_bluetooth_ready {
	unless ($reconnect) {
		my $peer = eval { &subs::misc_setting('sco_peer') } || '';
		return '' unless $peer;
		$reconnect = JawnOS::Sco::Reconnect->new(peer => $peer);
	}
	my $verdict = $reconnect->tick();
	return $verdict if !length $verdict || $verdict eq 'too soon';
	# one line per change: a phone that is still away is asked on a backoff and
	# must not fill the log every half minute
	if ($verdict ne $reconnect_said) {
		$reconnect_said = $verdict;
		$log->info('reception: bluetooth ' . $verdict . ' (' . $reconnect->peer . ')')
			if $verdict eq 'reconnected' || $verdict eq 'unreachable';
	}
	return $verdict;
}

# The chosen gateway is another machine's: this one must not arm it as well, or
# two Receivers cancel and re-spawn the same plan every few minutes. An explicit
# sco_gateway is the older arrangement and names no machine, so it still arms.
my $not_the_gateway = $client->remote()
	&& length($client->machine())
	&& $client->machine() ne (eval { &subs::signatorial_designer() } || '');
$log->info('reception: the gateway is another machine (' . $client->machine() . '); this one will not arm it')
	if $not_the_gateway;

# Keep the names a screened call left, where the house can find them after the
# call is over: the gateway's own recordings directory is pruned, and the index
# beside it is what the pane and a later filing read.
sub keep_new_recordings {
	my $status = $client->call({ cmd => 'status' });
	return unless $status && $status->{'ok'};
	my ($newest) = @{ $status->{'recordings'} || [] };
	return unless $newest && $newest->{'file'} && -s $newest->{'file'};
	my $dir = &subs::home('~/.president/sco/kept');
	mkdir $dir unless -d $dir;
	my $id = $newest->{'call_id'} || 'call';
	$id =~ s/[^A-Za-z0-9_-]//g;
	return unless length $id;
	my $kind = ($newest->{'kind'} || 'name') eq 'voicemail' ? 'voicemail' : 'name';
	my $kept = "$dir/" . ($kind eq 'voicemail' ? 'message-' : '') . "$id.wav";
	my $index = "$dir/index.jsonl";
	return if -e $kept;
	my $copy = eval {
		open(my $in, '<', $newest->{'file'}) or die "open: $!";
		open(my $out, '>', $kept) or die "open: $!";
		binmode $in;
		binmode $out;
		local $/;
		print {$out} <$in>;
		close $out;
		close $in;
		1;
	};
	return unless $copy;
	# the name in words: base and the CLI, not the warm server's tiny model - tiny
	# reads a narrowband name as "Listen strong." where base reads "This is John."
	my $name = '';
	my $heard = '';
	my $person = '';
	my $bytes = '';
	if (open(my $rf, '<', $kept)) {
		local $/;
		$bytes = <$rf> // '';
		close $rf;
	}
	if (length $bytes && $kind eq 'name') {
		$heard = eval { &subs::whisper_name_transcribe($bytes, 'auto') } || '';
		$heard =~ s/^\s+|\s+$//g;
		$name = &subs::name_from_transcript($heard);
		# the words are matched against the people the house knows: an 8 kHz
		# link turns a surname into something close, a first name usually holds
		$person = eval { &subs::person_name_match(length $name ? $name : $heard) } || '';
	}
	if (open(my $fh, '>>', $index)) {
		print {$fh} encode_json({
			call_id => $id,
			kind => $kind,
			at => $newest->{'at'} || time,
			ms => $newest->{'ms'} || 0,
			peer => $newest->{'peer'} || '',
			file => $kept,
			name => $name,
			# the house's own person, when the words match one of them
			person => $person,
			# the words as heard: a surname over an 8 kHz link is often only
			# close, and the raw line is what a person checks the clip against
			heard => $heard,
		}) . "\n";
		close $fh;
	}
	$log->info("reception: kept $kept" . (length $name ? " - \"$name\"" : '')
		. (length $person ? " ($person)" : '')
		. (length $heard && $heard ne $name ? " (heard \"$heard\")" : ''));
	# a hundred names is plenty; older ones go
	my @kept = sort { (stat($a))[9] <=> (stat($b))[9] } glob("$dir/*.wav");
	if (@kept > 100) {
		unlink $_ for @kept[ 0 .. @kept - 101 ];
	}
	return 1;
}

sub tick {
	return if $not_the_gateway;
	&keep_new_recordings();
	my $status = $client->call({ cmd => 'status' });
	my $state = ($status && $status->{'ok'}) ? ($status->{'state'} || 'idle') : '';
	# `done` is a plan finished on a line that may still be up: the gateway puts
	# that call down itself when the line goes quiet, and only then is there a
	# gateway to arm again. Arming into a dying line spoke a second plan into it.
	return if $state eq 'in_call' || $state eq 'done';
	&keep_bluetooth_ready();
	# the same settings the Phone app saves, defaults included
	my $settings = &subs::phone_ivr_settings();
	if (($settings->{'enabled'} || 'no') ne 'yes') {
		$client->call({ cmd => 'cancel' }) if $state && $state ne 'idle';
		return;
	}
	# a machine without the helper has no admission to give
	return unless -x $helper;
	# Every flow the house saved, so the phone can name the caller's own flow
	# when it answers; the gateway runs that one and keeps the rest ready.
	my $defs = $settings->{'flow_defs'} || {};
	my %flows;
	foreach my $key ( sort keys %{$defs} ) {
		my $def = $defs->{$key};
		next unless ref $def eq 'HASH';
		my %flow = map { $_ => (defined $def->{$_} ? $def->{$_} : '') }
			qw(name voice greeting prompt voicemail thanks hold after);
		$flow{'steps'} = $def->{'steps'} if ref $def->{'steps'} eq 'ARRAY' && @{ $def->{'steps'} };
		$flows{$key} = \%flow;
	}
	# A caller nobody named follows the unknown bucket. Ring and Reject are not
	# flows at all: the phone never sends the call here, and '' keeps that so.
	my $unknown = $settings->{'flows'}->{'unknown'} || 'receptionist';
	$unknown = 'receptionist' if $unknown eq 'ivr';
	$unknown = '' if $unknown =~ /^(?:ring|reject)$/;
	$unknown = '' unless $flows{$unknown};
	# every flow, its words and the default are what the gateway was armed with:
	# changing any of them re-arms the same way changing a prompt does
	my $from = encode_json({ flows => \%flows, default => $unknown });
	# A pipe gateway waits in `waiting` (the phone has not called yet) and an
	# adapter gateway listens in `armed`; both are ready. Re-arming tears the
	# watcher down, so a ready gateway is left alone while its prompts stand.
	# (Only `armed` was checked, so pipe mode was re-armed every six seconds.)
	return if ($state eq 'armed' || $state eq 'waiting')
		&& $from eq $armed_from
		&& time - $armed_at < 300;
	# The gateway renders every flow's words itself (it is the machine with the
	# voice), so a path rendered here would only be one more thing to keep.
	my $armed = $client->call({
		cmd => 'arm',
		flows => \%flows,
		default_flow => $unknown,
		# the helper keeps the clip open until it hears a name and then a pause
		record => { ms => 20000, silence_ms => 2000, min_ms => 400 },
	});
	$armed_at = time;
	if ($armed && $armed->{'ok'}) {
		$armed_from = $from;
		$log->info('reception: armed for the next call');
	}
	else {
		$log->info('reception: could not arm - ' . (($armed && $armed->{'error'}) || 'no answer'));
	}
}

$SIG{'TERM'} = sub { Mojo::IOLoop->stop };
$SIG{'INT'} = sub { Mojo::IOLoop->stop };
Mojo::IOLoop->timer(1 => \&tick);
# often enough that a call placed just after the last one still finds a gateway
Mojo::IOLoop->recurring(3 => \&tick);
$log->info('reception started');
Mojo::IOLoop->start;
$log->info('reception stopped');
