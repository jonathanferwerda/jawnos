package Manager;

# manager_misc13: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/keyboard/config
sub action_42519 {
	my $c = shift;
	my $toggle = $c->param('toggle');
	my $remote_uuid = $c->param('remote_uuid');
	my $remoted = $c->param('remoted');
	my $returner = {};
	if ($remote_uuid && !$remoted) {
		$returner = &Manager::remote_relay_request($c);
		$returner = eval { return decode_json $returner } || {};
	}
	else {

		$returner->{'html'} = $c->render_to_string(
			template => 'keyboard_config',
			toggle => $toggle,
			remote_uuid => $remote_uuid
		);
	}
	$c->render(json => $returner);
}

# GET /manager/keyboard_alias
sub action_42557 {
	my $c = shift;
	my $key = $c->param('key');
	my $toggle = $c->param('toggle');
	my $browser_tab_id = $c->param('browser_tab_id');
	my $value = &subs::db_select('settings', ['value','timestamp'], { app => 'keyboard', setting => $toggle, browser_tab_id => $browser_tab_id })->hash;
	my $key_cutter = &subs::decrypter(&subs::session_suds($c),$value->{'value'});
	$key_cutter = decode_json $key_cutter;
	foreach my $k (keys %{$key_cutter}) {
		if ($key_cutter->{$k} eq $key) {
			$key = $k;
		}
	}
	my $path = './public/icons/lettering/' . $key . '.png';
	if (! -e $path) {
		$path = './public/icons/lymeboard' . $key . '.png';
		if (! -e $path) {
			my @b = grep { $_->{'c'} eq $key } @{$gb::inputs};
			if ($b[0]->{'img'}) {
				$path = './public/icons/lymeboard/' . lc $b[0]->{'img'} . '.png';
			}
		}
	}
	my $paths = Mojo::File->new($path);
	$c->render_file('filepath' => $paths->to_string);
}

# GET /manager/say_it
sub action_42585 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $words = $c->param('words');
	my $voice = $c->param('voice');
	&subs::say_it($words, $voice);
	$c->render(text => 'said ' . $words);
	&Websocket::send('server', { json => { type => 'command', command => 'say_it', params => $words, timestamp => $timestamp } });
}

# POST /manager/teletype/enable_tty
sub action_42985 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $enabled = $c->param('enabled');
	my $chip_id = $c->param('chip_id');
	my $saved_enabled = &subs::setting_grabber({ app => $edt, setting => 'enabled', subsetting => $chip_id });
	if ($saved_enabled == 1) {
		$saved_enabled = 0;
	}
	else {
		$saved_enabled = 1;
	}
	my $set = &subs::setting_setter({ app => $edt, setting => 'enabled', value => $saved_enabled, timstamp => $timestamp, subsetting => $chip_id });
	$c->render(json => { enabled => $saved_enabled });
}

# GET /manager/teletype/wifi_update
sub action_43001 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $chip_id = $c->param('chip_id');
	my $json_wifi = &subs::setting_grabber({ app => $edt, setting => 'wifi', subsetting => $chip_id }) || '{}';

	my $wifi = decode_json $json_wifi;
	$c->render(text => $json_wifi);
}

# POST /manager/teletype/appearance
sub action_43028 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $field = $c->param('field');
	my $value = $c->param('value');
	my $chip_id = $c->param('chip_id');
	my $op_d = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });
	my $op = eval { return decode_json $op_d } || {};
	if ($field =~ /colour/gi) {
		my $colour = $value;
		$colour =~ s/^#//gi;
		my @rgb = map $_ , unpack 'C*', pack 'H*', $colour;
		$op->{'__specs'}->{$field . '_rgb'} = \@rgb;
	}
	$op->{'__specs'}->{$field} = $value;
	delete $op->{$field};
	$op_d = encode_json $op;
	my $done = &subs::setting_setter({ app => $edt, setting => 'operator_door', value => $op_d, subsetting => $chip_id });
	$c->render(json => $done);

}

# POST /manager/teletype/wifi_config
sub action_43050 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $field = $c->param('field');
	my $value = $c->param('val');
	my $chip_id = $c->param('chip_id');
	my $json_wifi = &subs::setting_grabber({ app => $edt, setting => 'wifi', subsetting => $chip_id }) || '{}';
	my $wifi = decode_json $json_wifi;
	$wifi->{$field} = $value;
	$json_wifi = encode_json $wifi;

	my $returner = &subs::setting_setter({ app => $edt, setting => 'wifi', value => $json_wifi, subsetting => $chip_id });
	my $teletype = &subs::device_lister($timestamp, $edt);

	$c->render(json => $returner);
}

# POST /manager/teletype/wifi_update
sub action_43067 {
	my $c = shift;
	my $edt = $c->param('edt') || 'watch';
	my $timestamp = $c->param('timestamp');
	my $chip_id = $c->param('chip_id');
	# Prefer the Bluetooth bridge: this button exists to hand a device credentials
	# it does not have yet, so it usually cannot be reached over the network it is
	# trying to join. Read the stored wifi setting back and push it over BLE.
	my $json_wifi = &subs::setting_grabber({ app => $edt, setting => 'wifi', subsetting => $chip_id }) || '{}';
	my $wifi = eval { decode_json $json_wifi } || {};
	if ($wifi->{'ssid'} && &subs::ble_push_available($edt, $chip_id)) {
		# Off the request: the client waits for the radio to acknowledge the write,
		# and a watch that has gone to sleep never does (see bluetooth_sender_async).
		&subs::bluetooth_sender_async({
			intent => 'com.jawn.president.bt.connect',
			chip_id => $chip_id,
			edt => $edt,
			message => { type => 'wifi', data => {
				ssid => $wifi->{'ssid'}, password => $wifi->{'password'},
				ap_ssid => $wifi->{'ap_ssid'}, ap_password => $wifi->{'ap_password'},
			} }
		});
		$c->render(text => 'pushed over bluetooth');
		return;
	}
	# else the device is on the network already: tell it to pull its own copy
	my $teletype = &subs::device_lister($timestamp, $edt, undef, $chip_id);
	# device_lister answers with the whole device array when the chip has no
	# neighbour row (a board that was never seen on the LAN, or whose only
	# sighting has lapsed). Dereferencing that as a hash was a 500; say plainly
	# that neither the link nor the network could reach it.
	if (ref $teletype ne 'HASH' || ($teletype->{'ip'} || '') !~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
		$c->render(text => 'not reachable: no live Bluetooth link and no network address');
		return;
	}
	my $wifi_url = 'http://' . $teletype->{'ip'} . ':' . $config->{'port'} . '/wifi_update';
	my $ua = Mojo::UserAgent->new();
	my $res = $ua->insecure(1)->get($wifi_url)->result;
	$c->render(text => $res->body);
}

# A peer machine hands over one device-to-device relay envelope. The receiving
# manager sends it only if it may serve the target chip; it never fans it out
# again (from_mesh), so one relay cannot loop around the mesh.
# POST /manager/ble/relay
sub action_43851 {
	my $c = shift;
	my $relay = eval { decode_json($c->param('payload') || '') };
	my $ok = ($relay && ref $relay eq 'HASH') ? &subs::ble_relay_route($relay, { from_mesh => 1 }) : 0;
	$c->render(json => { ok => $ok ? 1 : 0 });
}

# GET /manager/past_life_recall
sub action_44615 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $direction = $c->param('direction');
	my $room_check = $c->param('room_check');
	my $report = {};
	my $query = 'select * from websockets where app= ? and timestamp < ? ORDER BY timestamp DESC LIMIT 1';
	my $results;
	if ($direction eq 'load') {
		$query = 'select * from websockets where app= ? and timestamp = ?';
		$results = &subs::db_query($query, 'tab', $timestamp);
	}
	elsif ($direction eq 'forget') {
		$query = 'delete from websockets where app= ? and timestamp = ?';
		$results = &subs::db_query($query, 'tab', $timestamp);
	}
	elsif ($direction eq 'ff') {
		$query = 'select * from websockets where app= ? and timestamp > ? order by timestamp ASC LIMIT 1';
		if ($room_check eq 'true') {
			$query = 'select * from websockets where app= ? and timestamp > ? and room is not null order by timestamp ASC LIMIT 1';
		}
		$results = &subs::db_query($query, 'tab', $timestamp);
	}
	elsif ($direction eq 'rew') {
		if ($room_check eq 'true') {
			$query = 'select * from websockets where app= ? and timestamp < ? and room is not null order by timestamp DESC LIMIT 1';
		}
		$results = &subs::db_query($query, 'tab', $timestamp);
	}
	my $rooms = $results->hashes;

	foreach my $room  ( @{$rooms} ) {
		my $drawings = &subs::db_query('select * from appointments where browser_tab_id=? and file is not null',$room->{'browser_tab_id'})->hashes;
		my $portfolio = [];
		foreach my $d ( @{$drawings} ) {
			my $files = eval { return decode_json $d->{'file'} } || [];
			foreach my $f ( grep { $_->{'type'} eq 'image' || $_->{'type'} eq 'video' } @{$files} ) {
				push @{$portfolio}, $f;
			}
		}

		my $lifetime = localtime( $room->{'timestamp'} / 1000 )->strftime('%a %B %d %Y %I:%M:%S%P');
		my $windows = eval { return decode_json $room->{'windows'} } || {};
		my $appt_count = scalar %{$windows};
		my $playbook = ($room->{'room'} || $room->{'browser_tab_id'} ) . "<br>$lifetime<br><br>";
	#	next unless scalar keys %{$windows} > 0;
		foreach my $w ( keys %{$windows} ) {
			$playbook .= '<span class="room_appt" app="' . $windows->{$w}->{'app'} . '">' . &subs::format_name($windows->{$w}->{'app'}) . '</span><br>';
		}
		$report = {
			room => $room->{'room'},
			timestamp => $room->{'timestamp'},
			user_agent => $room->{'user_agent'},
			lifetime => $lifetime,
			json_windows => $room->{'windows'},
			windows => $windows,
			appt_count => $appt_count,
			playbook => $playbook,
			browser_tab_id => $room->{'browser_tab_id'},
			portfolio => $portfolio
		};
	}

	$c->render(json => $report);
}

# GET /manager/marker
sub action_44680 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app') || 'marker';
	my $browser_tab_id = $c->param('browser_tab_id');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $q = &subs::db_query('select * from appointments where app = ? and file is not null', $app);
	my $drawings = $q->hashes;

	my $settings = &subs::settings_grabber({ app => 'marker' });

	my $contents = $c->render_to_string(
		template => 'marker',
		window_maker => 'yes',
		drawings => $drawings,
		settings => $settings
	);

	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'marker', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# POST /manager/snapshot_save
sub action_44701 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	my $app_path = &subs::path_name($app);
	my $snapshot = $c->param('snapshot');
	my @snapshot = split ',', $snapshot;
	shift @snapshot;
	$snapshot = join ',', @snapshot;
	$snapshot = decode_base64($snapshot);
	my $folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
	my $location = &subs::home($folder) . '/' . $app_path;
	my $filename = $location . '/' . $timestamp . '.png';
	write_file($filename,$snapshot);
	my $jfile = encode_json [{ server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(8), type => 'image' }];
	my $write = {
		timestamp => $timestamp,
		app => &subs::unformat_name($app),
		type => 'image',
		file => $jfile,
		uuid => &subs::random_string_creator(20),
		duration => '1'
	};
	&appointment_writer($c,$write);
	&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => &subs::session_suds($c) });

	$c->render(json => $write);
}

# POST /manager/marker/save
sub action_44729 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $marker = $c->param('marker');
	my $image = $c->param('img');
	my $paper = $c->param('paper');
	my $app = &subs::unformat_name($c->param('app'));
	my $app_path = &subs::path_name($app);
	my $browser_tab_id = $c->param('browser_tab_id');
	my ($db,$database,$sql) = &subs::database_grabber();

	my @image = split ',', $image;
	shift @image;
	$image = join ',', @image;
	$image = decode_base64($image);
	my $folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
	my $location = &subs::home($folder) . '/' . $app_path;
	my $filename = $location . '/' . $timestamp . '.png';
	write_file($filename,$image);
	my $uuid = &subs::random_string_creator(20);
	my $jfile = encode_json [{ server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(18), type => 'image' }];
	my $write = {
		timestamp => $timestamp,
		app => &subs::unformat_name($app),
		type => 'image',
		file => $jfile,
		uuid => $uuid,
		duration => '1',
		browser_tab_id => $browser_tab_id
	};
	&appointment_writer($c,$write);
	&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => &subs::session_suds($c) });

	my $q = &subs::db_query('select * from appointments where app = ? and file is not null',$app);
	my $drawings = $q->hashes;
	my $json = encode_json $drawings || [];
	$c->render(json => $json);
}

# POST /manager/marker/delete
sub action_44767 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $app = $c->param('app');
	my $server_time = $c->param('server_time');

	&delete_file({ app => $app, app_uuid => $app_uuid, file_uuid => $file_uuid });

	$c->render(text => 'ok');
}

# GET /manager/marker/gallery
sub action_44779 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $drawings;
	if ($app) {
		$drawings = &subs::db_select('drawings', undef, { app => $app })->hashes;
	}
	else {
		$drawings = &subs::db_select('drawings')->hashes;
	}
	my $returner = { app => $app, timestamp => $timestamp, drawings => $drawings };
	$returner->{'html'} = '<h2>' . &subs::format_name($app || 'All') . '<div id="marker_exhibition">';
	foreach my $drawing ( @{$drawings} ) {
		$returner->{'html'} .= '<img id="' . $drawing->{'paper'} . '" timestamp="' . $drawing->{'timestamp'} . '" class="paper huge_thumb ' . $drawing->{'paper'} . '" src="' . $drawing->{'image'} . '">';
		$returner->{'html'} .= '<button class="marker_delete ' . $drawing->{'paper'} . '_delete" server_time="' . $drawing->{'server_time'} . '" uuid="' . $drawing->{'uuid'} . '" timestamp="' . $drawing->{'timestamp'} . '" paper="' . $drawing->{'paper'} . '" id="' . $drawing->{'paper'} . '_delete">D</button>';
	}
	$returner->{'html'} .= '</div>';
	$c->render(json => $returner);
}

# POST /manager/marker/session/save
sub action_44844 {
	my $c = shift;
	my $app = $c->param('app');
	$app = &subs::unformat_name($app) if $app;
	$app = 'marker' unless $app;
	my $layers = eval { return decode_json $c->param('layers') } || [];
	if (scalar @{$layers} == 0) {
		$c->render(json => { success => 0 });
		return;
	}
	my $session = {
		uuid => $c->param('session_uuid') || &subs::random_string_creator(20),
		name => $c->param('name') || 'session',
		app => $app,
		working => $c->param('working') ? 1 : 0,
		origin_uuid => $c->param('origin_uuid'),
		origin_name => $c->param('origin_name'),
		thumbnail => $c->param('thumbnail'),
		timestamp => $c->param('timestamp') || &subs::rightNow(),
		layers => $layers
	};
	&marker_session_store($session);
	$c->render(json => { success => 1, uuid => $session->{'uuid'}, sessions => &marker_sessions($app) });
}

# GET /manager/marker/session/list
sub action_44868 {
	my $c = shift;
	my $app = $c->param('app');
	$app = &subs::unformat_name($app) if $app;
	$c->render(json => { sessions => &marker_sessions($app) });
}

# GET /manager/marker/session/load
sub action_44874 {
	my $c = shift;
	my $session_uuid = $c->param('session_uuid');
	my $q = &subs::db_query('select * from cache where app = ? and context = ? and subcontext = ?', 'marker', 'sessions', $session_uuid);
	my $session = eval { return decode_sereal $q->hashes->[0]->{'data'} } || {};
	$c->render(json => $session);
}

# POST /manager/marker/session/delete
sub action_44881 {
	my $c = shift;
	my $session_uuid = $c->param('session_uuid');
	my $app = $c->param('app');
	$app = &subs::unformat_name($app) if $app;
	&subs::db_delete('cache', { app => 'marker', context => 'sessions', subcontext => $session_uuid });
	$c->render(json => { success => 1, sessions => &marker_sessions($app) });
}

# POST /manager/room_namer
sub action_44889 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $room_name = $c->param('room_name');
	my $app = $c->param('app');
	my $browser_tab_id = $c->param('browser_tab_id');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $uuid = &subs::random_string_creator(29);
	my $up = &subs::db_update('websockets', { room => $room_name }, { app => 'tab', browser_tab_id => $browser_tab_id });
	my $room = { browser_tab_id => $uuid, formatted_name => &subs::format_name($room_name), room_name => $room_name, timestamp => $timestamp };
	$c->render(json => $room);
}

# POST /manager/new_room
sub action_44901 {
	my $c = shift;
	my $uuid = &subs::random_string_creator(29);

	my $room = {
		timestamp => $c->param('timestamp'),
		room_name => $c->param('room_name'),
		app => $c->param('app'),
		browser_tab_id => $uuid
	};
	$c->render(json => $room);
}

# GET /manager/update_database
sub action_44913 {
	my $c = shift;
	$c->render('text' => 'no updates');
	&update_database($c);
}

# The code this machine is running: a content fingerprint of the source tree,
# plus the git commit when there is one. Lets any machine (or the device list)
# see whether a peer is on the same code - the remotes have no .git, so the
# fingerprint is what actually detects drift.
# GET /manager/version
sub action_44922 {
	my $c = shift;
	$c->render(json => &subs::code_revision());
}

# GET /manager/health
sub action_45064 {
	my $c = shift;
	unless (&health_allowed($c)) { $c->rendered(403); return; }
	# A peer asking us for a reading is alive: whatever silence earned a backoff
	# is over, so the next levels pass asks it again.
	&subs::levels_peer_announced($c->param('signatorial'));
	$c->render(json => &health_report());
}

# A peer's scheduled wake ends by pushing the row it would show for itself, so a
# handheld that is asleep for most of every four minutes still keeps its peers'
# Levels card current. The row is merged into this machine's cached snapshot and
# the embedded boards are rebuilt from the whole picture, exactly as a pull
# would leave it.
# POST /manager/health_report
sub action_45074 {
	my $c = shift;
	unless (&health_allowed($c)) { $c->rendered(403); return; }
	my $body = $c->req->json;
	unless (ref $body eq 'HASH') { $c->render(json => { ok => 0, error => 'bad body' }); return; }
	my $sig = $body->{'signatorial'} // '';
	unless ($sig =~ /^[0-9a-f]{32}$/) { $c->render(json => { ok => 0, error => 'bad signatorial' }); return; }
	# the peer is awake and telling us so: clear the backoff from when it was not
	&subs::levels_peer_announced($sig);
	# A machine reports only itself. Ignoring a push for our own row stops a
	# stale or spoofed copy replacing the live reading this machine just took.
	if ($sig eq &subs::signatorial_designer()) { $c->render(json => { ok => 1, ignored => 1 }); return; }
	my $snap = &subs::cache_get({ app => '__president', context => 'levels', subcontext => 'current' });
	$snap = { at => &subs::rightNow(), machines => [], devices => [] } unless ref $snap eq 'HASH';
	$snap->{'machines'} = [] unless ref $snap->{'machines'} eq 'ARRAY';
	my @machines = grep { ($_->{'signatorial'} || '') ne $sig } @{ $snap->{'machines'} };
	# The name the house knows a machine by: the OS hostname is often a bare
	# "localhost" on a phone, while the roster's manager URL carries the label
	# (phone.jonathanferwerda.com). Prefer the URL label when the pushed name is
	# generic, exactly as a pull names the row.
	my $hostname = $body->{'hostname'} // '';
	$hostname = substr($hostname, 0, 120);
	unless ($hostname ne '' && $hostname !~ /^(?:localhost|127\.0\.0\.1)$/i) {
		my $rm = &subs::db_select('remote_machines', undef, { signatorial => $sig })->hashes->[0];
		my ($pname) = (($rm ? ($rm->{'manager'} // '') : '') =~ m{^https?://([^/:]+)});
		$pname =~ s/\..*$// if defined $pname && $pname ne '' && $pname !~ /^\d{1,3}(?:\.\d{1,3}){3}$/ && $pname !~ /:/;
		$hostname = $pname if defined $pname && $pname ne '';
	}
	$hostname = 'machine' if $hostname eq '';
	push @machines, {
		signatorial => $sig,
		hostname => $hostname,
		device => $body->{'device'} // '',
		version => $body->{'version'} // '',
		battery => (ref $body->{'battery'} eq 'HASH') ? $body->{'battery'} : {},
		usage => (ref $body->{'usage'} eq 'HASH') ? $body->{'usage'} : undef,
		embedded => (ref $body->{'embedded'} eq 'ARRAY') ? $body->{'embedded'} : [],
		seen => &subs::rightNow(),
	};
	$snap->{'machines'} = \@machines;
	$snap->{'devices'} = &subs::levels_devices(\@machines);
	&subs::cache_set({ app => '__president', context => 'levels', subcontext => 'current', warranty => '-1d' }, $snap);
	$c->render(json => { ok => 1 });
}

# A peer's scheduled wake is its few seconds of availability: it says "my rows
# have moved" and this machine decides whether it needs to pull. The peer's
# newest server_time against the watermark of our last pull from it is a cheap
# answer; the ordinary remote_machine_sync pass then decides precisely and pulls
# through the same path (and counts as that interval's scheduled run).
# POST /manager/available
sub action_45121 {
	my $c = shift;
	unless (&health_allowed($c)) { $c->rendered(403); return; }
	my $body = $c->req->json;
	$body = {} unless ref $body eq 'HASH';
	my $sig = $c->param('signatorial') // '';
	unless ($sig =~ /^[0-9a-f]{32}$/) { $c->render(json => { ok => 0, error => 'bad signatorial' }); return; }
	# a scheduled wake says "I am here": the backoff its silence earned is over
	&subs::levels_peer_announced($sig);
	my $wm = &subs::db_query('select server_time from backups where reason = ? and signatorial = ? and recipient = ? order by server_time desc limit 1',
		'remote_upgraded', $sig, &subs::signatorial_designer())->hashes->[0] || {};
	my $newest = ($body->{'newest'} || 0) + 0;
	my $need = $newest > ($wm->{'server_time'} || 0) ? 1 : 0;
	if ($need) {
		my $now = &subs::rightNow();
		my $pending = &subs::cache_get({ app => '__president', context => 'remote_nudge', subcontext => 'pending' }) || 0;
		&subs::cache_set({ app => '__president', context => 'remote_nudge', subcontext => 'pending', warranty => '-1d' }, $now)
			unless $pending && $now - $pending < 30000;
	}
	$c->render(json => { ok => 1, pull => $need });
}

# POST /manager/address_report
sub action_45146 {
	my $c = shift;
&AddressDirectory::route_report($c);
}

# POST /manager/address_directory
sub action_45147 {
	my $c = shift;
&AddressDirectory::route_directory($c);
}

# GET /manager/address_lookup
sub action_45148 {
	my $c = shift;
&AddressDirectory::route_lookup($c);
}

# GET /manager/health/page
sub action_45150 {
	my $c = shift;
	unless (&health_allowed($c)) { $c->rendered(403); return; }
	my $h = &health_report();
	my $e = sub { &health_html_escape($_[0]) };
	my $db = $h->{'database'};
	my $peers = '';
	foreach my $p ( @{ $h->{'peers'} } ) {
		$peers .= '<tr><td>' . $e->($p->{'hostname'}) . '</td><td>' . $e->($p->{'device'}) . '</td>'
			. '<td>' . $e->($p->{'connection'}) . '</td><td>' . $e->($p->{'version'}) . '</td></tr>';
	}
	$peers = '<tr><td colspan="4" class="dim">no peers linked</td></tr>' unless $peers;
	my $commit = $h->{'commit'} || '-';
	$commit .= ' (dirty)' if $h->{'dirty'};
	my $html = '<!doctype html><html><head><meta charset="utf-8">'
		. '<title>' . $e->($h->{'hostname'}) . ' - jawn health</title>'
		. '<meta http-equiv="refresh" content="5">'
		. '<style>body{font:14px/1.5 system-ui,sans-serif;margin:2rem;color:#222;background:#f7f7f8}'
		. 'h1{font-size:1.15rem}table{border-collapse:collapse;margin:.4rem 0 1.4rem}'
		. 'td,th{border:1px solid #ccc;padding:.2rem .6rem;text-align:left}th{background:#eee}'
		. '.dim{color:#888}.ok{color:#1a7f37;font-weight:600}code{background:#eee;padding:0 .3rem}</style></head><body>'
		. '<h1>' . $e->($h->{'hostname'}) . ' <span class="ok">up</span></h1>'
		. '<table>'
		. '<tr><th>version</th><td>' . $e->($h->{'version'}) . '</td></tr>'
		. '<tr><th>commit</th><td><code>' . $e->($commit) . '</code></td></tr>'
		. '<tr><th>device</th><td>' . $e->($h->{'device'}) . '</td></tr>'
		. '<tr><th>environment</th><td>' . $e->($h->{'environment'}) . '</td></tr>'
		. '<tr><th>schema</th><td>' . $e->($h->{'schema_version'}) . '</td></tr>'
		. '<tr><th>uptime</th><td>' . &health_human_uptime($h->{'uptime'}) . '</td></tr>'
		. '<tr><th>processes</th><td>' . $e->($h->{'processes'}) . '</td></tr>'
		. '<tr><th>database</th><td>' . &health_human_bytes($db->{'bytes'})
			. ' <span class="dim">(wal ' . &health_human_bytes($db->{'wal_bytes'}) . ')</span></td></tr>'
		. '</table>'
		. '<h1>peers</h1><table><tr><th>host</th><th>device</th><th>link</th><th>version</th></tr>' . $peers . '</table>'
		. '<p class="dim">refreshes every 5s</p>'
		. '</body></html>';
	$c->res->headers->content_type('text/html');
	$c->render(data => $html);
}

# POST /manager/setting_setter
sub action_45199 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $subsetting = $c->param('subsetting');
	my $timestamp = $c->param('timestamp');
	# The coding nightly pushes to a repo the house names. The panel has its own
	# validated route, but this generic setter is a public door too: validate the
	# value here so a hand-made POST cannot store spaces or credentials and leave
	# the night unable to read its target.
	if ($setting eq 'coding_push_repo' || $setting eq 'coding_app_push_repo') {
		my $which = $setting eq 'coding_app_push_repo' ? 'app' : 'repo';
		my $check = &subs::coding_push_repo_valid($value);
		unless ($check->{'ok'}) {
			$c->render(json => { ok => 0, error => $check->{'error'} });
			return;
		}
		$value = $check->{'value'};
	}
	# An address field never accepts a phrase that could spend the wallet. JawnOS
	# stores public addresses only, so a seed phrase or private key is refused
	# here as well as in the panel's own warning.
	if (($setting eq 'wallet_address' || $setting eq 'crypto_asset') && &subs::crypto_looks_like_secret($value)) {
		$c->render(json => { ok => 0, error => 'That looks like a seed phrase or private key. JawnOS only stores a public address.' });
		return;
	}
	if ($setting eq 'wallet_address' && defined $value && length $value) {
		my $asset = $c->param('crypto_asset') || &subs::setting_grabber({ app => $app, setting => 'crypto_asset' });
		unless (&subs::crypto_address_valid($asset, $value)) {
			$c->render(json => { ok => 0, error => 'That does not look like a ' . (uc($asset || 'wallet')) . ' address.' });
			return;
		}
	}
	# An xpub is public, but it is still checked here: a private key, a seed
	# phrase, a key for another coin or a testnet key on a mainnet wallet is
	# refused before it is stored. The preview is the next address it would
	# issue, so the seller can compare it with the device before relying on it.
	my $xpub_note;
	if ($setting eq 'wallet_xpub' && defined $value && length $value) {
		$value =~ s/^\s+|\s+$//g;
		if (&subs::crypto_xpub_is_private($value) || &subs::crypto_looks_like_secret($value)) {
			$c->render(json => { ok => 0, error => 'That is a spending key or a seed phrase. JawnOS stores the public xpub only.' });
			return;
		}
		my $x = &subs::crypto_xpub_decode($value);
		unless ($x) {
			$c->render(json => { ok => 0, error => 'That is not an account xpub (xpub, ypub or zpub).' });
			return;
		}
		my $asset = &subs::setting_grabber({ app => $app, setting => 'crypto_asset' }) || 'BTC';
		unless (uc($asset) eq 'BTC') {
			$c->render(json => { ok => 0, error => 'Per-invoice addresses are Bitcoin only for now.' });
			return;
		}
		my $net = &subs::setting_grabber({ app => $app, setting => 'crypto_network' }) || 'bitcoin';
		if (lc($net) eq 'bitcoin' && $x->{'net'} ne 'main') {
			$c->render(json => { ok => 0, error => 'That is a testnet key; this wallet is on Bitcoin mainnet.' });
			return;
		}
		my $q = &subs::db_query("select max(addr_index) as m from crypto_address where app = ?", $app);
		my $row = $q ? $q->hashes->[0] : undef;
		my $next = (defined $row && defined $row->{'m'}) ? $row->{'m'} + 1 : 0;
		my $preview = &subs::crypto_xpub_address($x, $next);
		$xpub_note = $preview
			? 'Watch-only ready. The next invoice address is ' . $preview->{'address'}
			: 'The key was saved, but the next address could not be derived.';
		if (($x->{'depth'} // 0) != 3) {
			$xpub_note = 'Warning: this key is at depth ' . ($x->{'depth'} // 0) . '; an account xpub is usually depth 3. ' . $xpub_note;
		}
	}
	# the settingSetter() client already carries a device when one is asked for
	# (the Guide's associate saves its Confirm tick with device 'all' so every
	# machine reads the one shared row); the route used to drop it and store the
	# value against this device class instead
	my $device = $c->param('device');
	my $s = &subs::setting_setter({ app => $app, setting => $setting, value => $value, timestamp => $timestamp, subsetting => $subsetting, device => $device });
	$s->{'note'} = $xpub_note if defined $xpub_note && ref $s eq 'HASH';
	# Turning tracking on writes the first history point at once, so the Measures
	# app has something to chart without waiting for the six-hour tick.
	if ($app eq 'crypto' && $setting eq 'tracking' && defined $value && $value eq 'on') {
		eval { &subs::crypto_tracking_tick({ force => 1, create => 1 }) };
	}
	# Choosing a different history app while tracking is on writes the first
	# point there at once (and gives an app that has no measures its definitions).
	if ($app eq 'crypto' && $setting eq 'tracking_app' && &subs::crypto_tracking_on()) {
		eval { &subs::crypto_tracking_tick({ force => 1, create => 1 }) };
	}
	# a construct change is a person change: keep the people table beside it
	&people_link_sync() if (($setting eq 'pos' || $setting eq 'mab') && defined $app && length $app);
	$c->render(json => $s);
}

# GET /manager/setting_grabber
sub action_45278 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $s = &subs::setting_grabber({ app => $app, setting => $c->param('setting'), subsetting => $c->param('subsetting') });
	$c->render(json => $s);
}

# POST /manager/setting_deleter
sub action_45284 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $s = &subs::setting_deleter({ app => $app, setting => $c->param('setting'), device => $c->param('device') });
	$c->render(json => $s);
}

# GET /manager/settings_grabber
sub action_45290 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $device = &subs::unformat_name($c->param('device'));
	my $s = &subs::settings::grabber({ app => $app, device => $device });
	$c->render(json => $s);
}

1;
