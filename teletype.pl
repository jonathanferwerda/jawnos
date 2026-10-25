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
require './remote_input.pl';


my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
my $device = &subs::device_setter();
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);
&remote_input::set_log($log);


sub auth_check($c) {
	my @t = localtime(time);
	my $offset = timegm(@t) - timelocal(@t);
	my $server_time = time();
	# The deck is authenticated the same way its rooms are: the rotated Now Me
	# pair in the device's operator_door. There is no separate teletype password,
	# so a deck that has just run Now Me can open the control socket at once -
	# the same `authorization` token rides in the query string (URL-encoded).
	my $authorized = eval { &watch::embeddedAuthorizer($c) };
	if ($authorized) {
		return {
			result => 'approved',
			server_time => $server_time,
			offset => $offset,
			returner => "You're so in!"
		};
	}
	return { result => 'denial' };
};


# The T-Deck's control channel and the Manager's remote_control panel share one
# injection path (remote_input.pl), so whichever backend is installed here works
# for both. These keep the names the websocket handler already uses.
sub input_backends() {
	return &remote_input::backends();
}

sub input_backend() {
	return &remote_input::backend();
}

sub inject($action, @args) {
	return &remote_input::inject($action, @args);
}

sub screen_geometry() {
	return &remote_input::screen_geometry();
}

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
	else {
		$c->render(json => { result => 'denial' });
	}
};

websocket '/teletype/ws' => sub($c) {
	my $auth_check = &auth_check($c);
	unless (($auth_check->{'result'} || '') eq 'approved') {
		$c->rendered(403);
		return;
	}
	$c->on(message => sub ($ws, $msg) {
		if ($msg eq 'hey') {
			$c->send('Hey yourself!');
		}
		else { #if (	&subs::setting_grabber({ app => 'teletype', setting => 'enabled' }) eq 1) {
			my $m = eval { return decode_json $msg } || {};
			my $resolution = &screen_geometry();
			if ($m->{'command'} eq 'mouse') {
				if ($m->{'movement'} eq "button") {
					if ($m->{'value'} == 0) {
						&inject('mousedown') if $device eq 'computer';
					}
					elsif ($m->{'value'} == 1) {
						&inject('mouseup') if $device eq 'computer';
					}
				}
				if ($device eq 'mobile') {
					&Websocket::send('tab', $msg);

				}
			}
			elsif ($m->{'command'} eq 'keypress') {
				my $key = $m->{'key'};
				my ($keyboard) = grep { $_->{'num'} eq $key } @{$gb::inputs};

				if ($keyboard) {
					if ($keyboard->{'trigger'} eq 'key') {
						&inject('key', $keyboard->{'img'});
					}
					else {
						&inject('type', $keyboard->{'c'});
					}
				}
			}
			elsif ($m->{'command'} eq 'touch') {
				if ($device eq 'mobile') {
					my $ms = {
						'x' => $m->{'x'},
						'y' => $m->{'y'},
						'res_x' => $m->{'res_x'},
						'res_y' => $m->{'res_y'},
						'command' => 'touch'
					};
					&Websocket::send('tab', $ms);
				}
				elsif ($device eq 'computer' && $resolution && $m->{'res_x'} && $m->{'res_y'}) {
					my ($screen_x,$screen_y) = @{$resolution};
					my $x = ($screen_x / $m->{'res_x'}) * $m->{'y'};
					my $y = ($screen_y / $m->{'res_y'}) * ($m->{'res_y'} - $m->{'x'});
					if ($m->{'mmr'} eq "off") {
						&inject('move', $x, $y, $screen_x, $screen_y);
					}
					elsif ($m->{'last_y'} && $m->{'last_x'} && $m->{'touching'} == 1) {
						my $new_x = ($m->{'y'} - $m->{'last_y'} ) * 3;
						my $new_y = ($m->{'last_x'} - $m->{'x'} ) * 3;
						&inject('move_rel', $new_x, $new_y);
					}
				}
			}
		}
	});
};

if (!$ENV{PURPOSE} || $ENV{PURPOSE} eq "teletype") { 
	app->sessions->samesite('lax');
	$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
	app->renderer->cache->max_keys(0);
	app->sessions->encrypted(1);
	app->secrets($gb::secret_maker);
	app->sessions->cookie_name($ENV{'cookie_name'});
	# Name the injection path in the log: on a Wayland box this is how you see
	# whether dotool was found and what screen the touch map is using.
	my $geometry = &screen_geometry();
	$log->info('teletype input backend=' . &input_backend()
		. ' wayland=' . &remote_input::wayland_session()
		. ($geometry ? ' screen=' . $geometry->[0] . 'x' . $geometry->[1] : ' screen=unknown'));
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