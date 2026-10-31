use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# A peer row can carry a loopback manager: it is the hub's own tunnel route, and
# on any other row it is a leftover from a tunnel that no longer exists. Every
# peer call goes through subs::peer_useragent, so that is where the row has to be
# corrected - a machine whose stored manager points at its own 127.0.0.1 dials a
# port that belongs to nothing and never syncs, while a browser on the same
# network reaches the peer perfectly (the tablet, 2026-10-31).

is(subs::peer_live_manager({ manager => 'https://127.0.0.1:53665', fqdn => 'laptop.example', port => '45545' }),
	'https://laptop.example:45545',
	'a stale loopback manager becomes the peer name');

is(subs::peer_live_manager({ manager => 'https://10.0.0.5:45545', fqdn => 'laptop.example', port => '45545' }),
	'https://10.0.0.5:45545',
	'a real manager is left alone');

is(subs::peer_live_manager({ manager => 'https://127.0.0.1:53665', fqdn => 'laptop.example', port => '45545', tunnel => 'yes' }),
	'https://127.0.0.1:53665',
	'a tunnel route keeps its loopback manager');

is(subs::peer_live_manager({ manager => 'https://127.0.0.1:53665' }),
	'https://127.0.0.1:53665',
	'with no name to fall back to, the manager is left alone');

is(subs::peer_live_manager({ manager => 'https://127.0.0.1:53665', fqdn => '127.0.0.1' }),
	'https://127.0.0.1:53665',
	'a loopback name is not a fallback');

# The client every peer call is built from must apply it.
my $source = do {
	open(my $fh, '<', "$FindBin::Bin/../subroutines.pl") or die $!;
	local $/;
	<$fh>;
};
like($source, qr/sub peer_useragent \{.*?peer_live_manager/s,
	'peer_useragent resolves the live manager before it is used');

done_testing();
