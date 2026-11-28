# tests-for: jw/jw_01_globals.ino jw/jw_03_setup.ino jw/jw_04_loop.ino jw/jw_05_loop2.ino jw/jw_06_net_face.ino jw/jw_11_configure.ino jw/jw_13_serial_lowpower.ino jw/jw_14_settings.ino jw/jw_15_config_files.ino jw/jw_02_ble.ino jw/jw_07_house_audio.ino jw/jw_12_wrist.ino
# covers:    The watch actually sleeps when Sleep is on, and the awake screen
#            stops polling what does not change. A connected BLE bridge used to
#            keep the watch out of the real light sleep for as long as the bridge
#            held the link - the doze it fell into instead runs the core at
#            80 MHz with the radio up, so "sleeping" drained the battery. The
#            bridge is now held for a bounded window after the screen goes dark
#            (a burst of taps still rides one link) and then torn down for the
#            real sleep. The LoRa radio is parked unless receive is on, and the
#            face's fuel gauge, step counter and labels are read at 1 Hz with
#            writes only when the text changes, instead of once per ~5 ms pass.
#            A BLE WiFi push ends the doze (and skips the sleep) so jawn_loop()
#            runs the join at once, with the panel still dark. That push also
#            joins from cold (mode set, old link dropped), survives a reboot
#            (saved on success) and never prints its password.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root      = repo_root();
my $jw_globals = read_file("$root/jw/jw_01_globals.ino");
my $jw_setup   = read_file("$root/jw/jw_03_setup.ino");
my $jw_loop    = read_file("$root/jw/jw_04_loop.ino");
my $jw_loop2   = read_file("$root/jw/jw_05_loop2.ino");
my $jw_net     = read_file("$root/jw/jw_06_net_face.ino");
my $jw_doze    = read_file("$root/jw/jw_11_configure.ino");
my $jw_sleep   = read_file("$root/jw/jw_13_serial_lowpower.ino");
my $jw_save    = read_file("$root/jw/jw_14_settings.ino");
my $jw_config  = read_file("$root/jw/jw_15_config_files.ino");
my $jw_ble     = read_file("$root/jw/jw_02_ble.ino");
my $jw_house   = read_file("$root/jw/jw_07_house_audio.ino");
my $jw_wrist   = read_file("$root/jw/jw_12_wrist.ino");

# --- a live bridge delays the sleep, it does not cancel it -------------------
like( $jw_sleep, qr/const bool want_sleep = lightSleep && !watch\.isUsbIn\(\);/,
	'the sleep decision follows the setting and the cable' );
unlike( $jw_sleep, qr/lightSleep && !watch\.isUsbIn\(\) && !ble_link_ready\(\)/,
	'a connected bridge is no longer a reason to skip the real sleep for ever' );
like( $jw_sleep, qr/#define BLE_LINGER_MS (\d+)/, 'the bridge window is bounded' );
my ($linger) = $jw_sleep =~ /#define BLE_LINGER_MS (\d+)/;
ok( $linger && $linger > 0 && $linger <= 60000,
	"and short enough not to be a sleep substitute ($linger ms)" );
like( $jw_sleep, qr/doze_until_crown\(millis\(\) \+ BLE_LINGER_MS\);/,
	'the bridge is held for that window' );
like( $jw_sleep, qr/if \(want_sleep && !pmuIrq\) \{/,
	'and the real sleep runs once the window is over' );
like( $jw_sleep, qr/bridge held for a tap burst/,
	'the log names the window, so a drain report can be read off the console' );

# A watch on USB cannot be tapped, and no house route carries this setting, so
# the console is how a notification or battery test turns Sleep on.
like( $jw_sleep, qr/line\.startsWith\("sleep "\)/, 'the console can set Sleep');
like( $jw_sleep, qr/lightSleep = \(v == "on"\);\s*configSave\(\);/, 
	'and saves the choice the Set room would have saved');
like( $jw_sleep, qr/line == "wifi on" \|\| line == "wifi off"/,
	'the console can bring WiFi up for the notification fetch');

# A doze entered because the cable was in used to run until the crown: pull the
# cable and the watch kept its 80 MHz core and radio on the rest of the day.
like( $jw_doze, qr/static void doze_until_crown\(uint32_t until_ms = 0, bool recheck_usb = false\)/,
	'the doze knows the cable may be pulled');
like( $jw_doze, qr/if \(recheck_usb && !watch\.isUsbIn\(\)\) \{\s*Serial\.println\("\[doze\] cable pulled: back to the sleep path"\);\s*break;/,
	'and ends itself when it is');
like( $jw_sleep, qr/doze_until_crown\(0, lightSleep\);[\s\S]{0,900}?if \(lightSleep && !watch\.isUsbIn\(\) && !sleep_handler_reentering\) \{/,
	'the USB doze hands over to the sleep path instead of the wake tail');

# The join lives in jawn_loop(), and lowPowerEnergyHandler() (or the doze it
# runs) owns core 1 until it returns. A bridge push that arrives with the screen
# dark must therefore end the sleep handler, not wait for a crown tap that may
# not come until morning; the return leaves the panel dark.
like( $jw_doze, qr/if \(wifi_join_requested\) \{\s*\/\/[\s\S]{0,300}?Serial\.println\("\[doze\] wifi push: waking to join"\);\s*break;/,
	'the doze yields when the bridge pushed WiFi credentials' );
like( $jw_sleep, qr/if \(wifi_join_requested && !pmuIrq\) \{\s*Serial\.println\("\[sleep\] wifi push: staying up to join"\);\s*\/\/[^\n]*\n\s*setCpuFrequencyMhz\(240\);\s*return;/,
	'a pending push is never slept through, and a crown in the same pass still gets its screen' );
like( $jw_sleep, qr/doze_until_crown\(0, lightSleep\);\s*if \(wifi_join_requested && !pmuIrq\) \{\s*\/\/[\s\S]{0,300}?Serial\.println\("\[sleep\] wifi push: staying up to join"\);\s*\/\/[\s\S]{0,200}?dozing = true;\s*setCpuFrequencyMhz\(240\);[\s\S]{0,120}?return;/,
	'and the doze ending on a push returns before the screen-on tail' );
like( $jw_sleep, qr/if \(wifi_join_requested && !pmuIrq\) \{\s*Serial\.println\("\[sleep\] wifi push in the bridge window: staying up to join"\);\s*\/\/[\s\S]{0,200}?dozing = true;\s*setCpuFrequencyMhz\(240\);/,
	'a push inside the bridge linger also hands back to the join, still asleep' );
# The early returns skip watch.wakeupDisplay(), so dozing (and with it the voice
# gate and the radio restore) must stay in its asleep state - a push at night
# must not start a microphone listener on a dark watch.
unlike( $jw_sleep, qr/wifi_join_requested && !pmuIrq\) \{[\s\S]{0,260}?dozing = false;/,
	'the early join returns never claim the screen is awake' );

# --- a pushed network joins from cold, saves, and keeps its password ---------
# From the watch's own console: after boot the first push failed (status 254)
# because begin() ran with no mode set, and a push naming another network was
# ignored while the old link was still up. Both are what the deck works around,
# and the push used to print the whole message, password included.
like( $jw_net, qr/bool rejoin = \(WiFi\.status\(\) != WL_CONNECTED\) \|\| \(WiFi\.SSID\(\) != ssid\);/,
	'a push that names another network is not skipped as already connected' );
like( $jw_net, qr/WiFi\.mode\(wifi_ap_enabled \? WIFI_AP_STA : WIFI_STA\);\s*if \(WiFi\.status\(\) == WL_CONNECTED\) \{\s*WiFi\.disconnect\(\);\s*delay\(200\);\s*\}\s*WiFi\.begin\(ssid, password\);/,
	'a cold or changed join sets the mode and drops the live link before begin' );
like( $jw_net, qr/if \(wifi_save_pending\) \{\s*wifi_save_pending = false;\s*configSave\(\);/,
	'a bridge-pushed join is saved once it connects' );
like( $jw_loop2, qr/bool wifi_push = \(btmsg\.indexOf/,
	'the wifi push is recognised before the raw message is printed' );
like( $jw_loop2, qr/if \(!wifi_push\) \{\s*Serial\.print\("Safely processing incoming Tasker JSON on loop2 stack: "\);/,
	'and the raw prefix print is skipped for it' );
like( $jw_loop2, qr/Serial\.println\("\[ble\] wifi push for " \+ pushed_ssid\);/,
	'it logs the ssid alone' );
unlike( $jw_loop2, qr/Serial\.println\("\[ble\] wifi credentials received"\);/,
	'not the old generic line' );
unlike( $jw_loop2, qr/Serial\.(?:print|printf|println)\([^\n;]*\b(?:ap_)?password\b/,
	'and no console line in the BLE handler carries a password' );
unlike( $jw_net, qr/Serial\.(?:print|printf|println)\([^\n;]*\bpassword\b/,
	'nor does the join path' );

# A wrist raise or crown inside the window still gets the screen, instead of
# falling through into the sleep path.
like( $jw_sleep, qr/if \(pmuIrq\) \{\s*Serial\.println\("\[sleep\] wake inside the bridge window"\);/,
	'a wake inside the window ends it in a screen wake' );

# --- the doze can be given a deadline ----------------------------------------
like( $jw_doze, qr/static void doze_until_crown\(uint32_t until_ms = 0, bool recheck_usb = false\)/,
	'the doze takes an optional deadline' );
like( $jw_doze, qr/if \(until_ms && \(int32_t\)\(millis\(\) - until_ms\) >= 0\) \{\s*break;/,
	'and returns once it is reached' );
like( $jw_doze, qr/if \(until_ms && \(int32_t\)\(until_ms - beat_end\) < 0\) \{\s*beat_end = until_ms;/,
	'and the sampling beat cannot overshoot it by half a second' );

# --- the LoRa radio does not listen unless asked -----------------------------
like( $jw_net, qr/static void radio_follow_receive\(bool force\) \{/,
	'the radio follows the Receive setting' );
like( $jw_net, qr/if \(armed\) \{\s*radio\.startReceive\(\);/, 'on: it listens');
like( $jw_net, qr/else \{\s*radio\.sleep\(\);/, 'off: it sleeps instead of drawing RX current');
like( $jw_setup, qr/configRestore\(\);\s*[\s\S]{0,400}?radio_follow_receive\(\);/,
	'boot applies the saved setting after the restore' );
like( $jw_doze, qr/radio_follow_receive\(\);\s*\n\}/,
	'the Receive toggle applies it at once' );
like( $jw_config, qr/radio_follow_receive\(\);\s*\n\}/,
	'and so does a Restore, which overlays the saved preference' );
like( $jw_doze, qr/radio\.startTransmit\(public_announcement\);\s*radio_follow_receive\(true\);/,
	'a transmit re-arms the listen state it left' );
like( $jw_loop, qr/radio\.startTransmit\(returns\);\s*Serial\.println\("transmitted"\);\s*\/\/ back to listening only when receive is on \(transmit leaves standby\)\s*radio_follow_receive\(true\);/,
	'and so does a chat broadcast' );

# --- the saved picture says "off" --------------------------------------------
unlike( $jw_save, qr/lightSleep == false;/,
	'the off branch is an assignment, not a comparison that did nothing' );
like( $jw_save, qr/conf\["lightsleep"\] = "off";/, 'and it writes the off state' );

# --- the awake screen stops polling what does not change ---------------------
like( $jw_loop, qr/static uint32_t face_gauge_at = 0;/,
	'the fuel gauge is sampled on a beat, not once per loop' );
like( $jw_loop, qr/face_volts = \(int\)watch\.getBatteryPercent\(\);/,
	'and the I2C read lives inside that beat' );
like( $jw_loop, qr/label_set_if_changed\(face_battery, volts_text\);/,
	'the percentage label is only written when the number changes' );
like( $jw_loop, qr/if \(band != face_band\) \{/,
	'the status colour is only restyled on a band change' );
like( $jw_loop, qr/if \(millis\(\) - counter_read_at < 1000\) \{\s*return;/, 
	'the step counter is read at most once a second' );

# --- label writes compare first ----------------------------------------------
like( $jw_globals, qr/static void label_set_if_changed\(lv_obj_t \*obj, const char \*text\)/,
	'the label helper is declared for every part' );
like( $jw_globals, qr/if \(old && strcmp\(old, text\) == 0\) \{\s*return;/, 
	'and it compares before lv_label_set_text reallocates and redraws' );

my ($ipw) = $jw_net =~ /(void ip_writer\(\) \{.*?\n\}\n)/s;
ok( $ipw, 'the IP/status writer was found' );
unlike( $ipw, qr/lv_label_set_text\(/,
	'it no longer rewrites every label on every pass' );
like( $ipw, qr/label_set_if_changed\(face_ip, bufIP\);/,
	'the address labels go through the compare-first helper' );
like( $ipw, qr/if \(state != bt_state\) \{/,
	'and the BT colour is only restyled when the radio state changes' );

# --- the diagnostic boot record survives an unplugged light sleep -------------
# A real light sleep runs with the cable out, so the boot banner and the panic
# dump have no host. Diag persists the reset reason and the last breadcrumb to
# FFat, and the Set room's toggle arms it (the console can set it too).
like( $jw_globals, qr/static bool diagMode = false;/, 'a diagnostic mode exists' );
like( $jw_doze, qr/configure_button\("Delete", configDeleteButton, 10, 138, 105, 42/,
	'Delete is half width, leaving room for a neighbour' );
like( $jw_doze, qr/configure_button\("Diag", diag_toggle, 125, 138, 105, 42/,
	'with the Diag toggle beside it' );
like( $jw_save, qr/conf\["diag"\] = diagMode \? "on" : "off";/, 'the toggle is saved' );
like( $jw_config, qr/String dg = \(const char \*\)conf\["diag"\];/, 'and restored' );
like( $jw_setup, qr/diagRecordBoot\(\);/, 'a boot records its reason' );
like( $jw_config, qr/esp_reset_reason\(\)/, 'the record carries the reset reason' );
like( $jw_config, qr/esp_sleep_get_wakeup_cause\(\)/, 'and the sleep/wake cause' );
like( $jw_config, qr/crumb_tag\[crumb_head\]/, 'and the last breadcrumb' );
like( $jw_sleep, qr/line == "diag" \|\| line == "diag dump"/, 'the console can dump it' );
like( $jw_sleep, qr/diagMode = \(line == "diag on"\);/, 'and set it' );

# --- the finer crumbs locate a watchdog reset in the sleep path --------------
# reason 7 with "ls enter" said the reset was somewhere in the entry block; each
# step now marks itself, and the BLE teardown and the room fetch mark theirs,
# so the next reset names the call it died in.
like( $jw_sleep, qr/crumb\("ls pmu"\);/, 'the sleep entry marks the PMU read' );
like( $jw_sleep, qr/crumb\("ls ext1"\);/, 'and the EXT1 arm' );
like( $jw_sleep, qr/crumb\("ls sensor"\);/, 'and the sensor drain' );
like( $jw_sleep, qr/crumb\("ls ble"\);/, 'and the BLE teardown it is about to run' );
like( $jw_sleep, qr/crumb\("ls irq"\);/, 'and the PMU IRQ mask' );
like( $jw_sleep, qr/crumb\("ls nap"\);/, 'and the first nap' );
like( $jw_sleep, qr/crumb\("ls woke"\);/, 'and its return' );
like( $jw_ble, qr/crumb\("ble wait"\);/, 'the teardown marks the bring-up wait' );
like( $jw_ble, qr/crumb\("ble disc"\);/, 'and the disconnect handshake' );
like( $jw_ble, qr/crumb\("ble deinit"\);/, 'and the deinit' );
like( $jw_ble, qr/crumb\("ble done"\);/, 'and its completion' );
like( $jw_house, qr/crumb\("p0 ask"\);/, 'the room fetch marks its start' );
like( $jw_house, qr/crumb\("p1 got"\);/, 'its answer' );
like( $jw_house, qr/crumb\("p2 done"\);/, 'and its end' );

# --- the nap loop reports its phase and pass count ---------------------------
# A watchdog in the nap loop leaves the one-shot "ls woke" as the last crumb;
# the RTC phase and count say which step it died on and how many naps it ran.
like( $jw_sleep, qr/nap_phase = 13;/, 'the nap loop marks the entry into the sleep' );
like( $jw_sleep, qr/Armed last/, 'and the timer is armed last, so it cannot expire during the pin setup' );
like( $jw_sleep, qr/nap_count\+\+;/, 'and counts each nap' );
like( $jw_sleep, qr/nap_phase = 4;/, 'the sensor sample phase is marked' );
like( $jw_sleep, qr/nap_phase = 6;/, 'and the wrist poll' );
like( $jw_config, qr/nap=%u phase=%s/, 'the boot record carries the phase and count' );

# --- a real light sleep stops WiFi, the web server and mDNS first -------------
# Leaving them up hung esp_light_sleep_start() and the RTC watchdog reset the
# watch (reason 7, last "ls woke"); the deck already slept this way.
like( $jw_sleep, qr/wifi_down_for_nap\(\);/, 'the nap stops the network before sleeping' );
like( $jw_sleep, qr/wifi_wake_from_nap\(\);/, 'and brings it back on the way out' );
like( $jw_net, qr/WiFi\.mode\(WIFI_OFF\);/, 'WiFi is switched off, not just disconnected' );
like( $jw_net, qr/MDNS\.end\(\);/, 'and mDNS is ended' );
like( $jw_net, qr/wifi_restore_pending && WiFi\.status\(\) == WL_CONNECTED/, 'the restore finishes non-blocking' );
like( $jw_loop, qr/wifi_restore_tick\(\);/, 'the awake loop finishes the restore' );

# --- a capture owns the screen against the wrist glance -----------------------
# The glance's arm-drop sleeps the watch, which would cut a held Rec/Com memo
# short; isRecording joins the voice flags so the capture keeps the screen.
like( $jw_wrist, qr/bool capture_holds = isRecording \|\| voiceRecording \|\| voiceShipping \|\| voiceAwaitingReply/,
	'a held manual capture owns the screen against the wrist glance' );
like( $jw_wrist, qr/\[voice\] wrist hold: capture owns the screen/,
	'and the hold is named on the console for a capture that went wrong' );

done_testing();
