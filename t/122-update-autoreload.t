# tests-for: perl/help/topics_configure.pl public/js/manager/configure/03_platform_misc.js public/js/manager/configure/01_update_controls.js public/js/manager/websocket/02_heartbeat_and_reload.js public/js/manager/websocket/01_message_handler.js lib/JawnOS/Manager/Part35.pm lib/JawnOS/Controller/manager_ws.pm lib/JawnOS/Domain/Generate.pm lib/JawnOS/Domain/Loader.pm templates/configure/device_lister/body.html.ep templates/layouts/manager.html.ep
# covers:    Auto-reload on update is a per-device choice, off by default. Off
#            means pill only: a shipped script change waits for a press instead
#            of reloading a hidden tab on its own. On restores the auto-reload.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;

my $root = "$FindBin::Bin/..";

my $reload = read_file("$root/public/js/manager/websocket/02_heartbeat_and_reload.js");
my $misc   = read_file("$root/public/js/manager/configure/03_platform_misc.js");
my $tpl    = read_file("$root/templates/configure/device_lister/body.html.ep");
my $misc_tpl = read_file("$root/templates/configure/misc_setting_list.html.ep");
my $help   = read_file("$root/perl/help/topics_configure.pl");
my $layout = read_file("$root/templates/layouts/manager.html.ep");

# --- the switch is read from localStorage, per device -----------------------
like($reload, qr/function jawnosUpdateAutoReload\(\)/,
	'a single reader answers whether auto-reload is on');
like($reload, qr/localStorage\.getItem\('jawnos_update_autoreload'\) === 'on'/,
	'it reads the namespaced per-device key and treats absent as off');

# --- off is pill only -------------------------------------------------------
like($reload, qr/var auto = jawnosUpdateAutoReload\(\);/,
	'the quiet-reload path asks the reader');
like($reload, qr/if \(auto && document\.hidden\) \{ jawnosReloadWhenReady\(\); return; \}/,
	'a hidden tab waits for the press unless Auto-reload is on');

# --- one move, one reload ---------------------------------------------------
# A tab that has not recorded a revision yet compares its own version with the
# one the socket reports. It must write the arrived parts down BEFORE it
# reloads, because that is what the reloaded page compares against. Without it
# a tree held at two builds (an update synced, its restart not yet) reloads the
# tab on every socket connect: the page and the socket disagree every time and
# neither reading is ever stored.
my ($first) = $reload =~ /(if \(!was \|\| !parts \|\| !stored \|\| !stored\.js\) \{.*?\n\t\})/s;
ok($first, 'the no-recorded-parts branch is found');
my $store_at = defined $first ? index($first, 'remember();') : -1;
my $reload_at = defined $first ? index($first, 'jawnosUpdateQuietReload()') : -1;
ok($store_at >= 0 && $reload_at >= 0 && $store_at < $reload_at,
	'the arrived revision is stored before the reload, so one move reloads once');

# The visibilitychange listener is registered only when auto is on, so an off
# device never arms the hidden-tab reload after the pill has appeared.
like($reload, qr/if \(auto\) \{\s*\n\s*\$\(document\)\.on\('visibilitychange\.jawnos_update_pill'/,
	'the hidden-tab listener is armed only when Auto-reload is on');

# --- the checkbox writes the choice ----------------------------------------
like($misc, qr/function jawnosUpdateAutoreloadPaint\(\)/,
	'the Misc panel has a painter for the checkbox');
like($misc, qr/localStorage\.setItem\('jawnos_update_autoreload', this\.checked \? 'on' : 'off'\)/,
	'changing the box writes on or off');
like($misc, qr/jawnosUpdateAutoreloadPaint\(\);/,
	'opening the Misc panel paints the saved choice');

# --- the on-screen control and its words ------------------------------------
# It moved out of Misc: a switch about code updates belongs beside Update
# Method in the Dev panel, not among appearance and storage.
like($tpl, qr/id="update_autoreload"/, 'the checkbox has its id in the Dev panel');
like($tpl, qr/&subs::ui\('Auto-reload on update'\)/,
	'the label goes through subs::ui so it is translatable');
unlike($misc_tpl, qr/id="update_autoreload"/,
	'and the Misc panel no longer carries it');
like(read_file("$root/public/js/manager/configure/01_update_controls.js"),
	qr/jawnosUpdateAutoreloadPaint\(\);/, 'opening the Dev panel paints the saved choice');

# --- help matches the label -------------------------------------------------
like($help, qr/Auto-reload on update, under the Dev panel.*Update Method card, is per screen and off by default/,
	'the Configure help names the setting and its new home');
like($help, qr/Off is pill only/, 'the help explains the off state');

# --- the stylesheet swap is guarded ----------------------------------------
# A revision arrives after a reconnect, and the deploy that made it may have
# landed while a worker was restarting. Re-pointing every sheet and dropping
# the old one on a failed fetch left the Manager with no CSS at all: icons at
# their intrinsic size and a dead layout until the app was reopened.
like($reload, qr/if \(version && what\.css\) \{/,
	'only a stylesheet move re-points the sheets');
like($reload, qr/one\('load', function \(\) \{ \$\(old\)\.remove\(\); \}\)/,
	'the parsed sheet is dropped only after its replacement loads');
like($reload, qr/one\('error'/, 'a failed fetch keeps the old sheet');
like($reload, qr/retry=/, 'and retries once for a restart blip');
unlike($reload, qr/bust\('script\[src\]'/, 'a running page never re-points a script src');
unlike($reload, qr/\$\(this\)\.attr\(attr, url\.replace/, 'the blind href rewrite is gone');

# --- a sheet that fails while the page itself loads ------------------------
# The in-place swap above only helps a page that is already up. A page that
# LOADS while a worker restarts can lose a sheet on its first fetch, and with
# no retry it stays unstyled: icons at their intrinsic size and a dead layout.
like($layout, qr/document\.addEventListener\('error'/,
	'the layout listens for a stylesheet that fails to load');
like($layout, qr/link\.tagName !== 'LINK' \|\| link\.rel !== 'stylesheet'/,
	'only a stylesheet is retried, not every failed element');
like($layout, qr/retry=1/, 'the retry is marked in the URL, so one failure cannot loop');
like($layout, qr/\.test\(href\)/, 'the marker is checked before any re-fetch');
like($layout, qr/\}, true\);/, 'the listener is registered in the capture phase (a link error does not bubble)');
# armed before the links, or it would miss the very failure it exists for
my $listen_at = index($layout, "document.addEventListener('error'");
my $first_css = index($layout, 'rel="stylesheet" href="/css/keyboard.css');
ok($listen_at >= 0 && $first_css > $listen_at,
	'the listener is armed before the first stylesheet link');

# --- the reload waits for the NEW build, not just an answer -----------------
# The socket hands out the new revision while the tree is still restarting, so
# the wait must not reload into a closed port. But a 200 from the tree being
# REPLACED proves only that it is still up: reloading into it comes back to the
# same old page and the update never lands. The wait therefore compares the
# health answer with the boot stamp and version this page load began with.
like($reload, qr/var page_boot = window\.jawnosPageBoot \|\| '';/,
	'the wait remembers the boot this page load first saw');
like($reload, qr/var page_version = \(typeof jawnos_version !== 'undefined'\)/,
	'and the version the page itself was served');
like($reload, qr/boot !== page_boot/,
	'a restart since the page loaded proves the new build is serving');
like($reload, qr/version !== page_version/,
	'so does a different version');
like($reload, qr/var comparable = \(boot && page_boot\) \|\| \(version && page_version\);/,
	'an answer carrying neither stamp is not waited on');
unlike($reload, qr/\.done\(go\)/, 'a bare 200 is no longer enough to reload');
like($reload, qr/else \{ go\(\); \}/, 'the bound still reloads, so a tab is never frozen');

# The page records the boot it loaded under, once, in memory: the comparison
# above has nothing to compare without it, and sessionStorage would carry a
# stale stamp into the reloaded page.
my $handler = read_file("$root/public/js/manager/websocket/01_message_handler.js");
like($handler, qr/if \(!window\.jawnosPageBoot\) \{ window\.jawnosPageBoot = data\['boot'\]; \}/,
	'the first connect of a page load records its boot');
unlike($handler, qr/sessionStorage\.setItem\('jawnosPageBoot'/,
	'it is not kept in sessionStorage: a reload must start a fresh record');

# One stamp, both callers: the socket's connect and the health read must answer
# the same boot, or the wait compares two different clocks.
my $generate = read_file("$root/lib/JawnOS/Domain/Generate.pm");
my $part35   = read_file("$root/lib/JawnOS/Manager/Part35.pm");
my $ws_route = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");
my $loader   = read_file("$root/lib/JawnOS/Domain/Loader.pm");

like($generate, qr/sub jawn_boot_stamp \{/, 'one helper mints the tree boot stamp');
like($generate, qr/\(\(stat\(\$boot_file\)\)\[9\] \|\| 0\) \. '-' \. \$boot_pid/,
	'the stamp is the pid file mtime and the pid it holds');
like($loader, qr/JawnOS::Domain::Generate' for qw\([^)]*\bjawn_boot_stamp\b/,
	'the domain map names the helper, so subs:: finds it');
like($part35, qr/boot\s+=> &subs::jawn_boot_stamp\(\),/,
	'the health read carries the stamp');
like($ws_route, qr/my \$boot_stamp = &subs::jawn_boot_stamp\(\);/,
	'and the socket connect answers the same one');
unlike($ws_route, qr/stat\(\$boot_file\)/, 'the socket no longer mints its own copy');

done_testing();
