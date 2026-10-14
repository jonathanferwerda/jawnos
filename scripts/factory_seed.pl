#!/usr/bin/perl
#
# Build database/initial.enc - the factory seed a new install is provisioned
# from: the shipped schema plus the factory settings (appearance and
# configuration defaults, no personal data), sealed under the factory code.
#
#   perl scripts/factory_seed.pl
#
# The sealed seed is opened by scripts/jawnos_setup.pl with the same code and
# re-sealed under the user's own unlock code, so the factory code guards an
# empty template, not a secret. Re-run this after changing the factory settings
# below, and commit the new database/initial.enc.
#
use strict;
use warnings;
use Cwd ();
use FindBin qw($Bin);
use Mojo::SQLite;
use Crypt::Simple;
use File::Path qw(make_path);

my $root = Cwd::abs_path("$Bin/..");
chdir $root or die "cannot chdir to $root: $!\n";

# must match $FACTORY_CODE in scripts/jawnos_setup.pl; the seed is sealed with
# openssl enc -e -k <code> -aes-256-ctr -pbkdf2, standard recorded in the appendage
our $FACTORY_CODE = 'JAWNOS-FACTORY-SEED-v1';
my $standard = 'aes-256-ctr';
my $splitter = "--simple--split--and--whatnot--";

sub encrypter { my ( $secret, $content ) = @_; local *encrypt; local *decrypt; Crypt::Simple->import( passphrase => $secret ); return encrypt($content); }
sub randstr    { my $len = shift || 20; my @c = ( 'A'..'Z', 'a'..'z', 0..9 ); my $s = ''; $s .= $c[ int( rand(@c) ) ] for 1 .. $len; return $s; }

# ---------------------------------------------------------------------------
# the factory settings: what a fresh install starts with
# ---------------------------------------------------------------------------
# Each row is [ app, setting, value ]. These are appearance and configuration
# defaults only - no personal data. Extend as the factory set is defined.
my @factory_settings = (
	[ 'misc', 'encryption_standard', $standard ],
	[ 'me',   'name',                'Me' ],
	[ 'me',   'warranty',            '-10d' ],
	[ 'me',   'currency',            'CAD' ],
	[ 'me',   'worth',               '0' ],
);

my $tmp = "$ENV{HOME}/.president/factory_seed_" . randstr(8) . '.db';
make_path("$ENV{HOME}/.president") unless -d "$ENV{HOME}/.president";
my $build = `sqlite3 $tmp < database/schema.sql 2>&1`;
die "could not build the schema: $build\n" if $? != 0 || !-e $tmp;

my $sql = Mojo::SQLite->new('sqlite:' . $tmp);
my $db  = $sql->db;
$db->query('PRAGMA journal_mode=WAL');
my $now = time() * 1000;
$db->insert( 'security', {
	level       => 1,
	database    => 'jawnos.db',
	timestamp   => $now,
	server_time => $now,
	credential  => encrypter( $FACTORY_CODE, $FACTORY_CODE ),
	uuid        => randstr(30),
} );
foreach my $s (@factory_settings) {
	$db->insert( 'settings', {
		app         => $s->[0],
		setting     => $s->[1],
		value       => $s->[2],
		timestamp   => $now,
		server_time => $now,
		device      => 'computer',
		uuid        => randstr(20),
	} );
}
$db->query('PRAGMA wal_checkpoint(TRUNCATE)');
undef $db;
undef $sql;

my $temp = $tmp . '.1.db';
`sqlite3 $tmp ".backup '$temp'"`;
my $out = "$root/database/initial.enc";
`openssl enc -e -k "$FACTORY_CODE" -$standard -pbkdf2 -in $temp -out $out`;
die "openssl failed to seal the seed\n" unless -e $out && -s $out > 100;
open my $fh, '>>', $out or die $!;
binmode $fh;
print $fh ( $splitter . encrypter( $FACTORY_CODE, $standard ) );
close $fh;
`shred -u $tmp $temp $tmp-wal $tmp-shm 2>/dev/null`;
`rm -f $tmp-wal $tmp-shm $temp`;

print "wrote $out (" . ( -s $out ) . " bytes, " . scalar(@factory_settings) . " factory settings)\n";
