use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# Address arithmetic behind the Dev panel and device scan. No sockets are opened.

# --------------------------------------------------------------- ip_is_private
ok(&subs::ip_is_private('10.0.0.1'),     '10/8 is private');
ok(&subs::ip_is_private('192.168.1.1'),  '192.168/16 is private');
ok(&subs::ip_is_private('172.16.0.1'),   '172.16/12 starts private');
ok(&subs::ip_is_private('172.31.255.255'), '172.31/12 ends private');
ok(!&subs::ip_is_private('172.32.0.1'),  '172.32 is public');
ok(&subs::ip_is_private('169.254.1.1'),  '169.254/16 is link-local');
ok(&subs::ip_is_private('100.64.0.1'),   '100.64/10 starts carrier-grade NAT');
ok(!&subs::ip_is_private('100.128.0.1'), '100.128 is outside carrier-grade NAT');
ok(!&subs::ip_is_private('8.8.8.8'),     'a public address is not ours to probe');
ok(!&subs::ip_is_private(''),            'an empty address is not private');

# --------------------------------------------------------------- same_net_test
is(&subs::same_net_test('192.168.2.10', '192.168.2.20'), 'yes', 'two hosts on one /24 share a net');
is(&subs::same_net_test('192.168.2.10', '10.0.0.5'),     'no',  'different networks do not');
is(&subs::same_net_test('10.1.2.3',     '10.1.2.9'),     'yes', 'a pair on one /24 shares a prefix');
is(&subs::same_net_test('10.1.2.3',     '10.1.9.9'),     'no',  'a pair two octets apart does not');
is(&subs::same_net_test('127.0.0.1',    '127.0.0.1'),    'no',  'loopback alone is not a LAN match');
is(&subs::same_net_test('192.168.2.10', '127.0.0.1'),    'no',  'a loopback peer is not on the LAN');
is(&subs::same_net_test('192.168.2.10', '192.168.2.20', '127.0.0.1'), 'yes',
	'a loopback override marker does not break a real LAN match');

# ------------------------------------------------------------------ subnet_cidr
is(&subs::subnet_cidr('192.168.2.3',  '255.255.255.0'), '192.168.2.0/24', 'a /24 network');
is(&subs::subnet_cidr('10.1.2.3',     '255.255.0.0'),   '10.1.0.0/16',    'a /16 network');
is(&subs::subnet_cidr('10.1.2.3',     '255.0.0.0'),     '10.0.0.0/8',     'a /8 network');
is(&subs::subnet_cidr('10.1.2.3',     '0xffff0000'),    '10.1.0.0/16',    'a hex netmask is read');
is(&subs::subnet_cidr('10.1.2.3',     'bogus'),         '10.1.2.0/24',    'a bad netmask falls back to /24');
is(&subs::subnet_cidr('10.1.2.3',     undef),           '10.1.2.0/24',    'a missing netmask falls back to /24');
ok(!defined &subs::subnet_cidr('not-an-ip', '255.255.255.0'), 'a non-address has no CIDR');

done_testing();
