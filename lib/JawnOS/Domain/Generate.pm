package subs;

# Generate: extracted from subroutines.pl (package subs). Loaded on
# demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Clone qw(clone);
use Data::Dumper;
use Date::Parse;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
use Fcntl qw(:flock);
use File::Copy;
use File::Find;
use File::Path;
use File::Slurp;
use IPC::Open2;
use JSON::PP ();
use List::Util qw(shuffle);
use MIME::Base64;
use Math::Trig qw(cartesian_to_spherical spherical_to_cartesian great_circle_distance rad2deg deg2rad great_circle_bearing great_circle_direction great_circle_destination);
use Mojo::IOLoop;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Util qw/md5_sum xml_escape html_unescape term_escape quote unquote secure_compare url_escape url_unescape network_contains punycode_decode punycode_encode b64_decode b64_encode/;
use POSIX ();   # mktime: a local-time epoch that still predates 1970
use Text::Unidecode;
use Time::Duration;
use Time::HiRes qw(gettimeofday time);
use Time::Local;
use Time::Piece;
use Unicode::Normalize qw(NFC);

our %accounting_account_cache;
# A fingerprint of the code this machine is actually running. There is no
# .git on the remote machines (remote_rsync excludes it), so the source files
# themselves are hashed; when a .git is present the commit is reported too.
# Computed once per process and memoised - the app only re-reads its code on a
# restart, so the values cannot change under it.
our $code_revision_cache;
our $database;
our $device;
our $gb;
our $jawn_version_cache;
our $log;
our %m;

sub generate_ai_media {
  my ($data) = @_;
	my $kind = $data->{'kind'} || 'image';
	my $c = &subs::controller_builder();
	my $msg_uuid = $data->{'msg_uuid'};
  my $ua       = $data->{'ua'};
  my $prompt   = $data->{'prompt'};
  my $settings = $data->{'settings'};
	my $conversation = $data->{'conversation'};
	my $mail_contact = $data->{'mail_contact'};
	my $start_timestamp = &subs::rightNow();
	# Unclaimed media (a Guide associate, or Pen with no name for the chat) lands
	# on the Camera app, where it waits a week to be claimed onto an appointment.
	my $unclaimed = ($data->{'unclaimed'}) ? 1 : 0;
	my $app = $unclaimed ? 'camera' : $mail_contact;
	if (!$unclaimed && $conversation->{'chatbot_conversation_name'}) {
		$app = $conversation->{'chatbot_conversation_name'};
	}
	$app = &subs::unformat_name($app);

  $log->info(Dumper $data);
	# the media comes through the Plat generation model for this kind; the
	# storing, the appointment and the reply are this routine's own work. The
	# agent's fallback is tried when the primary fails (an outage, no credit).
	my $role = $kind eq 'image' ? 'text_to_image_assistant' : $kind eq 'audio' ? 'text_to_audio_assistant' : 'text_to_video_assistant';
	my ($primary, $fallback) = &subs::ai_role_models($role);
	my %gen_seen;
	my @gen_candidates = grep { !$gen_seen{$_}++ } grep { defined $_ && length $_ } ($data->{'model'}, $primary, $fallback);
	my ($binary, $mime, $gen_err);
	foreach my $candidate ( @gen_candidates ) {
		($binary, $mime, $gen_err) = ($kind eq 'image')
			? &subs::ai_text_to_image({ prompt => $prompt, model => $candidate })
			: &subs::ai_text_to_media($kind, { prompt => $prompt, model => $candidate });
		last if defined $binary && length $binary;
		&subs::say_it('AI: ' . $kind . ' with ' . $candidate . ' failed (' . ($gen_err || 'nothing returned') . ')') if @gen_candidates > 1;
	}
	if ($gen_err || !defined $binary || !length $binary) {
		$log->error(ucfirst($kind) . ' generation failed: ' . ($gen_err || 'nothing returned'));
		return undef;
	}
	my $upload_type = $kind;
	my $filename = $kind . '_' . &subs::rightNow() . ($kind eq 'image' ? '.png' : $kind eq 'audio' ? '.mp3' : '.mp4');
	my $setting = ($kind eq 'image' ? 'photo_location' : $kind eq 'audio' ? 'music_location' : 'video_location');
	my $folder = &subs::setting_grabber({ app => 'misc', setting => $setting, device => $device });
	my $location = $folder ? (&subs::home($folder) . '/' . &subs::path_name($app)) : '';
	my $public_dir = $location || &subs::home('~/Public/generated_' . $kind);
	`mkdir $public_dir` unless -d $public_dir;

	my $file_path = $public_dir . '/' . $filename;
	write_file($file_path, $binary);
	my $ocr;
	if ($kind eq 'image') {
		my $resolution = &subs::setting_grabber({ app => 'misc', setting => 'photo_size' } ) || '1920x1080';
		unless (lc $resolution eq 'raw') {
			my ($w, $h) = &subs::image_resolution_parts($resolution);
			my $resized = ($w && $h) ? &subs::image_bridge_resize($file_path, $w, $h) : undef;
			system('magick', $file_path, '-resize', $resolution, $file_path) unless $resized;
		}
		$ocr = &subs::ocr_reader($c,$file_path);
	}
	# a still thumbnail for image and video, made up front so the unclaimed
	# pool can show it at once instead of waiting on the full file
	my $thumb;
	if ($upload_type eq 'image' || $upload_type eq 'video') {
		my $thumb_dir = $public_dir . '/.thumbs';
		`mkdir -p $thumb_dir` unless -d $thumb_dir;
		my $t = $thumb_dir . '/' . $filename;
		$t =~ s/\.[^.]+$/.png/;
		my $thumbnail_size = &subs::setting_grabber({ app => 'misc', setting => 'thumbnail_size' }) || 'none';
		if ($thumbnail_size ne 'none') {
			my ($max) = $thumbnail_size =~ /(\d+)/;
			# The bridge makes the still itself (a video frame via
			# MediaMetadataRetriever); a desktop keeps the pipeline.
			my $native = &subs::image_bridge_thumbnail($file_path, $max || 256, $t);
			unless ($native) {
				my $cmd = ($upload_type eq 'video')
					? 'ffmpeg -nostdin -ss ' . &subs::thumbnail_seek_position() . ' -i ' . $file_path . ' -vframes 1 -c:v png -f image2pipe - | magick - -resize ' . $thumbnail_size . ' ' . $t
					: 'magick ' . $file_path . ' -resize ' . $thumbnail_size . ' ' . $t;
				`$cmd`;
			}
			$thumb = $t if -e $t;
		}
	}
	my $appt_uuid = &subs::random_string_creator(33);
	my $file_uuid = &subs::random_string_creator(21);
	my $u_data = [{ server_time => &subs::rightNow(), appt_uuid => $appt_uuid, mail_uuid => $msg_uuid, ocr => $ocr, f => $file_path, uuid => $file_uuid, type => $upload_type }];
	$u_data->[0]->{'thumb'} = $thumb if $thumb;
	$log->info(Dumper $u_data);
	my $jfile = encode_json $u_data;

	my $write = {
		timestamp => &subs::rightNow(),
		app => &subs::unformat_name($app),
		notes => &subs::note_encrypter(&subs::suds_grabber(),$prompt),
		type => $upload_type,
		file => $jfile,
		uuid => $appt_uuid,
		duration => &subs::rightNow() - $start_timestamp,
	};
	$write->{'source'} = 'unclaimed' if $unclaimed;
	$write->{'warranty'} = &subs::rightNow() + (7 * 24 * 60 * 60 * 1000) if $unclaimed;
	&Manager::appointment_writer($c,$write);
	&subs::file_encrypter({ app => &subs::unformat_name($app) });
	&Manager::centre_view_grabber({ c => $c, app => &subs::unformat_name($app), timestamp => &subs::rightNow(), cached => 'no' });

	return ('/file_open?appt_uuid=' . $appt_uuid . '&file_uuid=' . $file_uuid . '&app=' . $app,$u_data);
}

sub generate_ai_image {
	my ($data) = @_;
	$data->{'kind'} = 'image';
	return &generate_ai_media($data);
}

sub manager_file_maker {
	my $session_name = shift;
	my ($my_name,$hostname,$hostnamer,$database);
	(undef,$database) = &subs::database_grabber();
	$hostname = &subs::machine_hostname();
	$hostnamer = eval { return &subs::db_select('devices', ['name'], { hostname => $hostname } )->hash->{name} };
	$my_name = $session_name || &subs::setting_grabber({ app => 'me', setting => 'my_name' });
	# The computer segment is this machine's own name, never the mesh-synced
	# me/computer_name: a shared setting made two machines answer to one durable
	# id, so a device's stored homebase matched neither and nobody held its link.
	return &subs::machine_file_from(($my_name || $hostnamer || ''), $database, &subs::machine_name(), $hostname);

};

sub data_size {
	my $data = shift;
	my $data_size = $data;
	if ($data >= 1024000000) {
		$data_size = sprintf("%.2f", $data / 1000000000) . 'GB';
	}
	elsif ($data > 1024000) {
		$data_size = sprintf("%.2f", $data / 1000000) . 'MB';
	}

	elsif ($data > 1024) {
		$data_size = sprintf("%.2f", $data / 1000) . 'KB';
	}
	return $data_size;
}

sub usual_appointment_maker {
	my $data = shift;
	my $settings = shift;
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $uuid = $data->{'uuid'};
	my $type = $data->{'type'};
	my $duration = $data->{'duration'};
	if ($settings->{'project'}) {
		$data->{'project'} = $settings->{'project'};
	}
	my $m = &subs::db_select('model', undef, { app => $app, def => 'on' })->hashes->[0];
	my ($model,$jmodel,$joptions);
	if ($m->{'uuid'} && $m->{'def'} eq 'on' && &default_attribute_time_checker($m,$timestamp) eq 'yes') {
		$model = {
			uuid => $m->{'uuid'},
			name => $m->{'name'},
			timestamp => $timestamp,
			quantity => ($data->{'quantity'} || $m->{'quantity'}),
			unit => $data->{'unit'} || $m->{'unit'},
			delay_start => $m->{'delay_start'},
			delay_stop => $m->{'delay_stop'}
		};
		$jmodel = encode_json $model;
	}

	if (($m->{'save_app'} || '') eq 'on' && $model->{'uuid'}) {
		$data->{'seen'} = 'yes';
		&source_appt_writer($m,$data,'model');
	}

	my $def_options = &subs::db_select('option', undef, { app => $app, def => 'on' })->hashes;
	my $options = [];
	foreach my $do ( @{$def_options} ) {
		next unless &default_attribute_time_checker($do,$timestamp) eq 'yes';
		my $quantity = $do->{'quantity'};
		$quantity = ($data->{'quantity'} || $do->{'quantity'});
		push @{$options}, {
			uuid => $do->{'uuid'},
			timestamp => $timestamp,
			quantity => $quantity,
			unit => $do->{'unit'},
			name => $do->{'name'},
			delay_start => $do->{'delay_start'},
			delay_stop => $do->{'delay_stop'}
		};
		if ($do->{'save_app'} eq 'on') {
			$data->{'seen'} = 'yes';
			&source_appt_writer($do,$data,'option');
		}
	}
	if (scalar @{$options}) {
		$joptions = encode_json $options;
	}
	else { $options = undef; $joptions = undef; }

	return ($model,$options,$jmodel,$joptions);
}

sub default_attribute_time_checker {
	my $d = shift;
	my $timestamp = shift;
	my @ts = localtime($timestamp / 1000);
	my $allowed_count = 0;

	my $def_month = eval { return decode_json $d->{'def_month'} } || [];
	my $allowed_month = scalar @{$def_month} == 0 ? 1 : 0;
	foreach my $dm ( @{$def_month} ) {
		if ($dm eq 'all') {
			$allowed_month = 1; last;
		} elsif ($dm eq 'none') {
			$allowed_month = 0; last;
		}
		else {
			my ($mon) = grep { $_->{'abbrev'} eq $dm } @{$gb::months};
			if ($mon->{'number'} == $ts[4]) {
				$allowed_month++;
			}
		}
	}
	if ($allowed_month > 0) {
		$allowed_count++;
	}

	my $def_day = eval { return decode_json $d->{'def_day'} } || [];
	my $allowed_day = scalar @{$def_day} == 0 ? 1 : 0;
	foreach my $dd ( @{$def_day} ) {
		if ($dd eq 'all') {
			$allowed_day = 1; last;
		} elsif ($dd eq 'none') {
			$allowed_day = 0; last;
		}	else {
			if ($dd == $ts[3]) {
				$allowed_day++;
			}
		}
	}
	if ($allowed_day > 0) {
		$allowed_count++;
	}

	my $def_wday = eval { return decode_json $d->{'def_wday'} } || [];
	my $allowed_wday = scalar @{$def_wday} == 0 ? 1 : 0;
	foreach my $dw ( @{$def_wday} ) {
		if ($dw eq 'all') {
			$allowed_wday = 1; last;
		} elsif ($dw eq 'none') {
			$allowed_wday = 0; last;
		} else {
			my ($wday) = grep { $_->{'abbrev'} eq $dw } @{$gb::wdays};
			if ($wday->{'number'} == $ts[6]) {
				$allowed_wday++;
			}
		}
	}
	if ($allowed_wday > 0) {
		$allowed_count++;
	}

	my $def_hour = eval { return decode_json $d->{'def_hour'} } || [];
	my $allowed_hour = scalar @{$def_hour} == 0 ? 1 : 0;
	foreach my $dh ( @{$def_hour} ) {
		if ($dh eq 'all') {
			$allowed_hour = 1; last;
		} elsif ($dh eq 'none') {
			$allowed_hour = 0; last;
		} else {
			my ($hour) = grep { $_->{'abbrev'} eq $dh } @{$gb::hours};
			if ($hour->{'number'} == $ts[2]) {
				$allowed_hour++;
			}
		}
	}
	if ($allowed_hour > 0) {
		$allowed_count++;
	}


	return $allowed_count == 4 ? 'yes' : 'no';
}

sub source_appt_writer {
	my $m = shift;
	my $data = shift;
	my $table = shift;
	my $returner = {};
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $uuid = $data->{'uuid'};
	my $type = $data->{'type'};
	my $duration = $data->{'duration'};
	# The parent may have been stopped or deleted while this default's start was
	# still in flight - the model/option chain now runs after the press has its
	# header. A deleted parent writes nothing; a stopped one must not start a
	# child that nothing will ever stop.
	my $source_row = &subs::db_select('appointments', undef, { uuid => $uuid })->hashes->[0];
	return unless $source_row;
	if (($type eq 'start' || $type eq 'record')
		&& (($source_row->{'stop_seen'} || '') eq 'yes'
			|| ($source_row->{'type'} || '') =~ /^(?:stop|cancel)$/)) {
		return;
	}
	my $char = eval { return decode_json $m->{'characteristics'} } || [];
	my $measures = { uuid => &subs::random_string_creator(19) };
	my $unit =  ($app eq $m->{'unit'}) ? $data->{'unit'} : $m->{'unit'};

	my $quantity = $data->{'quantity'} || $m->{'quantity'};

	my $recursion_check = &subs::db_select('appointments', undef, { app => $m->{'name'}, source_uuid => $uuid })->hashes;
	my $datas = {
		app => $m->{'name'},
		timestamp => $timestamp,
		type => $type,
		duration => $duration || 1000,
		source_uuid => $uuid,
		unit => $data->{'unit'} || $m->{'unit'},
		quantity => ($data->{'quantity'} || $m->{'quantity'}),
		project => $data->{'project'} || $m->{'project'},
		manufacturer => $data->{'manufacturer'} || $m->{'manufacturer'},
		# The press that made this child has already drawn the window: a child
		# that forked its own centre view re-read and re-rendered the whole app
		# window on a 200-380 MB process, once per default model and option.
		# The writer drops the fork and its bookkeeping for a quiet child and
		# deletes the key before any insert (see Manager::appointment_writer).
		quiet_child => 1
	};

	if ($type eq 'start' && $m->{'delay_start'}) {
		my $t = &subs::time_abbrev_translator($m->{'delay_start'});
		$timestamp = $timestamp + $t;
		$datas->{'timestamp'} = $timestamp;
	}
	elsif ($type eq 'stop' && $data->{'delay_stop'}) {
		my $t = &subs::time_abbrev_translator($m->{'delay_stop'});
		$timestamp = $timestamp + $t;
		$datas->{'timestamp'} = $timestamp;
	}


	unless (scalar @{$recursion_check} > 0) {


		if ($table eq 'model') {

		}
		elsif ($table eq 'option') {

		}
		my $md5 = md5_sum $datas->{'source_uuid'} . '-' . $app . '-' . $timestamp . '-' . $datas->{'app'};
		$datas->{'uuid'} = $datas->{'source_uuid'} . '-' . $md5;# || &subs::random_string_creator(92);
		my $c = &subs::controller_builder();
		$returner = &Manager::appointment_writer($c,$datas);
	}

	foreach my $ch ( @{$char} ) {
		if (($ch->{'save_appt'} || '') eq 'on') {
			$datas->{'app'} = &subs::unformat_name($ch->{'name'});
			$datas->{'source_uuid'} = $returner->{'uuid'};
			$datas->{'quantity'} = $ch->{'value'};
			$datas->{'unit'} = $ch->{'unit'};
			my $md5 = md5_sum $datas->{'source_uuid'} . '-' . $app . '-' . $timestamp . '-' . $ch->{'name'};
			$datas->{'uuid'} = $datas->{'source_uuid'} . '-' . $md5,# || &subs::random_string_creator(92);
			my $c = &subs::controller_builder();
			&Manager::appointment_writer($c, $datas);
		}
	}

}

# A model/option session is a child appointment whose source_uuid names the
# parent session. The parent's own model/options list is what its details view
# reads, so the list follows the session: a start that attaches a child to a
# running parent adds the entry, and deleting the child leaves it. Only an entry
# that names the child's app is touched, so the other relationships that share
# source_uuid - a purchase to its transaction, the two legs of a transfer, a
# browser tab - are left alone.
sub source_model_option_add {
	my ($parent_uuid, $table, $entry) = @_;
	return unless ($parent_uuid // '') ne '' && ref $entry eq 'HASH';
	return unless $table eq 'model' || $table eq 'option';
	my $parent = &subs::db_select('appointments', undef, { uuid => $parent_uuid })->hashes->[0];
	return unless $parent && ($parent->{'uuid'} // '') ne '';
	if ($table eq 'model') {
		my $current = eval { return decode_json $parent->{'model'} } || {};
		return $parent if ($current->{'uuid'} // '') eq ($entry->{'uuid'} // '');
		&subs::db_update('appointments', { model => encode_json($entry) }, { uuid => $parent->{'uuid'}, app => $parent->{'app'} });
	}
	else {
		my $options = eval { return decode_json $parent->{'options'} } || [];
		return $parent if grep { ($_->{'uuid'} // '') eq ($entry->{'uuid'} // '') } @{$options};
		push @{$options}, $entry;
		&subs::db_update('appointments', { options => encode_json($options) }, { uuid => $parent->{'uuid'}, app => $parent->{'app'} });
	}
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $parent->{'app'}, $parent->{'uuid'})});
	return $parent;
}

sub source_model_option_remove {
	my ($parent_uuid, $child_app, $child_uuid, $child_type) = @_;
	return unless ($parent_uuid // '') ne '' && ($child_app // '') ne '';
	my $parent = &subs::db_select('appointments', undef, { uuid => $parent_uuid })->hashes->[0];
	return unless $parent && ($parent->{'uuid'} // '') ne '';
	# A child of another kind can share the parent's source_uuid and its app name
	# (a purchase whose item is also one of the transaction's models). Only a
	# session child, or one carrying the parent's own type, is a model/option.
	my $child_session = ($child_type // '') =~ /^(?:start|record|usual|add|stop|cancel)$/;
	return $parent unless $child_session || ($child_type // '') eq ($parent->{'type'} // '');
	# A second live child of the same app still holds the entry in the parent's list.
	my $live = &subs::db_query("select uuid from appointments where source_uuid = ? and app = ? and type not in ('stop','cancel') and uuid != ? limit 1",
		$parent_uuid, $child_app, ($child_uuid // ''))->hash;
	return $parent if $live && $live->{'uuid'};
	my $model = eval { return decode_json $parent->{'model'} } || {};
	my $options = eval { return decode_json $parent->{'options'} } || [];
	my $write = {};
	$write->{'model'} = undef if ($model->{'name'} // '') eq $child_app;
	my @kept = grep { ($_->{'name'} // '') ne $child_app } @{$options};
	$write->{'options'} = encode_json(\@kept) if scalar @kept != scalar @{$options};
	return $parent unless keys %{$write};
	&subs::db_update('appointments', $write, { uuid => $parent->{'uuid'}, app => $parent->{'app'} });
	&Websocket::send('tab', { console => &Websocket::console_command('appointmentDetailGrabber', $parent->{'app'}, $parent->{'uuid'})});
	return $parent;
}

sub log_writer {
	my $data = shift;
	my $log_data;
	my $timestamp = &subs::rightNow();
	if ( eval { @{$data} } ) {
		$log_data = Dumper $data;
	}
	elsif ( eval { %{$data} } ) {
		$log_data = Dumper $data;
	}
	else {
		$log_data = $data;
	}
	my $settings = &subs::settings_grabber({ app => 'terminal' });

	$settings->{'log'} = eval { return decode_json $settings->{'log'} } || [];
	splice @{$settings->{'log'}}, 30;
	my $uuid = &subs::random_string_creator(10);
	my $logg = { timestamp => $timestamp, 'msg' => $log_data, uuid => $uuid };
	push @{$settings->{'log'}}, $logg;

	my $sl = encode_json $settings->{'log'};
	&subs::setting_setter({ app => 'terminal', setting => 'log', value => $sl });
	my $hostname = &subs::machine_hostname();
	&Websocket::send('server', { view => 'log', console => $logg, error => $uuid, whoami => ($ENV{'USER'} || ''), hostname => $hostname });
	return $data;
}

# The human version shown in the System view (and available to the peer
# handshake). Bumped per commit by scripts/version_bump.pl; stored in ./VERSION.
sub jawn_version {
	return $jawn_version_cache if $jawn_version_cache;
	my $v = eval { read_file('./VERSION') } || '';
	$v =~ s/\s+$//;
	$v = '0.0.0' unless $v =~ /\d/;
	return $jawn_version_cache = $v;
}

# A bump rewrites ./VERSION under a live process; whatever cached the old number
# (the Coding agent's commit subject reads it) must be told to forget it.
sub jawn_version_forget { undef $jawn_version_cache; }

sub code_revision {
	return $code_revision_cache if $code_revision_cache;
	my @files;
	# The fingerprint is grouped as well as whole: a connected browser reads the
	# parts and asks what changed - a script (it must reload), a stylesheet (it
	# can point the link at the new build live), a template (re-render the open
	# windows), the shell or the server (reload / nothing) - before deciding how
	# to update itself. (See jawnosRevisionArrived in websocket.js.)
	my %part_canon = ( js => '', css => '', views => '', shell => '', server => '' );
	# Directories that are not the code this process runs. A worktree holds a
	# second copy of the tree, so an agent's edit there used to move the
	# revision a connected tab follows (a re-render, or a reload) and made
	# every fresh worker read tens of megabytes it never serves. Firmware
	# builds, staged releases and runtime state are the same kind of thing.
	my $not_running = qr{(?:^|/)(?:\.git|\.worktrees|node_modules|\.pio|build|releases|\.shots|jawnos-test-[^/]+)(?:/|$)};
	find({ no_chdir => 1, wanted => sub {
		my $n = $File::Find::name;
		return unless -f $n;
		return if $n =~ $not_running;
		push @files, $n if $n =~ /\.(pl|pm|ep|js|css)$/ || $n =~ m{(^|/)jawn$};
	} }, '.');
	@files = sort @files;
	my $canon = '';
	foreach my $f ( @files ) {
		my $c = eval { read_file($f) };
		my $line = $f . ':' . md5_sum(defined $c ? $c : '') . "\n";
		$canon .= $line;
		my $part = 'server';
		$part = 'js' if $f =~ /\.js$/;
		$part = 'css' if $f =~ /\.css$/;
		$part = 'views' if $f =~ /\.ep$/;
		# the shell frames every page at once: it cannot be rebuilt under a live tab
		$part = 'shell' if $f =~ m{(^|/)manager\.html\.ep$} || $f =~ m{(^|/)templates/layouts/};
		$part_canon{$part} .= $line;
	}
	my $fingerprint = md5_sum($canon);
	my ($commit,$branch,$dirty) = ('','',0);
	if (-e '.git') {
		$commit = `git rev-parse HEAD 2>/dev/null`; chomp $commit;
		$branch = `git rev-parse --abbrev-ref HEAD 2>/dev/null`; chomp $branch;
		# untracked files are not what the app runs (and the auto-update watcher
		# ignores them too), so `dirty` means tracked files were modified
		$dirty = 1 if (`git status --porcelain --untracked-files=no 2>/dev/null` =~ /\S/);
	}
	my $hostname = &subs::machine_hostname();
	$code_revision_cache = {
		fingerprint => $fingerprint,
		commit => $commit,
		branch => $branch,
		dirty => $dirty,
		files => scalar @files,
		hostname => $hostname,
		signatorial => &subs::signatorial_designer(),
		parts => { map { $_ => md5_sum($part_canon{$_}) } sort keys %part_canon },
	};
	return $code_revision_cache;
}

# A money move is a warehouse row. Every transaction with an account is written
# to the warehouse as it is recorded - the same fields under the same names, so
# the budget can read the ledger without knowing it moved - and the row is keyed
# by the source transaction's uuid, so a re-write or a backfill cannot double it.
# kind='money' marks it; type and movement keep what the transaction was.
# (Lives here, not in Manager.pl, so the boot process can run backfills.)
sub warehouse_money_mirror {
	my $row = shift;
	return unless $row && $row->{'uuid'};
	my $type = $row->{'type'} || '';
	# Only the transaction is a money move. A purchase row is the item and vendor
	# breakdown of that transaction and carries the same account and total, so
	# mirroring it as well counted one payment two or three times (a payment with
	# a vendor row and an item row wrote three). Transfers are type 'transaction'
	# too, so both legs still mirror. The old purchases' ledger rows are removed by
	# the money_ledger_transaction_rows backfill.
	return unless $type eq 'transaction';
	return unless $row->{'account'} && $row->{'account'} ne '';
	# an inventory row is a balance anchor, not a move; it already has its own
	# warehouse row (kind inventory)
	return if ($row->{'movement'} || '') eq 'inventory';
	my $exists = &subs::db_query('select uuid from warehouse where kind=? and uuid=? limit 1', 'money', $row->{'uuid'})->hashes->[0];
	return if $exists;
	my $movement = $row->{'movement'};
	$movement = 'expense' if (!defined $movement || $movement eq '') && $type eq 'purchase';
	&subs::db_insert('warehouse', {
		kind => 'money',
		type => $type,
		movement => $movement,
		app => $row->{'app'},
		account => $row->{'account'},
		project => $row->{'project'},
		item => $row->{'item'},
		model => $row->{'model'},
		quantity => $row->{'quantity'},
		unit => $row->{'unit'},
		amount => $row->{'amount'},
		tax => $row->{'tax'},
		aux => $row->{'aux'},
		total => $row->{'total'},
		duration => $row->{'duration'},
		vendor => $row->{'vendor'},
		manufacturer => $row->{'manufacturer'},
		currency => $row->{'currency'},
		notes => $row->{'notes'},
		state => $row->{'state'},
		warranty => $row->{'warranty'},
		place => $row->{'place'},
		data => $row->{'data'},
		uuid => $row->{'uuid'},
		app_uuid => $row->{'uuid'},
		source_uuid => $row->{'source_uuid'},
		timestamp => $row->{'timestamp'},
		server_time => &subs::rightNow(),
	});
}

sub accounting_account_ensure {
	my ($code,$name,$type,$normal,$app) = @_;
	my $row = &db_query('select code from ledger_accounts where code=?', $code)->hashes->[0];
	return $code if $row;
	&db_insert('ledger_accounts', {
		code => $code, name => $name, type => $type, normal => $normal,
		app => ($app // ''), active => 'yes', server_time => &rightNow()
	});
	return $code;
}

sub accounting_bank_account {
	my $account = shift || '';
	return $accounting_account_cache{"asset\0$account"} if defined $accounting_account_cache{"asset\0$account"};
	# a payable is a liability, not a place money sits
	if ($account eq 'accounts_payable') {
		return $accounting_account_cache{"asset\0$account"} = &accounting_account_ensure(2000, 'Accounts Payable', 'liability', 'credit', '');
	}
	my $row = &db_query("select code from ledger_accounts where app=? and type='asset' and cast(code as integer) between 1000 and 1099 limit 1", $account)->hashes->[0];
	return $accounting_account_cache{"asset\0$account"} = $row->{'code'} if $row;
	my $max = (&db_query("select coalesce(max(cast(code as integer)),999) as m from ledger_accounts where type='asset' and cast(code as integer) between 1000 and 1099")->hashes->[0]->{'m'} || 0) + 0;
	my $code = $max >= 1000 ? $max + 10 : 1000;
	$code = 1090 if $code > 1090;
	return $accounting_account_cache{"asset\0$account"} = &accounting_account_ensure($code, &format_name($account), 'asset', 'debit', $account);
}

sub accounting_app_account {
	my ($app,$type) = @_;
	$app = 'unknown' unless defined $app && length $app;
	$type = ($type || '') eq 'income' ? 'income' : 'expense';
	return $accounting_account_cache{"$type\0$app"} if defined $accounting_account_cache{"$type\0$app"};
	my $row = &db_query('select code from ledger_accounts where app=? and type=? limit 1', $app, $type)->hashes->[0];
	return $accounting_account_cache{"$type\0$app"} = $row->{'code'} if $row;
	my $base = $type eq 'income' ? 4000 : 5000;
	my $max = (&db_query('select coalesce(max(cast(code as integer)),?) as m from ledger_accounts where type=? and cast(code as integer) between ? and ?', $base - 1, $type, $base, $base + 999)->hashes->[0]->{'m'} || 0) + 0;
	my $code = $max + 1;
	return $accounting_account_cache{"$type\0$app"} = &accounting_account_ensure($code, &format_name($app), $type, ($type eq 'income' ? 'credit' : 'debit'), $app);
}

sub accounting_journal_add {
	my ($entry,$timestamp,$lines,$meta) = @_;
	my $n = 0;
	foreach my $line ( @{$lines} ) {
		my ($code,$debit,$credit) = @{$line};
		$debit = defined $debit ? $debit + 0 : 0;
		$credit = defined $credit ? $credit + 0 : 0;
		next if abs($debit) < 0.0001 && abs($credit) < 0.0001;
		$n++;
		&db_insert('journal', {
			uuid => $entry . '-' . $n,
			entry_uuid => $entry,
			timestamp => $timestamp,
			account_code => $code,
			debit => sprintf('%.4f', $debit),
			credit => sprintf('%.4f', $credit),
			currency => ($meta->{'currency'} // ''),
			memo => substr(($meta->{'memo'} // ''), 0, 490),
			source_uuid => ($meta->{'source_uuid'} // ''),
			source_kind => ($meta->{'source_kind'} // ''),
			app => ($meta->{'app'} // ''),
			account => ($meta->{'account'} // ''),
			server_time => &rightNow()
		});
	}
	return $n;
}

1;
