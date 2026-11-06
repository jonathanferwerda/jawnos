# tests-for: lib/JawnOS/Domain/Name.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Domain/Ble2.pm lib/JawnOS/Domain/Ble.pm lib/JawnOS/Domain/Notify.pm lib/JawnOS/Manager/Part05.pm perl/watch.pl jp/alarmclock/alarmclock_01_globals_clock_ble.ino jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino
# covers:    A device's event time is a moment or it is nothing. A clockless
#            board sent " 0" (the Arduino String(double) pads to width 2), which
#            is truthy and wrote appointments at 1970; every ingress point now
#            sanitises the stamp, the writer refuses one that is not a moment,
#            the board sends a plain "0", and the bridge teaches a Bluetooth-only
#            board the clock so it has one at all. Also: one toggle push per chip,
#            labelled with what the device actually is.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
unshift @INC, "$root/lib";
my $read = sub { scalar read_file("$root/$_[0]") };

require JawnOS::Domain::Name;

# --- the helper: a moment, or undef ---------------------------------------
my $now = 1793994629707;
is(subs::event_time_ms(' 0'), undef, 'a padded zero (" 0") is not a time');
is(subs::event_time_ms('0'), undef, 'a plain zero is not a time');
is(subs::event_time_ms(''), undef, 'an empty stamp is not a time');
is(subs::event_time_ms(undef), undef, 'a missing stamp is not a time');
is(subs::event_time_ms('later'), undef, 'a word is not a time');
is(subs::event_time_ms('  -5 '), undef, 'a negative stamp is not a time');
is(subs::event_time_ms($now . ''), $now, 'a millisecond epoch passes through');
is(subs::event_time_ms('1793994629'), 1793994629000, 'a seconds epoch is read as seconds');
is(subs::event_time_ms(" $now\n"), $now, 'surrounding whitespace is tolerated');

my $loader = $read->('lib/JawnOS/Domain/Loader.pm');
like($loader, qr/JawnOS::Domain::Name' for qw\([^)]*\bevent_time_ms\b/, 'the loader maps the helper');

# --- the firmware stops sending " 0" --------------------------------------
my $g1 = $read->('jp/alarmclock/alarmclock_01_globals_clock_ble.ino');
my ($ms_fn) = $g1 =~ /(String event_timestamp_ms\(\) \{.*?\n\})/s;
ok($ms_fn, 'event_timestamp_ms is still one function');
like($ms_fn, qr/if \(!time_defined\) \{ return "0"; \}/, 'a clockless board says "0", not " 0"');

# --- and learns the clock over the bridge --------------------------------
my $g2 = $read->('jp/alarmclock/alarmclock_02_ble_handlers_wifi_setup.ino');
like($g2, qr/static void ble_learn_time\(JSONVar msg\)/, 'the board can take the clock from a message');
like($g2, qr/if \(ts > 1600000000000LL && ts < 4102444800000LL\) \{/, 'only a plausible epoch is applied');
my ($toggles) = $g2 =~ /(else if \(type == "toggles"\) \{.*?\n  \})/s;
ok($toggles, 'the toggles branch is still one block');
like($toggles, qr/ble_learn_time\(msg\)/, 'the toggles reply carries the clock');
my ($toggle) = $g2 =~ /(else if \(type == "toggle"\) \{.*?\n  \})/s;
ok($toggle, 'the toggle branch is still one block');
like($toggle, qr/ble_learn_time\(msg\)/, 'so does a toggle push');

# A link from the bridge is short-lived; a board with no clock must ask before it
# is gone, or it never gets one and never corrects its stale address/build.
like($g2, qr/uint32_t state_settle = time_defined \? 3000 : 0;/,
	'a clockless board asks at once instead of waiting for the link to settle');
like($g2, qr/\(millis\(\) - ble_connected_at\) > state_settle/,
	'and the gate uses that delay');

# --- every ingress point sanitises ---------------------------------------
my $watch = $read->('perl/watch.pl');
my ($switch) = $watch =~ /(get '\/watch\/switch' => sub\(\$c\) \{.*?\n\};)/s;
ok($switch, 'the switch route is still one route');
like($switch, qr/&subs::event_time_ms\(/, 'the switch route sanitises the stamp');
my ($button) = $watch =~ /(get '\/watch\/button' => sub\(\$c\) \{.*?\n\};)/s;
ok($button, 'the button route is still one route');
like($button, qr/&subs::event_time_ms\(/, 'the button route sanitises the stamp');

my $ble2 = $read->('lib/JawnOS/Domain/Ble2.pm');
like($ble2, qr/my \$press_ms = &subs::event_time_ms\(/, 'a bridged button sanitises the stamp');
like($ble2, qr/my \$sw_ms = &subs::event_time_ms\(/, 'a bridged switch sanitises the stamp');
like($ble2, qr/type => 'toggles', data => \$chunks->\[0\], timestamp_ms => &subs::rightNow\(\)/, 'the state reply teaches the clock');
like($ble2, qr/type => 'toggles', data => \$chunk, timestamp_ms => &subs::rightNow\(\)/, 'paged replies too');

my $notify = $read->('lib/JawnOS/Domain/Notify.pm');
like($notify, qr/my \$timestamp = &subs::event_time_ms\(\$data->\{'timestamp'\}\) \|\| &subs::rightNow\(\);/, 'embedded_toggle sanitises the stamp');

my $part05 = $read->('lib/JawnOS/Manager/Part05.pm');
like($part05, qr/\$given = undef unless defined \$given && \$given =~ \/\^\\s\*\\d\+/, 'the writer refuses a non-moment');
like($part05, qr/\$app->\{'timestamp'\} = \$given \|\| \$app->\{'server_time'\}/, 'and falls back to the server clock');

# --- one push per chip, labelled with what it is -------------------------
my $ble = $read->('lib/JawnOS/Domain/Ble.pm');
my ($pusher) = $ble =~ /(sub watch_toggle_pusher \{.*?\n\})/s;
ok($pusher, 'watch_toggle_pusher is still one function');
like($pusher, qr/my \$dev_edt = \$w->\{'edt'\} \|\| \$w->\{'purpose'\} \|\| \$edt;/, 'the target carries the device\'s own type');
like($pusher, qr/next if \$seen\{ \$w->\{'chip_id'\} \}\+\+;/, 'and is deduped per chip, not per requested type');
unlike($pusher, qr/\$seen\{ \$edt \. '\|' \./, 'the old per-type key is gone');

done_testing();
