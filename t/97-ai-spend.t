# tests-for: lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Loader.pm

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);
use JSON::PP ();

# The domain layer is lazy: load the real definitions before the local *subs::
# stubs below, or a later module load would replace them.
subs::preload($_) for qw(ai_spend_minute_key ai_spend_note where_lookup_stats where_audit_uuid where_audit_bank where_audit_enabled where_audit_cadence where_audit_interval where_audit_report where_audit_next where_audit_due where_audit_run where_audit_tick ai_spend_buckets ai_spend_roles ai_spend_prune);

my $root = "$FindBin::Bin/..";

# The per-call AI token ledger. Every model call writes its own row carrying the
# minute, model and role, so the balance chart can put tokens against the minute
# an account fell in and name who spent them. These tests pin the minute key, the
# write shape (one row per call, no merge), the three read functions the chart
# calls, and the prune.

my $now = ts(2026, 11, 2, 17, 43, 59);

# ---- the minute key ---------------------------------------------------------
is &subs::ai_spend_minute_key(ts(2026, 11, 2, 17, 43, 59)), '2026-11-02 17:43',
	'a minute key is the local clock minute';
is &subs::ai_spend_minute_key(ts(2026, 11, 2, 17, 43, 0)), '2026-11-02 17:43',
	'and ignores the seconds';
is &subs::ai_spend_minute_key(ts(2026, 11, 2, 0, 5)), '2026-11-02 00:05',
	'midnight is its own minute';

# ---- the write: one row per call --------------------------------------------
{
	package FakeRowSet;
	sub new { my ($class, $rows, $count) = @_; return bless { rows => $rows, rows_count => $count }, $class }
	sub hashes { return $_[0]->{'rows'} }
	sub rows { return $_[0]->{'rows_count'} }
}
package main;

{
	no warnings 'redefine';
	local *subs::ai_house_me = sub { 'machine-a' };
	local *subs::rightNow = sub { $now };
	my @inserted;
	local *subs::db_insert = sub {
		my ($table, $row) = @_;
		push @inserted, { %{$row} };
		return 1;
	};
	ok &subs::ai_spend_note('deepseek', 800, 200, 'deepseek-chat', 'coding_assistant'),
		'a call banks its usage';
	is scalar @inserted, 1, 'with one row';
	my $row = $inserted[0];
	is $row->{'minute'}, '2026-11-02 17:43', 'under its clock minute';
	is $row->{'provider'}, 'deepseek', 'naming the provider';
	is $row->{'model'}, 'deepseek-chat', 'the model';
	is $row->{'role'}, 'coding_assistant', 'and the role that asked';
	is $row->{'tokens_in'}, 800, 'with its prompt tokens';
	is $row->{'tokens_out'}, 200, 'and its completion tokens';
	is $row->{'calls'}, 1, 'and one call';
	is $row->{'machine'}, 'machine-a', 'the row names this machine';
	ok !exists $row->{'uuid'}, 'and leaves the uuid to db_insert (a new row, not an update)';
	ok !exists $row->{'hour'}, 'the old hour column is not written';

	ok &subs::ai_spend_note('deepseek', 500, 100, 'deepseek-chat', 'coding_assistant'),
		'a second call in the same minute';
	is scalar @inserted, 2, 'writes a second row rather than merging';
	is $inserted[1]->{'tokens_in'}, 500, 'with its own tokens';

	ok !&subs::ai_spend_note('deepseek', undef, undef), 'a call that reported no usage is not banked';
	ok !&subs::ai_spend_note('deepseek', 0, 0), 'and neither is a zero';
	is scalar @inserted, 2, 'so nothing more was written';
}

# ---- the read: buckets ------------------------------------------------------
{
	no warnings 'redefine';
	my ($seen_sql, $seen_since);
	local *subs::db_query = sub {
		my ($sql, $since) = @_;
		($seen_sql, $seen_since) = ($sql, $since);
		return FakeRowSet->new([
			{ provider => 'deepseek',   model => 'm1', k => '2026-11-02 10:00', tokens => 100, calls => 1 },
			{ provider => 'deepseek',   model => 'm2', k => '2026-11-02 10:01', tokens => 50,  calls => 1 },
			{ provider => 'deepseek',   model => 'm1', k => '2026-11-02 10:02', tokens => 30,  calls => 1 },
			{ provider => 'deepseek',   model => '',   k => '2026-11-02 10:01', tokens => 5,   calls => 1 },
			{ provider => 'openrouter', model => 'm9', k => '2026-11-02 10:01', tokens => 10,  calls => 1 },
			{ provider => 'deepseek',   model => 'm1', k => '',                 tokens => 999, calls => 1 },
		]);
	};
	my $map = &subs::ai_spend_buckets('2m', '2026-11-02 10:00');
	like $seen_sql, qr/minute as k/, 'the 2m read groups by the full minute';
	like $seen_sql, qr/where minute >= \?/, 'and counts only minutes inside the chart';
	is $seen_since, '2026-11-02 10:00', 'from the since key it was given';
	is $map->{'deepseek'}->{'2026-11-02 10:00'}->{'tokens'}, 155,
		'10:00 and 10:01 fold into one even-minute bucket';
	is $map->{'deepseek'}->{'2026-11-02 10:00'}->{'calls'}, 3, 'with their calls added';
	is $map->{'deepseek'}->{'2026-11-02 10:00'}->{'models'}->{'m1'}, 100, 'and the model map merged';
	is $map->{'deepseek'}->{'2026-11-02 10:00'}->{'models'}->{'m2'}, 50, 'for every model in the bucket';
	ok !exists $map->{'deepseek'}->{'2026-11-02 10:00'}->{'models'}->{''}, 'an unnamed model is not a key';
	is $map->{'deepseek'}->{'2026-11-02 10:02'}->{'tokens'}, 30, '10:02 is left in its own bucket';
	is $map->{'openrouter'}->{'2026-11-02 10:00'}->{'tokens'}, 10, 'and providers stay apart';

	my $hourly = &subs::ai_spend_buckets('hour', '2026-11-02 09:00');
	like $seen_sql, qr/substr\(minute, 1, 13\) as k/, 'the hour read groups by the hour prefix';
	is $hourly->{'deepseek'}->{'2026-11-02 10:01'}->{'tokens'}, 55, 'the hour read leaves minutes in their own buckets, unfolded';

	my $daily = &subs::ai_spend_buckets('day', '2026-11-01 00:00');
	like $seen_sql, qr/substr\(minute, 1, 10\) as k/, 'the day read groups by the date prefix';

	&subs::ai_spend_buckets('week', '');
	like $seen_sql, qr/substr\(minute, 1, 13\) as k/, 'an unknown granularity falls back to hour';
}

# The hour and day grouping itself, with keys SQLite would return.
{
	no warnings 'redefine';
	local *subs::db_query = sub {
		return FakeRowSet->new([
			{ provider => 'deepseek', model => 'm1', k => '2026-11-02 10', tokens => 70, calls => 1 },
			{ provider => 'deepseek', model => 'm2', k => '2026-11-02 10', tokens => 30, calls => 2 },
			{ provider => 'deepseek', model => 'm1', k => '2026-11-02 11', tokens => 10, calls => 1 },
		]);
	};
	my $hourly = &subs::ai_spend_buckets('hour', '');
	is $hourly->{'deepseek'}->{'2026-11-02 10'}->{'tokens'}, 100, 'an hour adds its models in';
	is $hourly->{'deepseek'}->{'2026-11-02 10'}->{'calls'}, 3, 'with its calls';
	is $hourly->{'deepseek'}->{'2026-11-02 10'}->{'models'}->{'m1'}, 70, 'and keeps each model';
	is $hourly->{'deepseek'}->{'2026-11-02 11'}->{'tokens'}, 10, 'a second hour is its own bucket';
}

# ---- the read: roles --------------------------------------------------------
{
	no warnings 'redefine';
	my $seen_since;
	local *subs::db_query = sub {
		my ($sql, $since) = @_;
		$seen_since = $since;
		return FakeRowSet->new([
			{ provider => 'deepseek',   role => 'coding_assistant', tokens => 500 },
			{ provider => 'deepseek',   role => '',                 tokens => 20 },
			{ provider => 'openrouter', role => 'help_assistant',   tokens => 5 },
		]);
	};
	my $roles = &subs::ai_spend_roles('2026-11-02 00:00');
	is $seen_since, '2026-11-02 00:00', 'the role read asks only for minutes inside the chart';
	is $roles->{'deepseek'}->{'coding_assistant'}, 500, 'tokens are reported per role';
	is $roles->{'deepseek'}->{''}, 20, 'a role that was never named is its own bucket';
	is $roles->{'openrouter'}->{'help_assistant'}, 5, 'and providers stay apart';
}

# ---- the prune --------------------------------------------------------------
{
	no warnings 'redefine';
	my @seen;
	local *subs::rightNow = sub { $now };
	local *subs::db_query = sub {
		my ($sql, @params) = @_;
		push @seen, [ $sql, @params ];
		return FakeRowSet->new(undef, 7);
	};
	is &subs::ai_spend_prune(40), 7, 'the prune reports the rows it deleted';
	my ($seen_sql, @seen_params) = @{ $seen[0] };
	like $seen_sql, qr/minute < \?/, 'it bounds the per-call rows by minute';
	like $seen_sql, qr/hour < \?/, 'and the legacy hourly rows by their day';
	is $seen_params[0], '2026-09-23 17:43', 'forty days before now, in local minutes';
	is $seen_params[1], '2026-09-23', 'with the day bound for the old hour column';
	ok scalar(grep { $_->[0] =~ /from where_calls/ } @seen),
		'and the locator ledger is pruned on the same window';

	local *subs::db_query = sub { return undef };
	is &subs::ai_spend_prune(40), 0, 'a failed delete is reported as zero, not a quiet success';
}

# ---- the migration ----------------------------------------------------------
my $migrations = read_file( root() . '/lib/JawnOS/Domain/Migrations.pm' );
like $migrations, qr/alter table ai_spend add column minute/, 'the migration adds the minute column';
like $migrations, qr/alter table ai_spend add column model/, 'and the model column';
like $migrations, qr/alter table ai_spend add column role/, 'and the role column';
like $migrations, qr/idx_ai_spend_minute/, 'and an index on the minute';
like $migrations, qr/idx_ai_spend_provider/, 'and one on provider and minute';
like $migrations, qr/drop index if exists idx_ai_spend\b/, 'and drops the old unique hourly index';
unlike $migrations, qr/create unique index if not exists idx_ai_spend\b/,
	'no unique index is created on a per-call table';

# ---- the locator's own ledger ----------------------------------------------
{
	require DBI;
	my $dbh = DBI->connect('dbi:SQLite::memory:', '', '', { RaiseError => 1, PrintError => 0 });
	$dbh->do('create table where_calls (uuid text, machine text, minute text, name text, hit int, hits int, ost text, server_time text)');
	$dbh->do('create table where_feedback (uuid text, call_uuid text, machine text, minute text, name text, verdict text, found text, note text, ost text, server_time text)');
	$dbh->do("insert into where_calls (minute,name,hit,hits) values ('2026-11-02 17:43','a',1,1)");
	$dbh->do("insert into where_calls (minute,name,hit,hits) values ('2026-11-02 17:44','b',0,0)");
	$dbh->do("insert into where_calls (minute,name,hit,hits) values ('2026-11-01 09:00','c',1,2)");
	$dbh->do("insert into where_feedback (minute,name,verdict) values ('2026-11-02 17:45','a','right')");
	$dbh->do("insert into where_feedback (minute,name,verdict) values ('2026-11-02 17:46','b','wrong')");
	$dbh->do("insert into where_feedback (minute,name,verdict) values ('2026-11-01 09:05','c','right')");
	$dbh->do("insert into where_feedback (minute,name,verdict) values ('2026-11-02 17:47','d','miss')");
	no warnings 'redefine';
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		my $sth = $dbh->prepare($sql);
		$sth->execute(@args);
		return FakeRowSet->new($sth->fetchall_arrayref({}), 1);
	};
	my $stats = &subs::where_lookup_stats('2026-11-02');
	is($stats->{'calls'}, 2, 'today counts both locator lookups');
	is($stats->{'hits'}, 1, 'a declaration is a hit');
	is($stats->{'misses'}, 1, 'an unknown name is a miss');
	is($stats->{'right'}, 1, 'and the confirmed hit is counted');
	is($stats->{'wrong'}, 2, 'and the wrong and missed reports');
}
{
	no warnings 'redefine';
	local *subs::db_query = sub { die "no such table: where_calls\n" };
	my $stats = &subs::where_lookup_stats('2026-11-02');
	is_deeply($stats, { calls => 0, hits => 0, misses => 0, right => 0, wrong => 0 },
		'a pre-migration database reads as no calls');
}

# ---- the panel reads it -----------------------------------------------------
like(read_file("$root/lib/JawnOS/Controller/manager_configure4.pm"),
	qr/where_stats => &subs::where_lookup_stats/, 'the Sys panel is given the locator stats');
like(read_file("$root/templates/configure/system_setting_list.html.ep"),
	qr/where_lookup_note/, 'and shows them beside the cost ledger');

# ---- the locator audit's cadence -------------------------------------------
{
	no warnings 'redefine';
	local *subs::setting_grabber = sub { 'hourly' };
	is(&subs::where_audit_cadence(), 'hourly', 'the cadence is read from the house settings');
	is(&subs::where_audit_interval('hourly'), 3600 * 1000, 'hourly is an hour');
	is(&subs::where_audit_interval('daily'), 86400 * 1000, 'daily is a day');
	is(&subs::where_audit_interval('weekly'), 7 * 86400000, 'weekly is seven days');
	is(&subs::where_audit_interval('monthly'), 30 * 86400000, 'monthly is thirty days');
	is(&subs::where_audit_interval('yearly'), 365 * 86400000, 'yearly is a year');
	is(&subs::where_audit_interval('off'), 0, 'off has no interval');
}
{
	no warnings 'redefine';
	local *subs::setting_grabber = sub { 'nonsense' };
	is(&subs::where_audit_cadence(), 'off', 'an unknown cadence reads as off');
}
{
	no warnings 'redefine';
	local *subs::setting_grabber = sub { undef };
	is(&subs::where_audit_enabled(), 1, 'the butler is on by default');
	local *subs::setting_grabber = sub { 'off' };
	is(&subs::where_audit_enabled(), 0, 'off turns the butler off');
	local *subs::setting_grabber = sub { 'on' };
	is(&subs::where_audit_enabled(), 1, 'on turns it back on');
}
{
	no warnings 'redefine';
	local *subs::setting_grabber = sub { 'off' };
	local *subs::where_audit_report = sub { {} };
	local *subs::rightNow = sub { 1_000_000_000_000 };
	is(&subs::where_audit_due(), 0, 'a paused butler is never due');
	is(&subs::where_audit_next(), 0, 'and has no next run');
}
{
	no warnings 'redefine';
	my $now = 1_000_000_000_000;
	local *subs::rightNow = sub { $now };
	local *subs::setting_grabber = sub { 'hourly' };
	local *subs::where_audit_report = sub { {} };
	is(&subs::where_audit_due(), 1, 'with no report yet the audit is due');
	is(&subs::where_audit_next(), 0, 'and there is no next run to show');

	local *subs::where_audit_report = sub { { at => $now - 30 * 60 * 1000, ok => 1 } };
	is(&subs::where_audit_due(), 0, 'a run half an hour ago is not due');
	is(&subs::where_audit_next(), $now + 30 * 60 * 1000, 'the next run is an hour after the last');

	local *subs::where_audit_report = sub { { at => $now - 2 * 3600 * 1000, ok => 1 } };
	is(&subs::where_audit_due(), 1, 'a run two hours ago is due');

	local *subs::where_audit_report = sub { { at => $now - 2 * 3600 * 1000, attempt => $now - 60 * 1000, ok => 0 } };
	is(&subs::where_audit_due(), 0, 'a failure backs off for five minutes');
}

# ---- the report is synced ----------------------------------------------------
{
	require DBI;
	my $dbh = DBI->connect('dbi:SQLite::memory:', '', '', { RaiseError => 1, PrintError => 0 });
	$dbh->do('create table where_audit (uuid text, machine text unique, at text, report text, ost text, server_time text)');
	$dbh->do('insert into where_audit (uuid,machine,at,report,server_time) values (?,?,?,?,?)',
		undef, 'old', 'desktop', 1000, JSON::PP->new->encode({ at => 1000, ok => 1, summary => { calls => 3 } }), 1000);
	$dbh->do('insert into where_audit (uuid,machine,at,report,server_time) values (?,?,?,?,?)',
		undef, 'new', 'laptop', 2000, JSON::PP->new->encode({ at => 2000, ok => 1, summary => { calls => 4 } }), 2000);
	no warnings 'redefine';
	my $seen_sql;
	local *subs::db_query = sub {
		my ($sql, @args) = @_;
		$seen_sql = $sql;
		my $sth = $dbh->prepare($sql);
		$sth->execute(@args);
		return FakeRowSet->new($sth->fetchall_arrayref({}), 1);
	};
	my $report = &subs::where_audit_report();
	like $seen_sql, qr/order by cast\(server_time as integer\) desc/,
		'the newest synced report is the one shown';
	is $report->{'summary'}{'calls'}, 4, 'with the latest run\'s numbers';
	is $report->{'machine'}, 'laptop', 'and the machine that made it';
}
{
	no warnings 'redefine';
	local *subs::db_query = sub { die "no such table: where_audit\n" };
	is_deeply(&subs::where_audit_report(), {}, 'a pre-migration database reads as no report');
}

# ---- a run banks the script's JSON report -----------------------------------
{
	no warnings 'redefine';
	my $dir = tempdir(CLEANUP => 1);
	make_path("$dir/scripts");
	write_file("$dir/scripts/where_audit.pl", <<'FAKE');
print '{"days":14,"since":"2026-11-02 10:00","summary":{"calls":2},"misses":[],"wrong":[],"drift":[],"findings":0}';
FAKE
	my $saved;
	{
		package FakeMinion;
		sub lock { 1 }
		sub unlock { 1 }
	}
	package main;
	local *subs::home = sub { $dir };
	local *subs::ai_house_me = sub { 'machine-a' };
	local *subs::minion_grabber = sub { bless {}, 'FakeMinion' };
	local *subs::where_audit_report = sub { {} };
	local *subs::db_select = sub { FakeRowSet->new([]) };
	local *subs::db_insert = sub { my ($table, $row) = @_; $saved = $row; 1 };
	local *subs::db_update = sub { 1 };
	local *subs::rightNow = sub { 1_000_000_000_000 };
	ok(&subs::where_audit_run({ reason => 'test' }), 'a run banks the report');
	my $banked = JSON::PP->new->decode($saved->{'report'});
	is($banked->{'ok'}, 1, 'the report is marked ok');
	is($banked->{'summary'}{'calls'}, 2, 'and carries what the script found');
	is($banked->{'reason'}, 'test', 'with the reason it ran');
	is($banked->{'at'}, 1_000_000_000_000, 'stamped when it finished');
	is($saved->{'machine'}, 'machine-a', 'the row names this machine');
	is($saved->{'uuid'}, &subs::where_audit_uuid('machine-a'), 'under the machine\'s natural key');
	is($saved->{'server_time'}, 1_000_000_000_000, 'and is stamped for the peer sync');
}

# ---- the report is a synced table, not the machine-local cache --------------
{
	require DBI;
	my @dbs;
	no warnings 'redefine';
	local *subs::ai_house_me = sub { 'machine-a' };
	local *subs::rightNow = sub { 1_000_000_000_000 };
	local *subs::db_select = sub { FakeRowSet->new([]) };
	local *subs::db_update = sub { 1 };
	local *subs::db_insert = sub { my ($table, $row) = @_; push @dbs, [ $table, $row ]; 1 };
	local *subs::cache_set = sub { die 'the report must not go to the cache\n' };
	ok &subs::where_audit_bank({ at => 1, summary => { calls => 1 } }), 'a report is banked';
	is $dbs[0][0], 'where_audit', 'in the synced table';
	ok exists $dbs[0][1]->{'server_time'}, 'with the server_time the peer sync needs';
}

like(read_file("$root/lib/JawnOS/Domain/Migrations.pm"), qr/create table if not exists where_audit/,
	'the migration creates the synced report table');

# ---- the audit is wired to the button and the master -------------------------
like(read_file("$root/perl/President.pl"), qr/where_audit_tick/,
	'the master ticks the locator audit');
like(read_file("$root/lib/JawnOS/Controller/manager_configure4.pm"), qr/sub action_19400/,
	'the run-now route has an action');
like(read_file("$root/lib/JawnOS/Routes/manager_configure4.pm"), qr#where_audit/run#,
	'and the route reaches it');
like(read_file("$root/templates/configure/system_setting_list.html.ep"), qr/where_audit_cadence/,
	'the Sys panel offers the cadence');
like(read_file("$root/templates/configure/system_setting_list.html.ep"), qr/where_audit_enabled/,
	'and the butler switch');
like(read_file("$root/templates/configure/system_setting_list.html.ep"), qr/Run on \{0\}/,
	'and names the machine that made the report');

done_testing();
