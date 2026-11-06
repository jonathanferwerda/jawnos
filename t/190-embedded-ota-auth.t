# tests-for: lib/JawnOS/Controller/manager_embedded.pm jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino
# covers:    The Pico's raw OTA upload never parses query arguments, so the
#            manager sends the device authorization as a header the board
#            collects, and the board falls back to the query copy for an older
#            manager. The uploaded image is padded to a 4 KB page (the OTA shim
#            programs whole pages) and is left in LittleFS for the shim to read
#            after the reboot instead of being removed before it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $controller = read_file("$root/lib/JawnOS/Controller/manager_embedded.pm");
my $handlers   = read_file("$root/jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino");
my $loop       = read_file("$root/jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino");

# --- the manager names the authorization in a header ------------------------

my ($ota) = $controller =~ /(sub action_43561 \{.*?\n\})/s;
ok($ota, 'the pico OTA route is still one action');
like($ota, qr/post\([^{;]*\{[^}]*authorization\s*=>\s*\$auth[^}]*\}[^;]*stream\s*=>\s*\$file/s,
	'the streamed upload carries the authorization as a header');
like($ota, qr/stream\s*=>\s*\$file/, 'and still streams the staged file');

# --- the board reads that header --------------------------------------------

my ($upload) = $loop =~ /(void handleCreateProcess\(\)\s*\{.*?\n\})/s;
ok($upload, 'handleCreateProcess is still one function');
like($upload, qr/server\.header\(\s*"authorization"\s*\)/,
	'the board reads the authorization from a collected header');
like($upload, qr/server\.arg\(\s*"authorization"\s*\)/,
	'and falls back to the query copy for an older manager');

# A collected header has to be registered before the server handles the upload.
like($handlers, qr/collectHeaders\(\s*authorization_headers\s*,\s*1\s*\)/,
	'the authorization header is collected in setup');
my $collect_at = index($handlers, 'collectHeaders');
my $upload_at  = index($handlers, 'server.on(UriRegex("/upload/');
ok($collect_at >= 0 && $upload_at > $collect_at,
	'the header is collected before the upload route is registered');

# --- the image is page-aligned and survives the reboot ----------------------

my $end_at = index($upload, 'raw.status == RAW_END');
ok($end_at >= 0, 'the upload still finishes on RAW_END');
my $end = $end_at >= 0 ? substr($upload, $end_at) : '';
like($end, qr/4096/, 'the image is padded to the OTA shim page size');
like($end, qr/0xFF/, 'with erased-flash bytes, not zeroes');
unlike($end, qr/LittleFS\.end\(\)/, 'the filesystem is not unmounted before the reboot');
unlike($end, qr/LittleFS\.remove\(/, 'the image is not removed before the shim reads it');
like($end, qr/picoOTA\.commit\(\)/, 'the OTA command is still committed');
like($end, qr/rebooting\s*=\s*1/, 'and the board still reboots');

done_testing();
