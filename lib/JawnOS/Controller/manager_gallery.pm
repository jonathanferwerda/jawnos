package Manager;

# manager_gallery: route actions moved out of Manager.pl, one sub per route so a
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

# The Gallery shell. The old route built every tile into the response and let
# /file_open make missing thumbnails inside the request; a library opened that
# way held every prefork worker and the rest of the UI stopped answering. The
# tiles now come in pages from /manager/gallery/data, and the client only asks
# for the images it is about to show.
# GET /manager/gallery
sub action_27838 {
	my $c = shift;
	my $permissive = media_unlock_open($c, 'gallery') ? 1 : 0;
	my $unlock = $permissive ? ($c->param('unlock') || '') : '';
	my $settings = &subs::settings_grabber({ app => 'gallery' });
	my $contents = $c->render_to_string(
		template => 'apps/gallery',
		unlock => $unlock,
		permissive => $permissive,
		settings => $settings,
		c => $c
	);
	my $website = &Manager::window_maker({ user_agent => $c->param('user_agent'), app => 'gallery', contents => $contents }, $c->param('timestamp') || &subs::rightNow());
	$c->render(json => { window => $website, locked => ($permissive ? 0 : 1), unlock => $unlock });
}

# One page of tiles. A tile carries the thumbnail it should show (the stored
# one when there is one) and the full file for the viewer.
# GET /manager/gallery/data
sub action_27855 {
	my $c = shift;
	my $permissive = media_unlock_open($c, 'gallery') ? 1 : 0;
	my $revealed = $permissive ? 1 : 0;
	my $search = lc($c->param('search') || '');
	my $sort = ($c->param('sort') || 'desc') eq 'asc' ? 'asc' : 'desc';
	my $offset = int($c->param('offset') || 0);
	my $limit = int($c->param('limit') || 160);
	$limit = 160 if $limit < 1 || $limit > 300;
	my $apps = eval { return decode_json $c->param('apps') } || [];
	$apps = [] unless ref $apps eq 'ARRAY';
	my $jfiles = $c->param('files');
	# a Gallery opened from Travel's nearby strip carries the ground: only the files
	# taken inside it are listed, and the window pages through them like any album
	my %near_key;
	if ($c->param('near_lat') && $c->param('near_lon')) {
		my $near = &travel_nearby_items(
			lat => $c->param('near_lat'),
			lon => $c->param('near_lon'),
			limit => 3000,
			nw_lat => $c->param('near_nw_lat'),
			nw_lon => $c->param('near_nw_lon'),
			se_lat => $c->param('near_se_lat'),
			se_lon => $c->param('near_se_lon')
		);
		%near_key = map { ($_->{'app'} || '') . "\0" . ($_->{'app_uuid'} || '') . "\0" . ($_->{'uuid'} ? 'u:' . $_->{'uuid'} : 'f:' . ($_->{'f'} || '')) => 1 } @{$near};
	}
	my $settings = &subs::settings_grabber({ app => 'gallery' });
	my @all;
	my %albums;
	my %hidden_albums;
	my %aset_cache;
	my $uenc = sub {
		my $v = shift;
		return '' unless defined $v;
		my $copy = "$v";
		# uri_encode is pure Perl and costs half a millisecond a call; a gallery
		# page builds four URLs per tile, which was over a second per page and
		# held a worker that long. This is the same encoding, and it also escapes
		# # and ? that the old one left to break the query.
		utf8::encode($copy) if utf8::is_utf8($copy);
		return url_escape($copy, '^A-Za-z0-9\-._~/')
	};
	my $archive_lookup;

	my $tile_for = sub {
		my ($app, $appt, $f, $explicit) = @_;
		my $path = $f->{'f'} || '';
		return undef unless length $path;
		# A private album is not served at all outside a private place, whatever
		# padlock grant an old window still holds.
		return undef if &subs::app_private_now($app) && !&subs::private_reachable_now();
		my $type = $f->{'type'} || $appt->{'type'} || 'image';
		my $server_time = $f->{'server_time'} || $appt->{'server_time'} || 0;
		# The app's own timestamp is when the thing happened; server_time is when
		# the row was written or synced, which can be days later. Sort and date by
		# the former when the appointment carries one.
		my $sort_time = $appt->{'timestamp'} || $f->{'timestamp'} || $f->{'server_time'} || $server_time || 0;
		# A row synced from another machine keeps that machine's path. The copy on
		# this one lives under its own photo (or video) location, and the same
		# renamer the rest of the manager uses maps it there. Without this a phone
		# shows only the photos it took itself, and a laptop trips over a
		# main_image that names a phone path.
		if (!-e $path) {
			my ($dir, $asset) = &subs::file_device_renamer({ file => $path, app => $app, type => $type });
			my $local = (defined $dir && defined $asset) ? $dir . $asset : '';
			$path = $local if length $local && -e $local;
		}
		# The padlock is for what the person hid, not for every sealed file: an
		# album marked visible is theirs to browse, so only a hidden album's
		# photos wait for an unlock. A list handed over by another app (Folders,
		# the IDE) has already been through that app's own rule - the file was
		# chosen from a listing the person could see - and it is not one of this
		# gallery's albums, so its names are not filtered again here.
		if (!$explicit) {
			my $aset = $aset_cache{$app} ||= &subs::settings_grabber({ app => $app, settings => ['main_image', 'visible'] });
			my $app_visible = &subs::app_hidden_now($app) ? 0 : 1;
			return undef if !$app_visible && $path =~ /\.enc$/i && (!$permissive || &subs::lockdown_active());
		}
		if (!-e $path && !$f->{'remote_uuid'}) {
			return undef unless (($settings->{'archive'} // 'on') ne 'off');
			$archive_lookup = &subs::archive_image_lookup({}) unless $archive_lookup;
			my $archived = ($archive_lookup && $archive_lookup->{'locate'}) ? $archive_lookup->{'locate'}->($path) : undef;
			return undef unless $archived;
			$path = $archived->{'path'};
			$f->{'f'} = $path;
			$f->{'remote_uuid'} = $archived->{'remote_uuid'};
		}
		if ($f->{'thumb'} && !-e $f->{'thumb'}) {
			my ($tdir, $tasset) = &subs::file_device_renamer({ file => $f->{'thumb'}, app => $app, type => $type });
			my $tlocal = (defined $tdir && defined $tasset) ? $tdir . $tasset : '';
			$f->{'thumb'} = $tlocal if length $tlocal && -e $tlocal;
		}
		my $thumb_ok = ($f->{'thumb'} && -e $f->{'thumb'} && (-s $f->{'thumb'}) > 100) ? 1 : 0;
		my $thumb_path = $thumb_ok ? $f->{'thumb'} : $path;
		my $thumb = '/file_open?file=' . $uenc->($thumb_path)
			. '&app=' . $uenc->($app)
			. '&app_uuid=' . $uenc->($appt->{'uuid'} || '')
			. '&timestamp=' . $uenc->($server_time)
			. ($f->{'uuid'} ? '&file_uuid=' . $uenc->($f->{'uuid'}) : '')
			# a photo living on a peer (or the archive) must relay its thumb too,
			# not just the full-size file the viewer asks for
			. ($f->{'remote_uuid'} ? '&remote_uuid=' . $uenc->($f->{'remote_uuid'}) : '')
			. ($thumb_ok ? '' : '&thumb=ya');
		my $full = '/play?app=' . $uenc->($app)
			. '&track=' . $uenc->($path)
			. '&timestamp=' . $uenc->($server_time)
			. ($f->{'remote_uuid'} ? '&remote_uuid=' . $uenc->($f->{'remote_uuid'}) : '');
		my $name = $path;
		$name =~ s{.*/}{};
		return {
			uuid => $f->{'uuid'} || '',
			app => $app,
			label => $f->{'label'} || &subs::format_name($app),
			app_uuid => $appt->{'uuid'} || '',
			type => $type,
			f => $path,
			name => $name,
			thumb => $thumb,
			file => $full,
			server_time => $server_time,
			sort_time => $sort_time,
			timestamp => $appt->{'timestamp'} || 0,
			remote_uuid => $f->{'remote_uuid'} || '',
			info => $f->{'info'} || {},
		};
	};

	if ($jfiles) {
		my $files = eval { return decode_json $jfiles } || [];
		foreach my $f ( @{$files} ) {
			my $app = $f->{'app'} || 'ide';
			my $tile = $tile_for->($app, { timestamp => &subs::rightNow(), server_time => &subs::rightNow(), uuid => &subs::random_string_creator(12), type => $f->{'type'} || 'image' }, $f, 1);
			next unless $tile;
			push @all, $tile;
		}
	}
	else {
		my $rows = &subs::db_query('select * from appointments where file is not null and (type = ? or type = ?) order by timestamp', 'image', 'video')->hashes;
		foreach my $appt ( @{$rows} ) {
			my $app = $appt->{'app'} || '';
			next if scalar @{$apps} && !grep { $_ eq $app } @{$apps};
			my $aset = $aset_cache{$app} ||= &subs::settings_grabber({ app => $app, settings => ['main_image', 'visible'] });
			# Private is a lock, and the place is checked first: outside a private
			# place the album is not listed and not counted, so no Unlock button
			# offers a way to it either.
			next if &subs::app_private_now($app) && !&subs::private_reachable_now();
			if (&subs::app_hidden_now($app) && ($revealed == 0 || &subs::lockdown_active())) { $hidden_albums{$app} = 1; next; }
			# A record filed under a private project/club/account inherits that
			# lock even when its app is Public. The place is checked first, then a
			# fingerprint grant (this window's gallery lock or Security's private
			# grant).
			my $row_private = &subs::appointment_private_now($appt);
			next if $row_private && !&subs::private_reachable_now();
			next if $row_private && $revealed == 0 && !&subs::private_revealed();
			my $files = eval { return decode_json $appt->{'file'} } || [];
			foreach my $f ( @{$files} ) {
				next if %near_key && !$near_key{ ($app || '') . "\0" . ($appt->{'uuid'} || '') . "\0" . ($f->{'uuid'} ? 'u:' . $f->{'uuid'} : 'f:' . ($f->{'f'} || '')) };
				next if $search && index(lc($app), $search) < 0 && index(lc($f->{'f'} || ''), $search) < 0;
				my $tile = $tile_for->($app, $appt, $f);
				next unless $tile;
				push @all, $tile;
				my $album = $albums{$app} ||= { app => $app, label => &subs::format_name($app), count => 0, cover => '' };
				$album->{'count'}++;
				$album->{'cover'} ||= $tile->{'thumb'};
			}
		}
		# a chosen cover beats the newest photo
		foreach my $album ( values %albums ) {
			my $main = &subs::setting_grabber({ app => $album->{'app'}, setting => 'main_image' });
			next unless defined $main && length $main;
			# the choice may name a path from the machine that set it; this
			# machine's copy is under its own location
			if (!-e $main) {
				my ($dir, $asset) = &subs::file_device_renamer({ file => $main, app => $album->{'app'}, type => 'image' });
				my $local = (defined $dir && defined $asset) ? $dir . $asset : '';
				$main = $local if length $local && -e $local;
			}
			# a cover the tiles can already show is cheapest from its stored thumb
			my ($tile) = grep { ($_->{'f'} || '') eq $main } @all;
			if ($tile) { $album->{'cover'} = $tile->{'thumb'}; }
			elsif (-e $main) {
				$album->{'cover'} = '/file_open?file=' . $uenc->($main) . '&app=' . $uenc->($album->{'app'}) . '&thumb=ya';
			}
			# A choice that resolves to nothing on this machine (a photo taken on
			# the phone that never synced) keeps the newest photo's cover above.
		}
	}

	my @ordered = sort { $sort eq 'asc' ? $a->{'sort_time'} <=> $b->{'sort_time'} : $b->{'sort_time'} <=> $a->{'sort_time'} } @all;
	my $total = scalar @ordered;
	my @page;
	if ($offset < $total) {
		my $last = $offset + $limit - 1;
		$last = $total - 1 if $last > $total - 1;
		@page = @ordered[$offset .. $last];
	}
	$log->info('gallery data: locked, unlock=' . length($c->param('unlock') || '') . ' albums=' . scalar(keys %albums) . ' total=' . $total . ' revealed=' . $revealed . ' at_home=' . help_at_home())
		if (!$permissive && !$offset);
	$c->render(json => {
		items => \@page,
		total => $total,
		albums => [ sort { $a->{'label'} cmp $b->{'label'} } values %albums ],
		# albums the visibility rule kept out: the window offers its Unlock
		# button for them even on a device whose padlock context list is bare
		hidden => scalar(keys %hidden_albums),
		locked => ($permissive ? 0 : 1),
		unlock => ($permissive ? ($c->param('unlock') || '') : ''),
		sort => $sort,
	});
}

# GET /manager/gallery/scroll
sub action_28066 {
	my $c = shift;
	my $settings = &subs::settings_grabber({ app => 'gallery' });
	my $apps = eval { return decode_json $c->param('apps') } || [];
	my $search = $c->param('search');
	my $count = $c->param('count');
	my $count_timestamp = $c->param('count_timestamp');
	my $direction = $c->param('direction');
	my $first_count = $c->param('first_count');
	my $returner = { apps => $apps, count => $count, count_timestamp => $count_timestamp };
	my $permissive = media_unlock_open($c, 'gallery') ? 1 : 0;
	my $revealed = $permissive ? 1 : 0;
	$returner->{'html'} = $c->render_to_string(
		template => 'apps/gallery_album',
		settings => $settings,
		asettings => {},
		permissive => $permissive,
		revealed => $revealed,
		pre_count => $count,
		first_count => $first_count,
		view => 'album',
		apps => $apps,
		load => $direction,
		appts => []
	);
	$c->render(json => $returner);
}

# Whether a photo whose local copy is gone is looked for on the archive drive.
# The server defaults it on when the drive exists; a person turns it off here,
# and the choice is stored on this machine like the rest of the gallery settings.
# POST /manager/gallery/archive_toggle
sub action_28080 {
	my $c = shift;
	my $status = lc($c->param('status') || '');
	$status = ($status eq 'on') ? 'on' : 'off';
	&subs::setting_setter({
		app => 'gallery',
		setting => 'archive',
		value => $status,
		timestamp => $c->param('timestamp')
	});
	$c->render(text => (&subs::setting_grabber({ app => 'gallery', setting => 'archive' }) // $status));
}

1;
