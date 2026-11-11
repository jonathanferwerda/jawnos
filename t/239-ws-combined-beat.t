# tests-for: public/js/manager/websocket.js public/js/manager/websocket/02_heartbeat_and_reload.js lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Controller/manager_misc2.pm lib/JawnOS/Controller/sesh_check.pm lib/JawnOS/Routes/manager_misc2.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm templates/layouts/manager.html.ep
# covers:    one stayingAlive frame for the whole tab, one beats reply, and the
#            debrief moved to its own GET/POST endpoint instead of the beat.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = "$FindBin::Bin/..";
my $ws   = read_file("$root/public/js/manager/websocket.js");
my $beat = read_file("$root/public/js/manager/websocket/02_heartbeat_and_reload.js");
my $ctl  = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");
my $misc = read_file("$root/lib/JawnOS/Controller/manager_misc2.pm");
my $tpl  = read_file("$root/templates/layouts/manager.html.ep");

# --- the client sends one frame for every app --------------------------------
like($ws, qr/function heartbeatSendAll\(\)/, 'the tab has one combined beat');
like($ws, qr/data\.apps = apps;/, 'the beat names every app it carries');
like($ws, qr/data\.music_data = music\.music_data;/, 'the music payload rides the same frame');
like($ws, qr/data\.ws = server\.ws;/, 'the server payload rides the same frame');
like($ws, qr/if \(wsMultiplex && !collect\) \{ heartbeatSendAll\(\); return; \}/,
	'the per-app sender hands off to the combined beat in mux mode');
unlike($ws, qr/data\['debriefer'\]/, 'the heartbeat no longer carries the debrief');
like($ws, qr/function debriefSave\(force\)/, 'the debrief has its own save');
like($ws, qr{navigator\.sendBeacon\('/manager/debrief'}, 'the page close uses a beacon');
like($ws, qr{\$\.ajax\(\{ url: '/manager/debrief'}, 'the slow save uses the endpoint');

# --- the server runs the same work per app and answers once ------------------
like($ctl, qr/my \$beat_once = sub \{/, 'the stayingAlive body is one per-app closure');
like($ctl, qr/my \$app = \$beat_app;/, 'the closure uses the beat app');
like($ctl, qr/foreach my \$beat_app \( \@beat_apps \)/, 'the beat runs once per app');
like($ctl, qr/beats => \\%beats/, 'the reply carries a beats map');
like($ctl, qr/if \(ref \$data->\{'apps'\} eq 'ARRAY' && scalar\(\@beat_apps\) > 1\)/,
	'a combined request gets one combined reply');
like($ctl, qr/&Websocket::send\(\$data->\{'app'\}, \$frame\)/, 'the combined reply is one frame');
like($ctl, qr/'uuid' => \$uuid \. ':' \. \$app,/, 'each app row gets its own uuid');

# --- the client applies each beat --------------------------------------------
like($beat, qr/function stayingAliveOne\(data\)/, 'the old per-app handler still exists');
like($beat, qr/if \(data\.beats\) \{/, 'a combined reply is split into beats');
like($beat, qr/Object\.keys\(data\.beats\)\.forEach/, 'each beat is applied by its app');

# --- the debrief endpoint -----------------------------------------------------
like($misc, qr/sub action_9001 \{/, 'the debrief getter action exists');
like($misc, qr/sub action_9002 \{/, 'the debrief setter action exists');
like($misc, qr/&subs::debrief_store\(\$c->session\('ticket_uuid'\), \$debrief\)/,
	'the setter writes the session ticket');
like($tpl, qr{url: '/manager/debrief'}, 'the page seeds from the new getter');

require JawnOS::Routes::manager_misc2;
my @rows = JawnOS::Routes::manager_misc2->routes;
ok(scalar(grep { $_->[2] eq '/manager/debrief' && $_->[1] eq 'get' } @rows),
	'GET /manager/debrief is registered');
ok(scalar(grep { $_->[2] eq '/manager/debrief' && $_->[1] eq 'post' } @rows),
	'POST /manager/debrief is registered');

# --- the save slot actually round-trips --------------------------------------
my $uuid = 'debrief-test-' . $$;
&subs::db_insert('tickets', { uuid => $uuid, debriefer => '{}' });
is(&subs::debrief_store($uuid, '{"a":1,"b":[2]}'), 1, 'the snapshot is written to its ticket');
is_deeply(&subs::debrief_read($uuid), { a => 1, b => [2] }, 'the getter returns the same snapshot');
is(&subs::debrief_store($uuid, ''), 0, 'an empty snapshot is refused');
is_deeply(&subs::debrief_read('missing-' . $$), {}, 'a missing ticket reads as an empty store');

# --- the gate's own snapshot is the newest one --------------------------------
my $sesh = read_file("$root/lib/JawnOS/Controller/sesh_check.pm");
like($sesh, qr/&subs::debrief_gate_read\(\$device, &subs::machine_hostname\(\)\)/,
	'the gate reads through the newest-row helper');

my $dev = 'computer';
my $host = 'debrief-host-' . $$;
my $other = 'debrief-other-' . $$;
&subs::db_insert('settings', { app => '__DEBRIEFING__', setting => $host, device => $dev,
	value => '{"v":"old"}', server_time => 1000, timestamp => 1000, uuid => 'dbg-a-' . $$ });
&subs::db_insert('settings', { app => '__DEBRIEFING__', setting => $host, device => $dev,
	value => '{"v":"new"}', server_time => 2000, timestamp => 2000, uuid => 'dbg-b-' . $$ });
is(&subs::debrief_gate_read($dev, $host), '{"v":"new"}',
	'the gate reads the newest row for this hostname');
&subs::db_insert('settings', { app => '__DEBRIEFING__', setting => $other, device => $dev,
	value => '{"v":"other"}', server_time => 3000, timestamp => 3000, uuid => 'dbg-c-' . $$ });
is(&subs::debrief_gate_read($dev, $host), '{"v":"new"}',
	'the hostname match wins over a newer row under another name');
is(&subs::debrief_gate_read($dev, 'debrief-none-' . $$), '{"v":"other"}',
	"a new hostname falls back to the device's newest row");
is(&subs::debrief_gate_read('', $host), undef, 'no device has no gate snapshot');


# --- the Controller is the Network app's tab now ----------------------------
like($ws, qr/function jawnosControllerVisible\(\)/,
	'the beat asks whether the Controller is open');
like($ws, qr/\$\('#network_panel_controller'\)\.is\(':visible'\)/,
	'and finds it in the Network app');
like($ws, qr/controller_visible: \(typeof jawnosControllerVisible == 'function' && jawnosControllerVisible\(\)\) \? 'yes' : 'no'/,
	'a beat names the Controller so the server sends the neighbours');
like($beat, qr/\$\('\.heartbeating\[app="' \+ data\.app \+ '"\]'\)\.css/,
	'the row pulses when its beat arrives');
unlike($beat, qr/#controller_toggle/, 'the retired dock face is no longer pulsed');
like($beat, qr/scale\(1\.1\)[\s\S]*?if \(data\.slim\) \{ return; \}/,
	'a slim beat still pulses before the heavy neighbour work is skipped');
like($beat, qr/typeof jawnosControllerVisible == 'function' \? jawnosControllerVisible\(\)/,
	'the neighbour rebuild follows the Network Controller tab');


# --- the Controller's saved first paint and faster beat ----------------------
like($ctl, qr/my \$ws_neighbour_refresh = 5000;/, 'the full neighbour payload is refreshed in seconds');
like($ctl, qr/our \([^;]*%ws_snapshot_stamp\)/s, 'the saved picture keeps its own stamp');
like($ctl, qr/sub controller_snapshot_save \{/, 'one helper writes the saved picture');
like($ctl, qr/&subs::cache_set\(\{ app => 'controller', context => 'beat', subcontext => \$app \}/,
	'a changed anchor picture is kept in the house cache');
like($ctl, qr/\$app =~ \/\^\(\?:music\|server\|tab\)\$\//,
	'only the three anchored apps are saved');

done_testing();
