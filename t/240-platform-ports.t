# tests-for: lib/JawnOS/Platform/Ports.pm perl/President.pl lib/JawnOS/Transport.pm jawn perl/gb.pl lib/JawnOS/Controller/manager_configure2.pm scripts/manager_killer.pl perl/tunnel.pl scripts/jawnos_setup.pl desktop/mkosi/config.default.json
# covers:    the port seam: the base fallback and random roll, the duty and
#            transport offset tables, the peer and plain-WS overflow rules, the
#            PORT_* names, the tunnel range defaults/validation, allocation
#            exhaustion, and the rule that a tunnel row keeps its port.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Slurp qw(read_file);
use IO::Socket::INET;
use JawnOS::Platform::Ports qw(
	base valid_base offset port_for env_name duty_env_names max_offset
	in_use can_bind tunnel_range reserve_tunnel_ports
);

# ------------------------------------------------------------ the base
is(base(working_port => '45545'), 45545, 'a configured working port is the base');
is(base(working_port => '59999'), 59999, 'a base below 60000 is used as-is');
is(base(working_port => '60000'), 45545, '60000 falls back to the house default');
is(base(working_port => ''), 45545, 'an absent working port takes the default');
is(base(working_port => '0'), 45545, 'a false working port is absent');
is(base(working_port => 'nope'), 45545, 'a non-numeric working port falls back');

my @roll = (0, 0.5);
is(base(working_port => undef, random => 1, rand => sub { shift @roll }), 29999,
	'a random base skips an invalid roll and stays in the open interval');

is(base(working_port => undef, default => 3000), 3000, 'a caller can name its own default');

# ------------------------------------------------------------ base validation
ok(valid_base(45545), '45545 is valid');
ok(!valid_base(1024), '1024 is not above the floor');
ok(valid_base(1025), '1025 is');
ok(valid_base(65521), '65521 leaves room for the transport max (14)');
ok(!valid_base(65522), '65522 overflows the transport max');
ok(valid_base(65526, max_offset => 9), '65526 leaves room for the launcher guard (9)');
ok(!valid_base(65527, max_offset => 9), '65527 does not');
ok(!valid_base('nope'), 'a non-numeric base is invalid');
ok(!valid_base(undef), 'an undef base is invalid');

# ------------------------------------------------------------ the offset tables
is(offset('ahoy'), 0, 'ahoy is the base itself');
is(offset('ws'), 1, 'ws is +1');
is(offset('watch'), 2, 'watch is +2');
is(offset('bestow'), 3, 'bestow is +3');
is(offset('tty'), 3, 'tty is the same listener as bestow');
is(offset('coms'), 4, 'coms is +4');
is(offset('bell'), 5, 'bell is +5');
is(offset('alarm'), 5, 'alarm is the same listener as bell');
is(offset('peer'), 6, 'peer is +6');
is(offset('ws_plain'), 101, 'the plain WS port is +101 on a normal base');
is(offset('bogus'), undef, 'an unknown duty has no offset');

is(offset('control', table => 'transport'), 7, 'control is +7');
is(offset('log', table => 'transport'), 8, 'log is +8');
is(offset('watch', table => 'transport'), 9, 'the transport watch is +9');
is(offset('alarm', table => 'transport'), 10, 'the transport alarm is +10');
is(offset('memory', table => 'transport'), 11, 'memory is +11');
is(offset('ws', table => 'transport'), 12, 'the transport ws is +12');
is(offset('mailws', table => 'transport'), 13, 'mailws is +13');
is(offset('tree', table => 'transport'), 14, 'tree is +14');
is(offset('bogus', table => 'transport'), undef, 'an unknown transport kind has no offset');

is(max_offset(), 6, 'the duty guard stops at peer, not the plain WS special case');
is(max_offset(table => 'transport'), 14, 'the transport guard is +14');

# ------------------------------------------------------------ the ports
is(port_for('ws', base => 45545), 45546, 'ws is base + 1');
is(port_for('watch', base => 45545), 45547, 'watch is base + 2');
is(port_for('bestow', base => 45545), 45548, 'bestow is base + 3');
is(port_for('coms', base => 45545), 45549, 'coms is base + 4');
is(port_for('bell', base => 45545), 45550, 'bell is base + 5');
is(port_for('peer', base => 45545), 45551, 'peer is base + 6');

is(port_for('peer', base => 65530), 65524, 'the peer overflow pulls back by 12');
is(port_for('ws_plain', base => 45545), 45646, 'plain ws is +101 on a normal base');
is(port_for('ws_plain', base => 45545, ws_port => 45545), 45645,
	'a collapsed ws port keeps its own offset');
is(port_for('ws_plain', ws_port => 60001), 59901, 'plain ws pulls back by 100 past 60000');

is(port_for('control', base => 45100, table => 'transport'), 45107, 'the transport control port');
is(port_for('tree', base => 65521, table => 'transport'), 65535, 'the last transport port fits');
is(port_for('tree', base => 65522, table => 'transport'), undef, 'the last transport port refuses overflow');
is(port_for('bogus'), undef, 'an unknown kind has no port');

# ------------------------------------------------------------ env names
is(env_name('ahoy'), 'PORT_AHOY', 'ahoy is PORT_AHOY');
is(env_name('ws'), 'PORT_MSG', 'ws is PORT_MSG');
is(env_name('watch'), 'PORT_ARM', 'watch is PORT_ARM');
is(env_name('bestow'), 'PORT_BESTOW', 'bestow is PORT_BESTOW');
is(env_name('tty'), 'PORT_BESTOW', 'tty answers with the same env name');
is(env_name('coms'), 'PORT_COMS', 'coms is PORT_COMS');
is(env_name('bell'), 'PORT_BELL', 'bell is PORT_BELL');
is(env_name('alarm'), 'PORT_BELL', 'alarm answers with the same env name');
is(env_name('peer'), 'PORT_PEER', 'peer is PORT_PEER');
is(env_name('ws_plain'), 'PORT_WS_PLAIN', 'plain ws is PORT_WS_PLAIN');
is(env_name('dock'), 'PORT_DOCK', 'dock is PORT_DOCK');
is(env_name('board'), 'PORT_BOARD', 'board is PORT_BOARD');
is(env_name('bogus'), undef, 'an unknown kind has no env name');
is_deeply(duty_env_names(), [qw(PORT_AHOY PORT_MSG PORT_BELL PORT_ARM PORT_BESTOW PORT_DOCK PORT_COMS)],
	'the published PORT_* list keeps gb.pl\'s order');

# ------------------------------------------------------------ the tunnel range
is_deeply(tunnel_range(), [50000, 50127], 'the default range is 128 ports');
is_deeply(tunnel_range(tunnel_port_min => '60000', tunnel_port_max => '60100'), [60000, 60100],
	'configured bounds are read as integers');
is_deeply(tunnel_range(tunnel_port_min => '60000', tunnel_port_max => '59000'), [50000, 50127],
	'an inverted range falls back to the defaults');
is_deeply(tunnel_range(tunnel_port_min => 'abc', tunnel_port_max => '1'), [50000, 50127],
	'a non-numeric bound falls back to the defaults');

# ------------------------------------------------------------ allocation
my $none = sub { 0 };
my ($ports, $err) = reserve_tunnel_ports(3,
	range => [50000, 50004], start => 0, in_use => $none);
is($err, undef, 'a free range has no error');
is_deeply($ports, [50000, 50001, 50002], 'the first free ports are taken in order');

($ports, $err) = reserve_tunnel_ports(3,
	range => [50000, 50004], start => 0, in_use => $none,
	taken => sub { $_[0] == 50001 ? 1 : 0 });
is_deeply($ports, [50000, 50002, 50003],
	'a port a live tunnel row owns stays reserved');

($ports, $err) = reserve_tunnel_ports(2,
	range => [50000, 50004], start => 0, in_use => $none,
	held => [ '50000', 50002 ]);
is_deeply($ports, [50001, 50003], 'ports the tree already exports are skipped');

($ports, $err) = reserve_tunnel_ports(2,
	range => [50000, 50002], start => 0, in_use => sub { $_[0] == 50001 });
is_deeply($ports, [50000, 50002], 'a port already in use is skipped');

($ports, $err) = reserve_tunnel_ports(2,
	range => [50000, 50003], rand => sub { 0.5 }, in_use => $none);
is_deeply($ports, [50002, 50003], 'allocation rotates from the random start');

($ports, $err) = reserve_tunnel_ports(3,
	range => [50000, 50001], start => 0, in_use => $none);
is_deeply($ports, [], 'exhaustion returns no ports');
like($err, qr/^tunnel ports exhausted: need 3 in 50000-50001, only 2 free$/,
	'and says how many were short');

($ports, $err) = reserve_tunnel_ports(0,
	range => [50000, 50001], start => 0, in_use => $none);
is_deeply($ports, [], 'a zero count asks for nothing');
is($err, undef, 'and is not an error');

# ------------------------------------------------------------ the real probes
my $listener = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1', LocalPort => 0, Proto => 'tcp',
	Listen => 5, ReuseAddr => 1,
);
SKIP: {
	skip 'no loopback listener on this platform', 4 unless $listener;
	my $port = $listener->sockport;
	ok(in_use($port), 'a listening loopback port is in use');
	ok(!can_bind('127.0.0.1', $port), 'and cannot be bound again');
	close $listener;
	ok(!in_use($port), 'the port is free after the listener closes');
	ok(can_bind('127.0.0.1', $port), 'and can bind again');
}

is(in_use('not-a-port'), 0, 'a malformed port is not in use');
ok(!can_bind('127.0.0.1', 70000), 'an out-of-range port cannot bind');

# ------------------------------------------------------------ the call sites
my $president  = read_file("$FindBin::Bin/../perl/President.pl");
my $transport  = read_file("$FindBin::Bin/../lib/JawnOS/Transport.pm");
my $launcher   = read_file("$FindBin::Bin/../jawn");
my $gb         = read_file("$FindBin::Bin/../perl/gb.pl");
my $configure  = read_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_configure2.pm");
my $killer     = read_file("$FindBin::Bin/../scripts/manager_killer.pl");
my $tunnel     = read_file("$FindBin::Bin/../perl/tunnel.pl");
my $setup      = read_file("$FindBin::Bin/../scripts/jawnos_setup.pl");
my $mkosi      = read_file("$FindBin::Bin/../desktop/mkosi/config.default.json");

like($president, qr/JawnOS::Platform::Ports::base/, 'President asks the ports seam for its base');
like($president, qr/JawnOS::Platform::Ports::offset\('bell'\)/, 'President asks for the duty offsets');
like($president, qr/JawnOS::Platform::Ports::port_for\('peer'/, 'President asks for the peer overflow rule');
like($transport, qr/JawnOS::Platform::Ports::port_for/, 'the transport asks for its ports');
like($transport, qr/JawnOS::Platform::Ports::valid_base/, 'the transport asks for its base validation');
like($launcher, qr/JawnOS::Platform::Ports::valid_base/, 'the launcher asks for the same validation');
like($gb, qr/JawnOS::Platform::Ports::duty_env_names/, 'gb.pl reads the PORT_* list from the seam');
like($configure, qr/JawnOS::Platform::Ports::reserve_tunnel_ports/, 'tunnel allocation asks the seam');
unlike($configure, qr/50000 \+ int\(rand\(65000/, 'the old random tunnel scan is gone');
like($configure, qr/status = \? or status = \?/, 'tunnel rows are read back as reserved or active');
like($killer, qr/JawnOS::Platform::Ports::base/, 'manager_killer asks for the working port');
like($tunnel, qr/JawnOS::Platform::Ports::can_bind/, 'the hub bind probe asks the seam');
like($setup, qr/tunnel_port_min\s*=>.*'50000'/, 'the seed writes the tunnel minimum');
like($setup, qr/tunnel_port_max\s*=>.*'50127'/, 'the seed writes the tunnel maximum');
like($mkosi, qr/"tunnel_port_min"\s*:\s*"50000"/, 'the mkosi default carries the tunnel minimum');
like($mkosi, qr/"tunnel_port_max"\s*:\s*"50127"/, 'the mkosi default carries the tunnel maximum');

done_testing();
