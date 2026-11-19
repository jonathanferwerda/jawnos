# tests-for: lib/JawnOS/Routes.pm lib/JawnOS/Routes/manager_games.pm lib/JawnOS/Controller/manager_games.pm lib/JawnOS/Manager/Core1_tables_hooks.pm public/js/manager/manager/09_app_back.js public/js/manager/windows/03_stack.js lib/JawnOS/Domain/Appointment.pm perl/help/topics_people.pl templates/pipedream.html.ep templates/minesweeper.html.ep public/js/manager/pipedream/02_pipedream_ui.js public/js/manager/minesweeper.js
# covers:    Pipedream and Minesweeper are real apps: their routes render their
#            templates through the window maker, the lazy maps carry their chunks
#            and entry functions, ?open= knows their addresses, closing their
#            windows stops their play sessions, the play and heartbeat ledgers
#            accept their names, and the help topics exist.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", 't/lib';
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();

# --- routes and their actions -------------------------------------------------
my $route_index = read_file("$root/lib/JawnOS/Routes.pm");
like($route_index, qr/\bmanager_games\b/, 'the games route group is registered');

my $routes = read_file("$root/lib/JawnOS/Routes/manager_games.pm");
like($routes, qr/\[\s*44030\s*,\s*'get'\s*,\s*'\/manager\/pipedream'\s*,\s*'action_44030'\s*\]/,
	'GET /manager/pipedream is registered');
like($routes, qr/\[\s*44031\s*,\s*'get'\s*,\s*'\/manager\/minesweeper'\s*,\s*'action_44031'\s*\]/,
	'GET /manager/minesweeper is registered');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_games.pm");
my ($pipedream_action) = $controller =~ /(sub action_44030\b.*?\n\})/s;
my ($minesweeper_action) = $controller =~ /(sub action_44031\b.*?\n\})/s;
ok($pipedream_action, 'action_44030 exists');
ok($minesweeper_action, 'action_44031 exists');
like($pipedream_action // '', qr/template => 'pipedream'/, 'Pipedream renders its template');
like($pipedream_action // '', qr/app => 'pipedream'/, 'and opens a Pipedream window');
like($minesweeper_action // '', qr/template => 'minesweeper'/, 'Minesweeper renders its template');
like($minesweeper_action // '', qr/app => 'minesweeper'/, 'and opens a Minesweeper window');

# --- the lazy app maps --------------------------------------------------------
my $hooks = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");
like($hooks, qr{pipedream\s*=>\s*\[qw\(/js/manager/pipedream\.js\)\]}, 'Pipedream loads its own chunk');
like($hooks, qr{minesweeper\s*=>\s*\[qw\(/js/manager/minesweeper\.js\)\]}, 'Minesweeper loads its own chunk');
like($hooks, qr{pipedream\s*=>\s*\[qw\(pipedreamInit\)\]}, 'Pipedream has an entry function');
like($hooks, qr{minesweeper\s*=>\s*\[qw\(minesweeperInit\)\]}, 'Minesweeper has an entry function');
like($hooks, qr/pipedream_toggle\s*=>\s*'pipedream'/, 'the start-menu icon loads the Pipedream chunk');
like($hooks, qr/minesweeper_toggle\s*=>\s*'minesweeper'/, 'and Minesweeper\'s icon loads its chunk');

# --- ?open= and the close hook ------------------------------------------------
my $open = read_file("$root/public/js/manager/manager/09_app_back.js");
like($open, qr{pipedream:\s*'/manager/pipedream'}, '?open=pipedream knows its address');
like($open, qr{minesweeper:\s*'/manager/minesweeper'}, '?open=minesweeper knows its address');

my $stack = read_file("$root/public/js/manager/windows/03_stack.js");
like($stack, qr/app == 'pipedream' \|\| app == 'minesweeper'/,
	'closing either game window is its own teardown');
like($stack, qr/own_game === 'Pipedream'/, 'closing Pipedream ends its play');
like($stack, qr/own_game === 'Minesweeper'/, 'closing Minesweeper ends its play');

# --- the play ledger accepts both names ---------------------------------------
my $appointment = read_file("$root/lib/JawnOS/Domain/Appointment.pm");
my @allowed = $appointment =~ /my %allowed = map \{ \$_ => 1 \} \(([^)]*)\)/g;
is(scalar @allowed, 2, 'the play and heartbeat writers each keep an allowed list');
for my $list (@allowed) {
	like($list, qr/'Pipedream'/, 'the list accepts Pipedream');
	like($list, qr/'Minesweeper'/, 'and Minesweeper');
}

# --- the games have help and roots --------------------------------------------
my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr/\$topic\{'pipedream'\}/, 'Pipedream has a guide topic');
like($help, qr/\$topic\{'minesweeper'\}/, 'Minesweeper has a guide topic');
like($help, qr/Cards, Twirl, Pipedream and Minesweeper/, 'the Games topic names them');

my $pipedream = read_file("$root/templates/pipedream.html.ep");
like($pipedream, qr/id="pipedream"/, 'the Pipedream page has its root');
like($pipedream, qr/pipedreamInit\(\)/, 'and calls its entry');

my $minesweeper = read_file("$root/templates/minesweeper.html.ep");
like($minesweeper, qr/id="minesweeper"/, 'the Minesweeper page has its root');
like($minesweeper, qr/minesweeperInit\(\)/, 'and calls its entry');

# --- the games report their exact play names ---------------------------------
my $pipedream_ui = read_file("$root/public/js/manager/pipedream/02_pipedream_ui.js");
like($pipedream_ui, qr/jawnosGameSessionStart\('Pipedream'/, 'Pipedream reports its play as Pipedream');
my $minesweeper_js = read_file("$root/public/js/manager/minesweeper.js");
like($minesweeper_js, qr/jawnosGameSessionStart\('Minesweeper'/, 'Minesweeper reports its play as Minesweeper');

done_testing();
