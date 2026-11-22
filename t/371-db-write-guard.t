# tests-for: lib/JawnOS/Domain/Key.pm lib/JawnOS/Domain/Loader.pm
# covers:    a write or delete whose only key is undef - or which has no key at
#            all - is refused. SQL::Abstract turns that into "match every row";
#            a settings backfill once updated by `id` (null on every row) and
#            wrote one value over 43k rows. A defined key still writes normally.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Temp qw(tempfile);
use Mojo::SQLite;

# A throwaway SQLite file installed as the holder, so the live database is
# never touched (the same shape t/164 and t/175 use).
my ($fh, $dbfile) = tempfile('jawnos-db-write-guard-XXXXXX', TMPDIR => 1, UNLINK => 1);
close $fh;
my $sql = Mojo::SQLite->new('sqlite:' . $dbfile);
my $db  = $sql->db;
$db->query('create table settings (setting text, value text, timestamp text, '
	. 'id integer primary key autoincrement, app text, server_time text, device text, '
	. 'browser_tab_id text, uuid text, ost text, subsetting text)');
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

$db->query("insert into settings (setting,value,app,uuid,server_time,device) "
	. "values ('home_plate','before','me','u1','100','computer')");

my @log;
no warnings 'redefine';
local *subs::log_writer = sub { push @log, [ @_ ] };

is( subs::db_update('settings', { value => 'after' }, { id => undef }), 0,
	'a null key refuses the update' );
my $row = &subs::db_select('settings', ['value'], { uuid => 'u1' })->hashes->[0];
is( $row->{'value'}, 'before', 'the whole table was not written' );
ok( scalar @log && $log[0]->[0] =~ /db_update refused settings/,
	'and the refusal names the table in the log' );

is( subs::db_update('settings', { value => 'after' }, {}), 0,
	'an update with no key at all is refused too' );
is( &subs::db_select('settings', ['value'], { uuid => 'u1' })->hashes->[0]->{'value'}, 'before',
	'still untouched' );

subs::db_update('settings', { value => 'after' }, { uuid => 'u1' });
ok(1, 'a defined key is allowed through');
is( &subs::db_select('settings', ['value'], { uuid => 'u1' })->hashes->[0]->{'value'}, 'after',
	'and the value landed' );

is( subs::db_delete('settings', { id => undef }), 0,
	'a null key refuses the delete' );
is( scalar @{ &subs::db_select('settings', ['uuid'], { uuid => 'u1' })->hashes }, 1,
	'no row was deleted' );
is( subs::db_delete('settings', {}), 0, 'a delete with no key is refused' );
is( scalar @{ &subs::db_select('settings', ['uuid'], { uuid => 'u1' })->hashes }, 1,
	'still present' );

done_testing();
