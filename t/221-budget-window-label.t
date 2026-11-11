# tests-for: lib/JawnOS/Domain/Budget.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Part19.pm templates/apps/budget_current_information.html.ep public/js/manager/budget_light.js lib/JawnOS/Controller/manager_misc13.pm perl/help/topics_features.pl perl/help/topics_functions.pl
# covers:    the budget panel's window label - calendar or rolling - the label click that flips s_lock, and a reading held on a status threshold

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::Template;
use JawnOSTest;
use RepoSource;

my $root = repo_root();

# --------------------------------------------------------------- the label
# A locked budget names the calendar period its scope names; an unlocked one
# names the length it rolls back from now, so the panel cannot call a rolling
# window "this week".
my ($label, $phrase) = &subs::budget_window_label(
	{ scope_name => 'week', duration => 7 * 86400000, fixed => 0 }, 1);
is($label, 'This Week', 'a locked week reads as the calendar week');
is($phrase, 'Week', 'and its phrase is the scope word');

($label, $phrase) = &subs::budget_window_label(
	{ scope_name => 'week', duration => 7 * 86400000, fixed => 0 }, 0);
is($label, 'Last 7 days', 'an unlocked week names the length it rolls back');
is($phrase, 'last 7 days', 'and its phrase says last');

($label) = &subs::budget_window_label(
	{ scope_name => 'day', duration => 86400000, fixed => 0 }, 0);
is($label, 'Last 1 day', 'one day is singular');

($label) = &subs::budget_window_label(
	{ scope_name => 'hour', duration => 3600000, fixed => 0 }, 0);
is($label, 'Last 1 hour', 'an hour rolls back as an hour');

($label) = &subs::budget_window_label(
	{ scope_name => 'month', duration => 2591999449, fixed => 0 }, 0);
is($label, 'Last 30 days', 'a month reads as the days it holds');

($label) = &subs::budget_window_label(
	{ scope_name => 'month', duration => 30 * 86400000, fixed => 1 }, 0);
is($label, 'This Month', 'a fixed level keeps its calendar name');

# ------------------------------------------------------------ the template
my $template = read_file("$root/templates/apps/budget_current_information.html.ep");
my $html = Mojo::Template->new(vars => 1, auto_escape => 1)->render($template, {
	app => 'walk', circumstance => 'duration', running => 0,
	locked => 0, window_label => 'Last 7 days', window_phrase => 'last 7 days',
	budget => {
		scope_name => 'week', duration => 7 * 86400000, fixed => 0, status => 'budgeted',
		value => 0, budgeted => 0, formatted_value => 0, formatted_budgeted => '0/week',
		elapsed => 1, colour => 'green',
	},
	improvement => {
		share => 1, difference => 0, overall_value => 0, overall => 0,
		formatted_difference => '0', percentage => '0%', overall_percentage => '0%',
	},
	autocalc => { data => { app => 'walk', timestamp => 0 }, week => { result => 0, formatted_result => '0/week' } },
	goal => undef,
});
like($html, qr/Last 7 days/, 'the panel shows the rolling label');
like($html, qr/class="budget_lock_toggle"[^>]*app="walk"[^>]*circumstance="duration"[^>]*locked="0"/,
	'the label is the toggle, carrying the app, the circumstance and the lock side');

# ------------------------------------------------------- the click and write
my $js = read_file("$root/public/js/manager/budget_light.js");
like($js, qr/\.on\('click',\s*'\.budget_lock_toggle'/, 'the core binds the window label');
like($js, qr/settingSetter\(\{\s*app:\s*app,\s*setting:\s*'s_lock'/, 'the press writes s_lock');

my $part19 = read_file("$root/lib/JawnOS/Manager/Part19.pm");
like($part19, qr/budget_window_label\(\$budget, \$locked\)/, 'the panel asks for the window label');
like($part19, qr/window_label => \$window_label/, 'and hands it to the template');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc13.pm");
like($controller, qr/\$setting eq 's_lock'.*?budget_runner/s,
	'an s_lock write recomputes the budget, so the light and panel are pushed');

# ------------------------------------------------- a reading on a threshold
# One clock for the two period lengths: the budget's own month and the column
# asked for name the same span, so they must be the same number. Translating
# each from its own rightNow() made them differ by a millisecond, which also
# turned same_width false and the reading stopped being the budget's own period.
{
	my $at = ts(2027, 2, 1, 12, 0, 0);   # a month that is not a fixed 30 days
	my $appts = [ { app => 'trim_beard', timestamp => $at - 3 * 86400000, type => 'stop', duration => -300000 } ];
	my $reading = &subs::budget_calculator({
		app => 'trim_beard', circumstance => 'occurences', scope => '1month',
		budget => '2/1month', settings => { s_lock => 'off', s_calc => 'sum' },
		timestamp => $at, appts => $appts,
	});
	is($reading->{'duration'}, &subs::time_abbrev_translator('1month', $at),
		'the period length is read at the request\'s moment, not a later wall clock');
	is($reading->{'duration'}, $reading->{'scope'}, 'the budget and the column measure one span');
	is($reading->{'is_scope'}, 'yes', 'and the reading is the budget\'s own period');
	is($reading->{'value'}, 1, 'the rolling month holds the one session');
	is($reading->{'status'}, 'neglected', 'a reading at exactly half the target is neglected');
}

# Exactly on a threshold, the threshold's own inclusive direction decides. These
# month lengths used to round a hair above the half, so the same reading
# alternated between neglected and achievable and every flip was announced.
for my $p (2591999019, 2591999021, 2591999023, 2591999025, 2591999027) {
	my $status = &subs::budget_status_maker({
		expected => sprintf('%.19f', 2 / $p),
		actual   => sprintf('%.19f', 1 / $p),
	});
	is($status->{'status'}, 'neglected', "half the target reads as neglected at a $p ms period");
}

{
	my $expected = 0.0000000007716049832;   # any positive per-millisecond rate
	for my $case ( [ .80, 'budgeted' ], [ 1, 'accomplished' ], [ 1.2, 'burnt out' ],
		[ 2, 'overkill' ], [ .25, 'abandoned' ], [ .5, 'neglected' ], [ .6, 'achievable' ] ) {
		my ($share, $want) = @{$case};
		my $status = &subs::budget_status_maker({ expected => $expected, actual => $expected * $share });
		is($status->{'status'}, $want, sprintf('a reading at %.2f of the target reads as %s', $share, $want));
	}
}

# ---------------------------------------------------------------- the help
like(read_file("$root/perl/help/topics_features.pl"),
	qr/window named beside a reading can be pressed/,
	'the appointment help names the switch');

done_testing();
