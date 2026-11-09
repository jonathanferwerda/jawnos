package Manager;

# Manager helpers, part 2 of 37. Moved out of Manager.pl so a
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
use IPC::Open2 qw(open2);

our ($APP, $ws_live_window, $encoder, $decoder, $tuuid, $thread_uuid, $universal_splitter, $database, $sql, $remote_input_clipboard, $config_file, $config, $logfile, $log, $environment, $random_caching_string, $duty_file, $main_process, $device, $user_agent, %time_machine_guide_cache, @media_unlock_apps, %help_search_tables, %media_type_for_ext, %file_relay_down, @appointments, @results, %market_payment_family, @manager_bundle_files, $manager_bundle_cache, $js_minifier, %app_release_sha, %folders_desk_not_app, $jg_body, $remote_input_geometry_at, $remote_input_geometry_cache, %remote_input_ua, %remote_input_ws, %remote_input_rm, %remote_input_ws_failed, $public_ip_memo, $coding_protocols, $coding_protocols_mtime, $app_schema_done, $fingerprint_checked_at, $fingerprint_ok, %padlock_time_memo, %credential_browser_app, %app_gate_shadow_seen, $ws_server, %mailws_untrusted_rate);

sub take_picture($c,$data) {
	my $uuid = $data->{'uuid'} || undef;
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $app = &subs::unformat_name($data->{'app'} || $c->param('app'));
	my $app_path = &subs::path_name($app);
	unless (&subs::session_suds($c)) {
		$c->stash('app' => $app);
		$c->stash('uuid' => $uuid);
	}
	# A file the app's own camera already captured. Claim it before any relay or
	# capability test: the bytes exist, so this machine's job is to file them.
	my $native_path = $data->{'native_path'} || '';
	my $native_capture = &native_capture_claim($native_path);
	# A named capture that cannot be claimed (already filed, expired from the
	# staging dir, or not inside it) is not an invitation to take another one.
	return ('denial','denial') if length $native_path && !$native_capture;
	my $kind = lc($data->{'native_kind'} || '') eq 'video' ? 'video' : 'image';
	if ($native_capture) {
		my $native_ext = $data->{'native_name'} || $native_capture;
		$kind = 'video' if $native_ext =~ /\.(?:mp4|webm|mov|mkv|avi)\b/i;
	}
	# A named machine takes the picture; this one only hands the request over.
	# remoted=yes is the peer that received it, and it must not relay again.
	my $remote_uuid = $c->param('remote_uuid') || '';
	if (($c->param('remoted') || '') ne 'yes' && $remote_uuid ne '' && $remote_uuid ne &subs::signatorial_designer()) {
		&remote_relay_request($c, { remote_uuid => $remote_uuid });
		return ('denial','denial');
	}
	if (!$native_capture && !grep { $_ eq $data->{'camera'} } @{$gb::capabilities->{&subs::device_setter()}->{'camera'} || []}) {
		# A person who named a machine pointed at that machine: if it has no such
		# camera, the capture simply does not happen. Only an unpointed press
		# looks around the house for a camera that can take it.
		return ('denial','denial') if ($remote_uuid ne '');
		&remote_relay_request($c);
		return ('denial','denial');
	}


	my $camera = $data->{'camera'} || 0;
	my $warranty = &subs::ago_calc(&subs::setting_grabber({ app => 'app', setting => 'warranty' }) || &subs::setting_grabber({ app => 'me', setting => 'warranty' }), $server_time);
	my ($filename,$ocr);
	my ($db,$database,$sql) = &subs::database_grabber();
	# Captures taken on an appointment's media row belong to that appointment; a
	# press made from the wrapper names only the app, so resolve the row the
	# details view is showing. The app's open session (a start/record row with no
	# stop) wins, because that is the session a capture belongs to even while a
	# newer, already-stopped row exists. With no open session the newest row is the
	# one the view shows. The Camera app itself is unclaimed media by design and
	# keeps its own path.
	if (!$uuid && !$data->{'capture_only'} && $app ne 'camera') {
		my $rows = &subs::db_query('select uuid, type, stop_seen, stop_timestamp, server_time, timestamp from appointments where app=? and uuid is not null order by server_time desc limit 1', $app)->hashes || [];
		my $open = &subs::open_session_uuid($app);
		push @{$rows}, { uuid => $open, type => 'start', stop_seen => undef, stop_timestamp => undef } if length $open;
		# preload is the mapped Log.pm entry that defines capture_target_uuid.
		&subs::preload('log_reader');
		my $target = &subs::capture_target_uuid($rows);
		$uuid = $target if length $target;
	}
	# The caller (the wrapper names only an app) may not have known the row; hand
	# the resolved one back so the refresh below reopens the right appointment.
	$data->{'uuid'} = $uuid if $uuid;
	my $media_setting = $kind eq 'video' ? 'video_location' : 'photo_location';
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => $media_setting, device => $device } ));
	my $dir = $folder . '/' . $app_path;
	`mkdir -p $dir` unless -e $dir;
	my $thumb_dir = $dir . '/.thumbs/';
	`mkdir -p $thumb_dir` unless -e $thumb_dir;
	my $base = $dir . '/' . $app_path . '_' . $timestamp;
	my $thumb = $thumb_dir . $app_path . '_' . $timestamp . '.jpg';
	my $ext = $kind eq 'video' ? 'mp4' : 'jpg';
	if ($native_capture) {
		my $probe = $data->{'native_name'} || $native_capture;
		if ($probe =~ /\.([A-Za-z0-9]{1,5})$/) {
			my $given = lc $1;
			$ext = $given if $given =~ /^(?:jpg|jpeg|png|webp|heic|heif|bmp|tif|tiff|xcf|gif|mp4|webm|mov|mkv|avi)$/;
		}
	}
	$filename = $base . '.' . $ext;

	if ($native_capture) {
		# The app wrote the capture into the shared staging directory; move it
		# into the house's own folder. A move across filesystems is a copy+unlink.
		my $moved = eval { move($native_capture, $filename) };
		unless ($moved && -e $filename) {
			my $tn_src = &subs::shell_quote($native_capture);
			my $tn_dst = &subs::shell_quote($filename);
			`cp $tn_src $tn_dst`;
			unlink $native_capture if -e $filename;
		}
	}
	elsif ($device eq 'mobile' && ($camera eq 0 || $camera == 1)) {
		&subs::device_call('camera.photo', { path => $filename, camera => $camera });
	}
	elsif ($device eq 'computer' && $camera eq 'webcam') {
		eval { `ffmpeg -nostdin -i /dev/video0 $filename` };
	}
	if (-e $filename) {
		if ($kind eq 'image') {
			$ocr = &ocr_reader($c,$filename) unless $data->{'no_ocr'};
			my $resolution = &subs::setting_grabber({ app => 'misc', setting => 'photo_size' } ) || '1920x1080';
			unless (lc $resolution eq 'raw') {
				my ($w, $h) = &subs::image_resolution_parts($resolution);
				my $resized = ($w && $h) ? &subs::image_bridge_resize($filename, $w, $h) : undef;
				# Auto-orient before the EXIF block is stripped: a phone stores the
				# sensor's pixels sideways and records the rotation in EXIF, so a
				# resize that ignores it leaves every portrait photo on its side.
				unless ($resized) {
					{
						local $SIG{'__WARN__'} = sub { };
						system('magick', $filename, '-auto-orient', '-strip', '-resize', $resolution, $filename);
						system('convert', $filename, '-auto-orient', '-strip', '-resize', $resolution, $filename) if $? != 0;
					}
				}
			}
		}
	}
	# A caller that only wants the picture (the People app's crest capture) takes
	# the raw file here; it is not filed as an appointment or sealed in place.
	if ($data->{'capture_only'}) {
		return ($filename, $ocr);
	}
	my $duration = $server_time - &subs::rightNow();
	my $u_data = { thumb => $thumb, server_time => &subs::rightNow(), f => $filename, uuid => &subs::random_string_creator(9), type => $kind, ocr => $ocr };
	$u_data = &thumbnail_creator($u_data);

	my $files = [$u_data];
	if ($uuid) {
		my $appt = &subs::db_select('appointments', undef, { uuid => $uuid, app => $app })->hashes->[0];
		my $pre_files = eval { return decode_json $appt->{'file'} } || [];
		push @{$files}, @{$pre_files};
		my $jfiles = encode_json $files;
		&subs::db_update('appointments', { encryption_standard => undef, duration => $duration, file => $jfiles, server_time => &subs::rightNow() }, { app => $app, uuid => $uuid });
	}
	else {
		$uuid = &subs::random_string_creator(20);
		my $jfiles = encode_json $files;
		my $write = {
			app => $app,
			type => $kind,
			file => $jfiles,
			timestamp => $timestamp,
			server_time => $server_time,
			uuid => $uuid,
			duration => $duration,
		};
		# a capture taken in the Camera app itself, not on an appointment, is
		# unclaimed media: it waits a week on the Camera app to be claimed
		if ($app eq 'camera') {
			$write->{'source'} = 'unclaimed';
			$write->{'warranty'} = &subs::rightNow() + (7 * 24 * 60 * 60 * 1000);
		}
		else {
			$write->{'warranty'} = $warranty;
		}
		&appointment_writer($c, $write);
	}
	# A capture that had to mint a row (the Camera app, or an app with no rows) is
	# still a row the caller can refresh to.
	$data->{'uuid'} = $uuid if $uuid;
	my $jfiles = encode_json $files;
	&subs::file_encrypter({ app => $app });

	return ($jfiles,$ocr);
}

sub scanner_scan_command($feed, $file) {
	my $scanner = $config->{'scanners'}->[0];
	return undef unless $scanner && $file;
	my $printer = &subs::device_lister(&subs::rightNow(),'printer');
	my $address = ($printer && $printer->{'ip'}) ? "hpaio:/net/officejet_3830_series?ip=" . $printer->{'ip'} : $scanner->{'address'};
	my $resolution = $scanner->{'resolution'};
	my @feeds = map { lc } @{ $scanner->{'feeds'} || [] };
	$feed = lc($feed || '');
	if ($feed eq 'flatbed' && grep { $_ eq 'flatbed' } @feeds) {
		return "scanimage --format tiff --source Flatbed --batch=$file.tiff --mode Color -d $address --resolution=$resolution --progress";
	}
	if ($feed eq 'adf' && grep { $_ eq 'adf' } @feeds) {
		return "scanimage --format tiff --source ADF --batch=$file\_\%d.tiff --mode Color -d $address --resolution=$resolution --progress";
	}
	return undef;
}

sub scanner_page_list($base) {
	my @files = grep { length } glob("$base*.tiff");
	return sort {
		my ($an) = $a =~ /_([0-9]+)\.tiff$/;
		my ($bn) = $b =~ /_([0-9]+)\.tiff$/;
		(defined $an && defined $bn) ? ($an <=> $bn) : ($a cmp $b);
	} @files;
}

sub scan($c,$scandata) {
	my $timestamp = $scandata->{'timestamp'};
	my $feed = $scandata->{'feed'};
	my $uuid = $scandata->{'uuid'};
	my $suds = &subs::session_suds($c);
	my $source = $scandata->{'source'};
	my $app = $scandata->{'app'} || $c->param('app');
	my $app_path = &subs::path_name($app);
	# A named machine scans; this one only hands the request over (see take_picture).
	my $remote_uuid = $c->param('remote_uuid') || '';
	if (($c->param('remoted') || '') ne 'yes' && $remote_uuid ne '' && $remote_uuid ne &subs::signatorial_designer()) {
		&remote_relay_request($c, { remote_uuid => $remote_uuid });
		return 'denial';
	}
	if (!grep { $_ eq $scandata->{'feed'} } @{ $gb::capabilities->{&subs::device_setter()}->{'scan'} || [] }) {
		# as with a picture: a named machine that cannot scan with this feeder is
		# the end of the request, not a reason to scan somewhere else
		return 'denial' if ($remote_uuid ne '');
		&remote_relay_request($c);
		return 'denial';
	}
	my ($db,$database,$sql) = &subs::database_grabber();

	my $start_time = &subs::rightNow();
	my $folder = &subs::home(&subs::setting_grabber( { app => 'misc', setting => 'scan_location', device => $device } ));
	my $filename = $folder . '/' . $app_path;
	$filename = &subs::home($filename);
	`mkdir -p $filename` unless -e $filename;
	my $thumb_folder = $filename . '/.thumbs';
	`mkdir -p $thumb_folder` unless -e $thumb_folder;
	my $thumb = $thumb_folder . '/' . $app_path . '_' . $timestamp . '.jpg';
	my $file = $filename . '/' . $app_path . '_' . $timestamp;
	my $image_file = $file . '.jpg';
	&subs::subprocessor(sub {
    Mojo::IOLoop->reset;
		($db,$database,$sql) = &subs::database_grabber();
		my $command = &scanner_scan_command($feed, $file);
		my $run = &subs::subprocessor_command($command, { name => 'document scanner', stderr => 'inherit' });
		my $caseworker = $run->{'output'} // '';
		sleep 1;
		my @scans = &scanner_page_list($file);
		my @filenames;
		my $count = 1;
		my $photo_size = &subs::setting_grabber({ app => 'misc', setting => 'scan_size', device => $device } ) || '1920x1080';
		foreach my $scan (@scans) {
			$file = $scan;
			$file =~ s/\.[^.]+$//;
			$image_file = $file . '.jpg';

			my @image_file = split /\//, $image_file;
			my $thumb_file = pop @image_file;
			$thumb = $thumb_folder . '/' . $thumb_file;


			my $ocr = &ocr_reader($c,$scan);
			if ($photo_size ne "Raw") {
				my ($pw, $ph) = &subs::image_resolution_parts($photo_size);
				my $converted = ($pw && $ph) ? &subs::image_bridge_convert($scan, $image_file, max_width => $pw, max_height => $ph, auto_orient => 1) : undef;
				system('magick', 'convert', $scan, '-auto-orient', '-strip', '-resize', $photo_size, $image_file) unless $converted;
			}
			else {
				my $converted = &subs::image_bridge_convert($scan, $image_file, auto_orient => 1);
				system('magick', 'convert', $scan, '-auto-orient', '-strip', $image_file) unless $converted;
			}
			&subs::secure_unlink($scan);
			push @filenames, { f => $image_file , thumb => $thumb, ocr => $ocr};

			$count++;

		}
		my $fnames = [];
		foreach my $f ( @filenames ) {
			my $file_data = { server_time => &subs::rightNow(), ocr => $f->{'ocr'}, f => $f->{'f'}, thumb => $f->{'thumb'}, uuid => &subs::random_string_creator(10), type => 'document', 'of' => $f->{'f'} };
			$file_data = &thumbnail_creator($file_data);
			push @{$fnames}, $file_data;
		}

		if ($uuid) {
			my $appt = &subs::db_select('appointments', undef, { app => $app, uuid => $uuid })->hashes->[0];
			my $pre_files = eval { return decode_json $appt->{'file'} } || [];
			if (scalar @{$pre_files} > 0) {
				push @{$fnames}, @{$pre_files};
			}
		}


		my $filenames = encode_json $fnames;
		my $server_time = &subs::rightNow();
		my $duration = ($start_time - $server_time );
		if (@{$fnames} > 0) {
#			&subs::db_query('update appointments set server_time = ?, duration = ?, file = ?, encryption_standard = ? where app = ? and uuid = ?',
#				&subs::rightNow(),$duration, $filenames, undef, $app, $uuid );

			&subs::db_update('appointments' , { server_time => &subs::rightNow(), duration => $duration, file => $filenames, encryption_standard => undef }, { app => $app, uuid => $uuid });

			&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
		}
		elsif ( scalar @filenames == 0 && $source ne 'existing' ) {
			&subs::db_delete('appointments', { uuid => $uuid });
			&Websocket::send('server', { console => &Websocket::console_command('removeAppointmentDetail', $app, $uuid)});
		}
		&subs::file_encrypter({ app => $app });
	}, { name => 'document scanner' });
	&Websocket::send('server', { console => &Websocket::console_command('appointmentDetailGrabber', $app, $uuid)});
	return encode_json [{ f => $image_file }];
}

sub play_audio($file) {
	&subs::subprocessor(sub {
		$file = &subs::terminal_name($file);
		if ( `ps -e | grep play` ) {
			`pkill play`;
		}
		else {
			&subs::subprocessor(sub {
		    Mojo::IOLoop->reset;
				`play "$file"`;
			}, { name => 'audio player' });
		}
	}, { name => "Audio file player" });
	return $file;
}

sub play_audio_stop($file) {
	`pkill play`;
	return $file;
}

sub thumbs_bundle_one {
	my ($c, $raw, $appt_cache, $secrets_cache, $standard_cache, $suds_ref, $max_file) = @_;
	return undef unless defined $raw && length $raw && length $raw < 8192;
	my $url = eval { Mojo::URL->new($raw) };
	return undef unless $url;
	return undef unless ($url->path->to_string // '') eq '/file_open';
	my $q = $url->query;
	# A peer answer is a network wait, and a generated thumb is ImageMagick; both
	# stay on their own single-flight path rather than multiplying inside a batch.
	return undef if $q->param('remote_uuid');
	return undef if $q->param('duty') || $q->param('loudness') || $q->param('as_is')
		|| $q->param('subtitle') || $q->param('position') || $q->param('chapter');
	my $file = $q->param('file') || $q->param('track') || '';
	return undef unless length $file;
	# The batch route reads local files directly, so it applies the same private
	# rule as /file_open: a private app's pictures are never bundled outside a
	# private place or without the fingerprint grant.
	my $bundle_owner = &subs::unformat_name($q->param('app') || '');
	$bundle_owner = &folders_owning_app($file) unless length $bundle_owner;
	if (length $bundle_owner && &subs::app_private_now($bundle_owner)
		&& (!&subs::private_reachable_now() || !&media_grant_open($c))) {
		return undef;
	}
	my $appt_uuid = $q->param('app_uuid') || $q->param('appt_uuid') || '';
	my $file_uuid = $q->param('file_uuid') || '';
	my $timestamp = $q->param('timestamp') || &subs::rightNow();
	my ($appt, $file_data, $standard);
	if ($appt_uuid) {
		$appt = $appt_cache->{$appt_uuid};
		unless ($appt) {
			$appt = &subs::db_query('select * from appointments where uuid = ? limit 1', $appt_uuid)->hashes->[0] || {};
			$appt_cache->{$appt_uuid} = $appt;
		}
		$standard = $appt->{'encryption_standard'} if length($appt->{'encryption_standard'} || '');
	}
	# A thumb request is answered from the stored thumb when there is one. When
	# there is not, the caller wanted a generated image; leave that to /file_open,
	# whose global slot keeps the whole house to one generation at a time.
	if ($q->param('thumb')) {
		my $files = ($appt && length($appt->{'file'} || '')) ? (eval { decode_json $appt->{'file'} } || []) : [];
		foreach my $f ( @{$files} ) {
			next if $file_uuid && ($f->{'uuid'} || '') ne $file_uuid;
			next unless ($f->{'f'} || '') eq $file;
			$file_data = $f;
			last;
		}
		return undef unless $file_data;
		return undef unless $file_data->{'thumb'} && -e $file_data->{'thumb'} && (-s $file_data->{'thumb'}) > 100;
		$file = $file_data->{'thumb'};
	}
	return undef unless -e $file;
	my @st = stat($file);
	return undef unless @st && $st[7] > 0 && $st[7] <= $max_file;
	if ($file !~ /\.enc$/i) {
		my $data = read_file($file);
		return undef unless defined $data && length $data;
		my $type = &subs::plaintext_verdict(substr($data, 0, 65536)) || &thumbs_bundle_type($file);
		return ('data:' . $type . ';base64,' . encode_base64($data, ''), length $data);
	}
	# The credentials depend on the appointment's time, not the request's; one
	# read and one decryption per batch is the whole point of this route.
	my $key = ($appt_uuid || '') . '|' . ($timestamp || 0);
	my $secrets = $secrets_cache->{$key};
	unless ($secrets) {
		$$suds_ref = &subs::suds_grabber() || '' unless defined $$suds_ref;
		my @list;
		push @list, $$suds_ref if length $$suds_ref;
		my $passwords = &subs::db_query('select * from security where level != ? and level != ? and timestamp <= ? order by timestamp DESC', 'padlock', 'door', $timestamp)->hashes;
		foreach my $p ( @{$passwords} ) {
			my $secret = &subs::decrypter($$suds_ref, $p->{'credential'}, $timestamp);
			push @list, $secret if defined $secret && length $secret;
		}
		$secrets = $secrets_cache->{$key} = \@list;
	}
	my $std = $standard_cache->{$key};
	unless (defined $std) {
		$std = $standard || &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
		$standard_cache->{$key} = $std;
	}
	my $opened = &subs::sealed_file_open($file, $secrets, [ $std ], 1, sub { return &subs::plaintext_verdict($_[0]) });
	return undef unless $opened && defined $opened->{'data'} && length $opened->{'data'};
	my $type = $opened->{'verdict'} || &subs::plaintext_verdict(substr($opened->{'data'}, 0, 65536)) || &thumbs_bundle_type($file);
	return ('data:' . $type . ';base64,' . encode_base64($opened->{'data'}, ''), length $opened->{'data'});
}

sub thumbs_bundle_type {
	my ($file) = @_;
	my $name = $file || '';
	$name =~ s/\.enc$//i;
	return 'image/jpeg' if $name =~ /\.jpe?g$/i;
	return 'image/png' if $name =~ /\.png$/i;
	return 'image/webp' if $name =~ /\.webp$/i;
	return 'image/gif' if $name =~ /\.gif$/i;
	return 'image/bmp' if $name =~ /\.bmp$/i;
	return 'image/tiff' if $name =~ /\.tiff?$/i;
	return 'application/octet-stream';
}

sub file_cache_tag($file) {
	my @st = stat($file);
	return undef unless @st;
	return {
		etag => '"' . &subs::md5_sum(join(':', $file, $st[1], $st[7], $st[9])) . '"',
		mtime => $st[9],
	};
}

sub file_response_headers($c, $file, $cache_control) {
	my $tag = &file_cache_tag($file);
	return 0 unless $tag;
	# Every path through rock_and_roll honours a Range request, so say so: a
	# media stack that does not see Accept-Ranges asks for the whole file (or
	# gives up) instead of seeking.
	$c->res->headers->accept_ranges('bytes');
	$c->res->headers->etag($tag->{'etag'});
	eval {
		require Mojo::Date;
		$c->res->headers->last_modified(Mojo::Date->new($tag->{'mtime'})->to_string);
	};
	$c->res->headers->cache_control($cache_control) if defined $cache_control && length $cache_control;
	return 1;
}

sub file_response_cache_headers($c, $file, $cache_control) {
	my $tag = &file_cache_tag($file);
	return 0 unless $tag;
	my $match = 0;
	my $etag = $tag->{'etag'};
	my $inm = $c->req->headers->if_none_match;
	if (defined $inm && length $inm) {
		$match = 1 if $inm eq '*' || $inm =~ /\Q$etag\E/;
	}
	else {
		my $ims = $c->req->headers->if_modified_since;
		if (defined $ims && length $ims) {
			my $since = eval {
				require Mojo::Date;
				Mojo::Date->new($ims)->epoch;
			};
			$match = 1 if defined $since && $tag->{'mtime'} <= $since;
		}
	}
	return 0 unless $match;
	return &file_response_headers($c, $file, $cache_control);
}

sub media_content_type($file, $verdict) {
	my $name = $file;
	$name =~ s/\.enc$//i;
	my @parts = split /\./, $name;
	my $ext = lc $parts[-1];
	return $media_type_for_ext{$ext} if $media_type_for_ext{$ext};
	return $verdict if defined $verdict && $verdict =~ m{^(?:audio|video)/};
	return undef;
}

sub media_render_args($file, $verdict) {
	my $type = &media_content_type($file, $verdict);
	return () unless defined $type && $type =~ m{^(?:audio|video)/};
	return (content_type => $type, content_disposition => 'inline');
}

sub stream_fuse_media($c, $file) {
	my $type = &media_content_type($file, undef);
	return 0 unless defined $type && $type =~ m{^(?:audio|video)/};
	my $size = -s $file;
	return 0 unless defined $size && $size > 0;
	my ($start, $end, $code) = (0, $size - 1, 200);
	my $range = $c->req->headers->range;
	if (defined $range && length $range && $range =~ m/^bytes=(\d*)-(\d*)/) {
		my ($s, $e) = ($1, $2);
		if ($s eq '' && $e ne '') {
			my $want = int($e);
			$want = $size if $want > $size;
			$start = $size - $want;
			$end = $size - 1;
		}
		elsif ($s ne '') {
			$start = int($s);
			$end = ($e ne '') ? int($e) : $size - 1;
			$end = $size - 1 if $end >= $size;
		}
		if ($start > $end || $start >= $size) {
			$c->res->code(416);
			$c->res->headers->content_range('bytes */' . $size);
			$c->res->headers->accept_ranges('bytes');
			$c->res->body('');
			return 1;
		}
		$code = 206;
	}
	my $length = $end - $start + 1;
	return 0 unless open my $fh, '<:raw', $file;
	unless (seek($fh, $start, 0)) { close $fh; return 0; }
	my $name = $file;
	$name =~ s{.*/}{};
	$name =~ s/"/'/g;
	$c->res->code($code);
	$c->res->headers->content_type($type);
	$c->res->headers->content_disposition('inline; filename="' . $name . '"');
	$c->res->headers->content_length($length);
	$c->res->headers->content_range('bytes ' . $start . '-' . $end . '/' . $size) if $code == 206;
	&file_response_headers($c, $file, 'private, no-cache');
	my $remaining = $length;
	my $chunk = 256 * 1024;
	my $emit;
	$emit = sub {
		if ($remaining <= 0) { close $fh; $c->write(''); return; }
		my $want = $remaining < $chunk ? $remaining : $chunk;
		my $buf = '';
		my $got = read($fh, $buf, $want);
		if (!defined $got || $got <= 0) { close $fh; $c->write(''); return; }
		$remaining -= $got;
		$c->write($buf, $emit);
	};
	$emit->();
	return 1;
}

sub stream_sealed_file($c, $job, $file, $cache_control) {
	my $spec = $job->{'spec'};
	my $mode = $spec->{'family'} eq 'ctr' ? &subs::note_ctr_mode($spec) : &subs::note_cbc_mode($spec, 1);
	my $stream = eval { $mode->start_decrypt($job->{'key'}, $job->{'iv'}) };
	return 0 unless $stream;

	my $name = $file;
	$name =~ s{.*/}{};
	$name =~ s/\.enc$//i;
	utf8::decode($name) if !utf8::is_utf8($name);
	$name = &quote($name);
	$name = Encode::encode('UTF-8', $name) if eval { require Encode; 1 };

	my $content_type = &media_content_type($file, $job->{'verdict'}) || 'application/x-download';
	my $disposition = $content_type =~ m{^(?:audio|video)/} ? 'inline' : 'attachment';
	$c->res->code(200);
	$c->res->headers->content_type($content_type);
	$c->res->headers->content_disposition($disposition . ';filename=' . $name);
	$c->res->headers->accept_ranges('bytes');
	$c->res->headers->content_length($job->{'total'});
	&file_response_headers($c, $file, $cache_control);

	my $container = $job->{'container'};
	my ($offset, $end, $step) = (0, length($container) - 16, 1024 * 1024);
	my $emit;
	$emit = sub {
		if ($offset >= $end) { $c->write(''); return }
		my $take = $offset + $step > $end ? $end - $offset : $step;
		my $plain = eval { $stream->add(substr($container, 16 + $offset, $take)) };
		if (!defined $plain) {
			$c->app->log->error('sealed stream: ' . ($@ // 'decrypt failed'));
			$c->write('');
			return;
		}
		$offset += $take;
		if ($offset >= $end) {
			my $tail = eval { $stream->finish };
			$plain .= $tail if defined $tail && length $tail;
			$c->write($plain, sub { $c->write('') });
		}
		else { $c->write($plain, $emit) }
	};
	$emit->();
	return 1;
}

sub sealed_thumb_prefix($filename, $job, $bytes) {
	my $spec = $job->{'spec'} or return 0;
	my $container = $job->{'container'};
	my $total = length($container) - 16;
	my $take = $bytes < $total ? $bytes : $total;
	my $block = $spec->{'ivlen'};
	$take = int($take / $block) * $block if $spec->{'family'} eq 'cbc';
	$take = $total if $take > $total;
	return 0 unless $take > 0;
	my $ct = substr($container, 16, $take);
	my $mode = $spec->{'family'} eq 'ctr' ? &subs::note_ctr_mode($spec) : &subs::note_cbc_mode($spec, 1);
	my $plain = eval { $mode->decrypt($ct, $job->{'key'}, $job->{'iv'}) };
	return 0 unless defined $plain && length $plain;
	write_file($filename, $plain);
	return 1;
}

sub sealed_file_to_path($job, $path) {
	my $spec = $job->{'spec'} or return 0;
	my $container = $job->{'container'};
	my $mode = $spec->{'family'} eq 'ctr' ? &subs::note_ctr_mode($spec) : &subs::note_cbc_mode($spec, 1);
	my $stream = eval { $mode->start_decrypt($job->{'key'}, $job->{'iv'}) };
	return 0 unless $stream;
	open(my $fh, '>', $path) or return 0;
	my ($offset, $end, $step) = (0, length($container) - 16, 1024 * 1024);
	while ($offset < $end) {
		my $take = $offset + $step > $end ? $end - $offset : $step;
		my $plain = eval { $stream->add(substr($container, 16 + $offset, $take)) };
		if (!defined $plain) { close $fh; return 0; }
		print $fh $plain;
		$offset += $take;
	}
	my $tail = eval { $stream->finish };
	print $fh $tail if defined $tail && length $tail;
	close $fh;
	return -s $path ? 1 : 0;
}

1;
