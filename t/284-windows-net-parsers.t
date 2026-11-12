# tests-for: lib/JawnOS/Platform/Net.pm
# covers:    The Windows adapter/route/neighbour payloads captured on the VM become the
#            interface map the Network status reads; the Linux/macOS parsers are untouched.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOS::Platform::Net ();

# Captured from the Windows VM: Get-NetAdapter, Get-NetIPAddress, Get-NetRoute.
my $net = <<'JSON';
{"adapters":[{"Name":"Ethernet","InterfaceDescription":"Intel(R) PRO/1000 MT Network Connection","ifIndex":4,"Status":"Up","MacAddress":"BC-24-11-D7-60-A6","PhysicalMediaType":"802.3"}],
"ipv4":[{"InterfaceIndex":4,"IPAddress":"10.20.0.50","PrefixLength":24,"PrefixOrigin":1},{"InterfaceIndex":1,"IPAddress":"127.0.0.1","PrefixLength":8,"PrefixOrigin":2}],
"ipv6":[],"routes":[{"InterfaceIndex":4,"NextHop":"10.20.0.1","DestinationPrefix":"0.0.0.0/0"}]}
JSON

my $adapters = JawnOS::Platform::Net::parse_windows_net_json($net);
is(ref $adapters, 'ARRAY', 'the captured adapters parse to a list');
is(scalar @{$adapters}, 1, 'one adapter in the captured payload');

my $map = JawnOS::Platform::Net::windows_interface_map($adapters);
ok(ref $map->{4} eq 'HASH', 'the adapter is keyed by its ifIndex');
is($map->{4}->{'name'}, 'Ethernet', 'the friendly name is kept');
is($map->{4}->{'mac'}, 'bc:24:11:d7:60:a6', 'the dashed MAC becomes a colon MAC');
is($map->{4}->{'ip'}, '10.20.0.50', 'the VM address is the interface address');
is($map->{4}->{'prefix'}, 24, 'the prefix length is kept');
is($map->{4}->{'netmask'}, '255.255.255.0', 'the prefix becomes a netmask');
is($map->{4}->{'broadcast'}, '10.20.0.255', 'the broadcast follows the prefix');
is($map->{4}->{'gw'}, '10.20.0.1', 'the default route is the interface gateway');
is($map->{4}->{'up'}, 1, 'an Up adapter reads up');
is($map->{4}->{'wireless'}, 0, 'an 802.3 adapter is not wireless');
is($map->{4}->{'method'}, 'static', 'a manual prefix origin reads static');

# Captured Get-NetNeighbor rows: three real hosts plus multicast and broadcast.
my $neighbours = <<'JSON';
[{"InterfaceIndex":4,"IPAddress":"239.255.255.250","LinkLayerAddress":"01-00-5E-7F-FF-FA","State":6},
{"InterfaceIndex":4,"IPAddress":"224.0.0.252","LinkLayerAddress":"01-00-5E-00-00-FC","State":6},
{"InterfaceIndex":4,"IPAddress":"10.20.0.255","LinkLayerAddress":"FF-FF-FF-FF-FF-FF","State":6},
{"InterfaceIndex":4,"IPAddress":"10.20.0.20","LinkLayerAddress":"BC-24-11-5F-98-5B","State":4},
{"InterfaceIndex":4,"IPAddress":"10.20.0.10","LinkLayerAddress":"BC-24-11-80-93-8A","State":4},
{"InterfaceIndex":4,"IPAddress":"10.20.0.1","LinkLayerAddress":"1A-3D-AE-14-6C-EE","State":4}]
JSON
my $rows = JawnOS::Platform::Net::parse_windows_neighbours_json($neighbours);
is(scalar @{$rows}, 6, 'every captured neighbour row parses');
my $lines = JawnOS::Platform::Net::windows_neighbour_lines($rows);
is(scalar @{$lines}, 3, 'multicast and broadcast rows are not neighbours');
is($lines->[0], '10.20.0.20 lladdr bc:24:11:5f:98:5b STALE', 'the raw ip-neigh line shape is kept');
is($lines->[2], '10.20.0.1 lladdr 1a:3d:ae:14:6c:ee STALE', 'the gateway row keeps its MAC');

is(JawnOS::Platform::Net::_prefix_to_netmask(0),  '0.0.0.0',         'a /0 mask is empty');
is(JawnOS::Platform::Net::_prefix_to_netmask(32), '255.255.255.255', 'a /32 mask is full');

done_testing();
