# tests-for: jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino perl/watch.pl
# covers:    An OTA is durable and reports while it runs. Every LittleFS write
#            is checked, free space is refused up front, a short or failed
#            staging is answered with an error instead of wedging the board,
#            the consumed image is removed on the next boot, and the progress
#            callbacks go inline rather than queueing behind the upload that
#            produces them. config_writer reports whether the file landed, so
#            the WiFi an Embedded Update sends is either saved or named as
#            unsaved before the board reboots.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $g1    = read_file("$root/jp/alarmclock/alarmclock_01_globals_clock_ble.ino");
my $g2    = read_file("$root/jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino");
my $g3    = read_file("$root/jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino");
my $g4    = read_file("$root/jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino");
my $watch = read_file("$root/perl/watch.pl");

# --- the upload checks what it writes ----------------------------------------

my ($handler) = $g3 =~ /(void handleCreateProcess\(\) \{.*?\n\})/s;
ok($handler, 'handleCreateProcess is still one function');
like($handler, qr/size_t wrote = rawFile\.write\(raw\.buf, raw\.currentSize\)/,
	'every chunk write is measured');
like($handler, qr/if \(wrote != raw\.currentSize\)/,
	'a short write stops the upload');
like($handler, qr/LittleFS\.info\(fi\)/,
	'free space is checked before staging begins');
like($handler, qr/ota_status_send\(ota_received, "uploading"\)/,
	'progress is reported from the running total');
unlike($handler, qr/coreJobs\[jobTime\]\["url"\]/,
	'progress no longer queues behind the upload that produces it');
like($handler, qr/File check = LittleFS\.open\(path\.c_str\(\), "r"\)/,
	'the staged file is measured before the shim is armed');
like($handler, qr/if \(got < ota_received\)/,
	'a short staged image is refused');
like($g3, qr/void handleCreate\(\) \{\n  if \(ota_failed\)/,
	'a failed upload answers the manager with an error');
like($g2, qr/LittleFS\.remove\("\/alarmclock\.bin"\)/,
	'the image the shim consumed is removed on the next boot');

# --- the config write says whether it landed ---------------------------------

like($g4, qr/bool config_writer\(\)/, 'config_writer reports success');
like($g4, qr/if \(wrote != jconfig\.length\(\)\)/, 'a short config write is a failure');
like($g1, qr/\[cfg\] wifi apply not saved/, 'a BLE WiFi update names a failed save');
like($g2, qr/\[cfg\] wifi not saved/, 'the provisioning page names a failed save');
like($g2, qr/JAWNCFG ERR write failed/, 'USB provisioning refuses to reboot on a failed save');

# --- the progress the panel shows is a real percentage -----------------------

like($watch, qr/sprintf\("%\.0f", \$current \/ \$total_size \* 100\)/,
	'the OTA status route computes a whole percentage');
like($watch, qr/\$percentage = 100 if \$percentage > 100/,
	'and clamps a padded image at 100%');

done_testing();
