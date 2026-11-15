# tests-for: lib/JawnOS/Domain/Store.pm lib/JawnOS/Controller/manager_store.pm lib/JawnOS/Routes/manager_store.pm templates/configure/store_setting_list.html.ep public/js/manager/configure/03_platform_misc.js
# covers:    Configure -> Store's Document numbers card: the next invoice and
#           quote, the device's remaining offline block, the authority's own
#           view, and the one button that asks the hub for another block.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

&subs::db_query('create table if not exists numbering (uuid VARCHAR(255) unique, series VARCHAR(50) unique, next_number INTEGER, block_size INTEGER, timestamp VARCHAR(25), server_time VARCHAR(500), ost VARCHAR(25))');
&subs::db_query('create table if not exists number_blocks (uuid VARCHAR(255) unique, series VARCHAR(50), device VARCHAR(255), from_number INTEGER, to_number INTEGER, used INTEGER, timestamp VARCHAR(25), server_time VARCHAR(500), ost VARCHAR(25))');
&subs::db_query("delete from numbering where series in ('invoice','quote')");
&subs::db_query("delete from number_blocks where series in ('invoice','quote')");

# The authority mints every number and has no block of its own. Change only
# the device key: replacing the config hash loses the harness's database path.
my $original_device = $subs::config->{'device'};
$subs::config->{'device'} = 'server';
my $minted = &subs::store_numbering_mint_local('invoice');
is($minted->{'number'}, 1001, 'the authority mints the first invoice');
my $status = &subs::store_numbering_status();
ok($status->{'authority'}, 'a server is the numbering authority');
is($status->{'series'}->{'invoice'}->{'next_id'}, '1002', 'a minted number moves the card on');
is($status->{'series'}->{'quote'}->{'next_id'}, 'Q-1001', 'the next quote is Q-1001');
is($status->{'series'}->{'invoice'}->{'remaining'}, 0, 'the authority holds no offline block');

# A device reports the block it owns, and only that block.
$subs::config->{'device'} = 'computer';
my $sig = &subs::signatorial_designer();
&subs::db_insert('number_blocks', {
	uuid => &subs::random_string_creator(20), series => 'invoice', device => $sig,
	from_number => 5000, to_number => 5099, used => 5000,
	timestamp => &subs::rightNow(), server_time => &subs::rightNow(),
});
my $device = &subs::store_numbering_status();
ok(!$device->{'authority'}, 'a non-server machine reads a block');
is($device->{'series'}->{'invoice'}->{'remaining'}, 100, 'the block reports all one hundred left');
is($device->{'series'}->{'quote'}->{'remaining'}, 0, 'and a series with no block reports none');
&subs::store_numbering_block_take('invoice');
my $after = &subs::store_numbering_status();
is($after->{'series'}->{'invoice'}->{'remaining'}, 99, 'using a number lowers the count');
$subs::config->{'device'} = $original_device;

my $template = read_file(root() . '/templates/configure/store_setting_list.html.ep');
like($template, qr/store_numbering_card/, 'the Store panel draws the numbering card');
like($template, qr/store_numbering_reserve/, 'and offers the reserve button');

my $js = read_file(root() . '/public/js/manager/configure/03_platform_misc.js');
like($js, qr{/manager/store/number_reserve}, 'the button calls the reserve route');

my $routes = read_file(root() . '/lib/JawnOS/Routes/manager_store.pm');
like($routes, qr{\[6423, 'post', '/manager/store/number_reserve', 'action_6423'\]}, 'the route is registered');
my $controller = read_file(root() . '/lib/JawnOS/Controller/manager_store.pm');
like($controller, qr/sub action_6423\b/, 'and the action exists');

done_testing();
