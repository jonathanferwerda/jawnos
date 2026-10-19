#!/usr/bin/perl

use strict;
use warnings;

package Websocket;

use List::Util qw(shuffle);
use Mojo::Util qw/md5_sum html_unescape term_escape/;
use Time::Duration;
use Date::Parse;
use Time::Piece;
use Crypt::Simple;
use File::Slurp;
use IO::Socket::UNIX;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
my $encoder = Sereal::Encoder->new({ compress => SRL_ZSTD, compress_level => 3 });
my $decoder = Sereal::Decoder->new();

use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;
use Data::Dumper;
no warnings 'uninitialized';
require "./gb.pl";
require "./subroutines.pl";


my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);

my $device = &subs::device_setter();
my $home_file = &subs::home('~/') . '.president/ws_watcher';
`touch $home_file` unless -e $home_file;

# A locked house must not keep feeding an open manager socket. The HTTP gate
# refuses new requests; this drops the live pushes too. The lock's own
# messages (the overlay, the phone-key call, the unlock) and the console
# commands that drive its UI are let through. The answer is cached for a
# second so a burst of sends does not decrypt pl_time each time.
my $padlock_gate_checked = 0;
my $padlock_gate_until = 0;
my $padlock_dropped_at = 0;
sub padlock_gate_locked {
	my $now = &subs::rightNow();
	return $padlock_gate_checked if $now < $padlock_gate_until;
	my $locked = 0;
	my ($db) = &subs::database_grabber();
	if ($db) {
		my $padlock = &subs::db_select('security', undef, { level => 'padlock' })->hashes->[0];
		if ($padlock) {
			my $ctx_row = &subs::db_query('select value from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'padlock_contexts')->hashes->[0];
			my $contexts = $ctx_row ? (eval { decode_json $ctx_row->{'value'} } || []) : [];
			if (grep { $_ eq 'general' } @{$contexts}) {
				my $row = &subs::db_query('select value from settings where app = ? and setting = ? order by server_time desc limit 1', '__president', 'pl_time')->hashes->[0];
				my $suds = eval { &subs::suds_grabber() };
				if ($row && $suds) {
					my $pl = &subs::decrypter($suds, $row->{'value'}) || 0;
					$locked = ($now > $pl) ? 1 : 0;
				}
			}
		}
	}
	$padlock_gate_checked = $locked;
	$padlock_gate_until = $now + 1000;
	return $locked;
}
sub send() {
	my ($app,$msg) = @_;
	if ($app eq 'server' && !$msg->{'padlock'} && !$msg->{'padlock_open'} && !$msg->{'padlock_key_show'} && !$msg->{'console'} && &padlock_gate_locked()) {
		my $now = &subs::rightNow();
		if ($now - $padlock_dropped_at > 10000) {
			$log->info('padlock gate: dropped a websocket push while locked');
			$padlock_dropped_at = $now;
		}
		return;
	}
	my ($db,$database,$sql) = &subs::database_grabber();
	my $returner;
	if ($msg->{'console'}) {
		if (!$msg->{'whoami'}) {
			$msg->{'whoami'} = `whoami`;
			chomp $msg->{'whoami'};
		}
		if (!$msg->{'hostname'}) {
			$msg->{'hostname'} = `hostname`;
			chomp $msg->{'hostname'};
		}
	}
	my $original_msg = $msg;
	if (my $m = eval { return encode_json $msg } ) {
		my $uuid = &subs::random_string_creator(10);

		$msg->{'formatted_name'} = &subs::format_name($msg->{'app'});
		my $server_time = &subs::rightNow();
		my $wsm = {
			origin => $original_msg->{'origin'},
			server_time => $server_time,
			timestamp => $original_msg->{'timestamp'} || $server_time,
			message => $m,
			destination => $original_msg->{'destination'} || $original_msg->{'browser_tab_id'},
			app => $app,
			environment => 'manager',
			uuid => $uuid,
			patience => $original_msg->{'patience'}
		};
		foreach my $k ( keys %{$wsm} ) {
			delete $wsm->{$k} unless $wsm->{$k};
		}

		my $file = $gb::tmp_dir . '/ws/' . $app;
		&subs::unix_socket_sender($file,$wsm) if -e $file;
	}
	return $returner;
}

sub mail_send() {
	my ($msg) = @_;
	my $mailfile = $gb::tmp_dir . '/ws/mailws';
	&subs::unix_socket_sender($mailfile,$msg);
	




}

1;