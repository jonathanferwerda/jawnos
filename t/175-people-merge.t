# tests-for: lib/JawnOS/Manager/Part17.pm
# covers:    a synced row is merged even when its table has no `timestamp`
#            column. `people` has none, and the merge used to gate the whole
#            write path on `timestamp`: every people row was read, reported as
#            merged, and silently dropped. A table that does have `timestamp`
#            (notes) keeps merging as before.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;

# A throwaway SQLite file installed as the holder, so the live database is
# never touched (the same shape t/164 uses for the settings merge).
my ($fh, $dbfile) = tempfile('jawnos-people-merge-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table people (uuid text, name text, privilege text, status text, '
	. 'created text, ost text, server_time text, app text)');
$db->query('create table notes (uuid text, app text, text text, timestamp text, '
	. 'server_time text, ost text)');
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
$db->query('create table cache (app text, context text, subcontext text, data text, '
	. 'device text, timestamp text, server_time text, uuid text, ost text)');
$db->query('create table remote_machines (uuid text, signatorial text, deletions text, server_time text, ost text)');
$db->query('create table sync_log (id integer primary key autoincrement, '
	. 'server_time text, signatorial text, tbl text, app text, uuid text, '
	. 'scope text, additional text, ost text)');
my @st = stat($dbfile);
$gb::database_holder = {
	server_time => &subs::rightNow(),
	database    => $dbfile,
	db          => $db,
	dbh         => $db->dbh,
	sql         => $sql,
	pid         => $$,
	dev         => $st[0],
	ino         => $st[1],
};
$subs::say_quiet = 1;
$subs::sync_table_cache = undef;

# The Manager part defines package Manager directly; requiring the file is
# enough (Manager.pm itself wants a live Mojolicious app).
require JawnOS::Manager::Part17;

my $device = &subs::device_setter();

# One row, driven through the same merge the sync uses. No `deletions`, no job.
sub merge_row {
	my ($table, $row) = @_;
	my $served = 0;
	my $next = sub { return $served++ ? undef : $row; };
	my $ctx = {
		configuration      => {},
		misc_settings      => {},
		device             => $device,
		deletions          => [],
		universal_settings => {},
		updateables        => [],
		sync_job           => undef,
		auuid              => 'test-auuid',
		colour             => '#000000',
	};
	return Manager::merge_table_rows($ctx, $table, $next, 1, 1, 1);
}

sub count_rows {
	my ($table, $where) = @_;
	return &subs::db_select($table, ['uuid'], $where)->hashes || [];
}

# `people` has no `timestamp` column. It used to be dropped before the insert.
my $short = merge_row('people', {
	uuid => 'person-1', name => 'Glen', privilege => '', status => 'active',
	created => '100', server_time => '100', ost => '100', app => 'glen',
});
is(scalar @{ count_rows('people', { uuid => 'person-1' }) }, 1,
	'a table without a timestamp column still merges its row');
is($short, 0, 'and the merge reports a complete table');

# The row is a normal row: a newer peer copy updates it in place.
merge_row('people', {
	uuid => 'person-1', name => 'Glen', privilege => 'citizen', status => 'active',
	created => '100', server_time => '200', ost => '200', app => 'glen',
});
my $updated = count_rows('people', { uuid => 'person-1' });
is(scalar @{$updated}, 1, 'a newer copy updates rather than duplicating');
is($updated->[0]->{'uuid'}, 'person-1', 'by uuid');

# A table that does carry `timestamp` keeps the old path.
merge_row('notes', {
	uuid => 'note-1', app => 'notes', text => 'peer copy',
	timestamp => '100', server_time => '100', ost => '100',
});
is(scalar @{ count_rows('notes', { uuid => 'note-1' }) }, 1,
	'a table with a timestamp still merges');

done_testing();
