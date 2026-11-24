# tests-for: lib/JawnOS/Domain/Astronomy.pm lib/JawnOS/Domain/Budget2.pm
# covers:    the edge cases around the space-weather fetchers: a partial NOAA
#            outage, the location-keyed cache, OVATION's longitude-major grid
#            (the direct index, the longitude wrap and the fallback), Kyoto's
#            real line shape (a filler, 24 hours and the daily mean), GFZ's
#            -1 sentinels and its day filter, the backfill's provisional-to-
#            realtime fallback, and the evaluation's per-app condition caps.
#
# Everything here is offline: weather_http_get, weather_http_get_text, cache_*
# and rightNow are replaced in-process, so no request leaves the machine.

use strict;
use warnings;
# The stubs below replace package subs that the required modules do not all
# load, so perl would call each of them "used only once".
no warnings 'once';
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JSON::PP qw(decode_json);
use JawnOSTest;

my $root = root();

require "$root/lib/JawnOS/Domain/Schedule.pm";
require "$root/lib/JawnOS/Domain/Astronomy.pm";
require "$root/lib/JawnOS/Domain/Budget2.pm";

package FakeResult;
sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
sub hashes { return $_[0]->{rows}; }
sub hash { return $_[0]->{rows}->[0]; }
sub sth { return undef; }

package main;

# --- a fixed "now" and one complete, live-shaped NOAA/USGS answer -------------
# These payloads are the shapes the real endpoints return (checked against the
# live JSON): planetary Kp as objects, the summary files as one-object arrays,
# Kyoto Dst as an object table, the aurora grid as [lon, lat, value] triplets.

my $NOW = ts(2026, 11, 23, 12, 0, 0);

my %NOAA = (
	'noaa-planetary-k-index.json' => [
		{ time_tag => '2026-11-23T09:00:00', Kp => 3 },
		{ time_tag => '2026-11-23T12:00:00', Kp => 4 },
	],
	'summary/solar-wind-mag-field.json' => [
		{ time_tag => '2026-11-23T12:00:00Z', bz_gsm => '-3.5', bt => '6.0' },
	],
	'summary/solar-wind-speed.json' => [
		{ time_tag => '2026-11-23T12:00:00Z', proton_speed => '410', proton_density => '3.5' },
	],
	'kyoto-dst.json' => [
		{ time_tag => '2026-11-23T11:00:00', dst => -17 },
		{ time_tag => '2026-11-23T12:00:00', dst => -18 },
	],
	'noaa-scales.json' => {
		'0' => {
			R => { Scale => '1', Text => 'minor' },
			S => { Scale => '0', Text => 'none' },
			G => { Scale => '2', Text => 'moderate' },
		},
	},
	'noaa-planetary-k-index-forecast.json' => [
		{ time_tag => '2026-11-23T15:00:00', kp => 5, observed => 'predicted' },
		{ time_tag => '2026-11-25T15:00:00', kp => 6, observed => 'predicted' },
	],
	'summary/10cm-flux.json' => [ { flux => 112, time_tag => '2026-11-23T00:00:00' } ],
	'json/solar-cycle/sunspots.json' => [
		{ 'time-tag' => '2026-09', ssn => 60 },
		{ 'time-tag' => '2026-10', ssn => undef },
	],
	'products/alerts.json' => [
		{ product_id => 'K05A', issue_datetime => '2026-11-23 01:00:00', message => "ALERT: Geomagnetic K-index of 5\r\nThreshold Reached" },
		{ product_id => 'NONE', issue_datetime => '2026-11-23 02:00:00', message => 'Nothing to act on' },
	],
	'json/ovation_aurora_latest.json' => {
		'Observation Time' => '2026-11-23T11:00:00Z',
		coordinates => [ [ 0, 0, 42 ] ],
	},
	'geomag.usgs.gov/ws/observatories' => {
		features => [
			{
				id => 'BOU',
				properties => { name => 'Boulder' },
				geometry => { coordinates => [ -105.237, 40.137, 1682 ] },
			},
		],
	},
	'geomag.usgs.gov/ws/data/' => {
		times => [ '2026-11-23T11:59:00.000Z' ],
		metadata => { intermagnet => { imo => { iaga_code => 'BOU', name => 'Boulder' } } },
		values => [
			{ id => 'X', values => [ 20000, 20400 ] },
			{ id => 'Y', values => [ -700, -650 ] },
			{ id => 'Z', values => [ 39000, 39100 ] },
			{ id => 'F', values => [ 46000, 46100, undef ] },
		],
	},
);

# A stand-in for weather_http_get: substring of the URL -> payload. A key given
# as a false value fails the way a 503 would.
sub noaa_stub {
	my (%override) = @_;
	my %map = (%NOAA, %override);
	return sub {
		my ($url) = @_;
		foreach my $key ( sort { length($b) <=> length($a) } keys %map ) {
			next unless index($url, $key) >= 0;
			return (undef, 'HTTP 503') unless $map{$key};
			return ($map{$key}, undef);
		}
		return (undef, 'not stubbed');
	};
}

# --- a complete fetch: parses, caches under the rounded location -------------
{
	my @set;
	my $stub = noaa_stub();
	my $calls = 0;
	local *subs::rightNow = sub { return $NOW };
	local *subs::cache_get = sub { return undef };
	local *subs::cache_set = sub { push @set, [ $_[0], $_[1] ]; };
	local *subs::weather_http_get = sub { my ($u) = @_; $calls++; return $stub->($u); };

	my $got = &subs::space_weather_fetch({ lat => 40.137, lon => -105.237 });
	is($got->{'kp'}, 4, 'the latest Kp is read from the object shape');
	is($got->{'dst'}, -18, 'Kyoto Dst is the last row');
	is($got->{'g_scale'}, 2, 'the storm scales are read');
	is($got->{'kp_forecast_max'}, 6, 'the strongest prediction inside three days wins');
	is($got->{'f107'}, 112, 'F10.7 is read');
	is($got->{'sunspot_number'}, 60, 'a null latest sunspot month falls back to the last real one');
	is($got->{'aurora_probability'}, 42, 'aurora is read for the house');
	ok(ref $got->{'magnetometer'} eq 'HASH', 'the local field came back');
	is($got->{'magnetometer'}{'f'}, 46100, 'the last numeric total field wins over a trailing null');
	is(scalar @{ $got->{'alerts'} || [] }, 1, 'only the actionable alert is kept');
	ok(!defined $got->{'error'}, 'a complete fetch carries no error');

	my ($current) = grep { $_->[0]{'context'} eq 'current' } @set;
	ok($current, 'the reading is cached');
	is($current->[0]{'subcontext'}, '40.1_-105.2', 'the cache key is the rounded latitude and longitude');
	is($current->[1]{'kp'}, 4, 'the cached reading carries the Kp');
}

# --- the cache is per place, and 'house' when there is no place --------------
{
	my @set;
	my $stub = noaa_stub();
	local *subs::rightNow = sub { return $NOW };
	local *subs::cache_get = sub { return undef };
	local *subs::cache_set = sub { push @set, [ $_[0], $_[1] ]; };
	local *subs::weather_http_get = sub { my ($u) = @_; return $stub->($u); };

	&subs::space_weather_fetch({ lat => 40.137, lon => -105.237 });
	&subs::space_weather_fetch({ lat => 51.5, lon => -0.1 });
	my @keys = map { $_->[0]{'subcontext'} } grep { $_->[0]{'context'} eq 'current' } @set;
	is(scalar @keys, 2, 'two places cache separately');
	isnt($keys[0], $keys[1], 'a second place does not read the first place\'s local readings');

	@set = ();
	&subs::space_weather_fetch({});
	my ($house) = grep { $_->[0]{'context'} eq 'current' } @set;
	is($house->[0]{'subcontext'}, 'house', 'no coordinates cache under one house key');
	ok(!defined $house->[1]{'magnetometer'}, 'and a houseless fetch does not invent a local field');
}

# --- a fresh cache answers without the network, a stale one refetches --------
{
	my $stub = noaa_stub();
	my $calls = 0;
	local *subs::rightNow = sub { return $NOW };
	local *subs::cache_get = sub { return { kp => 2, server_time => $NOW - 5 * 60 * 1000 } };
	local *subs::cache_set = sub { };
	local *subs::weather_http_get = sub { my ($u) = @_; $calls++; return $stub->($u); };
	my $got = &subs::space_weather_fetch({ lat => 40.1, lon => -105.2 });
	is($calls, 0, 'a five-minute-old reading is served from the cache');
	is($got->{'kp'}, 2, 'and it is the cached reading');

	$calls = 0;
	local *subs::cache_get = sub { return { kp => 2, server_time => $NOW - 11 * 60 * 1000 } };
	$got = &subs::space_weather_fetch({ lat => 40.1, lon => -105.2 });
	cmp_ok($calls, '>', 0, 'an eleven-minute-old reading is refetched');
	is($got->{'kp'}, 4, 'and the fresh reading replaces it');
}

# --- a planetary outage must not throw away the local readings that arrived --
# NOAA's Kp, Bz/wind and Dst files all fail; the scales, forecast, F10.7,
# sunspots, alerts, OVATION and the USGS magnetometer all answer.
{
	my $stub = noaa_stub(
		'noaa-planetary-k-index.json' => undef,
		'summary/solar-wind-mag-field.json' => undef,
		'summary/solar-wind-speed.json' => undef,
		'kyoto-dst.json' => undef,
	);
	local *subs::rightNow = sub { return $NOW };
	local *subs::cache_get = sub { return undef };
	local *subs::cache_set = sub { };
	local *subs::weather_http_get = sub { my ($u) = @_; return $stub->($u); };

	my $got = &subs::space_weather_fetch({ lat => 40.1, lon => -105.2 });
	is($got->{'error'}, 'Space weather is unavailable right now.',
		'a planetary outage is reported when none of the four headline readings arrive');

	# The local and independent readings still arrived; an outage of the
	# planetary feeds must not throw them away.
	is($got->{'aurora_probability'}, 42, 'the aurora that did arrive is kept');
	ok(ref $got->{'magnetometer'} eq 'HASH', 'and the local magnetic field survives');
	is($got->{'f107'}, 112, 'and the solar index survives');

	# One of the four keys is enough to flip the whole answer. Swap Kp back in;
	# the magnetometer, wind and Dst still fail.
	my $kp_only = noaa_stub(
		'summary/solar-wind-mag-field.json' => undef,
		'summary/solar-wind-speed.json' => undef,
		'kyoto-dst.json' => undef,
	);
	local *subs::weather_http_get = sub { my ($u) = @_; return $kp_only->($u); };
	$got = &subs::space_weather_fetch({ lat => 40.1, lon => -105.2, force => 1 });
	is($got->{'kp'}, 4, 'a single surviving headline reading is served');
	ok(!defined $got->{'error'}, 'and is not treated as an outage');
	is($got->{'aurora_probability'}, 42, 'with the local readings it arrived alongside');
}

# --- a local failure never erases the planetary reading ----------------------
{
	my $stub = noaa_stub(
		'json/ovation_aurora_latest.json' => undef,
		'geomag.usgs.gov/ws/data/' => undef,
	);
	local *subs::rightNow = sub { return $NOW };
	local *subs::cache_get = sub { return undef };
	my @set;
	local *subs::cache_set = sub { push @set, [ $_[0], $_[1] ]; };
	local *subs::weather_http_get = sub { my ($u) = @_; return $stub->($u); };
	my $got = &subs::space_weather_fetch({ lat => 40.1, lon => -105.2 });
	is($got->{'kp'}, 4, 'the planetary Kp still arrives');
	is($got->{'dst'}, -18, 'and Dst');
	ok(!defined $got->{'aurora_probability'}, 'the failed aurora is simply missing');
	ok(!defined $got->{'magnetometer'}, 'and the failed local field is missing');
	my ($current) = grep { $_->[0]{'context'} eq 'current' } @set;
	ok($current && !exists $current->[1]{'magnetometer'},
		'the cached day does not invent a local field it did not read');
}

# --- the OVATION grid is longitude-major: 360 longitudes of 181 latitudes ----
# The real file starts [0,-90,v], [0,-89,v] ... so the cell for (lat, lon) is
# lon * 181 + (lat + 90). Build the whole grid so a regression to a latitude-
# major index cannot hide behind the nearest-point fallback.
my @GRID;
for my $lon (0 .. 359) {
	for my $lat_i (0 .. 180) {
		push @GRID, [ $lon, $lat_i - 90, $lon * 1000 + $lat_i ];
	}
}
{
	is(scalar @GRID, 360 * 181, 'the synthetic grid is the size of the real one');

	my $got = &subs::space_weather_aurora_at({ coordinates => \@GRID }, 40.4, -105.0);
	is($got->{'aurora_probability'}, 255 * 1000 + 130,
		'lat 40.4 / lon -105 is read straight from the grid (longitude 255, latitude row 130)');

	is(&subs::space_weather_aurora_at({ coordinates => \@GRID }, 40.6, -105.0)->{'aurora_probability'},
		255 * 1000 + 131, 'the latitude rounds up past the half degree');
	is(&subs::space_weather_aurora_at({ coordinates => \@GRID }, 40.4, 255.0)->{'aurora_probability'},
		255 * 1000 + 130, 'a 0..360 longitude reads the same cell as a negative one');

	# The wrap: 359.9 and -0.1 are the same degree.
	is(&subs::space_weather_aurora_at({ coordinates => \@GRID }, 10, 359.9)->{'aurora_probability'},
		&subs::space_weather_aurora_at({ coordinates => \@GRID }, 10, -0.1)->{'aurora_probability'},
		'359.9 and -0.1 wrap to the same longitude column');
	is(&subs::space_weather_aurora_at({ coordinates => \@GRID }, 10, -179.6)->{'aurora_probability'},
		&subs::space_weather_aurora_at({ coordinates => \@GRID }, 10, 180.4)->{'aurora_probability'},
		'and so do -179.6 and 180.4');

	# The poles are clamped, not indexed out of range.
	is(&subs::space_weather_aurora_at({ coordinates => \@GRID }, 95, 10)->{'aurora_probability'},
		10 * 1000 + 180, 'a latitude past the north pole reads the last row');
	is(&subs::space_weather_aurora_at({ coordinates => \@GRID }, -95, 10)->{'aurora_probability'},
		10 * 1000 + 0, 'and past the south pole the first');

	# A grid too small for the direct index falls back to the nearest point,
	# and the nearest point is measured across the longitude wrap.
	my @sparse = ( [ 359, 0, 5 ], [ 5, 0, 9 ] );
	is(&subs::space_weather_aurora_at({ coordinates => \@sparse }, 0, 0.6)->{'aurora_probability'}, 5,
		'the fallback picks 359 degrees over 5 for a house just past 0');
	is(&subs::space_weather_aurora_at({ coordinates => \@sparse }, 0, 3.0)->{'aurora_probability'}, 9,
		'and 5 degrees over 359 for a house at 3');

	# A same-size grid in another order is detected by its second cell and
	# falls through to the nearest-cell search, which is order-independent.
	my @lat_major;
	for my $lat_i (0 .. 180) {
		for my $lon (0 .. 359) { push @lat_major, [ $lon, $lat_i - 90, $lon * 1000 + $lat_i ]; }
	}
	is(&subs::space_weather_aurora_at({ coordinates => \@lat_major }, 40.4, -105.0)->{'aurora_probability'},
		255 * 1000 + 130, 'a misordered grid is caught by its shape and read correctly');
}

# --- Kyoto's line: a filler 0, the 24 hours, then the daily mean -------------
# These are real provisional lines. The hourly mean for day 12 is -58.1 and for
# day 1 it is -29.5; the parser averages 26 numbers (0, 24 hours, the mean).
{
	my $real = join("\n",
		'DST2409*01PPX120   0 -51 -43 -38 -41 -42 -43 -34 -26 -27 -28 -19 -17 -16 -14 -19 -23 -29 -31 -34 -34 -29 -25 -23 -22 -30',
		'DST2409*12PPX120   0  13  18  17  22  38  31  18 -23 -67 -78 -90 -85 -80-112-121-103 -80 -78 -95-107-115-109-101-108 -58',
		'DST2409*17PPX120   0 -23 -42 -80-102-120-119-120-114-121-120-119-116 -96 -87 -94 -91 -90 -93 -91 -85 -78 -76 -68 -60 -92',
		'',
	);
	my $rows = &subs::space_weather_dst_month_parse($real, 2024, 9);
	is($rows->{'2024-09-12'}{'dst_min'}, -121, 'the storm minimum is read from the hourly values');
	is($rows->{'2024-09-17'}{'dst_min'}, -121, 'the second storm day keeps its own minimum');
	is($rows->{'2024-09-01'}{'dst_min'}, -51, 'and a calm day its minimum');

	# The day mean is the mean of the 24 hours, not the filler, the hours and
	# the published mean averaged together.
	is($rows->{'2024-09-12'}{'dst'}, -58.1, 'the day mean is the mean of the 24 hours');
	is($rows->{'2024-09-17'}{'dst'}, -91.9, 'and so is the second day\'s');
	is($rows->{'2024-09-01'}{'dst'}, -29.5, 'and the calm day\'s');

	# Realtime (RRX) and provisional (PPX) headers parse the same way.
	my $rt = &subs::space_weather_dst_month_parse(
		"DST2611*01RRX020   0 -48 -37 -31 -42 -50 -43 -44 -43 -39 -44 -46 -40 -31 -24 -23 -22 -24 -27 -36 -34 -27 -22 -19 -17 -34\n",
		2026, 11,
	);
	is($rt->{'2026-11-01'}{'dst_min'}, -50, 'the realtime header is read too');

	# A missing hour (9999) is not a minimum and does not poison the average.
	my $gap = 'DST2611*02RRX020   0  10  10 9999  10  10  10  10  10  10  10  10  10  10  10  10  10  10  10  10  10  10  10  10  10  10';
	my $g = &subs::space_weather_dst_month_parse($gap, 2026, 11);
	is($g->{'2026-11-02'}{'dst_min'}, 0, 'a 9999 gap never becomes the minimum');

	# A month with no DST lines is simply empty, not an error.
	is_deeply(&subs::space_weather_dst_month_parse("<html>404</html>\n", 2026, 11), {},
		'a missing month parses to no days');
	is_deeply(&subs::space_weather_dst_month_parse('', 2026, 11), {}, 'and an empty body too');
}

# --- GFZ: Kp1..8 at 7..14, Ap 23, SN 24, F10.7obs 25, -1 means missing -------
{
	# Real lines: the 1932 line has Kp 3.333 at the top and -1.0 for F10.7.
	my $text = join("\n",
		'# YYYY MM DD  days days_m BSR dB ...',
		'1932 01 01     0     0.5 1352 10  3.333  2.667  2.333  2.667  3.333  2.667  3.333  3.333   18   12    9   12   18   12   18   18    15  22     -1.0     -1.0 2',
		'1932 01 02     1     1.5 1352 11  -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000 -1.000   -1   -1   -1   -1   -1   -1   -1   -1    -1  -1     -1.0     -1.0 0',
		'2026 11 15     0     0.5 1900 10  2.000  1.000  3.000  1.000  2.000  1.000  1.000  2.000   12    5   15    5   12    5    5   12     7  42     88.5     86.0 2',
		'',
	);
	my $all = &subs::space_weather_history_parse($text);
	is($all->{'1932-01-01'}{'kp'}, 3.333, 'the day\'s highest Kp is the max of Kp1..Kp8');
	is($all->{'1932-01-01'}{'ap'}, 15, 'Ap comes from column 23, past the eight ap values');
	is($all->{'1932-01-01'}{'sunspot_number'}, 22, 'SN comes from column 24');
	ok(!exists $all->{'1932-01-01'}{'f107'}, 'a -1.0 F10.7 is a missing value, not a reading');
	ok(!exists $all->{'1932-01-02'}, 'a day whose every value is -1 is dropped, not written as zero');
	is($all->{'2026-11-15'}{'kp'}, 3, 'a present-day line reads its Kp');
	is($all->{'2026-11-15'}{'ap'}, 7, 'and its Ap');
	is($all->{'2026-11-15'}{'f107'}, 88.5, 'and F10.7obs, not F10.7adj');

	# The window is a UTC day at noon: a 'from' after that noon drops the day.
	my $from = ts(1932, 1, 2, 0, 0, 0);
	my $windowed = &subs::space_weather_history_parse($text, $from, undef);
	ok(!exists $windowed->{'1932-01-01'}, 'a day before the window is not read');
	ok(exists $windowed->{'2026-11-15'}, 'a day inside it is');
	my $up_to = ts(1932, 1, 1, 6, 0, 0);
	ok(!exists &subs::space_weather_history_parse($text, undef, $up_to)->{'1932-01-01'},
		'a day whose noon is past the window end is not read either');

	# The current-day row is at noon, so a backfill before noon UTC loses today.
	ok(!exists &subs::space_weather_history_parse($text, undef, ts(2026, 11, 15, 8, 0, 0))->{'2026-11-15'},
		'a same-day row is dropped when the window ends before noon UTC');
}

# --- the backfill tries provisional first, then realtime ---------------------
{
	my @urls;
	my @writes;
	local *subs::weather_http_get_text = sub {
		my ($url) = @_;
		push @urls, $url;
		if ($url =~ /gfz-potsdam/) {
			return ('2026 11 10 0 0.5 1900 10  2 1 3 1 2 1 1 2  12 5 15 5 12 5 5 12  7 42 88.5 86.0 2' . "\n"
				. '2026 11 15 0 0.5 1900 10  2 1 3 1 2 1 1 2  12 5 15 5 12 5 5 12  7 42 88.5 86.0 2' . "\n", undef);
		}
		if ($url =~ /dst_provisional/) { return (undef, 'HTTP 404') }
		if ($url =~ /dst_realtime/) {
			return ("DST2611*01RRX020   0 -48 -37 -31 -42 -50 -43 -44 -43 -39 -44 -46 -40 -31 -24 -23 -22 -24 -27 -36 -34 -27 -22 -19 -17 -34\n"
				. "DST2611*15RRX020   0  13  18  17  22  38  31  18 -23 -67 -78 -90 -85 -80-112-121-103 -80 -78 -95-107-115-109-101-108 -58\n", undef);
		}
		return (undef, 'unexpected');
	};
	local *subs::astronomy_measure_write = sub {
		push @writes, [ $_[0], $_[1], $_[2] ];
		return 'uuid';
	};

	my $got = &subs::space_weather_backfill({
		from => ts(2026, 11, 15, 0, 0, 0),
		to => ts(2026, 11, 15, 23, 0, 0),
	});
	is($got->{'months'}, 1, 'one month is fetched for a one-day window inside a month');
	is($got->{'days'}, 1, 'only the day inside the window is counted');
	is(scalar @writes, 1, 'and written once');
	is($writes[0][0], 'space_weather', 'into the space weather app');
	is($writes[0][1]{'kp'}, 3, 'the GFZ Kp is merged in');
	is($writes[0][1]{'ap'}, 7, 'and its Ap');
	is($writes[0][1]{'dst_min'}, -121, 'and the Kyoto minimum from the realtime fallback');
	ok(!exists $writes[0][1]{'_when'}, 'the internal day stamp is not written as a measure');

	my @prov = grep { m{/dst_provisional/} } @urls;
	my @rt = grep { m{/dst_realtime/} } @urls;
	is(scalar @prov, 1, 'the provisional file is tried');
	is(scalar @rt, 1, 'and the realtime file only after it is missing');
	like($prov[0], qr{/202611/dst2611\.for\.request$}, 'the provisional URL carries YYYYMM and YYMM');
	like($rt[0], qr{/202611/dst2611\.for\.request$}, 'and so does the realtime URL');

	@writes = ();
	my $dry = &subs::space_weather_backfill({
		from => ts(2026, 11, 15, 0, 0, 0),
		to => ts(2026, 11, 15, 23, 0, 0),
		dry_run => 1,
	});
	is($dry->{'days'}, 1, 'a dry run still counts the day');
	is($dry->{'written'}, 0, 'but writes nothing');
	is(scalar @writes, 0, 'and the writer is never called');
}

# --- the same day written twice merges, it does not duplicate ----------------
# The daily tick writes the Dst of the moment; the backfill writes the day's
# mean. Both land in one row, and dst is whichever ran last while dst_min stays.
{
	local *subs::period_bounds = sub { return (1000, 2000) };
	local *subs::rightNow = sub { return 1500 };
	local *subs::device_setter = sub { return 'test-device' };
	local *subs::setting_grabber = sub { return undef };
	local *subs::setting_setter = sub { };
	my @inserted;
	my @updated;
	local *subs::db_insert = sub { push @inserted, [ @_ ] };
	local *subs::db_update = sub { push @updated, [ @_ ] };

	local *subs::db_query = sub { return FakeResult->new([]) };
	my $uuid = &subs::astronomy_measure_write('space_weather', { dst => -20 }, 1200);
	ok($uuid, 'the tick writes the day');
	is(scalar @inserted, 1, 'one row');

	my $row = {
		uuid => 'space-row',
		timestamp => 1200,
		measures => $inserted[0][1]{'measures'},
	};
	local *subs::db_query = sub { return FakeResult->new([ $row ]) };
	&subs::astronomy_measure_write('space_weather', { dst => -58.1, dst_min => -121 }, 1300, { seed => 'backfill' });
	is(scalar @updated, 1, 'the backfill updates the same row');
	my $entry = (decode_json($updated[0][1]{'measures'}))->[-1];
	is($entry->{'dst'}, -58.1, 'dst is the last writer: the daily mean replaces the hour');
	is($entry->{'dst_min'}, -121, 'and the minimum is kept');
}

# --- the evaluation caps the readings per app, and the whole list at 15 ------
{
	my %daily;
	my %series;
	my @names = qw(ap aurora_probability bz bt dst dst_min f107 g_scale kp kp_max_24h
		r_scale s_scale solar_wind_density solar_wind_speed sunspot_number);
	for my $i (1 .. 20) {
		my $day = sprintf('2026-10-%02d', $i);
		$daily{$day} = 1 + ($i % 5);
	}
	my $idx = 0;
	foreach my $name (@names) {
		$idx++;
		my %points;
		for my $i (1 .. 20) {
			my $day = sprintf('2026-10-%02d', $i);
			# dst tracks the day exactly (r = 1.00); dst_min is noise, so it
			# ranks last and loses its place under the cap.
			$points{$day} = $name eq 'dst' ? $daily{$day}
				: $name eq 'dst_min' ? 1 + (($i * 7) % 11)
				: $daily{$day} + (($i * $idx) % 3);
		}
		$series{$name} = \%points;
	}
	my %mag;
	foreach my $name (qw(magnetic_f magnetic_d magnetic_i magnetic_x)) {
		$mag{$name} = { map { sprintf('2026-10-%02d', $_) => 100 + $_ } 1 .. 20 };
	}
	my $out = &subs::evaluation_house_conditions({
		daily => \%daily,
		measures => {
			space_weather => \%series,
			magnetometer => \%mag,
		},
	});
	my @sw = grep { $_->{'app'} eq 'space_weather' } @{$out};
	my @mg = grep { $_->{'app'} eq 'magnetometer' } @{$out};
	is(scalar @sw, 7, 'space weather keeps seven readings');
	is(scalar @mg, 3, 'the local field keeps three');
	ok((grep { $_->{'measure'} eq 'dst' } @sw), 'the strongest reading is kept');
	ok(!(grep { $_->{'measure'} eq 'dst_min' } @sw),
		'a weaker reading loses its place to the seven that rank higher (the documented cap)');
	ok(!(grep { $_->{'measure'} eq 'magnetic_x' } @mg),
		'magnetic x is not a house condition at all');

	# A short series is still offered, flagged as too short to correlate.
	my $short = &subs::evaluation_house_conditions({
		daily => \%daily,
		measures => { space_weather => { dst => { '2026-10-01' => -10, '2026-10-02' => -20 } } },
	});
	is(scalar @{$short}, 1, 'a two-day reading is still a current condition');
	is($short->[0]{'measure'}, 'dst', 'dst is one of them');
	is($short->[0]{'insufficient_days'}, 1, 'and is marked too short to correlate');
	is($short->[0]{'latest'}, -20, 'its latest value follows the date, not the insertion order');
	is($short->[0]{'min'}, -20, 'and its minimum');
	is($short->[0]{'max'}, -10, 'and its maximum');

	# The whole list stops at fifteen even when five apps each have four.
	my %many;
	foreach my $app (qw(a1 a2 a3 a4 a5)) {
		foreach my $name (qw(temperature humidity pressure wind_speed)) {
			$many{$app}{$name} = { map { sprintf('2026-10-%02d', $_) => 10 + (($_ * 3) % 7) } 1 .. 20 };
		}
	}
	my $capped = &subs::evaluation_house_conditions({ daily => \%daily, measures => \%many });
	is(scalar @{$capped}, 15, 'the list is capped at fifteen readings');
	my %per;
	$per{ $_->{'app'} }++ for @{$capped};
	ok((!grep { $_ > 4 } values %per), 'and no app contributes more than four of them');
}

# --- a tight digest fit trims the conditions, never the house total ----------
{
	my @conditions = map {
		{ app => ( 'a' x 60 ) . $_, measure => 'kp', r => '0.50', lag_days => 0, n => 20 }
	} (1 .. 14);
	my $digest = {
		house => { apps => 7, categories => 1, windows => {}, daily => {}, hours => {}, weekdays => {} },
		categories => [ { name => 'nature', apps => 1, occurrences => 9, per_day => '0.30', total_duration => '', top_apps => [] } ],
		tail => { apps => 0, occurrences => 0 },
		conditions => \@conditions,
		money => { in => '1', out => '2', net => '-1', apps => [] },
		people => { count => 1 },
	};
	my ($fitted, $bytes, $truncated) = &subs::evaluation_digest_fit($digest, 1400);
	ok($truncated, 'the digest was fitted');
	cmp_ok(scalar @{ $fitted->{'conditions'} || [] }, '<=', 8,
		'the conditions are trimmed to at most eight before being dropped');
	is($fitted->{'house'}{'apps'}, 7, 'the house total survives every step');
}

done_testing();
