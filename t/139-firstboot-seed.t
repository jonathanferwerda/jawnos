# tests-for: scripts/jawnos_setup.pl desktop/mkosi/mkosi.extra/usr/local/bin/jawnos-firstboot
# covers:    A seed is only a house when its live database is non-empty and has the schema; a stale 0-byte database is dropped.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use RepoSource ();

# On VM 103 firstboot wrote the unlock code and its .seeded marker even though
# `cp -f $working $live_db` had left a 0-byte database. It treated any existing
# file as an adopted house on the next boot, and the app crash-looped on
# President.pl's sync_jobs_reap. These are the conditions that now have to pass:
# the live copy is verified by jawnos_setup.pl, firstboot only adopts a database
# that is non-empty (an older schema is the app's to migrate), and a fresh seed
# must answer the schema probe.

my $root = RepoSource::repo_root();
my $tmp  = tempdir( 'jawnos-seed-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

sub read_text {
	my ($path) = @_;
	open(my $fh, '<', $path) or die "$path: $!";
	local $/;
	return <$fh>;
}

sub spew {
	my ( $path, $text ) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $text;
	close $fh;
}

# The pristine tree shape the image ships: the seed files, the setup script and
# the language catalogue. The live database is deliberately not copied.
sub make_tree {
	my ($name) = @_;
	my $dir = "$tmp/$name";
	make_path( "$dir/database", "$dir/scripts", "$dir/home" );
	copy( "$root/database/schema.sql",    "$dir/database/schema.sql" )    or die "schema: $!";
	copy( "$root/database/initial.enc",   "$dir/database/initial.enc" )   or die "seed: $!";
	copy( "$root/scripts/jawnos_setup.pl", "$dir/scripts/jawnos_setup.pl" ) or die "setup: $!";
	symlink( "$root/perl", "$dir/perl" ) or die "perl: $!";
	return $dir;
}

sub run_setup {
	my ( $dir, @args ) = @_;
	my $pid = open( my $fh, '-|' );
	die "fork: $!" unless defined $pid;
	if ( !$pid ) {
		chdir $dir or exit 127;
		$ENV{'HOME'} = "$dir/home";
		open STDERR, '>&', \*STDOUT or exit 127;
		exec $^X, 'scripts/jawnos_setup.pl', @args;
		exit 127;
	}
	local $/;
	my $out = <$fh>;
	close $fh;
	return ( $? >> 8, defined $out ? $out : '' );
}

sub sqlite_ok {
	my ( $db, $sql ) = @_;
	my $pid = open( my $fh, '-|' );
	die "fork: $!" unless defined $pid;
	if ( !$pid ) {
		open STDERR, '>', '/dev/null' or exit 127;
		exec 'sqlite3', $db, $sql;
		exit 127;
	}
	local $/;
	<$fh>;
	close $fh;
	return ( $? >> 8 ) == 0;
}

my $dir = make_tree('fresh');
my ( $code, $out ) = run_setup( $dir, '--seed', '--name', 'JawnOS', '--code', '12345678' );
is( $code, 0, 'a fresh seed succeeds' ) or diag($out);

my $db = "$dir/database/jawnos.db";
ok( -s $db, 'the live database is non-empty' );
ok( sqlite_ok( $db, 'select count(*) from sync_jobs' ), 'the live database has the sync_jobs table' );
ok( -s "$dir/database/backups/jawnos.enc", 'the sealed backup is non-empty' );
ok( -s "$dir/config.json", 'config.json was written' );

# A live copy that cannot be written must be an error, not a silent ok: that is
# the firstboot half of the VM 103 chain. A non-root run proves it by making the
# database directory read-only after the first seed created backups/.
SKIP: {
	skip 'root can write through a read-only directory', 3 if $< == 0;
	my $locked = make_tree('locked');
	run_setup( $locked, '--seed', '--name', 'JawnOS', '--code', '11112222' );
	unlink "$locked/database/jawnos.db";
	chmod 0555, "$locked/database";
	my ( $locked_code, $locked_out ) = run_setup( $locked, '--seed', '--name', 'JawnOS', '--code', '11112222' );
	chmod 0755, "$locked/database";
	isnt( $locked_code, 0, 'a failed live copy makes the seed fail' );
	like( $locked_out, qr/could not write the live database/,
		'and the error names the live database' );
	ok( !-s "$locked/database/jawnos.db", 'no empty live database is left behind' );
}

# The firstboot helpers themselves: the probe and the removal that lets the
# seed rebuild a stale database. Extracted from the shipped script so the test
# runs the same shell the unit runs, without root, systemd or the image.
my $firstboot = read_text("$root/desktop/mkosi/mkosi.extra/usr/local/bin/jawnos-firstboot");
my ($db_present) = $firstboot =~ /^(db_present\(\) \{\n.*?^\})$/ms;
my ($db_schema)  = $firstboot =~ /^(db_has_schema\(\) \{\n.*?^\})$/ms;
my ($drop_db)   = $firstboot =~ /^(drop_database\(\) \{\n.*?^\})$/ms;
ok( $db_present && $db_schema && $drop_db, 'the firstboot database helpers are present' );

my $helper = "$tmp/firstboot-helpers.sh";
spew(
	$helper,
	"set -eu\n$db_present\n$db_schema\n$drop_db\n"
		. "case \"\$1\" in\n"
		. "  present) db_present \"\$2\" ;;\n"
		. "  schema) db_has_schema \"\$2\" ;;\n"
		. "  drop) drop_database \"\$2\" ;;\n"
		. "esac\n"
);
sub helper_run {
	my ( $action, $path ) = @_;
	my $rc = system( 'sh', $helper, $action, $path );
	return $rc >> 8;
}

is( helper_run( 'present', $db ), 0, 'firstboot adopts the seeded database' );
is( helper_run( 'schema', $db ), 0, 'and the seeded database answers the schema probe' );

# What VM 103 had: a 0-byte live database, its sidecars, and an empty sealed
# copy. The probe must reject it and the helper must remove all three, so the
# seed (which leaves any existing file alone) can build a real database.
my $stale = "$dir/database/jawnos.db";
spew( $stale, '' );
spew( "$stale-wal", '' );
spew( "$stale-shm", '' );
spew( "$dir/database/backups/jawnos.enc", '' );
isnt( helper_run( 'present', $stale ), 0, 'a 0-byte database is not adopted' );
is( helper_run( 'drop', $stale ), 0, 'the helper drops it' );
ok( !-e $stale && !-e "$stale-wal" && !-e "$stale-shm", 'the database and its sidecars are gone' );
like( $firstboot, qr/\[ -s "\$ENC" \] \|\| rm -f "\$ENC"/, 'and an empty sealed copy is removed' );

# A non-empty database is adopted even when it predates sync_jobs: the app
# migrates it, and deleting it would lose the person's rows. Only a fresh seed
# is required to answer the schema probe.
my $other = "$tmp/other.db";
system( 'sqlite3', $other, 'create table not_sync (x)' );
is( helper_run( 'present', $other ), 0, 'a non-empty older database is still adopted' );
isnt( helper_run( 'schema', $other ), 0, 'though it does not answer the fresh-seed schema probe' );

# With the stale file dropped, the same seed path replaces it with a real house.
( $code, $out ) = run_setup( $dir, '--seed', '--name', 'JawnOS', '--code', '87654321' );
is( $code, 0, 'the seed runs after the stale database is dropped' ) or diag($out);
ok( -s $db, 'the live database is non-empty again' );
ok( sqlite_ok( $db, 'select count(*) from sync_jobs' ), 'and it has sync_jobs' );

# The source guards that are not portable without the image: the post-seed
# re-check and the non-empty launcher sentinel.
like( $firstboot, qr/if \[ "\$NEW_DB" = yes \] && ! db_has_schema "\$DB"; then/, 'firstboot re-checks a fresh seed against the schema' );
like( $firstboot, qr/\[ ! -s "\$STATE\/jawnos\/perl\/Manager\.pl" \]/,
	'the tree sentinel is the non-empty perl/Manager.pl, not a root Manager.pl' );
unlike( $firstboot, qr/\[ ! -f "\$STATE\/jawnos\/Manager\.pl" \]/,
	'a path that never exists no longer decides whether the tree is copied' );

done_testing();
