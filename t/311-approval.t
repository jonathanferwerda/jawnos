# tests-for: lib/JawnOS/Controller/manager_box_office.pm lib/JawnOS/Routes/manager_box_office.pm templates/box_office/markup.html.ep public/js/manager/manager/03_box_office.js
# covers:    Approving a pass request admits a person and writes the roles the
#            desk chose: the controller filters against the catalog, the desk
#            shows what was asked for, and the picker sends it back.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource qw(repo_root template_source js_source);

my $root       = repo_root();
my $controller = read_file("$root/lib/JawnOS/Controller/manager_box_office.pm");
my $routes     = read_file("$root/lib/JawnOS/Routes/manager_box_office.pm");
my $template   = template_source('box_office/markup');
my $js         = js_source('public/js/manager/manager/03_box_office.js');

# --- the approve action -----------------------------------------------------
like($controller, qr/\$c->param\('roles'\)/, 'approve reads a roles param');
like($controller, qr/subs::role_keys_filter\(\$catalog, \$roles_value\)/, 'and filters it through the role catalog');
like($controller, qr/\$info->\{'roles'\}/, "with the request's information roles as the fallback");

like($controller, qr/subs::person_for_ticket\(\$pt\)/, 'approve mints or finds the person for the request');
like($controller, qr/privilege => 'resident'/, "the person is created as a resident, not as the request's guest");
like($controller, qr/subs::person_roles_write\(\$person->\{'uuid'\}, \$wanted, \$catalog\)/, 'and their roles are written');
like($controller, qr/\$minted->\{'person_uuid'\}\s*=\s*\$person->\{'uuid'\}/, 'the minted ticket carries the person_uuid');
like($controller, qr/subs::db_insert\('tickets', \$minted\)/, 'the insert copies that minted row, person_uuid included');

like($controller, qr/roles => \$wanted/, 'the answer reports the roles that were kept');
like($controller, qr/person => \$person/, 'and the person uuid, empty when none was made');

like($routes, qr{'/manager/box_office/approve'\s*,\s*'action_14274'}, 'the approve route still reaches the action');

# --- the desk markup --------------------------------------------------------
like($template, qr/class="ticket_approve_role"/, 'each request row offers a role picker');
like($template, qr/subs::role_keys_filter\(\$roles, \$r->\{'info'\}->\{'roles'\}\)/, 'the row reads the requested roles through the catalog');
like($template, qr/subs::role_find\(\$roles, \$key\)/, 'and maps each uuid to its role name');
like($template, qr/\{'interview'\}/, 'the row shows the interview text');
like($template, qr/\{'trial'\}/, 'and the trial text');
like($template, qr/grep \{ \$_ eq \$role->\{'uuid'\} \} \@role_keys/, 'the picker is checked for the requested roles');

# --- the browser ------------------------------------------------------------
like($js, qr/\.ticket_approve_role:checked/, 'the approve click gathers the checked roles');
like($js, qr/roles:\s*JSON\.stringify\(roles\)/, 'and sends them as a JSON roles param');
like($js, qr/\.ticket_request_privilege/, 'the privilege field is still sent');

done_testing();
