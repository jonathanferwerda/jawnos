package Manager;

# manager_misc12: route actions moved out of Manager.pl, one sub per route so a
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

use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

# POST /manager/lorawan/settings
sub action_41046 {
	my $c = shift;
	my %allowed = map { $_ => 1 } qw/EU433 EU868 US915 AU915 AS923 AS923_2 AS923_3 AS923_4 KR920 IN865 CN470/;
	my $band = $c->param('band') // 'EU433';
	return $c->render(json => { ok => 0, error => 'unknown LoRaWAN band' }) unless $allowed{$band};
	my $hex = sub {
		my ($v, $len) = @_;
		$v = defined $v ? uc $v : '';
		$v =~ s/[^0-9A-F]//g;
		return ( length($v) == $len ) ? $v : undef;
	};
	my $join = $hex->($c->param('join_eui'), 16);
	my $dev = $hex->($c->param('dev_eui'), 16);
	return $c->render(json => { ok => 0, error => 'Join EUI must be 16 hex characters' }) unless $join;
	return $c->render(json => { ok => 0, error => 'Dev EUI must be 16 hex characters' }) unless $dev;
	my $key = $c->param('app_key') // '';
	if ( length $key ) {
		$key = $hex->($key, 32);
		return $c->render(json => { ok => 0, error => 'App key must be 32 hex characters' }) unless $key;
	}
	my $subband = int($c->param('subband') // 1);
	$subband = 1 if $subband < 1 || $subband > 8;
	my $fport = int($c->param('fport') // 1);
	$fport = 1 if $fport < 1 || $fport > 223;
	my %set = (
		enabled => ($c->param('enabled') ? 'on' : 'off'),
		band => $band,
		subband => $subband,
		join_eui => $join,
		dev_eui => $dev,
		fport => $fport,
		confirmed => ($c->param('confirmed') ? 'on' : 'off'),
	);
	$set{'app_key'} = $key if length $key;
	foreach my $k ( keys %set ) {
		&subs::setting_setter({ app => 'mail', setting => 'lorawan_' . $k, value => $set{$k}, device => 'all' });
	}
	my $push = &lorawan_push_config($c);
	$c->render(json => { ok => 1, push => $push, settings => &lorawan_public_settings($c) });
}

# POST /manager/lorawan/join
sub action_41086 {
	my $c = shift;
	my $res = &lorawan_deck_call('/lorawan_join', { s => &lorawan_secret($c) });
	$c->render(json => $res);
}

# POST /manager/lorawan/send
sub action_41091 {
	my $c = shift;
	my $text = $c->param('message') // '';
	$c->render(json => &lorawan_send_text($text));
}

# GET /manager/lorawan/status
sub action_41096 {
	my $c = shift;
	my $res = &lorawan_deck_call('/lorawan_status', { s => 'manager' });
	$c->render(json => $res);
}

# POST /manager/sms/message
sub action_41140 {
	my $c = shift;
	my $digits = $c->param('digits');
	my $message = $c->param('message');

	my $sms = &sms_message_send($digits,$message);

	$c->render(json => $sms);

}

# POST /manager/delete_app
sub action_41155 {
	my $c = shift;
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $timestamp = $c->param('timestamp');
	my $type = $c->param('type');
	my $server_time = $c->param('server_time');
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		&remote_relay_request($c, { dissemination => 'yes' });
	}, { name => 'delete app remote relay' });
	my $deleter = &delete_app($app,$uuid,$server_time,'manual delete');
	&padlock_time_extender($c);

	# delete_app sends the header at once and forks the window render; the reply
	# only needs the deleted row's own status.
	$c->render(json => { deleter => $deleter });

}

# POST /manager/delete_file
sub action_41370 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $file_uuid = $c->param('file_uuid');
	my $app_uuid = $c->param('app_uuid');
	&delete_file({ app => $app, file_uuid => $file_uuid, app_uuid => $app_uuid });

	$c->render(json => { app => $app, file_uuid => $file_uuid, app_uuid => $app_uuid });
}

# GET /manager/edit_app
sub action_41431 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $uuid = $c->param('uuid');
	my $select = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid, timestamp => $timestamp })->hashes->[0];
	return $c->render(text => 'not found', status => 404) unless $select && defined $select->{'uuid'};
	my $s = &subs::session_suds($c);
	foreach my $note_type (qw/start_notes notes end_notes/) {
		$select->{$note_type} = &subs::note_decrypter($s, $select->{$note_type},$select->{'ost'}) if eval { &subs::note_decrypter($s, $select->{$note_type},$select->{'ost'}) };
	}
	# The editor previews the row's own file. A media row keeps a JSON list of
	# {f,uuid,...}; an older row may hold a plain path. Preparing it here keeps
	# the template free of decode logic (and of the log reader's row globals).
	my @edit_files;
	my $raw_file = $select->{'file'} // '';
	if (length $raw_file) {
		my $list = eval { return decode_json $raw_file };
		$list = [ $list ] if ref $list eq 'HASH' && defined $list->{'f'};
		if (ref $list ne 'ARRAY') { $list = [ { f => $raw_file } ]; }
		foreach my $f ( @{$list} ) {
			next unless ref $f eq 'HASH' && defined $f->{'f'} && length $f->{'f'};
			my $ext = lc($f->{'f'});
			my $file_type = $ext =~ /\.(?:jpe?g|png|bmp|tiff|gif|webp)(?:\?|$)/ ? 'img'
				: $ext =~ /\.(?:wav|mp3|aiff|weba|m4a|flac|ogg)(?:\?|$)/ ? 'snd'
				: $ext =~ /\.(?:mp4|avi|mov|webm|mkv)(?:\?|$)/ ? 'vid' : 'file';
			push @edit_files, { file => $f->{'f'}, uuid => $f->{'uuid'}, function => $f->{'function'}, type => $f->{'type'}, name => $f->{'name'}, file_type => $file_type };
		}
	}
	$select->{'files'} = \@edit_files;
	$select->{'data_hash'} = (eval { return decode_json $select->{'data'} }) || {};
	my $appts = &log_reader({ app => $app, view => 'appointment_display' });
	# The form renders against one app key; without it every $appts->{$a} lookup
	# in the details block resolved to the empty key and the form came back blank,
	# so a save posted blanks over good data.
	$c->render(template => 'apps/edit_app', app => $select, a => $app, appts => $appts);
}

# POST /manager/edit_app
sub action_41468 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $server_time = &subs::rightNow();
	my $uuid = $c->param('uuid');
	#Read the row first: an update that matches nothing must not answer 'ok'.
	my $appt = defined $uuid ? &subs::db_select('appointments', undef, { uuid => $uuid })->hashes->[0] : undef;
	return $c->render(text => 'not found', status => 404)
		unless $appt && defined $appt->{'uuid'} && (($appt->{'app'} // '') eq $app);

	# This form edits one record. A new name moves *this row* to that app and
	# leaves the old app's settings and every other record alone; Configure's own
	# name field is the whole-app relabel. A target that already exists is a
	# legitimate reassignment (the row joins that app), so it is not refused.
	my $new_app = &subs::unformat_name($c->param('app_name'));
	if (defined $c->param('app_name') && length $new_app && $new_app ne $app) {
		&subs::db_update('appointments', { app => $new_app, server_time => $server_time }, { uuid => $uuid });
		# a name nobody knows yet is a new app; give it its defaults at once so it
		# is listed and configurable rather than waiting for the next reader
		my $known = &subs::db_query('select 1 from settings where app = ? limit 1', $new_app)->hashes->[0];
		&subs::setting_initializer($new_app, $server_time) unless $known;
		$app = $new_app;
		$appt->{'app'} = $new_app;
		$c->param('app' => $new_app);
	}

	# The form names the controls it actually rendered. An absent control is
	# "unchanged", not "cleared"; a rendered blank is a deliberate clear. A
	# caller that sends no list keeps the safer old rule (only a non-blank value
	# may write).
	my %sent;
	if (defined $c->param('sent') && length $c->param('sent')) {
		$sent{$_} = 1 foreach grep { length } split /\s*,\s*/, $c->param('sent');
	}
	my $given = sub {
		my $k = shift;
		return $sent{$k} ? 1 : 0 if scalar keys %sent;
		my $v = $c->param($k);
		return (defined $v && length $v) ? 1 : 0;
	};

	my $data = {};
	# A time is millisecond digits; anything else would blank the row's own time.
	my $timestamp = $c->param('timestamp');
	$data->{'timestamp'} = $timestamp if $given->('timestamp') && defined $timestamp && $timestamp =~ /^-?\d{10,}$/;
	my $duration = &duration_read($c->param('duration'));
	if ($given->('duration') && defined $duration) {
		# start/record/stop durations are an accrual (negative); keep the sign
		# the row already carries instead of flipping the history on a save
		$duration = (abs $duration) * -1 if ($appt->{'duration'} // 0) < 0;
		$data->{'duration'} = $duration;
		# A closed session's stop is its start plus the length it carries, so a
		# length edited here has to move the stop with it. Leaving the stop at the
		# press time was how a hand-set duration and its stop came to disagree (and
		# the records audit then read the row as corrupt). Only a negative accrual
		# names a length; a positive duration is not a session span.
		if ($duration < 0 && defined $appt->{'stop_timestamp'} && $appt->{'stop_timestamp'} ne '') {
			my $start = defined $data->{'timestamp'} ? $data->{'timestamp'} : $appt->{'timestamp'};
			$data->{'stop_timestamp'} = (0 + $start) + abs($duration);
		}
	}
	$data->{'warranty'} = $c->param('warranty') if $given->('warranty');
	foreach my $k (qw/account project movement amount tax aux aux_description total manufacturer vendor unit quantity item state has_tax has_totes/) {
		next unless $given->($k);
		my $v = $c->param($k);
		$data->{$k} = defined $v ? $v : '';
	}
	# Notes are sealed at rest. A rendered empty clears the note; an absent note
	# never does, and a seal that fails leaves the old ciphertext alone.
	foreach my $k (qw/start_notes notes end_notes/) {
		next unless $given->($k);
		my $plain = $c->param($k) // '';
		if (length $plain) {
			my $sealed = &subs::note_encrypter(&subs::session_suds($c), $plain);
			next unless defined $sealed && length $sealed;
			$data->{$k} = $sealed;
		}
		else {
			$data->{$k} = '';
		}
	}
	# 'seen' is owned by the write path and the reminder sweep, so an edit must
	# not finalise a pending row. 'model' is JSON and belongs to
	# appointment_model_selector, not this scalar form. 'app_name' is not a
	# rename: a rename touches settings, models and child rows, and doing it
	# half-way here left later saves matching zero rows.

	my $sdata = {};
	foreach my $k ( keys %{$data} ) {
		my $old = defined $appt->{$k} ? $appt->{$k} : '';
		$sdata->{$k} = $data->{$k} if "$old" ne "$data->{$k}";
	}
	if (scalar keys %{$sdata}) {
		$sdata->{'server_time'} = $server_time;
		my $before = { %{$appt} };
		&subs::db_update('appointments', $sdata, { uuid => $uuid });
		&appointment_edit_ledger($c, $before, $sdata);
	}

	my $cv = &centre_view_grabber({ c => $c, app => $app, timestamp => ($sdata->{'timestamp'} // $appt->{'timestamp'}), cached => 'no' });
	&budget_runner($app);
	&padlock_time_extender($c);
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	$c->render(text => 'ok');
}

# Clone an app as a new app: its settings, models, options and categories, with
# fresh uuids. No history and no stock - copying either would duplicate physical
# levels and the mesh's own timeline. The new app gets its own identity uuid from
# setting_initializer, so it is a distinct app on every machine.
# POST /manager/clone_app
sub action_41568 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $new = &subs::unformat_name($c->param('new'));
	return $c->render(json => { ok => 0, error => 'name' }, status => 400)
		unless length $app && length $new && $new ne $app;
	my $taken = &subs::db_select('settings', undef, { app => $new, setting => 'uuid' })->hashes->[0]
		|| &subs::db_select('appointments', undef, { app => $new })->hashes->[0];
	return $c->render(json => { ok => 0, error => 'exists' }, status => 409) if $taken;
	my $now = &subs::rightNow();
	# defaults first, including the new app's own uuid/construct_uuid
	&subs::setting_initializer($new, $now);
	my %skip = map { $_ => 1 } qw/uuid construct_uuid scrollTop jopen dimensions s_scroll ci toggle/;
	my $rows = &subs::db_select('settings', undef, { app => $app })->hashes || [];
	foreach my $r ( @{$rows} ) {
		next if $skip{$r->{'setting'} || ''};
		my $dev = $r->{'device'} || &subs::device_setter();
		my $sub = defined $r->{'subsetting'} ? $r->{'subsetting'} : '';
		my $value = $r->{'value'};
		# a setting that named the app names the clone
		$value = $new if defined $value && $value eq $app;
		$value = &subs::format_name($new) if ($r->{'setting'} || '') eq 'notification_text' && ($value // '') eq &subs::format_name($app);
		my $existing = &subs::db_query('select uuid from settings where app = ? and setting = ? and coalesce(subsetting, \'\') = ? and device = ? limit 1', $new, $r->{'setting'}, $sub, $dev)->hashes->[0];
		if ($existing) {
			&subs::db_update('settings', { value => $value, timestamp => $r->{'timestamp'}, server_time => $now }, { uuid => $existing->{'uuid'} });
		}
		else {
			my %s = %{$r};
			delete $s{'id'};
			$s{'uuid'} = &subs::random_string_creator(40);
			$s{'app'} = $new;
			$s{'value'} = $value;
			$s{'device'} = $dev;
			$s{'server_time'} = $now;
			&subs::db_insert('settings', \%s);
		}
	}
	foreach my $t ( qw/model option option_category subcategory/ ) {
		my $items = &subs::db_select($t, undef, { app => $app })->hashes || [];
		foreach my $r ( @{$items} ) {
			my %n = %{$r};
			$n{'uuid'} = &subs::random_string_creator(40);
			$n{'app'} = $new;
			$n{'server_time'} = $now;
			$n{'name'} = $new if ($n{'name'} // '') eq $app;
			&subs::db_insert($t, \%n);
		}
	}
	$c->render(json => { ok => 1, app => $new });
}

# Delete an app: every appointment through the ordinary delete (files, invoice
# payments, continuation rows, warehouse rows, one tombstone each), then the
# app-scoped settings/models/options/continent rows, each tombstoned so peers
# drop their copies instead of pushing them back. Core house apps are refused.
# POST /manager/delete_whole_app
sub action_41622 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	return $c->render(json => { ok => 0, error => 'app' }, status => 400) unless length $app;
	my %reserved = map { $_ => 1 } qw/me misc config camera warehouse mail app sale purchase store terminal security ime people notes handbook studio music clock alarm padlock folders market budget crypto/;
	return $c->render(json => { ok => 0, error => 'reserved' }, status => 403) if $reserved{$app};
	# Deleting an app is destructive and reaches every machine, so it is only done
	# from Configure and only when the person has typed the app's own name.
	return $c->render(json => { ok => 0, error => 'confirm' }, status => 400)
		unless (($c->param('confirm_name') // '') eq $app);
	my $server_time = $c->param('server_time') || &subs::rightNow();
	my $appts = &subs::db_select('appointments', undef, { app => $app })->hashes || [];
	foreach my $a ( @{$appts} ) {
		&delete_app($app, $a->{'uuid'}, $a->{'server_time'} || $server_time, 'whole app delete', 1);
	}
	my $tombstoned = 0;
	foreach my $t ( qw/settings model option option_category subcategory continent cache mailbox tickets websites websockets/ ) {
		my $rows = eval { &subs::db_select($t, undef, { app => $app })->hashes } || [];
		foreach my $r ( @{$rows} ) {
			next unless defined $r->{'uuid'} && length $r->{'uuid'};
			&deletion_registration({ table => $t, app => $app, uuid => $r->{'uuid'}, scope => 'single', server_time => $r->{'server_time'} || $server_time });
			$tombstoned++;
		}
		&subs::db_query('delete from ' . $t . ' where app = ?', $app);
	}
	# Stock in rows name the item rather than an appointment; take them too.
	my $wh = &subs::db_query('select uuid, server_time from warehouse where item = ? or data like ?', $app, '%"source":"' . $app . '"%')->hashes || [];
	foreach my $w ( @{$wh} ) {
		next unless defined $w->{'uuid'} && length $w->{'uuid'};
		&deletion_registration({ table => 'warehouse', app => $app, uuid => $w->{'uuid'}, scope => 'single', server_time => $w->{'server_time'} || $server_time });
		$tombstoned++;
	}
	&subs::db_query('delete from warehouse where item = ? or data like ?', $app, '%"source":"' . $app . '"%');
	&Websocket::send('server', { console => &Websocket::console_command('closeButton', &subs::html_name($app)), timestamp => &subs::rightNow() });
	&subs::log_writer('deletion app ' . $app);
	$c->render(json => { ok => 1, app => $app, appointments => scalar @{$appts}, tombstones => $tombstoned });
}

# GET /manager/clothesline
sub action_41731 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $project = &subs::unformat_name($c->param('project'));
	my $account = &subs::unformat_name($c->param('account'));
	my $time_plinkos = &clothesline_calculator($app);
	my $cl = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'clothesline' })} || {};
	my $html = $c->render_to_string(template => 'apps/clothesline', app => $app, cl => $cl , time_plinkos => $time_plinkos );
	&subs::hang_to_dry();
	$c->render(json => { html => $html});
}

# POST /manager/clothesline
sub action_41744 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = $c->param('app');
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	if ($c->param('is_json')) {
		$value = eval { return decode_json $value } || [];
	}
	my $cl = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'clothesline' })} || {};
	$cl->{$setting} = $value;
	my $jcl = encode_json $cl;
	&subs::setting_setter({ app => $app, setting => 'clothesline', value => $jcl });
	&subs::hang_to_dry();
	$c->render(json => $cl);
}

# GET /manager/volume_control
sub action_41801 {
	my $c = shift;
	my $return_volume = '[]';
	my $stream = $c->param('stream');
	my $volume = $c->param('volume');
	my $max = $c->param('max');
	my $card = $c->param('device');
	my $remote_machines = &subs::db_select('remote_machines', undef, { connection => 'active' })->hashes;
	my ($json_vol,$md);

	if ($card && lc $card ne 'local' && grep { $_->{'uuid'} eq $card } @{$remote_machines}) {
		$c->param('device', 'local');
		$c->param('remote_uuid', $card);
		my $jdata = &remote_relay_request($c);
		my $data = eval { return decode_json $jdata } || {};
		$json_vol = $data->{'volumes'};
		$md = eval { return decode_json $data->{'md'} } || {};
	}
	else {
		my $bridge_volume;
		if (defined $stream && length $stream && defined $volume && length $volume) {
			if ($device eq 'mobile') {
				$stream = lc $stream;
				&subs::device_call('audio.volume', { stream => $stream, volume => $volume });
			}
			else {
				`amixer set $stream $volume%`;
			}
		}
		if ($device eq 'mobile') {
			$bridge_volume = &subs::device_call('audio.volume');
		}
		else {
			foreach my $control ( qw/Master Capture/ ) {
				my $amixer = `amixer get $control`;
				my @lines = split /\n/, $amixer;

				my $volume;
				foreach my $l ( @lines ) {
					if ($l =~ /Left:/gi) {
						my @p = split ' ', $l;
						my $p = $p[-2];
						$p =~ s/[^0-9]//gi;
						$volume = $p;
					}
				}
				push @{$json_vol}, { stream => $control, volume => $volume, max_volume => 100 };
			}

		}
		if ($device eq 'mobile') {
			$json_vol = ($bridge_volume && ref $bridge_volume->{'streams'} eq 'ARRAY')
				? $bridge_volume->{'streams'}
				: decode_json $return_volume;
		}

		foreach my $j ( @{$json_vol} ) {
			$j->{'stream'} = &subs::format_name($j->{'stream'});
		}
		my $ws_watcher = &subs::home('~/.president/ws_watcher');
		$md = eval { return decode_json read_file($ws_watcher) } || {};
	}

	$c->render( json => { volumes => $json_vol, remote_machines => $remote_machines, md => $md });

}

# POST /manager/clothesline
sub action_41867 {
	my $c = shift;
	my $app = $c->param('app');
	my $setting = $c->param('setting');
	my $value = $c->param('value');
	my $timestamp = $c->param('timestamp');
	my $cl = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'clothesline' })} || {};

	$c->render(json => $cl);
}

# POST /manager/calculate
sub action_41877 {
	my $c = shift;
	my $formula = $c->param('formula');
	if ($formula =~ /=/gi) {
		my @formulas = split '=', $formula;
		$formula = $formulas[-1];
	}
	my ($evaluation,$uom,$format);
	($formula,$evaluation,$uom,$format) = &formula_calculator($formula);

	$c->render(json => { format => $format, formula => $formula, evaluation => $evaluation, uom => $uom });
}

# The keyboard's conversion row: a quantity typed as "$32.31", "5jpy" or
# "32.33L" names its unit, and every other unit of the same kind is offered
# beside it. The old calculator's formulas are the non-currency source; the
# live rate snapshot is the currency source.
# GET /manager/keyboard/convert
sub action_41893 {
	my $c = shift;
	my $value = $c->param('value');
	$value =~ s/[^0-9.\-]//g if defined $value;
	return $c->render(json => { ok => 0 }) unless defined $value && $value =~ /^-?(?:\d+(?:\.\d+)?|\.\d+)$/;
	$c->render(json => &measure_conversion_rows($c->param('unit'), 0 + $value));
}

# The Android input method's page. It is the manager's own soft keyboard, not a
# copy: the same template the dock uses (so the layouts, the symbol page, the
# calculator and the field-aware rows are the same code), the same stylesheet and
# the same soft_keyboard.js. The service's WebView loads this over loopback and
# adds `window.JawnIme` before the page parses; soft_keyboard.js then commits
# keys through that bridge instead of into a DOM field. Serving it here keeps the
# units, the live rates and the labels identical to the dock's.
# GET /manager/keyboard/ime
sub action_41907 {
	my $c = shift;
	my ($manager_bg) = &subs::active_manager_background();
	$c->render(
		template => 'ime',
		layout => undef,
		body_class => (&subs::theme_is_dark() ? 'dark_theme' : ''),
		manager_bg => $manager_bg,
	);
}

# GET /manager/credentials/status
sub action_41969 {
	my $c = shift;
	my $gate = &credential_gate($c);
	if (length $gate) {
		return $c->render(json => { ok => 0, locked => ($gate eq 'locked' ? 1 : 0), error => $gate, matches => [] });
	}
	my $app = lc($c->param('app') || '');
	my $origin = lc($c->param('origin') || '');
	my $hints = &credential_hints_clean($c->param('hints'));
	my %want = map { $_ => 1 } @$hints;
	# With neither an app nor a site there is nothing to scope a match to; an
	# empty answer is safer than the whole vault.
	if (!length $app && !length $origin) {
		return $c->render(json => { ok => 1, locked => 0, matches => [] });
	}
	my $rows = &subs::db_query('select uuid,app,origin,kind,label,hints,has_user,has_password,server_time from credentials order by cast(server_time as integer) desc')->hashes || [];
	my @matches;
	foreach my $r ( @$rows ) {
		my $row_origin = lc($r->{'origin'} || '');
		my $row_app = lc($r->{'app'} || '');
		# a site row is only ever offered to that site
		next if length $row_origin && ($origin eq '' || $row_origin ne $origin);
		# an app row is only ever offered to that app
		next if !length $row_origin && length $row_app && ($app eq '' || $row_app ne $app);
		my $score = 0;
		$score += 6 if length $row_origin;
		$score += 4 if length $row_app && $row_app eq $app;
		my $entry_hints = &credential_hints_clean($r->{'hints'});
		my $hits = 0;
		foreach my $h ( @$entry_hints ) { $hits++ if $want{$h}; }
		# A row that names its fields is only offered to a field it names: a
		# password entry must not surface for a notes box just because the app is
		# the same. Rows with no hints still answer the app/site as a whole.
		next if scalar(@$hints) && scalar(@$entry_hints) && !$hits;
		$score += $hits * 3;
		push @matches, {
			uuid => $r->{'uuid'},
			label => ($r->{'label'} || $row_origin || $row_app || 'Saved'),
			app => $r->{'app'},
			origin => $r->{'origin'},
			kind => $r->{'kind'},
			hints => $entry_hints,
			has_user => ($r->{'has_user'} ? 1 : 0),
			has_password => ($r->{'has_password'} ? 1 : 0),
			score => $score,
		};
	}
	@matches = sort { $b->{'score'} <=> $a->{'score'} } @matches;
	$c->res->headers->cache_control('no-store, max-age=0');
	$c->render(json => { ok => 1, locked => 0, matches => \@matches });
}

# POST /manager/credentials/save
sub action_42020 {
	my $c = shift;
	my $gate = &credential_gate($c);
	if (length $gate) {
		return $c->render(json => { ok => 0, locked => ($gate eq 'locked' ? 1 : 0), error => $gate });
	}
	my $suds = &subs::suds_grabber();
	return $c->render(json => { ok => 0, error => 'no-vault' }) unless $suds;
	my %fields;
	foreach my $key ( qw/username password value/ ) {
		my $v = $c->param($key);
		$fields{$key} = $v if defined $v && length $v;
	}
	my $raw_fields = $c->param('fields');
	my $more = (defined $raw_fields && length $raw_fields) ? eval { decode_json $raw_fields } : undef;
	if (ref $more eq 'HASH') {
		foreach my $k ( keys %$more ) {
			next unless defined $more->{$k} && length $more->{$k};
			next if $k =~ /[^A-Za-z0-9_.:-]/;
			$fields{'fields'}->{$k} = $more->{$k};
		}
	}
	return $c->render(json => { ok => 0, error => 'empty' }) unless scalar keys %fields;
	my $app = substr(lc($c->param('app') || ''), 0, 250);
	my $origin = substr(lc($c->param('origin') || ''), 0, 450);
	$origin =~ s{^https?://}{};
	$origin =~ s{/.*$}{};
	my $kind = $c->param('kind') || (exists $fields{'password'} ? 'password' : 'field');
	$kind = 'login' if exists $fields{'username'} && exists $fields{'password'};
	$kind = 'field' unless $kind =~ /^(?:login|password|field)$/;
	if (($kind eq 'login' || $kind eq 'password') && !length $origin && $credential_browser_app{$app}) {
		return $c->render(json => { ok => 0, error => 'site-required' });
	}
	my $payload = &subs::note_encrypter($suds, encode_json \%fields);
	return $c->render(json => { ok => 0, error => 'seal' }) unless $payload;
	my $label = substr($c->param('label') || '', 0, 250);
	$label = ($origin || $app || 'Saved') unless length $label;
	my $hints = &credential_hints_clean($c->param('hints'));
	my $uuid = $c->param('uuid') || '';
	$uuid = '' unless $uuid =~ /^[A-Za-z0-9]{8,64}$/;
	my $existing = $uuid ? &subs::db_select('credentials', undef, { uuid => $uuid })->hashes->[0] : undef;
	my %row = (
		app => $app,
		origin => $origin,
		kind => $kind,
		label => $label,
		hints => encode_json($hints),
		payload => $payload,
		has_user => (exists $fields{'username'} ? 1 : 0),
		has_password => (exists $fields{'password'} ? 1 : 0),
		device => &subs::device_setter(),
		timestamp => &subs::rightNow(),
		server_time => &subs::rightNow(),
	);
	if ($existing) {
		&subs::db_update('credentials', \%row, { uuid => $uuid });
	}
	else {
		$uuid = &subs::random_string_creator(40) unless length $uuid;
		$row{'uuid'} = $uuid;
		&subs::db_insert('credentials', \%row);
	}
	$c->res->headers->cache_control('no-store, max-age=0');
	$c->render(json => { ok => 1, uuid => $uuid });
}

# POST /manager/credentials/fill
sub action_42085 {
	my $c = shift;
	my $gate = &credential_gate($c);
	if (length $gate) {
		return $c->render(json => { ok => 0, locked => ($gate eq 'locked' ? 1 : 0), error => $gate });
	}
	my $uuid = $c->param('uuid') || '';
	my $row = $uuid ? &subs::db_select('credentials', undef, { uuid => $uuid })->hashes->[0] : undef;
	return $c->render(json => { ok => 0, error => 'missing' }) unless $row;
	my $suds = &subs::suds_grabber();
	return $c->render(json => { ok => 0, error => 'no-vault' }) unless $suds;
	my $fields = &credential_payload_read($suds, $row);
	return $c->render(json => { ok => 0, error => 'unseal' }) unless scalar keys %$fields;
	$c->res->headers->cache_control('no-store, max-age=0');
	$c->render(json => { ok => 1, uuid => $uuid, label => $row->{'label'}, kind => $row->{'kind'}, fields => $fields });
}

# POST /manager/credentials/forget
sub action_42101 {
	my $c = shift;
	my $gate = &credential_gate($c);
	if (length $gate) {
		return $c->render(json => { ok => 0, locked => ($gate eq 'locked' ? 1 : 0), error => $gate });
	}
	my $uuid = $c->param('uuid') || '';
	my $row = $uuid ? &subs::db_select('credentials', undef, { uuid => $uuid })->hashes->[0] : undef;
	return $c->render(json => { ok => 0, error => 'missing' }) unless $row;
	&subs::tombstone_writer({ table => 'credentials', app => ($row->{'app'} || ''), uuid => $uuid, scope => 'single' });
	&subs::db_delete('credentials', { uuid => $uuid });
	$c->render(json => { ok => 1 });
}

# POST /manager/keyboard
sub action_42427 {
	my $c = shift;
	my $toggle = $c->param('toggle');
	my $remote_uuid = $c->param('remote_uuid');
	my $remote_control = &subs::setting_grabber({ app => 'me', setting => $toggle . '_machine' });
	# The picker's choice rides in this request and is the authority for this
	# render: the setting POST that saves it can land after us, and an explicit
	# empty pick (Me) must not fall back to the stored machine. Do not relay the
	# panel to the peer to fill its view: the panel already renders the local
	# pick, while a relayed copy shows that machine's own view ("ME!") and can
	# stall the render while it waits on an unreachable peer.
	my $picked = defined $remote_uuid ? $remote_uuid : $remote_control;
	my $kb = &keyboard_maker($c, $picked);

	$c->render(json => { keyboard => $kb });
}

1;
