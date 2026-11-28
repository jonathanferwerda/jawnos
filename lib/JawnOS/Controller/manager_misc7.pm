package Manager;

# manager_misc7: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/appointment_details
sub action_25444 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $timestamp = $c->param('timestamp');
	my $time_machine = $c->param('time_machine');
	my $timeshift = $c->param('timeshift');
	my $scope = $c->param('scope');
	my $sorts = $c->param('sorts');
	my $filter = $c->param('filter');
	my $uuid = $c->param('uuid');

	if ($time_machine) {
		$timestamp = &time_machine_resolve($time_machine,$timestamp);
	}
	if ($timeshift) {
		$timeshift = &subs::time_abbrev_translator($timeshift);
		$timestamp = $timestamp - ($timeshift);
	}
	my $appts = &log_reader({ uuid => $uuid, app => $app, filter => $filter, timeshift => $timeshift, timestamp => $timestamp, sorts => $sorts, scope => $scope, view => 'appointment_details' });
	my @details;
	my $pseudonyms = &pseudonym_maker('viewer', '');
	my $settings = $appts->{$app}->{'setting'};
	$settings->{'home_plate'} = eval { return decode_json $settings->{'home_plate'} } || {};
	my $main_home_plate = eval { return decode_json &subs::setting_grabber({ app => 'me', setting => 'home_plate' }) } || {};
	# A device's signatorial as the name the house knows it by, so the carrier line
	# under the fixes names a machine the way the movement picker does.
	my $carrier_names = &subs::device_labels();
	push @details, @{$appts->{$app}->{'list'}} if $appts->{$app}->{'list'};
	my $sum = scalar @details;
	foreach my $d ( @details ) {
		if ($d->{'files'}) {

			$sum += scalar @{$d->{'files'}};
		}
	}


	#splice @details, 10;



	my $models = &subs::db_query('select * from model where app=? order by timestamp desc', $app)->hashes;
	my $options = &subs::db_query('select * from option where app=? order by timestamp desc', $app)->hashes;
	my $option_categories = &subs::db_query('select * from option_category where app=? order by timestamp desc', $app)->hashes;
	# The Travel basemap keys live once under __president as map_key_<provider>;
	# the appointment details' map picker offers a keyed service only when its
	# key is already saved, so nothing asks for a key in two places.
	my $map_key_rows = &subs::db_query("select setting, value from settings where app='__president' and setting like 'map_key_%' and value is not null and value != ''")->hashes;
	my $map_keys = [];
	foreach my $mkr ( @{$map_key_rows} ) {
		my $provider = $mkr->{'setting'};
		$provider =~ s/^map_key_//;
		push @{$map_keys}, { provider => $provider, value => $mkr->{'value'} };
	}
	# Each app remembers its own appointment-details layout: the Dist view and
	# whether the Dist, Measures and Duties sections were left open. The answer is
	# shared by the house's machines; a __president row from the first build is
	# the fallback until that app is changed.
	my %detail_setting;
	foreach my $name (qw(dist_view distance_open measures_open duties_open)) {
		my $value = &subs::setting_grabber({ app => $app, setting => 'appointment_' . $name, device => 'all' });
		if (!defined $value || !length $value) {
			$value = &subs::setting_grabber({ app => '__president', setting => 'appointment_' . $name, device => 'all' });
		}
		$detail_setting{$name} = $value;
	}
	my $dist_view = $detail_setting{'dist_view'} || 'fixes';
	my $distance_open = ($detail_setting{'distance_open'} || '') eq 'on' ? 1 : 0;
	my $measures_open = ($detail_setting{'measures_open'} || '') eq 'on' ? 1 : 0;
	my $duties_open = ($detail_setting{'duties_open'} || '') eq 'on' ? 1 : 0;
	foreach my $mo ( @{$models}, @{$options} ) {
		$mo->{'characteristics'} = eval { return decode_json $mo->{'characteristics'} } || [];
		if (my @oc = grep { $_->{'name'} eq 'option_category' } @{$mo->{'characteristics'}}) {
			$mo->{'option_category'} = $oc[0]->{'value'};
		}
		else {
			$mo->{'option_category'} = 'uncategorized';
		}
	}

	my $home_plate = &subs::setting_grabber({ app => 'me', setting => 'home_plate' });
	my $hp = eval { return decode_json $home_plate } || {};
	foreach my $l ( @details ) {
		if ($l->{'data'}) {
			$l->{'data'} = eval { return decode_json $l->{'data'} } || $l->{'data'};
		}
		if ($l->{'duties'}) {
			$l->{'duties'} = eval { return decode_json $l->{'duties'} } || [];
		}
		$l->{'options'} = eval { return decode_json $l->{'options'} } || [];
		$l->{'model'} = eval { return decode_json $l->{'model'} } || {};
		$l->{'model'}->{'home_plate'} = eval { return decode_json &subs::setting_grabber({ app => &subs::unformat_name($l->{'model'}->{'name'}), setting => 'home_plate' }) } || {};
		my ($continental,$src);
		if ($l->{'source_uuid'}) {
			$continental = &subs::db_query('select * from continent where (app = ? and uuid like ?) or uuid like ? order by server_time',$app, $l->{'uuid'} . '%',$l->{'source_uuid'} . '%')->hashes;
			my $source = &subs::db_select('appointments', undef, { uuid => $l->{'source_uuid'} })->hashes->[0];
			$l->{'src'} = $source;
		}
		else {
			$continental = &subs::db_query('select * from continent where app = ? and uuid like ? order by timestamp',$app, $l->{'uuid'} . '%')->hashes;
		}
		$l->{'measures'} = eval { return decode_json $l->{'measures'} } || [];
		# which device was with the person: the one whose fixes covered the most
		# ground in this appointment, or the two that shared it when the device
		# changed mid-trip. A tablet left at home moves a few metres; the phone
		# carried on a walk covers the walk.
		my $carrier = &subs::carrier_device($continental);
		my $carried = &subs::carrier_track($continental);
		if ($carrier) {
			my @names = map { $carrier_names->{$_} || substr($_, 0, 10) } @{ $carried->{'carriers'} || [] };
			@names = ( $carrier_names->{ $carrier->{'signatorial'} } || substr( $carrier->{'signatorial'}, 0, 10 ) ) unless @names;
			$l->{'carrier'} = {
				signatorial => $carrier->{'signatorial'},
				name => join(', ', @names),
				path => $carrier->{'metres'},
				fixes => $carrier->{'fixes'},
				devices => $carrier->{'devices'},
			};
		}
		# only the device that was with the person makes the track and its
		# distance: the parked device's rows still exist (its own place and home
		# plates keep running) but joining them in time order added a house-to-walk
		# leg per fix, and the total read as kilometres the person never travelled.
		# Where the device with the person changed mid-trip the track is one leg
		# each, so a dead battery costs the trip nothing.
		my $track = $carried->{'fixes'};
		my @p = grep { $_->{'name'} eq $l->{'type'} } @{$pseudonyms};
		$l->{'total_distance'} = 0;
		my $last_visitor;
		my @homebase_plate;
		if ($main_home_plate->{'latitude'} && $main_home_plate->{'longitude'}) {
			my $hp = $main_home_plate;
			@homebase_plate = ( $hp->{'latitude'} + 0, $hp->{'longitude'} + 0 );
		}
		my $start_ts;
		foreach my $continent ( @{$track} ) {
			if ($continent->{'latitude'}) {
				$start_ts ||= $continent->{'timestamp'};
				my @home_plate;

				if ($l->{'model'}->{'home_plate'}->{'latitude'} && $l->{'model'}->{'home_plate'}->{'longitude'}) {
					my $hp = $l->{'model'}->{'home_plate'};
					@home_plate = ( $hp->{'latitude'} + 0, $hp->{'longitude'} + 0 );
				}
				elsif ($settings->{'home_plate'}->{'latitude'} && $settings->{'home_plate'}->{'longitude'}) {
					my $hp = $settings->{'home_plate'};
					@home_plate = ( $hp->{'latitude'} + 0, $hp->{'longitude'} + 0 );
				}
				my @visitor = ( $continent->{'latitude'} + 0, $continent->{'longitude'} + 0 );
				# kilometres on the WGS84 ellipsoid, the same rule as the plate
				# automation and the Travel list
				my $distance = sprintf( '%.3f', &subs::geodesic_offset( @home_plate, @visitor )->{'metres'} / 1000 ) if scalar @home_plate;

				if ($main_home_plate->{'latitude'} && $main_home_plate->{'longitude'}) {
					$continent->{'home_distance'} = sprintf( '%.3f', &subs::geodesic_offset( @homebase_plate, @visitor )->{'metres'} / 1000 );
				}
				my ($speed,$increment_distance);
				if ($last_visitor->{'visitor'}) {
					$increment_distance = &subs::geodesic_offset( @visitor, @{$last_visitor->{'visitor'}} )->{'metres'} / 1000;
					$speed = &travel_speed_calculator({ distance => $increment_distance, start => $last_visitor->{'continent'}->{'timestamp'}, end => $continent->{'timestamp'} });
					$l->{'total_distance'} += sprintf("%.4f", $increment_distance);
					if ($speed) {
						$l->{'speed'} = &travel_speed_calculator({ distance => $l->{'total_distance'}, start => $start_ts, end => $continent->{'timestamp'} });
					}
				}


				$last_visitor = { visitor => \@visitor, continent => $continent };
				if ($continent->{'timestamp'} eq $l->{'timestamp'}) {
					$continent->{'timestamp'} = $continent->{'server_time'};
				}
				push @{$l->{'distance'}}, {
					server_time => $continent->{'server_time'},
					home_distance => $continent->{'home_distance'},
					distance => sprintf("%.4f", $distance),
					latitude => $continent->{'latitude'},
					longitude => $continent->{'longitude'},
					signatorial => $continent->{'signatorial'},
					uuid => $continent->{'uuid'},
					timestamp => $continent->{'timestamp'},
					increment_speed => sprintf("%.2f", $speed),
					increment_distance => sprintf("%.2f", $increment_distance)
				};

			}
		}
		# the carrier line's own number is the track this section just summed, so a
		# trip that changed devices reads as one trip rather than as one leg of it
		$l->{'carrier'}->{'path'} = int( $l->{'total_distance'} * 1000 + 0.5 ) if $l->{'carrier'};
		$l->{'pseudonym'} = $p[0];
		if ($l->{'type'} eq 'website') {
			$l->{'content'} = &subs::db_select('websites', [ 'internal_url' ], { timestamp => $l->{'timestamp'} })->{content}->{hash};
		}
	}

	$c->render(
		template => 'appointment_details',
		appts => $appts,
		a => $app,
		details => \@details,
		settings => $settings,
		models => $models,
		options => $options,
		option_categories => $option_categories,
		map_keys => $map_keys,
		dist_view => $dist_view,
		distance_open => $distance_open,
		measures_open => $measures_open,
		duties_open => $duties_open,
		# the template's map fallback draws the house's own home plate when neither
		# the model nor the app has one, so hand it the decoded plate
		main_home_plate => $main_home_plate,
		device => $device,
		remote_machines => &subs::db_select('remote_machines', undef, { connection => 'active' })->hashes
	);
}

# POST /manager/delete_duty
sub action_25646 {
	my $c = shift;


	my $duuid = $c->param('duuid');
	my $server_time = $c->param('server_time');
	my $app_uuid = $c->param('app_uuid');
	my $app = &subs::unformat_name($c->param('app'));

	my $appt = &subs::db_select('appointments', undef, { uuid => $app_uuid, app => $app })->hashes->[0];
	return $c->render(json => { duuid => $duuid }) unless $appt;
	my $duties = eval { return decode_json $appt->{'duties'} } || [];
	@{$duties} = grep { $_->{'duuid'} && $_->{'duuid'} ne $duuid } @{$duties};
	@{$duties} = sort { $a->{'timestamp'} <=> $b->{'timestamp'} } @{$duties};

	# NULL, not []: an empty array still matches "duties is not null", so the row
	# stayed in the duty watch every 2 seconds with a next_duty already in the past
	my $next_duty = scalar @{$duties} ? $duties->[0]->{'timestamp'} : undef;
	my $jduties = scalar @{$duties} ? encode_json $duties : undef;

	&subs::db_update('appointments', { duties => $jduties, next_duty => $next_duty, server_time => &subs::rightNow() }, { app => $app, uuid => $appt->{'uuid'} });
	&subs::appt_alarm_setter(&subs::db_select('appointments', undef, { app => $app, uuid => $appt->{'uuid'} })->hashes->[0]);
	$c->render(json => { duuid => $duuid });
}

# The Autostop bar on a running appointment. Only the open session can carry it:
# a stopped or older row is history and must not be taught a new plate rule.
# 'off' is the only value worth storing - an absent column means on, so the
# default stays on for every row written before this existed.
# POST /manager/appointment/autostop
sub action_25674 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $uuid = $c->param('uuid');
	my $value = ($c->param('value') || '') eq 'off' ? 'off' : 'on';

	return $c->render(json => { error => 'no app or session' }) unless $app && $uuid;
	my $open = &subs::db_query('select uuid from appointments where app=? and uuid=? and (type=? or type=?) and stop_seen is null limit 1',
		$app, $uuid, 'start', 'record')->hashes->[0];
	return $c->render(json => { error => 'not running' }) unless $open;

	&subs::db_update('appointments', { autostop => $value, server_time => &subs::rightNow() }, { app => $app, uuid => $uuid });
	$c->render(json => { uuid => $uuid, autostop => $value });
}

# POST /manager/palette
sub action_25772 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $duty = $c->param('duty');
	my $file = $c->param('file');
	my $type = $c->param('type') || '';
	my $uuid = $c->param('uuid');
	my $returner = {};
	my $job = { ext => 'png' };
	my $duties = eval { return decode_json $c->param('duties') } || [];
	# The palette's temp file keeps the picture's own format, so the bytes the
	# browser is handed are the bytes it is told they are. A sealed name ends in
	# .enc, which is not an image format, so the media suffix before it is used;
	# a format magick cannot write falls back to PNG.
	my $ext = defined $file ? $file : '';
	$ext =~ s/\.enc$//i;
	$ext = ($ext =~ /\.([A-Za-z0-9]+)$/) ? lc $1 : 'png';
	$ext = 'jpg' if $ext eq 'jpeg';
	$ext = 'tiff' if $ext eq 'tif';
	$ext = 'png' unless grep { $_ eq $ext } qw(jpg png gif bmp webp tiff);
	my $sd = &subs::home('~/.president/') . &subs::random_string_creator() . '.' . $ext;
	if ($type eq 'snapshot') {
	}
	else {
		$job = &rock_and_roll($c);
		my $data = $job->{'data'};
		chomp $data;
		write_file($sd, $data);

	}
	my $original = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes;
	my $files = eval { return decode_json $original->[0]->{'file'} } || [];
	# A blank input box is given the same default the app bridge uses, so every
	# step works the first time it is pressed on a desktop as well as a phone.
	my @edits = &subs::palette_edit_steps($duties);
	# The phone has no magick: one bridge call applies the whole list. A desktop,
	# where the bridge answers undef, keeps the per-step command it always ran.
	if (@edits && !&subs::image_bridge_edit($sd, \@edits)) {
		foreach my $e ( @edits ) {
			system('magick', $sd, '-' . $e->{'duty'}, $e->{'value'}, $sd);
		}
	}
	if ($duty eq 'copy') {
		foreach my $fi ( @{$files} ) {
			my $f = $fi->{'f'};
			my $tf = $fi->{'thumb'};
			if ($f eq $file) {
				my @folder = split '/', $f;
				pop @folder;
				my $folder = join '/', @folder;
				my $thumb_folder = $folder . '/.thumbs';
				my @f = split /\./, $f;
				$f[0] = &subs::random_string_creator(12);
				my $nf = $folder . '/' . join '.', @f;
				my $tnf = $thumb_folder . '/' . join '.', @f;
				my %fil = %{$fi};
				my $fil = \%fil;
				$fil->{'server_time'} = &subs::rightNow();
				$fil->{'uuid'} = &subs::random_string_creator(32);
				$fil->{'f'} = $nf;

				my $cp = 'cp -v ' . &subs::shell_quote($f) . ' ' . &subs::shell_quote($nf);
				`$cp`;
				if ($fil->{'thumb'}) {
					$fil->{'thumb'} = $tnf;
					my $cp_thumb = 'cp -v ' . &subs::shell_quote($tf) . ' ' . &subs::shell_quote($tnf);
					`$cp_thumb`;
				}
				push @{$files}, $fil;
			}
		}
		my $modified_file = encode_json $files;
		&subs::db_update('appointments', {
			server_time => &subs::rightNow(),
			file => $modified_file,
			encryption_standard => undef,
		},
		{ uuid => $uuid, app => $app });
		&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => &subs::session_suds($c) });
		&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	}
	if ($duty eq 'save') {
		my $data = read_file($sd);
		write_file($file, $data);
		my $new_file = $file;
		$new_file =~ s/\.enc$//gi;
		my $mv = 'mv -v ' . &subs::shell_quote($file) . ' ' . &subs::shell_quote($new_file);
		`$mv`;
		my ($db) = &subs::database_grabber();


		foreach my $fi ( @{$files} ) {
			my $f = $fi->{'f'};

			if ($f eq $file) {

				$f =~ s/\.enc$//gi;
				$fi->{'f'} = $f;
				if ($fi->{'thumb'}) {
					my $thumb = $fi->{'thumb'};
					system('shred', '-u', $thumb);
					$fi = &thumbnail_creator($fi);
				}
				$fi->{'server_time'} = &subs::rightNow();
			}

		}
		my $modified_file = encode_json $files;
		&subs::db_update('appointments', {
			server_time => &subs::rightNow(),
			file => $modified_file,
			encryption_standard => undef,
		},
		{ uuid => $uuid, app => $app });
		&subs::file_encrypter({ app => $app, timestamp => $timestamp, suds => &subs::session_suds($c) });
		&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	}
	else {
		my $bytes = read_file($sd);
		# The edited temp file may have been written in the picture's own format
		# (a JPEG stays a JPEG) or re-encoded by the bridge, so the type comes
		# from the bytes rather than from the name that was read.
		my $mime = &subs::plaintext_verdict(substr($bytes, 0, 65536)) || $job->{'fd'} || 'image/png';
		$returner->{'image'} = 'data:' . $mime . ';base64,' . encode_base64($bytes);
	}
	system('shred', '-u', $sd);
	$c->render(json => $returner);
}

# GET /manager/share
sub action_25890 {
	my $c = shift;
	my $src = $c->param('src');
	my $type = $c->param('type');
	my $returner;
	if ($device eq 'mobile') {
		$returner = &subs::device_call('share.send', { type => $type, path => $src })
			? 'shared' : '';
	}
	$c->render('text' => $returner);
}

# GET /manager/note_retriever
sub action_25901 {
	my $c = shift;
	my $app_timestamp = $c->param('app_timestamp');
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $reflected_server_time = $c->param('server_time');
	my $uuid = $c->param('uuid');
	my $notekeeper = &subs::note_retriever($uuid, &subs::session_suds($c) || &subs::suds_grabber());
	$c->render(json => { notes => $notekeeper });
}

# GET /manager/torch
sub action_25914 {
	my $c = shift;
	my $torch = $c->param('torch');
	my $timestamp = $c->param('timestamp');
	my $returner;
	if ($device eq 'mobile') {
		# The parameter is inverted on purpose: the page sends the state it is
		# leaving, and this route has always answered with the new one.
		my $on = $torch eq 'off' ? 1 : 0;
		&subs::device_call('hardware.torch', { on => $on });
		$returner = $on ? 'on' : 'off';
	}
	return $c->render(text => $returner);
}

# GET /manager/centre_view
sub action_25928 {
	my $c = shift;
	# the app arrives either as its JSON object or as a bare name. A bare name
	# used to fall through and then be dereferenced as a hash ("Can't use
	# string as a HASH ref"), which killed the worker and dropped the
	# connection instead of answering - the app's own centre_view calls always
	# carry the object, but the watch, the boards and any hand-made request do
	# not, and they took the worker down with them.
	my $ap = eval { return decode_json $c->param('app') };
	$ap = { name => $c->param('app'), app => $c->param('app') } if ref $ap ne 'HASH';
	my $app = $ap;
	my $jp_report = eval { return decode_json $c->param('jp_report') } || {};
	my $timestamp = $c->param('timestamp');
	if ($app->{'name'}) {
		&padlock_time_extender($c);
		my $window = &centre_view_grabber({ c => $c, app => $app->{'name'}, timestamp => $timestamp, jp_report => $jp_report, source => $c->param('source') });
		if ($c->param('source') ne 'ws') {
			# A hidden tab has nobody looking at it; mirroring into it was a
			# 40-49 KB fetch and render that stole the main thread from the tab
			# the person is actually using. Visible windows (including a second
			# monitor) still mirror.
			&Websocket::send('tab', { browser_tab_id => $c->param('browser_tab_id'), not_me => 1, console => &Websocket::console_command('appointmentGrabberIfVisible', $app->{'name'}, $timestamp)});
		}
	#	&Websocket::send('tab', { browser_tab_id => $c->stash('browser_tab_id'), app => $app, window => $window, timestamp => $timestamp, not_me => 1 });
		$c->render(text => $window);
	}
	else {
		$c->render(text => '');
	}
}

# The whole searchable app list, read once by the manager and filtered in the
# browser. The settings table is small enough to hand over in one go, which is
# what makes typing local (and so instant) instead of a request per keystroke.
# Each entry is the key a window opens with, the name a person reads, the icon
# the window wears, and the akas the house has taught it. `version` lets the
# manager ask a tiny question - "has anything changed?" - without pulling the
# list again while it is unchanged.
# GET /manager/search_index
sub action_26091 {
	my $c = shift;
	my $version = &search_index_signature();
	if ($c->param('check')) {
		$c->render(json => { version => $version });
		return;
	}
	my $rows = &subs::db_query("select app, device, setting, value, server_time from settings where app is not null and app != '' and setting in ('pos','visible','main_image','aka')")->hashes;
	my %settings_by_app;
	foreach my $r ( @{$rows} ) {
		next unless defined $r->{'app'} && length $r->{'app'};
		$settings_by_app{$r->{'app'}}->{$r->{'setting'}}->{$r->{'device'} || ''} = { value => $r->{'value'}, server_time => $r->{'server_time'} };
	}
	# the music player writes the tracks it plays with account gallery, and the
	# dock's search is not the place for those to surface as apps
	my $gallery = {};
	foreach my $g ( @{ &subs::db_query('select distinct app from appointments where account = ? and app is not null', 'gallery')->hashes } ) {
		$gallery->{$g->{'app'}} = 1;
	}
	my (@apps, %indexed);
	foreach my $app ( sort keys %settings_by_app ) {
		my $s = $settings_by_app{$app};
		next if &help_app_hidden($app);
		# a quarantine key and an overlong key are the corrupt data that
		# settings_orphans.pl renames, never an app the box should offer
		next if $app =~ /^__/;
		next if &subs::name_overlong($app);
		# a known app stays even when it has gallery rows; those rows are its work
		next if $gallery->{$app} && !$gb::known_appts->{$app};
		my $pos_entry = &search_index_setting($s->{'pos'}, $device);
		my $pos = defined $pos_entry ? (ref $pos_entry eq 'HASH' ? $pos_entry->{'value'} : $pos_entry) : '';
		my $mi_entry = &search_index_setting($s->{'main_image'}, $device);
		my $main_image = defined $mi_entry ? (ref $mi_entry eq 'HASH' ? $mi_entry->{'value'} : $mi_entry) : '';
		my $stamp = ref $mi_entry eq 'HASH' ? ($mi_entry->{'server_time'} || '') : '';
		# the same aka convention guide_aka_read follows: a comma-separated row
		# on the app itself, so a word the person taught the house still finds
		# the app from the dock. The akas are house-wide, so every device's row
		# is read, not only this machine's. A hidden (private) app never gets
		# here.
		my (@aka, %aka_seen);
		foreach my $aka_row ( values %{ $s->{'aka'} || {} } ) {
			my $aka_value = ref $aka_row eq 'HASH' ? $aka_row->{'value'} : $aka_row;
			foreach my $token ( split /,/, ($aka_value || '') ) {
				$token =~ s/^\s+|\s+$//g;
				next unless length $token;
				push @aka, $token unless $aka_seen{$token}++;
			}
		}
		push @apps, { app => $app, name => &subs::format_name($app), icon => &search_index_icon({ app => $app, pos => $pos, main_image => $main_image, stamp => $stamp }), (scalar @aka ? (aka => \@aka) : ()) };
		$indexed{$app} = 1;
	}
	# the menu's own apps are code, not appointments: help, folders and mailbox
	# carry no visible row at all, and some have no appointment history either,
	# yet the box should still find and open them
	my %builtin = map { $_ => 1 } qw(
		configure handbook budget travel mailbox music embedded box_office cards security
		terminal ide gallery synth editor marker twirl studio store relational web warehouse
		measures folders process_monitor market notes phone people email chat internet search help
	);
	foreach my $app ( sort keys %builtin ) {
		next if $indexed{$app};
		next if &help_app_hidden($app);
		# a built-in with no visible row is always an app; one the person has
		# explicitly hidden stays hidden
		next if $settings_by_app{$app} && $settings_by_app{$app}->{'visible'};
		push @apps, { app => $app, name => &subs::format_name($app), icon => &search_index_icon({ app => $app }) };
	}
	$c->render(json => { apps => \@apps, version => $version });
}

# GET /manager/keyup_search
sub action_26142 {
	my $c = shift;
	my $search = $c->param('search');
	my $timestamp = $c->param('timestamp');
	if ($search) {
		my $movement;
		($search,undef,$movement) = &subs::typesetter(&subs::unformat_name($search),'no');
		$search = &subs::format_name($search);
		my @search = split ' ', $search;

		$search = join '%', @search;

		$search = '%' . $search . '%';
		my ($db) = &subs::database_grabber();
		# the music player writes the tracks it plays with account gallery, and the
		# dock's search is not the place for those to surface as apps. Visibility is
		# read through the same rule as everywhere else, not as one exact value.
		my $rows = &subs::db_query('select DISTINCT(app) from settings where device = ? and setting=? and app like ? and app not in (select distinct app from appointments where account = ? and app is not null) LIMIT 40', $device, 'visible', $search, 'gallery')->hashes;
		my @apps;
		foreach my $row ( @{$rows} ) {
			next unless &help_app_hidden($row->{'app'}) == 0;
			push @apps, $row;
			last if scalar @apps >= 7;
		}
		my $resulted = $c->render_to_string(template => 'search/manager', results => \@apps);

		$c->render(json => { results => $resulted, count => scalar @apps, timestamp => $timestamp });
	}
	else {
		$c->render(json => { count => 0, timestamp => $timestamp });
	}
}

# The Search app: one window with three contexts. Apps reads the house's own
# records, Web reads the engines that are switched on, and AI talks to the model
# the person chooses there. The window is the same for all three; the client
# remembers the tab and asks only that one.
# GET /manager/search
sub action_26178 {
	my $c = shift;
	my $q = $c->param('q') || $c->param('search') || '';
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	# Every chat model from every configured provider, grouped by provider, for
	# the AI tab's picker. Cached like the Help window's list, keyed by the provider
	# set: opening Search must not sit on an Ollama probe or a Cloudflare request,
	# and a provider added to the registry shows up without waiting out the cache.
	&subs::preload('pen_model_list');
	my $sig = &subs::ai_catalogue_signature();
	my $context = 'ai_models_' . $sig;
	my $models = &subs::cache_get({ app => 'search', context => $context });
	unless (ref $models eq 'ARRAY') {
		$models = &subs::ai_model_catalogue('chat');
		&subs::cache_set({ app => 'search', context => $context, warranty => '-10m' }, $models);
	}
	# Offer only what this house can reach: a provider whose key is entered, or
	# the local Ollama and its peers. The cached catalogue is the full one, so a
	# key added in Plat shows here at once instead of waiting out the cache.
	$models = &subs::ai_catalogue_available($models);
	my $contents = $c->render_to_string(
		template => 'apps/search',
		app => 'search',
		q => $q,
		models => $models,
		selected_model => (&subs::setting_grabber({ app => 'mail', setting => 'help_assistant' }) || '')
	);
	my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'search', contents => $contents }, $timestamp);
	$c->render(text => $window);
}

# GET /manager/search/apps
sub action_26236 {
	my $c = shift;
	my $apps = &search_app_matches($c->param('search'));
	$c->render(json => { apps => $apps });
}

# GET /manager/search/engines
sub action_26296 {
	my $c = shift;
	my ($all, $state) = &search_engine_all();
	$c->render(json => {
		engines => $all,
		enabled => [ map { $_->{'id'} } grep { $_->{'enabled'} } @{$all} ],
		defaults => [ @gb::search_default_engines ]
	});
}

# POST /manager/search/engines/toggle
sub action_26305 {
	my $c = shift;
	my $id = $c->param('id') // '';
	my $on = ($c->param('enabled') // '') =~ /^(?:1|on|yes|true)$/i ? 1 : 0;
	my ($all, $state) = &search_engine_all();
	unless (grep { $_->{'id'} eq $id } @{$all}) {
		$c->render(json => { ok => 0, error => 'unknown engine' });
		return;
	}
	my %enabled = map { $_ => 1 } @{ $state->{'enabled'} };
	if ($on) { $enabled{$id} = 1; }
	else { delete $enabled{$id}; }
	$state->{'enabled'} = [ sort keys %enabled ];
	&search_engine_save($state);
	$c->render(json => { ok => 1, enabled => $state->{'enabled'} });
}

# POST /manager/search/engines/remove
sub action_26321 {
	my $c = shift;
	my $id = $c->param('id') // '';
	my ($all, $state) = &search_engine_all();
	my ($engine) = grep { $_->{'id'} eq $id && $_->{'custom'} } @{$all};
	unless ($engine) {
		$c->render(json => { ok => 0, error => 'not a custom engine' });
		return;
	}
	@{$state->{'custom'}} = grep { ($_->{'id'} // '') ne $id } @{$state->{'custom'}};
	$state->{'enabled'} = [ grep { $_ ne $id } @{ $state->{'enabled'} } ];
	&search_engine_save($state);
	$c->render(json => { ok => 1 });
}

# POST /manager/search/engines/add
sub action_26361 {
	my $c = shift;
	my $name = $c->param('name') // '';
	my $url = $c->param('url') // '';
	unless ($url =~ m{^https?://}i) {
		$c->render(json => { ok => 0, error => 'the engine needs an http(s) address' });
		return;
	}
	my $entry = &search_engine_add_custom($name, $url);
	$c->render(json => { ok => 1, id => $entry->{'id'}, name => $entry->{'name'}, url => $entry->{'url'} });
}

1;
