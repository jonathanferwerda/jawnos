#!/usr/bin/perl
# tests-for: lib/JawnOS/Manager/Part33.pm
# covers:    The Dingaling is the house asking who is at the door, so it is news
#            only from a caller the house cannot place. A linked machine on the
#            signed peer rail is a house call even when the cookie it carries
#            says its session was rejected: after the peer-auth audit left a
#            stale cookie in every relay, each retry fell into the visitor
#            branch and rang the house (throttled to once per five minutes) for
#            weeks. A verified peer is never a stranger, and an unproved caller
#            is still news.

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
	return bless { stash => $args{'stash'} || {} }, $class;
}
sub stash {
	my ($self, $key, $value) = @_;
	$self->{'stash'}->{$key} = $value if @_ > 2;
	return $self->{'stash'}->{$key};
}

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

# The gate has to answer with the proof, not only with the cookie.
my $source = do {
	local $/;
	open(my $fh, '<', root() . '/lib/JawnOS/Manager/Part33.pm') or die "Part33: $!";
	<$fh>;
};
like($source, qr/my \$peer_call = \$c->stash\('peer_verified_key'\) \|\| \(\$app_peer \/\/ &app_peer_ok\(\$c\)\)/,
	'the Dingaling branch reads the peer proof');
like($source, qr/if \(&dingaling_is_news\(\$c, \$visitor, \$authentication, \$peer_call\)\)/,
	'and asks it before ringing');

done_testing();
