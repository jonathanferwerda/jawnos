# tests-for: lib/JawnOS/Domain/Weather.pm lib/JawnOS/Domain/WeatherHistory.pm lib/JawnOS/Domain/WeatherAutomation.pm lib/JawnOS/Controller/manager_weather.pm lib/JawnOS/Routes/manager_weather.pm templates/apps/weather.html.ep templates/apps/weather/automations.html.ep public/js/manager/weather.js public/js/manager/weather_history.js public/js/manager/weather_automation.js
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
require "$root/lib/JawnOS/Domain/Format.pm";
require "$root/lib/JawnOS/Domain/WeatherAutomation.pm";

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
like($help, qr/automations\.html\.ep/, 'the help topic claims the Automations tab');

# --- weather automations -----------------------------------------------------
my $source_am = {
	condition => {
		type => 'text',
		value => 'cloudy',
		cm => [
			{ uuid => 'rule-rain', type => 'match', match => 'Rain', app => 'raining', action => 'start' },
			{ uuid => 'rule-fog', type => 'match', match => 'fog', app => 'foggy', action => 'start' },
			{ uuid => 'rule-snow', type => 'match', match => 'snow', app => 'snowing', action => 'start' },
			{ uuid => 'blank', type => '', match => '', app => '', action => '' },
		],
	},
};
my $source_json = Mojo::JSON::encode_json($source_am);

my $rules = subs::weather_automation_rules($source_am);
is(scalar @{$rules}, 3, 'the blank configure row is not a rule');
is($rules->[0]{'uuid'}, 'rule-rain', 'rules keep their uuid');

my $clean = subs::weather_automation_normalize({ uuid => 'rule-clean', match => ' Rain ', app => 'Raining', action => '' });
is($clean->{'match'}, 'rain', 'a match is trimmed and read as the stored state');
is($clean->{'app'}, 'raining', 'an app name is unformatted');
is($clean->{'action'}, 'start', 'an empty action starts the app');
ok(!subs::weather_automation_normalize({ match => 'rain', app => '' }), 'a rule without an app is refused');
is(subs::weather_automation_normalize({ uuid => 'rule-words', match => 'light rain', app => 'raining' })->{'match'}, 'light_rain', 'a two-word match reads as the stored state');

my $added = subs::weather_automation_apply($rules, { uuid => 'rule-thunder', match => 'thunder', app => 'thunderstorm', action => 'start' });
is(scalar @{$added}, 4, 'a new rule is appended');
my $edited = subs::weather_automation_apply($added, { uuid => 'rule-rain', match => 'shower', app => 'raining', action => 'start' });
is(scalar @{$edited}, 4, 'an edit by uuid replaces in place');
my ($rain) = grep { $_->{'uuid'} eq 'rule-rain' } @{$edited};
is($rain->{'match'}, 'shower', 'the edit replaced the match');
my $removed = subs::weather_automation_apply($edited, { uuid => 'rule-fog', remove => 1 });
is(scalar @{$removed}, 3, 'a remove drops its uuid');

my $matches = subs::weather_automation_matches($rules, 'Light Rain');
is(scalar @{$matches}, 1, 'a condition matches a substring rule');
is($matches->[0]{'app'}, 'raining', 'and names the app');
is(scalar @{ subs::weather_automation_matches($rules, 'Partly Cloudy') }, 0, 'a condition with no match wakes nothing');

# --- the rules' home and the observation -------------------------------------
{
	my %store;
	my $now = 1794000000000;
	my @written;
	no warnings 'redefine';
	local *subs::rightNow = sub { $now };
	local *subs::random_string_creator = sub { 'newrule' . scalar(@written) . 'xx' };
	local *subs::cache_get = sub {
		my ($q) = @_;
		return $store{ join('|', $q->{'app'}, $q->{'context'}, $q->{'subcontext'} // '') };
	};
	local *subs::cache_set = sub {
		my ($q, $value) = @_;
		$store{ join('|', $q->{'app'}, $q->{'context'}, $q->{'subcontext'} // '') } = $value;
		return 1;
	};
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $source_json if $q->{'app'} eq 'weather' && $q->{'setting'} eq 'app_measures';
		return '[\"rain\",\"snow\"]' if $q->{'app'} eq 'weather' && $q->{'setting'} eq 'seen_measures';
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		push @written, $q;
		return 1;
	};
	local *subs::controller_builder = sub { return bless {}, 'FakeController' };
	local *Manager::appt_measure_writer = sub {
		my ($c, $data) = @_;
		$store{'measure'} = $data;
		return 'measure-uuid';
	};

	my $state = subs::weather_automation_state();
	is($state->{'app'}, 'weather_station', 'the rules live on the weather station app');
	is(scalar @{$state->{'rules'}}, 3, 'the old rules are carried over');
	is($state->{'condition_text'}, 'Cloudy', 'the last condition is shown as words');
	ok($store{'setting|weather_station|app_measures'}, 'the station app gets the rules');
	my $old = Mojo::JSON::decode_json($store{'setting|weather|app_measures'});
	is(scalar @{$old->{'condition'}{'cm'}}, 0, 'the old London app no longer drives automations');

	my $first = subs::weather_observe_record({ current => { condition => 'Light Rain' } }, {});
	is($first->{'ok'}, 1, 'a condition is recorded');
	is($store{'measure'}{'value'}, 'Light Rain', 'the raw condition is handed to the measure writer');
	is($first->{'matched'}[0]{'app'}, 'raining', 'the matching rule is reported');

	my $again = subs::weather_observe_record({ current => { condition => 'Light Rain' } }, {});
	is($again->{'skipped'}, 'waiting', 'the same condition is not written again inside the window');

	$now += 31 * 60 * 1000;
	my $later = subs::weather_observe_record({ current => { condition => 'Light Rain' } }, {});
	is($later->{'ok'}, 1, 'the same condition is written again after the window');

	my $changed = subs::weather_observe_record({ current => { condition => 'Snow' } }, {});
	is($changed->{'ok'}, 1, 'a changed condition is written at once');
	is($changed->{'matched'}[0]{'app'}, 'snowing', 'the snow rule answers');

	local *subs::weather_observe_now = sub { return { ok => 1, condition => 'Snow' } };
	$store{'weather|observe|lock'} = { at => $now - 5 * 60 * 1000 };
	is(subs::weather_observe_tick()->{'skipped'}, 'held', 'the lock holds a second machine');
	delete $store{'weather|observe|lock'};
	is(subs::weather_observe_tick()->{'ok'}, 1, 'the lock expires and the pass runs');
}

# --- the automation tab is wired into the app --------------------------------
my $routes_auto = read_file("$root/lib/JawnOS/Routes/manager_weather.pm");
like($routes_auto, qr{/manager/weather/automations\b}, 'the automation state route exists');
like($routes_auto, qr{/manager/weather/automation\b}, 'the automation save route exists');
like($routes_auto, qr{/manager/weather/observe\b}, 'the observe-now route exists');
my $controller_auto = read_file("$root/lib/JawnOS/Controller/manager_weather.pm");
like($controller_auto, qr/sub action_52015\b/, 'the automation state action exists');
like($controller_auto, qr/sub action_52016\b/, 'the automation save action exists');
like($controller_auto, qr/sub action_52017\b/, 'the observe-now action exists');
like($controller_auto, qr/weather_observe_record/, 'the data route records the condition');

my $page = read_file("$root/templates/apps/weather.html.ep");
like($page, qr/data-tab="automations"/, 'the page has an Automations tab');
like($page, qr{apps/weather/automations}, 'the page includes the Automations panel');
my $auto_partial = read_file("$root/templates/apps/weather/automations.html.ep");
like($auto_partial, qr/id="weather_automation_list"/, 'the panel has a rule list');
like($auto_partial, qr/id="weather_automation_check"/, 'the panel can check now');
my $core_auto = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($core_auto, qr{/js/manager/weather_automation\.js}, 'the lazy app loads the automation script');
like($core_auto, qr{weather\s*=>\s*\[qw\(/js/manager/weather\.js /js/manager/weather_history\.js /js/manager/weather_automation\.js\)\]}, 'the automation script is in the Weather chunk');
my $loader_auto = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader_auto, qr/JawnOS::Domain::WeatherAutomation' for qw\([^)]*weather_observe_record/, 'the domain loader maps the observer');
my $president = read_file("$root/perl/President.pl");
like($president, qr/weather_observe_tick/, 'the utility attaches the weather observer');
my $defaults = read_file("$root/perl/gb/01_state_and_defaults.pl");
like($defaults, qr/'weather_observe'\s*=>\s*\{/, 'the observer has a scheduled slot');

# --- the tab's own style is inside a <style> tag -----------------------------
my $weather_style = read_file("$root/templates/apps/weather/style.html.ep");
like($weather_style, qr/^<style>/m, 'the style partial opens a style element');
like($weather_style, qr{</style>\s*$}m, 'and closes it, so the page does not print CSS');

done_testing();
