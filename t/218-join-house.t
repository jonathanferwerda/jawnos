# tests-for: perl/subroutines.pl perl/hooks.pl lib/JawnOS/Routes/manager_configure2.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Manager/Part30.pm templates/configure/device_lister/body.html.ep templates/configure/device_lister/join_house.html.ep public/js/manager/configure/02_remote_devices.js perl/help/topics_configure.pl
# covers:    a machine that is not in the mesh yet can be introduced: the joining
#            machine asks for a six-digit code that lives ten minutes, the house
#            accepts it once, and the new machine is written as a citizen with
#            trusted access and no expiry.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = JawnOSTest::root();

my $routes = read_file("$root/lib/JawnOS/Routes/manager_configure2.pm");
my $ctrl   = read_file("$root/lib/JawnOS/Controller/manager_configure2.pm");
my $subs   = read_file("$root/perl/subroutines.pl");

# --- the two routes and their actions ----------------------------------------
like($routes, qr/\[\s*12450\s*,\s*'post'\s*,\s*'\/manager\/configure\/join_request'\s*,\s*'action_12450'\s*\]/,
	'POST /manager/configure/join_request is a route row');
like($routes, qr/\[\s*12451\s*,\s*'post'\s*,\s*'\/manager\/configure\/join_accept'\s*,\s*'action_12451'\s*\]/,
	'POST /manager/configure/join_accept is a route row');
like($ctrl, qr/^sub action_12450\b/m, 'the join request action exists');
like($ctrl, qr/^sub action_12451\b/m, 'the join acceptance action exists');

# --- the ten-minute window --------------------------------------------------
my ($ttl) = $subs =~ /^our \$JOIN_REQUEST_TTL_MS = (\d+);/m;
is($ttl, 600000, 'the join request lives ten minutes in epoch milliseconds');

my ($request) = $ctrl =~ /(sub action_12450 \{.*?\n\}\n)/s;
my ($accept)  = $ctrl =~ /(sub action_12451 \{.*?\n\}\n)/s;
ok($request && $accept, 'both actions were read for their bodies');

like($request, qr/delete from cache where context = \? and server_time < \?.*?JOIN_REQUEST_TTL_MS/s,
	'a request read deletes a row older than the window');
like($accept, qr/delete from cache where context = \? and server_time < \?.*?JOIN_REQUEST_TTL_MS/s,
	'an accept read deletes a row older than the window');
like($request, qr/random_string_creator\(6, '0-9'\)/, 'the code is six digits');
like($request, qr/context => 'join_request'/, 'the pending request is a join_request cache row');

# --- a used code cannot be reused -------------------------------------------
like($accept, qr/db_select\('cache', undef, \{ context => 'join_request', subcontext => \$code \}\)/,
	'acceptance finds the live row by its code');
like($accept, qr/db_delete\('cache', \{ uuid => \$pending->\{'uuid'\} \}\)/,
	'acceptance spends the row');
my $spent = index($accept, q{db_delete('cache', { uuid => $pending->{'uuid'} })});
my $written = index($accept, "db_insert('remote_machines'");
ok($spent >= 0 && $written > $spent, 'the code is deleted before the machine is written, so a second press finds nothing');

# --- the grant is the house's own phone/tablet grant ------------------------
like($accept, qr/peer_grant_setter\(\{ uuid => \$uuid, scope => 'trusted', privilege => 'citizen', expires => '' \}\)/,
	'the new machine is a citizen with trusted access and no expiry');
like($accept, qr/privilege => 'citizen'/, 'the relationship is citizen');

# --- the panel and its Guide topic ------------------------------------------
my $partial = read_file("$root/templates/configure/device_lister/join_house.html.ep");
my $body    = read_file("$root/templates/configure/device_lister/body.html.ep");
my $js      = read_file("$root/public/js/manager/configure/02_remote_devices.js");
my $help    = read_file("$root/perl/help/topics_configure.pl");

like($partial, qr/class="join_house_request"/, 'the card has a Request to join button');
like($partial, qr/class="join_house_accept"/, 'the card has an Accept button');
like($partial, qr/ten minutes/, 'the card says the code lasts ten minutes');
like($partial, qr/&subs::ui\(/, 'the card text is translatable on demand');
like($body, qr/include 'configure\/device_lister\/join_house'/, 'the card is included in the Devices list');
like($js, qr{/manager/configure/join_request}, 'the panel posts the join request');
like($js, qr{/manager/configure/join_accept}, 'the panel posts the acceptance');
like($help, qr/Join a house, at the top of the Dev panel/, 'the Guide explains the card');
like($help, qr/templates\/configure\/device_lister\/join_house\.html\.ep/, 'the Guide claims the new partial');
like(read_file("$root/lib/JawnOS/Manager/Part30.pm"), qr{return 1 if \$path eq '/manager/configure/join_request';},
	'the stranger rail is carved out of the app gate for the pending request only');
like(read_file("$root/perl/hooks.pl"), qr{\$path eq '/manager/configure/join_request'},
	'the session gate steps aside so a machine with no session can hand over its request');

done_testing();
