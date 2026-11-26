# tests-for: lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Domain/Backup.pm lib/JawnOS/Domain/Ai3.pm

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

# The ledger's attribution half: the call now names the app and run that asked,
# marks whether the provider reported usage, and folds into a day rollup. The
# balance chart, in turn, can now tell the part of a fall the ledger explains
# from the part it cannot. These tests pin the pure inference arithmetic, the
# write shape of ai_spend_note and its rollup, the once-only backfill, and the
# migration/index text.

# Load the real definitions before the local stubs below: the domain layer is
# lazy and a later AUTOLOAD would otherwise overwrite a stub.
require JawnOS::Domain::Run;
require JawnOS::Domain::Ai3;

my $root = root();

package FakeRowSet;
sub new { my ($class, $rows, $count) = @_; return bless { rows => $rows, rows_count => $count }, $class }
sub hashes { return $_[0]->{'rows'} }
sub rows { return $_[0]->{'rows_count'} }
package main;

# ---- external spend inference: pure arithmetic ------------------------------
{
	my $t0 = ts(2026, 11, 2, 10, 0, 0);
	my $t1 = ts(2026, 11, 2, 10, 10, 0);
	my $t2 = ts(2026, 11, 2, 10, 20, 0);
	my $t3 = ts(2026, 11, 2, 10, 30, 0);
	my $points = [
		{ t => $t0, v => 10 },    # 10:00
		{ t => $t1, v => 8 },     # 10:10: fell 2 with no tokens beside it
		{ t => $t2, v => 10 },    # 10:20: a top-up, ignored
		{ t => $t3, v => 7 },     # 10:30: fell 3, 500 tokens in the interval
	];
	my $split = subs::ai_balance_external($points, { '2026-11-02 10:25' => 500 });
	is $split->{'external'}, 2, 'a zero-token fall is external';
	is $split->{'tokens'}, 500, 'and the tokens in the intervals are counted';
	is scalar @{ $split->{'intervals'} }, 3, 'one interval per pair of readings';
	is $split->{'intervals'}->[0]->{'fall'}, 2, 'the first interval fell two';
	is $split->{'intervals'}->[0]->{'tokens'}, 0, 'with no JawnOS traffic';
	is $split->{'intervals'}->[0]->{'external'}, 2, 'so that fall is external';
	is $split->{'intervals'}->[1]->{'fall'}, 0, 'a top-up is not a negative fall';
	is $split->{'intervals'}->[1]->{'external'}, 0, 'and is never external spend';
	is $split->{'intervals'}->[2]->{'tokens'}, 500, 'the third interval carries the ledger tokens';
	is $split->{'intervals'}->[2]->{'fall'}, 3, 'and its fall is three';
	is $split->{'intervals'}->[2]->{'external'}, 0, 'any token beside a fall credits it to JawnOS';

	# Tokens in the minute of the earlier reading came before the fall; counting
	# them again would move spend out of the external figure.
	my $edge = subs::ai_balance_external(
		[ { t => $t0, v => 5 }, { t => $t1, v => 4 } ],
		{ '2026-11-02 10:00' => 999 },
	);
	is $edge->{'external'}, 1, 'the earlier reading minute is not part of the interval';

	# Both readings inside one minute leave that minute as the only candidate.
	my $same = subs::ai_balance_external(
		[ { t => ts(2026, 11, 2, 10, 5, 0), v => 5 }, { t => ts(2026, 11, 2, 10, 5, 0), v => 4 } ],
		{ '2026-11-02 10:05' => 10 },
	);
	is $same->{'external'}, 0, 'one minute of readings can still use its own tokens';
}

# ---- the per-call write now names provenance and metering -------------------
{
	no warnings 'redefine';
	my $now = ts(2026, 11, 2, 17, 43, 59);
	local $subs::ai_spend_daily_ready = 0;
	local *subs::ai_house_me = sub { 'machine-a' };
	local *subs::rightNow = sub { $now };
	my (@inserted, @queries);
	local *subs::db_insert = sub {
		my ($table, $row) = @_;
		push @inserted, { table => $table, row => { %{$row} } };
		return 1;
	};
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		return FakeRowSet->new([ { '1' => 1 } ], 1) if $sql =~ /sqlite_master/;
		push @queries, [ $sql, @args ];
		return FakeRowSet->new([], 1);
	};

	ok subs::ai_spend_note('deepseek', 800, 200, 'deepseek-chat', 'coding_assistant',
		{ app => 'help', run => 'run-7' }),
		'a call with provenance banks its usage';
	is scalar @inserted, 1, 'with one per-call row';
	my $row = $inserted[0]{'row'};
	is $inserted[0]{'table'}, 'ai_spend', 'in the call ledger';
	is $row->{'minute'}, '2026-11-02 17:43', 'under its clock minute';
	is $row->{'app'}, 'help', 'naming the app';
	is $row->{'run'}, 'run-7', 'and the run';
	is $row->{'metered'}, 1, 'and marking the usage as reported';
	is $row->{'tokens_in'}, 800, 'with its tokens';
	is $row->{'tokens_out'}, 200, 'both halves';

	is scalar @queries, 1, 'and one day-rollup write';
	my ($sql, @args) = @{ $queries[0] };
	like $sql, qr/insert into ai_spend_daily/, 'the rollup row is an insert';
	like $sql, qr/on conflict\(machine, day, provider, model, role, app\) do update/,
		'that adds to the natural key rather than colliding with it';
	is $args[0], subs::ai_spend_daily_uuid('machine-a', '2026-11-02', 'deepseek', 'deepseek-chat', 'coding_assistant', 'help'),
		'with the stable natural-key uuid';
	like $args[0], qr/^ai_spend_daily_/, 'which is visibly the rollup uuid';
	is $args[1], 'machine-a', 'the machine';
	is $args[2], '2026-11-02', 'the day';
	is $args[3], 'deepseek', 'the provider';
	is $args[4], 'deepseek-chat', 'the model';
	is $args[5], 'coding_assistant', 'the role';
	is $args[6], 'help', 'the app';
	is $args[7], 800, 'the day tokens in';
	is $args[8], 200, 'and out';
	is $args[9], 1, 'counting the call';
	is $args[10], 0, 'with nothing unmetered';

	# A call that reported no usage is still recorded only when asked, and the
	# rollup must count it as unmetered rather than as a free call.
	(@inserted, @queries) = ();
	ok subs::ai_spend_note('deepseek', 0, 0, 'deepseek-chat', 'coding_assistant', { count_unmetered => 1 }),
		'an explicitly counted unmetered call is banked';
	is $inserted[0]{'row'}{'metered'}, 0, 'the call row is marked unmetered';
	is $inserted[0]{'row'}{'tokens_in'}, 0, 'with no tokens';
	is scalar @queries, 1, 'and still reaches the rollup';
	is $queries[0]->[1 + 9], 1, 'which counts the call';
	is $queries[0]->[1 + 10], 1, 'and marks one unmetered';

	# The five-argument call sites keep working unchanged.
	(@inserted, @queries) = ();
	ok subs::ai_spend_note('deepseek', 10, 5, 'deepseek-chat', 'coding_assistant'),
		'a five-argument caller still banks its usage';
	is $inserted[0]{'row'}{'app'}, '', 'with an empty app';
	is $inserted[0]{'row'}{'run'}, '', 'and an empty run';
	is $inserted[0]{'row'}{'metered'}, 1, 'and is metered';

	(@inserted, @queries) = ();
	is subs::ai_spend_note('deepseek', 0, 0), 0, 'a zero-usage call without the flag is not banked';
	is scalar @inserted, 0, 'so no call row is written';
	is scalar @queries, 0, 'and no rollup is touched';
}

# A pre-migration database has no rollup table. The call must still be banked,
# and the absent table skipped quietly rather than logged on every call.
{
	no warnings 'redefine';
	my $now = ts(2026, 11, 2, 17, 43, 59);
	local $subs::ai_spend_daily_ready = 0;
	local *subs::ai_house_me = sub { 'machine-a' };
	local *subs::rightNow = sub { $now };
	my (@inserted, @checked);
	local *subs::db_insert = sub { push @inserted, $_[0]; return 1 };
	local *subs::db_query = sub { push @checked, $_[0]; return FakeRowSet->new([], 1) };
	local *subs::log_writer = sub { die "the absent rollup table must not be logged\n" };
	ok subs::ai_spend_note('deepseek', 10, 5, 'm', 'r'), 'a call is still banked when the rollup table is absent';
	is_deeply \@inserted, [ 'ai_spend' ], 'only the per-call row is written';
	is scalar @checked, 1, 'the missing table is probed once';
	like $checked[0], qr/sqlite_master/, 'with the table lookup';
}

# ---- the natural uuid is stable across a peer sync --------------------------
{
	my $a = subs::ai_spend_daily_uuid('machine-a', '2026-11-02', 'deepseek', 'm', 'r', 'help');
	my $b = subs::ai_spend_daily_uuid('machine-a', '2026-11-02', 'deepseek', 'm', 'r', 'help');
	my $c = subs::ai_spend_daily_uuid('machine-a', '2026-11-02', 'deepseek', 'm', 'r', 'mail');
	is $a, $b, 'the same natural key gives the same uuid';
	isnt $a, $c, 'and a different app gives a different one';
}

# ---- the rollup's upsert really adds to one row -----------------------------
{
	require DBI;
	my $dbh = DBI->connect('dbi:SQLite::memory:', '', '', { RaiseError => 1, PrintError => 0 });
	$dbh->do('create table ai_spend_daily (uuid text, machine text, day text, provider text, model text, role text, app text, tokens_in int, tokens_out int, calls int, unmetered int, ost text, server_time text)');
	$dbh->do('create unique index idx_ai_spend_daily on ai_spend_daily (machine, day, provider, model, role, app)');
	no warnings 'redefine';
	local $subs::ai_spend_daily_ready = 1;
	local *subs::rightNow = sub { ts(2026, 11, 2, 17, 0, 0) };
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		my $sth = $dbh->prepare($sql);
		$sth->execute(@args);
		return FakeRowSet->new($sth->fetchall_arrayref({}), $sth->rows);
	};
	ok subs::ai_spend_daily_add('machine-a', '2026-11-02', 'deepseek', 'm', 'r', 'help', 100, 50, 1, 0),
		'the first call writes a rollup row';
	ok subs::ai_spend_daily_add('machine-a', '2026-11-02', 'deepseek', 'm', 'r', 'help', 200, 70, 1, 0),
		'a second call adds to the same row';
	ok subs::ai_spend_daily_add('machine-a', '2026-11-02', 'deepseek', 'm', 'r', 'help', 0, 0, 1, 1),
		'and an unmetered call counts without tokens';
	my $rows = $dbh->selectall_arrayref('select * from ai_spend_daily', { Slice => {} });
	is scalar @{$rows}, 1, 'all three land in one natural-key row';
	my $row = $rows->[0];
	is $row->{'tokens_in'}, 300, 'tokens in add up';
	is $row->{'tokens_out'}, 120, 'and tokens out';
	is $row->{'calls'}, 3, 'and the calls';
	is $row->{'unmetered'}, 1, 'while unmetered calls are counted apart';
	is $row->{'uuid'}, subs::ai_spend_daily_uuid('machine-a', '2026-11-02', 'deepseek', 'm', 'r', 'help'),
		'with the stable natural-key uuid';
	ok subs::ai_spend_daily_add('machine-a', '2026-11-02', 'deepseek', 'm', 'r', 'mail', 5, 5, 1, 0),
		'a different app is its own row';
	is scalar @{ $dbh->selectall_arrayref('select * from ai_spend_daily') }, 2,
		'so the table holds two rows';
}

# ---- the one-time backfill --------------------------------------------------
{
	no warnings 'redefine';
	my $now = ts(2026, 11, 2, 17, 43, 59);
	my ($set, @upserts, @seen);
	local $subs::ai_spend_daily_ready = 1;
	local $subs::ai_spend_daily_backfilled = 0;
	local *subs::rightNow = sub { $now };
	local *subs::setting_grabber = sub { '' };
	local *subs::setting_setter = sub { my ($h) = @_; $set = $h->{'value'}; return 1 };
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		push @seen, $sql;
		return FakeRowSet->new([ { c => 0 } ], 1) if $sql =~ /count\(\*\) as c from ai_spend_daily/;
		return FakeRowSet->new([
			{ machine => 'machine-a', day => '2026-11-01', provider => 'deepseek', model => 'm',
				role => 'r', app => 'help', tokens_in => 100, tokens_out => 50, calls => 2, unmetered => 1 },
		], 1) if $sql =~ /from ai_spend where minute/;
		push @upserts, [ $sql, @args ] if $sql =~ /insert into ai_spend_daily/;
		return FakeRowSet->new([], 1);
	};

	is subs::ai_spend_daily_backfill(), 1, 'the first heartbeat folds the old ledger in';
	is scalar @upserts, 1, 'writing one grouped rollup row';
	my ($sql, @args) = @{ $upserts[0] };
	is $args[0], subs::ai_spend_daily_uuid('machine-a', '2026-11-01', 'deepseek', 'm', 'r', 'help'),
		'with the group natural-key uuid';
	is $args[2], '2026-11-01', 'for the grouped day';
	is $args[7], 100, 'summing the group tokens in';
	is $args[8], 50, 'and out';
	is $args[9], 2, 'and its calls';
	is $args[10], 1, 'and its unmetered calls';
	is $set, '1', 'and marks the backfill done';

	(@upserts, @seen) = ();
	is subs::ai_spend_daily_backfill(), 0, 'a second call in the same process does nothing';
	is scalar @seen, 0, 'and does not even read the database';
}

# The grouped select the backfill runs is exercised against a real SQLite too:
# the alias names and the day prefix are what the rollup's natural key depends
# on, and a stub cannot prove they parse.
{
	require DBI;
	my $dbh = DBI->connect('dbi:SQLite::memory:', '', '', { RaiseError => 1, PrintError => 0 });
	$dbh->do('create table ai_spend (uuid text, machine text, provider text, model text, role text, app text, minute text, tokens_in int, tokens_out int, calls int, metered int, ost text, server_time text)');
	$dbh->do('create table ai_spend_daily (uuid text, machine text, day text, provider text, model text, role text, app text, tokens_in int, tokens_out int, calls int, unmetered int, ost text, server_time text)');
	$dbh->do('create unique index idx_ai_spend_daily on ai_spend_daily (machine, day, provider, model, role, app)');
	my $insert = $dbh->prepare('insert into ai_spend (machine, provider, model, role, app, minute, tokens_in, tokens_out, metered) values (?,?,?,?,?,?,?,?,?)');
	$insert->execute('machine-a', 'deepseek', 'm', 'r', 'help', '2026-11-01 10:00', 100, 50, 1);
	$insert->execute('machine-a', 'deepseek', 'm', 'r', 'help', '2026-11-01 11:00', 20, 10, 1);
	$insert->execute('machine-a', 'deepseek', 'm', 'r', 'help', '2026-11-01 12:00', 0, 0, 0);
	$insert->execute('machine-a', 'deepseek', 'm', 'r', 'mail', '2026-11-01 12:05', 5, 5, 1);
	no warnings 'redefine';
	local $subs::ai_spend_daily_ready = 1;
	local $subs::ai_spend_daily_backfilled = 0;
	local *subs::rightNow = sub { ts(2026, 11, 2, 17, 0, 0) };
	local *subs::setting_grabber = sub { '' };
	local *subs::setting_setter = sub { 1 };
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		my $sth = $dbh->prepare($sql);
		$sth->execute(@args);
		return FakeRowSet->new($sth->fetchall_arrayref({}), $sth->rows);
	};
	is subs::ai_spend_daily_backfill(), 1, 'the grouped backfill really runs';
	my $rows = $dbh->selectall_arrayref('select * from ai_spend_daily order by app', { Slice => {} });
	is scalar @{$rows}, 2, 'the day and app split the calls into two rows';
	is $rows->[0]{'app'}, 'help', 'the first group is the help app';
	is $rows->[0]{'day'}, '2026-11-01', 'for the day in the minute key';
	is $rows->[0]{'tokens_in'}, 120, 'with its tokens in summed';
	is $rows->[0]{'tokens_out'}, 60, 'and its tokens out';
	is $rows->[0]{'calls'}, 3, 'and its calls';
	is $rows->[0]{'unmetered'}, 1, 'counting the call that reported nothing';
	is $rows->[1]{'app'}, 'mail', 'the other group is the mail app';
	is $rows->[1]{'tokens_in'}, 5, 'with its own tokens';
}

# A durable setting makes the guard survive a restart.
{
	no warnings 'redefine';
	my @seen;
	local $subs::ai_spend_daily_ready = 1;
	local $subs::ai_spend_daily_backfilled = 0;
	local *subs::setting_grabber = sub { '1' };
	local *subs::db_query = sub { push @seen, 1; return FakeRowSet->new([], 1) };
	is subs::ai_spend_daily_backfill(), 0, 'a database already backfilled does nothing';
	is scalar @seen, 0, 'without touching the ledger';
}

# An existing rollup row means this build is already writing daily rows; the old
# ledger must not be added again on top of them.
{
	no warnings 'redefine';
	my ($set, @upserts);
	local $subs::ai_spend_daily_ready = 1;
	local $subs::ai_spend_daily_backfilled = 0;
	local *subs::setting_grabber = sub { '' };
	local *subs::setting_setter = sub { my ($h) = @_; $set = $h->{'value'}; return 1 };
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		return FakeRowSet->new([ { c => 1 } ], 1) if $sql =~ /count\(\*\) as c from ai_spend_daily/;
		push @upserts, [ $sql, @args ] if $sql =~ /insert into ai_spend_daily/;
		return FakeRowSet->new([], 1);
	};
	is subs::ai_spend_daily_backfill(), 0, 'a rollup that already has rows is left alone';
	is scalar @upserts, 0, 'so no old call is counted twice';
	is $set, '1', 'and the guard is recorded';
}

# The table may not exist yet; that is not a completed backfill.
{
	no warnings 'redefine';
	my ($set, @upserts);
	local $subs::ai_spend_daily_ready = 1;
	local $subs::ai_spend_daily_backfilled = 0;
	local *subs::setting_grabber = sub { '' };
	local *subs::setting_setter = sub { my ($h) = @_; $set = $h->{'value'}; return 1 };
	local *subs::db_query = sub { return undef };
	is subs::ai_spend_daily_backfill(), 0, 'a missing table does not report a completed backfill';
	is scalar @upserts, 0, 'and writes nothing';
	ok !defined $set, 'so the next heartbeat can try again';
}

# ---- the chart puts the inference beside the roles --------------------------
{
	no warnings 'redefine';
	my $now = ts(2026, 11, 2, 12, 0, 0);
	my $start = $now - 3600000;
	my @points = (
		{ t => ts(2026, 11, 2, 11, 10, 0), v => 10 },
		{ t => ts(2026, 11, 2, 11, 20, 0), v => 8 },   # fell 2 with no tokens
		{ t => ts(2026, 11, 2, 11, 30, 0), v => 5 },   # fell 3, 1000 tokens beside it
	);
	local *subs::crypto_report_currency = sub { 'USD' };
	local *subs::ai_spend_since = sub { $start };
	local *subs::ai_spend_buckets = sub {
		{ deepseek => { '2026-11-02 11' => { tokens => 1000, calls => 1, models => {} } } };
	};
	local *subs::ai_spend_roles = sub { { deepseek => { coding_assistant => 1000 } } };
	local *subs::ai_spend_sessions = sub {
		{ providers => { deepseek => { active_ms => 60000, sessions => 1,
			roles => { coding_assistant => { active_ms => 60000, sessions => 1 } } } },
		  all => { active_ms => 60000 } };
	};
	local *subs::ai_balance_period_end = sub { $now };
	local *subs::ai_balance_edges = sub { [ { key => '2026-11-02 11:00', start => $start, end => $now } ] };
	local *subs::ai_balance_window = sub { { start => $start, now => $now, points => [ map { { %$_ } } @points ] } };
	local *subs::ai_balance_buckets = sub {
		{ window => '1h', total => 5, tokens => 1000, buckets => [ { tracked => 1 } ], samples => 3, max => 3 };
	};
	local *subs::ai_balance_role_label = sub { ucfirst $_[0] };
	local *subs::ai_window_span_ms = sub { 3600000 };
	local *subs::ai_balance_projection_rate = sub { undef };
	local *subs::ai_balance_period_label = sub { '' };
	local *subs::ui = sub { $_[0] };
	local *subs::db_query = sub {
		return FakeRowSet->new([ { minute => '2026-11-02 11:25', tokens => 1000 } ], 1);
	};

	my $report = {
		rows    => [ { provider => 'deepseek', label => 'DeepSeek', currency => 'USD', available => 1 } ],
		history => { deepseek => [ map { { %$_ } } @points ] },
	};
	my $chart = subs::ai_balance_chart($report, $now, 0);
	my $wd = $chart->{'series'}->[0]{'windows'}{'1h'};
	is $wd->{'external'}, 2, 'the chart calls the fall with no tokens external';
	is $wd->{'jawnos_total'}, 3, 'and leaves the rest to JawnOS';
	is $wd->{'per_k'}, 3, 'so the price divides only the JawnOS part';
	is $wd->{'bars'}{'total'}, 5, 'the whole fall is still the bar total';
	my ($ext) = grep { $_->{'role'} eq '__external' } @{ $wd->{'roles'} };
	ok $ext, 'an external role row is present';
	is $ext->{'label'}, 'Outside JawnOS (inferred)', 'with its own label';
	is $ext->{'tokens'}, 0, 'no tokens of its own';
	is $ext->{'cost'}, 2, 'carrying the inferred money';
	is $ext->{'share'}, 40, 'and a forty percent share of the fall';
	is $ext->{'active_ms'}, 0, 'with no session time';
	is $ext->{'sessions'}, 0, 'and no sessions';
	my ($coding) = grep { $_->{'role'} eq 'coding_assistant' } @{ $wd->{'roles'} };
	ok $coding, 'the named role is still there';
	is $coding->{'cost'}, 3, 'with the JawnOS spend';
	is $coding->{'share'}, 60, 'and the complementary share';
	is $coding->{'share'} + $ext->{'share'}, 100, 'so roles and external add to one hundred';
}

# ---- the schema and the backup list -----------------------------------------
my $migrations = read_file("$root/lib/JawnOS/Domain/Migrations.pm");
like $migrations, qr/alter table ai_spend add column app/, 'the migration adds the app column';
like $migrations, qr/alter table ai_spend add column run/, 'and the run column';
like $migrations, qr/alter table ai_spend add column metered/, 'and the metered column';
like $migrations, qr/idx_ai_spend_app on ai_spend \(app, minute\)/, 'and an app/minutes index';
like $migrations, qr/idx_ai_spend_role on ai_spend \(role, minute\)/, 'and a role/minutes index';
like $migrations, qr/create table if not exists ai_spend_daily/, 'the day rollup table is created';
like $migrations, qr/create unique index if not exists idx_ai_spend_daily on ai_spend_daily \(machine, day, provider, model, role, app\)/,
	'with its natural key made unique';

my $backup = read_file("$root/lib/JawnOS/Domain/Backup.pm");
like $backup, qr/qw\(backups ai_budget ai_spend ai_spend_daily continent notifications\)/,
	'the rollup cannot start a sync by itself and is not in an archive';

my $run = read_file("$root/lib/JawnOS/Domain/Run.pm");
like $run, qr/&ai_spend_daily_backfill\(\)/, 'the heartbeat runs the guarded backfill';

done_testing();
