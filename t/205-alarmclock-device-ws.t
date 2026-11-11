# tests-for: jp/alarmclock/alarmclock_05_device_ws.ino jp/alarmclock/alarmclock.ino jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino
# covers:    The Pico's /device/ws client: the RFC 6455 upgrade (SHA1 + base64
#            with the published GUID), masked client frames, the port derived
#            from the homebase's arm port, the hello/ack/pong frames the
#            manager's Devicews.pm expects, and a command body that mirrors the
#            board's own HTTP /relay handler (same id, stale grace, mark and
#            remember, immediate vs scheduled). Also that core 1 polls it, so a
#            command from the web UI reaches the relay without a physical press.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $read = sub { scalar read_file("$root/$_[0]") };

my $ws      = $read->('jp/alarmclock/alarmclock_05_device_ws.ino');
my $index   = $read->('jp/alarmclock/alarmclock.ino');
my $globals = $read->('jp/alarmclock/alarmclock_01_globals_clock_ble.ino');
my $boot    = $read->('jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino');
my $loop    = $read->('jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino');

ok(length $ws > 2000, 'the device bus client exists');

# --- it is part of the sketch and called on core 1 ------------------------
like($index, qr/alarmclock_05_device_ws\.ino/,
	'the index names the new part, so PlatformIO concatenates it');
like($globals, qr/^\s*void\s+device_ws_poll\(\)\s*;/m,
	'the sketch forward-declares the poll for loop1');
like($loop, qr/void\s+loop1\(\)\s*\{.*?handle_jobs\(\);\s*[^}]*device_ws_poll\(\);/s,
	'loop1 polls the device bus right after handle_jobs');

# --- the upgrade handshake RFC 6455 requires ------------------------------
like($ws, qr/sha1\(\s*key\s*\+\s*"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"\s*,\s*digest\s*\)/,
	'the accept key is SHA1(key + the RFC GUID)');
like($ws, qr/base64::encode\(\s*digest\s*,\s*20\s*\)/,
	'the accept key is base64 of the digest');
like($ws, qr/Upgrade:\s*websocket/i, 'the request asks for the websocket upgrade');
like($ws, qr/Connection:\s*Upgrade/i, 'the request sets Connection: Upgrade');
like($ws, qr/Sec-WebSocket-Key:\s*"\s*\+\s*key/, 'the request carries the key');
like($ws, qr/Sec-WebSocket-Version:\s*13/, 'the request declares protocol version 13');
like($ws, qr/indexOf\(" 101 "\)/, 'a non-101 answer is refused');

# --- the listener port comes from the arm port ----------------------------
# President.pl: watch_port = working + 2, ws_port = working + 1.
like($ws, qr/dev_ws_port\s*=\s*\(uint16_t\)\(arm\s*-\s*1\)/,
	'the websocket port is the homebase arm port minus one');
like($ws, qr/hb\.lastIndexOf\(':'\)/, 'the host:port homebase is split');

# --- the route's auth query and the house-CA peer leaf --------------------
like($ws, qr{"/device/ws\?authorization="}, 'the query targets /device/ws with the token');
like($ws, qr/&edt=microcontroller&chip_id=/, 'the query names the edt and the chip');
like($ws, qr/authorization\.length\(\)|dev_ws_escape\(\s*authorization\s*\)/,
	'the Now Me token is carried (and escaped)');
like($ws, qr/setTrustAnchors\(\s*&house_ca_list\s*\)/, 'the house-CA peer leaf is verified, not accepted blindly');

# --- client frames must be masked ----------------------------------------
like($ws, qr/header\[n\+\+\]\s*=\s*0x80\s*\|\s*\(uint8_t\)len/, 'short frames set FIN and the mask bit');
like($ws, qr/mask\[i\]\s*=\s*\(uint8_t\)random\(256\)/, 'every frame gets a random mask');
like($ws, qr/payload\[off \+ i\]\s*\^\s*mask\[\(off \+ i\) & 3\]/, 'the payload is XOR-masked');
like($ws, qr/opcode == 0x9\)\s*\{\s*dev_ws_send_frame\(0xA, payload\)/, 'a server ping is answered with a pong');

# --- the frames Devicews.pm expects --------------------------------------
like($ws, qr/\{\\"t\\":\\"hello\\",\\"chip\\":\\"/, 'the connect announces itself with hello');
like($ws, qr/\{\\"t\\":\\"ack\\",\\"id\\":\\"/, 'the command is acknowledged with the ack frame');
like($ws, qr/\\"state\\":\\"" \+ state \+ "\\"\}/, 'the ack reports the pin state');
like($ws, qr/\{\\"t\\":\\"pong\\"\}/, 'the board answers a ping with pong');
like($ws, qr/if\s*\(\s*t == "cmd"\)/, 'it handles the command frame');
like($ws, qr/if\s*\(\s*t == "snap"\)/, 'it handles the connect snapshot');
like($ws, qr/if\s*\(\s*t == "toggles"\)/, 'it handles a toggle push');
like($ws, qr/if\s*\(\s*t == "ping"\)/, 'it handles a server ping frame');

# --- the command body mirrors the board's HTTP /relay ---------------------
like($ws, qr/if\s*\(\s*when == "now"\s*\)/, 'only an immediate command moves a pin');
like($ws, qr/push_job\(component, pin, state,/, 'a later command becomes a scheduled job');
like($ws, qr/String\s+comp\s*=\s*\(component != ""\) \? component : String\("relay"\)/,
	'the component falls back to relay');
like($ws, qr/command_id\(uuid, comp, "", state, ms\)/,
	'the id is built the way the HTTP handlers build it');
like($ws, qr/if\s*\(!command_redundant\(id, pin, comp, state, ms\)\)/, 'it uses the same redundant/stale guard');
like($ws, qr/state\s*=\s*relay_toggle\(pin, state, true, 4\)/, 'a relay command drives the pin with the HTTP source tag');
like($ws, qr/state\s*=\s*led_toggle\(pin, state\)/, 'an led command drives the pin');
like($ws, qr/state\s*=\s*servo_toggle\(pin, state\)/, 'a servo command drives the pin');
like($ws,
	qr/command_mark_pin\(pin, ms\);\s*command_remember\(id, comp, "", ms\);/,
	'mark and remember run even for a redundant command');
# The snapshot teaches app state; it must not drive a switch-owned pin.
like($ws, qr/ble_apply_app_state\(app, jint\(c\["toggle"\]\) \? "on" : "off"\)/,
	'the snapshot applies app state through the switch-aware helper');
unlike($ws, qr/dev_ws_handle_text[\s\S]*?"snap"[\s\S]*?relay_toggle\(/,
	'the snapshot never calls relay_toggle directly');

# --- it never wedges the core --------------------------------------------
like($ws, qr/if\s*\(\s*wifiState != "connected" \|\| homebaseIP == "" \|\| authorization == ""\s*\)/,
	'the poll does nothing without a link and a pair');
like($ws, qr/dev_ws_backoff\s*<\s*30000/, 'a failed dial backs off');
like($ws, qr/dev_ws_tls\.setTimeout\(5000\)/, 'the handshake timeout is 5 s, not 5 ms');
like($ws, qr/dev_ws_tls\.setTimeout\(200\)/, 'a frame read is bounded at 200 ms');
unlike($ws, qr/setTimeout\([0-9]{1,2}\)/, 'no timeout is silently 5 ms (the Stream API is in milliseconds)');
like($ws, qr/WiFiClientSecure::setTLSConnectTimeout\(8000\)/,
	'the static TLS handshake timeout is bounded too');
# A Serial write on core 1 can hold the USB mutex when no host drains the CDC;
# that is what wedged the board. Diagnostics are counters read on JAWNCFG?.
unlike($ws, qr/Serial\./,
	'the poll path never writes to Serial (a CDC write can wedge the board)');
like($ws, qr/dev_ws_up_count\+\+/, 'a successful attach is counted');
like($ws, qr/dev_ws_fail_count\+\+/, 'a failed dial is counted');
like($ws, qr/dev_ws_cmd_count\+\+/, 'an applied command is counted');
like($ws, qr/dev_ws_last = 1;/, 'a connect failure is coded (last=1)');
like($ws, qr/dev_ws_last = 2;/, 'a refused upgrade is coded (last=2)');
like($ws, qr/" last=" \+ String\(dev_ws_last\)/, 'the report carries the last failure stage');
like($ws, qr/String dev_ws_report\(\)/, 'the counters are exposed by a report');
like($globals, qr/^String dev_ws_report\(\);$/m, 'the report is forward-declared for the USB diagnostic');
like($boot, qr/JAWNCFG WS " \+ dev_ws_report\(\)/, 'JAWNCFG? prints the device bus counters');
like($ws, qr/dev_ws_last_ping\)\s*>\s*30000/, 'it pings on an idle socket');

done_testing();
