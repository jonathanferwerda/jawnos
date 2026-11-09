# tests-for: templates/apps/controller.html.ep lib/JawnOS/Controller/manager_misc9.pm lib/JawnOS/Routes/manager_misc9.pm perl/help/topics_people.pl
# covers:    The controller's home is a launcher, not a desk: a handheld panel
#            opens on eight tiles, and the Leave tile names the power choices
#            before they are wired.

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

# --- the eight tiles ----------------------------------------------------------
my $template = read_file("$root/templates/apps/controller.html.ep");
for my $label (qw(Music Gallery Notifications Games Configuration IVR Automation Leave)) {
	like($template, qr/\Q$label\E/, "the $label tile is on the launcher");
}

# Leave has no route yet, so it must not be a link.
my ($leave) = $template =~ /(<div class="controller_tile controller_tile_leave">.*?<\/div>)/s;
ok($leave, 'Leave is a panel, not a link');
like($leave, qr/Sleep, Screen off, Restart, Shut down/,
	'Leave names the four power choices');
like($leave, qr/Not wired yet/, 'Leave says the choices are not wired');

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
like($desk, qr/return \$c->redirect_to\('\/manager\/controller'\) if &subs::device_setter\(\) eq 'controller';/,
	'the desk redirects a controller to its launcher');

done_testing();
