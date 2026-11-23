# tests-for: lib/JawnOS/Domain/House.pm lib/JawnOS/Domain/Remote.pm lib/JawnOS/Domain/Embedded.pm lib/JawnOS/Manager/Part36.pm lib/JawnOS/Domain/Loader.pm
# covers:    A peer row whose stored manager is a retired loopback port, or a
#           LAN address this machine has left, must resolve to the route that
#           can actually answer: the same LAN when both machines share it, the
#           tailnet otherwise. The address a verified probe used is written
#           back to remote_machines.manager, and a live tunnel is the fallback
#           route after the tailnet/LAN while its port is an active tunnel.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Mojo::URL ();
use RepoSource;
use JawnOSTest;

# The domain layer is lazy: load the real definitions before any local stub.
	subs::preload(qw(network_interface_reporter peer_literal_addresses peer_probe_candidates
	peer_literal_manager peer_live_manager peer_manager_host peer_manager_url
	peer_presence_probe peer_manager_remember peer_on_our_lan remote_relay_routes db_update
	peer_data_hydrate peer_secure_url remote_relay_request remote_useragent_maker
	remote_machine_lister signatorial_designer log_writer));

# Run one assertion inside a known local network. This is the only input that
# decides whether a peer's LAN literal is a route or a leftover.
#
# peer_secure_url is stubbed too, because it is not pure: it reads a house CA off
# the filesystem and dials the candidate's TLS port for real. On a checkout that
# has server/house-ca.pem, with a live peer on the tailnet, the probe verified a
# certificate and returned the TLS port and two bases for one literal - the two
# failures this file was reported for. This file decides routes, not leaves;
# t/187-house-ca.t owns the certificate side against a listener it starts itself.
sub as_machine_at {
	my ($ip, $code) = @_;
	no warnings qw(redefine once);
	local *subs::network_interface_reporter = sub {
		return { eth0 => { ip => $ip }, public_address => { ip => '203.0.113.9' } };
	};
	local *subs::peer_secure_url = sub { return ($_[1], 0) };
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
	hostname    => 'laptop',
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
is($live, 'https://100.64.0.3:45545',
	'the tailnet wins even when both machines share that LAN');
is($addrs->[0]->{'host'}, '100.64.0.3',
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
	ok(scalar(grep { $_ eq 'https://laptop:45545' } @routes),
		'and the peer hostname is a fallback too');
});

# A tunnel row's loopback is only the fallback: the tailnet is first class and
# is kept while the hub still holds its port. Seed the active tunnel row.
&subs::db_insert('tunnels', {
	signatorial => 'laptop-sig', status => 'active', direction => 'out',
	name => 'PORT_AHOY', in_port => 56138, uuid => 'test-tunnel-56138',
});
is(subs::peer_live_manager({ %{$laptop}, tunnel => 'yes' }),
	'https://100.64.0.3:45545',
	'a live tunnel with a tailnet keeps the tailnet first');
is(subs::peer_live_manager({ signatorial => 'laptop-sig', manager => 'https://127.0.0.1:56138', fqdn => 'laptop.example', port => 45545, tunnel => 'yes' }),
	'https://127.0.0.1:56138',
	'a tunnel-only row keeps its live loopback');
&as_machine_at('10.20.0.10', sub {
	$live = subs::peer_live_manager({ %{$laptop}, manager => 'https://127.0.0.1:56139', tunnel => 'yes' });
});
is($live, 'https://100.64.0.3:45545',
	'a tunnel flag with no active tunnel row falls back to the tailnet');
# The live tunnel's loopback is the probe's last candidate, after the tailnet.
my $order;
&as_machine_at('10.20.0.10', sub {
	my $cands = subs::peer_probe_candidates({ %{$laptop}, tunnel => 'yes' });
	my %pos; my $i = 0;
	$pos{$_->{'host'}} = $i++ for @{$cands};
	$order = [ $pos{'100.64.0.3'}, $pos{'127.0.0.1'} ];
});
ok(defined $order->[0] && defined $order->[1] && $order->[0] < $order->[1],
	'the tailnet is tried before the live tunnel loopback');

# With no literal to fall back to, the name is still last.
is(subs::peer_live_manager({ manager => 'https://127.0.0.1:56138', fqdn => 'laptop.example', port => 45545 }),
	'https://laptop.example:45545',
	'a loopback manager with no literal still resolves to the peer fqdn');

# --- the probe tries every candidate -----------------------------------------
# The tailnet is the first candidate even on a shared LAN; a failed tailnet
# still falls through to the LAN, so a failed first literal does not end the
# pass.
my (@tried, $probe);
&as_machine_at('192.168.1.50', sub {
	$probe = subs::peer_presence_probe($laptop, {
		signatorial => 'laptop-sig',
		ping        => sub { 0 },
		fetch       => sub {
			my ($c) = @_;
			push @tried, $c->{'host'};
			return $c->{'host'} eq '192.168.1.123' ? 'laptop-sig' : '';
		},
	});
});
ok($probe->{'ok'}, 'the probe falls back to the LAN when the tailnet does not answer');
is($probe->{'manager'}, 'https://192.168.1.123:45545',
	'the LAN address that answered wins');
is_deeply(\@tried, [ '100.64.0.3', '192.168.1.123' ],
	'the tailnet is tried before the LAN');

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
	ok(subs::peer_manager_remember({ %{$laptop}, tunnel => 'yes' }, 'https://100.64.0.3:45545'),
		'a tunnel row accepts the direct tailnet route');
	is($writes[0]->[1]->{'manager'}, 'https://100.64.0.3:45545',
		'and stores it as the row route');

	@writes = ();
	ok(!subs::peer_manager_remember({ %{$laptop}, tunnel => 'yes' }, 'https://127.0.0.1:56138'),
		'a tunnel row is never rewritten to a loopback');
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

# --- a row with no data blob learns its database from the handshake ---------
# The hub was joined through a tunnel with an empty `data`, so it had no
# database path: the credentialed login could not be attempted, no session
# cookie was ever stored, and every relayed change to it met the Gate.
{
	my $empty = { signatorial => 'hub', data => undef };
	is(subs::peer_data_hydrate($empty, { database => '/srv/jawnos/database/jawnos.db' }), 1,
		'a row with no data blob is filled from the handshake');
	is($empty->{'data'}->{'database'}, '/srv/jawnos/database/jawnos.db', 'with the peer database path');

	my $known = { signatorial => 'laptop', data => { database => '/old/jawnos.db', device => 'computer' } };
	is(subs::peer_data_hydrate($known, { database => '/new/jawnos.db' }), 0,
		'a path already on the row is left alone');
	is($known->{'data'}->{'database'}, '/old/jawnos.db', 'and is not overwritten');
	is(subs::peer_data_hydrate({ data => {} }, {}), 0, 'a handshake with no database changes nothing');
}

# --- a manual relay that reaches no route is logged -------------------------
# A Configure change made for another machine used to vanish when every known
# route was a dead address: the schedule never landed there and no line said
# why. Drive the real remote_relay_request with a fake agent; only the
# transport, the peer row, the log and the remember write are local.
{
	package RelayFakeTx;
	sub new { my ($class, %arg) = @_; bless \%arg, $class }
	sub result {
		my $self = shift;
		die $self->{'error'} if defined $self->{'error'};
		return $self->{'response'};
	}

	package RelayFakeResponse;
	sub new { my ($class, $code) = @_; bless { code => $code }, $class }
	sub is_success { my $self = shift; return $self->{'code'} >= 200 && $self->{'code'} < 300 }
	sub code { $_[0]->{'code'} }

	package RelayFakeUA;
	sub new { my ($class, $answer) = @_; bless { answer => $answer, connect => 4, tried => [] }, $class }
	sub connect_timeout {
		my $self = shift;
		return $self->{'connect'} unless @_;
		$self->{'connect'} = $_[0];
		return $self;
	}
	sub _try {
		my ($self, $url) = @_;
		push @{$self->{'tried'}}, $url;
		return $self->{'answer'}->($url, scalar @{$self->{'tried'}});
	}
	sub post { my ($self, $url) = @_; return $self->_try($url) }
	sub get  { my ($self, $url) = @_; return $self->_try($url) }

	package RelayFakeReq;
	sub new { my ($class, $method, $path) = @_; bless { method => $method, url => Mojo::URL->new($path) }, $class }
	sub method { $_[0]->{'method'} }
	sub url { $_[0]->{'url'} }

	package RelayFakeController;
	sub new {
		my ($class, %param) = @_;
		return bless {
			param => { %param },
			req   => RelayFakeReq->new('POST', '/manager/configure'),
		}, $class;
	}
	sub param {
		my ($self, $name, $value) = @_;
		return $self->{'param'}->{$name} unless @_ > 2;
		$self->{'param'}->{$name} = $value;
		return $self;
	}
	sub req { $_[0]->{'req'} }
}

my $peer_row = {
	uuid        => 'laptop-uuid',
	signatorial => 'laptop-sig',
	hostname    => 'laptop',
	manager     => 'https://127.0.0.1:56138',
	port        => 45545,
	additions   => '[]',
};
my ($relay_log, $relay_remembered, $relay_ua);
my $run_relay = sub {
	my ($answer, $params) = @_;
	$relay_log = [];
	$relay_remembered = [];
	$relay_ua = RelayFakeUA->new($answer);
	my $c = RelayFakeController->new(remote_uuid => 'laptop-uuid');
	my $ua = $relay_ua;
	no warnings qw(redefine once);
	local *subs::signatorial_designer = sub { return 'this-machine' };
	local *subs::remote_machine_lister = sub { return [ { %{$peer_row} } ] };
	local *subs::remote_useragent_maker = sub { return { %{ $_[0]->{'rm'} }, ua => $ua } };
	local *subs::remote_relay_routes = sub { return 'https://192.0.2.10:45545', 'https://192.0.2.11:45545' };
	local *subs::peer_manager_remember = sub { push @{$relay_remembered}, [@_]; return 1 };
	local *subs::log_writer = sub { push @{$relay_log}, $_[0]; return $_[0] };
	&subs::remote_relay_request($c, {
		override      => 'manual',
		url           => '/manager/configure/utility_controller/peer',
		type          => 'post',
		remote_uuid   => 'laptop-uuid',
		dissemination => 'yes',
		server_time   => 1770000000000,
		params        => $params,
	});
	return $relay_ua;
};

my $ua = $run_relay->(sub {
	my ($url, $n) = @_;
	return RelayFakeTx->new(error => "Connection refused\n") if $n == 1;
	return RelayFakeTx->new(response => RelayFakeResponse->new(503));
}, { device => 'laptop-uuid', setting => 'relay-secret-9f3', value => 'x' });

is(scalar @{$relay_log}, 1, 'a manual relay that reaches no route logs one line');
like($relay_log->[0] // '', qr/laptop/, 'the line names the peer by its hostname');
like($relay_log->[0] // '', qr{/manager/configure/utility_controller/peer},
	'and the request path');
like($relay_log->[0] // '', qr/HTTP 503/, 'and the last route failure');
unlike($relay_log->[0] // '', qr/relay-secret-9f3/, 'but never the request params');
is(scalar @{$relay_remembered}, 0, 'nothing is remembered for a route that never answered');
is(scalar @{$ua->{'tried'}}, 2, 'every route is tried after a transport failure');
like($ua->{'tried'}->[1], qr{^https://192\.0\.2\.11:45545/manager/configure/utility_controller/peer$},
	'and the fallback route is the one that reported the last failure');

my $ok_ua = $run_relay->(sub {
	my ($url, $n) = @_;
	return RelayFakeTx->new(error => "Connection refused\n") if $n == 1;
	return RelayFakeTx->new(response => RelayFakeResponse->new(200));
}, { device => 'laptop-uuid' });

is(scalar @{$relay_log}, 0, 'a route that answers logs nothing');
is(scalar @{$relay_remembered}, 1, 'and a new winning route is remembered');
is($relay_remembered->[0]->[1], 'https://192.0.2.11:45545',
	'the route that answered is the one remembered');
is(scalar @{$ok_ua->{'tried'}}, 2, 'the dead route short-circuits at the answer');

done_testing();
