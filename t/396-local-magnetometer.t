# tests-for: lib/JawnOS/Domain/Astronomy.pm lib/JawnOS/Domain/Loader.pm
# covers:    the local magnetometer reads INTERMAGNET's GIN for the nearest
#            observatory, including the Canadian codes the USGS data API
#            rejects, and falls back to USGS when INTERMAGNET has no reading.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib";
use Test::More;
use JSON::PP qw(decode_json);
use Time::Local qw(timegm);
use RepoSource;

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Astronomy.pm";

# Two published samples followed by the null INTERMAGNET sends for a sample it
# has not released yet. The reader must take index 1, not the trailing null.
my $fixture = <<'JSON';
{
  "datetime": [ "2026-11-21T23:58:00.000Z", "2026-11-21T23:59:00.000Z" ],
  "F": [ 56300.0, 56290.5, null ],
  "X": [ 20000.0, 20468.0, null ],
  "Y": [ -700.0, -759.0, null ],
  "Z": [ 39000.0, 39753.0, null ],
  "@info": {
    "iaga_code": "OTT",
    "station_name": "Ottawa, Canada",
    "latitude": 45.403,
    "longitude": 284.448
  }
}
JSON

# --- the INTERMAGNET reader --------------------------------------------------
{
	my $reading = &subs::space_weather_intermagnet_parse(decode_json($fixture));
	is($reading->{'f'}, 56290.5, 'F is the last defined value');
	is($reading->{'x'}, 20468, 'X is the last defined value');
	is($reading->{'y'}, -759, 'Y is the last defined value');
	is($reading->{'z'}, 39753, 'Z is the last defined value');
	cmp_ok($reading->{'d'}, '<', 0, 'declination keeps its western sign');
	cmp_ok($reading->{'i'}, '>', 0, 'inclination points down in the north');
	is($reading->{'observatory'}, 'OTT', 'the IAGA code comes from @info');
	is($reading->{'name'}, 'Ottawa, Canada', 'and the station name');
	is($reading->{'observed_at'}, timegm(0, 59, 23, 21, 10, 2026) * 1000,
		'the last defined sample carries its own timestamp, not the trailing null');
}

for my $case (
	[ 'an empty hash', {} ],
	[ 'null input', undef ],
	[ 'empty arrays', { F => [], X => [], Y => [], Z => [] } ],
	[ 'all null', decode_json('{"F":[null],"X":[null],"Y":[null],"Z":[null]}') ],
) {
	my ($label, $json) = @{$case};
	is_deeply(&subs::space_weather_intermagnet_parse($json), {}, "$label has no reading");
}

# F alone is still a reading, but it cannot yield a declination.
{
	my $f_only = &subs::space_weather_intermagnet_parse({ F => [ 51000, 51200 ] });
	is($f_only->{'f'}, 51200, 'a total-field-only response still reads F');
	ok(!exists $f_only->{'d'}, 'and derives no declination without X and Y');
}

# --- the catalogue and the nearest station -----------------------------------
{
	my $merged = &subs::space_weather_stations_merge([
		{ id => 'frd', name => 'Fredericksburg', lat => 38.2, lon => -77.37 },
		{ id => 'OTT', name => 'USGS Ottawa', lat => 45.4, lon => -75.5 },
	]);
	my %by = map { $_->{'id'} => $_ } @{$merged};
	is(scalar @{$merged}, 3, 'two USGS codes plus one curated addition');
	ok($by{'FRD'}, 'a lower-case USGS code is upper-cased');
	is($by{'OTT'}{'name'}, 'USGS Ottawa', 'the first row for a code wins');
	ok($by{'MEA'}, 'Meanook is added from the curated INTERMAGNET catalogue');
	is($by{'MEA'}{'lat'}, 54.616, 'with its own latitude');
}

{
	my $stations = &subs::space_weather_stations_merge([
		{ id => 'FRD', name => 'Fredericksburg', lat => 38.2, lon => -77.37 },
	]);
	my $near = &subs::space_weather_stations_nearest($stations, 45.403, -75.552);
	is($near->[0]{'id'}, 'OTT', 'a place at Ottawa gets Ottawa first');
	cmp_ok($near->[0]{'km'}, '<', 1, 'at (almost) no distance');
	cmp_ok($near->[-1]{'km'}, '>', $near->[0]{'km'}, 'and the list runs nearest first');

	# The place is (lat 10, lon 80); A sits on its meridian, B on its parallel.
	# If latitude and longitude were swapped, B would win instead.
	my $crossed = &subs::space_weather_stations_nearest([
		{ id => 'A', lat => 10, lon => 81 },
		{ id => 'B', lat => 80, lon => 10 },
	], 10, 80);
	is($crossed->[0]{'id'}, 'A', 'latitude and longitude are not swapped');

	is_deeply(&subs::space_weather_stations_nearest([], 45, -75), [], 'no stations, no list');
	is_deeply(&subs::space_weather_stations_nearest($stations, 'north', -75), [],
		'a non-numeric place has no nearest');
}

{
	my $url = &subs::space_weather_intermagnet_url('OTT', '2026-11-17', '2026-11-23');
	like($url, qr{^https://imag-data\.bgs\.ac\.uk/GIN_V1/GINServices\?}, 'the GIN endpoint is used');
	like($url, qr/observatoryIagaCode=OTT/, 'with the station code');
	like($url, qr/dataStartDate=2026-11-17/, 'and the requested start');
	like($url, qr/dataEndDate=2026-11-23/, 'and end');
	is(&subs::space_weather_intermagnet_url('bad code!'), '', 'an invalid code has no URL');
}

# --- the magnetometer prefers INTERMAGNET ------------------------------------
{
	my $im = decode_json($fixture);
	my @asked;

	local *subs::_usgs_observatories = sub {
		return [
			{ id => 'OTT', name => 'Ottawa, Canada', lat => 45.403, lon => -75.552 },
			{ id => 'FAR', name => 'Far away', lat => -40, lon => 100 },
		];
	};
	local *subs::weather_http_get = sub {
		my ($url) = @_;
		push @asked, $url;
		return ($im, undef) if $url =~ /GINServices/ && $url =~ /observatoryIagaCode=OTT/;
		return ({ datetime => [], F => [], X => [], Y => [], Z => [] }, undef) if $url =~ /GINServices/;
		return (undef, 'HTTP 422') if $url =~ /geomag\.usgs\.gov/;
		return (undef, 'unexpected');
	};

	my $reading = &subs::space_weather_magnetometer(undef, 45.403, -75.552);
	is($reading->{'observatory'}, 'OTT', 'the nearest station answers from INTERMAGNET');
	is($reading->{'name'}, 'Ottawa, Canada', 'the GIN metadata names it');
	is($reading->{'f'}, 56290.5, 'the reading is the INTERMAGNET one');
	is($reading->{'distance_km'}, 0, 'and its distance from the place is reported');
	like($asked[0], qr/GINServices.*observatoryIagaCode=OTT/, 'INTERMAGNET is asked first');
}

# --- and falls back to USGS when INTERMAGNET is empty ------------------------
{
	my $usgs = {
		metadata => { intermagnet => { imo => { iaga_code => 'FRD', name => 'Fredericksburg' } } },
		times => [ '2026-11-21T23:59:00.000Z' ],
		values => [
			{ id => 'X', values => [ 20000, 20468 ] },
			{ id => 'Y', values => [ -700, -759 ] },
			{ id => 'Z', values => [ 39000, 39753 ] },
			{ id => 'F', values => [ 46000, 46325 ] },
		],
	};
	local *subs::_usgs_observatories = sub {
		return [ { id => 'FRD', name => 'Fredericksburg', lat => 38.2, lon => -77.37 } ];
	};
	local *subs::weather_http_get = sub {
		my ($url) = @_;
		return ({ datetime => [], F => [], X => [], Y => [], Z => [] }, undef) if $url =~ /GINServices/;
		return ($usgs, undef) if $url =~ /geomag\.usgs\.gov\/ws\/data\/\?id=FRD/;
		return (undef, 'unexpected');
	};

	my $reading = &subs::space_weather_magnetometer(undef, 38.2, -77.37);
	is($reading->{'observatory'}, 'FRD', 'USGS answers when INTERMAGNET has no reading');
	is($reading->{'f'}, 46325, 'with its own total field');
	is($reading->{'distance_km'}, 0, 'and the distance is still reported');
}

# --- the loader knows the new names -----------------------------------------
require "$root/lib/JawnOS/Domain/Loader.pm";
for my $name (qw(space_weather_intermagnet_parse space_weather_stations_merge
	space_weather_stations_nearest space_weather_intermagnet_url)) {
	ok(subs::provides($name), "$name is registered in the domain loader");
}

done_testing();
