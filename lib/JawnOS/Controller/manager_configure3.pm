package Manager;

# manager_configure3: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/configure/remote_device_locker
sub action_12455 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $ip = $c->param('ip');
	my $status = $c->param('status');
	my $nic = $c->param('nic');
	my $device = &subs::db_select('devices', undef, { uuid => $uuid })->hashes->[0];
	my $address = eval { return decode_json $device->{'address'} };

	my @remote_device = grep { $_->{'ip'} eq $ip } @{$address->{$nic}->{'neigh'}};

	my $rd = $remote_device[0];
	if ($status eq 'yes') {
		$rd->{'locked'} = 'no';
	}
	else {
		$rd->{'locked'} = 'yes';
	}
	@{$address->{$nic}->{'neigh'}} = grep { $_->{'ip'} ne $ip } @{$address->{$nic}->{'neigh'}};
	push @{$address->{$nic}->{'neigh'}}, $rd;
	@{$address->{$nic}->{'neigh'}} = sort { $a->{'ip'} cmp $b->{'ip'} } @{$address->{$nic}->{'neigh'}};
	my $jaddress = encode_json $address;
	&subs::db_update('devices', { address => $jaddress }, { uuid => $uuid });

	$c->render(json => $rd);
}

# POST /manager/configure/device_domain_updater
sub action_12504 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $domain = $c->param('domain');
	my $uuid = $c->param('uuid');
	&subs::db_update('devices', { 'domain' => $domain }, { timestamp => $timestamp, uuid => $uuid });
	$c->render(text => 'ok');
}

# POST /manager/configure/device/neighbour_delete
sub action_12513 {
	my $c = shift;
	my $rm_uuid = $c->param('rm_uuid');
	my $uuid = $c->param('uuid');
	my $device_uuid = $c->param('device_uuid');

	my $device = &subs::db_select('devices', undef, { uuid => $device_uuid })->hashes->[0];
	my $address = eval { return decode_json $device->{'address'} };
	foreach my $nic ( keys %{$address} ) {
		@{$address->{$nic}->{'neigh'}} = grep { $_->{'uuid'} ne $uuid } @{$address->{$nic}->{'neigh'}};
	}

	my $jaddress = encode_json $address;
	&subs::db_update('devices', { address => $jaddress }, { uuid => $device_uuid });
	if ($rm_uuid) {
		&subs::db_delete('remote_machines', { uuid => $rm_uuid });
	}

	$c->render(text => 'ok');

}

# POST /manager/configure/device_deleter
sub action_12534 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	&subs::db_delete('devices', { timestamp => $timestamp, uuid => $uuid });
	$c->render(text => 'deleted');
}

# POST /manager/configure/nfc/setting
sub action_12542 {
	my $c = shift;
	my $app = $c->param('app');
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $uuid = $c->param('uuid');

	my $nfc = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'nfc' }) } || [];
	my ($n) = grep { $_->{'uuid'} eq $uuid } @{$nfc};

	unless ($n) {
		push @{$nfc}, {
			uuid => $uuid,
			$setting => $value
		};
	}
	else {
		$n->{$setting} = $value;
	}

	my $jnfc = encode_json $nfc;
	&subs::setting_setter({ app => $app, setting => 'nfc', value => $jnfc });

	$c->render(json => $nfc);
}

# POST /manager/configure/nfc/delete
sub action_12567 {
	my $c = shift;
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $nfc = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'nfc' }) } || [];

	@{$nfc} = grep { $_->{'uuid'} ne $uuid } @{$nfc};

	my $jnfc = encode_json $nfc;
	&subs::setting_setter({ app => $app, setting => 'nfc', value => $jnfc });

	$c->render(json => { app => $app, uuid => $uuid });
}

# POST /manager/configure/contact/setting
sub action_12591 {
	my $c = shift;
	my $app = $c->param('app');
	my $list = ($c->param('list') || '') eq 'emails' ? 'emails' : 'phones';
	my $field = $c->param('field') || '';
	my $value = $c->param('value');
	$value = '' unless defined $value;
	my $uuid = $c->param('uuid') || '';
	return $c->render(json => { error => 'bad field' }) unless grep { $field eq $_ } qw/type label value/;

	my $rows = &contact_list_row_finder($app, $list);
	my ($row) = grep { ($_->{'uuid'} || '') eq $uuid } @{$rows};
	unless ($row) {
		$row = { uuid => $uuid, type => 'mobile', label => '', value => '' };
		push @{$rows}, $row;
	}
	$row->{$field} = $value;
	&subs::setting_setter({ app => $app, setting => $list, value => encode_json $rows });
	$c->render(json => $row);
}

# POST /manager/configure/contact/delete
sub action_12611 {
	my $c = shift;
	my $app = $c->param('app');
	my $list = ($c->param('list') || '') eq 'emails' ? 'emails' : 'phones';
	my $uuid = $c->param('uuid') || '';
	my $rows = &contact_list_row_finder($app, $list);
	my $before = scalar @{$rows};
	@{$rows} = grep { ($_->{'uuid'} || '') ne $uuid } @{$rows};
	&subs::setting_setter({ app => $app, setting => $list, value => encode_json $rows }) if scalar @{$rows} != $before;
	$c->render(json => { app => $app, uuid => $uuid });
}

# GET /manager/configure/pseudonym_list
sub action_13484 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');

	my ($db,$database,$sql) = &subs::database_grabber();

	my $pseudonyms = &pseudonym_maker('','');
	$c->render(
		template => '/configure/pseudonym_list',
		pseudonyms => $pseudonyms
	);
}

# POST /manager/configure/pseudonym_setter
sub action_13496 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	&subs::cache_delete({ app => 'me', context => 'pseudonyms' });
	my $custom_pseudonyms = eval { return decode_json &subs::setting_grabber({ app => 'config', setting => 'pseudonyms' }) } || {};

	my $setting = $c->param('setting');
	my $name = $c->param('name');
	my $value = $c->param('value');

	$custom_pseudonyms->{$name}->{$setting} = $value;


	my $cs = encode_json $custom_pseudonyms;
	&subs::setting_setter({ app => 'config', setting => 'pseudonyms', value => $cs });
	my $pseudonyms = &pseudonym_maker('','');
	$c->render(
		template => '/configure/pseudonym_list',
		pseudonyms => $pseudonyms
	);
}

# GET /manager/configure/pseudonym_defaulter
sub action_13517 {
	my $c = shift;
	my $name = $c->param('name');
	my $custom_pseudonyms = eval { return decode_json &subs::setting_grabber({ app => 'config', setting => 'pseudonyms' }) } || {};
	$custom_pseudonyms->{$name} = undef;
	my $cs = encode_json $custom_pseudonyms;
	&subs::setting_setter({ app => 'config', setting => 'pseudonyms', value => $cs });
	my $pseudonyms = &pseudonym_maker('','');
	$c->render(
		template => '/configure/pseudonym_list',
		pseudonyms => $pseudonyms
	);
}

# POST /manager/configure/pseudonym_icon_changer
sub action_13530 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $custom_pseudonyms = eval { return decode_json &subs::setting_grabber({ app => 'config', setting => 'pseudonyms' }) } || {};
	my $name = $c->param('name');
	my $image = $c->param('image');
	$custom_pseudonyms->{$name}->{'icon'} = $image;

	my $cs = encode_json $custom_pseudonyms;
	&subs::setting_setter({ app => 'config', setting => 'pseudonyms', value => $cs });
	my $pseudonyms = &pseudonym_maker('','');
	my $returner;
	$returner->{'list'} = $c->render_to_string(
		template => '/configure/pseudonym_list',
		pseudonyms => $pseudonyms
	);
	$c->render(json => $returner);
}

# POST /manager/configure/site_type/manual_change
sub action_14608 {
	my $c = shift;
	my $new_site = $c->param('site');
	my $signatorial = &subs::signatorial_designer();

	my $navigation_information = &subs::navigation_information({ signatorial => $signatorial });
	if ($new_site eq 'reset' || $gb::site_types->{$new_site}->{'rating'} >= $navigation_information->{$signatorial}->{'site_rating'}) {

		if ($new_site eq 'reset') {
			&subs::setting_deleter({ app => '__president', setting => $signatorial . '_site_type' });
			&subs::setting_deleter({ app => '__president', setting => $signatorial . '_site_rating' });
		} else {
			&subs::setting_setter({ app => '__president', setting => $signatorial . '_site_type', value => $gb::site_types->{$new_site}->{'name'} });
			&subs::setting_setter({ app => '__president', setting => $signatorial . '_site_rating', value => $gb::site_types->{$new_site}->{'rating'} });
		}
		&subs::cache_delete({ app => 'travel', context => 'navigation_information', subcontext => $signatorial });
		&subs::visibility_cache_clear();
		$navigation_information = &subs::navigation_information({ signatorial => $signatorial });
		&subs::lockdown_sweep({ force => 1 });
	}
	$c->render(json => $gb::site_types->{$navigation_information->{$signatorial}->{'site_type'}} );
}

# POST /manager/configure/image_function
sub action_15000 {
	my $c = shift;
	my $app = $c->param('app');
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $function = $c->param('func');
	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];

	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'embedded', setting => 'diagrams' }) } || [];
	my $receipts = eval { return decode_json &subs::setting_grabber({ app => 'budget', setting => 'receipts' }) } || [];
	my $signatorials = eval { return decode_json &subs::setting_grabber({ app => 'customs', setting => 'signatorials' }) } || [];
	unless ($function eq 'map') {
		@{$maps} = grep { $_->{'uuid'} ne $file_uuid } @{$maps};
	}
	unless ($function eq 'background') {
		@{$backgrounds} = grep { $_->{'uuid'} ne $file_uuid } @{$backgrounds};
	}
	unless ($function eq 'diagram') {
		@{$diagrams} = grep { $_->{'uuid'} ne $file_uuid } @{$diagrams};
	}
	unless ($function eq 'receipt') {
		@{$receipts} = grep { $_->{'uuid'} ne $file_uuid } @{$receipts};
	}
	unless ($function eq 'signatorial') {
		@{$signatorials} = grep { $_->{'uuid'} ne $file_uuid } @{$signatorials};
	}

	foreach my $fi ( @{$files} ) {
		if ( $fi->{'uuid'} eq $file_uuid) {
			$fi->{'function'} = $function;
			$fi->{'app'} = $app;
			$fi->{'app_uuid'} = $appt->{'uuid'};
			if ($function eq 'map') {
				push @{$maps}, $fi;
			}
			elsif ($function eq 'background') {
				push @{$backgrounds}, $fi;
			}
			elsif ($function eq 'diagram') {
				push @{$diagrams}, $fi;
			}
			elsif ($function eq 'receipt') {
				push @{$receipts}, $fi;
			}
			elsif ($function eq 'signatorial') {
				push @{$signatorials}, $fi;
			}
		}
	}

	my $jmaps = encode_json $maps;
	my $jbacks = encode_json $backgrounds;
	my $jdiagrams = encode_json $diagrams;
	my $jreceipts = encode_json $receipts;
	my $jsignatorials = encode_json $signatorials;
	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::setting_setter({ app => 'marker', setting => 'backgrounds', value => $jbacks });
	&subs::setting_setter({ app => 'embedded', setting => 'diagrams', value => $jdiagrams });
	&subs::setting_setter({ app => 'budget', setting => 'receipts', value => $jreceipts });
	&subs::setting_setter({ app => 'customs', setting => 'signatorials', value => $jsignatorials });
	my $jfile = encode_json $files;
	$appt->{'file'} = $jfile;
	$appt->{'server_time'} = &subs::rightNow();

	&subs::db_update('appointments', $appt, { uuid => $appt->{'uuid'}, app => $appt->{'app'} });

	$c->render(json => $appt);
	&image_function_sanity_check();
}

# POST /manager/configure/image_function_tool
sub action_15072 {
	my $c = shift;
	my $app_uuid = $c->param('app_uuid');
	my $app = $c->param('app');
	my $file_uuid = $c->param('file_uuid');
	my $tool = $c->param('tool');
	my $value = $c->param('value');
	my $translate = $c->param('translate');
	$value = eval { return decode_json $value } || {};

	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];

	my $files = eval { return decode_json $appt->{'file'} } || [];

	my $home_plate = eval { return decode_json &subs::setting_grabber({ app => $value->{'legend'}, setting => 'home_plate' }) } || {};
	if ($tool eq 'home_plate') {
		foreach my $hp ( keys %{$home_plate} ) {
			$value->{$hp} = $home_plate->{$hp};
		}
	}
	elsif ($tool eq 'scale') {
		if ($value->{'legend'} =~ /[a-zA-z]/gi) {
			# a legend with units is stored as metres; a conversion that fails
			# keeps the text - the client shows it, and the server's ppm/mpp
			# maths reads a non-number as "no scale" rather than dividing by it
			my ($fo,$ev,$uom,$format) = &formula_calculator($value->{'legend'} . ' to m' );
			$value->{'legend'} = $ev if defined $ev && $ev =~ /^\s*[0-9.]+\s*$/;
		}
	}
	foreach my $fi ( @{$files} ) {
		$fi->{$tool} = $value if $fi->{'uuid'} eq $file_uuid;
	}
	foreach my $map ( @{$maps} ) {
		$map->{$tool} = $value if $map->{'uuid'} eq $file_uuid;
	}
	$value->{'formatted_legend'} = &subs::format_name($value->{'legend'});

	my $jmaps = encode_json $maps;
	my $jfiles = encode_json $files;

	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jfiles }, { app => $appt->{'app'}, uuid => $appt->{'uuid'} });

	$c->render(json => $value);
}

# The pair of helpers a person setting a map wants: read the scale legend off the
# image (local tesseract), or ask the vision model for the legend and how far the
# picture is off north-up. Both open the sealed image first.
# POST /manager/configure/map_helper
sub action_15171 {
	my $c = shift;
	my $uuid = $c->param('file_uuid');
	my $mode = $c->param('mode') || 'ocr';
	my ($map) = &travel_map_record($uuid);
	unless ($map && $map->{'f'}) { $c->render(json => { error => 'no such map' }); return; }
	my ($destination,$asset) = &subs::file_device_renamer({ file => $map->{'f'}, app => $map->{'app'}, type => $map->{'type'} });
	my $path = &subs::home($destination . $asset);
	unless (-e $path) { $c->render(json => { error => 'the map image is not on this machine' }); return; }
	my $bytes = &sealed_file_bytes(&subs::session_suds($c), $path);
	unless (defined $bytes && length $bytes) { $c->render(json => { error => 'could not open the map image' }); return; }

	my $tmp = '/tmp/jawn_map_' . &subs::random_string_creator(8) . '.png';
	write_file($tmp, $bytes);

	if ($mode eq 'vision') {
		my $model = &subs::setting_grabber({ app => 'mail', setting => 'visual_assistant' }) || &subs::setting_grabber({ app => '__president', setting => 'visual_assistant' });
		unless ($model) { unlink $tmp; $c->render(json => { error => 'no vision model is set (Configure, Plat, Vision)' }); return; }
		my $system = 'You label a single map screenshot for JawnOS. The map is meant to be north-up.';
		my $ask = 'Return ONLY JSON, no prose: {"legend":"the scale-bar text exactly as printed (e.g. 200 m or 1 km), or empty","rotate":degrees to turn the image CLOCKWISE so its north points up (a number; 0 if already north-up),"bar":{"x1":0.0,"y1":0.0,"x2":0.0,"y2":0.0}}. For bar, give the two ends of the scale bar as fractions of the image width and height, each between 0 and 1 (x1,y1 the left end, x2,y2 the right end). Judge the rotation from the map content (roads, labels, the graticule), not from the scale bar, which is drawn horizontally however the map is turned.';
		my ($text, $err) = &subs::ai_chat_role('visual_assistant', [ { role => 'system', content => $system }, { role => 'user', content => $ask, images => [ encode_base64($bytes, '') ] } ], &subs::ai_role_thinking_effective('visual_assistant'));
		unlink $tmp;
		unless ($text) { $c->render(json => { error => $err || 'the vision model returned nothing' }); return; }
		my ($json) = $text =~ /(\{.*\})/s;
		my $out = eval { return decode_json $json } || {};
		# a map may print more than one bar (500 ft and 200 m); keep the first
		my $legend = $out->{'legend'} // '';
		$legend =~ s/\s+/ /g; $legend =~ s/^\s+|\s+$//g;
		$legend = $1 if $legend =~ /(\d[\d.,]*\s*(?:km|m|cm|ft|mi|metres?|meters?|kilometres?|kilometers?|miles?|feet|foot)\b)/i;
		my $metres = &map_legend_metres($legend);
		$c->render(json => { legend => ($metres // $legend), legend_text => $legend, rotate => $out->{'rotate'}, bar => $out->{'bar'}, raw => $text });
		return;
	}

	my $base = '/tmp/jawn_map_ocr_' . &subs::random_string_creator(8);
	`tesseract "$tmp" "$base" 2>/dev/null`;
	my $ocr = (-e $base . '.txt') ? read_file($base . '.txt') : '';
	unlink $tmp; unlink $base . '.txt';
	my @cands;
	while ($ocr =~ /(\d[\d.,]*\s*(?:km|m|cm|ft|mi|metres?|meters?|kilometres?|kilometers?|miles?|feet|foot)\b)/gi) {
		push @cands, $1;
	}
	my $metres = &map_legend_metres($cands[0]);
	$c->render(json => { legend => ($metres // $cands[0]), legend_text => $cands[0], candidates => \@cands, text => $ocr });
}

# POST /manager/configure/map_rotate
sub action_15216 {
	my $c = shift;
	my $uuid = $c->param('file_uuid');
	my $rotate = 0 + ($c->param('rotate') || 0);
	my ($map, $maps) = &travel_map_record($uuid);
	unless ($map) { $c->render(json => { error => 'no such map' }); return; }
	foreach my $m ( @{$maps} ) { $m->{'rotate'} = $rotate if $m->{'uuid'} eq $uuid; }
	&subs::setting_setter({ app => 'travel', setting => 'maps', value => encode_json $maps });
	$c->render(json => { rotate => $rotate });
}

# Clear a provider's stand-down, so its paid models are offered again at once.
# POST /manager/configure/ai_availability_clear
sub action_15262 {
	my $c = shift;
	my $bucket = $c->param('bucket') || '';
	unless ($bucket =~ /^[a-z_]+$/) { $c->render(json => { error => 'bad bucket' }); return; }
	&subs::setting_setter({ app => '__president', setting => 'ai_' . $bucket . '_unavailable', value => 0 });
	$c->render(json => { bucket => $bucket, cleared => 1 });
}

# POST /manager/configure/image_name
sub action_15302 {
	my $c = shift;
	my $name = &subs::unformat_name($c->param('name'));
	my $app_uuid = $c->param('app_uuid');
	my $file_uuid = $c->param('file_uuid');
	my $app = $c->param('app');

	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];

	foreach my $file ( @{$files} ) {
		if ( $file->{'uuid'} eq $file_uuid) {
			$file->{'name'} = $name;
		}
	}
	my $jfiles = encode_json $files;

	&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $jfiles }, { app => $app, uuid => $app_uuid });


	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'handbook', setting => 'diagrams' }) } || [];
	foreach my $map ( @{$maps} ) {
		if ( $map->{'uuid'} eq $file_uuid ) {
			$map->{'name'} = $name;
		}
	}

	foreach my $background ( @{$backgrounds} ) {
		if ($background->{'uuid'} eq $file_uuid ) {
			$background->{'name'} = $name;
		}
	}

	foreach my $diagram ( @{$diagrams} ) {
		if ($diagram->{'uuid'} eq $file_uuid) {
			$diagram->{'name'} = $name;
		}
	}

	my $jmaps = encode_json $maps;
	my $jbacks = encode_json $backgrounds;
	my $jdiagrams = encode_json $diagrams;

	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::setting_setter({ app => 'marker', setting => 'backgrounds', value => $jbacks });
	&subs::setting_setter({ app => 'handbook', setting => 'diagrams', value => $jdiagrams });


	$c->render(json => $appt);
}

# POST /manager/configure/stop_all_appointments
sub action_16761 {
	my $c = shift;

	my $timestamp = $c->param('timestamp');

	my ($db,$database,$sql) = &subs::database_grabber();
	my $ap = &subs::db_query('select * from appointments where type = ? or type = ? and timestamp <= ?', 'record','start',$timestamp);
	my $appts = $ap->hashes;

	foreach my $a ( @{$appts}) {
		my $duration = $a->{'timestamp'} - $timestamp;
		my $sq = &subs::db_query('select app,setting,value from settings where app = ? and setting=? and value != ?',$a->{'app'},'duration','');
		my $sqsults = $sq->hashes;
		my $old_appts = &subs::db_query('select * from appointments where type=? and app = ? order by timestamp DESC LIMIT 20', 'stop', $a->{'app'})->hashes;
		if (scalar @{$old_appts} > 2) {
			my $toa = 0;
			foreach my $oa ( @{$old_appts} ) {
				$toa += abs $oa->{'duration'};
			}
			$duration = $toa / @{$old_appts};
		}
		elsif (scalar @{$sqsults} > 0) {
			$duration = &subs::time_abbrev_translator($sqsults->[-1]->{'value'});
			if ($duration && $duration > 0) { $duration = $duration * -1; }
		}
		&subs::db_update('appointments', {
			type => 'stop',
			duration => $duration,
			server_time => &subs::rightNow()
		},{
			app => $a->{'app'},
			uuid => $a->{'uuid'}
		});
		&appointment_stock_movement($c, $a->{'app'}, 'stop', $a->{'quantity'}, $a->{'unit'}, $timestamp, $a->{'uuid'}) if ($a->{'type'} || '') eq 'start';
	}
	# stopping every running start/record changes which theme owns the desktop
	&subs::appointment_theme_push();

	$c->render(text => 'ok');
}

# POST /manager/configure/app_measure_configuration_adder
sub action_17661 {
	my $c = shift;
	my $app = $c->param('app');

	my $amway = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};

	$amway->{'new_measure'} = {};

	my $jamway = encode_json $amway;
	&subs::setting_setter({ app => $app, setting => 'app_measures', value => $jamway });

	$amway->{'header'} = join ',', keys %{$amway};
	my $appts = &log_reader({ app => $app, view => 'appointment_display' });

	my $measures = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	$appts->{$app}->{'setting'}->{'measures'} = join ',', keys %{$measures};
	$appts->{$app}->{'setting'}->{'app_measures'} = $measures;

	$amway->{'config'} = $c->render_to_string(
		template => 'configure/app_measures',
		settings => $appts->{$app}->{'setting'},
		a => $app,
		b => 'app_measures'
	);
	$amway->{'app_measure'} = $c->render_to_string(
		template => 'apps/app_measures',
		settings => $appts->{$app}->{'setting'},
		appts => $appts,
		a => $app
	);
	$c->render('json' => $amway);
}

# POST /manager/configure/app_measure_configurator
sub action_17694 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $measure = &subs::unformat_name($c->param('measure'));
	my $setting = &subs::unformat_name($c->param('setting'));
	my $value = $c->param('value');
	my $oldvalue = $c->param('oldvalue');
	my $amway = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	$amway->{$measure} = {} unless $amway->{$measure};

	if ($setting eq 'options') {
		my @value = split ',', $value;
		$value = \@value;
	}

	foreach my $k ( keys %{$amway} ) {
		unless ( $k =~ /[a-zA-Z0-9.]/gi ) {
			$amway->{$k} = undef;
		}
	}
	if ($setting eq 'measure' && $value =~ /[a-zA-Z0-9]/gi) {

		$value = &subs::unformat_name($value);
		my $changing = 0;
		my $appointments = &subs::db_query('select * from appointments where app=? and measures is not null', $app)->hashes;
		foreach my $apps ( @{$appointments} ) {
			my $j = $apps->{'measures'};
			my $app_changed = 0;
			my $meas = eval { return decode_json $j } || [];
			if (scalar @{$meas} > 0) {
				$changing = 1;
				foreach my $m ( @{$meas} ) {
					if ($m->{$oldvalue}) {
						$m->{$value} = $m->{$oldvalue};
						delete $m->{$oldvalue};
						$app_changed = 1;
					}

				}
				if ($app_changed == 1) {
					my $jam = encode_json $meas;
					&subs::db_update('appointments', { server_time => &subs::rightNow(), measures => $jam }, { uuid => $apps->{'uuid'}, app => $apps->{'app'} });
					&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $apps->{'uuid'})});
				}
			}
		}
		if ($changing == 1) {
			$amway->{$value} = $amway->{$oldvalue};
			delete $amway->{$oldvalue};
		}
	}
	else {
		$amway->{$measure}->{$setting} = $value;
	}
	foreach my $k ( keys %{$amway} ) {
		unless ( $k =~ /[a-zA-Z0-9.]/gi ) {
			delete $amway->{$k};
		}
	}
	my $jamway = encode_json $amway;
	&subs::setting_setter({ app => $app, setting => 'app_measures', value => $jamway });

	$amway->{'header'} = join ',', keys %{$amway};
	my $appts = &log_reader({ app => $app, view => 'appointment_display' });

	my $measures = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
	$appts->{$app}->{'setting'}->{'measures'} = join ',', keys %{$measures};
	$appts->{$app}->{'setting'}->{'app_measures'} = $measures;

	$amway->{'config'} = $c->render_to_string(
		template => 'configure/app_measures',
		settings => $appts->{$app}->{'setting'},
		a => $app,
		appts => $appts,
		b => 'app_measures'
	);
	$amway->{'app_measure'} = $c->render_to_string(
		template => 'apps/app_measures',
		settings => $appts->{$app}->{'setting'},
		appts => $appts,
		a => $app
	);
	$c->render('json' => $amway);
}

1;
