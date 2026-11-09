# tests-for: lib/JawnOS/Platform/Net.pm lib/JawnOS/Platform/Mdns.pm lib/JawnOS/Domain/Device.pm lib/JawnOS/Domain/Edt.pm lib/JawnOS/Domain/Network.pm lib/JawnOS/Controller/manager_configure2.pm
# covers:    the network seam: ifconfig/route/neigh parsing against recorded
#            output, the Avahi parsable record, the safe empty answers, and the
#            call sites that now ask the platform modules.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file);
use JawnOS::Platform::Net qw(
	interfaces gateway gateway_mac neighbour_lines
	parse_ifconfig parse_route parse_neigh
);
use JawnOS::Platform::Mdns qw(available browse parse_browse publish_argv);

# ------------------------------------------------------------ ifconfig shapes
my $ifconfig = <<'IFCONFIG';
eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500
        inet 10.20.0.10  netmask 255.255.255.0  broadcast 10.20.0.255
        inet6 fe80::1  prefixlen 64  scopeid 0x20<link>
        ether AA:BB:CC:DD:EE:FF  txqueuelen 1000  (Ethernet)
        RX packets 1234  bytes 5678 (5.6 KB)

lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536
        inet 127.0.0.1  netmask 255.0.0.0
        inet6 ::1  prefixlen 128  scopeid 0x10<host>
        loop  txqueuelen 1000  (Local Loopback)

wlan0: flags=4099<UP,BROADCAST,MULTICAST>  mtu 1500
        ether 11:22:33:44:55:66  txqueuelen 1000  (Ethernet)

sh: 1: ifconfig: not found
IFCONFIG

my $address = parse_ifconfig($ifconfig);
is(ref $address, 'HASH', 'an ifconfig report parses to a hash');
is_deeply([sort keys %{$address}], [qw(eth0 lo wlan0)], 'the shell error is not an interface');
is($address->{'eth0'}{'ip'}, '10.20.0.10', 'eth0 address');
is($address->{'eth0'}{'netmask'}, '255.255.255.0', 'eth0 netmask');
is($address->{'eth0'}{'broadcast'}, '10.20.0.255', 'eth0 broadcast');
is($address->{'eth0'}{'mac'}, 'aa:bb:cc:dd:ee:ff', 'eth0 MAC is lowercased');
is($address->{'eth0'}{'ip6'}, 'fe80::1', 'eth0 keeps its IPv6 address');
is($address->{'lo'}{'ip'}, '127.0.0.1', 'loopback address');
is($address->{'wlan0'}{'mac'}, '11:22:33:44:55:66', 'a down interface still has a MAC');
ok(!defined $address->{'wlan0'}{'ip'}, 'and has no address');
is_deeply(parse_ifconfig(undef), {}, 'no text parses to an empty map');

# ------------------------------------------------------------ routes
is(parse_route('default via 10.20.0.1 dev eth0 proto dhcp src 10.20.0.10 metric 100'),
	'10.20.0.1', 'the default route names the gateway');
is(parse_route('10.20.0.0/24 dev eth0 proto kernel scope link src 10.20.0.10'), '',
	'a non-default route has no gateway');
is(parse_route(''), '', 'no route output has no gateway');

# ------------------------------------------------------------ neighbours
my $neigh = <<'NEIGH';
10.20.0.5 lladdr aa:bb:cc:dd:ee:ff REACHABLE
10.20.0.6 INCOMPLETE
10.20.0.7 FAILED
NEIGH
my $found = parse_neigh($neigh);
is(scalar @{$found}, 3, 'each neighbour line is a row');
is($found->[0]{'ip'}, '10.20.0.5', 'the resolved row keeps its address');
is($found->[0]{'mac'}, 'aa:bb:cc:dd:ee:ff', 'and its MAC');
is($found->[0]{'state'}, 'REACHABLE', 'and its state');
is($found->[1]{'mac'}, '', 'an incomplete row has no MAC');
is($found->[1]{'state'}, 'INCOMPLETE', 'an incomplete row keeps its state');
is_deeply(parse_neigh(''), [], 'no neighbour output is an empty list');

# ------------------------------------------------------------ safe answers
is(ref interfaces(), 'HASH', 'interfaces answers a hash on this platform');
is(gateway('bad nic!'), '', 'an invalid interface name is refused');
is(gateway_mac('eth0', 'not-an-ip'), '', 'an invalid gateway is refused');
is_deeply(neighbour_lines('bad nic!'), [], 'an invalid interface has no neighbours');

# ------------------------------------------------------------ Avahi records
my $avahi = '=;wlan0;IPv4;JawnOS Table\032(table);_jawnos._tcp;local;table.local;10.20.0.20;45545;"purpose=table" "name=Table" "mac=AA:BB:CC:DD:EE:FF" "ty=table"' . "\n";
my $records = parse_browse($avahi);
is(scalar @{$records}, 1, 'one Avahi record parses');
is($records->[0]{'service'}, '_jawnos._tcp', 'the service type');
is($records->[0]{'ip'}, '10.20.0.20', 'the address');
is($records->[0]{'port'}, '45545', 'the port');
is($records->[0]{'mac'}, 'aa:bb:cc:dd:ee:ff', 'the TXT MAC is lowercased');
is($records->[0]{'name'}, 'Table', 'the TXT name wins over the instance');
is($records->[0]{'fields'}{'purpose'}, 'table', 'the TXT fields are split');
is_deeply(parse_browse(''), [], 'no browse output is an empty list');
is_deeply(parse_browse('=;wlan0;IPv4;x;_jawnos._tcp;local;x.local;not-an-ip;1;""'), [],
	'an IPv6 or malformed address is skipped');

is_deeply(browse('not-a-service'), [], 'a malformed service type is refused');
if (available('publish')) {
	my @argv = publish_argv('_jawnos-house._tcp', 'JawnOS Table (table)', 45545, ['purpose=table']);
	ok(@argv > 5, 'the publish argv is built when a responder exists');
	like($argv[0], qr/(?:avahi-publish-service|dns-sd)$/, 'with the responder as argv[0]');
}
else {
	pass('no mDNS responder on this platform');
	is_deeply([publish_argv('_jawnos-house._tcp', 'JawnOS', 45545, [])], [],
		'and publishing answers an empty argv');
}

# ------------------------------------------------------------ the call sites
my $device = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Device.pm");
my $edt = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Edt.pm");
my $network = read_file("$FindBin::Bin/../lib/JawnOS/Domain/Network.pm");
my $configure = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_configure2.pm");

like($device, qr/JawnOS::Platform::Net::interfaces/, 'device discovery asks the net module');
like($device, qr/JawnOS::Platform::Net::neighbour_lines/, 'device discovery asks for neighbours');
like($edt, qr/JawnOS::Platform::Net::interfaces/, 'the interface reporter asks the net module');
like($edt, qr/JawnOS::Platform::Mdns::browse/, 'the browse wrapper asks the mdns module');
like($network, qr/JawnOS::Platform::Mdns::publish_argv/, 'the house advert asks the mdns module');
like($configure, qr/JawnOS::Platform::Net::interfaces/, 'the network helper asks the net module');

done_testing();
