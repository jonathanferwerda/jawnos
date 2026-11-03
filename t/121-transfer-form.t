# tests-for: lib/JawnOS/Controller/manager_transaction2.pm lib/JawnOS/Controller/manager_transaction.pm public/js/manager/transaction.js public/js/manager/transaction/ public/css/manager.css templates/apps/transaction/transfer.html.ep templates/apps/app_details.html.ep perl/help/topics_functions.pl
# covers:    Saving a transfer was refused with "Enter the amount or the total before saving." because the form's only figure lives in .transfer_amount; the transfer form itself was bare markup.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

# A transfer carries its figure in .transfer_amount, not in the line amount and
# total an expense uses. The save guard asked every movement for the expense
# pair, so a transfer could never be recorded. The form is also laid out like the
# rest of the transaction entry now: a From -> To route with one Amount.

my $root = repo_root();
my $js = js_source('public/js/manager/transaction.js');
my $template = read_file("$root/templates/apps/transaction/transfer.html.ep");
my $details = read_file("$root/templates/apps/app_details.html.ep");
my $css = read_file("$root/public/css/manager.css");
my $controller = read_file("$root/lib/JawnOS/Controller/manager_transaction2.pm");
my $entry = read_file("$root/lib/JawnOS/Controller/manager_transaction.pm");
my $help = help_source();

# --- the save guard asks each movement for the figure it has ----------------
like($js, qr/var transfer_amount = iq\.find\('\.transfer_amount'\)\.val\(\);/,
	'the save reads the transfer amount');
like($js, qr/if \(movement == 'transfer'\) \{[\s\S]{0,160}!\(numeral\(transfer_amount\)\.value\(\) > 0\)/,
	'a transfer is asked for its amount before saving');
like($js, qr/Enter the amount to transfer\./, 'and says so plainly');
like($js, qr/to_account === account/, 'the destination cannot be the source account');
like($js, qr/else \{\s*var sum_total[\s\S]{0,300}?Enter the amount or the total before saving\./,
	'the amount-or-total guard now applies to the movements that have those fields');

# --- the form is a route: From -> To, then one Amount -----------------------
like($template, qr/class="tx_line_body tx_transfer_body"/, 'the form uses the transaction line layout');
like($template, qr/class="tx_row tx_transfer_route"/, 'the two ends sit on one row');
like($template, qr/tx_transfer_from_name/, 'the source account is named');
like($template, qr/<label><%= &subs::ui\('From'\) %><\/label>/, 'the source is labeled From');
like($template, qr/<label><%= &subs::ui\('To'\) %><\/label>/, 'the destination is labeled To');
like($template, qr/class="transfer_amount"[^>]*placeholder="0\.00"|placeholder="0\.00"[^>]*class="transfer_amount"/,
	'the amount is the form\'s one figure');
like($template, qr/attribute="transfer_amount"/, 'that figure is the transfer_amount the save reads');

# A select in .purchase_input writes a setting named by its `name`, so the To
# picker used to overwrite the app's paid-from account with the destination.
unlike($template, qr/class="[^"]*purchase_input/, 'the To picker is not a purchase input');
unlike($template, qr/name="account"/, 'and does not carry the paid-from name');

# --- the label follows the movement ----------------------------------------
like($details, qr/class="tx_account_label"/, 'the account label can be re-named');
like($js, qr/function txAccountLabel\(ad, movement\)/, 'one helper names it');
like($js, qr/movement == 'transfer'\) \? 'From' : 'Paid from'/,
	'From for a transfer, Paid from for a payment');
like($js, qr/txTransferPaint\(ad\)/, 'the destination is kept on a different account');

# --- and the layout has styling of its own ---------------------------------
like($css, qr/\.app_details \.tx_transfer_route \{/, 'the route row has a rule');
like($css, qr/\.app_details \.tx_transfer_account \{/, 'the named source has a rule');
like($css, qr/\.app_details \.tx_transfer_note \{/, 'the note under it has a rule');

# --- the server refuses the same incomplete moves ---------------------------
like($controller, qr/\$transfer_amount = &subs::numeric_formatter\(\$transfer_amount\) \+ 0;/,
	'the route normalizes the transfer amount');
like($controller, qr/\$to_account eq \$account/, 'the route refuses a transfer to itself');
like($controller, qr/Enter the amount to transfer\./, 'the route returns a readable error');

# --- suggestions only ask a real column ------------------------------------
# transfer_amount is not a column, so the autocomplete query used to die with a
# 500 on every keystroke in that field.
like($entry, qr/pragma_table_info\(\?\).*'appointments', \$attribute/,
	'the autocomplete checks that the attribute is a column');
like($entry, qr/unless \(\$is_column\) \{\s*\$c->render\(json => \[\]\);\s*return;/,
	'and answers an empty list instead of failing');

# --- the guide says what the form does -------------------------------------
like($help, qr/Choose Transfer from Type/, 'the transactions topic explains Transfer');
like($help, qr/The account above the form is the From side; To picks where the money lands/,
	'and names the fields it draws');

done_testing();
