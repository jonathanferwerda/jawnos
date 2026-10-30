use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The privilege tiers behind hooks.pl's before_dispatch. This is the check that
# keeps a guest or resident out of /manager/configure and /manager/security;
# it used to be unreachable, so the table below is the regression.

# ---------------------------------------------------------------- tier_needed
is(&subs::tier_needed('/manager'),                      'resident', 'the manager shell is resident');
is(&subs::tier_needed('/manager/appointments'),        'resident', 'a manager app is resident');
is(&subs::tier_needed('/manager/configure'),           'citizen',  'configure is the citizen desk');
is(&subs::tier_needed('/manager/configure/oauth_panel'), 'citizen', 'configure panels are citizen');
is(&subs::tier_needed('/manager/security'),            'citizen',  'security is the citizen desk');
is(&subs::tier_needed('/manager/security/rotate_key'), 'citizen',  'security actions are citizen');
is(&subs::tier_needed('/manager/magazine/publish'),    'citizen',  'publishing is citizen');
is(&subs::tier_needed('/store/category_grabber'),      '',         'the public store claims no tier');
is(&subs::tier_needed('/'),                            '',         'the homepage claims no tier');
is(&subs::tier_needed('/js/jquery.js'),                '',         'assets claim no tier');
is(&subs::tier_needed('/manager/configuredness'),      'resident', 'a configure lookalike is not citizen');
is(&subs::tier_needed('/secure/manager'),              '',         'the manager pattern is anchored at the front');
is(&subs::tier_needed(''),                             '',         'an empty path claims no tier');
is(&subs::tier_needed(undef),                          '',         'an undefined path claims no tier');

# ---------------------------------------------------------------- tier_denied
ok(&subs::tier_denied('/manager', 'guest'),      'a guest cannot open the manager');
ok(!&subs::tier_denied('/manager', 'resident'),  'a resident can');
ok(!&subs::tier_denied('/manager', 'citizen'),   'a citizen can');
ok(&subs::tier_denied('/manager/configure', 'guest'),    'a guest cannot open configure');
ok(&subs::tier_denied('/manager/configure', 'resident'), 'a resident cannot either');
ok(!&subs::tier_denied('/manager/configure', 'citizen'), 'a citizen can');
ok(&subs::tier_denied('/manager/security', 'resident'),  'a resident cannot open security');
ok(&subs::tier_denied('/manager/security/rotate_key', 'resident'), 'nor rotate the key');
ok(&subs::tier_denied('/manager/magazine/publish', 'resident'),    'nor publish');
ok(!&subs::tier_denied('/manager/security', 'citizen'),  'a citizen can');
ok(&subs::tier_denied('/manager/configure', 'blacklisted'), 'an unknown privilege is refused');
ok(&subs::tier_denied('/manager/configure', ''),            'a missing privilege is refused');
ok(&subs::tier_denied('/manager/configure', undef),         'an undefined privilege is refused');
ok(!&subs::tier_denied('/store/category_grabber', 'guest'), 'a guest keeps the public store');
ok(!&subs::tier_denied('/', 'guest'),                       'a guest keeps the homepage');
ok(!&subs::tier_denied('/js/jquery.js', 'guest'),           'a guest keeps the assets');
ok(!&subs::tier_denied('/manager/configuredness', 'resident'), 'a resident may reach a lookalike page');
ok(&subs::tier_denied('/manager/configuredness', 'guest'), 'a guest may not reach it either');
# The padlock rail is claimed by the citizen pattern on purpose; hooks.pl is
# what steps aside for it (app_public_path), because those routes authenticate
# the caller with a device key. Pinned here so the layering is explicit.
ok(&subs::tier_denied('/manager/security/padlock_unlock', 'guest'),
	'the table claims the padlock rail; the caller carves it out');

# ------------------------------------------------------- privilege_is_house
ok(&subs::privilege_is_house('citizen'),  'a citizen is house');
ok(&subs::privilege_is_house('resident'), 'a resident is house');
ok(!&subs::privilege_is_house('guest'),   'a guest is not');
ok(!&subs::privilege_is_house('visitor'), 'the box-office visitor default is not');
ok(!&subs::privilege_is_house(''),        'a missing privilege is not');
ok(!&subs::privilege_is_house(undef),     'an undefined privilege is not');

# ------------------------------------------------------ guest_browser_session
ok(&subs::guest_browser_session('guest', 'ticket'),     'a guest ticket is a guest browser');
ok(&subs::guest_browser_session('visitor', 'ticket'),   'a visitor ticket is too');
ok(&subs::guest_browser_session(undef, ''),             'an unmarked session is refused');
ok(!&subs::guest_browser_session('guest', 'device'),    'a paired device with no person keeps its door');
ok(!&subs::guest_browser_session('resident', 'ticket'), 'a resident ticket is house');
ok(!&subs::guest_browser_session('citizen', ''),        'a citizen is house');

done_testing();
