# tests-for: lib/JawnOS/Manager/Part29.pm lib/JawnOS/Manager/Index.pm lib/JawnOS/Manager/Declarations.pm lib/JawnOS/Controller/manager_help.pm lib/JawnOS/Routes/manager_help.pm public/js/manager/help.js public/js/manager/help/03_pending.js public/js/manager/websocket/00_console_router.js templates/apps/help.html.ep
# covers:    The Guide's held-write card. A spoken app write is held in the
#           machine-local cache until a person confirms it; the Guide window
#           lists the live rows for this machine and lets the person press
#           Confirm (run it once, browser path) or Cancel (drop it). The list
#           drops expired rows and rows for an app the Guide cannot see, never
#           exposes the speaking chip, and the reload command tells an open
#           Guide window that the list changed.

use strict;
use warnings;
use utf8;
$| = 1;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use JawnOSTest;
use Mojolicious;
use Mojo::Transaction::HTTP;

require './perl/gb/03_engines_and_tools.pl';
require './perl/help.pl';
require 'JawnOS/Routes.pm';
require 'JawnOS/Manager/Part29.pm';

my $root = JawnOSTest::root();

my $fake_app;
sub fake_controller {
	$fake_app ||= Mojolicious->new(quiet => 1);
	my $tx = Mojo::Transaction::HTTP->new;
	$tx->req->method('GET');
	$tx->req->url->path('/manager/help/pending');
	return $fake_app->build_controller($tx);
}
my $c = fake_controller();

# A clock the test can move, so an expired row can sit beside a live one.
my $clock = subs::rightNow();
{
	local *subs::rightNow = sub { $clock };
	my $now = $clock;

	# Two live held writes, from two different watches (two chips).
	my $id_a = Manager::app_action_pending_store({ chip_id => 'chip-a' },
		{ app => 'market', do => 'add_item', params => { text => 'milk' }, scope_app => 'market' });
	my $id_b = Manager::app_action_pending_store({ chip_id => 'chip-b' },
		{ app => 'market', do => 'add_item', params => { text => 'bread' }, scope_app => 'market' });
	# One whose app the Guide hides here.
	my $id_hidden = Manager::app_action_pending_store({ chip_id => 'chip-c' },
		{ app => 'email', do => 'count', params => { folder => 'inbox' }, scope_app => 'email' });
	# One from before the TTL.
	$clock = $now - 200000;
	my $id_old = Manager::app_action_pending_store({ chip_id => 'chip-d' },
		{ app => 'market', do => 'add_item', params => { text => 'jam' }, scope_app => 'market' });

	# Read fifty seconds later: the two live rows are fresh, the old one is past
	# the two-minute TTL.
	$clock = $now + 50000;
	local *Manager::help_app_visible = sub {
		my ($app) = @_;
		return ($app // '') ne 'email' ? 1 : 0;
	};
	my $list = Manager::app_action_pending_list($c, 'device123');
	ok(ref $list eq 'ARRAY', 'the held writes come back as a list');
	is(scalar @$list, 2, 'only the two live, visible writes are listed');

	my %by_id = map { $_->{'id'} => $_ } @$list;
	ok($by_id{$id_a}, 'the first watch write is listed');
	ok($by_id{$id_b}, 'the second watch write is listed');
	ok(!$by_id{$id_hidden}, 'a write for a hidden app is omitted');
	ok(!$by_id{$id_old}, 'a write older than the TTL is omitted');

	my $a = $by_id{$id_a} || {};
	is($a->{'app'}, 'market', 'the row names its app');
	is($a->{'do'}, 'add_item', 'the row names its action');
	is($a->{'desc'}, 'add an item to the shopping list', 'the row carries the registry description');
	like($a->{'label'} // '', qr/milk/, 'the label carries the main parameter');
	is($a->{'params'}->{'text'}, 'milk', 'the declared parameters ride along');
	ok(!exists $a->{'speaker'}, 'the speaking chip is not exposed');
	unlike(($a->{'label'} // '') . ($a->{'id'} // ''), qr/chip-a/, 'no chip id reaches the browser');
}

# ------------------------------------------------------------ confirm
# The row is deleted before the action runs, so a second press cannot run it
# twice. The executor is localized: this tests the card's wiring, not the route.
my $confirm_id;
{
	local *subs::rightNow = sub { $clock };
	local *Manager::help_app_visible = sub { 1 };
	$confirm_id = Manager::app_action_pending_store({ chip_id => 'chip-confirm' },
		{ app => 'market', do => 'add_item', params => { text => 'tea' }, scope_app => 'market' });
}
my ($seen_action, $seen_opts, $present_at_run);
{
	no warnings 'redefine';
	local *Manager::app_action_execute = sub {
		my ($cc, $action, $opts) = @_;
		$seen_action = $action;
		$seen_opts = $opts;
		my $q = subs::db_query(
			'select count(*) as n from cache where app = ? and context = ? and subcontext = ?',
			'__president', 'app_action_pending', $confirm_id
		);
		my $row = $q ? $q->hash : undef;
		$present_at_run = $row ? $row->{'n'} : -1;
		return { ok => 1, speech => 'Added tea to the shopping list.' };
	};
	local *Manager::help_app_visible = sub { 1 };
	my $r = Manager::app_action_pending_confirm($c, $confirm_id);
	ok($r->{'ok'}, 'a held write can be confirmed');
	is($r->{'observation'}, 'Added tea to the shopping list.', 'the observation is the action speech');
	is($r->{'result'}->{'ok'}, 1, 'the action result rides along');
	is($present_at_run, 0, 'the row is deleted before the action runs');
	is($seen_action->{'confirmed'}, 1, 'the action carries the confirmation flag');
	is($seen_action->{'app'}, 'market', 'the action names the held app');
	is($seen_action->{'do'}, 'add_item', 'the action names the held do');
	is($seen_action->{'params'}->{'text'}, 'tea', 'the held parameter reaches the action');
	is_deeply($seen_opts, {}, 'the browser path, not a voice turn or a resume');
}

{
	no warnings 'redefine';
	local *Manager::app_action_execute = sub { return { ok => 1, speech => 'ran twice' }; };
	my $again = Manager::app_action_pending_confirm($c, $confirm_id);
	ok(!$again->{'ok'}, 'a second confirm does not run the action');
	like($again->{'error'} // '', qr/expired/, 'and reports the proposal as expired');
}

# ------------------------------------------------------------ cancel
{
	local *Manager::help_app_visible = sub { 1 };
	my $id = Manager::app_action_pending_store({ chip_id => 'chip-cancel' },
		{ app => 'market', do => 'add_item', params => { text => 'eggs' }, scope_app => 'market' });
	my $r = Manager::app_action_pending_cancel($c, $id);
	ok($r->{'ok'}, 'a held write can be cancelled');
	my $q = subs::db_query(
		'select count(*) as n from cache where app = ? and context = ? and subcontext = ?',
		'__president', 'app_action_pending', $id
	);
	my $row = $q ? $q->hash : undef;
	is($row ? $row->{'n'} : -1, 0, 'cancel deletes the row');
}

# ------------------------------------------------------------ the routes
my $table = JawnOS::Routes->table;
my %by_key = map { lc($_->[1]) . ' ' . $_->[2] => $_ } @$table;
foreach my $want (
	{ method => 'get', path => '/manager/help/pending', id => 37700, action => 'action_37700' },
	{ method => 'post', path => '/manager/help/pending/confirm', id => 37701, action => 'action_37701' },
	{ method => 'post', path => '/manager/help/pending/cancel', id => 37702, action => 'action_37702' },
) {
	my $row = $by_key{ $want->{'method'} . ' ' . $want->{'path'} };
	ok($row, $want->{'method'} . ' ' . $want->{'path'} . ' is in the route table');
	is($row ? $row->[0] : undef, $want->{'id'}, 'the route index matches the action number');
	is($row ? $row->[3] : undef, $want->{'action'}, 'the route names its action');
	my $src = read_file("$root/lib/JawnOS/Controller/manager_help.pm");
	like($src, qr/^\s*sub\s+\Q$want->{'action'}\E\b/m, 'the controller defines ' . $want->{'action'});
}

# ------------------------------------------------------------ the source shape
my $template = read_file("$root/templates/apps/help.html.ep");
like($template, qr/id="help_pending"/, 'the Guide template has the pending container');

my $pending_js = read_file("$root/public/js/manager/help/03_pending.js");
like($pending_js, qr{/manager/help/pending}, 'the card reads the pending route');
like($pending_js, qr{/manager/help/pending/confirm}, 'the card posts a confirm');
like($pending_js, qr{/manager/help/pending/cancel}, 'the card posts a cancel');

my $router = read_file("$root/public/js/manager/websocket/00_console_router.js");
like($router, qr/helpPendingReload/, 'the console router knows the reload command');

my $help_js = read_file("$root/public/js/manager/help.js");
my ($manifest) = $help_js =~ /\/\* \[\[js-split\]\](.*?)\[\[\/js-split\]\] \*\//s;
like($manifest // '', qr/03_pending\.js/, 'the split manifest names the card part');

done_testing();
