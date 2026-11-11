# tests-for: lib/JawnOS/Domain/Remote.pm lib/JawnOS/Controller/manager_market.pm lib/JawnOS/Controller/manager_misc.pm lib/JawnOS/Domain/Clock2.pm lib/JawnOS/Domain/Network.pm lib/JawnOS/Domain/Pay2.pm lib/JawnOS/Domain/Render.pm lib/JawnOS/Manager/Part06.pm lib/JawnOS/Manager/Part10.pm lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Devicews.pm lib/JawnOS/Manager/Part28.pm lib/JawnOS/Domain/Ble2.pm lib/JawnOS/Controller/manager_people.pm lib/JawnOS/Domain/Lan.pm lib/JawnOS/Domain/Device.pm lib/JawnOS/Domain/Tunnel.pm lib/JawnOS/Controller/manager_configure2.pm perl/tunnel.pl
# covers:    remote_useragent_maker is the single TLS decision point. It applies
#           the house CA to a verified peer and marks an unverified one insecure.
#           Callers that fan out to peers used to override that decision with
#           ->insecure(1), which downgraded a verified peer. A verified agent must
#           reach the request unmodified, and the named callers must not disable
#           verification on an agent the helper chose.
#
#           The five standalone peer agents (key push, the device relay, the
#           remote input socket, the BLE fetch and the crest lookup) make the
#           same decision: verify when the peer/URL is CA-verified, and disable
#           verification only when it is not (an unenrolled peer, a raw homebase
#           address, an unrecorded origin, a self-signed LAN device).

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use Mojo::JSON qw(encode_json);

require JawnOS::Domain::Remote;
require JawnOS::Domain::Render;
require JawnOS::Domain::Network;
require JawnOS::Domain::Key;
require JawnOS::Domain::Devicews;
require JawnOS::Domain::Ble2;
require JawnOS::Manager::Part28;
require JawnOS::Controller::manager_people;
require JawnOS::Controller::manager_configure2;
require(root() . '/perl/tunnel.pl');

# The lazy loader owns these names: load the real module first, or AUTOLOAD
# would replace a local stub the moment the call reaches it.
subs::preload($_) for qw(
	remote_useragent_maker peer_live_manager peer_secure_url peer_tls_verify
	remote_machine_tunnel_processor remote_machine_lister
	signatorial_designer rightNow ble_chip_record ble_may_serve
	db_select config_reader peer_manager_base peer_manager_host
	nearby_position operator_door_push
);

# A user agent that records the TLS decision it was given. Nothing here opens a
# socket, so these tests need no live TLS server.
{
	package FakeUA;
	sub new { bless { insecure => 0, gets => [], posts => [], builts => [], websockets => [], timeout => 0 }, shift }
	sub max_response_size { $_[0] }
	sub on { $_[0] }
	sub insecure { $_[0]->{'insecure'}++; $_[0] }
	sub tls_options { $_[0]->{'tls'} = $_[1] if defined $_[1]; return $_[0]->{'tls'} }
	sub connect_timeout { $_[0] }
	sub request_timeout { $_[0] }
	sub inactivity_timeout {
		my ($self, $value) = @_;
		return $self unless defined $value;
		$self->{'timeout'} = $value;
		return $self;
	}
	sub get {
		my ($self, $url) = @_;
		push @{$self->{'gets'}}, $url;
		return FakeTX->new(result => $self->{'get_result'});
	}
	sub post {
		my ($self, $url) = @_;
		push @{$self->{'posts'}}, $url;
		return FakeTX->new(result => $self->{'post_result'});
	}
	sub build_tx {
		my ($self, $method, $url) = @_;
		push @{$self->{'builts'}}, $url;
		return FakeTX->new(req => bless({}, 'FakeReq'), result => $self->{'start_result'});
	}
	sub start { return $_[1] }
	sub websocket {
		my ($self, $url) = @_;
		push @{$self->{'websockets'}}, $url;
		return $self;
	}
	package FakeTX;
	sub new { my ($class, %args) = @_; return bless { %args }, $class }
	sub req { return $_[0]->{'req'} }
	sub result { return $_[0]->{'result'} || FakeRes->new }
	package FakeRes;
	sub new { my ($class, $body) = @_; return bless { body => $body }, $class }
	sub is_success { 1 }
	sub code { 200 }
	sub body { return $_[0]->{'body'} // '{}' }
	package FakeLog;
	sub info { }
	sub error { }
	package FakeRows;
	sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class }
	sub hashes { return $_[0]->{'rows'} }
	package FakeController;
		sub new { return bless {}, shift }
		sub param { return $_[1] eq 'uuid' ? 'uuid-1234' : undef }
		sub render {
			my ($self, $kind, $payload) = @_;
			$self->{'rendered'} = $payload;
			return 1;
		}
		package FakeJoinController;
		sub new {
			my ($class, %param) = @_;
			return bless { param => \%param, rendered => undef }, $class;
		}
		sub session {
			my ($self, $key) = @_;
			return 'approved' if $key eq 'authentication';
			return 'citizen' if $key eq 'privilege';
			return undef;
		}
		sub param { return $_[0]->{'param'}{$_[1]} }
		sub render {
			my ($self, $kind, $payload) = @_;
			$self->{'rendered'} = $payload;
			return 1;
		}
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

# --- the five standalone peer agents -----------------------------------------
# These do not ride remote_useragent_maker, so each makes the canonical decision
# itself: the verified listener when the house CA can prove the peer, and only
# the route with no CA proof turns verification off.
local *subs::peer_sign_request = sub { };
local *subs::signatorial_designer = sub { 'self-sig' };

# key_push_one: verified -> listener, unverified -> stored manager + fallback.
{
	my @made;
	{
		no warnings 'redefine';
		local *Mojo::UserAgent::new = sub { my $u = FakeUA->new; push @made, $u; return $u };
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551', 1) };
		local *subs::peer_tls_verify = sub { $_[0]->tls_options({ SSL_ca_file => '/fixture/house-ca.pem' }); return 1 };
		subs::key_push_one({ signatorial => 'ab' x 8, manager => 'https://10.0.0.5:45545', ip => '10.0.0.5', port => '45545' }, 'proof');
	}
	is($made[0]->{'insecure'}, 0, 'key push keeps verification on for a verified peer');
	is($made[0]->{'posts'}->[0] // '', 'https://10.0.0.5:45551/manager/key_push',
		'and posts the key to the verified listener');
}
{
	my @made;
	{
		no warnings 'redefine';
		local *Mojo::UserAgent::new = sub { my $u = FakeUA->new; push @made, $u; return $u };
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_tls_verify = sub { return 1 };
		subs::key_push_one({ signatorial => 'ab' x 8, manager => 'https://10.0.0.5:45545', ip => '10.0.0.5', port => '45545' }, 'proof');
	}
	is($made[0]->{'insecure'}, 1, 'key push falls back to insecure only for an unverified peer');
	is($made[0]->{'posts'}->[0] // '', 'https://10.0.0.5:45545/manager/key_push',
		'and an unenrolled peer still gets the key on the stored manager');
}

# device_ws_peer_relay: a recorded candidate uses its row, a raw address does not.
my $od = { __specs => { homebase => '10.0.0.5:45547', name => 'table' } };
my $relay_row = {
	hostname => 'table', ip => '10.0.0.5', tailnet_ip => '100.64.0.5',
	port => '45545', manager => 'https://10.0.0.5:45545',
};
{
	my @made;
	my $sent;
	{
		no warnings 'redefine';
		local *subs::embedded_operator_door = sub { encode_json($od) };
		local *subs::db_select = sub { return FakeRows->new([ { %$relay_row } ]) };
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551/manager/device_ws', 1) };
		local *subs::peer_tls_verify = sub { $_[0]->tls_options({ SSL_ca_file => '/fixture/house-ca.pem' }); return 1 };
		local *Mojo::UserAgent::new = sub {
			my $u = FakeUA->new;
			$u->{'start_result'} = FakeRes->new('{"sent":1}');
			push @made, $u;
			return $u;
		};
		$sent = subs::device_ws_peer_relay('chip-1', { relay => 1 });
	}
	is($sent, 1, 'the recorded homebase takes the frame');
	is($made[0]->{'insecure'}, 0, 'the device relay keeps verification on for a recorded peer');
	is($made[0]->{'builts'}->[0] // '', 'https://10.0.0.5:45551/manager/device_ws',
		'and dials the verified listener');
}
{
	my @made;
	my $sent;
	{
		no warnings 'redefine';
		local *subs::embedded_operator_door = sub { encode_json($od) };
		local *subs::db_select = sub { return FakeRows->new([ { %$relay_row } ]) };
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_tls_verify = sub { return 1 };
		local *Mojo::UserAgent::new = sub {
			my $u = FakeUA->new;
			$u->{'start_result'} = FakeRes->new('{"sent":1}');
			push @made, $u;
			return $u;
		};
		$sent = subs::device_ws_peer_relay('chip-1', { relay => 1 });
	}
	is($sent, 1, 'an unverified recorded peer still takes the frame');
	is($made[0]->{'insecure'}, 1, 'and that route is the only one that turns verification off');
	is($made[0]->{'builts'}->[0] // '', 'https://10.0.0.5:45545/manager/device_ws', 'with the stored address');
}
{
	my @made;
	my $called = 0;
	my $sent;
	{
		no warnings 'redefine';
		local *subs::embedded_operator_door = sub { encode_json($od) };
		local *subs::db_select = sub { return FakeRows->new([]) };
		local *subs::peer_secure_url = sub { $called++; return ($_[1], 0) };
		local *subs::peer_tls_verify = sub { return 1 };
		local *Mojo::UserAgent::new = sub {
			my $u = FakeUA->new;
			$u->{'start_result'} = FakeRes->new('{"sent":1}');
			push @made, $u;
			return $u;
		};
		$sent = subs::device_ws_peer_relay('chip-1', { relay => 1 });
	}
	is($sent, 1, 'a raw homebase address with no row still takes the frame');
	is($called, 0, 'there is no row to ask peer_secure_url about');
	is($made[0]->{'insecure'}, 1, 'so that address keeps the signed fallback');
	like($made[0]->{'builts'}->[0] // '', qr{^https://10\.0\.0\.5:45545/manager/device_ws$},
		'and is dialled as the board named it');
}

# remote_input_socket_for: decide on https, then rewrite to wss.
{
	my @made;
	{
		no warnings 'redefine';
		local %Manager::remote_input_ws = ();
		local %Manager::remote_input_ws_failed = ();
		local *Manager::remote_input_socket_cooling = sub { return 0 };
		local *Manager::remote_useragent_maker = sub { return undef };
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551/manager', 1) };
		local *subs::peer_tls_verify = sub { $_[0]->tls_options({ SSL_ca_file => '/fixture/house-ca.pem' }); return 1 };
		local *Mojo::UserAgent::new = sub { my $u = FakeUA->new; push @made, $u; return $u };
		Manager::remote_input_socket_for({
			uuid => 'peer-1', signatorial => 'ab' x 8,
			manager => 'https://10.0.0.5:45545/manager',
		}, 'tab-1', '[]');
	}
	is($made[0]->{'insecure'}, 0, 'the input socket keeps verification on for a verified peer');
	is($made[0]->{'websockets'}->[0] // '',
		'wss://10.0.0.5:45551/manager/remote_input/ws?signatorial=self-sig',
		'and dials the secure listener before the address is rewritten to wss');
}
{
	my @made;
	{
		no warnings 'redefine';
		local %Manager::remote_input_ws = ();
		local %Manager::remote_input_ws_failed = ();
		local *Manager::remote_input_socket_cooling = sub { return 0 };
		local *Manager::remote_useragent_maker = sub { return undef };
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_tls_verify = sub { return 1 };
		local *Mojo::UserAgent::new = sub { my $u = FakeUA->new; push @made, $u; return $u };
		Manager::remote_input_socket_for({
			uuid => 'peer-2', signatorial => 'cd' x 8,
			manager => 'https://10.0.0.5:45545/manager',
		}, 'tab-2', '[]');
	}
	is($made[0]->{'insecure'}, 1, 'an unverified peer is the only input socket that turns verification off');
	is($made[0]->{'websockets'}->[0] // '',
		'wss://10.0.0.5:45545/manager/remote_input/ws?signatorial=self-sig',
		'and keeps the stored manager');
}

# ble_message_processor: the host decides the TLS policy, not the frame.
{
	local $gb::ble_ua;
	local $gb::ble_ua_house;
	my @made;
	{
		no warnings 'redefine';
		local *subs::ble_link_key = sub { return '' };
		local *subs::config_reader = sub { return { domain => 'house.example' } };
		local *Mojo::UserAgent::new = sub { my $u = FakeUA->new; push @made, $u; return $u };
		subs::ble_message_processor('{"url":"https://192.168.1.20/message"}', '');
		subs::ble_message_processor('{"url":"https://house.example/message"}', '');
		subs::ble_message_processor('{"url":"http://house.example/message"}', '');
	}
	is(scalar @made, 2, 'two agents cover the three URL policies');
	is($made[0]->{'insecure'}, 1, 'a self-signed private-LAN device keeps the lenient agent');
	like($made[0]->{'gets'}->[0] // '', qr{^https://192\.168\.1\.20/}, 'and fetches its URL');
	like($made[0]->{'gets'}->[1] // '', qr{^http://house\.example/}, 'while a plain-http house URL reuses it with no TLS choice');
	is($made[1]->{'insecure'}, 0, 'the house wildcard verifies against the system store, even after a LAN fetch');
	like($made[1]->{'gets'}->[0] // '', qr{^https://house\.example/}, 'and fetches the house URL');
}

# action_23959: the crest origin is a peer when a row names it.
my $crest_entry = {
	crest => { pubkey => 'pk' },
	endpoints => { manager => 'https://10.0.0.5:45545/manager' },
};
my %stubs = (
	'crest_entry_origin' => sub { return 'https://10.0.0.5:45545' },
	'crest_record_read' => sub { return { uuid => 'own-house' } },
	'session_suds' => sub { return 'suds' },
	'crest_key_read' => sub { return 'k' x 32 },
	'crest_code_build' => sub { return 'code' },
	'peer_manager_base' => sub { my $m = shift || ''; $m =~ s{/+$}{}; $m =~ s{/manager$}{}; return $m },
);
{
	my @made;
	{
		no warnings 'redefine';
		local *Manager::people_citizen = sub { return 1 };
		local *subs::crest_peer_find = sub { return $crest_entry };
		local *subs::crest_entry_origin = $stubs{'crest_entry_origin'};
		local *subs::crest_record_read = $stubs{'crest_record_read'};
		local *subs::session_suds = $stubs{'session_suds'};
		local *subs::crest_key_read = $stubs{'crest_key_read'};
		local *subs::crest_code_build = $stubs{'crest_code_build'};
		local *subs::peer_manager_base = $stubs{'peer_manager_base'};
		local *subs::db_select = sub { return FakeRows->new([ { manager => 'https://10.0.0.5:45545', ip => '10.0.0.5', fqdn => 'table.example' } ]) };
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551', 1) };
		local *subs::peer_tls_verify = sub { $_[0]->tls_options({ SSL_ca_file => '/fixture/house-ca.pem' }); return 1 };
		local *Mojo::UserAgent::new = sub { my $u = FakeUA->new; push @made, $u; return $u };
		Manager::action_23959(FakeController->new);
	}
	is($made[0]->{'insecure'}, 0, 'the crest lookup keeps verification on for a recorded peer');
	is($made[0]->{'gets'}->[0] // '', 'https://10.0.0.5:45551/crest/uuid-1234/profile',
		'and asks the verified listener');
}
{
	my @made;
	{
		no warnings 'redefine';
		local *Manager::people_citizen = sub { return 1 };
		local *subs::crest_peer_find = sub { return $crest_entry };
		local *subs::crest_entry_origin = $stubs{'crest_entry_origin'};
		local *subs::crest_record_read = $stubs{'crest_record_read'};
		local *subs::session_suds = $stubs{'session_suds'};
		local *subs::crest_key_read = $stubs{'crest_key_read'};
		local *subs::crest_code_build = $stubs{'crest_code_build'};
		local *subs::peer_manager_base = $stubs{'peer_manager_base'};
		local *subs::db_select = sub { return FakeRows->new([]) };
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_tls_verify = sub { return 1 };
		local *Mojo::UserAgent::new = sub { my $u = FakeUA->new; push @made, $u; return $u };
		Manager::action_23959(FakeController->new);
	}
	is($made[0]->{'insecure'}, 1, 'an origin with no recorded row is the only crest lookup that turns verification off');
	is($made[0]->{'gets'}->[0] // '', 'https://10.0.0.5:45545/crest/uuid-1234/profile',
		'and still asks the origin the crest named');
}

# The five sources: a conditional fallback is allowed, an unconditional one is not.
for my $rel (qw(
	lib/JawnOS/Domain/Key.pm
	lib/JawnOS/Domain/Devicews.pm
	lib/JawnOS/Manager/Part28.pm
	lib/JawnOS/Domain/Ble2.pm
	lib/JawnOS/Controller/manager_people.pm
)) {
	my $source = slurp_file(root() . '/' . $rel);
	my @unconditional = grep {
		my $line = $_;
		$line =~ /insecure\(1\)/ && $line !~ /^\s*#/ && $line !~ /\b(?:if|unless|else)\b/
	} split /\n/, $source;
	is(scalar @unconditional, 0, "$rel has no unconditional insecure(1)");
	unlike($source, qr/insecure\(1\)->get/, "$rel does not chain a stale insecure call into a request");
}

like(slurp_file(root() . '/lib/JawnOS/Domain/Key.pm'),
	qr/peer_secure_url\(\$rm, \$manager\)/, 'key push asks the canonical TLS decision');
like(slurp_file(root() . '/lib/JawnOS/Domain/Devicews.pm'),
	qr/\$_->\{'ip'\}.*\n.*\$_->\{'tailnet_ip'\}/, 'the device relay matches a row by ip and tailnet_ip');
my $part28 = slurp_file(root() . '/lib/JawnOS/Manager/Part28.pm');
my $decide = index($part28, 'peer_secure_url($rm, $manager)');
my $rewrite = index($part28, 's{^https://}{wss://}');
ok($decide >= 0 && $rewrite >= 0 && $decide < $rewrite,
	'the input socket decides on https before rewriting the manager to wss');
my $ble = slurp_file(root() . '/lib/JawnOS/Domain/Ble2.pm');
like($ble, qr/\$gb::ble_ua_house \|\|= Mojo::UserAgent->new/, 'the house BLE fetch has its own verified agent');
like($ble, qr/\$ua->insecure\(1\) if \$url_tls;/, 'only an https private-LAN device turns verification off');
like($ble, qr/\$house_https = \$url_tls && length \$house_domain && \$url_host eq \$house_domain/,
	'and the house origin is chosen by the same host check that permits the fetch');
like(slurp_file(root() . '/lib/JawnOS/Controller/manager_people.pm'),
	qr/peer_secure_url\(\$origin_row, \$origin\)/, 'the crest lookup asks the TLS decision when its origin is a recorded peer');

# --- the LAN peers ------------------------------------------------------------
# The manager port a peer advertises is public/self-signed; its house-CA leaf is
# on the peer listener (port + 6). The LAN paths take that verified route only
# when the leaf proves the address, and keep the signed rail when it does not.
{
	my ($fake, $fix);
	{
		no warnings 'redefine';
		local *subs::embedded_location_grabber = sub { return {} };
		local *subs::lan_physical_network = sub { return [ { ip => '192.168.1.10' } ] };
		local *subs::lan_peer_targets = sub { return [ { ip => '192.168.1.20', port => '45545', device => 'mobile', signatorial => 'peer-sig' } ] };
		local *subs::signatorial_designer = sub { 'self-sig' };
		local *subs::peer_sign_request = sub { };
		local *subs::peer_secure_url = sub { return ('https://192.168.1.20:45551/manager/navigation/position?peer=yes&signatorial=self-sig', 1) };
		local *subs::peer_tls_verify = sub { $_[0]->tls_options({ SSL_ca_file => '/fixture/house-ca.pem' }); return 1 };
		local *Mojo::UserAgent::new = sub {
			$fake = FakeUA->new;
			$fake->{'get_result'} = FakeRes->new('{"latitude":"1.5","longitude":"2.5"}');
			return $fake;
		};
		$fix = subs::nearby_position({ timestamp => 1 });
	}
	is($fake->{'insecure'}, 0, 'nearby position keeps verification on for a proved LAN peer');
	like($fake->{'gets'}->[0] // '', qr{^https://192\.168\.1\.20:45551/manager/navigation/position},
		'and asks the verified listener');
	is($fix->{'latitude'}, '1.5', 'the fix still comes back');
}
{
	my ($fake, $fix);
	{
		no warnings 'redefine';
		local *subs::embedded_location_grabber = sub { return {} };
		local *subs::lan_physical_network = sub { return [ { ip => '192.168.1.10' } ] };
		local *subs::lan_peer_targets = sub { return [ { ip => '192.168.1.20', port => '45545', device => 'mobile', signatorial => 'peer-sig' } ] };
		local *subs::signatorial_designer = sub { 'self-sig' };
		local *subs::peer_sign_request = sub { };
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_tls_verify = sub { return 1 };
		local *Mojo::UserAgent::new = sub {
			$fake = FakeUA->new;
			$fake->{'get_result'} = FakeRes->new('{"latitude":"1.5","longitude":"2.5"}');
			return $fake;
		};
		$fix = subs::nearby_position({ timestamp => 1 });
	}
	is($fake->{'insecure'}, 1, 'an unproved LAN peer is the only route that turns verification off');
	like($fake->{'gets'}->[0] // '', qr{^https://192\.168\.1\.20:45545/manager/navigation/position},
		'and keeps the address it advertised');
}
{
	my ($fake, $count);
	{
		no warnings 'redefine';
		local *subs::db_select = sub { return FakeRows->new([ { signatorial => 'peer-sig', connection => 'active', pubkey => 'pk' } ]) };
		local *subs::peer_lan_address = sub { return { ip => '192.168.1.20', port => '45545', manager => 'https://192.168.1.20:45545' } };
		local *subs::peer_secure_url = sub { return ('https://192.168.1.20:45551/manager/operator_door', 1) };
		local *subs::peer_tls_verify = sub { $_[0]->tls_options({ SSL_ca_file => '/fixture/house-ca.pem' }); return 1 };
		local *subs::peer_sign_request = sub { };
		local *subs::signatorial_designer = sub { 'self-sig' };
		local *subs::rightNow = sub { 1700000000000 };
		local *subs::device_setter = sub { 'server' };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new; return $fake };
		$count = subs::operator_door_push('edt', 'chip', 'value', 1, 'server');
	}
	is($count, 1, 'a proved LAN peer still takes the operator door');
	is($fake->{'insecure'}, 0, 'and keeps verification on');
	is($fake->{'posts'}->[0] // '', 'https://192.168.1.20:45551/manager/operator_door',
		'the verified listener takes it');
}

# --- the join request --------------------------------------------------------
# A target the roster already names is a peer and takes the canonical decision.
{
	my ($fake, $ctl);
	{
		no warnings 'redefine';
		local *subs::rightNow = sub { 1700000000000 };
		local *subs::random_string_creator = sub { 'ABC123' };
		local *subs::machine_name = sub { 'test-machine' };
		local *subs::signatorial_designer = sub { 'self-sig' };
		local *subs::peer_pubkey = sub { 'pk' };
		local *subs::device_setter = sub { 'server' };
		local *subs::jawn_version = sub { '1.0' };
		local *subs::db_query = sub { return FakeRows->new([]) };
		local *subs::db_insert = sub { return 1 };
		local *subs::db_select = sub {
			my ($table) = @_;
			return FakeRows->new([]) unless $table eq 'remote_machines';
			return FakeRows->new([ {
				signatorial => 'peer-sig', ip => '10.0.0.5', fqdn => 'house.example',
				hostname => 'house', manager => 'https://house.example:45545',
			} ]);
		};
		local *subs::peer_manager_host = sub {
			my ($rm) = @_;
			my ($host) = ($rm->{'manager'} || '') =~ m{^https?://([^/:]+)};
			return ($host, undef);
		};
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551/manager/configure/join_request', 1) };
		local *subs::peer_tls_verify = sub { $_[0]->tls_options({ SSL_ca_file => '/fixture/house-ca.pem' }); return 1 };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new; return $fake };
		$ctl = FakeJoinController->new(address => 'house.example');
		Manager::action_12450($ctl);
	}
	is($fake->{'insecure'}, 0, 'a rostered join target keeps verification on');
	is($fake->{'posts'}->[0] // '', 'https://10.0.0.5:45551/manager/configure/join_request',
		'and hands the request to the verified listener');
	is($ctl->{'rendered'}{'ok'}, 1, 'the request is still recorded locally');
}
{
	my ($fake, $ctl);
	{
		no warnings 'redefine';
		local *subs::rightNow = sub { 1700000000000 };
		local *subs::random_string_creator = sub { 'ABC123' };
		local *subs::machine_name = sub { 'test-machine' };
		local *subs::signatorial_designer = sub { 'self-sig' };
		local *subs::peer_pubkey = sub { 'pk' };
		local *subs::device_setter = sub { 'server' };
		local *subs::jawn_version = sub { '1.0' };
		local *subs::db_query = sub { return FakeRows->new([]) };
		local *subs::db_insert = sub { return 1 };
		local *subs::db_select = sub { return FakeRows->new([]) };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new; return $fake };
		$ctl = FakeJoinController->new(address => 'house.example');
		Manager::action_12450($ctl);
	}
	is($fake->{'insecure'}, 0, 'an unrostered public house verifies against the system store');
	is($fake->{'posts'}->[0] // '', 'https://house.example/manager/configure/join_request',
		'and is asked at the address the person typed');
	is($ctl->{'rendered'}{'ok'}, 1, 'the request is still recorded locally');
}

# --- the tunnel hub ----------------------------------------------------------
# The public switch is public-CA; a peer hub may be self-signed.
{
	my $public = Tunnel::_hub_useragent('wss://hub.example.com:45546/manager/tunnel/ws');
	is($public->insecure ? 1 : 0, 0, 'the public tunnel hub verifies against the system store');
	is(($public->tls_options || {})->{'SSL_ca_file'}, undef, 'and needs no house CA for it');
	Tunnel::_hub_allow_self_signed($public);
	is($public->insecure ? 1 : 0, 1, 'a public-looking hub that fails at TLS can fall back to the lenient rail');
	my $local = Tunnel::_hub_useragent('wss://192.168.1.20:45546/manager/tunnel/ws');
	is($local->insecure ? 1 : 0, 1, 'a LAN hub keeps the lenient rail');
	my $tailnet = Tunnel::_hub_useragent('wss://laptop.tail1234.ts.net:45546/manager/tunnel/ws');
	is($tailnet->insecure ? 1 : 0, 1, 'a tailnet hub does too');
}

# --- the sources -------------------------------------------------------------
for my $rel (qw(
	lib/JawnOS/Domain/Lan.pm
	perl/tunnel.pl
)) {
	my $source = slurp_file(root() . '/' . $rel);
	my @unconditional = grep {
		my $line = $_;
		$line =~ /insecure\(1\)/ && $line !~ /^\s*#/ && $line !~ /\b(?:if|unless|else)\b/
	} split /\n/, $source;
	is(scalar @unconditional, 0, "$rel has no unconditional insecure(1)");
}
like(slurp_file(root() . '/lib/JawnOS/Controller/manager_configure2.pm'),
	qr/my \$lenient_post = sub \{\s*\$ua->insecure\(1\);/, 'the join request has one lenient retry');
my $join_source = slurp_file(root() . '/lib/JawnOS/Controller/manager_configure2.pm');
my @join_insecure = $join_source =~ /insecure\(1\)/g;
is(scalar @join_insecure, 1, 'and it is the route\'s only lenient call');
like(slurp_file(root() . '/lib/JawnOS/Domain/Lan.pm'),
	qr/peer_secure_url\(\$row, \$url\)/, 'nearby position asks the TLS decision');
like(slurp_file(root() . '/lib/JawnOS/Domain/Lan.pm'),
	qr/peer_secure_url\(\$land_row, \$url\)/, 'the operator door asks the TLS decision');
like(slurp_file(root() . '/lib/JawnOS/Controller/manager_configure2.pm'),
	qr/peer_secure_url\(\$rm, \$join_url\)/, 'the join request asks the TLS decision when its target is rostered');
like(slurp_file(root() . '/perl/tunnel.pl'),
	qr/_hub_host_is_public/, 'the tunnel hub chooses its trust from the host');

# The two loopback tunnel gates are documented exceptions: their loopback route
# forwards to the peer's manager port, which never carries the house-CA leaf.
like(slurp_file(root() . '/lib/JawnOS/Domain/Tunnel.pm'),
	qr/which the tunnel does not carry/, 'the tunnel gate records why it stays lenient');
like(slurp_file(root() . '/lib/JawnOS/Domain/Device.pm'),
	qr/the house-CA leaf is on the peer listener/, 'the device scan records why it stays lenient');

done_testing();
