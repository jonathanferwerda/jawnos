# tests-for: lib/JawnOS/Domain/House2.pm lib/JawnOS/Domain/Crypt.pm lib/JawnOS/Domain/Loader.pm
# covers:    a live image whose vault was never seeded resolves its key from ~/UNLOCK-CODE.txt, judges it against the level-1 canary, and seeds the vault; a wrong code is refused and seeds nothing.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "lib";
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Slurp qw(write_file);
use JawnOSTest;

# VM 103's Exit failed because a live image never seeds the vault: firstboot
# builds the database with the unlock code as the level-1 canary and no ticket,
# and the live-local session opens the manager without passing through
# login_gate, which is the only thing that calls vault_seed. backup_now() then
# had no secret, openssl wrote nothing, and leave() refused (correctly) to
# shred the house behind it.
#
# The image writes its code beside the house (~/UNLOCK-CODE.txt, mode 0600) for
# the person at the machine, so suds_grabber() now reads it when the vault and
# the legacy ticket are both empty. suds_current() judges the candidate, so the
# file cannot become a key unless it is the canary's own secret.

my $root = root();
my $tmp  = tempdir('jawnos-unlock-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $code = '12345678';

# --- a machine shaped exactly like a fresh live image -----------------------
my $dir = "$tmp/image";
make_path("$dir/database", "$dir/scripts", "$dir/home");
copy("$root/database/schema.sql", "$dir/database/schema.sql") or die "schema: $!";
copy("$root/database/initial.enc", "$dir/database/initial.enc") or die "seed: $!";
copy("$root/scripts/jawnos_setup.pl", "$dir/scripts/jawnos_setup.pl") or die "setup: $!";
symlink("$root/perl", "$dir/perl") or die "perl: $!";
symlink("$root/lib",  "$dir/lib")  or die "lib: $!";

my $pid = open(my $setup, '-|');
die "fork: $!" unless defined $pid;
if (!$pid) {
	chdir $dir or exit 127;
	$ENV{'HOME'} = "$dir/home";
	open STDERR, '>&', \*STDOUT or exit 127;
	exec $^X, 'scripts/jawnos_setup.pl', '--seed', '--name', 'JawnOS', '--code', $code;
	exit 127;
}
my $setup_out = do { local $/; <$setup> };
close $setup;
is($? >> 8, 0, 'the live-image seed succeeds') or diag($setup_out);

# The app must read this tree, not the checkout's live database.
$subs::install_dir = $dir;
$subs::home_dir    = "$dir/home";
$gb::database_holder = {};

sub vault_rows {
	my $q = subs::db_query("select count(*) as n from settings where app = '__president' and setting = 'vault'");
	my $row = $q ? $q->hash : undef;
	return $row ? $row->{'n'} : -1;
}

# --- the precondition the failure came from --------------------------------
my @vault_before = subs::vault_read();
is(scalar(@vault_before), 0, 'a fresh live image has no vault');
my @legacy_before = subs::legacy_suds();
is(scalar(@legacy_before), 0, 'and no legacy ticket to derive the key');
is(vault_rows(), 0, 'the settings table holds no vault row');
is(subs::suds_grabber(), undef, 'with no local key, nothing resolves');

# --- a file that is not the canary's secret is not a key -------------------
write_file("$dir/home/UNLOCK-CODE.txt", "99999999\n");
is(subs::local_code_suds(), undef, 'a wrong code is refused by the canary');
is(subs::suds_grabber(), undef, 'and it does not become the key');
is(vault_rows(), 0, 'a wrong code seeds nothing');

write_file("$dir/home/UNLOCK-CODE.txt", "not-a-code\n");
is(subs::local_code_suds(), undef, 'a file that is not a numeric code is refused');

# --- the machine's own code is the key, and it seeds the vault -------------
write_file("$dir/home/UNLOCK-CODE.txt", "  $code \n");
is(subs::local_code_suds(), $code, 'the code beside the house is accepted');
is(subs::suds_grabber(), $code, 'suds_grabber resolves it');
is(vault_rows(), 1, 'the vault is seeded from it');
my ($vault) = subs::vault_read();
is($vault, $code, 'the vault now carries the key');

my $canary = subs::db_select('security', ['credential'], { level => 1 })->hash->{'credential'};
is(subs::decrypter($vault, $canary), $code,
	'the backup secret resolves: decrypter(key, canary) is the key');

my $plain = "$tmp/plain.txt";
my $sealed = "$tmp/sealed.enc";
write_file($plain, 'the house ' x 6000);
ok(subs::openssl_file_crypt('e', 'aes-256-cbc', subs::decrypter($vault, $canary), $plain, $sealed, 0, 1),
	'a backup sealed with that secret succeeds');
cmp_ok(-s $sealed, '>', 5000, 'and holds real ciphertext, above the restore floor');

# --- once seeded, the vault is the source; the file may be deleted ---------
unlink "$dir/home/UNLOCK-CODE.txt";
$gb::suds = undef;
$gb::duty_time = undef;
$gb::database_holder = {};
is(subs::local_code_suds(), undef, 'no code file is left');
is(subs::suds_grabber(), $code, 'the seeded vault still resolves the key');

done_testing();
