# tests-for: perl/gb/03_engines_and_tools.pl perl/gb/09_voice_actions_house.pl lib/JawnOS/Routes/manager_clock.pm lib/JawnOS/Routes/manager_misc6.pm lib/JawnOS/Routes/manager_transaction2.pm lib/JawnOS/Routes/manager_budget.pm lib/JawnOS/Routes/manager_budget2.pm lib/JawnOS/Routes/manager_misc.pm lib/JawnOS/Routes/manager_misc5.pm
# covers:    The house-side actions voice was missing: the clock's alarm and
#           timer, the tasks list/add/tick, a recorded spend and an account
#           balance, a bill and the runway, the warehouse shelf and an app's
#           inventory. Every entry names a route the server dispatches, a kind
#           and method that agree, an app-scoped help topic, a speech sub and a
#           parameter map whose required fields are declared.

use strict;
use warnings;
use utf8;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use JawnOSTest;

require './perl/gb/03_engines_and_tools.pl';
my $base = scalar @gb::app_actions;
require './perl/gb/09_voice_actions_house.pl';
require './perl/help.pl';
require 'JawnOS/Routes.pm';

my %mine_key = map { $_ => 1 } qw(clock/alarm clock/timer tasks/list tasks/add tasks/tick budget/record_spend budget/account_balance budget/record_payable budget/runway warehouse/on_hand warehouse/stock_in inventory/usage);
my @mine = grep { $mine_key{ ($_->{'app'} // '') . '/' . ($_->{'do'} // '') } } @gb::app_actions;
ok(scalar @mine, 'the house actions file declares entries');

# ------------------------------------------------------------ every entry
my %route = map { lc($_->[1]) . ' ' . $_->[2] => $_->[3] } @{ JawnOS::Routes->table };
my %topic_app = map { (help::get($_->{'id'})->{'app'} // '') => 1 } help::catalogue();
my %seen;
foreach my $a ( @mine ) {
	my $label = $a->{'app'} . ' ' . $a->{'do'};
	ok(!$seen{$label}++, $label . ' is declared once');
	ok(defined $a->{'desc'} && length $a->{'desc'}, $label . ' has a description');
	my $key = lc($a->{'method'} // '') . ' ' . ($a->{'route'} // '');
	ok($route{$key}, $label . ' names a real route');
	like($a->{'kind'} // '', qr/^(?:read|write)$/, $label . ' has a known kind');
	is(lc($a->{'method'} // ''), ($a->{'kind'} // '') eq 'read' ? 'get' : 'post',
		$label . ' uses the method its kind requires');
	ok($topic_app{ $a->{'app'} }, $label . ' names an app with a help topic');
	ok(ref $a->{'speech'} eq 'CODE', $label . ' can speak its result');
	like($a->{'confirm'} // '', qr/\S/, $label . ' carries a confirmation')
		if ($a->{'kind'} // '') eq 'write';
	is(ref $a->{'params'}, 'HASH', $label . ' declares a parameter map');
	foreach my $p ( sort keys %{ $a->{'params'} || {} } ) {
		like($p, qr/^[a-z][a-z0-9_]*$/, $label . ' parameter name is a plain key');
	}
	foreach my $r ( sort keys %{ $a->{'required'} || {} } ) {
		ok($a->{'params'}->{$r}, $label . ' declares required parameter ' . $r);
	}
	my $said = eval { $a->{'speech'}->({}, {}) };
	ok(defined $said && length $said, $label . ' speaks a sentence from an empty answer');
}

# ------------------------------------------------------------ the families
my %by;
$by{ $_->{'app'} . '/' . $_->{'do'} } = $_ for @mine;

sub entry_is {
	my ($key, $kind, $method, $path, $name) = @_;
	my $a = $by{$key};
	ok($a, $name . ' is declared') or return;
	is($a->{'kind'}, $kind, $name . ' is a ' . $kind);
	is(lc($a->{'method'}), $method, $name . ' uses ' . uc($method));
	is($a->{'route'}, $path, $name . ' names ' . $path);
	is(ref $a->{'params'}, 'HASH', $name . ' declares parameters');
	return $a;
}

# Clock: the read lives in 03; these are the alarm edit and a timer.
my $alarm = entry_is('clock/alarm', 'write', 'post', '/manager/clock/alarm', 'clock alarm');
for my $p ( qw(action uuid hour minute days label enabled) ) {
	ok($alarm->{'params'}->{$p}, 'clock alarm declares ' . $p);
}
ok($alarm->{'required'}->{'action'}, 'clock alarm requires the action');
my $timer = entry_is('clock/timer', 'write', 'post', '/manager/clock/timer', 'clock timer');
for my $p ( qw(action hours minutes seconds label uuid) ) {
	ok($timer->{'params'}->{$p}, 'clock timer declares ' . $p);
}

# Tasks: one list, one add, one tick, all on the same two-verb route.
my $tlist = entry_is('tasks/list', 'read', 'get', '/manager/tasks', 'tasks list');
is_deeply([ sort keys %{ $tlist->{'params'} } ], [ 'app', 'timestamp' ], 'tasks list reads an app');
ok($tlist->{'required'}->{'app'}, 'tasks list requires the app');
my $tadd = entry_is('tasks/add', 'write', 'post', '/manager/tasks', 'tasks add');
for my $p ( qw(app uuid name value) ) {
	ok($tadd->{'params'}->{$p}, 'tasks add declares ' . $p);
	ok($tadd->{'required'}->{$p}, 'tasks add requires ' . $p);
}
my $ttick = entry_is('tasks/tick', 'write', 'post', '/manager/tasks', 'tasks tick');
for my $p ( qw(app uuid name value) ) {
	ok($ttick->{'params'}->{$p}, 'tasks tick declares ' . $p);
}
for my $p ( qw(app uuid name value) ) {
	ok($ttick->{'required'}->{$p}, 'tasks tick requires ' . $p);
}

# Money: the spend is a transaction; the balance is the budget's account view.
my $spend = entry_is('budget/record_spend', 'write', 'post', '/manager/transaction/record', 'money record_spend');
for my $p ( qw(app account movement total vendor) ) {
	ok($spend->{'params'}->{$p}, 'money record_spend declares ' . $p);
}
for my $p ( qw(app account movement total) ) {
	ok($spend->{'required'}->{$p}, 'money record_spend requires ' . $p);
}
my $balance = entry_is('budget/account_balance', 'read', 'get', '/manager/budget', 'money account_balance');
is_deeply([ sort keys %{ $balance->{'params'} } ], [ 'accounts', 'display', 'timestamp' ], 'money account_balance reads the account view');
ok($balance->{'required'}->{'display'}, 'money account_balance requires the display');
ok($balance->{'required'}->{'accounts'}, 'money account_balance requires the accounts');

# Budget: a payable write and the runway read.
my $payable = entry_is('budget/record_payable', 'write', 'post', '/manager/budget/payable/add', 'budget record_payable');
for my $p ( qw(vendor total app item tax date repeat) ) {
	ok($payable->{'params'}->{$p}, 'budget record_payable declares ' . $p);
}
ok($payable->{'required'}->{'vendor'}, 'budget record_payable requires the vendor');
ok($payable->{'required'}->{'total'}, 'budget record_payable requires the total');
my $runway = entry_is('budget/runway', 'read', 'get', '/manager/budget', 'budget runway');
ok($runway->{'params'}->{'display'}, 'budget runway declares the display');
ok($runway->{'required'}->{'display'}, 'budget runway requires the display');

# Warehouse: on hand and stock in.
my $onhand = entry_is('warehouse/on_hand', 'read', 'get', '/manager/warehouse/on_hand', 'warehouse on_hand');
ok($onhand->{'params'}->{'item'}, 'warehouse on_hand declares the item');
ok($onhand->{'required'}->{'item'}, 'warehouse on_hand requires the item');
my $stockin = entry_is('warehouse/stock_in', 'write', 'post', '/manager/warehouse/stock_in', 'warehouse stock_in');
for my $p ( qw(item place quantity reason) ) {
	ok($stockin->{'params'}->{$p}, 'warehouse stock_in declares ' . $p);
}
for my $p ( qw(item place quantity) ) {
	ok($stockin->{'required'}->{$p}, 'warehouse stock_in requires ' . $p);
}

# Inventory: the app's details route.
my $usage = entry_is('inventory/usage', 'read', 'get', '/manager/inventory/details', 'inventory usage');
ok($usage->{'params'}->{'app'}, 'inventory usage declares the app');
ok($usage->{'required'}->{'app'}, 'inventory usage requires the app');

# ------------------------------------------------------------ speech shapes
like($alarm->{'speech'}->({ error => 'full' }, { action => 'add' }),
	qr/ten alarms/, 'an alarm refusal names the limit');
is($alarm->{'speech'}->({ ok => 1 }, { action => 'add' }), 'The alarm is set.',
	'an alarm add speaks success');
like($alarm->{'speech'}->({ ok => 1 }, { action => 'delete' }), qr/removed that alarm/,
	'an alarm delete speaks removal');

like($timer->{'speech'}->({ error => 'time' }, { action => 'start' }),
	qr/timer length is not valid/, 'a bad timer length says so');
like($timer->{'speech'}->({ ok => 1 }, { action => 'start' }), qr/timer is running/,
	'a started timer says it is running');
like($timer->{'speech'}->({ ok => 1 }, { action => 'stop' }), qr/timer is stopped/,
	'a stopped timer says so');

like($tlist->{'speech'}->({ tasks => [
	{ uuid => 'a', completed => 'off' },
	{ uuid => 'b', completed => 'on' },
	{ uuid => 'new' },
] }, { app => 'water' }), qr/2 tasks for water, 1 open, 1 done/,
	'tasks list counts the real rows and skips the new-task blank');
like($tlist->{'speech'}->({ tasks => [ { uuid => 'new' } ] }, { app => 'water' }),
	qr/no tasks for water/, 'an empty checklist says so');

like($tadd->{'speech'}->({}, { value => 'milk' }), qr/added "milk" to the list/,
	'tasks add names the task');
like($ttick->{'speech'}->({}, { value => 'on' }), qr/ticked that task off/,
	'a tick speaks the tick');
like($ttick->{'speech'}->({}, { value => 'off' }), qr/opened that task again/,
	'an untick speaks the reopen');

like($spend->{'speech'}->({ uuid => 'x' }, { vendor => 'the store', total => '12' }),
	qr/recorded the spend for the store/, 'a spend names the vendor');
like($spend->{'speech'}->({ error => 'no account' }, {}), qr/could not record the spend.*no account/,
	'a refused spend reports the error');

like($balance->{'speech'}->({ reports => { activity => [
	{ app => 'cash', closing => 120.5 },
	{ app => 'bank', closing => 300 },
] } }, {}), qr/cash at 120\.50, bank at 300\.00/,
	'the balance names each account and its closing figure');
like($balance->{'speech'}->({ reports => { activity => [] } }, {}), qr/could not read the balance/,
	'an empty account view says it could not read');

like($payable->{'speech'}->({ ok => 1, uuid => 'x' }, { vendor => 'hydro' }),
	qr/recorded the bill for hydro/, 'a bill names the vendor');
like($payable->{'speech'}->({ ok => 1, scheduled => 1 }, {}), qr/repeating bill/,
	'a repeating bill says it was scheduled');

like($runway->{'speech'}->({ runway => { held => 500, available => 300 } }, {}),
	qr/hold 500\.00, with 300\.00 available/, 'the runway speaks the held and available money');

like($onhand->{'speech'}->({ item => 'milk', on_hand => { each => 12 } }, { item => 'milk' }),
	qr/Milk: 12 each on hand/, 'on hand names the item and its units');
like($onhand->{'speech'}->({ item => 'milk', on_hand => {} }, { item => 'milk' }),
	qr/no milk on hand/, 'an empty shelf says none is on hand');

like($stockin->{'speech'}->({ ok => 1, item => 'milk', quantity => 12, unit => 'each' }, {}),
	qr/added 12 each of milk to the shelf/, 'stock in names the amount and item');
like($stockin->{'speech'}->({ ok => 0, error => 'quantity' }, {}),
	qr/quantity above zero/, 'a refused stock in names the missing fact');

like($usage->{'speech'}->({ app => 'water', total_occurences => 3, total_duration => 5400000 }, {}),
	qr/Water has 3 records and about 1 hour 30 minutes/, 'usage counts records and hours');
like($usage->{'speech'}->({ app => 'water', total_occurences => 0 }, {}),
	qr/no record for water/, 'an app with no records says so');

done_testing();
