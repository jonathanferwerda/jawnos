# tests-for: templates/start_menu/start_menu.html.ep public/js/manager/manager/05_start_menu.js public/js/manager/manager/08_handbook.js public/css/manager.css lib/JawnOS/Manager/Part11.pm perl/language.pl perl/help/topics_features.pl public/js/manager/taskbar.js
# covers:    the running list lists open sessions only, Internet is the one web entry
#            point, and every catalog-driven app label reads as a capitalised name

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use DBI;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::Template;
use JawnOSTest;

# The running list is built straight in the template. It used to take every
# `start`/`record` row, so a row a stop had already sealed (type=start,
# stop_seen=yes - the shape a stop/start race left behind) stayed on the menu
# forever. The query under test is lifted from the template itself and run
# against throwaway fixtures, so it is the shipped SQL that is pinned, not a
# copy. Nothing here touches the live database.

my $template = read_file(root() . '/templates/start_menu/start_menu.html.ep');
my $root = root();

# The Web app is a component of Internet now; the start menu offers Internet
# alone, so two icons cannot open the same pages from different places.
unlike($template, qr/id="web_toggle"/, 'no separate Web icon in the start menu');
like($template, qr/id="internet_toggle"/, 'Internet is the one web entry point');
my $menu_js = read_file(root() . '/public/js/manager/manager/05_start_menu.js');
unlike($menu_js, qr/web_toggle/, 'the start menu no longer maps a Web icon');
my $taskbar_js = read_file(root() . '/public/js/manager/taskbar.js');
my $help_features = read_file(root() . '/perl/help/topics_features.pl');

my ($run_sql) = $template =~ /if \(\$menu eq 'run'\) \{\s*\$query = &subs::db_query\('([^']+)'/s;
ok(defined $run_sql, 'the run list has its own query');

like($run_sql, qr/\(\s*type=\?\s+or\s+type=\?\s*\)/,
	'the run list looks at start and record sessions');
like($run_sql, qr/stop_seen\s+is\s+null/,
	'the run list only lists a session that no stop has sealed');

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
	{ RaiseError => 1, PrintError => 0, AutoCommit => 1 });
$dbh->do('create table appointments (app text, type text, timestamp integer, stop_seen text)');

my $now = 1_790_000_000_000;
my $insert = $dbh->prepare(
	'insert into appointments (app, type, timestamp, stop_seen) values (?, ?, ?, ?)');

$insert->execute('brushing', 'start', $now - 60_000, undef);   # running now
$insert->execute('toothpaste', 'start', $now - 50_000, 'yes'); # a stop sealed it, the row still says start
$insert->execute('shower', 'record', $now - 40_000, 'yes');    # a sealed recording, same shape
$insert->execute('later', 'start', $now + 60_000, undef);      # begins in the future
$insert->execute('shower', 'stop', $now - 30_000, 'yes');      # an ordinary stop row
$insert->execute('toothpaste', 'usual', $now - 20_000, undef); # the usual template is not a session

my $rows = $dbh->selectall_arrayref($run_sql, undef, 'start', 'record', $now);
my @apps = map { $_->[0] } @{ $rows || [] };

is_deeply(\@apps, ['brushing'],
	'only the session still running is listed; a sealed start row is not');

my ($up_sql) = $template =~ /db_query\("([^"]*coalesce\(type[^"]*)"/;
ok(defined $up_sql, 'the upcoming list has its own query');
$insert->execute('space_weather', 'measure', $now + 120_000, undef);
my $up_rows = $dbh->selectall_arrayref($up_sql, undef, $now);
my @up_apps = map { $_->[0] } @{ $up_rows || [] };
ok(!(grep { $_ eq 'space_weather' } @up_apps), 'a daily measurement stays off the upcoming list');
ok((grep { $_ eq 'later' } @up_apps), 'a real future appointment is still listed');


like($template, qr/id="keyboard_toggle"/, 'the keyboard is a start-menu app');
like($template, qr/id="calculator_toggle"/, 'and the calculator');

# Every launcher that opens a window (or a window-shaped panel) needs an app
# key, or the press-time window preview has no app to match its origin to.
# stop_all and upload are actions, not apps, and stay out of the map.
my ($icon_map_src) = $menu_js =~ /var startMenuIconApps = \{(.*?)\n\};/s;
ok(defined $icon_map_src, 'the start-menu icon map is readable');
my %icon_apps = ($icon_map_src // '') =~ /([A-Za-z0-9_]+)\s*:\s*'([^']*)'/g;
my %launchers = (
	handbook_toggle => 'handbook', help_toggle => 'help',
	notifications_toggle => 'notifications', packages_toggle => 'packages',
	keyboard_toggle => 'keyboard', calculator_toggle => 'calculator',
	weather_toggle => 'weather', power_toggle => 'power', sound_toggle => 'sound',
	twirl_toggle => 'twirl', scan_toggle => 'scan', studio_toggle => 'studio',
	pipedream_toggle => 'pipedream', minesweeper_toggle => 'minesweeper'
);
for my $id (sort keys %launchers) {
	is($icon_apps{$id}, $launchers{$id}, "$id names its app");
}
is(scalar(grep { !defined $icon_apps{$_} || $icon_apps{$_} eq '' } keys %icon_apps), 0,
	'no mapped launcher has an empty app');
for my $action (qw(stop_all upload)) {
	ok(!exists $icon_apps{$action}, "$action is an action, not an app in the map");
}

# Every app label drawn through the core catalog must read as a label. A key
# with no entry in language.pl falls back to printing itself, which is how the
# keyboard icon stayed lowercase beside Clock and Sound. The catalogue is
# loaded by JawnOSTest; the English value is the one the fallback shows.
my @lang_hints = $template =~ /hint="<%=\s*&subs::lang\('([^']+)'\)\s*%>"/g;
ok(scalar(@lang_hints), 'the start menu draws app labels through the core catalog');
for my $key (@lang_hints) {
	my $label = language::translate('en', $key);
	isnt($label, $key, "the $key label has a catalog entry");
	like($label, qr/^[A-Z]/, "the $key label starts with a capital letter");
}

# --- the rebuilt panel's shape ----------------------------------------------
# The panel is one labelled, tabbed dialog: a header (title, search slot, app
# filter, Configure gear), a page tablist, the app page's category chips and its
# Recent/All groups, and a footer of Leave, Site type and a More menu. The All
# chip is the resting selection, so the catalogue shows on open.
like($template, qr/class="start_menu_header"/, 'the panel has its header');
like($template, qr/class="start_menu_search_slot"/, 'the header reserves the search slot');
like($template, qr/id="start_menu_filter" class="start_menu_filter"/,
	'the header draws the app-name search');
# The search bar rides the header on every page, not only Apps, and Configure
# holds its right edge.
my ($menu_header) = $template =~ /(class="start_menu_header".*?<\/div>)/s;
like($menu_header, qr/id="start_menu_filter"/, 'the search bar rides the header on every page');
like($menu_header, qr/&subs::lang\('common\.search'\)/, 'the bar reads Search in every language');
like($menu_header, qr/id="main_logo"/, 'and Configure shares that header');
like($template, qr/class="start_menu_pages" role="tablist"/,
	'the page row is a labelled tablist');
like($template, qr/foreach my \$b \( qw\/app run up exp view\/ \)/,
	'the page row draws Apps, Running, Upcoming, Expiring and System');
like($template, qr/class="start_menu_menu/, 'each page is a start_menu_menu button');
like($template, qr/role="tab"/, 'each page button is a tab');
like($template, qr/aria-selected="<%= \$menu eq \$b \? 'true' : 'false' %>"/,
	'each page button announces whether it is selected');
like($template, qr/class="start_menu_category selected" category="all"[\s\S]{0,160}aria-selected="true"/,
	'the All category chip starts selected');
like($template, qr/class="start_menu_categories" role="tablist"/,
	'the category chips are a tablist');
like($template, qr/class="start_menu_recent_group"/, 'the app page has a Recent group');
like($template, qr/class="start_menu_all_group"/, 'and an All apps group');
like($template, qr/class="start_menu_footer"/, 'the panel has its footer');
like($template, qr/class="start_menu_foot start_menu_leave_button"/, 'Leave sits in the footer');
like($template, qr/class="start_menu_foot start_menu_site_button"/, 'Site type sits in the footer');
like($template, qr/class="start_menu_foot start_menu_more"/, 'More sits in the footer');
like($template, qr/id="start_menu_more_menu" class="start_menu_more_menu" role="menu"/,
	'More opens its own menu');
like($template, qr/class="start_menu_admin_item"/,
	'the Admin console is its own item, hidden outside the desktop app');

# The menu's surface is the theme's own start-menu colour, with the panel colour
# as the fallback - never a hardcoded yellow, which once left a pale sheet on the
# wrong theme.
like($template, qr/theme_surface_colour\('start_menu', \$device\)/,
	'the surface comes from theme_surface_colour(start_menu, device)');
like($template, qr/theme_surface_colour\('start_menu', \$device\) \|\| 'var\(--panel\)'/,
	'and falls back to the panel colour');
unlike($template, qr/theme_surface_colour\([^)]*\) \|\| 'yellow'/,
	'the surface has no yellow fallback');

# The page row is labelled from the core catalog and the category chips from the
# catalogue of app names, so every language has words where a key would show.
for my $key (qw(search.apps running start_menu.upcoming start_menu.expiring configure.follow_system)) {
	like($template, qr/&subs::lang\('\Q$key\E'\)/, "the page label $key comes from the catalog");
}
like($template, qr/&subs::format_name\(\$category\)/,
	'the category labels read as formatted names');

# The rebuilt labels are core keys, not just English prose: each resolves to a
# real English label rather than the key itself.
for my $key (qw(start_menu.upcoming start_menu.expiring start_menu.all start_menu.all_apps
	start_menu.forget start_menu.search_apps start_menu.start start_menu.more
	start_menu.site_type start_menu.no_matches)) {
	my $label = language::translate('en', $key);
	ok(defined $label && length $label, "$key resolves in English");
	isnt($label, $key, "$key is not left as the bare key");
}

# --- what the panel does ----------------------------------------------------
# startMenuView() sorts the catalogue and keeps the All chip's catalogue: the
# view lifts up to five recent apps into the Recent group and sorts the rest into
# All apps; a shelf narrows the same rows and drops both group labels. The header
# search is the house search on every page, so it no longer narrows the catalogue.
like($menu_js, qr/function startMenuView\(\)/, 'startMenuView draws the catalogue');
like($menu_js, qr/category === 'all'/, "startMenuView treats the All chip as the whole catalogue");
like($menu_js, qr/\.start_menu_recent_group/, 'the view moves recent apps into the Recent group');
like($menu_js, qr/\.start_menu_all_group/, 'and the rest into All apps');
like($menu_js, qr/\$\('#start_menu_filter'\)/, 'a fresh body resets the search field');
like($menu_js, qr/on\('input', '#start_menu_filter'/,
	'the header search answers as the person types');
unlike($menu_js, qr/startMenuQuery/, 'the search no longer narrows the catalogue');
like($menu_js, qr/function startMenuSelectCategory\(category\)/,
	'startMenuSelectCategory keeps exactly one chip selected');
like($menu_js, qr/function startMenuMoreToggle\(open\)/,
	'the More button toggles its menu');
like($menu_js, qr/function startMenuFocusCapture\(\)/, 'a swap remembers the focused node');
like($menu_js, qr/function startMenuFocusRestore\(info\)/, 'and puts the keyboard back on it');
like($menu_js, qr/key === 'Escape'/, 'Escape closes the menu');
like($menu_js, qr/key === 'ArrowLeft'/, 'the tablists step left with the arrow keys');
like($menu_js, qr/key === 'ArrowRight'/, 'and right');
like($menu_js, qr/key === 'ArrowDown'/, 'the rows step down with the arrow keys');
like($menu_js, qr/key === 'ArrowUp'/, 'and up');
like($menu_js, qr/key === 'Home'/, 'Home jumps to the first row');
like($menu_js, qr/key === 'End'/, 'and End to the last');
like($taskbar_js, qr/\$\('#start_menu \.start_menu_search_slot'\)/,
	'the search is placed in the menu header slot');
like($taskbar_js, qr/matchMedia\('\(max-width:620px\)'\)/,
	'placement asks whether this is a phone');
like($taskbar_js, qr/addClass\('start_menu_sheet'\)/,
	'and hangs the sheet class on a phone');
like($taskbar_js, qr/matchMedia\('\(max-height:520px\)'\)/,
	'a landscape phone is a short screen, not a narrow one');
like($taskbar_js, qr/var sheet_limit = short \? sheet_room : 'min\(78vh, ' \+ sheet_room \+ 'px\)'/,
	'and a short screen takes the whole room between the bars');
# A sheet follows the button's own bar: under a top bar, over a bottom one.
like($taskbar_js, qr/var below = \(edge != 'bottom'\);/, 'the sheet follows the button\'s own edge');
like($taskbar_js, qr/toggleClass\('start_menu_sheet_top', below\)/,
	'and hangs under a top bar as well as over a bottom one');
like($taskbar_js, qr/sheet\['top'\] = Math\.round\(t\.bottom \+ sheet_gap\)/,
	'a top-bar sheet starts just below the button');
like($taskbar_js, qr/sheet\['bottom'\] = Math\.round\(h - t\.top \+ sheet_gap\)/,
	'a bottom-bar sheet ends just above it');

# --- the guide's start-menu topic -------------------------------------------
# Tier-1 help is hand-written and has to keep up with the panel: the guide names
# the labelled pages and the house search, the Recent/All groups, Leave/Site/More,
# and that Help lives in the Apps list rather than at the foot.
my ($start_menu_help) = $help_features =~ /\$topic\{'start_menu'\} = \{(.*?)\n\t\};/s;
ok(defined $start_menu_help, 'the start_menu help topic is readable');
like($start_menu_help, qr/2026-11-26/, 'the topic was verified against this rebuild');
like($start_menu_help, qr/Apps, Running, Upcoming, Expiring and System/,
	'the guide names the labelled pages');
like($start_menu_help, qr/search bar in the header/, 'the guide describes the app search');
like($start_menu_help, qr/searches the house/, 'and says it searches the house');
like($start_menu_help, qr/on every page/, 'on every page');
like($start_menu_help, qr/Configure, the wrench, holds the header/, 'and that Configure holds the right edge');
like($start_menu_help, qr/Recent group/, 'the guide describes the Recent group');
like($start_menu_help, qr/All apps/, 'and the All apps list');
like($start_menu_help, qr/Leave, Site type and More/, 'the guide names the footer');
like($start_menu_help, qr/Help is one of the apps in the Apps list/,
	'and says Help is in the Apps list');

like($menu_js, qr/\.start_menu_toggle_copy/, 'a start button copied into an added bar answers');
like($menu_js, qr/closest\('#start_menu_toggle, \.start_menu_toggle_copy'\)/,
	'a press on the copy is not mistaken for an outside press');
# The on-screen keyboard types into the search without counting as an outside
# press, so the menu stands while the person types.
like($menu_js, qr/closest\('#start_menu, #start_menu_toggle, \.start_menu_toggle_copy, #start_menu_search_results, #jawn_soft_keyboard'\)/,
	'a soft-keyboard press is not an outside press');

# --- the panel unfolds out of its button ------------------------------------
# The motion is the same four-level scale the windows wear; the gate is the
# shared one, so off and reduced motion write no class at all and keep the old
# plain show/hide.
my $css = read_file(root() . '/public/css/manager.css');
like($menu_js, qr/jawnosWindowMotionAllowed/, 'the menu motion obeys the shared level and reduced-motion gate');
like($menu_js, qr/jawnosStartMenuUnfold\(\$\('#start_menu'\), st\)/,
	'the render unfolds the panel it has just shown and placed');
like($menu_js, qr/var was_open = jawnosStartMenuOpen\(\$\('#start_menu'\)\);/,
	'the render remembers whether the panel was already open');
like($menu_js, qr/if \(!was_open\) \{ jawnosStartMenuUnfold/,
	'so a tab press swaps the view without replaying the open motion');
like($menu_js, qr/function jawnosStartMenuOrigin\(below, x\)/, 'the unfold origin is one pure geometry');
like($menu_js, qr/jawnosStartMenuFold\(start_menu, st\)/,
	'the closer folds the panel rather than hiding it outright');
like($menu_js, qr/function jawnosStartMenuFold[\s\S]{0,1200}menu\.hide\(\)/,
	'and hides it when the fold ends, so a closed menu is unfocusable again');
like($css, qr/#start_menu\.jawnos_menu_unfold\s*\{[^}]*transform-origin: var\(--jm-origin-x[^}]*animation: jawnos_menu_unfold/s,
	'the panel unfolds from the corner facing its button');
like($css, qr/#start_menu\.jawnos_menu_fold\s*\{[^}]*pointer-events: none/s,
	'a closing panel takes no pointer');
like($css, qr/\@keyframes jawnos_menu_fold\s*\{/, 'the close has its own reverse keyframes');
for my $level (qw(light medium maximum)) {
	like($css, qr/body\[data-window-effects="$level"\]\s*\{[^}]*--jm-menu-scale:/s,
		"the $level level sets the unfold's size");
}
like($css, qr/\@media \(prefers-reduced-motion: reduce\) \{\s*#start_menu\.jawnos_menu_unfold \{ animation: none; \}/s,
	'reduced motion takes the unfold away even mid-flight');

# --- the panel's layout ------------------------------------------------------
# One flex column: header, page row, a body that gives, and a foot. The width
# and height are the desktop/tablet panel; a phone gets the sheet below.
like($css, qr/#start_menu\s*\{[^}]*display:\s*flex;[^}]*flex-direction:\s*column;[^}]*width:\s*clamp\(540px, 42vw, 620px\);[^}]*height:\s*clamp\(420px, 68vh, 720px\)/,
	'the panel is a flex column at the desktop clamp size');
like($css, qr/#start_menu\.start_menu_sheet\s*\{[^}]*left:\s*8px;[^}]*right:\s*8px;[^}]*bottom:\s*calc\(var\(--taskbar_bottom_h, 0px\) \+ 8px\)/,
	'a phone sheet spans the screen and stands on the taskbar');
# A sheet follows its button's bar: the phone branch hangs it under a top bar
# as well as over a bottom one, and the stylesheet draws that box too.
like($css, qr/#start_menu\.start_menu_sheet\.start_menu_sheet_top\s*\{[^}]*top:[^}]*bottom:\s*auto/s,
	'the stylesheet carries the top sheet as well');
like($css, qr/#start_menu \.start_menu_header #main_logo\s*\{[^}]*margin-left:\s*auto/s,
	'Configure holds the header right edge');
# The search bar is the house search on every page, through the global search's
# own index, ranking, openers and dropdown placement.
like($menu_js, qr/function startMenuSearchShow\(query\)/,
	'every page searches the house');
like($menu_js, qr/startMenuSearchShow\(\$\(this\)\.val\(\) \|\| ''\)/,
	'typing always asks the house search');
unlike($menu_js, qr/if \(\$\('\.start_menu_main_display'\)\.length\)/,
	'the search is not gated to the Apps page');
like($menu_js, qr/jawnosSearchMatches\(query\)/, 'using the global search\'s ranking');
like($menu_js, qr/jawnosSearchOpen\(row\.attr\('app'\)\)/, 'and its openers');
like($menu_js, qr/function startMenuSearchMove\(direction\)/, 'the arrows walk the results');
like($menu_js, qr/jawnosSearchResultsPlace\(\$\('#start_menu_filter'\), box\)/,
	'and the dropdown hugs the header filter');
like($css, qr/#start_menu_search_results\s*\{/, 'the dropdown has its own face');
like($css, qr/\@media \(max-width: 620px\)\s*\{\s*#start_menu\s*\{/,
	'and the stylesheet draws the same sheet at the 620px breakpoint');
like($css, qr/\@media \(max-height: 520px\)\s*\{\s*#start_menu\s*\{/,
	'and a short landscape screen gets the full-height sheet too');
like($css, qr/#start_menu \.start_menu_body\s*\{[^}]*overflow:\s*hidden/,
	'the body gives and clips');
like($css, qr/#start_menu \.start_menu_main_display\s*\{[^}]*overflow-y:\s*auto/,
	'while the app list scrolls inside it');
# The active tab/chip is painted under #start_menu: a soft accent fill and an
# inset foot, not a border width universal.css overrides with !important.
like($css, qr/#start_menu \.start_menu_menu\.selected[^}]*box-shadow:\s*inset 0 -3px 0 var\(--accent/,
	'the active page tab wears an accent foot and fill');
like($css, qr/#start_menu \.start_menu_category\.selected[^}]*background-color:\s*var\(--accent-soft/,
	'and so does the active category chip');
unlike($css, qr/#start_menu \.start_menu_menu\.selected[^}]*border-width/,
	'the active state does not rely on border-width');
# The recent X is a quiet neutral affordance at rest; red is only for the
# pointer or the keyboard.
like($css, qr/#start_menu \.start_menu_recent_clear\s*\{[^}]*color:\s*currentColor;[^}]*opacity:\s*\.55/,
	'the recent X is neutral at rest');
unlike($css, qr/#start_menu \.start_menu_recent_clear\s*\{[^}]*#cc0000/,
	'with no red in its resting rule');
like($css, qr/#start_menu \.start_menu_recent_clear:hover[^}]*#cc0000/,
	'and turns red on hover');
# The foot is three 44px keys; More opens a themed grid above it.
like($css, qr/#start_menu \.start_menu_foot\s*\{[^}]*min-height:\s*44px/,
	'a foot key is a 44px target');
like($css, qr/#start_menu \.start_menu_more_menu\s*\{(?=[^}]*position:\s*absolute)(?=[^}]*bottom:\s*100%)(?=[^}]*right:\s*0)/,
	'the More menu opens above the foot, anchored to its right');
like($css, qr/#start_menu \.start_menu_more_item\s*\{[^}]*min-height:\s*44px/,
	'and each More item is a 44px row');

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
SKIP: {
	skip 'node is needed to play the menu geometry', 1 unless $node && -x $node;

	my ($fh, $harness) = tempfile(SUFFIX => '.js', UNLINK => 1);
	print $fh <<'JS';
const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
const m = src.match(/function jawnosStartMenuOrigin\(below, x\) \{[\s\S]*?\n\}/);
if (!m) { console.log('missing helper'); process.exit(2); }
eval(m[0]);
const cases = [
	[[true, 0.5], { x: 50, y: 0, dy: -6 }],    // hangs under a top bar's button
	[[false, 0.5], { x: 50, y: 100, dy: 6 }],   // stands over a bottom bar's button
	[[true, -1], { x: 0, y: 0, dy: -6 }],       // a button past the left edge
	[[true, 2], { x: 100, y: 0, dy: -6 }],      // a button past the right edge
	[[false, null], { x: 0, y: 100, dy: 6 }]    // no button line is the left corner
];
let bad = 0;
for (const [args, want] of cases) {
	const got = jawnosStartMenuOrigin.apply(null, args);
	if (!got || got.x !== want.x || got.y !== want.y || got.dy !== want.dy) {
		bad++;
		console.log('FAIL', JSON.stringify(args), JSON.stringify(got));
	}
}
console.log(bad ? 'bad' : 'ok');
process.exit(bad ? 1 : 0);
JS
	close $fh;
	my $out = `$node $harness $root/public/js/manager/manager/05_start_menu.js 2>&1`;
	is($? >> 8, 0, 'the unfold runs down from a top bar and up from a bottom one, inside the panel');
}

# A desk and a phone have no DOSBox, so the games shelf carries the browser
# player's rows. The handheld keeps its native shelf, and the server sends an
# empty list there.
like($template, qr/dos_game_toggle/, 'the games shelf draws a row per DOS game');
like($template, qr/data-game="<%= \$dos_game->\{'id'\} %>"/,
	'the row carries the card id the player route resolves');
like($template, qr/manager\/games\/art\?id=/, 'and the card picture when the shelf has one');
like($menu_js, qr/\.dos_game_toggle/, 'a row press is the player opener');
like($menu_js, qr{url: '/manager/games/play'}, 'which asks the player route for the window');

# The games category carries a direct icon for each house game, so the desk
# starts one without going through the Controller's second launcher. Each icon
# is a lazy toggle, and core opens the window the same way Twirl's does.
like($template, qr/id="pipedream_toggle"[^>]*category="games"/, 'Pipedream is a start-menu game');
like($template, qr/id="minesweeper_toggle"[^>]*category="games"/, 'Minesweeper is a start-menu game');
my $handbook_js = read_file(root() . '/public/js/manager/manager/08_handbook.js');
like($handbook_js, qr/\#pipedream_toggle, \#minesweeper_toggle/, 'one opener handles both game icons');
like($handbook_js, qr{url: '/manager/' \+ app}, 'and asks the game\'s own route for the window');

# The template is rendered with `vars => 1`, so every name it uses has to be a
# key in the stash the caller passes; a missing one fails compilation and the
# route answers 500. /apps/start put the device in its stash, but the JSON
# route (/manager/start_menu) did not, and every refresh of its menu failed.
# Read the maker's own call so the test follows the names it actually hands in.
my $part11 = read_file(root() . '/lib/JawnOS/Manager/Part11.pm');
my ($maker_args) = $part11 =~ /render_to_string\(\s*template => 'start_menu\/start_menu',\s*(.*?)\n\t\);/s;
ok(defined $maker_args, 'the maker\'s start-menu render is readable');
my @stash_names = $maker_args =~ /(?:^|,)\s*(\w+)\s*=>/g;
ok(grep({ $_ eq 'device' } @stash_names), 'the maker hands the template a device');

# A new install opens on the App catalogue, not the System view: the water-drop
# page is one press away, and a launcher should not open on a diagnosis. The
# welcome tour still rides in first_run, so the returner keeps that key.
like($part11, qr/\$menu = 'app' unless length \$menu;/,
	'a new install lands on the App page');
unlike($part11, qr/\$menu = 'view' unless length \$menu;/,
	'and not on the System view');
like($part11, qr/first_run => \$first_run/,
	'the maker still returns first_run for the welcome tour');

my %stash = map {
	$_ => ($_ eq 'menu' ? 'app' : $_ eq 'device' ? 'computer' : ($_ eq 'config' || $_ eq 'parking_lot') ? {} : [])
} @stash_names;
local $SIG{'__WARN__'} = sub { };
my $mt = Mojo::Template->new(
	auto_escape => 1,
	vars => 1,
	# The renderer defines these in the template namespace; the early return
	# makes this a compile check, not an attempt to run the menu.
	prepend => 'sub _C { } sub include { } my $self = my $c = _C; return "compiled";'
);
my $rendered = eval { $mt->render($template, \%stash) };
my $error = ref $rendered ? "$rendered" : ($@ // '');
unlike($error, qr/Global symbol "\$(\w+)"/,
	'every name the template uses is in the stash the maker passes');

# The JSON route calls the maker with only the controller; the games rows are
# the maker's job there. The signature used to make that second argument
# mandatory, so the authenticated route died before the template was reached
# with "Too few arguments for subroutine 'Manager::start_menu_maker'". Call it
# the way the route does and keep every other read a stub.
require(root() . '/lib/JawnOS/Manager/Part11.pm');
{ package FakeStartMenuC;
	sub param { return undef }
	sub stash { return undef }
	sub render_to_string {
		my ($self, %args) = @_;
		$self->{'args'} = \%args;
		return '<div id="start_menu"></div>';
	}
}
{ package FakeStartMenuRows;
	sub new { return bless { rows => [] }, shift }
	sub hashes { return $_[0]->{'rows'} }
}
my $c = bless {}, 'FakeStartMenuC';
my $menu = do {
	no warnings 'redefine';
	local *help::welcome_seen = sub { 1 };
	local *Manager::parking_lot_grabber = sub { {} };
	local *Manager::start_menu_recent = sub { [] };
	local *Manager::start_menu_hidden_apps = sub { [] };
	local *subs::config_reader = sub { {} };
	local *subs::db_select = sub { FakeStartMenuRows->new };
	local *subs::game_menu_entries = sub { [] };
	local *subs::rightNow = sub { 123 };
	local *subs::icon_set = sub { undef };
	eval { Manager::start_menu_maker($c) };
};
is($@, '', 'the maker runs when its caller passes only the controller');
ok(ref $menu eq 'HASH' && ($menu->{'menu'} // '') eq 'app', 'and returns the app menu');
is($c->{'args'}->{'device'}, 'computer', 'with the config device the template needs');

done_testing();
