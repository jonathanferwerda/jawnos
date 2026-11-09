# tests-for: templates/apps/controller.html.ep lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm lib/JawnOS/Controller/manager_misc4.pm public/js/manager/manager/09_app_back.js public/css/manager.css lib/JawnOS/Domain/Misc.pm perl/help/topics_people.pl
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
like($template, qr/<div class="controller_tile controller_tile_leave">/,
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
cmp_ok($tiles, '>=', 6, 'app tiles ask the desk to open them');
like($page, qr/id="controller_manager_button"[^>]*href="\/manager\?desk=1"/,
	'the launcher has a Manager button that asks for the bare desk');
like($page, qr/\.wind\[app="controller"\] \.top_navbar\s*\{[^}]*display\s*:\s*none/,
	'the launcher hides its own window bar');
my $desk_js = read_file("$root/public/js/manager/manager/09_app_back.js");
like($desk_js, qr/location\.search\)\.get\('open'\)/, 'the desk reads the app to open');
like($desk_js, qr/e\.key !== 'Home'/, 'and listens for the handheld Home key');
like($desk_js, qr/typeof response === 'object'/, 'a JSON reply is recognised before the window is made');
like($desk_js, qr/response\.html \|\| response\.window/, 'both window envelope shapes are unwrapped');
like($desk_js, qr/full_app_mode/, 'a launcher press marks a full-screen app');
like($page, qr/id="controller_battery"/, 'the launcher has a battery button');
like($page, qr/data-power-plan=/, 'the panel offers the CPU profiles');
like($page, qr/No battery sensor/, 'a pack with no gauge says so');
like($page, qr/href="\/manager\?open=music&amp;full=1"/, 'an app tile asks for the full-screen mode');
like($controller, qr/power_status =>/, 'the launcher action passes the power reading');
like(read_file("$root/public/css/manager.css"), qr/body\.full_app_mode #taskbar/,
	'the full-screen mode hides the taskbar');
like(read_file("$root/lib/JawnOS/Domain/Misc.pm"), qr/jawnos_screen\.pl/,
	'screen off uses the handheld helper');

done_testing();
