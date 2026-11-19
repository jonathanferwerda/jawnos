# tests-for: lib/JawnOS/Domain/Tunnel.pm
# covers:    a client with config tunnel_hub starts a tunnel to that hub even when no NIC neighbour table names it; a tunnel flag with no tunnel row is cleared, and one still reserved is kept

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# A hub named only by config (tunnel_hub) lives behind a subnet route, so it is
# not in `ip neigh` and a scan cannot discover it. The checker must name it from
# the roster row instead of waiting forever for a neighbour that never appears.

package FakeResult;
sub new { my ($class, @rows) = @_; return bless { rows => \@rows }, $class }
sub hashes { return $_[0]->{'rows'} }

# A stand-in user agent that records the form the checker posts, so the test can
# read the alive body itself instead of trusting the source to build it.
package FakeUA;
sub new { return bless {}, shift }
sub inactivity_timeout { return $_[0] }
sub post {
	my ($self, $url, $kind, $form) = @_;
	$main::posted = { url => $url, kind => $kind, form => $form };
	return FakeTx->new();
}
package FakeTx;
sub new { return bless {}, shift }
sub result { return undef }
package main;

our $posted;
my $devices = [];
my @started;
my $active_tunnels = [];
my $network = { 'tailscale0' => { ip => '10.9.0.1', neigh => [] } };

{
	no warnings 'redefine';
	no warnings 'prototype';
	*subs::device_lister = sub { return $devices };
	*subs::device_setter = sub { return 'computer' };
	my $ua = FakeUA->new;
	*subs::db_select = sub {
		my ($table) = @_;
		return FakeResult->new(@{$active_tunnels}) if $table eq 'tunnels';
		return FakeResult->new() unless $table eq 'remote_machines';
		return FakeResult->new(
			{ signatorial => 'hubsig', manager => 'https://hub.example:45545', device => 'server', server_time => 200 },
			{ signatorial => 'oldsig', manager => 'https://cloud.example:45545', device => 'server', server_time => 100 },
		);
	};
	*subs::tunnel_starter = sub { push @started, shift };
	*subs::tunnel_stopper = sub { return 1 };
	*subs::rightNow = sub { return 1000 };
	*subs::db_update = sub { return 1 };
	*subs::network_interface_reporter = sub { return $network };
	*subs::signatorial_designer = sub { return 'designer-sig' };
	*subs::remote_useragent_maker = sub {
		return { manager => 'https://hub.example:45545', ip => 'hub.example', ua => $ua };
	};
	*Tunnel::alive_age = sub { return undef };
	*Tunnel::alive_ports = sub { return undef };
	*Websocket::send = sub { return 1 };
}

my $run = sub {
	@started = ();
	&subs::tunnel_checker({ duty => '', interval => 30 });
};

# no neighbour, but tunnel_hub names the roster's server row
$subs::config = { 'tunnel_hub' => 'https://hub.example:45545' };
$devices = [ { address => { tailscale0 => { neigh => [] } } } ];
$run->();
is(scalar @started, 1, 'the configured hub starts a tunnel without a neighbour');
is($started[0]->{'signatorial'}, 'hubsig', 'the tunnel targets the hub roster row');
is($started[0]->{'ip'}, 'hub.example', 'the target is the hub host, not the retired cloud row');

# the roster's freshest server row wins when no manager matches the host
$devices = [ { address => { tailscale0 => { neigh => [] } } } ];
$subs::config = { 'tunnel_hub' => 'https://moved.example:45545' };
$run->();
is(scalar @started, 1, 'a moved name still falls back to the freshest server row');
is($started[0]->{'signatorial'}, 'hubsig', 'the freshest server row is the target');

# a neighbour that already names the hub is not duplicated
$subs::config = { 'tunnel_hub' => 'https://hub.example:45545' };
$devices = [ { address => { tailscale0 => { neigh => [
	{ ip => 'hub.example', mac => 'aa', purpose => 'server', tunnel => 'active', signatorial => 'hubsig' },
] } } } ];
$run->();
is(scalar @started, 1, 'a discovered hub neighbour is not started twice');

# with no tunnel_hub there is nothing to add
$subs::config = {};
$devices = [ { address => { tailscale0 => { neigh => [] } } } ];
$run->();
is(scalar @started, 0, 'no config hub and no neighbour starts nothing');

# The alive POST is the whole sync, not just the network map. `encode_json` has
# no prototype, so in `network => encode_json $ref, interval => ...` the call
# eats the `interval` and `tunnel` pairs that follow it: the hub receives the
# signatorial and the network map but never the interval or the tunnel batch it
# asked for. Assert the posted body, not the source, so the regression is caught
# wherever the hash is built.
$active_tunnels = [ {
	signatorial => 'hubsig',
	direction => 'in',
	batch_uuid => 'batch-1',
	process_id => $$,
	failures => 0,
	in_port => 45545,
	status => 'active',
	uuid => 'tun-1',
} ];
my $expected_batch = { %{ $active_tunnels->[0] } };
$devices = [ { address => { tailscale0 => { neigh => [] } } } ];
$subs::config = { 'tunnel_hub' => 'https://hub.example:45545' };
$posted = undef;
{
	# the checker only POSTs while the tunnel's holder is alive, and it asks
	# `ps -p <pid> -o cmd=` - so the process title is our own
	local $0 = 'Manager.pl';
	$run->();
}
ok($posted, 'the checker POSTs the alive body to the hub');
is($posted->{'url'}, 'https://hub.example:45545/manager/tunnel/alive', 'the alive POST targets the hub');
is($posted->{'kind'}, 'form', 'the alive body is posted as a form');
my $form = $posted->{'form'} || {};
ok(exists $form->{'network'}, 'the body carries the network map');
ok(exists $form->{'interval'}, 'the body carries the interval the hub asked for');
ok(exists $form->{'tunnel'}, 'the body carries the tunnel batch');
is($form->{'interval'} // '', 30, 'the interval is the checker interval');
is_deeply(
	(exists $form->{'network'} ? eval { Mojo::JSON::decode_json($form->{'network'}) } : undef),
	$network, 'the network map decodes back');
is_deeply(
	(exists $form->{'tunnel'} ? eval { Mojo::JSON::decode_json($form->{'tunnel'}) } : undef),
	[ $expected_batch ], 'the tunnel batch decodes back');

# A tunnel flag with no tunnel row is stale and is cleared; a live or still
# pending tunnel keeps the flag. The hub kept tunnel=yes for Phone/Table/Laptop
# long after their dial-in tunnels were gone, and a reauth then dialled the
# hub's own house-CA port and was refused (2026-11-19).
{
	my @updates;
	local *subs::db_select = sub {
		my ($table, $cols, $where) = @_;
		return FakeResult->new() unless $table eq 'remote_machines' || $table eq 'tunnels';
		if ($table eq 'tunnels') {
			return FakeResult->new({ signatorial => 'pending', status => 'reserved' })
				if $where && ($where->{'signatorial'} || '') eq 'pending';
			return FakeResult->new();
		}
		return FakeResult->new(
			{ signatorial => 'stale', manager => 'https://192.168.1.147:45545', connection => 'active', tunnel => 'yes' },
			{ signatorial => 'pending', manager => 'https://127.0.0.1:63111', connection => 'active', tunnel => 'yes' },
		) if $where && ($where->{'tunnel'} || '') eq 'yes';
		return FakeResult->new();
	};
	local *subs::db_update = sub { push @updates, [ @_ ]; return 1 };
	local *subs::device_setter = sub { 'server' };
	local *subs::ensure_self_device = sub { 1 };
	$subs::config = {};
	$devices = [];
	&subs::tunnel_checker({ duty => '', interval => 30 });
	my ($cleared) = grep { ($_->[2]->{'signatorial'} || '') eq 'stale' } @updates;
	ok($cleared, 'a tunnel flag with no tunnel row is cleared');
	is($cleared->[1]->{'tunnel'}, 'no', 'and the row is written as tunnel=no');
	ok(!(grep { ($_->[2]->{'signatorial'} || '') eq 'pending' } @updates),
		'a tunnel still reserved keeps its flag');
}

done_testing();
