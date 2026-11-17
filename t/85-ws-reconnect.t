# tests-for: public/js/manager/websocket.js public/js/manager/websocket/ templates/
# covers:    A phone that slept comes back with sockets that still read readyState 1 and send into the void.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A phone that slept comes back with sockets that still read readyState 1 and
# send into the void. The only honest answer is a fresh handshake, so a page
# that became hidden and comes back reconnects at once and drops any backoff it
# earned while hidden. A foreground signal on a page that never went hidden is a
# check, not a teardown: the sockets that are still answering are kept. Hidden,
# the battery rule stands: one paced retry per failed socket, never a poll, and
# the retry reopens only the socket that is down rather than clearing its own
# backoff with a forced wake. The controller panel is drawn from a snapshot, so
# it asks for a beat on open rather than waiting for the next scheduled one.

my $root = repo_root();
my $ws   = js_source('public/js/manager/websocket.js');
my $tpl  = js_source('public/js/manager/network/02_tabs_bluetooth_remote.js');

# --- the timing a test (or a tuning pass) can read ---------------------------

like($ws, qr/^var wsVisibleRetryDelay = 1000;/m,
	'a visible socket that failed retries in a second, not a loop');
like($ws, qr/^var wsVisibleRetryMax = 30000;/m,
	'the visible retry doubles to half a minute');
like($ws, qr/^var wsHiddenReconnectDelay = 30000;/m,
	'the first hidden retry waits half a minute');
like($ws, qr/^var wsHiddenReconnectMax = 300000;/m,
	'the hidden backoff caps at five minutes');
like($ws, qr/^var wsRetryTimer = 0;/m, 'there is one retry timer');
like($ws, qr/^var wsRetryFailures = 0;/m, 'the failure count is tracked for the backoff');

# --- visible: every foreground signal asks for a check ----------------------

like($ws, qr/function websocketFront\(\) \{\s*if \(document\.hidden\) \{ return; \}\s*websocketWakeIfNeeded\(\);\s*\}/s,
	'a front signal asks for a check instead of forcing a teardown');
like($ws, qr/function unlockScreen\(\) \{.*?if \(typeof websocketFront === 'function'\) \{ websocketFront\(\); \}/s,
	'a screen unlock is a coming-to-front signal too');
like($ws, qr/document\.addEventListener\('visibilitychange'.*?else \{\s*websocketFront\(\);\s*\}/s,
	'visibilitychange -> visible asks for a check');
like($ws, qr/document\.addEventListener\('resume', websocketFront\);/,
	'the page lifecycle resume asks for a check');
like($ws, qr/window\.addEventListener\('focus', websocketFront\);/,
	'focus asks for a check');
like($ws, qr/window\.addEventListener\('pageshow', function\(event\) \{.*?event\.persisted\) \{ websocketFront\(\); \}/s,
	'a bfcache pageshow asks for a check');
like($ws, qr/document\.addEventListener\('jawnos:visible', websocketFront\);/,
	'the app can announce coming to the front');
like($ws, qr/document\.addEventListener\('jawnos:foreground', websocketFront\);/,
	'the foreground signal has a second, explicit name');
like($ws, qr/window\.jawnosWebsocketWake = websocketFront;/,
	'the bridge may call the wake directly');
like($ws, qr/window\.addEventListener\('online', websocketWakeIfNeeded\);/,
	'the existing online handler is kept');
like($ws, qr/document\.addEventListener\('pointerdown', websocketWakeIfNeeded, \{ capture: true, passive: true \}\);/,
	'the first-tap fallback is kept');

# a visible wake clears a hidden backoff and rebuilds immediately
like($ws, qr/function websocketWake\(force\) \{.*?websocketRetryClear\(\);.*?if \(force \|\| away > 0 \|\| websocketLooksDead\(\)\) \{\s*websocketRebuild\(\);/s,
	'a visible wake clears the backoff and rebuilds now');

# the cheap wake still rebuilds when the sockets really are gone
like($ws, qr/function websocketWakeIfNeeded\(\) \{.*?if \(wsRetryTimer \|\| pageHiddenAt \|\| websocketLooksDead\(\) \|\| !wsStatusInterval\) \{ websocketWake\(1\); \}/s,
	'a pending retry, a hidden absence, or a silent socket still rebuilds');

# --- hidden: the long backoff, and no poll ----------------------------------

like($ws, qr/function websocketRetryLater\(wasAlive\) \{.*?if \(document\.hidden \|\| windowVisible != 1\) \{.*?if \(wasAlive && wsRetryFailures <= wsFastRetryCount\)/s,
	'a hidden failure from a healthy socket retries fast first');
like($ws, qr/else \{\s*delay = Math\.min\(wsHiddenReconnectMax, wsHiddenReconnectDelay \* Math\.pow\(2, wsRetryFailures - 1\)\);\s*\}/s,
	'then a hidden failure waits the long, growing backoff');
like($ws, qr/else \{\s*delay = Math\.min\(wsVisibleRetryMax, wsVisibleRetryDelay \* Math\.pow\(2, wsRetryFailures - 1\)\);\s*\}/s,
	'a visible failure backs off too, instead of hammering a server that is down');
like($ws, qr/var wasAlive = heard && \(Date\.now\(\) - heard\) < \(stayingAliveInterval \* 2\);/, 'the close tells the retry whether the socket was healthy');
like($ws, qr/if \(ws\[app\] === this\) \{ websocketRetryLater\(wasAlive\); \}/,
	'a socket that closes on its own schedules the paced retry');
like($ws, qr/function wsOpener\(event,app,origin\) \{.*?wsRetryFailures = 0;/s,
	'a socket that answers clears the failure count');
like($ws, qr/wsRetryTimer = setTimeout\(function\(\) \{\s*wsRetryTimer = 0;\s*websocketRetryNow\(\);\s*\}, delay\);/s,
	'the paced retry reopens only the sockets that are down');
my ($retry_now) = $ws =~ /(function websocketRetryNow\(\) \{.*?\n\})/s;
ok($retry_now, 'the targeted retry has a body a test can read');
like($retry_now, qr/if \(down\) \{ websocketStart\(\); \}/,
	'the retry restarts the dead sockets, not the healthy ones');
like($retry_now, qr/readyState == 1 \|\| socket\.readyState == 0/,
	'a handshake still in flight is left to the watchdog');
unlike($retry_now, qr/websocketWake|websocketRebuild|websocketRetryClear/,
	'the retry never resets the backoff it just earned');
like($ws, qr/if \(document\.hidden\) \{.*?clearInterval\(wsStatusInterval\);.*?Object\.keys\(heartbeat\).*?delete heartbeat\[app\];/s,
	'hidden still stops the status beat and the heartbeats');
unlike($ws, qr/setInterval\(\s*websocket(?:Wake|Front|Retry)/,
	'nothing polls the reconnect while hidden');

# --- the controller asks for live data as soon as it is drawn ---------------

like($ws, qr/function stayingAliveNow\(app\) \{.*?heartbeatSend\(app\);.*?return true;/s,
	'a panel can ask for a stayingAlive round trip now');
like($ws, qr/heartbeatStart\(app\);\s*\/\/ beat once now.*?heartbeatSend\(app\);/s,
	'a socket that (re)subscribes beats once at once');
like($ws, qr/if \(!document\.hidden\) \{\s*heartbeatStart\(app\);.*?heartbeatSend\(app\);\s*\}/s,
	'a socket opened while hidden does not restart the heartbeat');
my $controller = $tpl;
like($controller, qr/if \(tab === 'controller'\) \{\s*networkControllerSnapshotApply\(\);\s*networkControllerBeatStart\(\);\s*if \(typeof stayingAliveNow == 'function'\) \{ stayingAliveNow\('server'\); \}/s,
	'opening the Controller tab paints the saved picture and asks for a beat at once');

# --- the music socket is a permanent line -----------------------------------

# The music socket is not the music window's private connection: its beat is what
# advertises this device's playback to the house, and the house's playback comes
# back on it. So every manager page opens it, and closing the music window must
# not close it - only a socket that is no longer open falls through, so the
# heartbeat and the watchdog can still drop a dead one and rebuild it.

my $stop = read_file("$root/public/js/manager/websocket/02_heartbeat_and_reload.js");
like($ws, qr/var wappts = \['server','tab','music'\];/,
	'a manager page opens the music socket even with no music window');
like($stop, qr/if \(app == 'music' && ws\[app\] && ws\[app\]\.readyState == 1\) \{ return; \}/,
	'closing the music window leaves a healthy music socket up');
like($ws, qr/tree\['music_data'\] != undefined && tree\.sound && \$\(\'\.track_item\.playing\'\)\.length/,
	'the beat reports music only while a track is on screen');
like($ws, qr/else if \(tree\['music_data'\] != undefined\) \{\s*tree\['music_data'\] = '';\s*data\['music_data'\] = '';/s,
	'a closed or locked player advertises nothing instead of a hollow record');
like($stop, qr/if \( n\.music_data \) \{/,
	'a peer drawing a music list skips the blank row');

# --- the touched script still parses ----------------------------------------

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my @files = map { "$root/$_" } qw(
		public/js/manager/websocket.js
		public/js/manager/websocket/02_heartbeat_and_reload.js
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

done_testing();
