# tests-for: templates/start_menu/htop.html.ep public/js/manager/manager/05_start_menu.js public/js/manager/keyboard/02_keyboard_maker.js public/js/manager/keyboard/01_side_dock.js public/js/manager/soft_keyboard.js public/css/manager.css public/css/soft_keyboard.css perl/help/topics_features.pl perl/help/topics_functions.pl
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
my $menu = js_source('public/js/manager/manager/05_start_menu.js');
my $maker = js_source('public/js/manager/keyboard/02_keyboard_maker.js');
my $dock = js_source('public/js/manager/keyboard/01_side_dock.js');
my $soft = js_source('public/js/manager/soft_keyboard.js');
my $manager_css = read_file($root . '/public/css/manager.css');
my $soft_css = read_file($root . '/public/css/soft_keyboard.css');
my $features_help = help_source();
my $functions_help = read_file($root . '/perl/help/topics_functions.pl');

# --- a machine's card opens remote_control on that machine -------------------
like($htop, qr/class="level_tile remote_control_open hover/,
	'a peer card is the remote-control opener');
like($htop, qr/machine="<%= \$m->\{'signatorial'\} %>"/,
	'the card names the peer it opens');
like($htop, qr/hint="<%= &subs::ui\('Open Remote control for this machine'\) %>"/,
	'the card says what the press does');
like($menu, qr/\$\(document\)\.on\('click', '\.remote_control_open'/,
	'the System page has the opener handler');
like($menu, qr/keyboardMaker\(\{ toggle: 'remote_control', state: 'on', remote_uuid: machine \}\)/,
	'it opens the remote_control panel with that machine picked');
like($menu, qr/settingSetter\(\{ 'app': 'me', 'setting': 'remote_control_machine', 'value': machine \}\)/,
	'the pick is saved for the next open');
like($menu, qr/if \(\$\('#start_menu'\)\.is\(':visible'\)\) \{ startMenuToggle\(\); \}/,
	'the press puts the start menu away');
like($maker, qr/\$\('#remote_control_machine_select option'\)\.filter\(function\(\) \{ return this\.value === remote_uuid; \}\)/,
	'a signatorial pick leaves the server\'s uuid selection in the picker');

# --- a panel that was never moved gets a default floating spot ---------------
like($maker, qr/function keyboardPanelDefaultCSS\(panel\)/,
	'the default spot has one helper');
like($maker, qr/var limit = \(typeof panelTopLimit === 'function'\) \? panelTopLimit\(\) : 0;/,
	'the default starts under the clothesline ceiling');
like($maker, qr/'position': 'fixed',/,
	'a fresh panel floats rather than sitting in the page flow');
like($maker, qr/top = Math\.max\(limit, Math\.min\(top, Math\.max\(limit, vh - height - bar - 8\)\)\);/,
	'the default spot is never above the viewport or off the foot of it');
like($maker, qr/'max-height': Math\.max\(120, vh - limit - bar - 16\) \+ 'px'/,
	'its height is capped to the room under the clothesline');
like($maker, qr/t\.attr\('default_placed', 'yes'\);/,
	'a panel in its default spot is marked as such');
like($maker, qr/\$\('\.keyboard\[default_placed="yes"\]:visible'\)/,
	'the default spot follows a reshaped screen');
like($maker, qr/t\.attr\('claimed', 'yes'\);\s*keyboardDragBarMaker\(t\);/s,
	'the framed panel still gets its drag bar');

# --- a restored panel obeys the same ceiling --------------------------------
like($maker, qr/function keyboardPanelClamp\(panel, css\)/,
	'a saved spot is clamped before it is painted');
like($maker, qr/if \(isFinite\(top\) && top < limit\) \{ css\['top'\] = limit \+ 'px'; \}/,
	'a saved panel cannot start above the clothesline');
like($maker, qr/if \(css\['position'\] != 'fixed'\) \{ css\['position'\] = 'fixed'; \}/,
	'an older in-flow save comes back as a floating panel');
like($maker, qr/t\.removeAttr\('default_placed'\);/,
	'a moved panel stops following the screen');

# --- dragging a keyboard panel stays on the screen --------------------------
like($dock, qr/ui\.position\.top = Math\.max\(panelTopLimit\(\), Math\.min\(ui\.position\.top, vh - height - bar\)\);/,
	'a dragged panel stops at the clothesline and the taskbar');
like($dock, qr/ui\.position\.left = Math\.max\(0, Math\.min\(ui\.position\.left, vw - width\)\);/,
	'a dragged panel stays on the screen sideways');
like($dock, qr/panel\.removeAttr\('default_placed'\);/,
	'taking hold of a panel claims its spot');

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
like($features_help, qr/A press on a peer\\'s card opens the Assistant\\'s remote_control panel already pointed at that machine/,
	'the start-menu topic names the door');
like($functions_help, qr/a press on a peer\\'s card on the start menu\\'s System page opens it already pointed at that machine/,
	'the remote_control topic names the door');

done_testing();
