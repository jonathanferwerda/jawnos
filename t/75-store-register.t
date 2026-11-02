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

# The Store's Register is a cash till, not a customer page. A walk-in has no
# account: the order is kept in the manager's memory, and only a paid order is
# written as a sale. These checks pin the money, the independent tabs, the
# receipt payload and the labels; nothing here touches the live database.

# ------------------------------------------------------------- an anonymous order
&subs::store_register_order_reset();
my $order = &subs::store_register_order_open();
is( $order->{'customer'}->{'app'}, 'Customer', 'a walk-in is simply Customer' );
ok( length($order->{'id'} || ''), 'the order has its own id so nobody has to be known' );

&subs::store_register_order_add($order->{'id'}, { item => 'widget', name => 'Widget', price => 10, quantity => 1 });
&subs::store_register_order_add($order->{'id'}, { item => 'gizmo',  name => 'Gizmo',  price => 5,  quantity => 2 });

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
is( scalar @{$order->{'items'}}, 2, 'the same item at the same price is one line' );
is( $order->{'items'}->[0]->{'quantity'}, 2, 'and its quantity went up' );
&subs::store_register_order_quantity($order->{'id'}, $order->{'items'}->[0]->{'line'}, 1);
is( $order->{'items'}->[0]->{'quantity'}, 1, 'a quantity can be typed back down' );

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
&subs::store_register_order_add($second->{'id'}, { item => 'b', name => 'B', price => 7, quantity => 2 });

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
is( sprintf('%.2f', $built->{'data'}->{'numbers'}->{'total'}), '15.82', 'the sale total is recomputed by the server' );
is( sprintf('%.2f', $built->{'data'}->{'payments'}->[0]->{'change'}), '4.18', 'the change is on the receipt payment' );
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
my $register_src = read_file('templates/store/register.html.ep');
my $rendered = eval { Mojo::Template->new(vars => 1)->name('store/register.html.ep')->render($register_src, { cx => '' }) };
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
my $routes = read_file('lib/JawnOS/Routes/manager_store.pm');
like( $routes, qr{\[6411, 'get', '/manager/store/register', 'action_6411'\]}, 'the register has its own route' );
like( $routes, qr{\[6419, 'post', '/manager/store/register/sale', 'action_6419'\]}, 'the sale route is registered' );
like( $routes, qr{\[6420, 'get', '/manager/store/register/receipt', 'action_6420'\]}, 'the receipt can be reopened' );

my $controller = read_file('lib/JawnOS/Controller/manager_store.pm');
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

done_testing();
