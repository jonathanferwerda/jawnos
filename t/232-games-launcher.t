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
like($page, qr/^\s*\.wind \{[^}]*width:100vw/m, 'the launcher page itself fills the glass');

# --- the shelf's system filter ------------------------------------------------
like($page, qr/id="games_filters"/, 'the shelf carries a system filter bar');
like($page, qr/#games_filters \{[^}]*display:flex;/, 'the filter bar lays its buttons in one row');
like($page, qr/#games_filters \{[^}]*overflow-x:auto;/, 'the filter bar scrolls sideways when it is wider than the glass');
like($page, qr/#games_filters \{[^}]*white-space:nowrap;[^}]*gap:6px;/, 'its labels stay on one line with a tight gap');
like($page, qr/#games_filters \{[^}]*flex-wrap:nowrap;/, 'the filter bar never wraps');
like($page, qr/data-filter="all"[^>]*>.*?<%= &subs::ui\('All'\) %>/s, 'All is the first filter');
like($page, qr/data-system="<%=\s*\$sys->\{'id'\}\s*%>"/,
	'each system button filters by its own id');
like($page, qr/data-system="<%=\s*defined \$game->\{'system'\}/,
	'each card names the system the filter matches');
like($page, qr/class="games_filter is_active"/, 'a filter starts active');
like($page, qr/No games yet\. Install the emulators/, 'the empty-shelf message still reaches the page');

# --- the per-system emulator picker ------------------------------------------
like($page, qr/<select[^>]*data-system-emulator=/,
	'a system with runners gets an emulator picker');
like($page, qr/<details id="games_emulators">/, 'the pickers sit in a compact, folded Systems list');
like($page, qr/\$sys->\{'runners'\}/, 'the picker is drawn from the runners the backend reports');
like($page, qr/\$sys->\{'chosen'\}/, 'and marks the chosen runner');
like($page, qr{post\('/manager/games/emulator'}, 'a change saves through the emulator route');
like($page, qr/\{ system: system, runner: picker\.value \}/, 'the POST carries the system and the runner');

# --- fetching covers ----------------------------------------------------------
like($page, qr/id="games_covers"/, 'the shelf bar has a Fetch covers button');
like($page, qr/Fetch covers/, 'and names it');
like($page, qr{post\('/manager/games/covers'}, 'Fetch covers starts the cover fetch');
like($page, qr{fetch\('/manager/games/covers/status'}, 'it then polls the cover status route');
like($page, qr/setTimeout\(coversPoll, 2000\)/, 'the status is read every two seconds while it runs');
like($page, qr/coversSay\(fetchingCovers \+ ' ' \+ \(status\.done \|\| 0\) \+ '\/' \+ \(status\.total \|\| 0\)\)/,
	'progress is shown as done over total');
like($page, qr/coversSay\(status\.error \|\| failed\)/, 'a failure shows the error');

# --- the controls page --------------------------------------------------------
like($page, qr/id="games_controls"[^>]*href="\/manager\/games\/mapping"/,
	'Controls points at the mapping page');
like($page, qr/encodeURIComponent\(system\)/, 'the chosen system follows the Controls link into its query');
unlike($page, qr/cursor:(?!var\()/, 'every cursor uses the house pointer token');

# --- the desk and the Controller know it -------------------------------------
my $back = read_file("$root/public/js/manager/manager/09_app_back.js");
like(read_file("$root/templates/apps/controller.html.ep"), qr/href="\/manager\/games"/,
	'the Controller Games tile opens the launcher page, not Twirl directly');
unlike($back, qr/games: '\/manager\/games'/, 'the desk does not deal the launcher as a window');
like($page, qr/\.wind\[app="games"\] \.top_navbar\s*\{[^}]*display:none/, 'the launcher hides its own window bar');

# --- the Guide ----------------------------------------------------------------
my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr/\$topic\{'games'\}\s*=\s*\{/, 'the games Guide topic exists');
like($help, qr/category => 'apps', app => 'games'/, 'the topic claims the games app page');
like($help, qr/one button for each system that holds a game/, 'the Guide describes the system filter');
like($help, qr/Systems list below the filter chooses the emulator/, 'the Guide describes the emulator picker');
like($help, qr/Fetch covers looks up a cover picture/, 'the Guide describes the cover fetch');
like($help, qr/Controls opens the controls page/, 'the Guide describes the controls page');

# --- Twirl's two turns --------------------------------------------------------
my $twirl = read_file("$root/public/js/manager/twirl.js");
like($twirl, qr/code == 124/, 'B arrives as F13 (DOM keyCode 124) and maps to a command');
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
