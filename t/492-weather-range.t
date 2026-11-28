# tests-for: lib/JawnOS/Domain/VoiceFunnel.pm lib/JawnOS/Domain/WeatherHistory.pm lib/JawnOS/Domain/Loader.pm perl/gb/03_engines_and_tools.pl perl/help/topics_apps.pl perl/help/topics_features.pl docs/voice-funnel.md
# covers:    The weather answer reads the whole forecast and the whole past: any
#           day in the fourteen-day forecast, a past day, month or season from
#           Open-Meteo's archive, and a comparison against last year/month/week.
#           The archive reader maps the provider's daily arrays, and a weather
#           question reaches the weather resolver before the visit resolver.

use strict;
use warnings;
use utf8;
$| = 1;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;
use Time::Piece;
use File::Slurp qw(read_file);

require './perl/gb/03_engines_and_tools.pl';
require 'JawnOS/Domain/Weather.pm';
require 'JawnOS/Domain/WeatherHistory.pm';
require 'JawnOS/Domain/VoiceFunnel.pm';

&subs::preload('cache_get');
&subs::preload('cache_set');

my $now = &subs::rightNow();
my $today = &subs::weather_day_key($now);

my $real_archive = \&subs::weather_history_archive_days;

local *subs::signatorial_designer = sub { 'test-device' };
local *subs::weather_device_fix = sub { { lat => 42.97, lon => -82.40 } };
local *subs::weather_locations = sub { [] };
local *subs::weather_home_place = sub { undef };

# Fourteen days, each with a distinct high so a lookup can be proved.
my @forecast;
for my $i (0 .. 13) {
	push @forecast, {
		date => &subs::weather_day_key($now + $i * 86400000),
		high => 10 + $i, low => $i - 5, condition => 'Clear sky',
		precip_prob => 5 * $i, wind_speed => 12, wind_direction => 'W',
	};
}
local *subs::weather_fetch = sub {
	return {
		current => { temperature => 12, condition => 'Clear sky', wind_speed => 10 },
		daily => [ @forecast ], hourly => [],
	};
};

# The archive carries 2025 at 6 degrees and 2026 at 2, so a comparison has a
# direction that does not depend on the day the suite runs.
local *subs::weather_history_archive_days = sub {
	my ($lat, $lon, $from, $to) = @_;
	my $t = eval { Time::Piece->strptime($from, '%Y-%m-%d') } or return { days => [] };
	my $e = eval { Time::Piece->strptime($to, '%Y-%m-%d') } or return { days => [] };
	my @days;
	while ($t->epoch <= $e->epoch && @days < 400) {
		my $year = $t->year;
		push @days, {
			date => $t->strftime('%Y-%m-%d'),
			high => $year == 2025 ? 6 : 2,
			low => $year == 2025 ? -2 : -8,
			mean => 0, condition => 'Light snow', precip_mm => 1.5,
			source => 'Open-Meteo archive',
		};
		$t = Time::Piece->localtime($t->epoch + 86400);
	}
	return { days => \@days, source => 'Open-Meteo archive' };
};

sub ask {
	my ($what, $text) = @_;
	return &subs::voice_funnel_weather_answer('', $what, $text);
}

# ------------------------------------------------------------ the forecast
my $ten = &ask('now', 'what is the weather in 10 days');
ok($ten && $ten->{'handled'}, 'a day ten days out is answered');
like($ten->{'speech'}, qr/high 20/, 'from the tenth forecast day');
unlike($ten->{'speech'}, qr/Open-Meteo's record/, 'and it is the forecast, not the archive');

my $tw = Time::Piece->new->wday;
my $ahead = (5 - $tw + 7) % 7;
my $friday = &ask('highlow', 'what is the weather on Friday');
like($friday->{'speech'}, qr/high (?:@{[ 10 + $ahead ]})/, 'a weekday reads that forecast day');

# ------------------------------------------------------------ the past
my $march = &ask('now', 'what was the weather on March 5');
ok($march && $march->{'handled'}, 'a past day is answered');
like($march->{'speech'}, qr/Open-Meteo's record for March 5, 2026/, 'from the archive, named as such');
like($march->{'speech'}, qr/high 2/, 'with the archived high');
like($march->{'speech'}, qr/low -8/, 'and the archived low');

my $month = &ask('now', 'what was the weather in March');
like($month->{'speech'}, qr/Open-Meteo's record for March 2026/, 'a named month is a period');
like($month->{'speech'}, qr/highs averaging 2/, 'summarised across the month');

my $three = &ask('now', 'what was the weather 3 months ago');
like($three->{'speech'}, qr/August 2026/, 'months ago becomes that month');
like($three->{'speech'}, qr/highs averaging 2/, 'and is summarised the same way');

my $yesterday = &ask('now', 'what was the weather yesterday');
like($yesterday->{'speech'}, qr/Open-Meteo's record for yesterday/, 'yesterday is a past day');
like($yesterday->{'speech'}, qr/high 2/, 'read from the archive');

# ------------------------------------------------------------ comparisons
my $week = &ask('now', 'compare this week to last year');
like($week->{'speech'}, qr/than the same time last year/, 'a comparison names the year before');
like($week->{'speech'}, qr/a high of/, 'and states both highs');

my $warm = &ask('now', 'was it warmer than last year');
like($warm->{'speech'}, qr/warmer/, 'a warmer/colder question compares the same day');
like($warm->{'speech'}, qr/by 4 degrees/, 'with the difference (10 against 6)');

# A weather question reaches the weather resolver even when the visit resolver
# would otherwise claim the words.
{
	local *subs::voice_funnel_history_answer = sub {
		return { handled => 1, kind => 'history', speech => 'the wrong answer' };
	};
	my $fast = &subs::voice_funnel_fast('what was the weather on March 5', {});
	like($fast->{'speech'}, qr/Open-Meteo's record/, 'weather wins the fast path');
}

# ------------------------------------------------------------ the archive reader
{
	local *subs::cache_get = sub { undef };
	local *subs::cache_set = sub { };
	local *subs::weather_http_get = sub {
		return ({ daily => {
			time => [ '2025-06-01', '2025-06-02' ],
			temperature_2m_max => [ 21.5, 18 ],
			temperature_2m_min => [ 9, 7.5 ],
			temperature_2m_mean => [ 15, 13 ],
			weather_code => [ 1, 61 ],
			precipitation_sum => [ 0, 4.2 ],
			wind_speed_10m_max => [ 14, 22 ],
			wind_direction_10m_dominant => [ 270, 90 ],
		} }, undef);
	};
	my $archive = $real_archive->(42.97, -82.40, '2025-06-01', '2025-06-02');
	is(scalar @{ $archive->{'days'} }, 2, 'the archive reader keeps both days');
	is($archive->{'days'}[0]{'high'}, 21.5, 'the high is read from temperature_2m_max');
	is($archive->{'days'}[1]{'condition'}, 'Slight rain', 'the weather code is read as a condition');
	is($archive->{'days'}[1]{'precip_mm'}, 4.2, 'the rain total is kept');
	is($archive->{'days'}[0]{'wind_direction'}, 'W', 'the dominant wind is named');
	is($archive->{'source'}, 'Open-Meteo archive', 'and the source is the archive');
}

# ------------------------------------------------------------ what the person is told
my ($weather_tool) = grep { ($_->{'name'} // '') eq 'weather' } @gb::guide_tools;
ok($weather_tool, 'the weather tool is declared');
like($weather_tool->{'desc'}, qr/fourteen-day/, 'the tool names the whole forecast');
like($weather_tool->{'desc'}, qr/compare to last year/, 'and the comparison');
like(read_file('perl/help/topics_apps.pl'), qr/compare this week to last year/,
	'the Weather topic names the spoken comparison');
like(read_file('perl/help/topics_features.pl'), qr/fourteen-day forecast/,
	'the Voice topic names the whole forecast');
like(read_file('docs/voice-funnel.md'), qr/weather_history_archive_days/,
	'the funnel doc names the archive reader');

done_testing();
