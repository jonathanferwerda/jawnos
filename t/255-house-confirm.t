# tests-for: public/js/manager/dialog.js templates/manager.html.ep public/js/manager/keyboard/03_editor_switcher.js public/js/manager/configure/03_platform_misc.js public/js/manager/marker/02_input_panel.js public/js/manager/manager/10_appointment_edit.js public/js/manager/manager/12_cards.js public/js/manager/configure/01_update_controls.js public/js/manager/configure/05_database_records.js public/js/manager/configure/06_watch_pay.js public/js/manager/network/01_wifi_vpn_android.js public/js/manager/network/02_tabs_bluetooth_remote.js public/js/manager/security/01_house_key.js public/js/manager/twirl/01_twirl_game.js public/js/manager/budget/01_reconcile_payables.js public/js/manager/warehouse.js public/js/manager/internet.js public/js/manager/marker.js public/js/manager/transaction/01_record_crypto.js public/js/manager/market.js public/js/manager/phone.js public/js/manager/email.js public/js/manager/configure/04_currency_backup.js
# covers:    a dialog is the house's own Alert shell - a message, a question with
#           OK and Cancel, or a question with one line of text - so the engine's
#           confirm(), alert() and prompt() (a Qt box in the live image, an
#           Android box on the phone, an OS box in a browser) never appear.

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
like($dialog, qr/function jawnosConfirmClear\(run_cancel\)/,
	'and a close drops it');
like($dialog, qr/function jawnosAlertClose\(run_cancel\) \{\n\tjawnosConfirmClear\(run_cancel === true\);/,
	'so the X and Escape cancel rather than answer');
like($dialog, qr/'#alert_confirm_ok', function\(\) \{[\s\S]*?var yes = jawnos_confirm_yes;[\s\S]*?jawnosAlertClose\(\);[\s\S]*?yes\(value\)/,
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

# --- the same shell carries an alert and a one-line question -----------------
like($dialog, qr/function jawnosAlertText\(message, options\)/,
	'a text Alert is the house dialog too');
like($dialog, qr/if \(options\.text\) \{ content\.text\(html\); \}/,
	'with the message as written, not as markup');
like($dialog, qr/typeof window\.alert === 'function'/,
	'a page without the shell still alerts through the browser');
like($dialog, qr/function jawnosPrompt\(message, default_value, on_yes, options\)/,
	'a question may take one line of text');
like($dialog, qr/\$\('#alert_input'\)[\s\S]*?\.val\(default_value === undefined \|\| default_value === null \? '' : default_value\)[\s\S]*?\.show\(\)\.trigger\('focus'\)\.select\(\);/,
	'the prompt fills, shows and focuses the input');
like($dialog, qr/var value = \$\('#alert_input'\)\.is\(':visible'\)/,
	'and OK reads the answer before the close empties it');
like($dialog, qr/addClass\('jawnos_dialog_text'\)/,
	'a typed question keeps its line breaks');
like($dialog, qr/typeof window\.prompt === 'function'/,
	'a page without the shell still prompts through the browser');
like($dialog, qr/jawnos_confirm_no = \(typeof options\.on_cancel === 'function'\)/,
	'a caller may hear that the question was dismissed');

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
like($markup, qr/<div id="alert"><\/div>\s*<input type="text" style="display:none;" id="alert_input">/,
	'the prompt input sits under the question');

# --- the keys ----------------------------------------------------------------
# The shell lives in the page all the time, so Enter must never press the OK of
# a dialog the person cannot see.
like($keys, qr/var open_boxes = \$\('\.dialog_box:visible'\);/,
	'Enter only presses a visible dialog');
like($keys, qr/open_boxes\.last\(\)\.find\('\.ok'\)/,
	'and presses its OK');
unlike($keys, qr/\$\('\.dialog_box'\)\[\$\('\.dialog_box'\)\.length - 1\]/,
	'the hidden shell is not the last dialog any more');

# --- every manager dialog is the house's -------------------------------------
# The measured files are the ones converted; the sweep below is what makes a new
# native confirm(), alert() or prompt() fail here instead of surprising the
# phone.
my %house = (
	'public/js/manager/configure/03_platform_misc.js'   => 'jawnosConfirm(',
	'public/js/manager/marker/02_input_panel.js'       => 'jawnosPrompt(',
	'public/js/manager/manager/10_appointment_edit.js' => 'jawnosConfirm(',
	'public/js/manager/manager/12_cards.js'            => 'jawnosConfirm(',
	'public/js/manager/configure/01_update_controls.js' => 'jawnosConfirm(',
	'public/js/manager/configure/05_database_records.js' => 'jawnosAlertText(',
	'public/js/manager/configure/06_watch_pay.js'      => 'jawnosAlertText(',
	'public/js/manager/configure/04_currency_backup.js' => 'jawnosPrompt(',
	'public/js/manager/network/01_wifi_vpn_android.js' => 'jawnosConfirm(',
	'public/js/manager/network/02_tabs_bluetooth_remote.js' => 'jawnosConfirm(',
	'public/js/manager/security/01_house_key.js'       => 'jawnosAlertText(',
	'public/js/manager/twirl/01_twirl_game.js'         => 'jawnosPrompt(',
	'public/js/manager/budget/01_reconcile_payables.js' => 'jawnosAlertText(',
	'public/js/manager/warehouse.js'                   => 'jawnosAlertText(',
	'public/js/manager/internet.js'                    => 'jawnosAlertText(',
	'public/js/manager/marker.js'                      => 'jawnosPrompt(',
	'public/js/manager/transaction/01_record_crypto.js' => 'jawnosAlertText(',
	'public/js/manager/market.js'                      => 'jawnosAlertText(',
	'public/js/manager/phone.js'                       => 'jawnosPrompt(',
	'public/js/manager/email.js'                       => 'jawnosPrompt(',
);
for my $rel (sort keys %house) {
	my $src = read_file("$root/$rel");
	like($src, qr/\Q$house{$rel}\E/, "$rel asks the house");
}

my @native;
find(sub {
	return unless -f && /\.js$/;
	my $rel = $File::Find::name;
	$rel =~ s{^\Q$root\E/}{};
	return if $rel eq 'public/js/manager/dialog.js';   # the documented fallbacks
	my $src = read_file($File::Find::name);
	# a commented-out call is not a call
	my $live = join "\n", grep { !/^\s*\/\// } split /\n/, $src;
	push @native, $rel if $live =~ /\b(?:window\.)?(?:alert|confirm|prompt)\s*\(/;
}, "$root/public/js/manager");
is_deeply(\@native, [], 'no manager script opens the engine\'s own box');

done_testing();
