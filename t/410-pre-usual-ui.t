# tests-for: lib/JawnOS/Manager/Part12.pm templates/appointment_wrapper.html.ep public/js/manager/dialog.js public/js/manager/manager/09_app_back.js public/js/manager/manager/06_appointment_distance.js public/js/manager/manager/02_web_nfc.js
# covers:    the Pre-usual button beside the usual, the line under the Extra
#            group's buttons that says what the usual fills in, and the press
#            paths for an ambiguous or capture usual: the ask re-sends the same
#            press with the chosen kind (remembering it only when the box is
#            checked), the capture opens the camera on the row the server named,
#            and an error is shown without clearing the form. The choice dialog
#            reuses the Alert shell and never leaves a confirm waiting to fire.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);

my $root = "$FindBin::Bin/..";
my $part12 = read_file("$root/lib/JawnOS/Manager/Part12.pm");
my $template = read_file("$root/templates/appointment_wrapper.html.ep");
my $dialog = read_file("$root/public/js/manager/dialog.js");
my $app_back = read_file("$root/public/js/manager/manager/09_app_back.js");
my $distance = read_file("$root/public/js/manager/manager/06_appointment_distance.js");
my $nfc = read_file("$root/public/js/manager/manager/02_web_nfc.js");

# --- the button beside the usual ---------------------------------------------
like($part12, qr/name => 'pre_usual', icon => 'pre_usual_button'/,
	'the Pre-usual button is in the pseudonym list');
like($part12, qr/name => 'pre_usual'.*?group => 'extra'/,
	'and sits in the Extra group with the usual');
like($part12, qr/name => 'usual', icon => 'usual_button', hint => &subs::ui\('Usual: fill in the usual extras'\)/,
	'the usual button carries its own hint');
like($part12, qr/hint => &subs::ui\('Pre-usual: fill in the usual extras from now'\)/,
	'the Pre-usual hint names what it does');
like($part12, qr/my \$set_key = \$context \. '\.' \. \$icon_set \. '\.usual2';/,
	'the pseudonym cache key is versioned so a new button reaches an installed list');
ok(-e "$root/public/images/decipherable/pre_usual_button.png",
	'the Pre-usual icon is staged where the pseudonym lookup finds it');

# --- the line under the buttons ----------------------------------------------
my ($extra) = $template =~ /class="group_contents extra_group_contents"([\s\S]*?)class="group_contents connect_group_contents"/;
ok(defined $extra, 'the Extra group renders');
like($extra, qr/<span class="usual_summary" app="<%= \$a %>"><\/span>/,
	'the usual line sits inside the Extra group, after its buttons');
like($template, qr/hint="<%= \$p->\{'hint'\} \|\| &subs::format_name\(\$p->\{'name'\}\) %>"/,
	'a pseudonym hint falls back to its displayed name');
my $hint_fallbacks = () = $template =~ /hint="<%= \$p->\{'hint'\} \|\| &subs::format_name\(\$p->\{'name'\}\) %>"/g;
is($hint_fallbacks, 4, 'every pseudonym loop uses the fallback');
like($template, qr/\.extra_group_contents \.usual_summary:empty \{ display: none; \}/,
	'an empty line takes no space before the fetch lands');

# --- the ambiguity dialog ----------------------------------------------------
like($dialog, qr/function jawnosUsualChoice\(candidates, chosen, on_ok, on_cancel\)/,
	'the choice dialog has one entry point');
like($dialog, qr/name="usual_kind"/, 'each candidate is a usual_kind radio');
like($dialog, qr/id="usual_remember"/, 'the remember checkbox is present');
like($dialog, qr/jawnosDialogT\('This is the usual'\)/,
	'its fixed words go through the translator');
like($dialog, qr/jawnos_usual_choice_ok = \(typeof on_ok === 'function'\) \? on_ok : null/,
	'OK keeps its own answer, not the confirm slot');
like($dialog, qr/jawnos_confirm_yes = null;[\s\S]*?jawnos_usual_choice_ok = \(typeof on_ok/,
	'a pending confirm cannot fire from the usual OK');
like($dialog, qr/'#alert_usual_cancel'[\s\S]*?jawnosAlertClose\(true\)/,
	'Cancel runs the cancel path');
like($dialog, qr/jawnos_usual_choice_open[\s\S]*?'Escape'/,
	'Escape dismisses the choice as Cancel does');
like($dialog, qr/jawnos_usual_choice_ok = null;[\s\S]*?jawnos_usual_choice_open = false;/,
	'closing clears the choice state');

# --- the press paths ---------------------------------------------------------
like($app_back, qr/response\['usual_ask'\]/, 'an ambiguous press is a question');
like($app_back, qr/jawnosUsualChoice\(ask\['candidates'\]/,
	'the question is asked in the house dialog');
like($app_back, qr/usual_kind: signature/, 'the retried press carries the chosen kind');
like($app_back, qr/retry\.usual_remember = 'on'/, 'and remembers only when the box is checked');
like($app_back, qr/usual_confirm: 'on'/, 'the dialog answer confirms a message send');
like($app_back, qr/data\.usual_confirm = usual_confirm/, 'and the confirmation rides the retried press');
like($app_back, qr/response\['usual_capture'\]/, 'a capture answer is handled');
like($app_back, qr/usual: true \}/, 'the native camera pending remembers it is a usual');
like($app_back, qr/usual: 1 \}/, 'the server camera post says it is a usual');
like($app_back, qr/remote_uuid: machine/, 'the capture names its machine');
like($app_back, qr/kind === 'scan'[\s\S]*?url: '\/manager\/scan_document'[\s\S]*?feed: feed[\s\S]*?usual: 1/,
	'a scan usual asks the scanner with its feed, not the camera');
like($app_back, qr/kind === 'video'[\s\S]*?window\.JawnCamera\.video\(\)[\s\S]*?native_kind: 'video'/,
	'a video usual records through the bridge, or falls back to the route');
like($app_back, qr/var kind = capture\['kind'\] \|\| 'image';/,
	'an image usual (the default) keeps the photo path');
like($app_back, qr/jawnCameraAvailable\(\)[\s\S]*?window\.JawnCamera\.photo\(camera\)/,
	'and the image path still opens the native camera');
like($app_back, qr/response\['usual_error'\]/, 'an error is shown');
like($app_back, qr/data\.usual_kind = usual_kind/, 'the chosen kind travels in the press payload');
like($app_back, qr/data\.usual_remember = usual_remember/, 'and the remember flag');
like($app_back, qr/url: '\/manager\/usual'/, 'the summary line is fetched');
like($app_back, qr/data: \{ app: app \}/, 'by app');
like($app_back, qr/t\('Usual: '\) \+ t\(line\)/, 'and shows the one line under the buttons');
like($app_back, qr/type == 'usual' \|\| type == 'pre_usual'\) \{ usualSummaryRefresh/,
	'a written usual refreshes the line');

my $ask_at = index($app_back, "response['usual_ask']");
my $clear_at = index($app_back, 'appClearer(app)');
ok($ask_at >= 0 && $clear_at > $ask_at,
	'the usual answers are read before the form is cleared and the place recorded');

like($distance, qr/group == 'extra' && typeof usualSummaryFill === 'function'/,
	'opening the Extra group fills the line');
like($nfc, qr/if \(pending\.usual\) \{ data\.usual = 1; \}/,
	'a native usual capture tells the picture route');

done_testing();
