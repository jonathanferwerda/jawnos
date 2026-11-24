# tests-for: lib/JawnOS/Domain/Astronomy.pm lib/JawnOS/Domain/Budget2.pm lib/JawnOS/Domain/Evaluation.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_weather.pm lib/JawnOS/Routes/manager_weather.pm lib/JawnOS/Domain/Web.pm templates/apps/weather/now.html.ep templates/apps/weather/style.html.ep templates/handbook/evaluation.html.ep templates/apps/evaluation_wide_controls.html.ep public/js/manager/weather.js perl/gb/01_state_and_defaults.pl perl/utility_jobs.pl scripts/moon_backfill.pl scripts/space_weather_backfill.pl
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
require "$root/lib/JawnOS/Domain/Clock.pm";
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

# --- the wider NOAA set reads as one picture --------------------------------
{
	is(&subs::space_weather_dst([ { time_tag => '2026-11-22T21:00:00', dst => -42 } ]), -42,
		'Dst keeps its sign');

	my $scales = &subs::space_weather_scales({
		'0' => {
			R => { Scale => '1', Text => 'minor' },
			S => { Scale => '0', Text => 'none' },
			G => { Scale => '2', Text => 'moderate' },
		},
	});
	is($scales->{'r_scale'}, 1, 'R is read');
	is($scales->{'g_scale'}, 2, 'G is read');
	is($scales->{'g_text'}, 'moderate', 'and its word');

	my $now = utc_ms(2026, 11, 22, 21, 0, 0);
	my $forecast = &subs::space_weather_forecast([
		{ time_tag => '2026-11-22T18:00:00', kp => 2, observed => 'observed' },
		{ time_tag => '2026-11-23T03:00:00', kp => 4, observed => 'predicted' },
		{ time_tag => '2026-11-24T03:00:00', kp => 6, observed => 'predicted' },
	], $now);
	is($forecast->{'kp_forecast_max'}, 6, 'the strongest forecast Kp is kept');

	is(&subs::space_weather_f107([ { flux => 94, time_tag => '2026-11-22T20:00:00' } ]), 94,
		'F10.7 is read');
	my $spots = &subs::space_weather_sunspots([
		{ 'time-tag' => '2026-09', ssn => 40 },
		{ 'time-tag' => '2026-10', ssn => 45.7 },
	]);
	is($spots->{'sunspot_number'}, 45.7, 'the latest monthly sunspot number wins');

	my $alerts = &subs::space_weather_alerts([
		{ product_id => 'K05A', issue_datetime => '2026-11-22 20:00:00', message => "ALERT: Geomagnetic K-index of 5\r\nThreshold Reached" },
		{ product_id => 'X1', issue_datetime => '2026-11-22 20:30:00', message => 'Nothing to act on' },
	], $now);
	is(scalar @{$alerts}, 1, 'only the actionable bulletin is kept');
	like($alerts->[0]{'text'}, qr/Geomagnetic K-index/, 'and its text is readable');
	is($alerts->[0]{'title'}, 'ALERT: Geomagnetic K-index of 5', 'the product line is the accordion header');
	is($alerts->[0]{'issued_at'}, utc_ms(2026, 11, 22, 20, 0, 0), 'the issue time is a timestamp');

	# A bulletin leaves the card when its own end is behind us. NOAA's file keeps
	# the whole day's products, so without this the newest three are yesterday's.
	my $expired = &subs::space_weather_alerts([
		{ product_id => 'OLD', issue_datetime => '2026-11-22 19:00:00',
			message => "WARNING: Geomagnetic K-index of 5 expected\r\nValid To: 2026 Nov 22 2000 UTC" },
	], $now);
	is(scalar @{$expired}, 0, 'a bulletin whose stated end has passed is dropped');
	my $extended = &subs::space_weather_alerts([
		{ product_id => 'EXT', issue_datetime => '2026-11-22 19:00:00',
			message => "EXTENDED WARNING: Geomagnetic K-index of 5 expected\r\nValid To: 2026 Nov 22 2000 UTC\r\nNow Valid Until: 2026 Nov 23 0300 UTC" },
	], $now);
	is(scalar @{$extended}, 1, 'an extended warning is kept while its new end is ahead');
	is($extended->[0]{'valid_to'}, utc_ms(2026, 11, 23, 3, 0, 0), 'and carries the new end');
	my $stale = &subs::space_weather_alerts([
		{ product_id => 'STALE', issue_datetime => '2026-11-20 12:00:00', message => 'ALERT: Geomagnetic K-index of 5' },
	], $now);
	is(scalar @{$stale}, 0, 'an open-ended bulletin issued days ago is dropped');
	is(&subs::_noaa_utc('2026 Nov 22 2100 UTC'), utc_ms(2026, 11, 22, 21, 0, 0), 'the alert body time parses');
	is(&subs::_noaa_alert_title("Space Weather Message Code: WARK04\r\nEXTENDED WARNING: Geomagnetic K-index of 4 expected\r\nValid To: 2026 Nov 22 2000 UTC"),
		'EXTENDED WARNING: Geomagnetic K-index of 4 expected', 'an extended warning keeps its own headline');

	# A tiny aurora grid: the real one is longitude-major, but the nearest-point
	# fallback must work when the index assumption does not.
	my @coords;
	for my $lon (0 .. 3) {
		for my $lat (-2 .. 2) { push @coords, [ $lon, $lat, ($lon == 2 && $lat == 1) ? 7 : 0 ]; }
	}
	my $aurora = &subs::space_weather_aurora_at({ coordinates => \@coords }, 1, 2);
	is($aurora->{'aurora_probability'}, 7, 'the aurora over the house is extracted from the grid');

	my $magnetometer = &subs::space_weather_magnetometer_parse({
		metadata => { intermagnet => { imo => { iaga_code => 'FRD', name => 'Fredericksburg' } } },
		times => [ '2026-11-22T23:59:00.000Z' ],
		values => [
			{ id => 'X', values => [ 20000, 20468 ] },
			{ id => 'Y', values => [ -700, -759 ] },
			{ id => 'Z', values => [ 39000, 39753 ] },
			{ id => 'F', values => [ 46000, 46325 ] },
		],
	});
	is($magnetometer->{'f'}, 46325, 'the total field is read');
	cmp_ok($magnetometer->{'d'}, '<', 0, 'declination keeps its sign');
	is($magnetometer->{'observatory'}, 'FRD', 'and the station is named');

	my @gfz = ( 2026, 11, 21, 0, 0, 0, 0, 2, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 5, 37, 99.0, 96.6, 0 );
	my $history = &subs::space_weather_history_parse("# header\n" . join(' ', @gfz) . "\n", utc_ms(2026, 11, 1, 0, 0, 0), utc_ms(2026, 11, 30, 0, 0, 0));
	is($history->{'2026-11-21'}{'kp'}, 2, 'the day\'s highest Kp is kept');
	is($history->{'2026-11-21'}{'ap'}, 5, 'Ap is read');
	is($history->{'2026-11-21'}{'sunspot_number'}, 37, 'the sunspot number is read');
	is($history->{'2026-11-21'}{'f107'}, 99, 'and F10.7');

	my $dst_text = "DST2610*01RRX020   0  -3  -5   3   7   7   8  11   7  -1  -6  -2   3   6   5   0  -1  -1  -1   0   3   5   7  11  12   3\n";
	my $dst = &subs::space_weather_dst_month_parse($dst_text, 2026, 10);
	is($dst->{'2026-10-01'}{'dst_min'}, -6, 'the lowest Dst is kept');
}

# --- the historical fetch merges GFZ and Kyoto into one row -----------------
{
	my @written;
	local *subs::weather_http_get_text = sub {
		my ($url) = @_;
		if ($url =~ /gfz-potsdam/) {
			my @f = ( 2026, 11, 21, 0, 0, 0, 0, 2, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 5, 37, 99.0, 96.6, 0 );
			return ("# header\n" . join(' ', @f) . "\n", undef);
		}
		return ("DST2611*21RRX020   0  -3  -5   3   7\n", undef);
	};
	local *subs::astronomy_measure_write = sub {
		my ($app, $values, $when) = @_;
		push @written, [ $app, $values, $when ];
		return 'uuid';
	};
	my $got = &subs::space_weather_backfill({
		from => utc_ms(2026, 11, 21, 0, 0, 0),
		to => utc_ms(2026, 11, 21, 23, 0, 0),
	});
	is($got->{'written'}, 1, 'one day written');
	is($written[0][0], 'space_weather', 'into the space weather app');
	is($written[0][1]{'kp'}, 2, 'the GFZ Kp is there');
	is($written[0][1]{'dst_min'}, -5, 'and the Kyoto Dst is merged in');
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
	local *subs::clock_zone_house = sub { return 'UTC' };

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

# --- the daily row is the person's day, not the box's -----------------------
{
	my (@inserted, %set, $zone_seen);
	local *subs::clock_zone_house = sub { return 'America/New_York' };
	local *subs::period_bounds = sub {
		$zone_seen = $ENV{'TZ'};
		return (1000, 2000);
	};
	local *subs::rightNow = sub { return 1500 };
	local *subs::device_setter = sub { return 'test-device' };
	local *subs::setting_grabber = sub { return undef };
	local *subs::setting_setter = sub { my ($d) = @_; $set{ $d->{'setting'} } = $d->{'value'}; };
	local *subs::db_insert = sub { push @inserted, [ @_ ] };
	local *subs::db_query = sub { return FakeResult->new([]) };
	my $before = $ENV{'TZ'};
	&subs::astronomy_measure_write('moon', { illumination => 50 }, 1200);
	is($zone_seen, 'America/New_York', 'the day bounds are computed in the house zone');
	is($ENV{'TZ'}, $before, 'and the process zone is put back afterwards');
	is($inserted[0][1]{'timestamp'}, 1000 + 12 * 3600 * 1000, 'the row is anchored at noon of that day');
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
		'the moon backfill script exists');
	like(read_file("$root/scripts/space_weather_backfill.pl"), qr/space_weather_backfill/,
		'the space weather backfill script exists');
	like(read_file("$root/public/js/manager/weather.js"), qr/weather_space_local/,
		'the card has a local magnetic field section');
}

done_testing();
