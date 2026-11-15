# tests-for: scripts/gou_recovery.pl scripts/gou_bios_patch.pl scripts/gou_image_build.sh scripts/gou_provision.pl
# covers:    The eMMC's way back into recovery without a microSD: the board-side
#            marker, the boot.ini entry that reads it, and the recovery BIOS
#            rebuild that lets a finished flash restart the board by itself.
#            The cramfs rebuild runs only where cramfs-tools is installed; the
#            marker and the entry are checked on every run.

use strict;
use warnings;
use utf8;

use FindBin qw($Bin);
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);

my $root = "$Bin/..";

# --- the board-side marker ----------------------------------------------------
my $recovery = "$root/scripts/gou_recovery.pl";
ok(-x $recovery, 'scripts/gou_recovery.pl is executable');
is(system($^X, '-c', $recovery) >> 8, 0, 'it compiles');

my $dir = tempdir(CLEANUP => 1);
is(system($^X, $recovery, '--mount', $dir, '--no-reboot', '--status') >> 8, 1,
	'an unarmed board is not in recovery');
is(system($^X, $recovery, '--mount', $dir, '--no-reboot') >> 8, 0, 'arming writes the marker');
ok(-f "$dir/RECOVERY", 'the marker is on the BOOT partition');
is(system($^X, $recovery, '--mount', $dir, '--status') >> 8, 0, 'the board now reports armed');
is(system($^X, $recovery, '--mount', $dir, '--clear') >> 8, 0, 'clearing removes it');
ok(!-e "$dir/RECOVERY", 'the marker is gone');
is(system($^X, $recovery, '--mount', "$dir/nope", '--no-reboot') >> 8, 1,
	'a missing BOOT partition is refused');

# --- the bootloader entry -----------------------------------------------------
my $provision = read_file("$root/scripts/gou_provision.pl");
like($provision, qr/load mmc \$\{devno\}:1 0x1F000000 RECOVERY/,
	'the provisioner writes a boot.ini entry that reads the marker');
like($provision, qr/setenv bootmode recovery/, 'and starts the BIOS in recovery mode');
like($provision, qr/_install_recovery_entry/, 'and installs it idempotently');
like($provision, qr/_prepare_boot/, 'the flash prepares the BOOT partition');
like($provision, qr/_wait_for_reboot/, 'and waits for the board to restart');
like($provision, qr/gou_recovery\.pl/, 'the recovery script is copied onto the board');

my $build = read_file("$root/scripts/gou_image_build.sh");
like($build, qr/recovery_stanza/, 'the image builder has the recovery stanza');
like($build, qr/apply_recovery_entry/, 'and applies it to the BOOT partition');
like($build, qr/load mmc \$\{devno\}:1 0x1F000000 RECOVERY/, 'with the same marker read');

# --- the BIOS rebuild ---------------------------------------------------------
my $patch = "$root/scripts/gou_bios_patch.pl";
ok(-x $patch, 'scripts/gou_bios_patch.pl is executable');
is(system($^X, '-c', $patch) >> 8, 0, 'it compiles');
my $patch_src = read_file($patch);
like($patch_src, qr/my \$MARKER = 'JNREBOOT'/, 'the host marker is JNREBOOT');
like($patch_src, qr/rm -f \/mnt\/boot\/\$MARKER/, 'a stale marker is cleared before export');
like($patch_src, qr/grep -qa \$MARKER/, 'the BIOS watches the raw BOOT partition');
like($patch_src, qr/substr\(\$header, 4, 4\)  = pack\('N', Compress::Raw::Zlib::crc32\(\$header\)\)/,
	'the uImage header CRC is rebuilt');

# The end-to-end rebuild needs cramfs-tools. Build a small BIOS with the shape
# the patch expects: a cramfs holding a uImage-wrapped newc initrd.
my $cramfs = (-x '/usr/sbin/mkfs.cramfs') ? '/usr/sbin/mkfs.cramfs'
	: (-x '/usr/bin/mkfs.cramfs' ? '/usr/bin/mkfs.cramfs' : undef);
my $check_cramfs = (-x '/usr/sbin/fsck.cramfs') ? '/usr/sbin/fsck.cramfs'
	: (-x '/usr/bin/fsck.cramfs' ? '/usr/bin/fsck.cramfs' : undef);
my $have_cramfs = defined $cramfs && defined $check_cramfs;

SKIP: {
	skip 'cramfs-tools is not installed', 5 unless $have_cramfs;
	require Compress::Raw::Zlib;

	my $work = tempdir(CLEANUP => 1);
	my $tree = "$work/bios";
	make_path($tree);
	write_file("$tree/boot.ini", "ODROIDGOU-UBOOT-CONFIG\n");
	write_file("$tree/uImage", 'K' x 128);
	write_file("$tree/meson64_odroidgou.dtb", 'D' x 128);

	my $init = <<'INIT';
#!/bin/sh
set -- $(cat /proc/cmdline)
for x in "$@"; do
	case "$x" in
		bootmode=*)
			bootmode=${x#bootmode=}
			;;
	esac
done
/sbin/getty -L ttyS0 115200 vt100 -n -l /bin/sh &
if [ "$bootmode" == "recovery" ]; then
	/usr/sbin/ums /dev/mmcblk0
fi
exec sh
INIT
	make_path("$work/initrd");
	write_file("$work/initrd/init", $init);

	my $cpio = "$work/rootfs.cpio";
	is(system('sh', '-c', 'cd "$1" && find . | cpio -o -H newc --quiet > "$2"',
		'sh', "$work/initrd", $cpio) >> 8, 0, 'the test initrd packs');
	my $gz = `gzip -9 -n -c "$cpio"`;
	my $header = "\x27\x05\x19\x56" . "\0\0\0\0" . pack('N', 0) . pack('N', length $gz)
		. pack('N', 0) . pack('N', 0) . pack('N', Compress::Raw::Zlib::crc32($gz))
		. pack('C', 5) . pack('C', 22) . pack('C', 2) . pack('C', 1) . ("\0" x 32);
	substr($header, 4, 4) = pack('N', Compress::Raw::Zlib::crc32($header));
	write_file("$tree/rootfs.cpio.uboot", $header . $gz);
	is(system($cramfs, '-N', 'little', '-b', '4096', $tree, "$work/stock.bios") >> 8, 0,
		'the test BIOS packs');

	is(system($^X, $patch, '--check', "$work/stock.bios") >> 8, 1, 'the stock BIOS has no watcher');
	is(system($^X, $patch, '--bios', "$work/stock.bios", '--out', "$work/patched.bios") >> 8, 0,
		'the BIOS rebuilds');
	is(system($^X, $patch, '--check', "$work/patched.bios") >> 8, 0, 'the rebuilt BIOS has the watcher');
}

done_testing();
