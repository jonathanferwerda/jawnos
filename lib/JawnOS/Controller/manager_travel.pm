package Manager;

# manager_travel: route actions moved out of Manager.pl, one sub per route so a
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

# POST /manager/travel/delete_map
sub action_15354 {
	my $c = shift;
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	my $app = $c->param('app');
	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	# a guessed map has no appointment to detach from (the atlas draws it from the
	# travel folder): drop the record and the picture with it
	my ($guess) = grep { $_->{'uuid'} eq $file_uuid && $_->{'guessed'} } @{$maps};
	if ($guess) {
		@{$maps} = grep { $_->{'uuid'} ne $file_uuid } @{$maps};
		&subs::setting_setter({ app => 'travel', setting => 'maps', value => encode_json $maps });
		unlink $guess->{'f'} if $guess->{'f'} && $guess->{'f'} =~ m{/guess_[^/]+\.png(\.enc)?$};
		$c->render(json => { uuid => $file_uuid, deleted => 'yes' });
		return;
	}
	my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $app_uuid })->hashes->[0];
	my $files = eval { return decode_json $appt->{'file'} } || [];

	foreach my $file ( @{$files} ) {
		if ($file->{'uuid'} eq $file_uuid) {
			delete $file->{'function'};
			delete $file->{'scale'};
			delete $file->{'home_plate'};
		}
	}
	@{$maps} = grep { $_->{'uuid'} ne $file_uuid } @{$maps};
	my $jfiles = encode_json $files;
	my $jmaps = encode_json $maps;

	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::db_update('appointments', { file => $jfiles, server_time => &subs::rightNow() }, { uuid => $appt->{'uuid'}, app => $app });


	$c->render(json => $maps);
}

# GET /manager/travel
sub action_32638 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $contents = &travel_grabber($c);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'travel', contents => $contents }, $timestamp);
	$c->render(text => $website);
}

# The pictures and videos taken while the house was at a place. A file carries no
# coordinates of its own, so the media is joined to the position fixes the house
# kept: a photo belongs to a place if a fix inside the area was recorded around the
# time it was taken. The area is the ground the map is showing when the caller
# names it, else a small circle around the point. That is the honest reading of
# "taken near here" for a library whose photos have no GPS of their own.
# GET /manager/travel/nearby
sub action_32651 {
	my $c = shift;
	my $lat = 0 + ($c->param('lat') || 0);
	my $lon = 0 + ($c->param('lon') || 0);
	return $c->render(json => { items => [] }) unless $lat || $lon;
	my $items = &travel_nearby_items(
		lat => $lat,
		lon => $lon,
		radius => $c->param('radius'),
		window => $c->param('window'),
		limit => $c->param('limit'),
		nw_lat => $c->param('nw_lat'),
		nw_lon => $c->param('nw_lon'),
		se_lat => $c->param('se_lat'),
		se_lon => $c->param('se_lon')
	);
	$c->render(json => { items => $items });
}

# A plate set from the map: it joins the app's own home_plate_duties with its own
# coordinates, so one app can have several plates (a franchise at each shop) and
# every plate triggers its own app.
# POST /manager/travel/plate
sub action_32878 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app') || '');
	my $lat = 0 + ($c->param('latitude') || 0);
	my $lon = 0 + ($c->param('longitude') || 0);
	my $metres = 0 + ($c->param('radius') || 200);
	my $action = $c->param('action') || 'start';
	my %allowed = map { $_ => 1 } qw(none start record stop command kill);
	$action = 'start' unless $allowed{$action};
	return $c->render(json => { error => 'an app is needed' }) unless length $app;
	return $c->render(json => { error => 'that place is not valid' }) unless $lat || $lon;
	return $c->render(json => { error => 'that app is hidden' }) if &subs::app_hidden_now($app);
	$metres = 10 if $metres < 10;
	$metres = 5000 if $metres > 5000;
	my $duties = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'home_plate_duties' }) } || [];
	my $plate = {
		uuid => &subs::random_string_creator(22),
		timestamp => &subs::rightNow(),
		placement => 'within',
		distance => sprintf('%.3f', $metres / 1000),
		action => $action,
		self => 'on',
		app => $app,
		device => '',
		latitude => sprintf('%.7f', $lat),
		longitude => sprintf('%.7f', $lon),
	};
	push @{$duties}, $plate;
	&subs::setting_setter({ app => $app, setting => 'home_plate_duties', value => encode_json $duties });
	# the app needs a base plate for the older readers; the first one set here is it
	my $base = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'home_plate' }) } || {};
	if (!$base->{'latitude'}) {
		$base = {
			app => $app, type => 'home_plate', uuid => &subs::random_string_creator(22),
			timestamp => &subs::rightNow(), server_time => &subs::rightNow(),
			latitude => $plate->{'latitude'}, longitude => $plate->{'longitude'}
		};
		&subs::setting_setter({ app => $app, setting => 'home_plate', value => encode_json $base });
	}
	$c->render(json => { saved => 1, app => $app, name => &subs::format_name($app), plate => $plate });
}

# GET /manager/travel/continent
sub action_33472 {
	my $c = shift;
	my $settings = &subs::settings_grabber({ app => 'travel' });
	# guesses ride along only while the guess toggle is on, here as in the viewer
	my $maps = &travel_atlas_maps(eval { return decode_json $settings->{'maps'} } || [], ($settings->{'guess_enabled'} eq 'enabled'));
	my $points = &travel_atlas_points($c->param('start'), $c->param('end'));
	my $appointments = &travel_atlas_appointments($c->param('start'), $c->param('end'));
	my $home_plates = &travel_atlas_home_plates();
	my $here = &travel_here_position();
	# the maps switched off in the Travel picker stay off on the background too
	my $hidden_maps = eval { return decode_json $settings->{'hidden_maps'} } || [];
	my %hidden = map { $_ => 1 } @{$hidden_maps};
	$maps = [ grep { $_->{'guessed'} || !$hidden{ $_->{'uuid'} } } @{$maps} ];
	my %map_keys = map { $_ => (&subs::setting_grabber({ app => '__president', setting => 'map_key_' . $_ }) || '') } qw(maptiler mapbox stadia thunderforest carto);
	$c->render(json => {
		maps => $maps,
		points => $points,
		appointments => $appointments,
		home_plates => $home_plates,
		here => $here,
		provider => $settings->{'map_provider'} || 'none',
		custom_url => $settings->{'map_custom_url'} || '',
		keys => \%map_keys
	});
}

# Guess the empty ground in what the client is looking at: the largest pocket of
# unmapped ground in the view, grown 40% into the blanks around it (never across a
# measured map - the guess may only ever show where nothing is known), drawn by
# the Plat Image-generation model from a conservative description of what all the
# maps around it show (the Vision model reads each one's own part of that ground
# first). The picture is filed sealed under the photo location's `me` folder - the
# place the mugshot lives - and the record is kept beside the measured maps,
# georeferenced to exactly that ground, dashed and named 'guess: ...' so it never
# passes for a measured map. It is drawn under every measured map and counts as
# ground already known, so a gap is generated once and never again. A guess
# covering the same ground is replaced, picture and all.
# POST /manager/travel/guess_gap
sub action_33508 {
	my $c = shift;
	my $view = {
		minLat => 0 + ($c->param('minLat') || 0),
		maxLat => 0 + ($c->param('maxLat') || 0),
		minLon => 0 + ($c->param('minLon') || 0),
		maxLon => 0 + ($c->param('maxLon') || 0),
	};
	unless ($view->{'maxLat'} > $view->{'minLat'} && $view->{'maxLon'} > $view->{'minLon'}) {
		$c->render(json => { error => 'no view of the ground was given' });
		return;
	}
	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my @placed;
	foreach my $map ( @{$maps} ) {
		&travel_map_home_plate($map);
		my $bounds = &travel_map_bounds($map);
		next unless $bounds;
		push @placed, { uuid => $map->{'uuid'}, name => ($map->{'name'} || $map->{'uuid'}), map => $map, bounds => $bounds };
	}
	unless (@placed) { $c->render(json => { error => 'no placed maps yet to read the ground from' }); return; }

	# only the ground nobody has mapped: the largest empty pocket in the view,
	# grown through the blanks around it and widened towards the canvas's own
	# shape, stopping at every map it meets
	my $pocket = &travel_uncovered_pocket(\@placed, $view);
	unless ($pocket) { $c->render(json => { covered => 'yes', note => 'everything in this view is already covered' }); return; }
	$pocket = &travel_pocket_widen(&travel_pocket_grow($pocket, 0.4), $view);
	my $box = &travel_grid_box($view, $pocket);

	my $pi = 3.14159265358979;
	my $mpd = 6372800 * $pi / 180;
	my $mid_lat = ($box->{'minLat'} + $box->{'maxLat'}) / 2;
	my $mid_lon = ($box->{'minLon'} + $box->{'maxLon'}) / 2;
	my $mpd_lon = $mpd * cos($mid_lat * $pi / 180);
	my $lon_metres = ($box->{'maxLon'} - $box->{'minLon'}) * $mpd_lon;
	my $lat_metres = ($box->{'maxLat'} - $box->{'minLat'}) * $mpd;
	# never longer than 30 km, so a huge blank is filled in sane pieces
	my $longest = $lon_metres > $lat_metres ? $lon_metres : $lat_metres;
	if ($longest > 30000) {
		my $shrink = 30000 / $longest;
		my $half_lat = ($lat_metres * $shrink) / 2 / $mpd;
		my $half_lon = ($lon_metres * $shrink) / 2 / $mpd_lon;
		$box->{'minLat'} = $mid_lat - $half_lat; $box->{'maxLat'} = $mid_lat + $half_lat;
		$box->{'minLon'} = $mid_lon - $half_lon; $box->{'maxLon'} = $mid_lon + $half_lon;
		$lat_metres *= $shrink;
		$lon_metres *= $shrink;
	}

	# what the maps around the pocket show of it, read conservatively
	my ($described) = &travel_guess_describe_area($c, \@placed, $box);
	my @names = &travel_box_names(\@placed, $box, 2);
	my $name = 'guess';
	$name .= ' near ' . $names[0] if scalar @names == 1;
	$name .= ' between ' . $names[0] . ' and ' . $names[1] if scalar @names >= 2;
	$name .= ' ' . sprintf('%.3f,%.3f', $mid_lat, $mid_lon) unless scalar @names;

	my $prompt = 'A seamless top-down aerial satellite photograph filling one unmapped patch of ground' . (@names ? ' among maps of ' . join(' and ', @names) : '') . '.';
	$prompt .= ' ' . $described if $described && $described =~ /\S/;
	$prompt .= ' Conservative continuation of the surrounding land: roads and rivers run straight on unless the neighbouring maps show otherwise; no invented bends, junctions, towns or landmarks; the same season and imagery style as the neighbouring maps. No borders, no labels, no text, no icons, no arrows.';

	# the canvas: the long side 1024, the short side proportional but never under
	# 256 (the image model refuses less), rounded to the 64s the model likes. The
	# pocket's short axis has already been widened towards this shape, over empty
	# ground only; whatever it could not reach just stretches the picture a little -
	# the ground box itself is never grown over a map
	my ($px_lon, $px_lat);
	if ($lon_metres >= $lat_metres) {
		$px_lon = 1024;
		$px_lat = int(((1024 * $lat_metres / $lon_metres) / 64) + 0.5) * 64;
		$px_lat = 256 if $px_lat < 256;
		$px_lat = 1024 if $px_lat > 1024;
	}
	else {
		$px_lat = 1024;
		$px_lon = int(((1024 * $lon_metres / $lat_metres) / 64) + 0.5) * 64;
		$px_lon = 256 if $px_lon < 256;
		$px_lon = 1024 if $px_lon > 1024;
	}

	my ($bytes, $mime, $err) = &subs::ai_text_to_image({
		prompt => $prompt,
		negative_prompt => 'text, labels, letters, watermark, border, frame, user interface, legend, invented landmarks, fantasy, horizon, perspective view, close-up',
		width => $px_lon,
		height => $px_lat
	});
	unless ($bytes) { $c->render(json => { error => $err || 'the image model returned nothing' }); return; }

	# where it is filed: sealed, under the photo location's `me` folder - the same
	# place the mugshot lives. A guess is a picture the app keeps (so the same gap
	# is never generated twice), not an appointment's file, so it sits with the
	# pictures the device holds for itself
	my $photo = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $device }) || 'Pictures';
	my $folder = &subs::home($photo) . '/me';
	`mkdir -p "$folder"`;
	my $guess_uuid = &subs::random_string_creator(15);
	my $raw = $folder . '/guess_' . $guess_uuid . '.png';
	write_file($raw, $bytes);

	my ($w, $h) = (0, 0);
	my $identified = &subs::image_bridge_identify($raw);
	if ($identified) { ($w, $h) = ($identified->{'width'}, $identified->{'height'}); }
	else {
		open(my $identify, '-|', 'magick', 'identify', '-format', '%w %h', $raw);
		if ($identify) { my $line = <$identify>; close $identify; ($w, $h) = split ' ', ($line || ''); }
	}
	($w, $h) = ($px_lon, $px_lat) unless $w && $h;

	my $secret = &subs::suds_grabber();
	my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	my $file_path = $folder . '/guess_' . $guess_uuid . '.png.enc';
	&subs::openssl_file_crypt('e', $standard, $secret, $raw, $file_path, 0, 1);
	unless (-e $file_path && -s $file_path) {
		unlink $raw;
		$c->render(json => { error => 'the guess could not be sealed' });
		return;
	}
	`shred -u "$raw"`;

	my $centre_lat = ($box->{'minLat'} + $box->{'maxLat'}) / 2;
	my $centre_lon = ($box->{'minLon'} + $box->{'maxLon'}) / 2;
	my $bar_metres = int(($lon_metres / 4) + 0.5);
	$bar_metres = 1 if $bar_metres < 1;
	my $entry = {
		uuid => $guess_uuid,
		app => 'travel',
		type => 'image',
		function => 'map',
		name => $name,
		'f' => $file_path,
		guessed => 1,
		guess_area => $box,
		guess_names => \@names,
		guess_prompt => $prompt,
		guessed_by => &subs::setting_grabber({ app => 'mail', setting => 'text_to_image_assistant' }),
		server_time => &subs::rightNow(),
		home_plate => {
			x => $w / 2, y => $h / 2, width => $w, height => $h,
			latitude => $centre_lat, longitude => $centre_lon,
			legend => 'guessed', formatted_legend => 'guessed'
		},
		scale => {
			first => { x => $w * 0.1, y => $h - 12 },
			last => { x => ($w * 0.1) + ($w / 4), y => $h - 12 },
			width => $w, height => $h,
			legend => $bar_metres, formatted_legend => $bar_metres . ' m'
		},
		rotate => 0
	};
	# a guess covering the same ground is a re-roll: it replaces the old one,
	# picture and all; guesses beside it are kept
	my @replace;
	foreach my $old ( @{$maps} ) {
		next unless $old->{'guessed'};
		my $ob = &travel_map_bounds($old);
		next unless $ob;
		my $old_lat = ($ob->{'nw'}->{'lat'} + $ob->{'se'}->{'lat'}) / 2;
		my $old_lon = ($ob->{'nw'}->{'lon'} + $ob->{'se'}->{'lon'}) / 2;
		my $old_covers = ($centre_lat <= $ob->{'nw'}->{'lat'} && $centre_lat >= $ob->{'se'}->{'lat'} && $centre_lon >= $ob->{'nw'}->{'lon'} && $centre_lon <= $ob->{'se'}->{'lon'});
		my $new_covers = ($old_lat <= $box->{'maxLat'} && $old_lat >= $box->{'minLat'} && $old_lon >= $box->{'minLon'} && $old_lon <= $box->{'maxLon'});
		next unless $old_covers || $new_covers;
		unlink $old->{'f'} if $old->{'f'} && $old->{'f'} =~ m{/guess_[^/]+\.png(\.enc)?$};
		push @replace, $old->{'uuid'};
	}
	@{$maps} = grep { my $u = $_->{'uuid'}; !grep { $_ eq $u } @replace } @{$maps};
	push @{$maps}, $entry;
	&subs::setting_setter({ app => 'travel', setting => 'maps', value => encode_json $maps });
	$c->render(json => { uuid => $guess_uuid, name => $entry->{'name'}, prompt => $prompt, width => $w, height => $h, names => \@names });
}

# The picture behind a guessed map (session-guarded, like every manager route).
# The picture is sealed under the photo location's `me` folder, like the mugshot,
# so it is opened here the way /mugshot opens one.
# GET /manager/travel/guess_image
sub action_33680 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my ($map) = grep { $_->{'uuid'} eq $uuid && $_->{'guessed'} } @{$maps};
	unless ($map && $map->{'f'} && -e $map->{'f'}) { $c->rendered(404); return; }
	my $data;
	if ($map->{'f'} =~ /\.enc$/) {
		my $secret = &subs::suds_grabber();
		my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
		$data = &subs::openssl_file_read($standard, $secret, $map->{'f'}, 0, 1);
	}
	else {
		$data = eval { read_file($map->{'f'}) };
	}
	unless (defined $data && length $data) { $c->rendered(404); return; }
	$c->res->headers->content_type('image/png');
	$c->res->headers->cache_control('private, max-age=60');
	$c->render(data => $data);
}

# GET /manager/travel/viewer
sub action_33700 {
	my $c = shift;
	if ($c->param('settings')) {
		my $set = eval { return decode_json $c->param('settings') } || {};
		foreach my $s ( keys %{$set} ) {
			if ( $set->{$s} ) {
				&subs::setting_setter({ app => 'travel', setting => $s, value => $set->{$s} });
			}
			else {
				&subs::setting_deleter({ app => 'travel', setting => $s });
			}
		}
	}

	my $settings = &subs::settings_grabber({ app => 'travel' });
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $time_scope = $c->param('time_scope') ? $c->param('time_scope') : '5minute';
	my $t = &subs::time_span($time_scope, $timestamp); #timestamp at beginning
	my $t1 = ($timestamp - $t);
	my $t2 = ($t1 + $timestamp);
	if ($settings->{'start_time'}) {
		$t = $settings->{'start_time'};
	}
	if ($settings->{'end_time'}) {
		$t2 = $settings->{'end_time'};
	}

	my $map = $c->param('map');

	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my ($main_map,$home_bases);
	@{$main_map} = grep { $_->{'uuid'} eq ($map || '') } @{$maps};
	# the picker lists the measured maps (a guessed gap is drawn, but not offered),
	# so a stale choice - or none at all - falls back to the first measured map
	@{$main_map} = grep { !$_->{'guessed'} } @{$maps} unless $main_map->[0];
	unless ($main_map->[0]) { $c->render(json => { error => 'no measured maps yet', all_maps => [], settings => $settings }); return; }

	my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $main_map->[0]->{'f'}, app => $main_map->[0]->{'app'}, type => $main_map->[0]->{'type'} });
	$main_map = $main_map->[0];
	$main_map->{'f'} = $destination . $asset;
	&travel_map_home_plate($main_map);

	$main_map->{'original_scale'} = $main_map->{'scale'}->{'last'}->{'x'} - $main_map->{'scale'}->{'first'}->{'x'};

	# A legend is metres once converted, but a map can carry a text legend (an
	# older save, or a conversion that failed) and the bar can be missing: the
	# divide is only meaningful when both are numbers above zero, and the client
	# reads a 0 as "no scale", which is the honest answer.
	my $scale_legend = $main_map->{'scale'}->{'legend'};
	$scale_legend = &map_legend_metres($scale_legend) if defined $scale_legend && $scale_legend =~ /[a-zA-Z]/;
	$scale_legend = 0 unless defined $scale_legend && $scale_legend =~ /^\s*[0-9.]+\s*$/;
	$main_map->{'ppm'} = ($scale_legend > 0 && $main_map->{'original_scale'} > 0) ? $main_map->{'original_scale'} / $scale_legend : 0;
	$main_map->{'mpp'} = ($scale_legend > 0 && $main_map->{'original_scale'} > 0) ? $scale_legend / $main_map->{'original_scale'} : 0;
	my $proxies = {
		current_map => $main_map,
		near => [],
		far => [],
		here => {},
		scope => $time_scope,
		start_time => $t,
		end_time => $t2
	};
	# every measured map for the pan-able engine, and the machine's current
	# position (the 'temporary' row) so the view opens on it when there is one.
	# Guesses ride along only while the guess toggle is on.
	$proxies->{'all_maps'} = &travel_atlas_maps($maps, ($settings->{'guess_enabled'} eq 'enabled'));
	$proxies->{'position'} = &travel_here_position();
	my $locations = [];
	if ($settings->{'home_plate_enabled'} eq 'enabled') {
		my $home_plates = &subs::db_select('settings', undef, { setting => 'home_plate' })->hashes;

		foreach my $hp ( @{$home_plates} ) {
			my $ho = eval { return decode_json $hp->{'value'} } || {};
			$ho->{'app'} = $hp->{'app'};
			push @{$locations}, $ho;
		}
	}
	else {
		my $q;
		if ($settings->{'search'}) {
			$q = &subs::db_query('select * from continent where timestamp >= ? and timestamp <= ? and app like ?', $t, $t2, '%' . &subs::unformat_name($settings->{'search'}));
		} else {
			$q = &subs::db_query('select * from continent where timestamp >= ? and timestamp <= ?', $t, $t2);
		}
		$locations = $q->hashes;
	}

	# A filed fix carries its appointment's uuid as a prefix; a track is drawn only
	# inside one appointment, so fixes from different sessions are never joined.
	my $appt_rows = &subs::db_query('select uuid from appointments where (timestamp between ? and ?) or (stop_timestamp between ? and ?) or (stop_timestamp is null and type in (?,?) and timestamp > 0 and timestamp <= ?)', $t, $t2, $t, $t2, 'start', 'record', $t2)->hashes;
	my %travel_appt_uuid = map { $_->{'uuid'} => 1 } @{$appt_rows};

	# One appointment can hold fixes from more than one device: a tablet left in
	# the house files jittering rows while the phone carried on the walk files the
	# walk. One track is drawn per appointment, from the device that covered the
	# most ground, so the stationary device cannot zigzag it.
	my %travel_carrier;
	{
		my %by_appt;
		foreach my $sl ( @{$locations} ) {
			$sl->{'appointment_uuid'} = &travel_appointment_uuid($sl->{'uuid'}, \%travel_appt_uuid);
			push @{$by_appt{ $sl->{'appointment_uuid'} }}, $sl if $sl->{'appointment_uuid'};
		}
		foreach my $appt ( keys %by_appt ) {
			my $carrier = &subs::carrier_device($by_appt{$appt});
			$travel_carrier{$appt} = $carrier->{'signatorial'} if $carrier;
		}
	}

  sub NESW { deg2rad($_[0]), deg2rad(90 - $_[1]) }
	&subs::setting_setter({ app => 'travel', setting => 'time_scope', value => $time_scope });

	my $universal_settings = {};
	$main_map->{'home_plate'}->{'app'} = $main_map->{'home_plate'}->{'legend'};
	my @home_plate = NESW($main_map->{'home_plate'}->{'longitude'}, $main_map->{'home_plate'}->{'latitude'});

	foreach my $sl (@{$locations}) {
		# the device that was with the person on this appointment; the map draws
		# its fixes as one track and ignores the others' jitter. The uuid was
		# matched in the pre-pass above, before any two devices' rows were grouped.
		# A row in an appointment is explicitly 0 or 1: the map must be able to tell
		# "the other device" from "not part of a track at all", which a missing key
		# cannot say.
		if ($sl->{'appointment_uuid'}) {
			my $carried = defined $travel_carrier{ $sl->{'appointment_uuid'} }
				&& (defined $sl->{'signatorial'} ? $sl->{'signatorial'} : '') eq $travel_carrier{ $sl->{'appointment_uuid'} };
			$sl->{'carrier'} = $carried ? 1 : 0;
		}
		$universal_settings->{$sl->{'app'}} = &subs::settings_grabber({ app => $sl->{'app'} }) unless $universal_settings->{$sl->{'app'}};
		$sl->{'settings'} = $universal_settings->{$sl->{'app'}};
		# the map says a name the way the rest of the app does (the grouped marker's
		# list reads straight off this)
		$sl->{'name'} = &subs::format_name($sl->{'settings'}->{'name'} || $sl->{'app'});
		next if &subs::app_hidden_now($sl->{'app'});
		my $radius = 6372.8;
		my @visitor = NESW($sl->{'longitude'}, $sl->{'latitude'});
		$sl->{'rad'} = clone \@visitor;
		$sl->{'rad'}->[2] = 2;
		my $distance = great_circle_distance(@home_plate, @visitor, $radius);
		my $metres = $distance * 1000;
		my $direction = great_circle_direction(@home_plate, @visitor);

		my @destination = great_circle_destination(@home_plate,$distance,$direction);

		$sl->{'direction'} = rad2deg($direction);

		$sl->{'destination'} = \@destination;
		$sl->{'distance'} = sprintf("%.2f", $metres);
		$sl->{'home_plate'} = $main_map->{'home_plate'};




		my ($x,$y);
		$sl->{'map_coordinates'} = {
			'x' => $x,
			'y' => $y
		};

		push @{$proxies->{'near'}}, $sl;
	}

	push @{$proxies->{'near'}}, $main_map->{'home_plate'};
	$proxies->{'here'} = $main_map->{'home_plate'};

	$proxies->{'html'} = $c->render_to_string(
		template => 'travel/proxy',
		proxies => $proxies,
		start_time => $t,
		end_time => $t2,

	);
	$proxies->{'settings'} = $settings;
	$c->render(json => $proxies);
}

1;
