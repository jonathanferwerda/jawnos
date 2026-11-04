package Manager;

# Manager helpers, part 21 of 37. Moved out of Manager.pl so a
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

sub people_crest_install {
	my ($c, $src) = @_;
	my $suds = &subs::session_suds($c);
	return { ok => 0, error => 'the house key is not available' } unless $suds;
	my $device = &subs::device_setter();
	my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $device }) || 'Pictures';
	my $dir = &subs::home($folder) . '/me';
	unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) }; }
	my $old = &subs::crest_record_read();
	my $version = (($old->{'version'} || 0) + 1);
	my $color_png = "$dir/crest.v$version.color.png";
	my $ref_png = "$dir/crest.v$version.ref.png";
	my $converted = &subs::image_bridge_convert($src, $color_png, format => 'png', quality => 100);
	my $rc = defined $converted ? 0 : system('magick', $src, $color_png);
	unless ($rc == 0 && -e $color_png && -s $color_png > 0) {
		unlink $color_png;
		return { ok => 0, error => 'the picture could not be read' };
	}
	unless (&subs::crest_normalize_image($color_png, $ref_png)) {
		unlink $color_png; unlink $ref_png;
		return { ok => 0, error => 'the picture could not be normalized' };
	}
	my $dhash = &subs::crest_dhash($ref_png);
	my $sha = &subs::crest_sha256_file($ref_png);
	unless (defined $dhash && defined $sha) {
		unlink $color_png; unlink $ref_png;
		return { ok => 0, error => 'the picture could not be hashed' };
	}
	my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard', device => $device }) || 'aes-256-ctr';
	my $color_name = "crest.v$version.color.png.enc";
	my $ref_name = "crest.v$version.ref.png.enc";
	my $color_enc = "$dir/$color_name";
	my $ref_enc = "$dir/$ref_name";
	unless (&subs::openssl_file_crypt('e', $standard, $suds, $color_png, $color_enc, 0, 1)
		&& &subs::openssl_file_crypt('e', $standard, $suds, $ref_png, $ref_enc, 0, 1)) {
		unlink $color_png; unlink $ref_png; unlink $color_enc; unlink $ref_enc;
		return { ok => 0, error => 'the picture could not be sealed' };
	}
	unlink $color_png; unlink $ref_png;
	my $priv = &subs::crest_key_read($suds);
	my $pub;
	if (defined $priv && length $priv == 32) {
		$pub = &subs::crest_public_from_private($priv);
	}
	elsif ($old->{'uuid'}) {
		# A record already names a house key. Minting a new one here would turn
		# the house into a stranger without anyone asking; refuse instead.
		return { ok => 0, error => 'the crest key could not be opened; the house identity was left unchanged' };
	}
	else {
		($pub, $priv) = &subs::crest_key_generate();
		unless (defined $pub && defined $priv) {
			return { ok => 0, error => 'the crest key could not be made' };
		}
		unless (&subs::crest_key_write($suds, $priv)) {
			return { ok => 0, error => 'the crest key could not be stored' };
		}
	}
	my $record = {
		uuid => $old->{'uuid'} || &subs::random_string_creator(32),
		house_id => $old->{'house_id'} || &subs::random_string_creator(24),
		name => $old->{'name'} || &subs::crest_house_name_read(),
		pubkey => encode_base64($pub, ''),
		fingerprint => &subs::crest_fingerprint($pub),
		dhash => $dhash,
		sha256 => $sha,
		image => $color_name,
		reference => $ref_name,
		version => $version,
		issued => $old->{'issued'} || &subs::rightNow(),
		server_time => &subs::rightNow(),
		device => $device,
		origin => &subs::crest_origin(),
		members => $old->{'members'} || [ { signatorial => &subs::signatorial_designer(), device => $device } ],
	};
	my $signed = &subs::crest_sign_record($record, $priv);
	unless ($signed && $signed->{'sig'}) {
		return { ok => 0, error => 'the crest could not be signed' };
	}
	unless (&subs::crest_record_write($signed)) {
		return { ok => 0, error => 'the crest could not be saved' };
	}
	my $sync_image = &subs::crest_image_data_uri($color_enc, $suds, $standard, 512);
	&subs::crest_image_sync_store($signed, $sync_image) if defined $sync_image;
	return { ok => 1, crest => $signed };
}

sub construct_crest_install {
	my ($c, $src, $app) = @_;
	my $sing = &people_construct_kind($app);
	return { ok => 0, error => 'no such construct' } unless $sing;
	my $suds = &subs::session_suds($c);
	return { ok => 0, error => 'the house key is not available' } unless $suds;
	my $priv = &subs::crest_key_read($suds);
	unless (defined $priv && length $priv == 32) {
		return { ok => 0, error => 'the house crest key is not available' };
	}
	my $house = &subs::crest_record_read();
	unless ($house->{'uuid'} && $house->{'pubkey'}) {
		return { ok => 0, error => 'make the house crest first' };
	}
	my $device = &subs::device_setter();
	my $folder = &subs::setting_grabber({ app => 'misc', setting => 'photo_location', device => $device }) || 'Pictures';
	my $dir = &subs::home($folder) . '/me';
	unless (-d $dir) { eval { require File::Path; File::Path::make_path($dir) }; }
	my $old = &subs::construct_crest_record_read($app);
	my $version = (($old->{'version'} || 0) + 1);
	my $uuid = $old->{'uuid'} || &subs::random_string_creator(32);
	my $color_png = "$dir/crest-$uuid.v$version.color.png";
	my $ref_png = "$dir/crest-$uuid.v$version.ref.png";
	my $converted = &subs::image_bridge_convert($src, $color_png, format => 'png', quality => 100);
	my $rc = defined $converted ? 0 : system('magick', $src, $color_png);
	unless ($rc == 0 && -e $color_png && -s $color_png > 0) {
		unlink $color_png;
		return { ok => 0, error => 'the picture could not be read' };
	}
	unless (&subs::crest_normalize_image($color_png, $ref_png)) {
		unlink $color_png; unlink $ref_png;
		return { ok => 0, error => 'the picture could not be normalized' };
	}
	my $dhash = &subs::crest_dhash($ref_png);
	my $sha = &subs::crest_sha256_file($ref_png);
	unless (defined $dhash && defined $sha) {
		unlink $color_png; unlink $ref_png;
		return { ok => 0, error => 'the picture could not be hashed' };
	}
	my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard', device => $device }) || 'aes-256-ctr';
	my $color_name = "crest-$uuid.v$version.color.png.enc";
	my $ref_name = "crest-$uuid.v$version.ref.png.enc";
	my $color_enc = "$dir/$color_name";
	my $ref_enc = "$dir/$ref_name";
	unless (&subs::openssl_file_crypt('e', $standard, $suds, $color_png, $color_enc, 0, 1)
		&& &subs::openssl_file_crypt('e', $standard, $suds, $ref_png, $ref_enc, 0, 1)) {
		unlink $color_png; unlink $ref_png; unlink $color_enc; unlink $ref_enc;
		return { ok => 0, error => 'the picture could not be sealed' };
	}
	unlink $color_png; unlink $ref_png;
	my $record = {
		uuid => $uuid,
		construct => $app,
		construct_type => $sing,
		name => $old->{'name'} || &subs::format_name($app),
		pubkey => $house->{'pubkey'},
		house_uuid => $house->{'uuid'},
		house_pubkey => $house->{'pubkey'},
		dhash => $dhash,
		sha256 => $sha,
		image => $color_name,
		reference => $ref_name,
		version => $version,
		issued => $old->{'issued'} || &subs::rightNow(),
		server_time => &subs::rightNow(),
		device => $device,
		origin => &subs::crest_origin(),
	};
	$record->{'fingerprint'} = &subs::construct_crest_fingerprint($record);
	my $signed = &subs::crest_sign_record($record, $priv);
	unless ($signed && $signed->{'sig'}) {
		return { ok => 0, error => 'the crest could not be signed' };
	}
	unless (&subs::construct_crest_record_write($app, $signed)) {
		return { ok => 0, error => 'the crest could not be saved' };
	}
	my $sync_image = &subs::crest_image_data_uri($color_enc, $suds, $standard, 512);
	&subs::construct_crest_image_sync_store($app, $signed, $sync_image) if defined $sync_image;
	return { ok => 1, crest => $signed, app => $app };
}

sub people_crest_upload_file {
	my ($c) = @_;
	my @uploads = @{ $c->req->uploads || [] };
	return (undef, 'no picture') unless @uploads;
	require File::Temp;
	my ($fh, $path) = File::Temp::tempfile('jawnos-crest-XXXXXX', TMPDIR => 1, UNLINK => 0, SUFFIX => '.img');
	return (undef, 'no temporary file') unless $fh && $path;
	binmode $fh;
	print $fh $uploads[0]->asset->slurp;
	close $fh;
	return ($path, undef);
}

sub people_crest_card {
	my ($c, $construct_app) = @_;
	my $suds = &subs::session_suds($c);
	my $construct = defined $construct_app && length $construct_app ? $construct_app : '';
	my $crest = $construct ? &subs::construct_crest_record_read($construct) : &subs::crest_record_read();
	return undef unless $crest->{'uuid'} && $suds;
	my $device = $crest->{'device'} || &subs::device_setter();
	my $standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard', device => $device }) || 'aes-256-ctr';
	my $file = &subs::crest_image_file($crest, 'image');
	my $image = $file ? &subs::crest_image_data_uri($file, $suds, $standard, 512) : undef;
	my @vouches;
	unless ($construct) {
		my $peers = &subs::crest_peer_list_read();
		my %seen_vouch;
		foreach my $vouch ( @{ &subs::crest_incoming_vouch_list_read() } ) {
			next unless ref $vouch eq 'HASH' && &subs::crest_vouch_verify($vouch);
			next unless ($vouch->{'to_uuid'} || '') eq ($crest->{'uuid'} || '');
			next unless ($vouch->{'to_pubkey'} || '') eq ($crest->{'pubkey'} || '');
			next if $seen_vouch{ $vouch->{'sig'} || '' }++;
			push @vouches, $vouch;
		}
		foreach my $entry ( @{$peers} ) {
			next unless ref $entry eq 'HASH' && ref $entry->{'vouch'} eq 'HASH';
			my $vouch = $entry->{'vouch'};
			next unless &subs::crest_vouch_verify($vouch);
			next unless ($vouch->{'from_uuid'} || '') eq ($crest->{'uuid'} || '');
			next if $seen_vouch{ $vouch->{'sig'} || '' }++;
			push @vouches, $vouch;
		}
	}
	my $card = { format => 'jawnos-crest-card', card_version => 1, crest => $crest, vouches => \@vouches };
	$card->{'image'} = $image if defined $image;
	my $config = &subs::config_reader();
	# The card is handed to another house, so name the address they can reach:
	# a loopback domain on a laptop would point them at their own machine.
	my $origin = &subs::crest_origin();
	my $host = $config->{'domain'} || $c->req->url->base->host;
	my $port = $config->{'port'} || 3000;
	my $working = $config->{'working_port'} || $port;
	$origin ||= "https://$host:$working";
	$card->{'endpoints'} = {
		home => $origin . '/',
		store => $origin . '/store',
		manager => $origin . '/manager',
		signatorial => &subs::signatorial_designer(),
	};
	# The machines that back the crest, each with its own signed statement. The
	# crest record is the signed part of the card; a recipient can check each
	# statement against the key it carries. Cosignatures back the house crest,
	# not a construct's.
	$card->{'cosignatures'} = &subs::crest_member_cosig_list($crest, { include_local => 1 }) unless $construct;
	return $card;
}

sub people_crest_import_code {
	my ($c, $code) = @_;
	return { ok => 0, error => 'citizen only' } unless (($c->session('privilege') || '') eq 'citizen');
	my $record = &subs::crest_code_parse($code);
	return { ok => 0, error => 'the crest code is not readable' } unless ref $record eq 'HASH';
	return { ok => 0, error => 'the crest record does not verify' } unless &subs::crest_verify_record($record);
	# A construct crest names a construct, not a house. A tag for one of this
	# house's own constructs opens it; another house's construct is not a house
	# crest and there is nothing here to import it into.
	if (length($record->{'construct'} || '')) {
		my $local = &construct_crest_find_by_uuid($record->{'uuid'});
		if ($local) {
			return {
				ok => 1,
				crest => $record,
				construct_app => $local->{'app'},
				construct_name => $record->{'name'} || $local->{'crest'}->{'name'} || '',
				known => 1,
			};
		}
		my $imported = &foreign_construct_import($record);
		return { ok => 0, error => $imported->{'error'} || 'the construct could not be imported' }
			unless $imported->{'ok'};
		return {
			ok => 1,
			crest => $record,
			construct_app => $imported->{'app'},
			construct_name => $imported->{'name'} || $record->{'name'} || '',
			house_name => $imported->{'house_name'},
			foreign => 1,
		};
	}
	my $own = &subs::crest_record_read();
	return { ok => 0, error => 'that is this house\'s own crest' } if $own->{'uuid'} && $record->{'uuid'} && $own->{'uuid'} eq $record->{'uuid'};
	my $existing = &subs::crest_peer_find($record->{'uuid'});
	my $entry = {
		crest => $record,
		device => &subs::device_setter(),
		imported_at => &subs::rightNow(),
		status => 'imported',
		vouches => [],
	};
	my $known = $existing ? 1 : 0;
	if ($existing) {
		$entry->{'imported_at'} = $existing->{'imported_at'} || $entry->{'imported_at'};
		$entry->{'vouch'} = $existing->{'vouch'} if ref $existing->{'vouch'} eq 'HASH';
		$entry->{'met_at'} = $existing->{'met_at'} if defined $existing->{'met_at'};
		$entry->{'status'} = $existing->{'status'} if (($existing->{'status'} || '') eq 'met');
		$entry->{'image_file'} = $existing->{'image_file'} if $existing->{'image_file'};
		$entry->{'image_data'} = $existing->{'image_data'} if defined $existing->{'image_data'};
		$entry->{'endpoints'} = $existing->{'endpoints'} if ref $existing->{'endpoints'} eq 'HASH';
	}
	return { ok => 0, error => 'the crest could not be stored' } unless &subs::crest_peer_upsert($entry);
	return { ok => 1, crest => $record, entry => $entry, known => $known };
}

sub app_draft_uuid($app, $field) {
	my $name = $app . '_' . $field;
	if (length($name) > 150) {
		require Digest::MD5;
		utf8::encode($name) if utf8::is_utf8($name);
		$name = Digest::MD5::md5_hex($name);
	}
	return 'appdraft_' . $name;
}

sub notification_grabber($data) {

	my $timestamp = &subs::rightNow();
	my @notifications;
	my $settings = &subs::settings_grabber({ app => 'notifications', benign => 1 });
	my $notifications = { titles => [], apps => [], settings => $settings };
	my ($db,$database,$sql) = &subs::database_grabber();
	my $q = &subs::db_query('select * from notifications order by timestamp DESC LIMIT 100');
	my $more_notifications = $q->hashes;
	if ($device eq 'mobile') {
		# The listener answers only after the person grants notification access;
		# without the grant there is nothing to read, so the list stays empty.
		my $bridge_nl = &subs::device_call('notification.list');
		my $notifications = ($bridge_nl && ref $bridge_nl->{'notifications'} eq 'ARRAY')
			? $bridge_nl->{'notifications'}
			: [];
		my @fresh;
		foreach my $n ( @{$notifications} ) {
			if ($n->{'title'} && !grep { $_->{'id'} eq $n->{'id'} } @{$more_notifications}) {
				my $ts = &subs::ago_calc($n->{'when'},$timestamp);
				&subs::db_insert('notifications', {
					id => $n->{'id'},
					app => &subs::unformat_name($n->{'title'}),
					timestamp => $ts,
					tag => $n->{'tag'},
					message => $n->{'content'},
					title => $n->{'title'},
					key => $n->{'key'},
					image => "/images/make believe/face.png",
					uuid => &subs::random_string_creator(20)
				});
				push @fresh, { key => $n->{'key'}, message => $n->{'content'}, title => $n->{'title'}, timestamp => $ts };
			}
		}
		# a payment the phone has announced is booked as it lands, not when a
		# screen is opened later
		&notification_payable_autobook(\@fresh) if scalar @fresh;
	}

	$q = &subs::db_query('select * from notifications order by timestamp DESC');
	$more_notifications = $q->hashes;

	foreach my $m ( @{$more_notifications}) {
		push @{$notifications->{'apps'}}, $m->{'app'} unless grep { $m->{'app'} eq $_ } @{$notifications->{'apps'}};
	}

	if ($settings->{'filter'} && $settings->{'filter'} ne '' && $settings->{'filter'} ne 'all') {
		@{$more_notifications} = grep { $_->{'app'} eq $settings->{'filter'} } @{$more_notifications};
	}
	if ($settings->{'search'} && $settings->{'search'} ne '') {
		my $search = $settings->{'search'};
		@{$more_notifications} = grep { $_->{'app'} =~ /\Q$search/gi ||  $_->{'message'} =~ /\Q$search/gi } @{$more_notifications};
	}
	if ($data->{'scroll'} eq 'down') {
		my @now_notifications = splice @{$more_notifications}, $data->{'position'} * 100;
		@{$more_notifications} = @now_notifications;

	}
	unless ($data->{'delete'}) {
		splice @{$more_notifications}, 100;
	}
	my $content;

	my $c = &subs::controller_builder();
	foreach my $m ( @{$more_notifications}) {
		$notifications->{'content'} .= $c->render_to_string(
			n => $m,
			template => 'notification',
		);
	}
	$notifications->{'list'} = $more_notifications;
	return $notifications;
}

sub travel_speed_calculator($data) {
	my $distance = $data->{'distance'};
	my $start = $data->{'start'};
	my $end = $data->{'end'};
	my $time_diff = $end - $start;
	if ($start > $end) {
		$time_diff = $start - $end;
	}
	my $speed;
	if ($distance > 0 && $time_diff != 0) {
		$speed = sprintf("%.2f", $distance / (( abs ($time_diff) / 1000) / 3600));
	}

	return $speed;
}

sub centre_view_grabber($data) {
	my $c = $data->{'c'} || &subs::controller_builder();
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $jp_report = $data->{'jp_report'} || [];
	$app = &subs::unformat_name($app);
	my $server_time = &subs::rightNow();

	if ($app) {
		my $appointments = [ $app ];
		# The wrapper is cached by template signature, but what it may draw also
		# depends on this screen's private grant and the app's own level. Put both
		# in the key, so a wrapper built while private was open is not served after
		# the grant closes (and one built before it opens is not reused).
		my $private_open = (&subs::private_reachable_now() && &subs::private_revealed()) ? 1 : 0;
		my $signature = &subs::render_signature() . '|vis:' . &subs::app_visibility_value($app) . '|open:' . $private_open;
		# A cached wrapper belongs to a window that was allowed when it was built.
		# Private is a lock, so a hidden app never reads the cache: the request
		# falls through to log_reader, which draws the denial for this moment.
		if (!&subs::app_hidden_now($app)) {
			if (my $cache_data = &subs::cache_get({ context => 'template', app => $app })) {
				if (($cache_data->{'signature'} || '') eq $signature && ($data->{'cached'} ne 'no' || $cache_data->{'timestamp'} + 200 > $server_time)) {
					my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $cache_data->{'contents'} }, $timestamp);
					return $window;
				}
			}
		}
		my $string;
		my $appointment = &subs::db_query('select app,server_time,timestamp from appointments where app=? LIMIT 1',$app);
		# the header worker hands its appointments over so this render does not
		# fetch the same set again
		my $appts = $data->{'appts'} || &log_reader({ app => $app, view => 'centre_view'  });
		if (!$appts->{$app}) {
			# A private app the person may unlock here (a private place with no
			# enemy) gets the same fingerprint padlock the media apps carry, under
			# the denial picture. Outside such a place there is nothing to unlock,
			# so the plain denial stays.
			my $private_denial = (&subs::app_private_now($app) && &subs::private_reachable_now()) ? 1 : 0;
			# The denial template reads these from the stash (render_to_string args
			# are template locals), so set them here before it is drawn.
			$c->stash(
				private_denial => $private_denial,
				denial_app => $app,
				denial_timestamp => $timestamp,
			);
			$string = $c->render_to_string(
				template => 'denial',
				private_denial => $private_denial,
				denial_app => $app,
				denial_timestamp => $timestamp,
			);
			$app = 'Denied';
		} else {
			# a header-only log_reader skipped the pos/mab markers; the wrapper's
			# details form needs them, so build them once here
			my $markers = (ref $appts->{'__specs'} eq 'HASH') ? ($appts->{'__specs'}->{'markers'} || '') : '';
			&appts_marker_builder($appts) if $markers ne 'yes';
			$appts->{$app}->{'setting'}->{'app_measures'} = eval { return decode_json $appts->{$app}->{'setting'}->{'app_measures'} } || {};
			my $header = $data->{'header'};
			unless ($header || $data->{'resetting'} eq 'yes' || $data->{'cached'} eq 'no') {
				my $hc = &subs::cache_get({ app => $app, context => 'header' });
				$header = $hc->{'header'} if ($hc->{'signature'} || '') eq $signature;
			}
			unless ($header) {
				$header = &subs::appt_header_printer({ appts => $appts, app => $app, timestamp => $timestamp, source => 'centre_view_grabber', broadcast => (($data->{'source'} // '') eq 'ws' ? 'no' : 'yes') });
			}
			$string = $c->render_to_string(
				template => 'appointment_wrapper',
				appts => $appts,
				appointments => $appointments,
				header => $header,
				timestamp => $timestamp,
				device => $device,
				from => 'centre_view',
				config => &subs::config_reader(),
				measures => $gb::measures,
				server_time => $server_time,
				jp_report => $jp_report
			);
		}
		my $window = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => $app, contents => $string, source => 'centre_view_grabber', settings => $appts->{$app}->{'setting'} }, $timestamp);
		# One write against this process's own cached database handle, so the
		# template goes into the cache here instead of in a forked child - the fork
		# was the entire cost of the write. The eval keeps a failed write from
		# taking the window down with it, as the child's own eval used to.
		my $template_cached = eval { &subs::cache_set({app => $app, context => 'template', warranty => '-10d' }, { contents => $string, settings => $window->{'settings'}, signature => $signature }) };
		if ($@) {
			eval { &subs::log_writer('centre view cache set failed: ' . ($@ =~ s/\s+/ /gr)) };
		}
		return $window->{'window'};
	}
}

sub search_index_setting($set, $device) {
	return undef unless ref $set eq 'HASH' && scalar keys %{$set};
	return (defined $device && exists $set->{$device}) ? $set->{$device}
		: (exists $set->{'all'} ? $set->{'all'} : (values %{$set})[0]);
}

sub search_index_signature {
	my $s = &subs::db_query("select count(*) as n, max(cast(server_time as integer)) as t from settings where setting in ('pos','visible','main_image','icon_set','manager_background_colour')")->hashes->[0] || {};
	my $g = &subs::db_query('select count(*) as n, max(cast(server_time as integer)) as t from appointments where account = ?', 'gallery')->hashes->[0] || {};
	return join ':', ($s->{'n'} // 0), ($s->{'t'} // 0), ($g->{'n'} // 0), ($g->{'t'} // 0);
}

sub search_index_icon($data) {
	my $app = $data->{'app'};
	my $main_image = $data->{'main_image'} || '';
	if (length $main_image) {
		# the same rule the gallery and the icon use: an existing path as it
		# stands, a foreign one mapped onto this machine, or a data URI as-is
		my $src = &subs::main_image_src($main_image, $app);
		if (length $src) {
			# the setting's own stamp keeps a replaced picture from being read
			# back out of the browser's cache under the same path
			my $stamp = $data->{'stamp'} || '';
			$src .= '&v=' . $stamp if length $stamp && $src =~ m{\A/file_open\?};
			return $src;
		}
	}
	if ($gb::known_appts->{$app} && $gb::known_appts->{$app}->{'icon'}) {
		return &subs::icon_for($gb::known_appts->{$app}->{'icon'});
	}
	if (length($data->{'pos'} || '') && -e 'public/icons/pos/' . $data->{'pos'} . '.png') {
		return &subs::icon_for('/icons/pos/' . $data->{'pos'} . '.png');
	}
	return &subs::icon_for('/images/decipherable/gear.png');
}

sub search_app_matches($search) {
	$search = &subs::unformat_name($search || '');
	return [] unless length $search;
	my $like = '%' . $search . '%';
	my %seen;
	my @apps;
	my $push = sub {
		my ($app) = @_;
		return unless defined $app && length $app;
		return if $app =~ /^__/;
		return if $seen{$app}++;
		return if &help_app_hidden($app);
		push @apps, $app;
	};
	foreach my $row ( @{ &subs::db_query('select distinct app from appointments where app is not null and app != ? and app like ?', '', $like)->hashes || [] } ) {
		$push->($row->{'app'});
	}
	foreach my $row ( @{ &subs::db_query("select distinct app from settings where app is not null and app != '' and app like ? and setting in ('visible','main_image')", $like)->hashes || [] } ) {
		$push->($row->{'app'});
	}
	foreach my $app ( keys %{$gb::known_appts} ) {
		$push->($app) if $app =~ /\Q$search\E/i;
	}
	my $plain = sub { my $s = lc($_[0] // ''); $s =~ s/_/ /g; return $s };
	my $needle = $plain->($search);
	@apps = sort {
		my $na = $plain->($a); my $nb = $plain->($b);
		my $ra = ($na eq $needle) ? 0 : (index($na, $needle) == 0 ? 1 : 2);
		my $rb = ($nb eq $needle) ? 0 : (index($nb, $needle) == 0 ? 1 : 2);
		$ra <=> $rb || $na cmp $nb
	} @apps;
	splice @apps, 40 if scalar @apps > 40;
	my @out;
	foreach my $app ( @apps ) {
		push @out, {
			app => $app,
			name => &subs::format_name($app),
			icon => &search_index_icon({ app => $app })
		};
	}
	return \@out;
}

sub search_engine_state {
	my $raw = &subs::setting_grabber({ app => 'search', setting => 'engines', device => 'all' });
	my $state = eval { decode_json $raw } || {};
	$state->{'custom'} = [] unless ref $state->{'custom'} eq 'ARRAY';
	# no stored choice means the defaults; an empty list is the person turning
	# every engine off, which is a real choice and stays empty
	$state->{'enabled'} = [ @gb::search_default_engines ] unless ref $state->{'enabled'} eq 'ARRAY';
	return $state;
}

sub search_engine_all {
	my $state = &search_engine_state();
	my %enabled = map { $_ => 1 } @{ $state->{'enabled'} };
	my %custom = map { $_->{'id'} => 1 } grep { ref $_ eq 'HASH' } @{ $state->{'custom'} };
	my @out;
	foreach my $e ( @gb::search_engines ) {
		next if $custom{$e->{'id'}};
		my $group = &search_engine_group($e->{'group'});
		push @out, { %$e, group => $group, group_label => &subs::lang("search.group.$group"), enabled => $enabled{$e->{'id'}} ? 1 : 0, custom => 0 };
	}
	foreach my $e ( @{ $state->{'custom'} } ) {
		next unless ref $e eq 'HASH' && ($e->{'id'} // '') ne '';
		my $group = &search_engine_group($e->{'group'});
		push @out, { %$e, group => $group, group_label => &subs::lang("search.group.$group"), enabled => $enabled{$e->{'id'}} ? 1 : 0, custom => 1 };
	}
	return (\@out, $state);
}

sub search_engine_group($group) {
	return (defined $group && $group =~ /^(?:general|reference|media|shopping|news|custom)$/) ? $group : 'custom';
}

sub search_engine_save($state) {
	&subs::setting_setter({ app => 'search', setting => 'engines', value => encode_json($state), device => 'all' });
}

sub search_engine_url($engine, $q) {
	my $url = $engine->{'url'} // '';
	my $esc = url_escape($q);
	return $url =~ /\{q\}/ ? ($url =~ s/\{q\}/$esc/gr) : $url . $esc;
}

sub search_enabled_engines {
	my ($all) = &search_engine_all();
	return [ grep { $_->{'enabled'} } @{$all} ];
}

1;
