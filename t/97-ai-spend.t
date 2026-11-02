# tests-for: lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Migrations.pm lib/JawnOS/Domain/Ai2.pm lib/JawnOS/Domain/Loader.pm

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

# The domain layer is lazy: load the real definitions before the local *subs::
# stubs below, or a later module load would replace them.
subs::preload($_) for qw(ai_spend_minute_key ai_spend_note ai_spend_buckets ai_spend_roles ai_spend_prune);

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
	my ($seen_sql, @seen_params);
	local *subs::rightNow = sub { $now };
	local *subs::db_query = sub {
		my ($sql, @params) = @_;
		($seen_sql, @seen_params) = ($sql, @params);
		return FakeRowSet->new(undef, 7);
	};
	is &subs::ai_spend_prune(40), 7, 'the prune reports the rows it deleted';
	like $seen_sql, qr/minute < \?/, 'it bounds the per-call rows by minute';
	like $seen_sql, qr/hour < \?/, 'and the legacy hourly rows by their day';
	is $seen_params[0], '2026-09-23 17:43', 'forty days before now, in local minutes';
	is $seen_params[1], '2026-09-23', 'with the day bound for the old hour column';

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

done_testing();
