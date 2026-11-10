# tests-for: public/js/manager/dialog.js templates/manager.html.ep public/js/manager/keyboard/03_editor_switcher.js public/js/manager/configure/03_platform_misc.js public/js/manager/marker/02_input_panel.js public/js/manager/manager/10_appointment_edit.js public/js/manager/manager/12_cards.js public/js/manager/configure/01_update_controls.js public/js/manager/configure/05_database_records.js public/js/manager/configure/06_watch_pay.js public/js/manager/network/01_wifi_vpn_android.js public/js/manager/network/02_tabs_bluetooth_remote.js public/js/manager/security/01_house_key.js public/js/manager/twirl/01_twirl_game.js public/js/manager/budget/01_reconcile_payables.js
# covers:    a question is the house's own dialog - the Alert shell with OK and
#           Cancel - so the engine's confirm() (a Qt box in the live image, an
#           Android box on the phone, an OS box in a browser) never appears.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Find qw(find);
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";

my $dialog = read_file("$root/public/js/manager/dialog.js");
my $markup = read_file("$root/templates/manager.html.ep");
my $keys = read_file("$root/public/js/manager/keyboard/03_editor_switcher.js");

# --- the helper --------------------------------------------------------------
# It reuses the Alert's shell, so an Alert and a question cannot drift apart.
like($dialog, qr/function jawnosConfirm\(message, on_yes, options\)/,
	'jawnosConfirm is the one house question');
like($dialog, qr/var dialog = \$\('#alert_dialog'\)/,
	'and it asks in the Alert dialog');
like($dialog, qr/content\.text\(message/,
	'the question is text: a record or network name cannot become markup');
like($dialog, qr/jawnos_confirm_yes = \(typeof on_yes === 'function'\) \? on_yes : null/,
	'OK holds the caller\'s action');
like($dialog, qr/function jawnosConfirmClear\(\)/,
	'and a close drops it');
like($dialog, qr/function jawnosAlertClose\(\) \{\n\tjawnosConfirmClear\(\);/,
	'so the X and Escape cancel rather than answer');
like($dialog, qr/'#alert_confirm_ok', function\(\) \{[\s\S]*?var yes = jawnos_confirm_yes;[\s\S]*?jawnosAlertClose\(\);[\s\S]*?yes\(\)/,
	'the action runs after the dialog closes, and only on OK');
like($dialog, qr/class="cancel" id="alert_confirm_cancel"/,
	'Cancel carries the class Escape presses');
like($dialog, qr/class="ok" id="alert_confirm_ok"/,
	'OK carries the class Enter presses');
like($dialog, qr/function jawnosDialogT\(s\)/,
	'a page without translate.js still reads a label');
like($dialog, qr/jawnosDialogT\('OK'\)/, 'the buttons are translated');
like($dialog, qr/jawnosDialogT\('Cancel'\)/, 'both of them');
like($dialog, qr/jawnosDialogT\('Confirm'\)/, 'and the title is too');
like($dialog, qr/typeof window\.confirm === 'function'/,
	'a page without the shell still asks, through the browser');

# A plain Alert must not keep a question's buttons or its pending action, and
# must put the shell's own title back.
like($dialog, qr/function jawnosAlert\(html, options\) \{[\s\S]*?jawnosConfirmClear\(\);/,
	'a plain Alert drops a pending question');
like($dialog, qr/dialog\.attr\('data-dialog-title'\)/,
	'and restores the shell\'s own title');

# --- the shell ---------------------------------------------------------------
like($markup, qr/<div class="bottom_buttons jawnos_dialog_footer" id="alert_buttons" hidden style="display:none;"><\/div>/,
	'the shell has a footer for the answers, hidden until asked');
unlike($markup, qr/<span id="alert_buttons">/,
	'and the buttons are not inside the scrolling body');

# --- the keys ----------------------------------------------------------------
# The shell lives in the page all the time, so Enter must never press the OK of
# a dialog the person cannot see.
like($keys, qr/var open_boxes = \$\('\.dialog_box:visible'\);/,
	'Enter only presses a visible dialog');
like($keys, qr/open_boxes\.last\(\)\.find\('\.ok'\)/,
	'and presses its OK');
unlike($keys, qr/\$\('\.dialog_box'\)\[\$\('\.dialog_box'\)\.length - 1\]/,
	'the hidden shell is not the last dialog any more');

# --- every manager question is the house's -----------------------------------
# The measured files are the ones converted; the sweep below is what makes a new
# native confirm() fail here instead of surprising the phone.
my @house = qw(
	public/js/manager/configure/03_platform_misc.js
	public/js/manager/marker/02_input_panel.js
	public/js/manager/manager/10_appointment_edit.js
	public/js/manager/manager/12_cards.js
	public/js/manager/configure/01_update_controls.js
	public/js/manager/configure/05_database_records.js
	public/js/manager/configure/06_watch_pay.js
	public/js/manager/network/01_wifi_vpn_android.js
	public/js/manager/network/02_tabs_bluetooth_remote.js
	public/js/manager/security/01_house_key.js
	public/js/manager/twirl/01_twirl_game.js
	public/js/manager/budget/01_reconcile_payables.js
);
for my $rel (@house) {
	my $src = read_file("$root/$rel");
	like($src, qr/jawnosConfirm\(/, "$rel asks the house");
}

my @native;
find(sub {
	return unless -f && /\.js$/;
	my $rel = $File::Find::name;
	$rel =~ s{^\Q$root\E/}{};
	return if $rel eq 'public/js/manager/dialog.js';   # the documented fallback
	my $src = read_file($File::Find::name);
	push @native, $rel if $src =~ /\b(?:window\.)?confirm\s*\(/;
}, "$root/public/js/manager");
is_deeply(\@native, [], 'no manager script calls the engine\'s own confirm()');

done_testing();
