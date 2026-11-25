# tests-for: lib/JawnOS.pm lib/JawnOS/Controller/ lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Sync.pm lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Manager.pm lib/JawnOS/Manager/ lib/JawnOS/Routes.pm lib/JawnOS/Routes/ perl/Manager.pl
# covers:    A peer's stored manager can outlive the route it named: a LAN address the machine has since left, a 127.0.0.1 port from a dead tunnel, or a tunnel flag whose active tunnel row is gone; the live route wins and a tunnel's loopback is kept only while its port is an active tunnel.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;
use JawnOSTest;
use Mojo::JSON qw(decode_json encode_json);

# The address reporter is lazy: load the real definition before a local stub,
# or the module load replaces the stub mid-test.
subs::preload('network_interface_reporter');

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
	ip      => '10.0.0.9',
	port    => 45545,
	tunnel  => 'yes',
};
&subs::db_insert('tunnels', {
	signatorial => 'peer-sig', status => 'active', direction => 'out',
	name => 'PORT_AHOY', in_port => 59377, uuid => 'test-tunnel-59377',
});
is(subs::peer_manager_url($tunnel, 'peer.example', 45545),
	'https://127.0.0.1:59377',
	'a tunnel row keeps its stored tunnel manager for the fqdn candidate');
is(subs::peer_live_manager($tunnel),
	'https://10.0.0.9:45545',
	'a live tunnel with a direct address keeps the direct route first');
is(subs::peer_live_manager({ manager => 'https://127.0.0.1:59377', fqdn => 'peer.example', port => 45545, tunnel => 'yes' }),
	'https://127.0.0.1:59377',
	'a tunnel-only row keeps its live loopback');
is(subs::peer_live_manager({ %{$tunnel}, manager => 'https://127.0.0.1:59378' }),
	'https://10.0.0.9:45545',
	'a tunnel flag with no active tunnel row falls back to the peer literal');

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

# remote_useragent_maker runs the tunnel processor after the presence probe. It
# used to prefer the peer's advertised LAN address whenever that address was in
# our subnet - the very address the probe had just failed to reach.
my $verified = {
	manager => 'https://100.64.0.4:45545',
	fqdn => 'phone.jonathanferwerda.com',
	ip => '100.64.0.4',
	port => 45545,
	tunnel => 'no',
	manager_verified => 1,
	network => '{"lan":{"ip":"192.168.1.140","manager":"https://192.168.1.140:45545","port":"45545"}}',
};
my $kept = &subs::remote_machine_tunnel_processor({ %{$verified} });
is($kept->{'manager'}, 'https://100.64.0.4:45545',
	'a manager that answered the probe is not replaced by the advertised LAN address');

# With the VPN off the house names (*.jonathanferwerda.com) do not resolve at
# all. A row that still carries the LAN address the peer advertised must be
# dialled there instead; the name is only the last resort. `.invalid` is
# guaranteed not to resolve, so this does not depend on the test machine's DNS.
my $plain_wifi = {
	manager => 'https://no-such-peer.invalid:45545',
	fqdn    => 'no-such-peer.invalid',
	ip      => '192.168.1.140',
	port    => 45545,
	tunnel  => 'no',
};
my $candidates = subs::peer_probe_candidates($plain_wifi, 45545);
is($candidates->[0]->{'host'}, '192.168.1.140',
	'the stored LAN ip is the first candidate, before any name');
ok((grep { $_->{'host'} eq 'no-such-peer.invalid' } @{$candidates}),
	'the name is still tried after the literal addresses');
is(subs::peer_live_manager($plain_wifi), 'https://192.168.1.140:45545',
	'an unresolvable house name falls back to the stored LAN ip');

# The reported phone row: a retired hub tunnel left 127.0.0.1, and the peer's
# name needs the tailnet's DNS. The LAN ip is the route that does not.
is(subs::peer_live_manager({
	manager => 'https://127.0.0.1:53665',
	fqdn    => 'laptop.jonathanferwerda.com',
	ip      => '192.168.1.155',
	port    => 45545,
	tunnel  => 'no',
}), 'https://192.168.1.155:45545',
	'a retired tunnel manager falls back to the stored LAN ip, not the name');

# A row whose stored ip is on the tailnet but whose advertised map carries the
# LAN address must try the tailnet first: it is the direct WireGuard path and a
# same-LAN Wi-Fi can isolate its clients while the tailnet still works.
is(subs::peer_address_rank('192.168.1.155'), 0, 'a private LAN address is classed as LAN');
is(subs::peer_address_rank('100.64.0.3'), 1, 'a tailnet address is classed as CGNAT');
my $tailnet_row = {
	ip      => '100.64.0.3',
	fqdn    => 'laptop.jonathanferwerda.com',
	port    => 45545,
	network => '{"lan":{"ip":"192.168.1.155","port":"45545"}}',
};
my $ranked;
{
	# This machine is on the peer's LAN, but the tailnet is still tried first.
	no warnings qw(redefine once);
	local *subs::network_interface_reporter = sub { return { eth0 => { ip => '192.168.1.50' } } };
	$ranked = subs::peer_probe_candidates($tailnet_row, 45545);
}
is($ranked->[0]->{'host'}, '100.64.0.3',
	'the tailnet is tried before the advertised LAN when both are known');

# The probe must not use ping as a gate: a peer whose echo is dropped (or a
# candidate whose name has no DNS answer) still gets its manager called, and a
# name that cannot resolve is skipped without a ping.
my @tried;
my $sig = 'peer-sig';
my $probe = subs::peer_presence_probe(
	{ %{$plain_wifi}, signatorial => $sig },
	{
		ip => 'no-such-peer.invalid',
		port => 45545,
		signatorial => $sig,
		ping => sub { 0 },
		fetch => sub {
			my $c = shift;
			push @tried, $c->{'host'};
			return $c->{'host'} eq '192.168.1.140' ? $sig : '';
		},
	}
);
is($probe->{'ok'}, 1, 'an unanswered ping does not end the candidate');
is($probe->{'manager'}, 'https://192.168.1.140:45545',
	'the LAN address that answered becomes the manager');
is_deeply(\@tried, ['192.168.1.140'],
	'the unresolvable name is skipped without a ping or a request');

my $fetched = 0;
my $nothing = subs::peer_presence_probe(
	{ fqdn => 'no-such-peer.invalid', manager => 'https://no-such-peer.invalid:45545', signatorial => $sig },
	{ signatorial => $sig, ping => sub { 1 }, fetch => sub { $fetched++; return $sig } }
);
ok(!$nothing->{'ok'}, 'a row with only an unresolvable name is not reachable');
is($fetched, 0, 'and its name is never dialled');

# The manager's probe is the production path, not a parallel copy.
my $manager_source = manager_source();
like($manager_source, qr/sub remote_machine_online\b[^{]*\{.*?peer_presence_probe/s,
	'remote_machine_online probes through the shared candidate list');
unlike($manager_source, qr/next unless \$ping && \$ping =~ \/ttl\//,
	'the presence probe no longer drops a candidate on a failed ping');

# The snapshot download must keep the route that was proved, exactly as the
# tunnel processor does. A mirror row still carries the hub's `tunnel` flag, so
# rewriting it to 127.0.0.1:<the hub's port> made every windowed deep pull from
# a mirrored phone, tablet or laptop fail with Connection refused (2026-11-05).
like($manager_source,
	qr/\$remote_machine->\{'tunnel'\} \|\| ''\) eq 'yes' && !\$remote_machine->\{'manager_verified'\}/,
	'a snapshot download does not overwrite the manager a probe proved');

# `sync_peer_order` fixes the starvation: a pass starts one pull, so the peer
# with the oldest confirmed watermark must go first.
my $peers = [
	{ signatorial => 'busy' },
	{ signatorial => 'phone' },
	{ signatorial => 'unknown' },
];
my $ordered = subs::sync_peer_order($peers, { busy => 300, phone => 100 });
is_deeply([ map { $_->{'signatorial'} } @{$ordered} ], [ 'unknown', 'phone', 'busy' ],
	'the pass starts with the peer whose last confirmed pull is oldest');
my $tied = subs::sync_peer_order([ { signatorial => 'b' }, { signatorial => 'a' } ], { a => 5, b => 5 });
is_deeply([ map { $_->{'signatorial'} } @{$tied} ], [ 'a', 'b' ],
	'a watermark tie is broken by signatorial so the order is stable');

# A tailnet address the row has already proved is kept and probed after the LAN
# literals. Android never lists its VPN interface in the live network map, so
# without the remembered column a peer that left the LAN had no route at all.
my $remembered = {
	ip         => '192.168.1.142',
	tailnet_ip => '100.64.0.6',
	network    => '{"lan":{"nic":"lan","ip":"192.168.1.142","port":45545}}',
	port       => 45545,
};
my $addresses;
{
	# A peer on our own LAN: the tailnet is still tried first.
	no warnings qw(redefine once);
	local *subs::network_interface_reporter = sub { return { eth0 => { ip => '192.168.1.50' } } };
	$addresses = subs::peer_literal_addresses($remembered);
}
my @hosts = map { $_->{'host'} } @{$addresses};
ok(scalar(grep { $_ eq '100.64.0.6' } @hosts), 'a persisted tailnet address is a probe candidate');
my $lan_at = (grep { $hosts[$_] eq '192.168.1.142' } 0 .. $#hosts)[0];
my $tail_at = (grep { $hosts[$_] eq '100.64.0.6' } 0 .. $#hosts)[0];
ok(defined $lan_at && defined $tail_at && $tail_at < $lan_at,
	'the tailnet address is tried before the LAN one');

# The map alone can still name the tailnet when the column was never written.
my $from_map = {
	ip      => '100.64.0.6',
	network => '{"tailscale0":{"nic":"tailscale0","ip":"100.64.0.6","port":45545}}',
	port    => 45545,
};
ok(scalar(grep { $_->{'host'} eq '100.64.0.6' } @{ subs::peer_literal_addresses($from_map) }),
	'a tailnet address in the live map is a candidate too');

# The address is only used when the LIVE map drops the VPN interface (a report
# taken with the VPN down), so the stored column has to outlive it.
is subs::tailnet_address({ network => '{"tailscale0":{"nic":"tailscale0","ip":"100.64.0.1"}}' }),
	'100.64.0.1', 'a tailnet interface in the network map is the tailnet address';
is subs::tailnet_address({ ip => '100.64.0.2' }), '100.64.0.2',
	'a row whose ip is already in the CGNAT range is its own tailnet address';
is subs::tailnet_address({ ip => '192.168.1.140', network => '{"lan":{"ip":"192.168.1.140"}}' }), '',
	'a LAN address is not mistaken for a tailnet one';

# The value is only useful if it was written down while the VPN was up, so pin
# both places a peer's interfaces arrive: its network report and a LAN beacon.
like($manager_source, qr/tailnet_ip/,
	'the peer network report stores the tailnet address');
my $house_source = '';
{
	open(my $fh, '<', repo_root() . '/lib/JawnOS/Domain/House.pm') or die $!;
	local $/;
	$house_source = <$fh>;
	close $fh;
}
like($house_source, qr/\$update->\{'tailnet_ip'\}/,
	'a LAN beacon stores the tailnet address too');

# A mirror is a small address record, not the peer's whole row. The handshake
# and the tunnel heartbeat used to ship `data` (the peer's login body), `cookie`
# (a live session), the deletion log and the nested mirror blob to every machine;
# nothing on the receiving side reads those for a mirror.
my $full_row = {
	uuid => 'u1', signatorial => 's1', pubkey => 'pk',
	ip => '192.168.1.5', fqdn => 'laptop.example', port => 45545,
	manager => 'https://laptop.example:45545', network => '{"lan":{"ip":"192.168.1.5"}}',
	hostname => 'Laptop', buttons => '<button>Go</button>',
	device => 'computer', connection => 'active', status => 'connected',
	tunnel => 'no', archive => '{"dir":"/archive"}', archive_dir => '/archive', privilege => 'peer',
	grant_scope => 'trusted', grant_expires => '0', server_time => '1700000000000',
	data => '{"debriefer":"a lot of audit text"}',
	cookie => '[{"name":"president"}]', deletions => '[]', log => 'noise',
	additions => '[]', edits => '[]', mirrors => '[{"uuid":"nested"}]',
};
my $mirror = subs::remote_machine_mirror_row($full_row);
for my $kept (qw(uuid signatorial pubkey ip fqdn port manager network hostname
		buttons device connection status tunnel archive archive_dir privilege grant_scope
		grant_expires server_time)) {
	is($mirror->{$kept}, $full_row->{$kept}, "a mirror keeps $kept");
}
for my $dropped (qw(data cookie deletions log additions edits mirrors)) {
	ok(!exists $mirror->{$dropped}, "a mirror does not carry $dropped");
}

# The column is the place a peer's login body is remembered. Only these fields
# are read from it later; the debriefer and browser bookkeeping are not.
my $stored_login = subs::remote_machine_data_view({
	database => '/house.db', device => 'mobile', ssh_port => 8022,
	manager_colour => '#123456', manager_file => 'face.html',
	debriefer => 'a lot of audit text', browser_tab_id => 'tab',
	pwd => '/home/peer', mirrors => [ { uuid => 'nested' } ],
});
is_deeply($stored_login, {
	database => '/house.db', device => 'mobile', ssh_port => 8022,
	manager_colour => '#123456', manager_file => 'face.html',
}, 'the stored login body keeps only the fields a peer row reads');

# Every peer rail that hands another machine this roster goes through the same
# whitelist, so a field added to the table is not leaked by one route that
# forgot to prune it.
my $root = repo_root();
for my $file (qw(
	lib/JawnOS/Controller/sesh_check.pm
	lib/JawnOS/Controller/manager_misc4.pm
	lib/JawnOS/Manager/Part11.pm
	lib/JawnOS/Domain/Tunnel.pm
)) {
	open(my $fh, '<', "$root/$file") or die "$file: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	like($text, qr/remote_machine_mirror_row/, "$file prunes a mirror payload");
}
like($manager_source, qr/remote_machine_data_view/, 'the handshake stores only the data fields a peer reads');


# A beacon's update hash carries more than one key, and encode_json is a Perl
# list operator with no prototype: `network => encode_json $net, server_time
# => ...` handed every following pair to encode_json, which took only its first
# argument. The peer this machine had just accepted never recorded that it was
# connected and the freshness marker never moved. Drive the real sub against
# the sandbox row and read the columns back.
subs::preload(qw(signature_verify signatorial_designer lan_presence_reply lan_presence_wake));
{
	my $sig = 'encode-json-peer-sig';
	my $peer_ip = '192.168.1.77';
	subs::db_delete('remote_machines', { signatorial => $sig });
	subs::db_insert('remote_machines', {
		uuid        => 'encode-json-peer-uuid',
		signatorial => $sig,
		pubkey      => "-----BEGIN PUBLIC KEY-----\ntest\n-----END PUBLIC KEY-----\n",
		ip          => '192.168.1.99',
		port        => 45545,
		manager     => 'https://192.168.1.99:45545',
		network     => '{"lan":{"ip":"192.168.1.99","port":45545}}',
		status      => 'idle',
		connection  => 'idle',
		tunnel      => 'no',
	});
	my $msg = {
		type        => 'jawnos-lan',
		signatorial => $sig,
		hostname    => 'peer',
		device      => 'computer',
		port        => 45545,
		ts          => CORE::time(),
		sig         => 'test-signature',
		nics        => "eth0|$peer_ip|aa:bb:cc:dd:ee:ff",
	};
	my $before = subs::rightNow();
	{
		no warnings qw(redefine once);
		local *subs::network_interface_reporter = sub { return { eth0 => { ip => '192.168.1.50' } } };
		local *subs::signature_verify = sub { return 1 };
		local *subs::signatorial_designer = sub { return q{this-machine-sig} };
		local *subs::lan_presence_reply = sub { return };
		local *subs::lan_presence_wake = sub { return };
		local *Websocket::send = sub { return };
		subs::lan_presence_accept($msg, $peer_ip);
	}
	my $row = subs::db_select('remote_machines', undef, { signatorial => $sig })->hashes->[0] || {};
	is($row->{'status'}, 'connected',
		'an accepted beacon records that the peer is connected');
	is($row->{'connection'}, 'active',
		'an accepted beacon records the connection as active');
	ok(length($row->{'server_time'} // ''),
		'an accepted beacon records when the peer was seen');
	cmp_ok($row->{'server_time'} // 0, '>=', $before,
		'and that server time is this call, not a stale row');
	my $map = eval { decode_json($row->{'network'} // '') } || {};
	is($map->{'lan'}->{'ip'}, $peer_ip,
		'the accepted beacon still stores the peer LAN map');
}

# The same trap sat in the device refresh: the address JSON swallowed
# `timestamp` and `server_time`, so a card showed a new address with no time.
{
	my $hostname = `hostname`;
	chomp $hostname;
	subs::db_delete('devices', { hostname => $hostname });
	subs::db_insert('devices', {
		uuid     => 'encode-json-device-uuid',
		hostname => $hostname,
		address  => encode_json({ eth0 => { nic => 'eth0', ip => '192.168.1.50', neigh => [] } }),
	});
	my $before = subs::rightNow();
	my $changed = subs::lan_presence_note_device(
		{
			signatorial => 'encode-json-device-peer',
			device      => 'mobile',
			name        => 'Phone',
			hostname    => 'phone',
		},
		'192.168.1.77', 'aa:bb:cc:dd:ee:ff', 45545,
	);
	ok($changed, 'a beacon from a peer on our LAN updates this machine devices row');
	my $row = subs::db_select('devices', undef, { uuid => 'encode-json-device-uuid' })->hashes->[0] || {};
	ok(length($row->{'timestamp'} // ''),
		'the device refresh records when the address was seen');
	cmp_ok($row->{'timestamp'} // 0, '>=', $before,
		'and that timestamp is this refresh, not a stale row');
	ok(length($row->{'server_time'} // ''),
		'the device refresh keeps its server time');
	my $map = eval { decode_json($row->{'address'} // '') } || {};
	is($map->{'eth0'}->{'neigh'}->[0]->{'ip'}, '192.168.1.77',
		'the refreshed address map still carries the peer');
	is($map->{'eth0'}->{'neigh'}->[0]->{'signatorial'}, 'encode-json-device-peer',
		'and the signatorial that identifies it');
}

# A peer's network map carries its own `lo` NIC. That loopback names the peer's
# machine, never a route to it: adopting it made this machine probe its own
# port+6 listener and take that as the peer, which answered 403 to the peer's
# signature (the Table->hub sync, 2026-11-23). A loopback *manager* is a tunnel
# and stays allowed (t/187 pins that), so the guard is in the secure-url picker,
# not in the address list.
my $lo_row = {
	manager => 'https://hub.example:45545',
	fqdn    => 'hub.example',
	ip      => '10.20.0.20',
	port    => 45545,
	network => '{"eth0":{"ip":"10.20.0.20"},"lo":{"ip":"127.0.0.1"}}',
};
{
	no warnings qw(redefine once);
	local *subs::peer_tls_port = sub {
		my ($rm, $host) = @_;
		return 45551 if ($host->{'host'} // '') eq '127.0.0.1';
		return 0;
	};
	local *subs::peer_listener_port = sub { return 45545 };
	# A retired tunnel leaves 127.0.0.1 in `ip` too; the named manager must win,
	# or the secure url points this machine at its own listener and the peer's
	# signature is refused.
	my ($secure, $verified) = subs::peer_secure_url({ %{$lo_row}, ip => '127.0.0.1' },
		'https://hub.example:45545');
	is($secure, 'https://hub.example:45545',
		'a loopback address is never adopted over the named manager');
	ok(!$verified, 'and the named manager is used unverified, not as our own listener');
}

# A row filed by an older identity stored the peer listener's own port, so the
# derived port (stored + offset) names nothing, and the peer was called "no
# verified peer listener" while its listener was up and proving its name (the
# gou's re-admit, 2026-11-25). Both ports are the same listener: the derived one
# is tried first, then the stored one.
SKIP: {
	skip 'IO::Socket::SSL is not installed', 4 unless eval { require IO::Socket::SSL; 1 };
	require IO::Socket::INET;
	my @tried;
	{
		no warnings qw(redefine once);
		local *subs::peer_ca_file = sub { return '/etc/ssl/certs/ca-certificates.crt' };
		local *IO::Socket::SSL::new = sub {
			my ($class, %arg) = @_;
			push @tried, $arg{'PeerPort'};
			return undef unless $arg{'PeerPort'} == 45551;
			open(my $fh, '<', '/dev/null') or return undef;
			return bless $fh, 'IO::Socket::SSL';
		};
		is(subs::peer_tls_port({ ip => '10.9.9.76', port => 45551, tunnel => 'no' }, { host => 'gou.example' }),
			45551, 'a row that stores the listener port verifies on that port');
		is_deeply(\@tried, [ 45557, 45551 ],
			'the derived port is tried first, then the stored one');
		is(subs::peer_tls_port({ ip => '10.9.9.77', port => 45545, tunnel => 'no' }, { host => 'hub.example' }),
			45551, 'a manager-port row still verifies on manager plus the offset');
	}
	# The unverified fallback asks the same question over plain TCP.
	{
		no warnings qw(redefine once);
		local *IO::Socket::INET::new = sub {
			my ($class, %arg) = @_;
			return undef unless $arg{'PeerPort'} == 45551;
			open(my $fh, '<', '/dev/null') or return undef;
			return bless $fh, 'IO::Socket::INET';
		};
		is(subs::peer_listener_port({ ip => '10.9.9.78', port => 45551, tunnel => 'no' }, { host => 'board.example' }),
			45551, 'the plain probe finds a listener-port row too');
	}
}

done_testing();
