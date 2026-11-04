# tests-for: lib/JawnOS/Manager/Part12.pm lib/JawnOS/Controller/manager_phone.pm lib/JawnOS/Routes/manager_phone.pm templates/apps/phone.html.ep public/js/manager/phone.js perl/Reception.pl
# covers:    One number's own call route: saved, cleared, resolved before the
#            person's relationship, carried on the sync blob and offered by the
#            routing sheet; the reception worker only arms where the helper is.
use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;
use JawnOSTest;

require(root() . '/lib/JawnOS/Manager/Part12.pm');

my $repo = root();

# ------------------------------------------------------------ the store
my $saved = Manager::phone_routes_save({ '5551234567' => 'ivr', '5559999999' => 'reject' });
is($saved->{'5551234567'}, 'ivr', 'a number keeps its route');
is($saved->{'5559999999'}, 'reject', 'and so does a second one');
my $read = Manager::phone_routes_read();
is($read->{'5551234567'}, 'ivr', 'the route is read back');
is($read->{'5559999999'}, 'reject', 'the second one too');

my $junk = Manager::phone_routes_save({ '5550000000' => 'explode' });
ok(!exists $junk->{'5550000000'}, 'an unknown flow is not stored');

# a number is stored by its ten digits, however it was written
Manager::phone_routes_save({ '+1 (555) 123-4567' => 'voicemail' });
is(Manager::phone_routes_read()->{'5551234567'}, 'voicemail',
	'the route follows the number, not its punctuation');

# ------------------------------------------------------------ one save
my $set = Manager::phone_route_set('5552222222', 'ring');
ok($set->{'ok'}, 'one number can be set on its own');
is(Manager::phone_routes_read()->{'5552222222'}, 'ring', 'and is stored');
my $cleared = Manager::phone_route_set('5552222222', 'default');
ok($cleared->{'ok'}, 'default clears it');
ok(!exists Manager::phone_routes_read()->{'5552222222'}, 'the entry is gone');
my $bad = Manager::phone_route_set('5552222222', 'whatever');
ok(!$bad->{'ok'}, 'a flow the house does not know is refused');
my $none = Manager::phone_route_set('', 'ivr');
ok(!$none->{'ok'}, 'a save without a number is refused');

# ------------------------------------------------------------ resolution
Manager::phone_routes_save({});
&subs::setting_setter({ app => 'phone', setting => 'ivr_enabled', value => 'no' });
my $off = Manager::phone_route_for('5551234567');
is($off->{'flow'}, 'ring', 'with the reception flow off everything rings');
is($off->{'source'}, 'off', 'and the answer says why');

Manager::phone_route_set('5551234567', 'ivr');
my $pinned = Manager::phone_route_for('5551234567');
is($pinned->{'flow'}, 'ivr', 'a number route wins over a switched-off reception flow');
is($pinned->{'source'}, 'number', 'and is reported as the number\'s own');

Manager::phone_route_set('5551234567', 'default');
&subs::setting_setter({ app => 'phone', setting => 'ivr_enabled', value => 'yes' });
my $unknown = Manager::phone_route_for('5551234567');
is($unknown->{'source'}, 'unknown', 'a number the house cannot name falls to the unknown bucket');
is($unknown->{'flow'}, 'ivr', 'which is the receptionist by default');

# ------------------------------------------------------------ the routes
my $routes = read_file("$repo/lib/JawnOS/Routes/manager_phone.pm");
like($routes, qr/\[\s*24761\s*,\s*'post'\s*,\s*'\/manager\/phone\/route'\s*,\s*'action_24761'\s*\]/,
	'the routing save is registered');
like($routes, qr/\[\s*24762\s*,\s*'get'\s*,\s*'\/manager\/phone\/route'\s*,\s*'action_24762'\s*\]/,
	'the routing read is registered');
my $controller = read_file("$repo/lib/JawnOS/Controller/manager_phone.pm");
like($controller, qr/^sub action_24761\b/m, 'the save has its action');
like($controller, qr/^sub action_24762\b/m, 'the read has its action');
like($controller, qr/routes => &phone_routes_read\(\)/, 'the sync blob carries the routes');
like($controller, qr/remote_relay_request\(\$c, \{ dissemination => 'yes' \}\)/,
	'a route save is handed to the peers at once');
like($controller, qr/remoted/, 'and a relayed copy does not relay again');

my $template = read_file("$repo/templates/apps/phone.html.ep");
like($template, qr/id="phone_route_sheet"/, 'the phone page has the routing sheet');
like($template, qr/class="phone_route_choice" route="default"/, 'with a follow-the-person choice');
like($template, qr/class="little_thumb phone_app_row_route"/, 'a recent call offers the routing icon');
like($template, qr/class="phone_app_ivr_save" id="phone_ivr_arm"/, 'the IVR pane can arm the gateway');

my $js = read_file("$repo/public/js/manager/phone.js");
like($js, qr/phone_app_row_route/, 'the icon is wired');
like($js, qr{url: '/manager/phone/route'}, 'the sheet talks to the routing route');
like($js, qr{url: '/manager/sco/arm'}, 'the IVR pane arms the gateway');

# ------------------------------------------------------------ reception
my $reception = read_file("$repo/perl/Reception.pl");
like($reception, qr/phone_ivr_settings/, 'the worker reads the same IVR settings the phone saves');
like(read_file("$repo/lib/JawnOS/Domain/Phone.pm"), qr/device => 'all'/,
	'and the reception settings are read house-wide, not per device');
like($reception, qr/-x \$helper/, 'and only arms where the helper is built');
like($reception, qr/cmd => 'cancel'/, 'turning IVR off drops the listener');
like(read_file("$repo/perl/President.pl"), qr/Phone Reception/, 'the master starts it');
like($reception, qr/keep_new_recordings/, 'the names a call leaves are kept for the house');
like(read_file("$repo/docs/reception.md"), qr/jawn_call_in/, 'the working audio setup is written down');

done_testing();
