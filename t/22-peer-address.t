# tests-for: lib/JawnOS.pm lib/JawnOS/Controller/ lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Sync.pm lib/JawnOS/Domain/Warehouse.pm lib/JawnOS/Manager.pm lib/JawnOS/Manager/ lib/JawnOS/Routes.pm lib/JawnOS/Routes/ perl/Manager.pl
# covers:    A peer's stored manager can outlive the route it named: a LAN address the machine has since left, or a 127.0.0...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;
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
# LAN address must try the LAN first: the offline tailnet node would otherwise
# blackhole the pass.
is(subs::peer_address_rank('192.168.1.155'), 0, 'a private LAN address ranks first');
is(subs::peer_address_rank('100.64.0.3'), 1, 'a tailnet address ranks after the LAN');
my $tailnet_row = {
	ip      => '100.64.0.3',
	fqdn    => 'laptop.jonathanferwerda.com',
	port    => 45545,
	network => '{"lan":{"ip":"192.168.1.155","port":"45545"}}',
};
my $ranked = subs::peer_probe_candidates($tailnet_row, 45545);
is($ranked->[0]->{'host'}, '192.168.1.155',
	'the advertised LAN address is tried before the stored tailnet ip');

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
my $addresses = subs::peer_literal_addresses($remembered);
my @hosts = map { $_->{'host'} } @{$addresses};
ok(scalar(grep { $_ eq '100.64.0.6' } @hosts), 'a persisted tailnet address is a probe candidate');
my $lan_at = (grep { $hosts[$_] eq '192.168.1.142' } 0 .. $#hosts)[0];
my $tail_at = (grep { $hosts[$_] eq '100.64.0.6' } 0 .. $#hosts)[0];
ok(defined $lan_at && defined $tail_at && $lan_at < $tail_at,
	'the LAN address is still tried before the tailnet one');

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

done_testing();
