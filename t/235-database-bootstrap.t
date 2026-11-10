# tests-for: lib/JawnOS/Domain/Key.pm lib/JawnOS/Platform/TLS.pm
# covers:    a fresh install builds its database from the factory seed or the
#            shipped schema, and issues a local certificate so the TLS
#            listeners can bind instead of dying before the panel is reachable.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";

use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use RepoSource;
use JawnOS::Platform::TLS;

my $root = repo_root();
require "$root/lib/JawnOS/Domain/Key.pm";

# ---------------------------------------------------------------- the schema
my $schema_dir = tempdir(CLEANUP => 1);
copy("$root/database/schema.sql", "$schema_dir/schema.sql") or die "schema: $!";
my $db = &subs::database_bootstrap(dir => $schema_dir);
ok($db && -e $db && -s $db > 5000, 'a fresh install builds jawnos.db from schema.sql');

require DBI;
my $dbh = DBI->connect("dbi:SQLite:dbname=$db", '', '', { RaiseError => 1, PrintError => 0 });
my ($tables) = $dbh->selectrow_array("select count(*) from sqlite_master where type='table'");
cmp_ok($tables, '>', 10, 'the schema tables are present');
$dbh->disconnect;

my $size = -s $db;
is(&subs::database_bootstrap(dir => $schema_dir), $db,
	'a second call returns the same database');
is(-s $db, $size, 'and does not rebuild it');

my $empty = tempdir(CLEANUP => 1);
ok(!defined &subs::database_bootstrap(dir => $empty),
	'no seed and no schema is undef, not a crash');

# ------------------------------------------------------------ the factory seed
SKIP: {
	skip 'openssl is not installed', 2 unless JawnOS::Platform::TLS::openssl();
	my $seed_dir = tempdir(CLEANUP => 1);
	copy("$root/database/initial.enc", "$seed_dir/initial.enc") or die "seed: $!";
	my $seeded = &subs::database_bootstrap(dir => $seed_dir);
	ok($seeded && -e $seeded && -s $seeded > 5000,
		'the factory seed provisions the database without sqlite3');
	my $sdb = DBI->connect("dbi:SQLite:dbname=$seeded", '', '', { RaiseError => 1, PrintError => 0 });
	my ($rows) = $sdb->selectrow_array("select count(*) from sqlite_master where type='table'");
	cmp_ok($rows, '>', 10, 'and the seeded database has its tables');
	$sdb->disconnect;
}

# ----------------------------------------------------------------- the cert
SKIP: {
	skip 'openssl is not installed', 3 unless JawnOS::Platform::TLS::openssl();
	my $tls_dir = tempdir(CLEANUP => 1);
	my $made = JawnOS::Platform::TLS::ensure_local_cert(dir => $tls_dir);
	ok($made->{'created'}, 'a missing certificate is issued');
	ok(-s "$tls_dir/fullchain.pem" && -s "$tls_dir/privkey.pem", 'both files are written');
	my $again = JawnOS::Platform::TLS::ensure_local_cert(dir => $tls_dir);
	ok(!$again->{'created'}, 'an existing pair is left alone');
}

done_testing();
