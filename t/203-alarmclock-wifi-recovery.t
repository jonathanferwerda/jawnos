# tests-for: jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino
# covers:    A board that associates but never gets a DHCP lease must not lose
#            its provisioning AP. WL_CONNECTED with localIP() 0.0.0.0 is not a
#            usable link: the boot path keeps the AP up and says why,
#            wifi_join_done refuses to drop it without an address, and
#            wifi_supervise tears the address-less association down so DHCP runs
#            again instead of holding a link that cannot dial the house.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $read = sub { scalar read_file("$root/$_[0]") };

my $globals = $read->('jp/alarmclock/alarmclock_01_globals_clock_ble.ino');
my $boot    = $read->('jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino');
my $loop    = $read->('jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino');

# --- one definition of "usable link" ---------------------------------------
like($loop,
	qr/bool\s+wifi_addressed\(\)\s*\{[^}]*WL_CONNECTED[^}]*WiFi\.localIP\(\)[^}]*IPAddress\(\s*0\s*,\s*0\s*,\s*0\s*,\s*0\s*\)/s,
	'wifi_addressed requires WL_CONNECTED and a non-zero local IP');
like($globals, qr/^\s*bool\s+wifi_addressed\(\)\s*;/m,
	'the sketch forward-declares it for the other parts');

# --- the AP is not dropped without a lease --------------------------------
like($loop,
	qr/void\s+wifi_join_done\(\)\s*\{\s*if\s*\(\s*!\s*wifi_addressed\(\)\s*\)\s*\{[^}]*wifiState\s*=\s*"disconnected"[^}]*return;[^}]*\}\s*WiFi\.softAPdisconnect\(true\)/s,
	'wifi_join_done keeps the AP up and stays disconnected without an address');

# --- the supervise loop treats it as down, keeps the AP, and retries ------
like($loop, qr/if\s*\(\s*wifi_addressed\(\)\s*\)\s*\{\s*wifiDownTicks\s*=\s*0;/,
	'wifi_supervise only resets on an addressed link');
unlike($loop, qr/if\s*\(\s*WiFi\.status\(\)\s*==\s*WL_CONNECTED\s*\)\s*\{\s*wifiDownTicks\s*=\s*0;/,
	'a bare association no longer counts as healthy');
like($loop,
	qr/if\s*\(\s*WiFi\.status\(\)\s*==\s*WL_CONNECTED\s*&&\s*\(wifiDownTicks\s*%\s*DHCP_RETRY_TICKS\)\s*==\s*0\s*\)\s*\{[^}]*WiFi\.disconnect\(\)/s,
	'an address-less association is torn down so DHCP runs again');
like($loop,
	qr/if\s*\(\s*multi\.run\(\)\s*==\s*WL_CONNECTED\s*&&\s*wifi_addressed\(\)\s*\)\s*\{\s*wifi_join_done\(\)\s*;\s*\}/,
	'the rejoin only completes with an address');

# --- the boot path keeps the AP and says why ------------------------------
like($boot, qr/bool\s+linked\s*=\s*\(multi\.run\(\)\s*==\s*WL_CONNECTED[^;]*;/,
	'wifi_start records the association');
like($boot, qr/if\s*\(\s*linked\s*&&\s*wifi_addressed\(\)\s*\)/,
	'the boot success path needs a lease');
like($boot, qr/associated but no IP address; DHCP did not complete/,
	'the boot log names the DHCP failure');

done_testing();
