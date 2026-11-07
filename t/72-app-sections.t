# tests-for: lib/JawnOS/Controller/manager_misc.pm lib/JawnOS/Domain/Appointment.pm lib/JawnOS/Routes/manager_misc.pm public/js/manager/manager/09_app_back.js templates/
# covers:    An appointment window rendered the details (transaction) form and the app's measures into every open and left ...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# An appointment window rendered the details (transaction) form and the app's
# measures into every open and left them hidden - the details form alone is 11 KB
# of a 42 KB window. Both are fetched now, the first time a control reveals them.
# The window keeps a placeholder in the same place, so every selector that looks
# for .app_details or .app_measure still finds the form once it lands.

my $root = repo_root();
my $wrapper = read_file("$root/templates/appointment_wrapper.html.ep");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc.pm");
my $routes = read_file("$root/lib/JawnOS/Routes/manager_misc.pm");
my $js = read_file("$root/public/js/manager/manager/09_app_back.js");

# --- the window no longer carries the forms it does not show ----------------
unlike($wrapper, qr/include 'apps\/app_details'/, 'the details form is not rendered into every open');
unlike($wrapper, qr/include 'apps\/app_measures'/, 'the measures are not rendered into every open');
like($wrapper, qr/class="app_section_placeholder" app="<%= \$a %>" section="details"/,
	'the window keeps a placeholder where the details form was');
like($wrapper, qr/class="app_section_placeholder" app="<%= \$a %>" section="measures"/,
	'the window keeps a placeholder where the measures were');

# --- the pieces are fetched on first use ------------------------------------
like($routes, qr{\[18101, 'get', '/manager/app_section', 'action_18101'\]},
	'there is a route for one section');
like($controller, qr/sub action_18101 \{/, 'the route has an action');
like($controller, qr{\$section =~ /\^\(\?:details\|measures\|stats\)\$/}, 'the known sections are served');
like($controller, qr/template => 'apps\/appointment_stats'/, 'the stats section draws the bottom line');
like($controller, qr/&subs::appointment_statistics_for\(\$app\)/, 'the stats section reads the app\'s numbers');
like($controller, qr/template => 'apps\/app_details'/, 'the details section draws the form');
like($controller, qr/template => 'apps\/app_measures'/, 'the measures section draws the measures');
like($controller, qr/&appts_marker_builder\(\$appts\)/, 'the form is built from the same set the window reads');
like($controller, qr/&subs::app_hidden_now\(\$app\)/, 'a hidden app is not served its form');

# --- and revealed only once the form has landed ----------------------------
like($js, qr/function appSectionGrabber\(/, 'there is one fetcher for both sections');
like($js, qr/appSectionGrabber\(app, 'details', appointment/, 'the reset control asks for the details form');
like($js, qr/appSectionGrabber\(app, 'measures', parent/, 'the measures control asks for the measures');
like($js, qr/holder\.attr\('loading', 'yes'\)/, 'a second press does not ask twice while one is in flight');
like($js, qr/appointment\.find\('\.app_details'\)\.show\(\);/, 'the details form is shown once it has arrived');

done_testing();
