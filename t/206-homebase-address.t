# tests-for: lib/JawnOS/Domain/Network.pm lib/JawnOS/Domain/Ble.pm lib/JawnOS/Domain/Loader.pm
# covers:    An embedded device reaches only the house LAN, and DHCP reassigns
#            those addresses. The house must never hand a board an address it
#            cannot route to: no loopback, link-local, Tailscale/CGNAT, or the
#            IETF 192.0.0.0/24 block (a phone's p2p/tun or a VPN sits there).
#            lan_address_ok is the single gate, house_nodes_list uses it for the
#            fallback list, and ble_rehome_check no longer falls back to
#            Tailscale when this machine has no LAN address.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $read = sub { scalar read_file("$root/$_[0]") };

my $network = $read->('lib/JawnOS/Domain/Network.pm');
my $ble     = $read->('lib/JawnOS/Domain/Ble.pm');
my $loader  = $read->('lib/JawnOS/Domain/Loader.pm');

# --- the gate itself ------------------------------------------------------
my ($helper) = $network =~ /(sub lan_address_ok \{.*?\n\})/s;
ok($helper, 'Network.pm defines lan_address_ok');
{
	no warnings 'redefine';
	eval $helper;
	is($@, '', 'the helper compiles') or diag($@);
}
SKIP: {
	skip 'helper did not compile', 12 unless defined &lan_address_ok;
	# Real LAN addresses a board can reach.
	ok(lan_address_ok('192.168.1.102'), 'a 192.168.1 address is usable');
	ok(lan_address_ok('10.20.0.10'), 'a 10/8 address is usable');
	ok(lan_address_ok('172.16.5.9'), 'a 172.16 address is usable');
	ok(lan_address_ok('100.63.0.1'), 'a non-CGNAT 100.x address is usable');
	# The addresses that poisoned the board's homebase.
	ok(!lan_address_ok('192.0.0.4'), 'the 192.0.0.0/24 p2p/tun block is refused');
	ok(!lan_address_ok('100.64.0.1'), 'Tailscale/CGNAT 100.64/10 is refused');
	ok(!lan_address_ok('100.127.255.254'), 'the top of the CGNAT range is refused');
	ok(!lan_address_ok('127.0.0.1'), 'loopback is refused');
	ok(!lan_address_ok('169.254.3.4'), 'link-local is refused');
	ok(!lan_address_ok('0.0.0.0'), 'the unspecified address is refused');
	ok(!lan_address_ok(''), 'empty is refused');
	ok(!lan_address_ok('not-an-ip'), 'a non-address is refused');
}

# --- the fallback list only offers routable addresses ---------------------
like($network, qr/my \$add = sub \{\s*my \(\$ip.*?return unless &subs::lan_address_ok\(\$ip\);/s,
	'house_nodes_list filters every candidate through the gate');

# --- a re-home never points at Tailscale or a p2p/tun address ------------
like($ble, qr/sub ble_rehome_check \{.*?&subs::lan_address_ok/s,
	'ble_rehome_check candidates go through the gate');
like($ble, qr/return unless \@usable;/, 'no usable LAN address means no re-home');
unlike($ble, qr/\@lan \? \@lan : \@ips/,
	'the Tailscale fallback is gone (a board cannot route 100.64/10)');

# --- the lazy map names the new domain sub --------------------------------
like($loader, qr/'JawnOS::Domain::Network' for qw\([^)]*\blan_address_ok\b/,
	'Loader.pm maps lan_address_ok to Network.pm');

done_testing();
