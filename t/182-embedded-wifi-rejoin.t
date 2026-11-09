# tests-for: jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino templates/embedded/body.html.ep templates/embedded/watch.html.ep public/js/manager/embedded.js perl/help/topics_configure.pl
# covers:    A board re-joining its WiFi kept every AP it had ever been given:
#            WiFiMulti only ever adds, so the BLE apply could still land on the
#            network the person had just replaced. Only the configured pair may
#            remain, an SSID without a password is not a join, and an empty or
#            unreadable /wifi_update answer must never clear the saved pair and
#            reboot into AP mode. The panel's WiFi card gains a lazily filled
#            Scan list and on-screen clues; the help topic says both.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $globals  = read_file("$root/jp/alarmclock/alarmclock_01_globals_clock_ble.ino");
my $handlers = read_file("$root/jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino");
my $loop     = read_file("$root/jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino");
my $body     = read_file("$root/templates/embedded/body.html.ep");
my $watch    = read_file("$root/templates/embedded/watch.html.ep");
my $js       = read_file("$root/public/js/manager/embedded.js");
my $help     = read_file("$root/perl/help/topics_configure.pl");

# --- the BLE apply only rejoins on a complete pair ----------------------------
my ($apply) = $globals =~ /(static void ble_apply_wifi\(JSONVar data\) \{.*?\n\})/s;
ok($apply, 'ble_apply_wifi is still one function');
like($apply, qr/if \(s != "" && p != ""\) \{\s*WiFi\.disconnect\(\);/,
	'an SSID on its own does not drop the current network');
unlike($apply, qr/if \(s != ""\) \{\s*WiFi\.disconnect\(\);/,
	'and the old SSID-only rejoin is gone');

# --- wifi_start leaves only the configured AP in the list --------------------
my ($start) = $handlers =~ /(void wifi_start\(\) \{.*?\n\})/s;
ok($start, 'wifi_start is still one function');
my $clear = index($start, 'multi.clearAPList();');
my $add   = index($start, 'multi.addAP(');
ok($clear >= 0, 'wifi_start clears the multi list');
ok($add > $clear, 'before it adds the configured pair (the list only ever grew)');

# --- a rejoin must not switch the mode after the station is up --------------
my ($join_done) = $loop =~ /(void wifi_join_done\(\) \{.*?\n\})/s;
ok($join_done, 'wifi_join_done is still one function');
unlike($join_done, qr/WiFi\.mode\(WIFI_STA\)/,
	'the rejoin does not switch to WIFI_STA after the station is up (that dropped it)');
like($join_done, qr/wifi_ap_down_pending = true;/,
	'it keeps the provisioning AP for now (dropping it here dropped the station)');
like($loop, qr/WiFi\.softAPdisconnect\(true\);[^\n]*\n[^\n]*\[wifi\] link held; AP down/s,
	'and drops it once the link has held');

# --- /wifi_update refuses an empty or unreadable answer ----------------------
my ($update) = $handlers =~ /(server\.on\("\/wifi_update".*?\n  \}\);)/s;
ok($update, 'the /wifi_update route is still one handler');
like($handlers, qr/req\["ip"\] = WiFi\.localIP\(\)\.toString\(\)/,
	'the state request carries the board\'s own LAN address');
like($handlers, qr/JAWNCFG MORE[^\n]*ip=/, 'and the diagnostic reads it back');
like($update, qr/JSON\.typeof\(info\) != "object"/,
	'an unreadable answer is refused before anything is applied');
like($update, qr/next_ssid == "" \|\| next_password == ""/,
	'a blank pair is refused too');
my $object_guard = index($update, 'JSON.typeof(info) != "object"');
my $pair_guard   = index($update, 'next_ssid == "" || next_password == ""');
my $apply_block  = index($update, 'multi.clearAPList();');
ok($object_guard >= 0 && $object_guard < $apply_block,
	'the unreadable guard runs before the saved pair is cleared');
ok($pair_guard >= 0 && $pair_guard < $apply_block,
	'and so does the blank-pair guard');
unlike($update, qr/String\(\(const char \*\)info\[/,
	'it no longer turns a missing field into the literal "null"');

# --- the panel has a scannable, still-typable WiFi field ---------------------
like($body, qr/<datalist id="teletype_wifi_ssids"><\/datalist>/,
	'the SSID field has an empty datalist to fill');
like($body, qr/id="teletype_wifi_ssid" list="teletype_wifi_ssids"/,
	'and the field is bound to it');
like($body, qr/id="teletype_wifi_scan"/, 'there is a Scan button');
like($body, qr/&subs::ui\('your WiFi network name'\)/,
	'the SSID talks in on-screen words');
like($body, qr/&subs::ui\('Type the name or press Scan and pick one'\)/,
	'and says the stored name can still be typed');

like($body, qr/id="teletype_wifi_ap_ssid"[^\n]*&subs::ui\('the board.*?own network name'\)/,
	'the AP SSID has a clue');
like($body, qr/id="embedded_device_picker"[^\n]*&subs::ui\('Choose a watch, deck or board'\)/,
	'the device picker has a clue');
like($body, qr/<option value=""><%= &subs::ui\('Choose a device'\) %><\/option>/,
	'and the chip picker names its blank choice');
like($body, qr/id="embedded_device_chip_id"[^\n]*&subs::ui\('Choose the device to control'\)/,
	'the chip picker has a clue');

# both password fields: value="" + data-set + a placeholder, never the stored text
for my $id (qw/teletype_wifi_password teletype_wifi_ap_password/) {
	like($body, qr/id="$id" value="" data-set=/,
		"$id never echoes the stored password");
	like($body, qr/id="$id"[^\n]*placeholder="<%= &subs::ui\(/,
		"$id has an on-screen placeholder");
}
like($body, qr/id="teletype_wifi_update"[^>]*&subs::ui\('Send the stored WiFi name and password to the device'\)/,
	'Update WiFi says what it sends and where');
like($body, qr/id="teletype_usb_update"[^>]*&subs::ui\('Write the stored WiFi name and password over USB'\)/,
	'Update USB says what the cable is for');

# the watch page mirrors it, and must not print the stored password either
for my $id (qw/teletype_wifi_password teletype_wifi_ap_password/) {
	like($watch, qr/id="$id" value="" data-set=/,
		"the watch card never echoes $id");
}
like($watch, qr/<datalist id="teletype_wifi_ssids"><\/datalist>/,
	'the watch card has the same scannable list');
like($watch, qr/id="teletype_wifi_scan"/, 'and the same Scan button');

# --- the scan is fired after the panel is drawn, not at load ----------------
like($js, qr/windowMaker\(response\.html\);\s*localStorage\.setItem[^;]*;\s*localStorage\.setItem[^;]*;\s*\/\/[^\n]*\n\s*embeddedWifiScan\(\);/s,
	'the panel scan runs after windowMaker has put the card in the page');
like($js, qr{url: '/manager/network/wifi_scan'},
	'it reuses the Networks app scan, not a second scan route');
like($js, qr/function embeddedWifiScan\(\)/,
	'there is one scan helper');
like($js, qr/\$\('#teletype_wifi_ssids'\)\.empty\(\)/,
	'a manual Scan clears the old answers first');
like($js, qr/\$\('<option>'\)\.attr\('value', ssid\)/,
	'and the answers become datalist options');
like($js, qr/function embeddedChipId\(\) \{\s*return \$\('#embedded_device_chip_id'\)\.val\(\)/,
	'the rendered chip picker wins over the remembered one');
like($js, qr/\$\(document\)\.on\('click', '#teletype_wifi_scan'/,
	'the Scan button is delegated, so an AJAX-rendered panel still answers');
unlike($js, qr/timeout:\s*\d+.*wifi_scan/s,
	'the scan is not put on a load-time timer');

# --- the help topic says Scan and the blank-password rule -------------------
like($help, qr/Scan to fill the list/,
	'the embedded topic explains Scan');
like($help, qr/Leave a password box blank/,
	'and says a blank password keeps the stored one');
like($help, qr/Update USB/,
	'and names the USB update');

done_testing();
