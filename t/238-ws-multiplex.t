# tests-for: public/js/manager/websocket.js public/js/manager/websocket/02_heartbeat_and_reload.js lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Manager/Part37.pm templates/layouts/manager.html.ep config.json.example
# covers:    the opt-in bus socket: one browser connection registered under
#            every app, app-tagged pushes on the way out, and the per-app
#            proxies that keep the heartbeat, watchdog and stop paths intact.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $js   = read_file("$root/public/js/manager/websocket.js");
my $beat = read_file("$root/public/js/manager/websocket/02_heartbeat_and_reload.js");
my $ctl  = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");
my $send = read_file("$root/lib/JawnOS/Manager/Part37.pm");
my $tpl  = read_file("$root/templates/layouts/manager.html.ep");
my $cfg  = read_file("$root/config.json.example");

# --- opt-in, so the per-app sockets stay the default -------------------------
like($cfg, qr/"ws_multiplex": false/, 'the shipped config leaves multiplexing off');
like($tpl, qr/var ws_multiplex = <%= \(&subs::config_reader\(\)->\{'ws_multiplex'\} \? 'true' : 'false'\) %>;/,
	'the page hands the flag to the client');

# --- one bus, one registration per app --------------------------------------
like($ctl, qr/my \$mux = \(\$c->param\('mux'\) && &subs::config_reader\(\)->\{'ws_multiplex'\}\)/,
	'the server accepts mux only when the config allows it');
like($ctl, qr/\$c->tx->\{'mux'\} = 1 if \$mux;/, 'the connection is marked as a mux');
like($ctl, qr/\$gb::ws->\{\$app\}->\{\$tab\} = \$c->tx;/,
	'a mux frame registers the one tx under the app it names');
like($ctl, qr/\$data->\{'type'\} eq 'close_app'/, 'a closed window unregisters its app');
like($send, qr/\$conn->\{'mux'\}/, 'the sender checks whether the recipient is a mux');
like($send, qr/__mux_app.*__mux/, 'the sender tags each push with its app');

# --- the client keeps the per-app API ---------------------------------------
like($js, qr/var wsMultiplex = \(typeof ws_multiplex != 'undefined'\) \? !!ws_multiplex : false;/,
	'the client reads the flag, defaulting to off');
like($js, qr/function wsMuxProxy\(app\)/, 'a proxy stands in for a per-app socket');
like($js, qr/function websocketMuxStart\(/, 'the mux transport has its own starter');
like($js, qr/wsMultiplex && !address/, 'a remote machine keeps its per-app sockets');
like($js, qr/__mux_app !== undefined && data\.__mux !== undefined/,
	'an app-tagged frame is unwrapped before dispatch');
like($js, qr/websocketRetryLater\(wasAlive\)/, 'a bus that closed on its own keeps the fast retry');
like($beat, qr/if \(wsBus\) \{ wsBus\['deliberate'\] = 1; try \{ wsBus\.close\(\); \} catch \(e\) \{\} wsBus = null; \}/,
	'a full stop closes the bus deliberately');

done_testing();
