# tests-for: templates/apps/games.html.ep lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm public/js/manager/manager/09_app_back.js public/js/manager/twirl.js public/js/manager/twirl/01_twirl_game.js perl/help/topics_people.pl public/css/manager.css
# covers:    The second launcher behind the Controller's Games tile, Twirl's
#            clockwise and counter-clockwise turns, and the strip a full-screen
#            app used to keep where its title bar had been.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();

# --- the route and its action -------------------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc9.pm");
like($routes, qr/\[\s*44004\s*,\s*'get'\s*,\s*'\/manager\/games'\s*,\s*'action_44004'\s*\]/,
	'GET /manager/games is registered and names its action');
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my ($action) = $controller =~ /(sub action_44004\b.*?\n\})/s;
ok($action, 'action_44004 exists');
like($action, qr/template => 'apps\/games'/, 'the action renders the games page');
like($action, qr/&Manager::window_maker\(/, 'the page is served through the window maker');

# --- the shelf ----------------------------------------------------------------
my $page = read_file("$root/templates/apps/games.html.ep");
like($page, qr/href="\/manager\?open=cards&amp;full=1"/, 'Cards opens the card room full screen');
like($page, qr/href="\/manager\?open=twirl&amp;full=1"/, 'Twirl opens the puzzle full screen');
like($page, qr/Emulated games/, 'the emulated shelf is named');
like($page, qr/None installed yet/, 'and says there is nothing on it yet');
like($page, qr/id="games_home"[^>]*href="\/manager\/controller"/, 'Home returns to the Controller launcher');

# --- the desk and the Controller know it -------------------------------------
my $back = read_file("$root/public/js/manager/manager/09_app_back.js");
like($back, qr/games: '\/manager\/games'/, 'the desk resolves ?open=games to the launcher');
like(read_file("$root/templates/apps/controller.html.ep"), qr/href="\/manager\?open=games&amp;full=1"/,
	'the Controller Games tile opens the launcher, not Twirl directly');

# --- the Guide ----------------------------------------------------------------
my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr/\$topic\{'games'\}\s*=\s*\{/, 'the games Guide topic exists');
like($help, qr/category => 'apps', app => 'games'/, 'the topic claims the games app page');

# --- Twirl's two turns --------------------------------------------------------
my $twirl = read_file("$root/public/js/manager/twirl.js");
like($twirl, qr/code == 183/, 'B arrives as F13 and maps to a command');
like($twirl, qr/return 'rotate_left'/, 'that command is the counter-clockwise turn');
my $game = read_file("$root/public/js/manager/twirl/01_twirl_game.js");
like($game, qr/function rotateMatrixLeft/, 'a counter-clockwise matrix turn exists');
like($game, qr/function rotateCounter/, 'and keeps the same fixed pivot');
like($game, qr/command == 'rotate_left'/, 'the action handles it');
like($game, qr/\.on\('mousedown', '#twirl'/, 'A, a plain click, turns the piece clockwise');

# --- the full-screen strip ----------------------------------------------------
like(read_file("$root/public/css/manager.css"),
	qr/body\.full_app_mode \.wind\.full_app_window \.window_contents \{ padding-top:0 !important; \}/,
	'a full-screen app drops the title-bar padding that showed as a top strip');

done_testing();
