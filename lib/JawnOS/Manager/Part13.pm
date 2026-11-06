package Manager;

# Manager helpers, part 13 of 37. Moved out of Manager.pl so a
# helper can be read and changed without opening 24k lines. The package is
# still Manager, and lib/JawnOS/Manager/Index.pm maps every sub name here to
# this file; Manager.pm loads it on the first call.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'uninitialized';
no warnings 'once';

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

sub thumbnail_creator($data) {
	# A TIFF/XCF/HEIC capture has no WebView-renderable form; make the preview
	# while the plain file is still here (the encrypter seals it afterwards).
	# preload is the mapped File.pm entry that defines file_preview_maker.
	&subs::preload('file_media_information');
	$data = &subs::file_preview_maker($data);
	if ($data->{'thumb'}) {
		$data = &subs::file_media_information($data,$data->{'f'});

		my $thumbnail_size = &subs::setting_grabber({ app => 'misc', setting => 'thumbnail_size' }) || 'none';
		if ($thumbnail_size ne 'none') {
			my $filename = $data->{'f'};
			my $upload_type = $data->{'type'};
			my $thumb = $data->{'thumb'};
			my @filename = split /\./, $filename;
			my $ext = $filename[-1];

			my @thumb = split /\./, $thumb;
			pop @thumb;
			push @thumb, 'png';
			$thumb = join '.', @thumb;
			$data->{'thumb'} = $thumb;
			if ($upload_type eq 'video') {
				my $command2 = 'ffmpeg -nostdin -ss ' . &subs::thumbnail_seek_position() . ' -i ' . $filename . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize ' . $thumbnail_size . ' ' . $thumb;
				my $native = &native_thumb_png($filename, $thumbnail_size);
				if (defined $native && length $native) { write_file($thumb, $native); }
				else { &run_thumb_command($command2); }
			}
			elsif ($upload_type eq 'image' || $upload_type eq 'document') {
				# [0] takes the first page/layer, so a multi-page TIFF or a layered
				# XCF writes the one thumb file the row names instead of frames.
				my $command2 = 'magick ' . &subs::shell_quote($filename . '[0]') . ' -auto-orient -strip -resize ' . &subs::shell_quote($thumbnail_size) . ' ' . &subs::shell_quote($thumb);
				my $native = &native_thumb_png($filename, $thumbnail_size);
				if (defined $native && length $native) { write_file($thumb, $native); }
				else { &run_thumb_command($command2); }
			}
			else {
				return $data;
			}
		}
	}

	if ($data->{'app_uuid'} && $data->{'file_uuid'}) {
		my $appt = &subs::db_query('select * from appointments where uuid = ? and file is not null', $data->{'app_uuid'} )->hashes->[0];
		my $files = eval { return decode_json $appt->{'file'} } || [];
		if (scalar @{$files} > 0) {
			my $written = 0;
			foreach my $f ( @{$files} ) {
				if ($f->{'uuid'} eq $data->{'file_uuid'}) {
					$f->{'thumb'} = $data->{'thumb'};
					$f->{'server_time'} = &subs::rightNow();
					$written = 1;
				}
			}
			if ($written == 1) {
				my $jfile = encode_json $files;
				&subs::db_update('appointments', { file => $jfile, server_time => &subs::rightNow() }, { uuid => $appt->{'uuid'}, app => $appt->{'app'} });
			}
		}
	}
	delete $data->{'app_uuid'};
	delete $data->{'file_uuid'};

	return $data;
}

sub sealed_file_bytes {
	my ($suds, $file) = @_;
	return read_file($file) unless $file =~ /\.enc$/i;
	my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
	my @secrets;
	push @secrets, $suds if defined $suds && length $suds;
	my $pwords = &subs::db_query('select * from security where level != ? and level != ? order by server_time DESC', 'padlock', 'door')->hashes;
	foreach my $p ( @{$pwords} ) {
		my $secret = &subs::decrypter($suds, $p->{'credential'});
		push @secrets, $secret if defined $secret && length $secret;
	}
	# The configured standard is the likely one; the rest are only probed if it
	# does not open the file. This used to fork openssl once per credential.
	my @standards = ( $standard );
	foreach my $s ( @{ &subs::note_encryption_standards() } ) {
		push @standards, $s unless grep { $_ eq $s } @standards;
	}
	my $opened = &subs::sealed_file_open($file, \@secrets, \@standards, 0, sub { return &subs::plaintext_verdict($_[0]); });
	return $opened ? $opened->{'data'} : undef;
}

sub travel_map_record {
	my ($uuid) = @_;
	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my ($map) = grep { $_->{'uuid'} eq $uuid } @{$maps};
	return ($map, $maps);
}

sub map_legend_metres {
	my ($text) = @_;
	return undef unless defined $text && length $text;
	return undef unless $text =~ /(\d[\d.,]*)\s*([a-zA-Z]+)/;
	(my $n = $1) =~ s/,//g;
	my $u = lc $2;
	my %f = (
		m => 1, metre => 1, meter => 1, metres => 1, meters => 1,
		km => 1000, kilometre => 1000, kilometer => 1000, kilometres => 1000, kilometers => 1000,
		cm => 0.01, mm => 0.001,
		ft => 0.3048, foot => 0.3048, feet => 0.3048,
		mi => 1609.344, mile => 1609.344, miles => 1609.344,
		in => 0.0254, inch => 0.0254, inches => 0.0254,
	);
	return undef unless exists $f{$u};
	return sprintf('%.3f', $n * $f{$u});
}

sub image_function_sanity_check() {
	my $maps = eval { return decode_json &subs::setting_grabber({ app => 'travel', setting => 'maps' }) } || [];
	my $backgrounds = eval { return decode_json &subs::setting_grabber({ app => 'marker', setting => 'backgrounds' }) } || [];
	my $diagrams = eval { return decode_json &subs::setting_grabber({ app => 'handbook', setting => 'diagrams' }) } || [];
	foreach my $map ( @{$maps} ) {
		unless ( -e $map->{'f'} ) {
			@{$maps} = grep { $_->{'uuid'} ne $map->{'uuid'} } @{$maps};
		}
	}

	foreach my $background ( @{$backgrounds} ) {
		unless ( -e $background->{'f'} ) {
			@{$backgrounds} = grep { $_->{'uuid'} ne $background->{'uuid'} } @{$backgrounds};
		}
	}

	foreach my $diagram ( @{$diagrams} ) {
		unless ( -e $diagram->{'f'} ) {
			@{$diagrams} = grep { $_->{'uuid'} ne $diagram->{'uuid'} } @{$diagrams};
		}
	}

	my $jmaps = encode_json $maps;
	my $jbacks = encode_json $backgrounds;
	my $jdiagrams = encode_json $diagrams;

	&subs::setting_setter({ app => 'travel', setting => 'maps', value => $jmaps });
	&subs::setting_setter({ app => 'marker', setting => 'backgrounds', value => $jbacks });
	&subs::setting_setter({ app => 'handbook', setting => 'diagrams', value => $jdiagrams });
}

sub continent_record($c) {
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($c->param('app'));
	my $device = $c->param('device') || &subs::device_setter();
	my $server_time = &subs::rightNow();
	my $timestamp = $c->param('timestamp');
	my $signatorial = &subs::signatorial_designer();
	my $warranty = $c->param('warranty') || &subs::ago_calc(&subs::setting_grabber({ app => 'app', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }),$server_time);
	my $navigation = $c->param('navigation');
	my $next_navigation = $c->param('next_navigation');
	my $returner = {};
	my $purpose = $c->param('purpose');
	my $scope = $c->param('scope');
	# A handheld's place comes from the app's GPS service, never from the posted
	# coordinates: a browser/Wi-Fi answer carries no provider, so it is replaced
	# by the file's real fix. With no proven GPS fix, file no place at all - the
	# appointment's own bookkeeping is not this route's job.
	my $provider = lc($c->param('provider') || '');
	if ($device eq 'mobile' && $purpose ne 'home_plate') {
		my $native = &subs::native_location({ max_age_ms => 15 * 60 * 1000 });
		if ($native) {
			$c->param('latitude', $native->{'latitude'});
			$c->param('longitude', $native->{'longitude'});
			$c->param('accuracy', $native->{'accuracy'});
			$c->param('speed', $native->{'speed'}) if defined $native->{'speed'};
			$c->param('altitude', $native->{'altitude'}) if defined $native->{'altitude'};
			$provider = 'gps';
		}
		else {
			$c->param('latitude', '');
			$c->param('longitude', '');
		}
	}
	# The machine's current place is only written by a machine that has a real
	# GPS. A home plate is the person's own explicit mark, so that purpose keeps
	# working anywhere; a browser's network estimate on a computer has no place
	# here.
	my $publishable_place = ($purpose eq 'home_plate'
		|| (($provider eq 'gps') && $device eq 'mobile')) ? 1 : 0;
	my ($uuid,$pre_uuid);
	if ($c->param('uuid')) {
		$pre_uuid = $c->param('uuid');
		$uuid = $c->param('uuid') . '-' . &subs::random_string_creator(8);
	}
	else {
		$uuid = &subs::random_string_creator(25);
		$pre_uuid = $uuid;
	}
	# One device records an appointment's movement. When another machine is already
	# carrying this appointment, the fix still updates this machine's place and
	# still runs its home plates, but it is not filed into the appointment: two
	# devices travelling together would otherwise count the trip twice.
	my $movement_here = 1;
	my $recorder_of;
	if ($purpose eq 'app' && $c->param('uuid')) {
		$recorder_of = &subs::movement_recorder({ app => $app, appt => $pre_uuid, signatorial => $signatorial, timestamp => $timestamp });
		$movement_here = 0 if length $recorder_of && $recorder_of ne $signatorial;
	}
	if ($navigation ne 'once') {
		my $continentals = &subs::db_query('select * from continent where app = ? and uuid = ? order by server_time DESC LIMIT 1', $app, $uuid)->hashes;
		if ($continentals->[0]->{'latitude'} eq $c->param('latitude') && $continentals->[0]->{'longitude'} eq $c->param('longitude')) {
			$returner = $continentals->[0];
			if ($device eq 'mobile') {
				my $navigations = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'running_navigation' }) } || {};
			}
			# An unmoved fix still refreshes the borrowed place on the peers:
			# the browser short-circuits the write here, but the laptop's hold
			# must keep pace with the fix that just arrived.
			&subs::navigation_share_fix({
				latitude => $c->param('latitude'),
				longitude => $c->param('longitude'),
				accuracy => $c->param('accuracy'),
				timestamp => $timestamp,
			});

			return $returner;
		}
	}
	if (my $alt = $c->param('latitude')) {
		my $speed = $c->param('speed');
		my $altitude = $c->param('altitude');
		$returner = {
			timestamp => $timestamp,
			latitude => $c->param('latitude'),
			longitude => $c->param('longitude'),
			accuracy => sprintf("%.2F", $c->param('accuracy')),
			(defined $speed && $speed =~ /\S/ ? (speed => $speed) : ()),
			(defined $altitude && $altitude =~ /\S/ ? (altitude => $altitude) : ()),
			server_time => $server_time,
			uuid => $uuid,
			type => $purpose,
			app => $app,
			warranty => $warranty,
			signatorial => $signatorial
		};
		&subs::db_insert('continent', $returner) if $movement_here;
		$returner->{'recorded'} = 0 unless $movement_here;
		$returner->{'recorder'} = $recorder_of if defined $recorder_of && !$movement_here;
		# the speed a fix carried is saved as a measure on the appointment it was
		# recorded against, so the evaluation reads it with the rest of the readings
		&subs::continent_speed_measure($app, $pre_uuid, $speed, $timestamp) if $movement_here && defined $speed && $speed =~ /\S/;
		if ($returner->{'accuracy'} < 200 && $publishable_place) {
			my $treturner = clone $returner;
			$treturner->{'type'} = 'temporary';
			$treturner->{'app'} = '__president';
			# hold the place until the next automatic run, not a flat five minutes
			# (the gap that let a private place fall back to public between fixes)
			$treturner->{'warranty'} = &subs::navigation_hold_warranty({
				navigation => $navigation,
				next_navigation => $next_navigation,
				timestamp => $timestamp,
				server_time => $server_time
			});
			$treturner->{'uuid'} = &subs::random_string_creator(31);
			&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
			&subs::db_insert('continent', $treturner);
		}
		# A fresh fix is also the moment to hand it to a computer on this LAN:
		# the receiving machine records its own place, without running the
		# home-plate automation that would duplicate this machine's start.
		&subs::navigation_share_fix($returner) if $returner->{'latitude'};
		if ($purpose eq 'proxy_load' && $scope) {
			&Websocket::send('server', { console => 'listProxy(' . $timestamp . ',' . encode_json($uuid) . ');' });
		}
		elsif ($purpose eq 'proxy_set' && $scope) {
			&Websocket::send('server', { console => 'setProxy(' . $timestamp . ',' . encode_json($uuid) . ');' });
		}
		elsif ($purpose eq 'travel_viewer' && $scope) {
			&Websocket::send('server', { console => 'travelViewer(' . $timestamp . ',' . encode_json($uuid) . ');' });
		}
		elsif ($purpose eq 'home_plate') {
			my $json = encode_json $returner;
			&subs::setting_setter({ app => 'me', device => $device, setting => 'home_plate', value => $json });
		}
		&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $pre_uuid . '\');' }) unless $purpose eq 'navigation';
		&subs::navigation_automation($returner, $provider) if $returner->{'latitude'};
		# a manual navigation answers with the place it has just settled on, so
		# the start menu's site-type picture follows the fresh fix at once
		if ($purpose eq 'navigation') {
			my $nav = &subs::navigation_information({ signatorial => $signatorial, cache => 'no' });
			my $site_type = $nav->{$signatorial}->{'site_type'};
			if ($site_type && $gb::site_types->{$site_type}) {
				$returner->{'site_type'} = $site_type;
				$returner->{'site_rating'} = $nav->{$signatorial}->{'site_rating'};
				$returner->{'site_source'} = $nav->{$signatorial}->{'site_source'};
				$returner->{'site_icon'} = &subs::icon_for($gb::site_types->{$site_type}->{'icon'});
			}
		}
	}
	if ($returner->{'navigation'} ne 'once') {
		$returner->{'navigation'} = &subs::ago_calc('-' . ($navigation || 60000), $server_time);
	}


	return $returner;
}

sub schedule_maker($c,$schedule,$timestamp) {
	my $app = $c->param('app');
	# The caller's timestamp is the appointment's own moment, already adjusted for
	# "ago", a timeshift or the time machine. The old code overwrote it with the
	# raw browser time, so a scheduled run started somewhere other than the first
	# appointment and could write that appointment a second time.
	my $original_timestamp = $timestamp || $c->param('timestamp');
	my $type = $c->param('type');
	# A schedule names appointments to make, not actions on one: repeating a stop
	# or a resume would close or reopen sessions the person never touched.
	return { dates => [] } if $type =~ /^(?:stop|cancel|resume|pause|delay)$/;
	$schedule = '' unless defined $schedule;

	my $settings = &subs::settings_grabber({ app => $app });
	my $warranty = $c->param('warranty');
	$warranty = $settings->{'warranty'} unless defined $warranty && $warranty =~ /\S/;
	$warranty = '-10y' unless defined $warranty && $warranty =~ /\S/;
	my $default_until = &warranty_resolve($warranty, $original_timestamp, 1);
	$default_until = &subs::ago_calc($warranty, $original_timestamp) unless defined $default_until;

	# One entry point: the compact interval syntax stays on the fast parser, and
	# a phrase in words is read by the Guide and expanded here.
	my $result = &subs::schedule_from_text($schedule, $original_timestamp,
		app => $app, type => $type, default_until => $default_until, max => 366);

	if ($result->{'ask'}) {
		# The appointment is still written; the repeats wait for the Associate to
		# clarify the rule. The token is what the schedule action later names.
		my $token = &subs::random_string_creator(24);
		&subs::pending_schedule_add({
			token => $token, kind => 'appointment', app => $app,
			start => $original_timestamp, type => $type, uuid => $c->param('uuid'),
			text => $schedule, created => &subs::rightNow()
		});
		my $when = localtime(int($original_timestamp / 1000))->strftime('%A, %B %d %Y, %I:%M%P');
		$result->{'question'} = 'I started the "' . $app . '" appointment for ' . $when
			. ', but I could not read the schedule "' . $schedule . '": ' . $result->{'ask'}
			. ' Ask me what you need, then call schedule with token "' . $token . '" and the full schedule text.';
		return $result;
	}

	my $dates = $result->{'dates'} || [];
	my $usual_duration = $settings->{'duration'};
	$c->param('duration', $usual_duration) if ($c->param('lockingStatus') || '') eq 'on';
	my $duration = &duration_read($c->param('duration'));
	$duration = &duration_read($usual_duration) unless defined $duration;
	$duration = 0 unless defined $duration;
	$duration = $duration * -1 if $type eq 'start' || $type eq 'record';

	my $base_uuid = $c->param('uuid');
	my @written;
	# The first occurrence is the appointment manager_reset writes itself, so
	# every date here is one of the repeats after it.
	foreach my $next ( @{$dates} ) {
		next unless defined $next && $next > $original_timestamp;
		my $uuid = $base_uuid . md5_sum($next - $original_timestamp) . '+' . md5_sum($app . ' ' . $type);
		next if &subs::db_query('select 1 from appointments where uuid = ? limit 1', $uuid)->hashes->[0];
		push @written, $next;
		&appointment_writer($c, {
			app => $app,
			timestamp => $next,
			type => $type,
			project => $settings->{'project'},
			duration => $duration,
			stop_timestamp => $c->param('duration') =~ /[a-zA-Z0-9]/ ? $next + abs($duration) : undef,
			source_uuid => $base_uuid,
			uuid => $uuid
		});
	}
	$result->{'dates'} = \@written;
	return $result;
}

sub peer_row_for_request {
	my ($c) = @_;
	my $peer_key = $c->stash('peer_verified_key') || '';
	if (!$peer_key) {
		&app_peer_ok($c);
		$peer_key = $c->stash('peer_verified_key') || '';
	}
	if (!$peer_key && ($c->session('peer') || '') eq '1') {
		my $ssig = $c->session('peer_signatorial') || '';
		my $srm = $ssig && &subs::db_select('remote_machines', undef, { signatorial => $ssig })->hash;
		if ($srm) {
			$peer_key = $srm->{'uuid'} || $srm->{'signatorial'};
			$c->stash('peer_verified_key' => $peer_key) if $peer_key;
		}
	}
	return undef unless $peer_key;
	return &subs::db_select('remote_machines', undef, { uuid => $peer_key })->hash
		|| &subs::db_select('remote_machines', undef, { signatorial => $peer_key })->hash;
}

sub peer_action_gate {
	my ($c, $action) = @_;
	my $rm = &peer_row_for_request($c);
	return 1 unless $rm;
	my $need = &subs::peer_action_scope($action) || 'resident';
	return &subs::peer_allows($c, $rm, $need) ? 1 : 0;
}

1;
