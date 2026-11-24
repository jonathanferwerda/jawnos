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

use Math::Trig qw(deg2rad pi great_circle_distance);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::UserAgent;
use Mojo::Util qw(md5_sum);
use POSIX ();
use Time::Local qw(timegm timelocal);

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
# The summary files are tens of bytes, not the multi-megabyte one-minute
# streams: the card and the daily row only need the latest reading.
my $MAG_URL = 'https://services.swpc.noaa.gov/products/summary/solar-wind-mag-field.json';
my $WIND_URL = 'https://services.swpc.noaa.gov/products/summary/solar-wind-speed.json';
my $DST_URL = 'https://services.swpc.noaa.gov/products/kyoto-dst.json';
my $SCALES_URL = 'https://services.swpc.noaa.gov/products/noaa-scales.json';
my $KP_FC_URL = 'https://services.swpc.noaa.gov/products/noaa-planetary-k-index-forecast.json';
my $F107_URL = 'https://services.swpc.noaa.gov/products/summary/10cm-flux.json';
my $SSN_URL = 'https://services.swpc.noaa.gov/json/solar-cycle/sunspots.json';
my $ALERTS_URL = 'https://services.swpc.noaa.gov/products/alerts.json';
my $AURORA_URL = 'https://services.swpc.noaa.gov/json/ovation_aurora_latest.json';
my $USGS_OBS_URL = 'https://geomag.usgs.gov/ws/observatories/?format=json';
my $USGS_DATA_URL = 'https://geomag.usgs.gov/ws/data/';
my $GFZ_URL = 'https://www-app3.gfz-potsdam.de/kp_index/Kp_ap_Ap_SN_F107_since_1932.txt';
my $KYOTO_DST_URL = 'https://wdc.kugi.kyoto-u.ac.jp/dst_provisional/%s/dst%s.for.request';
my $KYOTO_DST_RT_URL = 'https://wdc.kugi.kyoto-u.ac.jp/dst_realtime/%s/dst%s.for.request';
my $INTERMAGNET_URL = 'https://imag-data.bgs.ac.uk/GIN_V1/GINServices';

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

# The alert bodies write a time as "2026 Nov 19 0900 UTC" rather than the
# ISO stamp the JSON fields use. A bulletin with no readable end cannot be
# called current, so an unparsed time is 0 and the caller decides.
my %NOAA_MONTH = (
	jan => 1, feb => 2, mar => 3, apr => 4, may => 5, jun => 6,
	jul => 7, aug => 8, sep => 9, oct => 10, nov => 11, dec => 12,
);
sub _noaa_utc ($text) {
	return 0 unless defined $text && length $text;
	my ($year, $mon, $day, $hm) = $text =~ /(\d{4})\s+([A-Za-z]{3})\s+(\d{1,2})\s+(\d{3,4})/;
	return 0 unless $year && defined $mon && defined $NOAA_MONTH{lc $mon};
	my $hour = int($hm / 100);
	my $minute = $hm % 100;
	return 0 if $hour > 23 || $minute > 59;
	return timegm(0, $minute, $hour, $day, $NOAA_MONTH{lc $mon} - 1, $year) * 1000;
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

sub space_weather_dst ($json) {
	return &_noaa_number( &_noaa_row($json, [ 'dst' ])->{'dst'} );
}

# The current Dst for the card, and the day's mean and minimum for the measure.
# The measure must be a daily statistic, not whichever hourly value happened to
# be fetched last; the card still shows the current reading.
sub space_weather_dst_day ($json, $now = undef) {
	return {} unless ref $json eq 'ARRAY';
	$now = &rightNow() unless defined $now;
	my @lt = localtime(int($now / 1000));
	my $today = sprintf('%04d-%02d-%02d', $lt[5] + 1900, $lt[4] + 1, $lt[3]);
	my ($latest, $latest_at, @vals);
	foreach my $row ( @{$json} ) {
		next unless ref $row eq 'HASH';
		my $value = &_noaa_number($row->{'dst'});
		next unless defined $value;
		my $when = &_noaa_time($row->{'time_tag'});
		next unless $when;
		if (!defined $latest_at || $when > $latest_at) { $latest = $value; $latest_at = $when; }
		my @l = localtime(int($when / 1000));
		my $day = sprintf('%04d-%02d-%02d', $l[5] + 1900, $l[4] + 1, $l[3]);
		push @vals, $value if $day eq $today;
	}
	my %out;
	$out{'dst'} = $latest if defined $latest;
	if (scalar @vals) {
		my ($min, $sum) = ($vals[0], 0);
		foreach my $v ( @vals ) { $min = $v if $v < $min; $sum += $v; }
		$out{'dst_day'} = 0 + sprintf('%.1f', $sum / scalar @vals);
		$out{'dst_min'} = $min;
	}
	return \%out;
}

# The current R/S/G storm scales. R is a radio blackout, S a radiation storm,
# G a geomagnetic storm; each is 0 to 5.
sub space_weather_scales ($json) {
	return {} unless ref $json eq 'HASH';
	my $today = $json->{'0'} || {};
	my %out;
	foreach my $key ( qw/R S G/ ) {
		my $entry = $today->{$key} || {};
		my $scale = &_noaa_number($entry->{'Scale'});
		my $lower = lc $key;
		$out{$lower . '_scale'} = $scale if defined $scale;
		$out{$lower . '_text'} = $entry->{'Text'} if defined $entry->{'Text'} && length $entry->{'Text'};
	}
	return \%out;
}

# The strongest predicted Kp in the next three days. The file also carries the
# observed past; those rows are skipped.
sub space_weather_forecast ($json, $now = undef) {
	return {} unless ref $json eq 'ARRAY';
	$now = &rightNow() unless defined $now;
	my ($best, $best_at);
	foreach my $row ( @{$json} ) {
		next unless ref $row eq 'HASH';
		next if (($row->{'observed'} // '') eq 'observed');
		my $when = &_noaa_time($row->{'time_tag'});
		next unless $when && $when >= $now - 3600 * 1000 && $when <= $now + 3 * 86400000;
		my $kp = &_noaa_number($row->{'kp'});
		next unless defined $kp;
		if (!defined $best || $kp > $best) { $best = $kp; $best_at = $when; }
	}
	return {} unless defined $best;
	return { kp_forecast_max => $best, kp_forecast_at => $best_at };
}

sub space_weather_f107 ($json) {
	my $row = &_noaa_row($json, [ 'flux' ]);
	my $flux = &_noaa_number($row->{'flux'});
	return defined $flux ? $flux : undef;
}

# The monthly catalogue is small and gives the latest month's sunspot number.
sub space_weather_sunspots ($json) {
	return {} unless ref $json eq 'ARRAY';
	my ($value, $month);
	foreach my $row ( @{$json} ) {
		next unless ref $row eq 'HASH';
		my $ssn = &_noaa_number($row->{'ssn'});
		next unless defined $ssn && $ssn >= 0;
		$value = $ssn;
		$month = $row->{'time-tag'} if defined $row->{'time-tag'};
	}
	return {} unless defined $value;
	return { sunspot_number => $value, ($month ? (sunspot_month => $month) : ()) };
}

# Only the bulletins a person would act on: geomagnetic, radiation, radio
# blackout and aurora. The full alert file is text, so the card keeps three and
# the full text is not stored in a measure.
#
# NOAA leaves every bulletin it issued in this file, so the newest three used
# to be a warning that ended days ago. A bulletin with a stated end is kept
# only while that end is ahead; one with no end (an "ALERT" for an event that
# has happened) is kept only when it was issued in the last day. The comparison
# is against the fetch time, not the cache's, so a cached card cannot age back
# into the past.
sub space_weather_alerts ($json, $now = undef) {
	return [] unless ref $json eq 'ARRAY';
	$now = &rightNow() unless defined $now;
	my $oldest = $now - 24 * 60 * 60 * 1000;
	my @out;
	foreach my $alert ( @{$json} ) {
		next unless ref $alert eq 'HASH';
		my $msg = $alert->{'message'} // '';
		next unless $msg =~ /GEOMAGNETIC|K-INDEX|K INDEX|SOLAR RADIATION|RADIO BLACKOUT|AURORA/i;
		# An extended warning names both its old "Valid To" and the newer
		# "Now Valid Until"; the last readable end is the one that still stands.
		my $end_text;
		while ($msg =~ /(?:Now\s+Valid\s+Until|Valid\s+Until|Valid\s+To|\bEnd\s*Time\b|\bENDS?\b)\s*:?\s*(\d{4}\s+[A-Za-z]{3}\s+\d{1,2}\s+\d{3,4})/ig) {
			$end_text = $1;
		}
		my $ends_at = &_noaa_utc($end_text);
		my $issued_at = &_noaa_time($alert->{'issue_datetime'});
		next if $ends_at ? ($ends_at <= $now) : !($issued_at && $issued_at >= $oldest);
		my $text = $msg;
		$text =~ s/\r//g;
		$text =~ s/\s+/ /g;
		push @out, {
			id => $alert->{'product_id'} // '',
			issue => $alert->{'issue_datetime'} // '',
			($ends_at ? (valid_to => $ends_at) : ()),
			text => substr($text, 0, 600),
		};
	}
	@out = sort { $b->{'issue'} cmp $a->{'issue'} } @out;
	splice(@out, 3) if scalar @out > 3;
	return \@out;
}

# OVATION is a 1-degree world grid, ordered longitude 0..359 then latitude
# -90..90. Read the one cell over the house; the 900 KB map is discarded and
# only the percentage is cached or stored.
sub space_weather_aurora_at ($json, $lat, $lon) {
	return {} unless ref $json eq 'HASH' && ref $json->{'coordinates'} eq 'ARRAY';
	return {} unless defined $lat && $lat =~ /^-?[0-9.]+$/ && defined $lon && $lon =~ /^-?[0-9.]+$/;
	$lat = 90 if $lat > 90;
	$lat = -90 if $lat < -90;
	my $coords = $json->{'coordinates'};
	my $lat_i = int($lat + 90 + 0.5);
	my $lon_i = int($lon + 360 + 0.5) % 360;
	my $idx = $lon_i * 181 + $lat_i;
	# Only use the index when the grid is the real longitude-major 360x181
	# OVATION map. The first and last cells are the same in either ordering; the
	# second cell tells them apart (longitude-major steps latitude first,
	# [0,-89]; latitude-major steps longitude first, [1,-90]). A differently
	# ordered grid falls through to the nearest-cell search rather than being
	# silently misread.
	my $ordered = scalar @{$coords} == 360 * 181
		&& ref $coords->[0] eq 'ARRAY' && $coords->[0][0] == 0 && $coords->[0][1] == -90
		&& ref $coords->[1] eq 'ARRAY' && $coords->[1][0] == 0 && $coords->[1][1] == -89
		&& ref $coords->[-1] eq 'ARRAY' && $coords->[-1][0] == 359 && $coords->[-1][1] == 90;
	my $value;
	if ($ordered && $idx >= 0 && $idx < scalar @{$coords} && ref $coords->[$idx] eq 'ARRAY') {
		$value = $coords->[$idx][2];
	}
	unless (defined $value) {
		my $best_d;
		foreach my $point ( @{$coords} ) {
			next unless ref $point eq 'ARRAY' && scalar @{$point} >= 3;
			my $dlat = abs($point->[1] - $lat);
			# A point longitude may be 0..360 while the place is -180..180, so
			# reduce the gap modulo 360 before choosing the short way round.
			my $dlon = abs($point->[0] - $lon) % 360;
			$dlon = 360 - $dlon if $dlon > 180;
			my $d = $dlat + $dlon;
			if (!defined $best_d || $d < $best_d) { $best_d = $d; $value = $point->[2]; }
		}
	}
	return {} unless defined $value && $value =~ /^-?[0-9.]+$/;
	return {
		aurora_probability => 0 + $value,
		($json->{'Observation Time'} ? (aurora_observed_at => &_noaa_time($json->{'Observation Time'})) : ()),
		($json->{'Forecast Time'} ? (aurora_forecast_at => &_noaa_time($json->{'Forecast Time'})) : ()),
	};
}

# USGS sends four series, X (north), Y (east), Z (down) and F (total field).
# The last value of each is the current reading; declination and inclination
# are derived from them.
sub space_weather_magnetometer_parse ($json) {
	return {} unless ref $json eq 'HASH' && ref $json->{'values'} eq 'ARRAY';
	my %series;
	foreach my $set ( @{ $json->{'values'} } ) {
		next unless ref $set eq 'HASH' && defined $set->{'id'} && ref $set->{'values'} eq 'ARRAY';
		my $id = uc $set->{'id'};
		next unless $id =~ /^(X|Y|Z|F)$/;
		my $last;
		foreach my $v ( @{ $set->{'values'} } ) {
			$last = $v if defined $v && $v =~ /^-?[0-9.]+$/;
		}
		$series{$id} = 0 + $last if defined $last;
	}
	return {} unless defined $series{'F'} || (defined $series{'X'} && defined $series{'Y'});
	my $d;
	if (defined $series{'X'} && defined $series{'Y'} && ($series{'X'} || $series{'Y'})) {
		$d = atan2($series{'Y'}, $series{'X'}) * 180 / pi;
	}
	my $i;
	if (defined $series{'Z'} && defined $series{'X'} && defined $series{'Y'}) {
		$i = atan2($series{'Z'}, sqrt($series{'X'} ** 2 + $series{'Y'} ** 2)) * 180 / pi;
	}
	if (!defined $series{'F'} && defined $series{'X'} && defined $series{'Y'} && defined $series{'Z'}) {
		$series{'F'} = sqrt($series{'X'} ** 2 + $series{'Y'} ** 2 + $series{'Z'} ** 2);
	}
	my $imo = $json->{'metadata'}->{'intermagnet'}->{'imo'} || {};
	my $times = $json->{'times'};
	my $observed = ref $times eq 'ARRAY' ? &_noaa_time($times->[-1]) : 0;
	return {
		(defined $series{'F'} ? (f => $series{'F'}) : ()),
		(defined $series{'X'} ? (x => $series{'X'}) : ()),
		(defined $series{'Y'} ? (y => $series{'Y'}) : ()),
		(defined $series{'Z'} ? (z => $series{'Z'}) : ()),
		(defined $d ? (d => 0 + sprintf('%.2f', $d)) : ()),
		(defined $i ? (i => 0 + sprintf('%.2f', $i)) : ()),
		(($imo->{'iaga_code'} // '') ne '' ? (observatory => $imo->{'iaga_code'}) : ()),
		(($imo->{'name'} // '') ne '' ? (name => $imo->{'name'}) : ()),
		($observed ? (observed_at => $observed) : ()),
	};
}

# INTERMAGNET's GIN returns one array per component, with a trailing null for
# samples not yet published (or still embargoed). Read the last defined value of
# each, then derive declination and inclination the same way the USGS reader does.
sub space_weather_intermagnet_parse ($json) {
	return {} unless ref $json eq 'HASH';
	my (%series, %last_index);
	foreach my $key ( qw(F X Y Z) ) {
		my $row = $json->{$key};
		next unless ref $row eq 'ARRAY';
		for my $idx ( 0 .. $#{$row} ) {
			my $v = $row->[$idx];
			next unless defined $v && $v =~ /^-?[0-9.]+$/;
			$series{$key} = 0 + $v;
			$last_index{$key} = $idx;
		}
	}
	return {} unless defined $series{'F'} || (defined $series{'X'} && defined $series{'Y'});
	my $d;
	if (defined $series{'X'} && defined $series{'Y'} && ($series{'X'} || $series{'Y'})) {
		$d = atan2($series{'Y'}, $series{'X'}) * 180 / pi;
	}
	my $i;
	if (defined $series{'Z'} && defined $series{'X'} && defined $series{'Y'}) {
		$i = atan2($series{'Z'}, sqrt($series{'X'} ** 2 + $series{'Y'} ** 2)) * 180 / pi;
	}
	if (!defined $series{'F'} && defined $series{'X'} && defined $series{'Y'} && defined $series{'Z'}) {
		$series{'F'} = sqrt($series{'X'} ** 2 + $series{'Y'} ** 2 + $series{'Z'} ** 2);
	}
	my $info = ref $json->{'@info'} eq 'HASH' ? $json->{'@info'} : {};
	my $times = $json->{'datetime'};
	my $at = $last_index{'F'} // $last_index{'X'} // $last_index{'Y'} // $last_index{'Z'};
	my $observed = ref $times eq 'ARRAY' && defined $at && defined $times->[$at] ? &_noaa_time($times->[$at]) : 0;
	return {
		(defined $series{'F'} ? (f => $series{'F'}) : ()),
		(defined $series{'X'} ? (x => $series{'X'}) : ()),
		(defined $series{'Y'} ? (y => $series{'Y'}) : ()),
		(defined $series{'Z'} ? (z => $series{'Z'}) : ()),
		(defined $d ? (d => 0 + sprintf('%.2f', $d)) : ()),
		(defined $i ? (i => 0 + sprintf('%.2f', $i)) : ()),
		(($info->{'iaga_code'} // '') ne '' ? (observatory => $info->{'iaga_code'}) : ()),
		(($info->{'station_name'} // '') ne '' ? (name => $info->{'station_name'}) : ()),
		($observed ? (observed_at => $observed) : ()),
	};
}

# USGS's observatory list carries no Canadian station with live data, and its
# data API rejects a Canadian IAGA code (BRD answers 422). INTERMAGNET's GIN
# serves them, so these are merged into the cached USGS list by IAGA code. The
# coordinates are the observatories' own (INTERMAGNET publishes longitude
# 0..360; these are the same places as -75.552 and -113.35).
my @INTERMAGNET_STATIONS = (
	{ id => 'OTT', name => 'Ottawa, Canada', lat => 45.403, lon => -75.552 },
	{ id => 'MEA', name => 'Meanook, Canada', lat => 54.616, lon => -113.35 },
);

# Union of a station list and the curated INTERMAGNET stations, one row per
# IAGA code. The first row wins, so a USGS row keeps its own name and
# coordinates when both carry the code.
sub space_weather_stations_merge ($list) {
	my (%seen, @out);
	foreach my $station ( ref $list eq 'ARRAY' ? @{$list} : () ) {
		next unless ref $station eq 'HASH';
		my $id = uc($station->{'id'} // '');
		next unless $id =~ /^[A-Z0-9]{3,5}$/;
		next unless defined $station->{'lat'} && defined $station->{'lon'};
		next if $seen{$id}++;
		push @out, { %{$station}, id => $id };
	}
	foreach my $station ( @INTERMAGNET_STATIONS ) {
		next if $seen{ $station->{'id'} }++;
		push @out, { %{$station} };
	}
	return \@out;
}

# Every station with its great-circle distance from the place, nearest first.
sub space_weather_stations_nearest ($list, $lat, $lon) {
	return [] unless ref $list eq 'ARRAY';
	return [] unless defined $lat && $lat =~ /^-?[0-9.]+$/ && defined $lon && $lon =~ /^-?[0-9.]+$/;
	return [
		sort { $a->{'km'} <=> $b->{'km'} } map {
			{
				%{$_},
				# Math::Trig takes longitude first, then latitude.
				km => great_circle_distance(deg2rad($lon), deg2rad($lat), deg2rad($_->{'lon'}), deg2rad($_->{'lat'}), 6371),
			}
		} grep { ref $_ eq 'HASH' && defined $_->{'lat'} && defined $_->{'lon'} } @{$list}
	];
}

# The GIN endpoint takes an inclusive start and an exclusive end date. A week
# back is enough for an observatory whose latest day is still embargoed; the
# parser then takes the last value that was actually published.
sub space_weather_intermagnet_url ($id, $start = undef, $end = undef) {
	return '' unless defined $id && $id =~ /^[A-Z0-9]{3,5}$/;
	my $now = time();
	$end = POSIX::strftime('%Y-%m-%d', gmtime($now)) unless defined $end && $end =~ /^\d{4}-\d{2}-\d{2}$/;
	$start = POSIX::strftime('%Y-%m-%d', gmtime($now - 6 * 86400)) unless defined $start && $start =~ /^\d{4}-\d{2}-\d{2}$/;
	return $INTERMAGNET_URL
		. '?Request=GetData&format=json'
		. '&observatoryIagaCode=' . $id
		. '&samplesPerDay=1440'
		. '&dataStartDate=' . $start
		. '&dataEndDate=' . $end
		. '&dataType=adjusted&orientation=XYZF';
}

sub _usgs_observatories ($ua) {
	my $cached = eval { &cache_get({ app => 'space_weather', context => 'usgs_observatories' }) };
	my $list = ref $cached eq 'HASH' && ref $cached->{'list'} eq 'ARRAY' ? $cached->{'list'} : undef;
	# A cache written before the curated INTERMAGNET stations existed holds only
	# the USGS rows; merging on read adds them without a refetch.
	return &space_weather_stations_merge($list) if $list && scalar @{$list};
	my ($json) = &weather_http_get($USGS_OBS_URL, $ua);
	return &space_weather_stations_merge([]) unless ref $json eq 'HASH' && ref $json->{'features'} eq 'ARRAY';
	my @out;
	foreach my $feature ( @{ $json->{'features'} } ) {
		next unless ref $feature eq 'HASH';
		my $id = $feature->{'id'} // '';
		next unless $id =~ /^[A-Z0-9]{3,5}$/;
		my $name = $feature->{'properties'}->{'name'} // $id;
		next if $id =~ /T$/ || $name =~ /test|development/i;
		my $coords = $feature->{'geometry'}->{'coordinates'};
		next unless ref $coords eq 'ARRAY' && scalar @{$coords} >= 2;
		push @out, {
			id => $id,
			name => $name,
			lat => 0 + $coords->[1],
			lon => 0 + $coords->[0],
		};
	}
	my $merged = &space_weather_stations_merge(\@out);
	eval { &cache_set({ app => 'space_weather', context => 'usgs_observatories', warranty => '-30d' }, { list => $merged }) } if scalar @{$merged};
	return $merged;
}

sub space_weather_magnetometer ($ua, $lat, $lon) {
	return {} unless defined $lat && $lat =~ /^-?[0-9.]+$/ && defined $lon && $lon =~ /^-?[0-9.]+$/;
	my $stations = &_usgs_observatories($ua);
	return {} unless $stations && scalar @{$stations};
	my $sorted = &space_weather_stations_nearest($stations, $lat, $lon);
	# The nearest station can be offline, embargoed or null at the end of its
	# file, so try the next few. INTERMAGNET is asked first because it carries
	# the Canadian observatories the USGS data API rejects (BRD answers 422);
	# the USGS data API is the fallback for the same station.
	my $tries = 0;
	foreach my $station ( @{$sorted} ) {
		last if ++$tries > 8;
		my ($im_json) = &weather_http_get(&space_weather_intermagnet_url($station->{'id'}), $ua);
		my $reading = &space_weather_intermagnet_parse($im_json);
		unless (scalar keys %{$reading}) {
			my $url = $USGS_DATA_URL . '?id=' . $station->{'id'} . '&sampling_period=60&format=json';
			my ($json) = &weather_http_get($url, $ua);
			$reading = &space_weather_magnetometer_parse($json);
		}
		next unless scalar keys %{$reading};
		$reading->{'observatory'} = $station->{'id'} unless defined $reading->{'observatory'};
		$reading->{'name'} = $station->{'name'} unless defined $reading->{'name'};
		$reading->{'distance_km'} = int($station->{'km'} + 0.5);
		return $reading;
	}
	return {};
}

# GFZ's daily file carries the eight three-hour Kp values, Ap, the international
# sunspot number and F10.7. Read the last days into one row a day.
sub space_weather_history_parse ($text, $from = undef, $to = undef) {
	return {} unless defined $text && length $text;
	my %out;
	foreach my $line ( split /\n/, $text ) {
		next unless $line =~ /\S/ && $line !~ /^\s*#/;
		my @f = split ' ', $line;
		next unless scalar @f >= 26 && $f[0] =~ /^\d{4}$/ && $f[1] =~ /^\d{1,2}$/ && $f[2] =~ /^\d{1,2}$/;
		my $when = timelocal(0, 0, 12, $f[2], $f[1] - 1, $f[0]) * 1000;
		next if defined $from && $when < $from;
		next if defined $to && $when > $to;
		my $max;
		foreach my $raw ( @f[7 .. 14] ) {
			my $kp = &_noaa_number($raw);
			next unless defined $kp && $kp >= 0;
			$max = $kp if !defined $max || $kp > $max;
		}
		my %entry;
		if (defined $max) { $entry{'kp'} = $max; $entry{'kp_max_24h'} = $max; }
		my $ap = &_noaa_number($f[23]); $entry{'ap'} = $ap if defined $ap && $ap >= 0;
		my $sn = &_noaa_number($f[24]); $entry{'sunspot_number'} = $sn if defined $sn && $sn >= 0;
		my $f107 = &_noaa_number($f[25]); $entry{'f107'} = $f107 if defined $f107 && $f107 > 0;
		next unless scalar keys %entry;
		$out{ sprintf('%04d-%02d-%02d', $f[0], $f[1], $f[2]) } = \%entry;
	}
	return \%out;
}

# Kyoto's provisional monthly Dst file: one line a day, then the hourly values.
# The lowest value is the storm's strength; the average is the day's level.
sub space_weather_dst_month_parse ($text, $year, $month) {
	return {} unless defined $text && defined $year && defined $month;
	my %out;
	foreach my $line ( split /\n/, $text ) {
		next unless $line =~ /^DST\d{4}\*(\d{2})[A-Z]{2}X\d+\s+(.*)$/;
		my ($day, $rest) = ($1, $2);
		next unless $day >= 1 && $day <= 31;
		my @vals = grep { defined $_ && abs($_) < 1000 } map { &_noaa_number($_) } ($rest =~ /([-+]?\d+)/g);
		next unless scalar @vals;
		# A real line is a filler 0, the 24 hourly values, then a published daily
		# mean. Strip the filler and the trailing mean, then average the hours
		# ourselves: including them double-counts the mean and lets the filler
		# pull a storm day calm.
		my @hourly;
		if (scalar @vals >= 26) {
			@hourly = @vals[1 .. $#vals - 1];
		}
		elsif (scalar @vals >= 25) {
			@hourly = @vals[0 .. $#vals - 1];
		}
		else {
			@hourly = @vals;
		}
		my $sum = 0; $sum += $_ for @hourly;
		my $mean = @hourly ? $sum / scalar @hourly : 0;
		my $min = $hourly[0];
		foreach my $v ( @hourly ) { $min = $v if $v < $min; }
		my $when = timelocal(0, 0, 12, $day, $month - 1, $year) * 1000;
		$out{ sprintf('%04d-%02d-%02d', $year, $month, $day) } = {
			dst_min => $min,
			dst => 0 + sprintf('%.1f', $mean),
			_when => $when,
		};
	}
	return \%out;
}

sub space_weather_fetch ($opts = {}) {
	$opts ||= {};
	my $lat = $opts->{'lat'};
	my $lon = $opts->{'lon'};
	# The local parts (aurora, magnetometer) belong to a place, so the cache is
	# keyed by it; the planetary parts are the same and cost almost nothing.
	my $cache_key = (defined $lat && $lat =~ /^-?[0-9.]+$/ && defined $lon && $lon =~ /^-?[0-9.]+$/)
		? sprintf('%.1f_%.1f', $lat, $lon)
		: 'house';
	my $cached = eval { &cache_get({ app => 'space_weather', context => 'current', subcontext => $cache_key }) };
	return $cached if !$opts->{'force'} && ref $cached eq 'HASH' && ($cached->{'server_time'} || 0) > &rightNow() - 10 * 60 * 1000;
	my $ua = Mojo::UserAgent->new(connect_timeout => 4, inactivity_timeout => 7, request_timeout => 12);
	my ($kp_json) = &weather_http_get($Kp_URL, $ua);
	my ($mag_json) = &weather_http_get($MAG_URL, $ua);
	my ($wind_json) = &weather_http_get($WIND_URL, $ua);
	my $reading = &space_weather_parse($kp_json, $mag_json, $wind_json);
	my $dst = &space_weather_dst_day( (&weather_http_get($DST_URL, $ua))[0], &rightNow() );
	$reading->{$_} = $dst->{$_} for keys %{$dst};
	my $scales = &space_weather_scales( (&weather_http_get($SCALES_URL, $ua))[0] );
	$reading->{$_} = $scales->{$_} for keys %{$scales};
	my $forecast = &space_weather_forecast( (&weather_http_get($KP_FC_URL, $ua))[0] );
	$reading->{$_} = $forecast->{$_} for keys %{$forecast};
	my $f107 = &space_weather_f107( (&weather_http_get($F107_URL, $ua))[0] );
	$reading->{'f107'} = $f107 if defined $f107;
	my $spots = &space_weather_sunspots( (&weather_http_get($SSN_URL, $ua))[0] );
	$reading->{$_} = $spots->{$_} for keys %{$spots};
	my $alerts = &space_weather_alerts( (&weather_http_get($ALERTS_URL, $ua))[0] );
	$reading->{'alerts'} = $alerts if ref $alerts eq 'ARRAY' && scalar @{$alerts};
	if (defined $lat && $lat =~ /^-?[0-9.]+$/ && defined $lon && $lon =~ /^-?[0-9.]+$/) {
		my $aurora = &space_weather_aurora_at( (&weather_http_get($AURORA_URL, $ua))[0], $lat, $lon );
		$reading->{$_} = $aurora->{$_} for keys %{$aurora};
		my $magnetometer = &space_weather_magnetometer($ua, $lat, $lon);
		$reading->{'magnetometer'} = $magnetometer if scalar keys %{$magnetometer};
	}
	my $got = grep { defined $reading->{$_} } qw(kp bz dst solar_wind_speed);
	unless ($got) {
		# A planetary outage must not discard a local aurora, magnetometer,
		# scale, alert or solar reading that did arrive.
		return { %{ ref $cached eq 'HASH' ? $cached : {} }, %{$reading}, error => 'Space weather is unavailable right now.' };
	}
	$reading->{'server_time'} = &rightNow();
	eval { &cache_set({ app => 'space_weather', context => 'current', subcontext => $cache_key, warranty => '-10m' }, $reading) };
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
	kp_forecast_max => { type => 'number', min => 0, max => 9, unit => 'Kp' },
	dst => { type => 'number', min => -500, max => 100, unit => 'nT' },
	dst_min => { type => 'number', min => -500, max => 100, unit => 'nT' },
	ap => { type => 'number', min => 0, max => 400, unit => '' },
	bz => { type => 'number', min => -30, max => 30, unit => 'nT' },
	bt => { type => 'number', min => 0, max => 100, unit => 'nT' },
	solar_wind_speed => { type => 'number', min => 0, max => 2000, unit => 'km/s' },
	solar_wind_density => { type => 'number', min => 0, max => 100, unit => 'p/cm³' },
	g_scale => { type => 'number', min => 0, max => 5, unit => 'G' },
	s_scale => { type => 'number', min => 0, max => 5, unit => 'S' },
	r_scale => { type => 'number', min => 0, max => 5, unit => 'R' },
	f107 => { type => 'number', min => 0, max => 500, unit => 'sfu' },
	sunspot_number => { type => 'number', min => 0, max => 500, unit => '' },
	aurora_probability => { type => 'number', min => 0, max => 100, unit => '%' },
);
my %MAGNETOMETER_MEASURES = (
	magnetic_f => { type => 'number', min => 0, max => 100000, unit => 'nT' },
	magnetic_x => { type => 'number', min => -100000, max => 100000, unit => 'nT' },
	magnetic_y => { type => 'number', min => -100000, max => 100000, unit => 'nT' },
	magnetic_z => { type => 'number', min => -100000, max => 100000, unit => 'nT' },
	magnetic_d => { type => 'number', min => -180, max => 180, unit => '°' },
	magnetic_i => { type => 'number', min => -90, max => 90, unit => '°' },
);

# Teach an app its measures and, once, what kind of thing it is. Values already
# chosen are left alone; this only fills what is missing.
sub astronomy_measure_defaults ($app) {
	return 0 unless defined $app && length $app;
	my $defs = $app eq 'space_weather' ? \%SPACE_MEASURES
		: $app eq 'magnetometer' ? \%MAGNETOMETER_MEASURES
		: $app eq 'moon' ? \%MOON_MEASURES
		: {};
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
		: $app eq 'magnetometer'
		? (category => 'nature', subcategory => 'magnetic', colour => '#b48ead')
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
	# The local readings belong to the house's own ground, not the box's.
	my $home = eval { &weather_home_plate() } || {};
	my $space = &space_weather_fetch({
		force => $opts->{'force'},
		(defined $home->{'lat'} ? (lat => $home->{'lat'}) : ()),
		(defined $home->{'lon'} ? (lon => $home->{'lon'}) : ()),
	});
	my $space_written = 0;
	my $magnetometer_written = 0;
	if ($space && !$space->{'error'}) {
		&astronomy_measure_write('space_weather', {
			kp => $space->{'kp'},
			kp_max_24h => $space->{'kp_max_24h'},
			kp_forecast_max => $space->{'kp_forecast_max'},
			dst => $space->{'dst_day'},
			dst_min => $space->{'dst_min'},
			bz => $space->{'bz'},
			bt => $space->{'bt'},
			solar_wind_speed => $space->{'solar_wind_speed'},
			solar_wind_density => $space->{'solar_wind_density'},
			g_scale => $space->{'g_scale'},
			s_scale => $space->{'s_scale'},
			r_scale => $space->{'r_scale'},
			f107 => $space->{'f107'},
			sunspot_number => $space->{'sunspot_number'},
			aurora_probability => $space->{'aurora_probability'},
		}, $now);
		$space_written = 1;
		my $mag = $space->{'magnetometer'};
		if (ref $mag eq 'HASH' && scalar keys %{$mag}) {
			&astronomy_measure_write('magnetometer', {
				magnetic_f => $mag->{'f'},
				magnetic_x => $mag->{'x'},
				magnetic_y => $mag->{'y'},
				magnetic_z => $mag->{'z'},
				magnetic_d => $mag->{'d'},
				magnetic_i => $mag->{'i'},
			}, $now);
			$magnetometer_written = 1;
		}
	}
	return {
		moon => $moon,
		space_weather => $space,
		space_written => $space_written,
		magnetometer_written => $magnetometer_written,
	};
}

# Historical Kp, Ap, F10.7, sunspot number and Dst, one row a day. GFZ's file
# carries the solar and Kp indices; Kyoto's provisional monthly files carry Dst.
# The two are merged before the write, so a day gets one row.
sub space_weather_backfill ($opts = {}) {
	$opts ||= {};
	my $now = $opts->{'to'} || &rightNow();
	my $days = $opts->{'days'};
	my $from = $opts->{'from'};
	unless (defined $from) {
		$days = 365 unless defined $days && $days =~ /^-?[0-9]+$/ && $days > 0;
		$from = $now - $days * 86400000;
	}
	my $dry = $opts->{'dry_run'} ? 1 : 0;
	my $ua = Mojo::UserAgent->new(connect_timeout => 6, inactivity_timeout => 15, request_timeout => 30);
	my %history;
	my ($gfz) = &weather_http_get_text($GFZ_URL, $ua);
	if ($gfz) {
		my $rows = &space_weather_history_parse($gfz, $from, $now);
		foreach my $day ( keys %{$rows} ) {
			$history{$day} = { %{ $history{$day} || {} }, %{ $rows->{$day} } };
		}
	}
	# Kyoto's provisional archive is monthly, from 2021. Walk the months the
	# window touches; a missing month is simply no Dst for those days.
	my @a = localtime(int($from / 1000));
	my @b = localtime(int($now / 1000));
	my ($y, $m) = ($a[5] + 1900, $a[4] + 1);
	my $last_y = $b[5] + 1900;
	my $last_m = $b[4] + 1;
	my $months = 0;
	while ($y < $last_y || ($y == $last_y && $m <= $last_m)) {
		my $stamp = sprintf('%04d%02d', $y, $m);
		my $short = sprintf('%02d%02d', $y % 100, $m);
		my $url = sprintf($KYOTO_DST_URL, $stamp, $short);
		my ($text) = &weather_http_get_text($url, $ua);
		# The current month is published in realtime (RRX) before it is
		# provisional (PPX); try that when the provisional file is not there.
		unless ($text) {
			my $rt = sprintf($KYOTO_DST_RT_URL, $stamp, $short);
			($text) = &weather_http_get_text($rt, $ua);
		}
		if ($text) {
			my $rows = &space_weather_dst_month_parse($text, $y, $m);
			foreach my $day ( keys %{$rows} ) {
				my $row = { %{ $rows->{$day} } };
				delete $row->{'_when'};
				$history{$day} = { %{ $history{$day} || {} }, %{ $row } };
			}
			$months++;
		}
		$m++;
		if ($m > 12) { $m = 1; $y++; }
	}
	my ($count, $written) = (0, 0);
	foreach my $day ( sort keys %history ) {
		my ($yy, $mm, $dd) = split /-/, $day;
		my $when = timelocal(0, 0, 12, $dd, $mm - 1, $yy) * 1000;
		next if $when < $from || $when > $now;
		$count++;
		next if $dry;
		my $uuid = &astronomy_measure_write('space_weather', $history{$day}, $when, { seed => 'backfill' });
		$written++ if $uuid;
	}
	return {
		days => $count,
		written => ($dry ? 0 : $written),
		dry_run => $dry,
		months => $months,
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
