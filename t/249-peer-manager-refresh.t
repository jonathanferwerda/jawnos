# tests-for: lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Embedded.pm lib/JawnOS/Manager/Part36.pm lib/JawnOS/Domain/Loader.pm
# covers:    A peer row whose stored manager is a retired loopback port, or a
#           LAN address this machine has left, must resolve to the route that
#           can actually answer: the same LAN when both machines share it, the
#           tailnet otherwise. The address a verified probe used is written
#           back to remote_machines.manager, and a tunnel row keeps its own
#           loopback route.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;
use JawnOSTest;

# The domain layer is lazy: load the real definitions before any local stub.
subs::preload(qw(network_interface_reporter peer_literal_addresses peer_probe_candidates
	peer_literal_manager peer_live_manager peer_manager_host peer_manager_url
	peer_presence_probe peer_manager_remember peer_on_our_lan remote_relay_routes db_update));

# Run one assertion inside a known local network. This is the only input that
# decides whether a peer's LAN literal is a route or a leftover.
sub as_machine_at {
	my ($ip, $code) = @_;
	no warnings qw(redefine once);
	local *subs::network_interface_reporter = sub {
		return { eth0 => { ip => $ip }, public_address => { ip => '203.0.113.9' } };
	};
	return $code->();
}

# The reported dev box: not attached to 192.168.1.0/24. The laptop row still
# carried a retired hub-tunnel manager and both of its addresses.
my $laptop = {
	uuid        => 'laptop-uuid',
	signatorial => 'laptop-sig',
	ip          => '192.168.1.123',
	tailnet_ip  => '100.64.0.3',
	port        => 45545,
	manager     => 'https://127.0.0.1:56138',
	tunnel      => 'no',
	fqdn        => 'laptop.jonathanferwerda.com',
};

# --- address selection -------------------------------------------------------
my ($live, $addrs);
&as_machine_at('10.20.0.10', sub {
	$live  = subs::peer_live_manager($laptop);
	$addrs = subs::peer_literal_addresses($laptop);
});
is($live, 'https://100.64.0.3:45545',
	'a loopback manager resolves to the tailnet when this machine is not on the peer LAN');
is($addrs->[0]->{'host'}, '100.64.0.3',
	'the tailnet is the first literal candidate from another network');
ok(scalar(grep { $_->{'host'} eq '192.168.1.123' } @{$addrs}),
	'the LAN address this machine has left is still tried as a fallback');

&as_machine_at('192.168.1.50', sub {
	$live  = subs::peer_live_manager($laptop);
	$addrs = subs::peer_literal_addresses($laptop);
});
is($live, 'https://192.168.1.123:45545',
	'the LAN address wins when both machines share that LAN');
is($addrs->[0]->{'host'}, '192.168.1.123',
	'and it is the first literal candidate there');

# A row that already stored the LAN literal is corrected once this machine is
# no longer on that network.
my $stored_lan = { %{$laptop}, manager => 'https://192.168.1.123:45545' };
&as_machine_at('10.20.0.10', sub {
	$live = subs::peer_live_manager($stored_lan);
});
is($live, 'https://100.64.0.3:45545',
	'a stored LAN literal is replaced by the tailnet on another network');

# The relay keeps the chosen route first and the other addresses as fallbacks,
# so a stored route that is now a blackhole does not make the peer unreachable.
&as_machine_at('10.20.0.10', sub {
	my @routes = subs::remote_relay_routes($stored_lan);
	is($routes[0], 'https://192.168.1.123:45545', 'the stored route is tried first');
	ok(scalar(grep { $_ eq 'https://100.64.0.3:45545' } @routes),
		'and the tailnet is a fallback when it does not answer');
});

# A tunnel row's loopback belongs to the hub and is kept exactly as stored.
is(subs::peer_live_manager({ %{$laptop}, tunnel => 'yes' }),
	'https://127.0.0.1:56138',
	'a tunnel row keeps its loopback manager');

# With no literal to fall back to, the name is still last.
is(subs::peer_live_manager({ manager => 'https://127.0.0.1:56138', fqdn => 'laptop.example', port => 45545 }),
	'https://laptop.example:45545',
	'a loopback manager with no literal still resolves to the peer fqdn');

# --- the probe tries every candidate -----------------------------------------
# On the shared LAN the direct address is tried first and fails; the tailnet
# must still be reached. This pins that a failed first literal does not end
# the pass.
my (@tried, $probe);
&as_machine_at('192.168.1.50', sub {
	$probe = subs::peer_presence_probe($laptop, {
		signatorial => 'laptop-sig',
		ping        => sub { 0 },
		fetch       => sub {
			my ($c) = @_;
			push @tried, $c->{'host'};
			return $c->{'host'} eq '100.64.0.3' ? 'laptop-sig' : '';
		},
	});
});
ok($probe->{'ok'}, 'the probe finds the peer after the first literal fails');
is($probe->{'manager'}, 'https://100.64.0.3:45545',
	'the address that answered wins over the stale stored one');
is_deeply(\@tried, [ '192.168.1.123', '100.64.0.3' ],
	'both literals are tried, LAN first on that network');

# --- the verified route is written back --------------------------------------
my @writes;
&as_machine_at('10.20.0.10', sub {
	no warnings qw(redefine once);
	local *subs::db_update = sub { push @writes, [@_]; return 1 };
	ok(subs::peer_manager_remember($laptop, 'https://100.64.0.3:45545'),
		'the verified manager is remembered');
	is($writes[0]->[0], 'remote_machines', 'the write names the peer table');
	is($writes[0]->[1]->{'manager'}, 'https://100.64.0.3:45545',
		'and stores the address that answered');
	is($writes[0]->[1]->{'port'}, 45545, 'with the row port in step');
	is($writes[0]->[2]->{'uuid'}, 'laptop-uuid', 'for this peer row');

	@writes = ();
	ok(!subs::peer_manager_remember({ %{$laptop}, tunnel => 'yes' }, 'https://100.64.0.3:45545'),
		'a tunnel row is never rewritten');
	is(scalar @writes, 0, 'and nothing is written for it');

	ok(!subs::peer_manager_remember($laptop, 'https://127.0.0.1:56138'),
		'a loopback is not persisted as a live route');
	is(scalar @writes, 0, 'so the retired tunnel manager cannot heal itself back');
});

# --- the callers use it ------------------------------------------------------
# The verified probe, a healthy levels pull, and a resolved live manager are
# the three places a corrected address is learned; each must persist it.
my $manager_source = manager_source();
like($manager_source,
	qr/sub remote_machine_online\b.*?peer_presence_probe.*?peer_manager_remember/s,
	'remote_machine_online persists the address its probe proved');

my $embedded = do {
	open(my $fh, '<', repo_root() . '/lib/JawnOS/Domain/Embedded.pm') or die $!;
	local $/;
	<$fh>;
};
like($embedded, qr/peer_manager_remember/,
	'a peer that answered the levels health call is written back');

my $remote = do {
	open(my $fh, '<', repo_root() . '/lib/JawnOS/Domain/Remote.pm') or die $!;
	local $/;
	<$fh>;
};
like($remote, qr/peer_live_manager\(\$rm\).*?peer_manager_remember/s,
	'remote_useragent_maker persists a resolved live manager');

done_testing();
