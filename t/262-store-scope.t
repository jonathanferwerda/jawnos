# tests-for: lib/JawnOS/Controller/manager_transaction.pm lib/JawnOS/Controller/store_misc.pm lib/JawnOS/Controller/manager_store2.pm lib/JawnOS/Controller/manager_transaction2.pm lib/JawnOS/Controller/manager_store.pm lib/JawnOS/Domain/Pay.pm lib/JawnOS/Domain/Printer2.pm lib/JawnOS/Controller/manager_configure2.pm lib/JawnOS/Manager/Part08.pm templates/configure/store_setting_list.html.ep templates/store/printer/header.html.ep templates/store/printer/receipt.html.ep
# covers:    The seventh pass, data scope: a column name is checked before it
#           becomes SQL, a quote is read or changed only by its customer or the
#           house, a payment token that matches nothing scopes nothing, and a
#           join code cannot be moved to another machine.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file write_file);
use JawnOSTest;
use JawnOS::Platform;
use Mojo::JSON qw(decode_json);
use Mojo::Template;

sub source { return read_file(root() . '/' . $_[0]) }

# --- the autofill name is a column, not SQL ---------------------------------
my $tx = source('lib/JawnOS/Controller/manager_transaction.pm');
like($tx, qr/pragma_table_info\(\?\).*'appointments', \$name/,
	'autofill checks the name against the appointments columns');
like($tx, qr/unless \(\$is_column\) \{/,
	'and refuses a name that is not a column');

# --- a quote belongs to a customer or to the house ---------------------------
my $store = source('lib/JawnOS/Controller/store_misc.pm');
like($store, qr/my \$query = \{ uuid => \$uuid \};/,
	'quote/load starts from the uuid');
like($store, qr/\$query->\{'app'\} = \$customer->\{'app'\};/,
	'and narrows to the token customer app');
like($store, qr/return \$c->render\(json => \{\}\);/,
	'and answers nothing for a uuid with no customer and no house');
my ($delete_block) = $store =~ /(# POST \/store\/quote\/delete\b.*?)(?=\n# (?:GET|POST) )/s;
like($delete_block, qr/guest_browser_session/,
	'quote/delete refuses a guest browser');
my ($move_block) = $store =~ /(# POST \/store\/quote\/move\b.*?)(?=\n# (?:GET|POST) )/s;
like($move_block, qr/guest_browser_session/,
	'quote/move refuses a guest browser');
like($store, qr/my \$customer_app = &subs::printer_customer_app\(/,
	'print derives the customer app from the document');
like($store, qr/&& !&subs::guest_browser_session/,
	'and only a house session may override it');

# --- an unknown customer token scopes nothing -------------------------------
my $now = &subs::rightNow();
&subs::db_insert('appointments', {
	uuid => 'inv-scope-1', app => 'CxScope', type => 'invoice',
	data => '{"numbers":{"total":10,"balance":10}}',
	server_time => $now, timestamp => $now,
});
&subs::db_insert('appointments', {
	uuid => 'inv-scope-2', app => 'CxOther', type => 'invoice',
	data => '{"numbers":{"total":20,"balance":20}}',
	server_time => $now, timestamp => $now,
});
&subs::db_insert('settings', {
	app => 'CxScope', setting => 'uuid', value => 'cx-scope-1',
	server_time => $now, timestamp => $now,
});
my ($found_inv) = &subs::pay_invoice_lookup('inv-scope-1', '');
ok($found_inv, 'a link with no token still finds its invoice');
my @wrong = &subs::pay_invoice_lookup('inv-scope-1', 'cx-does-not-exist');
is(scalar @wrong, 0, 'a token that matches nothing scopes nothing');
my ($scoped_inv) = &subs::pay_invoice_lookup('inv-scope-1', 'cx-scope-1');
ok($scoped_inv, 'the matching customer token finds its own invoice');
my @crossed = &subs::pay_invoice_lookup('inv-scope-2', 'cx-scope-1');
is(scalar @crossed, 0, 'and cannot reach another customer invoice');

# --- a pending join code cannot be moved to another machine -----------------
my $conf = source('lib/JawnOS/Controller/manager_configure2.pm');
like($conf, qr/'join_request_rate'/, 'the forward rail has a per-address budget');
like($conf, qr/my \$same_machine = \(\$old_sig ne '' \|\| \$old_key ne ''\)/,
	'and only the identity that made a code may replace it');
like($conf, qr/that code is already pending/,
	'and a stranger is refused');

# --- an invoice keeps a paper version when it is saved ---------------------
my $store = source('lib/JawnOS/Controller/store_misc.pm');
like($store, qr/&store_invoice_paper_enabled\(\)/,
	'the move to an invoice asks the Store setting');
like($store, qr/&store_invoice_paper\(%paper\)/,
	'and writes the invoice\'s paper when it is allowed');
my $part08 = source('lib/JawnOS/Manager/Part08.pm');
like($part08, qr/payment_due_date invoice_paper/,
	'the paper switch is a setting the Store keeps');
like($part08, qr/sub store_invoice_paper\b/,
	'and the paper has its own helper');
like($part08, qr/shared => 1/,
	'the paper is one file the invoice names, never a copy');
my $cfg = source('templates/configure/store_setting_list.html.ep');
like($cfg, qr/setting="<%=\$m%>".*invoice_paper|invoice_paper/s,
	'Configure offers the switch');

{
	package FakePaperRows;
	sub new    { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
	package main;
	my $part08_path = root() . '/lib/JawnOS/Manager/Part08.pm';
	require $part08_path;
	require File::Temp;
	my $dir = File::Temp::tempdir(CLEANUP => 1);
	my ($updated, @logged);
	no warnings 'redefine';
	local *subs::db_select = sub { return FakePaperRows->new([ { app => 'bluewater_pallet', uuid => 'i1', file => '[]' } ]) };
	local *Manager::store_printer = sub { return { template => 'fake' } };
	local *subs::setting_grabber = sub { return 'Documents' };
	local *subs::home = sub { return $dir . '/' . ($_[0] || '') };
	local *subs::path_name = sub { return 'bluewater_pallet' };
	local *subs::rightNow = sub { return 1_800_000_000_000 };
	local *subs::random_string_creator = sub { return 'fuuid' };
	local *subs::db_update = sub { $updated = $_[1] if ($_[0] || '') eq 'appointments'; return 1 };
	local *subs::log_writer = sub { push @logged, join('', @_); return 1 };
	ok(Manager::store_invoice_paper({ app => 'bluewater_pallet', uuid => 'i1' }), 'the invoice keeps a paper');
	my $files = decode_json($updated->{'file'});
	is(scalar @{$files}, 1, 'one paper is on the invoice');
	is($files->[0]{'type'}, 'document', 'as an ordinary document row');
	like($files->[0]{'f'}, qr{/invoice_\d+\.pdf$}, 'named as its own version');
	ok($files->[0]{'shared'}, 'shared, so the sealer leaves the paper where it is');
	ok(-e $files->[0]{'f'}, 'and the paper is on disk');
	ok((grep { /invoice paper saved/ } @logged), 'the save is recorded');

	# The engine is the one renderer now: there is no HTML fallback to hide a
	# defect in it.
	@logged = ();
	local *JawnOS::PDF::Store::paper_pdf = sub { return (undef, 'the engine failed') };
	ok(!Manager::store_invoice_paper({ app => 'bluewater_pallet', uuid => 'i5' }), 'no engine, no paper');
	ok((grep { /the engine failed/ } @logged), 'and the log says what stopped it');
}

# --- the store's print and mail paths use the same engine -------------------
my $store_misc = source('lib/JawnOS/Controller/store_misc.pm');
like($store_misc, qr/JawnOS::PDF::Store::paper_pdf/, 'the print/PDF routes draw with the engine');
unlike($store_misc, qr/printer_pdf_from_html/, 'and keep no HTML fallback');

# --- a receipt is written for every invoice payment -------------------------
my $part08_again = source('lib/JawnOS/Manager/Part08.pm');
like($part08_again, qr/payment_paper_app receipt_message/,
	'the two receipt settings are in the Store list');
like($part08_again, qr/sub store_payment_receipt\b/,
	'and a payment has its own receipt writer');
for my $hook (qw(
	lib/JawnOS/Controller/manager_store2.pm
	lib/JawnOS/Domain/Pay.pm
	lib/JawnOS/Controller/manager_transaction2.pm
	lib/JawnOS/Controller/manager_store.pm
)) {
	like(source($hook), qr/&(?:Manager::)?store_payment_receipt\(/,
		"$hook writes the receipt after the payment");
}
like(source('lib/JawnOS/Domain/Printer2.pm'), qr/\$d->\{'customer_app'\}/,
	'a receipt printed from another app still names its invoice customer');

my $cfg_again = source('templates/configure/store_setting_list.html.ep');
like($cfg_again, qr/receipt_message/, 'Configure offers the receipt message');
like($cfg_again, qr/\$m eq 'receipt_message'/, 'as a free-text box');
like($cfg_again, qr/setting="<%= \$m %>"/, 'and every Store setting, the payment paper app included, is drawn');
like(source('templates/store/printer/header.html.ep'), qr/include 'store\/printer\/receipt'/,
	'the receipt template is part of the printed sheet');

{
	my $receipt_tpl = read_file(root() . '/templates/store/printer/receipt.html.ep');
	like($receipt_tpl, qr/receipt_message/, 'the receipt template prints the footer message');
	local *subs::setting_grabber = sub { return 'Thanks for your business!' };
	local *subs::ui = sub { return $_[0] };
	local *subs::price_formatter = sub { return sprintf('%.2f', $_[0] || 0) };
	my $html = Mojo::Template->new(vars => 1, auto_escape => 1)->render($receipt_tpl, {
		registers => [ { data => {
			numbers => { balance => 0 },
			payment => { amount => 25 },
			invoice => { id => 'INV-9' },
		} } ],
	});
	like($html, qr/Thanks for your business!/, 'the rendered receipt carries the message');
	like($html, qr/Remaining balance/, 'and says what is left to pay');
	like($html, qr/INV-9/, 'and which invoice it settles');
}

{
	package FakeReceiptRows;
	sub new    { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
	package main;
	require File::Temp;
	my $dir = File::Temp::tempdir(CLEANUP => 1);
	my ($inserted, $updated);
	no warnings 'redefine';
	local *subs::db_select = sub { return FakeReceiptRows->new([ {
		app => 'bluewater_pallet', uuid => 'inv-9', type => 'invoice',
		data => '{"id":"INV-9","item":"Widget","numbers":{"total":100,"balance":5},"payments":[]}',
		file => '[]' } ]) };
	local *subs::db_insert = sub { $inserted = $_[1] if ($_[0] || '') eq 'appointments'; return 1 };
	local *subs::db_update = sub { $updated = $_[1] if ($_[0] || '') eq 'appointments'; return 1 };
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return 'computer_repair' if ($q->{'setting'} || '') eq 'payment_paper_app';
		return 'Thanks!' if ($q->{'setting'} || '') eq 'receipt_message';
		return $dir if ($q->{'setting'} || '') eq 'scan_location';
		return '';
	};
	local *JawnOS::Platform::use_fork = sub { return 0 };
	local *Manager::store_invoice_paper = sub { return { f => $dir . '/invoice_1.pdf', shared => 1, type => 'document' } };
	local *Manager::store_printer = sub { return { template => 'fake' } };
	local *subs::home = sub { return $_[0] };
	local *subs::path_name = sub { return 'computer_repair' };
	local *subs::rightNow = sub { return 1_800_000_000_000 };
	local *subs::random_string_creator = sub { return 'ruuid' };
	local *subs::log_writer = sub { return 1 };
	my $payment = { amount => 95, timestamp => 1_800_000_000_000, method => 'cash' };
	my $rid = Manager::store_payment_receipt({ app => 'bluewater_pallet', uuid => 'inv-9', tx_app => 'bluewater_pallet', payment => $payment });
	ok($rid, 'a receipt row is written for the payment');
	is($inserted->{'type'}, 'receipt', 'as a receipt');
	is($inserted->{'app'}, 'computer_repair', 'on the configured payment-paper app');
	my $rd = decode_json($inserted->{'data'});
	is($rd->{'numbers'}->{'balance'}, 5, 'the receipt keeps the post-payment balance');
	is($rd->{'payment'}->{'amount'}, 95, 'and names the one payment it receipts');
	is($rd->{'customer_app'}, 'bluewater_pallet', 'and the customer it prints for');
	my $files = decode_json($updated->{'file'});
	is(scalar @{$files}, 2, 'the invoice paper and the receipt are stapled together');
	like($files->[0]{'f'}, qr/invoice/, 'the invoice comes first');
	like($files->[1]{'f'}, qr/receipt/, 'then the receipt');
	ok($files->[0]{'shared'} && $files->[1]{'shared'}, 'both are shared, so the sealer leaves them');
}

# --- the row is written now; the two renders wait for the child -------------
{
	package ForkReceiptRows;
	sub new    { my ($class, $rows) = @_; return bless { rows => $rows }, $class }
	sub hashes { return $_[0]->{'rows'} }
	package main;
	require File::Temp;
	my $dir = File::Temp::tempdir(CLEANUP => 1);
	my ($inserted, $updated, $captured);
	no warnings 'redefine';
	local *subs::db_select = sub { return ForkReceiptRows->new([ {
		app => 'bluewater_pallet', uuid => 'inv-9', type => 'invoice',
		data => '{"id":"INV-9","item":"Widget","numbers":{"total":100,"balance":5}}',
		file => '[]' } ]) };
	local *subs::db_insert = sub { $inserted = $_[1] if ($_[0] || '') eq 'appointments'; return 1 };
	local *subs::db_update = sub { $updated = $_[1] if ($_[0] || '') eq 'appointments'; return 1 };
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return 'computer_repair' if ($q->{'setting'} || '') eq 'payment_paper_app';
		return $dir if ($q->{'setting'} || '') eq 'scan_location';
		return '';
	};
	local *Manager::store_invoice_paper = sub { return { f => $dir . '/invoice_1.pdf', shared => 1, type => 'document' } };
	local *Manager::store_printer = sub { return { template => 'fake' } };
	local *subs::home = sub { return $_[0] };
	local *subs::path_name = sub { return 'computer_repair' };
	local *subs::rightNow = sub { return 1_800_000_000_000 };
	local *subs::random_string_creator = sub { return 'ruuid' };
	local *subs::log_writer = sub { return 1 };
	local *JawnOS::Platform::use_fork = sub { return 1 };
	local *subs::subprocessor = sub { $captured = $_[0]; return { pid => 1 } };
	my $rid = Manager::store_payment_receipt({ app => 'bluewater_pallet', uuid => 'inv-9', payment => { amount => 95, timestamp => 1_800_000_000_000 } });
	ok($rid, 'the caller gets the receipt uuid at once');
	ok($inserted, 'the receipt row is written synchronously');
	ok(!$updated, 'while no paper is rendered in the payment');
	ok(ref $captured eq 'CODE', 'a forked child is handed the renders');
	$captured->();
	my $files = decode_json($updated->{'file'});
	is(scalar @{$files}, 2, 'the child attaches both papers');
}

done_testing();
