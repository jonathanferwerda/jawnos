# tests-for: lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Edt.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Domain/Embedded2.pm lib/JawnOS/Domain/Ble2.pm lib/JawnOS/Domain/File.pm lib/JawnOS/Manager/Part14.pm perl/watch.pl jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino
# covers:    A toggle is ordered by the event's own time, not by when the write
#            happened to arrive. A start pressed on the panel and a switch
#            flipped a moment later reach the manager at their own pace; the
#            older event must not repaint the panel or turn the relay back on.
#            The board stamps the pins a physical switch drove, so a delayed
#            command minted before the flip is dropped instead of re-energising
#            the relay; both sides carry milliseconds so a same-second race is
#            still decided. A switch/button report also takes the LAN when the board is online, because a Bluetooth link can read as up after its listener closed and the stop never reaches the Manager.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use JawnOSTest;
use RepoSource;

my $root = repo_root();

# --- the settings gate keeps the newest event ---------------------------------

my ($fh, $dbfile) = tempfile('jawnos-switch-last-write-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table cache (app text, context text, subcontext text, data text, '
	. 'device text, timestamp text, server_time text, uuid text, ost text)');
# The real cache.uuid is unique; INSERT OR IGNORE is what makes a claim atomic.
$db->query('create unique index cache_uuid_unique on cache(uuid)');
$db->query('create table remote_machines (uuid text, signatorial text, deletions text)');
$db->query('create table sync_log (id integer primary key autoincrement, '
	. 'server_time text, signatorial text, tbl text, app text, uuid text, '
	. 'scope text, additional text, ost text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;

# The pass-through update and the BLE fan-out belong to the live app; this test
# is about the value the settings row ends up holding.
{
	no warnings 'redefine';
	local *Websocket::send = sub { };
	local *subs::watch_toggle_pusher = sub { };
	local *subs::icon_path = sub { $_[0] };

	my $app = 'le_tableau_stereo';
	my $t0  = 1793980000000;   # a start pressed on the panel
	my $t1  = $t0 + 2500;      # the switch thrown a moment later

	&subs::setting_setter({ app => $app, setting => 'toggle', value => 'on',
		timestamp => $t1, source => 'test' });
	is(&subs::setting_grabber({ app => $app, setting => 'toggle' }), 'on',
		'the switch-off state is stored with its event time');

	&subs::setting_setter({ app => $app, setting => 'toggle', value => 'off',
		timestamp => $t0, source => 'test' });
	is(&subs::setting_grabber({ app => $app, setting => 'toggle' }), 'on',
		'a delayed start (older event) cannot turn the toggle back on');

	# One movement writes the pre-press state and then its final state with the
	# same event time; the final write must land.
	&subs::setting_setter({ app => $app, setting => 'toggle', value => 'off',
		timestamp => $t1, source => 'test' });
	is(&subs::setting_grabber({ app => $app, setting => 'toggle' }), 'off',
		'an equal event time is allowed, so the final write of one movement lands');

	&subs::setting_setter({ app => $app, setting => 'toggle', value => 'on',
		timestamp => $t1 + 500, source => 'test' });
	is(&subs::setting_grabber({ app => $app, setting => 'toggle' }), 'on',
		'a newer event wins');

	# A seconds stamp from an older caller is read as seconds, not 1970.
	&subs::setting_setter({ app => $app, setting => 'toggle', value => 'off',
		timestamp => int(($t1 + 1500) / 1000), source => 'test' });
	is(&subs::setting_grabber({ app => $app, setting => 'toggle' }), 'off',
		'a seconds event stamp is normalised before it is compared');

	# No stamp means "now": the caller has no older event to lose to.
	&subs::setting_setter({ app => $app, setting => 'toggle', value => 'on', source => 'test' });
	is(&subs::setting_grabber({ app => $app, setting => 'toggle' }), 'on',
		'an unstamped write is now and wins');

	ok(&subs::toggle_event_is_older($app, $t0), 'the helper reports an older event');
	ok(!&subs::toggle_event_is_older($app, &subs::rightNow() + 60000), 'and a newer one is not older');
}

# --- one flick is one event, however many roads carried it --------------------

my $claim_chip = '988D7CC4B524D03A';
my $claim_ms   = 1794105106420;
ok(&subs::switch_event_fresh($claim_chip, '15', 'on', $claim_ms),
	'the first copy of a flick is fresh');
ok(!&subs::switch_event_fresh($claim_chip, '15', 'on', $claim_ms),
	'a second copy of the same flick - another worker, or a retry - is dropped');
ok(!&subs::switch_event_fresh($claim_chip, '15', 'on', '' . $claim_ms),
	'the same stamp as a string is the same flick');
ok(&subs::switch_event_fresh($claim_chip, '15', 'on', $claim_ms + 1),
	'a later flick of the same switch is a new event');
ok(&subs::switch_event_fresh($claim_chip, '15', 'off', $claim_ms),
	'the opposite state at the same instant is its own event');
ok(&subs::switch_event_fresh($claim_chip, '16', 'on', $claim_ms),
	'another switch at the same instant is its own event');
ok(&subs::switch_event_fresh($claim_chip, '15', 'on', 0),
	'a board with no clock sends no stamp, so nothing is claimed');
ok(&subs::switch_event_fresh($claim_chip, '15', 'on', 0),
	'... and it is never swallowed by the claim');

# --- every road to the toggle carries the event's time ------------------------


my $name   = read_file("$root/lib/JawnOS/Domain/Name.pm");
my $loader = read_file("$root/lib/JawnOS/Domain/Loader.pm");
my $edt    = read_file("$root/lib/JawnOS/Domain/Edt.pm");
my $notify = read_file("$root/lib/JawnOS/Domain/Notify.pm");
my $emb2   = read_file("$root/lib/JawnOS/Domain/Embedded2.pm");
my $ble2   = read_file("$root/lib/JawnOS/Domain/Ble2.pm");
my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");
my $watch  = read_file("$root/perl/watch.pl");
my $g1     = read_file("$root/jp/alarmclock/alarmclock_01_globals_clock_ble.ino");
my $g3     = read_file("$root/jp/alarmclock/alarmclock_03_loop_house_inputs_jobs.ino");
my $g4     = read_file("$root/jp/alarmclock/alarmclock_04_jobs_clock_config_net.ino");
my $file   = read_file("$root/lib/JawnOS/Domain/File.pm");

like($name, qr/sub toggle_event_is_older \{/, 'the settings layer has one ordering helper');
like($loader, qr/'JawnOS::Domain::Name' for qw\([^)]*toggle_event_is_older/,
	'the helper is registered in the domain loader');
like($name, qr/toggle write refused as older/, 'an older toggle write is refused');
like($name, qr/if \(!\$sync && defined \$settings->\{'timestamp'\}/,
	'the guard compares only a caller-supplied event time, never a peer replay');

like($edt, qr/setting_setter\(\{[^\n]*value => \$toggle[^\n]*timestamp => \$timestamp/,
	'the button/switch presser stamps the toggle it writes');
like($notify, qr/if \(&subs::toggle_event_is_older\(\$app, \$timestamp\)\)/,
	'a stale direct command is dropped before it reaches the board');
like($notify, qr/setting_setter\(\{[^\n]*value => \$save_state[^\n]*timestamp => \$timestamp/,
	'the direct command stamps the toggle it writes');
like($emb2, qr/if \(&subs::toggle_event_is_older\(\$app, \$timestamp\)\)/,
	'the automation leaves outputs alone for an event the settings layer superseded');

like($watch, qr/param\('timestamp_ms'\)/, 'the switch/button routes prefer the millisecond stamp');
like($watch, qr/setting_setter\(\{[^\n]*value => \$state[^\n]*timestamp => \$timestamp/,
	'the switch pre-press carries the event time');
like($ble2, qr/\$payload->\{'timestamp_ms'\}/, 'the BLE switch/button path prefers the millisecond stamp');
like($part14, qr/value => 'on', timestamp => \$timestamp/, 'a start appointment stamps its toggle write');
like($part14, qr/value => 'off', timestamp => \$timestamp/, 'a stop appointment stamps its toggle write');

# --- the board keeps its own switch as the newest word ------------------------

like($g1, qr/void set_epoch_ms\(/, 'the board can set its clock with milliseconds');
like($g1, qr/#define CMD_STALE_GRACE_MS 250/, 'the stale grace is smaller than a person\'s "a moment later"');
like($g4, qr/jint64\(timers\["timestamp_ms"\]\)/, 'the board reads the millisecond clock sync');
like($watch, qr/timestamp_ms => &subs::rightNow\(\)/, 'the time route sends milliseconds');

like($g1, qr/static int64_t event_ms\(\)/, 'the board has the event time in milliseconds');
like($g1, qr/String event_timestamp_ms\(\)/, 'and a string copy for BLE and HTTP');
my ($local) = $g3 =~ /(static void local_apply\(.*?\n\})/s;
ok($local, 'local_apply is still one function');
like($local, qr/command_mark_pin\(op, ev\)/,
	'a physical switch stamps the output pins it drove');
like($g3, qr/sd\["timestamp_ms"\] = event_timestamp_ms\(\)/, 'a BLE switch carries the millisecond stamp');
like($g3, qr{/watch/switch\?room=1.{0,300}?&timestamp_ms=}s, 'the HTTP switch fallback carries the millisecond stamp');
like($g3, qr{/watch/button\?room=1.{0,300}?&timestamp_ms=}s, 'the HTTP button fallback carries the millisecond stamp');

like($g3, qr/static bool lan_report_ready\(\)/, 'the board knows when the LAN can carry a report');
my $lan_pref = () = $g3 =~ /if \(!lan_report_ready\(\) && ble_up && ble_notify_enabled\)/g;
is($lan_pref, 2, 'a switch and a button both prefer the LAN while it is up');

# --- the claim is shared, not remembered in one process -----------------------

like($file, qr/sub switch_event_fresh \{/, 'one helper claims a physical switch event');
like($file, qr/insert or ignore into cache/, 'the claim is an atomic database insert');
like($loader, qr/'JawnOS::Domain::File' for qw\([^)]*switch_event_fresh/,
	'the helper is registered in the domain loader');
like($watch, qr/my \$stamp = \$c->param\('timestamp_ms'\) \|\| \$c->param\('timestamp'\)/,
	'the switch route reads the stamp the board sent');
like($watch, qr/switch_event_fresh\(\$chip_id, \$button, \$state, \$stamp\)/,
	'the switch route claims it before any work');
like($ble2, qr/my \$stamp = \$payload->\{'timestamp_ms'\} \|\| \$payload->\{'timestamp'\}/,
	'the BLE switch reads the same stamp');
like($ble2, qr/switch_event_fresh\(\$chip_id, \$button, \$state, \$stamp\)/,
	'the BLE switch claims the same event, so a flick on two roads is one event');
like($watch, qr/event_duplicate\(join\('\|', 'switch'/, 'a stamp-less board keeps the old window');

done_testing();
