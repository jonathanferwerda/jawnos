# tests-for: lib/JawnOS/Routes/manager_controllers.pm lib/JawnOS/Controller/manager_controllers.pm lib/JawnOS/Routes.pm templates/controllers/controllers.html.ep templates/controllers/style.html.ep templates/controllers/body.html.ep public/js/manager/controllers.js lib/JawnOS/Manager/Core1_tables_hooks.pm templates/start_menu/start_menu.html.ep public/js/manager/manager/05_start_menu.js perl/gb/02_labels_and_collectives.pl perl/help/topics_apps.pl scripts/gou_provision.pl
# covers:    The Controller app: its four routes and their action ids, the page and
#            its partials, the bundle entry, the start-menu toggle, the label row
#            and the help topic. The handheld's own /manager/controller app is a
#            different thing and must stay untouched, so the plural path is checked
#            to the word.

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use Test::More;
use File::Slurp qw(read_file);

my $root = "$Bin/..";

sub slurp {
	my ($file) = @_;
	return read_file("$root/$file");
}

my $routes = slurp('lib/JawnOS/Routes/manager_controllers.pm');
ok($routes =~ m{/manager/controllers['\s]}, 'the page route');
ok($routes =~ m{/manager/controllers/list}, 'the roster route');
ok($routes =~ m{/manager/controllers/request}, 'the request route');
ok($routes =~ m{/manager/controllers/approve}, 'the approve route');
ok($routes =~ m{/manager/controllers/new/scan}, 'the New scan route');
ok($routes =~ m{/manager/controllers/new/flash}, 'the New flash route');
ok($routes =~ m{/manager/controllers/storage}, 'the storage route');
ok($routes =~ m{/manager/controllers/roms}, 'the roms route');

foreach my $id (54001 .. 54010) {
	like($routes, qr/\[\Q$id\E,\s*'\w+',\s*'\/manager\/controllers[^']*',\s*'action_\Q$id\E'\]/,
		"row $id names action_$id");
}

my $controller = slurp('lib/JawnOS/Controller/manager_controllers.pm');
like($controller, qr/^package Manager;/m, 'the controller is in package Manager');
foreach my $id (54001 .. 54010) {
	like($controller, qr/^sub action_\Q$id\E\b/m, "action_$id is defined");
}

my $provision = slurp('scripts/gou_provision.pl');
like($provision, qr/--scan/, 'the provisioning script can scan');
like($provision, qr/--flash/, 'the provisioning script can flash');
like($provision, qr/30_?535_?680/, 'the script knows the eMMC sector count');

my $names = slurp('lib/JawnOS/Routes.pm');
like($names, qr/\bmanager_controllers\b/, 'the module is registered in @NAMES');

foreach my $partial (qw(controllers.html.ep style.html.ep body.html.ep)) {
	ok(-e "$root/templates/controllers/$partial", "templates/controllers/$partial exists");
}
my $page = slurp('templates/controllers/controllers.html.ep');
like($page, qr{controllers/style}, 'the page includes its style partial');
like($page, qr{controllers/body}, 'the page includes its body partial');

my $core = slurp('lib/JawnOS/Manager/Core1_tables_hooks.pm');
like($core, qr{/js/manager/controllers\.js}, 'the JS is in the manager bundle');
ok(-e "$root/public/js/manager/controllers.js", 'public/js/manager/controllers.js exists');

my $menu = slurp('templates/start_menu/start_menu.html.ep');
like($menu, qr/id="controllers_toggle"/, 'the start menu carries the toggle');

my $start = slurp('public/js/manager/manager/05_start_menu.js');
like($start, qr/controllers_toggle\s*:\s*'controllers'/, 'the toggle maps to the app');

my $labels = slurp('perl/gb/02_labels_and_collectives.pl');
like($labels, qr/\bcontrollers\s*=>\s*\{\s*icon/, 'the app has a known-app row');

my $help = slurp('perl/help/topics_apps.pl');
like($help, qr/\$topic\{'controllers'\}/, 'the help topic is registered as controllers');

# Every template the topic claims must exist, or t/11 would fail for the wrong reason.
my ($topic_block) = $help =~ /(\$topic\{'controllers'\}\s*=\s*\{.*?\n\t+\};)/s;
ok($topic_block, 'the topic block is complete');
if ($topic_block) {
	my ($templates) = $topic_block =~ /templates\s*=>\s*\[([^\]]*)\]/;
	foreach my $path ($templates =~ /'([^']+)'/g) {
		ok(-e "$root/$path", "the topic's $path exists") if $path =~ m{^(templates|public)/};
	}
}

done_testing();
