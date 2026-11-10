# tests-for: lib/JawnOS/Domain/Weather.pm lib/JawnOS/Domain/WeatherHistory.pm lib/JawnOS/Domain/WeatherAutomation.pm lib/JawnOS/Controller/manager_weather.pm lib/JawnOS/Routes/manager_weather.pm lib/JawnOS/Manager/Core1_tables_hooks.pm lib/JawnOS/Manager/Part15.pm templates/apps/weather.html.ep templates/apps/weather/automations.html.ep templates/apps/weather/map.html.ep public/js/manager/weather.js public/js/manager/weather_history.js public/js/manager/weather_automation.js public/js/manager/weather_map.js public/js/manager/mapengine/01_engine.js perl/utility_jobs.pl
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
require "$root/lib/JawnOS/Manager/Part15.pm";

# The domain layer reads its user-facing labels through subs::ui, which the real
# manager answers from language.pl. This test only needs the English it passes in.
no warnings 'redefine';
*subs::ui = sub { return defined $_[0] ? "$_[0]" : ''; };

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
	my ($foggy_app) = grep { ($_->{'key'} || '') eq 'foggy' } @{ $state->{'apps'} || [] };
	ok($foggy_app, 'an app named by a rule is suggested even when it is not in the catalog');
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
	local *subs::weather_locations = sub { [ { uuid => 'warwick', name => 'Warwick', lat => 43.0023, lon => -81.9419, anchor => 1 } ] };
	$store{'weather|observe|lock'} = { at => $now - 5 * 60 * 1000 };
	is(subs::weather_observe_tick()->{'skipped'}, 'held', 'the lock holds a second machine');
	delete $store{'weather|observe|lock'};
	is(subs::weather_observe_tick()->{'ok'}, 1, 'the lock expires and the pass runs');
}

# --- one actor for the house, however many screens record a reading ----------
{
	my %store;
	my $now = 1794020000000;
	my @written;
	my @evaluated;
	no warnings 'redefine';
	local *subs::rightNow = sub { $now };
	local *subs::weather_observe_leader = sub { 0 };
	local *subs::weather_observe_prepare = sub {
		return { condition => { type => 'text', value => 'rain', cm => [
			{ uuid => 'r1', match => 'rain', app => 'raining', action => 'start' },
		] } };
	};
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return Mojo::JSON::encode_json([{ uuid => 'm1', when => [{ measure => 'wind_gust', op => '>', value => 20 }], for_ms => 0, action => 'start', app => 'gusty' }])
			if $q->{'app'} eq 'weather_station' && $q->{'setting'} eq 'weather_rules';
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		return 1;
	};
	local *subs::cache_get = sub { {} };
	local *subs::cache_set = sub { 1 };
	local *subs::db_query = sub { bless { rows => [] }, 'FakeResult' };
	local *subs::db_select = sub { bless { rows => [] }, 'FakeResult' };
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $store{'setting|weather|locations'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/ && $store{'setting|weather|locations'};
		return bless { rows => [] }, 'FakeResult';
	};
	local *subs::controller_builder = sub { bless {}, 'FakeController' };
	local *Manager::appt_measure_writer = sub {
		my ($c, $data) = @_;
		push @written, $data;
		return 'measure-uuid';
	};
	local *subs::weather_measure_rule_evaluate = sub {
		my (@args) = @_;
		push @evaluated, \@args;
		return [];
	};
	my $result = subs::weather_observe_record({ current => { condition => 'Rain' } }, { force => 1, location => 'dev:phone' });
	is($result->{'ok'}, 1, 'a machine that is not the house server still records the reading');
	is($result->{'leader'}, 0, 'and says the house server is the actor');
	ok((grep { $_->{'skip_actions'} } @written), 'the measure writer is told not to run the rules there');
	is(scalar @evaluated, 0, 'and the measurement rules are not evaluated there');
}

{
	my %store;
	my $now = 1794020000000;
	my @written;
	my @evaluated;
	no warnings 'redefine';
	local *subs::rightNow = sub { $now };
	local *subs::weather_observe_leader = sub { 1 };
	local *subs::weather_observe_prepare = sub {
		return { condition => { type => 'text', value => 'rain', cm => [
			{ uuid => 'r1', match => 'rain', app => 'raining', action => 'start' },
		] } };
	};
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return Mojo::JSON::encode_json([{ uuid => 'm1', when => [{ measure => 'wind_gust', op => '>', value => 20 }], for_ms => 0, action => 'start', app => 'gusty' }])
			if $q->{'app'} eq 'weather_station' && $q->{'setting'} eq 'weather_rules';
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		return 1;
	};
	local *subs::cache_get = sub { {} };
	local *subs::cache_set = sub { 1 };
	local *subs::db_query = sub { bless { rows => [] }, 'FakeResult' };
	local *subs::db_select = sub { bless { rows => [ { warranty => '2109000000000' } ] }, 'FakeResult' };
	local *subs::controller_builder = sub { bless {}, 'FakeController' };
	local *Manager::appt_measure_writer = sub {
		my ($c, $data) = @_;
		push @written, $data;
		return 'measure-uuid';
	};
	local *subs::weather_measure_rule_evaluate = sub {
		my (@args) = @_;
		push @evaluated, \@args;
		return [];
	};
	my $result = subs::weather_observe_record({ current => { condition => 'Rain' } }, { force => 1, location => 'dev:phone' });
	is($result->{'leader'}, 1, 'the house server is the actor');
	ok(!(grep { $_->{'skip_actions'} } @written), 'so the measure writer runs the rules');
	is(scalar @evaluated, 1, 'and the measurement rules are evaluated');
	is($evaluated[0][5], '2109000000000', 'with the reading warranty to give the app it starts');
}

# --- one start for the house, and it carries the reading's warranty ----------
{
	my %store;
	my @appointments;
	my $now = 1794020000000;
	no warnings 'redefine';
	local *subs::rightNow = sub { $now };
	local *subs::setting_grabber = sub {
		my ($q) = @_;
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
	local *subs::open_session_uuid = sub { '' };
	is(subs::weather_rule_app_switch('raining', 1, 'appt-1', $now, '2109000000000'), 1, 'a measurement rule starts its app');
	is($store{'setting|raining|toggle'}, 'on', 'and switches it on');
	is($appointments[0]{'warranty'}, '2109000000000', 'the start carries the reading warranty');

	$store{'setting|raining|toggle'} = 'off';
	@appointments = ();
	local *subs::open_session_uuid = sub { 'open-uuid' };
	is(subs::weather_rule_app_switch('raining', 1, 'appt-2', $now, ''), 1, 'a second reading reports the app as on');
	is($store{'setting|raining|toggle'}, 'on', 'and repairs the toggle');
	is(scalar @appointments, 0, 'but does not write a second start');
}

{
	my %store = ( 'setting|raining|toggle' => 'off' );
	my @appointments;
	my $now = 1794020000000;
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
	local *Manager::appointment_writer = sub {
		my ($c, $data) = @_;
		push @appointments, $data;
		return $data;
	};
	local *subs::open_session_uuid = sub { '' };
	my $rule = { type => 'match', match => 'rain', app => 'raining', action => 'start' };
	Manager::appt_measure_action({
		appt_uuid => 'appt-1', appt_measure => { cm => [ $rule ] },
		value => 'light_rain', 'state' => 'light_rain', measure => 'condition',
		timestamp => $now, location => 'dev:phone', warranty => '2109000000000',
	});
	is($store{'setting|raining|toggle'}, 'on', 'a matching condition starts its app');
	is($appointments[0]{'warranty'}, '2109000000000', 'and the appointment carries the reading warranty');

	@appointments = ();
	$store{'setting|raining|toggle'} = 'off';
	local *subs::open_session_uuid = sub { 'open-uuid' };
	Manager::appt_measure_action({
		appt_uuid => 'appt-2', appt_measure => { cm => [ $rule ] },
		value => 'light_rain', 'state' => 'light_rain', measure => 'condition',
		timestamp => $now, location => 'dev:phone', warranty => '2109000000000',
	});
	is(scalar @appointments, 0, 'an app that is already running is not started again');
	is($store{'setting|raining|toggle'}, 'on', 'the toggle follows the running app');
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

# --- the tab is scoped to the picker's place ----------------------------------
{
	my $now = 1794010000000;
	no warnings 'redefine';
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::rightNow = sub { $now };
	local *subs::weather_device_fix = sub {
		return $_[0] eq 'phone' ? { lat => 43.0023, lon => -81.9419 } : undef;
	};
	local *subs::weather_locations = sub {
		return [
			{ uuid => 'warwick', name => 'Warwick', lat => 43.0023, lon => -81.9419, anchor => 1 },
			{ uuid => 'cottage', name => 'Cottage', lat => 45, lon => -79, anchor => 0 },
			{ uuid => 'cabin', name => 'Cabin', lat => 45.5, lon => -79.5, anchor => 0 },
		];
	};
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return Mojo::JSON::encode_json({ condition => { type => 'text', cm => [
			{ uuid => 'r', match => 'rain', app => 'raining', location => 'loc:cottage' },
		] } }) if $q->{'app'} eq 'weather_station' && $q->{'setting'} eq 'app_measures';
		return '[]' if $q->{'app'} eq 'weather_station' && $q->{'setting'} eq 'weather_rules';
		return undef;
	};
	is(subs::weather_automation_view_location({ device => 'me' }), 'loc:warwick',
		'a machine at the anchored home views the home place');
	is(subs::weather_automation_view_location({ device => 'loc:cottage' }), 'loc:cottage',
		'a saved place views itself');
	is(subs::weather_automation_view_location({ device => 'me', lat => 45, lon => -79 }), 'loc:cottage',
		'a machine at an unanchored place a rule names views that place');
	is(subs::weather_automation_view_location({ device => 'me', lat => 45.5, lon => -79.5 }), 'dev:phone',
		'a machine at a place no rule names keeps its own key');
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
		return '[]' if $q->{'setting'} eq 'seen_measures';
		return undef;
	};
	local *subs::setting_setter = sub { 1 };
	local *subs::rightNow = sub { $now };
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::cache_get = sub { {} };
	local *subs::weather_device_fixes = sub { [] };
	local *subs::weather_locations = sub { [] };
	local $gb::known_appts = {};

	my $all = subs::weather_automation_state();
	is(scalar @{ $all->{'rules'} }, 2, 'without a place the tab still lists every rule');
	is($all->{'view_location'}, '', 'and names no view');

	my $cottage = subs::weather_automation_state({ location => 'loc:cottage' });
	is($cottage->{'view_location'}, 'loc:cottage', 'the view names the chosen place');
	is_deeply([ map { $_->{'uuid'} } @{ $cottage->{'rules'} } ], [qw(a b)],
		'and shows the cottage rule beside the one for any location');
	is(scalar @{ $cottage->{'measure_rules'} }, 0, 'another place\'s measurement rule stays off this tab');

	my $cabin = subs::weather_automation_state({ location => 'loc:cabin' });
	is_deeply([ map { $_->{'uuid'} } @{ $cabin->{'rules'} } ], [qw(b)],
		'the cabin tab shows only the rule for any location');
	is_deeply([ map { $_->{'uuid'} } @{ $cabin->{'measure_rules'} } ], [qw(m1)],
		'and its own measurement rule');
}

# --- the place-less rules become the home's rules -----------------------------
{
	my $now = 1794010000000;
	my %store = (
		'app_measures' => Mojo::JSON::encode_json({ condition => { type => 'text', cm => [
			{ uuid => 'r1', match => 'rain', app => 'raining', action => 'start' },
			{ uuid => 'r2', match => 'snow', app => 'snowing', action => 'start', location => 'loc:cabin' },
		] } }),
		'weather_rules' => Mojo::JSON::encode_json([
			{ uuid => 'm1', when => [{ measure => 'wind_gust', op => '>', value => 20 }], action => 'start', app => 'gusty' },
		]),
	);
	no warnings 'redefine';
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::rightNow = sub { $now };
	local *subs::weather_home_place = sub { { uuid => 'warwick', name => 'Warwick' } };
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $store{ $q->{'setting'} } if $q->{'app'} eq 'weather_station';
		return undef;
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ $q->{'setting'} } = $q->{'value'};
		return 1;
	};

	ok(subs::weather_automation_adopt_home(), 'the home place is adopted');
	my $am = Mojo::JSON::decode_json($store{'app_measures'});
	my ($placed) = grep { $_->{'uuid'} eq 'r2' } @{ $am->{'condition'}{'cm'} };
	my ($adopted) = grep { $_->{'uuid'} eq 'r1' } @{ $am->{'condition'}{'cm'} };
	is($adopted->{'location'}, 'loc:warwick', 'a place-less condition rule moves to the home place');
	is($placed->{'location'}, 'loc:cabin', 'a rule that already names a place is left alone');
	my $wr = Mojo::JSON::decode_json($store{'weather_rules'});
	is($wr->[0]{'location'}, 'loc:warwick', 'a place-less measurement rule moves too');

	my %before = %store;
	ok(subs::weather_automation_adopt_home(), 'a second pass is still a pass');
	is($store{'app_measures'}, $before{'app_measures'}, 'and writes nothing new');

	local *subs::weather_home_place = sub { undef };
	is(subs::weather_automation_adopt_home(), 0, 'a house with no home place waits for the next pass');
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
	is_deeply($keys, ['loc:cottage', 'loc:cabin'],
		'the tick covers every rule place, and does not follow a fix that applies anywhere');
}

{
	my $now = 1794010000000;
	no warnings 'redefine';
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::rightNow = sub { $now };
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => Mojo::JSON::encode_json([{ uuid => 'cottage', name => 'cottage', lat => 45, lon => -79 }]) } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/;
		return bless { rows => [
			{ signatorial => 'phone', latitude => '43.45', longitude => '-80.49', accuracy => '5', server_time => '' . $now, label => 'Phone' },
			{ signatorial => 'table', latitude => '43.50', longitude => '-80.40', accuracy => '9', server_time => '' . ($now - 1000), label => 'table' },
		] }, 'FakeResult';
	};
	local *subs::setting_grabber = sub {
		my ($q) = @_;
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
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $store{'setting|weather|locations'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/ && $store{'setting|weather|locations'};
		return bless { rows => [] }, 'FakeResult';
	};
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

# --- deleting a saved place --------------------------------------------------
{
	my %store;
	my $n = 0;
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
	local *subs::random_string_creator = sub { 'locuuid' . (++$n) };
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $store{'setting|weather|locations'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/ && $store{'setting|weather|locations'};
		return bless { rows => [] }, 'FakeResult';
	};
	subs::weather_location_save('Cottage', 45, -79);
	subs::weather_location_save('Camp', 46, -80);
	my $deleted = subs::weather_location_delete('locuuid1');
	ok($deleted, 'a saved place can be deleted');
	is(scalar @{ $deleted->{'locations'} }, 1, 'the list keeps the other place');
	is($deleted->{'locations'}[0]{'name'}, 'Camp', 'and it is the one not deleted');
	ok(!subs::weather_location_delete('locuuid1'), 'deleting it again is refused');
	ok(!subs::weather_location_delete('nonsense!'), 'an impossible uuid is refused');
}

# --- one weather pass per household ------------------------------------------
{
	no warnings 'redefine';
	my $now = 1794020000000;
	my $me = 'me123';
	my @rows;
	local *subs::rightNow = sub { $now };
	local *subs::signatorial_designer = sub { $me };
	local *subs::db_query = sub {
		my ($query) = @_;
		return bless { rows => \@rows }, 'FakeResult'
			if ($query // '') =~ /from remote_machines/;
		return bless { rows => [] }, 'FakeResult';
	};
	@rows = (
		{ signatorial => 'server1', device => 'server', connection => 'active', server_time => $now - 60000 },
	);
	is(subs::weather_observe_leader(), 0, 'a live house server leads');
	$me = 'server1';
	is(subs::weather_observe_leader(), 1, 'the house server runs the pass');

	# The server has gone quiet: the live machines elect the lowest signatorial.
	@rows = (
		{ signatorial => 'server1', device => 'server', connection => 'inactive', server_time => $now - 3600000 },
		{ signatorial => 'aaa', device => 'computer', connection => 'active', server_time => $now - 60000 },
		{ signatorial => 'zzz', device => 'phone', connection => 'active', server_time => $now - 60000 },
	);
	$me = 'zzz';
	is(subs::weather_observe_leader(), 0, 'the stand-in is the lowest live machine, not every machine');
	$me = 'aaa';
	is(subs::weather_observe_leader(), 1, 'and that machine takes the pass while the server is away');
	$me = 'me123';
	is(subs::weather_observe_leader(), 0, 'a machine outside the election stays a reader');

	@rows = ();
	is(subs::weather_observe_leader(), 1, 'a household with no server row still checks');

	@rows = (
		{ signatorial => 'server1', device => 'server', connection => 'inactive', server_time => $now - 3600000 },
	);
	is(subs::weather_observe_leader(), 1, 'a lone live machine takes the pass while the server is away');
}

# --- the house server leads even though its roster omits itself --------------
{
	no warnings 'redefine';
	local *subs::device_setter = sub { 'server' };
	local *subs::signatorial_designer = sub { 'hub' };
	local *subs::rightNow = sub { 1794020000000 };
	local *subs::db_query = sub {
		return bless { rows => [
			{ signatorial => 'phone', device => 'mobile', connection => 'active', server_time => 1794020000000 },
		] }, 'FakeResult';
	};
	is(subs::weather_observe_leader(), 1, 'the house server leads its own house');
}

# --- the whole house is back together ----------------------------------------
{
	no warnings 'redefine';
	my $now = 1794020000000;
	my @rows;
	local *subs::rightNow = sub { $now };
	local *subs::db_query = sub {
		my ($query) = @_;
		return bless { rows => \@rows }, 'FakeResult'
			if ($query // '') =~ /from remote_machines/;
		return bless { rows => [] }, 'FakeResult';
	};
	@rows = (
		{ signatorial => 'hub', device => 'server', connection => 'active', server_time => $now - 60000 },
		{ signatorial => 'phone', device => 'mobile', connection => 'active', server_time => $now - 60000 },
	);
	is(subs::weather_observe_house_together(), 1, 'every machine is connected and heard from');
	$rows[1]->{'connection'} = 'inactive';
	is(subs::weather_observe_house_together(), 0, 'one machine away means the house is still apart');
	$rows[1]->{'connection'} = 'active';
	$rows[1]->{'server_time'} = $now - 3600000;
	is(subs::weather_observe_house_together(), 0, 'a machine that has gone quiet is not together either');
	@rows = ();
	is(subs::weather_observe_house_together(), 1, 'a single machine is its own whole house');
}

# --- duplicates fold when the house is together ------------------------------
{
	no warnings 'redefine';
	my $now = 1794020000000;
	my $reading = sub {
		my ($temp, $time, $place) = @_;
		return Mojo::JSON::encode_json([
			{ condition => 'cloudy', temperature => $temp, location => ($place || 'dev:phone'), ts => '' . $time, uuid => 'm' . $time },
		]);
	};
	my @rows;
	my @folded;
	local *subs::rightNow = sub { $now };
	local *subs::db_query = sub {
		my ($query) = @_;
		return bless { rows => \@rows }, 'FakeResult' if ($query // '') =~ /from appointments/;
		return bless { rows => [] }, 'FakeResult';
	};
	local *subs::records_tombstone = sub {
		my ($app, $uuid) = @_;
		push @folded, $uuid;
		return 1;
	};
	local *subs::cache_set = sub { 1 };
	@rows = (
		{ uuid => 'keep', timestamp => $now - 120000, device => 'Laptop', measures => $reading->('7.1', $now - 120000) },
		{ uuid => 'dup', timestamp => $now - 60000, device => 'Phone', measures => $reading->('7.1', $now - 60000) },
		{ uuid => 'changed', timestamp => $now - 30000, device => 'Phone', measures => $reading->('7.2', $now - 30000) },
		{ uuid => 'back', timestamp => $now, device => 'Phone', measures => $reading->('7.1', $now) },
		{ uuid => 'cabin', timestamp => $now - 60000, device => 'Phone', measures => $reading->('7.1', $now - 60000, 'loc:cabin') },
	);
	my $out = subs::weather_observe_reconcile({ days => 1 });
	is($out->{'removed'}, 1, 'one duplicate reading is folded');
	is_deeply(\@folded, ['dup'], 'and it is the later copy of the same reading');
	is($out->{'checked'}, 5, 'every reading was considered');
	ok(!grep { $_ eq 'back' } @folded, 'the value that returned is kept');
	ok(!grep { $_ eq 'changed' } @folded, 'the changed value is kept');
	ok(!grep { $_ eq 'cabin' } @folded, 'the same reading at another place is kept');

	# The house server's copy is the one the rules saw; keep it in the run.
	@rows = (
		{ uuid => 'early', timestamp => $now - 120000, device => 'Laptop', measures => $reading->('9.0', $now - 120000) },
		{ uuid => 'house', timestamp => $now - 60000, device => 'server', measures => $reading->('9.0', $now - 60000) },
	);
	@folded = ();
	$out = subs::weather_observe_reconcile({ days => 1 });
	is_deeply(\@folded, ['early'], 'the house server copy is kept when the run has one');
}

{
	no warnings 'redefine';
	local *subs::weather_observe_leader = sub { 0 };
	is(subs::weather_observe_tick()->{'skipped'}, 'not the house', 'only the house holds the hourly pass');
	local *subs::weather_observe_leader = sub { 1 };
	local *subs::rightNow = sub { 1794010000000 };
	local *subs::weather_observe_prepare = sub { {} };
	local *subs::weather_rule_locations = sub { [] };
	local *subs::weather_device_fixes = sub { [ { signatorial => 'phone', lat => 1, lon => 2, seen => 1 } ] };
	local *subs::weather_device_fix = sub { { lat => 1, lon => 2 } };
	local *subs::weather_observe_now = sub { my ($o) = @_; return { ok => 1 } };
	local *subs::cache_get = sub { {} };
	local *subs::cache_set = sub { 1 };
	my $tick = subs::weather_observe_tick();
	is($tick->{'skipped'}, 'no fix', 'the pass does not follow the newest fix when no place is a station');
}

# --- a place reads as a name, and machines at one place are one entry --------
is(subs::weather_name_is_coordinate('Location 46.2260, -63.0998'), 1, 'the map\'s coordinate fill is not a name');
is(subs::weather_name_is_coordinate('46.2260, -63.0998'), 1, 'a bare coordinate is not a name');
is(subs::weather_name_is_coordinate('Cottage'), 0, 'a real name is a name');
is(subs::weather_name_is_coordinate(''), 0, 'an empty name is not a coordinate either');

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
	is(subs::weather_place_name(43.45, -80.49), '', 'a place has no name until one is learned');
	is(subs::weather_place_name_remember(43.45, -80.49, ' Kitchener '), 1, 'the provider name is remembered');
	is(subs::weather_place_name(43.451, -80.492), 'Kitchener', 'a coordinate near it shares the name');
	is(subs::weather_place_name_remember(43.45, -80.49, 'Location 43.4500, -80.4900'), 0, 'a coordinate is never stored as a name');
}

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
	local *subs::weather_provider_for = sub { 'openmeteo' };
	local *subs::rightNow = sub { 1000000 };
	local *subs::weather_reverse_geocode = sub { '' };
	is(subs::weather_place_lookup(38.74, 0.22), '', 'a place the geocoder cannot name stays empty');
	is_deeply([ sort keys %{ subs::weather_place_misses() } ], ['38.74,0.22'], 'and the miss is remembered for that place');
	is(subs::weather_place_lookup(38.74, 0.22), '', 'so the same place is not asked again');
	local *subs::weather_reverse_geocode = sub { 'Jávea' };
	is(subs::weather_place_lookup(46.23, -63.10), 'Jávea', 'another place is still tried and named by the geocoder');
	is(subs::weather_place_name(46.23, -63.10), 'Jávea', 'and the name is kept');
}

{
	no warnings 'redefine';
	local *subs::setting_grabber = sub { return undef };
	is(subs::weather_provider_for(46.226, -63.0998), 'ec', 'a Canadian coordinate reads its provider without an override');
}

{
	no warnings 'redefine';
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::setting_grabber = sub { return undef };
	my $groups = subs::weather_place_groups([
		{ signatorial => 'phone', label => 'Phone', lat => 43.4500, lon => -80.4900, seen => 100 },
		{ signatorial => 'laptop', label => 'Laptop', lat => 43.4502, lon => -80.4901, seen => 90 },
		{ signatorial => 'cabin', label => 'Cabin phone', lat => 45.0000, lon => -79.0000, seen => 80 },
	]);
	is(scalar @{$groups}, 2, 'machines at one place are one entry');
	is($groups->[0]{'signatorial'}, 'phone', 'this device keys its group');
	ok($groups->[0]{'me'}, 'and the group knows it is this device');
	is($groups->[0]{'label'}, 'This device', 'with no name it reads as this device');
	is($groups->[0]{'devices_text'}, 'This device, Laptop', 'the tooltip lists the machines in it');
	is($groups->[0]{'seen'}, 100, 'the group keeps the newest fix');
	is($groups->[1]{'signatorial'}, 'cabin', 'a machine elsewhere is its own entry');
}

{
	no warnings 'redefine';
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::setting_grabber = sub { return undef };
	my $groups = subs::weather_place_groups([
		{ signatorial => 'phone', label => 'Phone', lat => 43.4500, lon => -80.4900, seen => 100 },
		{ signatorial => 'laptop', label => 'Laptop', lat => 43.4860, lon => -80.4900, seen => 90 },
		{ signatorial => 'cabin', label => 'Cabin', lat => 43.4500, lon => -80.4000, seen => 80 },
	]);
	is(scalar @{$groups}, 2, 'a machine within five kilometres shares the place');
	is($groups->[0]{'devices_text'}, 'This device, Laptop', 'and is one entry, not two');
	is($groups->[1]{'signatorial'}, 'cabin', 'a machine seven kilometres away is its own place');
}

# --- fourteen days and a reverse geocoder ------------------------------------
{
	my @week = map { { date => sprintf('2026-11-%02d', $_), high => $_ } } (1 .. 7);
	my @fortnight = map { { date => sprintf('2026-11-%02d', $_), high => 100 + $_ } } (1 .. 14);
	my $merged = subs::weather_daily_extend(\@week, \@fortnight);
	is(scalar @{$merged}, 14, 'the week is filled out to a fortnight');
	is($merged->[0]{'high'}, 1, 'a national day is kept');
	is($merged->[7]{'high'}, 108, 'the eighth day comes from the fallback');
	ok($merged->[7]{'extended'}, 'and is marked as extended');
	is(scalar @{ subs::weather_daily_extend(\@fortnight, \@week) }, 14, 'a full fortnight is not duplicated');
}

{
	no warnings 'redefine';
	local *subs::weather_http_get = sub {
		my ($url) = @_;
		return ({ city => 'Jávea', locality => 'Xàbia', principalSubdivision => 'Valencia' }, undef)
			if $url =~ /latitude=38\.74/;
		return ({ city => '', locality => 'Somewhere' }, undef);
	};
	is(subs::weather_reverse_geocode(38.74, 0.22), 'Jávea', 'a coordinate outside the national services is named');
	is(subs::weather_reverse_geocode(10, 10), 'Somewhere', 'the locality is the fallback when there is no city');
	local *subs::weather_http_get = sub { return ({}, undef) };
	is(subs::weather_reverse_geocode(10, 10), '', 'an answer with no name is no name');
}

{
	no warnings 'redefine';
	local *subs::signatorial_designer = sub { 'phone' };
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return Mojo::JSON::encode_json({ '43.45,-80.49' => 'Kitchener' }) if $q->{'setting'} eq 'place_names';
		return undef;
	};
	my $groups = subs::weather_place_groups([
		{ signatorial => 'phone', label => 'Phone', lat => 43.4500, lon => -80.4900, seen => 100 },
	]);
	is($groups->[0]{'label'}, 'Kitchener', 'a learned place shows its name instead of the device');
}

{
	my $locs = Mojo::JSON::encode_json([
		{ uuid => 'a', name => 'Cottage', lat => 45, lon => -79 },
		{ uuid => 'b', name => '46.2260, -63.0998', lat => 46.226, lon => -63.0998 },
		{ uuid => 'c', name => 'Location 44.0000, -80.0000', lat => 44, lon => -80 },
	]);
	no warnings 'redefine';
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $locs if $q->{'app'} eq 'weather' && $q->{'setting'} eq 'locations';
		return Mojo::JSON::encode_json({ '46.23,-63.10' => 'Charlottetown' }) if $q->{'setting'} eq 'place_names';
		return undef;
	};
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $locs } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/;
		return bless { rows => [] }, 'FakeResult';
	};
	my $labels = subs::weather_location_labels();
	is($labels->{'a'}, 'Cottage', 'a place the person named keeps that name');
	is($labels->{'b'}, 'Charlottetown', 'a coordinate name reads as the provider place');
	is($labels->{'c'}, 'Saved location 1', 'a nameless place is numbered, never a coordinate');
}

# --- recording a place names it, and renames a saved coordinate --------------
{
	my %store;
	my %cache;
	my $now = 1794010000000;
	$store{'setting|weather|locations'} = Mojo::JSON::encode_json([
		{ uuid => 'abc', name => '43.4500, -80.4900', lat => 43.45, lon => -80.49 },
	]);
	no warnings 'redefine';
	local *subs::rightNow = sub { $now };
	local *subs::random_string_creator = sub { 'newrule' };
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $store{'setting|weather|locations'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/ && $store{'setting|weather|locations'};
		return bless { rows => [] }, 'FakeResult';
	};
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		return 1;
	};
	local *subs::cache_get = sub {
		my ($q) = @_;
		return $cache{ join('|', $q->{'app'}, $q->{'context'}, $q->{'subcontext'} // '') };
	};
	local *subs::cache_set = sub {
		my ($q, $value) = @_;
		$cache{ join('|', $q->{'app'}, $q->{'context'}, $q->{'subcontext'} // '') } = $value;
		return 1;
	};
	local *subs::controller_builder = sub { return bless {}, 'FakeController' };
	local *subs::weather_observe_leader = sub { 1 };
	local *Manager::appt_measure_writer = sub { return 'measure-uuid' };
	my $result = subs::weather_observe_record({
		current => { condition => 'Rain' },
		location_name => 'Kitchener',
		lat => 43.45, lon => -80.49,
	}, { location => 'loc:abc' });
	is($result->{'ok'}, 1, 'the observation is recorded');
	my $names = Mojo::JSON::decode_json($store{'setting|weather|place_names'} // '{}');
	is($names->{'43.45,-80.49'}, 'Kitchener', 'the reading names its place');
	my $locs = Mojo::JSON::decode_json($store{'setting|weather|locations'});
	is($locs->[0]{'name'}, 'Kitchener', 'and a coordinate-named saved place takes the name');
	is($locs->[0]{'uuid'}, 'abc', 'keeping its uuid');
}

# --- a fix becomes a place you can anchor or delete --------------------------
{
	my %store;
	no warnings 'redefine';
	local *subs::rightNow = sub { 1794020000000 };
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		return 1;
	};
	local *subs::random_string_creator = sub { 'fallbackplace' };
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $store{'setting|weather|locations'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/ && $store{'setting|weather|locations'};
		return bless { rows => [] }, 'FakeResult';
	};
	my $place = subs::weather_location_for_fix(43.0023, -81.9419, 'Lambton Shores', { create => 1, seen => 1794020000000 });
	ok($place, 'a fix becomes a place');
	is($place->{'name'}, 'Lambton Shores', 'named by the provider');
	is($place->{'auto'}, 1, 'marked automatic');
	is($place->{'anchor'}, 0, 'and not anchored');
	is(subs::weather_place_match_km(), 30, 'a saved place is matched within thirty kilometres');
	my $near_km = subs::weather_saved_place_km(43.2023, -81.9419);
	ok(defined $near_km && $near_km > 20 && $near_km < 25, 'a nearby fix measures its distance to the saved place');
	my $again = subs::weather_location_for_fix(43.0030, -81.9425, 'Lambton Shores', { create => 1 });
	is($again->{'uuid'}, $place->{'uuid'}, 'the same ground keeps one place');
	my $saved = subs::weather_location_save('Warwick', 43.0024, -81.9418, { anchor => 1, auto => 0 });
	my $warwick = subs::weather_location_find($saved->{'uuid'});
	is($warwick->{'uuid'}, $place->{'uuid'}, 'naming the ground reuses the auto place');
	is($warwick->{'name'}, 'Warwick', 'and keeps the name the person gave it');
	is($warwick->{'anchor'}, 1, 'the place is anchored');
	my $found = subs::weather_location_for_fix(43.002356, -81.941971, 'Lambton Shores', { create => 0 });
	is($found->{'uuid'}, $place->{'uuid'}, 'a later fix lands on the anchored place');
	is($found->{'name'}, 'Warwick', 'and does not take the provider name back');
	my $toggled = subs::weather_location_anchor($place->{'uuid'}, 0);
	is($toggled->{'anchor'}, 0, 'the anchor can be turned off again');
	is(scalar @{ $toggled->{'locations'} }, 1, 'and the place is still listed');
	my $near = subs::weather_location_for_fix(43.2023, -81.9419, 'Nearby', { create => 0 });
	is($near->{'uuid'}, $place->{'uuid'}, 'a fix within thirty kilometres is the same place');
	my $far = subs::weather_location_for_fix(43.6023, -81.9419, 'Faraway', { create => 1 });
	isnt($far->{'uuid'}, $place->{'uuid'}, 'a fix beyond thirty kilometres is a new place');
}

# --- the home plate is the house's own station -------------------------------
{
	my %store;
	no warnings 'redefine';
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $store{'home_plate'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'home_plate'/ && $store{'home_plate'};
		return bless { rows => [ { value => $store{'locations'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/ && $store{'locations'};
		return bless { rows => [] }, 'FakeResult';
	};
	$store{'home_plate'} = Mojo::JSON::encode_json({ latitude => '43.0024', longitude => '-81.9419' });
	$store{'locations'} = Mojo::JSON::encode_json([
		{ uuid => 'warwick', name => 'Warwick', lat => 43.0023, lon => -81.9419, anchor => 1 },
	]);
	my $plate = subs::weather_home_plate();
	is($plate->{'from'}, 'home', 'the home app plate is the house');
	is($plate->{'lat'}, 43.0024, 'and carries its latitude');
	my $home_place = subs::weather_home_place();
	is($home_place->{'uuid'}, 'warwick', 'the picker finds the place at the home plate');
	$store{'home_plate'} = '';
	$plate = subs::weather_home_plate();
	is($plate->{'from'}, 'anchor', 'without a plate the anchored place is the house');
	is($plate->{'uuid'}, 'warwick', 'and names that place');
	is(subs::weather_home_place()->{'uuid'}, 'warwick', 'and stands in for the marked entry');
	$store{'locations'} = Mojo::JSON::encode_json([]);
	is(subs::weather_home_place(), undef, 'no plate and no anchor has no place to mark');
}

{
	no warnings 'redefine';
	local *subs::weather_locations = sub { [] };
	is(subs::weather_saved_place_km(43.0023, -81.9419), undef, 'no saved place has no distance');
}

# --- moving the home plate unanchors the old home ----------------------------
{
	my %store = (home_place => 'warwick');
	my %anchors;
	no warnings 'redefine';
	local *subs::rightNow = sub { 1794030000000 };
	local *subs::weather_home_place = sub { { uuid => 'toronto', name => 'Toronto', lat => 43.65, lon => -79.38 } };
	local *subs::weather_location_find = sub {
		return { uuid => 'warwick', name => 'Warwick', lat => 43.0023, lon => -81.9419, anchor => 1 } if $_[0] eq 'warwick';
		return { uuid => $_[0], name => uc $_[0], anchor => 0 };
	};
	local *subs::weather_location_anchor = sub { my ($u, $a) = @_; $anchors{$u} = $a; return { anchor => $a }; };
	local *subs::db_query = sub {
		return bless { rows => [ { value => $store{'home_place'} } ] }, 'FakeResult'
			if ($_[0] // '') =~ /setting = 'home_place'/ && $store{'home_place'};
		return bless { rows => [] }, 'FakeResult';
	};
	local *subs::setting_setter = sub { my ($q) = @_; $store{ $q->{'setting'} } = $q->{'value'}; return 1; };
	my $place = subs::weather_home_place_sync();
	is($place->{'uuid'}, 'toronto', 'the new home plate is the home place');
	is($anchors{'warwick'}, 0, 'the old home is unanchored');
	is($store{'home_place'}, 'toronto', 'and the new home is remembered');
	%anchors = ();
	subs::weather_home_place_sync();
	ok(!exists $anchors{'toronto'} && !exists $anchors{'warwick'}, 'the same home is left alone');
	$store{'home_place'} = 'warwick';
	delete $anchors{'warwick'};
	local *subs::weather_location_find = sub { { uuid => 'warwick', anchor => 0 } };
	subs::weather_home_place_sync();
	ok(!exists $anchors{'warwick'}, 'an old home that was already unanchored is not rewritten');
}

# --- the display name follows the home, but not a name you chose -------------
{
	my %store = (
		home_label => 'Warwick Weather',
		text_weather => 'Warwick Weather',
		text_weather_station => 'Warwick Weather',
	);
	no warnings 'redefine';
	local *subs::db_query = sub {
		my ($q, @args) = @_;
		return bless { rows => [ { value => $store{'home_label'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'home_label'/ && $store{'home_label'};
		if (($q // '') =~ /setting = 'notification_text'/) {
			my $app = $args[0] // '';
			return bless { rows => [ { value => $store{"text_$app"} } ] }, 'FakeResult'
				if defined $store{"text_$app"} && length $store{"text_$app"};
			return bless { rows => [] }, 'FakeResult';
		}
		return bless { rows => [] }, 'FakeResult';
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ $q->{'setting'} } = $q->{'value'};
		$store{ 'text_' . $q->{'app'} } = $q->{'value'} if ($q->{'setting'} // '') eq 'notification_text';
		return 1;
	};
	local *subs::format_name = sub { return $_[0] eq 'weather_station' ? 'Weather Station' : 'Weather'; };
	local *subs::ui = sub { return $_[0] // ''; };
	subs::weather_home_name_sync({ name => 'Toronto' });
	is($store{'text_weather'}, 'Toronto Weather', 'the weather app follows the new home');
	is($store{'text_weather_station'}, 'Toronto Weather', 'and the station display name too');
	is($store{'home_label'}, 'Toronto Weather', 'and the remembered label moves');
	$store{'text_weather'} = 'My Weather';
	$store{'text_weather_station'} = 'Warwick Weather';
	$store{'home_label'} = 'Warwick Weather';
	subs::weather_home_name_sync({ name => 'Sarnia' });
	is($store{'text_weather'}, 'My Weather', 'a name the person chose is left alone');
	is($store{'text_weather_station'}, 'Sarnia Weather', 'a name still tracking the home follows');
	$store{'home_label'} = 'Sarnia Weather';
	subs::weather_home_name_sync({ name => '43.6500, -79.3800' });
	is($store{'home_label'}, 'Sarnia Weather', 'an unnamed place does not move the label');
}

# --- the scheduled pass keeps an anchored place, not its covered phone -------
{
	no warnings 'redefine';
	local *subs::weather_observe_prepare = sub { {} };
	local *subs::weather_automation_rules = sub { [ { location => '' } ] };
	local *subs::weather_measure_rules = sub { [] };
	local *subs::weather_locations = sub { [ { uuid => 'warwick', name => 'Warwick', lat => 43.0023, lon => -81.9419, anchor => 1 } ] };
	local *subs::weather_device_fixes = sub { [ { signatorial => 'phone', lat => 43.0023, lon => -81.9419 } ] };
	my $keys = subs::weather_rule_locations();
	is_deeply($keys, ['loc:warwick'], 'the anchored place keeps its pass and the covered phone is not doubled');
	local *subs::weather_device_fixes = sub { [ { signatorial => 'phone', lat => 42.97, lon => -82.40 } ] };
	$keys = subs::weather_rule_locations();
	is_deeply($keys, ['loc:warwick'], 'a phone away from the anchor is not a station of its own');
}

# --- a reading carries the place, and an anchored place is written as itself -
{
	my %store;
	my %cache;
	my @written;
	no warnings 'redefine';
	local *subs::rightNow = sub { 1794020000000 };
	local *subs::weather_observe_leader = sub { 1 };
	local *subs::weather_observe_prepare = sub { {} };
	local *subs::weather_automation_rules = sub { [] };
	local *subs::weather_measure_rules = sub { [] };
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return $store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} };
	};
	local *subs::setting_setter = sub {
		my ($q) = @_;
		$store{ 'setting|' . $q->{'app'} . '|' . $q->{'setting'} } = $q->{'value'};
		return 1;
	};
	local *subs::cache_get = sub {
		my ($q) = @_;
		return $cache{ join('|', $q->{'app'}, $q->{'context'}, $q->{'subcontext'} // '') };
	};
	local *subs::cache_set = sub {
		my ($q, $v) = @_;
		$cache{ join('|', $q->{'app'}, $q->{'context'}, $q->{'subcontext'} // '') } = $v;
		return 1;
	};
	local *subs::controller_builder = sub { bless {}, 'FakeController' };
	local *Manager::appt_measure_writer = sub {
		my ($c, $data) = @_;
		push @written, { %{$data} };
		return 'measure-uuid';
	};
	local *subs::db_select = sub { bless { rows => [] }, 'FakeResult' };
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $store{'setting|weather|locations'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/ && $store{'setting|weather|locations'};
		return bless { rows => [] }, 'FakeResult';
	};
	$store{'setting|weather|locations'} = Mojo::JSON::encode_json([
		{ uuid => 'warwick', name => 'Warwick', lat => 43.0023, lon => -81.9419, anchor => 1, auto => 0 },
	]);
	my $r = subs::weather_observe_record({
		current => { condition => 'Rain', temperature => 7 },
		location_name => 'Lambton Shores', lat => 43.0023, lon => -81.9419,
	}, { location => 'dev:phone', force => 1 });
	is($r->{'ok'}, 1, 'the anchored reading is recorded');
	is($written[0]{'place'}, 'loc:warwick', 'the reading carries the anchored place');
	is($written[0]{'location'}, 'loc:warwick', 'and is written as the place, not the phone');
	is($cache{'weather|observe|last'}{'place_key'}, 'loc:warwick', 'the last observation points History at the place');

	$store{'setting|weather|locations'} = Mojo::JSON::encode_json([
		{ uuid => 'sarnia', name => 'Sarnia', lat => 42.97, lon => -82.40, anchor => 0, auto => 1 },
	]);
	@written = ();
	$r = subs::weather_observe_record({
		current => { condition => 'Cloudy', temperature => 12 },
		location_name => 'Sarnia', lat => 42.97, lon => -82.40,
	}, { location => 'dev:phone', force => 1 });
	is($r->{'ok'}, 1, 'the visiting reading is recorded');
	is($written[0]{'place'}, 'loc:sarnia', 'it carries the place it was taken at');
	is($written[0]{'location'}, 'dev:phone', 'the rule key stays the phone for a place that is not anchored');
	is($cache{'weather|observe|last'}{'place_key'}, 'loc:sarnia', 'and History follows the visiting place');
}

# --- deleting a place takes its readings with it ----------------------------
{
	my %store;
	my @tombstoned;
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
	$store{'setting|weather|locations'} = Mojo::JSON::encode_json([
		{ uuid => 'sarnia', name => 'Sarnia', lat => 42.97, lon => -82.40, auto => 1 },
	]);
	local *subs::db_query = sub {
		my ($q) = @_;
		return bless { rows => [ { value => $store{'setting|weather|locations'} } ] }, 'FakeResult'
			if ($q // '') =~ /setting = 'locations'/ && $store{'setting|weather|locations'};
		return bless { rows => [
			{ uuid => 'row1', measures => Mojo::JSON::encode_json([{ condition => 'Rain', place => 'loc:sarnia', location => 'dev:phone' }]) },
			{ uuid => 'row2', measures => Mojo::JSON::encode_json([{ condition => 'Rain', location => 'loc:sarnia' }]) },
			{ uuid => 'row3', measures => Mojo::JSON::encode_json([{ condition => 'Rain', place => 'loc:other' }]) },
		] }, 'FakeResult' if ($q // '') =~ /from appointments/;
		return bless { rows => [] }, 'FakeResult';
	};
	local *subs::records_tombstone = sub { push @tombstoned, $_[1]; return 1 };
	local *subs::cache_get = sub { {} };
	local *subs::cache_delete = sub { 1 };
	my $out = subs::weather_location_delete('sarnia');
	is($out->{'deleted_readings'}, 2, 'the place takes its readings with it');
	is_deeply(\@tombstoned, ['row1', 'row2'], 'and tombstones each one');
	is(scalar @{ $out->{'locations'} }, 0, 'the place is gone from the picker');
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
unlike($controller_auto, qr/weather_observe_record/, 'looking at a place does not record it');
like($controller_auto, qr/home_uuid/, 'the page finds the home plate for the picker');

my $page = read_file("$root/templates/apps/weather.html.ep");
like($page, qr/data-tab="automations"/, 'the page has an Automations tab');
like($page, qr{apps/weather/automations}, 'the page includes the Automations panel');
like($page, qr/id="weather_check_here"/, 'the page offers one check where you are');
like($page, qr/data-home="1"/, 'the home plate is marked in the picker');
like($page, qr/Home, always checked/, 'and says it is always checked');
my $weather_script = read_file("$root/public/js/manager/weather.js");
like($weather_script, qr/weatherCheckHere/, 'and the script keeps that reading');
like($weather_script, qr/Always checked/, 'the anchor button marks the home plate always checked');
like($weather_script, qr/data-home/, 'the script knows the home entry');
my $auto_partial = read_file("$root/templates/apps/weather/automations.html.ep");
like($auto_partial, qr/id="weather_automation_list"/, 'the panel has a rule list');
like($auto_partial, qr/id="weather_automation_check"/, 'the panel can check now');
my $core_auto = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($core_auto, qr{/js/manager/weather_automation\.js}, 'the lazy app loads the automation script');
like($core_auto, qr{weather\s*=>\s*\[qw\(/js/manager/weather\.js /js/manager/weather_history\.js /js/manager/weather_automation\.js /js/manager/weather_map\.js\)\]}, 'the automation and map scripts are in the Weather chunk');
my $loader_auto = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader_auto, qr/JawnOS::Domain::WeatherAutomation' for qw\([^)]*weather_observe_record/, 'the domain loader maps the observer');
my $president = read_file("$root/perl/utility_jobs.pl");
like($president, qr/weather_observe_tick/, 'the utility attaches the weather observer');
my $defaults = read_file("$root/perl/gb/01_state_and_defaults.pl");
like($defaults, qr/'weather_observe'\s*=>\s*\{/, 'the observer has a scheduled slot');

# --- the location picker and the hourly history are wired --------------------
like($routes_auto, qr{/manager/weather/location\b}, 'the saved-location route exists');
like($routes_auto, qr{/manager/weather/measure_rule\b}, 'the measurement-rule route exists');
like($controller_auto, qr/sub action_52018\b/, 'the saved-location action exists');
like($controller_auto, qr/sub action_52019\b/, 'the measurement-rule action exists');
like($routes_auto, qr{/manager/weather/location/anchor\b}, 'the anchor route exists');
like($controller_auto, qr/sub action_52021\b/, 'and its action');
like($controller_auto, qr/weather_location_save/, 'the page saves a location through the domain');
like($page, qr/id="weather_location_add"/, 'the location dropdown has an Add button');
my ($sticky_bar) = $page =~ m{(<div id="weather_toolbar">.*?</div>)}s;
ok($sticky_bar, 'the pinned bar is the toolbar');
like($sticky_bar, qr/id="weather_device"/, 'the pinned bar holds the location dropdown');
like($sticky_bar, qr/id="weather_location_add"/, 'and the Add button');
unlike($sticky_bar, qr/id="weather_location_delete"/, 'the other controls are not pinned');
like($page, qr{<div id="weather_actions">.*?id="weather_location_delete"}s, 'they scroll with the tab in their own row');
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

# --- the picker reads places, not coordinates --------------------------------
like($page, qr/\$places/, 'the page is handed place groups');
like($page, qr/data-seen=/, 'an option keeps the fix time for the place label');
like($page, qr/devices_text/, 'and names the machines in a group for the tooltip');
like($page, qr/location_labels/, 'a saved place is shown by its label');
my $weather_js = read_file("$root/public/js/manager/weather.js");
like($weather_js, qr/weatherPlaceLabel/, 'the app names the selected place from the provider');
unlike($map_js, qr/toFixed\(4\)/, 'the map does not fill a coordinate as the name');
like($map_js, qr/response\.labels/, 'the map uses the named place after a save');
like($loader_auto, qr/weather_place_groups/, 'the domain loader maps the place groups');
like($loader_auto, qr/weather_location_labels/, 'and the saved-place labels');
my $now_partial = read_file("$root/templates/apps/weather/now.html.ep");
like($now_partial, qr/14-day forecast/, 'the Now tab promises fourteen days');
like($now_partial, qr/Next 24 hours/, 'and names the hourly strip');
like($weather_js, qr/i < 14/, 'the script draws fourteen days');
like($weather_js, qr/weatherDayToggle/, 'a forecast day opens its detail, and a second press hides it');
like($weather_js, qr/weatherDayDetail/, 'the detail is built from the day and its hours');
like($weather_js, qr/weatherHoursByDate/, 'the hourly forecast is grouped by the day it belongs to');
like($weather_js, qr/weatherPrecipWindows/, 'the detail names when precipitation is likely');
like($weather_js, qr/weatherTempTrend/, 'and the warmest and coolest hours');
like($weather_js, qr/weatherDayChart/, 'the day detail draws a small temperature chart');
like($weather_js, qr/Hourly temperature for the day/, 'and labels the chart for assistive tech');
like($weather_js, qr/aria-expanded/, 'the day row reports whether it is open');
like($loader, qr/weather_reverse_geocode/, 'the domain loader maps the reverse geocoder');
like($loader, qr/weather_daily_extend/, 'and the daily extension');

# --- the tab's own style is inside a <style> tag -----------------------------
my $weather_style = read_file("$root/templates/apps/weather/style.html.ep");
like($weather_style, qr/^<style>/m, 'the style partial opens a style element');
like($weather_style, qr{</style>\s*$}m, 'and closes it, so the page does not print CSS');
like($weather_style, qr/#weather_toolbar \{[^}]*position: sticky/, 'the location dropdown and Add stay at the top while a tab scrolls');
like($weather_style, qr/#weather_toolbar \{[^}]*background: var\(--panel\)/, 'and hides the tab scrolling under it');
like($weather_style, qr/\.weather_day_detail\.open/, 'the day detail stays hidden until the row is opened');
like($weather_style, qr/\.weather_day_chart svg/, 'the day chart gets a compact height');

# --- saving, restoring and the strip ----------------------------------------
like($routes_auto, qr{/manager/weather/location/delete\b}, 'the delete route exists');
like($controller_auto, qr/sub action_52020\b/, 'and its action');
like($auto_partial, qr/class="weather_location_delete"/, 'the rule forms offer Delete beside At');
like($page, qr/id="weather_location_delete"/, 'the toolbar offers Delete too');
like($weather_js, qr/weatherLocationDelete/, 'the script deletes a saved place');
like($page, qr/id="weather_location_anchor"/, 'the toolbar offers Anchor');
like($weather_js, qr/weatherLocationAnchor/, 'the script toggles an anchor');
like($map_partial, qr/id="weather_map_anchor"/, 'the map offers Keep recording here');
like($map_js, qr/weather_map_anchor/, 'and sends it with the save');
like($loader_auto, qr/weather_location_for_fix/, 'the domain loader maps the fix-to-place helper');
like($loader_auto, qr/weather_location_anchor/, 'and the anchor writer');
like($weather_js, qr/weatherDateStamp/, 'the day rows carry a month/day/year stamp');
like($weather_js, qr/weatherDayName/, 'and a weekday name');
like($weather_js, qr/weatherLoading/, 'the app asks once at a time');
like($weather_style, qr/overscroll-behavior-x/, 'the hourly strip scrolls sideways');
my $windows_storage = read_file("$root/public/js/manager/windows/01_storage.js");
like($windows_storage, qr/i == 'weather'/, 'a restored Weather window uses its opener');
my $windows_js = read_file("$root/public/js/manager/windows.js");
like($windows_js, qr/weatherLoad\(\)/, 'a refreshed Weather window asks again');
my $defaults_t = read_file("$root/perl/gb/01_state_and_defaults.pl");
like($defaults_t, qr/'weather_observe'\s*=>\s*\{\s*interval\s*=>\s*60 \* 60/, 'the observer runs every hour');
like($loader, qr/weather_location_delete/, 'the domain loader maps the delete');
like($loader, qr/weather_observe_leader/, 'and the household leader');

done_testing();
