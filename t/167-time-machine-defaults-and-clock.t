# tests-for: templates/keyboard.html.ep templates/apps/clock/machine.html.ep public/js/manager/keyboard/02_keyboard_maker.js public/js/manager/taskbar.js public/js/manager/leaderboardprinter.js public/js/manager/clothesline/01_timeline.js lib/JawnOS/Controller/manager_misc6.pm
# covers:    A fresh browser starts on the desk with the time machine on All,
#            15 minutes and a 3 s interval, and the header and taskbar clocks
#            tick every second unless the view is held on one moment.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A fresh browser - the live USB and a first install - had no layout, scope or
# interval yet, and initializer() seeded layout 'leaderboard', scope 'hour',
# update_frequency 'no', and project/account 'def'. 'def' matched no row and
# never matched 'all' either, so the first view came up empty until the dropdowns
# were touched. The seed is now the desk, All/All/All, 15 minutes and 3 seconds,
# and the template marks the same choices for the first paint before the script
# runs.
#
# The second half pins the one-second clock: the poll may be 3 s (or off), but the
# header and taskbar faces are anchored on the view's centre and advanced here
# every second. A time machine that names one fixed moment is stationary and its
# face stands still, which the server now marks in __specs.

my $root    = repo_root();
my $keyboard = read_file("$root/templates/apps/clock/machine.html.ep");
my $maker    = read_file("$root/public/js/manager/keyboard/02_keyboard_maker.js");
my $taskbar  = read_file("$root/public/js/manager/taskbar.js");
my $header   = read_file("$root/public/js/manager/leaderboardprinter.js");
my $timeline = read_file("$root/public/js/manager/clothesline/01_timeline.js");
my $viewer   = read_file("$root/lib/JawnOS/Controller/manager_misc6.pm");

# --- the fresh-browser defaults ---------------------------------------------
like($maker, qr/\blayout = 'desk';\s*\n\s*localStorage\.setItem\('layout', layout\);/,
	'the first view is the desk');
like($maker, qr/\bscope = 'fifteenminute';\s*\n\s*localStorage\.setItem\('scope', scope\);/,
	'the first scope is fifteen minutes');
like($maker, qr/\bupdate_frequency = '3000';\s*\n\s*localStorage\.setItem\('update_frequency', update_frequency\);/,
	'the first view refresh is 3 seconds');
like($maker, qr/\bfilter = 'all';\s*\n\s*localStorage\.setItem\('filter', filter\);/,
	'the first type is All, not the string "null"');
like($maker, qr/\bproject = 'all';\s*\n\s*localStorage\.setItem\('project',project\);/,
	'the first project is All, not the dead "def"');
like($maker, qr/\baccount = 'all';\s*\n\s*localStorage\.setItem\('account',account\);/,
	'the first account is All, not the dead "def"');
unlike($maker, qr/\b(?:project|account) = 'def';/,
	'the unmatched "def" filter is gone');

# --- and the template's own first paint carries the same choices ------------
like($keyboard, qr/<option value="desk" selected>/,
	'the layout select marks the desktop');
like($keyboard, qr/<option value="3000" selected>/,
	'the interval select marks 3 seconds');
like($keyboard, qr/<option value="<%=\s*\$span\s*%>"<%=\s*\$span eq 'fifteenminute' \? ' selected' : ''\s*%>>/,
	'the scope select marks fifteen minutes');
like($keyboard, qr/<select name="filter" id="filter">.*?\$m eq 'all' \? ' selected' : ''/s,
	'the type select marks All');
like($keyboard, qr/<select id="accounts" style="max-width: 50%;">\s*\n\s*<option value="all" selected>All<\/option>/,
	'the account select keeps All selected');
like($keyboard, qr/<select id="projects" style="max-width: 50%">\s*\n\s*<option value="all" selected>All<\/option>/,
	'the project select keeps All selected');

# --- the header and taskbar clock tick every second -------------------------
like($taskbar, qr/var jawnosClockAnchor = null;/,
	'the taskbar clock keeps an anchor');
like($taskbar, qr/jawnosClockAnchor = \{ timestamp: timestamp, at: Date\.now\(\), moving: !stationary \};/,
	'the anchor records the view moment, the wall moment and whether it moves');
like($taskbar, qr/if \(!jawnosClockAnchor \|\| !jawnosClockAnchor\.moving\) \{ return; \}/,
	'a stationary anchor leaves the face alone');
like($taskbar, qr/var stamp = jawnosClockAnchor\.timestamp \+ \(Date\.now\(\) - jawnosClockAnchor\.at\);/,
	'a moving face advances from the anchored moment by the wall clock');
like($taskbar, qr/\$\('#header'\)\.text\(fixedTimeString\(stamp\)\);/,
	'the header face is redrawn from the same stamp');
like($taskbar, qr/jawnos_tick_register\('taskbar_clock', jawnosClockFaceTick\)/,
	'the once-a-second job is registered with the shared tick');
like($taskbar, qr/typeof desk_visible != 'undefined' && desk_visible/,
	"the desk's own tick is left to own the face");

like($header, qr/var clock_stationary = \(appts\['__specs'\]\['time_machine_stationary'\] == 1\);/,
	'the printer reads the server\'s stationary flag');
like($header, qr/jawnosClockAnchorSet\(clock_stamp, clock_stationary\)/,
	'and anchors the face with it on every payload');
like($timeline, qr/response\.appts\['__specs'\]\['time_machine_stationary'\] = 1;/,
	'a timeline slide leaves a stationary face where it was put');

# --- the server says whether the view is stationary -------------------------
like($viewer, qr/my \$anchor = \(defined \$timestamp && \$timestamp =~ \/\\S\/\) \? \$timestamp : &subs::rightNow\(\);/,
	'the viewer keeps the anchor before the time machine resolves');
like($viewer, qr/my \$later = &time_machine_resolve\(\$time_machine, \$anchor \+ 3600000\);/,
	'it resolves the words an hour later to see whether they move');
like($viewer, qr/\$time_machine_stationary = 1 if abs\(\$later - \$time_machine_timestamp\) < 1000;/,
	'a moment that does not move is stationary');
like($viewer, qr/\$appts->\{'__specs'\}->\{'time_machine_stationary'\} = \$time_machine_stationary;/,
	'and the flag travels with the payload');

# --- the dock's strip, not the background, calls it back ---------------------
like($header, qr/typeof pseudonymDockPointOnDock == 'function'/,
	'a background tap asks whether it landed on the dock');
like($header, qr/pseudonymDockPointOnDock\(e\.clientX, e\.clientY\)/,
	'and only the strip the tucked dock keeps on screen brings it back');

# --- the scripts still parse ------------------------------------------------
my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	for my $file (qw(
		public/js/manager/keyboard/02_keyboard_maker.js
		public/js/manager/taskbar.js
		public/js/manager/leaderboardprinter.js
		public/js/manager/clothesline/01_timeline.js
	)) {
		my $out = `$node --check "$root/$file" 2>&1`;
		my $status = $?;
		diag($out) if $status != 0;
		is($status, 0, "node --check accepts $file");
	}
}
else {
	diag('node is not installed; the syntax checks are skipped');
}

done_testing();
