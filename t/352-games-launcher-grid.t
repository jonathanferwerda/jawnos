# tests-for: templates/apps/games.html.ep lib/JawnOS/Controller/manager_misc9.pm
# covers:    The second launcher's eight-column shelf, the emulated tile kept
#            first, and the house games ordered by the play ledger's latest
#            visit with a fixed tie-break.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $page = read_file("$root/templates/apps/games.html.ep");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my ($action) = $controller =~ /(sub action_44004\b.*?\n\})/s;
ok($action, 'action_44004 supplies the launcher its list');

# --- the grid -----------------------------------------------------------------
my ($grid) = $page =~ /(#games_grid \{[^}]*\})/s;
ok($grid, 'the launcher grid has a rule of its own');
like($grid, qr/grid-template-columns:repeat\(8, ?minmax\(0, ?1fr\)\)/, 'eight columns, one share each');
like($grid, qr/overflow-y:auto/, 'the shelf scrolls down when it outgrows the glass');
like($grid, qr/align-content:start/, 'a short shelf starts at the top instead of stretching');
like($grid, qr/flex:1 1 auto/, 'and it takes the height the bar leaves');
like($grid, qr/min-height:0/, 'so the scrolling is real inside a flex column');
like($page, qr/\.games_tile_note \{ display:none/, 'the long note folds away at this width but stays in the markup');
like($page, qr/class="games_tile_note"><%= &subs::ui\(\$tile->\{'note'\}\) %>/,
	'and every tile still carries it');

# --- emulated first, then the house's games -----------------------------------
my $emulated_at = index($page, 'href="/manager/games?view=emulated"');
my $loop_at = index($page, 'for my $tile (@{ $tiles })');
ok($emulated_at >= 0, 'the emulated shelf tile is on the page');
ok($loop_at > $emulated_at, 'the emulated tile comes first and the house games follow it');
like($page, qr/icon_for\('\/images\/decipherable\/diskette\.png'\)/, 'it keeps the diskette icon');
like($page, qr/None installed yet/, 'and its count note');

# --- the loop is fed by the action's list ------------------------------------
like($page, qr/\$tiles = \(ref \$jawnos_games eq 'ARRAY'\)/, 'the tile loop reads the action-rendered list');
like($page, qr/href="\/manager\?open=<%=\s*\$tile->\{'key'\}\s*%>&amp;full=1&amp;back=%2Fmanager%2Fgames"/,
	'each tile opens its own game full screen and remembers the launcher');
like($page, qr/icon_for\(\$tile->\{'icon'\}\)/, 'and wears the icon the action chose');
like($page, qr/class="games_tile_label"><%=\s*&subs::ui\(\$tile->\{'title'\}\) %>/, 'the title');
unlike($page, qr/href="\/manager\?open=cards/, 'no game tile is hardcoded ahead of the recency order');

# --- the four house games -----------------------------------------------------
my %want = (
	cards       => [ 'Cards',       '/images/decipherable/cards.png' ],
	twirl       => [ 'Twirl',       '/images/decipherable/tetris.png' ],
	pipedream   => [ 'Pipedream',   '/images/decipherable/tunnel.png' ],
	minesweeper => [ 'Minesweeper', '/images/decipherable/marker.png' ],
);
foreach my $key (qw(cards twirl pipedream minesweeper)) {
	my ($title, $icon) = @{ $want{$key} };
	like($action, qr/key => '$key'/, "$key is on the shelf");
	like($action, qr/title => '$title'/, "and is titled $title");
	like($action, qr{'\Q$icon\E'}, "$title keeps its icon");
}
like($action, qr/note => 'Place the pipes before the liquid spills'/, 'Pipedream explains itself');
like($action, qr/note => 'Clear the field without hitting a mine'/, 'so does Minesweeper');

# --- recency from the play ledger ---------------------------------------------
like($action, qr/eval \{\s*&subs::db_query\(/, 'the ledger read is guarded in an eval');
like($action, qr/from appointments/, 'it reads the appointments table');
like($action, qr/app = 'games'/, 'for the games app only');
like($action, qr/project is not null and project != ''/, 'skipping a play with no project');
like($action, qr/group by project/, 'one row per game played');
like($action, qr/max\(cast\(timestamp as integer\)\) as last_at/, 'each row is its latest play');
like($action, qr/->hashes/, 'read as plain hashes');

foreach my $project ('Solitaire', 'Spider Solitaire', 'Mahjong', 'Blackjack') {
	like($action, qr/'\Q$project\E'/, "Cards' recency counts $project");
}
like($action, qr/\$game->\{'last_at'\} = \$at if \$at > \$game->\{'last_at'\}/,
	'a game takes the latest of the projects that feed it');
like($action, qr/\$b->\{'last_at'\} <=> \$a->\{'last_at'\}/, 'the list is sorted newest first');
like($action, qr/<=> \$a->\{'last_at'\}\) \|\| \(\$a->\{'rank'\} <=> \$b->\{'rank'\}/,
	'equal times fall back to the fixed rank');
like($action, qr/key => 'cards'[\s\S]*?key => 'twirl'[\s\S]*?key => 'pipedream'[\s\S]*?key => 'minesweeper'/,
	'and that rank is Cards, Twirl, Pipedream, Minesweeper');
like($action, qr/jawnos_games => \\\@jawnos_games/, 'the sorted list is handed to the page');
like($action, qr/template => 'apps\/games'/, 'which is the games template');

done_testing();
