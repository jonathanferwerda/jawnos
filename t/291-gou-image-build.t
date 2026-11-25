# tests-for: scripts/gou_image_build.sh
# covers:    The eMMC image builder's contract: it refuses to run without its
#            inputs, a dry run needs no root and changes nothing, and the three
#            things a board taught us are in the file - the eMMC bootloader in
#            the first 16 MiB, the state directory the server unit logs to, and
#            the USB gadget link - along with the exclusion list, the mmc 0
#            boot.ini rewrite and the operating-system time zone it installs.

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);

my $root = "$Bin/..";
my $script = "$root/scripts/gou_image_build.sh";

ok(-f $script, 'scripts/gou_image_build.sh exists');

my $syntax = `bash -n "$script" 2>&1`;
is($?, 0, 'bash -n accepts the script') or diag $syntax;

my $source = read_file($script);

# The four things a GOU eMMC image must carry.
like($source, qr/BOOT_BYTES=16777216/, 'the eMMC bootloader is 16 MiB');
like($source, qr{\.local/state/jawnos}, 'the state directory the unit logs to');
like($source, qr/usb-gadget\.nmconnection/, 'the USB gadget profile');
like($source, qr{/etc/machine-id}, 'the machine-id is written');
like($source, qr{od -An -N16 -tx1 /dev/urandom}, 'with a real random id, not an empty file');
like($source, qr{chmod 644 "\$root/etc/machine-id"}, 'that systemd and every reader can open');
like($source, qr{s/mmc 1:1/mmc 0:1}, 'boot.ini is rewritten to mmc 0');
like($source, qr/recovery_stanza/, 'the eMMC carries a boot.ini recovery entry');
like($source, qr/0x1F000000 RECOVERY/, 'which starts the BIOS when the marker is present');
like($source, qr/apply_recovery_entry/, 'and it is applied by both build and repair');

# The OS clock: a board with no /etc/localtime boots in UTC.
like($source, qr/--timezone/, 'a zone can be named on the command line');
like($source, qr/America\/New_York/, 'the house Eastern zone is the default');
like($source, qr{\bTIMEZONE=}, 'the zone is a named value, not a path');
like($source, qr{ln -sfn "/usr/share/zoneinfo/\$TIMEZONE" "\$root/etc/localtime"},
	'the image gets the /etc/localtime link systemd reads');
like($source, qr{\$root/etc/timezone}, 'and the /etc/timezone name file');
like($source, qr{apply_fixes "\$MNT_P2"}, 'the fixes, zone included, run on build and repair');

# What the image must not keep.
foreach my $pattern (qw(/root/kbuild /usr/share/doc /etc/ssh/ssh_host_ /home/jawn/roms /opt/retroarch-stock)) {
	like($source, qr/\Q$pattern\E/, "the exclusion list has $pattern");
}

# The geometry is the eMMC's, not the card's.
like($source, qr/EMMC_BYTES=15634268160/, 'the eMMC size');
like($source, qr/P2_SECTORS=30273536/, 'the eMMC root partition');

# Usage and refusals.
my $help = `bash "$script" --help 2>&1`;
is($?, 0, '--help exits 0');
like($help, qr/\bbuild\b/, '--help names build');
like($help, qr/\brepair\b/, '--help names repair');
like($help, qr/\bpatch\b/, '--help names patch');

my $unknown = `bash "$script" wobble 2>&1`;
isnt($?, 0, 'an unknown command is refused');

my $no_from = `bash "$script" build --out /tmp/x.img 2>&1`;
isnt($?, 0, 'build without --from is refused');
like($no_from, qr/needs --from/, 'and says what is missing');

my $dir = tempdir(CLEANUP => 1);
my $existing = "$dir/x.img";
write_file($existing, "z" x 1024);

my $no_stock = `bash "$script" repair --image "$existing" --out "$dir/y.img" 2>&1`;
isnt($?, 0, 'repair without --stock-backup is refused');
like($no_stock, qr/needs --stock-backup/, 'and says what is missing');

my $no_patch = `bash "$script" patch 2>&1`;
isnt($?, 0, 'patch without its paths is refused');

# A dry run needs no root and writes nothing: point it at placeholder files.
my $dump = "$dir/dump.img";
my $stock = "$dir/stock.img";
write_file($dump, "x" x 1024);
write_file($stock, "y" x 1024);
my $out = "$dir/out.img";

my $dry = `bash "$script" build --from "$dump" --out "$out" --stock-backup "$stock" --dry-run 2>&1`;
is($?, 0, 'build --dry-run exits 0 without root');
like($dry, qr/plan:/, 'and prints the plan');
ok(!-e $out, 'and writes no image');

# A zone is a tz-database name, not a path; a typo is refused, not shipped.
my $bad_zone = `bash "$script" build --from "$dump" --out "$out" --stock-backup "$stock" --timezone 'Etc/../../passwd' --dry-run 2>&1`;
isnt($?, 0, 'a traversal-shaped time zone is refused');
like($bad_zone, qr/invalid time zone/, 'and says so');

my $tz_dry = `bash "$script" build --from "$dump" --out "$out" --stock-backup "$stock" --timezone America/Chicago --dry-run 2>&1`;
is($?, 0, 'a named zone is accepted');

done_testing();
