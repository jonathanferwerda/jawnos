package Manager;

# manager_watch: route actions moved out of Manager.pl, one sub per route so a
# route can be read and changed without opening the whole file. The package
# is still Manager, so unqualified calls to its helpers and its package
# state work exactly as they did in the single file.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

use strict;
use warnings ;#'uninitialized';
use Mojo::Promise;
use Mojo::UserAgent;
use Time::Local;
use Time::Piece;
use Time::Duration;
use Date::Parse;
use Clone qw(clone);
use Mojolicious::Static;
use Mojo::Log;
use Mojo::Transaction::WebSocket;
use Mojo::Parameters;
use Mojo::DOM;
use Mojo::URL;
use Mojo::JSON qw(decode_json encode_json);
use URI::Encode qw(uri_encode uri_decode);
use List::Util qw(shuffle);
use Data::Dumper;
use Mojo::Util qw/md5_sum html_unescape xml_escape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use File::Find;
use File::Slurp;
use File::Type;
use File::Copy;
use POSIX ();
use Fcntl qw(:flock O_CREAT O_EXCL O_WRONLY);
use Number::Format qw/:subs/;
use SQL::Abstract;
use Mojo::SQLite;
use Mojo::IOLoop;
use Mojo::IOLoop::ReadWriteFork;
use Mojolicious::Sessions;
use Mojo::Server::Daemon;
use Mojolicious::Renderer;
use Crypt::Simple;
use CryptX;
use HTML::Strip;
use HTML::Parser;
use Data::UUID;
use Storable;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use MIME::Base64;
use Sereal::Encoder qw(encode_sereal SRL_SNAPPY SRL_ZSTD);
use Sereal::Decoder qw(decode_sereal);
use Minion;
use IO::Socket::UNIX;
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# POST /manager/watch/assign
sub action_43926 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $ip = $c->param('ip');
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $pre_value = $c->param('pre_value');
	my $numero = $c->param('numero');
	my $component = $c->param('component');
	my $chip_id = $c->param('chip_id');
	my $syl_count = 10;
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $syl = &subs::shorthand_name($component, $syl_count);
	my $type = 'text';
	($app,$type) = &subs::typesetter($app);
	&subs::setting_setter({ app => $app, setting => 'pos', value => $type });
	my $init = &subs::setting_initializer($app,$timestamp);
	$app = $init->{'app'};
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = (eval { decode_json $od }) ? decode_json $od : {};
	my $colour = &subs::setting_grabber({ app => $app, setting=> 'colour' });
	$colour =~ s/^#//gi;
	my @rgb = map $_ , unpack 'C*', pack 'H*', $colour;
	$op_d->{$syl . $numero} = {
		'colour' => $colour,
		rgb => \@rgb,
		shorthand_name => &subs::shorthand_name(&subs::format_name($app)),
		app => $app,
		movement => $op_d->{$syl . $numero}->{'movement'} || 'command',
		inverted => $op_d->{$syl . $numero}->{'inverted'},
		numero => $numero,
		measure => $op_d->{$syl . $numero}->{'measure'},
		toggle => $op_d->{$syl . $numero }->{'toggle'} || 0,
		direction => $gb::embedded_components->{$component}->{'direction'},
		component => $component,
		uuid => &subs::random_string_creator(),
		name => $op_d->{$syl . $numero}->{'name'}
	};
	if ($app eq '') {
		delete $op_d->{$syl . $numero};
	}
	my $json_od = encode_json $op_d;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $json_od, subsetting => $chip_id });
	my $pia = eval { return decode_json &subs::setting_grabber({ app => $pre_value, setting => 'ia' }) } || {};
	delete $pia->{$chip_id}->{$numero};
	my $jpia = encode_json $pia;
	&subs::setting_setter({ app => $pre_value, setting => 'ia', value => $jpia });
	my $ia = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'ia'}) } || {};
	$ia->{$chip_id}->{$numero} = {
		movement =>	$op_d->{$syl . $numero}->{'movement'},
		ip => $ip,
		edt => $edt,
		pin => $numero,
		direction => $gb::embedded_components->{$component}->{'direction'},
		component => $component
	};
	my $jia = encode_json $ia;
	&subs::setting_setter({ app => $app, setting => 'ia', value => $jia });
	my $returner = &embedded_pin_grabber({
		edt => $edt,
		numero => $numero,
		component => $component,
		chip_id => $chip_id,
		timestamp => $timestamp,
		component => $component
	});
	my $res = &now_me({ c => $c, timestamp => $timestamp, edt => $edt, chip_id => $chip_id, browser_tab_id => $c->param('browser_tab_id') });
	$c->render('json' => { app => $app, formatted_name => &subs::format_name($app ), html => $returner->{'html'} });
}

# POST /manager/watch/setting
sub action_43995 {
	my $c = shift;
	# A die in here used to be a 500 with an empty body: the panel paints its red
	# dot and says nothing about why. Name the fault in the reply as well as the
	# log, so the dot itself carries the reason.
	my $returner = eval { &watch_setting_save($c) };
	if ($@) {
		my $reason = $@;
		$reason =~ s/\s+/ /g;
		$log->error('watch setting ' . ($c->param('setting') || '?')
			. ' for ' . ($c->param('edt') || '?') . '/' . ($c->param('chip_id') || '?')
			. ' failed: ' . $reason);
		return $c->render(json => { ok => 0, error => $reason }, status => 500);
	}
	$c->render(json => $returner );
}

# GET /manager/watch/diagram
sub action_44078 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'embedded', setting => 'diagrams' }) } || [];
	@{$diagrams} = grep { $_->{'uuid'} eq $uuid } @{$diagrams};
	my $diagram = $diagrams->[0];

	my $op_d = eval { return decode_json &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id }) } || {};
	my $returner = { uuid => $uuid, diagram => $diagram };
	$returner->{'html'} = $c->render_to_string(
		template => 'embedded/diagram',
		d => $diagram,
		op_d => $op_d
	);
	$c->render(json => $returner);
}

# POST /manager/watch/diagram
sub action_44096 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $diagram = eval { return decode_json $c->param('diagram') } || {};
	my $op_d = eval { return decode_json &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id }) } || {};

	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'embedded', setting => 'diagrams'}) } || [];
	my $returner = { diagram => $diagram };
	foreach my $d ( @{$diagrams} ) {
		if ($d->{'uuid'} eq $diagram->{'file'}->{'uuid'}) {
			$d->{'components'} = $diagram->{'components'};
		}
	}
	my $jdiagrams = encode_json $diagrams;
	&subs::setting_setter({ app => 'embedded', setting => 'diagrams', value => $jdiagrams });
	$returner->{'diagrams'} = $diagrams;
	$c->render(json => $returner);
}

# POST /manager/watch/measure
sub action_44117 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $component = $c->param('component');
	my $numero = $c->param('numero');
	my $syl_count = 10;
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	$syl_count = 1 unless $edt eq 'microcontroller';
	my $syl = &subs::shorthand_name($component, $syl_count);
	my $measure = $c->param('measure');

	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op_d = eval { return decode_json $od } || {};

	$op_d->{$syl . $numero}->{'measure'} = $measure;
	my $app = $op_d->{$syl . $numero}->{'app'};
	my $jopd = encode_json $op_d;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', subsetting => $chip_id, value => $jopd });
	my $jia = &subs::setting_grabber({ app => $app, setting => 'ia' });
	if ($app) {
		my $ia = ($jia && (eval { return decode_json $jia })) ? decode_json $jia : {};
		my $entry = &ia_entry_ensure($ia, $chip_id, $numero, $edt, $op_d, $syl, $component);
		$entry->{'measure'} = $measure;
		$jia = encode_json $ia;
		&subs::setting_setter({ app => $app, setting => 'ia', value => $jia });
	}
	my $returner = &embedded_pin_grabber({
		edt => $edt,
		numero => $numero,
		component => $component,
		chip_id => $chip_id,
		timestamp => $timestamp
	});
	$c->render(json => $returner);
}

# GET /manager/watch/set_proxy
sub action_44452 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $lat_calc = 110.574;
	my $long_calc = (111.320 * cos($lat_calc));
	my $scope = $c->param('scope') || 20;
	my $chip_id = $c->param('chip_id');
	my $q = &subs::db_query('select * from continent where uuid = ? and timestamp=?',$uuid, $timestamp);
	my $locations = $q->hashes;

	&subs::setting_setter({ app => $edt, setting => 'watch_scope', value => $scope, subsetting => $chip_id });
	my $proxies = { near => $locations, far => [], here => {}, scope => $scope };
	foreach my $l ( @{$locations} ) {
		my $operator_door = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
		my $od = decode_json $operator_door;
		my $operator = $od->{'b1'}->{'app'};
		&subs::db_update('continent', {
			operator => $operator,
			operator_door => $operator_door,
			type => 'proxy_set',
			scope => $scope
		},{ uuid => $l->{'uuid'}, timestamp => $timestamp });
		my $sloop = &subs::db_query('select * from continent where timestamp=? and uuid=?',$timestamp, $l->{'uuid'});
		my $slur = $sloop->hashes;
		my $sl = $slur->[0];
		$proxies->{'here'} = $sl;
	}

	$c->render(json => $proxies);
}

# GET /manager/watch/list_proxy
sub action_44484 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $q = &subs::db_query('select * from continent where uuid = ? and timestamp=?',$uuid,$timestamp);
	my $locations = $q->hashes;
	my $scope = $c->param('scope') ? $c->param('scope') : 20;
	&subs::setting_setter({ app => $edt, setting => 'watch_scope', value => $scope, subsetting => $chip_id });
	my $proxies = { near => [], far => [], here => {}, scope => $scope };
	my $operator_door = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $od = decode_json $operator_door;
	foreach my $l (@{$locations}) {

		my $operator = $od->{'b1'}->{'app'};
		&subs::db_update('continent',{
			operator => $operator,
			operator_door => $operator_door,
			type => 'proxy_load'
		}, {
			uuid => $l->{'uuid'}, timestamp => $l->{'timestamp'}
		});

		my $similar = &subs::db_query('select * from continent where type=?', 'proxy_set');

		foreach my $sl (@{$similar->hashes}) {
			my $lat = ($sl->{'longitude'} - $l->{'longitude'});
			my $long = ($sl->{'longitude'} - $l->{'longitude'});
			my $radius = 6372.8;
			my @BNA = (deg2rad($l->{'longitude'}), deg2rad(90 - $l->{'latitude'}));
			my @LAX = (deg2rad($sl->{'longitude'}), deg2rad(90 - $sl->{'latitude'}));

			my $distance = great_circle_distance(@BNA, @LAX, $radius);
			my $metres = $distance * 1000;

			$sl->{'distance'} = sprintf("%.2f", $metres);
			$sl->{'ago'} = &subs::duration_sayer(($timestamp - $sl->{'timestamp'}) / 1000);

			if ($metres <= $scope) {
				push @{$proxies->{'near'}}, $sl;
			}
		}
		push @{$proxies->{'near'}}, $l;
		$proxies->{'here'} = $l;
	}
	$proxies->{'html'} = $c->render_to_string(
		template => 'embedded/proxy',
		proxies => $proxies,
	);

	$c->render(json => $proxies);
}

# POST /manager/watch/proxy_load
sub action_44538 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $locations = &subs::db_query('select * from continent where uuid=?', $uuid)->hashes;
	my $location = $locations->[0];

	my $operator_door = decode_json $location->{'operator_door'};
	&subs::setting_setter({ app => $edt, setting => 'operator_door', value => $location->{'operator_door'}, subsetting => $chip_id });

	$c->render('text' => &embedded_grabber($c,$timestamp));
}

# POST /manager/watch/proxy_here
sub action_44552 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $locations = &subs::db_query('select * from continent where timestamp=?', $timestamp)->hashes;
	my $location = $locations->[0];
	&subs::db_update('continent', {
		latitude => $location->{'latitude'},
		longitude => $location->{'longitude'},
	}, {
		uuid => $uuid
	});
	$locations = &subs::db_query('select * from continent where uuid=?', $uuid)->hashes;
	$location = $locations->[0];
	$c->render(json => $location);
}

# POST /manager/watch/proxy_save
sub action_44570 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $chip_id = $c->param('chip_id');
	my $room_max = &subs::setting_grabber({ app => 'me', setting => 'room_max' });

	my $op = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $watch_settings = eval { return decode_json $op } || {};
	my $room_count = $watch_settings->{'__specs'}->{'room_count'} || &subs::setting_grabber({ app => 'me', setting => 'room_count' });
	for (my $n = 1; $n <= $room_max * $room_count; $n++) {
		my $app = $watch_settings->{"b" . $n}->{'app'};
		my $colour = $watch_settings->{"b" . $n}->{'colour'};
		my $movement = $watch_settings->{"b" . $n}->{'movement'};
		$colour =~ s/^#//gi;
		my @rgb = map $_ , unpack 'C*', pack 'H*', $colour;
		$watch_settings->{"b" . $n} = {
			'colour' => $colour,
			rgb => \@rgb,
			shorthand_name => &subs::shorthand_name(&subs::format_name($app)),
			app => $app,
			movement => $movement,
			numero => $n
		};
	}
	my $json_watch = encode_json $watch_settings;
	my $q = &subs::db_update('continent', {
		timestamp => $timestamp,
		operator_door => $json_watch,
		operator => $watch_settings->{'b1'}->{'app'}
	}, {
		uuid => $uuid
	});
	$c->render(text => $uuid);
}

# POST /manager/watch/delete_proxy
sub action_44606 {
	my $c = shift;
	if ($c->param('uuid')) {
		&subs::db_delete('continent', { uuid => $c->param('uuid') });
	}
	$c->render(text => $c->param('uuid') );
}

1;
