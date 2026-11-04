# tests-for: lib/JawnOS/Manager/Part19.pm lib/JawnOS/Controller/manager_budget.pm templates/budget/runway.html.ep public/js/manager/budget/02_runway.js public/js/manager/budget.js public/css/manager.css public/css/universal.css perl/help/topics_people.pl
# covers:    the Runway view: its calendar buckets, the projection that adds promised money to the trailing pace, the date the balance crosses the floor, and the chart a click opens a period from.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;
use JawnOSTest;

my $ROOT = repo_root();
require "$ROOT/lib/JawnOS/Manager/Part19.pm";

# The Runway view reads the money ledger backwards over whole periods to get a
# pace, then forward over what has been promised to get a date. The calendar and
# the walk are pure, so they are exercised here without a database; the wiring
# that shows them (the display, the partial, the chart and its click) is pinned
# by source checks at the end.

my $day = 86400000;

# --- the calendar sits on the house's own boundaries ------------------------
is(JawnOSTest::ymd(Manager::accounting_runway_bucket_start('day', ts(2026, 11, 4, 15, 30))),
	'2026-11-04', 'a day starts at local midnight');
# 2026-11-04 is a Wednesday; the budget windows count weeks from Sunday
is(JawnOSTest::ymd(Manager::accounting_runway_bucket_start('week', ts(2026, 11, 4, 15, 30))),
	'2026-11-01', 'a week starts on the Sunday before it');
is(JawnOSTest::ymd(Manager::accounting_runway_bucket_start('month', ts(2026, 11, 4))),
	'2026-11-01', 'a month starts on its first');
is(JawnOSTest::ymd(Manager::accounting_runway_bucket_start('quarter', ts(2026, 11, 4))),
	'2026-10-01', 'November belongs to the quarter that opened in October');
is(JawnOSTest::ymd(Manager::accounting_runway_bucket_start('year', ts(2026, 11, 4))),
	'2026-01-01', 'a year starts on its first');

is(JawnOSTest::ymd(Manager::accounting_runway_step(ts(2026, 11, 1), 'month', 1)),
	'2026-12-01', 'a month step crosses the calendar, not thirty days');
is(JawnOSTest::ymd(Manager::accounting_runway_step(ts(2026, 10, 1), 'quarter', 1)),
	'2027-01-01', 'a quarter step is three months');
is(JawnOSTest::ymd(Manager::accounting_runway_step(ts(2026, 11, 1), 'week', 1)),
	'2026-11-08', 'a week step is seven days');

# --- the reading the buttons show ------------------------------------------
is_deeply(Manager::accounting_runway_units(), [qw(day week month quarter year)],
	'the five readings are the five buckets');
is(Manager::accounting_runway_shape('day')->{'back'}, 14, 'a day reads two weeks back');
is(Manager::accounting_runway_shape('year')->{'ahead'}, 5, 'a year reads five years ahead');
is(Manager::accounting_runway_shape('nonsense')->{'back'}, 12,
	'an unknown reading falls back to months rather than failing');

{
	my $bounds = Manager::accounting_runway_edges('month', ts(2026, 11, 4), 2, 2);
	my @edges = @{ $bounds->{'edges'} };
	is(scalar @edges, 6, 'two back, this one, two ahead: six boundaries');
	is(JawnOSTest::ymd($edges[0]), '2026-09-01', 'the window opens two months back');
	is(JawnOSTest::ymd($edges[-1]), '2027-02-01', 'and closes two months on');
	is(Manager::accounting_runway_slot(\@edges, ts(2026, 11, 4)), 2, 'now is in the third bucket');
	is(Manager::accounting_runway_slot(\@edges, ts(2026, 9, 1)), 0, 'the first instant is in the first bucket');
	is(Manager::accounting_runway_slot(\@edges, ts(2025, 1, 1)), 0, 'a row before the window lands in the first');
	is(Manager::accounting_runway_slot(\@edges, ts(2030, 1, 1)), 4, 'a row after it lands in the last');
}

# --- the walk: a pace that burns, a floor it reaches -----------------------
{
	my $now = ts(2026, 11, 15);
	my $bounds = Manager::accounting_runway_edges('month', $now, 2, 3);
	my $runway = Manager::accounting_runway_steps({
		unit => 'month',
		now => $now,
		edges => $bounds->{'edges'},
		opening => 3000,
		reserve => 0,
		moves => [
			{ timestamp => ts(2026, 9, 10), total => -1000, movement => 'expense', app => 'store' },
			{ timestamp => ts(2026, 10, 10), total => -1000, movement => 'expense', app => 'store' },
			{ timestamp => ts(2026, 11, 2), total => 200, movement => 'income', app => 'work' },
			{ timestamp => ts(2026, 11, 3), total => -300, movement => 'expense', app => 'store' },
		],
		bills => [
			{ timestamp => ts(2026, 12, 5), total => 500, vendor => 'Landlord', app => 'home' },
		],
		owed => [ { timestamp => $now, total => 100 } ],
	});

	my @b = @{ $runway->{'buckets'} };
	is(scalar @b, 6, 'two past, this one, three ahead');
	is($b[0]->{'kind'}, 'past', 'September is behind us');
	is($b[1]->{'kind'}, 'past', 'October is behind us');
	is($b[2]->{'kind'}, 'current', 'November is now');
	is($b[3]->{'kind'}, 'future', 'December is ahead');

	is($b[0]->{'balance'}, 2000, 'September closes the opening 3000 less its 1000');
	is($b[1]->{'balance'}, 1000, 'October closes another 1000 down');
	is($b[2]->{'balance'}, 900, 'November is 200 in and 300 out');
	is($b[2]->{'actual_in'}, 200, 'the income is counted as in');
	is($b[2]->{'actual_out'}, -300, 'the expense keeps its negative sign');
	is($runway->{'balance'}, 900, 'the balance now is the walk’s own');
	is($runway->{'available'}, 900, 'with no floor set, all of it is available');

	# the pace is the mean of the two complete months behind, not of the part-month
	is($runway->{'pace'}, -1000, 'the pace is the mean net of the completed periods');
	is($b[3]->{'planned_net'}, -500, 'December carries its 500 bill');
	is($b[2]->{'owed'}, 100, 'money already owed lands on the period you are in');

	# the projection: the rest of this month at pace, then each period after it
	my $edges = $bounds->{'edges'};
	my $share = ($edges->[3] - $now) / ($edges->[3] - $edges->[2]);
	my $november = 900 + (-1000 * $share) - 100;
	is(sprintf('%.2f', $b[2]->{'projected_net'}), sprintf('%.2f', (-1000 * $share) - 100),
		'the rest of November at pace, less the money already owed');
	is(sprintf('%.2f', $b[2]->{'projected_balance'}), sprintf('%.2f', $november),
		'so November is projected to close part way down');
	is(sprintf('%.2f', $b[3]->{'projected_balance'}), sprintf('%.2f', $november - 1500),
		'December runs the balance under: the pace plus its bill');

	ok(defined $runway->{'runway_at'}, 'the projection runs out inside the window');
	ok($runway->{'runway_at'} > ts(2026, 12, 1), 'the money lasts into December');
	ok($runway->{'runway_at'} < ts(2026, 12, 31), 'but not to the end of it');
	cmp_ok($runway->{'runway_days'}, '>', 15, 'the runway is the days between now and that date');
	cmp_ok($runway->{'runway_days'}, '<', 46, 'and is less than a month and a half');

	# the same walk without the bills is the more hopeful reading, and is kept
	# beside the headline rather than replacing it
	ok(defined $runway->{'pace_at'}, 'the pace alone also crosses the floor');
	cmp_ok($runway->{'pace_at'}, '>', $runway->{'runway_at'},
		'the bills bring the date forward from the pace alone');

	is($runway->{'has_history'}, 1, 'two completed periods are a history to read');
}

# --- a house with no history is not given a guess --------------------------
{
	my $now = ts(2026, 11, 15);
	my $bounds = Manager::accounting_runway_edges('month', $now, 2, 2);
	my $runway = Manager::accounting_runway_steps({
		unit => 'month', now => $now, edges => $bounds->{'edges'},
		opening => 500, reserve => 0, moves => [], bills => [], owed => [],
	});
	is($runway->{'has_history'}, 0, 'a month with no movement is not a history');
	is($runway->{'pace'}, 0, 'and reads as a pace of nothing');
	ok(!defined $runway->{'runway_at'}, 'so no date is invented for the money running out');
}

# --- the floor is the accounts' own minimum --------------------------------
{
	my $now = ts(2026, 11, 15);
	my $bounds = Manager::accounting_runway_edges('month', $now, 1, 1);
	my $runway = Manager::accounting_runway_steps({
		unit => 'month', now => $now, edges => $bounds->{'edges'},
		opening => 700, reserve => 300,
		moves => [ { timestamp => ts(2026, 10, 10), total => -200, movement => 'expense' } ],
		bills => [], owed => [],
	});
	is($runway->{'balance'}, 500, 'the balance walks down from the opening');
	is($runway->{'available'}, 200, 'available is what is left above the floor');
	ok(defined $runway->{'runway_at'}, 'a burned pace still reaches a floor above zero');
	cmp_ok($runway->{'runway_at'}, '>', $now, 'and the date is ahead');
}

# --- an anchor re-states an account, as the ledger does --------------------
{
	my $now = ts(2026, 11, 15);
	my $bounds = Manager::accounting_runway_edges('month', $now, 1, 1);
	my $runway = Manager::accounting_runway_steps({
		unit => 'month', now => $now, edges => $bounds->{'edges'},
		opening => 1000, reserve => 0,
		moves => [ { timestamp => ts(2026, 10, 20), total => -100, movement => 'expense' } ],
		anchors => [ { timestamp => ts(2026, 10, 25), amount => 1250 } ],
		bills => [], owed => [],
	});
	is($runway->{'balance'}, 1250, 'the month closes at the anchor, not at the sum of the moves');
}

# --- the display, the partial, the chart and its click ---------------------
my $controller = read_file("$ROOT/lib/JawnOS/Controller/manager_budget.pm");
my $statement = read_file("$ROOT/templates/budget/statement.html.ep");
my $partial = read_file("$ROOT/templates/budget/runway.html.ep");
my $part = read_file("$ROOT/public/js/manager/budget/02_runway.js");
my $index = read_file("$ROOT/public/js/manager/budget.js");
my $css = read_file("$ROOT/public/css/manager.css");
my $universal = read_file("$ROOT/public/css/universal.css");
my $help = help_source();

like($controller, qr/\[ 'runway', &subs::ui\('Runway'\) \]/,
	'Runway is a choice in the display menu');
like($controller, qr/\$runway = &accounting_runway\(/,
	'the display reads the runway when it is chosen');
like($controller, qr/my \$period_start = \$c->param\('period_start'\);/,
	'a period named by a click is read from the request');
like($controller, qr/\$bt = \$period_start \+ 0;/,
	'and it wins over the scope for that render only');

like($statement, qr/include 'budget\/runway'/,
	'the runway is a partial of the statement, not more markup in it');
like($partial, qr/id="budget_runway_canvas"/, 'the runway draws on its own canvas');
like($partial, qr/class="runway_unit/, 'the five readings are on screen');
like($partial, qr/&subs::ui\('Available now'\)/, 'the headline names the money available');
like($partial, qr/&subs::ui\('Money lasts'\)/, 'and how long it lasts');
like($partial, qr/&subs::ui\('Promised'\)/, 'and what is already promised');

like($part, qr/function budgetRunwayWriter\(response\)/,
	'the chart is painted from the response the route rendered');
like($part, qr/\$\('#budget_runway_detail'\)\.html\(html\)\.show\(\)/,
	'a click shows the period in a panel under the chart');
like($part, qr/jawnosT\('Open this period'\)/,
	'and the panel offers the period as the window');
like($part, qr/budgetInit\(\{ display: 'statement', period: \{ start: start, end: end \} \}\)/,
	'which re-renders the Ledger on that window');
like($part, qr/settings\['runway_unit'\] = unit/,
	'a reading button changes the bucket and the view follows');

like($index, qr/budgetInit\(\{ period: \{ start: Math\.round\(stop\.start\), end: Math\.round\(stop\.end\) \} \}\)/,
	'a click on the statement chart opens the period it points at');
like($index, qr/ctx\.clearRect\(0, 0, wide, tall\)/,
	'the chart is cleared before it is drawn, so redraws do not stack');
like($index, qr/window\.devicePixelRatio/,
	'and is drawn at the screen’s own pixel ratio instead of stretched');
like($index, qr/getComputedStyle\(document\.body\)/,
	'the ink comes from the theme, not from black');
like($index, qr/function budgetTicks\(/, 'the balance axis is labelled in money');
like($index, qr/jawnosT\('Click to open this period'\)/,
	'the hover says what a click will do');
unlike($index, qr/console\.log/, 'and the chart no longer logs on every draw');

like($universal, qr/--runway-good:/, 'the two money directions are theme variables');
like($universal, qr/body\.dark_theme \{[^\n]*--runway-good:/,
	'with a dark-theme pair of their own');
like($css, qr/\.runway_canvas \{/, 'the runway canvas has a rule');
like($css, qr/\.runway_summary \{/, 'and so do its figures');
like($css, qr/#budget_account_information, #budget_runway_tip \{/,
	'both charts share one tooltip surface');

like($help, qr/Runway is the cash reading/,
	'the Accounting topic explains the Runway view');

done_testing();
