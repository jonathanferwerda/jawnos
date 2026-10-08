#!/usr/bin/perl

use strict;
use warnings;
package teletype;
use Mojolicious::Lite -signatures;
use File::Slurp;
use Mojo::JSON qw(decode_json encode_json);
use SQL::Abstract;
use Mojo::SQLite;
use Data::Dumper;
use URI::Encode qw(uri_encode uri_decode);
use Mojo::Util qw(secure_compare);
use Time::Local;
plugin 'RenderFile';
no warnings 'uninitialized';
# the gb globals below live in gb.pl and are written or read from every
# corner of the house; a file that touches one only once is not a typo
no warnings 'once';
require './subroutines.pl';
require './gb.pl';
require './watch.pl';
require './Websocket.pl';


my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
my $device = &subs::device_setter();
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);


sub auth_check($c) {
	my $lock = &subs::setting_grabber({ app => 'teletype', setting => 'tauthorization' });
	my $patience = &subs::setting_grabber({ app => 'teletype', setting => 'patience' });
	my $authorship = `echo $lock | base64 --decode`;
	my $auth = &subs::note_decrypter($patience,$authorship);
	chomp $auth;
	my @t = localtime(time);
	my $offset = timegm(@t) - timelocal(@t);
	my $server_time = time();
	if ($c->param('first_check') eq 'true') {
		my $tauthorization = $c->param('tauthorization');
		chomp $tauthorization;
		my $tty_port = $ENV{PORT_BESTOW};
		if ($tauthorization && secure_compare $auth, $tauthorization) {
			my $info = {
				tty_port => $tty_port,
				tauthorization => $lock,
				result => "approved",
				server_time => $server_time,
				offset => $offset,
				returner => "You're so in!"
			};

			return $info;
		}
		else {
			return { result => "denial" };
		}
	}
	else {
		my $saved_auth = $c->param('tauthorization');
		my $authors = `echo $saved_auth | base64 --decode`;
		my $au = &subs::note_decrypter($patience, $authors);
		chomp $au;
		if ($au eq $auth) {
			my $sa = `echo $saved_auth | base64 --decode`;
			my $result = "You said " . $c->param('life');

			return { result => "approved" , returner => $result, tauthorization => $saved_auth, server_time => $server_time, offset => $offset};
		}
	}
};

get '/teletype/information' => sub($c) {
	my $auth_check = &auth_check($c);
	if ( $auth_check->{'result'} eq 'approved') {
		my ($db,$database) = &subs::database_grabber();

		my $server_time = &subs::rightNow();
		my $timestamp = $c->param('timestamp') * 1000;
		my $life = &subs::unformat_name($c->param('life'));
		my ($app,$type) = &subs::typesetter($life);
		&subs::setting_setter({ app => $app, setting => 'pos', value => $type });
		my $init = &subs::setting_initializer($app,$timestamp);
	
		my $insert = &subs::db_insert('appointments', {
			app => $app,
			server_time => $server_time,
			timestamp => $timestamp,
			type => 'text',
#			toggle => $b->{'toggle'}
			uuid => &subs::random_string_creator(40)
		});
		$c->render(json => $auth_check);
		my $msg = { app => $app, console => 'appointmentGrabber("' . $app . '",' . $timestamp . ')' };
		&Websocket::send('server', $msg);
	}
};

websocket '/teletype/ws' => sub($c) {
	my $auth_check = &auth_check($c);
	if ($auth_check->{'result'} eq 'approved') {
		$c->on(message => sub ($ws, $msg) {
			my $server_time = &subs::rightNow();
			if ($msg eq 'hey') {
				$c->send('Hey yourself!');
			}
			else { #if (	&subs::setting_grabber({ app => 'teletype', setting => 'enabled' }) eq 1) {
				my ($db,$database) = &subs::database_grabber();
				my $m = eval { return decode_json $msg } || {};
				my $screen_size = `xprop -notype -len 16 -root _NET_DESKTOP_GEOMETRY | cut -c 25-`;
				chomp $screen_size;
				my @resolution = split ", ", $screen_size;
				my $resolution = [ $resolution[0], $resolution[1] ];
				my $display = ":0.0";
				if ($m->{'command'} eq 'mouse') {
					if ($m->{'movement'} eq "button") {
						if ($m->{'value'} == 0) {
							
							`xdotool mousedown 1` if $device eq 'computer';
						}
						elsif ($m->{'value'} == 1) {
							`xdotool mouseup 1` if $device eq 'computer';
						}
					}
					if ($device eq 'mobile') {
						&Websocket::send('tab', $msg);

					}
				}
				elsif ($m->{'command'} eq 'keypress') {
					my $key = $m->{'key'};
					my @keyboard = grep { $_->{'num'} eq $key } @{$gb::inputs};

					if ($keyboard[0]->{'trigger'} eq 'key') {
						my $master = $keyboard[0]->{'img'};
						`xdotool key "$master"`;
					}
					else {
						my $master = $keyboard[0]->{'c'};
						`xdotool type "$master"`;
					}
				}
				elsif ($m->{'command'} eq 'touch') {

					my $resolution_x = $m->{'res_x'};
					my $resolution_y = $m->{'res_y'};
					my ($screen_x,$screen_y) = @resolution;
					my $x = $m->{'y'};
					my $y = $resolution_y - $m->{'x'};

					$x = ($screen_x / $resolution_x) * $x;
					$y = ($screen_y / $resolution_y) * $y;
					if ($device eq 'mobile') {
						my $ms = {
							'x' => $m->{'x'},
							'y' => $m->{'y'},
							'res_x' => $resolution_x,
							'res_y' => $resolution_y,
							'command' => 'touch'
						};
						&Websocket::send('tab', $ms);

					}
					elsif ($device eq 'computer') {
						if ($m->{'mmr'} eq "off") {
							`xdotool mousemove $x $y`;
						}
						else {
							if ($m->{'last_y'} && $m->{'last_x'} && $m->{'touching'} == 1) {
								my $new_x = ($m->{'y'} - $m->{'last_y'} ) * 3;
								my $new_y = ($m->{'last_x'} - $m->{'x'} ) * 3;
								`xdotool mousemove_relative -- $new_x $new_y`;
							}

						}
					}
				}
			}
		});
	}
};

if (!$ENV{PURPOSE} || $ENV{PURPOSE} eq "teletype") { 
	app->sessions->samesite('lax');
	$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
	app->renderer->cache->max_keys(0);
	app->sessions->encrypted(1);
	app->secrets($gb::secret_maker);
	app->sessions->cookie_name($ENV{'cookie_name'});
	if ($config->{'environment'} eq 'production') {
		app->log->level('error'); 
	} else {
		app->log->level('debug'); 
	}
	app->start;
}
else {
	1;
}