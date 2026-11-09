# tests-for: public/js/manager/windows.js public/js/manager/taskbar.js public/js/manager/taskbar_edit.js public/js/manager/taskbar_edit/01_window_events.js public/js/manager/windows/02_fit.js public/js/manager/soft_keyboard.js public/js/manager/soft_keyboard/04_eval_text.js public/css/manager.css public/css/soft_keyboard.css templates/layouts/manager.html.ep
# covers:    The taskbar's window tiles were sorted by z-index, so raising a
#            window (or opening an app on top) rearranged the bar. They now keep
#            the order they were opened in, can be dragged into another place,
#            and a window opened after a drag joins at the right. The window in
#            front wears a bright title bar and the rest are greyed, so a key
#            press's destination is visible. On a desk the on-screen keyboard
#            and calculator hold the input until another field claims it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $windows = js_source('public/js/manager/windows.js');
my $bar = js_source('public/js/manager/taskbar.js');
my $edit = js_source('public/js/manager/taskbar_edit.js');
my $kb = js_source('public/js/manager/soft_keyboard.js');
my $kb_events = js_source('public/js/manager/soft_keyboard/04_eval_text.js');
my $css = read_file("$root/public/css/manager.css");
my $kb_css = read_file("$root/public/css/soft_keyboard.css");
my $layout = read_file("$root/templates/layouts/manager.html.ep");
my $help = help_source();

# --- the list is no longer the z-order --------------------------------------
like($windows, qr/function jawnosTaskbarWindowOrderTiles\(tiles\)/,
	'the displayer has one place that orders the tiles');
unlike($windows, qr/tiles\.sort\(function\s*\(a,\s*b\)\s*\{\s*return a\.z - b\.z;\s*\}\)/,
	'the old z-index sort is gone');
like($windows, qr/jawnosTaskbarWindowOrderTiles\(tiles\);/,
	'the displayer applies the open/dragged order');
unlike($windows, qr/stamp \+= v\.z/,
	'raising a window does not change the tile stamp (no rebuild, no blink)');

# --- a tile knows which window it is, and when it opened --------------------
like($windows, qr/function jawnosTaskbarWindowKey\(v\)/,
	'a tile key is derived from the window');
like($windows, qr/return 'dialog:' \+ dialog_id;/,
	'a dialog is keyed by its own id');
like($windows, qr/return 'terminal:' \+ terminal_id;/,
	'a Terminal keeps its session key');
like($windows, qr/return 'window:' \+ window_id;/,
	'a Folders window keeps its instance key');
like($windows, qr/return 'app:' \+ app;/,
	'an ordinary app is keyed by its name');
like($windows, qr/function jawnosTaskbarWindowSeq\(v\)/,
	'open order comes from the window timestamp');
like($windows, qr/parseInt\(el\.attr\('timestamp'\), 10\)/,
	'the server-stamped open time is the sequence');

# --- a dragged order is kept, and new windows go on the right ---------------
like($windows, qr/jawnosBars\.window_order/,
	'the saved order rides jawnosBars');
like($windows, qr/jawnosTaskbarSave\('taskbar_window_order'/,
	'a stale key is pruned through the misc setting');
like($windows, qr/if \(ia === undefined && ib === undefined\) \{ return \(a\.seq - b\.seq\)/,
	'tiles with no saved key follow in open order');
like($windows, qr/if \(ia === undefined\) \{ return 1; \}/,
	'a window opened after a drag sorts to the right-hand end');

# --- the setting is seeded into the page ------------------------------------
like($bar, qr/window_order: jawnosTaskbarWindowOrderSetting\(jawnos_bar_settings\['taskbar_window_order'\]\)/,
	'taskbar.js parses the saved window order');
like($layout, qr/taskbar_window_order: <%== encode_json\(/,
	'the layout embeds the order as raw JSON');

# --- a tile drags without answering as a press ------------------------------
like($edit, qr/function jawnosTaskbarWindowDragInit\(\)/, 'the window list is made sortable');
like($edit, qr/items: '> \.window_toggle'/, 'only the window tiles are dragged');
like($edit, qr/distance: 8/, 'a press without travel is still a press');
like($edit, qr/jawnosTaskbarWindowOrderSave\(\)/, 'the drag writes the new order');
like($edit, qr/jawnosTaskbarSave\('taskbar_window_order', JSON\.stringify\(order\)\)/,
	'the dragged order is the taskbar_window_order setting');
like($windows, qr/jawnosTaskbarWindowDragAt/,
	'the click handler ignores the press that ends a drag');
like($css, qr/#taskbar_windows \.window_toggle \{ cursor: var\(--jawnos-cursor-grab, grab\); \}/,
	'a window tile reads as draggable');
like($css, qr/\.taskbar_window_placeholder/, 'the drop place has a visible placeholder');

# --- the front window keeps a bright title bar ------------------------------
like($edit, qr/function jawnosWindowFocusApply\(\)/, 'one pass marks the front window');
like($edit, qr/bar\.attr\('data-focus', \(this === top\) \? 'on' : 'off'\)/,
	'only the top window is lit');
like($edit, qr/if \(typeof jawnosWindowFocusApply == 'function'\) \{ jawnosWindowFocusApply\(\); \}/,
	'the taskbar state pass applies the focus cue');
like($css, qr/\.top_navbar\[data-focus="off"\] \{ opacity: \.62; filter: grayscale\(\.9\); \}/,
	'an unfocused title bar is greyed');

# --- on a desk the keyboard/calculator holds the input ----------------------
like($kb, qr/var jawnSoftSticky = false;/, 'the dock has a sticky focus state');
like($kb, qr/function softKbStickySet\(on\)/, 'the state can be set');
like($kb, qr/if \(softKbDesk\(\)\) \{ softKbStickySet\(true\); \}/,
	'only a desk makes the dock sticky');
like($kb, qr/#jawn_soft_keyboard'\)\.toggleClass\('soft_kb_sticky'/,
	'the sticky state reaches the stylesheet');
like($kb, qr/function softKbLiveField\(\)/,
	'a re-rendered field is found again by id instead of typing into a detached node');
like($kb, qr/var el = target \|\| softKbLiveField\(\);/, 'insertion uses the live field');
like($kb_events, qr/if \(jawnSoftSticky\) \{ return; \}/,
	'focus moving off the field does not take the dock away on a desk');
like($kb_css, qr/#jawn_soft_keyboard\.soft_kb_sticky \{ z-index: 100000; \}/,
	'the sticky dock paints over a top-level window');
like($kb, qr/softKbStickySet\(false\);\n\t\$\(\'#soft_kb_layouts\'\)/,
	'closing the dock releases the input');

# --- the guide says what the bar and keys now do ----------------------------
like($help, qr/The open windows sit in the order they were opened/,
	'the taskbar topic explains the open order');
like($help, qr/Drag a tile along the window list/,
	'the taskbar topic explains the drag');
like($help, qr/title bars are greyed/, 'the windows topic explains the focus cue');
like($help, qr/While it is up on a desk the dock keeps the input/,
	'the keyboard topic explains the sticky dock');

done_testing();
