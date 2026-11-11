# tests-for: lib/JawnOS/Domain/House.pm
# covers:    A peer whose TLS listener answers TCP but whose leaf does not name
#           the address (a phone whose DHCP lease moved) must still be reached
#           over the signed rail on the plain manager port.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

my $sig = 'peer-sig';
my $row = {
	ip          => '192.168.1.102',
	port        => 45545,
	tunnel      => 'no',
	signatorial => $sig,
};
my $plain  = 'https://192.168.1.102:45545';
my $secure = 'https://192.168.1.102:45551';

# peer_secure_url proves the listener with a real TCP probe. Stub only that
# decision so these tests touch no network; the fetch seam still records every
# request the probe made, including its `verified` flag.
sub probe_with {
	my ($verified, $answer) = @_;
	my @calls;
	my $result;
	{
		no warnings qw(redefine once);
		local *subs::peer_secure_url = sub {
			return $verified ? ($secure, 1) : ($plain, 0);
		};
		$result = subs::peer_presence_probe($row, {
			port        => 45545,
			signatorial => $sig,
			ping        => sub { 1 },
			fetch       => sub {
				my ($c) = @_;
				push @calls, { %{$c} };
				return $answer->($c);
			},
		});
	}
	return ($result, \@calls);
}

# (a) The listener answers TCP, so the probe rewrites to it and verifies; the
# leaf does not name the LAN address, so that attempt fails. The signed rail on
# the manager port authenticates by signature and must be tried once.
my ($fallback, $fallback_calls) = probe_with(1, sub {
	my ($c) = @_;
	return '' if $c->{'verified'};
	return $sig;
});
is($fallback->{'ok'}, 1, 'the plain manager port answers when the verified attempt fails');
is($fallback->{'manager'}, $plain, 'the base that answered is returned as the manager');
is(scalar @{$fallback_calls}, 2, 'exactly one fallback attempt is made, not a second pass');
is($fallback_calls->[0]->{'base'}, $secure, 'the first attempt is the secure listener');
is($fallback_calls->[0]->{'verified'}, 1, 'and it is marked verified');
is($fallback_calls->[1]->{'base'}, $plain, 'the fallback uses the pre-rewrite base');
is($fallback_calls->[1]->{'verified'}, 0, 'and it is marked unverified');
like($fallback_calls->[1]->{'url'}, qr{^\Q$plain\E/\?signatorial=},
	'the signature still rides on the fallback url');
# The claim is the peer's own public signatorial and the manager compares it as
# text (v0.1.2685), so the plaintext claim is the one that may prove the peer.
like($fallback_calls->[0]->{'url'}, qr{\?signatorial=\Q$sig\E$},
	'the first claim is the plaintext signatorial, the form this build answers');

# (b) Neither base answers: the peer is not present. A host that said nothing
# is not an older build, so the sealed claim is not spent on it.
my ($dead, $dead_calls) = probe_with(1, sub { '' });
ok(!$dead->{'ok'}, 'when neither base answers the peer is not present');
is(scalar @{$dead_calls}, 2, 'the verified attempt and its fallback both ran');
like($dead_calls->[0]->{'url'}, qr{\?signatorial=\Q$sig\E$},
	'and only the plaintext claim was asked');

# (c) A verified answer is still the preferred route and is not retried.
my ($verified_ok, $verified_calls) = probe_with(1, sub { $sig });
is($verified_ok->{'ok'}, 1, 'a verified answer still proves the peer');
is($verified_ok->{'manager'}, $secure, 'and keeps the secure base');
is(scalar @{$verified_calls}, 1, 'a verified success does not fall back');
is($verified_calls->[0]->{'verified'}, 1, 'the successful attempt is marked verified');

# (d) When the listener was not chosen there is nothing to fall back from.
my ($plain_miss, $plain_miss_calls) = probe_with(0, sub { '' });
ok(!$plain_miss->{'ok'}, 'an unverified miss is still a miss');
is(scalar @{$plain_miss_calls}, 1, 'no fallback runs when the listener was not chosen');
is($plain_miss_calls->[0]->{'base'}, $plain, 'the one attempt is the plain base');
is($plain_miss_calls->[0]->{'verified'}, 0, 'and it is marked unverified');
like($plain_miss_calls->[0]->{'url'}, qr{\?signatorial=\Q$sig\E$},
	'and it asks in plaintext first');

# (e) A build that predates the text comparison answers 'dunno' to the
# plaintext claim and still recognizes the legacy seal. The probe must try the
# seal on a host that answered, or a mixed-version house reads as absent and
# the hub is dropped from sync (the laptop, 2026-11-11).
my ($sealed_ok, $sealed_calls) = probe_with(0, sub {
	my ($c) = @_;
	return $c->{'url'} =~ /\?signatorial=\Q$sig\E\z/ ? 'dunno' : $sig;
});
is($sealed_ok->{'ok'}, 1, 'a peer that answers dunno is proved by the sealed claim');
is(scalar @{$sealed_calls}, 2, 'the plaintext claim is followed by the seal');
like($sealed_calls->[0]->{'url'}, qr{\?signatorial=\Q$sig\E\z}, 'plaintext first');
unlike($sealed_calls->[1]->{'url'}, qr{\?signatorial=\Q$sig\E\z}, 'then the sealed claim');

my ($plain_ok, $plain_ok_calls) = probe_with(0, sub { $sig });
is($plain_ok->{'ok'}, 1, 'the plain base proves the peer when the listener is absent');
is($plain_ok->{'manager'}, $plain, 'and its own base is returned');
is(scalar @{$plain_ok_calls}, 1, 'still one attempt');

done_testing();
