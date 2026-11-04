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

my $config = -e './config.json' ? eval { decode_json(read_file('./config.json')) } : {};
my $log = Mojo::Log->new(path => &subs::home(($config && $config->{'logfile'}) || '~/manager.log'));
my $client = JawnOS::Sco::Client->new();
my $helper = './perl/sco/sco_helper';
my $armed_at = 0;
my $armed_from = '';

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
	my $kept = "$dir/$id.wav";
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
	# the name in words, the way dictation does it: the clip goes to the house's
	# transcription role (whisper.cpp on this machine, or the chosen cloud model)
	my $name = '';
	my $bytes = '';
	if (open(my $rf, '<', $kept)) {
		local $/;
		$bytes = <$rf> // '';
		close $rf;
	}
	if (length $bytes) {
		$name = eval { &subs::whisper_transcribe($bytes, 'auto') } || '';
		$name =~ s/^\s+|\s+$//g;
	}
	if (open(my $fh, '>>', $index)) {
		print {$fh} encode_json({
			call_id => $id,
			at => $newest->{'at'} || time,
			ms => $newest->{'ms'} || 0,
			peer => $newest->{'peer'} || '',
			file => $kept,
			name => $name,
		}) . "\n";
		close $fh;
	}
	$log->info("reception: kept $kept" . (length $name ? " - \"$name\"" : ""));
	# a hundred names is plenty; older ones go
	my @kept = sort { (stat($a))[9] <=> (stat($b))[9] } glob("$dir/*.wav");
	if (@kept > 100) {
		unlink $_ for @kept[ 0 .. @kept - 101 ];
	}
	return 1;
}

sub tick {
	&keep_new_recordings();
	my $status = $client->call({ cmd => 'status' });
	my $state = ($status && $status->{'ok'}) ? ($status->{'state'} || 'idle') : '';
	return if $state eq 'in_call';
	# the same settings the Phone app saves, defaults included
	my $settings = &subs::phone_ivr_settings();
	if (($settings->{'enabled'} || 'no') ne 'yes') {
		$client->call({ cmd => 'cancel' }) if $state && $state ne 'idle';
		return;
	}
	# a machine without the helper has no admission to give
	return unless -x $helper;
	my $voice = $settings->{'voice'} || '';
	my @text = map { $settings->{$_} || '' } qw(greeting prompt thanks);
	my $from = join("\x00", $voice, @text);
	# A pipe gateway waits in `waiting` (the phone has not called yet) and an
	# adapter gateway listens in `armed`; both are ready. Re-arming tears the
	# watcher down, so a ready gateway is left alone while its prompts stand.
	# (Only `armed` was checked, so pipe mode was re-armed every six seconds.)
	return if ($state eq 'armed' || $state eq 'waiting')
		&& $from eq $armed_from
		&& time - $armed_at < 300;
	my %clips;
	foreach my $key (qw(greeting prompt thanks)) {
		my $text = $settings->{$key} || '';
		next unless length $text;
		my $raw = &JawnOS::Sco::Render::render($text, $voice);
		$clips{$key} = $raw if $raw;
	}
	my $armed = $client->call({
		cmd => 'arm',
		clips => \%clips,
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
Mojo::IOLoop->recurring(6 => \&tick);
$log->info('reception started');
Mojo::IOLoop->start;
$log->info('reception stopped');
