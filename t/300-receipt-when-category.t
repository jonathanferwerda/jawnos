# tests-for: lib/JawnOS/Controller/manager_market.pm lib/JawnOS/Controller/manager_market2.pm lib/JawnOS/Controller/manager_transaction2.pm lib/JawnOS/Domain/File.pm lib/JawnOS/Manager/Part05.pm lib/JawnOS/Manager/Part06.pm lib/JawnOS/Manager/Part32.pm public/js/manager/market.js public/js/manager/market/01_tabs_and_receipts.js public/js/manager/transaction.js public/js/manager/transaction/01_record_crypto.js templates/apps/app_details.html.ep templates/market/market.html.ep perl/help/topics_business.pl perl/help/topics_functions.pl
# covers:    A receipt's printed time and its category were lost at Checkout: the transaction was saved at "now" under the shopping list's category, with no way to file a Vape/Coffee/Dinner receipt elsewhere.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use Mojo::JSON qw(decode_json encode_json);
use RepoSource;

my $root = repo_root();
my $market = read_file("$root/lib/JawnOS/Controller/manager_market.pm");
my $receipt = read_file("$root/lib/JawnOS/Controller/manager_market2.pm");
my $part06 = read_file("$root/lib/JawnOS/Manager/Part06.pm");
my $save = read_file("$root/lib/JawnOS/Controller/manager_transaction2.pm");
my $market_js = read_file("$root/public/js/manager/market.js");
my $receipt_js = read_file("$root/public/js/manager/market/01_tabs_and_receipts.js");
my $tx_js = js_source('public/js/manager/transaction.js');
my $record_js = js_source('public/js/manager/transaction/01_record_crypto.js');
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

# --- a kept receipt can be thrown away ------------------------------------
{
	package FakeRows;
	sub new    { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
}
require "$root/lib/JawnOS/Manager/Part06.pm";
{
	require File::Temp;
	my $dir = File::Temp::tempdir(CLEANUP => 1);
	my $page = "$dir/keep.jpg";
	write_file($page, 'pages');
	my @writes;
	no warnings 'redefine';
	local *Manager::market_receipts = sub {
		return [ { uuid => 'r1', machine => 'me', files => [ $page ] }, { uuid => 'r2', files => [] } ];
	};
	local *subs::setting_setter = sub { push @writes, $_[0]; return 1 };
	local *subs::db_query = sub { return FakeRows->new([]) };
	local *subs::signatorial_designer = sub { return 'me' };
	local *subs::subprocessor = sub { return 1 };
	ok(Manager::market_receipt_remove('r1'), 'a kept receipt is thrown away');
	my $left = decode_json($writes[0]{'value'});
	is(scalar @{$left}, 1, 'the house row keeps the rest');
	is($left->[0]{'uuid'}, 'r2', 'the other receipt stays');
	ok(!-e $page, 'the page this machine kept goes with it');
	ok(!Manager::market_receipt_remove('nope'), 'an unknown receipt is not a removal');
	# a page a saved purchase still names is not ours to delete
	my $shared = "$dir/ref.jpg";
	write_file($shared, 'ref');
	local *Manager::market_receipts = sub { return [ { uuid => 'r3', machine => 'me', files => [ $shared ] } ] };
	local *subs::db_query = sub {
		return FakeRows->new([ { app => 'clothes', uuid => 'a1', file => encode_json([ { f => $shared } ]) } ]);
	};
	ok(Manager::market_receipt_remove('r3'), 'a receipt whose page a purchase names is still removed');
	ok(-e $shared, 'and the page stays for that purchase');
}

# --- the paper is copied onto the purchase it paid for ---------------------
{
	require File::Temp;
	my $dir = File::Temp::tempdir(CLEANUP => 1);
	my $page = "$dir/receipt_1.jpg";
	write_file($page, 'receipt page bytes');
	my ($updated, @logged);
	no warnings 'redefine';
	local *Manager::market_receipts = sub { return [ { uuid => 'r9', machine => 'me', files => [ $page ] } ] };
	local *subs::setting_grabber = sub { return 'Documents' };
	local *subs::home = sub { return $dir . '/' . ($_[0] || '') };
	local *subs::path_name = sub { return 'clothes' };
	local *subs::db_select = sub { return FakeRows->new([ { uuid => 'a1', app => 'clothes', file => '[]' } ]) };
	local *subs::db_update = sub { $updated = $_[1]; return 1 };
	local *Manager::thumbnail_creator = sub { return $_[0] };
	local *subs::rightNow = sub { return 1_800_000_000_000 };
	local *subs::random_string_creator = sub { return 'fuuid' };
	local *subs::log_writer = sub { push @logged, join('', @_); return 1 };
	ok(Manager::market_receipt_attach({ app => 'clothes', uuid => 'a1', receipt_uuid => 'r9' }),
		'the receipt page is attached to the purchase');
	my $files = decode_json($updated->{'file'});
	is(scalar @{$files}, 1, 'one page is on the appointment');
	is($files->[0]{'f'}, $page, 'naming the receipt own page, not a copy');
	ok($files->[0]{'shared'}, 'marked shared, so sealing and deleting leave it alone');
	ok(-e $page, 'and the page is still where the receipt keeps it');
	is(read_file($page), 'receipt page bytes', 'with its own bytes');
	ok(!Manager::market_receipt_attach({ app => 'clothes', uuid => 'a1', receipt_uuid => 'gone' }),
		'an unknown receipt attaches nothing');
}

# --- the list says which apps use a receipt --------------------------------
{
	local *subs::db_query = sub {
		return FakeRows->new([
			{ app => 'clothes', uuid => 'a1', file => encode_json([ { f => '/d/market/receipt_1.jpg' } ]) },
			{ app => 'wal-mart', uuid => 'a2', file => encode_json([ { f => '/d/market/receipt_2.jpg' } ]) },
			{ app => 'unrelated', uuid => 'a3', file => encode_json([ { f => '/d/other.jpg' } ]) },
		]);
	};
	my $refs = Manager::market_receipt_referrers([
		{ uuid => 'r1', files => [ '/d/market/receipt_1.jpg', '/d/market/receipt_2.jpg' ] },
	]);
	is_deeply($refs->{'r1'}, [ 'clothes', 'wal-mart' ], 'every app that names a page is listed');
	my $none = Manager::market_receipt_referrers([ { uuid => 'r2', files => [ '/d/market/none.jpg' ] } ]);
	ok(!defined $none->{'r2'}, 'a receipt nothing uses lists nothing');
}

# --- the wiring between the pane, the cart, the form and the save ---------
ok(index($receipt, 'market_receipt_remove($uuid)') >= 0, 'the remove route asks the helper');
ok(index($receipt_js, '/manager/market/receipt/remove') >= 0, 'the pane posts to the remove route');
ok(index($market_page, 'market_receipt_drop') >= 0, 'the kept receipt row carries a delete button');
ok(index($market_page, 'data-uuid=') >= 0, 'and the id that button removes');
ok(index($market_page, 'referenced_by') >= 0, 'the row says which apps use the receipt');
ok(index($receipt, 'my $receipt_uuid = &subs::random_string_creator(20);') >= 0, 'apply names the kept receipt on the cart rows');
ok(index($receipt, 'uuid => $receipt_uuid, files => $files') >= 0, 'and keeps it under that id');
ok(index($market, 'uuid => $receipt_uuid, storage => $storage') >= 0, 'checkout hands it to the transaction form');
ok(index($market_js, "attr('receipt_uuid', t.uuid)") >= 0, 'which the form carries');
ok(index($tx_js, "['receipt_uuid']") >= 0, 'the draft keeps it too');
ok(index($record_js, 'receipt_uuid: receipt_uuid') >= 0, 'and the save sends it');
ok(index($save, 'market_receipt_attach') >= 0, 'the save points the appointment at the paper');
ok(index($save, 'market_receipt_attach({ app => $vendor, uuid => $vendor_uuid') >= 0, 'the vendor names the same page');
ok(index($save, 'market_receipt_attach({ app => $i, uuid => $purchase->{\'uuid\'}') >= 0, 'and so does every item');
my $file_domain = read_file("$root/lib/JawnOS/Domain/File.pm");
my $part32 = read_file("$root/lib/JawnOS/Manager/Part32.pm");
ok(index($file_domain, q{next if ref $fi eq 'HASH' && $fi->{'shared'};}) >= 0,
	'the sealer leaves a shared page where it is');
ok(index($part32, q{if (!$file->{'shared'} && -e $filing)}) >= 0,
	'and deleting the row leaves the shared page on disk');
ok(index($help, 'The') >= 0 && index($help, 'throws it away for the whole House') >= 0,
	'the guide says a receipt can be thrown away');
ok(index($help, 'The list also says which apps use a receipt') >= 0, 'the guide says the list names its users');
ok(index($help, 'points the app it is filed under, its vendor and each item at that same page') >= 0,
	'and that the app, vendor and items point at the same page');

# --- what done_testing is for -----------------------------------------
done_testing();
