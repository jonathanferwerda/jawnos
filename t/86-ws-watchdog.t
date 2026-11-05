# tests-for: public/js/manager/websocket.js public/js/manager/websocket/ public/js/manager/manager/09_app_back.js lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Manager/Part37.pm lib/JawnOS/Manager/Part14.pm perl/Websocket.pl
# covers:    A websocket can read OPEN while the machine slept or the server went silent, and a start/stop pushed in that gap
#

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A websocket can read OPEN while the machine slept or the server went silent.
# The 10-second beat only notices after two unanswered beats, and a resume does
# not always arrive as visibilitychange or focus (a WebKitGTK desktop waking, a
# WebView whose screen was off). This pins the local watch that closes both
# gaps without adding a poll to the network:
#
#   - a clock jump much wider than the tick is a wake no event announced;
#   - one late beat is probed at once, and an unanswered probe rebuilds;
#   - a handshake that never completes is retired;
#   - a reconnect asks for the open windows' headers, so a start or stop pushed
#     while the socket was away is painted at once;
#   - the server answers that catch-up from the header cache, and one dead
#     recipient can no longer swallow the rest of a broadcast.

my $root = repo_root();
my $ws   = js_source('public/js/manager/websocket.js');
my $watch = read_file("$root/public/js/manager/websocket/03_watchdog.js");
my $world = read_file("$root/lib/JawnOS/Domain/Calendar.pm");
my $ws_pm = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");
my $part37 = read_file("$root/lib/JawnOS/Manager/Part37.pm");
my $websocket_pl = read_file("$root/perl/Websocket.pl");
my $part14 = read_file("$root/lib/JawnOS/Manager/Part14.pm");
my $app_back = read_file("$root/public/js/manager/manager/09_app_back.js");
my $handler = read_file("$root/public/js/manager/websocket/01_message_handler.js");

# --- the watch itself --------------------------------------------------------

like($watch, qr/var wsWatchdogPeriod = 1000;/,
	'the watch looks at the sockets once a second');
like($watch, qr/var wsWatchdogProbeWait = 8000;/,
	'a probe gets a longer grace before it is called unanswered');
like($watch, qr/var wsWatchdogConnectGrace = 8000;/,
	'a handshake that never finishes is retired');
like($watch, qr/function wsWatchdogStart\(\) \{.*?wsWatchdogTimer = setInterval\(wsWatchdogTick, wsWatchdogPeriod\);/s,
	'the watch is the only poll, and it is local');
like($watch, qr/function wsWatchdogStop\(\) \{.*?clearInterval\(wsWatchdogTimer\);/s,
	'it can be stopped for a hidden page');
unlike($ws, qr/setInterval\(\s*websocket(?:Wake|Front|Retry)/,
	'the reconnect paths still do not poll the network');

# a clock jump is the wake signal
like($watch, qr/if \(since > stayingAliveInterval \* 2 && websocketLooksDead\(\)\) \{\s*websocketRebuild\(\);/s,
	'a suspended machine is seen as a wake, even without an event');
like($watch, qr/var since = now - \(wsWatchdogLast \|\| now\);/,
	'the watch compares the wall clock, not a frame');
like($watch, qr/if \(document\.hidden \|\| windowVisible != 1\) \{ return; \}/,
	'a hidden page costs nothing');

# a socket that reads OPEN but has gone quiet
like($watch, qr/var heard = socket\['ackAt'\] \|\| socket\['stayingAlive'\] \|\| 0;/,
	'the age is measured from the last frame actually heard');
like($watch, qr/if \(age > stayingAliveInterval \* 2\) \{ rebuild = 1; continue; \}/,
	'two silent beats is a dead socket');
like($watch, qr/if \(age > stayingAliveInterval\) \{.*?socket\['probedAt'\] = now;\s*heartbeatSend\(app\);/s,
	'one late beat is probed immediately instead of waiting');
like($watch, qr/else if \(now - socket\['probedAt'\] > wsWatchdogProbeWait\) \{.*?probeCount.*?< 2.*?heartbeatSend\(app\);.*?else \{\s*rebuild = 1;/s,
	'a second unanswered probe - not the first - rebuilds');
like($watch, qr/delete ws\[app\]\['probeCount'\];/,
	'a heard frame clears the probe count');
like($watch, qr/if \(now - socket\['connectingAt'\] > wsWatchdogConnectGrace\) \{ rebuild = 1; \}/,
	'a stuck handshake is retired too');
like($watch, qr/function wsTouched\(app\) \{.*?ws\[app\]\['ackAt'\] = Date\.now\(\);\s*delete ws\[app\]\['probedAt'\];/s,
	'any frame is proof of life');
like($ws, qr/ws\[app\]\.onmessage = function \(event\) \{\s*\/\/ any frame is an ack.*?wsTouched\(app\);\s*wsMessageHandler\(event\);/s,
	'every socket message marks its app as heard');
like($ws, qr/var ws_heard = socket\['ackAt'\] \|\| socket\['stayingAlive'\];/,
	'the dead check counts any frame, not only the liveness ack');

# started with the page and after every wake, stopped while hidden
like($ws, qr/ensureYellowRing\(\);\s*websocketStart\(\);\s*wsWatchdogStart\(\);/s,
	'the watch starts with the page');
like($ws, qr/function websocketWake\(force\) \{.*?websocketRetryClear\(\);\s*wsWatchdogStart\(\);/s,
	'a wake restarts the watch');
like($ws, qr/clearInterval\(wsStatusInterval\);\s*wsStatusInterval = null;\s*wsWatchdogStop\(\);/s,
	'hiding the page stops the watch with the other timers');

# --- the reconnect catch-up --------------------------------------------------

like($watch, qr/function wsResyncSoon\(\) \{.*?setTimeout\(function \(\) \{.*?wsResync\(\);.*?\}, 400\);/s,
	'a rebuild of several sockets asks once, not once per socket');
like($watch, qr/function wsResync\(\) \{.*?var chosen = '';.*?if \(!chosen \|\| apps\[i\] == 'tab'\) \{ chosen = apps\[i\]; \}/s,
	'the tab socket carries the request when it is up');
like($watch, qr/\$\('\.wind'\)\.each\(function \(\) \{.*?open_apps\.push\(a\);.*?\}\);/s,
	'the request names the windows that are actually open');
like($watch, qr/if \(open_apps\.length > 30\) \{ open_apps = open_apps\.slice\(0, 30\); \}/,
	'the open list is bounded');
like($watch, qr/type: 'resync',.*?apps: open_apps,\s*theme: 1/s,
	'the request carries the apps and the theme');
like($ws, qr/var ws_reopened = wsOpenedBefore\[app\] \? 1 : 0;\s*wsOpenedBefore\[app\] = 1;/,
	'the first open is not a reconnect');
like($ws, qr/if \(ws_reopened\) \{ wsResyncSoon\(\); \}/,
	'a reconnect asks for the state it may have missed');
like($watch, qr/function jawnosWebsocketStatus\(\)/,
	'a read-only status call exists for support');

# the answer lands the same way a live header push does
like($handler, qr/function jawnosHeaderApply\(app, html, timestamp\)/,
	'one place applies a header');
like($handler, qr/else if \( data\['type'\] == 'header' \) \{\s*jawnosHeaderApply\(data\['app'\], data\['header'\], data\['timestamp'\]\);/,
	'the live header push uses it');
like($handler, qr/else if \( data\['type'\] == 'resync' \) \{.*?\$\.each\(data\['headers'\] \|\| \{\}, function \(app, html\) \{\s*jawnosHeaderApply\(app, html, data\['timestamp'\]\);/s,
	'the catch-up applies every header in the frame');
like($app_back, qr/if \(response && response\['header'\] && typeof jawnosHeaderApply === 'function'\) \{\s*jawnosHeaderApply\(app, response\['header'\], response\['server_time'\]\);/s,
	'the press that caused a start/stop applies the header it was answered with');

# --- the server side ---------------------------------------------------------

like($part14, qr/\$returner->\{'header'\} = \$appt_header if defined \$appt_header && length \$appt_header;/,
	'a reset returns the header it just rendered');
like($world, qr/unless \(\$data->\{'header_only'\}\) \{\s*foreach my \$a \( \@\{ \(\$appts->\{\$app\} \|\| \{\}\)->\{'list'\} \|\| \[\] \} \) \{\s*&appt_alarm_setter\(\$a\);\s*\}\s*\}/s,
	'a header-only render skips the alarm walk');
like($world, qr/return wantarray \? \(\$header, \$appts\) : \$header;/,
	'a header-only render just returns the HTML');
like($ws_pm, qr/elsif \(\(\$data->\{'type'\} \|\| ''\) eq 'resync'\) \{/,
	'the worker has the resync branch');
like($ws_pm, qr/my \$cached_header = eval \{ &subs::cache_get\(\{ app => \$ra, context => 'header' \}\) \} \|\| \{\};/,
	'the answer reads the header cache a start/stop wrote');
like($ws_pm, qr/\$ra_html = eval \{ &subs::appt_header_printer\(\{ app => \$ra, header_only => 1, broadcast => 'no' \}\) \} \|\| '';/,
	'only a window with no cached header is rendered');
like($ws_pm, qr/destination => \$browser_tab_id,.*?timestamp => &subs::rightNow\(\)/s,
	'the catch-up goes to the tab that asked');
like($ws_pm, qr/\$data->\{'method'\} = '' unless defined \$data->\{'method'\};/,
	'a frame that omits method is normalised before the eq chain (no warning flood)');
like($ws_pm, qr/eval \{ &subs::appointment_theme_push\(\) \} if \$data->\{'theme'\};/,
	'a reconnect asks the theme to speak once more');
like($part37, qr/my \$deliver = sub \{.*?my \$ok = eval \{ \$conn->send\(\$wire\); 1 \};.*?delete \$target->\{\$app\}->\{\$key\} if defined \$key;/s,
	'one dead recipient is dropped, not the broadcast');
like($part37, qr/next if eval \{ \$recipient_locked->\(\$conn\) \};/,
	'a failing padlock check cannot take the push down');

# --- the padlock gate is per recipient --------------------------------------
# A house-wide pl_time expires while a screen can hold a future
# padlock_device_time (activity_timeout is per device). The HTTP gate honours
# that screen, so the live push must use the same rule; a global drop at the
# producer silenced the connect frame and left the manager painted but frozen.
like($part37, qr/return &padlock_locked_now\(undef, \$dev\);/,
	'the recipient gate asks the same per-device rule as HTTP');
unlike($part37, qr/return &padlock_device_locked\(\$dev\);/,
	'it does not stop at the manual per-device lock row');
unlike($websocket_pl, qr/&padlock_gate_locked\(\)/,
	'the producer no longer drops every server frame on the house-wide stamp');

{ my $n = () = $part37 =~ /\$returner = \$deliver->\(\$ws, \$conn, \$w\);/g;
  is($n, 2, 'both broadcast arms deliver through the guard'); }

# The manager-worker -> websocket-worker link is a cached unix socket. It can
# outlive its peer (a worker restart), and neither connected() nor a zero-byte
# write notices: the push then goes into a socket nobody reads. The peek is the
# honest check, and one retry on a fresh socket keeps a start/stop from being
# swallowed in the gap.
like($world, qr/use Socket qw\(MSG_PEEK MSG_DONTWAIT\);/,
	'the sender can ask the kernel whether the peer is still there');
like($world, qr/my \$peeked = recv\(\$socket, \$peek, 1, MSG_PEEK \| MSG_DONTWAIT\);/,
	'a reused socket is checked for EOF before a send');
like($world, qr/return length\(\$peek\) == 0 \? 1 : 0;/,
	'0 bytes in the peeked buffer is a dead peer (recv returns the address, not a count)');
like($world, qr/my \$got = recv\(\$socket, \$junk, 65536, MSG_DONTWAIT\);\s*last unless defined \$got && length\(\$junk\) > 0;/s,
	'the uuid a push is answered with is drained first, so the peek sees EOF');
like($world, qr/if \(&socket_drain_peek\(\$socket, \$rcv \? 0 : 1\)\) \{/,
	'the cached socket is drained and peeked in one helper');
like($world, qr/if \(!\$retried && !\$rcv && \$had_cached && \$bytes_written == 0 && \$err =~ \/Write error\|Broken pipe\|Connection reset\/\) \{\s*return &unix_socket_sender\(\$file, \$data, \$rcv, 1\);/s,
	'a write that left no bytes is retried once on a fresh socket');

# --- one binding per name ----------------------------------------------------
# A `var x = 1;` and a `function x(){}` in the same script are one binding: the
# hoisted function is assigned first, then the var assignment overwrites it. That
# is how the watch's own interval (var wsWatchdogTick = 1000) turned the tick
# function into the number 1000 and the watcher never ran. The page looked fine
# because jawnosWebsocketStatus still existed.
{
	my %vars = map { $_ => 1 } ($ws =~ /^var\s+([A-Za-z_\$][A-Za-z0-9_\$]*)\s*=/mg);
	my @fns  = ($ws =~ /^function\s+([A-Za-z_\$][A-Za-z0-9_\$]*)\s*\(/mg);
	my @both = grep { $vars{$_} } @fns;
	is_deeply(\@both, [], 'no var and function share a name in the websocket scripts')
		or diag('both var and function: ' . join(', ', @both));
}

like($ws, qr/var seen_headers = \{\};\s*\$\('\.wind'\)\.each\(function \(\) \{.*?seen_headers\[ha\] = hh\.attr\('last_updated'\) \|\| hh\.attr\('last_update'\) \|\| '';/s,
	'the tab beat names the header version every open window wears');
like($ws, qr/data\['headers_at'\] = seen_headers;/, 'and ships the map on the beat');
like(read_file("$root/public/js/manager/websocket/02_heartbeat_and_reload.js"),
	qr/if \(data\.headers && typeof jawnosHeaderApply === 'function'\) \{.*?\$\.each\(data\.headers, function \(app, html\) \{\s*jawnosHeaderApply\(app, html, header_at\[app\] \|\| 0\);/s,
	'a beat reply with newer headers applies them');

# --- a lost header push is corrected on the next beat -----------------------

like($ws_pm, qr/if \(\(\$apper \|\| ''\) eq 'tab' && ref \$data->\{'headers_at'\} eq 'HASH'\) \{/,
	'the tab beat is answered with stale headers');
like($ws_pm, qr/select timestamp, data from cache where app = \? and context = \? order by server_time desc limit 1/,
	'the answer compares against the header cache a push writes');
like($ws_pm, qr/my \$newer = 0 \+ \(\$hrow->\{'timestamp'\} \|\| 0\);\s*my \$wearing = 0 \+ \(\$data->\{'headers_at'\}->\{\$ha\} \|\| 0\);\s*next unless \$newer > \$wearing;/s,
	'only a header newer than the one on screen is sent');
like($ws_pm, qr/\$return_data->\{'headers'\} = \\%stale_headers;\s*\$return_data->\{'header_at'\} = \\%stale_times;/s,
	'the beat reply carries the header and its version');

# --- a reopened desk session is open again ----------------------------------

# The desk-session hook (music connect, log_me on) reopens the row a refresh
# stopped two minutes ago. A reopen must clear the stop flag: `stop_seen is
# null` is what stop_target_row and open_session_uuid read, so a row left with
# type=start and stop_seen=yes can never be named by the next stop, and the
# session runs on. The children it reopens are sessions of their own and follow
# the same rule.

like($ws_pm, qr/&subs::db_update\('appointments', \{ server_time => &subs::rightNow\(\), type => 'start', stop_seen => undef, stop_timestamp => undef \}/,
	'a refreshed desk session is reopened with the stop flag cleared');
like($ws_pm, qr/&subs::db_update\('appointments', \{ stop_seen => undef, stop_timestamp => undef, type => 'start', duration => \$dur, server_time => \$server_time \}/,
	'and so is each child session it reopens');
unlike($ws_pm, qr/stop_seen => 'yes', type => 'start'/,
	'a start is never written with the stop flag still set');

# --- the touched files still parse ------------------------------------------

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my @files = map { "$root/$_" } qw(
		public/js/manager/websocket.js
		public/js/manager/websocket/01_message_handler.js
		public/js/manager/websocket/03_watchdog.js
		public/js/manager/manager/09_app_back.js
	);
	my $failed = 0;
	foreach my $file (@files) {
		my $out = `$node --check "$file" 2>&1`;
		if ($? != 0) { $failed++; diag("$file: $out"); }
	}
	is($failed, 0, 'every touched script parses');
}
else {
	diag('node is not installed; the syntax check is skipped');
}

my $perl = $^X;
foreach my $file (qw(lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Domain/Calendar.pm lib/JawnOS/Manager/Part37.pm lib/JawnOS/Manager/Part14.pm)) {
	my $out = `$perl -I. -Ilib -c "$root/$file" 2>&1`;
	my $ok = ($out =~ /syntax OK/) ? 1 : 0;
	ok($ok, "$file compiles") or diag($out);
}

done_testing();
