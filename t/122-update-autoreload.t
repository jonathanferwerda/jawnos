# tests-for: perl/help/topics_configure.pl public/js/manager/configure/03_platform_misc.js public/js/manager/websocket/02_heartbeat_and_reload.js templates/configure/misc_setting_list.html.ep templates/layouts/manager.html.ep
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
my $tpl    = read_file("$root/templates/configure/misc_setting_list.html.ep");
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
like($tpl, qr/id="update_autoreload"/, 'the checkbox has its id');
like($tpl, qr/&subs::ui\('Auto-reload on update'\)/,
	'the label goes through subs::ui so it is translatable');

# --- help matches the label -------------------------------------------------
like($help, qr/Auto-reload on update, in Misc, is per device and off by default/,
	'the Configure help names the setting exactly as the panel does');
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

done_testing();
