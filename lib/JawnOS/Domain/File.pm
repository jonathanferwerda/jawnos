package subs;

# File: extracted from subroutines.pl (package subs). Loaded on
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
use File::Type;
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

# The folder a location lands in under the archive root. A location's key is a
# setting name (video, rec); a person looking at the drive expects the words the
# folders use here (Videos, Recordings). An archive made before these names
# still reads: archive_location_folder keeps the old lower-case folder when it
# is the one that exists.
our %archive_folder_names;
our $config;
our $database;
our $device;
our $gb;
our %m;

# Remove a file after it has been sealed or converted. `shred -u` is the wear
# path on a desktop, but the Android runtime carries no shred, and the old
# backtick left BOTH the plaintext and the sealed copy on the phone. Fall back
# to unlink, which is all a flash filesystem can honour anyway.
sub secure_unlink {
	my ($path) = @_;
	return 0 unless defined $path && length $path;
	return 0 unless -e $path || -l $path;
	return 0 if -d $path;
	my $shred = `command -v shred 2>/dev/null`;
	system('shred', '-u', $path) if defined $shred && $shred =~ /\S/;
	unlink $path if -e $path || -l $path;
	return (-e $path || -l $path) ? 0 : 1;
}

sub file_encrypter {
	my $data = shift;

	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'} || &subs::rightNow();
	my $suds = $data->{'suds'} || &subs::suds_grabber();
	my $pre_server_time = &subs::ago_calc('1h', &subs::rightNow());
	my $file_db = &subs::db_query('select * from appointments where app=? and file != ? and (encryption_standard is null or server_time >= ?)', $app,'',$pre_server_time);
	my $filings = $file_db->hashes;
	my $server_time = &subs::rightNow();
	return unless &subs::setting_grabber({ app => $app, setting => 'enc' } ) eq 'on';
	my $success = 0;
	my $file_join;
	my $encryption_standard = &subs::setting_grabber({ app => 'misc', setting => 'encryption_standard' } ) || "aes-256-ctr";

	foreach my $filing ( @{$filings} ) {
		my $files = eval { return decode_json $filing->{'file'} } || [];
		if (eval { $files->{'f'} }) {
			$files = [ $files ];
		}
		foreach my $fi ( @{$files} ) {
			foreach my $file_type ( qw/f thumb preview/ ) {
				my $f = $fi->{$file_type};

				if (defined $f && length $f && -e $f && $f !~ /\.enc/gi) {

					my $path = &subs::terminal_name($f);
					my $enc_path = $path;
					my @enc_path = split '/', $enc_path;
					my @ext = split /\./, $enc_path[-1];
					my $ext = $ext[-1];
					my $original_filename = pop @enc_path;
					$enc_path = ( join '/', @enc_path ) . '/' . &subs::random_string_creator(20) . '.' . $ext . '.enc';
					my $secret = $suds;
					# first, store the encryption standard.

					&seal_file($path, $enc_path, $secret, $encryption_standard);
					&secure_unlink($path);
					$f = $enc_path;
					$fi->{$file_type} = $f;
					$fi->{'server_time'} = &subs::rightNow();
					$fi->{'uuid'} = &subs::random_string_creator(17) unless $fi->{'uuid'};
					if ($file_type eq 'f') {
						$fi->{'of'} = $original_filename;

						if ($fi->{'att'}) {
							my $att_file = &subs::db_select($fi->{'att'}, undef, { uuid => $fi->{'att_uuid'}, app => $app })->hashes->[0];

							my $atf = eval { return decode_json $att_file->{'file'} } || [];
							foreach my $af ( @{$atf} ) {
								if ($af->{'uuid'} eq $fi->{'uuid'}) {
									$af->{'f'} = $f;
									$af->{'server_time'} = &subs::rightNow();
									$af->{'of'} = $original_filename;
								}
							}
							my $jaf = encode_json $atf;
							&subs::db_update($fi->{'att'}, { file => $jaf, server_time => &subs::rightNow() }, { uuid => $att_file->{'uuid'}, app => $att_file->{'app'} });
						}
					}
					$success = 1;
				}
			}
		}
		$file_join = encode_json $files;
		if ($success == 1) {
			#&subs::db_query('update appointments set server_time = ?, file = ?, encryption_standard = ? where app= ? and uuid = ?',
			#	&subs::rightNow(), $file_join, $encryption_standard, $app, $filing->{'uuid'});
			&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $file_join, encryption_standard => $encryption_standard }, { app => $app, uuid => $filing->{'uuid'} });
			&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $filing->{'uuid'} .'\');'});
		}

	}
}

sub file_decrypter {
	my $data = shift;
	my $app = $data->{'app'};
	my $timestamp = $data->{'timestamp'};
	my $suds = $data->{'suds'};
	my $file_db = &subs::db_query('select * from appointments where app=? and file is not null', $app);
	my $filings = $file_db->hashes;
	my $success = 0;
	my $file_join;
	my $server_time = &subs::rightNow();
	# One credential list and one sniffer for the whole job, not a DB query and a
	# fresh File::Type per file.
	my @secrets;
	push @secrets, $suds if defined $suds && length $suds;
	my $passwords = &subs::db_query('select * from security where level != ? and level != ? order by server_time DESC','padlock','door');
	foreach my $p ( @{ $passwords->hashes } ) {
		my $secret = &subs::decrypter($suds, $p->{'credential'});
		push @secrets, $secret if defined $secret && length $secret;
	}
	my $inspect = sub {
		return &plaintext_verdict($_[0]);
	};
	foreach my $filing ( @{$filings} ) {
		my $files = eval { return decode_json $filing->{'file'} } || [];
		foreach my $fi ( @{$files} ) {
			foreach my $file_type ( qw/f thumb preview/ ) {
				my $f = $fi->{$file_type};
				if (defined $f && length $f && -e $f && $f =~ /\.enc/gi) {
					my $encryption_standard = $filing->{'encryption_standard'} || &setting_grabber({ app => 'misc', setting => 'encryption_standard' }) || 'aes-256-ctr';
					my $enc_path = &subs::terminal_name($f);


					my $path = $enc_path;
					if ($fi->{'of'}) {
						my @f = split '/', $path;
						pop @f;
						push @f, $fi->{'of'};
						$path = join '/', @f;
					}
					$path =~ s/\.enc$//gi;
					my $opened = &sealed_file_open($enc_path, \@secrets, [ $encryption_standard ], 0, $inspect);
					if ($opened) {
						&write_file($path, $opened->{'data'});
						$f = $path;
						&secure_unlink($enc_path);
						$success = 1;
					}



					$fi->{$file_type} = $f;
					$fi->{'server_time'} = &subs::rightNow();
					$fi->{'uuid'} = &subs::random_string_creator(7) unless $fi->{'uuid'};

					if ($fi->{'att'} && $file_type eq 'f') {
						my $att_file = &subs::db_select($fi->{'att'}, undef, { uuid => $fi->{'att_uuid'}, app => $app })->hashes->[0];
						my $atf = eval { return decode_json $att_file->{'file'} } || [];
						foreach my $af ( @{$atf} ) {
							if ($af->{'uuid'} eq $fi->{'uuid'}) {
								$af->{'f'} = $f;
								$af->{'server_time'} = &subs::rightNow();
							}
						}
						my $jaf = encode_json $atf;
						&subs::db_update($fi->{'att'}, { file => $jaf, server_time => &subs::rightNow() }, { uuid => $att_file->{'uuid'}, app => $att_file->{'app'} });
					}

				}
			}

		}
		$file_join = encode_json $files;
		if ($success == 1) {
			&subs::db_update('appointments', { server_time => &subs::rightNow(), file => $file_join, encryption_standard => undef }, { app => $app, uuid => $filing->{'uuid'} });
		}
#		&subs::db_query('update appointments set server_time = ?, file = ?, encryption_standard = ? where app= ? and uuid = ?',
#			&subs::rightNow(), $file_join, undef, $app, $filing->{'uuid'}) if $success == 1;
		&Websocket::send('tab', { console => 'appointmentDetailGrabber(\'' . $app . '\',\'' . $filing->{'uuid'} .'\');'});
	}
}

sub window_closer {
	my $app = shift;
	my $browser_tab_id = shift;
	my $timestamp = &subs::rightNow();

	&Websocket::send('server', { browser_tab_id => $browser_tab_id, not_me => 1, console => '$(".' . &subs::html_name($app) . '_close_button").trigger("click");', timestamp => $timestamp });
	undef $gb::ws->{$app}->{$browser_tab_id};
}

sub config_reader {
	my $cache = &subs::cache_get({ app => '__president', context => 'config' });
	if ($cache) {
		return $cache;
	}

	my $signatorial = &subs::signatorial_designer();
	my $device = &subs::device_setter();
	foreach my $dt ( ( @gb::device_types, $signatorial )  ) {
		foreach my $k ( @gb::misc_settings ) {
			my $s = $k . "_background_colour";
			my $req = &db_query('select value from settings where setting = ? and app = ? and device = ?',$s,'misc',$dt);
			my $qu = $req->hashes;

			foreach my $q ( @{$qu } ) {
				$config->{$dt}->{$k}->{'background_colour'} = $q->{'value'} || $config->{$k}->{'background_colour'};
			}
			if ($dt eq $signatorial && !$config->{$dt}->{$k}->{'background_colour'}) {
				$config->{$dt}->{$k}->{'background_colour'} = $config->{$device}->{$k}->{'background_colour'};
			}
		}
	}
	$config->{'device'} = &device_setter();
	# the selected icon set for the current device; stored in the shared config
	# cache (invalidated on configure changes) so every prefork worker agrees
	my $is = &db_query('select value from settings where setting = ? and app = ? and device = ?', 'icon_set', 'misc', $device)->hashes;
	$config->{'icon_set'} = $is->[0]->{'value'} if scalar @{$is};
	my $environment = $config->{'environment'};
	if ($environment =~ /^dev/) {
		$config->{'environment'} = 'development';
	}
	elsif ($environment =~ /^pro/) {
		$config->{'environment'} = 'production';
	}

	&subs::cache_set({ app => '__president', context => 'config', warranty => '-10m' }, $config);
	return $config;
}

sub cache_set {
	my ($params,$data) = @_;
	my $app = &subs::unformat_name($params->{'app'});
	my $context = $params->{'context'};
	my $subcontext = $params->{'subcontext'} || undef;
	my $timestamp = $params->{'timestamp'} || &subs::rightNow();
	my $server_time = &subs::rightNow();
	my $json_data = encode_sereal $data;
	my $warranty;
	if ($params->{'warranty'}) {
		$warranty = &subs::ago_calc($params->{'warranty'}, &subs::rightNow());
	}
	else {
		$warranty = &subs::ago_calc(&subs::setting_grabber({ app => $app, setting => 'warranty' }), &subs::rightNow()) || &subs::ago_calc(&subs::setting_grabber({ app => 'me', setting => 'warranty' }) || '-10d', &subs::rightNow());
	}
	my $key = { app => $app, context => $context, subcontext => $subcontext, device => $device };
	my $value = {
		data => $json_data,
		timestamp => $timestamp,
		server_time => $server_time,
		warranty => $warranty,
	};
	# Update the row in place and insert only when there is none. The old
	# delete-then-insert left a window in which the value did not exist at all,
	# so a restart (or a refused insert on a busy database) between the two
	# statements lost the whole cached value - including the balance chart's
	# rolling month, which lives in one row. An update is one atomic statement:
	# a crash leaves either the old value or the new one, never neither.
	my $found = eval { &subs::db_select_simple('cache', ['uuid'], $key) };
	# If the row cannot even be read, leave whatever is stored alone rather than
	# inserting a second copy beside it.
	return unless $found;
	my $existing = $found->hashes->[0];
	if ($existing && $existing->{'uuid'}) {
		&subs::db_update('cache', $value, { uuid => $existing->{'uuid'} });
	}
	else {
		&db_insert('cache', {
			%{$key},
			%{$value},
			uuid => &random_string_creator(25)
		});
	}
}

sub cache_delete {
	my ($params) = @_;
	$params->{'device'} = $device;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $result = &db_delete('cache', $params);
}

sub cache_get {
	my ($params) = @_;
	$params->{'device'} = $device;
	my $returner;
	my $results = &subs::db_select_simple('cache', ['data'], $params)->hashes;
	my $result = $results->[0];
	my $json_data = $result->{'data'};
	if ($result->{'data'}) {
		$returner = eval { return decode_sereal $json_data };
		return $returner if $returner;
	}
}

# Gossip dedupe for relayed requests. A relay carries a relay_id, minted once by
# the machine that first sent it, and every machine that handles it claims the
# id here. INSERT OR IGNORE makes claim-and-check atomic, so of two copies that
# race in exactly one is "fresh" and the rest are dropped. cache is local (never
# synced), and the rows are pruned by age, so a machine forgets a relay only
# long after it has stopped circulating.
sub stale_action_ms {
	# How old a user action may be before it is treated as a replay rather than a
	# press: a machine that comes back after being away flushes the actions it
	# queued, and applying those minutes or hours later re-closes sessions the
	# person already stopped. Fifteen minutes is longer than any live press takes
	# to arrive over the mesh and far shorter than an offline spell.
	return 15 * 60 * 1000;
}

sub relay_fresh {
	my ($id) = @_;
	return 1 unless $id;
	my $now = &subs::rightNow();
	my $q = &subs::db_query('insert or ignore into cache (uuid, context, app, device, server_time, timestamp) values (?,?,?,?,?,?)',
		$id, 'relay', '__president', &subs::device_setter(), $now, $now);
	my $fresh = ($q && $q->rows) ? 1 : 0;
	&subs::db_query('delete from cache where context=? and server_time < ?', 'relay', $now - 600000) if $fresh;
	return $fresh;
}

sub file_device_renamer {
	my $data = shift;
	my $file = $data->{'file'};
	my $app = $data->{'app'};
	my $app_path = &subs::path_name($app);
	my $is_thumb = $data->{'is_thumb'} || 0;
	undef $data->{'is_thumb'};
	my $misc_settings = $data->{'misc_settings'};
	my $type = $data->{'type'};

	my @f = split '/', $file;
	my $destination;
	my $asset = $f[-1];

	if ($f[-2] eq '.thumbs' || $f[-2] eq 'thumbs') {
		$is_thumb = 1;
	}
	if (!$app) {
		if ($f[-2] eq '.thumbs' || $f[-2] eq 'thumbs') {
			$app = $f[-3];
		}
		else {
			$app = $f[-2];
		}
	}
	my @asset = split /\./, $asset;
	my $assetual = $asset;
	$assetual =~ s/\.enc$//gi;
	my $ext = $asset[-1];
	if ($asset[-1] eq 'enc') {
		$ext = $asset[-2];
	}

	if ($type) {
		if ($type eq 'recording') {
			$type = 'rec';
		}
		elsif ($type eq 'image') {
			$type = 'photo';
		}
		elsif ($type eq 'audio') {
			$type = 'music';
		}
		if (my $location = &subs::setting_grabber({ app => 'misc', setting => $type . '_location', device => $device})) {
			$destination = &subs::home($location . '/' . $app_path . '/');
		}
	}


	unless ($destination) {
		$misc_settings = &subs::misc_setting_list() unless $misc_settings;
		if ($assetual =~ /\.mp3$|\.m4a$|\.flac$|\.aiff$|\.aif$|\.weba$|\.wav$|\.ogg$|\.oga$|\.opus$/i) {
			$destination = &subs::home($misc_settings->{$device}->{'music_location'} . '/' . $app_path . '/');
			$type = 'audio';
		}
		elsif ($assetual =~ /\.jpe?g$|\.xcf$|\.png$|\.webp$|\.heic$|\.heif$|\.bmp$|\.tiff?$|\.gif$/i) {
			$destination = &subs::home($misc_settings->{$device}->{'photo_location'} . '/' . $app_path . '/');
			$type = 'image';
		}
		elsif ($assetual =~ /\.mov$|\.avi$|\.webm$|\.mp4$|\.mkv$|\.m4v$/i) {
			$destination = &subs::home($misc_settings->{$device}->{'video_location'} . '/' . $app_path . '/');
			$type = 'video';
		}
		elsif ($assetual =~ /\.pdf$/i) {
			$destination = &subs::home($misc_settings->{$device}->{'document_location'} . '/' . $app_path . '/');
			$type = 'document';
		}
		else {
			$destination = &subs::home($misc_settings->{$device}->{'download_location'} . '/' . $app_path . '/');
			$type = 'software';
		}
	}
	if ($is_thumb == 1) {
		$destination = $destination . '.thumbs/';
	}
	return ($destination,$asset,$type,$app);
}

# Put an arbitrary filesystem path into a shell command literally. Single
# quotes carry spaces, brackets, parentheses, ampersands and quotes, and the
# one character that cannot appear inside them is escaped the usual way.
sub shell_quote {
	my $s = shift // '';
	$s =~ s/'/'\\''/g;
	return "'" . $s . "'";
}

sub file_media_information {
	my $file_data = shift;
	my $file = shift || $file_data->{'f'};



	if ($file_data->{'type'} eq 'image') {
		my $command = 'ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 ' . &shell_quote($file);
		my $res = `$command`;
		chomp $res;
		my @res = split ',', $res;
		$file_data->{'info'} = { width => $res[0], height => $res[1] };
	}
	elsif ($file_data->{'type'} eq 'audio') {

		my $command = 'ffprobe -print_format json -show_entries stream=codec_name:format -select_streams a:0 -v quiet ' . &shell_quote($file);

		my $jres = `$command`;
		my $res = eval { return decode_json $jres } || {};
		my $format = $res->{'format'};
		if ($format->{'duration'}) {
			$file_data->{'info'} = $format;
		}
		else {
			my $command = 'ffprobe -v error -select_streams a:0 -show_entries stream=duration -of csv=p=0 ' . &shell_quote($file);
			my $res = `$command`;
			chomp $res;
			my @res = split ',', $res;
			my $duration = $res[0];
			$file_data->{'info'} = { duration => $duration };
		}
	}
	elsif ($file_data->{'type'} eq 'video') {
		my $command = 'ffprobe -print_format json -show_chapters -show_entries stream=height,width,duration,codec_name:format -select_streams v:0 -v quiet ' . &shell_quote($file);
		my $jres = `$command`;
		my $res = eval { return decode_json $jres } || {};
		my $format = $res->{'format'};
		my $streams = $res->{'streams'} || [];
		# A probe that answered nothing is a failed probe, not an empty file. The
		# old code assigned the undef format and then wrote chapters into it, which
		# autovivified { chapters => undef } and cached that as a real answer - the
		# Music card asks a video for a duration and a height, found neither, and hid
		# its thumbnail for the life of the cache. Leave info unset so the caller can
		# tell "not probed" from "probed and empty" and retry.
		if ((ref $format eq 'HASH' && scalar keys %{$format}) || scalar @{$streams}) {
			$file_data->{'info'} = ref $format eq 'HASH' ? $format : {};
			$file_data->{'info'}->{'chapters'} = $res->{'chapters'} if ref $res->{'chapters'} eq 'ARRAY';
			foreach my $d ( @{$streams} ) {
				foreach my $dr ( keys %{$d} ) {
					$file_data->{'info'}->{$dr} = $d->{$dr};
				}
			}
		}
	}
	return $file_data;
}

# Formats a phone WebView cannot show in an <img>. A TIFF or an XCF has to be
# flattened to a PNG for the details view; HEIC/HEIF are still unreliable across
# Android WebView versions, so they get the same treatment.
sub image_preview_needed {
	my ($file) = @_;
	return 0 unless defined $file && length $file;
	my $name = $file;
	$name =~ s/\.enc$//i;
	return $name =~ /\.(?:tiff?|xcf|heic|heif)$/i ? 1 : 0;
}

# Record a WebView-viewable preview for a picture the browser cannot render.
# The original stays the file that is downloaded; `preview` is what the details
# view draws. magick reads the first page/layer, applies the EXIF orientation and
# writes a PNG. No magick on the machine means no preview and no error.
sub file_preview_maker {
	my $data = shift;
	return $data unless ref $data eq 'HASH';
	my $file = $data->{'f'} || '';
	return $data unless &image_preview_needed($file);
	return $data if $data->{'preview'} && -e $data->{'preview'} && (-s $data->{'preview'}) > 0;
	return $data unless -e $file;
	(my $preview = $file) =~ s/\.[^.]+$//;
	$preview .= '.preview.png';
	my $size = $data->{'preview_size'} || '1920x1080>';
	my $made = 0;
	foreach my $bin (qw/magick convert/) {
		my $command = &shell_quote($bin)
			. ' ' . &shell_quote($file . '[0]')
			. ' -auto-orient -strip -resize ' . &shell_quote($size)
			. ' ' . &shell_quote($preview) . ' 2>/dev/null';
		system($command);
		if (-e $preview && (-s $preview) > 0) { $made = 1; last; }
	}
	if ($made) {
		$data->{'preview'} = $preview;
	}
	else {
		unlink $preview if -e $preview;
	}
	return $data;
}

# Where a video's poster frame is taken from. Ten milliseconds in is a fade or a
# black frame on most encodes, which is why so many posters came back blank; the
# frame people recognise is a little way in. The plain-file thumb path used this
# rule inline; the sealed path now shares it instead of always taking 00:00:00.010.
sub thumbnail_seek_position {
	my $duration = shift;
	$duration = 0 unless defined $duration && $duration =~ /^\d+(?:\.\d+)?$/;
	return '00:00:01.000' if $duration < 10;
	return '00:00:12.000' if $duration < 60;
	return '00:01:01.000' if $duration < 120;
	return '00:02:00.020';
}

# A cached Music file_information entry is only worth reusing when it carries the
# facts the cards draw. A failed ffprobe used to be cached as
# { chapters => undef, tags => {} }: truthy, so it was reused for ever, and every
# video card asked for a duration and a height it did not have and fell back to
# the generic icon. The callers treat an unusable entry as a miss and re-probe.
sub music_info_usable {
	my $info = shift;
	return 0 unless ref $info eq 'HASH';
	return 1 if defined $info->{'duration'} && length $info->{'duration'};
	return 1 if defined $info->{'height'} && length $info->{'height'};
	return 1 if defined $info->{'width'} && length $info->{'width'};
	return 1 if ref $info->{'tags'} eq 'HASH' && scalar keys %{$info->{'tags'}};
	return 0;
}

# The old whole-file transmitter is retired: it downloaded the track on the
# remote and started `play` at a guessed offset. Remote audio is now a live PCM
# stream driven by public/js/music.js over /manager/music/stream. An older page
# that still sends method=transmitter reaches this no-op instead of starting a
# download.
sub music_transmitter {
	return;
}

# A remembered music queue (see music_queue_remember in Music.pl) is replayed
# into a reopened window only when it still describes the same library: a peer's
# paths mean nothing on this machine. What a window may *list* is a different
# question - sealed and private tracks are filtered out of the queue by the
# window it is being replayed into (music_queue_file_visible), the same rule the
# folder walk applies, so a list assembled while unlocked still comes back in a
# locked window instead of being thrown away. Pure, so the rule is testable
# without a database.
sub music_queue_applies {
	my ($queue, $library) = @_;
	return 0 unless $queue && ref $queue eq 'HASH' && ref $queue->{'files'} eq 'ARRAY';
	return 0 unless scalar @{ $queue->{'files'} };
	$library = 'local' unless defined $library && length $library;
	return 0 unless ($queue->{'library'} || 'local') eq $library;
	return 1;
}

sub vacuum {
	my $app = shift;
	# the house's own apps are not a use case that ends: me carries name, warranty
	# and budget_alarm, __president carries ws_pa and cache_folders, music and misc
	# their own house settings. None is rebuilt by opening the app again, so an
	# expired last appointment must never take them with it
	return if grep { $_ eq $app } qw/misc customs music __president me/;
	my ($db,$database,$sql) = &subs::database_grabber();
	my $timestamp = rightNow();
	my $app_q = &db_query('select * from appointments where app=?',$app);
	my $appts = $app_q->hashes;
	if (scalar @{$appts} == 0 && &setting_grabber({ app => $app, setting => 'permanent' }) ne 'checked') {
		&Websocket::send('server', { console => '$(".' . &subs::html_name($app) . '_close_button").trigger("click");', timestamp => $timestamp });

		foreach my $t ( qw/appointments tickets settings continent websites tickets cache subcategory option model option_category mailbox websockets/) {
			&db_query('delete from ' . $t . ' where app=?',$app);
		}
	}
}

sub vacuum_app {
	my $app = shift;
	my $timestamp = rightNow();
	my ($db,$database,$sql) = &subs::database_grabber();
	my $app_q = &db_query('select * from appointments where app=?',$app);
	my $appts = $app_q->hashes;
	foreach my $app ( @{$appts} ) {
		if ($app->{'file'}) {
			my @files = split ',', $app->{'file'};
			foreach my $f ( @files ) {
				if (-e $f) {
					&secure_unlink($f);
				}
			}
		}
	}
	&Websocket::send('server', { console => '$(".' . &subs::html_name($app) . '_close_button").trigger("click");', timestamp => $timestamp });
	sleep 1;
	foreach my $t ( qw/appointments tickets settings continent websites tickets cache subcategory option model option_category mailbox websockets/) {
		&db_query('delete from ' . $t . ' where app=?',$app);
	}

}

# The location types a device can point at a folder and archive to: one per
# <location>_location / <location>_archive setting pair, and one folder each
# under the archive root.
sub location_types {
	return qw/music download photo document video scan rec/;
}

sub archive_folder_name {
	my $location = shift;
	my $name = $archive_folder_names{$location};
	return (defined $name && length $name) ? $name : $location;
}

# The folder an archive keeps a location's files in. A drive filled before the
# readable names keeps its lower-case folder rather than growing a second one
# beside it; an empty or new drive gets the readable name.
sub archive_location_folder {
	my ($root, $location) = @_;
	$root =~ s{/+$}{};
	my $name = &archive_folder_name($location);
	my $folder = $root . '/' . $name;
	my $legacy = $root . '/' . $location;
	return $legacy if ($name ne $location && -d $legacy && !-d $folder);
	return $folder;
}

# The machines that advertise an archive drive, once each however many rows or
# mirrors name them.
sub archive_machine_candidates {
	my $machines = shift || [];
	my %seen;
	return grep {
		my $rm = $_;
		(ref $rm eq 'HASH')
			&& defined $rm->{'archive_dir'} && length $rm->{'archive_dir'} && lc($rm->{'archive_dir'}) ne 'null'
			&& defined $rm->{'uuid'} && length $rm->{'uuid'}
			&& !$seen{$rm->{'uuid'}}++
	} @{$machines};
}

# The machine a location archives to. A configured <location>_archive wins by
# its signatorial (or uuid). When nothing is chosen and the house has exactly
# one machine with an archive drive, that machine is used - a single drive is
# not a guess. More than one candidate is a real choice, so it stays refused
# until a person picks one rather than let listing order decide.
# In list context it also says why there is no machine, for the refusal text.
sub archive_machine_for {
	my ($location, $settings, $machines) = @_;
	$settings ||= {};
	$machines ||= [];
	my %by_id;
	foreach my $rm ( @{$machines} ) {
		next unless ref $rm eq 'HASH';
		foreach my $id ( $rm->{'signatorial'}, $rm->{'uuid'} ) {
			next unless defined $id && length $id && $id ne 'null';
			$by_id{$id} = $rm;
		}
	}
	my $chosen = $settings->{$location . '_archive'};
	if (defined $chosen && length $chosen && $chosen ne 'null') {
		my $rm = $by_id{$chosen};
		return wantarray ? ($rm, $rm ? undef : 'its archive machine is not known on this machine') : $rm;
	}
	my @candidates = &archive_machine_candidates($machines);
	if (scalar @candidates == 1) {
		return wantarray ? ($candidates[0], undef) : $candidates[0];
	}
	my $why = scalar @candidates
		? 'several machines have an archive drive; choose one in Configure'
		: 'its location has no archive machine';
	return wantarray ? (undef, $why) : undef;
}

# The archive root of this machine: the configure panel's pick first — it is a
# misc setting, so the root can be chosen without editing config.json — then
# config.json's archive_dir. Tidied: ~ resolved, no trailing slash. Undef when
# this machine is not an archive.
sub archive_root {
	# the panel's pick wants the settings table, which the very first boot may
	# not have open yet; config.json is the fallback either way
	my $dir = eval { return &setting_grabber({ app => 'misc', setting => 'archive_dir' }) };
	$dir = $config->{'archive_dir'} unless (defined $dir && length $dir && lc($dir) ne 'null');
	return undef unless (defined $dir && length $dir);
	my $root = &home($dir);
	$root =~ s{/+$}{};
	return $root;
}

# Where an item lands inside an archive: <root>/<location folder>/<path inside
# the location folder>. The location has to be one we know, and the relative path
# cannot climb out of it, since the sending machine chooses both. `folder` is
# the location's folder, `parent` the folder the item's own file goes in.
sub archive_destination {
	my $data = shift;
	my $location = $data->{'location'};
	return { error => 'unknown location' } unless grep { $_ eq $location } &location_types();
	my $root = $data->{'root'} || &archive_root();
	return { error => 'no archive_dir on this machine' } unless $root;
	# the root is usually a mounted drive, so a drive that has not come up has
	# to fail the transfer rather than have its folders invented on the disk
	# below it
	return { error => 'archive root is not there' } unless -d $root;
	my $relative = defined $data->{'path'} ? $data->{'path'} : '';
	$relative =~ s{\\}{/}g;
	my @parts;
	foreach my $part (split m{/+}, $relative) {
		next if $part eq '' || $part eq '.';
		# .. resolves against what came before it, and cannot climb above the
		# location folder because there is nothing above it to pop
		if ($part eq '..') { pop @parts; next; }
		push @parts, $part;
	}
	my $inside = join '/', @parts;
	my $folder = &archive_location_folder($root, $location);
	my @upper = @parts;
	pop @upper if scalar @upper;
	return {
		root => $root,
		location => $location,
		folder => $folder,
		parent => $folder . (scalar @upper ? '/' . join('/', @upper) : ''),
		relative => $inside,
		path => $folder . (length $inside ? '/' . $inside : '')
	};
}

# A selected path's archive plan. The location whose folder holds the path,
# the machine that location archives to, and where the item lands inside the
# archive. The longest matching location folder wins, so a scans folder inside
# documents resolves to scans; a tie, which is two names for one folder, goes
# to the earlier location type, so document beats scan. A path under no
# location is refused by name rather than guessed at; a location with no chosen
# machine uses the house's only archive drive, or is refused when the choice is
# genuinely ambiguous. Every path appears once however many selections repeat
# it.
sub archive_plan {
	my $data = shift;
	my $items = $data->{'items'} || [];
	my $settings = $data->{'settings'} || {};
	my $machines = $data->{'machines'} || [];
	# per-job choice, never the default: the original is removed only after the
	# archive machine has verified the copy
	my $delete_after = $data->{'delete_after'} ? 1 : 0;
	# the folders to match against, longest first; within one length the
	# location type order decides, so a tie is not hash order
	my @roots;
	my $order = 0;
	foreach my $location ( &location_types() ) {
		$order++;
		my $base = $settings->{$location . '_location'};
		next unless (defined $base && length $base);
		$base = &home($base);
		$base =~ s{/+$}{};
		push @roots, { location => $location, base => $base, order => $order };
	}
	@roots = sort { length($b->{'base'}) <=> length($a->{'base'}) || $a->{'order'} <=> $b->{'order'} } @roots;

	my (@jobs, @refused, %seen);
	foreach my $item ( @{$items} ) {
		my $path = $item->{'path'};
		next unless (defined $path && length $path);
		$path = &home($path);
		$path =~ s{/+$}{};
		next if $seen{$path}++;
		my $match;
		foreach my $root ( @roots ) {
			next unless ($path eq $root->{'base'} || $path =~ m{^\Q$root->{'base'}\E/});
			$match = $root;
			last;
		}
		unless ($match) {
			push @refused, { path => $path, reason => 'no location folder holds it' };
			next;
		}
		my ($rm, $why) = &archive_machine_for($match->{'location'}, $settings, $machines);
		unless ($rm) {
			push @refused, { path => $path, location => $match->{'location'}, reason => $why || 'its location has no archive machine' };
			next;
		}
		# the item may be the location folder itself, which lands at its top
		my $relative = ($path eq $match->{'base'}) ? '' : substr($path, length($match->{'base'}) + 1);
		push @jobs, {
			path => $path,
			location => $match->{'location'},
			relative => $relative,
			folder => (($item->{'type'} || '') eq 'folder' || -d $path) ? 1 : 0,
			delete_after => $delete_after,
			remote_uuid => $rm->{'uuid'},
			remote_hostname => $rm->{'hostname'}
		};
	}
	return { jobs => \@jobs, refused => \@refused };
}

1;
