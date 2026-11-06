# tests-for: lib/JawnOS/Domain/WeatherHistory.pm lib/JawnOS/Domain/Weather.pm lib/JawnOS/Controller/manager_weather.pm lib/JawnOS/Routes/manager_weather.pm templates/apps/weather.html.ep templates/apps/weather/history.html.ep templates/apps/weather/accuracy.html.ep templates/apps/weather/style.html.ep templates/apps/weather/now.html.ep public/js/manager/weather.js public/js/manager/weather_history.js
# covers:    The weather history backfill (old measures -> one row per day), the
#            daily merge, the 1-7 day forecast/actual accuracy, and the app wiring.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;
use Mojo::JSON qw(encode_json);

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Weather.pm";
require "$root/lib/JawnOS/Domain/WeatherHistory.pm";

# --- the old measures fold into one row per day -----------------------------
# The old app wrote one reading per entry, the measure name as the key.
my @rows = (
	{
		app => 'weather', device => 'hub', timestamp => '1700000000000',
		measures => [
			{ temperature => '5.4', ts => '1700000000000', uuid => 'a' },
			{ humidity => '85', ts => '1700000001000', uuid => 'b' },
			{ condition => 'cloudy', ts => '1700000002000', uuid => 'c' },
		],
	},
	{
		app => 'weather', device => 'hub', timestamp => '1700003600000',
		measures => [
			{ temperature => '7.8', ts => '1700003600000', uuid => 'd' },
			{ condition => 'a_few_clouds', ts => '1700003601000', uuid => 'e' },
			{ wind => 'calm', ts => '1700003602000', uuid => 'f' },
			{ visibility => '24', ts => '1700003603000', uuid => 'g' },
			{ wind_direction => 'SW', ts => '1700003604000', uuid => 'h' },
		],
	},
	{
		app => 'cambridge_weather', device => 'hub', timestamp => '1700000000000',
		measures => [
			{ temperature => '10', ts => '1700000000000', uuid => 'i' },
			{ temperature => '-.1', ts => '1700000005000', uuid => 'j' },
		],
	},
);
my $agg = subs::weather_history_aggregate(\@rows);
is(scalar @{$agg->{'days'}}, 2, 'one weather day and one Cambridge day');
my ($day) = grep { $_->{'source'} eq 'weather' } @{$agg->{'days'}};
ok($day, 'the weather day is kept');
is($day->{'high'}, 7.8, 'the day high is the warmest reading');
is($day->{'low'}, 5.4, 'the day low is the coldest reading');
is($day->{'count'}, 2, 'both temperature readings are counted');
is($day->{'condition'}, 'A few clouds', 'the most frequent condition wins the tie by name');
is($day->{'conditions'}[1]{'text'}, 'Cloudy', 'a machine-token condition reads as words');
is($day->{'humidity_forecast'}, 85, 'the forecast humidity is kept separately');
is($day->{'readings'}, 8, 'the reading count includes every measure');
is($day->{'wind'}, 0, 'a calm day reads as no wind');
is($day->{'wind_direction'}, 'SW', 'the wind direction is kept');
is($day->{'visibility'}, '24 km', 'a bare visibility number gains its unit');
is($agg->{'sources'}{'weather'}{'readings'}, 8, 'the source count is kept');
is($agg->{'sources'}{'weather'}{'day_count'}, 1, 'the source day count is kept');
is($agg->{'sources'}{'cambridge_weather'}{'day_count'}, 1, 'and the second source too');
my ($cambridge) = grep { $_->{'source'} eq 'cambridge_weather' } @{$agg->{'days'}};
is($cambridge->{'low'}, -0.1, 'a trimmed leading zero still reads as a number');

# --- day/night periods merge into one calendar day --------------------------
my $merged = subs::weather_daily_merge([
	{ date => '2026-11-06', label => 'Today', high => 10, low => 2, condition => 'cloudy', text => 'Cloudy' },
	{ date => '2026-11-06', label => 'Tonight', high => 8, low => 1, condition => 'rain', text => 'Rain' },
	{ date => '2026-11-07', label => 'Tomorrow', high => 12, low => 3, condition => 'sunny' },
]);
is(scalar @{$merged}, 2, 'two calendar days');
is($merged->[0]{'high'}, 10, 'the day keeps the higher high');
is($merged->[0]{'low'}, 1, 'and the lower low');
is($merged->[0]{'condition'}, 'cloudy', 'the first condition is kept');
is(scalar @{$merged->[0]{'periods'}}, 2, 'both periods ride along');

# --- forecast against what happened -----------------------------------------
my $actuals = [
	{ date => '2026-11-06', high => 10, low => 2, condition => 'cloudy' },
	{ date => '2026-11-07', high => 8, low => 1, condition => 'rain' },
];
my $snapshots = {
	'2026-11-06' => {
		1 => { high => 11, low => 3, condition => 'cloudy', fetched_at => 1 },
		2 => { high => 9, low => 0, condition => 'sunny', fetched_at => 1 },
	},
	'2026-11-07' => {
		1 => { high => 7, low => 2, condition => 'rain', fetched_at => 1 },
	},
};
my $accuracy = subs::weather_accuracy_summary($actuals, $snapshots);
is($accuracy->{'forecast_days'}, 2, 'two actual days have a forecast');
my ($lead1) = grep { $_->{'lead'} == 1 } @{$accuracy->{'summary'}};
is($lead1->{'count'}, 2, 'lead 1 has two samples');
is($lead1->{'mae_high'}, 1, 'lead 1 high MAE is one degree');
is($lead1->{'mae_low'}, 1, 'lead 1 low MAE is one degree');
is($lead1->{'condition_match'}, 100, 'lead 1 conditions match');
my ($lead2) = grep { $_->{'lead'} == 2 } @{$accuracy->{'summary'}};
is($lead2->{'count'}, 1, 'lead 2 has one sample');
is($lead2->{'mae_high'}, 1, 'lead 2 high MAE is one degree');
is($lead2->{'mae_low'}, 2, 'lead 2 low MAE is two degrees');
is($lead2->{'condition_match'}, 0, 'lead 2 condition does not match');
is($accuracy->{'detail'}[0]{'forecasts'}{1}{'high_error'}, 1, 'the detail carries the signed high error');

# --- small helpers -----------------------------------------------------------
is(subs::weather_condition_class('Light rain'), 'rain', 'rain words class as rain');
is(subs::weather_condition_class('Cloudy'), 'cloud', 'cloud words class as cloud');
is(subs::weather_condition_class('Thunderstorm'), 'thunder', 'storm words class as thunder');
is(subs::weather_days_between('2026-11-06', '2026-11-07'), 1, 'one day between dates');
ok(length subs::weather_day_key(1700000000000), 'a timestamp has a day key');

# --- wiring ------------------------------------------------------------------
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
like($loader, qr/JawnOS::Domain::WeatherHistory' for qw\([^)]*weather_history_build/, 'the history module is mapped');
like($loader, qr/JawnOS::Domain::Weather' for qw\([^)]*weather_daily_merge/, 'the daily merge is mapped');
my $controller = read_file("$root/lib/JawnOS/Controller/manager_weather.pm");
like($controller, qr/sub action_52012\b/, 'the history route action exists');
like($controller, qr/sub action_52013\b/, 'the backfill route action exists');
like($controller, qr/sub action_52014\b/, 'the accuracy route action exists');
my $routes = read_file("$root/lib/JawnOS/Routes/manager_weather.pm");
like($routes, qr{/manager/weather/history}, 'the history route is registered');
like($routes, qr{/manager/weather/backfill}, 'the backfill route is registered');
like($routes, qr{/manager/weather/accuracy}, 'the accuracy route is registered');
my $template = read_file("$root/templates/apps/weather.html.ep");
like($template, qr{apps/weather/history}, 'the page includes the history panel');
like($template, qr{apps/weather/accuracy}, 'and the accuracy panel');
my $history_template = read_file("$root/templates/apps/weather/history.html.ep");
like($history_template, qr/weather_history_backfill/, 'the Backfill history button exists');
my $js = read_file("$root/public/js/manager/weather_history.js");
like($js, qr/function weatherHistoryLoad/, 'the history loads');
like($js, qr/function weatherAccuracyRender/, 'the accuracy renders');
like($js, qr/weatherHistoryChart/, 'the chart is drawn');
my $help = read_file("$root/perl/help/topics_apps.pl");
like($help, qr{The History tab reads}, 'the help topic explains history');
like($help, qr{The Accuracy tab compares}, 'and the accuracy comparison');

done_testing();
