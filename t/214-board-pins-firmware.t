# tests-for: jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino
# covers:    The Pico can describe its own pin map and safely probe the pins
#            nothing is configured on, so a manager can adopt it and a person can
#            attach a peripheral. The probe is asked for over USB (JAWNPINS?) or
#            HTTP (/pins, same authorization as the neighbouring routes), never
#            at boot or in the loop, never touches a configured pin, and leaves
#            every pin it reads undriven.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $read = sub { scalar read_file("$root/$_[0]") };

my $g1 = $read->('jp/alarmclock/alarmclock_01_globals_clock_ble.ino');
my $g2 = $read->('jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino');

# --- the report builder ---------------------------------------------------
like($g1, qr/String board_pins_json\(\) \{/, 'the board has a pin report builder');
my ($json) = $g1 =~ /(String board_pins_json\(\) \{.*?\n\})/s;
ok($json, 'board_pins_json is still one function');

like($json, qr/\\"t\\":\\"pins\\"/, 'the report labels itself a pin report');
like($json, qr/\\"chip\\":/, 'the report names the chip');
like($json, qr/\\"version\\":/, 'the report names the build');
like($json, qr/\\"purpose\\":/, 'the report names the purpose');
like($json, qr/\\"components\\":\[/, 'the report lists the components');
like($json, qr/\\"free\\":\[/, 'the report lists the free pins');
like($json, qr/\\"probe\\":\[/, 'the report carries the probe results');

# Components come from every mapped class, outputs first, and each entry
# carries the pin, component, app and inverted fields.
like($g1, qr/const char \*maps\[\] = \{ "relay", "led", "servo", "button", "switch", "pot" \};/,
	'components are read from the configured maps');
like($json, qr/\\"pin\\":/, 'a component reports its pin');
like($json, qr/\\"component\\":/, 'a component reports its class');
like($json, qr/\\"app\\":/, 'a component reports its app, empty when absent');
like($json, qr/\\"inverted\\":/, 'a component reports inverted, empty when absent');
like($g1, qr/String app = "", inverted = "";/, 'a non-object entry leaves app and inverted empty');

# Sorted by pin, and free is capped.
like($json, qr/comp_pins\[j\] > p/, 'components are sorted by pin');
like($json, qr/free_n < 30/, 'the free list is capped at 30');

# --- the probe ------------------------------------------------------------
like($g1, qr/static int board_pins_probe\(int pins\[\], String kinds\[\], int analogs\[\], int max\)/,
	'the probe exists as its own function');
my ($probe) = $g1 =~ /(static int board_pins_probe\(.*?\n\})/s;
ok($probe, 'board_pins_probe is still one function');

# It must never touch a pin a component claims: driving a relay, servo or LED
# is a real-world action.
like($probe, qr/board_pin_is_configured\(pin\)/, 'the probe skips a configured pin');
like($g1, qr/static bool board_pin_is_configured\(int pin\) \{/, 'the configured check exists');
like($g1, qr/JSONVar keys = config\[maps\[m\]\]\.keys\(\);/, 'the check reads the configured maps');
like($probe, qr/pinMode\(pin, INPUT_PULLUP\);/, 'the probe pulls the pin up');
like($probe, qr/pinMode\(pin, INPUT_PULLDOWN\);/, 'then pulls it down');
like($probe, qr/pinMode\(pin, INPUT\);/, 'and leaves the pin undriven');
unlike($probe, qr/digitalWrite/, 'the probe never drives a pin');

# 23/24/25 belong to the CYW43 on a Pico 2 W.
like($g1, qr/pin == 23 \|\| pin == 24 \|\| pin == 25/, 'the radio-owned pins are excluded');
like($probe, qr/board_pin_reserved\(pin\)/, 'the probe honours the exclusion');

# A table of kinds, so a new sensor class is one row.
like($g1, qr/struct pin_probe_kind_t \{/, 'the probe kinds are a table');
like($g1, qr/\{ "floating", probe_is_floating \}/, 'floating is a row');
like($g1, qr/\{ "grounded", probe_is_grounded \}/, 'grounded is a row');
like($g1, qr/\{ "high",\s+probe_is_high \}/, 'high is a row');
like($g1, qr/String kind = "unknown";/, 'an unclassified pin says unknown');

# Never at boot, never in the loop: only the command paths ask.
my $g3 = $read->('jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino');
unlike($g3, qr/board_pins_probe|board_pins_json/, 'the loop never probes on its own');

# --- the two ways to ask --------------------------------------------------
like($g2, qr/line == "JAWNPINS\?"/, 'the USB console answers JAWNPINS?');
like($g2, qr/Serial\.println\("JAWNPINS " \+ board_pins_json\(\)\);/, 'and prints exactly one JAWNPINS line');

my ($route) = $g2 =~ /(server\.on\("\/pins", \[\]\(\) \{.*?\n  \}\);)/s;
ok($route, 'the /pins route is registered');
like($route, qr/server\.arg\("authorization"\)/, 'the route reads the authorization parameter');
like($route, qr/rauth != authorization/, 'and refuses a wrong token like its neighbours');
like($route, qr/server\.send\(200, "application\/json", board_pins_json\(\)\)/,
	'the route answers JSON with the report');
like($g2, qr/server\.on\("\/relay", \[\]\(\) \{\n    homebaseChecked\(\);\n    String rauth = server\.arg\("authorization"\);\n    if \(authorization\.length\(\) > 0 && rauth != authorization\) \{/,
	'the neighbouring route uses the same check');

done_testing();
