# tests-for: templates/start_menu/start_menu.html.ep public/js/manager/manager/05_start_menu.js public/js/manager/manager/08_handbook.js public/css/manager.css lib/JawnOS/Manager/Part11.pm
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

like($menu_js, qr/\.start_menu_toggle_copy/, 'a start button copied into an added bar answers');
like($menu_js, qr/closest\('#start_menu_toggle, \.start_menu_toggle_copy'\)/,
	'a press on the copy is not mistaken for an outside press');

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
