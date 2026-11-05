# tests-for: lib/JawnOS/Domain/Backup.pm lib/JawnOS/Domain/Misc.pm lib/JawnOS/Controller/manager_misc4.pm public/js/manager/manager/10_appointment_edit.js perl/help/topics_features.pl lib/JawnOS/Domain/Loader.pm
# covers:    Exit keeps the database when the backup did not seal; a failed encryption must never leave a footer-only file that leave() then trusts.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JawnOSTest;

# On VM 103, Exit shredded a 1.1 MB database after openssl failed: the backup
# file held only the 96-byte split footer. backup_now() now verifies the
# ciphertext and leave() refuses to shred unless both the timestamped archive
# and the stable jawnos.enc hold real bytes. These checks pin that floor and
# the guard on both sides.

my $root = root();
my $dir = tempdir(CLEANUP => 1);

# --- the seal test is the restore's own floor --------------------------------
my $footer = "$dir/footer.enc";
write_file($footer, '--simple--split--and--whatnot--' . ('A' x 40) . "\n");
ok(!subs::backup_sealed_ok($footer), 'a footer-only file is not a backup');

my $empty = "$dir/empty.enc";
write_file($empty, '');
ok(!subs::backup_sealed_ok($empty), 'an empty file is not a backup');

my $floor = "$dir/floor.enc";
write_file($floor, 'x' x 5000);
ok(!subs::backup_sealed_ok($floor), 'exactly 5000 bytes is still below the restore floor');

my $sealed = "$dir/sealed.enc";
write_file($sealed, 'x' x 5001);
ok(subs::backup_sealed_ok($sealed), 'a real ciphertext passes');

ok(!subs::backup_sealed_ok("$dir/nope.enc"), 'a missing path is not a backup');
ok(!subs::backup_sealed_ok(''), 'an empty path is not a backup');

# --- backup_now checks the ciphertext before it writes the footer ------------
my $backup = read_file("$root/lib/JawnOS/Domain/Backup.pm");
like($backup, qr/unless \(\$encrypt && &backup_sealed_ok\(\$archive_enc\)\)/,
	'backup_now checks the encryption result and the sealed bytes');
like($backup, qr/status => 'failed', error => 'could not seal the database'/,
	'and reports a failed seal instead of continuing');
like($backup, qr/rename \$staged, \$enc_file/,
	'the stable jawnos.enc is replaced atomically after a size check');

# --- leave refuses to shred without a sealed archive and stable copy ---------
my $misc = read_file("$root/lib/JawnOS/Domain/Misc.pm");
like($misc, qr/my \$backup = &subs::backup_now\(\$c\);/,
	'leave keeps the backup result');
like($misc, qr/&subs::backup_sealed_ok\(\$backup->\{'archive_path'\}\)/,
	'it checks the timestamped archive');
like($misc, qr/&subs::backup_sealed_ok\(\$backup->\{'path'\}\)/,
	'and the stable copy');
like($misc, qr/Could not seal the database; it was kept\./,
	'it says the database was kept');
unlike($misc, qr/&subs::backup_now\(\$c\);\s*`shred/,
	'no unguarded shred follows the backup call');

# --- the route and the dialog surface the refusal ----------------------------
my $controller = read_file("$root/lib/JawnOS/Controller/manager_misc4.pm");
like($controller, qr/status => 500, json =>/, 'a failed leave answers with an error, not the gate');

my $js = read_file("$root/public/js/manager/manager/10_appointment_edit.js");
like($js, qr/Could not seal the database; it was kept\./, 'the dialog says why the leave did not happen');

my $help = read_file("$root/perl/help/topics_features.pl");
like($help, qr/Exit refuses and keeps the house open/,
	'the help topic warns that a failed seal keeps the house open');

done_testing();
