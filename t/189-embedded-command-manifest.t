# tests-for: lib/JawnOS/Domain/Ble.pm lib/JawnOS/Domain/Notify.pm jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino
# covers:    The board remembers the last commands it ran (id/type/app + time), so
#            a movement delivered over a second road, or a copy of an older one,
#            is not applied again. The manager stamps a toggle push with one id
#            and time for every target, and does not fan a direct command back
#            to the board that already ran it.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root    = repo_root();
my $ble     = read_file("$root/lib/JawnOS/Domain/Ble.pm");
my $notify  = read_file("$root/lib/JawnOS/Domain/Notify.pm");
my $globals = read_file("$root/jp/alarmclock/alarmclock_01_globals_clock_ble.ino");
my $handlers = read_file("$root/jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino");
my $loop    = read_file("$root/jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino");

# --- the manager stamps the toggle push with one identity per movement --------

my ($pusher) = $ble =~ /(sub watch_toggle_pusher \{.*?\n\})/s;
ok($pusher, 'watch_toggle_pusher is still one sub');

my $toggle_at = index($pusher, "type => 'toggle'");
ok($toggle_at >= 0, 'the push still builds a toggle message');
# A bounded window after the message kind, so an `app`/`state` elsewhere in the
# sub cannot satisfy the identity checks below.
my $toggle_data = $toggle_at >= 0 ? substr($pusher, $toggle_at, 260) : '';
like($toggle_data, qr/app\s*=>\s*\$app/, 'the push still names the app');
like($toggle_data, qr/state\s*=>\s*\$state/, 'and still carries the state');
like($toggle_data, qr/uuid\s*=>/, 'the toggle data carries a command id');
like($toggle_data, qr/timestamp\s*=>/, 'and the time the movement happened');
like($pusher, qr/my \$push_at = \$data->\{'timestamp'\} \|\| &subs::rightNow\(\);/, 'the push carries the movement\'s own event time, not the send time');

# One identity for every target of the same movement: minted before the loop and
# reused by each message, so the board can recognise a command it already ran.
like($pusher, qr/my \$push_id\s*=\s*&subs::random_string_creator\(\d+\)/,
	'the push mints one id');
like($pusher, qr/my \$push_at\s*=\s*\$data->\{'timestamp'\} \|\| &subs::rightNow\(\)/,
	'and stamps it with the movement time, falling back to now');
my @minted = $pusher =~ /random_string_creator/g;
is(scalar @minted, 1, 'the id is minted once for the whole push, not per target');
like($toggle_data, qr/uuid\s*=>\s*\$push_id/, 'the message uses the minted id');
like($toggle_data, qr/timestamp\s*=>\s*\$push_at/, 'and the minted time');

my $mint_at = index($pusher, 'my $push_id');
my $loop_at = index($pusher, 'foreach my $t ( @targets )');
ok($mint_at >= 0 && $loop_at > $mint_at,
	'the identity is minted before the target loop');

# --- a direct command must not be echoed back to the board that ran it --------

my ($embedded) = $notify =~ /(sub embedded_toggle\(.*?\n\})/s;
ok($embedded, 'embedded_toggle is still one sub');
like($embedded, qr/subs::setting_setter\(\{[^}]*source_chip_id\s*=>\s*\$chip_id/,
	'the toggle write names the chip the direct command already drove');
like($embedded, qr/subs::setting_setter\(\{[^}]*setting\s*=>\s*'toggle'/,
	'and still writes the app toggle');

# --- the board keeps a small manifest of the commands it has run --------------

for my $name (qw/APPLIED_CMD_MAX command_id( command_seen( command_remember(
	command_is_stale( command_mark_pin( output_state( command_redundant(/) {
	like($globals, qr/\b\Q$name\E/, "the board declares $name");
}

# A toggle push and a BLE `set` both pass through the manifest before applying.
my ($app_state) = $globals =~ /(static void ble_apply_app_state\([^)]*\)\s*\{.*?\n\})/s;
ok($app_state, 'ble_apply_app_state is still one function');
like($app_state, qr/command_redundant\(/, 'a toggle push asks the manifest first');
like($app_state, qr/command_remember\(/, 'and remembers the command it ran');

my ($apply_set) = $globals =~ /(static void ble_apply_set\([^)]*\)\s*\{.*?\n\})/s;
ok($apply_set, 'ble_apply_set is still one function');
like($apply_set, qr/command_redundant\(/, 'a BLE set asks the manifest first');
like($apply_set, qr/command_remember\(/, 'and remembers the command it ran');

# The fast HTTP relay is the other road to the same hardware.
my $relay_at = index($handlers, 'server.on("/relay"');
ok($relay_at >= 0, 'the /relay route is still there');
my $relay_end = $relay_at >= 0 ? index($handlers, 'server.on(', $relay_at + 1) : -1;
my $relay = $relay_at >= 0 ? substr($handlers, $relay_at, ($relay_end > $relay_at ? $relay_end - $relay_at : 4000)) : '';
like($relay, qr/command_redundant\(/, 'a relay GET the board already ran is dropped');

# A scheduled job re-fires on every loop pass until it is removed; it must not
# click the relay twice, and the job is still removed after a skip.
my ($jobs) = $loop =~ /(void run_local_jobs\(\)\s*\{.*?\n\})/s;
ok($jobs, 'run_local_jobs is still one function');
like($jobs, qr/command_redundant\(/, 'a job copy the board already ran is dropped');
like($jobs, qr/config\["jobs"\]\[uuid\]\s*=\s*undefined/, 'and the job is still removed');

# The switch/button urls name the board, so the manager can exclude it from the
# toggle fan-out (the fast road already drove it).
for my $route ('/watch/switch?', '/watch/button?') {
	my $at = index($loop, $route);
	ok($at >= 0, "$route is still built by the board");
	my $url = $at >= 0 ? substr($loop, $at, 320) : '';
	like($url, qr/chip_id=/, "$route names this board's chip");
}

# --- the id means a command plus its time ------------------------------------
# Source-based: a signature that ignored the time would accept an old copy as
# the same command. The signature is built from the id and the timestamp, and a
# remembered command keeps that time.
my ($cmd_id) = $globals =~ /((?:static\s+)?\w+\s+command_id\s*\([^)]*\)\s*\{.*?\n\})/s;
ok($cmd_id, 'command_id is still one function');
like($cmd_id, qr/(?:ms|timestamp)\s*==\s*0/,
	'an id without a time is not a signature (an old copy cannot claim it)');

my ($remember) = $globals =~ /((?:static\s+)?\w+\s+command_remember\s*\([^)]*\)\s*\{.*?\n\})/s;
ok($remember, 'command_remember is still one function');
like($remember, qr/\.ms\s*=\s*ms|timestamp/, 'a remembered command keeps the time it ran');

done_testing();
