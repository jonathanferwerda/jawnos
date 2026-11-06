# tests-for: lib/JawnOS/Domain/Weather.pm lib/JawnOS/Domain/WeatherHistory.pm lib/JawnOS/Domain/WeatherAutomation.pm lib/JawnOS/Controller/manager_weather.pm lib/JawnOS/Routes/manager_weather.pm lib/JawnOS/Manager/Core1_tables_hooks.pm templates/apps/weather.html.ep templates/apps/weather/automations.html.ep templates/apps/weather/map.html.ep public/js/manager/weather.js public/js/manager/weather_history.js public/js/manager/weather_automation.js public/js/manager/weather_map.js public/js/manager/mapengine/01_engine.js
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
use DBI;
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

# --- the fix list reads the real schema --------------------------------------
# weather_device_fixes joined remote_machines on a column the table does not
# have, so every caller's eval saw an empty list and the scheduled observer
# said "no fix" without a word. Run the query against schema.sql itself.
{
	my $sql = read_file("$root/database/schema.sql");
	my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
		{ RaiseError => 1, PrintError => 0 });
	$dbh->do($_) for grep { /\S/ } split /;[ \t]*\n/, $sql;
	$dbh->do("insert into continent (signatorial, type, latitude, longitude, accuracy, server_time) values ('sig-one', 'temporary', '43.45', '-80.49', '5', '1794000000000')");
	$dbh->do("insert into remote_machines (signatorial, hostname) values ('sig-one', 'table')");
	no warnings 'redefine';
	local *subs::db_query = sub {
		my ($query, @bind) = @_;
		my $sth = $dbh->prepare($query);
		$sth->execute(@bind);
		return bless { rows => $sth->fetchall_arrayref({}) }, 'FakeResult';
	};
	local *subs::signatorial_designer = sub { 'me' };
	local *subs::rightNow = sub { 1794000100000 };
	my $fixes = subs::weather_device_fixes(24 * 60 * 60 * 1000);
	is(scalar @{$fixes}, 1, 'a GPS fix joins the machine that sent it');
	is($fixes->[0]{'label'}, 'table', 'the machine name labels the fix');
}

{
	package FakeResult;
	sub hashes { return $_[0]->{'rows'} }
}

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
like($help, qr/map\.html\.ep/, 'the help topic claims the location map');
like($help, qr/Measurement automations/, 'the help topic explains measurement rules');
like($help, qr/1 day \(hourly\)/, 'the help topic explains the hourly day');

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
is(subs::weather_automation_normalize({ uuid => 'rule-place', match => 'rain', app => 'raining', location => 'loc:cottage' })->{'location'}, 'loc:cottage', 'a condition rule can name its place');
is(subs::weather_automation_normalize({ uuid => 'rule-place', match => 'rain', app => 'raining', location => 'browser' })->{'location'}, '', 'a place that is not a device or a saved point is dropped');

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
	local *subs::signatorial_designer = sub { 'sig-one' };
	local *subs::db_query = sub {
		my ($query, @bind) = @_;
		if (($query // '') =~ /from continent/) {
			return bless { rows => [ {
				signatorial => 'sig-one', latitude => '43.45', longitude => '-80.49',
				accuracy => '5', server_time => '' . $now,
			} ] }, 'FakeResult';
		}
		return bless { rows => [] }, 'FakeResult';
	};
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
	local $gb::known_appts = { raining => {}, snowing => {} };

	my $state = subs::weather_automation_state();
	is($state->{'app'}, 'weather_station', 'the rules live on the weather station app');
	is(scalar @{$state->{'rules'}}, 3, 'the old rules are carried over');
	is($state->{'rules'}[0]{'location_label'}, '', 'a rule with no place is not shown as anywhere in particular');
	is($state->{'condition_text'}, 'Cloudy', 'the last condition is shown as words');
	my ($raining_app) = grep { ($_->{'key'} || '') eq 'raining' } @{ $state->{'apps'} || [] };
	ok($raining_app, 'the app field suggests the known apps');
	is($raining_app->{'label'}, 'Raining', 'and shows a formatted name');
	is($state->{'locations'}[0]{'key'}, '', 'the location picker starts with any location');
	is($state->{'locations'}[1]{'label'}, 'This device', 'and offers this device');
	ok($store{'setting|weather_station|app_measures'}, 'the station app gets the rules');
	my $old = Mojo::JSON::decode_json($store{'setting|weather|app_measures'});
	is(scalar @{$old->{'condition'}{'cm'}}, 0, 'the old London app no longer drives automations');

	my $first = subs::weather_observe_record({ current => { condition => 'Light Rain' } }, {});
	is($first->{'ok'}, 1, 'a condition is recorded');
	is($store{'measure'}{'value'}, 'light_rain', 'the condition is handed to the measure writer in its stored key');
	is($first->{'matched'}[0]{'app'}, 'raining', 'the matching rule is reported');

	my $again = subs::weather_observe_record({ current => { condition => 'Light Rain' } }, {});
	is($again->{'skipped'}, 'waiting', 'the same condition is not written again inside the window');

	my $case = subs::weather_observe_record({ current => { condition => 'LIGHT RAIN' } }, {});
	is($case->{'skipped'}, 'waiting', 'a case change is not a new condition');

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

# --- the new helpers ---------------------------------------------------------
my $stamp = subs::weather_stamp_text(1794000104000);
like($stamp, qr{^\d{2}/\d{2}/\d{4} \d{1,2}:\d{2}:\d{2}(am|pm)$}, 'the picker stamp is MM/DD/YYYY h:mm:ssam/pm');
is(subs::weather_stamp_text(undef), '', 'no stamp without a time');
is(subs::weather_pressure_kpa(1012, 'hPa'), 101.2, 'hPa pressure reads as kPa');
is(subs::weather_pressure_kpa(101.2, 'kPa'), 101.2, 'kPa pressure is left alone');

my $measured = subs::weather_measure_values({ current => {
	temperature => 5, condition => 'Light Rain', wind_gust => 25,
	wind_direction => 'NNE', pressure => 1012, pressure_unit => 'hPa',
} });
is($measured->{'temperature'}, 5, 'the observer reads the temperature');
is($measured->{'wind_gust'}, 25, 'the observer reads the gust');
is($measured->{'wind_direction'}, 'nne', 'the observer reads the direction as the stored key');
is($measured->{'pressure'}, 101.2, 'the observer reads pressure in kPa');
is($measured->{'condition'}, 'light_rain', 'the observer reads the condition as the stored key');

my $gust_rule = subs::weather_measure_rule_normalize({
	uuid => 'gust-rule', name => 'Gusty north wind',
	when => [
		{ measure => 'wind_gust', op => '>=', value => 20 },
		{ measure => 'wind_direction', op => 'from', value => 'N' },
	],
	action => 'start', app => 'gusty',
});
is(scalar @{ $gust_rule->{'when'} }, 2, 'a measurement rule keeps both conditions');
is($gust_rule->{'when'}[1]{'value'}, 'n', 'a direction is stored as the compass key');
is($gust_rule->{'for_ms'}, 0, 'no duration means immediately');
is($gust_rule->{'location'}, '', 'a measurement rule with no place applies anywhere');
is(subs::weather_measure_rule_normalize({
	uuid => 'cabin-gust',
	when => [{ measure => 'wind_gust', op => '>', value => 20 }],
	action => 'start', app => 'gusty', location => 'loc:cabin',
})->{'location'}, 'loc:cabin', 'a measurement rule can name its place');

my $long_rule = subs::weather_measure_rule_normalize({
	uuid => 'long-rule',
	when => [{ measure => 'pressure', op => '<', value => 101.2 }],
	for_ms => 6 * 3600000, action => 'run', command => 'echo hi',
});
is($long_rule->{'for_ms'}, 6 * 3600000, 'a six-hour rule keeps its window');
is($long_rule->{'action'}, 'run', 'a rule can run a command');
ok(!subs::weather_measure_rule_normalize({ when => [{ measure => 'pressure', op => '<', value => 101 }], action => 'run' }), 'a run rule needs a command');
ok(!subs::weather_measure_rule_normalize({ when => [], action => 'start', app => 'x' }), 'a rule needs at least one condition');
ok(!subs::weather_measure_rule_normalize({ when => [{ measure => 'nonsense', op => '>', value => 1 }], action => 'start', app => 'x' }), 'an unknown measure is refused');

is(subs::weather_rule_condition_match({ measure => 'wind_gust', op => '>', value => 20 }, { wind_gust => 25 }), 1, 'a gust above the threshold matches');
is(subs::weather_rule_condition_match({ measure => 'wind_gust', op => '>', value => 20 }, { wind_gust => 15 }), 0, 'a gust below it does not');
is(subs::weather_rule_condition_match({ measure => 'wind_direction', op => 'from', value => 'n' }, { wind_direction => 'nne' }), 1, 'a north sector includes NNE');
is(subs::weather_rule_condition_match({ measure => 'wind_direction', op => 'from', value => 'n' }, { wind_direction => 's' }), 0, 'a north sector excludes south');
is(subs::weather_rule_condition_match({ measure => 'condition', op => 'contains', value => 'rain' }, { condition => 'light_rain' }), 1, 'a condition word matches its stored key');

{
	my $now = 1794010000000;
	my $pressure = { measure => 'pressure', op => '<', value => 101.2 };
	my $held = [
		{ ts => $now - 6 * 3600000, values => { pressure => 100 } },
		{ ts => $now - 3 * 3600000, values => { pressure => 101 } },
		{ ts => $now, values => { pressure => 99 } },
	];
	is(subs::weather_rule_held($held, $pressure, 6 * 3600000, $now), 1, 'a rule holds when every reading covers the window');
	$held->[1]{'values'}{'pressure'} = 102;
	is(subs::weather_rule_held($held, $pressure, 6 * 3600000, $now), 0, 'one reading above the line breaks the hold');
	my $short = [
		{ ts => $now - 5 * 3600000, values => { pressure => 100 } },
		{ ts => $now, values => { pressure => 100 } },
	];
	is(subs::weather_rule_held($short, $pressure, 6 * 3600000, $now), 0, 'a window with no reading at its start waits');
}

{
	my $now = 1794010000000;
	my $rows = [
		{ timestamp => $now - 7200000, measures => Mojo::JSON::encode_json([
			{ ts => '' . ($now - 7200000), wind_gust => '25', wind_direction => 'nne' },
			{ ts => '' . ($now - 7200000), pressure => '100' },
		]) },
		{ timestamp => $now, measures => Mojo::JSON::encode_json([
			{ ts => '' . $now, wind_gust => '10', wind_direction => 's' },
		]) },
	];
	no warnings 'redefine';
	local *subs::db_query = sub { return bless { rows => $rows }, 'FakeResult' };
	my $series = subs::weather_observation_series('weather_station', $now - 86400000, $now);
	is(scalar @{$series}, 2, 'the series merges the measures written at one timestamp');
is($series->[0]{'values'}{'wind_gust'}, '25', 'the series keeps the gust');
is($series->[0]{'values'}{'pressure'}, '100', 'the series keeps the pressure');
}

# --- a measurement rule acts on its edge -------------------------------------
{
	my %store;
	my @appointments;
	my @runs;
	my $now = 1794010000000;
	my $rules_json = Mojo::JSON::encode_json([{
		uuid => 'g1', name => 'Gusty north wind',
		when => [
			{ measure => 'wind_gust', op => '>', value => 20 },
			{ measure => 'wind_direction', op => 'from', value => 'n' },
		],
		for_ms => 0, action => 'start', app => 'gusty',
	}]);
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
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $rules_json if $q->{'app'} eq 'weather_station' && $q->{'setting'} eq 'weather_rules';
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		return 1;
	};
	local *Manager::appointment_writer = sub {
		my ($c, $data) = @_;
		push @appointments, $data;
		return $data;
	};
	local *subs::run_command = sub {
		my ($app, $command) = @_;
		push @runs, $command;
		return 1;
	};
	my $values = { wind_gust => 25, wind_direction => 'nne' };
	my $fired = subs::weather_measure_rule_evaluate($values, [], 'appt-1', $now);
	is(scalar @{$fired}, 1, 'a matching measurement rule fires');
	is($fired->[0]{'action'}, 'start', 'and starts an app');
	is($store{'setting|gusty|toggle'}, 'on', 'the target app is switched on');
	my ($start) = grep { ($_->{'type'} // '') eq 'start' } @appointments;
	ok($start, 'a start appointment is written');
	is($start->{'app'}, 'gusty', 'for the target app');
	is(scalar @{ subs::weather_measure_rule_evaluate($values, [], 'appt-1', $now) }, 0, 'a rule acts on its rising edge only');
	my $fall = subs::weather_measure_rule_evaluate({ wind_gust => 10, wind_direction => 'nne' }, [], 'appt-1', $now);
	is($fall->[0]{'action'}, 'stop', 'the falling edge stops the app');
	is($store{'setting|gusty|toggle'}, 'off', 'and switches it off');

	# the same engine can run a command instead
	delete $store{'weather|rules|state'};
	$rules_json = Mojo::JSON::encode_json([{
		uuid => 'r1', name => 'Low pressure',
		when => [{ measure => 'pressure', op => '<', value => 101.2 }],
		for_ms => 0, action => 'run', command => 'echo hi',
	}]);
	my $run = subs::weather_measure_rule_evaluate({ pressure => 100 }, [], 'appt-1', $now);
	is($run->[0]{'action'}, 'run', 'a run rule fires');
	is_deeply(\@runs, ['echo hi'], 'the command is run once');
	is(scalar @{ subs::weather_measure_rule_evaluate({ pressure => 100 }, [], 'appt-1', $now) }, 0, 'and not again while the condition holds');
}

# --- a rule names its own place ----------------------------------------------
is(subs::weather_rule_location_normalize('dev:abc123'), 'dev:abc123', 'a device fix is a location');
is(subs::weather_rule_location_normalize('loc:abc123'), 'loc:abc123', 'a saved place is a location');
is(subs::weather_rule_location_normalize('browser'), '', 'a one-off browser reading is not a rule location');
is(subs::weather_rule_location_normalize('nowhere'), '', 'a bare word is refused');
is(subs::weather_rule_location_normalize(undef), '', 'no location is the old global rule');

{
	my $place_rules = [
		{ uuid => 'r-cottage', match => 'rain', app => 'cottage_raining', action => 'start', location => 'loc:cottage' },
		{ uuid => 'r-cabin', match => 'rain', app => 'cabin_raining', action => 'start', location => 'loc:cabin' },
		{ uuid => 'r-global', match => 'rain', app => 'raining', action => 'start' },
	];
	my $at_cottage = subs::weather_automation_matches($place_rules, 'Light Rain', 'loc:cottage');
	is(scalar @{$at_cottage}, 2, 'the cottage reading wakes its rule and the global one');
	is_deeply([ sort map { $_->{'app'} } @{$at_cottage} ], [qw(cottage_raining raining)], 'and not the cabin rule');
	my $at_cabin = subs::weather_automation_matches($place_rules, 'Light Rain', 'loc:cabin');
	is(scalar @{$at_cabin}, 2, 'the cabin reading wakes its own rule');
	is_deeply([ sort map { $_->{'app'} } @{$at_cabin} ], [qw(cabin_raining raining)], 'and not the cottage rule');
	is(scalar @{ subs::weather_automation_matches($place_rules, 'Light Rain', '') }, 1, 'a reading with no place wakes only the global rule');
}

{
	my $now = 1794010000000;
	my $cm = Mojo::JSON::encode_json({ condition => { type => 'text', cm => [
		{ uuid => 'a', match => 'rain', app => 'raining', location => 'loc:cottage' },
		{ uuid => 'b', match => 'snow', app => 'snowing' },
	] } });
	my $wr = Mojo::JSON::encode_json([
		{ uuid => 'm1', when => [{ measure => 'wind_gust', op => '>', value => 20 }], action => 'start', app => 'gusty', location => 'loc:cabin' },
	]);
	no warnings 'redefine';
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $cm if $q->{'app'} eq 'weather_station' && $q->{'setting'} eq 'app_measures';
		return $wr if $q->{'app'} eq 'weather_station' && $q->{'setting'} eq 'weather_rules';
		return undef;
	};
	local *subs::setting_setter = sub { 1 };
	local *subs::rightNow = sub { $now };
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::db_query = sub {
		return bless { rows => [ {
			signatorial => 'phone', latitude => '43.45', longitude => '-80.49',
			accuracy => '5', server_time => '' . $now, label => 'Phone',
		} ] }, 'FakeResult';
	};
	my $keys = subs::weather_rule_locations();
	is_deeply($keys, ['loc:cottage', 'loc:cabin', 'dev:phone'],
		'the tick covers every rule place, and the newest fix for a rule that applies anywhere');
}

{
	my $now = 1794010000000;
	no warnings 'redefine';
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::rightNow = sub { $now };
	local *subs::db_query = sub {
		return bless { rows => [
			{ signatorial => 'phone', latitude => '43.45', longitude => '-80.49', accuracy => '5', server_time => '' . $now, label => 'Phone' },
			{ signatorial => 'table', latitude => '43.50', longitude => '-80.40', accuracy => '9', server_time => '' . ($now - 1000), label => 'table' },
		] }, 'FakeResult';
	};
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return Mojo::JSON::encode_json([{ uuid => 'cottage', name => 'cottage', lat => 45, lon => -79 }])
			if $q->{'app'} eq 'weather' && $q->{'setting'} eq 'locations';
		return undef;
	};
	my $options = subs::weather_location_options();
	is($options->[0]{'key'}, '', 'any location comes first in the picker');
	is($options->[0]{'label'}, 'Any location', 'and says so');
	is($options->[1]{'key'}, 'dev:phone', 'the current device is offered');
	is($options->[1]{'label'}, 'This device', 'and is called this device');
	is($options->[2]{'key'}, 'dev:table', 'another machine with a fix is offered');
	is($options->[3]{'key'}, 'loc:cottage', 'a saved place is offered');
	is($options->[3]{'label'}, 'Cottage', 'and shown by its name');
}

{
	my %store;
	my @appointments;
	my $now = 1794010000000;
	my $rules_json = Mojo::JSON::encode_json([{
		uuid => 'cabin-gust', name => 'Cabin gust',
		when => [{ measure => 'wind_gust', op => '>', value => 20 }],
		for_ms => 0, action => 'start', app => 'gusty', location => 'loc:cabin',
	}]);
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
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $rules_json if $q->{'app'} eq 'weather_station' && $q->{'setting'} eq 'weather_rules';
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		return 1;
	};
	local *Manager::appointment_writer = sub {
		my ($c, $data) = @_;
		push @appointments, $data;
		return $data;
	};
	my $values = { wind_gust => 25 };
	is(scalar @{ subs::weather_measure_rule_evaluate($values, [], 'appt-1', $now, 'dev:phone') }, 0,
		'the phone reading does not fire the cabin rule');
	is($store{'setting|gusty|toggle'}, undef, 'and the target app stays off');
	my $fired = subs::weather_measure_rule_evaluate($values, [], 'appt-1', $now, 'loc:cabin');
	is(scalar @{$fired}, 1, 'the cabin reading runs it');
	is($store{'setting|gusty|toggle'}, 'on', 'and switches the app on');
}

# --- saved locations ---------------------------------------------------------
{
	my %store;
	no warnings 'redefine';
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		return 1;
	};
	local *subs::random_string_creator = sub { 'locuuid1234' };
	my $saved = subs::weather_location_save('Cottage', 43.45, -80.49);
	is($saved->{'uuid'}, 'locuuid1234', 'a saved location gets a uuid');
	is(subs::weather_location_find('locuuid1234')->{'name'}, 'Cottage', 'and can be found by it');
	my $renamed = subs::weather_location_save('The cottage', 43.45, -80.49);
	is($renamed->{'uuid'}, 'locuuid1234', 'the same ground keeps its uuid');
	is(scalar @{ $renamed->{'locations'} }, 1, 'and is not duplicated');
	is($renamed->{'locations'}[0]{'name'}, 'The cottage', 'the new name wins');
	my $blank = subs::weather_location_save('', 44.0, -80.0);
	like($blank->{'locations'}[1]{'name'}, qr/^44\.0000, -80\.0000$/, 'a nameless point is named by its coordinate');
	ok(!subs::weather_location_save('Nowhere', 200, 10), 'an impossible latitude is refused');
}

# --- the one-day history reads hourly ----------------------------------------
{
	my $now = 1794010000000;
	my $rows = [
		{ timestamp => $now - 7200000, measures => Mojo::JSON::encode_json([{ ts => '' . ($now - 7200000), temperature => '10' }]) },
		{ timestamp => $now - 7200000, measures => Mojo::JSON::encode_json([{ ts => '' . ($now - 7200000), condition => 'light_rain' }]) },
		{ timestamp => $now - 3600000, measures => Mojo::JSON::encode_json([{ ts => '' . ($now - 3600000), temperature => '14' }]) },
	];
	no warnings 'redefine';
	local *subs::rightNow = sub { $now };
	local *subs::db_query = sub { return bless { rows => $rows }, 'FakeResult' };
	my $hours = subs::weather_history_hourly('weather', 24);
	is(scalar @{$hours}, 2, 'the last day folds into one row per hour');
	is($hours->[0]{'temperature'}, 10, 'the first hour averages its readings');
	is($hours->[0]{'condition'}, 'Light rain', 'and keeps the condition its readings named');
	is($hours->[1]{'temperature'}, 14, 'the next hour has its own temperature');

	my $place_rows = [
		{ timestamp => $now - 3600000, measures => Mojo::JSON::encode_json([{ ts => '' . ($now - 3600000), temperature => '10', location => 'dev:phone' }]) },
		{ timestamp => $now - 3600000, measures => Mojo::JSON::encode_json([{ ts => '' . ($now - 3600000), temperature => '2', location => 'loc:cabin' }]) },
		{ timestamp => $now - 7200000, measures => Mojo::JSON::encode_json([{ ts => '' . ($now - 7200000), temperature => '9' }]) },
	];
	$rows = $place_rows;
	my $phone_hours = subs::weather_history_hourly('weather_station', 24, 'dev:phone');
	is(scalar @{$phone_hours}, 2, 'the phone day skips the cabin reading');
	is($phone_hours->[0]{'temperature'}, 9, 'a reading from before places were recorded is kept');
	is($phone_hours->[1]{'temperature'}, 10, 'and the phone hour is its own');
	my $cabin_hours = subs::weather_history_hourly('weather_station', 24, 'loc:cabin');
	is(scalar @{$cabin_hours}, 2, 'the cabin day skips the phone reading');
	is($cabin_hours->[1]{'temperature'}, 2, 'and keeps only its own hour');
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
like($core_auto, qr{weather\s*=>\s*\[qw\(/js/manager/weather\.js /js/manager/weather_history\.js /js/manager/weather_automation\.js /js/manager/weather_map\.js\)\]}, 'the automation and map scripts are in the Weather chunk');
my $loader_auto = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader_auto, qr/JawnOS::Domain::WeatherAutomation' for qw\([^)]*weather_observe_record/, 'the domain loader maps the observer');
my $president = read_file("$root/perl/President.pl");
like($president, qr/weather_observe_tick/, 'the utility attaches the weather observer');
my $defaults = read_file("$root/perl/gb/01_state_and_defaults.pl");
like($defaults, qr/'weather_observe'\s*=>\s*\{/, 'the observer has a scheduled slot');

# --- the location picker and the hourly history are wired --------------------
like($routes_auto, qr{/manager/weather/location\b}, 'the saved-location route exists');
like($routes_auto, qr{/manager/weather/measure_rule\b}, 'the measurement-rule route exists');
like($controller_auto, qr/sub action_52018\b/, 'the saved-location action exists');
like($controller_auto, qr/sub action_52019\b/, 'the measurement-rule action exists');
like($controller_auto, qr/weather_location_save/, 'the page saves a location through the domain');
like($page, qr/id="weather_location_add"/, 'the location dropdown has an Add button');
like($page, qr/weather_stamp_text/, 'the dropdown uses the new date stamp');
like($page, qr{apps/weather/map}, 'the page includes the map view');
my $map_partial = read_file("$root/templates/apps/weather/map.html.ep");
like($map_partial, qr/id="weather_map_canvas"/, 'the map view has a canvas');
like($map_partial, qr/id="weather_map_save" disabled/, 'Save waits for a position');
like($map_partial, qr/id="weather_map_cancel"/, 'the map can be cancelled');
my $map_js = read_file("$root/public/js/manager/weather_map.js");
like($map_js, qr{/manager/travel/continent}, 'the picker uses the Travel map data');
like($map_js, qr{/manager/weather/location}, 'the picker saves the location');
like($map_js, qr/weatherPickerFlag/, 'the picker draws a flag');
my $engine_js = read_file("$root/public/js/manager/mapengine/01_engine.js");
like($engine_js, qr/project:\s*function/, 'the map engine can project the flag position');
like($core_auto, qr{/js/manager/weather_map\.js}, 'the lazy app loads the map script');

my $history_partial = read_file("$root/templates/apps/weather/history.html.ep");
like($history_partial, qr/<option value="1"/, 'the history range has a one-day option');
my $history_js = read_file("$root/public/js/manager/weather_history.js");
like($history_js, qr/weatherHistoryHourChart/, 'the history draws an hourly chart');
like($history_js, qr/weatherHistoryHourTable/, 'the history lists hourly readings');
like($loader_auto, qr/weather_history_hourly/, 'the domain loader maps the hourly reader');
like($loader_auto, qr/weather_location_save/, 'the domain loader maps the location writer');
like($loader_auto, qr/weather_measure_rule_save/, 'the domain loader maps the measurement rule writer');

like($auto_partial, qr/id="weather_measure_list"/, 'the Automations tab lists measurement rules');
like($auto_partial, qr/id="weather_measure_form"/, 'the Automations tab has a measurement form');
like($auto_partial, qr/id="weather_measure_condition_add"/, 'a rule can hold more than one condition');
like($auto_partial, qr/id="weather_measure_command"/, 'a rule can run a command');

# --- a rule can be scoped to a place, and the app field suggests apps -------
like($auto_partial, qr/id="weather_automation_location"/, 'the condition form picks the place a rule is about');
like($auto_partial, qr/id="weather_measure_location"/, 'the measurement form picks the place too');
like($auto_partial, qr/id="weather_automation_app" list="weather_app_options"/, 'the app field suggests existing apps');
like($auto_partial, qr/id="weather_measure_app" list="weather_app_options"/, 'and so does the measurement form');
like($auto_partial, qr/<datalist id="weather_app_options"><\/datalist>/, 'the suggestions have a datalist');
my $auto_js = read_file("$root/public/js/manager/weather_automation.js");
like($auto_js, qr/weatherAutomationLocations/, 'the script fills the place pickers');
like($auto_js, qr/data\.apps/, 'and the app suggestions');
like($auto_js, qr/location_label/, 'a saved rule shows its place in the sentence');
like($loader_auto, qr/weather_rule_location_normalize/, 'the domain loader maps the place normaliser');
like($loader_auto, qr/weather_rule_locations/, 'and the places the tick covers');

# --- the tab's own style is inside a <style> tag -----------------------------
my $weather_style = read_file("$root/templates/apps/weather/style.html.ep");
like($weather_style, qr/^<style>/m, 'the style partial opens a style element');
like($weather_style, qr{</style>\s*$}m, 'and closes it, so the page does not print CSS');

done_testing();
