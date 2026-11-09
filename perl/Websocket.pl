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
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
my $encoder = Sereal::Encoder->new({ compress => SRL_ZSTD, compress_level => 3 });
my $decoder = Sereal::Decoder->new();

use Mojo::JSON qw(decode_json encode_json);
use Mojo::IOLoop;
BEGIN {
	require File::Basename;
	require Cwd;
	my $dir = Cwd::abs_path(File::Basename::dirname(__FILE__));
	unshift @INC, "$dir/../lib" if $dir && -d "$dir/../lib";
}
use JawnOS::Transport ();
use Data::Dumper;
no warnings 'uninitialized';
require "./perl/gb.pl";
require "./perl/subroutines.pl";


my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
our $logfile = &subs::home($config->{'logfile'});
write_file($logfile, '') if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);

my $device = &subs::device_setter();
my $home_file = &subs::home('~/') . '.president/ws_watcher';
write_file($home_file, '') if !-e $home_file && -d &subs::home('~/.president');

# The padlock gate for live pushes is per recipient, in
# Manager::websocket_sender (Part37.pm): it asks padlock_locked_now about the
# connection's own device, the same rule the HTTP gate uses. A global drop here
# would silence a screen whose device holds a future per-device unlock - the
# house-wide pl_time can expire while that screen stays open - and the manager
# would paint its server-rendered dock and then freeze: no connect frame, no
# window, header or appointment push ever reaches the page.
# A console command is data, not source: the browser routes the name through
# its table (public/js/manager/websocket/00_console_router.js) and refuses
# anything else. The terminal's deliberate JS line is the only exception.
sub console_command {
	my ($cmd, @args) = @_;
	return { cmd => $cmd, args => \@args };
}

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
		$wsm->{'token'} = JawnOS::Transport::token() if JawnOS::Transport::tcp();

		my $file = $gb::tmp_dir . '/ws/' . $app;
		# Report whether the frame actually went. The worker can be between
		# restarts, and a device command that treats a dropped frame as delivered
		# skips its HTTP fallback, so the relay never moves while the Manager says
		# it did. On TCP the sender connects to the shared ws port; on UNIX it
		# still refuses a path that does not exist.
		$returner = &subs::unix_socket_sender($file,$wsm);
	}
	return $returner;
}

sub mail_send() {
	my ($msg) = @_;
	my $mailfile = $gb::tmp_dir . '/ws/mailws';
	$msg->{'token'} = JawnOS::Transport::token()
		if JawnOS::Transport::tcp() && ref $msg eq 'HASH';
	&subs::unix_socket_sender($mailfile,$msg);
	




}

1;