# tests-for: lib/JawnOS/Domain/Tunnel.pm
# covers:    a client with config tunnel_hub starts a tunnel to that hub even when no NIC neighbour table names it

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
package main;

my $devices = [];
my @started;

{
	no warnings 'redefine';
	no warnings 'prototype';
	*subs::device_lister = sub { return $devices };
	*subs::device_setter = sub { return 'computer' };
	*subs::db_select = sub {
		my ($table) = @_;
		return FakeResult->new() unless $table eq 'remote_machines';
		return FakeResult->new(
			{ signatorial => 'hubsig', manager => 'https://hub.example:45545', device => 'server', server_time => 200 },
			{ signatorial => 'oldsig', manager => 'https://cloud.example:45545', device => 'server', server_time => 100 },
		);
	};
	*subs::tunnel_starter = sub { push @started, shift };
	*subs::rightNow = sub { return 1000 };
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

done_testing();
