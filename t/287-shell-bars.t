# tests-for: public/js/manager/shell_layout.js public/js/manager/shell_workspaces.js public/js/manager/taskbar.js public/js/manager/taskbar_edit.js public/js/manager/taskbar_edit/01_window_events.js public/js/manager/keyboard.js public/js/manager/windows.js public/js/manager/windows/01_storage.js public/css/manager.css templates/manager.html.ep templates/pseudonyms.html.ep templates/layouts/manager.html.ep lib/JawnOS/Manager/Core1_tables_hooks.pm public/icons/workspaces.svg perl/help/topics_features.pl
# covers:    More than one workspace, taskbar and dock. A bar added in edit mode
#            takes the next free edge; every bar can be dragged by the grip on
#            its left side to an edge (locked) or into the open (floating), and
#            the layout is kept in the shell_layout misc setting.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $shell = read_file("$root/public/js/manager/shell_layout.js");
my $edit = read_file("$root/public/js/manager/taskbar_edit.js");
my $events = read_file("$root/public/js/manager/taskbar_edit/01_window_events.js");
my $dock = read_file("$root/public/js/manager/keyboard.js");
my $taskbar = read_file("$root/public/js/manager/taskbar.js");
my $css = read_file("$root/public/css/manager.css");
my $page = read_file("$root/templates/manager.html.ep");
my $pseudonyms = read_file("$root/templates/pseudonyms.html.ep");
my $layout = read_file("$root/templates/layouts/manager.html.ep");
my $core = read_file("$root/lib/JawnOS/Manager/Core1_tables_hooks.pm");

# --- the state: workspaces, each with its own bars --------------------------
like($shell, qr/var jawnosShell = \{/, 'the shell layer has its own state');
like($shell, qr/function jawnosShellLayout\(\)/, 'the layout has one reader');
like($shell, qr/function jawnosShellSeed\(\)/, 'a first load seeds one workspace');
like($shell, qr/workspaces: \[\s*\{ id: 'ws-main', name: 'Main', bars: \[taskbar, dock\] \}/s,
	'with the page\'s own taskbar and dock');
like($shell, qr/function jawnosShellWorkspaceAdd\(kind, extra\)/, 'a workspace can be added');
like($shell, qr/function jawnosShellWorkspaceSet\(id\)/, 'and switched');
like($shell, qr/function jawnosShellWorkspaceRows\(context\)/, 'the menus list the workspaces');
like($shell, qr/act="shell_ws"/, 'with a row per workspace');
like($shell, qr/act="shell_ws_add"/, 'and an Add workspace row');
like($shell, qr/var jawnosShellMaxWorkspaces = 7;/, 'the switcher offers seven workspaces at most');
like($shell, qr/layout\.workspaces\.length >= jawnosShellMaxWorkspaces/, 'the cap is enforced when one is added');
like($shell, qr/function jawnosShellWorkspaceRemove\(id\)/, 'a workspace beyond the first can be removed');
like($shell, qr/act="shell_ws_remove"/, 'and the menu offers it');
like($shell, qr/jawnosTaskbarSave\('shell_layout'/, 'the layout is written as shell_layout');
like($layout, qr/shell_layout: <%== encode_json\(eval \{ decode_json\(&subs::misc_setting\('shell_layout'\)\) \} \|\| undef\) %>/,
	'and seeded into the page as JSON');

# --- add a taskbar from the taskbar menu, add a dock from the dock menu -----
like($edit, qr/if \(editing\) \{\s*context\.append\('<div class="taskbar_context_selection" act="shell_add_bar" kind="taskbar">' \+ jawnosT\('Add taskbar'\)/s,
	'Add taskbar is offered in edit mode');
like($edit, qr/act="shell_remove_bar"/, 'an added bar can be removed');
like($dock, qr/if \(jawnosDockEditing\(\)\) \{\s*context\.append\('<div class="taskbar_context_selection" act="shell_add_bar" kind="dock">'/s,
	'Add dock is offered in Edit dock');
like($dock, qr/jawnosDockText\('dock\.add_dock', 'Add dock'\)/, 'and named on screen');
like($events, qr/act == 'shell_add_bar'/, 'the press adds the bar kind it names');
like($events, qr/jawnosShellBarAdd\(\$\(this\)\.attr\('kind'\) \|\| 'taskbar'\)/, 'through the shell');
like($events, qr/act == 'shell_ws_remove'/, 'the menu\'s remove row is handled');
like($events, qr/jawnosShellWorkspaceRemove\(ws\.id\)/, 'and removes the desk in front');
like($shell, qr/function jawnosShellBarAdd\(kind\)/, 'the shell adds a bar');
like($shell, qr/function jawnosShellFreeEdge\(workspace, kind\)/, 'on the next free edge');
like($shell, qr/var edges = kind == 'taskbar' \? \['bottom', 'top'\] : jawnosShellEdges;/,
	'a taskbar looks for a horizontal edge only');
like($shell, qr/function jawnosShellBarRemove\(id\)/, 'and removes an added one');

# --- the drag handle, on the left side, in edit mode only -------------------
like($shell, qr/function jawnosShellHandleEnsure\(el\)/, 'every bar gets a grip');
like($shell, qr/class="jawnos_bar_handle"/, 'the grip is a handle');
like($shell, qr/function jawnosShellDragStart\(x, y, handle\)/, 'the grip starts a drag');
like($shell, qr/function jawnosShellDragMove\(x, y\)/, 'follows the pointer');
like($shell, qr/function jawnosShellDragEnd\(\)/, 'and settles on release');
like($shell, qr/function jawnosShellSnapEdge\(x, y, kind, el\)/, 'the pointer can snap to an edge');
like($shell, qr/jawnosBars\.taskbar = 'floating';/, 'a legacy side-pinned taskbar is rescued to a float');
like($shell, qr/jawnosTaskbarSave\('taskbar_position', 'floating'\)/, 'and the legacy setting is corrected');
like($shell, qr/if \(kind != 'taskbar'\) \{.*?near\.left = x;/s,
	'a taskbar only takes a top or bottom edge');
like($shell, qr/near\.bottom = h - rect\.bottom;/, 'a dock is judged by its own box');
like($shell, qr/function jawnosShellSnapFor\(kind, x, y, el\)/, 'a drag asks where it would land');
like($shell, qr/align = 'left'/, 'a dock near the left of its edge snaps left');
like($shell, qr/align = 'right'/, 'near the right it snaps right');
like($shell, qr/align = 'center'/, 'near the centre it snaps centre');
like($shell, qr/else \{ edge = null; \}/, 'between the anchors the dock stays free');
like($shell, qr/function jawnosShellSnapShow\(edge, align\)/, 'the edge and its anchor are previewed');
like($shell, qr/if \(drag\.edge\) \{/, 'a drop near an edge locks the bar there');
like($shell, qr/desc\.mode = 'floating';/, 'an open drop floats it');
like($css, qr/\.jawnos_bar_handle\s*\{[^}]*position: absolute/s, 'the grip sits on the bar');
like($css, qr/left: 3px;/, 'on its left side');
like($css, qr/\.jawnos_taskbar\.taskbar_edit > \.jawnos_bar_handle,/, 'a taskbar grip shows in edit mode');
like($css, qr/\.jawnos_dock\.dock_edit > \.jawnos_bar_handle/, 'and a dock grip in Edit dock');
like($css, qr/\.jawnos_dock:not\(#pseudonym_home\)\[position="bottom"\]\[align="left"\]/,
	'an added dock can sit at the left of its edge');
like($css, qr/\.jawnos_dock:not\(#pseudonym_home\)\[position="bottom"\]\[align="right"\]/,
	'or at its right');
like($shell, qr/desc\.align = \(drag\.edge == 'top' \|\| drag\.edge == 'bottom'\)/,
	'a dock keeps the anchor the drop chose');
like($shell, qr/found\.bar\.align = found\.bar\.align \|\| 'center'/, 'a dock position defaults its anchor to centre');
unlike($edit, qr/\['top', 'bottom', 'left', 'right', 'hidden'\]/, 'a taskbar menu offers no side edge');
like($css, qr/\.jawnos_snap_preview\.on\s*\{\s*display: block/, 'the snap preview is drawn');

# --- an edge bar and a floating bar are placed differently ------------------
like($shell, qr/function jawnosShellPlace\(el, desc\)/, 'a bar has one placement function');
like($shell, qr/el\.attr\('position', 'floating'\)/, 'a floating bar carries the floating position');
like($shell, qr/el\.attr\('position', edge\);/, 'an edge bar carries its edge');
like($css, qr/#taskbar\[position="left"\], \.jawnos_taskbar\[position="left"\]/,
	'a taskbar can take a side edge');
like($css, qr/#taskbar\[position="floating"\], \.jawnos_taskbar\[position="floating"\]/,
	'a floating taskbar keeps a box');
like($css, qr/\.jawnos_dock:not\(#pseudonym_home\)\[position="bottom"\]/,
	'an added dock is centred on its edge');
like($css, qr/\.jawnos_dock:not\(#pseudonym_home\)\[position="left"\]/,
	'and stacks on a side edge');

# --- the added bars carry the desk's live content ---------------------------
like($shell, qr/function jawnosShellTaskbarSync\(\)/, 'added taskbars are kept current');
like($shell, qr/taskbarDisplayer\(windows\)/, 'each reads the same open windows');
like($shell, qr/clone\(true\)/, 'and copies the pins and widgets with their handlers');
like($shell, qr/data-role="icons"/, 'an added taskbar carries the start and lock slot');
like($shell, qr/start_menu_toggle_copy/, 'and copies the start button');
like($shell, qr/lock_session_copy/, 'and the lock');
like($taskbar, qr/start_menu_toggle_copy:visible/, 'the menu hangs from the visible start button');
like($css, qr/\.start_menu_toggle_copy\.start/, 'the copied start button keeps its frame');
like($shell, qr/function jawnosShellDockSync\(\)/, 'added docks are kept current');
like($shell, qr/row\.html\(source\.html\(\)\)/, 'from the first dock\'s faces');
like($shell, qr/row\.find\('\[id\]'\)\.removeAttr\('id'\)/, 'without repeating its ids');
like($events, qr/jawnosShellTaskbarSync\(\)/, 'the window displayer feeds the extra bars');
like($dock, qr/jawnosShellDockSync\(\)/, 'the dock renderer feeds the extra docks');
like($taskbar, qr/typeof jawnosShellApply == 'function'/, 'the legacy bar layout ends with the shell');
like($taskbar, qr/jawnosBars\.dock == 'floating'/, 'a floating dock reserves no window space');

# --- each workspace owns its windows and its piles --------------------------
my $windows = read_file("$root/public/js/manager/windows.js");
my $storage = read_file("$root/public/js/manager/windows/01_storage.js");
my $space = read_file("$root/public/js/manager/shell_workspaces.js");
like($space, qr/function jawnosWorkspaceApplyWindows/, 'switching lays out the windows of the desk it reaches');
like($space, qr/function jawnosWorkspaceWindowApplyOne/, 'a window is laid back on its desk');
like($space, qr/function jawnosWorkspaceWindowHere/, 'the window list asks which desk a window is on');
like($space, qr/classList|hasClass\('jawnos_ws_away'\)/, 'a switch hides with its own class, not a minimise');
like($space, qr/ws_visible/, 'a manually minimised window keeps its own state');
like($space, qr/function jawnosWorkspaceStackDefault/, 'each desk gets its own default pile');
like($windows, qr/jawnosWorkspaceWindowStack\(win\)/, 'the tiler asks the desk for the pile');
like($windows, qr/jawnosWorkspaceWindowNew\(\$\('#/, 'a new window is tagged before it is tiled');
like($windows, qr/\(p\.stack \|\| windowTiledDefaultStack\) !== stack/, 'a reserved slot is counted in its own desk\'s pile');
like($shell, qr/win\.attr\('workspace', keep\)/, 'removing a desk hands its windows to the first');
like($storage, qr/workspace: \(typeof jawnosWorkspaceActiveId/, 'the saved window record carries its desk');
like($storage, qr/ws_visible:/, 'and the state its own minimise left it in');
like($space, qr/function jawnosWorkspaceWindowRestore/, 'a restored window takes its desk back');
like($storage, qr/jawnosWorkspaceWindowRestore\(window, v\)/, 'and the openers call it');
like($storage, qr/function windowRetriever\(saved\)/, 'a room can hand its own windows to the retriever');
like($dock, qr/jawnosWorkspaceWindowHere/, 'the dock lists only this desk\'s windows');

# --- the switcher widget ----------------------------------------------------
like($edit, qr/workspaces: \{ hint: 'Workspaces'/, 'Workspaces is a taskbar widget');
like($edit, qr/w == 'workspaces'/, 'and builds its slot glyph');
like($space, qr/function jawnosWorkspaceWidgetPanelBuild/, 'it opens a panel of desks');
like($space, qr/data-workspace-add/, 'with an Add workspace row');
like($space, qr/data-workspace-remove/, 'and a Remove this workspace row');
like($core, qr{/js/manager/shell_workspaces\.js}, 'the window side is in the core bundle');
ok(-e "$root/public/icons/workspaces.svg", 'the widget icon exists');
like($css, qr/\.taskbar_widget_workspaces \.taskbar_workspaces_glyph/, 'the glyph is styled');
like($css, qr/\.taskbar_panel button\.taskbar_panel_workspace/, 'and the panel row');

# --- the first bars keep their ids and gain the shell classes ---------------
like($page, qr/id="taskbar" class="theme_surface_soft jawnos_bar jawnos_taskbar"/,
	'the first taskbar keeps its id and wears the shell classes');
like($page, qr/data-role="windows"/, 'its window list has a role');
like($pseudonyms, qr/id="pseudonym_home" class="theme_surface jawnos_bar jawnos_dock"/,
	'the first dock keeps its id and wears the shell classes');
like($pseudonyms, qr/<span id="pseudonym_bar" class="pseudonym_bar">/, 'and its face row has a class');
like($events, qr/on\('contextmenu', '\.jawnos_taskbar'/, 'an added taskbar opens the same menu');
like($dock, qr/on\('contextmenu', '\.jawnos_dock'/, 'an added dock opens the dock menu');
like($dock, qr/on\('contextmenu', '\.pseudonym_bar \.pseudonym'/, 'and so does a copied face');
like($core, qr{/js/manager/shell_layout\.js}, 'the shell layer is in the core bundle');

# --- the help topic is in the on-screen words -------------------------------
require "$root/perl/help.pl";
my $topic = $help::topic{'taskbar'};
ok($topic, 'the taskbar topic exists');
my $body = join(' ', @{ $topic->{body} || [] });
like($body, qr/Add taskbar/, 'the topic names Add taskbar');
like($body, qr/workspaces/, 'and the workspaces');
like($body, qr/grip on its left side/, 'and the grip');
like($body, qr/It can lock to the top or bottom edge/, 'the taskbar only takes a horizontal edge');
like($body, qr/taskbar stays horizontal/, 'and stays horizontal when it floats');
like($body, qr/floating/, 'and the floating state');
my $dock_topic = $help::topic{'dock'};
my $dock_body = join(' ', @{ $dock_topic->{body} || [] });
like($dock_body, qr/Add dock/, 'the dock topic names Add dock');
like($dock_body, qr/snaps to that edge\'s left, centre or right/, 'and the dock\'s edge anchors');
like($dock_body, qr/floating box/, 'and its floating box');

done_testing();
