package Manager;

# manager_embedded: route actions moved out of Manager.pl, one sub per route so a
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
use JawnOS::Platform::Serial ();

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

use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# POST /manager/embedded/setting
sub action_43011 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $timestamp = $c->param('timestamp');
	my $op_d = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id });

	my $op = eval { return decode_json $op_d } || {};
	$op->{'__specs'}->{$setting} = $value;
	my $jop = encode_json $op;
	&subs::setting_setter({ app => $edt, setting => 'operator_door', subsetting => $chip_id, value => $jop });

	$c->render(json => { $setting => $value });

}

# POST /manager/embedded/now_me
sub action_43099 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $chip_id = $c->param('chip_id');
	my $name = &subs::format_name($c->param('name'));
	my $res = &now_me({ c => $c, timestamp => $timestamp, edt => $edt, ip => $ip, name => $name, chip_id => $chip_id, browser_tab_id => $c->param('browser_tab_id'), force_home => 1 });
	$c->render('text' => $res);
}

# POST /manager/embedded/bt_now_me
sub action_43109 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $timestamp = $c->param('timestamp');
	my $chip_id = $c->param('chip_id');
	my $bt_mac = $c->param('bt_mac');
	my $ip = $c->param('ip');
	my $name = $c->param('name');
	$log->info('Got bt now me');
	$log->info($bt_mac);

	my $res = &now_me({ c => $c, timestamp => $timestamp, edt => $edt, ip => $ip, name => $name, chip_id => $chip_id, browser_tab_id => $c->param('browser_tab_id'), method => 'bluetooth', force_home => 1 });
	$c->render('text' => $res);
}

# GET /manager/embedded
sub action_43129 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');

	my $returner = &embedded_grabber($c,$timestamp);
	$returner->{'html'} = &window_maker({ user_agent => $c->param('user_agent'), app => 'Embedded', timestamp => $timestamp, contents => $returner->{'contents'} }, $timestamp);
	$c->render(json => $returner);
}

# GET /manager/embedded/device_query
sub action_43287 {
	my $c = shift;
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $embedded = &subs::embedded_device($timestamp,$edt,$chip_id);
	my $query = &embedded_device_query($embedded);
	my $od = &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id } );
	my $op_d = eval { return decode_json $od } || {};
	my $html = $c->render_to_string(
		template => 'embedded/device_query',
		query => $query,
		embedded => $embedded,
		edt => $edt,
		chip_id => $chip_id,
		op_d => $op_d
	);
	$c->render(json => { query => $query, html => $html });
}

# POST /manager/embedded/files/delete
sub action_43358 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $embedded = &subs::embedded_device($timestamp,$edt,$chip_id);
	my $file = $c->param('file');
	if ($embedded->{'ip'}) {
		my $op_d = eval { return decode_json &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $embedded->{'chip_id'} }) } || {};
		my $params = {
			file => $file,
			authorization => $op_d->{'__specs'}->{'authorization'}
		};

		my $returner;
		$returner->{'req'} = Mojo::URL->new("http://$embedded->{ip}:$config->{port}/delete_file")
			->query($params)
			->to_string;
		my $ua = Mojo::UserAgent->new();
		$returner->{'res'} = $ua->insecure(1)->get($returner->{'req'})->result;
		# The request URL carries the board's authorization: log who, not what.
		$log->info('embedded delete_file for ' . ($embedded->{'chip_id'} // '?') . ' at ' . ($embedded->{'ip'} // '?'));
		$c->render(json => $returner);
	} else {
		$c->render(json => {});
	}
}

# GET /manager/embedded/pin_grabber
sub action_43384 {
	my $c = shift;
	my $edt = $c->param('edt');
	my $numero = $c->param('numero');
	my $pin = $c->param('pin') || $numero;
	my $form = $c->param('form');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $returner = &embedded_pin_grabber({
		edt => $edt,
		numero => $numero,
		pin => $pin,
		form => $form,
		component => $c->param('component'),
		chip_id => $chip_id,
		timestamp => $timestamp
	});
	$c->render(json => $returner);
}

# GET /manager/embedded/wigi
sub action_43495 {
	my $c = shift;
	my $ip = $c->param('ip');
	my $timestamp = $c->param('timestamp');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $data = {
		ip => $ip,
		timestamp => $timestamp,
		edt => $edt,
		chip_id => $chip_id
	};
	&subs::embedded_wigi($data);
	$c->render(text => 'ok');
}

# POST /manager/embedded/toggle
sub action_43536 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $component = $c->param('component');
	my $pin = $c->param('pin');
	my $ip = $c->param('ip');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $state = $c->param('state');

	my $returner = &embedded_toggle({
		app => $app,
		pin => $pin,
		ip => $ip,
		edt => $edt,
		component => $component,
		timestamp => $timestamp,
		'state' => $state,
		'when' => 'now',
		chip_id => $chip_id
	});
	$c->render(json => $returner);
}

# POST /manager/embedded/ota_uploader
sub action_43561 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');

	if ($edt eq 'microcontroller') {
		# The manager serves firmware from a hardwired path, not .pio/build.
		# scripts/stage_firmware.pl copies the newest build there and leaves a
		# sidecar naming the version, the sha256 and the digest of the sources it
		# came from. A file with no sidecar, one whose bytes moved, or one built
		# from older firmware is the previous image - sending it rolls the board
		# back with nobody asking. Refuse it and name the fix. `force` is for a
		# person who really means to send that image.
		my $staged = &subs::firmware_staged('microcontroller');
		unless ($staged->{'exists'}) {
			return $c->render(json => { success => 0, result => $staged->{'reason'} });
		}
		unless ($staged->{'current'} || $c->param('force')) {
			$log->info('OTA refused: ' . $staged->{'reason'});
			return $c->render(json => { success => 0, result => $staged->{'reason'} });
		}

		&Websocket::send('tab', { console => &Websocket::console_command('show', 'embedded_ota_uploader_wait'), browser_tab_id => $c->param('browser_tab_id') });
		&Websocket::send('tab', { console => &Websocket::console_command('hide', 'embedded_ota_uploader_fail'), browser_tab_id => $c->param('browser_tab_id') });
		&Websocket::send('tab', { console => &Websocket::console_command('hide', 'embedded_ota_uploader_success'), browser_tab_id => $c->param('browser_tab_id') });

		# The device's own Now Me token, the header the board collects, and the
		# streamed body all live in firmware_push: the panel button and the
		# auto-OTA sweep must send an image the same way.
		my $result = &subs::firmware_push({
			edt => $edt,
			chip_id => $chip_id,
			force => ($c->param('force') ? 1 : 0)
		});

		if ($result->{'success'}) {
			&Websocket::send('tab', { console => &Websocket::console_command('hide', 'embedded_ota_uploader_wait'), browser_tab_id => $c->param('browser_tab_id') });
			&Websocket::send('tab', { console => &Websocket::console_command('show', 'embedded_ota_uploader_success'), browser_tab_id => $c->param('browser_tab_id') });
		}
		else {
			&Websocket::send('tab', { console => &Websocket::console_command('hide', 'embedded_ota_uploader_wait'), browser_tab_id => $c->param('browser_tab_id') });
			&Websocket::send('tab', { console => &Websocket::console_command('show', 'embedded_ota_uploader_fail'), browser_tab_id => $c->param('browser_tab_id') });
			$log->info('OTA failed: ' . ($result->{'result'} || 'no answer'));
		}

		$c->render(json => {
			success => $result->{'success'},
			code => $result->{'code'},
			result => $result->{'result'},
			version => $result->{'version'}
		});
	}
	else {
		$c->render(text => 'no');
	}


}

# the esp32 boards have no build path baked into the manager the way the pico
# does: the panel hands over whatever .bin was picked, we stream it to the
# board's own /update and the board flashes itself and reboots.
# POST /manager/embedded/ota_uploader_wifi
sub action_43620 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $ip = $c->param('ip');
	my $edt = $c->param('edt') || '';
	my $chip_id = $c->param('chip_id') || '';
	my $firmware = $c->req->upload('firmware');

	if (!$ip || !$firmware) {
		return $c->render(json => { success => 0, result => 'needs a board ip and a .bin' });
	}

	# The board refuses /update without its own Now Me token, and the manager is
	# the machine that holds that token in operator_door.
	my $od = ($edt && $chip_id) ? &subs::setting_grabber({ app => $edt, setting => 'operator_door', device => $device, subsetting => $chip_id }) : '';
	my $op_d = eval { decode_json $od } || {};
	my $auth = $op_d->{'__specs'}->{'authorization'} || '';
	unless ($auth) {
		return $c->render(json => { success => 0, result => 'no authorization on record - run Now Me first' });
	}

	my $image = $firmware->slurp;
	my $boundary = '----jawnos' . int(rand(1000000000));
	my $body =
		"--$boundary\r\n" .
		"Content-Disposition: form-data; name=\"firmware\"; filename=\"" . ($firmware->filename || 'firmware.bin') . "\"\r\n" .
		"Content-Type: application/octet-stream\r\n\r\n" .
		$image . "\r\n--$boundary--\r\n";

	my $ua = Mojo::UserAgent->new();
	$ua->inactivity_timeout(180000);
	my $res = $ua->post('http://' . $ip . '/update?authorization=' . url_escape($auth) => { 'Content-Type' => "multipart/form-data; boundary=$boundary", authorization => $auth } => $body)->result;
	my $result = $res->is_success ? $res->body : ($res->error ? $res->error->{message} : 'board said ' . $res->code);

	$c->render(json => { success => $res->is_success ? 1 : 0, code => $res->code, result => $result });
}

# GET /manager/embedded/usb_ports
sub action_43673 {
	my $c = shift;
	$c->render(json => { ports => &usb_ports_grabber() });
}

# POST /manager/embedded/usb_upload
sub action_43677 {
	my $c = shift;
	my $edt = $c->param('edt') || 'watch';
	my $chip_id = $c->param('chip_id');
	my $port = $c->param('port');

	my ($project, $environment, $prefer_acm) = $edt eq 'teletype' ? ('./jt', 'deck', 0) : ('./jw', 'watch', 1);

	if ($port && !JawnOS::Platform::Serial::valid_port($port)) {
		return $c->render(json => { started => 0, result => 'that port does not look right' });
	}

	# the watch speaks native USB (ttyACM), the deck sits behind its bridge (ttyUSB);
	# auto-pick when there is exactly one candidate of the right kind
	my $ports = &usb_ports_grabber();
	if (!$port) {
		my @preferred = grep { $_->{'acm'} == $prefer_acm } @{$ports};
		if (@preferred == 1) {
			$port = $preferred[0]->{'path'};
		}
		elsif (scalar @{$ports} == 1) {
			$port = $ports->[0]->{'path'};
		}
	}
	if (!$port) {
		return $c->render(json => { started => 0, result => (scalar @{$ports} ? 'pick a port' : 'no board is plugged in'), ports => $ports });
	}

	my $pio = (-x &subs::home('~/.platformio/penv/bin/pio')) ? &subs::home('~/.platformio/penv/bin/pio') : 'pio';
	my $log = &subs::home('~/.jawnos_usb_upload.log');
	my $project_path = Mojo::File->new($project)->to_abs_path;
	Mojo::File->new($log)->spurt("usb upload to $port starting...\n");
	my $command = 'cd ' . &subs::shell_quote($project_path) . ' && exec ' . &subs::shell_quote($pio) . ' run -j 4 -e ' . &subs::shell_quote($environment) . ' -t upload --upload-port ' . &subs::shell_quote($port);
	system('nohup sh -c ' . &subs::shell_quote($command) . ' > ' . &subs::shell_quote($log) . ' 2>&1 &');

	$c->render(json => { started => 1, port => $port, project => $project });
}

# GET /manager/embedded/usb_upload_status
sub action_43714 {
	my $c = shift;
	my $log = &subs::home('~/.jawnos_usb_upload.log');
	my $text = -e $log ? read_file($log) : '';
	$text = substr($text, -6000) if length($text) > 6000;
	my @percent = ($text =~ m{\((\d+(?:\.\d+)?) %\)}g);
	@percent = ($text =~ m{(\d+(?:\.\d+)?)%}g) unless @percent;
	my $success = ($text =~ m{\[SUCCESS\]}) ? 1 : 0;
	my $failed = (!$success && $text =~ m{\[FAILED\]|error:}) ? 1 : 0;
	my @lines = grep { /\S/ } map { my $l = $_; $l =~ s/^\s+//; $l =~ s/\s+$//; $l } split m{\n}, $text;
	$c->render(json => {
		running => ($success || $failed) ? 0 : 1,
		success => $success,
		failed => $failed,
		percent => (@percent ? $percent[-1] : ''),
		tail => (@lines ? $lines[-1] : '')
	});
}

# Provision a board over its USB serial link: the manager writes the stored WiFi
# and role into config.txt, the board acknowledges and reboots, and it comes up
# on the house network with its pins already restored. This is the out-of-band
# path for a crashed board that is sitting on the desk in its provisioning AP
# (and for a Pico 2 W, which has no Bluetooth stack to fall back on).
# POST /manager/embedded/usb_provision
sub action_43737 {
	my $c = shift;
	my $chip_id = $c->param('chip_id');
	my $edt = $c->param('edt') || 'microcontroller';
	my $port = $c->param('port');
	return $c->render(json => { ok => 0, error => 'need a chip_id' }) unless $chip_id;

	unless ($port) {
		my $ports = &usb_ports_grabber();
		my @acm = grep { $_->{'acm'} } @{$ports};
		if (scalar @acm == 1) { $port = $acm[0]->{'path'}; }
		else {
			# More than one board can be plugged in. The USB descriptor carries
			# the Pico's chip id (the serial number), so pick the one that names
			# this chip rather than asking which cable is which.
			my $key = $chip_id;
			$key =~ s/[^0-9A-F]//gi;
			my @match = grep {
				my $label = $_->{'label'} || '';
				$label =~ /\Q$chip_id\E/i || ($key && $label =~ /\Q$key\E/i)
			} @acm;
			if (scalar @match == 1) { $port = $match[0]->{'path'}; }
			else {
				return $c->render(json => { ok => 0, error => 'choose a port', ports => $ports });
			}
		}
	}
	return $c->render(json => { ok => 0, error => 'that port does not look right' }) unless JawnOS::Platform::Serial::valid_port($port);

	my $wifi = eval { decode_json &subs::setting_grabber({ app => $edt, setting => 'wifi', subsetting => $chip_id }) } || {};
	return $c->render(json => { ok => 0, error => 'this chip has no stored WiFi' }) unless $wifi->{'ssid'} && $wifi->{'password'};
	my $op = eval { decode_json &subs::setting_grabber({ app => $edt, setting => 'operator_door', subsetting => $chip_id }) } || {};

	# The homebase a board calls is this machine, at the port /watch listens on.
	my $address = &subs::network_interface_reporter();
	my @my_ips = map { $address->{$_}->{'ip'} }
		grep { $_ !~ /^(?:lo|tailscale)/ && $address->{$_}->{'ip'} && $address->{$_}->{'ip'} !~ /^127\./ }
		sort keys %{$address};
	my $my_ip = $my_ips[0] || '127.0.0.1';

	# Small on purpose: WiFi, identity and the token are all the board needs to
	# rejoin. Its role (components and internal jobs) is the manager's copy and
	# comes back over BLE, or from /watch once the network is up. A 2.5 KB role
	# blob on this CDC link was where the JSON got truncated.
	# No timestamp/offset here: the board takes the clock from /watch/time (and
	# from now_me over BLE). An offset that serialized as an empty token made
	# the whole file unparseable, which is what put the board back in its AP.
	my $payload = {
		ssid => $wifi->{'ssid'},
		password => $wifi->{'password'},
		ap_ssid => $wifi->{'ap_ssid'},
		ap_password => $wifi->{'ap_password'},
		name => $op->{'__specs'}->{'name'} || '',
		authorization => $op->{'__specs'}->{'authorization'} || '',
		homebase => '',
		homebaseIP => $my_ip . ($ENV{'PORT_ARM'} ? ':' . $ENV{'PORT_ARM'} : '')
	};
	my $json = encode_json $payload;

	JawnOS::Platform::Serial::prepare($port)
		or return $c->render(json => { ok => 0, error => 'could not prepare ' . $port });
	my $fh = JawnOS::Platform::Serial::open_read($port)
		or return $c->render(json => { ok => 0, error => 'could not open ' . $port . ': ' . $! });
	# The Pico's USB CDC receive ring is small; a 2.5 KB line written in one go
	# overflows it and the JSON arrives truncated (the board still answers OK,
	# because the partial object parses). Feed it in small pieces, paced so the
	# sketch's loop drains each one before the next.
	my $line = "JAWNCFG " . $json . "\n";
	JawnOS::Platform::Serial::write_paced($fh, $line, 64, 4);

	my ($buf, $err, $ok) = ('', '', 0);
	$buf = JawnOS::Platform::Serial::read_until($fh, qr/JAWNCFG (?:OK|ERR)/, time() + 8);
	if ($buf =~ /JAWNCFG OK/) { $ok = 1; }
	elsif ($buf =~ /JAWNCFG ERR\s*([^\r\n]*)/) { $err = $1; }
	close $fh;
	# Never hand the echoed command back: it carries the WiFi password and the
	# device authorization. An older firmware echoes it; strip that line.
	my $reply = $buf;
	$reply =~ s/JAWNCFG \{[^\n]*\n?//g;
	$c->render(json => {
		ok => $ok,
		port => $port,
		bytes => length($json),
		reply => $reply,
		error => $ok ? undef : ($err || 'no reply from the board')
	});
}

# GET /manager/embedded/teletype_backup
sub action_43857 {
	my $c = shift;
	my $ip = $c->param('ip');
	my $mac = $c->param('mac');
	my $timestamp = $c->param('timestamp');
	my $teletype = &subs::device_lister($timestamp,'teletype');
	my $chip_id = $c->param('chip_id');
	$c->param('reason' => 'teletype_backup');
  &subs::subprocessor(sub {
    Mojo::IOLoop->reset;

		if ($teletype->{'ip'} && !$teletype->{'uuid'} && $teletype->{'ip'} eq $ip) {
			my $ping_ip = $teletype->{'ip'};
			my $ping_test = '';
			if (&subs::peer_host_is_literal($ping_ip) && open(my $ping_fh, '-|', 'timeout', '.2', 'ping', '-c', '1', $ping_ip)) {
				local $/;
				$ping_test = <$ping_fh> // '';
				close $ping_fh;
			}
			my $backup = &subs::backup_now($c);
			$backup = encode_json $backup;
			if ($ping_test =~ /ttl/gi) {
				my $teletype_url = 'http://' . $teletype->{'ip'} . ':' . $config->{'port'} . '/backup?backup=' . $backup . '&timestamp=' . $timestamp;
				my $ua = Mojo::UserAgent->new();
				my $res = $ua->insecure(1)->get($teletype_url)->result;
			}
		}
	}, { name => 'teletype backup' });
}

# GET /manager/embedded/jobs
sub action_43881 {
	my $c = shift;
	my $ip = $c->param('ip');
	my $mac = $c->param('mac');
	my $edt = $c->param('edt');
	my $chip_id = $c->param('chip_id');
	my $timestamp = $c->param('timestamp');
	my $mc = &subs::device_lister($timestamp, $edt, undef, $chip_id);

	my $wat_set = &subs::setting_grabber({ app => $edt, setting => 'operator_door', device => $device, subsetting => $chip_id });;
	my $watch_settings = eval { return decode_json $wat_set } || {};

	my $auth = $watch_settings->{'__specs'}->{'authorization'};
	# Decode in Perl: a shell would expand $(...) inside the quotes.
	my $author = decode_base64($auth // '');
	my $authorization = &subs::note_decrypter($watch_settings->{'__shutup'}->{'patience'}, $author);





	my $url = 'http://' . $mc->{'ip'} . ':' . $config->{'port'} . '/jobs?authorization=' . $authorization;
	my $ua = Mojo::UserAgent->new();
	my $res = $ua->insecure(1)->get($url)->result;
	my $returner = {};
	if ($res->is_success) {
		my $jobs = eval { return decode_json $res->body } || {};
		$returner->{'jobs'} = $jobs;
		$returner->{'html'} = $c->render_to_string(
			template => 'embedded/jobs',
			jobs => $jobs,
			op_d => $watch_settings
		);
	}

	$c->render(json => $returner);

}

# POST /manager/embedded/delete_job
sub action_43918 {
	my $c = shift;
	my $appt_uuid = $c->param('appt_uuid');
	my $chip_id = $c->param('chip_id');
	my $uuid = $c->param('uuid');
	&embedded_app_deleter({ appt_uuid => $appt_uuid, $chip_id });
	$c->render(json => { uuid => $uuid, appt_uuid => $appt_uuid });
}

# GET /manager/embedded/board_pins
# Ask a board what it is actually wired to, over HTTP when an ip is given and
# over its USB console otherwise, then adopt the answer into the house record.
sub action_43934 {
	my $c = shift;
	my $edt = $c->param('edt') || 'microcontroller';
	my $chip_id = $c->param('chip_id');
	my $ip = $c->param('ip');
	my $port = $c->param('port');

	my $read;
	if ($port) {
		$read = &subs::board_pins_usb_read($port);
	}
	else {
		# No address from the caller: ask the house where this board last
		# answered. A board plugged into another machine's USB still reports
		# over the network, and /pins is guarded like every other board route,
		# so the check needs the door's token.
		if ((!$ip) && defined $chip_id && length $chip_id) {
			my $watch = eval { &subs::device_lister(&subs::rightNow(), $edt, undef, $chip_id) };
			$ip = $watch->{'ip'} if ref $watch eq 'HASH' && defined $watch->{'ip'} && length $watch->{'ip'};
		}
		my $authorization = '';
		if (defined $chip_id && length $chip_id) {
			my $od = eval { decode_json(&subs::embedded_operator_door($edt, $chip_id) || '') } || {};
			$authorization = $od->{'__specs'}->{'authorization'} || '';
		}
		if ($ip) {
			# A board serves /pins on the same house port as /jobs and /device_query.
			$read = &subs::board_pins_http_read($ip, $port || $config->{'port'}, $authorization);
		}
		unless ($read && $read->{'ok'}) {
			my $ports = &usb_ports_grabber();
			my @acm = grep { $_->{'acm'} } @{$ports};
			my $usb_port;
			if (scalar @acm == 1) { $usb_port = $acm[0]->{'path'}; }
			else {
				my $key = $chip_id || '';
				$key =~ s/[^0-9A-F]//gi;
				my @match = grep {
					my $label = $_->{'label'} || '';
					($chip_id && $label =~ /\Q$chip_id\E/i) || ($key && $label =~ /\Q$key\E/i)
				} @acm;
				$usb_port = $match[0]->{'path'} if scalar @match == 1;
			}
			if ($usb_port) {
				my $usb = &subs::board_pins_usb_read($usb_port);
				# Keep the network error when USB cannot answer either: it names
				# the address that did not reply, which is more use than a port.
				$read = $usb if $usb->{'ok'} || !$read;
			}
			elsif (!$read) {
				return $c->render(json => { ok => 0, error => 'choose a port', ports => $ports });
			}
		}
	}
	return $c->render(json => { ok => 0, error => $read->{'error'} }) unless $read && $read->{'ok'};

	my $report = $read->{'report'};
	$edt ||= $report->{'purpose'} || 'microcontroller';
	$chip_id ||= $report->{'chip'};
	my $adopted = &subs::board_pins_adopt($report, { edt => $edt, chip_id => $chip_id });
	$c->render(json => {
		%{$adopted},
		report => $report,
		port => $read->{'port'},
		ip => $read->{'ip'},
	});
}

# POST /manager/embedded/board_pins_attach
sub action_43947 {
	my $c = shift;
	$c->render(json => &subs::board_pins_attach({
		edt => $c->param('edt'),
		chip_id => $c->param('chip_id'),
		pin => $c->param('pin'),
		component => $c->param('component'),
		app => $c->param('app'),
		inverted => $c->param('inverted'),
		movement => $c->param('movement'),
	}));
}

# GET /manager/embedded/remotes
# The board's learned IR sequences, keyed by the name a person gave them.
sub action_44630 {
	my $c = shift;
	my $edt = $c->param('edt') || 'microcontroller';
	my $chip_id = $c->param('chip_id') || '';
	my $remotes = &subs::remote_store_read($edt, $chip_id);
	$c->render(json => { ok => 1, remotes => $remotes });
}

# POST /manager/embedded/remote_learn
# Start a learn window on one pin; the board POSTs the capture back to /watch/ir.
sub action_44631 {
	my $c = shift;
	$c->render(json => &subs::remote_learn_start({
		edt     => $c->param('edt') || 'microcontroller',
		chip_id => $c->param('chip_id'),
		pin     => $c->param('pin'),
		ms      => $c->param('ms'),
	}));
}

# POST /manager/embedded/remote_save
sub action_44632 {
	my $c = shift;
	$c->render(json => &subs::remote_store_add({
		edt     => $c->param('edt') || 'microcontroller',
		chip_id => $c->param('chip_id'),
		pin     => $c->param('pin'),
		seq     => $c->param('seq'),
		name    => $c->param('name'),
	}));
}

# POST /manager/embedded/remote_send
sub action_44633 {
	my $c = shift;
	$c->render(json => &subs::remote_send({
		edt       => $c->param('edt') || 'microcontroller',
		chip_id   => $c->param('chip_id'),
		name      => $c->param('name'),
		appt_uuid => $c->param('appt_uuid'),
	}));
}

# POST /manager/embedded/remote_delete
sub action_44634 {
	my $c = shift;
	$c->render(json => &subs::remote_store_delete({
		edt     => $c->param('edt') || 'microcontroller',
		chip_id => $c->param('chip_id'),
		name    => $c->param('name'),
	}));
}

1;
