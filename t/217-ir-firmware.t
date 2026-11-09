# tests-for: jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino jp/alarmclock/alarmclock_05_device_ws.ino
# covers:    Core 0 must stay live after a BLE central connects: the send path
#            enqueues and wakes the stack's own worker instead of blocking on
#            the CYW43 async lock, and the loop never waits for a central that
#            stopped draining. The USB console is serviced before the network
#            and BLE in every pass. The same firmware learns any IR remote as
#            raw microsecond timings (bounded at 512 transitions / 5 s) and
#            replays them with a 38 kHz carrier, with no protocol library.

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
my $g3 = $read->('jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino');
my $g4 = $read->('jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino');
my $g5 = $read->('jp/alarmclock/alarmclock_05_device_ws.ino');

# --- (a) the BLE send path is non-blocking and bounded ----------------------
like($g1, qr/static void ble_send_json\(const String &json\) \{/,
	'the send path is still one function');
my ($send) = $g1 =~ /(static void ble_send_json\(const String &json\) \{.*?\n\})/s;
ok($send, 'ble_send_json is still one function');

# The block that wedged core 0: ble_send_json used to take BluetoothLock, which
# is async_context_acquire_lock_blocking(). It must never come back.
unlike($send, qr/^\s*BluetoothLock\s+\w+\s*;/m, 'the producer never takes the blocking async lock');
unlike($send, qr/^\s*async_context_acquire_lock_blocking\(/m, 'and never calls the blocking acquire directly');
like($send, qr/async_context_set_work_pending\(cyw43_arch_async_context\(\), &ble_tx_worker\)/,
	'the producer only wakes the async-context worker');
like($g1, qr/ble_send_pending/, 'one outstanding send request is tracked');
like($g1, qr/ble_send_at/, 'the request is aged, not waited on');

# The stack callback asks before it drains the queue, and parks a frame it
# cannot send instead of spinning or losing it.
my ($can) = $g1 =~ /(static void ble_can_send\(void \*ctx\) \{.*?\n\})/s;
ok($can, 'ble_can_send is still one function');
like($can, qr/att_server_can_send_packet_now\(ble_con_handle\)/,
	'the callback checks the controller can send before draining');
like($can, qr/ble_tx_retry_at = millis\(\) \+ BLE_TX_RETRY_MS;/,
	'a full buffer parks the frame with a deadline');
like($can, qr/ERROR_CODE_SUCCESS/, 'a failed notification is noticed, not dropped blindly');
unlike($can, qr/BluetoothLock/, 'the callback never re-enters the async lock');

like($g1, qr/#define BLE_TX_RETRY_MS 25/, 'the retry window is bounded');
like($g1, qr/#define BLE_TX_STALE_MS 1500/, 'a lost can-send window has a deadline');
like($g1, qr/static void ble_tx_worker_fn\(async_context_t \*context, async_when_pending_worker_t \*worker\)/,
	'the worker runs on the async context');

# The stale-request recovery and the retry live in the loop, where nothing
# blocks; the loop must not call the request itself.
my ($loop_ble) = $g2 =~ /(static void ble_loop\(\) \{.*?\n\})/s;
ok($loop_ble, 'ble_loop is still one function');
like($loop_ble, qr/ble_send_pending && \(uint32_t\)\(millis\(\) - ble_send_at\) > BLE_TX_STALE_MS/,
	'the loop ages out a can-send request that never came back');
like($loop_ble, qr/async_context_set_work_pending\(cyw43_arch_async_context\(\), &ble_tx_worker\)/,
	'the loop retries through the worker, never by blocking');
unlike($loop_ble, qr/ble_request_send\(\)/, 'the loop never asks BTstack directly');
like($g1, qr/async_context_acquire_lock_blocking\(\)/, 'the comment names the block that was removed');

# --- (b) the console is still serviced from loop() --------------------------
my ($loop) = $g3 =~ /(void jawn_loop\(\) \{.*?\n\})/s;
ok($loop, 'jawn_loop is still one function');
like($loop, qr/usb_config_loop\(\);/, 'loop() still calls the USB console');
like($loop, qr/input_scanner\(\);/, 'and still scans the switches');
my $usb_at = index($loop, 'usb_config_loop();');
my $ble_at = index($loop, 'ble_loop();');
ok($usb_at >= 0 && $ble_at >= 0 && $usb_at < $ble_at,
	'the console is serviced before the BLE pass, not after it');
like($loop, qr/core0_passes\+\+/, 'loop() counts its own passes for the console');
like($g2, qr/JAWNCFG CORE passes=/, 'JAWNCFG? reports the pass counter');
like($g2, qr/core0_stalls/, 'and records a long gap');

# --- (c) irrx capture is bounded -------------------------------------------
like($g3, qr/#define IR_RX_MAX 512/, 'the capture buffer is capped at 512 transitions');
like($g3, qr/#define IR_RX_MAX_MS 5000/, 'the capture window is capped at 5 s');
like($g3, qr/static void ir_rx_isr\(\)/, 'edges are recorded by an ISR');
my ($isr) = $g3 =~ /(static void ir_rx_isr\(\) \{.*?\n\})/s;
ok($isr, 'ir_rx_isr is still one function');
like($isr, qr/micros\(\)/, 'the edge durations are microseconds');
like($isr, qr/if \(ir_rx_n >= IR_RX_MAX\) \{ ir_rx_active = false; \}/,
	'the buffer fill stops the capture');
my ($begin) = $g3 =~ /(static void irrx_begin\(int pin, uint32_t ms\) \{.*?\n\})/s;
ok($begin, 'irrx_begin is still one function');
like($begin, qr/if \(ms > IR_RX_MAX_MS\) \{ ms = IR_RX_MAX_MS; \}/,
	'a longer request is clamped to 5 s');
like($begin, qr/attachInterrupt\(digitalPinToInterrupt\(pin\), ir_rx_isr, CHANGE\)/,
	'the capture is edge-driven, not polled in a tight loop');
like($begin, qr/INPUT_PULLUP/, 'the receiver pin is pulled up');
unlike($begin, qr/while \(/, 'starting a capture never spins');

# The deferred start keeps the ISR on core 0 even though the command is
# handled on core 1.
like($g3, qr/void irrx_request_learn\(int pin, uint32_t ms\)/,
	'the command path only records a learn request');
like($g3, qr/ir_learn_pin/, 'and irrx_poll consumes it on core 0');
my ($poll) = $g3 =~ /(static void irrx_poll\(\) \{.*?\n\})/s;
ok($poll, 'irrx_poll is still one function');
like($poll, qr/if \(n == 0\) \{ return; \}/, 'no edges means no report');

# --- (d) the capture posts to /watch/ir ------------------------------------
like($poll, qr/\\"chip_id\\"/, 'the report carries the chip id');
like($poll, qr/\\"pin\\"/, 'the report carries the pin');
like($poll, qr/\\"seq\\"/, 'the report carries the sequence');
like($poll, qr/\\"timestamp\\"/, 'the report carries the event timestamp');
like($poll, qr{coreJobs\[jobTime\]\["path"\] = "/watch/ir";}, 'the path is /watch/ir');
like($poll, qr/coreJobs\[jobTime\]\["type"\] = "ir_post";/, 'the report is a queued POST');
like($poll, qr/seq \+= ',';/, 'the sequence is comma-separated durations');
like($g4, qr/String\(coreJobs\[coreKeys\[i\]\]\["type"\]\) == "ir_post"/,
	'the core-1 job runner sends it');
like($g4, qr/https_post\(path, body, answer\)/, 'over the same authorized POST as the other events');

# --- (e) irtx replays `code` with a 38 kHz carrier -------------------------
like($g1, qr/String ir_toggle\(int pin, const String &code\);/, 'ir_toggle is declared for the command paths');
my ($tx) = $g3 =~ /(String ir_toggle\(int pin, const String &code\) \{.*?\n\})/s;
ok($tx, 'ir_toggle is still one function');
like($tx, qr/for \(int i = 0; i <= len; i\+\+\)/, 'the code is walked token by token');
like($tx, qr/code\[i\] != ','/, 'the tokens are comma-separated');
like($tx, qr/strtoul\(tok\.c_str\(\), nullptr, 10\)/, 'each leg is a microsecond duration');
like($tx, qr/if \(leg % 2 == 0\) \{ ir_mark\(pin, us\); \}/, 'even legs are carrier marks');
like($tx, qr/IR_TX_MAX_FRAME_US/, 'the whole frame is bounded');
my ($mark) = $g3 =~ /(static void ir_mark\(int pin, uint32_t us\) \{.*?\n\})/s;
ok($mark, 'ir_mark is its own function');
like($mark, qr/delayMicroseconds\(13\)/, 'the carrier is ~38 kHz (13 us on, 13 us off)');
like($mark, qr/digitalWrite\(pin, HIGH\)/, 'the mark drives the pin');

# Both command paths accept it: the /device/ws cmd handler and the HTTP output
# route.
my ($ws_cmd) = $g5 =~ /(static void dev_ws_apply_cmd\(JSONVar d\) \{.*?\n\})/s;
ok($ws_cmd, 'dev_ws_apply_cmd is still one function');
like($ws_cmd, qr/String code = jstr\(d\["code"\]\);/, 'the socket command reads `code`');
like($ws_cmd, qr/comp == "ir" \|\| comp == "irtx"/, 'component ir/irtx selects the blaster');
like($ws_cmd, qr/ir_toggle\(pin, code\)/, 'the socket command replays the code');
my ($relay) = $g2 =~ /(server\.on\("\/relay", \[\]\(\) \{.*?\n  \}\);)/s;
ok($relay, 'the /relay route is still registered');
like($relay, qr/server\.arg\("code"\)/, 'the HTTP output route reads `code`');
like($relay, qr/ir_toggle\(pin, code\)/, 'and replays it');
like($relay, qr/\\"state\\":\\"/, 'and acks a state like its neighbours');

# --- (f) learn starts and stops the capture remotely -----------------------
like($g5, qr/else if \(t == "learn"\) \{/, 'the socket accepts a learn message');
like($g5, qr/int pin = jpin\(m\["pin"\]\);/, 'learn names the receiver pin');
like($g5, qr/uint32_t ms = \(uint32_t\)jint64\(m\["ms"\]\);/, 'and the window');
like($g5, qr/irrx_request_learn\(pin, ms\)/, 'learn reaches the capture state machine');
like($g5, qr/\(ms == 0 \? "stopping" : "started"\)/, 'ms:0 stops; a positive window starts');

# --- (g) both kinds are ordinary components in the pin report --------------
like($g1, qr/struct component_kind_t \{/, 'component classes are a table');
like($g1, qr/\{ "irtx",\s+true\s+\}/, 'irtx is an output row');
like($g1, qr/\{ "irrx",\s+false \}/, 'irrx is an input row');
like($g1, qr/component_kinds\[m\]\.kind/, 'the report reads the class table');
like($g1, qr/JSONVar keys = config\[component_kinds\[m\]\.kind\]\.keys\(\);/,
	'components come from every mapped class, IR included');
like($g1, qr/const char \*ir_maps\[\] = \{ "irrx", "irtx" \};/,
	'the probe leaves configured IR pins alone');
like($g1, qr/ultrasonic and DHT are next/, 'the next classes are named where the next row goes');

# --- (h) a USB provision keeps the role it did not carry --------------------
like($g2, qr/JSONVar prior = JSON\.parse\(JSON\.stringify\(config\)\);/,
	'the provision snapshots the role through a string, not an alias');
unlike($g2, qr/JSONVar prior = config;/, 'a direct assignment aliases and loses it');
like($g2, qr/const char \*keep_keys\[\] = \{ "relay", "led", "button", "switch", "pot", "servo"/,
	'the role and the pin maps survive a USB provision');



# --- (j) the station stays awake and rejoins at once -----------------------
like($g2, qr/WiFi\.noLowPowerMode\(\);/, 'the station disables the CYW43 power save');
like($g3, qr/WiFi\.noLowPowerMode\(\);/, 'and asks again after an AP-mode change');
unlike($g3, qr/wifiDownTicks % 3 == 0/, 'a dropped link is retried every tick, not every third');
like($g3, qr/if \(multi\.run\(\) == WL_CONNECTED && wifi_addressed\(\)\) \{ wifi_join_done\(\); \}/,
	'and the retry is the same join');


# --- (k) a failed request does not poison the shared client ----------------
like($g4, qr/https\.end\(\);\s*\n\s*connexion->stop\(\);/,
	'a failed GET closes the shared TLS client before returning');
like($g4, qr/connexion->stop\(\)/, 'the stale socket is dropped explicitly');

done_testing();
