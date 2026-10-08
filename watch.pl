#!/usr/bin/perl

use strict;
use warnings;
package watch;
use Mojolicious::Lite -signatures;
use File::Slurp;
use Mojo::JSON qw(decode_json encode_json);
use SQL::Abstract;
use Mojo::SQLite;
use Time::Local;
use Data::Dumper;
use URI::Encode qw(uri_encode uri_decode);
use Mojo::Util qw(secure_compare);
use Time::Local;
use Time::Piece;
plugin 'RenderFile';
require './subroutines.pl';
require './teletype.pl';
require './Websocket.pl';
require './Manager.pl';
no warnings 'uninitialized';
# the gb globals below live in gb.pl and are written or read from every
# corner of the house; a file that touches one only once is not a typo
no warnings 'once';
my $config_file = read_file('./config.json');
my $config = decode_json $config_file;
my $device = &subs::device_setter();
our $logfile = &subs::home($config->{'logfile'});
`touch $logfile` if not -e $logfile;
our $log = Mojo::Log->new(path => $logfile);


sub embeddedAuthorizer($c) {
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $wat_set = &subs::setting_grabber({ app => $edt, setting => 'operator_door', device => $device, subsetting => $chip_id });;
	my $watch_settings = eval { return decode_json $wat_set } || {};
	my $auth = $watch_settings->{'__specs'}->{'authorization'};
	my $author = `echo $auth | base64 --decode`;
	my $authorization = &subs::note_decrypter($watch_settings->{'__shutup'}->{'patience'}, $author);
	my $rauth = $c->param('authorization');
	my $rauthorization = `echo $rauth | base64 --decode`;
	my $remote_auth = &subs::note_decrypter($watch_settings->{'__shutup'}->{'patience'}, $rauthorization);

	if ($remote_auth && $edt && secure_compare $remote_auth, $authorization) {
		$watch_settings->{'__shutup'} = undef;
		return $watch_settings;
	}
	else {
		return undef;
	}
}

get '/watch/time' => sub($c) {
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my $edt = $c->param('edt');
		my $server_time = time();
		my @t = localtime(time);
		my $is_dst = $t[8];
		my $offset = timegm(@t) - timelocal(@t);
		if ($is_dst == 0 && $edt eq 'watch') { 
			$server_time = $server_time + (1000 * 3600);
		}
		my $returner = encode_json { timestamp => $server_time, offset => $offset };
		$c->render(text => $returner);
	}
	else {
		$c->render(template => 'guest_layouts/denial');
	}
};


get '/watch/asset' => sub($c) {
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my $filename = $c->param('filename');
		my $paths = Mojo::File->new('public/' . $filename);
		$c->render_file('filepath' => $paths->to_string);
	}
	else {
		$c->render(template => 'guest_layouts/denial');
	}
};

get '/teletype/wifi_update' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $json_wifi = &subs::setting_grabber({ app => $edt, setting => 'wifi'}) || '{}';
	
	my $wifi = decode_json $json_wifi;
	$c->render(text => $json_wifi);
};

get '/embedded/teletype/backup' => sub($c) {
	if (my $watch_settings = &embeddedAuthorizer($c)) {

		my $b = $c->param('archive');

		my $paths = Mojo::File->new($b);
		$c->render_file('filepath' => $paths->to_string);
	}
	else {
		$c->render(template => 'guest_layouts/denial');
	}
};


get '/watch' => sub($c) {
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $room = $c->param('room');
	my $chip_id = $c->param('chip_id');
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my $room_count = $watch_settings->{'__specs'}->{'room_count'};
		my $room_max = $watch_settings->{'__specs'}->{'room_max'};
		foreach my $k ( keys %{$watch_settings} ) {
			$watch_settings->{$k}->{'toggle'} = &subs::setting_grabber({ app => $watch_settings->{$k}->{'app'}, setting => 'toggle' }) eq 'on' ? 1 : 0;
		}
		$watch_settings = &subs::embedded_internal_jobs($watch_settings);
	#	$log->info(Dumper $watch_settings);
		$c->render('json' => $watch_settings);
		&Websocket::send('tab', { console => 'nowMeSuccess(\'' . $edt . '\',\'' . $chip_id . '\')', browser_tab_id => $c->param('browser_tab_id') });
	}
	else { 
		$c->render('text' => "failure"); 
	}
};

get '/watch/telephone_msg' => sub($c) {
	my $timestamp = &subs::rightNow() || $c->param('timestamp');
	my $server_time = &subs::rightNow();
	my $message = $c->param('msg');
	my $app = &subs::unformat_name($c->param('app'));
	my ($db,$database) = &subs::database_grabber();
	my $insert = &subs::db_insert('appointments', {
		app => $app,
		server_time => $server_time,
		timestamp => $timestamp,
		type => 'msg',
		data => &subs::format_name($message),
		uuid => &subs::random_string_creator(40),
	});
	my $msg = { app => $app, uuid => &subs::random_string_creator(6), console => 'appointmentGrabber("' . $app . '",' . $timestamp . ')' };
	&Websocket::send('server', $msg );

	$c->render('json' => { 'msg' => $message });
};

get '/watch/button' => sub($c) {
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $remote_address = $c->tx->remote_address;
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my $button = $c->param('button');
		my $timestamp = $c->param('timestamp') * 1000 || &subs::rightNow();
		my $room = $c->param('room');
		my $toggle = $c->param('toggle');
		if ($toggle == 1) {
			$toggle = 'off'
		}
		else {
			$toggle = 'on';
		}



		&subs::setting_setter({ app => $b->{'app'}, setting => 'toggle', value => $toggle });

		my $returner = &subs::edt_button_presser({
			timestamp => $timestamp,
			room => $room,
			watch_settings => $watch_settings,
			button => $button,
			edt => $edt,
			chip_id => $chip_id,
			remote_address => $remote_address,
			toggle => $toggle
		});
		$c->render('json' => $returner);

		my $bt_msg = {
			type => 'button',
			data => $returner
		};

		my $returner = &subs::bluetooth_sender({
			intent => 'com.jawn.president.bt.connect',
			chip_id => $chip_id,
			edt => $edt,
			message => $bt_msg
		});
	}
	else { $c->render("text" => "failure" ); }
};

get '/watch/switch' => sub($c) {
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $remote_address = $c->tx->remote_address;
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my $button = $c->param('switch');
		my $state = $c->param('state');
		my $toggle = $c->param('toggle');
		my $timestamp = $c->param('timestamp') * 1000 || &subs::rightNow();
		my $room = $c->param('room');
		if ($state eq 'on') {
			$state = 'off'
		}
		else {
			$state = 'on';
		}
		my $syl_count = 10;
		$syl_count = 1 unless $edt eq 'microcontroller';
		my $b = $watch_settings->{&subs::shorthand_name('switch', $syl_count) . $button} || {};
		&subs::setting_setter({ app => $b->{'app'}, setting => 'toggle', value => $state });
		my $data = {
			timestamp => $timestamp,
			room => $room,
			watch_settings => $watch_settings,
			button => $button,
			component => 'switch',
			edt => $edt,
			chip_id => $chip_id,
			remote_address => $remote_address
		};
		$data->{'switch'} = $button;
		if ($data->{'toggle'} == 1) {
			$data->{'state'} = 'on';
		}
		else {
			$data->{'state'} = 'off';
		}
		my $returner = &subs::edt_button_presser($data);
		$c->render(json => $returner);
	}
	else {
		$c->render('text' => 'failure');
	}
};

get '/watch/measure' => sub($c) {
	my $remote_address = $c->tx->remote_address;
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		$c->render('text' => 'ok');		

		my $component = $c->param('component');
		my $chip_id = $c->param('chip_id');
		my $measure = $c->param('measure');
		my $button = $c->param('button');
		my $edt = $c->param('edt');
		my $room = $c->param('room');
		my $timestamp = &subs::rightNow();


		my $emin = $c->param('min');
		my $emax = $c->param('max');
		my $syl_count = 10;
		$syl_count = 1 unless $edt eq 'microcontroller';
		my $b = $watch_settings->{&subs::shorthand_name($component, $syl_count) . $button} || {};

		my $app = $b->{'app'};
		my $settings = &subs::settings_grabber({ app => $app, settings => ['app_measures'] });
		my $app_measures = eval { return decode_json $settings->{'app_measures'} } || [];
		if (exists $app_measures->{$b->{'measure'}}->{'max'} && exists $app_measures->{$b->{'measure'}}->{'min'}) {
			my $etotal = $emax - $emin;

			my $estate = $measure - $emin;
			my $eratio = $estate / $etotal;
			my $total = $app_measures->{$b->{'measure'}}->{'max'} - $app_measures->{$b->{'measure'}}->{'min'};
			my $state_total = $eratio * $total;

			$measure = sprintf("%.3f", $state_total + $app_measures->{$b->{'measure'}}->{'min'});
			my $state = $state_total / $total * 100;
		}

		my $returner = &subs::edt_button_presser({
			timestamp => $timestamp,
			room => $room,
			watch_settings => $watch_settings,
			button => $button,
			edt => $edt,
			chip_id => $chip_id,
			measure => $measure,
			component => $component,
			remote_address => $remote_address
		});
	}

	else { $c->render("text" => "failure" ); }
};

any '/watch/chat_received' => sub ($c) {
	my $message = $c->param('message');

	my $username = $c->param('username');
	my $timestamp = $c->param('timestamp');
	my $contact = $c->param('contact');
	my $community = $c->param('community');
	my $club = $c->param('club');
	my $team = $c->param('team');
	my $project = $c->param('project');
	my $account = $c->param('account');
	my $person = $c->param('person');
	my $authorization = $c->param('authorization');
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my ($db,$database,$sql) = &subs::database_grabber();
		my $ticket = &subs::db_query('select uuid from tickets where name = ?', $contact);
		my $contact_uuid = $ticket->hashes->[0]->{'uuid'};
		&subs::db_insert('mailbox', {
			uuid => &subs::random_string_creator(25),
			timestamp => &subs::rightNow(),
			server_time => &subs::rightNow(),
			body => $message,
			manager_file => $username,
			status => 'public',
			project => $project || $gb::social_constructs->{'projects'}->{'def'},
			account => $account || $gb::social_constructs->{'accounts'}->{'def'},
			community => $community || $gb::social_constructs->{'communities'}->{'def'},
			club => $club || $gb::social_constructs->{'clubs'}->{'def'},
			team => $team || $gb::social_constructs->{'teams'}->{'def'},
			person => $person || $gb::social_constructs->{'people'}->{'def'},
			contact => $contact_uuid || $watch_settings->{'__specs'}->{'computer'}
		});
		$c->render(json => { returner => $username . ": " . $message });
	}
	else {
		$c->render(json => { returner => "P: NO!!!!" });
	}
};


get '/teletype/pen' => sub($c) {
	my $returner = {};
	if (my $watch_settings = &embeddedAuthorizer($c)) {

		&subs::db_insert('mailbox', {
			uuid => &subs::random_string_creator(25),
			timestamp => &subs::rightNow(),
			server_time => &subs::rightNow(),
			body => $c->param('message'),
			manager_file => $c->param('username'),
			status => 'public',
			contact => 'pen'
		});
		my $return_msg = &subs::pen_message({ 'msg' => $c->param('message') });
		$returner = { message => $return_msg };
	}
	else {
		$returner->{'message'} = "i don't know you";
	}
	$c->render(json => $returner);
};

get '/watch/chat_grabber' => sub($c) {
	my $secret = $c->param('s');
	my $timestamp = $c->param('ts');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $wat_set = &subs::setting_grabber({ app => 'watch', setting => 'operator_door', subsetting => $chip_id });;
	my $op_d = eval { return decode_json $wat_set } || {};
	my $s = `(echo $secret) | base64 --decode`;
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my $pass = &subs::note_decrypter($op_d->{'__shutup'}->{'patience'},$s);
		my ($db,$database,$sql) = &subs::database_grabber();
		my $q = &subs::db_query('select * from mailbox where uuid = ?', $uuid);
		my $mail = $q->hashes->[0];
		my $mb = &subs::note_decrypter($pass, $mail->{'body'}, $mail->{'timestamp'});
		chomp $mb;
		$mail->{'body'} = $mb;
		$c->render(json => $mail);
	}
	else {
		$c->render('text' => 'failure');
	}
};

get '/watch/alive' => sub($c) {
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $ip = $c->tx->remote_address;
	my $returner = {
		status => 'alive'
	};
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my $edt = $c->param('edt');
		my $chip_id = $c->param('chip_id');
		my $ip = $c->tx->remote_address;
		if ($edt eq 'watch' || $edt eq 'teletype') {
			my $data = {
				ip => $ip,
				timestamp => &subs::rightNow(),
				edt => $edt,
				chip_id => $chip_id
			};
			&subs::embedded_wigi($data);
		}
		$c->render(json => $returner);
	}
	else {
		$c->render(json => {});
	}



};

get '/watch/next_appt' => sub($c) {
	if (my $watch_settings = &embeddedAuthorizer($c)) {

		my $next_data = &subs::next_appointment_time({ now => &subs::rightNow(), list => 30, type => 'notification' });

		my $return = [];
		my $settings = {};
		foreach my $nd ( @{$next_data->{'list'}} ) {
			$settings->{$nd->{'app'}} = &subs::settings_grabber({ app => $nd->{'app'}, settings => [ 'colour','notification','notification_text' ] }) unless $settings->{$nd}->{'app'};
			if ($settings->{$nd->{'app'}}->{'notification'} eq 'on') {
				$settings->{$nd->{'app'}}->{'colour'} =~ s/\#//gi;
				my @rgb = map $_ , unpack 'C*', pack 'H*', $settings->{$nd->{'app'}}->{'colour'};
				push @{$return}, {
					next_time => $nd->{'next_time'},
					title => &subs::format_name($nd->{'app'}),
					timestamp => sprintf("%.0f", $nd->{'timestamp'} / 1000),
					formatted_time => localtime($nd->{'timestamp'} / 1000 )->strftime('%a %D %I:%M:%S%P'),
					notification => $settings->{$nd->{'app'}}->{'notification_text'},
					colour => $settings->{$nd->{'app'}}->{'colour'},
					rgb => \@rgb
				};
			}
		}
		@{$return} = sort { $a->{'next_time'} <=> $b->{'next_time'} } @{$return};

	#	$log->info(Dumper $return);
		$c->render(json => $return);
	} else {
		$c->render(text => 'failure');
	}
};

get '/watch/ota_status' => sub($c) {
	if (my $watch_settings = &embeddedAuthorizer($c)) {
		my $file = './jp/alarmclock/build/rp2040.rp2040.rpipico2w/alarmclock.ino.bin';
		my $total_size = -s $file;

		my $percentage = sprintf("%.2f", $c->param('current_size') / $total_size * 100 ) . '%';
		$c->render(text => $total_size);
		&Websocket::send('tab', { console => '$(\'#embedded_ota_uploader_percentage\').text(\'' . &subs::format_name($c->param('status')) . ' ' . $percentage . '\').show()', browser_tab_id => $c->param('browser_tab_id') });
	}
	else {
		$c->render(text => 'no');
	}
};

if ($ENV{PURPOSE} eq "watch") { 
	app->sessions->samesite('lax');
	$ENV{MOJO_MAX_MESSAGE_SIZE} = 1023423423473741824;
	app->renderer->cache->max_keys(0);
#	app->sessions->encrypted(1);
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
