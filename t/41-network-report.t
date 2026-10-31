use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The phone and tablet have no ifconfig in their runtime, and `ip addr` cannot
# bind a netlink socket as an app uid, so subs::network_interface_reporter()
# returned nothing and the devices row carried `{}`. The app now answers the
# same report natively; this is the mapping from that result to the structure
# the rest of the tree reads. A desktop has no bridge and keeps the ifconfig
# parser, so the function is exercised directly here.

local $ENV{'PORT_DOCK'} = 3000;
local $ENV{'PORT_AHOY'} = 3000;
local $ENV{'PORT_MSG'} = 4000;

my $report = {
	interfaces => {
		wlan0 => {
			nic       => 'wlan0',
			ip        => '192.168.1.5',
			mac       => 'aa:bb:cc:dd:ee:ff',
			netmask   => '255.255.255.0',
			broadcast => '192.168.1.255',
			gw        => '192.168.1.1',
		},
		rmnet0 => {
			nic => 'rmnet0',
			ip  => '10.42.0.7',
		},
	},
};

my $mapped = subs::network_report_from_bridge($report);
is( ref $mapped, 'HASH', 'a bridge report maps to an address hash' );
is( $mapped->{'wlan0'}{'ip'}, '192.168.1.5', 'the IPv4 address survives' );
is( $mapped->{'wlan0'}{'mac'}, 'aa:bb:cc:dd:ee:ff', 'the MAC survives' );
is( $mapped->{'wlan0'}{'netmask'}, '255.255.255.0', 'the netmask survives' );
is( $mapped->{'wlan0'}{'broadcast'}, '192.168.1.255', 'the broadcast survives' );
is( $mapped->{'wlan0'}{'gw'}, '192.168.1.1', 'the gateway survives' );
is( $mapped->{'wlan0'}{'port'}, 3000, 'the ports are added as the ifconfig path adds them' );
is( $mapped->{'wlan0'}{'manager'}, 'https://192.168.1.5:3000/manager',
	'the manager URL is built from the address' );
like( $mapped->{'wlan0'}{'timestamp'}, qr/^\d+/, 'and the entry is stamped' );

is( $mapped->{'rmnet0'}{'ip'}, '10.42.0.7', 'an interface without a MAC still maps' );
ok( !exists $mapped->{'rmnet0'}{'mac'}, 'and carries no empty MAC' );
ok( !exists $mapped->{'rmnet0'}{'netmask'}, 'nor an empty netmask' );

is( subs::network_report_from_bridge(undef), undef, 'no bridge answer maps to undef' );
is( subs::network_report_from_bridge({}), undef, 'a result without interfaces maps to undef' );
is( subs::network_report_from_bridge({ interfaces => {} }), undef,
	'an empty interface set maps to undef so the caller falls through' );
is_deeply( subs::network_report_from_bridge({ interfaces => { lo => { ip => '' } } }), {},
	'an interface without an address is not reported' );

is( subs::address_signature( { b => { ip => '2' }, a => { ip => '1' } } ),
	subs::address_signature( { a => { ip => '1' }, b => { ip => '2' } } ),
	'the address signature does not depend on key order' );
isnt( subs::address_signature( { a => { ip => '9' } } ),
	subs::address_signature( { a => { ip => '1' } } ),
	'a changed address changes the signature' );
isnt( subs::address_signature( { a => { ip => '1', port => 3000 } } ),
	subs::address_signature( { a => { ip => '1', port => 4000 } } ),
	'a changed port changes the signature' );
is( subs::address_signature(undef), '', 'no address map has an empty signature' );

done_testing();
