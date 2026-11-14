# tests-for: jw/jw_01_globals.ino jw/jw_03_setup.ino jw/jw_04_loop.ino jw/jw_06_net_face.ino jw/jw_11_configure.ino jw/jw_13_serial_lowpower.ino jw/jw_14_settings.ino jw/jw_15_config_files.ino
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
my $jw_net     = read_file("$root/jw/jw_06_net_face.ino");
my $jw_doze    = read_file("$root/jw/jw_11_configure.ino");
my $jw_sleep   = read_file("$root/jw/jw_13_serial_lowpower.ino");
my $jw_save    = read_file("$root/jw/jw_14_settings.ino");
my $jw_config  = read_file("$root/jw/jw_15_config_files.ino");

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

# A wrist raise or crown inside the window still gets the screen, instead of
# falling through into the sleep path.
like( $jw_sleep, qr/if \(pmuIrq\) \{\s*Serial\.println\("\[sleep\] wake inside the bridge window"\);/,
	'a wake inside the window ends it in a screen wake' );

# --- the doze can be given a deadline ----------------------------------------
like( $jw_doze, qr/static void doze_until_crown\(uint32_t until_ms = 0\)/,
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

done_testing();
