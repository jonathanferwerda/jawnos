# tests-for: lib/JawnOS/Manager/Part35.pm
# covers:    A device with a live LAN address is not BLE-only. The house shares
#            one /24, so when the stored homebase's address moves (DHCP) any
#            machine the person presses Now Me on may re-home the device over
#            HTTP, not only the BLE owner. Before this, a WiFi board was classed
#            as BLE, the regular Now Me skipped, and BT Now Me forced the radio
#            that the non-owner had already yielded, so the token never
#            refreshed and the board could not open /device/ws.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $src  = scalar read_file("$root/lib/JawnOS/Manager/Part35.pm");

# --- a LAN ping decides whether the device is BLE-only --------------------
like($src, qr/my \$lan_alive = 0;/, 'now_me computes lan_alive');
like($src, qr/`timeout \.2 ping -c 1 \$watch->\{'ip'\}/, 'it pings the device address');
like($src, qr/\$lan_alive = 1 if \$ping =~ \/ttl\/i;/,
	'a reply marks the device reachable on the LAN');

# --- the owner guard only holds for a radio-only device -------------------
like($src,
	qr/if \(\$watch->\{'ble'\} && !\$lan_alive && !&subs::ble_owns\(/,
	'the skip requires the device to be unreachable on the LAN');
unlike($src,
	qr/if \(\$watch->\{'ble'\} && !&subs::ble_owns\(/,
	'a reachable device is no longer skipped');

# --- the link selection reuses the probe ----------------------------------
like($src, qr/\$link = 'http' if \$lan_alive;/, 'a reachable device is pushed over HTTP');


# --- Now Me is authoritative: a settings save does not re-pair ------------
like($src, qr/my \$keep_pairing = \$data->\{'keep_pairing'\};/,
	'now_me accepts keep_pairing');
like($src, qr/my \$force_home\s+= \$data->\{'force_home'\};/,
	'and force_home');
like($src, qr/unless \(\$keep_pairing\) \{/, 'the token rotation is skipped for a save');
like($src, qr/force_home\s+=> \(\$force_home \? 1 : 0\)/,
	'the push says whether the person meant to move the device');

my $embedded = read_file("$root/lib/JawnOS/Controller/manager_embedded.pm");
my $part34   = read_file("$root/lib/JawnOS/Manager/Part34.pm");
my $watch_ctl = read_file("$root/lib/JawnOS/Controller/manager_watch.pm");
my $ble      = read_file("$root/lib/JawnOS/Domain/Ble.pm");
like($embedded, qr/now_me\(\{[^\n]*force_home => 1 \}\)/,
	'the Now Me button forces the move');
like($ble, qr/force_home => \(\$edt eq 'microcontroller' \? 0 : 1\)/,
	'a BLE re-home moves a watch but leaves a board pinned');
like($part34, qr/now_me\(\{[^\n]*keep_pairing => 1 \}\)/,
	'a settings save keeps the pairing');
like($watch_ctl, qr/now_me\(\{[^\n]*keep_pairing => 1 \}\)/,
	'a watch setting save keeps it too');



done_testing();
