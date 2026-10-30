use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# A peer's stored manager can outlive the route it named: a LAN address the
# machine has since left, or a 127.0.0.1 port from a tunnel that is gone. The
# probe (remote_machine_online) and the useragent builder must call the address
# that actually answers, and a hub's tunnel row must keep its stored manager
# because the peer's name can resolve to loopback there.

my $stale_lan = {
	manager => 'https://192.168.1.140:45545',
	fqdn    => 'phone.jonathanferwerda.com',
	port    => 45545,
};

is(subs::peer_manager_url($stale_lan, '192.168.1.140', 45545),
	'https://192.168.1.140:45545',
	'a literal candidate is called directly');
is(subs::peer_manager_url($stale_lan, 'phone.jonathanferwerda.com', 45545),
	'https://phone.jonathanferwerda.com:45545',
	'the fqdn candidate is called by name, not through the stale LAN manager');

my $dead_tunnel = {
	manager => 'https://127.0.0.1:59377',
	fqdn    => 'phone.jonathanferwerda.com',
	port    => 45545,
};
is(subs::peer_manager_url($dead_tunnel, 'phone.jonathanferwerda.com', 45545),
	'https://phone.jonathanferwerda.com:45545',
	'a dead loopback manager does not replace the fqdn that answered');
is(subs::peer_live_manager($dead_tunnel),
	'https://phone.jonathanferwerda.com:45545',
	'a leftover loopback manager is resolved to the peer fqdn');

my $tunnel = {
	manager => 'https://127.0.0.1:59377',
	fqdn    => 'peer.example',
	port    => 45545,
	tunnel  => 'yes',
};
is(subs::peer_manager_url($tunnel, 'peer.example', 45545),
	'https://127.0.0.1:59377',
	'a tunnel row keeps its stored tunnel manager for the fqdn candidate');
is(subs::peer_live_manager($tunnel),
	'https://127.0.0.1:59377',
	'a tunnel row keeps its loopback manager');

my $healthy = {
	manager => 'https://laptop.jonathanferwerda.com:45545',
	fqdn    => 'laptop.jonathanferwerda.com',
	port    => 45545,
};
is(subs::peer_manager_url($healthy, '192.168.1.155', 45545),
	'https://192.168.1.155:45545',
	'a reachable LAN candidate is used directly');
is(subs::peer_live_manager($healthy),
	'https://laptop.jonathanferwerda.com:45545',
	'a non-loopback manager is left alone');

my $port_from_manager = {
	manager => 'https://peer.example:45545',
	fqdn    => 'peer.example',
};
is(subs::peer_manager_url($port_from_manager, 'peer.example'),
	'https://peer.example:45545',
	'the port is read from the stored manager when the row has none');
is(subs::peer_manager_url({ manager => 'https://peer.example', fqdn => 'peer.example' }, 'peer.example'),
	'https://peer.example:45545',
	'a manager with no port falls back to the working port');
is(subs::peer_live_manager({ manager => 'https://127.0.0.1:1' }),
	'https://127.0.0.1:1',
	'a loopback manager with no fqdn is left alone');

done_testing();
