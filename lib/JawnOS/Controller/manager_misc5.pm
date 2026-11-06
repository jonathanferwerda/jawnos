package Manager;

# manager_misc5: route actions moved out of Manager.pl, one sub per route so a
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

# GET /manager/download_file
sub action_14716 {
	my $c = shift;
	my $file = $c->param('file');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid');
	my $timestamp = $c->param('timestamp');
	my $server_time = $c->param('server_time');
	# A file that lives on the archive machine is downloaded through it: the
	# request here has this machine's session, and the archive machine is asked
	# with the peer cookie and signature the archive rail already uses.
	if ($c->param('remote_uuid') && ($c->param('remoted') || '') ne 'yes') {
		my $agent = &subs::remote_agent_for($c->param('remote_uuid'));
		if ($agent->{'error'} || !$agent->{'manager'}) {
			$c->render(text => 'Not Found');
			return;
		}
		my $url = Mojo::URL->new($agent->{'manager'} . '/manager/download_file');
		my $params = $c->req->query_params->to_hash;
		delete @{$params}{qw/remote_uuid/};
		$params->{'remoted'} = 'yes';
		$url->query($params);
		my $tx = eval { $agent->{'ua'}->get($url) };
		my $res = $tx ? $tx->res : undef;
		if ($res && !$res->error && $res->code == 200) {
			my $disposition = $res->headers->header('Content-Disposition') || '';
			my $type = $res->headers->content_type || 'application/octet-stream';
			$c->res->headers->content_type($type);
			$c->res->headers->header('Content-Disposition' => $disposition) if length $disposition;
			$c->render(data => $res->body);
			return;
		}
		$c->render(text => 'Not Found');
		return;
	}
	my ($db,$database,$sql) = &subs::database_grabber();
	my $appt = &subs::db_query('select * from appointments where app = ? and uuid = ?', $app, $uuid)->hashes->[0];
	my $encryption_standard = $appt->{'encryption_standard'};
	my $saved_file = eval { return decode_json $appt->{'file'} } || [{}];
	@{$saved_file} = grep { $_->{'f'} eq $file } @{$saved_file};

	my ($data,$filename);
	if (-e $file) {
		if ($file =~ /\.enc$/gi) {
			my $suds = &subs::session_suds($c);
			my $passwords = &subs::db_query('select * from security where level != ? and level != ? order by server_time DESC', 'padlock', 'door');
			my $pwords = $passwords->hashes;

			foreach my $p ( @{$pwords} ) {
				my $secret = &subs::decrypter($suds, $p->{'credential'});
				my $process_data = &subs::openssl_file_read($encryption_standard, $secret, $file, 0, 1);
				my $type_from_data = &subs::plaintext_verdict($process_data);
				if (defined $type_from_data) {
					$data = $process_data;

					my @file = split '/', $file;
					$filename = $file[-1];
					$filename =~ s/\.enc//gi;
					$filename = $saved_file->[0]->{'of'} if $saved_file->[0]->{'of'};
					last;
				}
			}
		}
		else {
			$data = read_file($file);
			my @file = split '/', $file;
			$filename = $file[-1];
			$filename = $saved_file->[0]->{'of'} if $saved_file->[0]->{'of'};
		}
		$c->render_file(data => $data, filename => $filename);
	}
	else {
		$c->render(text => 'Not Found');
	}
}

# POST /manager/upload_file
sub action_14764 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my @uploads = @{$c->req->uploads};
	my $timestamp = $c->param('timestamp') - 1;
	my $duration = $c->param('duration');
	my $app = $c->param('app');
	my $uuid = $c->param('uuid') || &subs::random_string_creator(22);
	my $seen_appts = [];
	my $notes;
	my @uploaded_files;
	my @uuids;
	if ($c->param('uuid')) {
		$seen_appts = &subs::db_select('appointments', undef, { uuid => $uuid })->hashes;
		if (scalar @{$seen_appts} > 0) {
			my $appt = $seen_appts->[0];
			my $of = eval { return decode_json $appt->{'file'} } || [];
			push @uploaded_files, @{$of};
			$app = $appt->{'app'};
			$notes = &subs::note_decrypter(&subs::session_suds($c), $appt->{'notes'},$appt->{'server_time'}) . '<br>';
			$timestamp = $appt->{'timestamp'};
		}
	}
	my $returner = { uuid => $uuid, app => $app, timestamp => $timestamp, urls => [] };

	my $upload_type;
	my $linux_file;
	my $resolution = &subs::setting_grabber({ app => 'misc', setting => 'photo_size' } ) || '1920x1080';
	foreach my $u ( @uploads ) {
		my $is_enc = 0;
		my $server_time = &subs::rightNow();
		$timestamp++;
		my $filen = &subs::unformat_name($u->filename);
		my @f = split /\./, $filen;
		if (lc $f[-1] eq 'enc') {
			$is_enc = 1;
			pop @f;
		}
		my $ext = pop @f;
		$filen = join '.', @f;
		my $fn = $filen . '_' . $timestamp . '.' . $ext;

		my $upload = {
			type => $u->headers->content_type,
			path => $u->asset->path,
			filename => $fn,
			size => $u->size,
		};
		$app = $upload->{'filename'} unless $c->param('app');
		$app = &subs::unformat_name($app);
		my $init = &subs::setting_initializer($app,$timestamp);
		$app = $init->{'app'};
		my $app_path = &subs::path_name($app);

		my ($folder,$location,$thumb);

		if ($upload->{'type'} =~ /audio/gi) {
			$upload_type = 'audio';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'rec_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
		}
		elsif ($upload->{'type'} =~ /video/gi || lc $ext eq 'webm' || lc $ext eq 'avi' || lc $ext eq 'mp4' || lc $ext eq 'mov' || lc $ext eq 'mkv') {
			$upload_type = 'video';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'video_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
			$thumb = $location . '/.thumbs';

		}
		elsif ($upload->{'type'} =~ /image/gi || lc($ext) =~ /^(?:jpg|jpeg|jpe|png|webp|heic|heif|bmp|tif|tiff|xcf|gif)$/) {
			$upload_type = 'image';
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'photo_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
			$thumb = $location . '/.thumbs';
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

		else {
			$folder = &subs::setting_grabber( { app => 'misc', setting => 'download_location', device => $device } );
			$location = &subs::home($folder) . '/' . $app_path;
		}
		`mkdir -p $location` unless -e $location;
		my $filename = $location . '/' . $upload->{'filename'};
		my $new_uuid = &subs::random_string_creator(13);
		if ($is_enc == 1) {
			$filename = $filename . '.enc';
			push @uuids, $new_uuid;
		}
		$u->move_to($filename);
		my $ocr;
		if ($upload_type eq 'image') {
			unless (lc $resolution eq 'raw') {
				my ($w, $h) = &subs::image_resolution_parts($resolution);
				my $resized = ($w && $h) ? &subs::image_bridge_resize($filename, $w, $h) : undef;
				unless ($resized) {
					{
						local $SIG{'__WARN__'} = sub { };
						system('magick', $filename, '-auto-orient', '-strip', '-resize', $resolution, $filename);
						system('convert', $filename, '-auto-orient', '-strip', '-resize', $resolution, $filename) if $? != 0;
					}
				}
			}
			$ocr = &ocr_reader($c,$filename);
		}
		$linux_file .= `file $filename` . "\n";
		if ($upload->{'filename'} =~ /avi$|mkv$/gi) {
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

		my $u_data = { server_time => &subs::rightNow(), ocr => $ocr, f => $filename, uuid => $new_uuid, type => $upload_type };

		if ($thumb) {
			`mkdir -p $thumb` unless -e $thumb;

			$u_data->{'thumb'} = $thumb . '/' . $upload->{'filename'};
			$u_data = &thumbnail_creator($u_data);
		}
		push @uploaded_files, $u_data;
	}
	my $jfile = encode_json \@uploaded_files;

	if (@{$seen_appts} > 0) {
		&subs::db_update('appointments', {
			timestamp => $timestamp,
			notes => &subs::note_encrypter(&subs::session_suds($c),$notes . $linux_file),
			file => $jfile,
			uuid => $uuid,
			duration => $duration || '1000',
			encryption_standard => undef,
		},
		{
			uuid => $uuid,
			app => $app
		});
		&Websocket::send($app, { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	}
	else {
		my $write = {
			timestamp => $timestamp,
			app => &subs::unformat_name($app),
			notes => &subs::note_encrypter(&subs::session_suds($c),$notes . $linux_file),
			type => $upload_type || $c->param('type') || 'upload',
			file => $jfile,
			uuid => $uuid,
			duration => $duration || '1000',
			browser_tab_id => $c->param('browser_tab_id')
		};

		# a capture taken in the Camera app itself, not on an appointment, is
		# unclaimed media: it waits a week on the Camera app to be claimed
		if (&subs::unformat_name($app) eq 'camera') {
			$write->{'source'} = 'unclaimed';
			$write->{'warranty'} = &subs::rightNow() + (7 * 24 * 60 * 60 * 1000);
		}

		&appointment_writer($c,$write);
	}
	&subs::file_encrypter({ app => &subs::unformat_name($app) });
	# The encrypter renames every file it seals, so the addresses handed back here
	# are built from the row it wrote, not from the names given to it above: a
	# caller (the magazine editor) drops the bytes and needs the URL that works
	# now, not the one that existed for a moment.
	my $written_row = &subs::db_query('select file from appointments where app=? and uuid=? limit 1', &subs::unformat_name($app), $uuid)->hashes->[0];
	my $written_files = ($written_row && $written_row->{'file'}) ? (eval { return decode_json $written_row->{'file'} } || []) : [];
	foreach my $written ( @{$written_files} ) {
		next unless $written->{'f'};
		my $target = $c->url_for('/manager/download_file');
		$target->query(app => &subs::unformat_name($app), uuid => $uuid, timestamp => $timestamp, file => $written->{'f'});
		push @{$returner->{'urls'}}, $target->path_query;
	}

	$returner->{'cv'} = &centre_view_grabber({ c => $c, app => &subs::unformat_name($app), timestamp => $timestamp, cached => 'no' });
	# the files just written, so a caller (the chat's paperclip) can carry them
	# on the message without asking again
	$returner->{'file'} = $jfile;


	$c->render(json => $returner);
}

# A thin test bed for the multimodal chat layer: hand it a model, a prompt and some
# media - uploads named 'media', or base64 / data: values in image / audio / video /
# files - and it hands back the reply as parts. Nothing routes through it; it is
# here to poke ai_chat while the media features grow.
# ANY /manager/ai_chat
sub action_15230 {
	my $c = shift;
	my $model = $c->param('model') || &subs::setting_grabber({ app => 'mail', setting => 'chatbot_model' });
	unless ($model) { $c->render(json => { error => 'no model given, and no default chatbot model is set' }); return; }
	my $prompt = $c->param('prompt') || 'Describe what you are given.';
	my $system = $c->param('system');
	my $msg = { role => 'user', content => $prompt };
	foreach my $key ( qw/images image audio video files/ ) {
		my $v = $c->param($key);
		next unless defined $v && length $v;
		$msg->{$key} = $v;
	}
	foreach my $u ( @{ $c->req->uploads('media') } ) {
		my $ct = ($u->headers->content_type || 'application/octet-stream');
		my $data = encode_base64($u->slurp, '');
		my $key = $ct =~ m{^image/} ? 'images' : $ct =~ m{^audio/} ? 'audio' : $ct =~ m{^video/} ? 'video' : 'files';
		push @{ $msg->{$key} }, { data => $data, mime => $ct };
	}
	my @msgs = ( ($system ? { role => 'system', content => $system } : ()), $msg );
	# A vision or chat model can take a minute; the uploads are already read
	# above, so only the model call runs in the child.
	&subs::render_in_subprocess($c, sub {
		my ($parts, $err) = &subs::ai_chat_parts($model, \@msgs);
		return { parts => $parts, err => $err, used => $subs::ai_last_model };
	}, sub {
		my ($c, $r) = @_;
		$r ||= {};
		if ($r->{'err'}) { $c->render(json => { model => $model, error => $r->{'err'} }); return; }
		$c->render(json => { model => $model, model_used => $r->{'used'}, parts => $r->{'parts'} });
	});
}

# POST /manager/continent/record
sub action_15390 {
	my $c = shift;
	my $returner = &continent_record($c);
	$c->render(json => $returner );
}

# The manual navigation button asks a device that has a GPS for its fix. On a
# computer with none of its own, that is the phone or the deck on the same
# physical LAN; the answer is written here as this machine's place, with no
# home-plate automation (the phone's own navigation does that). When nothing
# answers, `local` says to fall back to the browser's own geolocation.
# POST /manager/navigation/nearby
sub action_15400 {
	my $c = shift;
	my $timestamp = $c->param('timestamp') || &subs::rightNow();
	return $c->render(json => { local => 1 }) if &subs::device_setter() eq 'mobile';
	my $fix = &subs::nearby_position({ timestamp => $timestamp });
	unless ($fix->{'latitude'}) {
		return $c->render(json => { local => 1 });
	}
	my $now = &subs::rightNow();
	my $signatorial = &subs::signatorial_designer();
	my $fix_time = $fix->{'timestamp'} || $timestamp;
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'app', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $now);
	my $returner = {
		timestamp => $fix_time,
		server_time => $now,
		uuid => &subs::random_string_creator(25),
		type => 'navigation',
		app => 'me',
		warranty => $warranty,
		signatorial => $signatorial,
		latitude => $fix->{'latitude'},
		longitude => $fix->{'longitude'},
		accuracy => sprintf("%.2F", ($fix->{'accuracy'} || 0)),
	};
	&subs::db_insert('continent', $returner);
	my $treturner = clone $returner;
	$treturner->{'type'} = 'temporary';
	$treturner->{'app'} = '__president';
	$treturner->{'uuid'} = &subs::random_string_creator(31);
	$treturner->{'warranty'} = &subs::navigation_hold_warranty({ timestamp => $fix_time, server_time => $now });
	&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
	&subs::db_insert('continent', $treturner);
	&subs::cache_delete({ app => 'travel', context => 'navigation_information', subcontext => $signatorial });
	my $nav = &subs::navigation_information({ signatorial => $signatorial, cache => 'no' });
	my $site_type = $nav->{$signatorial}->{'site_type'};
	if ($site_type && $gb::site_types->{$site_type}) {
		$returner->{'site_type'} = $site_type;
		$returner->{'site_rating'} = $nav->{$signatorial}->{'site_rating'};
		$returner->{'site_source'} = $nav->{$signatorial}->{'site_source'};
		$returner->{'site_icon'} = &subs::icon_for($gb::site_types->{$site_type}->{'icon'});
	}
	$returner->{'source'} = $fix->{'source'} || 'peer';
	&Websocket::send('tab', { console => &Websocket::console_command('startMenuRefresh')});
	$c->render(json => $returner);
}

# A peer on this LAN asks this handheld where it is, for its manual navigation
# button. The route is on the bare signed rail (a peer has no session): the
# caller must be in the roster with a pinned key AND its source must be on one
# of this machine's physical subnets. It only reads - the asking machine writes
# the place; this one's own navigation keeps its cadence.
# GET /manager/navigation/position
sub action_15450 {
	my $c = shift;
	my $signatorial = $c->param('signatorial') || '';
	my $rm = ($signatorial && &subs::db_select('remote_machines', undef, { signatorial => $signatorial })->hashes->[0]);
	unless ($rm && &subs::peer_verify($c, $rm)) { $c->rendered(403); return; }
	my $ip = $c->tx->remote_address || '';
	my @nics = @{ &subs::lan_physical_network() };
	my $same = grep { &subs::same_net_test($_->{'ip'}, $ip) eq 'yes' } @nics;
	unless ($same) { $c->rendered(403); return; }
	$c->render(json => &subs::local_position());
}

# POST /manager/continent/record_anyway
sub action_15618 {
	my $c = shift;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app = &subs::unformat_name($c->param('app'));
	my $timestamp = $c->param('timestamp');
	my $server_time = &subs::rightNow();

	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		my $watch = &subs::device_lister($timestamp,'teletype') || {};
		my $signatorial = &subs::signatorial_designer();
		my ($uuid,$pre_uuid);
		if ($c->param('uuid')) {
			$pre_uuid = $c->param('uuid');
			$uuid = $c->param('uuid') . '-' . &subs::random_string_creator(8);
		}
		else {
			$uuid = &subs::random_string_creator(25);
			$pre_uuid = $uuid;
		}
		my $warranty => $c->param('warranty') || &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }),$server_time);
		my $purpose = $c->param('purpose') || 'home_plate';
		my $publishable_place = ($purpose eq 'home_plate'
			|| &subs::navigation_gps_present()
			|| ($purpose eq 'navigation' && &subs::device_setter() eq 'mobile')) ? 1 : 0;
		# the same one-device rule as the ordinary record route: a fix filed
		# "anyway" is still movement, and must not be counted twice
		my $movement_here = 1;
		if ($purpose eq 'app' && $c->param('uuid')) {
			my $recorder = &subs::movement_recorder({ app => $app, appt => $pre_uuid, signatorial => $signatorial, timestamp => $timestamp });
			$movement_here = 0 if length $recorder && $recorder ne $signatorial;
		}

		my $returner = {
			timestamp => $timestamp,
			server_time => $server_time,
			uuid => $uuid,
			type => $purpose,
			app => $app,
			warranty => $warranty,
			signatorial => $signatorial
		};

		my $scope = $c->param('scope');
		$returner = &subs::embedded_location_grabber($returner);
		# The deck answers /my_position from its own GPS. The home-plate fallback
		# below is not a fix, so it gets no provider and cannot move an appointment.
		my $fix_provider = $returner->{'latitude'} ? 'gps' : '';

		unless ($returner->{'latitude'}) {
			# navigation (like an appointment) is a place the person is standing in;
			# the home plate is where their machine lives, so it is never the answer
			if ($purpose ne 'app' && $purpose ne 'navigation') {
				my $home_plate = &subs::setting_grabber({ 'app' => 'me', setting => 'home_plate' });
				if (my $hp = eval { return decode_json $home_plate }) {

					foreach my $k ( keys %{$hp} ) {
						next if grep { $k eq $_ } qw/altitude speed pathname hostname user_agent protocol/;
						$returner->{$k} = $hp->{$k} unless $returner->{$k};
					}
					&subs::db_insert('continent', $returner);
				}
			}
		}
		else {
			&subs::db_insert('continent', $returner) if $movement_here;
			if ($returner->{'accuracy'} < 200 && $publishable_place) {
				my $treturner = clone $returner;
				$treturner->{'type'} = 'temporary';
				$treturner->{'app'} = '__president';
				$treturner->{'uuid'} = &subs::random_string_creator(31);
				$treturner->{'warranty'} = &subs::navigation_hold_warranty({ timestamp => $timestamp, server_time => $server_time });
				&subs::db_delete('continent', { type => 'temporary', signatorial => $signatorial });
				&subs::db_insert('continent', $treturner);
			}
		}

		if ($purpose eq 'proxy_load' && $scope) {
			&Websocket::send('server', { console => &Websocket::console_command('listProxy', $timestamp, $uuid)});
		}
		elsif ($purpose eq 'proxy_set' && $scope) {
			&Websocket::send('server', { console => &Websocket::console_command('setProxy', $timestamp, $uuid)});
		}
		elsif ($purpose eq 'travel_viewer' && $scope) {
			&Websocket::send('server', { console => &Websocket::console_command('travelViewer', $timestamp, $uuid)});
		}
		elsif ($purpose eq 'home_plate') {
			my $json = encode_json $returner;
			&subs::setting_setter({ app => 'me', setting => 'home_plate', value => $json });
		}

		&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $pre_uuid)});

		&subs::navigation_automation($returner, $fix_provider) if $returner->{'latitude'};
	}, { name => 'continent record anyway' });
	$c->render('text' => 'ok');
}

# POST /manager/continent/delete
sub action_15715 {
	my $c = shift;
	my $uuid = $c->param('uuid');
	my $server_time = $c->param('server_time');
	&subs::db_delete('continent', { uuid => $uuid });
	&deletion_registration({ table => 'continent', uuid => $uuid, server_time => $server_time });
	$c->render(json => { uuid => $uuid });
}

# POST /manager/reset
sub action_15836 {
	my $c = shift;
	unless (&peer_action_gate($c, &subs::peer_movement_action($c->param('type')))) {
		return $c->rendered(403);
	}
	my $peer = &peer_row_for_request($c);
	if ($peer && !&subs::peer_rate_ok($peer, 'action')) {
		return $c->rendered(429);
	}
	my $started = &subs::rightNow();
	my $content = &manager_reset($c);
	# A press is a single-page action, so its own time is the feedback time. One
	# line per reset names the type and the app, and a slow one is visible without
	# having to reproduce it with a profiler.
	$log->info('reset ' . ($c->param('type') // '?') . ' ' . ($content->{'app'} // '?') . ' took ' . (&subs::rightNow() - $started) . 'ms');
	$c->render(json => $content );

}

# POST /manager/app_measures
sub action_17621 {
	my $c = shift;
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		&remote_relay_request($c, { dissemination => 'yes' });
	}, { name => 'app measures remote relay' });
	my $app = $c->param('app');
	my $measure = $c->param('measure');
	my $value = $c->param('value');
	my $server_time = &subs::rightNow();
	my $measures = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	my $setting_only = $c->param('setting_only');
	my $just_one = $c->param('just_one');
	my $timestamp = &timestamp_adjuster($c);
	unless ( eval { %{$measures->{$measure}} } ) {
		$measures->{$measure} = {};
	}

	$measures->{$measure}->{'value'} = $value;
#	if ($value == 0) { $value = "0"; }

	my $jmeasures = encode_json $measures;
	unless ($just_one) {
		&subs::setting_setter({ app => $app, setting => 'app_measures', value => $jmeasures });
	}

	my $running_appts = &subs::db_query('select uuid from appointments where (type = ? or type = ?) and app = ? and timestamp < ? ORDER BY timestamp LIMIT 1', 'record', 'start', $app, $server_time )->hashes;
	if (scalar @{$running_appts} > 0) {
		foreach my $ra ( @{$running_appts} ) {
			&appt_measure_writer($c,{ app => $app, uuid => $ra->{'uuid'}, measure => $measure, value => $value, timestamp => $timestamp });
			&Websocket::send('tab', { console => &Websocket::console_command('setMeasure', $app, $measure, $value)}) if $setting_only ne 'yes';
		}
	}
	else {
		&appt_measure_writer($c, { app => $app, measure => $measure, value => $value, timestamp => $timestamp });
		&Websocket::send('tab', { console => &Websocket::console_command('setMeasure', $app, $measure, $value)}) if $setting_only ne 'yes';
	}

	$c->render(json => { measures => $measures });
}

# POST /manager/configuration/app_measure_configuration_matcher
sub action_17778 {
	my $c = shift;
	my $app = $c->param('app');
	my $measure = $c->param('measure');
	my $uuid = $c->param('uuid') eq 'new' ? &subs::random_string_creator(22) : $c->param('uuid');
	my $setting = $c->param('setting');
	my $value = $c->param('value');

	my $measures = eval { return decode_json &subs::setting_grabber({ app => $app, setting => 'app_measures' }) } || {};
	$measure = $measures->{$measure};

	my $cms = $measure->{'cm'} || [];
	my ($cm) = grep { $_->{'uuid'} eq $uuid } @{$cms};
	if ($setting eq 'app') { $value = &subs::unformat_name($value); }
	if ($cm->{'uuid'}) {
		$cm->{$setting} = $value;
	}
	else {
		$cm = { uuid => $uuid, $setting => $value };
		push @{$cms}, $cm;
	}
	$measure->{'cm'} = $cms;
	my $jmeasures = encode_json $measures;
	&subs::setting_setter({ app => $app, setting => 'app_measures', value => $jmeasures });


	$c->render(json => $cm);

}

# POST /manager/app_measure_delete
sub action_17807 {
	my $c = shift;
	my $app = $c->param('app');
	my $app_uuid = $c->param('app_uuid');
	my $uuid = $c->param('uuid');
	my $appts = &subs::db_select('appointments', undef, { uuid => $app_uuid, app => $app })->hashes;

	my $am = eval { return decode_json $appts->[0]->{'measures'} } || [];
	@{$am} = grep { $_->{'uuid'} ne $uuid } @{$am};

	my $jam = encode_json $am;
	&subs::db_update('appointments', { measures => $jam, server_time => &subs::rightNow() }, { uuid => $app_uuid, app => $app });

	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $app_uuid)});
	$c->render('text' => 'ok');
}

# POST /manager/inventory/evaluate
sub action_17913 {
	my $c = shift;
	my $timestamp = $c->param('timestamp');
	my $app = &subs::unformat_name($c->param('app'));
	# the picker's answer rides the request; the setting behind it is what the
	# nightly run will read
	my $period = $c->param('period');
	# the timeslot counts that used to be tallied here (a scan of every
	# appointment) had no reader left once the raw dump came off the page, so
	# they are gone
	# the numbers are rolled up; let the evaluation agent read them with the model,
	# and hand the page the headline and the chunks the text splits into so its
	# app names can be links
	my $evaluation_report = &subs::evaluation_agent($app || '__president', $period);
	my $returner = { ok => 'yes', app => $app, evaluation_report => $evaluation_report, pieces => &subs::evaluation_report_pieces($evaluation_report) };
	$c->render(json => $returner);
}

# POST /manager/inventory/evaluate/nightly
sub action_17930 {
	my $c = shift;
	# the setting remembers the wish, the schedule carries it out, so the control
	# cannot drift from the queue; the answer reports the cadence and schedule that
	# now exist, and the page paints that. checked is the old checkbox, read as
	# daily/off, so a stale control still works
	my $app = &subs::unformat_name($c->param('app')) || '__president';
	my $cadence = $c->param('cadence');
	$cadence = ($c->param('checked') ? 'daily' : 'off') unless defined $cadence && $cadence ne '';
	my $schedule = &subs::evaluation_cadence_apply($app, $cadence);
	$c->render(json => {
		ok => 'yes',
		app => $app,
		cadence => &subs::evaluation_cadence($app),
		next_run => $schedule ? $schedule->{'next_run'} : undef,
	});
}

# GET /manager/inventory/information
sub action_17947 {
	my $c = shift;
	my $app = $c->param('app');
	my $timestamp = $c->param('timestamp');
	my $scope = $c->param('scope');
	my $x = $c->param('x');
	my $y = $c->param('y');
	my $start_timestamp = $c->param('start_timestamp');
	my $end_timestamp = $c->param('end_timestamp');
	my $zone = $c->param('zone');
	my $returner = {
		scope => $scope,
		timestamp => $timestamp,
		app => $app
	};
	$returner->{'details'} = &inventory_details($c, &subs::settings_grabber({ app => $app }));

	$returner->{'html'} = $c->render_to_string(
		template => 'apps/inventory_info',
		scope => $scope,
		timestamp => $timestamp,
		app => $app,
		'x' => $x,
		'y' => $y,
		zone => $zone,
		start_timestamp => $start_timestamp,
		end_timestamp => $end_timestamp,
		details => $returner->{'details'}
	);

	$c->render(json => $returner);
}

# A quick, plain-language reading of one cell of the inventory - its value, the
# pace it is on if the app keeps a budget, how it sits against the recent
# periods, and what the activity was made of - written by the same model the
# evaluation uses. The panel asks for it after it has drawn, so a slow model
# only leaves the summary a moment late rather than holding the window shut.
# GET /manager/inventory/summary
sub action_17984 {
	my $c = shift;
	my $data = {
		app => &subs::unformat_name($c->param('app')),
		scope => $c->param('scope'),
		zone => $c->param('zone'),
		timestamp => $c->param('timestamp'),
		start => $c->param('start_timestamp'),
		end => $c->param('end_timestamp'),
	};
	# Hovering a row asks for a summary per cell, and each is a model call. The
	# child does the waiting; this worker keeps serving the panel in between.
	&subs::render_in_subprocess($c, sub {
		return &inventory_cell_summary($data);
	}, sub {
		my ($c, $returner) = @_;
		$c->render(json => ($returner || { summary => '', error => 'the summary did not answer' }));
	});
}

# GET /manager/inventory/details
sub action_18252 {
	my $c = shift;
	my $app = &subs::unformat_name($c->param('app'));
	my $s_scroll = $c->param('s_scroll');
	if ($s_scroll != 0) {
		&subs::setting_setter({ app => $app, setting => 's_scroll', value => $s_scroll });
	}
	my $settings = &subs::settings_grabber({ app => $app });
	my $returner = &inventory_details($c, $settings);
	$c->render(json => $returner);
}

1;
