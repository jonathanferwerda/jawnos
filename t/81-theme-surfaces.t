# tests-for: public/css/manager.css public/js/manager/tasks.js templates/
# covers:    Two surfaces painted themselves with a colour picked for a light desktop and stayed that way on a dark one: a ...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Two surfaces painted themselves with a colour picked for a light desktop and
# stayed that way on a dark one: a task row's own colour (an inline
# background-color) and the ledger's rows and budget cells (also inline). In
# dark_theme the ink follows the theme, so the figures were light text on a
# light fill, and the task admin block under the list (Sort, Filter, totals)
# came back glaring after every save.
#
# The root fix is the same for both: the colour is carried as a custom property
# (--task-colour, --budget-colour) instead of an inline background-color, so
# manager.css owns the fill and can lay a dark wash over the user's hue. These
# checks pin that shape, so neither surface can quietly go back to an inline
# light face - including the re-render path that rebuilds the task list.

my $root  = repo_root();
my $css   = read_file("$root/public/css/manager.css");
my $tasks = read_file("$root/templates/apps/tasks.html.ep");
my $js    = js_source('public/js/manager/tasks.js');
my $ledger = read_file("$root/templates/budget/statement.html.ep");

# --- tasks: the colour is a variable, not an inline face -------------------
like($tasks, qr/--task-colour:<%= \$task->\{'colour'\} %>/,
	'the task row carries its colour as --task-colour');
unlike($tasks, qr/background-color:<%= \$task->\{'colour'\} %>/,
	'no task row paints an inline background-color any more');
like($tasks, qr/task_item_new/, 'the new-task row is told apart from a real task');
like($tasks, qr/class="task_admin_table"/, 'the Sort/Filter table has a scoped class');
like($tasks, qr/class="task_settings_table"/, 'the renewal/budget table has a scoped class');
like($tasks, qr/background-color:var\(--panel-2\)/, 'the task name chip takes the theme surface');

# --- tasks: the re-render path carries the theme, not inline styles --------
like($js, qr/addClass\('task_list_busy'\)/, 'a save dims the list by class, not by inline styles');
unlike($js, qr/opacity': '0\.5'/, 'the JS no longer writes the dim as an inline opacity');
unlike($js, qr/'filter': 'grayscale\(1\)'/, 'the JS no longer writes the dim as an inline filter');

like($css, qr/\.task_list\.task_list_busy \{[^}]*pointer-events: none/,
	'the busy state is styled by the sheet');
like($css, qr/\.task_item \{\s*background-color: var\(--task-colour, var\(--panel-2\)\)/,
	'a task row takes the task colour or the control surface');
like($css, qr/\.task_item \{[^}]*color: var\(--ink\)/s, 'task rows use the theme ink');
like($css, qr/\.task_item \{[^}]*border-color: var\(--line\)/s, 'task rows use the theme line');
like($css, qr/body\.dark_theme \.task_item \{[^}]*background-image: linear-gradient\(rgba\(27, 29, 33, \.80\)/s,
	'a dark theme lays a wash over the task colour instead of leaving it glaring');
like($css, qr/body\.dark_theme \.task_item_new \{[^}]*background-color: var\(--panel-2\)/s,
	'the admin row is the theme surface in a dark theme');
like($css, qr/\.task_admin_table, \.task_settings_table \{[^}]*background-color: var\(--panel\)/s,
	'the task tables sit on the panel surface');
like($css, qr/\.task_admin_table, \.task_settings_table \{[^}]*color: var\(--ink\)/s,
	'and the text in them is the theme ink');

# --- accounting: the ledger uses the same contract -------------------------
like($ledger, qr/class="budget_ledger"/, 'the ledger table has a scoped class');
like($ledger, qr/--budget-colour:<%= \$tally/,
	'ledger rows carry their colour as --budget-colour');
unlike($ledger, qr/background-color:<%= \$tally/,
	'no ledger row or cell paints an inline background-color any more');
like($ledger, qr/class="budget_cell"/, 'the coloured budget cells are scoped');

like($css, qr/\.budget_row, \.budget_detail_row, \.budget_cell \{\s*background-color: var\(--budget-colour/s,
	'ledger rows and cells take their own colour, or none');
like($css, qr/\.budget_row, \.budget_detail_row, \.budget_cell \{[^}]*color: var\(--ink\)/s,
	'the ledger reads in the theme ink');
like($css, qr/body\.dark_theme \.budget_row,\s*body\.dark_theme \.budget_detail_row,\s*body\.dark_theme \.budget_cell \{[^}]*background-image: linear-gradient\(rgba\(27, 29, 33, \.82\)/s,
	'a dark theme washes the ledger fill so the figures stay readable');

done_testing();
