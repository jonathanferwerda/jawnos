use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# An act panel opening or closing used to cost a whole layout round trip: the
# toggle changed window_saver(), so the next beat re-sent every window in the
# page, and the server wrote a jopen (and a scrollTop) for each of them. The
# panel is an event now: one small frame names the window that changed and
# nothing else, sent the moment it opens or closes. The beat carries geometry.
#
# The other two idle costs this pins: incoming frames are dispatched in one pass
# per turn instead of one immediate pass per frame, and the 1 Hz clock walk keeps
# its node list (and each node's window preference) until the page's elements
# change, so an idle second is attribute reads and text comparison.

my $root = repo_root();

# --- the act frame -----------------------------------------------------------

my $windows_js = js_source('public/js/manager/windows.js');
like($windows_js, qr/function appActSync\(target\)/,
	'the client has the act message');
like($windows_js, qr/windowjOpenSaver\(win\)/,
	'the frame carries the window jopen the server writes');
like($windows_js, qr/type: 'act', app: 'tab', window: app, jopen: json/,
	'it names the window and travels on the tab socket');
like($windows_js, qr/appActPosted\[key\] == json/,
	'an unchanged state is not re-sent');

# the toggles themselves call it, so the beat never has to notice
foreach my $ref (
	['public/js/manager/manager/09_app_back.js', qr/'reset'.*?appActSync\(app\)/s, '.reset'],
	['public/js/manager/manager/09_app_back.js', qr/'measures'.*?appActSync\(app\)/s, '.measures'],
	['public/js/manager/manager/10_appointment_edit.js', qr/'det'.*?appActSync\(app\)/s, '.det'],
	['public/js/manager/manager/10_appointment_edit.js', qr/'register'.*?appActSync\(app\)/s, '.register'],
	['public/js/manager/manager/06_appointment_distance.js', qr/'inventory'.*?appActSync\(app\)/s, '.inventory'],
	['public/js/manager/manager/06_appointment_distance.js', qr/appointment_list_toggle.*?appActSync/s, '.appointment_list_toggle'],
	['public/js/manager/tasks.js', qr/container\.show\(\);.*?appActSync\(app\);/s, '.tasks'],
	['public/js/manager/configure/04_currency_backup.js', qr/display\.html\(response\)\.show\(\);.*?appActSync/s, 'the configure display'],
) {
	my ($file, $re, $name) = @{$ref};
	like(read_file("$root/$file"), $re, "$name posts its open/close");
}

# the transaction panel is drawn on demand now: its act frame has to wait for the
# form to land, or it reports the panel closed and the server loses it
my $app_back = read_file("$root/public/js/manager/manager/09_app_back.js");
my ($reset_block) = $app_back =~ /(\$\(document\)\.on\('click', '\.reset'.*?\n\}\);)/s;
ok($reset_block, 'the .reset handler is found');
like($reset_block, qr/app_details'\)\.show\(\);.*?appActSync\(app\);/s,
	'the details panel reports open only once its form has landed');
like($reset_block, qr/if \(details\.is\(':visible'\)\) \{\s*details\.hide\(\);\s*appActSync\(app\);/s,
	'closing it reports at once');

# the beat ships geometry only
my $websocket_js = js_source('public/js/manager/websocket.js');
like($websocket_js, qr/var windows_json = windowSaver\(1\);/,
	'the heartbeat asks windowSaver for geometry only');
my $storage_js = read_file("$root/public/js/manager/windows/01_storage.js");
like($storage_js, qr/function windowSaver\(skip_act\)/,
	'windowSaver takes the skip flag');
like($storage_js, qr/var jopen = skip_act \? undefined : windowjOpenSaver\(\$\(v\)\);/,
	'a beat-shaped snapshot carries no jopen');

# --- the server side ---------------------------------------------------------

my $ws_pm = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");
like($ws_pm, qr/elsif \(\(\$data->\{'type'\} \|\| ''\) eq 'act'\)/,
	'the server has the act branch');
like($ws_pm, qr/setting => 'jopen',\s*value => encode_json\(\{ \$window_app => \$jopen->\{\$window_app\} \}\)/,
	'only the named window jopen is written');
like($ws_pm, qr/# jopen rides its own act frame now.*?\n\s*next unless defined \$windows->\{\$w\}->\{\$set\};/s,
	'a beat without jopen does not write a null over the saved panels');

# --- one dispatch pass per turn ----------------------------------------------

my $handler_js = read_file("$root/public/js/manager/websocket/01_message_handler.js");
like($handler_js, qr/var wsMessageQueue = \[\];/, 'incoming frames are queued');
like($handler_js, qr/function wsMessageHandler\(event\) \{\s*wsMessageQueue\.push\(event\.data\);/,
	'every frame joins the queue');
like($handler_js, qr/wsMessageFlushTimer = setTimeout\(function \(\) \{/,
	'the queue flushes on a timer (a hidden tab still takes its messages)');
like($handler_js, qr/function wsMessageDispatch\(raw\)/, 'the old handler body is the dispatcher');
like($handler_js, qr/var batch = wsMessageQueue;\s*wsMessageQueue = \[\];/,
	'the batch is taken in one go, so a frame arriving mid-flush queues for the next');
like($handler_js, qr/setTimeout\(function \(\) \{ throw err; \}, 0\);/,
	'a failed frame still reaches the page error reporter and does not stop the batch');
unlike($handler_js, qr/\brequestAnimationFrame\s*\(/,
	'the flush does not rely on rAF, which stops while the page is hidden');

# --- the 1 Hz clock walk keeps its nodes -------------------------------------

my $universal = read_file("$root/public/js/universal.js");
like($universal, qr/function jawnosChronNodeList\(\)/, 'the clock walk has a node-list cache');
like($universal, qr/nodes\.push\(\{ j: j, app: j\.closest\('\.wind'\)\.attr\('app'\) \|\| '' \}\)/,
	'each node is wrapped and its window resolved once');
like($universal, qr/var nodes = jawnosChronNodeList\(\);/,
	'the tick reads the cached list instead of re-querying the page');
unlike($universal, qr/\$\('\.since, \.time'\)\.each\( function\(\) \{\s*var header = \$\(this\);/,
	'the per-second jQuery wrap is gone');
like($universal, qr/new MutationObserver\(function\(mutations\)/, 'element changes dirty the cache');
like($universal, qr/lists\[l\]\[n\]\.nodeType === 1/, 'a text rewrite inside a clock is not a change');
like($universal, qr/jawnosChronDirty\(\);\s*\n\ttime_updater\(\);/, 'appointment_chron dirties the list it is about to paint');

# --- and every touched script still parses ----------------------------------

my $node = `command -v node 2>/dev/null`;
chomp $node if defined $node;
if ($node && -x $node) {
	my @files = map { "$root/$_" } qw(
		public/js/universal.js
		public/js/manager/websocket.js
		public/js/manager/websocket/01_message_handler.js
		public/js/manager/windows/01_storage.js
		public/js/manager/windows/04_act.js
		public/js/manager/windows.js
		public/js/manager/manager/06_appointment_distance.js
		public/js/manager/manager/09_app_back.js
		public/js/manager/manager/10_appointment_edit.js
		public/js/manager/tasks.js
		public/js/manager/configure/04_currency_backup.js
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
