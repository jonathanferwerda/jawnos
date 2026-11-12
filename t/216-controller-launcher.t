# tests-for: templates/apps/controller.html.ep templates/controller/standalone.html.ep lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm lib/JawnOS/Controller/manager_misc4.pm public/js/manager/manager/09_app_back.js public/css/manager.css lib/JawnOS/Domain/Misc.pm perl/help/topics_people.pl
# covers:    The controller's home is a launcher, not a desk: a handheld panel
#            opens on eight tiles, a Manager button, and the Leave tile draws a
#            working button per power choice this machine can offer.

# A handheld has no desk to lay windows on, so the controller is served as its
# own app page at /manager/controller. The route, the action that draws it, the
# template's eight labels and the Guide topic are pinned together here: a tile
# renamed in one place and not the other is the kind of drift a person only
# finds by pressing it.

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
like($routes, qr/\[\s*44001\s*,\s*'get'\s*,\s*'\/manager\/controller'\s*,\s*'action_44001'\s*\]/,
	'GET /manager/controller is registered and names its action');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc9.pm");
my ($action) = $controller =~ /(sub action_44001\b.*?\n\})/s;
ok($action, 'action_44001 exists');
like($action, qr/template => 'apps\/controller'/,
	'the action renders the controller app page');
like($action, qr/&Manager::window_maker\(/,
	'the page is served through the window maker');
like($action, qr/power_actions\s*=>\s*\[\s*&subs::power_actions\(\)\s*\]/,
	'the action passes the usable power choices to the template');

# --- the eight tiles ----------------------------------------------------------
my $template = read_file("$root/templates/apps/controller.html.ep");
for my $label (qw(Music Gallery Notifications Games Configuration IVR Automation Leave)) {
	like($template, qr/\Q$label\E/, "the $label tile is on the launcher");
}

# Leave is a panel, not a link: one button per action, drawn from the list
# the action handed the template, and an inline script that posts the chosen
# word to the power route without navigating away.
like($template, qr/<div class="controller_tile controller_tile_leave"[^>]*>/,
	'Leave is a panel, not a link');
like($template, qr/\(grep \{ \$power_has\{\$\_\} \} \@power_order\)/,
	'the buttons are filtered from the actions this machine offers');
like($template, qr/\@power_order\s*=\s*qw\(sleep screen_off restart shutdown logout\)/,
	'the panel offers Sleep, Screen off, Restart, Shut down and Log out in order');
like($template, qr/data-power-action=/, 'each Leave button carries its action word');
like($template, qr/fetch\('\/manager\/power'/, 'the buttons post to the power route');
like($template, qr/URLSearchParams\(\{ action: action/, 'the action word is the only thing sent');
like($template, qr/This machine cannot power itself/,
	'an empty list says so instead of drawing dead buttons');

# --- the Guide topic ----------------------------------------------------------
my $help = read_file("$root/perl/help/topics_people.pl");
like($help, qr/\$topic\{'controller'\}\s*=\s*\{/,
	'the controller Guide topic exists');
like($help, qr/category => 'apps', app => 'controller'/,
	'the topic claims the controller app page');
like($help, qr/Tapping a text field raises the house keyboard/,
	'and says the handheld raises the house keyboard for typing');

# --- the desk sends a controller home ----------------------------------------
# /manager is the desk. A controller cannot use it, and the panel's first
# navigation is always there, so the desk redirects one to its launcher.
my $desk = read_file("$root/lib/JawnOS/Controller/manager_misc4.pm");
like($desk, qr/if !\$c->param\('open'\) && !\$c->param\('desk'\) && &subs::device_setter\(\) eq 'controller';/,
	'the desk redirects a controller to its launcher, unless an app or the bare desk was named');

# --- the page can actually render -------------------------------------------
# A template runs in the app's sandbox, which has none of the controller's
# imports: encode_json without this line is a 500 at render time, and a
# clicked-through page is the only place it used to show.
my $page = read_file("$root/templates/apps/controller.html.ep");
if ($page =~ /encode_json/) {
	like($page, qr/<%\s*use Mojo::JSON[^%]*encode_json/, 'the page imports encode_json it uses');
}


# --- a tile asks the desk, not the fragment -----------------------------------
# An app page is a window fragment: its JavaScript comes from the desk's bundle,
# so a link straight at it renders a frame with nothing driving it (a canvas and
# no game). Every app tile names the app on the desk instead.
my $tiles = () = $page =~ /href="\/manager\?open=/g;
cmp_ok($tiles, '>=', 5, 'app tiles ask the desk to open them');
like($page, qr/id="controller_games_tile"|href="\/manager\/games"/, 'the Games tile is a launcher page of its own');
like($page, qr/href="\/manager\?open=notifications&amp;full=1"/,
	'Notifications opens through the desk, so it is styled and Home still works');
like($page, qr/id="controller_manager_button"[^>]*href="\/manager\?desk=1"/,
	'the launcher has a Manager button that asks for the bare desk');
like($page, qr/\.wind\[app="controller"\] \.top_navbar\s*\{[^}]*display\s*:\s*none/,
	'the launcher hides its own window bar');
my $desk_js = read_file("$root/public/js/manager/manager/09_app_back.js");
like($desk_js, qr/location\.search\)\.get\('open'\)/, 'the desk reads the app to open');
like($desk_js, qr/e\.key !== 'Home'/, 'and listens for the handheld Home key');
like($desk_js, qr/function jawnosHomeBack/, 'Home follows one page-back rule');
like($desk_js, qr/'\/manager\/controller\/retroarch': '\/manager\/controller\/config'/,
	'RetroArch returns to Configuration');
like($desk_js, qr/'\/manager\/controller\/time': '\/manager\/controller\/config'/,
	'Time returns to Configuration too');
like($desk_js, qr/'\/manager\/controller\/config': '\/manager\/controller'/,
	'Configuration returns to the launcher');
like($desk_js, qr/if \(!back \|\| back === path \+ location\.search\) \{ back = '\/manager\/controller'; \}/,
	'and anywhere else still comes home to the launcher');
like($desk_js, qr/typeof response === 'object'/, 'a JSON reply is recognised before the window is made');
like($desk_js, qr/response\.html \|\| response\.window/, 'both window envelope shapes are unwrapped');
like($desk_js, qr/typeof jawnosLoadApp === 'function'/, 'a launcher app loads its lazy chunk before the window');
like($desk_js, qr/jawnosLoadApp\(open, openLauncherApp\)/, 'and waits for the chunk before dealing the app');
like($desk_js, qr/\.wind\.full_app_window/, 'Home finds the whole-screen launcher app');
like($desk_js, qr/closeWindow\(timestamp, leave\)/, 'and closes it before it leaves the page');
my $stack_js = read_file("$root/public/js/manager/windows/03_stack.js");
like($stack_js, qr/function closeWindow\(timestamp, done\)/, 'closeWindow accepts a completion callback');
like($stack_js, qr/if \(typeof done === 'function'\) \{ done\(\); \}/, 'and calls it when the server answers');
like($desk_js, qr/launcher_apps\[a\] && a !== open/, 'the launcher clears the other launcher app first');
like($desk_js, qr/Object\.keys\(urls\)\.forEach\(function \(app\) \{ launcher_apps\[app\] = 1; \}\)/,
	'every app the launcher can deal is a launcher app');
like($desk_js, qr/notifications: '\/manager\/notifications'/, 'Notifications is a launcher app');
like($desk_js, qr/embedded: '\/manager\/embedded'/, 'Automation is a launcher app');
like($desk_js, qr/configure: '\/manager\/configure'/, 'Configure is a launcher app');
like($desk_js, qr/delete saved\[a\]/, 'the launcher drops the other launcher apps from the saved list');
like($desk_js, qr/sessionStorage\.setItem\('window_storage', JSON\.stringify\(saved\)\)/, 'so the next page does not restore them');
like($desk_js, qr/\}, 500\);\n/, 'a window restored a moment later is swept too');
my $storage_js = read_file("$root/public/js/manager/windows/01_storage.js");
like($storage_js, qr/full: \$\(v\)\.hasClass\('full_app_window'\)/, 'a saved window remembers the whole-screen mode');
like($storage_js, qr/if \(v\.full && window && window\.length\)/, 'a restore puts the whole-screen mode back');
like($stack_js, qr/document\.body\.classList\.remove\('full_app_mode'\)/, 'closing the last app gives the desk back');
like($desk_js, qr/full_app_mode/, 'a launcher press marks a full-screen app');
like($page, qr/id="controller_battery"/, 'the launcher has a battery button');
like($page, qr/id="controller_clock"/, 'the launcher has a clock to the right of Manager');
like($page, qr/Intl\.DateTimeFormat/, 'the clock formats in the house time zone');
like($page, qr|href="/manager/controller/config"|, 'Configuration opens the handheld sublauncher, not the house Configure app');
like($page, qr/\.controller_tile_icon\s*\{[^}]*width:80%/, 'a tile icon fills 80% of its container');
like($page, qr/data-power-plan=/, 'the panel offers the CPU profiles');
like($page, qr/No battery sensor/, 'a pack with no gauge says so');
like($page, qr/id="controller_volume"/, 'the launcher has a volume button');
like($page, qr/id="controller_network"/, 'the launcher has a network button');
like($page, qr/data-volume-channel="master"/, 'the volume panel has a master row');
like($page, qr/% for my \$channel \(qw\(music phone alarm\)\)/, 'the panel draws the three source channels');
like($page, qr/Master volume/, 'the master row is labelled for a screen reader');
like($page, qr/channel_label = \(music => 'Music'/, 'the channels are named in the on-screen words');
like($page, qr|fetch\('/manager/controller/volume'|, 'the panel reads the volume route');
like($page, qr|post\('/manager/network/radio'|, 'the network panel toggles the Wi-Fi radio');
like($page, qr|post\('/manager/network/bluetooth/action'|, 'the network panel toggles Bluetooth');
like($page, qr/closeControllerPanels/, 'opening one panel closes the others');
like($page, qr/addEventListener\('wheel'/, 'the right stick steps a volume row under the pointer');
like($routes, qr/\[\s*44002\s*,\s*'get'\s*,\s*'\/manager\/controller\/volume'\s*,\s*'action_44002'\s*\]/,
	'GET /manager/controller/volume is registered');
like($routes, qr/\[\s*44003\s*,\s*'post'\s*,\s*'\/manager\/controller\/volume'\s*,\s*'action_44003'\s*\]/,
	'POST /manager/controller/volume is registered');
like($controller, qr/sound_status =>/, 'the launcher action passes the sound reading');
like($page, qr/href="\/manager\?open=music&amp;full=1"/, 'an app tile asks for the full-screen mode');
like($controller, qr/power_status =>/, 'the launcher action passes the power reading');
like($controller, qr/clock_timezone/, 'the launcher action reads the house clock zone');
like($controller, qr/America\/New_York/, 'Eastern is the launcher clock default');
like(read_file("$root/public/css/manager.css"), qr/body\.full_app_mode #taskbar/,
	'the full-screen mode hides the taskbar');
like(read_file("$root/lib/JawnOS/Domain/Misc.pm"), qr/jawnos_screen\.pl/,
	'screen off uses the handheld helper');

# --- the arrow buttons walk the tiles ----------------------------------------
# The D-pad is delivered as the keyboard arrows. The launcher keeps a selection
# so a person can walk the eight tiles without touching the pointer; Enter or a
# click after an arrow opens the selected tile.
like($page, qr/querySelectorAll\('\.controller_tile'\)/, 'the launcher collects its tiles for keyboard walking');
like($page, qr/ArrowRight/, 'the right arrow selects the next tile');
like($page, qr/ArrowLeft/, 'the left arrow selects the previous tile');
like($page, qr/ArrowDown/, 'the down arrow moves a row');
like($page, qr/ArrowUp/, 'and the up arrow moves back');
like($page, qr/is_selected/, 'the selected tile is marked for the outline');
like($page, qr/preventScroll: true/, 'focusing a tile does not scroll the panel');
like($page, qr/keyboardMode/, 'a click after a keyboard move belongs to the selection');
like($page, qr/movementX \|\| e\.movementY/, 'moving the stick hands the click back to the pointer');
like($page, qr/controller_tile_leave" tabindex="0"/, 'the Leave tile can take the keyboard selection');

# --- the launcher wears the theme it was given --------------------------------
# These pages are window fragments, not the desk, so they carry the theme's
# cursor and Home rule themselves.
like($page, qr/include 'controller\/standalone'/, 'the launcher includes the standalone theme and Home rule');
my $standalone = read_file("$root/templates/controller/standalone.html.ep");
like($standalone, qr/cursor_css/, 'the standalone page gets the cursor-set stylesheet');
like($standalone, qr/data-cursor-set/, 'and marks the body with the theme cursor');
like($standalone, qr/jawnosStandaloneHome/, 'and sends Home back one launcher page');
like($standalone, qr/\/manager\/games\/mapping'\) \{ back = '\/manager\/games\?view=emulated'/, 'the controls page returns to the shelf');
like($standalone, qr/\/manager\/controller\/config'\) \{ back = '\/manager\/controller'/, 'Configuration returns to the launcher');

my %tile_icon = (
	Music => 'headphones', Gallery => 'gallery', Notifications => 'bell', Games => 'tetris',
	Configuration => 'gear', IVR => 'phone', Automation => 'on', Leave => 'exit',
);
for my $name (sort keys %tile_icon) {
	like($page, qr/icon_for\('\/images\/decipherable\/\Q$tile_icon{$name}\E\.png'\)/,
		"the $name tile asks the active icon set, not the hand-drawn path");
}


done_testing();
