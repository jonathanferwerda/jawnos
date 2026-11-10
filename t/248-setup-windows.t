# tests-for: scripts/jawnos_setup.pl scripts/jawnos_deps.pl lib/JawnOS/Database/Bootstrap.pm
# covers:    first-run setup builds the database with DBD::SQLite instead of the
#           sqlite3 CLI, cuts the factory seed's note in Perl instead of tail,
#           and the dependency checker resolves a Windows home without getpwuid.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Slurp qw(read_file);
use RepoSource;
use JawnOS::Database::Bootstrap qw(
	read_seed seed_cipher seed_from_factory build_from_schema backup_database
);

my $root = repo_root();
my $src  = read_file("$root/scripts/jawnos_setup.pl");
my $deps = read_file("$root/scripts/jawnos_deps.pl");
my $tmp  = tempdir( 'jawnos-win-setup-XXXXXX', TMPDIR => 1, CLEANUP => 1 );

# --- no shell tools ---------------------------------------------------------
# A clean Windows box has neither `tail` nor `sqlite3`, and each call was a full
# stop for setup. Nothing in the script may invoke either.
unlike(
	$src,
	qr/(?:`\s*(?:tail|sqlite3)\b|system\(\s*['"](?:tail|sqlite3)['"]|'\|\s*,\s*['"](?:tail|sqlite3)['"])/,
	'setup never shells out to tail or sqlite3'
);
like( $src, qr/use JawnOS::Database::Bootstrap/,
	'it uses the shared bootstrap module' );

# --- the schema build, through DBD::SQLite ---------------------------------
copy( "$root/database/schema.sql", "$tmp/schema.sql" ) or die "schema: $!";
my ( $built, $build_error ) = build_from_schema( "$tmp/schema.sql", "$tmp/schema.db" );
ok( $built, 'schema.sql builds a database without the sqlite3 CLI' )
	or diag($build_error);
ok( -s "$tmp/schema.db" > 5000, 'the database is non-empty' );

require DBI;
my $dbh = DBI->connect( "dbi:SQLite:dbname=$tmp/schema.db", '', '',
	{ RaiseError => 1, PrintError => 0 } );
my ($tables) = $dbh->selectrow_array("select count(*) from sqlite_master where type='table'");
cmp_ok( $tables, '>', 10, 'the schema tables are present' );
my ($jobs) = $dbh->selectrow_array('select count(*) from sync_jobs');
is( $jobs, 0, 'and the sync_jobs table the firstboot probe asks for exists' );
$dbh->disconnect;

my ( $backed, $backup_error ) = backup_database( "$tmp/schema.db", "$tmp/backup.db" );
ok( $backed, 'the working database backs up through SQLite' ) or diag($backup_error);
ok( -s "$tmp/backup.db" > 5000, 'the backup is non-empty' );

# --- the seed note ---------------------------------------------------------
# factory_seed.pl writes ciphertext, the splitter, then a Crypt::Simple note
# naming the cipher. Read the pair without tail, and recover the name.
my $fixture = "$tmp/seed.enc";
{
	require Crypt::Simple;
	no warnings 'once';
	local *encrypt;
	local *decrypt;
	Crypt::Simple->import( passphrase => 'JAWNOS-FACTORY-SEED-v1' );
	open( my $fh, '>:raw', $fixture ) or die "seed: $!";
	print $fh 'CIPHERTEXT-BYTES', '--simple--split--and--whatnot--', encrypt('aes-256-cbc');
	close $fh;
}
my ( $ciphertext, $note ) = read_seed($fixture);
is( $ciphertext, 'CIPHERTEXT-BYTES', 'the splitter cuts the ciphertext out of the seed' );
ok( length $note, 'and leaves the note' );
is( seed_cipher($fixture), 'aes-256-cbc', 'the note names the cipher' );

my $plain = "$tmp/no-note.enc";
open( my $plain_fh, '>:raw', $plain ) or die "seed: $!";
print $plain_fh 'ONLY-CIPHERTEXT';
close $plain_fh;
my ( $only_ciphertext, $empty_note ) = read_seed($plain);
is( $only_ciphertext, 'ONLY-CIPHERTEXT', 'a seed with no note is all ciphertext' );
is( $empty_note, '', 'and its note is empty' );
ok( !defined seed_cipher($plain), 'so no cipher is guessed' );

# --- the missing-file -s check ---------------------------------------------
# `-s $working > 5000` warned when the seed had not produced a file. Both
# helpers must report the absence as a plain error, with no uninitialized value.
my @warnings;
{
	local $SIG{__WARN__} = sub { push @warnings, @_ };
	my ( $seeded, $seed_error ) = seed_from_factory( "$tmp/absent.enc", "$tmp/absent.db" );
	ok( !$seeded, 'a missing seed does not seed' );
	like( $seed_error, qr/missing/, 'and says it is missing' );
	my ( $made, $schema_error ) = build_from_schema( "$tmp/absent.sql", "$tmp/absent2.db" );
	ok( !$made, 'a missing schema does not build' );
	like( $schema_error, qr/missing/, 'and says it is missing' );
}
is( scalar @warnings, 0, 'neither path warns about an uninitialized -s' )
	or diag( join '', @warnings );

# --- the dependency checker's home -----------------------------------------
# jawnos_deps.pl runs before the app's modules, so it carries the same fallback
# chain as JawnOS::Platform::Paths::home. Pull the two subs out of the script
# and exercise them with a synthetic environment.
my ($resolve_src) = $deps =~ /^(sub resolve_home \{.*?^\})$/ms;
my ($env_src)     = $deps =~ /^(sub home_from_env \{.*?^\})$/ms;
ok( $resolve_src && $env_src, 'the checker keeps its home resolver in two subs' );
{
	no warnings 'redefine';
	eval "package SetupWinHome; $env_src\n$resolve_src\n1;" or die $@;
}
is( SetupWinHome::home_from_env( { 'HOME' => '/house/home' } ), '/house/home',
	'HOME answers first' );
is( SetupWinHome::home_from_env( { 'USERPROFILE' => 'C:\\Users\\j' } ), 'C:\\Users\\j',
	'USERPROFILE answers when HOME is unset' );
is( SetupWinHome::home_from_env( { 'HOMEDRIVE' => 'C:', 'HOMEPATH' => '\\Users\\x' } ),
	'C:\\Users\\x', 'the older HOMEDRIVE+HOMEPATH pair still works' );
ok( defined SetupWinHome::home_from_env( {} ),
	'an empty environment does not die in getpwuid' );

like( $deps, qr/^\s*require JawnOS::Platform;/m,
	'the checker can load the platform module first' );
like( $deps, qr/JawnOS::Platform::home\(\)/,
	'and asks it for the home directory' );

# --- the sqlite3 row is not demanded on Windows ---------------------------
like( $deps, qr/cmd => 'sqlite3'.*required_on\s*=>\s*sub\s*\{[^}]*MSWin32/,
	'the sqlite3 tool row is not required on Windows' );
like( $deps, qr/^sub have_command \{.*?return 1 unless tool_required\(\$t\);/ms,
	'have_command skips a tool its platform does not need' );

done_testing();
