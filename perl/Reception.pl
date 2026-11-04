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
use Mojo::JSON qw(decode_json);
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

sub setting {
	my ($key) = @_;
	my $value = eval { &subs::setting_grabber({ app => 'phone', setting => $key, benign => 1 }) };
	return defined $value ? $value : '';
}

sub tick {
	my $status = $client->call({ cmd => 'status' });
	my $state = ($status && $status->{'ok'}) ? ($status->{'state'} || 'idle') : '';
	return if $state eq 'in_call';
	my $enabled = &setting('ivr_enabled');
	if (($enabled || '') ne 'yes') {
		$client->call({ cmd => 'cancel' }) if $state && $state ne 'idle';
		return;
	}
	# a machine without the helper has no admission to give
	return unless -x $helper;
	return if $state eq 'armed' && time - $armed_at < 300;
	my $voice = &setting('ivr_voice');
	my @text = map { &setting('ivr_' . $_) } qw(greeting prompt thanks);
	my $from = join("\x00", $voice, @text);
	# the prompts have not changed since the last arm: leave the listener up
	return if $state eq 'armed' && $from eq $armed_from;
	my %clips;
	foreach my $key (qw(greeting prompt thanks)) {
		my $text = &setting('ivr_' . $key);
		next unless length $text;
		my $raw = &JawnOS::Sco::Render::render($text, $voice);
		$clips{$key} = $raw if $raw;
	}
	my $armed = $client->call({
		cmd => 'arm',
		clips => \%clips,
		record => { ms => 20000, silence_ms => 1200, min_ms => 400 },
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
