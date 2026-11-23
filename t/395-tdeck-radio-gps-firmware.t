# tests-for: jt/jt_02_lorawan_radio_gps.ino jt/jt_03_setup.ino jt/jt_04_gps_wifi_helpers.ino jt/jt_05_loop.ino jt/jt_06_ui_lora_keypad.ino jt/jt_08_display_touch_rooms.ino jt/jt_09_mb_buttons_config.ino jt/jt_10_remote_auth.ino jt/jt_13_config_files.ino
# covers:    The deck's SX1262 brings up its output power after begin() (begin
#            resets the power and current limit), every raw transmit goes
#            through one CAD-guarded queue, the receiver re-arms after a
#            transmit or a failed read, and the L76K's constellation and rate
#            come from the panel instead of two hardcoded PCAS commands. The
#            Radio tab shows the channel and the last packet's RSSI/SNR, and
#            every screen clean forgets those labels first.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $jt_radio = read_file("$root/jt/jt_02_lorawan_radio_gps.ino");
my $jt_setup = read_file("$root/jt/jt_03_setup.ino");
my $jt_gps   = read_file("$root/jt/jt_04_gps_wifi_helpers.ino");
my $jt_loop  = read_file("$root/jt/jt_05_loop.ino");
my $jt_key   = read_file("$root/jt/jt_06_ui_lora_keypad.ino");
my $jt_face  = read_file("$root/jt/jt_08_display_touch_rooms.ino");
my $jt_conf_ui = read_file("$root/jt/jt_09_mb_buttons_config.ino");
my $jt_auth  = read_file("$root/jt/jt_10_remote_auth.ino");
my $jt_conf  = read_file("$root/jt/jt_13_config_files.ino");

# --- one bring-up owns begin(), power and current, in that order --------------
my ($apply) = $jt_radio =~ /(static void loraApply\(\).*?\n\}\n)/s;
ok($apply, 'loraApply was found');

my $begin_at = index($apply, 'radio.begin(');
my $power_at = index($apply, 'setOutputPower(');
my $limit_at = index($apply, 'setCurrentLimit(');
ok($begin_at >= 0, 'loraApply begins the radio');
ok($power_at > $begin_at, 'and sets output power after begin() reset it');
ok($limit_at > $power_at, 'and the current limit after the power');

unlike($jt_setup, qr/radio\.begin\(\s*433\.0/,
	'setup no longer hardcodes radio.begin(433.0)');
like($jt_setup, qr/\bloraApply\(\);/,
	'setup brings the radio up through loraApply()');
unlike($jt_setup, qr/radio\.setOutputPower\(\s*22\s*\)/,
	'and no longer applies power before begin()');

like($apply, qr/RADIOLIB_SX126X_SYNC_WORD_PRIVATE/, 'the raw sync word is the private one');
like($apply, qr/lora_tx_power >= 20 \? 140\.0 : 80\.0/,
	'high power gets the bigger current limit');
like($apply, qr/if \(lorawan_enabled && hasRadio\) \{.*?return;/s,
	'a live LoRaWAN modem is not re-initialised for a raw setting');

# --- every raw transmit goes through one CAD-guarded queue --------------------
my ($queue) = $jt_radio =~ /(static void loraQueuePayload\(.*?\n\}\n)/s;
ok($queue, 'loraQueuePayload was found');
like($queue, qr/radio\.scanChannel\(\)/, 'the queue listens (CAD) before it talks');
like($queue, qr/RADIOLIB_LORA_DETECTED/, 'and backs off when the channel is busy');
like($queue, qr/radio\.startTransmit\(/, 'then starts the transmit');
like($queue, qr/loraTxPending = true;/, 'and marks the transmit pending for the DIO1 handler');

my ($service) = $jt_radio =~ /(static void loraService\(\).*?\n\}\n)/s;
ok($service, 'loraService was found');
like($service, qr/radio\.finishTransmit\(\)/, 'a transmit whose DIO1 never came is finished');
like($jt_loop, qr/readRadio\(\);\s*loraService\(\);/,
	'loop() services the radio right after readRadio()');

my ($broadcast) = $jt_key =~ /(void loraChatBroadcast\(.*?\n\}\n)/s;
ok($broadcast, 'loraChatBroadcast was found');
like($broadcast, qr/loraQueuePayload\(/, 'the chat broadcast goes through the queue');
unlike($broadcast, qr/radio\.startTransmit\(/, 'and no longer starts a transmit by hand');
like($broadcast, qr/"queued"/, 'and says queued, not transmitted');

my ($telephone) = $jt_setup =~ /(server\.on\("\/send_telephone".*?\n  \}\);)/s;
ok($telephone, 'the /send_telephone handler was found');
like($telephone, qr/loraQueuePayload\(/, 'it goes through the queue');
unlike($telephone, qr/delay\(2000\)/, 'and no longer blocks for two seconds');

like($jt_auth, qr/static void ap_lora_send.*?loraQueuePayload\(/s,
	'ap_lora_send goes through the queue');
like($jt_auth, qr/static void wifi_lora_send.*?loraQueuePayload\(/s,
	'wifi_lora_send goes through the queue');

my ($toggle) = $jt_auth =~ /(static void loraReceiveToggle\(.*?\n\}\n)/s;
ok($toggle, 'the receive toggle was found');
like($toggle, qr/radio\.startReceive\(\)/, 'turning the receiver on arms it now');
like($toggle, qr/radio\.standby\(\)/, 'turning it off stands the radio down');

# --- the receive path cannot be left unarmed ----------------------------------
my ($read) = $jt_key =~ /(void readRadio\(\).*?\n\}\n)/s;
ok($read, 'readRadio was found');
like($read, qr/if \(loraTxPending\) \{.*?radio\.finishTransmit\(\);.*?radio\.startReceive\(\);/s,
	'a finished transmit is closed and the receiver re-armed');
like($read, qr/radio\.getRSSI\(\)/, 'the received packet keeps its RSSI');
like($read, qr/radio\.getSNR\(\)/, 'and its SNR');
like($read, qr/readData failed.*?radio\.startReceive\(\);/s,
	'a failed read still re-arms the receiver');
like($read, qr/if \(!hasRadio \|\| lorawan_enabled \|\| !operationDone\)/,
	'LoRaWAN and a missing radio stand the raw path down');

# --- the Radio tab shows the channel and the last packet's signal ------------
my ($writer) = $jt_radio =~ /(static void loraSignalWriter\(\).*?\n\}\n)/s;
ok($writer, 'loraSignalWriter was found');
like($writer, qr/LoRa %\.1f MHz SF%u BW%\.0f %d dBm/, 'it prints the configured channel');
like($writer, qr/RX %\.0f dBm  SNR %\.1f dB/, 'and the last packet RSSI/SNR');
like($writer, qr/RX: no packet yet/, 'with a first-run wording before a packet');
like($jt_radio, qr/static void loraSignalForget\(\)/, 'and a forget helper for the pointers');
like($read, qr/lora_has_signal = true;\s*loraSignalDirty = true;/, 'a received packet marks the tab for refresh');
like($service, qr/if \(loraSignalDirty\) \{ loraSignalWriter\(\); \}/, 'the loop flushes the tab');
like($jt_key, qr/void display_exit\( void \) \{\s*loraSignalForget\(\);\s*lv_obj_clean/,
	'a screen wipe forgets the Radio tab labels before deleting them');
like($jt_face, qr/loraSignalForget\(\);\s*button_feedback_forget\(\);\s*lv_obj_clean/,
	'and so does a room rebuild');

my ($config_radio) = $jt_conf_ui =~ /(case 1:.*?break;)/s;
ok($config_radio, 'the Radio tab page was found');
like($config_radio, qr/lora_channel_label = lv_label_create/, 'the tab builds a channel line');
like($config_radio, qr/lora_signal_label = lv_label_create/, 'and a signal line');
like($config_radio, qr/loraSignalWriter\(\);/, 'and fills both on entry');

# --- the new settings are saved, restored and defaulted ----------------------
my ($save)    = $jt_conf =~ /(void configSave\(\).*?\n\}\n)/s;
my ($defaults) = $jt_conf =~ /(void configDefaults\(\).*?\n\}\n)/s;
my ($restore) = $jt_conf =~ /(void configRestore\(\).*?\n\}\n)/s;
ok($save && $defaults && $restore, 'configSave/configDefaults/configRestore were found');

for my $key (qw(lora_frequency lora_spreading_factor lora_bandwidth lora_tx_power
                gps_enabled gps_constellation gps_rate)) {
	like($save, qr/conf\["\Q$key\E"\]/, "configSave writes $key");
	like($restore, qr/conf\["\Q$key\E"\]/, "configRestore reads $key");
}

like($defaults, qr/lora_frequency = 433\.0;/, 'the raw frequency defaults to 433.0');
like($defaults, qr/lora_spreading_factor = 9;/, 'the spreading factor defaults to 9');
like($defaults, qr/lora_bandwidth = 125\.0;/, 'the bandwidth defaults to 125.0');
like($defaults, qr/lora_tx_power = 22;/, 'the power defaults to 22 dBm');
like($defaults, qr/gps_enabled = true;/, 'the GPS defaults on');
like($defaults, qr/gps_constellation = "gps_glonass";/, 'on GPS + GLONASS');
like($defaults, qr/gps_rate = 1;/, 'at 1 Hz');
like($restore, qr/int gps_r = conf\["gps_rate"\];/,
	'the saved update rate is read as the JSON number configSave wrote');

# --- Now Me delivers them over both transports -------------------------------
for my $key (qw(lora_frequency lora_spreading_factor lora_bandwidth lora_tx_power
                gps_enabled gps_constellation gps_rate)) {
	like($jt_setup, qr/server\.arg\("\Q$key\E"\)/,
		"the HTTP /now_me handler reads $key");
	like($jt_loop, qr/params\.hasOwnProperty\("\Q$key\E"\)/,
		"the BLE now_me handler reads $key");
}
like($jt_loop, qr/if \(loraApplyRequested\) \{ loraApply\(\); \}/,
	'the BLE now_me applies a radio change');
like($jt_loop, qr/if \(gpsApplyRequested\) \{ gpsApply\(\); \}/,
	'and a GPS change');

# --- /device_query reports what the deck is doing -----------------------------
for my $key (qw(has_radio lora_frequency lora_spreading_factor lora_bandwidth
                lora_tx_power lora_last_rssi lora_last_snr
                gps_enabled gps_constellation gps_rate gps_ready gps_lat gps_lng gps_sats)) {
	like($jt_setup, qr/g\["\Q$key\E"\] =/, "/device_query reports $key");
}

# --- the GPS constellation and rate are configured, not hardcoded ------------
my ($setup_gps) = $jt_gps =~ /(bool setupGPS\(.*?\n\}\n)/s;
ok($setup_gps, 'setupGPS was found');
like($setup_gps, qr/gpsNmeaWrite\("PCAS04," \+ String\(gpsConstellationMode\(\)\)\)/,
	'the constellation mode comes from the setting');
like($setup_gps, qr/gpsNmeaWrite\("PCAS02," \+ String\(gpsRateMs\(\)\)\)/,
	'and the update interval from the rate');
like($setup_gps, qr/gps_is_l76k = true;/, 'an answered L76K is remembered as one');

my ($nmea) = $jt_gps =~ /(static void gpsNmeaWrite\(.*?\n\}\n)/s;
ok($nmea, 'gpsNmeaWrite was found');
like($nmea, qr/sum \^= \(uint8_t\)body\[i\]/, 'the checksum XORs every character');
like($nmea, qr/\*%02X/, 'and writes it as two uppercase hex digits');

my ($mode) = $jt_gps =~ /(static uint8_t gpsConstellationMode\(\).*?\n\}\n)/s;
ok($mode, 'gpsConstellationMode was found');
like($mode, qr/if \(gps_constellation == "all"\)     \{ return 7; \}/,
	'every constellation mode uses the L76K table');
like($mode, qr/return 5;/, 'and GPS + GLONASS is the fallback');

my ($apply_gps) = $jt_gps =~ /(static void gpsApply\(\).*?\n\}\n)/s;
ok($apply_gps, 'gpsApply was found');
like($apply_gps, qr/if \(!gps_enabled\) \{.*?SerialGPS\.end\(\);.*?gpsReady = false;/s,
	'disabling the GPS closes the port and drops the ready flag');
like($apply_gps, qr/if \(gpsReady && gps_is_l76k\)/, 'a live L76K is reconfigured in place');
like($apply_gps, qr/gpsRetryAt = millis\(\) \+ 1000;/, 'a module that is not up is only scheduled');

# --- the loop does no GPS work when the receiver is off ----------------------
like($jt_loop, qr/if \(gps_enabled && !gpsReady && gpsAttempts < GPS_MAX_ATTEMPTS/,
	'the retry only runs when the GPS is enabled');
like($jt_loop, qr/while \(gps_enabled && gpsReady && SerialGPS\.available\(\)/,
	'NMEA is only parsed for an enabled, ready module');
like($jt_loop, qr/if \(gps_enabled\) \{ SerialGPS\.write\(ch\); \}/,
	'host bytes only reach the GPS when it is enabled');
like($jt_loop, qr/if \(gps_enabled && millis\(\) > 30000 && gps\.charsProcessed\(\) < 10\)/,
	'the no-GPS warning is silenced when the GPS is off');

done_testing();
