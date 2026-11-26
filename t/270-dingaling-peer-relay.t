#!/usr/bin/perl
# tests-for: lib/JawnOS/Manager/Part33.pm
# covers:    The Dingaling is the house asking who is at the door, so it is news
#            only from a caller the house cannot place. A linked machine on the
#            signed peer rail is a house call even when the cookie it carries
#            says its session was rejected: after the peer-auth audit left a
#            stale cookie in every relay, each retry fell into the visitor
#            branch and rang the house (throttled to once per five minutes) for
#            weeks. A verified peer is never a stranger, and neither is a
#            roster machine whose session or relay cookie has gone stale: the
#            address or durable name its row pins still places it. An unproved
#            caller with a rejected session is still news.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;

use JawnOSTest;

require(root() . '/lib/JawnOS/Manager/Part33.pm');

package FakeController;
sub new {
	my ($class, %args) = @_;
	return bless { stash => $args{'stash'} || {}, session => $args{'session'} || {} }, $class;
}
sub stash {
	my ($self, $key, $value) = @_;
	$self->{'stash'}->{$key} = $value if @_ > 2;
	return $self->{'stash'}->{$key};
}
sub session {
	my ($self, $key, $value) = @_;
	$self->{'session'}->{$key} = $value if @_ > 2;
	return $self->{'session'}->{$key};
}
# A query standing in for subs::db_select: hashes for a roster read and hash
# for the one-row peer-session lookup.
package FakeQuery;
sub new { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
sub hashes { return $_[0]->{'rows'} }
sub hash { return $_[0]->{'rows'}->[0] }

package main;

my $tabbed = FakeController->new(stash => { browser_tab_id => 'tab' });
my $bare   = FakeController->new;

ok(!Manager::dingaling_is_news($bare, 'Me', 'revoked', 0),
	'the machine itself never rings its own house');
ok(!Manager::dingaling_is_news($tabbed, '192.168.1.5', 'approved', 0),
	'an approved tab is not news');
ok(!Manager::dingaling_is_news($tabbed, '192.168.1.5', 'revoked', 0),
	'a tab this house already revoked is not news either');
ok(!Manager::dingaling_is_news($bare, '100.64.0.11', 'rejected', 1),
	'a peer proved on the signed rail is a house call, whatever its cookie says');
ok(!Manager::dingaling_is_news($bare, '100.64.0.11', 'pending', 1),
	'and so is a peer still mid-handshake');
ok(Manager::dingaling_is_news($bare, '100.64.0.11', 'rejected', 0),
	'an unproved caller carrying a rejected session is news');
ok(Manager::dingaling_is_news($bare, '203.0.113.9', 'revoked', 0),
	'a tab-less stranger over the wire is news');

# A linked machine whose proof did not ride this request is still placed by its
# roster row: an expired peer session, or the address/durable name the row pins.
my $roster = [
	{ uuid => 'table-uuid', signatorial => 'table-sig',
		ip => '192.168.1.147', tailnet_ip => '100.64.0.1',
		manager_file => 'Jonathan@jawnos.Table', pubkey => 'PEM',
		network => '{"wlp1s0":{"ip":"192.168.1.147","gw":"192.168.1.1","broadcast":"192.168.1.255"},"tailscale0":{"ip":"100.64.0.1"}}' },
	# the best route is the tailnet, but the handshake reports its LAN address
	{ uuid => 'lan-uuid', signatorial => 'lan-sig',
		ip => '100.64.0.7', tailnet_ip => '100.64.0.7',
		manager_file => 'lan@jawnos.Laptop', pubkey => 'PEM',
		network => '{"wlp1s0":{"ip":"192.168.1.99","gw":"192.168.1.1"}}' },
	# a name the house heard but never enrolled
	{ uuid => 'keyless-uuid', signatorial => 'keyless-sig',
		ip => '192.168.1.50', tailnet_ip => '', manager_file => 'keyless',
		pubkey => '', network => '{"eth0":{"ip":"192.168.1.50"}}' },
];
{
	no warnings 'redefine';
	local *subs::db_select = sub {
		my ($table, $fields, $where) = @_;
		return FakeQuery->new([]) unless $table eq 'remote_machines';
		my @rows = @{$roster};
		if ($where && defined $where->{'signatorial'}) {
			@rows = grep { ($_->{'signatorial'} || '') eq $where->{'signatorial'} } @rows;
		}
		return FakeQuery->new(\@rows);
	};
	my $peer_session = FakeController->new(session => { peer => '1', peer_signatorial => 'table-sig' });
	ok(Manager::dingaling_known_machine($peer_session, '127.0.0.1'),
		'a peer session still places the machine after its warranty lapses');
	my $gone_session = FakeController->new(session => { peer => '1', peer_signatorial => 'gone-sig' });
	ok(!Manager::dingaling_known_machine($gone_session, '127.0.0.1'),
		'a peer session naming a row that is gone is not proof');
	ok(Manager::dingaling_known_machine($bare, '192.168.1.147'), 'a roster ip places the machine');
	ok(Manager::dingaling_known_machine($bare, '100.64.0.1'), 'and its tailnet ip');
	ok(Manager::dingaling_known_machine($bare, 'Jonathan@jawnos.Table'), 'and its durable name');
	ok(Manager::dingaling_known_machine($bare, '192.168.1.99'),
		'an interface address in the handshake blob places a machine whose best route differs');
	ok(!Manager::dingaling_known_machine($bare, '192.168.1.1'), 'a gateway in that blob does not');
	ok(!Manager::dingaling_known_machine($bare, '192.168.1.50'), 'a row with no pinned key proves nothing');
	ok(!Manager::dingaling_known_machine($bare, '203.0.113.9'), 'an address no row knows is still a stranger');
}

# The gate has to answer with the proof, not only with the cookie, and place a
# roster machine when the proof is missing.
my $source = do {
	local $/;
	open(my $fh, '<', root() . '/lib/JawnOS/Manager/Part33.pm') or die "Part33: $!";
	<$fh>;
};
like($source, qr/my \$peer_call = \$c->stash\('peer_verified_key'\) \|\| \(\$app_peer \/\/ &app_peer_ok\(\$c\)\)/,
	'the Dingaling branch reads the peer proof');
like($source, qr/if \(&dingaling_is_news\(\$c, \$visitor, \$authentication, \$peer_call\)\s*\n\s*&& !&dingaling_known_machine\(\$c, \$visitor\)\)/,
	'and places a known roster machine before ringing');

done_testing();
