# tests-for: lib/JawnOS/Domain/Store.pm lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Controller/store_misc.pm lib/JawnOS/Controller/manager_store.pm
# covers:    The house document series starts at 1001, a quote has its own
#           series, an offline block hands out its own range and never overlaps
#           the hub, and a document is one line or many without changing the
#           shape the printer, the list and the stock journal read.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

# The test database is a copy of the live house; this version's migration may
# not have run on it yet, so make the two new tables here.
&subs::db_query('create table if not exists numbering (uuid VARCHAR(255) unique, series VARCHAR(50) unique, next_number INTEGER, block_size INTEGER, timestamp VARCHAR(25), server_time VARCHAR(500), ost VARCHAR(25))');
&subs::db_query('create table if not exists number_blocks (uuid VARCHAR(255) unique, series VARCHAR(50), device VARCHAR(255), from_number INTEGER, to_number INTEGER, used INTEGER, timestamp VARCHAR(25), server_time VARCHAR(500), ost VARCHAR(25))');
&subs::db_query("delete from numbering where series in ('invoice','quote')");
&subs::db_query("delete from number_blocks where series in ('invoice','quote')");

# This machine is the authority for the local mint; the relay path is covered
# by the route's own source and is not asked to find a peer here.
local $subs::config = { %{ $subs::config || {} }, device => 'server' };

my $first = &subs::store_numbering_mint_local('invoice');
is($first->{'number'}, 1001, 'the first invoice number is 1001');
is($first->{'id'}, '1001', 'and prints plainly');
my $second = &subs::store_numbering_mint_local('invoice');
is($second->{'number'}, 1002, 'the next is 1002');

my $quote = &subs::store_numbering_mint_local('quote');
is($quote->{'id'}, 'Q-1001', 'quotes are their own series, labelled Q-');

# A block reserves a range and advances the counter past it, so the hub cannot
# hand one of those numbers to another device.
my $block = &subs::store_numbering_block_reserve_local('invoice', 'device-a', 100);
is($block->{'from'}, 1003, 'a block starts at the counter');
is($block->{'to'}, 1102, 'and covers one hundred numbers');
my $after = &subs::store_numbering_mint_local('invoice');
is($after->{'number'}, 1103, 'the hub never hands out a number inside a reserved block');

# The device's own block hands out its range locally, in order, once each.
my $sig = &subs::signatorial_designer();
&subs::db_insert('number_blocks', {
	uuid => &subs::random_string_creator(20),
	series => 'invoice',
	device => $sig,
	from_number => 2000,
	to_number => 2002,
	used => 2000,
	timestamp => &subs::rightNow(),
	server_time => &subs::rightNow(),
});
my @taken = map { &subs::store_numbering_block_take('invoice') } (1 .. 3);
is_deeply([ map { $_->{'number'} } @taken ], [2000, 2001, 2002], 'the block hands out its range in order');
ok(!defined &subs::store_numbering_block_take('invoice'), 'an exhausted block hands out nothing');
is(&subs::store_numbering_block_remaining('invoice'), 0, 'and reports nothing left');

# One line or many: the old quote, the new cart and a register sale all answer
# through the same reader.
my $single = { item => 'widget', model => { name => 'Widget', price => 10, quantity => 2 }, options => {} };
is(scalar @{ &subs::store_document_lines($single) }, 1, 'an old quote is one line');
my $multi = { lines => [
	{ item => 'a', model => { name => 'A', price => 1, quantity => 1 }, options => {} },
	{ item => 'b', model => { name => 'B', price => 2, quantity => 3 }, options => {} },
]};
is(scalar @{ &subs::store_document_lines($multi) }, 2, 'a cart is its lines');
is(&subs::store_document_item_label($multi), 'A ' . chr(0xb7) . ' B', 'the label joins the line names');
my $stock = &subs::store_document_stock_lines($multi);
is($stock->[0]->{'item'}, 'a', 'the first stock line names its own store item');
is($stock->[1]->{'quantity'}, 3, 'and keeps its own quantity');
my $sale = { register => { items => [ { item => 'x', name => 'X', price => 3, quantity => 2, total => 6 } ] } };
my $sale_lines = &subs::store_document_stock_lines($sale);
is($sale_lines->[0]->{'item'}, 'x', 'a register sale moves the store item, not its display name');
is($sale_lines->[0]->{'quantity'}, 2, 'and its own quantity');

# The migration seeds both series at 1001.
my $migrations = read_file(root() . '/lib/JawnOS/Domain/Migrations.pm');
like($migrations, qr/'numbering:invoice', 'invoice', 1001/, 'the migration seeds invoices at 1001');
like($migrations, qr/'numbering:quote', 'quote', 1001/, 'and quotes separately');

done_testing();
