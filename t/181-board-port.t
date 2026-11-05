# tests-for: lib/JawnOS/Domain/Embedded.pm lib/JawnOS/Domain/Device.pm lib/JawnOS/Domain/Say.pm lib/JawnOS/Manager/Part34.pm lib/JawnOS/Manager/Part11.pm lib/JawnOS/Manager/Part36.pm perl/President.pl
# covers:    A board's firmware port is PORT_BOARD, not our entry port; the peer login no longer detours through a dock port.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# Two ports wore one name. PORT_DOCK is the house's entry/ticket door, but the
# sketches in jp/, jt/ and jw/ hardcode 3000 for their own web server, and the
# board probes read PORT_DOCK for it. Moving the entry door (PORT_DOCK ->
# PORT_AHOY) would have sent every /device_query to a port that is not
# listening. PORT_BOARD now names the firmware port on its own, defaulting to
# 3000 because that is what the boards answer on.
#
# The second half is why the entry door may move at all: /sesh_check is a public
# path on every listener and every listener registers the same route table, so
# the peer login can dial the peer's own port instead of a hidden dock one.

my $root = repo_root();
my $president = read_file("$root/perl/President.pl");
my $embedded  = read_file("$root/lib/JawnOS/Domain/Embedded.pm");
my $device    = read_file("$root/lib/JawnOS/Domain/Device.pm");
my $say       = read_file("$root/lib/JawnOS/Domain/Say.pm");
my $part34    = read_file("$root/lib/JawnOS/Manager/Part34.pm");
my $part11    = read_file("$root/lib/JawnOS/Manager/Part11.pm");
my $part36    = read_file("$root/lib/JawnOS/Manager/Part36.pm");
my $hooks     = read_file("$root/perl/hooks.pl");
my $app       = read_file("$root/lib/JawnOS.pm");

# --- the board port is its own name ------------------------------------------

like($president, qr/\$ENV\{PORT_BOARD\} = \$config->\{'board_port'\} \|\| 3000;/,
	'President publishes the board port, defaulting to the firmware 3000');
like($president, qr/\$ENV\{PORT_DOCK\} = \$dock_port;/, 'the entry port is still PORT_DOCK');

my ($scan) = $embedded =~ /(sub embedded_levels_scan \{.*?\n\})/s;
ok($scan, 'embedded_levels_scan is still one sub');
like($scan, qr/\$ENV\{'PORT_BOARD'\} \|\| 3000/, 'the levels scan defaults to the board port');
unlike($scan, qr/\$ENV\{'PORT_DOCK'\}/, 'the levels scan no longer reads our entry port from the environment');

my @board_query = $part34 =~ /^(\s*my \$manager = .*\/device_query.*)$/mg;
is(scalar @board_query, 1, 'one board query url in the embedded panel');
like($board_query[0], qr/\$ENV\{PORT_BOARD\} \|\| 3000/, 'the board query falls back to the board port');
unlike($board_query[0], qr/\|\| \$ENV\{PORT_DOCK\}/, 'the board query does not fall back to the entry port');

my @device_query = $device =~ /^(\s*my \$manager = .*\/device_query.*)$/mg;
is(scalar @device_query, 1, 'one board query url in the device sweep');
like($device_query[0], qr/\$ENV\{PORT_BOARD\} \|\| 3000/, 'the sweep falls back to the board port');
unlike($device_query[0], qr/\|\| \$ENV\{PORT_DOCK\}/, 'the sweep does not fall back to the entry port');

my @manager_probe = $device =~ /^(\s*my \$manager = .*\/manager.*)$/mg;
ok(scalar @manager_probe, 'the peer manager probe is still built');
unlike($manager_probe[0], qr/PORT_BOARD/, 'a peer manager is not dialled on the board port');
like($manager_probe[0], qr/PORT_DOCK/, 'a peer manager keeps the entry port');

like($say, qr/PeerPort => \(\$ENV\{PORT_BOARD\} \|\| 3000\)/,
	'the wifi reply test probes the board port');
unlike($say, qr/PeerPort => 3000/, 'the board port is no longer hardcoded');

# --- the peer login dials the peer's own door --------------------------------

like($hooks, qr/\$path eq '\/sesh_check'/, '/sesh_check is a public path on every listener');
like($app, qr/JawnOS::Routes->register\(\$self, \$r\)/,
	'every listener registers the same route table');

unlike($part11, qr/\$dock_port/, 'the peer login no longer rewrites to a dock port');
like($part11, qr/\$rdata->\{'port'\} \|\| \$ENV\{PORT_AHOY\}/,
	'the login port falls back to the entry port, not the dock');
like($part11, qr/&sesh_login_url\(\$manager, \$browser_tab_id, \$signatorial, \$login\)/,
	'the login still goes to /sesh_check');
like($part11, qr/&subs::peer_entry_url\(\$manager, \$announced\)/,
	'the login adopts the port the peer announces');

unlike($part36, qr/my \$port_dock = \$rm->\{'dock_port'\}/,
	'the auth test no longer swaps a live call to the dock port');

done_testing();
