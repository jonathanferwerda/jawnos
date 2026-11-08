# tests-for: lib/JawnOS/Domain/Devicews.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Routes/manager_ws.pm lib/JawnOS/Controller/manager_ws.pm perl/hooks.pl
# covers:    A device holds its socket to one homebase. A command from another
#            house machine (start pressed on the Phone, board homed on the
#            Table) used to fall back to HTTP to the board. It now relays to the
#            homebase over the signed peer rail, which writes the frame to its
#            own socket: one hop, same frame, same ack. 0 from the peer keeps
#            the old HTTP-then-BLE order untouched.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $read = sub { scalar read_file("$root/$_[0]") };

my $dev    = $read->('lib/JawnOS/Domain/Devicews.pm');
my $loader = $read->('lib/JawnOS/Domain/Loader.pm');
my $routes = $read->('lib/JawnOS/Routes/manager_ws.pm');
my $ctl    = $read->('lib/JawnOS/Controller/manager_ws.pm');
my $hooks  = $read->('perl/hooks.pl');

# --- the relay itself -----------------------------------------------------
like($dev, qr/sub device_ws_send_local \{/, 'the local socket write is its own helper');
like($dev, qr/sub device_ws_peer_relay \{/, 'the peer relay exists');
like($dev, qr/return &device_ws_peer_relay\(\$chip_id, \$frame\);/,
	'device_ws_command falls through to the peer relay');
like($dev, qr/my \$port = \$arm - 2;/, 'the homebase manager port is arm - 2');
like($dev, qr/&subs::peer_sign_request\(\$tx->req\)/, 'the relay request is peer-signed');
like($dev, qr{/manager/device_ws}, 'the relay posts to the relay route');

# --- the route, its peer check, and the gate exemption --------------------
like($routes, qr{\[47101, 'post', '/manager/device_ws', 'action_47101'\]},
	'the relay route is registered');
like($ctl, qr/sub action_47101 \{.*?&app_peer_ok\(\$c\)/s,
	'the route requires a signed peer');
like($ctl, qr/&subs::device_ws_write_frame\(\$chip_id, \$frame\)/,
	'the route writes through the worker that holds the socket');
like($hooks, qr{\$path eq '/manager/device_ws'}, 'the session gate exempts the relay');

# --- the lazy map names the new domain subs ------------------------------
like($loader, qr/device_ws_send_local device_ws_peer_relay/,
	'Loader.pm maps the relay subs');

done_testing();
