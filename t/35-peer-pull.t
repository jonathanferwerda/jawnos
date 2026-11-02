# tests-for: lib/JawnOS.pm lib/JawnOS/Controller/ lib/JawnOS/Domain/House.pm lib/JawnOS/Manager.pm lib/JawnOS/Manager/ lib/JawnOS/Routes.pm lib/JawnOS/Routes/ perl/Manager.pl scripts/peer_pull.pl scripts/deploy_neighbours.pl
# covers:    scripts/peer_pull.pl is the repair lever for rows a timestamp-driven sync never asks for: either this machine ...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use RepoSource;
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

# ---------------------------------------------------------------- peer_resolve
my $rows = [
	{ uuid => 'u-tablet', hostname => 'tablet', signatorial => 'sig-tablet' },
	{ uuid => 'u-old',    hostname => 'tablet-old', signatorial => 'sig-old' },
	{ uuid => 'u-phone',  hostname => 'phone', fqdn => 'phone.tailnet.ts.net', signatorial => 'sig-phone' },
];
my ($rm, $err) = subs::peer_resolve('tablet', $rows);
is $rm && $rm->{'uuid'}, 'u-tablet', 'an exact hostname wins over a longer one that contains it';
is $err, '', 'with no error';

($rm, $err) = subs::peer_resolve('PHONE', $rows);
is $rm && $rm->{'uuid'}, 'u-phone', 'matching is case-insensitive';

($rm, $err) = subs::peer_resolve('tailnet', $rows);
is $rm && $rm->{'uuid'}, 'u-phone', 'a substring of the fqdn finds the peer';

($rm, $err) = subs::peer_resolve('nobody', $rows);
ok !$rm, 'an unknown name resolves to nothing';
like $err, qr/no machine matches/, 'and says so';

($rm, $err) = subs::peer_resolve('', $rows);
ok !$rm, 'an empty name resolves to nothing';

# Both Android devices report the hostname 'localhost' (Android has no hostname
# of its own), so an exact hostname is not unique. Refuse it, name the
# candidates, and let an ip or signatorial reach one of them.
my $handhelds = [
	{ uuid => 'u-fe',     hostname => 'localhost', ip => '192.168.1.140', signatorial => 'sig-fe' },
	{ uuid => 'u-tablet2', hostname => 'localhost', ip => '192.168.1.142', signatorial => 'sig-tablet2' },
];
($rm, $err) = subs::peer_resolve('localhost', $handhelds);
ok !$rm, 'an ambiguous exact hostname resolves to nothing';
like $err, qr/more than one machine/, 'and refuses instead of guessing';
like $err, qr/192\.168\.1\.140/, 'the refusal names the first candidate by ip';
like $err, qr/192\.168\.1\.142/, 'and the second';

($rm, $err) = subs::peer_resolve('192.168.1.142', $handhelds);
is $rm && $rm->{'uuid'}, 'u-tablet2', 'an ip reaches the right handheld despite the shared hostname';

($rm, $err) = subs::peer_resolve('sig-fe', $handhelds);
is $rm && $rm->{'uuid'}, 'u-fe', 'and so does the signatorial';

# A row's `ip` is only the address it was last reached at - a machine on the
# tailnet keeps its LAN address in the network map - so the map's addresses name
# the row too.
my $moved = [
	{
		uuid       => 'u-table',
		hostname   => 'Table',
		ip         => '100.64.0.1',
		tailnet_ip => '100.64.0.1',
		network    => '{"lan":{"nic":"lan","ip":"192.168.1.123","port":45545}}',
		signatorial => 'sig-table',
	},
];
($rm, $err) = subs::peer_resolve('192.168.1.123', $moved);
is $rm && $rm->{'uuid'}, 'u-table', 'the LAN address in the network map names a row whose ip moved to the tailnet';
($rm, $err) = subs::peer_resolve('100.64.0.1', $moved);
is $rm && $rm->{'uuid'}, 'u-table', 'and so does the tailnet address it currently carries';
($rm, $err) = subs::peer_resolve('192.168.1', $moved);
ok !$rm, 'half an address is not a match';

# deploy_neighbours uses the same resolver, so a hostname collision no longer
# answers "no such machine" for one of the two handhelds.
my $deploy_script = root() . '/scripts/deploy_neighbours.pl';
require $deploy_script;
my ($picked, $refused) = Jawn::DeployNeighbours::select_machines(['192.168.1.142'], $handhelds);
is scalar @{$picked}, 1, 'the deploy lever picks the machine named by ip';
is $picked->[0]->{'uuid'}, 'u-tablet2', 'the right one';
is scalar @{$refused}, 0, 'with nothing refused';

($picked, $refused) = Jawn::DeployNeighbours::select_machines(['localhost'], $handhelds);
is scalar @{$picked}, 0, 'an ambiguous name deploys nothing';
is scalar @{$refused}, 1, 'and is reported once';
like $refused->[0], qr/more than one machine/, 'with the candidates in the message';

($picked, $refused) = Jawn::DeployNeighbours::select_machines([], $rows);
is scalar @{$picked}, 3, 'no names means every machine';

# ---------------------------------------------------------------- peer_manager
is Jawn::PeerPull::peer_manager({ manager => 'http://127.0.0.1:1/manager' }, 'https://192.168.1.140:45545/manager'),
	'https://192.168.1.140:45545/manager', '--manager overrides the stored address';
is Jawn::PeerPull::peer_manager({ manager => 'https://peer.example:45545' }, undef),
	'https://peer.example:45545/manager', 'a manager URL is rooted at /manager';
is Jawn::PeerPull::peer_manager({ manager => 'https://peer.example:45545/manager/' }, undef),
	'https://peer.example:45545/manager', 'a trailing slash does not double the route';

# A stale roster ip must not decide where the pull dials: the CLI hands the
# proven manager to the local route, and only an approved session may name one.
{
	my $read = sub {
		open(my $fh, '<', $_[0]) or die "$_[0]: $!";
		local $/;
		my $text = <$fh>;
		close $fh;
		return $text;
	};
	my $script = $read->(root() . '/scripts/peer_pull.pl');
	like $script, qr/manager => \$peer_manager/, 'the local pull passes the proven manager';
	like $script, qr/local_pull\(\$rm, \$window, \$url\)/, 'the resolved peer url reaches it';
	my $manager = manager_source();
	like $manager, qr/manager => \$manager_override/, 'the route accepts a proven manager';
	like $manager, qr/\$c->session\('authentication'\) eq 'approved'\) \? \$c->param\('manager'\)/,
		'only an approved session may name it';
}

done_testing();
