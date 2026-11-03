# tests-for: perl/help/topics_configure.pl public/js/manager/configure/03_platform_misc.js public/js/manager/websocket/02_heartbeat_and_reload.js templates/configure/misc_setting_list.html.ep
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

done_testing();
