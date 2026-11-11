# tests-for: lib/JawnOS/Domain/Remote.pm lib/JawnOS/Controller/manager_market.pm lib/JawnOS/Controller/manager_misc.pm lib/JawnOS/Domain/Clock2.pm lib/JawnOS/Domain/Network.pm lib/JawnOS/Domain/Pay2.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Manager/Part06.pm lib/JawnOS/Manager/Part10.pm
# covers:    remote_useragent_maker is the single TLS decision point. It applies
#           the house CA to a verified peer and marks an unverified one insecure.
#           Callers that fan out to peers used to override that decision with
#           ->insecure(1), which downgraded a verified peer. A verified agent must
#           reach the request unmodified, and the named callers must not disable
#           verification on an agent the helper chose.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

require JawnOS::Domain::Remote;
require JawnOS::Domain::Render;
require JawnOS::Domain::Network;

# The lazy loader owns these names: load the real module first, or AUTOLOAD
# would replace a local stub the moment the call reaches it.
subs::preload($_) for qw(
	remote_useragent_maker peer_live_manager peer_secure_url peer_tls_verify
	remote_machine_tunnel_processor remote_machine_lister
	signatorial_designer rightNow ble_chip_record ble_may_serve
);

# A user agent that records the TLS decision it was given. Nothing here opens a
# socket, so these tests need no live TLS server.
{
	package FakeUA;
	sub new { bless { insecure => 0, gets => [], posts => [], timeout => 0 }, shift }
	sub max_response_size { $_[0] }
	sub on { $_[0] }
	sub insecure { $_[0]->{'insecure'}++; $_[0] }
	sub connect_timeout { $_[0] }
	sub request_timeout { $_[0] }
	sub inactivity_timeout {
		my ($self, $value) = @_;
		return $self unless defined $value;
		$self->{'timeout'} = $value;
		return $self;
	}
	sub get { my ($self, $url) = @_; push @{$self->{'gets'}}, $url; return FakeTX->new }
	sub post {
		my ($self, $url) = @_;
		push @{$self->{'posts'}}, $url;
		return FakeTX->new;
	}
	package FakeTX;
	sub new { bless {}, shift }
	sub result { return FakeRes->new }
	package FakeRes;
	sub new { bless {}, shift }
	sub is_success { 1 }
	sub code { 200 }
	sub body { '{}' }
	package FakeLog;
	sub info { }
	sub error { }
}

# --- the helper is the decision point ---------------------------------------
# A verified peer keeps the house CA; the agent handed back must not be marked
# insecure.
{
	my ($fake, $got);
	{
		no warnings 'redefine';
		local *subs::remote_machine_tunnel_processor = sub { $_[0] };
		local *subs::peer_live_manager = sub { $_[0]->{'manager'} };
		local *subs::peer_secure_url = sub { ('https://10.0.0.5:45551', 1) };
		local *subs::peer_tls_verify = sub { $_[0]->{'tls_verified'} = 1; return 1 };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new };
		$got = subs::remote_useragent_maker({
			rm => {
				manager => 'https://10.0.0.5:45545', ip => '10.0.0.5',
				port => '45545', signatorial => 'ab' x 16,
			},
		});
	}
	is($fake->{'insecure'}, 0, 'a verified peer is never marked insecure');
	is($fake->{'tls_verified'}, 1, 'the house CA is applied instead');
	is($got->{'ua'}, $fake, 'the helper hands back the agent it decided on');
	is($got->{'manager'}, 'https://10.0.0.5:45551', 'and the verified listener route');
}

# An unverified peer is marked insecure by the helper, not by a caller.
{
	my ($fake, $got);
	{
		no warnings 'redefine';
		local *subs::remote_machine_tunnel_processor = sub { $_[0] };
		local *subs::peer_live_manager = sub { $_[0]->{'manager'} };
		local *subs::peer_secure_url = sub { ('https://10.0.0.5:45545', 0) };
		local *subs::peer_tls_verify = sub { $_[0]->{'tls_verified'} = 1; return 1 };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new };
		$got = subs::remote_useragent_maker({
			rm => {
				manager => 'https://10.0.0.5:45545', ip => '10.0.0.5',
				port => '45545', signatorial => 'ab' x 16,
			},
		});
	}
	is($fake->{'insecure'}, 1, 'an unverified peer is marked insecure once');
	ok(!$fake->{'tls_verified'}, 'and no CA is claimed for it');
}

# --- a verified helper agent reaches the request unmodified -----------------
# Render::destination_relay used to call ->insecure(1) on the agent the helper
# returned, so a peer with a house-CA leaf was downgraded for the hand-off.
{
	my ($fake, $out);
	{
		no warnings 'redefine';
		local $subs::log = bless {}, 'FakeLog';
		local *subs::signatorial_designer = sub { 'self-sig' };
		local *subs::rightNow = sub { 1700000000000 };
		local *subs::remote_machine_lister = sub {
			[ { signatorial => 'peer-sig', ip => '10.0.0.5', uuid => 'u1', hostname => 'peer' } ]
		};
		local *subs::remote_useragent_maker = sub {
			$fake = FakeUA->new;
			return { ua => $fake, manager => 'https://10.0.0.5:45551/manager' };
		};
		$out = subs::destination_relay({ destination => 'all', app => 'fixture', movement => 'command', timestamp => 1 });
	}
	is($fake->{'insecure'}, 0, 'the relay does not disable verification on the helper agent');
	is(scalar @{$fake->{'posts'}}, 1, 'the hand-off is still sent');
	is($out->{'sent'}, 1, 'and it counts as delivered');
}

# Network::ble_relay_route had the same override in its peer fan-out.
{
	my ($fake, $ok);
	{
		no warnings 'redefine';
		local $subs::log = bless {}, 'FakeLog';
		local %gb::ble_relay_seen = ();
		local *subs::ble_chip_record = sub { { id => 'chip-2', purpose => 'watch', bluetooth => 0 } };
		local *subs::ble_may_serve = sub { 0 };
		local *subs::signatorial_designer = sub { 'self-sig' };
		local *subs::remote_machine_lister = sub { [ { signatorial => 'peer-sig', ip => '10.0.0.5' } ] };
		local *subs::remote_useragent_maker = sub {
			$fake = FakeUA->new;
			return { ua => $fake, manager => 'https://10.0.0.5:45551/manager' };
		};
		$ok = subs::ble_relay_route({
			type => 'relay', to => 'chip-2', from => 'chip-1', id => 'fixture-id',
			hops => 0, message => { text => 'fixture' },
		});
	}
	is($fake->{'insecure'}, 0, 'the BLE relay does not disable verification on the helper agent');
	is(scalar @{$fake->{'posts'}}, 1, 'the relay is still offered to the peer');
	ok($ok, 'and the peer answer counts as sent');
}

# --- the sources -------------------------------------------------------------
sub slurp_file {
	open(my $fh, '<', $_[0]) or die "open $_[0]: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text // '';
}

my @overriders = qw(
	lib/JawnOS/Controller/manager_market.pm
	lib/JawnOS/Controller/manager_misc.pm
	lib/JawnOS/Domain/Clock2.pm
	lib/JawnOS/Domain/Network.pm
	lib/JawnOS/Domain/Pay2.pm
	lib/JawnOS/Domain/Render.pm
	lib/JawnOS/Manager/Part06.pm
	lib/JawnOS/Manager/Part10.pm
);

for my $rel (@overriders) {
	my $source = slurp_file(root() . '/' . $rel);
	unlike($source, qr/->\{'ua'\}->insecure\(1\)/,
		"$rel never disables verification on the helper's agent");
	unlike($source, qr/\$ua = \$ua->insecure\(1\)/,
		"$rel never overrides the helper's decision with insecure(1)");
}

# Part10 keeps its deliberate "a requested install chooses the route" branch;
# only the fan-out agent was changed.
like(slurp_file(root() . '/lib/JawnOS/Manager/Part10.pm'),
	qr/else \{ \$ua->insecure\(1\); \}/,
	'Part10 still disables verification for a requested install, not a peer agent');

done_testing();
