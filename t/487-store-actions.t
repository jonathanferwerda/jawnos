# tests-for: perl/gb/03_engines_and_tools.pl perl/help/topics_business.pl lib/JawnOS/Routes.pm
# covers:    The Store's app-action family: `find` and `orders` are read-only
#           GETs that name routes the server actually dispatches, the store
#           help topic belongs to the store app, and each speech reads only the
#           JSON answer it is given - the count, up to three item prices, the
#           open order count and their total - without dying on a missing or
#           malformed field.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

require './perl/gb/03_engines_and_tools.pl';
require './perl/help.pl';
require 'JawnOS/Routes.pm';

# ------------------------------------------------------------ the registry
my %by_do;
foreach my $a ( @gb::app_actions ) {
	next unless (($a->{'app'} // '') eq 'store');
	$by_do{ $a->{'do'} } = $a;
}
is_deeply([ sort keys %by_do ], [ 'find', 'orders' ], 'the Store declares find and orders');

foreach my $do ( sort keys %by_do ) {
	my $a = $by_do{$do};
	is($a->{'kind'}, 'read', "store $do is a read");
	is(lc($a->{'method'}), 'get', "store $do uses GET");
	my $r = JawnOS::Routes->lookup($a->{'method'}, $a->{'route'});
	ok($r, "store $do names a route the server dispatches");
	like(($r->{'action'} // ''), qr/^action_\d+$/, "store $do resolves to a controller action") if $r;
	ok(ref $a->{'speech'} eq 'CODE', "store $do can speak its result");
}

is(help::get('store')->{'app'}, 'store', 'the store help topic belongs to the store app');

# ------------------------------------------------------------ find
my $find = $by_do{'find'} or BAIL_OUT('no store find entry');
my $said = $find->{'speech'}->({ items => [
	{ name => 'Coffee', price => '4.50' },
	{ name => 'Tea',    price => '3.00' },
]});
like($said, qr/\b2 items\b/, 'find counts two items');
like($said, qr/Coffee at 4\.50/, 'find names an item and its price');

$said = $find->{'speech'}->({ items => [] }, { search => 'zzz' });
like($said, qr/Nothing in the Store/, 'an empty find says nothing was found');
like($said, qr/"zzz"/, 'and repeats what was searched for');

$said = $find->{'speech'}->({ items => [ { name => 'Only' } ] });
like($said, qr/\b1 item\b/, 'find says one item, singular');
unlike($said, qr/ at /, 'an item with no price is named without one');

$said = $find->{'speech'}->();
ok(defined $said && length $said, 'find survives a missing answer');

# ------------------------------------------------------------ orders
my $orders = $by_do{'orders'} or BAIL_OUT('no store orders entry');
$said = $orders->{'speech'}->({ orders => [] });
like($said, qr/register is clear/i, 'an empty register says it is clear');

$said = $orders->{'speech'}->({ orders => [
	{ totals => { total => 5.25 } },
	{ totals => { total => 4.75 } },
]});
like($said, qr/\b2 orders are open\b/, 'orders counts the open orders');
like($said, qr/10\.00/, 'orders sums the open totals');

$said = $orders->{'speech'}->({ orders => [ { totals => { total => 7 } } ] });
like($said, qr/\b1 order is open\b/, 'one order reads as a single order');

$said = $orders->{'speech'}->({ orders => [ {} ] });
like($said, qr/\b1 order is open\b/, 'an order with no totals still counts');
unlike($said, qr/total/i, 'and is not given a made-up total');

$said = $orders->{'speech'}->();
ok(defined $said && length $said, 'orders survives a missing answer');

done_testing();
