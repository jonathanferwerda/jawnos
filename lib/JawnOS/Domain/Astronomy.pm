package subs;

# Astronomy: the sky the house lives under, computed locally. The moon's
# phase is arithmetic (the same Meeus series Schedule uses for full moons), so
# a new house needs no scraper and no API key. Space weather comes from NOAA's
# Space Weather Prediction Center, cached and allowed to fail quietly: the
# Weather app may lose the geomagnetic line, but it must not lose the weather.
#
# The readings are written as ordinary measure appointments - one row a day,
# merged in place - so the evaluation sees them through measure_series and the
# Inventory graphs them like any other reading.
#
# Loaded on demand by lib/JawnOS/Domain/Loader.pm.
use strict;
use warnings;
use utf8;
use feature 'signatures';
no warnings 'experimental::signatures';
no warnings 'experimental::args_array_with_signatures';

use Math::Trig qw(deg2rad pi);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::Util qw(md5_sum);
use POSIX ();
use Time::Local qw(timegm);

our $device;

my $SYNODIC_DAYS = 29.530588853;

# ---- the moon --------------------------------------------------------------

# The phase between two full moons, read from the same series Schedule.pm uses.
# 0 is a full moon, 0.5 a new moon, 1 the next full moon. The illuminated
# fraction follows the cosine of that angle, which is what the eye sees.
sub moon_phase ($timestamp = undef) {
	$timestamp = &rightNow() unless defined $timestamp && $timestamp =~ /^[0-9]+$/;
	# The lunation number nearest this moment, not the one at the start of the
	# year: a November date is ten cycles past January, and a narrow window
	# around January would clamp it to the last full moon in the list.
	my $jd = int($timestamp / 1000) / 86400 + 2440587.5;
	my $k = int(($jd - 2451550.09766) / $SYNODIC_DAYS);
	my @full;
	for my $i (-2 .. 2) {
		my $ts = eval { &moon_full_ts($k + $i + 0.5) };
		push @full, $ts if defined $ts && $ts > 0;
	}
	@full = sort { $a <=> $b } @full;
	# A missing Schedule module must not take the Weather app down.
	unless (scalar @full >= 2) {
		my $days = (($timestamp / 1000) - 947182440) / 86400;
		$days -= int($days / $SYNODIC_DAYS) * $SYNODIC_DAYS;
		my $phase = $days / $SYNODIC_DAYS;
		return _moon_answer($timestamp, $phase, 'synodic');
	}
	my ($prev, $next);
	foreach my $ts (@full) {
		if ($ts <= $timestamp) { $prev = $ts; next; }
		$next = $ts;
		last;
	}
	$prev = $full[0] unless defined $prev;
	$next = $full[-1] unless defined $next;
	my $span = ($next - $prev) || ($SYNODIC_DAYS * 86400000);
	my $between = ($timestamp - $prev) / $span;
	$between = 0 if $between < 0;
	$between = 1 if $between > 1;
	# phase 0 is new: shift the full-moon fraction by half a cycle
	my $phase = ($between + 0.5) - int($between + 0.5);
	return _moon_answer($timestamp, $phase, 'series');
}

sub _moon_answer ($timestamp, $phase, $source) {
	$phase = 0 if $phase < 0;
	$phase -= 1 if $phase >= 1;
	my $illumination = (1 - cos(2 * pi * $phase)) / 2;
	my $percent = int($illumination * 100 + 0.5);
	my ($key, $name) = &moon_phase_name($phase);
	return {
		timestamp => $timestamp + 0,
		phase => 0 + sprintf('%.5f', $phase),
		age_days => 0 + sprintf('%.2f', $phase * $SYNODIC_DAYS),
		illumination => $percent,
		waxing => ($phase < 0.5 ? 1 : 0),
		phase_key => $key,
		phase_name => $name,
		source => $source,
	};
}

# The eight names a person uses. The edges sit half a day either side of the
# exact quarters, so "almost full" still reads as full.
sub moon_phase_name ($phase) {
	$phase = 0 unless defined $phase && $phase =~ /^-?[0-9.]+$/;
	$phase -= 1 if $phase >= 1;
	$phase += 1 if $phase < 0;
	my @bands = (
		[ 0.03125, 'new_moon',        'New moon' ],
		[ 0.21875, 'waxing_crescent', 'Waxing crescent' ],
		[ 0.28125, 'first_quarter',   'First quarter' ],
		[ 0.46875, 'waxing_gibbous',  'Waxing gibbous' ],
		[ 0.53125, 'full_moon',       'Full moon' ],
		[ 0.71875, 'waning_gibbous',  'Waning gibbous' ],
		[ 0.78125, 'last_quarter',    'Last quarter' ],
		[ 0.96875, 'waning_crescent', 'Waning crescent' ],
	);
	foreach my $band (@bands) {
		return ($band->[1], $band->[2]) if $phase < $band->[0];
	}
	return ('new_moon', 'New moon');
}

# What the Weather app shows: the computed phase, with the house's own recorded
# illumination preferred when it is fresh (it is the number the Moon app shows).
sub moon_current ($opts = {}) {
	$opts ||= {};
	my $ts = $opts->{'timestamp'} || &rightNow();
	my $moon = &moon_phase($ts);
	my $row = eval {
		&db_query(
			"select timestamp, measures from appointments where app = 'moon' and measures is not null and measures != '' order by cast(timestamp as integer) desc limit 1"
		)->hash;
	};
	if ($row && ($row->{'timestamp'} || 0) > $ts - 36 * 3600 * 1000) {
		my $list = eval { decode_json($row->{'measures'} || '') } || [];
		my $latest = ref $list eq 'ARRAY' ? ($list->[-1] || {}) : {};
		if (defined $latest->{'illumination'} && $latest->{'illumination'} =~ /^-?[0-9.]+$/) {
			$moon->{'illumination'} = int($latest->{'illumination'} + 0.5);
			$moon->{'source'} = 'moon_app';
		}
		if (defined $latest->{'lunar_phase'} && length $latest->{'lunar_phase'}) {
			$moon->{'phase_name'} = $latest->{'lunar_phase'};
			my $key = lc($latest->{'lunar_phase'});
			$key =~ s/[^a-z]+/_/g;
			$key =~ s/^_|_$//g;
			$moon->{'phase_key'} = $key if length $key;
		}
	}
	$moon->{'southern'} = (defined $opts->{'lat'} && $opts->{'lat'} < 0) ? 1 : 0;
	return $moon;
}

# ---- space weather ---------------------------------------------------------

my $Kp_URL = 'https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json';
my $MAG_URL = 'https://services.swpc.noaa.gov/json/rtsw/rtsw_mag_1m.json';
my $WIND_URL = 'https://services.swpc.noaa.gov/json/rtsw/rtsw_wind_1m.json';

# NOAA sends two shapes: a product table ([header, row, row...]) and an array
# of objects. Read the last row of either, and map the names we ask for.
sub _noaa_row ($json, $want) {
	return {} unless ref $json eq 'ARRAY' && scalar @{$json};
	my %out;
	if (ref $json->[0] eq 'HASH') {
		my $row = $json->[-1] || {};
		foreach my $key (@{$want}) {
			$out{$key} = $row->{$key} if defined $row->{$key};
		}
		$out{'time_tag'} = $row->{'time_tag'} if defined $row->{'time_tag'};
		return \%out;
	}
	my $header = $json->[0];
	return {} unless ref $header eq 'ARRAY';
	my %at;
	for my $i (0 .. $#{$header}) { $at{ $header->[$i] } = $i if defined $header->[$i]; }
	my $row = $json->[-1] || [];
	foreach my $key (@{$want}, 'time_tag') {
		my $i = $at{$key};
		next unless defined $i && defined $row->[$i];
		$out{$key} = $row->[$i];
	}
	return \%out;
}

sub _noaa_time ($text) {
	return 0 unless defined $text && length $text;
	my $s = $text;
	$s =~ s/T/ /g;
	$s =~ s/Z$//;
	$s =~ s/\.\d+$//;
	my ($y, $mo, $d, $h, $mi, $sec) = $s =~ /^(\d{4})-(\d{2})-(\d{2})(?:\s+(\d{2}):(\d{2})(?::(\d{2}))?)?/;
	return 0 unless $y;
	return timegm($sec || 0, $mi || 0, $h || 0, $d, $mo - 1, $y) * 1000;
}

sub _noaa_number ($v) {
	return undef unless defined $v && !ref $v && $v =~ /^-?[0-9]+(?:\.[0-9]+)?$/;
	return 0 + $v;
}

# The Kp bands a person reads. Kp is a 0-9 scale, updated every three hours.
sub space_weather_label ($kp) {
	return ('Unknown', 0) unless defined $kp && $kp =~ /^-?[0-9.]+$/;
	return ('Quiet', 1) if $kp < 4;
	return ('Unsettled', 2) if $kp < 5;
	return ('Active', 3) if $kp < 6;
	return ('Minor storm', 4) if $kp < 7;
	return ('Moderate storm', 5) if $kp < 8;
	return ('Strong storm', 6);
}

# Turn the three NOAA answers into one reading. Missing pieces stay missing;
# a quiet failure is better than a Weather app that will not draw.
sub space_weather_parse ($kp_json, $mag_json, $wind_json) {
	my $kp_row = &_noaa_row($kp_json, [ 'Kp' ]);
	my $mag_row = &_noaa_row($mag_json, [ 'bz_gsm', 'by_gsm', 'bx_gsm', 'bt' ]);
	my $wind_row = &_noaa_row($wind_json, [ 'speed', 'density', 'temperature', 'proton_speed', 'proton_density', 'proton_temperature' ]);
	my $kp = &_noaa_number($kp_row->{'Kp'});
	my $bz = &_noaa_number($mag_row->{'bz_gsm'});
	my $bt = &_noaa_number($mag_row->{'bt'});
	my $speed = &_noaa_number(defined $wind_row->{'speed'} ? $wind_row->{'speed'} : $wind_row->{'proton_speed'});
	my $density = &_noaa_number(defined $wind_row->{'density'} ? $wind_row->{'density'} : $wind_row->{'proton_density'});
	# The last 24 hours of Kp, so the day has a peak as well as a now.
	my $max_kp;
	my $last_kp_at = 0;
	my $kp_at = &_noaa_time($kp_row->{'time_tag'});
	my $take_kp = sub {
		my ($when, $v) = @_;
		return unless $when && defined $v;
		return unless $when >= $kp_at - 24 * 3600 * 1000;
		$max_kp = $v if !defined $max_kp || $v > $max_kp;
		$last_kp_at = $when if $when > $last_kp_at;
	};
	if (ref $kp_json eq 'ARRAY' && scalar @{$kp_json}) {
		if (ref $kp_json->[0] eq 'HASH') {
			foreach my $row ( @{$kp_json} ) {
				$take_kp->(&_noaa_time($row->{'time_tag'}), &_noaa_number($row->{'Kp'}));
			}
		}
		elsif (ref $kp_json->[0] eq 'ARRAY' && scalar @{$kp_json} > 1) {
			my $header = $kp_json->[0];
			my %at;
			for my $i (0 .. $#{$header}) { $at{ $header->[$i] } = $i; }
			if (defined $at{'Kp'} && defined $at{'time_tag'}) {
				foreach my $row ( @{$kp_json}[1 .. $#{$kp_json}] ) {
					$take_kp->(&_noaa_time($row->[ $at{'time_tag'} ]), &_noaa_number($row->[ $at{'Kp'} ]));
				}
			}
		}
	}
	my @times = grep { $_ > 0 } ($kp_at, &_noaa_time($mag_row->{'time_tag'}), &_noaa_time($wind_row->{'time_tag'}));
	my ($label, $level) = &space_weather_label($kp);
	return {
		kp => $kp,
		kp_max_24h => (defined $max_kp ? $max_kp : $kp),
		bz => $bz,
		bt => $bt,
		solar_wind_speed => $speed,
		solar_wind_density => $density,
		label => $label,
		level => $level,
		observed_at => ($last_kp_at || ($times[-1] || 0)) + 0,
		source => 'NOAA SWPC',
	};
}

sub space_weather_fetch ($opts = {}) {
	$opts ||= {};
	my $cached = eval { &cache_get({ app => 'space_weather', context => 'current' }) };
	return $cached if !$opts->{'force'} && ref $cached eq 'HASH' && ($cached->{'server_time'} || 0) > &rightNow() - 10 * 60 * 1000;
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 7, request_timeout => 12);
	my ($kp_json) = &weather_http_get($Kp_URL, $ua);
	my ($mag_json) = &weather_http_get($MAG_URL, $ua);
	my ($wind_json) = &weather_http_get($WIND_URL, $ua);
	my $reading = &space_weather_parse($kp_json, $mag_json, $wind_json);
	my $got = grep { defined $reading->{$_} } qw(kp bz solar_wind_speed solar_wind_density);
	unless ($got) {
		return { %{ ref $cached eq 'HASH' ? $cached : {} }, error => 'Space weather is unavailable right now.' };
	}
	$reading->{'server_time'} = &rightNow();
	eval { &cache_set({ app => 'space_weather', context => 'current', warranty => '-10m' }, $reading) };
	return $reading;
}

# ---- measure rows ----------------------------------------------------------

my %MOON_MEASURES = (
	illumination => { type => 'number', min => 0, max => 100, unit => '%' },
	moon_phase => { type => 'number', min => 0, max => 1, unit => '' },
	moon_age_days => { type => 'number', min => 0, max => 29.6, unit => 'days' },
	lunar_phase => { type => 'text' },
);
my %SPACE_MEASURES = (
	kp => { type => 'number', min => 0, max => 9, unit => 'Kp' },
	kp_max_24h => { type => 'number', min => 0, max => 9, unit => 'Kp' },
	bz => { type => 'number', min => -30, max => 30, unit => 'nT' },
	bt => { type => 'number', min => 0, max => 100, unit => 'nT' },
	solar_wind_speed => { type => 'number', min => 0, max => 2000, unit => 'km/s' },
	solar_wind_density => { type => 'number', min => 0, max => 100, unit => 'p/cm³' },
);

# Teach an app its measures and, once, what kind of thing it is. Values already
# chosen are left alone; this only fills what is missing.
sub astronomy_measure_defaults ($app) {
	return 0 unless defined $app && length $app;
	my $defs = $app eq 'space_weather' ? \%SPACE_MEASURES : $app eq 'moon' ? \%MOON_MEASURES : {};
	return 0 unless scalar keys %{$defs};
	my $own = eval { decode_json(&setting_grabber({ app => $app, setting => 'app_measures' }) || '') } || {};
	my $changed = 0;
	foreach my $key ( sort keys %{$defs} ) {
		next if ref $own->{$key} eq 'HASH';
		$own->{$key} = { %{ $defs->{$key} } };
		$changed = 1;
	}
	&setting_setter({ app => $app, setting => 'app_measures', value => encode_json($own) }) if $changed;
	# Every one of these is a reading, not an event: a sum would be nonsense.
	foreach my $key ( grep { ($defs->{$_}->{'type'} || '') eq 'number' } sort keys %{$defs} ) {
		my $calc = &setting_grabber({ app => $app, setting => 'measure_calc', subsetting => $key });
		&setting_setter({ app => $app, setting => 'measure_calc', subsetting => $key, value => 'average' })
			unless defined $calc && length $calc;
	}
	my %facts = $app eq 'space_weather'
		? (category => 'nature', subcategory => 'space', colour => '#7b68ee')
		: (category => 'nature', subcategory => 'sky', colour => '#40bfbf');
	foreach my $key ( sort keys %facts ) {
		my $have = &setting_grabber({ app => $app, setting => $key });
		&setting_setter({ app => $app, setting => $key, value => $facts{$key} })
			unless defined $have && length $have;
	}
	# A local source never needs the web scraper, on this house or a new one.
	&setting_setter({ app => $app, setting => 'local_source', value => 'on' });
	return 1;
}

# One measure row a day, merged in place. A second pass (a restart, a peer, a
# backfill overlapping the daily tick) updates the same row rather than adding
# a second reading of the same day.
sub astronomy_measure_write ($app, $values, $timestamp = undef, $opts = {}) {
	return undef unless defined $app && length $app;
	return undef unless ref $values eq 'HASH' && scalar keys %{$values};
	$timestamp = &rightNow() unless defined $timestamp && $timestamp =~ /^[0-9]+$/;
	$opts ||= {};
	&astronomy_measure_defaults($app);
	my ($day_begin, $day_end) = &period_bounds('day', $timestamp, 0);
	my $rows = eval {
		&db_query(
			"select uuid, timestamp, measures from appointments where app = ? and type = 'measure'"
			. " and cast(timestamp as integer) >= ? and cast(timestamp as integer) < ?"
			. " order by cast(timestamp as integer) desc",
			$app, $day_begin, $day_end
		)->hashes;
	} || [];
	my $want = { %{$values} };
	delete $want->{location};
	my $entry_ts = $timestamp + 0;
	my $clean = sub {
		my ($v) = @_;
		return undef unless defined $v && !ref $v && length "$v";
		return "$v" =~ /^-?[0-9]+(?:\.[0-9]+)?$/ ? 0 + $v : "$v";
	};
	if (my $row = $rows->[0]) {
		my $measures = eval { decode_json($row->{'measures'} || '') } || [];
		$measures = [] unless ref $measures eq 'ARRAY';
		my $entry = $measures->[-1];
		$entry = {} unless ref $entry eq 'HASH';
		my $dirty = 0;
		foreach my $key ( sort keys %{$want} ) {
			my $value = $clean->($want->{$key});
			next unless defined $value;
			next if defined $entry->{$key} && "$entry->{$key}" eq "$value";
			$entry->{$key} = $value;
			$dirty = 1;
		}
		return $row->{'uuid'} unless $dirty;
		$entry->{'ts'} = $entry_ts;
		$entry->{'uuid'} ||= substr(md5_sum($app . '-' . $row->{'uuid'} . '-' . $entry_ts), 0, 32);
		$measures->[-1] = $entry;
		&db_update('appointments',
			{ measures => encode_json($measures), server_time => &rightNow() },
			{ uuid => $row->{'uuid'}, app => $app });
		return $row->{'uuid'};
	}
	my @clean;
	my %entry;
	foreach my $key ( sort keys %{$want} ) {
		my $value = $clean->($want->{$key});
		next unless defined $value;
		$entry{$key} = $value;
	}
	return undef unless scalar keys %entry;
	my $uuid = substr(md5_sum("$app-$day_begin-" . ($opts->{'seed'} || 'astronomy')), 0, 32);
	$entry{'ts'} = $entry_ts;
	$entry{'uuid'} = $uuid . '-astronomy';
	&db_insert('appointments', {
		app => $app,
		timestamp => $day_begin + 12 * 3600 * 1000,
		type => 'measure',
		duration => 1000,
		measures => encode_json([ \%entry ]),
		uuid => $entry{'uuid'},
		server_time => &rightNow(),
		device => (&subs::device_setter() // ''),
		source => 'astronomy',
	});
	return $entry{'uuid'};
}

# The daily job: compute the moon for today and record it; pull the space
# weather and record it. Both writers are idempotent, so a repeated tick is
# cheap and a second machine cannot double the day's reading.
sub astronomy_tick ($opts = {}) {
	$opts ||= {};
	# One machine records the sky, the same leader that records the weather. The
	# writer would merge a second machine's identical day anyway; this keeps the
	# sync from carrying it.
	return { skipped => 'not the house leader' } unless &weather_observe_leader();
	my $now = $opts->{'timestamp'} || &rightNow();
	my $moon = &moon_phase($now);
	&astronomy_measure_write('moon', {
		illumination => $moon->{'illumination'},
		moon_phase => $moon->{'phase'},
		moon_age_days => $moon->{'age_days'},
		lunar_phase => $moon->{'phase_name'},
	}, $now);
	my $space = &space_weather_fetch({ force => $opts->{'force'} });
	my $space_written = 0;
	if ($space && !$space->{'error'}) {
		&astronomy_measure_write('space_weather', {
			kp => $space->{'kp'},
			kp_max_24h => $space->{'kp_max_24h'},
			bz => $space->{'bz'},
			bt => $space->{'bt'},
			solar_wind_speed => $space->{'solar_wind_speed'},
			solar_wind_density => $space->{'solar_wind_density'},
		}, $now);
		$space_written = 1;
	}
	return {
		moon => $moon,
		space_weather => $space,
		space_written => $space_written,
	};
}

# Fill the moon's own history from the arithmetic. Existing rows are merged,
# never deleted, so a scraped value the person already has is only replaced
# where this run has a computed value for the same measure.
sub astronomy_backfill ($opts = {}) {
	$opts ||= {};
	my $app = $opts->{'app'} || 'moon';
	my $now = $opts->{'to'} || &rightNow();
	my $days = $opts->{'days'};
	my $from = $opts->{'from'};
	unless (defined $from) {
		$days = 365 unless defined $days && $days =~ /^-?[0-9]+$/ && $days > 0;
		$from = $now - $days * 86400000;
	}
	my $dry = $opts->{'dry_run'} ? 1 : 0;
	my $count = 0;
	my $written = 0;
	my @rows;
	for (my $ts = $from; $ts <= $now; $ts += 86400000) {
		my @lt = localtime(int($ts / 1000));
		# local noon, so a daylight-saving change does not move the day
		# localtime's year is already the offset from 1900 that mktime wants.
		my $noon = POSIX::mktime(0, 0, 12, $lt[3], $lt[4], $lt[5]) * 1000;
		my $moon = &moon_phase($noon);
		$count++;
		next if $dry;
		my $uuid = &astronomy_measure_write($app, {
			illumination => $moon->{'illumination'},
			moon_phase => $moon->{'phase'},
			moon_age_days => $moon->{'age_days'},
			lunar_phase => $moon->{'phase_name'},
		}, $noon, { seed => 'backfill' });
		$written++ if $uuid;
	}
	return { days => $count, written => ($dry ? 0 : $written), dry_run => $dry };
}

1;
