# tests-for: lib/JawnOS/Domain/ perl/subroutines.pl
# covers:    A peer row can carry a loopback manager: it is the hub's own tunnel route, and on any other row it is a leftov...

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

# The pull routes append /manager/... themselves. A caller that hands over the
# address the panel shows (.../manager) must not produce /manager/manager/...
# - that ask answers with the Gate page, which the pull reads as an empty
# snapshot (the tablet, 2026-10-31).
is(subs::peer_manager_base('https://192.168.1.155:45545/manager'),
	'https://192.168.1.155:45545',
	'the panel address loses its /manager route');
is(subs::peer_manager_base('https://192.168.1.155:45545/manager/'),
	'https://192.168.1.155:45545',
	'a trailing slash after the route is dropped too');
is(subs::peer_manager_base('https://192.168.1.155:45545'),
	'https://192.168.1.155:45545',
	'a base url is left alone');
is(subs::peer_manager_base('https://127.0.0.1:53665'),
	'https://127.0.0.1:53665',
	'a tunnel route keeps its literal base');
is(subs::peer_manager_base(''), '', 'an empty manager stays empty');

# A minted ticket's URL must name a port the peer actually serves it on. The
# mint request goes to the peer's manager, so a direct row uses the manager's own
# port; a tunnel mirror keeps the mapping it is reached through. dock_port is the
# peer's LAN port (3000 on the house), which a peer published on PORT_AHOY does
# not expose from a laptop - that authority was the blank Go window.
is(subs::peer_ticket_port({ port => 45545, dock_port => 3000, fqdn => 'hub.example' }),
	45545, 'a direct row uses its manager port, not dock_port');
is(subs::peer_ticket_port({ port => 45545, port_dock => 45123, dock_port => 3000 }),
	45123, 'a tunnel mirror keeps its mapped dock port');
is(subs::peer_ticket_port({ port => 3001, dock_port => 3000 }),
	3001, 'a direct LAN row uses its own manager port');
is(subs::peer_ticket_port({}),
	3000, 'with no port fields the dock default answers');
is(subs::peer_ticket_port({ manager => 'https://hub.example:45545', dock_port => 3000 }),
	45545, 'a row with no port field takes the port from its manager url');

# The client every peer call is built from must apply it.
my $source = join "\n", map {
	open(my $fh, '<', $_) or die $!;
	local $/;
	<$fh>;
} ("$FindBin::Bin/../perl/subroutines.pl", sort glob("$FindBin::Bin/../lib/JawnOS/Domain/*.pm"));
like($source, qr!sub peer_manager_base \{.*?s\{/manager\$\}\{\}!s,
	'peer_manager_base strips the route segment');
like($source, qr/sub peer_useragent \{.*?peer_live_manager/s,
	'peer_useragent resolves the live manager before it is used');

done_testing();
