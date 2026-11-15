# tests-for: lib/JawnOS/Controller/manager_market.pm lib/JawnOS/Controller/manager_market2.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part06.pm public/js/manager/market.js public/js/manager/market/01_tabs_and_receipts.js public/js/manager/transaction.js public/js/manager/transaction/01_record_crypto.js templates/apps/app_details.html.ep templates/market/market.html.ep perl/help/topics_business.pl perl/help/topics_functions.pl
# covers:    A receipt's printed time and its category were lost at Checkout: the transaction was saved at "now" under the shopping list's category, with no way to file a Vape/Coffee/Dinner receipt elsewhere.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use RepoSource;

my $root = repo_root();
my $market = read_file("$root/lib/JawnOS/Controller/manager_market.pm");
my $receipt = read_file("$root/lib/JawnOS/Controller/manager_market2.pm");
my $part06 = read_file("$root/lib/JawnOS/Manager/Part06.pm");
my $market_js = read_file("$root/public/js/manager/market.js");
my $receipt_js = read_file("$root/public/js/manager/market/01_tabs_and_receipts.js");
my $tx_js = js_source('public/js/manager/transaction.js');
my $details = template_source('apps/app_details');
my $market_page = template_source('market/market');
my $help = help_source();

# --- the read asks for the printed time, not only the date ----------------
like($part06, qr/"time":"the printed time of day as HH:MM in 24-hour form, or empty"/,
	'the receipt reader asks for the printed time');
like($receipt, qr/time => \$out->\{'time'\} \|\| ''/,
	'the read hands the time to the confirm panel');
like($receipt, qr/category => \$receipt_category/, 'and a category to file it under');
like($receipt, qr/categories => \\\@category_choices/, 'with the apps the house has used');

# --- apply keeps both on the cart rows and on the kept receipt -------------
like($receipt, qr/my \$category = &subs::unformat_name\(\$c->param\('category'\)\) \|\| '';/,
	'apply reads the chosen category');
like($receipt, qr/my \$receipt_when = join\(' ', grep \{ defined \$_ && length \$_ \} \(\$receipt_date, \$receipt_time\)\);/,
	'apply keeps the printed date and time together');
like($receipt, qr/\$it->\{'receipt_timestamp'\} = \$receipt_ts if defined \$receipt_ts;/,
	'a linked row carries the receipt moment');
like($receipt, qr/\$row->\{'category'\} = \$category if \$category ne '';/,
	'a new row carries the chosen category');
like($receipt, qr/time => \$receipt_time, category => \$category/,
	'and the kept receipt records both');

# --- checkout hands the transaction the receipt's category and moment ------
like($market, qr/\$category = \$it->\{'category'\} if !\$category && \(\$it->\{'category'\} \|\| ''\) ne '';/,
	'the receipt category beats the shopping list');
like($market, qr/\$receipt_ts = \$it->\{'receipt_timestamp'\} if !\$receipt_ts/,
	'checkout reads the receipt moment from the cart');
like($market, qr/timestamp => \$receipt_ts, when => \$receipt_when/, 'and returns it with the transaction');
like($market, qr/receipt_timestamp => \$receipt_ts, receipt_when => \$receipt_when/,
	'the draft storage carries it too');

# --- the form shows the moment and saves it --------------------------------
like($details, qr/class="tx_receipt_when"/, 'the transaction form has a line for the receipt moment');
like($tx_js, qr/function txReceiptPaint\(ad\)/, 'one helper paints it');
like($tx_js, qr/\['receipt_timestamp'\] = appt\.find\('\.app_details'\)\.attr\('receipt_timestamp'\)/,
	'the draft keeps the receipt timestamp');
like($tx_js, qr/details\.attr\('receipt_timestamp', totals\['receipt_timestamp'\]\)/,
	'and restores it when the draft is read back');
like($tx_js, qr/appt\.find\('\.app_details'\)\.removeAttr\('receipt_timestamp'\)\.removeAttr\('receipt_when'\)/,
	'a cleared form forgets the receipt');
like($receipt_js, qr/function marketReceiptMoment\(date, time\)/, 'the panel resolves the local moment');
like($receipt_js, qr/receipt_timestamp: marketReceiptMoment\(rdate, rtime\)/,
	'and sends it with the apply');
like($market_js, qr/details\.attr\('receipt_timestamp', t\.timestamp\)/, 'checkout stamps the form');
like($market_js, qr/details\.attr\('receipt_when', t\.when\)/, 'with the printed moment for the person to see');
like($tx_js, qr/timestamp: receipt_timestamp \|\| timestamp/, 'Save sends the receipt moment, not now');

# --- the kept receipts pane can put it back -------------------------------
like($market_page, qr/data-time="<%= \$r->\{'time'\} \|\| '' %>"/, 'the kept receipt row carries its time');
like($market_page, qr/data-category="<%= \$r->\{'category'\} \|\| '' %>"/, 'and its category');

# --- the guide says where the choice lives --------------------------------
like($help, qr/the date and time, total, category, paid-by, reference and account editable/,
	'the Market topic names the new inputs');
like($help, qr/The category is the app the expense is filed under/, 'and says what the category means');
like($help, qr/keeps the receipt\\'s printed date and time/, 'the transactions topic says the record is backdated');

# --- a shop keeps the name the house already uses --------------------------
# A till slip prints WALMART and the house keeps Wal-mart: the read must find
# that vendor instead of starting a second app with a second set of purchases.
require "$root/lib/JawnOS/Manager/Part05.pm";
{
	no warnings 'redefine';
	local *Manager::market_vendors = sub { return [ 'wal-mart', 'canadian_tire', 'circle_k' ] };
	is(Manager::market_vendor_resolve('Walmart'), 'wal-mart', 'a spelling without the hyphen finds the house name');
	is(Manager::market_vendor_resolve('WAL-MART'), 'wal-mart', 'and so does the upper-case one');
	is(Manager::market_vendor_resolve('Wal Mart'), 'wal-mart', 'a space where the house has a hyphen finds it too');
	is(Manager::market_vendor_resolve('wal-mart'), 'wal-mart', 'the house name itself is left alone');
	is(Manager::market_vendor_resolve('Canadian Tire'), 'canadian_tire', 'an underscore in the key is not part of the name');
	is(Manager::market_vendor_resolve('Walmart Supercentre'), 'walmart_supercentre',
		'a different shop is not forced onto one it only resembles');
	is(Manager::market_vendor_resolve('Target'), 'target', 'a shop the house has not kept yet is left as read');
	is(Manager::market_vendor_resolve(''), '', 'no vendor stays no vendor');
}
like($receipt, qr/my \$receipt_vendor = &market_vendor_resolve\(\$out->\{'vendor'\} \|\| ''\);/,
	'the read resolves the vendor before the confirm shows it');
like($receipt, qr/vendor_formatted => &subs::format_name\(\$receipt_vendor\),/,
	'and the panel names it the house way');
like($receipt, qr/my \$vendor = &market_vendor_resolve\(\$c->param\('vendor'\) \|\| ''\);/,
	'apply resolves a vendor typed by hand too');

# --- the guide says the shop is the one the house keeps -------------------
like($help, qr/are one shop, so the purchases stay on the vendor you already have/,
	'the Market topic says a known shop keeps its name');

# --- what done_testing is for -----------------------------------------
done_testing();
