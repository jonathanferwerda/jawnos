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
sub send() {
	my ($app,$msg) = @_;
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