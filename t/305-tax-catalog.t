# tests-for: lib/JawnOS/Domain/Tax.pm database/schema.sql lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_transaction2.pm lib/JawnOS/Controller/manager_store.pm lib/JawnOS/Domain/Store.pm lib/JawnOS/PDF/Store.pm templates/configure/me_setting_list.html.ep templates/configure/store_setting_list.html.ep templates/configure/appointment_list.html.ep templates/apps/transaction/expense.html.ep templates/apps/transaction/income.html.ep templates/apps/app_details.html.ep templates/store/item.html.ep templates/store/register.html.ep templates/store/printer/header.html.ep public/js/manager/transaction.js public/js/store.js public/js/store/register.js public/js/manager/configure/03_platform_misc.js
# covers:    The house tax catalog is one list, rates are percents, a line's
#            selected taxes are snapshotted, a customer's exemption travels with
#            the sale, and the Store's sales-tax switch can be off.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;
use RepoSource;

my $root = repo_root();

# --- the helpers are reachable through the domain loader -------------------
foreach my $name (qw(tax_catalog tax_catalog_write tax_percent tax_entry_normalize
	tax_codes_value tax_entries_for_codes tax_compute tax_line_snapshot
	tax_snapshot_merge tax_transaction_snapshot tax_exemption_for tax_countries
	store_tax_enabled store_tax_default_codes store_tax_settings
	store_tax_line_snapshot store_tax_totals cash_rounding_home_currency
	cash_rounding_setting cash_rounding_step cash_rounding_apply)) {
	ok(subs::provides($name), "$name is mapped");
}

# --- a rate is a percent, with or without the sign -------------------------
is(subs::tax_percent('13%'), 13, '13% is thirteen percent');
is(subs::tax_percent('13'), 13, '13 is thirteen percent');
is(subs::tax_percent(' 5 % '), 5, 'spaces and the sign are ignored');
ok(!defined subs::tax_percent('not a rate'), 'a non-number is not a rate');
ok(!defined subs::tax_percent('101'), 'a rate over 100 is refused');

my $entry = subs::tax_entry_normalize({ name => 'HST (Ontario)', rate => '13%', country => 'ca' });
is($entry->{'code'}, 'HST_ONTARIO', 'a code is made from the name when none is given');
is($entry->{'rate'}, 13, 'the entry keeps the percent');
is($entry->{'country'}, 'CA', 'the country is upper-cased');

# --- the catalog reads a list, normalizes it, and keeps a stored empty list --
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::setting_grabber = sub {
		my ($p) = @_;
		return encode_json([
			{ code => 'HST', name => 'HST', rate => '13%', country => 'ca' },
			{ name => 'GST', rate => 5, country => 'CA' },
		]) if (($p->{'setting'} // '') eq 'taxes');
		return 1;
	};
	my $cat = subs::tax_catalog();
	is(scalar @{$cat}, 2, 'the stored list is read');
	is($cat->[0]->{'rate'}, 13, 'the percent is normalized');
	is($cat->[1]->{'code'}, 'GST', 'a missing code is made from the name');
	is($cat->[0]->{'country'}, 'CA', 'the country is normalized');
}
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::setting_grabber = sub {
		my ($p) = @_;
		return '[]' if (($p->{'setting'} // '') eq 'taxes');
		return 1.13;
	};
	my $cat = subs::tax_catalog();
	is_deeply($cat, [], 'a stored empty list stays empty, with no legacy entry invented');
}
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::setting_grabber = sub {
		my ($p) = @_;
		return undef if (($p->{'setting'} // '') eq 'taxes');
		return 1.13;
	};
	my $cat = subs::tax_catalog();
	is($cat->[0]->{'code'}, 'SALES', 'a legacy 1.13 multiplier becomes one 13% entry');
	is($cat->[0]->{'rate'}, 13, 'the legacy multiplier keeps its rate');
}

# --- write normalizes the list ---------------------------------------------
{
	local *subs::warranty_device = sub { 'all' };
	my $stored;
	local *subs::setting_setter = sub { $stored = $_[0]->{'value'}; return {} };
	my $out = subs::tax_catalog_write([ { name => 'VAT', rate => '20%', country => 'gb' } ]);
	is($out->[0]->{'code'}, 'VAT', 'the writer returns the normalized code');
	my $list = decode_json($stored);
	is($list->[0]->{'rate'}, 20, 'the stored rate is a percent');
	is($list->[0]->{'country'}, 'GB', 'the stored country is normalized');
}

# --- the arithmetic: exclusive, inclusive, mixed rates, rounding -----------
my $catalog = [
	{ code => 'HST', name => 'HST', rate => 13, country => 'CA' },
	{ code => 'GST', name => 'GST', rate => 5, country => 'CA' },
	{ code => 'VAT', name => 'VAT', rate => 20, country => 'GB' },
];
my $both = [ $catalog->[0], $catalog->[1] ];
my $exclusive = subs::tax_compute(100, $both, 0);
is($exclusive->{'tax'}, 18, 'exclusive tax is the sum of the rates');
is($exclusive->{'total'}, 118, 'exclusive total adds the tax');
is($exclusive->{'entries'}[0]->{'amount'}, 13, 'HST gets its share');
is($exclusive->{'entries'}[1]->{'amount'}, 5, 'GST gets its share');
my $inclusive = subs::tax_compute(118, $both, 1);
is($inclusive->{'tax'}, 18, 'inclusive tax is the part inside the gross');
is($inclusive->{'net'}, 100, 'inclusive net is the gross less the tax');
my $odd = subs::tax_compute(10, [ { code => 'A', name => 'A', rate => 7 }, { code => 'B', name => 'B', rate => 7 } ], 0);
is($odd->{'tax'}, 1.4, 'a repeating share is rounded to the cent');
is($odd->{'entries'}[0]->{'amount'} + $odd->{'entries'}[1]->{'amount'}, 1.4,
	'the parts always add to the whole');

# --- the transaction snapshot merges the lines -----------------------------
my $movement = {
	line_one => { amount => 100, has_tax => 'off', taxes => [ 'HST', 'GST' ] },
	line_two => { amount => 50, has_tax => 'off', taxes => [ 'HST' ] },
	totals => { amount => 150 },
};
my $snapshot = subs::tax_transaction_snapshot($movement, $catalog);
my %by = map { $_->{'code'} => $_ } @{$snapshot};
is($by{'HST'}->{'amount'}, 19.5, 'HST is merged across the lines');
is($by{'GST'}->{'amount'}, 5, 'GST is its own line');

# --- a customer's exemption and country defaults ---------------------------
my $with_gb = [ @{$catalog}, { code => 'VAT_GB', name => 'VAT (UK)', rate => 20, country => 'GB' } ];
{
	local *subs::settings_grabber = sub {
		return { tax_exempt => 'on', tax_exemption_id => 'EX-42', tax_country => 'GB' };
	};
	my $ex = subs::tax_exemption_for('acme', $with_gb);
	is($ex->{'exempt'}, 1, 'the customer is exempt');
	is($ex->{'id'}, 'EX-42', 'the exemption id is read');
	is($ex->{'country'}, 'GB', 'the country is read');
	is_deeply($ex->{'codes'}, [ 'VAT', 'VAT_GB' ], 'the country preselects its catalog entries');
}

# --- the Store switch and its totals --------------------------------------
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::setting_grabber = sub {
		my ($p) = @_;
		return 'on' if (($p->{'setting'} // '') eq 'sales_tax_enabled');
		return 1;
	};
	is(subs::store_tax_enabled(), 1, 'an explicit on enables the Store tax');
}
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::setting_grabber = sub {
		my ($p) = @_;
		return 'off' if (($p->{'setting'} // '') eq 'sales_tax_enabled');
		return 1.13;
	};
	is(subs::store_tax_enabled(), 0, 'an explicit off wins over the legacy multiplier');
}
{
	local *subs::setting_grabber = sub {
		my ($p) = @_;
		return undef if (($p->{'setting'} // '') eq 'sales_tax_enabled');
		return 1.13;
	};
	is(subs::store_tax_enabled(), 1, 'no switch falls back to a legacy multiplier above 1');
}
{
	local *subs::setting_grabber = sub {
		my ($p) = @_;
		return undef if (($p->{'setting'} // '') eq 'sales_tax_enabled');
		return 1;
	};
	is(subs::store_tax_enabled(), 0, 'a legacy 1 means no tax');
}

my $settings = { enabled => 1, default_codes => [ 'HST' ], catalog => $catalog, countries => [ 'CA', 'GB' ] };
my $one = subs::store_tax_totals([ { price => 100, quantity => 1 } ], $settings);
is($one->{'tax'}, 13, 'an item with no codes uses the Store default');
is($one->{'total'}, 113, 'the Store total adds the default tax');
my $two = subs::store_tax_totals([ { price => 100, quantity => 1, tax_codes => [ 'HST', 'GST' ] } ], $settings);
is($two->{'tax'}, 18, 'an item with its own codes charges both');
my $off = subs::store_tax_totals([ { price => 100, quantity => 1 } ], { %{$settings}, enabled => 0 });
is($off->{'tax'}, 0, 'a switched-off Store charges no tax');
is_deeply($off->{'taxes'}, [], 'and has no breakdown');

# --- the schema and the migration carry the new columns -------------------
my $schema = read_file("$root/database/schema.sql");
like($schema, qr/taxes LONGTEXT/, 'the schema carries the taxes snapshot');
like($schema, qr/tax_exemption VARCHAR\(255\)/, 'the schema carries the exemption id');
my $migrations = read_file("$root/lib/JawnOS/Domain/Migrations.pm");
like($migrations, qr/add column taxes LONGTEXT/, 'the migration adds the taxes snapshot');
like($migrations, qr/add column tax_exemption VARCHAR\(255\)/, 'the migration adds the exemption id');

# --- the save route and the Store read the new columns --------------------
my $transaction = read_file("$root/lib/JawnOS/Controller/manager_transaction2.pm");
like($transaction, qr/tax_transaction_snapshot/, 'the transaction save computes the snapshot');
like($transaction, qr/taxes => encode_json\(\$tax_snapshot\)/, 'the transaction saves the snapshot');
like($transaction, qr/tax_exemption => \$tax_exemption/, 'the transaction saves the exemption');
my $store = read_file("$root/lib/JawnOS/Domain/Store.pm");
like($store, qr/store_tax_totals/, 'the Store totals use the catalog helper');
my $store_controller = read_file("$root/lib/JawnOS/Controller/manager_store.pm");
like($store_controller, qr/store_tax_settings/, 'the register reads the tax settings');
like($store_controller, qr/tax_exemption/, 'the register carries the exemption');

# --- the UI is wired ------------------------------------------------------
my $me = read_file("$root/templates/configure/me_setting_list.html.ep");
like($me, qr/tax_catalog_row/, 'the Me panel has catalog rows');
my $store_cfg = read_file("$root/templates/configure/store_setting_list.html.ep");
like($store_cfg, qr/sales_tax_enabled/, 'the Store panel has the sales-tax switch');
my $app_cfg = read_file("$root/templates/configure/appointment_list.html.ep");
like($app_cfg, qr/tax_exempt/, 'the App panel has the exemption fields');
my $expense = read_file("$root/templates/apps/transaction/expense.html.ep");
like($expense, qr/purchase_input taxes/, 'the transaction has a tax picker');
my $transaction_js = read_file("$root/public/js/manager/transaction.js");
like($transaction_js, qr/transactionTaxRate/, 'the transaction JS computes the line rate');
my $item = read_file("$root/templates/store/item.html.ep");
like($item, qr/tax_codes/, 'the Store item has its own tax codes');
my $register = read_file("$root/templates/store/register.html.ep");
like($register, qr/tax_exemption/, 'the register has the exemption controls');
my $printer = read_file("$root/templates/store/printer/header.html.ep");
like($printer, qr/paper_taxes/, 'the printed bill breaks the taxes out');
my $pdf = read_file("$root/lib/JawnOS/PDF/Store.pm");
like($pdf, qr/tax_exemption/, 'the PDF prints the exemption');
my $configure_js = read_file("$root/public/js/manager/configure/03_platform_misc.js");
like($configure_js, qr/sales_tax_enabled/, 'the Configure JS saves the Store switch');

# --- cash rounding: auto CAD, travel, explicit steps ----------------------
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::cash_rounding_home_currency = sub { 'CAD' };
	local *subs::setting_grabber = sub { return undef if (($_[0]->{'setting'} // '') eq 'cash_rounding'); return ''; };
	my $s = subs::cash_rounding_setting();
	is($s->{'setting'}, 'auto', 'the default cash rounding is auto');
	is($s->{'step'}, 0.05, 'auto rounds a CAD house to five cents');
	my $down = subs::cash_rounding_apply(10.02, 'CAD');
	is($down->{'rounded'}, 10.00, '10.02 rounds down to 10.00');
	is($down->{'rounding'}, -0.02, 'the rounding difference is recorded');
	is(subs::cash_rounding_apply(10.03, 'CAD')->{'rounded'}, 10.05, '10.03 rounds up to 10.05');
	is(subs::cash_rounding_apply(-10.02, 'CAD')->{'rounded'}, -10.00, 'a refund rounds symmetrically');
	is(subs::cash_rounding_apply(10.02, 'USD')->{'step'}, 0, 'a USD payment is never rounded');
}
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::cash_rounding_home_currency = sub { 'USD' };
	local *subs::setting_grabber = sub { return undef if (($_[0]->{'setting'} // '') eq 'cash_rounding'); return ''; };
	is(subs::cash_rounding_setting()->{'step'}, 0, 'auto leaves a USD house at the cent');
}
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::cash_rounding_home_currency = sub { 'CAD' };
	local *subs::setting_grabber = sub { return 'off' if (($_[0]->{'setting'} // '') eq 'cash_rounding'); return ''; };
	is(subs::cash_rounding_setting()->{'step'}, 0, 'off turns cash rounding off');
}
{
	local *subs::warranty_device = sub { 'all' };
	local *subs::cash_rounding_home_currency = sub { 'CAD' };
	local *subs::setting_grabber = sub { return '0.10' if (($_[0]->{'setting'} // '') eq 'cash_rounding'); return ''; };
	is(subs::cash_rounding_setting()->{'step'}, 0.10, 'an explicit ten-cent step is kept');
}

# --- a cash register sale rounds; a card sale is exact --------------------
{
	local *subs::cash_rounding_home_currency = sub { 'CAD' };
	local *subs::cash_rounding_setting = sub { { setting => '0.05', home_currency => 'CAD', step => 0.05 } };
	my $order = {
		items => [ { name => 'x', price => 10.02, quantity => 1 } ],
		customer => { app => 'Customer' },
		tax_exemption => { exempt => 0 },
	};
	my $tax_off = { enabled => 0, default_codes => [], catalog => [], countries => [] };
	my $cash = subs::store_register_sale_data($order, 'cash', 20, 'Customer', '', $tax_off, { exempt => 0 });
	is($cash->{'data'}->{'numbers'}->{'rounding'}, -0.02, 'a cash sale records its rounding');
	is($cash->{'data'}->{'numbers'}->{'total'}, 10.00, 'the cash total is the rounded figure');
	is($cash->{'data'}->{'numbers'}->{'cash_total'}, 10.00, 'the cash total rides beside the exact total');
	is($cash->{'change'}->{'change'}, 10.00, 'change is worked from the rounded total');
	my $card = subs::store_register_sale_data($order, 'credit', 20, 'Customer', '', $tax_off, { exempt => 0 });
	is($card->{'data'}->{'numbers'}->{'rounding'}, 0, 'a card sale is not rounded');
	is($card->{'data'}->{'numbers'}->{'total'}, 10.02, 'a card sale keeps the exact total');
}

# --- the UI and the printed bill are wired --------------------------------
my $store_tax_ui = read_file("$root/templates/configure/store_setting_list.html.ep");
like($store_tax_ui, qr/store_cash_rounding/, 'the Store panel has the cash-rounding picker');
my $register_js = read_file("$root/public/js/store/register.js");
like($register_js, qr/storeRegisterCashTotal/, 'the till rounds a cash total');
my $transaction_ui = read_file("$root/templates/apps/app_details.html.ep");
like($transaction_ui, qr/tx_rounding/, 'the transaction shows its cash rounding');
my $transaction_js = read_file("$root/public/js/manager/transaction.js");
like($transaction_js, qr/txCashRounding/, 'the transaction JS knows the cash step');
my $paper = read_file("$root/templates/store/printer/header.html.ep");
like($paper, qr/paper_rounding/, 'the printed bill carries the rounding');
my $pdf = read_file("$root/lib/JawnOS/PDF/Store.pm");
like($pdf, qr/labels->\{'rounding'\}/, 'the PDF labels the rounding row');


done_testing();
