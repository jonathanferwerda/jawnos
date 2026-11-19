# tests-for: public/js/manager/tasks.js public/js/manager/windows/05_effects.js public/css/manager.css
# covers:    a task ticked under the Open filter leaves the list the way a
#            window leaves the desk - the same fade, crumble or burst at the
#            device's Window Effects level, played on the row before the list
#            is rebuilt - while every other filter still swaps the row in place.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use RepoSource;

my $root = repo_root();
my $js    = js_source('public/js/manager/tasks.js');
my $effects = read_file("$root/public/js/manager/windows/05_effects.js");
my $css   = read_file("$root/public/css/manager.css");

# --- the row decides whether it is leaving -----------------------------------
like($js, qr/function taskLeavesOpenList\(item, container, name, value\)/,
	'the leaving test names the row, the list and the change');
like($js, qr/if \(name !== 'completed' \|\| value !== 'on'\) \{ return false; \}/,
	'only a tick of the completed box leaves');
like($js, qr/container\.find\('\.task_admin_input\[setting="filter"\]'\)\.val\(\)/,
	'the list\'s own Filter decides');
like($js, qr/\|\| ''\) === 'open'/,
	'and only the Open filter leaves the row out');
like($js, qr/container\.children\('\.task_list'\)[\s\S]*?item\.closest\('\.task_list'\)[\s\S]*?top\[0\] !== list\[0\]/,
	'a nested row is left alone: the filtered list is the only one that drops it');

# --- the farewell, then the rebuild -----------------------------------------
like($js, qr/var reopen = function\(\) \{\s*appointmentTaskReopener\(container,response\.html\);\s*ac\.scrollTop\(top\);/s,
	'the rebuild and the scroll wait for the farewell');
like($js, qr/if \(taskLeavesOpenList\(item, container, name, value\)\s*&& typeof jawnosWindowCloseEffect === 'function'\) \{\s*\/\/ the save has answered[^\n]*\n\s*container\.find\('\.task_list'\)\.removeClass\('task_list_busy'\);\s*if \(jawnosWindowCloseEffect\(item\[0\], reopen\)\) \{ return; \}/,
	'the save\'s answer clears the busy dim, then the row reuses the window-close effect');
like($js, qr/jawnosWindowCloseEffect\(item\[0\], reopen\)/,
	'the effect is handed the row and the rebuild');
like($js, qr/if \(jawnosWindowCloseEffect\(item\[0\], reopen\)\) \{ return; \}\s*\}\s*reopen\(\);/,
	'a desk that cannot play the close still rebuilds at once');

# --- the row plays the window's own close keyframes -------------------------
foreach my $name (qw(fade crumble burst)) {
	like($css, qr/\.task_item\.jawnos_effect_close_$name \{ animation: jawnos_window_close_$name calc\([^)]*var\(--je-time\)/,
		"a task row plays the $name close keyframes at the desk's own level");
}
like($css, qr/\.task_item\.jawnos_effect_close_crumble \{[^}]*cubic-bezier\(\.3,\.1,\.7,1\)/,
	'the crumble curve is the window\'s');
like($css, qr/\.task_item\.jawnos_effect_close_burst \{[^}]*cubic-bezier\(\.2,\.6,\.3,1\)/,
	'so is the burst curve');
like($css, qr/\.task_item\.jawnos_effect_close_fade \{[^}]*will-change: opacity/,
	'a fading row only asks the compositor for opacity');
like($css, qr/prefers-reduced-motion: reduce\) \{[\s\S]*\.task_item\.jawnos_effect_close_fade[\s\S]*?animation-duration: 1ms/,
	'reduced motion finishes a leaving row at once too');

# The pieces are appended to the body, outside the window's glass; a row with no
# z-index of its own must borrow its window's so they are not painted under it.
like($effects, qr/closest\('\.wind'\)[\s\S]*?closest\('#browser'\)[\s\S]*?host > z[\s\S]*?box\.style\.zIndex = z \+ 1/,
	'a row inside a window borrows the window\'s level for its pieces');

# --- the decision itself, played --------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to play the task decision', 1 unless $node && -x $node;

	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
'use strict';
const fs = require('fs');
const vm = require('vm');

// tasks.js registers its handlers on load; the fake $ only has to let that
// happen. The decision is a plain function and is called directly.
const sandbox = {
	$: function () { return { on: function () { return this; }, length: 0 }; },
	window: {},
	document: {},
	console
};
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(process.argv[2], 'utf8'), sandbox);

function jq(items) {
	const j = { length: items.length };
	items.forEach(function (v, i) { j[i] = v; });
	return j;
}
// A row whose nearest .task_list is the one given.
function row(list) {
	return { length: 1, 0: {}, closest: function () { return jq([list]); } };
}
// The .re_tasks box: its direct .task_list is the filtered one, and the Filter
// select answers with the given value (undefined for a nested list with none).
function box(top, filter) {
	return {
		length: 1,
		0: {},
		children: function () { return jq([top]); },
		find: function () { return { val: function () { return filter; } }; }
	};
}

let failures = 0;
function check(name, cond) {
	if (!cond) { failures++; console.log('not ok - ' + name); }
	else { console.log('ok - ' + name); }
}

const top = {};
const child = {};
check('a tick in the Open list leaves',
	sandbox.taskLeavesOpenList(row(top), box(top, 'open'), 'completed', 'on') === true);
check('an un-tick stays',
	sandbox.taskLeavesOpenList(row(top), box(top, 'open'), 'completed', 'off') === false);
check('another field stays',
	sandbox.taskLeavesOpenList(row(top), box(top, 'open'), 'priority', 'on') === false);
check('All keeps the row',
	sandbox.taskLeavesOpenList(row(top), box(top, 'all'), 'completed', 'on') === false);
check('Done keeps the row',
	sandbox.taskLeavesOpenList(row(top), box(top, 'done'), 'completed', 'on') === false);
check('a list with no Filter row keeps the row',
	sandbox.taskLeavesOpenList(row(top), box(top, undefined), 'completed', 'on') === false);
check('a nested row is not the filtered list',
	sandbox.taskLeavesOpenList(row(child), box(top, 'open'), 'completed', 'on') === false);

process.exit(failures ? 1 : 0);
JS
	close $fh;

	my $out = `$node "$harness" "$root/public/js/manager/tasks.js" 2>&1`;
	my $rc = $? >> 8;
	diag($out) if $rc;
	is($rc, 0, 'only a tick of a row in the Open list plays the close effect');
}

done_testing();
