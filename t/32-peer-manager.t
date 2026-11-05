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

# The login is the one peer call that must reach the peer's own door. A row
# entered on the old LAN port moves to the port the peer announces; a hidden
# dock port is never named again.
is(subs::peer_entry_url('https://10.0.0.5:3000', 45545),
	'https://10.0.0.5:45545', 'the announced port replaces the old LAN port');
is(subs::peer_entry_url('http://10.0.0.5:3000', 45545),
	'http://10.0.0.5:45545', 'the scheme is kept');
is(subs::peer_entry_url('https://[::1]:6100', 45545),
	'https://[::1]:45545', 'a bracketed address keeps its brackets');
is(subs::peer_entry_url('https://10.0.0.5', 45545),
	'https://10.0.0.5', 'a url with no port is left alone');
is(subs::peer_entry_url('https://10.0.0.5:3000', ''),
	'https://10.0.0.5:3000', 'no announced port leaves the url alone');
is(subs::peer_entry_url('https://10.0.0.5:3000', 'x'),
	'https://10.0.0.5:3000', 'a non-numeric announcement is ignored');
is(subs::peer_entry_url(undef, 45545), undef, 'nothing to rewrite, nothing returned');

# A Go request from the installed app may be a ticket session rather than an
# app_login, but the app's own bridge flags are still its proof. A plain browser
# sends neither and must not mint.
is(subs::go_from_app({ app_device => 'device-1' }), 1,
	'an app_login device is the app');
is(subs::go_from_app({ desktop => '1', bridge => '1' }), 1,
	'a remote window opened by the app is the app even without app_device');
is(subs::go_from_app({ desktop => '1' }), 0,
	'the desktop flag alone is not proof');
is(subs::go_from_app({ bridge => '1' }), 0,
	'the bridge flag alone is not proof');
is(subs::go_from_app({ desktop => '1', bridge => '1', app_device => '' }), 1,
	'an empty app_device does not cancel the app window');
is(subs::go_from_app({ desktop => '0', bridge => '0' }), 0,
	'a browser is not the app');
is(subs::go_from_app({}), 0, 'no proof, no ticket');

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
