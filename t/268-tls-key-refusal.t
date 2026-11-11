# tests-for: lib/JawnOS/Domain/House2.pm lib/JawnOS/Manager/Part11.pm lib/JawnOS/Controller/manager_configure2.pm
# covers:    A transfer of the house key is refused, with an error and a log
#           line, when the only TLS route to the peer cannot be verified. Both
#           transfers used to call insecure(1) and send the secret anyway.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

require JawnOS::Domain::House2;
require JawnOS::Manager::Part11;

# The lazy loader owns these names: load the real module first, or the AUTOLOAD
# behind it would replace the stub.
subs::preload($_) for qw(peer_secure_url peer_tls_verify peer_ca_file log_writer signatorial_designer ui);

# A user agent that records what it was asked to do. Nothing here opens a
# socket, so these tests need no live TLS server.
{
	package FakeUA;
	sub new { bless { insecure => 0, gets => [], posts => [], form => undef }, shift }
	sub max_response_size { $_[0] }
	sub on { $_[0] }
	sub inactivity_timeout { $_[0] }
	sub insecure { $_[0]->{'insecure'}++; $_[0] }
	sub get { my ($self, $url) = @_; push @{$self->{'gets'}}, $url; return FakeTX->new }
	sub post {
		my ($self, $url, $type, $form) = @_;
		push @{$self->{'posts'}}, $url;
		$self->{'form'} = $form;
		return FakeTX->new;
	}
	package FakeTX;
	sub result { return undef }
}

# The roster lookup remote_device_connect makes for a signed login. The row it
# hands back is the one the TLS decision must see.
our $ROSTER_ROW;
{
	package FakeRoster;
	sub hashes { return [ $main::ROSTER_ROW ] }
}

# The identity file and the translations are the machine's own state; a test
# must not write either.
local *subs::signatorial_designer = sub { 'self-sig' };
local *subs::ui = sub { return $_[0] };

my $seal = 'A' x 40;
my $row = {
	manager     => 'https://10.0.0.5:45545',
	ip          => '10.0.0.5',
	port        => '45545',
	signatorial => 'ab' x 16,
};

# --- vault_pull_one ----------------------------------------------------------
# (a) No house CA: no verified route exists at all, so nothing is sent.
{
	my (@logs, $got);
	my $made = 0;
	{
		no warnings 'redefine';
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_ca_file = sub { '' };
		local *subs::peer_tls_verify = sub { return 1 };
		local *subs::log_writer = sub { push @logs, $_[0] };
		local *Mojo::UserAgent::new = sub { $made++; return FakeUA->new };
		$got = subs::vault_pull_one($row, $seal);
	}
	ok(!defined $got, 'no key comes back without a verified route');
	is($made, 0, 'and no user agent is even built');
	like($logs[0] // '', qr/vault pull refused from abababab.*house CA is not enrolled/,
		'the refusal is logged and names the missing CA');
	like($gb::vault_pull_error // '', qr/^house key refused over unverified TLS/,
		'the refusal carries an explicit error');
}

# (b) The CA is on file but the peer is not on its listener: still refused.
{
	my (@logs, $got);
	my $tls = 0;
	{
		no warnings 'redefine';
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { $tls++; return 1 };
		local *subs::log_writer = sub { push @logs, $_[0] };
		$got = subs::vault_pull_one($row, $seal);
	}
	ok(!defined $got, 'an unverified listener is refused');
	is($tls, 0, 'the CA is not applied to a route that is not the listener');
	like($logs[0] // '', qr/peer listener is not verified/, 'the log says which route failed');
}

# (c) The listener is chosen but the CA cannot be applied: refused, no request.
{
	my (@logs, $fake, $got);
	my $tls = 0;
	{
		no warnings 'redefine';
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551', 1) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { $tls++; return 0 };
		local *subs::log_writer = sub { push @logs, $_[0] };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new };
		$got = subs::vault_pull_one($row, $seal);
	}
	ok(!defined $got, 'the pull refuses when the CA could not be applied');
	is($tls, 1, 'the house CA was asked for');
	is(scalar @{$fake->{'gets'}}, 0, 'no pull request goes out');
	like($logs[0] // '', qr/house CA could not be applied/, 'and the log names the cause');
}

# (d) The verified path still works and never turns verification off.
{
	my ($fake, $got);
	my $tls = 0;
	{
		no warnings 'redefine';
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551', 1) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { $tls++; return 1 };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new };
		$got = subs::vault_pull_one($row, $seal);
	}
	is($tls, 1, 'the CA is applied to the verified listener');
	is($fake->{'insecure'}, 0, 'verification is never turned off');
	is(scalar @{$fake->{'gets'}}, 1, 'one pull is made');
	like($fake->{'gets'}->[0] // '', qr{^https://10\.0\.0\.5:45551/manager/vault_share},
		'the verified listener carries the seal');
}

# --- remote_device_connect ---------------------------------------------------
# (e) No house CA: the login body holds the house key, so it is refused.
{
	my (@logs, $fake, $ret);
	{
		no warnings 'redefine';
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_ca_file = sub { '' };
		local *subs::peer_tls_verify = sub { return 1 };
		local *subs::log_writer = sub { push @logs, $_[0] };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new };
		$ret = Manager::remote_device_connect({
			manager   => 'https://10.0.0.5:45545/manager',
			ip        => '10.0.0.5',
			password  => 'house-key-not-a-real-key',
			name      => 'here',
			filename  => 'here.enc',
			timestamp => 1,
			tunnel    => 'no',
		});
	}
	ok($ret && $ret->{'tls_refused'}, 'the peer login is refused without a verified route');
	is($ret->{'body'}->{'authentication'}, 'refused', 'the caller sees an unapproved login');
	like($ret->{'error'} // '', qr/house key.*unverified TLS/, 'the error says the key was not sent');
	like($ret->{'status'} // '', qr/verified TLS/, 'the status is a readable refusal');
	like($logs[0] // '', qr/peer connect refused for 10\.0\.0\.5.*house CA is not enrolled/,
		'and a log line names the peer and the missing CA');
	ok(!defined $ret->{'body'}->{'signatorial'}, 'no peer identity is invented');
	is(scalar @{$fake->{'posts'}}, 0, 'the key was never posted');
}

# (f) The peer listener is not verified though the CA is on file.
{
	my (@logs, $ret);
	my $fake;
	my $tls = 0;
	{
		no warnings 'redefine';
		local *subs::peer_secure_url = sub { return ($_[1], 0) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { $tls++; return 1 };
		local *subs::log_writer = sub { push @logs, $_[0] };
		local *Mojo::UserAgent::new = sub { FakeUA->new };
		$ret = Manager::remote_device_connect({
			manager => 'https://10.0.0.5:45545/manager', ip => '10.0.0.5',
			password => 'house-key-not-a-real-key', tunnel => 'no',
		});
	}
	ok($ret->{'tls_refused'}, 'an unverified listener is refused');
	is($tls, 0, 'the CA is not applied to a route that is not the listener');
	like($logs[0] // '', qr/peer listener is not verified/, 'the log says which route failed');
}

# (g) The listener is chosen but the CA cannot be applied.
{
	my ($fake, $ret);
	{
		no warnings 'redefine';
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551', 1) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { return 0 };
		local *subs::log_writer = sub { };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new };
		$ret = Manager::remote_device_connect({
			manager => 'https://10.0.0.5:45545/manager', ip => '10.0.0.5',
			password => 'house-key-not-a-real-key', tunnel => 'no',
		});
	}
	ok($ret->{'tls_refused'}, 'the login refuses when the CA could not be applied');
	is(scalar @{$fake->{'posts'}}, 0, 'and posts nothing');
}

# (h) The verified path still logs in, on the listener, with no insecure(1).
{
	my ($fake, $tls, $ret);
	{
		no warnings 'redefine';
		local *subs::peer_secure_url = sub { return ('https://10.0.0.5:45551', 1) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { $tls++; return 1 };
		local *subs::log_writer = sub { };
		local *Mojo::UserAgent::new = sub { $fake = FakeUA->new };
		local *Manager::manager_file_maker = sub { return 'fixture.enc' };
		local *Manager::sesh_login_url = sub { return $_[0] . '/sesh_check?fixture=1' };
		$ret = Manager::remote_device_connect({
			manager   => 'https://10.0.0.5:45545/manager',
			ip        => '10.0.0.5',
			password  => 'house-key-not-a-real-key',
			name      => 'here',
			filename  => 'here.enc',
			timestamp => 1,
			tunnel    => 'no',
		});
	}
	is($tls, 1, 'the CA is applied to the verified listener');
	is($fake->{'insecure'}, 0, 'verification is never turned off');
	is(scalar @{$fake->{'posts'}}, 1, 'one login is posted');
	like($fake->{'posts'}->[0] // '', qr{^https://10\.0\.0\.5:45551/sesh_check}, 'to the verified listener');
	is($fake->{'form'}->{'numerics'} // '', 'house-key-not-a-real-key', 'and it carries the login body');
	ok(!ref $ret || !$ret->{'tls_refused'}, 'a verified peer is not refused');
}

# (i) The TLS decision sees every address the roster row advertises.
# peer_live_manager may resolve the login route to the tailnet while rdata
# names only the stored LAN address; the row's own network map is the proof
# that the tailnet address is the same peer. Without it a working listener
# read as "not verified" and the login never minted a session cookie.
{
	my ($seen, $ret);
	{
		no warnings 'redefine';
		local $main::ROSTER_ROW = {
			signatorial => 'ab' x 8, ip => '10.20.0.10', fqdn => '127.0.0.1',
			port => 3001, tailnet_ip => '100.64.0.4',
			network => '{"tailscale0":{"ip":"100.64.0.4"}}',
		};
		local *subs::db_select = sub { return bless {}, 'FakeRoster' };
		local *subs::peer_secure_url = sub { $seen = $_[0]; return ($_[1], 0) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { return 1 };
		local *subs::log_writer = sub { };
		$ret = Manager::remote_device_connect({
			manager => 'https://100.64.0.4:3001/manager', ip => '10.20.0.10',
			signatorial => 'ab' x 8, password => 'house-key-not-a-real-key', tunnel => 'no',
		});
	}
	is($seen->{'tailnet_ip'}, '100.64.0.4', 'the roster tailnet address reaches the TLS decision');
	like($seen->{'network'} // '', qr/100\.64\.0\.4/, 'and so does its network map');
	is($seen->{'ip'}, '10.20.0.10', 'the route rdata names still wins for ip');
	ok($ret->{'tls_refused'}, 'the stubbed refusal still comes back');
}

# --- a tunnel row whose tunnel is not up -------------------------------------
# The hub's rows for the machines that used to dial out to it kept tunnel 'yes'
# after the mesh moved their route to the tailnet. Mapping an absent tunnel built
# a loopback manager with no port, so the login was refused as "unverified"
# although the peer was answering on a direct address its house-CA leaf proves.
{
	package FakeRes;
	sub body { return '{"authentication":"denied"}' }
}
{
	my ($seen, $ret);
	{
		no warnings 'redefine';
		local *subs::db_select = sub { return bless {}, 'FakeRoster' };
		local *subs::peer_secure_url = sub { $seen = $_[1]; return ($_[1], 1) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { return 1 };
		local *subs::log_writer = sub { };
		local *subs::tunnel_port_mapper = sub { return {} };
		local *Manager::manager_file_maker = sub { return 'here.enc' };
		local *Manager::sesh_login_url = sub { return 'https://100.64.0.9:45545/manager/sesh_check' };
		local *FakeTX::result = sub { return bless {}, 'FakeRes' };
		local *Mojo::UserAgent::new = sub { FakeUA->new };
		$ret = Manager::remote_device_connect({
			manager => 'https://100.64.0.9:45545/manager', ip => '100.64.0.9',
			signatorial => 'ab' x 8, password => 'house-key-not-a-real-key',
			tunnel => 'yes', port => '45545',
		});
	}
	is($seen, 'https://100.64.0.9:45545', 'an absent tunnel keeps the direct route');
	ok($ret && !$ret->{'tls_refused'}, 'so the login is not refused as unverified');
}

# A live tunnel port still takes the loopback route the tunnel serves.
{
	my ($seen, $ret);
	{
		no warnings 'redefine';
		local *subs::db_select = sub { return bless {}, 'FakeRoster' };
		local *subs::peer_secure_url = sub { $seen = $_[1]; return ($_[1], 0) };
		local *subs::peer_ca_file = sub { '/fixture/house-ca.pem' };
		local *subs::peer_tls_verify = sub { return 1 };
		local *subs::log_writer = sub { };
		local *subs::tunnel_port_mapper = sub { return { PORT_AHOY => 46000 } };
		local *FakeTX::result = sub { return bless {}, 'FakeRes' };
		local *Mojo::UserAgent::new = sub { FakeUA->new };
		$ret = Manager::remote_device_connect({
			manager => 'https://100.64.0.9:45545/manager', ip => '100.64.0.9',
			signatorial => 'ab' x 8, password => 'house-key-not-a-real-key',
			tunnel => 'yes', port => '45545',
		});
	}
	is($seen, 'https://127.0.0.1:46000', 'a live tunnel still dials its loopback port');
}

# --- the sources -------------------------------------------------------------
# No secret transfer may turn verification off again.
sub slurp_file {
	open(my $fh, '<', $_[0]) or die "open $_[0]: $!";
	local $/;
	my $text = <$fh>;
	close $fh;
	return $text // '';
}

for my $rel (qw(lib/JawnOS/Domain/House2.pm lib/JawnOS/Manager/Part11.pm)) {
	unlike(slurp_file("$FindBin::Bin/../$rel"), qr/^[^#\n]*->insecure\(1\)/m,
		"$rel never disables TLS verification");
}

like(slurp_file("$FindBin::Bin/../lib/JawnOS/Controller/manager_configure2.pm"),
	qr/if \(\$returner->\{'tls_refused'\}\) \{ \$c->render\(json => \$returner\); return; \}/,
	'the route returns the refusal before it touches the device row');

# The session the relay rides must be read from the host the login actually
# reached. remote_device_connect may rewrite $manager to the peer's announced
# fqdn after the post, and a cookie set for the verified listener literal does
# not match that name: the jar looked empty and every approved login stored [].
{
	my $part11 = slurp_file("$FindBin::Bin/../lib/JawnOS/Manager/Part11.pm");
	like($part11, qr/find\(Mojo::URL->new\(\$login_manager\)\)/,
		'the login cookies are read for the listener that served them');
	unlike($part11, qr/find\(Mojo::URL->new\(\$manager\)\)/,
		'not for a manager rewritten after the login');
}

done_testing();
