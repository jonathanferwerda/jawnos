package Manager;

# Manager helpers, part 26 of 37. Moved out of Manager.pl so a
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

sub travel_pocket_line {
	my ($pocket, $side, $axis) = @_;
	my $empty = $pocket->{'empty'};
	my $n = $pocket->{'n'};
	if ($axis eq 'x') {
		if ($side < 0) {
			return 0 if $pocket->{'minx'} <= 0;
			for my $y ( $pocket->{'miny'} .. $pocket->{'maxy'} ) { return 0 unless $empty->[$y][$pocket->{'minx'} - 1]; }
			$pocket->{'minx'}--;
		}
		else {
			return 0 if $pocket->{'maxx'} >= $n - 1;
			for my $y ( $pocket->{'miny'} .. $pocket->{'maxy'} ) { return 0 unless $empty->[$y][$pocket->{'maxx'} + 1]; }
			$pocket->{'maxx'}++;
		}
	}
	else {
		if ($side < 0) {
			return 0 if $pocket->{'miny'} <= 0;
			for my $x ( $pocket->{'minx'} .. $pocket->{'maxx'} ) { return 0 unless $empty->[$pocket->{'miny'} - 1][$x]; }
			$pocket->{'miny'}--;
		}
		else {
			return 0 if $pocket->{'maxy'} >= $n - 1;
			for my $x ( $pocket->{'minx'} .. $pocket->{'maxx'} ) { return 0 unless $empty->[$pocket->{'maxy'} + 1][$x]; }
			$pocket->{'maxy'}++;
		}
	}
	return 1;
}

sub travel_pocket_grow {
	my ($pocket, $fraction) = @_;
	$pocket = { %{$pocket} };
	my $room_x = int(((($pocket->{'maxx'} - $pocket->{'minx'}) + 1) * $fraction) + 0.5);
	my $room_y = int(((($pocket->{'maxy'} - $pocket->{'miny'}) + 1) * $fraction) + 0.5);
	my ($left, $right, $south, $north) = ($room_x, $room_x, $room_y, $room_y);
	my $changed = 1;
	while ( $changed ) {
		$changed = 0;
		$changed = 1, $left-- if $left > 0 && &travel_pocket_line($pocket, -1, 'x');
		$changed = 1, $right-- if $right > 0 && &travel_pocket_line($pocket, 1, 'x');
		$changed = 1, $south-- if $south > 0 && &travel_pocket_line($pocket, -1, 'y');
		$changed = 1, $north-- if $north > 0 && &travel_pocket_line($pocket, 1, 'y');
	}
	return $pocket;
}

sub travel_pocket_widen {
	my ($pocket, $view) = @_;
	my $n = $pocket->{'n'};
	my $lat_step = ($view->{'maxLat'} - $view->{'minLat'}) / $n;
	my $lon_step = ($view->{'maxLon'} - $view->{'minLon'}) / $n;
	my $pi = 3.14159265358979;
	my $mpd = 6372800 * $pi / 180;
	my $mid_lat = ($view->{'minLat'} + $view->{'maxLat'}) / 2;
	my $mpd_lon = $mpd * cos($mid_lat * $pi / 180);
	my $lon_metres = (($pocket->{'maxx'} - $pocket->{'minx'}) + 1) * $lon_step * $mpd_lon;
	my $lat_metres = (($pocket->{'maxy'} - $pocket->{'miny'}) + 1) * $lat_step * $mpd;
	my ($axis, $want, $cell_m);
	if ($lon_metres >= $lat_metres) {
		$axis = 'y'; $want = $lon_metres / 3; $cell_m = $lat_step * $mpd;
	}
	else {
		$axis = 'x'; $want = $lat_metres / 3; $cell_m = $lon_step * $mpd_lon;
	}
	my $span_m = $axis eq 'y' ? $lat_metres : $lon_metres;
	my $moved = 1;
	while ( $moved && $span_m < $want ) {
		$moved = 0;
		if (&travel_pocket_line($pocket, -1, $axis)) { $moved = 1; $span_m += $cell_m; }
		last if $span_m >= $want;
		if (&travel_pocket_line($pocket, 1, $axis)) { $moved = 1; $span_m += $cell_m; }
	}
	return $pocket;
}

sub travel_box_grow {
	my ($box, $fraction) = @_;
	my $lat = ($box->{'maxLat'} - $box->{'minLat'}) * $fraction;
	my $lon = ($box->{'maxLon'} - $box->{'minLon'}) * $fraction;
	return {
		minLat => $box->{'minLat'} - $lat, maxLat => $box->{'maxLat'} + $lat,
		minLon => $box->{'minLon'} - $lon, maxLon => $box->{'maxLon'} + $lon,
	};
}

sub travel_map_box_bytes {
	my ($c, $map, $box) = @_;
	my $p = &travel_map_home_plate($map);
	my $s = $map->{'scale'} || {};
	my $first = $s->{'first'} || {};
	my $last = $s->{'last'} || {};
	my $pi = 3.14159265358979;
	my $lat0 = 0 + ($p->{'latitude'} || 0);
	my $lon0 = 0 + ($p->{'longitude'} || 0);
	my $w = 0 + ($p->{'width'} || 0);
	my $h = 0 + ($p->{'height'} || 0);
	my $legend = 0 + ($s->{'legend'} || 0);
	return undef unless defined $p->{'latitude'} && defined $p->{'longitude'} && $w > 0 && $h > 0 && $legend > 0;
	my $sdx = (0 + ($s->{'width'} || 0)) > 0 ? $w / (0 + $s->{'width'}) : 1;
	my $sdy = (0 + ($s->{'height'} || 0)) > 0 ? $h / (0 + $s->{'height'}) : 1;
	my $dx = ((0 + ($last->{'x'} || 0)) - (0 + ($first->{'x'} || 0))) * $sdx;
	my $dy = ((0 + ($last->{'y'} || 0)) - (0 + ($first->{'y'} || 0))) * $sdy;
	my $bar = sqrt(($dx * $dx) + ($dy * $dy));
	return undef unless $bar > 0;
	my $ppm = $bar / $legend;
	my $mpd = 6372800 * $pi / 180;
	my $mpd_lon = $mpd * cos($lat0 * $pi / 180);
	# the box in the home plate's own pixels
	my $x0 = ($p->{'x'} || 0) + (($box->{'minLon'} - $lon0) * $ppm * $mpd_lon);
	my $x1 = ($p->{'x'} || 0) + (($box->{'maxLon'} - $lon0) * $ppm * $mpd_lon);
	my $y0 = ($p->{'y'} || 0) - (($box->{'maxLat'} - $lat0) * $ppm * $mpd);
	my $y1 = ($p->{'y'} || 0) - (($box->{'minLat'} - $lat0) * $ppm * $mpd);
	$x0 = 0 if $x0 < 0; $y0 = 0 if $y0 < 0;
	$x1 = $w if $x1 > $w; $y1 = $h if $y1 > $h;
	my ($cw, $ch) = ( $x1 - $x0, $y1 - $y0 );
	return undef unless $cw > 2 && $ch > 2;
	my ($destination,$asset) = &subs::file_device_renamer({ file => $map->{'f'}, app => $map->{'app'}, type => $map->{'type'} });
	my $path = &subs::home($destination . $asset);
	return undef unless -e $path;
	my $bytes = &sealed_file_bytes(&subs::session_suds($c), $path);
	return undef unless $bytes && length $bytes;
	my $tmp = '/tmp/jawn_guess_' . &subs::random_string_creator(8) . '.png';
	write_file($tmp, $bytes);
	# the file may be at another resolution than the plate space was measured in
	my ($aw, $ah) = (0, 0);
	my $identified = &subs::image_bridge_identify($tmp);
	if ($identified) { ($aw, $ah) = ($identified->{'width'}, $identified->{'height'}); }
	else {
		open(my $identify, '-|', 'magick', 'identify', '-format', '%w %h', $tmp);
		if ($identify) { my $line = <$identify>; close $identify; ($aw, $ah) = split ' ', ($line || ''); }
	}
	return undef unless $aw && $ah;
	my $geo = sprintf('%dx%d+%d+%d', int($cw * $aw / $w), int($ch * $ah / $h), int($x0 * $aw / $w), int($y0 * $ah / $h));
	my $crop = '/tmp/jawn_guess_' . &subs::random_string_creator(8) . '_crop.png';
	my $edited = &subs::image_bridge_edit($tmp, [ { duty => 'crop', value => $geo } ], $crop);
	if ($edited) {
		&subs::image_bridge_resize($crop, 512, 512, $crop);
	}
	else {
		system('magick', $tmp, '-crop', $geo, '+repage', '-resize', '512x512>', $crop);
	}
	unlink $tmp;
	return undef unless -e $crop;
	my $out = read_file($crop);
	unlink $crop;
	return $out;
}

sub travel_guess_describe_area {
	my ($c, $placed, $box) = @_;
	my @images;
	my @names;
	my $context = &travel_box_grow($box, 0.3);
	foreach my $p ( @{$placed} ) {
		next if $p->{'map'}->{'guessed'};
		last if scalar @images >= 5;
		my $bytes = &travel_map_box_bytes($c, $p->{'map'}, $context);
		next unless $bytes;
		push @images, MIME::Base64::encode_base64($bytes, '');
		push @names, &subs::format_name($p->{'name'});
	}
	my $model = &subs::setting_grabber({ app => 'mail', setting => 'visual_assistant' }) || &subs::setting_grabber({ app => '__president', setting => 'visual_assistant' });
	return (undef, \@names) unless $model && @images;
	my $ask = 'These pictures are the parts of our own maps that fall in or beside one patch of ground we have not mapped' . (@names ? ' (the maps are: ' . join(', ', @names) . ')' : '') . '. Each is a crop, not a whole map. In one paragraph (no preamble, no lists), describe what most likely fills the unmapped patch, as a prompt for an image generator: terrain, land use, roads that visibly continue from the crops, water, season and the look of the imagery. Stay conservative: only say what these crops support; do not invent turns, junctions, buildings or landmarks.';
	my ($text) = &subs::ai_chat_role('visual_assistant', [ { role => 'system', content => 'You describe real places conservatively, for a satellite-imagery image generator.' }, { role => 'user', content => $ask, images => \@images } ], &subs::ai_role_thinking('visual_assistant'));
	return ($text, \@names);
}

sub travel_box_names {
	my ($placed, $box, $want) = @_;
	my $pi = 3.14159265358979;
	my $mpd = 6372800 * $pi / 180;
	my $lat = ($box->{'minLat'} + $box->{'maxLat'}) / 2;
	my $lon = ($box->{'minLon'} + $box->{'maxLon'}) / 2;
	my $mpd_lon = $mpd * cos($lat * $pi / 180);
	my @named;
	foreach my $p ( @{$placed} ) {
		next if $p->{'map'}->{'guessed'};
		my $b = $p->{'bounds'};
		my $barea = ($b->{'nw'}->{'lat'} - $b->{'se'}->{'lat'}) * ($b->{'se'}->{'lon'} - $b->{'nw'}->{'lon'});
		my $inside = 0;
		foreach my $q ( @{$placed} ) {
			next if $q == $p || $q->{'map'}->{'guessed'};
			my $c = $q->{'bounds'};
			next unless ($c->{'nw'}->{'lat'} >= $b->{'nw'}->{'lat'} && $c->{'se'}->{'lat'} <= $b->{'se'}->{'lat'}
				&& $c->{'nw'}->{'lon'} <= $b->{'nw'}->{'lon'} && $c->{'se'}->{'lon'} >= $b->{'se'}->{'lon'});
			my $carea = ($c->{'nw'}->{'lat'} - $c->{'se'}->{'lat'}) * ($c->{'se'}->{'lon'} - $c->{'nw'}->{'lon'});
			$inside = 1 if $carea > $barea;
		}
		push @named, $p unless $inside;
	}
	my @ranked;
	foreach my $p ( @named ) {
		my $b = $p->{'bounds'};
		my $dlat = 0;
		$dlat = $b->{'se'}->{'lat'} - $lat if $lat < $b->{'se'}->{'lat'};
		$dlat = $b->{'nw'}->{'lat'} - $lat if $lat > $b->{'nw'}->{'lat'};
		my $dlon = 0;
		$dlon = $b->{'nw'}->{'lon'} - $lon if $lon < $b->{'nw'}->{'lon'};
		$dlon = $b->{'se'}->{'lon'} - $lon if $lon > $b->{'se'}->{'lon'};
		my $d = sqrt((($dlat * $mpd) ** 2) + (($dlon * $mpd_lon) ** 2));
		push @ranked, [ $d, &subs::format_name($p->{'name'}) ];
	}
	@ranked = sort { $a->[0] <=> $b->[0] } @ranked;
	my @names;
	foreach my $r ( @ranked ) {
		last if scalar @names >= ($want || 2);
		next if grep { $_ eq $r->[1] } @names;
		push @names, $r->[1];
	}
	return @names;
}

sub travel_atlas_maps {
	my ($maps, $with_guesses) = @_;
	$with_guesses = 1 unless defined $with_guesses;
	my $out = [];
	foreach my $map ( @{$maps} ) {
		next if $map->{'guessed'} && !$with_guesses;
		next unless $map->{'home_plate'} && $map->{'scale'};
		my $home_plate = &travel_map_home_plate($map);
		next unless $home_plate->{'latitude'} && $home_plate->{'longitude'};
		my ($destination,$asset,$type) = &subs::file_device_renamer({ file => $map->{'f'}, app => $map->{'app'}, type => $map->{'type'} });
		my $f = $destination . $asset;
		my $file = '/file_open?timestamp=' . ($map->{'server_time'} || 0) . '&file=' . $f . '&app=' . ($map->{'app'} || '');
		# a guessed map has no appointment sealing its picture, so travel serves it
		# itself (session-guarded) rather than through /file_open
		$file = '/manager/travel/guess_image?uuid=' . $map->{'uuid'} if $map->{'guessed'};
		push @{$out}, {
			name => $map->{'name'} || $map->{'app'} || $map->{'uuid'},
			uuid => $map->{'uuid'},
			app => $map->{'app'},
			file => $file,
			guessed => ($map->{'guessed'} ? 1 : 0),
			guess_for => $map->{'guess_for'},
			home_plate => $home_plate,
			scale => $map->{'scale'},
			rotate => ($map->{'rotate'} || 0)
		};
	}
	return $out;
}

sub travel_appointment_uuid {
	my ($uuid, $set) = @_;
	return '' unless defined $uuid && length $uuid;
	return $uuid if $set->{$uuid};
	my $pos = 0;
	while (($pos = index($uuid, '-', $pos)) >= 0) {
		my $cand = substr($uuid, 0, $pos);
		return $cand if $set->{$cand};
		$pos++;
	}
	return '';
}

sub travel_here_position {
	my $row = &subs::db_query('select * from continent where type = ? and latitude is not null and (warranty is null or warranty = ? or cast(warranty as integer) > cast(? as integer)) order by server_time desc limit 1', 'temporary', '', &subs::rightNow())->hashes->[0];
	return ($row && $row->{'latitude'}) ? { latitude => $row->{'latitude'} + 0, longitude => $row->{'longitude'} + 0, label => 'You are here' } : undef;
}

sub travel_atlas_points {
	my ($start,$end) = @_;
	my $sql = 'select app, latitude, longitude, timestamp from continent where latitude is not null and (type is null or type != ?)';
	my @bind = ('temporary');
	if (defined $start && length $start && defined $end && length $end) {
		$sql .= ' and timestamp >= ? and timestamp <= ?';
		push @bind, $start, $end;
	}
	$sql .= ' order by timestamp desc';
	my $rows = &subs::db_query($sql, @bind)->hashes;
	my $points = [];
	my $seen = {};
	my %set_cache;
	foreach my $con ( @{$rows} ) {
		last if scalar @{$points} >= 1500;
		next if !$con->{'latitude'} || $con->{'latitude'} eq '';
		my $app = $con->{'app'};
		next if !$app;
		my $key = $app . '|' . $con->{'latitude'} . '|' . $con->{'longitude'};
		next if $seen->{$key}++;
		my $set = $set_cache{$app} ||= &subs::settings_grabber({ app => $app });
		next if &subs::app_hidden_now($app); # the same places the travel viewer shows
		push @{$points}, {
			latitude => $con->{'latitude'} + 0,
			longitude => $con->{'longitude'} + 0,
			name => &subs::format_name($set->{'name'} || $app),
			colour => $set->{'colour'}
		};
	}
	return $points;
}

sub travel_atlas_appointments {
	my ($start,$end) = @_;
	return [] unless defined $start && length $start && defined $end && length $end;
	my $rows = &subs::db_raw(
		'select distinct app from appointments where app is not null and ((timestamp >= ? and timestamp <= ?) or (stop_timestamp >= ? and stop_timestamp <= ?) or (stop_timestamp is null and type in (?,?) and timestamp > 0 and timestamp <= ?))',
		$start, $end, $start, $end, 'start', 'record', $end);
	my @apps = map { $_->{'app'} } @{$rows};
	return [] unless @apps;
	my $sql = 'select app, latitude, longitude, timestamp from continent where latitude is not null and (type is null or type != ?) and app in (' . join(',', map { '?' } @apps) . ') and timestamp <= ? order by timestamp desc';
	my $fixes = &subs::db_raw($sql, 'temporary', @apps, $end);
	my $out = [];
	my $seen = {};
	my %set_cache;
	foreach my $fix ( @{$fixes} ) {
		next if $seen->{$fix->{'app'}}++;
		next if !$fix->{'latitude'} || $fix->{'latitude'} eq '';
		my $set = $set_cache{$fix->{'app'}} ||= &subs::settings_grabber({ app => $fix->{'app'} });
		next if &subs::app_hidden_now($fix->{'app'});
		push @{$out}, {
			app => $fix->{'app'},
			name => &subs::format_name($set->{'name'} || $fix->{'app'}),
			colour => $set->{'colour'},
			latitude => $fix->{'latitude'} + 0,
			longitude => $fix->{'longitude'} + 0
		};
	}
	return $out;
}

sub travel_atlas_home_plates {
	my $rows = &subs::db_select('settings', undef, { setting => 'home_plate' })->hashes;
	my $out = [];
	my %seen;
	foreach my $row ( @{$rows} ) {
		my $hp = eval { return decode_json $row->{'value'} } || {};
		next unless $hp->{'latitude'} && $hp->{'longitude'};
		my $key = $row->{'app'} . '|' . $hp->{'latitude'} . '|' . $hp->{'longitude'};
		next if $seen{$key}++;
		my $set = &subs::settings_grabber({ app => $row->{'app'} });
		push @{$out}, {
			app => $row->{'app'},
			name => &subs::format_name($set->{'name'} || $row->{'app'}),
			colour => $set->{'colour'},
			latitude => $hp->{'latitude'} + 0,
			longitude => $hp->{'longitude'} + 0
		};
	}
	return $out;
}

sub handbook_day_bounds {
	my ($day, $fallback) = @_;
	$fallback = &subs::rightNow() unless defined $fallback && $fallback;
	my $ms;
	if (defined $day && $day =~ /\S/) {
		$ms = &subs::resolve_when($day, $fallback);
		# a weekday is a day of the week, with the clock's own words around it:
		# "monday" is the next one (today counts), "last monday" the one before,
		# "next monday" the one after this week's
		if (!defined $ms && $day =~ /^\s*(?:(last|next|this)\s+)?(sun(?:day)?|mon(?:day)?|tue(?:sday)?|wed(?:nesday)?|thu(?:rsday)?|fri(?:day)?|sat(?:urday)?)\s*$/i) {
			my ($modifier, $word) = (lc($1 || ''), lc $2);
			my %weekday = (sun => 0, mon => 1, tue => 2, wed => 3, thu => 4, fri => 5, sat => 6);
			my $target = $weekday{ substr($word, 0, 3) };
			if (defined $target) {
				my @now = localtime($fallback / 1000);
				my $delta = ($target - $now[6] + 7) % 7;
				$delta = $delta == 0 ? -7 : $delta - 7 if $modifier eq 'last';
				$delta = $delta == 0 ? 7 : $delta if $modifier eq 'next';
				$ms = &subs::calendar_shift(&subs::calendar_shift($fallback, 0, 'day'), $delta, 'day');
			}
		}
		# a spelled relative day ("3 days ago", "in 2 weeks", "a month ago"):
		# a bare amount points into the past, as the clock's own time machine does
		if (!defined $ms && $day =~ /^\s*(?:in\s+)?(a|an|\d+)\s*(day|week|month|year)s?\s*(ago)?\s*$/i) {
			# copy the captures before the next match clears them
			my ($count_text, $unit, $ago) = ($1, lc $2, $3);
			my $count = ($count_text =~ /^\d+$/) ? $count_text + 0 : 1;
			my $forward = !$ago && $day =~ /^\s*in\b/i;
			$count = -$count unless $forward;
			$ms = &subs::calendar_shift($fallback, $count, $unit);
		}
		if (!defined $ms && $day =~ /^\s*(last|next)\s+(day|week|month|year)\s*$/i) {
			my $count = (lc $1 eq 'next') ? 1 : -1;
			$ms = &subs::calendar_shift($fallback, $count, lc $2);
		}
		unless (defined $ms) {
			my $parsed = eval { str2time($day) };
			$ms = $parsed * 1000 if $parsed;
		}
	}
	my $unread = (defined $day && $day =~ /\S/ && !defined $ms) ? 1 : 0;
	$ms = $fallback unless defined $ms;
	my @fallback = localtime($fallback / 1000);
	my @chosen = localtime($ms / 1000);
	my $start = eval { timelocal(0, 0, 0, $chosen[3], $chosen[4], $chosen[5]) };
	$start = $ms unless defined $start;
	$start = $start * 1000;
	my $end = &subs::calendar_shift($start, 1, 'day');
	my $today = eval { timelocal(0, 0, 0, $fallback[3], $fallback[4], $fallback[5]) };
	$today = $fallback unless defined $today;
	$today = $today * 1000;
	return { start => $start, end => $end, today => $today, ms => $ms, unread => $unread };
}

sub handbook_money_number {
	my ($row) = @_;
	my $value = $row->{'total'};
	$value = $row->{'amount'} unless defined $value && $value =~ /[0-9]/;
	return &subs::numeric_formatter($value) + 0;
}

sub handbook_money_value {
	my ($row) = @_;
	return abs(&handbook_money_number($row));
}

sub handbook_plant_time {
	my ($when, $kind, $now) = @_;
	$now = &subs::rightNow() unless defined $now && $now;
	my $ms;
	if (defined $when && $when =~ /\S/) {
		$ms = &subs::resolve_when($when, $now);
		unless (defined $ms) {
			my $bounds = &handbook_day_bounds($when, $now);
			$ms = $bounds->{'ms'} unless $bounds->{'unread'};
		}
	}
	my $days = $kind eq 'plan' ? 7 : $kind eq 'dream' ? 365 : 30;
	my @n = localtime($now / 1000);
	my $today = eval { timelocal(0, 0, 0, $n[3], $n[4], $n[5]) };
	$today = $now unless defined $today;
	$today = $today * 1000;
	$ms = &subs::calendar_shift($now, $days, 'day') unless defined $ms && $ms >= $today;
	my @d = localtime($ms / 1000);
	my $noon = eval { timelocal(0, 0, 12, $d[3], $d[4], $d[5]) };
	return defined $noon ? $noon * 1000 : $ms;
}

sub handbook_journal_entries {
	my ($from, $to, $limit) = @_;
	$limit ||= 50;
	my @entries;
	my %seen;
	my $appts = eval { &subs::db_query("select uuid,timestamp from appointments where app='journal' and type='note' and cast(timestamp as integer) >= ? and cast(timestamp as integer) < ? order by cast(timestamp as integer) desc limit ?", $from, $to, $limit)->hashes } || [];
	foreach my $row ( @{$appts} ) {
		my $text = &subs::note_retriever('journal', $row->{'uuid'}) || '';
		$text =~ s/<br\s*\/?>/\n/gi;
		$text =~ s/<[^>]+>//g;
		$text =~ s/&nbsp;/ /g;
		$text =~ s/\s+/ /g;
		$text =~ s/^\s+|\s+$//g;
		next unless length $text;
		my $key = ($row->{'timestamp'} || 0) . '|' . substr($text, 0, 200);
		next if $seen{$key}++;
		push @entries, {
			text => $text,
			snippet => length($text) > 160 ? substr($text, 0, 160) . '...' : $text,
			timestamp => $row->{'timestamp'} || 0,
			source => 'journal',
		};
	}
	my $notes = eval { &subs::db_query('select text,timestamp from notes where cast(timestamp as integer) >= ? and cast(timestamp as integer) < ? order by cast(timestamp as integer) desc limit ?', $from, $to, $limit)->hashes } || [];
	foreach my $note ( @{$notes} ) {
		my $text = defined $note->{'text'} ? $note->{'text'} : '';
		$text =~ s/\s+/ /g;
		$text =~ s/^\s+|\s+$//g;
		next unless length $text;
		my $key = ($note->{'timestamp'} || 0) . '|' . substr($text, 0, 200);
		next if $seen{$key}++;
		push @entries, {
			text => $text,
			snippet => length($text) > 160 ? substr($text, 0, 160) . '...' : $text,
			timestamp => $note->{'timestamp'} || 0,
			source => 'notes',
		};
	}
	@entries = sort { ($b->{'timestamp'} || 0) <=> ($a->{'timestamp'} || 0) } @entries;
	@entries = @entries[0 .. $limit - 1] if scalar @entries > $limit;
	return \@entries;
}

sub handbook_journal_write {
	my ($c, $text, $bounds, $now) = @_;
	$text =~ s/^\s+|\s+$//g;
	return undef unless length $text;
	$text = substr($text, 0, 20000);
	$now ||= &subs::rightNow();
	my $timestamp = $bounds->{'start'} + 12 * 3600000;
	$timestamp = $now if $bounds->{'start'} == $bounds->{'today'} && $now >= $bounds->{'start'} && $now < $bounds->{'end'};
	my $suds = eval { &subs::session_suds($c) } || &subs::suds_grabber();
	my $settings = &subs::settings_grabber({ app => 'journal' });
	my $uuid = &subs::random_string_creator(90);
	&subs::db_insert('appointments', {
		app => 'journal',
		type => 'note',
		timestamp => $timestamp,
		server_time => $now,
		start_notes => &subs::note_encrypter($suds, $text),
		ost => $now,
		duration => 5000,
		seen => 'yes',
		pos => $settings->{'pos'} || 'idea',
		project => $settings->{'t_project'} || 'personal',
		source => 'handbook',
		uuid => $uuid,
		device => &subs::device_setter(),
	});
	&Websocket::send('tab', { console => 'calculator();' });
	return { uuid => $uuid, timestamp => $timestamp };
}

1;
