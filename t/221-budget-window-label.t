# tests-for: lib/JawnOS/Domain/Budget.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Manager/Part19.pm templates/apps/budget_current_information.html.ep public/js/manager/budget_light.js lib/JawnOS/Controller/manager_misc13.pm perl/help/topics_features.pl perl/help/topics_functions.pl
# covers:    the budget panel's window label - calendar or rolling - and the label click that flips s_lock

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

# ---------------------------------------------------------------- the help
like(read_file("$root/perl/help/topics_features.pl"),
	qr/window named beside a reading can be pressed/,
	'the appointment help names the switch');

done_testing();
