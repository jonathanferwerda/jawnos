# tests-for: lib/JawnOS/Controller/manager_store.pm lib/JawnOS/Domain/Crest.pm lib/JawnOS/Domain/Format.pm lib/JawnOS/Domain/Store.pm lib/JawnOS/Routes/manager_store.pm public/js/store/register.js public/js/store/floor.js templates/store/register.html.ep templates/store/floor.html.ep templates/store/store.html.ep public/js/store.js templates/ribbons.html.ep
# covers:    The Store's Register is a cash till, not a customer page; an open
#            order is a row that survives the counter, a name can be put on it,
#            and the floorplan seats orders.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);
use Mojo::Template;
use RepoSource;

binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';

# Every path below is anchored to the tree. Relative reads made the working
# directory an input, and a file the child could not open killed the run before
# its plan with no assertion to read.
my $root = root();

# The Store's Register is a cash till, not a customer page. A walk-in has no
# account: the order is a row, and only a paid order is written as a sale. These
# checks pin the money, the independent tabs, the receipt payload and the
# labels. The test database is a copy of the live house, so a version that has
# not migrated it yet gets the two new tables here.
&subs::db_query('create table if not exists store_order (uuid VARCHAR(255) unique, device VARCHAR(255), label VARCHAR(255), customer_uuid VARCHAR(255), customer_app VARCHAR(255), customer_name VARCHAR(255), tax_exemption LONGTEXT, items LONGTEXT, seat VARCHAR(255), created VARCHAR(25), server_time VARCHAR(255), ost VARCHAR(25))');
&subs::db_query('create table if not exists store_floorplan (uuid VARCHAR(255) unique, name VARCHAR(255), image LONGTEXT, seats LONGTEXT, server_time VARCHAR(255), ost VARCHAR(25))');

# ------------------------------------------------------------- an anonymous order
&subs::store_register_order_reset();
my $order = &subs::store_register_order_open();
is( $order->{'customer'}->{'app'}, 'Customer', 'a walk-in is simply Customer' );
ok( length($order->{'id'} || ''), 'the order has its own id so nobody has to be known' );

&subs::store_register_order_add($order->{'id'}, { item => 'widget', name => 'Widget', price => 10, quantity => 1 });
$order = &subs::store_register_order_add($order->{'id'}, { item => 'gizmo',  name => 'Gizmo',  price => 5,  quantity => 2 });

is( scalar @{$order->{'items'}}, 2, 'two different items make two lines' );

my $tax = 1.13;
my $totals = &subs::store_register_totals($order->{'items'}, $tax);
is( sprintf('%.2f', $totals->{'subtotal'}), '20.00', 'subtotal is the two lines together' );
is( sprintf('%.2f', $totals->{'tax'}),      '2.60',  'tax is charged on the subtotal' );
is( sprintf('%.2f', $totals->{'total'}),    '22.60', 'the running total is 22.60' );
is( $totals->{'quantity'}, 3, 'multiple units are counted, not just lines' );

# Adding the same item at the same price is more units on one line; a different
# price stays its own line so a discount on one unit is not smeared over all.
&subs::store_register_order_add($order->{'id'}, { item => 'widget', name => 'Widget', price => 10, quantity => 1 });
$order = &subs::store_register_order($order->{'id'});
is( scalar @{$order->{'items'}}, 2, 'the same item at the same price is one line' );
is( $order->{'items'}->[0]->{'quantity'}, 2, 'and its quantity went up' );
$order = &subs::store_register_order_quantity($order->{'id'}, $order->{'items'}->[0]->{'line'}, 1);
is( $order->{'items'}->[0]->{'quantity'}, 1, 'a quantity can be typed back down' );

# A saved order is a row, so a reader that never saw the write (another worker,
# a reopened register) still finds the same lines.
my $reread = &subs::store_register_order($order->{'id'});
is( scalar @{$reread->{'items'}}, 2, 'the order reads back from the database' );
is( $reread->{'items'}->[1]->{'name'}, 'Gizmo', 'with its own lines intact' );

# A name on the walk-in: the order keeps who the customer is, and the next read
# agrees, so the sale is written against them.
my $named = &subs::store_register_order_customer($order->{'id'}, {
	cx => 'cx-named', app => 'jane_smith', name => 'Jane Smith',
	tax_exemption => { exempt => 0, id => '', country => 'CA', codes => [] },
});
is( $named->{'customer'}->{'name'}, 'Jane Smith', 'a named customer is on the order' );
my $named_again = &subs::store_register_order($order->{'id'});
is( $named_again->{'customer'}->{'app'}, 'jane_smith', 'and the name survives the read' );
is( $named_again->{'customer'}->{'cx'}, 'cx-named', 'the customer uuid is kept too' );

# A seat is where the order sits, not a second copy of it.
my $seated = &subs::store_register_order_seat($order->{'id'}, 'seat-1');
is( $seated->{'seat'}, 'seat-1', 'an order can be sat at a seat' );
is( &subs::store_register_order($order->{'id'})->{'seat'}, 'seat-1', 'and the seat reads back' );
&subs::store_register_order_seat($order->{'id'}, '');
is( &subs::store_register_order($order->{'id'})->{'seat'}, '', 'taking it off the floor keeps the order' );

# ------------------------------------------------------------------- cash change
my $exact = &subs::store_register_change(22.60, 22.60);
is( sprintf('%.2f', $exact->{'change'}), '0.00', 'exact payment leaves no change' );
ok( $exact->{'exact'}, 'exact payment is named exact' );

my $over = &subs::store_register_change(22.60, 50);
is( sprintf('%.2f', $over->{'change'}), '27.40', 'a fifty for a 22.60 sale gives 27.40 back' );
ok( $over->{'overpaid'}, 'an overpayment is named' );

my $short = &subs::store_register_change(22.60, 20);
is( sprintf('%.2f', $short->{'change'}), '-2.60', 'a short cash payment is negative, never rounded up' );
ok( $short->{'short'}, 'a short payment is named' );
ok( !$short->{'exact'} && !$short->{'overpaid'}, 'and is neither exact nor overpaid' );

my $parts = &subs::store_register_change_breakdown(27.40);
my %pieces = map { $_->{'amount'} => $_->{'count'} } @{$parts};
is( $pieces{20},   1, 'the change starts with a twenty' );
is( $pieces{5},    1, 'and a five' );
is( $pieces{2},    1, 'and a two' );
is( $pieces{0.25}, 1, 'and a quarter' );
is( $pieces{0.10}, 1, 'and a dime' );
is( $pieces{0.05}, 1, 'and a nickel' );
my $sum = 0;
$sum += $_->{'amount'} * $_->{'count'} foreach @{$parts};
is( sprintf('%.2f', $sum), '27.40', 'the pieces add up to the change' );

# ------------------------------------------------- two orders, cancel only one
&subs::store_register_order_reset();
my $first  = &subs::store_register_order_open();
my $second = &subs::store_register_order_open();
&subs::store_register_order_add($first->{'id'},  { item => 'a', name => 'A', price => 3, quantity => 1 });
$second = &subs::store_register_order_add($second->{'id'}, { item => 'b', name => 'B', price => 7, quantity => 2 });

my $second_before = &subs::store_register_totals($second->{'items'}, 1.13)->{'total'};
ok( &subs::store_register_order_cancel($first->{'id'}), 'the first order is given up' );
my $left = &subs::store_register_orders();
is( scalar @{$left}, 1, 'one order is left' );
is( $left->[0]->{'id'}, $second->{'id'}, 'the other customer still has their order' );
is( sprintf('%.2f', &subs::store_register_totals($left->[0]->{'items'}, 1.13)->{'total'}),
	sprintf('%.2f', $second_before), 'and its total did not move' );
ok( !defined &subs::store_register_order($first->{'id'}), 'the cancelled order is gone, not merely hidden' );

# ------------------------------------------------------ the receipt payload
my $built = &subs::store_register_sale_data($second, 'cash', 20, 'Customer', 'TEST-RECEIPT', 1.13);
ok( $built->{'ok'}, 'a paid order builds a sale document' );
is( $built->{'payment'}->{'method'}, 'cash', 'the payment method is carried' );
is( $built->{'data'}->{'payments'}->[0]->{'method'}, 'cash', 'and is on the receipt payment' );
is( sprintf('%.2f', $built->{'data'}->{'numbers'}->{'total'}), '15.80', 'the sale total is recomputed by the server, rounded for cash' );
is( sprintf('%.2f', $built->{'data'}->{'numbers'}->{'rounding'}), '-0.02', 'and the cash rounding is recorded' );
is( sprintf('%.2f', $built->{'data'}->{'payments'}->[0]->{'change'}), '4.20', 'the change is worked from the rounded total' );
is( $built->{'data'}->{'register'}->{'customer'}, 'Customer', 'the receipt names the anonymous customer' );
is( scalar @{$built->{'data'}->{'register'}->{'items'}}, 1, 'the receipt lists the order lines' );
is( $built->{'data'}->{'payments'}->[0]->{'label'}, &subs::lang('common.cash'), 'the method label is a translated core label' );

my $card = &subs::store_register_sale_data($second, 'credit', 0, 'Customer', 'TEST-CARD', 1.13);
is( $card->{'payment'}->{'method'}, 'credit', 'credit is recorded as its own method' );
is( sprintf('%.2f', $card->{'payment'}->{'tendered'}), '15.82', 'a card is charged the total, not a cash amount' );
is( sprintf('%.2f', $card->{'payment'}->{'change'}), '0.00', 'and gives no change' );

# --------------------------------------------------------------- the till labels
my @languages = map { $_->{code} } @language::languages;
is( scalar(@languages), 16, 'the app offers sixteen interface languages' );
my @keys = qw(
	common.customer store.order store.new_order store.cancel_order store.void
	store.payment_method store.complete_sale store.sale_complete store.credit
	store.interac store.bitcoin store.cheque store.change store.received
);
my @missing;
for my $lang (@languages) {
	for my $key (@keys) {
		my $value = $language::catalog{$lang}{$key};
		push @missing, "$lang/$key"
			unless defined $value && length $value && $value ne $key;
	}
}
is_deeply( \@missing, [], 'every till label is written in all sixteen languages' )
	or diag( 'missing: ' . join( ', ', @missing ) );

# ------------------------------------------------------------- the template and JS
my $register_src = read_file("$root/templates/store/register.html.ep");
my $rendered = eval { Mojo::Template->new(vars => 1)->name('store/register.html.ep')->render($register_src, { cx => '', webauthn_available => 0 }) };
ok( defined $rendered && length $rendered, 'the register template renders' ) or diag($@);
like( $rendered || '', qr/id="store_register_complete"/, 'a resident session gets the complete-sale control' );

is_deeply( &subs::store_register_denominations(), [5, 10, 20, 50, 100], 'the till offers five, ten, twenty, fifty and a hundred' );
for my $amount (5, 10, 20, 50, 100) {
	like( $register_src, qr/data-amount="\Q$amount\E"/, "a denomination button exists for \$$amount" );
}
like( $register_src, qr/id="store_register_complete"/, 'the till has a Complete sale button' );
like( $register_src, qr/id="store_register_void"/, 'the till has a Void button' );
like( $register_src, qr/id="store_register_search"/, 'the till can search for an item' );
like( $register_src, qr/id="store_register_receipt"/, 'the till can show a receipt' );

my $js = js_source('js/store/register.js');
like( $js, qr/function storeRegisterChange\b/, 'the client has the same change calculation' );
like( $js, qr/Math\.round\(r \* 100\) - Math\.round\(t \* 100\)/, 'the client calculates change in cents' );
like( $js, qr/function storeRegisterTotals\b/, 'the client shows a running total' );
like( $js, qr{/manager/store/register/sale}, 'the sale is written through the Store route' );
like( $js, qr{/manager/store/register/cancel}, 'voiding is done through the Store route' );
like( $js, qr/store_register_tab/, 'open orders are tabs' );
like( $js, qr/store_register_denomination/, 'the denomination buttons are wired' );

# --------------------------------------------------------------- the route
my $routes = read_file("$root/lib/JawnOS/Routes/manager_store.pm");
like( $routes, qr{\[6411, 'get', '/manager/store/register', 'action_6411'\]}, 'the register has its own route' );
like( $routes, qr{\[6419, 'post', '/manager/store/register/sale', 'action_6419'\]}, 'the sale route is registered' );
like( $routes, qr{\[6420, 'get', '/manager/store/register/receipt', 'action_6420'\]}, 'the receipt can be reopened' );

my $controller = read_file("$root/lib/JawnOS/Controller/manager_store.pm");
like( $controller, qr/sub action_6411 \{/, 'the register action exists' );
like( $controller, qr/template => 'store\/register'/, 'the register action renders the register template' );
like( $controller, qr/template => 'store\/journal'/, 'the customer history still renders the journal' );

is( &subs::tier_needed('/manager/store/register'), 'resident', 'the register asks for a resident session' );
is( &subs::tier_denied('/manager/store/register', 'resident'), 0, 'a resident may open the register' );
is( &subs::tier_denied('/manager/store/register', ''), 1, 'a guest is kept out' );

# Opening the till must not need a customer: the route falls back to Customer
# before it ever looks one up, and an empty lookup keeps that default.
like( $controller, qr/my \$app = 'Customer'/, 'an unknown or absent customer falls back to Customer' );
is( &subs::store_register_order_open()->{'customer'}->{'app'}, 'Customer', 'an order with no customer is still valid' );

&subs::store_register_order_reset();

# ------------------------------------------- /manager/store is a desk opener
# store_maker's window_maker branch returns the window's contents; its other
# branch renders the Store page itself. The action used to render again after
# that, and the unfinished response hung until the watchdog restarted the tree.
require "$root/lib/JawnOS/Controller/manager_store.pm";
{
	package StoreActionProbe;
	sub new { bless { p => { window_maker => $_[1], user_agent => 'probe' }, redirect => undef, rendered => undef }, $_[0] }
	sub param { my ($s,$k)=@_; return $s->{p}->{$k} }
	sub redirect_to { my ($s,$u)=@_; $s->{redirect}=$u; return $s }
	sub render { my ($s,%o)=@_; $s->{rendered}=$o{'text'}; return $s }
	package main;
}
my $direct = StoreActionProbe->new('');
Manager::action_5518($direct);
is($direct->{'redirect'}, '/store', 'a direct /manager/store goes to the store page');
is($direct->{'rendered'}, undef, 'and is not rendered a second time');
{
	no warnings 'redefine';
	local *Manager::store_maker = sub { 'CONTENTS' };
	local *Manager::window_maker = sub { 'WINDOW' };
	my $desk = StoreActionProbe->new('yes');
	Manager::action_5518($desk);
	is($desk->{'redirect'}, undef, 'the desk opener is not redirected');
	is($desk->{'rendered'}, 'WINDOW', 'the desk opener gets the window wrapper');
}

# ------------------------------------ the walk-in and the Manager window
# The privacy policy is a storefront notice: a desk window already stands in the
# house, so it is left out there. It also used to be a sibling of the store shell
# and became a whole column beside it once the window put the contents in a flex
# row; in the footer it can only ever be a line.
my $store_page = read_file("$root/templates/store/store.html.ep");
like($store_page, qr/\$in_manager\s*=\s*\(\s*\(\$window_maker \|\| ''\) eq 'yes'\s*\)/,
	'the Store page knows whether it is drawn in a Manager window');
like($store_page, qr/unless \(\$in_manager\)[\s\S]{0,800}?id="store_privacy"/,
	'the privacy link is left out of a Manager window');
like($store_page, qr/<footer class="store_footer">[\s\S]*?id="store_privacy"[\s\S]*?<\/footer>/,
	'the privacy link rides in the footer, where it cannot become a column');
unlike($store_page, qr{</div>\s*<div id="store_privacy">},
	'the privacy link is no longer a sibling of the store shell');

# A walk-in has no account, and the customer bar is otherwise empty until a
# customer is loaded. Its Register opens the same till the toolbar does.
my $ribbons = read_file("$root/templates/ribbons.html.ep");
like($ribbons, qr/id="store_register_bottom_open"/,
	'the customer bar carries a Register till for a walk-in');
my $store_js = js_source('js/store.js');
like($store_js, qr/\$\('#store_register_bottom_open'\)\.toggle\(!cx_uuid\)/,
	'the bottom Register is offered only while no customer is loaded');
like($store_js, qr/\$\('#store_register_bottom_open'\)\.hide\(\)/,
	'loading a customer steps the bottom Register aside');
like($store_js, qr/\$\('#store_register_bottom_open'\)\.show\(\)/,
	'clearing the customer brings the bottom Register back');
like($js, qr/#store_register_open, #store_register_bottom_open/,
	'both Register buttons open the same till');

# ---------------------------------------------------------------- the floorplan
# A seating plan is a picture and the seats placed on it; a seat is where an
# order sits, and an order is still the register's own row.
&subs::db_query("delete from store_floorplan where uuid = 'store:floorplan'");
my $empty_plan = &subs::store_floorplan();
is(scalar @{ $empty_plan->{'seats'} }, 0, 'a house with no plan has no seats');

&subs::store_floorplan_save({ name => 'Dining room', seats => [] });
my $named_plan = &subs::store_floorplan();
is($named_plan->{'name'}, 'Dining room', 'the room can be named');

my $crowded = &subs::store_floorplan_save({ seats => [
	{ id => 'seat-a', name => 'Table 1', x => 10, y => 20, seats => 4, kind => 'table' },
	{ id => 'seat-a', name => 'Duplicate', x => 30, y => 30, seats => 2, kind => 'table' },
	{ id => 'seat-b', name => 'Window', x => 150, y => -5, seats => 99, kind => 'sofa' },
] });
is(scalar @{ $crowded->{'seats'} }, 2, 'a seat id is kept once');
is($crowded->{'seats'}->[0]->{'name'}, 'Table 1', 'a seat keeps its name');
is($crowded->{'seats'}->[1]->{'x'}, 0, 'a seat placed off the picture is pulled back onto it');
is($crowded->{'seats'}->[1]->{'y'}, 0, 'on both axes');
is($crowded->{'seats'}->[1]->{'kind'}, 'table', 'an unknown kind reads as a table');
is($crowded->{'seats'}->[1]->{'seats'}, 99, 'and covers stay within 99');
is(scalar @{ &subs::store_floorplan()->{'seats'} }, 2, 'the seats read back from the database');
is(&subs::store_floorplan()->{'name'}, 'Dining room', 'and the room keeps its name');

# A seat holds the order, so the same order is at the table and at the till.
my $floor_order = &subs::store_register_order_open({ label => 'Table 1', seat => 'seat-a' });
&subs::store_register_order_add($floor_order->{'id'}, { item => 'a', name => 'A', price => 4, quantity => 1 });
my @on_floor = grep { ($_->{'seat'} || '') eq 'seat-a' } @{ &subs::store_register_orders() };
is(scalar @on_floor, 1, 'a seated order is on the floor');
is($on_floor[0]->{'id'}, $floor_order->{'id'}, 'and it is the same order the till sees');

# Changing the picture does not erase the tables placed on it.
&subs::store_floorplan_save({ image => 'data:image/jpeg;base64,AAAA' });
is(&subs::store_floorplan()->{'image'}, 'data:image/jpeg;base64,AAAA', 'the picture is stored');
is(scalar @{ &subs::store_floorplan()->{'seats'} }, 2, 'and the seats stay on the plan');

# The browser asks the routes that exist, and the page carries the panel.
my $floor_js = js_source('js/store/floor.js');
like($floor_js, qr{/manager/store/register/floor/seat}, 'the floor asks the seat route');
like($floor_js, qr{/manager/store/register/floor/plan}, 'and saves the plan');
my $floor_template = read_file("$root/templates/store/floor.html.ep");
like($floor_template, qr/id="store_floor_plan"/, 'the panel has a place for the room');
like($floor_template, qr/id="store_floor_image_file"/, 'and a field for its picture');
like($floor_template, qr/id="store_floor_seat_name"/, 'and a name for a table');
like($store_page, qr/include 'store\/floor'/, 'the Store page carries the floor panel');

# A walk-in can be named from the register.
my $register_template = read_file("$root/templates/store/register.html.ep");
like($register_template, qr/id="store_register_customer_open"/, 'the order offers Name this customer');
like($register_template, qr/id="store_register_customer_kind"/, 'with a kind to add them as');
like($register_template, qr/id="store_register_customer_new_name"/, 'and a name field');
like($js, qr#/manager/store/register/customer'#, 'the register posts the name to its route');
like($js, qr#/manager/store/register/customer_search'#, 'and searches the house names');

# Reopening the register lands on the tab last used, not on whichever is first.
like($js, qr/store_register_active/, 'the register remembers the active tab');

# The route table and the domain loader name the new helpers.
my $routes = read_file("$root/lib/JawnOS/Routes/manager_store.pm");
like($routes, qr{/manager/store/register/customer_search'.*action_50201}, 'the name search is routed');
like($routes, qr{/manager/store/register/customer'.*action_50202}, 'a name is written by a route');
like($routes, qr{/manager/store/register/floor'.*action_50203}, 'the floor is read by a route');
like($routes, qr{/manager/store/register/floor/plan'.*action_50204}, 'the plan is saved by a route');
like($routes, qr{/manager/store/register/floor/seat'.*action_50205}, 'a seat is sat by a route');
foreach my $name (qw(store_register_order_customer store_register_order_seat store_floorplan store_floorplan_save)) {
	ok(&subs::provides($name), "$name is mapped in the domain loader");
}

# -------------------------------------------------------------- the schema
my $schema_file = read_file("$root/database/schema.sql");
like($schema_file, qr/CREATE TABLE IF NOT EXISTS store_order/, 'the schema has the open order table');
like($schema_file, qr/CREATE TABLE IF NOT EXISTS store_floorplan/, 'and the floorplan table');
my $migrations_file = read_file("$root/lib/JawnOS/Domain/Migrations.pm");
like($migrations_file, qr/create table if not exists store_order/, 'an existing house gains the order table');
like($migrations_file, qr/create table if not exists store_floorplan/, 'and the floorplan table');

done_testing();
