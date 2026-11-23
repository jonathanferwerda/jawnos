# tests-for: lib/JawnOS/Domain/Astronomy.pm lib/JawnOS/Domain/Budget2.pm lib/JawnOS/Domain/Evaluation.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_weather.pm lib/JawnOS/Routes/manager_weather.pm lib/JawnOS/Domain/Web.pm templates/apps/weather/now.html.ep templates/apps/weather/style.html.ep templates/handbook/evaluation.html.ep templates/apps/evaluation_wide_controls.html.ep public/js/manager/weather.js perl/gb/01_state_and_defaults.pl perl/utility_jobs.pl scripts/moon_backfill.pl
# covers:    the moon computed locally (no scraper), NOAA's space-weather products
#            parsed into one reading, the measure writer/backfill, the whole-house
#            digest and its automatic fit, the manual-only guard, and the weather
#            and Handbook wiring.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JSON::PP qw(encode_json decode_json);
use Time::Local qw(timegm);
use JawnOSTest;

my $root = root();

require "$root/lib/JawnOS/Domain/Schedule.pm";
require "$root/lib/JawnOS/Domain/Astronomy.pm";
require "$root/lib/JawnOS/Domain/Budget2.pm";
require "$root/lib/JawnOS/Domain/Evaluation.pm";

package FakeResult;
sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
sub hashes { return $_[0]->{rows}; }
sub hash { return $_[0]->{rows}->[0]; }

package main;

sub utc_ms {
	my ($y, $mo, $d, $h, $mi, $s) = @_;
	return timegm($s || 0, $mi || 0, $h || 0, $d, $mo - 1, $y) * 1000;
}

# --- the moon is arithmetic, and it agrees with the house's old scrape --------
{
	my $new = &subs::moon_phase(utc_ms(2000, 1, 6, 18, 14, 0));
	is($new->{'illumination'}, 0, 'a new moon is dark');
	like($new->{'phase_name'}, qr/New moon/i, 'and is named');
	is($new->{'waxing'}, 1, 'the cycle is waxing out of the new moon');

	my $first = &subs::moon_phase(utc_ms(2026, 11, 17, 12, 0, 0));
	cmp_ok($first->{'illumination'}, '>=', 48, '17 November 2026 is near first quarter');
	cmp_ok($first->{'illumination'}, '<=', 58, 'and not yet gibbous');
	like($first->{'phase_name'}, qr/first quarter/i, 'named first quarter');

	my $gibbous = &subs::moon_phase(utc_ms(2026, 11, 21, 12, 0, 0));
	is($gibbous->{'illumination'}, 89, '21 November 2026 matches the house scraped 89%');
	like($gibbous->{'phase_name'}, qr/waxing gibbous/i, 'and its waxing-gibbous name');
	is($gibbous->{'waxing'}, 1, 'still waxing before the full moon');

	my $full = &subs::moon_phase(utc_ms(2000, 1, 21, 4, 40, 0));
	cmp_ok($full->{'illumination'}, '>=', 99, 'a full moon is lit');
	like($full->{'phase_name'}, qr/full moon/i, 'and is named full');

	my $waning = &subs::moon_phase(utc_ms(2026, 11, 28, 12, 0, 0));
	is($waning->{'waxing'}, 0, 'after the full moon the cycle wanes');
	like($waning->{'phase_name'}, qr/waning/i, 'and the name says so');
}

{
	my $moon = &subs::moon_current({ timestamp => utc_ms(2026, 11, 21, 12, 0, 0), lat => -33.9 });
	is($moon->{'southern'}, 1, 'a southern place flips the lit limb');
	is($moon->{'illumination'}, 89, 'the computed reading is kept');
}

# --- NOAA's two shapes read the same -----------------------------------------
{
	my $kp = [
		[ 'time_tag', 'Kp', 'a_running', 'station_count' ],
		[ '2026-11-22 18:00:00.000', '2.33', '12', '8' ],
		[ '2026-11-22 21:00:00.000', '5.00', '15', '8' ],
	];
	my $mag = [ { time_tag => '2026-11-22T21:00:00.000Z', bt => '6.2', bz_gsm => '-2.1' } ];
	my $wind = [ { time_tag => '2026-11-22T21:00:00.000Z', speed => '420.5', density => '4.2' } ];
	my $got = &subs::space_weather_parse($kp, $mag, $wind);
	is($got->{'kp'}, 5, 'the latest Kp wins');
	is($got->{'kp_max_24h'}, 5, 'the 24-hour peak is kept');
	is($got->{'bz'}, -2.1, 'Bz keeps its sign');
	is($got->{'solar_wind_speed'}, 420.5, 'the solar wind speed is read');
	is($got->{'solar_wind_density'}, 4.2, 'the density is read');
	is($got->{'label'}, 'Active', 'Kp 5 reads as active');
	is($got->{'source'}, 'NOAA SWPC', 'the source is named');

	# The live SWPC files are arrays of objects, and the solar wind calls its
	# readings proton_speed / proton_density. Read that shape too.
	my $live_kp = [
		{ time_tag => '2026-11-22T18:00:00', Kp => 2.33 },
		{ time_tag => '2026-11-22T21:00:00', Kp => 5.67 },
	];
	my $live_wind = [ { time_tag => '2026-11-22T21:00:00', proton_speed => '361.85', proton_density => '6.33' } ];
	my $live = &subs::space_weather_parse($live_kp, $mag, $live_wind);
	is($live->{'kp'}, 5.67, 'the object-shaped Kp is read');
	is($live->{'kp_max_24h'}, 5.67, 'and its 24-hour peak');
	is($live->{'solar_wind_speed'}, 361.85, 'the proton speed is the solar wind speed');
	is($live->{'solar_wind_density'}, 6.33, 'and the proton density is the density');

	my $partial = &subs::space_weather_parse([], $mag, []);
	is($partial->{'bz'}, -2.1, 'a partial answer keeps what arrived');
	ok(!defined $partial->{'kp'}, 'and leaves the missing reading missing');
}

# --- a measure row is merged by day, or inserted once ------------------------
{
	my (@inserted, @updated, %set);
	local *subs::period_bounds = sub { return (1000, 2000) };
	local *subs::rightNow = sub { return 1500 };
	local *subs::device_setter = sub { return 'test-device' };
	local *subs::setting_grabber = sub { return undef };
	local *subs::setting_setter = sub { my ($d) = @_; $set{ $d->{'setting'} } = $d->{'value'}; };
	local *subs::db_insert = sub { push @inserted, [ @_ ] };
	local *subs::db_update = sub { push @updated, [ @_ ] };

	local *subs::db_query = sub { return FakeResult->new([]) };
	my $uuid = &subs::astronomy_measure_write('moon', {
		illumination => 89,
		moon_phase => 0.39399,
		lunar_phase => 'Waxing gibbous',
	}, 1200);
	ok($uuid, 'a new day writes a row');
	is(scalar @inserted, 1, 'one insert');
	is($inserted[0][0], 'appointments', 'into appointments');
	is($inserted[0][1]{'app'}, 'moon', 'under the moon app');
	is($inserted[0][1]{'type'}, 'measure', 'as a measure');
	is($inserted[0][1]{'source'}, 'astronomy', 'marked as computed');
	my $row = decode_json($inserted[0][1]{'measures'})->[0];
	is($row->{'illumination'}, 89, 'the illumination is in the row');
	is($row->{'moon_phase'}, 0.39399, 'the numeric phase is in the row');
	is($set{'local_source'}, 'on', 'the app is marked as a local source');

	local *subs::db_query = sub {
		return FakeResult->new([ {
			uuid => 'existing-row',
			timestamp => 1200,
			measures => encode_json([ { sun_angle => '0.54', illumination => '89' } ]),
		} ]);
	};
	my $same = &subs::astronomy_measure_write('moon', {
		illumination => 90,
		moon_phase => 0.40,
	}, 1200);
	is($same, 'existing-row', 'the day keeps its row');
	is(scalar @updated, 1, 'and the row is updated');
	my $merged = decode_json($updated[0][1]{'measures'})->[-1];
	is($merged->{'sun_angle'}, '0.54', 'the other measure is kept');
	is($merged->{'moon_phase'}, 0.4, 'the new phase is merged in');
	is($merged->{'illumination'}, 90, 'and the reading is replaced');
}

# --- the backfill walks local days and writes each one ----------------------
{
	my @days;
	local *subs::astronomy_measure_write = sub { push @days, $_[2]; return 'u'; };
	my $from = utc_ms(2026, 11, 20, 12, 0, 0);
	my $to = utc_ms(2026, 11, 22, 12, 0, 0);
	my $got = &subs::astronomy_backfill({ from => $from, to => $to });
	is($got->{'days'}, 3, 'three days counted');
	is($got->{'written'}, 3, 'three days written');
	is(scalar @days, 3, 'the writer saw each day');
	my @first = localtime($days[0] / 1000);
	is($first[5] + 1900, 2026, 'the first day is in 2026, not 1900');
	cmp_ok($days[1] - $days[0], '>=', 86000, 'and the days step forward');

	my $dry = &subs::astronomy_backfill({ from => $from, to => $to, dry_run => 1 });
	is($dry->{'written'}, 0, 'a dry run writes nothing');
}

# --- the category map prefers this machine's row -----------------------------
{
	local *subs::device_setter = sub { return 'laptop' };
	local *subs::db_query = sub {
		return FakeResult->new([
			{ app => 'coffee', setting => 'category', value => 'food', device => 'phone', server_time => 10 },
			{ app => 'coffee', setting => 'category', value => 'drink', device => 'laptop', server_time => 5 },
			{ app => 'nap', setting => 'pos', value => 'action', device => 'phone', server_time => 20 },
		]);
	};
	my $map = &subs::evaluation_house_categories();
	is($map->{'coffee'}{'category'}, 'drink', 'this machine\'s category row wins');
	is($map->{'nap'}{'pos'}, 'action', 'pos is read for an app with no category');
}

# --- the whole-house digest covers categories and keeps the tail ------------
{
	my $cats = {
		coffee => { category => 'food', subcategory => 'drinks' },
		tea => { category => 'food', subcategory => 'drinks' },
		bread => { category => 'food', subcategory => 'bakery' },
		nap => { category => 'rest', subcategory => 'sleep' },
	};
	my %daily;
	my %moon;
	my %kp;
	for my $i (0 .. 29) {
		my $day = sprintf('2026-10-%02d', $i + 1);
		$daily{$day} = 3 + ($i % 4);
		$moon{$day} = 20 + $i * 2;
		$kp{$day} = ($i % 5) + 1;
	}
	my $roll = {
		activity => {
			coffee => { count => 20, duration => 20 * 60000 },
			tea => { count => 10, duration => 10 * 30000 },
			bread => { count => 4, duration => 4 * 120000 },
			nap => { count => 8, duration => 8 * 1800000 },
		},
		daily => { map { $_ => { %daily } } qw(coffee tea bread nap) },
		hours => { coffee => { 8 => 5, 13 => 15 }, nap => { 14 => 8 } },
		weekdays => { coffee => { 1 => 20 }, nap => { 0 => 8 } },
		kinds => {},
		quantity => {},
	};
	my $rolls = {
		day => { activity => { coffee => { count => 1, duration => 60000 } } },
		week => { activity => { coffee => { count => 5, duration => 300000 } } },
		month => $roll,
		year => { activity => { coffee => { count => 200, duration => 12000000 } } },
		all => { activity => { coffee => { count => 2000, duration => 120000000 } } },
	};
	my $measures = {
		moon => { illumination => \%moon },
		space_weather => { kp => \%kp },
	};
	local *subs::db_query = sub {
		my ($sql) = @_;
		if ($sql =~ /group by movement/) {
			return FakeResult->new([
				{ movement => 'expense', total => 100, n => 2 },
				{ movement => 'income', total => 250, n => 1 },
			]);
		}
		if ($sql =~ /group by app/) {
			return FakeResult->new([ { app => 'coffee', total => 60 } ]);
		}
		if ($sql =~ /group by project/) {
			return FakeResult->new([ { project => 'garden', n => 3 } ]);
		}
		if ($sql =~ /from people/) {
			return FakeResult->new([ { n => 4 } ]);
		}
		return FakeResult->new([]);
	};
	my $d = &subs::evaluation_house_digest({
		roll => $roll,
		rolls => $rolls,
		measures => $measures,
		now => utc_ms(2026, 11, 1, 12, 0, 0),
		categories => $cats,
		top_k => 2,
	});
	is($d->{'house'}{'apps'}, 4, 'all four apps are counted');
	is(scalar @{$d->{'categories'}}, 2, 'two categories');
	my ($food) = grep { $_->{'name'} eq 'food' } @{ $d->{'categories'} };
	ok($food, 'food is a category');
	is($food->{'apps'}, 3, 'three apps in food');
	ok(scalar @{$food->{'top_apps'}} <= 2, 'only the top apps are named');
	is($d->{'tail'}{'apps'}, 1, 'the rest are counted in the tail');
	is($d->{'money'}{'in'}, '250', 'money in is read');
	is($d->{'money'}{'out'}, '100', 'money out is read');
	is($d->{'money'}{'net'}, '150', 'and the net follows');
	is($d->{'people'}{'count'}, 4, 'people are a count, not names');
	is($d->{'projects'}[0]{'project'}, 'garden', 'the project is kept');
	ok((grep { $_->{'app'} eq 'moon' && $_->{'measure'} eq 'illumination' } @{ $d->{'conditions'} }),
		'the moon is offered as a condition');
	ok((grep { $_->{'app'} eq 'space_weather' && $_->{'measure'} eq 'kp' } @{ $d->{'conditions'} }),
		'and the geomagnetic reading');
}

# --- the fit removes detail, never the categories ---------------------------
{
	my @categories;
	for my $c (0 .. 19) {
		my @top;
		for my $a (0 .. 4) {
			push @top, { app => "app_$c$a", occurrences => 10 - $a, kinds => { type => { 'a' x 30 => 1 } } };
		}
		push @categories, {
			name => "category_$c",
			apps => 5,
			occurrences => 40,
			per_day => '1.33',
			total_duration => '1 hour',
			top_apps => \@top,
		};
	}
	my $digest = {
		house => { apps => 100, categories => 20, windows => {}, daily => {}, hours => {}, weekdays => {} },
		categories => \@categories,
		tail => { apps => 0, occurrences => 0 },
		conditions => [ map { { app => 'moon', measure => 'illumination', r => '0.5', lag_days => 0 } } 0 .. 20 ],
		money => { in => '1', out => '2', net => '-1', apps => [ map { { app => "a$_", amount => '1' } } 0 .. 9 ] },
		projects => [ map { { project => "p$_", count => 1 } } 0 .. 20 ],
		people => { count => 3 },
	};
	my $before = length encode_json($digest);
	my ($fitted, $bytes, $truncated) = &subs::evaluation_digest_fit($digest, 1500);
	ok($truncated, 'the digest was fitted');
	cmp_ok($bytes, '<=', 1500, 'it fits the budget');
	cmp_ok(scalar @{$fitted->{'categories'}}, '>=', 5, 'the busiest categories survive');
	ok(!exists $fitted->{'projects'}, 'projects went first');
	is($fitted->{'house'}{'apps'}, 100, 'the house total is untouched');
}

# --- the whole-house run never schedules itself -----------------------------
{
	is(&subs::evaluation_manual_only('__president'), 1, 'the whole house is manual only');
	is(&subs::evaluation_manual_only('coffee'), 0, 'a single app keeps its cadence');
	is(&subs::evaluation_schedule_cron('__president', 'daily'), undef, 'and builds no cron');
}

# --- the wiring exists where the person will meet it ------------------------
{
	like(read_file("$root/templates/handbook/evaluation.html.ep"), qr/evaluation_wide_controls/,
		'Handbook has an Everything chapter');
	like(read_file("$root/templates/apps/evaluation_wide_controls.html.ep"), qr/system_evaluation/,
		'the chapter carries the Evaluate button');
	like(read_file("$root/lib/JawnOS/Routes/manager_weather.pm"), qr{/manager/weather/space_weather},
		'the space weather route is registered');
	like(read_file("$root/lib/JawnOS/Controller/manager_weather.pm"), qr/moon_current/,
		'the weather data includes the moon');
	like(read_file("$root/lib/JawnOS/Controller/manager_weather.pm"), qr/space_weather_fetch/,
		'and the space weather route fetches NOAA');
	like(read_file("$root/public/js/manager/weather.js"), qr/weatherMoonRender/,
		'the browser draws the moon');
	like(read_file("$root/public/js/manager/weather.js"), qr/weatherSpaceRender/,
		'and the space weather card');
	like(read_file("$root/lib/JawnOS/Domain/Web.pm"), qr/local_source/,
		'a local source stops the old scraper');
	like(read_file("$root/perl/gb/01_state_and_defaults.pl"), qr/'astronomy'/,
		'the astronomy job is in the utility schedule');
	like(read_file("$root/perl/utility_jobs.pl"), qr/astronomy_tick/,
		'and its subroutine is attached');
	like(read_file("$root/scripts/moon_backfill.pl"), qr/astronomy_backfill/,
		'the backfill script exists');
}

done_testing();
