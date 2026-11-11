# tests-for: templates/start_menu/htop.html.ep public/js/manager/manager/05_start_menu.js public/js/manager/network/02_tabs_bluetooth_remote.js templates/apps/network.html.ep public/js/manager/keyboard/01_side_dock.js public/js/manager/soft_keyboard.js public/css/manager.css public/css/soft_keyboard.css perl/help/topics_features.pl perl/help/topics_functions.pl
# covers:    A machine's card on the start menu's System page is a door to that
#            machine: it opens the Assistant's remote_control panel already
#            pointed at the peer. A keyboard panel that has never been moved now
#            opens in a default floating spot instead of the page's flow, wears
#            the same frame as every window, and neither it nor the floating
#            keyboard/calculator can start above the clothesline or the viewport.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $htop = read_file($root . '/templates/start_menu/htop.html.ep');
like($htop, qr/\$u->\{'cores'\}/, 'the usage line shows the core count');
like($htop, qr/\$u->\{'mem_total_kb'\}/, 'the usage line shows the RAM total');
like($htop, qr/no battery sensor/, 'a controller with no gauge says so');
my $menu = js_source('public/js/manager/manager/05_start_menu.js');
my $dock = js_source('public/js/manager/keyboard/01_side_dock.js');
my $soft = js_source('public/js/manager/soft_keyboard.js');
my $manager_css = read_file($root . '/public/css/manager.css');
my $soft_css = read_file($root . '/public/css/soft_keyboard.css');
my $features_help = help_source();
my $functions_help = read_file($root . '/perl/help/topics_functions.pl');

# --- a machine's card opens remote_control on that machine -------------------
like($htop, qr/class="level_tile level_you remote_control_open hover" machine=""/,
	'this machine\'s card opens the Me view too');
like($htop, qr/class="level_tile remote_control_open hover/,
	'a peer card is the remote-control opener');
like($htop, qr/machine="<%= \$m->\{'signatorial'\} %>"/,
	'the card names the peer it opens');
like($htop, qr/hint="<%= &subs::ui\('Open Remote control in the Network app'\) %>"/,
	'the card says what the press does');
like($menu, qr/\$\(document\)\.on\('click', '\.remote_control_open'/,
	'the System page has the opener handler');
like($menu, qr/appWindowOpener\('network'/, 'it opens the Network app');
like($menu, qr/networkTabShow\('remote', true\)/, 'on its Remote Machines tab');
like($menu, qr/network_remote_toggle/, 'and expands that machine\'s accordion');
like($menu, qr/if \(\$\('\#start_menu'\)\.is\(':visible'\)\) \{ startMenuToggle\(\); \}/,
	'the press puts the start menu away');

# The levels tiles are ordered by name, then address, so a peer or a board does
# not jump around the card between answers.
like($htop, qr/\@peers = sort \{[\s\S]*?lc\(\$a->\{'hostname'\}[\s\S]*?ip_sort_key/,
	'peers sort by name, then address');
like($htop, qr/\@devices = sort \{[\s\S]*?lc\(\$a->\{'name'\}[\s\S]*?ip_sort_key/,
	'devices sort by name, then address too');
my $net_tabs = js_source('public/js/manager/network/02_tabs_bluetooth_remote.js');
like($net_tabs, qr/select\.val\(uuid\)/, 'the accordion picks the row\'s machine');
like($net_tabs, qr/function networkRemoteControlOpen/, 'and moves the shared panel under the row');

# --- dragging a keyboard panel stays on the screen --------------------------
like($dock, qr/ui\.position\.top = Math\.max\(panelTopLimit\(\), Math\.min\(ui\.position\.top, vh - height - bar\)\);/,
	'a dragged panel stops at the clothesline and the taskbar');
like($dock, qr/ui\.position\.left = Math\.max\(0, Math\.min\(ui\.position\.left, vw - width\)\);/,
	'a dragged panel stays on the screen sideways');
like($dock, qr/panel\.removeAttr\('default_placed'\);/,
	'taking hold of a panel claims its spot');
like($dock, qr/\$\( "\.pseudonym" \)\.draggable\(\{\s*distance: 4,/,
	'a dock face waits for a real move before it drags, so its first click opens it');

# --- a panel wears the window frame ----------------------------------------
like($manager_css, qr/#keyboard_container \.keyboard \{[^}]*border-width:var\(--window_border, 3px\)/s,
	'the keyboard panel takes the Window Border width');
like($manager_css, qr/#keyboard_container \.keyboard \{[^}]*border-color:var\(--window_border_colour, var\(--line\)\)/s,
	'and its colour');
like($manager_css, qr/#keyboard_container \.keyboard \{[^}]*display:block/s,
	'it is a block, so the frame encloses the contents');
like($manager_css, qr/#keyboard_container \.keyboard \{[^}]*box-shadow:/s,
	'and it floats over the desk');
like($manager_css, qr/\.pseudonym\.bar \{[^}]*border: 1px solid var\(--line\)/s,
	'the dock icons keep their own thin tile edge');

# --- the keyboard/calculator dock shares the frame and the ceiling ----------
like($soft_css, qr/\.soft_kb\.soft_kb_floating \{[^}]*border: var\(--window_border, 3px\) solid var\(--window_border_colour, var\(--line\)\)/s,
	'the floating keyboard and calculator wear the same frame too');
like($soft, qr/dock\.css\('max-height', Math\.max\(180, vh - limit - bar - 16\) \+ 'px'\);/,
	'the dock is capped to the room under the clothesline');
like($soft, qr/var top = Math\.max\(limit, Math\.min\(saved\.top, Math\.max\(limit, vh - height - bar\)\)\);/,
	'its saved spot never starts above the clothesline');
like($soft, qr/ui\.position\.top = Math\.max\(limit, Math\.min\(ui\.position\.top, Math\.max\(limit, vh - height - bar\)\)\);/,
	'a dock drag obeys the same ceiling');
like($soft, qr/top = Math\.max\(limit, Math\.min\(top, Math\.max\(limit, \$\(window\)\.height\(\) - height - bar\)\)\);/,
	'its saved spot is written back inside the screen');

# --- the guide says so ------------------------------------------------------
like($features_help, qr/Network app\\'s Remote Machines tab with that machine\\'s Remote control accordion open/,
	'the start-menu topic names the door');
like($features_help, qr/this machine\\'s own card opens the same tab/,
	'the start-menu topic names this machine\'s own door');
like($functions_help, qr/opens the tab with that machine\\'s accordion already expanded/,
	'the remote_control topic names the door');
like($functions_help, qr/this machine\\'s own card opens the tab too/,
	'the remote_control topic names this machine\'s card');

done_testing();
