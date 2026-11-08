# tests-for: t/lib/JawnOSTest.pm
# covers:    The regression suite's sandbox. subroutines.pl resolves the
#            database from its own real path, and the sandbox links perl/ to
#            the checkout, so without an override every test opened the live
#            house database - and a test that saved a setting changed the
#            house (phone/ivr_routes was wiped by a nightly). The harness now
#            snapshots the house and points install_dir at the snapshot, and
#            the fork runner gives each child its own copy.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Cwd qw(abs_path);
use Test::More;
use JawnOSTest;

my $live = root() . '/database/jawnos.db';
my $test_db = &subs::database_path();

isnt($test_db, $live, 'the suite does not name the live house database');
isnt(abs_path(&subs::install_dir()), abs_path(root()),
	'the install dir is the sandbox, not the checkout');
like($test_db, qr{\A(?:/tmp|/var/tmp|/private/var/tmp|/dev/shm)/},
	'and the database lives outside the checkout');

SKIP: {
	skip 'this checkout has no house database to snapshot', 2 unless -f $live;
	ok(-f $test_db, 'the sandbox holds a snapshot of it');
	my $tables = &subs::db_query(
		"select count(*) as n from sqlite_master where type = 'table'")->hash;
	cmp_ok($tables->{'n'}, '>', 10, 'and the snapshot carries the schema');
}

done_testing();
