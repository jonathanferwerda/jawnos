use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# scripts/peer_pull.pl is the repair lever for rows a timestamp-driven sync
# never asks for: either this machine pulls a window from a peer, or (--remote)
# it asks the peer to pull the window from this machine. The network half is
# exercised against a live peer; these tests pin the pure name/window rules so a
# typo cannot silently point the lever at the wrong machine or the wrong way.

my $script = root() . '/scripts/peer_pull.pl';
require $script;

# ------------------------------------------------------------ normalize_window
is Jawn::PeerPull::normalize_window('120d'), '120d', 'a plain ago span is kept';
is Jawn::PeerPull::normalize_window('-120d'), '120d', 'a leading minus is dropped (a window is a positive span)';
is Jawn::PeerPull::normalize_window(' 6h '), '6h', 'surrounding space is ignored';
is Jawn::PeerPull::normalize_window(''), '3d', 'the default window is three days';
is Jawn::PeerPull::normalize_window(undef), '3d', 'and applies when nothing is given';
ok !defined Jawn::PeerPull::normalize_window('soon'), 'a word that is not a span is refused';

# ---------------------------------------------------------------- resolve_peer
my $rows = [
	{ uuid => 'u-tablet', hostname => 'tablet', signatorial => 'sig-tablet' },
	{ uuid => 'u-old',    hostname => 'tablet-old', signatorial => 'sig-old' },
	{ uuid => 'u-phone',  hostname => 'phone', fqdn => 'phone.tailnet.ts.net', signatorial => 'sig-phone' },
];
my ($rm, $err) = Jawn::PeerPull::resolve_peer('tablet', $rows);
is $rm && $rm->{'uuid'}, 'u-tablet', 'an exact hostname wins over a longer one that contains it';
is $err, '', 'with no error';

($rm, $err) = Jawn::PeerPull::resolve_peer('PHONE', $rows);
is $rm && $rm->{'uuid'}, 'u-phone', 'matching is case-insensitive';

($rm, $err) = Jawn::PeerPull::resolve_peer('tailnet', $rows);
is $rm && $rm->{'uuid'}, 'u-phone', 'a substring of the fqdn finds the peer';

($rm, $err) = Jawn::PeerPull::resolve_peer('nobody', $rows);
ok !$rm, 'an unknown name resolves to nothing';
like $err, qr/no machine matches/, 'and says so';

($rm, $err) = Jawn::PeerPull::resolve_peer('', $rows);
ok !$rm, 'an empty name resolves to nothing';

# ---------------------------------------------------------------- peer_manager
is Jawn::PeerPull::peer_manager({ manager => 'http://127.0.0.1:1/manager' }, 'https://192.168.1.140:45545/manager'),
	'https://192.168.1.140:45545/manager', '--manager overrides the stored address';
is Jawn::PeerPull::peer_manager({ manager => 'https://peer.example:45545' }, undef),
	'https://peer.example:45545/manager', 'a manager URL is rooted at /manager';
is Jawn::PeerPull::peer_manager({ manager => 'https://peer.example:45545/manager/' }, undef),
	'https://peer.example:45545/manager', 'a trailing slash does not double the route';

done_testing();
