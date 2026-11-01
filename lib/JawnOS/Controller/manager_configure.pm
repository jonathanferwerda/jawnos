package Manager;

# manager_configure: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/configure/attribute_copy
sub action_6572 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $att = $c->param('att');
	my $app = &subs::unformat_name($c->param('app'));
	my $pre_app = &subs::unformat_name($c->param('pre_app'));
	my $returner = { app => $app, att => $att, uuid => $uuid, pre_app => $pre_app };

	my $attribute = &subs::db_select($att, undef, { uuid => $uuid, app => $pre_app })->hashes->[0];
	$attribute->{'characteristics'} = eval { return decode_json $attribute->{'characteristics'} } || [];
	if ($att eq 'option') {
		my @category = grep { $_->{'name'} eq 'option_category' } @{$attribute->{'characteristics'}};
		my $cat = $category[0];
		my $oc = &subs::db_select('option_category', undef, { app => $pre_app, uuid => $cat->{'value'} })->hashes->[0];

		my $oc_check = &subs::db_select('option_category', undef, { app => $app, name => $oc->{'name'} })->hashes;

		unless ( scalar @{$oc_check} > 0 ) {
			$oc->{'app'} = $app;
			$oc->{'server_time'} = &subs::rightNow();
			$oc->{'uuid'} = &subs::random_string_creator(100);
			&subs::db_insert('option_category', $oc);

		}
		else {
			$oc = $oc_check->[0];
		}
		$cat->{'value'} = $oc->{'uuid'};

		$returner->{'option_category'} = $oc;
	}
	$attribute->{'characteristics'} = encode_json $attribute->{'characteristics'};
	$attribute->{'server_time'} = &subs::rightNow();
	$attribute->{'uuid'} = &subs::random_string_creator(101);
	$attribute->{'app'} = $app;

	my $att_check = &subs::db_select($att, undef, { name => $attribute->{'name'}, app => $app })->hashes;

	if (scalar @{$att_check} > 0 ) {
		my $ac = $att_check->[0];
		$attribute->{'uuid'} = $ac->{'uuid'};
		&subs::db_update($att, $attribute, { uuid => $ac->{'uuid'}, app => $ac->{'app'}, name => $ac->{'name'} });
	}
	else {
		&subs::db_insert($att, $attribute);
	}
	$returner->{'template'} = $c->render_to_string(template => 'pos/attributes', att => $att, app => $app);

	$returner->{'attribute'} = $attribute;

	$c->render(json => $returner);

}

# POST /manager/configure/attribute_upload
sub action_6704 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $attribute = $c->param('attribute');
	my $uuid = $c->param('uuid');
	my $app = $c->param('app');
	my @uploads = @{$c->req->uploads};
	my $image;
	my $returner;
	my $att_files = &subs::db_select($attribute, undef, { uuid => $uuid, app => $app })->hashes->[0];
	my $atf = eval { return decode_json $att_files->{'file'} } || [];
	my (@uploaded_files,$linux_file,$upload_type);
	foreach my $u ( @uploads ) {

		my $server_time = &subs::rightNow();
		$timestamp++;
		my $filen = &subs::unformat_name($u->filename);
		my @f = split /\./, $filen;
		my $ext = pop @f;
		$filen = join '.', @f;
		my $fn = $filen . '_' . $timestamp . '.' . $ext;

		my $upload = {
			type => $u->headers->content_type,
			path => $u->asset->path,
			filename => $fn,
			size => $u->size,
		};

		$app = &subs::unformat_name($app);
		my $init = &subs::setting_initializer($app,$timestamp);
		$app = $init->{'app'};
		my $app_path = &subs::path_name($app);
		push @uploaded_files, $upload;
		my ($folder,$location);

		if ($upload->{'type'} =~ /audio/gi) {
			$upload_type = 'audio';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
		}
		elsif ($upload->{'type'} =~ /video/gi) {
			$upload_type = 'video';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'video_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
		}
		elsif ($upload->{'type'} =~ /pdf/gi) {
			$upload_type = 'scan';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'document_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
		}
		elsif ($upload->{'type'} =~ /application/gi) {
			$upload_type = 'software';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'download_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
		}
		elsif ($upload->{'type'} =~ /image/gi) {
			$upload_type = 'image';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
		}
		else {
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'download_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
		}
		`mkdir -p $location` unless -e $location;
		my $filename = $location . '/' . $upload->{'filename'};
		$u->move_to($filename);
		$linux_file .= `file $filename`;

		if ($upload->{'filename'} =~ /avi$/gi) {
			my $old_filename = $filename;
			$filename =~ s/avi$|mkv$/mp4/;
			my $tn_o = &subs::terminal_name($old_filename);
			my $tn_f = &subs::terminal_name($filename);
			&subs::subprocessor(sub {
				`ffmpeg -i $tn_o $tn_f & exit /b`;
				`shred -u $tn_o`;
				&subs::file_encrypter({ app => $app });
			}, { name => "Video file converter" });
		}
		my $filing = { f => $filename, att => $attribute, att_uuid => $uuid, uuid => &subs::random_string_creator(18), type => $upload_type, server_time => &subs::rightNow() };
		push @{$returner}, $filing;
		push @{$atf}, $filing;


	}

	my $jfile = encode_json $returner;
	my $jafile = encode_json $atf;
	&subs::db_update($attribute, { file => $jafile, server_time => &subs::rightNow() }, { uuid => $uuid, app => $app });
	my $write = {
		timestamp => $timestamp,
		app => &subs::unformat_name($app),
		notes => &subs::note_encrypter(&subs::session_suds($c),$linux_file),
		type => $upload_type,
		file => $jfile,
		uuid => &subs::random_string_creator(20),
		duration => '1000'
	};
	&appointment_writer($c,$write);
	&subs::file_encrypter({ app => $app });
	$c->render(json => $returner);
}

# GET /manager/configure/store_list
sub action_7061 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $store = &store_setting_list();
	$c->render(
		template => 'configure/store_setting_list',
		store => $store,
		pos_list => $gb::pos
	);
}

# GET /manager/configure/device_lister
sub action_7789 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $load_type = $c->param('load_type');
	my $ip = $c->param('host');
	my $ping_scan = $c->param('ping_scan');
	# The host box beside Ping and Scan is one field with two buttons: only Ping
	# used to record it, so clearing the box and pressing Scan redrew it from the
	# value still on record and the clear looked like it never saved. Record the
	# box here too, before the panel is drawn, so what is drawn is what was typed.
	&subs::setting_setter({ app => 'misc', setting => 'ping', value => $ip }) if (($load_type // '') eq 'scan' && defined $ip);
	my $devices = &subs::device_lister($timestamp,$load_type,$ip);
	my $networks = &subs::network_groups($devices);
	my $remote_machines = &subs::remote_machine_orphans($devices);
	my $ble_devices = &subs::ble_device_listing();
	my $routers = &subs::router_list();
	my $ping = &subs::setting_grabber({ app => 'misc', setting => 'ping' });

	$c->render(
		template => 'configure/device_lister',
		devices => $devices,
		networks => $networks,
		remote_machines => $remote_machines,
		ble_devices => $ble_devices,
		routers => $routers,
		ping => $ping,
		ping_scan => $ping_scan,
		ip => $ip,
		load_type => $load_type
	);
}

# A printer's own ink and toner, asked over IPP when its row in the Dev panel
# opens. A separate call, so a printer that is off cannot stall the whole device
# listing - the readout fills in a moment later, or says the printer is away.
# GET /manager/configure/printer_ink
sub action_7966 {
	my $c = shift;
	$c->render(json => &subs::printer_ink_levels($c->param('ip')));
}

# POST /manager/configure/device_purpose
sub action_7970 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my ($db,$database,$sql) = &subs::database_grabber();
	my $ip = $c->param('ip');
	my $mac = $c->param('mac');
	my $uuid = $c->param('uuid');
	my $purpose = $c->param('purpose');
	my $dev = &subs::db_query('select * from devices where uuid=?',$uuid);
	my $devices = $dev->hashes;
	foreach my $d ( @{$devices} ) {
		my $address = decode_json $d->{'address'};
		foreach my $nic ( keys %{$address} ) {
			foreach my $neigh ( @{$address->{$nic}->{'neigh'}} ) {
				if ($neigh->{'ip'} eq $ip && $neigh->{'mac'} eq $mac) {
					$neigh->{'purpose'} = $purpose;
				}
			}
		}
		my $json_address = encode_json $address;
		&subs::db_update('devices', { address => $json_address }, { uuid => $uuid });
	}
	$c->render('text' => 'done');
}

# GET /manager/configure/me_settings
sub action_8043 {
	my $c = shift;
	my $pos = &subs::setting_grabber({ app => 'me', setting => 'pos' });
	my $me = &me_setting_list();
	$c->render(
		template => 'configure/me_setting_list',
		me => $me,
		pos_list => $gb::pos
	);
}

# The Platform panel: every AI model choice and provider credential in one place.
# GET /manager/configure/plat_setting_list
sub action_8054 {
	my $c = shift;
	$c->render(template => 'configure/plat_setting_list');
}

# ---- crypto (Configure -> Plat -> Crypto) -----------------------------------
# Wallets are ordinary account apps; this panel owns the assets, the live rates
# and how a wallet is valued. It never holds a key: only an address is stored.
# GET /manager/configure/crypto_panel
sub action_8061 {
	my $c = shift;
	$c->render(text => $c->render_to_string('configure/crypto_setting_list'));
}

# POST /manager/configure/crypto_refresh
sub action_8065 {
	my $c = shift;
	my $result = eval { &subs::crypto_rates_refresh({ force => 1 }) } || { ok => 0, error => 'the refresh failed' };
	$c->render(json => $result);
}

# ---- pay (Configure -> Plat -> Pay) ----------------------------------------
# The panel is one page: Crypto first, then the hosted checkouts and Interac.
# A provider's keys are sealed the same way an AI key is; a blank secret field
# means "keep what is saved", so the panel never has to carry a key back out.
# GET /manager/configure/pay_panel
sub action_8074 {
	my $c = shift;
	$c->render(text => $c->render_to_string('configure/pay_setting_list'));
}

# ---- OAuth2 clients (Configure -> Plat -> OAuth2) ---------------------------
# One entry per app registration; several mail accounts can share one.
# GET /manager/configure/oauth_panel
sub action_8791 {
	my $c = shift;
	$c->render(text => $c->render_to_string('configure/oauth_clients'));
}

# POST /manager/configure/oauth_client/add
sub action_8794 {
	my $c = shift;
	my $clients = &subs::oauth_clients();
	push @{$clients}, { uuid => &subs::random_string_creator(15), name => 'New client', provider => 'microsoft' };
	&subs::oauth_clients_store($clients);
	$c->render(json => { result => 'ok' });
}

# POST /manager/configure/oauth_client/save
sub action_8800 {
	my $c = shift;
	my $uuid = $c->param('uuid') || '';
	my $field = $c->param('field') || '';
	my $value = $c->param('value');
	$value = '' unless defined $value;
	my $clients = &subs::oauth_clients();
	my ($client) = grep { ($_->{'uuid'} || '') eq $uuid } @{$clients};
	return $c->render(json => { result => 'no client' }) unless $client;
	return $c->render(json => { result => 'bad field' }) unless $field =~ /^(name|provider|client_id|client_secret|tenant|scope)$/;
	$value = &subs::note_encrypter(&subs::session_suds($c), $value) if $field eq 'client_secret';
	$client->{$field} = $value;
	&subs::oauth_clients_store($clients);
	$c->render(json => { result => 'ok' });
}

# POST /manager/configure/oauth_client/remove
sub action_8814 {
	my $c = shift;
	my $uuid = $c->param('uuid') || '';
	my $clients = &subs::oauth_clients();
	@{$clients} = grep { ($_->{'uuid'} || '') ne $uuid } @{$clients};
	&subs::oauth_clients_store($clients);
	$c->render(json => { result => 'ok' });
}

# ---- DNS credentials (Configure -> Plat -> DNS) ----------------------------
# The provider a certificate is issued through. A wildcard can only be proved
# by DNS-01, which needs no inbound port - the only challenge a machine behind
# NAT can pass. The token is sealed with the house key, the same as an OAuth
# client secret, so it syncs as ciphertext and is never shown again.
# GET /manager/configure/dns_panel
sub action_8827 {
	my $c = shift;
	$c->render(text => $c->render_to_string('configure/dns_clients'));
}

# POST /manager/configure/dns_client/add
sub action_8831 {
	my $c = shift;
	my $clients = &tls::dns_clients();
	push @{$clients}, { uuid => &subs::random_string_creator(15), name => 'New provider', provider => 'cloudflare', zone => '' };
	&tls::dns_clients_store($clients);
	$c->render(json => { result => 'ok' });
}

# POST /manager/configure/dns_client/save
sub action_8838 {
	my $c = shift;
	my $uuid = $c->param('uuid') || '';
	my $field = $c->param('field') || '';
	my $value = $c->param('value');
	$value = '' unless defined $value;
	my $clients = &tls::dns_clients();
	my ($client) = grep { ($_->{'uuid'} || '') eq $uuid } @{$clients};
	return $c->render(json => { result => 'no client' }) unless $client;
	return $c->render(json => { result => 'bad field' }) unless $field =~ /^(name|provider|zone|token|key|secret)$/;
	if ($field =~ /^(?:token|key|secret)$/) {
		return $c->render(json => { result => 'empty' }) unless length $value;
		$value = &tls::dns_seal($value, &subs::session_suds($c));
	}
	$client->{$field} = $value;
	# A different provider cannot use the old one's secrets: drop them so a
	# Cloudflare token is never sent to GoDaddy by accident.
	if ($field eq 'provider') {
		foreach my $k ( qw/token key secret/ ) { $client->{$k} = ''; }
	}
	&tls::dns_clients_store($clients);
	$c->render(json => { result => 'ok' });
}

# POST /manager/configure/dns_client/remove
sub action_8861 {
	my $c = shift;
	my $uuid = $c->param('uuid') || '';
	my $clients = &tls::dns_clients();
	@{$clients} = grep { ($_->{'uuid'} || '') ne $uuid } @{$clients};
	&tls::dns_clients_store($clients);
	$c->render(json => { result => 'ok' });
}

# POST /manager/configure/dns_client/test
sub action_8869 {
	my $c = shift;
	my $client = &tls::dns_client($c->param('uuid') || '');
	return $c->render(json => { result => 'no client' }) unless $client;
	my ($ok, $message) = &tls::dns_check($client);
	$c->render(json => { result => ($ok ? 'ok' : 'error'), message => $message });
}

# Cloudflare is the one provider the AI panel also holds a token for, so either
# direction copies it, sealed. No other provider's credential is shared.
# POST /manager/configure/dns_client/from_ai
sub action_8878 {
	my $c = shift;
	my $client = &tls::dns_client($c->param('uuid') || '');
	return $c->render(json => { result => 'no client' }) unless $client;
	return $c->render(json => { result => 'error', message => 'Cloudflare only' }) unless ($client->{'provider'} || '') eq 'cloudflare';
	my $suds = &subs::session_suds($c);
	my $stored = &subs::setting_grabber({ app => 'mail', setting => 'cloudflare_token' });
	return $c->render(json => { result => 'error', message => 'no Cloudflare token under Plat -> AI' }) unless length $stored;
	my $plain = eval { &subs::note_decrypter($suds, $stored) } || '';
	$plain = $stored unless length $plain;
	my $clients = &tls::dns_clients();
	my ($row) = grep { ($_->{'uuid'} || '') eq $client->{'uuid'} } @{$clients};
	$row->{'token'} = &tls::dns_seal($plain, $suds);
	&tls::dns_clients_store($clients);
	$c->render(json => { result => 'ok' });
}

# POST /manager/configure/dns_client/to_ai
sub action_8894 {
	my $c = shift;
	my $client = &tls::dns_client($c->param('uuid') || '');
	return $c->render(json => { result => 'no client' }) unless $client;
	return $c->render(json => { result => 'error', message => 'Cloudflare only' }) unless ($client->{'provider'} || '') eq 'cloudflare';
	my $plain = &tls::dns_plain($client->{'token'});
	return $c->render(json => { result => 'error', message => 'save a token first' }) unless length $plain;
	my $suds = &subs::session_suds($c);
	&subs::setting_setter({ app => 'mail', setting => 'cloudflare_token', value => &subs::note_encrypter($suds, $plain) });
	$c->render(json => { result => 'ok' });
}

# ---- the house's public names ----------------------------------------------
# config.json's `domain` stays the loopback the house calls itself on. These two
# routes own the public side: the zone (which is also the WebAuthn RP ID) and the
# name each machine answers on, keyed by signatorial so one machine can name all
# of them.
# POST /manager/configure/domain/house
sub action_8910 {
	my $c = shift;
	my $v = $c->param('domain') || '';
	$v =~ s/^\s+|\s+$//g;
	$v =~ s{^https?://}{}i;
	$v =~ s{/.*$}{};
	$v =~ s{:\d+$}{};
	return $c->render(json => { result => 'error', message => 'a domain like example.com' }) unless $v =~ /^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$/i;
	$v = lc $v;
	&subs::setting_setter({ app => '__president', setting => 'house_domain', device => 'all', value => $v });
	$c->render(json => { result => 'ok', domain => $v });
}

# POST /manager/configure/domain/host
sub action_8922 {
	my $c = shift;
	my $sig = $c->param('signatorial') || '';
	my $host = $c->param('host') || '';
	$host =~ s/^\s+|\s+$//g;
	$host =~ s{^https?://}{}i;
	$host =~ s{/.*$}{};
	$host =~ s{:\d+$}{};
	$host = lc $host;
	my $house = &subs::house_domain();
	return $c->render(json => { result => 'error', message => 'set the house domain first' }) unless length $house;
	$sig = lc $sig;
	return $c->render(json => { result => 'error', message => 'not a signatorial' }) unless $sig =~ /^[0-9a-f]{8,64}$/;
	if (length $host) {
		return $c->render(json => { result => 'error', message => 'must be under ' . $house }) unless $host eq $house || $host =~ /\.\Q$house\E$/;
		return $c->render(json => { result => 'error', message => 'letters, digits, dots and hyphens only' }) unless $host =~ /^[a-z0-9.-]+$/;
	}
	my $map = &subs::device_hosts();
	if (length $host) { $map->{$sig} = $host; }
	else { delete $map->{$sig}; }
	&subs::setting_setter({ app => '__president', setting => 'device_hosts', device => 'all', value => encode_json($map) });
	$c->render(json => { result => 'ok', host => $host });
}

# POST /manager/configure/me_setting
sub action_9257 {
	my $c = shift;
	my $value = $c->param('value');
	if ($value =~ /\%$/gi) {
		$value =~ s/\%$//gi;
		$value = ($value / 100) + 1;
	}
	my $setting = &subs::setting_setter({
		app => 'me',
		setting => $c->param('setting'),
		value => $value,
		device => $c->param('device'),
		timestamp => $c->param('timestamp')
	});
	$c->render(json => $setting);
}

# POST /manager/configure/mugshot_upload
sub action_9304 {
	my $c = shift;
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $dev = $c->param('device') || $device;
	my @uploads = @{$c->req->uploads};
	my $image;
	if (scalar @uploads > 0) {
		# The mugshot is a picture, so it is stored like one: sealed under the photo
		# location's `me` folder. It used to be a multi-megabyte data URI in the
		# settings table, which every load and every sync paid for.
		my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $dev });
		my $location = &subs::home($folder) . '/me';
		`mkdir -p "$location"` unless -e $location;
		foreach my $u ( @uploads ) {
			my $ass = $u->asset->slurp;
			my $raw = $location . '/mugshot.png';
			write_file($raw, $ass);
			my $secret = &subs::suds_grabber();
			my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
			my $sealed = "mugshot.$dev.png.enc";
			&subs::openssl_file_crypt('e', $standard, $secret, $raw, "$location/$sealed", 0, 1);
			`shred -u "$raw"`;
			&subs::setting_setter({ app => 'me', setting => 'mugshot', device => $dev, value => $sealed });
			$image = &Manager::mugshot_source($dev);
		}
	}
	$c->render(text =>  $image );
}

# POST /manager/configure/logo_upload
sub action_9374 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my @uploads = @{$c->req->uploads};
	my $image;
	my $ass;
	if (scalar @uploads > 0) {
		foreach my $u ( @uploads ) {
		  $ass = $u->asset->slurp;
			$image = 'data:image/png;base64,' . encode_base64($ass);
			&subs::setting_setter({ app => 'me', setting => 'logo', value => $image });
		}
	}
	$c->render(text =>  $image );
}

# GET /manager/configure/misc_setting_list
sub action_9391 {
	my $c = shift;
	our $voice_synced_at;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	# Gather the voice models alongside this panel, the way the Plat panel reads
	# the AI model lists when it opens - on demand, not on a timer. Background, and
	# at most once a minute, so opening Configure never waits on a peer.
	unless ($voice_synced_at && (&subs::rightNow() - $voice_synced_at) < 60000) {
		$voice_synced_at = &subs::rightNow();
		&subs::subprocessor(sub { Mojo::IOLoop->reset; eval { &subs::voice_sync(); }; }, { name => 'voice sync' });
	}
	my $settings = &misc_setting_list();
	# only the standards this house can actually seal with (the AES family runs
	# in-process, the rest through openssl); `openssl enc -ciphers` offered every
	# cipher openssl lists, most of which the scheme cannot use
	my @encryption_standards = @{ &subs::note_encryption_standards() };
	$c->render(
		template => 'configure/misc_setting_list',
		settings => $settings,
		encryption_standards => \@encryption_standards,
		photo_sizes => $gb::photo_sizes,
		thumbnail_sizes => $gb::thumbnail_sizes,
		folders => $config->{'folders'},
		translation_languages => &subs::translation_languages(),
		translation_model => &subs::setting_grabber({ app => 'mail', setting => 'help_assistant' }),
		translation_model_fallback => &subs::setting_grabber({ app => 'mail', setting => 'help_assistant_fallback' }),
		config => &subs::config_reader()
	);
}

# POST /manager/configure/misc_setting
sub action_9421 {
	my $c = shift;
	&subs::cache_delete({ app => '__president', context => 'config' });
	my $signatorial = &subs::signatorial_designer();
	my $device = $c->param('device');
	my $returner = [];
	if ($device eq &subs::device_setter()) {
		my $data = {
			app => 'misc',
			setting => $c->param('setting'),
			value => $c->param('value'),
			device => $signatorial,
			timestamp => $c->param('timestamp')
		};
		push @{$returner}, $data;
		&subs::setting_setter($data);
	}

	my $data = {
		app => 'misc',
		setting => $c->param('setting'),
		value => $c->param('value'),
		device => $c->param('device'),
		timestamp => $c->param('timestamp')
	};
	push @{$returner}, $data;
	&subs::setting_setter($data);
	$c->render(json => $returner);
}

# A colour scheme changes every misc surface at once. Posting each swatch's own
# change event meant ~23 requests and ~46 writes for one pick, and each response
# repainted the desktop: on the WebKitGTK desktop that held the CPU for tens of
# seconds. The scheme picker sends this one batch instead, so the server clears
# the config cache once and the browser repaints once.
# POST /manager/configure/misc_settings
sub action_9455 {
	my $c = shift;
	my $signatorial = &subs::signatorial_designer();
	my $device = $c->param('device') || &subs::device_setter();
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	my $settings = eval { decode_json($c->param('settings') || '{}') } || {};
	return $c->render(json => { error => 'no settings' }) unless ref $settings eq 'HASH' && scalar keys %{$settings};
	&subs::cache_delete({ app => '__president', context => 'config' });
	my @applied;
	foreach my $setting ( keys %{$settings} ) {
		my $value = $settings->{$setting};
		if ($device eq &subs::device_setter()) {
			&subs::setting_setter({ app => 'misc', setting => $setting, value => $value, device => $signatorial, timestamp => $timestamp });
			push @applied, { setting => $setting, value => $value, device => $signatorial };
		}
		&subs::setting_setter({ app => 'misc', setting => $setting, value => $value, device => $device, timestamp => $timestamp });
		push @applied, { setting => $setting, value => $value, device => $device };
	}
	$c->render(json => \@applied);
}

# ---- named themes ----------------------------------------------------------
# A theme is the whole dressing (paint, icons, material, face, corner); these
# routes save and remove the ones a person names. Presets live in
# subroutines.pl::theme_presets and can never be overwritten. A saved theme is
# one house-wide settings row, so an appointment may name it on any machine.
# POST /manager/configure/theme_save
sub action_9480 {
	my $c = shift;
	my $name = $c->param('name') // '';
	$name =~ s/^\s+|\s+$//g;
	return $c->render(json => { error => 'a theme needs a name' }) unless length $name && length($name) <= 60;
	my $slug = $c->param('slug') // '';
	unless ($slug =~ /^[a-z0-9][a-z0-9_-]{0,39}$/) {
		$slug = lc $name;
		$slug =~ s/[^a-z0-9]+/-/g;
		$slug =~ s/^-+|-+$//g;
		$slug = 'theme' unless length $slug;
		$slug = substr($slug, 0, 40);
	}
	# a saved theme must not take a preset's name: the preset is the house's own
	$slug = 'custom-' . $slug if $subs::theme_presets{$slug};
	# a new theme with a name already in use gets its own slug rather than
	# silently overwriting the older theme
	unless (length($c->param('slug') // '')) {
		my $base = $slug;
		my $n = 2;
		while ( &subs::db_query('select 1 from settings where app = ? and setting = ? and subsetting = ?', 'misc', 'appearance_theme_custom', $slug)->hashes->[0] ) {
			$slug = $base . '-' . $n++;
		}
	}
	my $scheme = $c->param('scheme') // '';
	$scheme = '' unless $subs::colour_schemes{$scheme};
	my $icon_set = $c->param('icon_set') // '';
	$icon_set = '' unless grep { $_ eq $icon_set } @gb::icon_sets;
	my $texture = $c->param('texture') // '';
	$texture = '' unless grep { $_ eq $texture } @gb::textures;
	my $font = &subs::theme_safe_font($c->param('font'));
	my $corner = &subs::theme_safe_corner($c->param('corner'));
	my $accent = $c->param('accent') // '';
	$accent = '' unless $accent =~ /^\#?[0-9a-fA-F]{6}$/;
	$accent = '#' . lc $accent if $accent =~ /^[0-9a-fA-F]{6}$/;
	my $now = &subs::rightNow();
	my $value = encode_json({
		name => $name, scheme => $scheme, icon_set => $icon_set,
		texture => $texture, font => $font, corner => $corner, accent => $accent,
	});
	my $existing = &subs::db_query(
		'select rowid from settings where app = ? and setting = ? and subsetting = ?',
		'misc', 'appearance_theme_custom', $slug
	)->hashes->[0];
	if ($existing) {
		&subs::db_update('settings', {
			value => $value, device => 'all', timestamp => $now, server_time => $now,
		}, { rowid => $existing->{'rowid'} });
	}
	else {
		&subs::db_insert('settings', {
			app => 'misc', setting => 'appearance_theme_custom', subsetting => $slug,
			device => 'all', value => $value, timestamp => $now, server_time => $now,
		});
	}
	&subs::icon_set_forget();
	&subs::cache_delete({ context => 'template' });
	&subs::cache_delete({ context => 'header' });
	&subs::appointment_theme_push();
	$c->render(json => { slug => $slug, name => $name, bundle => &subs::theme_bundle($slug) });
}

# POST /manager/configure/theme_delete
sub action_9541 {
	my $c = shift;
	my $slug = $c->param('slug') // '';
	return $c->render(json => { error => 'no theme' }) unless $slug =~ /^[a-z0-9][a-z0-9_-]{0,39}$/;
	return $c->render(json => { error => 'a preset cannot be deleted' }) if $subs::theme_presets{$slug};
	&subs::db_delete('settings', { app => 'misc', setting => 'appearance_theme_custom', subsetting => $slug });
	# a desk wearing the theme falls back to the Misc surfaces rather than to a
	# name that no longer resolves
	my $chosen = &subs::db_query(
		'select rowid from settings where app = ? and setting = ? and value = ?',
		'misc', 'appearance_theme', $slug
	)->hashes;
	foreach my $row ( @{$chosen} ) {
		&subs::db_update('settings', { value => '', server_time => &subs::rightNow() }, { rowid => $row->{'rowid'} });
	}
	&subs::icon_set_forget();
	&subs::cache_delete({ context => 'template' });
	&subs::cache_delete({ context => 'header' });
	&subs::appointment_theme_push();
	$c->render(json => { deleted => 1, slug => $slug });
}

1;
