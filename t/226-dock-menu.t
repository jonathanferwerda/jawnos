# tests-for: public/js/manager/keyboard.js public/js/manager/keyboard/01_side_dock.js public/js/manager/keyboard/02_music_and_handlers.js public/js/manager/taskbar.js public/js/manager/taskbar/01_inputs.js public/js/manager/taskbar_edit.js public/js/manager/taskbar_edit/01_window_events.js public/css/manager.css templates/layouts/manager.html.ep templates/configure/misc_setting_list.html.ep perl/help/topics_features.pl perl/language/en.pl
# covers:    The dock's right-click menu and its drag-to-reorder mode. The dock
#            background opens the dock's own menu - Edit dock, Dock position,
#            Show/Hide icons, Open windows, Transparent and Add items - and
#            nothing from the taskbar, whose menu stays on the bar. Add items is
#            a flyout beside the menu (right, or left when that edge is short),
#            so a dock along the bottom never pushes the list off the screen.
#            The menu animates in and puts itself away after an idle spell.
#            The dock's pins and widgets are its own list (dock_pins), seeded
#            once from the taskbar's faces; adding or removing one changes the
#            dock alone. Open windows ride the row as faces while dock_windows
#            is on, a pinned app's own window being left to its pin. Only the
#            pseudonym order is per browser (dock_order).

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $dock = js_source('public/js/manager/keyboard.js');
my $css  = read_file("$root/public/css/manager.css");

# --- the menu is the dock's own ---------------------------------------------
like($dock, qr/function jawnosDockContextBuild\(\)/,
	'the dock has a context-menu builder');
unlike($dock, qr/jawnosTaskbarContextBuild\(\)/,
	'the dock menu does not build on the taskbar menu');
unlike($dock, qr/dock\.taskbar/,
	'and carries no taskbar heading');

# --- a background right-click opens it --------------------------------------
like($dock, qr/\$\(document\)\.on\('contextmenu', '#pseudonym_home', function\(e\) \{/,
	'a right-click on the dock background is taken');
like($dock, qr/jawnosDockMenuPlace\(jawnosDockContextBuild\(\), e\.clientX, e\.clientY\);/,
	'and opens the dock menu');

# --- the dock's own rows ----------------------------------------------------
like($dock, qr/act="dock_edit"/, 'Edit dock is offered');
like($dock, qr/jawnosDockText\('dock\.edit', 'Edit dock'\)/, 'and named on screen');
like($dock, qr/act="dock_add"/, 'Add items is offered');
like($dock, qr/jawnosDockText\('dock\.add_items', 'Add items'\)/, 'and named on screen');
like($dock, qr/act="dock_pos"/, 'Dock position rows are offered');
like($dock, qr/\['bottom', 'Bottom'\], \['top', 'Top'\], \['left', 'Left'\], \['right', 'Right'\], \['hidden', 'Hidden'\]/,
	'all five dock positions are offered');
like($dock, qr/act="dock_icons"/, 'the icon row can be switched');
like($dock, qr/jawnosDockText\('dock\.show_icons', 'Show icons'\)/,
	'a hidden row offers Show icons');
like($dock, qr/jawnosDockText\('dock\.hide_icons', 'Hide icons'\)/,
	'a shown row offers Hide icons');
like($dock, qr/act="dock_transparent"/, 'Transparent is offered');
like($dock, qr/jawnosDockText\('dock\.transparent', 'Transparent'\)/,
	'and named on screen');
like($dock, qr/function jawnosDockTransparentSet\(state\)/,
	'the dock backing has one setter');
like($dock, qr/jawnosBars\.transparent = state/, 'it moves the live setting');
like($dock, qr/jawnosTaskbarSave\('dock_transparent', state\)/,
	'and writes the dock_transparent setting');

# --- Add items is a flyout beside the menu ----------------------------------
like($dock, qr/function jawnosDockFlyoutToggle\(row, menu\)/,
	'Add items opens a flyout beside its menu');
like($dock, qr/context\.data\('dock_add_panel', add\)/,
	'the menu keeps its flyout for the row');
like($dock, qr/right_edge \+ w <= vw - 4/, 'it opens to the right when that edge has room');
like($dock, qr/left_edge >= 4/, 'and to the left otherwise');
like($dock, qr/dock_add_flyout/, 'the flyout has its own class');
unlike($dock, qr/taskbar_context_sub\[sub="dock_add"\]/, 'the old inline submenu is gone');
like($dock, qr/'max-height': \(vh - top - 4\) \+ 'px'/, 'the flyout is clamped on screen');

# --- the menu animates in and has an idle timeout ---------------------------
like($dock, qr/var jawnosDockMenuWait = 8000;/, 'the dock menu has an idle wait');
like($dock, qr/function jawnosDockMenuArm\(\)/, 'opening the menu arms the timeout');
like($dock, qr/function jawnosDockMenuFade\(\)/, 'an expired menu fades away');
like($dock, qr/jawnosDockMenuArm\(\);/, 'a press or a move starts the wait again');
like($css, qr/\.taskbar_context\s*\{[^}]*animation: jawnos_context_in/s,
	'the menu animates in');
like($css, qr/\.taskbar_context\.taskbar_context_closing/,
	'and carries a closing state');
like($css, qr/#pseudonym_home\.dock_transparent\s*\{[^}]*background-color: transparent/s,
	'Transparent steps the dock backing aside');
like($css, qr/\.dock_add_flyout/, 'the flyout is styled');
like($css, qr/prefers-reduced-motion/, 'reduced motion skips the animation');

# --- the dock's pins and widgets are its own list ---------------------------
like($dock, qr/function jawnosDockApps\(\)/, 'the dock has one reader for its app and widget faces');
like($dock, qr/function jawnosDockPins\(\)/, 'the dock has its own pin list');
like($dock, qr/function jawnosDockPinsEnsure\(\)/, 'which is seeded once');
like($dock, qr/function jawnosDockTaskbarOrder\(\)/, 'the seed reads the taskbar order');
like($dock, qr/item\.k == 'pin'/, 'a pin becomes a face');
like($dock, qr/item\.k == 'widget'/, 'a widget becomes a face too');
like($dock, qr/jawnosTaskbarSave\('dock_pins'/, 'the list is written as dock_pins');
like($dock, qr/function jawnosDockAppHas\(app\)/, 'an app face asks the dock list');
unlike($dock, qr/jawnosTaskbarAppPinned/, 'not the taskbar pin');
like($dock, qr/function jawnosDockWidgetHas\(w\)/, 'a widget face asks the dock list too');
unlike($dock, qr/jawnosTaskbarWidgetToggle/, 'not the taskbar widget setting');
like($dock, qr/function jawnosDockWidgetOpen\(w\)/, 'a widget face opens the app it stands for');
like($dock, qr/jawnosDockAppAdd\(app, info\.hint \|\| app, info\.src \|\| ''\)/,
	'a browser\'s old dock apps are carried onto the dock');
like($dock, qr/remote_control: 1/, 'the retired remote control face is not offered back');

# --- open windows ride the dock too ------------------------------------------
like($dock, qr/act="dock_windows"/, 'Open windows is offered');
like($dock, qr/jawnosDockText\('dock\.open_windows', 'Open windows'\)/, 'and named on screen');
like($dock, qr/function jawnosDockWindowsSet\(state\)/, 'the window faces have one switch');
like($dock, qr/jawnosTaskbarSave\('dock_windows', state\)/, 'which is written away');
like($dock, qr/function jawnosDockWindowFaces\(\)/, 'the open windows are read as faces');
like($dock, qr/jawnosTaskbarWindowKey/, 'a face carries the taskbar window key');
like($dock, qr/function jawnosDockWindowPress\(icon\)/, 'a press answers for its window');
like($dock, qr/jawnosDockWindowTile\(key\)/, 'through the taskbar tile when it exists');
like($dock, qr/function jawnosDockWindowsState\(\)/, 'the faces wear the window state');
like($dock, qr/if \(\$\(this\)\.hasClass\('dock_window'\)\)/, 'the press handler knows a window face');
like($dock, qr/jawnosDockWindowsRender\(\)/, 'the window faces can be rebuilt');
like($dock, qr/!t\.terminal && !t\.window && !t\.dialog && t\.app && jawnosDockAppHas\(t\.app\)/,
	'a pinned app\'s own window is left to its pin');
like($css, qr/\.pseudonym\.dock_window\[state=active\]/,
	'an active window face is marked');
like($css, qr/\.pseudonym\.dock_window\[state=minimized\]/,
	'and a minimized one dims');

# --- Add items uses the start menu's list, and adds to the dock alone --------
like($dock, qr/jawnosTaskbarAppPins\(\)/, 'Add items reads the start menu app list');
like($dock, qr/jawnosTaskbarPinsFrom\(root\)/, 'a fetched start menu is read with the taskbar reader');
like($dock, qr/url: '\/manager\/start_menu'/, 'the menu fetches the start menu when it is not in the DOM');
like($dock, qr/act="dock_add_app"|'dock_add_app'/, 'an app row adds that app to the dock');
like($dock, qr/jawnosDockAppAdd\(app, row\.attr\('dock_hint'\), row\.attr\('dock_src'\)\)/,
	'the app row goes through jawnosDockAppAdd, the dock\'s own list');
like($dock, qr/'dock_widget_toggle'/, 'a widget row toggles the dock\'s own widget');
like($dock, qr/selected\(jawnosDockWidgetHas\(w\)\)/, 'the widget check marks the dock list');
like($dock, qr/jawnosDockText\('dock\.widgets', 'Widgets'\)/, 'the widget rows have their own heading');
like($dock, qr/'dock_show_toggle'/, 'a removed pseudonym face is listed to be put back');
like($dock, qr/class="taskbar_context_selection dock_context_app"/,
	'dock add rows are dock rows, not the taskbar add list that pins to the bar');
like($dock, qr/jawnosDockIconState\(toggle\) == 'on'/, 'only switched-off pseudonyms are listed');
like($dock, qr/jawnosDockText\('dock\.removed_faces', 'Removed faces'\)/,
	'those rows carry their own heading');

# --- position and icons write the existing settings --------------------------
like($dock, qr/function jawnosDockPositionSet\(pos\)/,
	'the dock position has one setter');
like($dock, qr/jawnosBars\.dock = pos/, 'it moves the live dock edge');
like($dock, qr/jawnosTaskbarSave\('dock_position', pos\)/,
	'and writes the dock_position setting through the same route');
like($dock, qr/function jawnosDockIconsSet\(state\)/,
	'the icon row has one setter');
like($dock, qr/jawnosBars\.icons = state/, 'it moves the live icon state');
like($dock, qr/jawnosTaskbarSave\('dock_icons', state\)/,
	'and writes the dock_icons setting');

# --- a face's menu still removes that face ----------------------------------
like($dock, qr/\$\(document\)\.on\('contextmenu', '#pseudonym_bar \.pseudonym', function\(e\) \{/,
	'a dock face has its own right-click');
like($dock, qr/var menu = jawnosDockContextBuild\(\);/, 'the face gets the same menu');
like($dock, qr/act="dock_app_remove"/, 'an app face can be removed');
like($dock, qr/act="dock_widget_remove"/, 'a widget face can be disabled');
like($dock, qr/act="dock_launcher_remove"/, 'a launcher pin can be removed');
like($dock, qr/act="dock_hide_toggle"/, 'a pseudonym face is switched off in dock_icons');
like($dock, qr/jawnosDockText\('dock\.remove', 'Remove from dock'\)/,
	'the face row says Remove from dock');
like($dock, qr/menu\.prepend\(row\)/, 'the Remove row heads the face menu');

# --- the pseudonym order is this browser's ----------------------------------
# The taskbar's faces keep the bar's order; dock_order must not move them.
like($dock, qr/function jawnosDockOrder\(\)/, 'the order is read');
like($dock, qr/jawnosStore\.read\('dock_order'\)/, 'from the dock_order store');
like($dock, qr/jawnosStore\.set\('dock_order', 'order'/, 'and written per browser');
like($dock, qr/function jawnosDockOrderSave\(\)/, 'the order can be saved');
like($dock, qr/children\('\.draggable_icon'\)\.not\('\.dock_taskbar_face, \.dock_window_face'\)/,
	'the dock\'s own faces and the windows are left out of the saved order');
like($dock, qr/function jawnosDockOrderApply\(\)/, 'the saved order can be applied');
like($dock, qr/function jawnosDockFaceKey\(el\)/, 'a face key covers both kinds of face');
like($dock, qr/if \(app\) \{ return 'app:' \+ app; \}/, 'an added app keeps an app: key');
like($dock, qr/var toggle = el\.attr\('toggle'\);/, 'a pseudonym is keyed by its toggle');
like($dock, qr/hasClass\('dock_taskbar_face'\) \|\| \$\(w\)\.hasClass\('dock_window_face'\)/,
	'the applier leaves the dock\'s own faces in their own order');
my ($render) = $dock =~ /function jawnosDockAppsRender\(\) \{(.*?)\n\}/s;
ok(defined $render && length $render, 'the app renderer is found');
like($render, qr/jawnosDockOrderApply\(\);/, 'the app renderer applies the saved order');
my ($apply) = $dock =~ /function jawnosDockOrderApply\(\) \{(.*?)\n\}/s;
ok(defined $apply && length $apply, 'the order applier is found');
like($apply, qr/bar\.children\('\.draggable_icon'\)/, 'it sorts the wrappers in the bar');
like($apply, qr/bar\.append\(w\)/, 'and moves them into the saved order');

# --- Edit dock drags the row, keeps the per-icon drag and slide --------------
like($dock, qr/function jawnosDockEdit\(on\)/, 'Edit dock toggles a mode');
like($dock, qr/home\.toggleClass\('dock_edit', !!on\)/, 'the mode marks the dock');
like($dock, qr/function jawnosDockReorderAt\(x, y, drag\)/, 'a dragged face finds its place');
like($dock, qr/getBoundingClientRect\(\)/, 'it measures the faces as laid out');
like($dock, qr/function jawnosDockDragStart\(x, y, target\)/, 'the reorder drag starts');
like($dock, qr/function jawnosDockDragMove\(x, y\)/, 'and follows the pointer');
like($dock, qr/function jawnosDockDragEnd\(\)/, 'and saves on release');
like($dock, qr/jawnosDockOrderSave\(\);/, 'the drop keeps the order');
like($dock, qr/draggable\('disable'\)/, 'the free per-icon drag stands down while editing');
like($dock, qr/draggable\('enable'\)/, 'and comes back when the mode ends');
like($dock, qr/jawnosDockDragBind\(\)/, 'the drag handlers are bound once');
like($dock, qr/\$\(document\)\.ready\(function\(\) \{\s*jawnosDockMigrateApps\(\);\s*jawnosDockAppsRender\(\);\s*jawnosDockWindowsRender\(\);\s*jawnosDockOrderApply\(\);/, 'ready migrates the old faces, draws the pins and windows, and lays the saved order out');

# --- the mode and its drag are styled ---------------------------------------
like($css, qr/#pseudonym_home\.dock_edit #pseudonym_bar \.pseudonym\.bar/,
	'Edit dock styles the faces as the thing being reordered');
like($css, qr/#pseudonym_home\.dock_edit\.dock_dragging/,
	'the dragging state has its own cursor');
like($css, qr/\.dock_context_app img/, 'the dock add rows size their icons');

# --- the help topic is in the on-screen words -------------------------------
require "$root/perl/help.pl";
my $topic = $help::topic{'dock'};
ok($topic, 'the dock topic exists');
my $body = join(' ', @{ $topic->{body} || [] });
like($body, qr/Right-click.*background.*menu/s, 'the topic names the background menu');
like($body, qr/Edit dock/, 'the topic names Edit dock');
like($body, qr/Add items/, 'the topic names Add items');
like($body, qr/Transparent/, 'the topic names Transparent');
like($body, qr/opens a list beside the menu/, 'the topic says Add items is a flyout');
unlike($body, qr/the taskbar's own rows underneath/, 'the dock topic no longer lends the menu taskbar rows');
like($body, qr/Dock position/, 'the topic names Dock position');
like($body, qr/drag.*reorder|reorder/s, 'the topic explains drag-to-reorder');
like($body, qr/faces are the keyboard panels, its own pinned apps and widgets, and the open windows/, 'the topic says the dock has its own pins and windows');
like($body, qr/Open windows turns the open-window faces on and off/, 'the topic names Open windows');
like($body, qr/an app can be pinned to the dock, and a widget can be put on or taken off the dock/, 'the topic says Add items changes the dock alone');
like($body, qr/the taskbar is left as it is/, 'the topic says removing a face leaves the bar alone');
like($body, qr/adding one under Add items puts a face here and nothing on the taskbar/, 'the topic says the dock\'s list is its own');
like($body, qr/restores a minimized window, raises one behind, or minimizes the one in front/, 'the topic explains the window faces');
like($body, qr/Remove from dock/, 'the topic still explains removing a face');
my $steps = join(' ', @{ $topic->{steps} || [] });
like($steps, qr/Right-click the dock background/, 'a step opens the background menu');
like($steps, qr/Open windows/, 'a step names Open windows');
like($steps, qr/Transparent/, 'a step names Transparent');
like($steps, qr/those choices change the dock alone/, 'a step says Add items changes the dock alone');
like($steps, qr/Edit dock and drag/, 'a step reorders the row');

done_testing();
