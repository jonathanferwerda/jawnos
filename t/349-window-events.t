# tests-for: database/schema.sql lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Controller/manager_ws.pm perl/Alarm.pl public/js/manager/windows.js
# covers:    window_events records one row per desktop window transition (open,
#            close, minimize, restore), so the clothesline can rebuild a day's
#            window flow instead of reading the one layout snapshot the
#            websockets row keeps. The table arrives both ways - schema.sql for a
#            fresh database, update_database for an existing one; the manager's
#            socket handler inserts a validated frame; the client sends it from
#            the real transitions only; alarm_haircut expires it by warranty.

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
	uuid window_id browser_tab_id app event timestamp server_time
	hostname user_agent room warranty ost
);
my @want_indexes = qw(
	idx1_window_events idx2_window_events idx3_window_events idx4_window_events
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
like($windows_js, qr/type: 'window_event', event: event, app: app, window_id: window_id/,
	'the frame carries the event, the app and the window id');
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

$gb::database_holder = {};

done_testing();
