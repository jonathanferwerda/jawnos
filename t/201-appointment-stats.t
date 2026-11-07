# tests-for: lib/JawnOS/Domain/Appointment2.pm lib/JawnOS/Domain/Loader.pm templates/appointment_wrapper.html.ep public/js/manager/manager/09_app_back.js public/js/manager/websocket/01_message_handler.js
# covers:    the appointment's bottom line - shelf in/out, and time, count, money and measures for today/week/month/year

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
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
$db->query('create table warehouse (item text, unit text, quantity text, kind text, type text, account text)');
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
my $now    = ts(2026, 11, 7, 12, 0, 0);   # a Saturday, so the week began November 2
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
	return '[{"steps":"' . $steps . '","weight":"' . $weight . '","ts":"' . $at . '","uuid":"m' . $row_id . '"}]';
}

appt(ts(2026, 11,  7, 10), 3600000, 10, measure_json(ts(2026, 11,  7, 10), 1000, 170));   # today
appt(ts(2026, 11,  3, 10), 7200000, 20, measure_json(ts(2026, 11,  3, 10), 2000, 180));   # this week
appt(ts(2026, 11,  1, 10), 3600000,  5, measure_json(ts(2026, 11,  1, 10), 3000, 190));   # this month
appt(ts(2026,  2,  1, 10), 1800000,  7, measure_json(ts(2026,  2,  1, 10), 4000, 200));   # this year
appt(ts(2025, 12, 31, 10), 3600000, 99, measure_json(ts(2025, 12, 31, 10), 9000, 300));   # last year

foreach my $set ( [ 'measure_calc', 'sum', 'steps' ], [ 'measure_calc', 'average', 'weight' ] ) {
	$db->query('insert into settings (setting, value, app, device, subsetting, uuid, server_time) values (?,?,?,?,?,?,?)',
		$set->[0], $set->[1], 'walk', $device, $set->[2], 'set-' . $set->[2], $now);
}
$db->query('insert into settings (setting, value, app, device, uuid, server_time) values (?,?,?,?,?,?)',
	'app_measures', '{"steps":{"type":"number"},"weight":{"type":"number","unit":"lb"}}',
	'walk', $device, 'set-app-measures', $now);

# the shelf: two in, two out, one Usage row that must not count
$db->query('insert into warehouse (item, unit, quantity, kind) values (?,?,?,?)', 'walk', 'g', '10', 'stock');
$db->query('insert into warehouse (item, unit, quantity, kind) values (?,?,?,?)', 'walk', 'g', '6',  'stock');
$db->query('insert into warehouse (item, unit, quantity, kind) values (?,?,?,?)', 'walk', 'g', '-4', 'stock');
$db->query('insert into warehouse (item, unit, quantity, kind) values (?,?,?,?)', 'walk', 'g', '-2', 'stock');
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
is($p{'week'}->{'count'}, 2, 'this week adds its own row, not the month one');
is($p{'month'}->{'count'}, 3, 'this month adds the first of the month');
is($p{'year'}->{'count'}, 4, 'this year adds February and leaves last year out');

is($p{'today'}->{'duration'}, 3600000, 'today holds an hour');
is($p{'week'}->{'duration'}, 10800000, 'this week holds three hours');
is($p{'month'}->{'duration'}, 14400000, 'this month holds four hours');
is($p{'year'}->{'duration'}, 16200000, 'this year holds four and a half hours');

is($p{'today'}->{'money'}, 10, 'today holds its ten');
is($p{'week'}->{'money'}, 30, 'this week holds thirty');
is($p{'month'}->{'money'}, 35, 'this month holds thirty-five');
is($p{'year'}->{'money'}, 42, 'this year holds forty-two, not last year');

is($p{'today'}->{'measures'}->{'steps'}->{'calc'}, 'sum', 'steps read as a sum');
is($p{'today'}->{'measures'}->{'steps'}->{'value'}, 1000, 'today sums its steps');
is($p{'year'}->{'measures'}->{'steps'}->{'value'}, 10000, 'the year sums every step');
is($p{'today'}->{'measures'}->{'weight'}->{'calc'}, 'average', 'weight reads as an average');
is($p{'today'}->{'measures'}->{'weight'}->{'value'}, 170, 'today averages its weight');
is($p{'year'}->{'measures'}->{'weight'}->{'value'}, 185, 'the year averages every weight');
is($stats->{'measure_names'}->[0]->{'unit'}, '', 'a measure without a unit says so');
is($stats->{'measure_names'}->[1]->{'unit'}, 'lb', 'a measure keeps the unit the app declares it in');

is(scalar @{ $stats->{'inventory'}->{'units'} }, 1, 'one unit is held');
is($stats->{'inventory'}->{'units'}->[0]->{'in'}, 16, 'the shelf counts what came in');
is($stats->{'inventory'}->{'units'}->[0]->{'out'}, 6, 'the shelf counts what went out');
is($stats->{'inventory'}->{'units'}->[0]->{'on_hand'}, 10, 'the shelf level is in minus out');
is($stats->{'inventory'}->{'units'}->[0]->{'unit'}, 'g', 'the unit is the shelf unit');

my $empty = &subs::appointment_statistics_for('nothing_here', $now);
is($empty->{'periods'}->[0]->{'count'}, 0, 'an app with no rows reads zero');
is(scalar @{ $empty->{'inventory'}->{'units'} }, 0, 'and holds no stock');

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

my $messages = read_file("$root/public/js/manager/websocket/01_message_handler.js");
like($messages, qr/jawnosTimePreviewPaintApp\(app\)/,
	'a pushed header asks the readings again, so start moves them to now');

done_testing();
