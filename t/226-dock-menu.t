# tests-for: public/js/manager/keyboard.js public/css/manager.css perl/help/topics_features.pl
# covers:    The dock's right-click menu and its drag-to-reorder mode. The dock
#            background opens the taskbar's own menu (same builder, same rows)
#            with Edit dock, Dock position, Show/Hide icons and Add items laid
#            above it; a face offers the same menu plus Remove from dock.
#            Add items lists the start menu's apps and the removed pseudonym
#            faces, through the same dock_apps/dock_icons merge rules the rest
#            of the dock uses. Edit dock reorders the row and keeps the order
#            per browser in dock_order, so a reload lays the faces out again.

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

# --- the menu reuses the taskbar's builder -----------------------------------
like($dock, qr/function jawnosDockContextBuild\(\)/,
	'the dock has a context-menu builder');
like($dock, qr/var base = jawnosTaskbarContextBuild\(\);/,
	'it builds on jawnosTaskbarContextBuild');
like($dock, qr/context\.append\(base\.children\(\)\);/,
	'the taskbar rows ride in the dock menu rather than a second copy');

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

# --- Add items reads the same app list as the taskbar ------------------------
like($dock, qr/jawnosTaskbarAppPins\(\)/, 'Add items reads the taskbar app pins');
like($dock, qr/jawnosTaskbarPinsFrom\(root\)/, 'a fetched start menu is read with the taskbar reader');
like($dock, qr/url: '\/manager\/start_menu'/, 'the menu fetches the start menu when it is not in the DOM');
like($dock, qr/act="dock_add_app"|'dock_add_app'/, 'an app row adds that app to the dock');
like($dock, qr/jawnosDockAppAdd\(app, row\.attr\('dock_hint'\), row\.attr\('dock_src'\)\)/,
	'the app row goes through jawnosDockAppAdd, the same merge rule as the start menu');
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
like($dock, qr/act="dock_hide_toggle"/, 'a pseudonym face is switched off in dock_icons');
like($dock, qr/jawnosDockText\('dock\.remove', 'Remove from dock'\)/,
	'the face row says Remove from dock');
like($dock, qr/menu\.prepend\(row\)/, 'the Remove row heads the face menu');

# --- the order is this browser's and survives a reload ----------------------
like($dock, qr/function jawnosDockOrder\(\)/, 'the order is read');
like($dock, qr/jawnosStore\.read\('dock_order'\)/, 'from the dock_order store');
like($dock, qr/jawnosStore\.set\('dock_order', 'order'/, 'and written per browser');
like($dock, qr/function jawnosDockOrderSave\(\)/, 'the order can be saved');
like($dock, qr/function jawnosDockOrderApply\(\)/, 'the saved order can be applied');
like($dock, qr/function jawnosDockFaceKey\(el\)/, 'a face key covers both kinds of face');
like($dock, qr/if \(app\) \{ return 'app:' \+ app; \}/, 'an added app keeps an app: key');
like($dock, qr/var toggle = el\.attr\('toggle'\);/, 'a pseudonym is keyed by its toggle');
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
like($dock, qr/\$\(document\)\.ready\(function\(\) \{\s*jawnosDockAppsRender\(\);\s*jawnosDockOrderApply\(\);/, 'ready lays the saved order out');

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
like($body, qr/Dock position/, 'the topic names Dock position');
like($body, qr/drag.*reorder|reorder/s, 'the topic explains drag-to-reorder');
like($body, qr/order is kept by this browser/i, 'the topic says the order is per browser');
like($body, qr/Remove from dock/, 'the topic still explains removing a face');
my $steps = join(' ', @{ $topic->{steps} || [] });
like($steps, qr/Right-click the dock background/, 'a step opens the background menu');
like($steps, qr/Edit dock and drag/, 'a step reorders the row');

done_testing();
