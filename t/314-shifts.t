# tests-for: lib/JawnOS/Domain/Shifts.pm lib/JawnOS/Domain/Loader.pm lib/JawnOS/Controller/manager_store.pm lib/JawnOS/Routes/manager_store.pm lib/JawnOS/Domain/Migrations.pm database/schema.sql templates/store/register.html.ep public/js/store/register.js perl/help/topics_business.pl
# covers:    The Store register's till: a shift opened with a float and an
#            associate, cash sales tied to it, End of day counting the drawer,
#            recording over or short and locking the shift.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Slurp qw(read_file);
use Mojo::JSON qw(decode_json encode_json);
use JawnOSTest;
use RepoSource;

my $root = root();

require "$root/lib/JawnOS/Domain/Shifts.pm";
require "$root/lib/JawnOS/Controller/manager_store.pm";

{ package FakeRows;
  sub new { my ($class, $rows) = @_; return bless { rows => $rows || [] }, $class; }
  sub hashes { return $_[0]->{'rows'}; }
}

# --- the map and the schema ------------------------------------------------
foreach my $name (qw(shift_open shift_current shift_sales shift_expected shift_close shift_report store_shift_required)) {
	ok(subs::provides($name), "$name is mapped in the domain loader");
}

my $schema = read_file("$root/database/schema.sql");
like($schema, qr/CREATE TABLE IF NOT EXISTS store_shift/, 'the schema has a store_shift table');
my $migrations = read_file("$root/lib/JawnOS/Domain/Migrations.pm");
like($migrations, qr/create table if not exists store_shift/, 'an existing house gains the table by migration');

# --- the fixtures ----------------------------------------------------------
my $open_shift = {
	uuid => 'shift-1', device => 'register', associate => 'Ada', associate_uuid => 'person-1',
	opened_at => '1000', closed_at => '', float => '50.00', expected => '', counted => '',
	over_short => '', status => 'open', cash_sales => 0, refunds => 0, notes => '',
};
my $sale_data = sub {
	my ($method, $amount, $shift) = @_;
	return encode_json({
		register => { payment => $method, shift_uuid => $shift },
		payments => [ { method => $method, amount => $amount } ],
		numbers => { total => $amount },
	});
};
my @sales = (
	{ uuid => 'sale-1', type => 'sale', timestamp => '1500', data => $sale_data->('cash',   '20.00', 'shift-1') },
	{ uuid => 'sale-2', type => 'sale', timestamp => '1600', data => $sale_data->('cash',   '-5.00', 'shift-1') },
	{ uuid => 'sale-3', type => 'sale', timestamp => '1700', data => $sale_data->('credit', '100.00', 'shift-1') },
	{ uuid => 'sale-4', type => 'sale', timestamp => '1800', data => $sale_data->('cash',   '3.00', 'shift-2') },
	{ uuid => 'sale-5', type => 'sale', timestamp => '500',  data => $sale_data->('cash',   '7.00', 'shift-1') },
);
my $sales_select = sub {
	my ($table) = @_;
	return FakeRows->new(\@sales) if ($table // '') eq 'appointments';
	return FakeRows->new([]);
};

# --- opening ----------------------------------------------------------------
{
	my $inserted;
	local *subs::db_select = sub { return FakeRows->new([$open_shift]) };
	local *subs::db_insert = sub { $inserted = $_[1]; return 1 };
	my $r = subs::shift_open({ associate => 'Ada', device => 'register' });
	ok(!$r->{'ok'}, 'a second till on the same device is refused');
	like($r->{'error'}, qr/already open/, 'and says a till is already open');
	ok(!defined $inserted, 'nothing is written');
}
{
	my $inserted;
	local *subs::db_select = sub { return FakeRows->new([]) };
	local *subs::db_insert = sub { $inserted = $_[1]; return 1 };
	local *subs::rightNow = sub { return 5000 };
	local *subs::random_string_creator = sub { return 'shift-new' };
	my $r = subs::shift_open({ associate => ' Ada ', device => 'register' });
	ok($r->{'ok'}, 'a till opens when none is open');
	is($r->{'shift'}->{'uuid'}, 'shift-new', 'the shift has its own uuid');
	is($r->{'shift'}->{'associate'}, 'Ada', 'the associate is trimmed and kept');
	is($r->{'shift'}->{'float'}, 0, 'the float defaults to zero');
	is($r->{'shift'}->{'status'}, 'open', 'the shift is open');
	is($r->{'shift'}->{'opened_at'}, 5000, 'the opening time is recorded');
	is($inserted->{'associate'}, 'Ada', 'the row is written with the associate');
	is($inserted->{'device'}, 'register', 'and belongs to the device');
	is($inserted->{'status'}, 'open', 'and is written open');
}
{
	local *subs::db_select = sub { return FakeRows->new([]) };
	local *subs::db_insert = sub { return undef };
	local *subs::random_string_creator = sub { return 'shift-new' };
	my $r = subs::shift_open({ associate => 'Ada', device => 'register', float => '20.00' });
	ok(!$r->{'ok'}, 'a refused insert is reported');
	like($r->{'error'}, qr/could not be recorded/, 'and says the shift was not recorded');
}

# --- what the drawer should hold -------------------------------------------
{
	local *subs::db_select = $sales_select;
	my $expected = subs::shift_expected($open_shift);
	is($expected->{'float'}, 50, 'the float is the starting figure');
	is($expected->{'cash_sales'}, 20, 'only cash sales that belong to the shift count');
	is($expected->{'refunds'}, 5, 'a negative cash amount is a refund');
	is($expected->{'expected'}, 65, 'expected is float plus cash less refunds');

	my @shift_sales = subs::shift_sales($open_shift);
	is(scalar @shift_sales, 3, 'the shift has its three sales, not another shift\'s or an older one');
	is_deeply([ map { $_->{'uuid'} } @shift_sales ], [ 'sale-1', 'sale-2', 'sale-3' ],
		'sales are matched on data.register.shift_uuid');
	is($shift_sales[0]->{'data'}->{'register'}->{'payment'}, 'cash', 'the decoded data travels with the row');
}

# --- counting the drawer and locking the shift ------------------------------
{
	my ($updated_table, $updated, $updated_where);
	local *subs::db_select = sub {
		my ($table) = @_;
		return FakeRows->new([$open_shift]) if ($table // '') eq 'store_shift';
		return $sales_select->($table);
	};
	local *subs::db_update = sub { $updated_table = $_[0]; $updated = $_[1]; $updated_where = $_[2]; return 1 };
	local *subs::rightNow = sub { return 9000 };
	my $closed = subs::shift_close('shift-1', '60.00', 'counted at close');
	ok($closed->{'ok'}, 'End of day closes an open shift');
	is($updated_table, 'store_shift', 'the shift row is updated');
	is($updated->{'status'}, 'closed', 'the shift is locked closed');
	is($updated->{'closed_at'}, 9000, 'the closing time is recorded');
	is($updated->{'counted'}, 60, 'the counted drawer is kept');
	is($updated->{'expected'}, 65, 'expected is float plus cash less refunds');
	is($updated->{'over_short'}, -5, 'over or short is counted less expected');
	is($updated->{'cash_sales'}, 20, 'the cash sales are stored on the shift');
	is($updated->{'refunds'}, 5, 'and its refunds');
	is($updated->{'notes'}, 'counted at close', 'the note is kept');
	is($updated_where->{'uuid'}, 'shift-1', 'only this shift is updated');
	is($closed->{'report'}->{'over_short'}, -5, 'the report comes back with the close');

	local *subs::db_select = sub { return FakeRows->new([ $closed->{'shift'} ]) };
	my $again = subs::shift_close('shift-1', '60.00', '');
	ok(!$again->{'ok'}, 'a second End of day is refused');
	like($again->{'error'}, qr/already closed/, 'because the shift is locked');
}

# --- the Z-report -----------------------------------------------------------
{
	local *subs::db_select = $sales_select;
	my $report = subs::shift_report({ %{$open_shift}, closed_at => '3000', counted => '60.00', over_short => '-5.00', status => 'closed' });
	is($report->{'associate'}, 'Ada', 'the report names the associate');
	is($report->{'float'}, 50, 'it carries the float');
	is($report->{'cash_sales'}, 20, 'it sums the cash sales');
	is($report->{'refunds'}, 5, 'and the refunds');
	is($report->{'expected'}, 65, 'and what the drawer should hold');
	is($report->{'counted'}, 60, 'with the counted drawer');
	is($report->{'over_short'}, -5, 'and the over or short');
	is($report->{'sales'}, 3, 'and the shift\'s sale count');
}

# --- the sale carries the shift --------------------------------------------
sub run_store_sale {
	my (%opt) = @_;
	my %seen;
	no warnings 'redefine';
	local *subs::store_register_order = sub {
		return { id => 'order-1', customer => { app => 'Customer' }, items => [ { name => 'Widget', price => 20, quantity => 1 } ] };
	};
	local *subs::store_register_order_cancel = sub { return 1 };
	local *subs::store_tax_settings = sub { return { catalog => [], enabled => 0 } };
	local *subs::tax_exemption_for = sub { return { exempt => 0, id => '' } };
	local *subs::store_register_sale_data = sub {
		return {
			ok => 1, payment => { method => 'cash' }, change => { short => 0 }, totals => { total => 20 },
			data => {
				register => { items => [], payment => 'cash' },
				payments => [ { method => 'cash', amount => 20 } ],
				numbers => { taxes => [], total => 20 },
			},
		};
	};
	local *subs::store_numbering_mint = sub { return { id => '1001' } };
	local *Manager::appointment_writer = sub {
		my ($c, $row) = @_;
		$seen{'data'} = $row->{'data'};
		return { uuid => 'sale-uuid' };
	};
	local *Manager::store_payment_receipt = sub { return 1 };
	local *Manager::store_printer = sub { return {} };
	local *subs::log_writer = sub { return 1 };
	local *subs::rightNow = sub { return 7000 };
	local *subs::device_setter = sub { return 'register' };
	local *subs::shift_current = sub { return $opt{'shift'} };
	local *subs::store_shift_required = sub { return $opt{'required'} ? 1 : 0 };

	my $c = FakeController->new(id => 'order-1', payment => 'cash', received => '20.00');
	Manager::action_6419($c);
	return ($c, \%seen);
}

{ package FakeController;
  sub new { my ($class, %p) = @_; return bless { params => \%p, rendered => undef }, $class; }
  sub param { my ($s, $k) = @_; return $s->{'params'}{$k}; }
  sub render { my ($s, %o) = @_; $s->{'rendered'} = \%o; return 1; }
  sub render_to_string { return ''; }
}

{
	my ($c, $seen) = run_store_sale(shift => { uuid => 'shift-1' });
	ok($c->{'rendered'}{'json'}{'ok'}, 'a sale with an open till still completes');
	my $data = decode_json($seen->{'data'});
	is($data->{'register'}{'shift_uuid'}, 'shift-1', 'the sale data carries the open shift\'s uuid');
}
{
	my ($c, $seen) = run_store_sale(shift => undef);
	ok($c->{'rendered'}{'json'}{'ok'}, 'a sale with no till still records (legacy)');
	my $data = decode_json($seen->{'data'});
	ok(!exists $data->{'register'}{'shift_uuid'}, 'and carries no shift');
}
{
	my ($c, $seen) = run_store_sale(shift => undef, required => 1);
	ok(!$c->{'rendered'}{'json'}{'ok'}, 'with the setting on, a cash sale needs an open till');
	like($c->{'rendered'}{'json'}{'error'}, qr/no till is open/, 'and says so');
	ok(!defined $seen->{'data'}, 'and no sale is written');
}

# --- the route and the UI ---------------------------------------------------
my $routes = read_file("$root/lib/JawnOS/Routes/manager_store.pm");
like($routes, qr{\[6979, 'post', '/manager/store/shift/open', 'action_6979'\]}, 'the open-till route is registered');
like($routes, qr{\[6980, 'post', '/manager/store/shift/close', 'action_6980'\]}, 'the End of day route is registered');
like($routes, qr{\[6981, 'get', '/manager/store/shift', 'action_6981'\]}, 'the current-shift route is registered');

my $controller = read_file("$root/lib/JawnOS/Controller/manager_store.pm");
like($controller, qr/sub action_6979 \{/, 'the open action exists');
like($controller, qr/sub action_6980 \{/, 'the close action exists');
like($controller, qr/sub action_6981 \{/, 'the current-shift action exists');
like($controller, qr/store_shift_required/, 'the sale honours the till-required setting');

my $template = read_file("$root/templates/store/register.html.ep");
like($template, qr/id="store_register_till_open"/, 'the till bar offers Open till');
like($template, qr/id="store_register_till_eod"/, 'and End of day');
like($template, qr/id="store_register_till_associate"/, 'with an associate field');
like($template, qr/id="store_register_till_float"/, 'and a float field');
like($template, qr/id="store_register_till_counted"/, 'End of day asks for the counted drawer');
like($template, qr/id="store_register_till_report"/, 'and shows the report');

my $js = read_file("$root/public/js/store/register.js");
like($js, qr{/manager/store/shift/open}, 'the till opens through the route');
like($js, qr{/manager/store/shift/close}, 'End of day closes through the route');
like($js, qr{/manager/store/shift'}, 'the bar reads the current shift');
like($js, qr/function storeRegisterTillRefresh\b/, 'the bar refreshes from the server');
like($js, qr/#store_register_till_print/, 'the report can be printed');

# --- the help knows the till ------------------------------------------------
my $help = read_file("$root/perl/help/topics_business.pl");
like($help, qr/Open till records the float/, 'the Store help explains the float and the associate');
like($help, qr/End of day shows what the drawer should hold/, 'and counting the drawer at End of day');
like($help, qr/locks the shift/, 'and that the shift is locked after counting');

done_testing();
