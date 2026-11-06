# tests-for: lib/JawnOS/Domain/Weather.pm lib/JawnOS/Domain/WeatherHistory.pm lib/JawnOS/Controller/manager_weather.pm lib/JawnOS/Routes/manager_weather.pm templates/apps/weather.html.ep public/js/manager/weather.js
# covers:    The Weather app's pure parsers for Environment Canada and Open-Meteo,
#            the country-to-provider choice, and the app's route/menu/help wiring.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;
use Mojo::JSON;
use Time::Piece;

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Weather.pm";
require "$root/lib/JawnOS/Domain/WeatherHistory.pm";

# --- Environment Canada: the nested {value}{en} shape ------------------------
my $ec = {
	properties => {
		lastUpdated => '2026-11-06T16:02:03Z',
		name => { en => 'Kitchener-Waterloo', fr => 'Kitchener-Waterloo' },
		region => { en => 'Waterloo', fr => 'Waterloo' },
		currentConditions => {
			temperature => { value => { en => 7.9 } },
			relativeHumidity => { value => { en => 82 } },
			wind => {
				speed => { value => { en => 15 } },
				direction => { value => { en => 'WNW' } },
				gust => { value => { en => 30 } },
			},
			pressure => { units => { en => 'kPa' }, value => { en => 101.2 } },
			dewpoint => { value => { en => 5 } },
			windChill => { value => { en => 6 } },
			condition => { en => 'Cloudy' },
			timestamp => { en => '2026-11-06T16:00:00Z' },
			iconCode => { value => 4, url => 'https://weather.gc.ca/weathericons/04.gif' },
			station => { value => { en => 'YKF' } },
		},
		hourlyForecastGroup => {
			hourlyForecasts => [{
				timestamp => '2026-11-06T17:00:00Z',
				temperature => { value => { en => 8 } },
				condition => { en => 'Cloudy' },
				iconCode => { value => 4 },
				lop => { value => { en => 30 } },
				wind => { speed => { value => { en => 10 } }, direction => { value => { en => 'W' } } },
			}],
		},
		forecastGroup => {
			forecasts => [{
				period => { textForecastName => { en => 'Today' } },
				temperatures => { temperature => [
					{ class => { en => 'high' }, value => { en => 10 } },
					{ class => { en => 'low' }, value => { en => 2 } },
				] },
				abbreviatedForecast => {
					textSummary => { en => 'Cloudy with 40 percent chance of showers' },
					icon => { value => 6 },
				},
				cloudPrecip => { en => 'Cloudy with 40 percent chance of showers.' },
				winds => { periods => [{ speed => { value => { en => 20 } }, bearing => { value => { en => 270 } } }] },
			}],
		},
		warnings => [],
	},
};

my $out = subs::weather_ec_normalize($ec);
is($out->{'provider'}, 'ec', 'EC keeps its provider');
is($out->{'location_name'}, 'Kitchener-Waterloo', 'EC names the nearest city');
is($out->{'current'}{'temperature'}, 7.9, 'EC reads the nested temperature');
is($out->{'current'}{'feels_like'}, 6, 'EC reads the wind chill as feels-like');
is($out->{'current'}{'wind_direction'}, 'WNW', 'EC keeps the wind direction word');
is($out->{'current'}{'high'}, 10, 'EC reads the high');
is($out->{'current'}{'low'}, 2, 'EC reads the low');
is(scalar @{$out->{'hourly'}}, 1, 'EC reads hourly periods');
is($out->{'hourly'}[0]{'precip_prob'}, 30, 'EC reads the hourly precipitation probability');
is(scalar @{$out->{'daily'}}, 1, 'EC reads daily periods');
is($out->{'daily'}[0]{'precip_prob'}, 40, 'EC reads the chance from the forecast text');
is($out->{'daily'}[0]{'wind_direction'}, 'W', 'EC turns the forecast bearing into a compass point');

# --- Open-Meteo: plain numbers and parallel arrays ---------------------------
my $om = {
	timezone => 'America/Toronto',
	current => {
		time => '2026-11-06T11:45',
		temperature_2m => 8.7,
		relative_humidity_2m => 80,
		apparent_temperature => 7,
		weather_code => 3,
		wind_speed_10m => 11.2,
		wind_direction_10m => 270,
		wind_gusts_10m => 20,
		pressure_msl => 1012,
		dew_point_2m => 5,
		precipitation => 0,
		cloud_cover => 90,
	},
	hourly => {
		time => [ '2026-11-06T11:00', '2026-11-06T12:00' ],
		temperature_2m => [ 8, 9 ],
		weather_code => [ 3, 61 ],
		precipitation_probability => [ 10, 20 ],
		wind_speed_10m => [ 10, 11 ],
		wind_direction_10m => [ 270, 280 ],
	},
	daily => {
		time => [ '2026-11-06', '2026-11-07' ],
		weather_code => [ 3, 61 ],
		temperature_2m_max => [ 11, 7 ],
		temperature_2m_min => [ 4, 1 ],
		precipitation_probability_max => [ 30, 80 ],
		wind_speed_10m_max => [ 15, 20 ],
		uv_index_max => [ 2, 1 ],
		sunrise => [ '2026-11-06T07:00', '2026-11-07T07:01' ],
		sunset => [ '2026-11-06T17:00', '2026-11-07T16:59' ],
	},
};
my $mo = subs::weather_openmeteo_normalize($om);
is($mo->{'provider'}, 'openmeteo', 'Open-Meteo keeps its provider');
is($mo->{'current'}{'temperature'}, 8.7, 'Open-Meteo reads the current temperature');
is($mo->{'current'}{'wind_direction'}, 'W', 'Open-Meteo turns degrees into a compass point');
is($mo->{'current'}{'condition'}, 'Overcast', 'Open-Meteo maps the WMO code to words');
is($mo->{'current'}{'glyph'}, '☁️', 'Open-Meteo maps the WMO code to a glyph');
is(scalar @{$mo->{'hourly'}}, 2, 'Open-Meteo reads the hourly arrays');
is(scalar @{$mo->{'daily'}}, 2, 'Open-Meteo reads the daily arrays');
is($mo->{'daily'}[0]{'high'}, 11, 'Open-Meteo reads the high');

# --- a cached payload without hourly periods is not trusted -------------------
{
	my %store;
	my $now = Time::Piece::gmtime()->epoch * 1000;
	no warnings 'redefine';
	local *subs::rightNow = sub { $now };
	local *subs::cache_get = sub {
		my ($q) = @_;
		return $store{ join('|', $q->{'app'}, $q->{'context'}, $q->{'subcontext'} // '') };
	};
	local *subs::cache_set = sub {
		my ($q, $value) = @_;
		$store{ join('|', $q->{'app'}, $q->{'context'}, $q->{'subcontext'} // '') } = $value;
		return 1;
	};
	# The Weather app once cached an EC city page before it read the hourly
	# periods, so the strip stayed empty for the whole cache window.
	$store{'weather|forecast|43.45_-80.49_ec'} = {
		fetched_at => $now, provider => 'ec',
		current => {}, hourly => [], daily => [],
	};
	my $ec_live = Mojo::JSON::decode_json(Mojo::JSON::encode_json($ec));
	$ec_live->{'properties'}{'lastUpdated'} = Time::Piece::gmtime()->strftime('%Y-%m-%dT%H:%M:%SZ');
	push @{ $ec_live->{'properties'}{'forecastGroup'}{'forecasts'} }, {
		period => { textForecastName => { en => 'Tomorrow' } },
		temperatures => { temperature => [
			{ class => { en => 'high' }, value => { en => 6 } },
			{ class => { en => 'low' }, value => { en => 0 } },
		] },
		abbreviatedForecast => { textSummary => { en => 'Rain' }, icon => { value => 12 } },
		cloudPrecip => { en => 'Rain.' },
	};
	my %seen_url;
	local *subs::weather_http_get = sub {
		my ($url) = @_;
		$seen_url{$url}++;
		if ($url =~ m{/items\?}) {
			return ({ features => [ {
				geometry => { coordinates => [-80.49, 43.45] },
				properties => { identifier => 'on-82', name => 'Kitchener-Waterloo', region => 'Waterloo' },
			} ] }, undef);
		}
		return ($ec_live, undef) if $url =~ m{/items/on-82\?};
		return (undef, 'unexpected URL');
	};
	my $fetched = subs::weather_fetch(43.45, -80.49, {});
	is($fetched->{'error'}, undef, 'the fetch answers');
	is(scalar @{ $fetched->{'hourly'} || [] }, 1, 'a cached payload with no hourly periods is fetched again');
	is(scalar @{ $fetched->{'daily'} || [] }, 2, 'day and night merge into one calendar day');
	my $tomorrow = &subs::weather_day_key($now + 86400000);
	my $snap = $store{'weather|forecast_history|43.45_-80.49'} || {};
	ok($snap->{$tomorrow}{1}, 'the forecast is kept for the day it is about');
	is($snap->{$tomorrow}{1}{'high'}, 6, 'the snapshot keeps the forecast high');
	ok($store{'weather|forecast|43.45_-80.49_ec'}{'fetched_at'}, 'the fresh answer is cached');
	ok(!$snap->{ &subs::weather_day_key($now) }, 'today has no lead time to score');
}

# --- provider choice ---------------------------------------------------------
is(subs::weather_provider_default(43.5, -80.5), 'ec', 'Canada uses Environment Canada');
is(subs::weather_provider_default(40.7, -74.0), 'nws', 'the US uses the National Weather Service');
is(subs::weather_provider_default(51.5, -0.1), 'openmeteo', 'elsewhere uses Open-Meteo');
is(subs::weather_provider_for(51.5, -0.1, 'ec'), 'ec', 'an explicit provider wins');

# --- small pure helpers ------------------------------------------------------
is(subs::weather_compass(0), 'N', '0 degrees is north');
is(subs::weather_compass(180), 'S', '180 degrees is south');
is(subs::weather_wmo_text(0), 'Clear sky', 'WMO 0 is clear');
is(subs::weather_wmo_text(95), 'Thunderstorm', 'WMO 95 is a thunderstorm');
cmp_ok(subs::weather_distance_km(43.45, -80.49, 43.65, -79.38), '>', 50, 'Kitchener to Toronto is a real distance');
cmp_ok(subs::weather_distance_km(43.45, -80.49, 43.65, -79.38), '<', 150, 'and not an absurd one');

# --- the app is wired into the menu, routes and help ------------------------
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::Weather' for qw\([^)]*weather_fetch/, 'the domain loader maps weather_fetch');
like($loader, qr/JawnOS::Domain::Weather' for qw\([^)]*weather_device_fixes/, 'and the GPS helper');

my $route_index = read_file("$root/lib/JawnOS/Routes.pm");
like($route_index, qr/\bmanager_weather\b/, 'the route group is registered');
my $routes = read_file("$root/lib/JawnOS/Routes/manager_weather.pm");
like($routes, qr{/manager/weather\b}, 'the page route exists');
like($routes, qr{/manager/weather/data\b}, 'the data route exists');
my $controller = read_file("$root/lib/JawnOS/Controller/manager_weather.pm");
like($controller, qr/sub action_52010\b/, 'the page action exists');
like($controller, qr/sub action_52011\b/, 'the data action exists');

my $known = read_file("$root/perl/gb/02_labels_and_collectives.pl");
like($known, qr/weather\s*=>\s*\{\s*icon/, 'the app has an icon entry');
my $menu = read_file("$root/templates/start_menu/start_menu.html.ep");
like($menu, qr/id="weather_toggle"/, 'the start menu has a Weather tile');
my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($core, qr{/js/manager/weather\.js}, 'the lazy app loads its JavaScript');
like($core, qr/weather_toggle\s*=>\s*'weather'/, 'the tile is bound to the app');
like($core, qr/weather\s*=>\s*\[qw\(weatherMaker\)\]/, 'the entry function is stubbed');

my $help = read_file("$root/perl/help/topics_apps.pl");
like($help, qr/\$topic\{'weather'\}\s*=\s*\{/, 'the help topic exists');
like($help, qr/app\s*=>\s*'weather'/, 'the topic names the app');

done_testing();
