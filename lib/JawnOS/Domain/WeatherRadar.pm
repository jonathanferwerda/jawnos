package subs;

# WeatherRadar: the Weather app's radar timeline. The free RainViewer feed only
# publishes two hours of past frames; to keep a day, this module records the
# tiles for a window around the house plate into public/radar/ and prunes them
# after the configured number of hours. The same timeline can carry a model
# rain forecast from Open-Meteo, sampled on a small grid for the next 24-72
# hours. Only the house server records; every machine can read its own live
# frames and the model forecast.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use Math::Trig qw(pi);
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::Util qw(md5_sum);

our $device;
our $log;

my $API_URL = 'https://api.rainviewer.com/public/weather-maps.json';
my $FORECAST_URL = 'https://api.open-meteo.com/v1/forecast';
my $ARCHIVE_Z = 7;
my $ARCHIVE_ACROSS = 5;
my $FORECAST_COLS = 17;
my $FORECAST_ROWS = 17;
my $FORECAST_STEP = 0.25;

sub weather_radar_setting($name, $default = '') {
	my $value = eval { &setting_grabber({ app => 'weather', setting => $name, device => 'all' }) };
	return (defined $value && length $value) ? $value : $default;
}

sub weather_radar_hours() {
	my $hours = int(weather_radar_setting('radar_hours', 24) || 24);
	$hours = 6 if $hours < 6;
	$hours = 72 if $hours > 72;
	return $hours;
}

sub weather_radar_record_enabled() {
	return weather_radar_setting('radar_record', 'on') ne 'off' ? 1 : 0;
}

sub weather_radar_forecast_enabled() {
	return weather_radar_setting('radar_forecast', 'on') ne 'off' ? 1 : 0;
}

sub weather_radar_forecast_hours() {
	my $hours = int(weather_radar_setting('radar_forecast_hours', 72) || 72);
	$hours = 6 if $hours < 6;
	$hours = 72 if $hours > 72;
	return $hours;
}

sub weather_radar_dir() {
	return 'public/radar';
}

# Web Mercator tile coordinates for a point, and the square window recorded
# around it. Longitude wraps; latitude is clamped by the caller.
sub weather_radar_tile_window($lat, $lon, $z = $ARCHIVE_Z, $across = $ARCHIVE_ACROSS) {
	$lat = 85.0511 if $lat > 85.0511;
	$lat = -85.0511 if $lat < -85.0511;
	my $n = 2 ** $z;
	my $nx = int((($lon + 180) / 360) * $n);
	my $rad = $lat * pi / 180;
	my $ny = int((0.5 - log((1 + sin($rad)) / (1 - sin($rad))) / (4 * pi)) * $n);
	my $half = int($across / 2);
	my @tiles;
	for my $dy (-$half .. $half) {
		my $y = $ny + $dy;
		next if $y < 0 || $y >= $n;
		for my $dx (-$half .. $half) {
			my $x = (($nx + $dx) % $n + $n) % $n;
			push @tiles, [ $x, $y ];
		}
	}
	return (\@tiles, $n);
}

# The raw image bytes. The JSON helper would try to decode a PNG, so this one
# asks only for a successful image response.
sub weather_radar_image_bytes($url, $ua) {
	return undef unless defined $url && length $url;
	my $res = eval {
		$ua->get($url => {
			'User-Agent' => 'JawnOS Weather (weather@jawnos.local)',
			'Accept' => 'image/png,image/*;q=0.8',
		})->result;
	};
	return undef unless $res && $res->is_success;
	my $type = $res->headers->content_type || '';
	return undef unless $type =~ m{^image/};
	my $body = $res->body;
	return (defined $body && length $body) ? $body : undef;
}

# One pass: read the feed, record every frame not in the manifest, prune the
# frames older than the retention, and keep the manifest in the cache. The
# frames are RainViewer's content-addressed paths, and the tiles are ours.
sub weather_radar_record_tick($opts = {}) {
	$opts ||= {};
	return { skipped => 'radar recording is off' } unless weather_radar_record_enabled();
	# A computer or server keeps the archive; a handheld reads its live two hours
	# and the model forecast instead of filling its own storage with a day of
	# tiles. The archive is local files, so two computers recording is harmless.
	my $purpose = &subs::device_setter() // '';
	return { skipped => 'a handheld does not keep the radar archive' }
		unless $purpose =~ /^(?:computer|server)$/;
	my $home = eval { &weather_home_plate() };
	return { skipped => 'no home plate' } unless ref $home eq 'HASH'
		&& defined $home->{'lat'} && defined $home->{'lon'};
	my $hours = weather_radar_hours();
	my $z = $ARCHIVE_Z;
	my $root = $opts->{'dir'} || weather_radar_dir();
	my ($tiles, $n) = weather_radar_tile_window($home->{'lat'}, $home->{'lon'}, $z, $ARCHIVE_ACROSS);
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 7, request_timeout => 10);
	my ($feed) = &weather_http_get($API_URL, $ua);
	return { skipped => 'the radar feed did not answer' } unless ref $feed eq 'HASH';
	my $host = $feed->{'host'} || 'https://tilecache.rainviewer.com';
	my $cached = eval { &cache_get({ app => 'weather', context => 'radar_archive', subcontext => 'v1' }) } || {};
	my %have = map { (0 + ($_->{'time'} || 0)) => $_ } @{ ref $cached->{'frames'} eq 'ARRAY' ? $cached->{'frames'} : [] };
	my @feed = (
		@{ ref $feed->{'radar'}{'past'} eq 'ARRAY' ? $feed->{'radar'}{'past'} : [] },
		@{ ref $feed->{'radar'}{'nowcast'} eq 'ARRAY' ? $feed->{'radar'}{'nowcast'} : [] },
	);
	my ($added, $written) = (0, 0);
	foreach my $frame (@feed) {
		next unless ref $frame eq 'HASH' && defined $frame->{'path'} && defined $frame->{'time'};
		my $time = int($frame->{'time'});
		next if $have{$time};
		my $dir = sprintf('%s/%d', $root, $time);
		my $ok = 1;
		my $bytes = 0;
		foreach my $tile (@{$tiles}) {
			my ($x, $y) = @{$tile};
			my $url = sprintf('%s%s/256/%d/%d/%d/2/1_1.png', $host, $frame->{'path'}, $z, $x, $y);
			my $body = weather_radar_image_bytes($url, $ua);
			if (!defined $body) { $ok = 0; last; }
			my $file = sprintf('%s/%d/%d/%d.png', $dir, $z, $x, $y);
			eval { make_path(dirname($file)); path($file)->spew($body); 1 };
			if (!-s $file) { $ok = 0; last; }
			$bytes += length $body;
			$written++;
		}
		if ($ok) {
			$have{$time} = { time => $time, local => 1, bytes => $bytes };
			$added++;
		}
		else {
			eval { remove_tree($dir) if -d $dir; 1 };
		}
	}
	# Prune whole frame directories, so a deleted frame leaves no orphan tiles.
	my $cutoff = int(&rightNow() / 1000) - $hours * 3600;
	foreach my $time (keys %have) {
		next if $time >= $cutoff;
		my $dir = sprintf('%s/%d', $root, $time);
		eval { remove_tree($dir) if -d $dir; 1 };
		delete $have{$time};
	}
	my @frames = sort { $a->{'time'} <=> $b->{'time'} } values %have;
	my $bytes = 0;
	$bytes += ($_->{'bytes'} || 0) for @frames;
	my $state = {
		frames => \@frames,
		z => $z,
		across => $ARCHIVE_ACROSS,
		at => &rightNow(),
		hours => $hours,
		bytes => $bytes,
		center => { lat => 0 + $home->{'lat'}, lon => 0 + $home->{'lon'} },
	};
	eval { &cache_set({ app => 'weather', context => 'radar_archive', subcontext => 'v1', warranty => '-4d' }, $state) };
	return {
		ok => 1,
		added => $added,
		written => $written,
		frames => scalar @frames,
		bytes => $bytes,
		hours => $hours,
	};
}

# What the Radar panel and the Plat -> Weather pill read. The frames carry only
# their time; the client builds /radar/<time>/<z>/<x>/<y>.png from the recorded
# window, and falls back to the live feed for the newest two hours.
sub weather_radar_archive_state() {
	my $purpose = &subs::device_setter() // '';
	my $cached = eval { &cache_get({ app => 'weather', context => 'radar_archive', subcontext => 'v1' }) } || {};
	my @frames = map {
		{ time => 0 + ($_->{'time'} || 0), local => 1 }
	} grep { ref $_ eq 'HASH' && $_->{'time'} } @{ ref $cached->{'frames'} eq 'ARRAY' ? $cached->{'frames'} : [] };
	return {
		frames => \@frames,
		z => $cached->{'z'} || $ARCHIVE_Z,
		across => $cached->{'across'} || $ARCHIVE_ACROSS,
		at => $cached->{'at'},
		bytes => $cached->{'bytes'} || 0,
		center => $cached->{'center'},
		hours => weather_radar_hours(),
		record => weather_radar_record_enabled(),
		forecast => weather_radar_forecast_enabled(),
		forecast_hours => weather_radar_forecast_hours(),
		recorder => (($purpose =~ /^(?:computer|server)$/) ? 1 : 0),
	};
}

# A small grid of model rain for the place on screen. Hourly steps keep the
# request small; the chart labels them as model frames rather than radar.
sub weather_radar_forecast_grid($opts = {}) {
	$opts ||= {};
	my $lat = &weather_number($opts->{'lat'});
	my $lon = &weather_number($opts->{'lon'});
	my $empty = { enabled => weather_radar_forecast_enabled(), frames => [], source => 'Open-Meteo' };
	return $empty unless defined $lat && defined $lon;
	my $hours = weather_radar_forecast_hours();
	my $cols = $FORECAST_COLS;
	my $rows = $FORECAST_ROWS;
	my $step = $FORECAST_STEP;
	my @lats;
	my @lons;
	for my $r (0 .. $rows - 1) {
		for my $c (0 .. $cols - 1) {
			push @lats, sprintf('%.4f', $lat + ($r - ($rows - 1) / 2) * $step);
			push @lons, sprintf('%.4f', $lon + ($c - ($cols - 1) / 2) * $step);
		}
	}
	my $key = substr(md5_sum(sprintf('forecast|%.3f|%.3f|%d|%d|%.2f', $lat, $lon, $hours, $cols, $step)), 0, 24);
	my $cached = eval { &cache_get({ app => 'weather', context => 'radar_forecast', subcontext => $key }) };
	return $cached if ref $cached eq 'HASH' && ($cached->{'server_time'} || 0) > &rightNow() - 3 * 60 * 60 * 1000;
	my $ua = Mojo::UserAgent->new(connect_timeout => 5, inactivity_timeout => 10, request_timeout => 25);
	my $url = $FORECAST_URL
		. '?latitude=' . join(',', @lats)
		. '&longitude=' . join(',', @lons)
		. '&hourly=precipitation&forecast_hours=' . $hours . '&timezone=GMT';
	my ($json) = &weather_http_get($url, $ua);
	return { %{$empty}, error => &subs::ui('The model rain forecast is unavailable right now.') }
		unless ref $json eq 'ARRAY' && scalar @{$json};
	my $times = ref $json->[0]{'hourly'}{'time'} eq 'ARRAY' ? $json->[0]{'hourly'}{'time'} : [];
	my @frames;
	my $max = 0;
	for my $i (0 .. $#{$times}) {
		my @values;
		for my $p (0 .. $#lats) {
			my $value = &weather_number($json->[$p]{'hourly'}{'precipitation'}[$i]);
			$value = 0 unless defined $value;
			push @values, 0 + $value;
			$max = $value if $value > $max;
		}
		push @frames, { time => $times->[$i], values => \@values };
	}
	my $out = {
		enabled => 1,
		source => 'Open-Meteo',
		center => { lat => 0 + $lat, lon => 0 + $lon },
		step => $step,
		cols => $cols,
		rows => $rows,
		hours => $hours,
		max => 0 + sprintf('%.2f', $max),
		unit => 'mm/h',
		frames => ($max > 0.02 ? \@frames : []),
		server_time => &rightNow(),
		($max > 0.02 ? () : (note => &subs::ui(sprintf('The model has no rain over this place in the next %d hours.', $hours)))),
	};
	eval { &cache_set({ app => 'weather', context => 'radar_forecast', subcontext => $key, warranty => '-4h' }, $out) };
	return $out;
}

1;
