# tests-for: database/schema.sql lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Controller/manager_ws.pm perl/Alarm.pl public/js/manager/windows.js lib/JawnOS/Domain/Misc.pm lib/JawnOS/Domain/Loader.pm
# covers:    window_events records one row per desktop window transition (open,
#            close, minimize, restore), so the clothesline can rebuild a day's
#            window flow instead of reading the one layout snapshot the
#            websockets row keeps. The table arrives both ways - schema.sql for a
#            fresh database, update_database for an existing one; the manager's
#            socket handler inserts a validated frame; the client sends it from
#            the real transitions only; alarm_haircut expires it by warranty;
#            window_events_read/window_events_spans read a day of it back in
#            order; and the table itself rides the sync rail (it has a
#            server_time and is not forbidden) so another machine reads the day
#            too.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Slurp qw(read_file);
use File::Temp qw(tempfile);
use Mojo::SQLite;
use RepoSource;
use JawnOSTest;

my $root = repo_root();
require "$root/lib/JawnOS/Controller/manager_ws.pm";

my @want_columns = qw(
	uuid window_id browser_tab_id device_id app event timestamp server_time
	hostname user_agent room warranty ost
);
my @want_indexes = qw(
	idx1_window_events idx2_window_events idx3_window_events idx4_window_events
	idx5_window_events
);

my $schema = read_file("$root/database/schema.sql");
my @statements = grep { /\S/ } split /;[ \t]*\n/, $schema;

# ---------------------------------------------------------------- a fresh database

my ($fresh_fh, $fresh_file) = tempfile('jawnos-window-fresh-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fresh_fh;
my $fresh_sql = Mojo::SQLite->new('sqlite:' . $fresh_file);
my $fresh = $fresh_sql->db;

my @failed;
for my $i (0 .. $#statements) {
	my $ok = eval { $fresh->query($statements[$i]); 1 };
	push @failed, 'statement ' . ($i + 1) . ': ' . ($@ || 'failed') unless $ok;
}
is_deeply(\@failed, [], 'every schema statement executes') or diag(join("\n", @failed));

my $table = $fresh->query(q{select name from sqlite_master where type = 'table' and name = 'window_events'})->hashes->[0];
ok($table, 'schema.sql creates window_events');

my $columns = $fresh->query('select name from pragma_table_info(?)', 'window_events')->hashes;
is_deeply([ sort map { $_->{'name'} } @{$columns} ], [ sort @want_columns ],
	'window_events carries the documented columns');

my $indexes = $fresh->query(q{select name, sql from sqlite_master where type = 'index' and tbl_name = 'window_events' and name not like 'sqlite_%' order by name})->hashes;
is_deeply([ map { $_->{'name'} } @{$indexes} ], \@want_indexes,
	'window_events has its four indexes');

my %index_sql = map { $_->{'name'} => ($_->{'sql'} || '') } @{$indexes};
like($index_sql{'idx1_window_events'}, qr/\(app,\s*cast\(timestamp as integer\)\)/,
	'the app read is indexed by the cast timestamp');
like($index_sql{'idx2_window_events'}, qr/\(browser_tab_id,\s*cast\(timestamp as integer\)\)/,
	'the tab read is indexed by the cast timestamp');
like($index_sql{'idx3_window_events'}, qr/\(window_id,\s*cast\(timestamp as integer\)\)/,
	'the window read is indexed by the cast timestamp');
like($index_sql{'idx4_window_events'}, qr/cast\(warranty as integer\)/,
	'the warranty cull is indexed by the cast warranty');
like($index_sql{'idx5_window_events'}, qr/\(device_id,\s*cast\(timestamp as integer\)\)/,
	'the device read is indexed by the cast timestamp');

# The indexes only help if the planner matches the expression the queries write.
my $warranty_plan = $fresh->query(
	'explain query plan delete from window_events where cast(warranty as integer) < cast(? as integer)', 0
)->hashes->[0]->{'detail'} || '';
like($warranty_plan, qr/idx4_window_events/, 'the cull query is served by its expression index');

# ---------------------------------------------------------------- an existing database

# The old database is the same schema with the window_events statements taken
# out: what a house that predates this change looks like. update_database has to
# bring the table and its indexes in.
my ($old_fh, $old_file) = tempfile('jawnos-window-old-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $old_fh;
my $old_sql = Mojo::SQLite->new('sqlite:' . $old_file);
my $old = $old_sql->db;
my @old_failed;
for my $statement (@statements) {
	next if $statement =~ /window_events/;
	my $ok = eval { $old->query($statement); 1 };
	push @old_failed, $@ unless $ok;
}
is_deeply(\@old_failed, [], 'the old database builds without window_events');
ok(!$old->query(q{select 1 from sqlite_master where type = 'table' and name = 'window_events'})->hashes->[0],
	'the old database starts without window_events');

my @stat = stat($old_file);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $old_file,
	db          => $old,
	dbh         => $old->dbh,
	sql         => $old_sql,
	pid         => $$,
	dev         => $stat[0],
	ino         => $stat[1],
};

subs::preload('update_database');
eval { &subs::update_database({}) };
ok($old->query(q{select 1 from sqlite_master where type = 'table' and name = 'window_events'})->hashes->[0],
	'update_database creates window_events on an existing database')
	or diag($@ || '');

my $migrated_indexes = $old->query(q{select name from sqlite_master where type = 'index' and tbl_name = 'window_events' and name not like 'sqlite_%' order by name})->hashes;
is_deeply([ map { $_->{'name'} } @{$migrated_indexes} ], \@want_indexes,
	'update_database creates the window_events indexes');

# ---------------------------------------------------------------- an insert round-trips

my $manager_src = read_file("$root/lib/JawnOS/Controller/manager_ws.pm");

ok(defined &Manager::window_event_record, 'the socket handler has a window_event helper');

my $inserted = eval {
	&Manager::window_event_record({
		data => {
			type      => 'window_event',
			event     => 'open',
			app       => 'notes',
			window_id => 'window_1700000000001',
			device_id => 'device-round-trip',
		},
		browser_tab_id => 'tab-round-trip',
		hostname       => 'test-box',
		user_agent     => 'TestAgent/1.0',
	});
};
is($inserted, 1, 'a well-formed open frame is recorded') or diag($@ || '');

my $row = $old->query(q{select * from window_events where window_id = ?}, 'window_1700000000001')->hashes->[0] || {};
is($row->{'event'}, 'open', 'the event round-trips');
is($row->{'app'}, 'notes', 'the app round-trips');
is($row->{'window_id'}, 'window_1700000000001', 'the window id round-trips');
is($row->{'browser_tab_id'}, 'tab-round-trip', 'the tab round-trips');
is($row->{'device_id'}, 'device-round-trip', 'the browser device id round-trips');
is($row->{'hostname'}, 'test-box', 'the hostname round-trips');
is($row->{'user_agent'}, 'TestAgent/1.0', 'the user agent round-trips');
ok(defined $row->{'uuid'} && length $row->{'uuid'}, 'the row has a uuid');
like($row->{'server_time'} || '', qr/\A\d{10,}\z/, 'server_time is an epoch millisecond reading');
is($row->{'timestamp'}, $row->{'server_time'}, 'the event timestamp is the server clock');
ok(!defined $row->{'room'}, 'a tab that never named a room records none');
cmp_ok($row->{'warranty'} || 0, '>', $row->{'server_time'} || 0, 'the warranty is a month ahead');
ok($row->{'ost'} ? 1 : 0, 'ost is stamped for the sync rail');

# A tab that has parked a room names it on its transition.
$old->query(q{insert into websockets (uuid, app, browser_tab_id, room, server_time, timestamp) values (?,?,?,?,?,?)},
	'ws-room-1', 'tab', 'tab-round-trip', 'kitchen', &subs::rightNow(), &subs::rightNow());
&Manager::window_event_record({
	data => { event => 'close', app => 'notes', window_id => 'window_1700000000001' },
	browser_tab_id => 'tab-round-trip',
});
my $closed = $old->query(q{select * from window_events where window_id = ? and event = ?}, 'window_1700000000001', 'close')->hashes->[0] || {};
is($closed->{'room'}, 'kitchen', "a tab's room is recorded with the transition");

# ---------------------------------------------------------------- only the four events

my $before = $old->query('select count(*) as n from window_events')->hashes->[0]->{'n'};
for my $bad (qw(explode openx drag '')) {
	my $ok = eval {
		&Manager::window_event_record({
			data => { event => $bad, app => 'notes', window_id => 'window_1' },
			browser_tab_id => 'tab-round-trip',
		});
	};
	is($ok, 0, "the event '$bad' is refused") or diag($@ || '');
}
is($old->query('select count(*) as n from window_events')->hashes->[0]->{'n'}, $before,
	'no refused frame writes a row');

# A frame with no device id still records, and a device id that is not a plain id
# is stripped rather than dying the handler; the span reader falls back for the
# rows that carry none.
my $no_device = eval { &Manager::window_event_record({
	data => { event => 'open', app => 'notes', window_id => 'window_nodev' },
	browser_tab_id => 'tab-round-trip',
}); };
is($no_device, 1, 'a frame with no device id is still recorded');
my $nodev_row = $old->query(q{select * from window_events where window_id = ?}, 'window_nodev')->hashes->[0] || {};
ok(!defined $nodev_row->{'device_id'} || $nodev_row->{'device_id'} eq '', 'and stores no device id');

my $junk_device = eval { &Manager::window_event_record({
	data => { event => 'open', app => 'notes', window_id => 'window_junkdev', device_id => '<script>' },
	browser_tab_id => 'tab-round-trip',
}); };
is($junk_device, 1, 'a device id with markup is still recorded');
my $junk_row = $old->query(q{select * from window_events where window_id = ?}, 'window_junkdev')->hashes->[0] || {};
is($junk_row->{'device_id'}, 'script', 'the device id is stripped to id characters');

# A malformed frame must never die the socket's message handler.
my @survived;
for my $junk (undef, '', 'nonsense', [], { data => 'not-a-hash' }, { data => {} }) {
	my $ok = eval { &Manager::window_event_record($junk); 1 };
	push @survived, ($ok ? 1 : 0);
}
is_deeply(\@survived, [ (1) x 6 ], 'a malformed frame returns instead of dying');

# ---------------------------------------------------------------- the server dispatch

like($manager_src, qr/elsif \(\(\$data->\{'type'\} \|\| ''\) eq 'window_event'\) \{ eval \{ &window_event_record\(/,
	'the message handler dispatches window_event, and a frame cannot die the socket');
like($manager_src, qr/sub window_event_record \{/, 'the helper lives in the controller');
like($manager_src, qr/&subs::db_insert\('window_events'/, 'the helper inserts into window_events');
like($manager_src, qr/\\A\(\?:open\|close\|minimize\|restore\)\\z/, 'the event is an allowlist');
like($manager_src, qr/ago_calc\('-30d', \$server_time\)/, 'the warranty is the month the sessions keep');

# The device action's route row pins this line (t/204, t/272); the dispatch above
# it must not move it.
my @ws_lines = split /\n/, $manager_src;
like($ws_lines[765] || '', qr{^sub action_766\b},
	'the device action still sits on its route row line');

# ---------------------------------------------------------------- the client transitions

my $windows_js = js_source('js/manager/windows.js');

like($windows_js, qr/function windowEventSend\(event, app, window_id\)/,
	'the client has one window-event sender');
like($windows_js, qr/\$\('#browser'\)\.append\('' \+ response \+ ''\);\s*\n\s*made = 1;\s*\n\s*(\/\/[^\n]*\n\s*)*windowEventSend\('open', app, window_id\);/,
	'a really appended window sends the open event');
like($windows_js, qr/windowEventSend\('minimize', win\.attr\('app'\), win\.attr\('id'\)\)/,
	'minimizing sends the minimize event');
like($windows_js, qr/windowEventSend\('restore', win\.attr\('app'\), win\.attr\('id'\)\)/,
	'a restore sends the restore event');
like($windows_js, qr/windowEventSend\('close', app, win\.attr\('id'\)\)/,
	'the close teardown sends the close event');
like($windows_js, qr/type: 'window_event', event: event, app: app, window_id: window_id, device_id: windowEventDeviceId\(\)/,
	'the frame carries the event, the app, the window id and the browser device id');
like($windows_js, qr/function windowEventDeviceId\(\)/, 'the browser identity has one helper');
like($windows_js, qr/jawnosStore\.get\('window_events', 'device_id'/, 'the identity is read from the desk store');
like($windows_js, qr/jawnosStore\.set\('window_events', 'device_id'/, 'and minted into it once');
# one socket: the tab socket the act frame already speaks on
like($windows_js, qr/var socket = ws\['tab'\];/, 'the event rides the tab socket, not a new one');
unlike($windows_js, qr/new WebSocket\(/, 'the client opens no second socket for events');

# An open is sent from the append branch only: the re-render/restore branch
# (matches == 1) must not emit one.
my ($open_calls) = scalar(() = $windows_js =~ /windowEventSend\('open'/g);
is($open_calls, 1, 'exactly one open call site, so a re-render cannot double it');

# ---------------------------------------------------------------- the cull

my $alarm = read_file("$root/perl/Alarm.pl");
my ($cull_sql) = $alarm =~ /(delete from window_events where cast\(warranty as integer\) < cast\(\? as integer\))/;
ok($cull_sql, 'alarm_haircut carries the window_events cull');
like($alarm, qr/\&subs::websocket_sessions_cull\(\$timestamp\);\s*\n\s*(#[^\n]*\n\s*)*\&subs::db_query\('\Q$cull_sql\E'/,
	'the cull sits beside the websocket session cull');

my $now = &subs::rightNow();
# ago_calc counts backwards: '1d' is yesterday's warranty - expired - and '-29d'
# is one that lapses a month out, like the one the handler writes.
my $expired = &subs::ago_calc('1d', $now);
my $live    = &subs::ago_calc('-29d', $now);
$old->query(q{insert into window_events (uuid, window_id, browser_tab_id, app, event, timestamp, server_time, warranty, ost) values (?,?,?,?,?,?,?,?,?)},
	'expired-row', 'window_2', 'tab-round-trip', 'notes', 'open', $now, $now, $expired, $now);
$old->query(q{insert into window_events (uuid, window_id, browser_tab_id, app, event, timestamp, server_time, warranty, ost) values (?,?,?,?,?,?,?,?,?)},
	'live-row', 'window_3', 'tab-round-trip', 'notes', 'open', $now, $now, $live, $now);

eval { &subs::db_query($cull_sql, $now); 1 } or diag($@ || '');
ok(!$old->query(q{select 1 from window_events where uuid = ?}, 'expired-row')->hashes->[0],
	'an expired window event is culled');
ok($old->query(q{select 1 from window_events where uuid = ?}, 'live-row')->hashes->[0],
	'a window event inside its month survives');

# ---------------------------------------------------------------- the sync rail

# The rail is dynamic: a table with a server_time that is not in the forbidden
# list rides it. window_events is meant to ride it, so a second machine reads the
# same day. The list is memoised, and the database under this test is the temp
# one, so forget the memo before asking.
$subs::sync_table_cache = undef;
subs::preload('sync_table_list');
my $sync_tables = eval { &subs::sync_table_list() } || [];
ok(scalar @{$sync_tables} > 0, 'sync_table_list answers from the sandbox database');
my %syncs = map { $_ => 1 } @{$sync_tables};
ok($syncs{'window_events'}, 'window_events rides the sync rail');

my $gb_defaults = read_file("$root/perl/gb/01_state_and_defaults.pl");
my ($forbidden_tables) = $gb_defaults =~ /our \$forbidden = \{\s*tables => \[(.*?)\]/s;
ok(defined $forbidden_tables, 'the forbidden table list can be read');
like($forbidden_tables || '', qr/'websockets'/, 'a control: the retired sessions stay forbidden');
unlike($forbidden_tables || '', qr/window_events/, 'window_events is not forbidden from syncing');

# ---------------------------------------------------------------- reading the day

$subs::sync_table_cache = undef;

# A fixed day, far from the rows above (which use the real clock), so the
# bounds select exactly these transitions.
my $day = 1_700_000_000_000;
my $day_from = $day + 500;
my $day_to   = $day + 20000;
my $add_event = sub {
	my ($uuid, $window_id, $app, $event, $at, $tab, $hostname, $device) = @_;
	$hostname = 'test-box' unless defined $hostname;
	$old->query(q{insert into window_events (uuid, window_id, browser_tab_id, device_id, app, event, timestamp, server_time, hostname, warranty, ost) values (?,?,?,?,?,?,?,?,?,?,?)},
		$uuid, $window_id, (defined $tab ? $tab : 'tab-day'), $device, $app, $event, $at, $at, $hostname, $live, $at);
};

# a whole window: open, two panels' worth of minimize/restore, close
$add_event->('e1',  'wc-a', 'notes',   'open',     $day + 1000);
$add_event->('e2',  'wc-a', 'notes',   'minimize', $day + 2000);
$add_event->('e3',  'wc-a', 'notes',   'restore',  $day + 3000);
$add_event->('e4',  'wc-a', 'notes',   'close',    $day + 4000);
# a second tab's window
$add_event->('e5',  'wc-b', 'mailbox', 'open',     $day + 5000, 'tab-day2');
$add_event->('e6',  'wc-b', 'mailbox', 'close',    $day + 9000, 'tab-day2');
# two transitions in the same millisecond, inserted close-first: only rowid can
# tell them apart, and the rowid order is the order they happened
$add_event->('e7',  'wc-tie', 'clock',  'close',    $day + 10000);
$add_event->('e8',  'wc-tie', 'clock',  'open',     $day + 10000);
# a window that closed and came back under the same id, then is still open
$add_event->('e9',  'wc-c', 'notes',   'open',     $day + 11000);
$add_event->('e10', 'wc-c', 'notes',   'close',    $day + 12000);
# a window still open at the end of the range
$add_event->('e11', 'wc-d', 'notes',   'open',     $day + 13000);
$add_event->('e12', 'wc-c', 'notes',   'open',     $day + 15000);

my $read = &subs::window_events_read(from => $day_from, to => $day_to);
is($read->{'count'}, 12, 'the read returns the day\'s transitions');
is(scalar @{ $read->{'events'} }, 12, 'count matches the list');

my @order = map { $_->{'window_id'} . '/' . $_->{'event'} } @{ $read->{'events'} };
is_deeply(\@order, [
	'wc-a/open', 'wc-a/minimize', 'wc-a/restore', 'wc-a/close',
	'wc-b/open', 'wc-b/close',
	'wc-tie/close', 'wc-tie/open',
	'wc-c/open', 'wc-c/close', 'wc-d/open', 'wc-c/open'
], 'the events read in timestamp order, then rowid for a tie');

my $first = $read->{'events'}[0] || {};
ok(!ref $first->{'timestamp'} && $first->{'timestamp'} == $day + 1000,
	'the timestamp comes back as a number');
is($first->{'app'}, 'notes', 'the app comes back');
is($first->{'browser_tab_id'}, 'tab-day', 'the tab comes back');
is($first->{'hostname'}, 'test-box', 'the hostname comes back');
ok(defined $first->{'event_row'} && $first->{'event_row'} > 0, 'each event names its rowid');

my $notes = &subs::window_events_read(from => $day_from, to => $day_to, app => 'notes');
is($notes->{'count'}, 8, 'an app filter keeps only that app\'s transitions');
my @not_notes = grep { ($_->{'app'} || '') ne 'notes' } @{ $notes->{'events'} };
is_deeply(\@not_notes, [], 'no other app leaks through the filter');

my $minimizes = &subs::window_events_read(from => $day_from, to => $day_to, app => 'notes', limit => 3);
is($minimizes->{'count'}, 3, 'the limit bounds the answer');

my $one_window = &subs::window_events_read({ from => $day_from, to => $day_to, window_id => 'wc-c' });
is($one_window->{'count'}, 3, 'a window filter (hashref options) keeps that window');

my $one_tab = &subs::window_events_read(from => $day_from, to => $day_to, browser_tab_id => 'tab-day2');
is($one_tab->{'count'}, 2, 'a tab filter keeps that tab\'s transitions');

my $narrow = &subs::window_events_read(from => $day + 2000, to => $day + 5000);
is($narrow->{'count'}, 4, 'the from/to bounds are inclusive and cut the rest off');

# A filter that is not a plain value fails closed and says which one.
my $bad_app = &subs::window_events_read(from => $day_from, to => $day_to, app => { nope => 1 });
is($bad_app->{'count'}, 0, 'a ref used as an app filter returns nothing');
is($bad_app->{'error'}, 'app', 'and names the filter it refused');
my $bad_from = &subs::window_events_read(from => 'yesterday', to => $day_to);
is($bad_from->{'count'}, 0, 'a non-numeric bound returns nothing');
is($bad_from->{'error'}, 'from', 'and names the bound it refused');
my $empty_window = &subs::window_events_read(from => $day_from, to => $day_to, window_id => '');
is($empty_window->{'count'}, 0, 'an empty window filter returns nothing');

# The values stay data: a quote in a filter is a quote, not a clause.
my $injection = &subs::window_events_read(from => $day_from, to => $day_to, window_id => q{' or 1=1 --});
is($injection->{'count'}, 0, 'a quoted filter value matches nothing instead of everything');

# The reader's predicates are the ones the expression indexes were built for, so
# a filter plus a range is a lookup rather than a scan of the month.
for my $probe (
	[ 'app', 'notes', qr/idx1_window_events/ ],
	[ 'window_id', 'wc-a', qr/idx3_window_events/ ],
	[ 'browser_tab_id', 'tab-day', qr/idx2_window_events/ ],
	[ 'device_id', 'dev-day', qr/idx5_window_events/ ]
) {
	my ($column, $value, $want) = @{$probe};
	my $plan = $fresh->query(
		'explain query plan select rowid from window_events where cast("timestamp" as integer) >= cast(? as integer)'
			. ' and cast("timestamp" as integer) <= cast(? as integer) and "' . $column . '" = ?'
			. ' order by cast("timestamp" as integer), rowid limit 500',
		$day_from, $day_to, $value
	)->hashes->[0]->{'detail'} || '';
	like($plan, $want, "a $column read with a range is served by its index");
}

# ---------------------------------------------------------------- pairing them up

my $spans = &subs::window_events_spans(from => $day_from, to => $day_to);
is($spans->{'count'}, 7, 'the day pairs into seven spans');
my %spans_by_window;
push @{ $spans_by_window{ $_->{'window_id'} } }, $_ for @{ $spans->{'spans'} };

my $a = ($spans_by_window{'wc-a'} || [])->[0] || {};
is($a->{'app'}, 'notes', 'a span names the app its open carried');
is($a->{'opened'}, $day + 1000, 'the span opens when the window did');
is($a->{'closed'}, $day + 4000, 'and closes when it did');
is($a->{'duration_ms'}, 3000, 'the duration is the pair\'s difference');
my @a_events = map { $_->{'event'} } @{ $a->{'events'} || [] };
is_deeply(\@a_events, [ 'open', 'minimize', 'restore', 'close' ],
	'minimize and restore ride inside the span that was open');

my $b = ($spans_by_window{'wc-b'} || [])->[0] || {};
is($b->{'duration_ms'}, 4000, 'a second window\'s own duration');

my ($c_closed, $c_open) = @{ $spans_by_window{'wc-c'} || [] };
is(scalar @{ $spans_by_window{'wc-c'} || [] }, 2, 'a second open after a close is a new span');
is($c_closed->{'opened'}, $day + 11000, 'the first span opened first');
is($c_closed->{'duration_ms'}, 1000, 'the first span closed in the same window id');
is($c_open->{'opened'}, $day + 15000, 'the second span opened when the window came back');
ok(!defined $c_open->{'closed'}, 'a window still open has no close');
ok(!defined $c_open->{'duration_ms'}, 'and no duration');
is(scalar @{ $c_open->{'events'} }, 1, 'the open span holds only its open');

my $d = ($spans_by_window{'wc-d'} || [])->[0] || {};
is($d->{'opened'}, $day + 13000, 'an open with no close is a span of its own');
ok(!defined $d->{'closed'}, 'left open at the end of the range');

my @tie = @{ $spans_by_window{'wc-tie'} || [] };
is(scalar @tie, 2, 'a close with no open in range is kept, and the open after it is its own span');
# both spans sit on the same millisecond, so which of the two the sort puts first
# is arbitrary: find them by what they are, not by where they landed
my ($tie_closed) = grep { !defined $_->{'opened'} } @tie;
my ($tie_opened) = grep { defined $_->{'opened'} } @tie;
ok($tie_closed, 'the close-only span has no opening');
is($tie_closed->{'closed'}, $day + 10000, 'but it keeps the close it was shown') if $tie_closed;
ok($tie_opened, 'the open after the close is a span');
is($tie_opened->{'opened'}, $day + 10000, 'opened at its own moment') if $tie_opened;

my $spans_order = $spans->{'spans'};
is($spans_order->[0]{'window_id'}, 'wc-a', 'the spans read left to right');
is($spans_order->[-1]{'opened'}, $day + 15000, 'the last span is the one that opened last');

my $c_spans = &subs::window_events_spans(from => $day_from, to => $day_to, window_id => 'wc-c');
is($c_spans->{'count'}, 2, 'the span reader takes the same filters as the event reader');

# ------------------------------------------------- the machine is part of the key

# window_events syncs, and window_id is page-local (window_<Date.now()>), so two
# machines can mint the same id. They have to pair separately; within one machine
# the pairing must read exactly as it did before.
my $cross_from = $day + 30000;
my $cross_to   = $day + 40000;
$add_event->('x1', 'wc-dup', 'notes', 'open',  $day + 30000, 'tab-x', 'box-one');
$add_event->('x2', 'wc-dup', 'notes', 'close', $day + 31000, 'tab-x', 'box-one');
$add_event->('x3', 'wc-dup', 'notes', 'open',  $day + 32000, 'tab-y', 'box-two');
$add_event->('x4', 'wc-dup', 'notes', 'close', $day + 33500, 'tab-y', 'box-two');

my $cross = &subs::window_events_spans(from => $cross_from, to => $cross_to);
is($cross->{'count'}, 2, 'one window id on two machines is two spans');
is_deeply([ map { $_->{'hostname'} } @{ $cross->{'spans'} } ], [ 'box-one', 'box-two' ],
	'each span names the machine it came from');
is($cross->{'spans'}[0]{'window_id'}, 'wc-dup', 'both spans keep the same window id');
is($cross->{'spans'}[1]{'window_id'}, 'wc-dup', 'and neither swallowed the other');
is($cross->{'spans'}[0]{'duration_ms'}, 1000, 'the first machine pairs its own open and close');
is($cross->{'spans'}[1]{'duration_ms'}, 1500, 'the second machine pairs its own');
is(scalar @{ $cross->{'spans'}[0]{'events'} }, 2, 'each span holds only its machine\'s two transitions');

# A row with no hostname falls back to its tab, and then to the bare window id.
my $fallback_from = $day + 50000;
my $fallback_to   = $day + 60000;
$add_event->('y1', 'wc-nh',  'notes', 'open',  $day + 50000, 'tab-x', '');
$add_event->('y2', 'wc-nh',  'notes', 'close', $day + 51000, 'tab-x', '');
$add_event->('y3', 'wc-nh',  'notes', 'open',  $day + 52000, 'tab-y', '');
$add_event->('y4', 'wc-nh',  'notes', 'close', $day + 54000, 'tab-y', '');
$add_event->('y5', 'wc-nh2', 'notes', 'open',  $day + 55000, '',      '');
$add_event->('y6', 'wc-nh2', 'notes', 'close', $day + 55500, '',      '');

my $fallback = &subs::window_events_spans(from => $fallback_from, to => $fallback_to);
is($fallback->{'count'}, 3, 'no hostname: the tab separates, and a pair with neither still pairs');
my @fallback = @{ $fallback->{'spans'} };
is($fallback[0]{'duration_ms'}, 1000, 'the first tab pairs its own');
is($fallback[1]{'duration_ms'}, 2000, 'the second tab pairs its own rather than joining the first');
is($fallback[2]{'window_id'}, 'wc-nh2', 'a row with neither identity still pairs by its window id');
is($fallback[2]{'duration_ms'}, 500, 'over its own open and close');
is_deeply([ map { $_->{'hostname'} } @fallback ], [ '', '', '' ],
	'these spans carry the empty hostname they were read with');

# ------------------------------------------------- the browser is part of the key

# A reload keeps one flow: two tabs of one browser (one device id) and the same
# window id closing what the other opened are one span, not two.
my $reload_from = $day + 70000;
my $reload_to   = $day + 80000;
$add_event->('z1', 'wc-reload', 'notes', 'open',  $day + 70000, 'tab-r1', 'box-one', 'dev-one');
$add_event->('z2', 'wc-reload', 'notes', 'close', $day + 71000, 'tab-r2', 'box-one', 'dev-one');

my $reload = &subs::window_events_spans(from => $reload_from, to => $reload_to);
is($reload->{'count'}, 1, 'a reload across two tabs of one browser is one span');
is($reload->{'spans'}[0]{'duration_ms'}, 1000, 'the reload\'s two halves pair');
is($reload->{'spans'}[0]{'device_id'}, 'dev-one', 'the span names its browser');

my $by_device = &subs::window_events_read(from => $reload_from, to => $reload_to, device_id => 'dev-one');
is($by_device->{'count'}, 2, 'a device filter keeps that browser\'s transitions');

# Two browsers sharing a window id keep their own flows.
my $devices_from = $day + 90000;
my $devices_to   = $day + 100000;
$add_event->('v1', 'wc-both', 'notes', 'open',  $day + 90000, 'tab-a', 'box-one', 'dev-one');
$add_event->('v2', 'wc-both', 'notes', 'close', $day + 91000, 'tab-a', 'box-one', 'dev-one');
$add_event->('v3', 'wc-both', 'notes', 'open',  $day + 92000, 'tab-b', 'box-one', 'dev-two');
$add_event->('v4', 'wc-both', 'notes', 'close', $day + 94000, 'tab-b', 'box-one', 'dev-two');

my $devices = &subs::window_events_spans(from => $devices_from, to => $devices_to);
is($devices->{'count'}, 2, 'two browsers sharing a window id are two spans');
is($devices->{'spans'}[0]{'device_id'}, 'dev-one', 'the first span names its browser');
is($devices->{'spans'}[1]{'device_id'}, 'dev-two', 'the second span names the other');
is($devices->{'spans'}[0]{'duration_ms'}, 1000, 'the first browser pairs its own');
is($devices->{'spans'}[1]{'duration_ms'}, 2000, 'the second pairs its own');
is(scalar @{ $devices->{'spans'}[0]{'events'} }, 2, 'each span holds only its browser\'s transitions');

# The device id outranks the server's name: one browser seen through two
# hostnames (a renamed box) is still one flow.
my $outrank_from = $day + 110000;
my $outrank_to   = $day + 120000;
$add_event->('w1', 'wc-out', 'notes', 'open',  $day + 110000, 'tab-a', 'box-one', 'dev-one');
$add_event->('w2', 'wc-out', 'notes', 'close', $day + 112000, 'tab-b', 'box-two', 'dev-one');

my $outrank = &subs::window_events_spans(from => $outrank_from, to => $outrank_to);
is($outrank->{'count'}, 1, 'one device id is one span even across server names');
is($outrank->{'spans'}[0]{'duration_ms'}, 2000, 'and pairs its two transitions');

$gb::database_holder = {};

done_testing();
