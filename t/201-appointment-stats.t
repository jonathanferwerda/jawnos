# tests-for: lib/JawnOS/Domain/Appointment2.pm lib/JawnOS/Domain/Web.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_misc.pm lib/JawnOS/Manager/Part05.pm templates/appointment_wrapper.html.ep templates/apps/appointment_stats.html.ep templates/apps/app_measure_details.html.ep templates/market/market.html.ep public/js/manager/manager/09_app_back.js public/js/manager/websocket/01_message_handler.js public/js/manager/windows.js
# covers:    the appointment's bottom line - shelf in/out, days of stock left coloured when low and movements per period, and time, count, money and measures for today/week/month/year, each with its pace to the period's end; and the shopping list reading the same shelf as a due item, with its runway named on the row and on the Shopping tab badge

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use Mojo::Template;
use JawnOSTest;
use RepoSource;

# The appointment wrapper closes with one row of headers: Evaluation (the report
# it already showed), Inv (the item's shelf), Time, Count, $ and Meas. Each
# period reading counts a row at its start, but time is the portion spent inside
# the period; money is the total's magnitude; and a measure reads with its own
# calc, so steps are summed and weight averaged. The same test pins the small UI
# moves around it: the five state buttons are little_thumb, the placeholders
# start with a capital, the note sits directly under its row, and a save or a
# pushed header asks the ago/warranty readings again.

my $root = repo_root();

# ----------------------------------------------------------- the readings
my ($fh, $dbfile) = tempfile('jawnos-stats-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table appointments (app text, timestamp text, stop_timestamp text, type text, duration text, total text, measures text)');
$db->query('create table warehouse (item text, unit text, quantity text, kind text, type text, account text, timestamp text)');
$db->query('create table settings (setting text, value text, timestamp text, id integer primary key autoincrement, '
	. 'app text, server_time text, device text, browser_tab_id text, uuid text, ost text, subsetting text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;

my $device = &subs::device_setter();
my $now    = ts(2026, 11, 7, 12, 0, 0);   # a Saturday, so the week began Sunday November 1
my $row_id = 0;

sub appt {
	my ($at, $duration, $total, $measures) = @_;
	$row_id++;
	$db->query(
		'insert into appointments (app, timestamp, stop_timestamp, type, duration, total, measures) values (?,?,?,?,?,?,?)',
		'walk', $at, $at + $duration, 'stop', $duration * -1, $total, $measures,
	);
}

sub measure_json {
	my ($at, $steps, $weight) = @_;
	$row_id++;
	# the recorder stamps every entry with its clock under more than one name;
	# none of those names is a reading
	return '[{"steps":"' . $steps . '","weight":"' . $weight . '","ts":"' . $at
		. '","timestamp":"' . $at . '","server_time":"' . $at . '","uuid":"m' . $row_id . '"}]';
}

appt(ts(2026, 11,  7, 10), 3600000, 10, measure_json(ts(2026, 11,  7, 10), 1000, 170));   # today
appt(ts(2026, 11,  3, 10), 7200000, 20, measure_json(ts(2026, 11,  3, 10), 2000, 180));   # this week
appt(ts(2026, 11,  1, 10), 3600000,  5, measure_json(ts(2026, 11,  1, 10), 3000, 190));   # this month
appt(ts(2026,  2,  1, 10), 1800000,  7, measure_json(ts(2026,  2,  1, 10), 4000, 200));   # this year
appt(ts(2025, 12, 31, 10), 3600000, 99, measure_json(ts(2025, 12, 31, 10), 9000, 300));   # last year

# an open start carries a duration written when it began; the reading still
# runs to now, the same way the budget reads that row
$db->query('insert into appointments (app, timestamp, stop_timestamp, type, duration, total, measures) values (?,?,?,?,?,?,?)',
	'walk_open', ts(2026, 11, 7, 11), undef, 'start', -600000, 0, undef);

foreach my $set ( [ 'measure_calc', 'sum', 'steps' ], [ 'measure_calc', 'average', 'weight' ] ) {
	$db->query('insert into settings (setting, value, app, device, subsetting, uuid, server_time) values (?,?,?,?,?,?,?)',
		$set->[0], $set->[1], 'walk', $device, $set->[2], 'set-' . $set->[2], $now);
}
$db->query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
	'app_measures', '{"steps":{"type":"number"},"weight":{"type":"number","unit":"lb"}}',
	'walk', $device, 'set-app-measures', $now);
# the app's own warning lines: this item is urgent at eighty days, amber at a
# hundred, so the seventy-five-day reading lands in the red
foreach my $set ( [ 'low_stock_days', '100' ], [ 'urgent_stock_days', '80' ] ) {
	$db->query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
		$set->[0], $set->[1], 'walk', $device, 'set-' . $set->[0], $now);
}

# the shelf: two in, two out, one Usage row that must not count. The stock rows
# carry their own clock too, so the period rows can show when each moved.
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk', 'g', '10', 'stock', ts(2026, 11,  7, 10));
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk', 'g', '6',  'stock', ts(2026, 11,  3, 10));
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk', 'g', '-4', 'stock', ts(2026, 11,  1, 10));
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk', 'g', '-2', 'stock', ts(2026,  2,  1, 10));
$db->query('insert into warehouse (item, unit, quantity, kind) values (?,?,?,?)', 'walk', 'g', '100', 'usage');
# a balance anchor and a money row name the item but are not stock
$db->query('insert into warehouse (item, unit, quantity, type) values (?,?,?,?)', 'walk', 'g', '500', 'inventory');
$db->query('insert into warehouse (item, unit, quantity, account) values (?,?,?,?)', 'walk', 'g', '900', 'cash');

my $stats = &subs::appointment_statistics_for('walk', $now);
is($stats->{'item'}, 'walk', 'the readings belong to the app it was asked for');
is_deeply([ map { $_->{'key'} } @{ $stats->{'periods'} } ], [qw/today week month year/],
	'the four periods come back in their order');
my %p = map { $_->{'key'} => $_ } @{ $stats->{'periods'} };

is($p{'today'}->{'count'}, 1, 'today counts the row that started today');
is($p{'week'}->{'count'}, 3, 'this week starts on Sunday, so the first of the month counts too');
is($p{'month'}->{'count'}, 3, 'this month adds the first of the month');
is($p{'year'}->{'count'}, 4, 'this year adds February and leaves last year out');

is($p{'today'}->{'duration'}, 3600000, 'today holds an hour');
is($p{'week'}->{'duration'}, 14400000, 'this week holds four hours, the first of the month included');
is($p{'month'}->{'duration'}, 14400000, 'this month holds four hours');
is($p{'year'}->{'duration'}, 16200000, 'this year holds four and a half hours');

# a start still in the stream reads to now, not to the duration the row was
# written with when it began (the budget reads the same row the same way)
my $open = &subs::appointment_statistics_for('walk_open', $now);
my %op = map { $_->{'key'} => $_ } @{ $open->{'periods'} };
is($op{'today'}->{'duration'}, 3600000, 'an open start reads to now, not its stored duration');
is($op{'today'}->{'count'}, 1, 'and it still counts once');

# a session that began last year and ran into this one gives this year the part
# after midnight, though its occurrence stays in the year it started
$db->query('insert into appointments (app, timestamp, stop_timestamp, type, duration, total, measures) values (?,?,?,?,?,?,?)',
	'walk_year', ts(2025, 12, 31, 23), ts(2026, 1, 1, 1), 'stop', -7200000, 0, undef);
my $cross = &subs::appointment_statistics_for('walk_year', $now);
my %cy = map { $_->{'key'} => $_ } @{ $cross->{'periods'} };
is($cy{'year'}->{'duration'}, 3600000, 'time across New Year counts where it was spent');
is($cy{'year'}->{'count'}, 0, 'but the occurrence stays in the year it started');

is($p{'today'}->{'money'}, 10, 'today holds its ten');
is($p{'week'}->{'money'}, 35, 'this week holds thirty-five');
is($p{'month'}->{'money'}, 35, 'this month holds thirty-five');
is($p{'year'}->{'money'}, 42, 'this year holds forty-two, not last year');

is($p{'today'}->{'measures'}->{'steps'}->{'calc'}, 'sum', 'steps read as a sum');
is($p{'today'}->{'measures'}->{'steps'}->{'value'}, 1000, 'today sums its steps');
is($p{'year'}->{'measures'}->{'steps'}->{'value'}, 10000, 'the year sums every step');
is($p{'today'}->{'measures'}->{'weight'}->{'calc'}, 'average', 'weight reads as an average');
is($p{'today'}->{'measures'}->{'weight'}->{'value'}, 170, 'today averages its weight');
is($p{'year'}->{'measures'}->{'weight'}->{'value'}, 185, 'the year averages every weight');
my %measure_name = map { $_->{'name'} => $_ } @{ $stats->{'measure_names'} };
my @measure_names = sort keys %measure_name;
is_deeply(\@measure_names, [qw/steps weight/],
	'ts, timestamp and server_time are the entry clock, not measures in the table');
is($measure_name{'steps'}->{'unit'}, '', 'a measure without a unit says so');
is($measure_name{'weight'}->{'unit'}, 'lb', 'a measure keeps the unit the app declares it in');

# ---------------------------------------------------------------- the pace
# A reading is a period still running, so its pace is the same rate carried to
# the period's end: one count at noon projects two for the day, an hour two
# hours, ten dollars twenty. A sum measure paces the same way; an average has
# no rate to carry.
my $today_elapsed = $p{'today'}->{'elapsed'};
cmp_ok(abs($today_elapsed - 0.5), '<', 1e-9, 'noon is half way through the day');
cmp_ok(abs($p{'today'}->{'projected'}->{'count'} - 2), '<', 1e-9,
	'one count by noon projects two for the day');
cmp_ok(abs($p{'today'}->{'projected'}->{'duration'} - 7200000), '<', 0.5,
	'an hour by noon projects two hours');
cmp_ok(abs($p{'today'}->{'projected'}->{'money'} - 20), '<', 1e-9,
	'ten by noon projects twenty for the day');
cmp_ok(abs($p{'today'}->{'measures'}->{'steps'}->{'projected'} - 2000), '<', 1e-6,
	'a sum measure carries its pace');
ok(!defined $p{'today'}->{'measures'}->{'weight'}->{'projected'},
	'an average measure has no pace');
my (undef, undef, $week_elapsed) = &subs::period_bounds('week', $now, 0);
cmp_ok(abs($p{'week'}->{'elapsed'} - $week_elapsed), '<', 1e-12,
	'the week reads the elapsed share its own window gives');
cmp_ok(abs($p{'week'}->{'projected'}->{'count'} - 3 / $week_elapsed), '<', 1e-9,
	'the week carries its count to the end of the week');
is($p{'today'}->{'progress'}, '50', 'the progress says the share the pace was read at');
my $series = &subs::measure_series(0);
is_deeply([ sort keys %{ $series->{'walk'} } ], [qw/steps weight/],
	'the same clock fields are left out of the per-day series');

# the measure list under an appointment's details is the other place the entry
# clock surfaced: the same fields are not rows there either
my $measure_details = Mojo::Template->new(vars => 1, auto_escape => 1)->render(
	scalar read_file("$root/templates/apps/app_measure_details.html.ep"),
	{
		l => { measures => [ {
			steps => 5, weight => 170,
			ts => 1000, timestamp => 1000, server_time => 1000, uuid => 'm1',
		} ] },
	},
);
like($measure_details, qr/>Steps</, 'the measure list still shows a reading');
unlike($measure_details, qr/Timestamp|Server time|>Ts</,
	'the measure list does not show the fields the entry was filed under');

is(scalar @{ $stats->{'inventory'}->{'units'} }, 1, 'one unit is held');
is($stats->{'inventory'}->{'units'}->[0]->{'in'}, 16, 'the shelf counts what came in');
is($stats->{'inventory'}->{'units'}->[0]->{'out'}, 6, 'the shelf counts what went out');
is($stats->{'inventory'}->{'units'}->[0]->{'on_hand'}, 10, 'the shelf level is in minus out');
is($stats->{'inventory'}->{'units'}->[0]->{'unit'}, 'g', 'the unit is the shelf unit');
cmp_ok(abs($stats->{'inventory'}->{'units'}->[0]->{'days_left'} - 75), '<', 1e-9,
	'ten on hand at the last 30 days pace lasts seventy-five days');
is($stats->{'inventory'}->{'units'}->[0]->{'stock_state'}, 'urgent',
	"the app's own urgent line colours the reading red");

# the shelf's movements inside each period, kept per unit, with the out carried
# to the period's end at the same pace the other tables read
my $shelf_periods = $stats->{'inventory'}->{'periods'};
is(scalar @{$shelf_periods}, 1, 'one unit gives one period table');
is($shelf_periods->[0]->{'unit'}, 'g', 'the period table names its unit');
my %ip = map { $_->{'key'} => $_ } @{ $shelf_periods->[0]->{'rows'} };
is_deeply([ map { $_->{'key'} } @{ $shelf_periods->[0]->{'rows'} } ], [qw/today week month year/],
	'the period rows come in the house order');
is($ip{'today'}->{'in'}, 10, 'today counts the ten that came in today');
is($ip{'today'}->{'out'}, 0, 'and nothing went out today');
is($ip{'week'}->{'in'}, 16, 'the week adds the six from Tuesday');
is($ip{'month'}->{'out'}, 4, 'the month holds the four that went out on the first');
is($ip{'year'}->{'out'}, 6, 'the year holds both draws');
cmp_ok(abs($ip{'today'}->{'pace'} - 0), '<', 1e-9, 'a day with no out paces at zero');
cmp_ok(abs($ip{'month'}->{'pace'} - 4 / $p{'month'}->{'elapsed'}), '<', 1e-9,
	'the month carries its out to the month end');
cmp_ok(abs($ip{'year'}->{'pace'} - 6 / $p{'year'}->{'elapsed'}), '<', 1e-9,
	'the year carries its out to the year end');

# grams and millilitres are kept apart: each shelf unit gets its own period rows
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk_two', 'g', '5', 'stock', ts(2026, 11, 7, 10));
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk_two', 'ml', '-20', 'stock', ts(2026, 11, 7, 11));
my $two_units = &subs::appointment_statistics_for('walk_two', $now);
my $groups = $two_units->{'inventory'}->{'periods'};
is(scalar @{$groups}, 2, 'each shelf unit gets its own period table');
is_deeply([ map { $_->{'unit'} } @{$groups} ], [qw/g ml/], 'the units come in shelf order');
is($groups->[0]->{'rows'}->[0]->{'in'}, 5, 'the grams keep their own in');
is($groups->[1]->{'rows'}->[0]->{'out'}, 20, 'the millilitres keep their own out');
ok(!defined $two_units->{'inventory'}->{'units'}->[0]->{'days_left'},
	'a unit with no draw has no days-left reading');
is($two_units->{'inventory'}->{'units'}->[1]->{'days_left'}, 0,
	'a shelf already spent reads zero days left');
is($two_units->{'inventory'}->{'units'}->[1]->{'stock_state'}, 'urgent',
	'a spent shelf is urgent');

# with no settings the house defaults hold: seven days is amber, two is red
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk_low', 'l', '24', 'stock', ts(2026, 11, 7, 10));
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk_low', 'l', '-20', 'stock', ts(2026, 11, 7, 11));
my $low = &subs::appointment_statistics_for('walk_low', $now);
is($low->{'inventory'}->{'units'}->[0]->{'days_left'}, 6, 'four on hand at a two-thirds-a-day draw lasts six days');
is($low->{'inventory'}->{'units'}->[0]->{'stock_state'}, 'low',
	'the default seven days turns days left amber');

# the shopping list reads the same shelf: an item inside its low days is due
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk_fine', 'g', '100', 'stock', ts(2026, 11, 7, 9));
$db->query('insert into warehouse (item, unit, quantity, kind, timestamp) values (?,?,?,?,?)', 'walk_fine', 'g', '-20', 'stock', ts(2026, 11, 7, 10));
require "$root/lib/JawnOS/Manager/Part05.pm";
is(Manager::market_item_due('walk_fine', $now), 0, 'a shelf with plenty left is not due');
is(Manager::market_item_due('walk_low', $now), 1, 'a shelf inside its low days is due');
is(Manager::market_item_due('walk', $now), 1, "a shelf inside its own urgent line is due");
is(Manager::market_item_due('nothing_here', $now), 0, 'an item with no shelf is not due');
my $low_detail = Manager::market_item_due_detail('walk_low', $now);
is($low_detail->{'due'}, 1, 'the low shelf is due with its reason');
is($low_detail->{'reason'}, 'days', 'and the reason is the runway');
is($low_detail->{'days_left'}, 6, 'the runway carries the days the shelf has left');
is(Manager::market_item_due_detail('walk_fine', $now)->{'reason'}, '',
	'a well-stocked shelf has no due reason');
{
	no warnings 'redefine';
	*Manager::budget_calculator = sub {
		my ($d) = @_;
		return $d->{'app'} eq 'walk_budget'
			? { fixed => 1, circumstance => 'quantity', budgeted => 6, value => 2 }
			: undef;
	};
}
my $budget_detail = Manager::market_item_due_detail('walk_budget', $now);
is($budget_detail->{'due'}, 1, 'a shelf below its keep level is due');
is($budget_detail->{'reason'}, 'budget', 'and the reason is the keep level');

my $empty = &subs::appointment_statistics_for('nothing_here', $now);
is($empty->{'periods'}->[0]->{'count'}, 0, 'an app with no rows reads zero');
is($empty->{'periods'}->[0]->{'projected'}->{'count'}, 0, 'and paces at zero');
is(scalar @{ $empty->{'inventory'}->{'units'} }, 0, 'and holds no stock');
is(scalar @{ $empty->{'inventory'}->{'periods'} }, 0, 'and has no shelf period rows');

# ------------------------------------------------------------- the template
my $wrapper = read_file("$root/templates/appointment_wrapper.html.ep");
like($wrapper, qr/class="appointment_stats_headers"/, 'the bottom line has its own header row');
foreach my $name ( qw/Evaluation Inv Time Count Meas/ ) {
	like($wrapper, qr/&subs::ui\('\Q$name\E'\)/, "the $name header is there");
}
like($wrapper, qr/stat="money"[^>]*>\$</, 'the money header is the dollar sign');
like($wrapper, qr/\.appointment_stats_headers \{[^}]*flex-wrap: nowrap/, 'the headers never wrap to a second row');
like($wrapper, qr/class="appointment_stats_panel appointment_evaluation_zone"/,
	'the evaluation moved into the bottom line');
like($wrapper, qr/include 'apps\/evaluation'/, 'and it still draws the report');
like($wrapper, qr/class="app_section_placeholder" app="<%= \$a %>" section="stats"/,
	'the readings are left to a lazy placeholder');
unlike($wrapper, qr/class="appointment_stats_panel" stat="inv"/,
	'the wrapper does not draw the readings panels');

my $stats_template = read_file("$root/templates/apps/appointment_stats.html.ep");
foreach my $stat ( qw/inv time count money meas/ ) {
	like($stats_template, qr/stat="\Q$stat\E"/, "the $stat panel is in the fetched partial");
}
my $pace_html = Mojo::Template->new(vars => 1, auto_escape => 1)->render(
	scalar $stats_template,
	{
		app => 'walk',
		app_stats => {
			item => 'walk',
			inventory => { units => [ { unit => 'g', in => 10, out => 4, on_hand => 6, days_left => 75, stock_state => 'low' } ], periods => [{
				unit => 'g',
				rows => [ { key => 'today', label => 'Today', in => 10, out => 4, pace => 8 } ],
			} ] },
			periods => [ {
				key => 'today', label => 'Today',
				duration => 3600000, count => 1, money => 10,
				elapsed => 0.5, progress => '50',
				projected => { duration => 7200000, count => 2, money => 20 },
				measures => {
					steps => { value => 1000, calc => 'sum', unit => '', projected => 2000 },
					weight => { value => 170, calc => 'average', unit => 'lb' },
				},
			} ],
			measure_names => [
				{ name => 'steps', unit => '', calc => 'sum' },
				{ name => 'weight', unit => 'lb', calc => 'average' },
			],
		},
	},
);
like($pace_html, qr/<tr class="appointment_stats_pace"><td>Pace <span class="appointment_stats_calc">by the end<\/span><\/td><td>2h<\/td>/,
	'the time table carries the hour to the day end');
like($pace_html, qr/<tr class="appointment_stats_pace"><td>Pace <span class="appointment_stats_calc">by the end<\/span><\/td><td>2<\/td>/,
	'the count table carries one occurrence to two');
like($pace_html, qr/<tr class="appointment_stats_pace"><td>Pace <span class="appointment_stats_calc">by the end<\/span><\/td><td>\$20\.00<\/td>/,
	'the money table carries ten dollars to twenty');
like($pace_html, qr/<tr class="appointment_stats_pace"><td>Pace <span class="appointment_stats_calc">by the end<\/span><\/td><td>2000<\/td>/,
	'the summed measure carries its pace');
like($pace_html, qr/<tr class="appointment_stats_pace"><td>Pace <span class="appointment_stats_calc">by the end<\/span><\/td><td>-<\/td>/,
	'an averaged measure has no pace to carry');
like($pace_html, qr/<th>g<\/th>.*?<td>Today<\/td>\s*<td>10<\/td>\s*<td>4<\/td>\s*<td>8<\/td>/s,
	'the inventory period row shows in, out and the out pace');
like($pace_html, qr/<td>g<\/td>\s*<td>10<\/td>\s*<td>4<\/td>\s*<td>6<\/td>\s*<td class="appointment_stats_days_low">75<\/td>/,
	'the shelf row shows the days of stock left in its warning colour');
my $abilities_src = read_file("$root/perl/gb/05_abilities_and_studio.pl");
like($abilities_src, qr/low_stock_days/, 'the app panel offers a Low stock days setting');
like($abilities_src, qr/urgent_stock_days/, 'and an Urgent stock days setting');
like($wrapper, qr/\.appointment_stats_days_low/, 'the low reading has its amber rule');
like($wrapper, qr/\.appointment_stats_days_urgent/, 'and the urgent reading its red rule');
my $market_html = Mojo::Template->new(vars => 1, auto_escape => 1)->render(
	scalar read_file("$root/templates/market/market.html.ep"),
	{
		list => [
			{ uuid => 'u1', text => 'milk', kind => 'need', due => 1, due_reason => 'days', due_days => 3 },
			{ uuid => 'u2', text => 'eggs', kind => 'need', due => 1, due_reason => 'budget' },
			{ uuid => 'u3', text => 'bread', kind => 'want', due => 0 },
		],
		vendors => [], vendor => '', lists => {}, nearby => [], receipts => [], scan_feeds => [],
	},
);
like($market_html, qr/- due - 3 days left/, 'the market row shows the runway beside due');
like($market_html, qr/- due - below keep level/, 'and names the keep level when that is the rule');
like($market_html, qr/>Need - 3 days left</, 'the shopping tab badge carries the runway');
like($market_html, qr/>Need - below keep level</, 'and the keep level');
my $section_controller = read_file("$root/lib/JawnOS/Controller/manager_misc.pm");
like($section_controller, qr/template => 'apps\/appointment_stats'/,
	'the app_section route draws the readings from the lazy partial');

foreach my $pair ( [ 'Ago', 'ago' ], [ 'Duration', 'duration' ], [ 'Quantity', 'quantity' ], [ 'Warranty', 'warranty' ], [ 'Note', 'note' ] ) {
	like($wrapper, qr/placeholder="<%= &subs::ui\('\Q$pair->[0]\E'\) %>"/,
		"the $pair->[1] placeholder starts with a capital");
}
unlike($wrapper, qr{</div>\s*<br>\s*<textarea class="timed_input notes"},
	'the note follows the schedule row without an empty line between them');
unlike($wrapper, qr/medium_thumb/, 'the state buttons are all little_thumb');

# ----------------------------------------------------------- the live hints
my $app_back = read_file("$root/public/js/manager/manager/09_app_back.js");
like($app_back, qr/jawnosTimePreviewPaintApp\(app\)/,
	'a save asks the ago and warranty readings again');
like($app_back, qr/\.on\('click', '\.appointment_stats_header'/,
	'a bottom-line header chooses its panel');
like($app_back, qr/appSectionGrabber\(app, 'stats'/,
	'the first press fetches the readings');
like($app_back, qr/function appointmentStatsShow\(/,
	'one helper turns the selected header and its panel');
like($app_back, qr/function appointmentStatsReload\(/,
	'a loaded panel has one reload path');
like($app_back, qr/function appointmentStatsRemember\(/,
	'a chosen reading has one place that remembers it');
like($app_back, qr/function appointmentStatsRemembered\(/,
	'and one place that reads it back');
like($app_back, qr/function appointmentStatsRestore\(/,
	'a window that is drawn puts its reading back');
like($app_back, qr/localStorage\.setItem\('appointment_stats_' \+ app/,
	'the reading is kept per app in this browser');
like($app_back, qr/appointmentStatsRemember\(stats\.attr\('app'\) \|\| '', stat\)/,
	'pressing a header saves that header for the app');
like($app_back, qr/appointmentStatsRemembered\(stats\.attr\('app'\)/,
	'the restore asks the same app what it last read');
my $windows = read_file("$root/public/js/manager/windows.js");
like($windows, qr/appointmentStatsRestore\(win\)/,
	'the window manager restores the reading when it draws the window');
like($app_back, qr/appointmentStatsReload\(app\);/,
	'a save reloads the readings');
my ($stats_reload) = $app_back =~ /(function appointmentStatsReload\(app\) \{.*?\n\})/s;
ok($stats_reload, 'the reload helper is one function');
like($stats_reload, qr/holder\.removeAttr\('loaded'\)\.empty\(\)/,
	'the old snapshot is dropped before the new read');
like($stats_reload, qr/appointmentStatsOpen\(stats, stat\)/,
	'a panel that is showing is fetched again in place');
like($stats_reload, qr/if \(stat === 'evaluation' \|\| !stat\) \{ return; \}/,
	'an evaluation view only drops the snapshot for the next press');

my ($stats_open) = $app_back =~ /(function appointmentStatsOpen\(stats, stat\) \{.*?\n\})/s;
ok($stats_open, 'the open helper is one function');
like($stats_open, qr/holder\.attr\('loading'\) === 'yes'/,
	'a press during a fetch does not start a second one');
like($stats_open, qr/stats\.attr\('stats_wanted', stat\)/,
	'the last pressed header is remembered for the answer');
like($stats_open, qr/var wanted = stats\.attr\('stats_wanted'\) \|\| stat;/,
	'the answer opens the last header pressed');
like($stats_open, qr/jawnosT\('Loading…'\)/,
	'the loading line is translated');
like($stats_open, qr/appointmentStatsShow\(stats, stat\)/,
	'the pressed header is selected while it loads');
like($wrapper, qr/\[loading="yes"\]::before/,
	'the placeholder shows a loading line');
like($wrapper, qr/content: attr\(data-loading-text\)/,
	'the line takes its words from the request');

my $messages = read_file("$root/public/js/manager/websocket/01_message_handler.js");
like($messages, qr/jawnosTimePreviewPaintApp\(app\)/,
	'a pushed header asks the readings again, so start moves them to now');

done_testing();
