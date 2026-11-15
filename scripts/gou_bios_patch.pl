#!/usr/bin/perl
#
# gou_bios_patch.pl - teach the ODROID Go Ultra recovery BIOS to restart the
# board when the host has finished writing an image.
#
# The recovery mode is not u-boot's UMS: it is a small Linux (the "BIOS")
# packed in a cramfs image called ODROIDBIOS.BIN. Its /init exports the eMMC
# through g_mass_storage and draws a screen that says <F3+F6=REBOOT>. Nothing
# on the USB wire can press F3+F6, so the stock BIOS leaves the board sitting
# there after a flash until a person picks it up.
#
# This script rebuilds the BIOS with one addition to /init: in recovery mode it
# clears a marker on the BOOT partition before exporting the disk, then watches
# that partition for the marker and reboots when the host writes it. The host
# writes it in gou_provision.pl after the write and its verification.
#
#   gou_bios_patch.pl --check FILE
#       Say whether a BIOS image already has the watcher (exit 0 yes, 1 no).
#   gou_bios_patch.pl --bios IN --out OUT
#       Rebuild a cramfs BIOS with the watcher. No root, no device.
#   gou_bios_patch.pl --sdimage PATH
#       Patch bios/ODROIDBIOS.BIN inside a recovery SD image (loop mount).
#   gou_bios_patch.pl --device /dev/sdX
#       Patch ODROIDBIOS.BIN on the BOOT partition of a mounted-capable device.
#
# A patched BOOT partition also carries JNBIOS.TXT, the plain marker the
# provisioner reads to know the board it just wrote can restart itself.

use strict;
use warnings;

use Compress::Raw::Zlib ();
use Cwd ();
use File::Basename ();
use File::Copy ();
use File::Find ();
use File::Path ();
use File::Temp ();
use Getopt::Long ();

# The name the host writes into the BOOT partition. Eight characters, no dot,
# so it is a single 8.3 directory entry and the BIOS can find it by reading the
# raw partition without mounting it.
my $MARKER = 'JNREBOOT';
my $STAMP  = 'JNBIOS.TXT';
my $STAMP_TEXT = "jawnos-reboot=1\n";

my %opt;
Getopt::Long::Configure('no_ignore_case');
Getopt::Long::GetOptions(
	'check=s'  => \$opt{'check'},
	'bios=s'  => \$opt{'bios'},
	'out=s'   => \$opt{'out'},
	'sdimage=s' => \$opt{'sdimage'},
	'device=s'  => \$opt{'device'},
	'help|h'  => \$opt{'help'},
) or _die('bad options');

if ($opt{'help'} || !%opt) {
	print <<'USAGE';
gou_bios_patch.pl --check FILE
gou_bios_patch.pl --bios IN --out OUT
gou_bios_patch.pl --sdimage PATH
gou_bios_patch.pl --device /dev/sdX
USAGE
	exit($opt{'help'} ? 0 : 1);
}

if (defined $opt{'check'}) {
	my $yes = _is_patched($opt{'check'});
	print $yes ? "patched\n" : "stock\n";
	exit($yes ? 0 : 1);
}
if (defined $opt{'bios'}) {
	_die('--bios needs --out') unless defined $opt{'out'} && length $opt{'out'};
	my $r = _patch_cramfs($opt{'bios'}, $opt{'out'});
	_die($r->{'error'}) unless $r->{'ok'};
	print "wrote $opt{'out'} ($r->{'bytes'} bytes)\n";
	exit 0;
}
if (defined $opt{'sdimage'}) {
	_need_root('--sdimage');
	_need_tools(qw(losetup mount umount));
	_die("no such image: $opt{'sdimage'}") unless -f $opt{'sdimage'};
	# Keep the image the board came with: this rewrites the only copy of the
	# vendor BIOS in place, and a bad rebuild must not be the only one left.
	my $stock = $opt{'sdimage'} . '.stock';
	File::Copy::copy($opt{'sdimage'}, $stock) unless -e $stock;
	my $loop = _capture(_tool('losetup'), '-Pf', '--show', $opt{'sdimage'});
	_die("could not attach $opt{'sdimage'}") unless defined $loop && $loop =~ m{^/dev/loop\d+$};
	my $ok = eval { _on_boot_partition($loop, 'bios/ODROIDBIOS.BIN') };
	my $err = $@;
	system(_tool('losetup'), '-d', $loop);
	_die($err) if $err;
	print $ok->{'changed'} ? "patched $opt{'sdimage'}\n" : "$opt{'sdimage'} was already patched\n";
	exit 0;
}
if (defined $opt{'device'}) {
	_need_root('--device');
	my $r = _on_boot_partition($opt{'device'}, 'ODROIDBIOS.BIN');
	print $r->{'changed'} ? "patched $opt{'device'}\n" : "$opt{'device'} was already patched\n";
	exit 0;
}
_die('choose --check, --bios, --sdimage or --device');

# ---------------------------------------------------------------------------

sub _die {
	my ($message) = @_;
	print STDERR "gou_bios_patch: $message\n";
	exit 1;
}

sub _need_root {
	_die("$_ needs root (loop mounts)") unless $< == 0;
}

sub _need_tools {
	for my $tool (@_) {
		my $found = 0;
		for my $dir (split /:/, _search_path()) {
			next unless length $dir;
			if (-x "$dir/$tool") { $found = 1; last }
		}
		_die("missing tool: $tool") unless $found;
	}
}

# The tools live in the sbin directories, which a service account's PATH often
# does not have.
sub _search_path {
	return '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:' . ($ENV{'PATH'} // '');
}

sub _which {
	my ($tool) = @_;
	for my $dir (split /:/, _search_path()) {
		next unless length $dir;
		return "$dir/$tool" if -x "$dir/$tool";
	}
	return undef;
}

# The resolved path when there is one, the bare name otherwise (the shell will
# look it up, which is right when the caller's PATH is complete).
sub _tool {
	my ($tool) = @_;
	return _which($tool) // $tool;
}

sub _slurp {
	my ($path) = @_;
	open my $fh, '<:raw', $path or return undef;
	local $/;
	my $bytes = <$fh>;
	close $fh;
	return $bytes;
}

sub _write_file {
	my ($path, $bytes) = @_;
	open my $fh, '>:raw', $path or return 0;
	my $printed = print {$fh} $bytes;
	my $closed = close $fh;
	return ($printed && $closed) ? 1 : 0;
}

sub _capture {
	my (@args) = @_;
	open my $fh, '-|', @args or return undef;
	local $/;
	my $out = <$fh>;
	close $fh;
	return $out;
}

# --- what a patched BIOS says -------------------------------------------------
sub _is_patched {
	my ($path) = @_;
	return 0 unless defined $path && -f $path;
	my $work = File::Temp::tempdir('gou-bios-check-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	my $tree = "$work/tree";
	my $fsck = _which('fsck.cramfs') or return 0;
	return 0 if system($fsck, "--extract=$tree", $path) != 0;
	my $raw = _slurp("$tree/rootfs.cpio.uboot");
	return 0 unless defined $raw && length $raw > 64;
	my $cpio = _gunzip(substr($raw, 64), $work);
	return (defined $cpio && index($cpio, $MARKER) >= 0) ? 1 : 0;
}

sub _gunzip {
	my ($gzip_bytes, $work) = @_;
	my $in = "$work/in.gz";
	return undef unless _write_file($in, $gzip_bytes);
	return _capture(_tool('gzip'), '-dc', $in);
}

# --- rebuild a cramfs BIOS ----------------------------------------------------
sub _patch_cramfs {
	my ($in, $out) = @_;
	return { ok => 0, error => "no such BIOS: $in" } unless -f $in;
	my $fsck = _which('fsck.cramfs') or return { ok => 0, error => 'missing tool: fsck.cramfs' };
	my $mkfs = _which('mkfs.cramfs') or return { ok => 0, error => 'missing tool: mkfs.cramfs' };
	for my $tool (qw(cpio gzip)) {
		return { ok => 0, error => "missing tool: $tool" } unless _which($tool);
	}
	my $work = File::Temp::tempdir('gou-bios-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	my $tree = "$work/tree";
	return { ok => 0, error => 'the BIOS is not a cramfs image' }
		if system($fsck, "--extract=$tree", $in) != 0;

	my $uboot = "$tree/rootfs.cpio.uboot";
	my $raw = _slurp($uboot);
	return { ok => 0, error => 'the BIOS has no initrd' } unless defined $raw && length $raw > 64;
	my $header = substr($raw, 0, 64);
	my $image = unpack('N', substr($header, 0, 4));
	return { ok => 0, error => 'the BIOS initrd is not a uImage' } unless $image == 0x27051956;

	my $cpio = _gunzip(substr($raw, 64), $work);
	return { ok => 0, error => 'the BIOS initrd would not decompress' } unless defined $cpio && length $cpio;
	return { ok => 0, error => 'the BIOS initrd is not a newc cpio' }
		unless substr($cpio, 0, 6) eq '070701';

	my $root = "$work/root";
	File::Path::make_path($root);
	my $cpio_file = "$work/rootfs.cpio";
	_write_file($cpio_file, $cpio) or return { ok => 0, error => 'could not write the initrd' };
	# mknod fails without privilege; every file that matters still extracts.
	system('sh', '-c', 'cd "$1" && "$3" -idm --no-absolute-filenames < "$2" >/dev/null 2>&1',
		'sh', $root, $cpio_file, _tool('cpio'));

	my $init_path = "$root/init";
	my $init = _slurp($init_path);
	return { ok => 0, error => 'the BIOS has no /init' } unless defined $init && length $init;
	if (index($init, $MARKER) < 0) {
		my $anchor = "/sbin/getty -L ttyS0 115200 vt100 -n -l /bin/sh &";
		return { ok => 0, error => 'the BIOS init is not the shape this patch knows' }
			unless index($init, $anchor) >= 0;
		my $block = <<"BLOCK";
# JawnOS: the host finishes a flash by writing $MARKER into the BOOT
# partition and releasing the LUN, and the board then restarts itself. A
# marker left by the previous flash is cleared before the disk is exported,
# or a stale one would restart the board every time recovery is entered.
if [ "\$bootmode" == "recovery" ]; then
	mkdir -p /mnt/boot
	if mount -t vfat /dev/mmcblk0p1 /mnt/boot 2>/dev/null; then
		rm -f /mnt/boot/$MARKER
		umount /mnt/boot
		(
			while :; do
				if dd if=/dev/mmcblk0p1 bs=1024 count=2048 2>/dev/null | grep -qa $MARKER; then
					reboot
				fi
				sleep 1
			done
		) &
	fi
fi

BLOCK
		$init =~ s/\Q$anchor\E/$block$anchor/ or
			return { ok => 0, error => 'could not place the reboot watcher' };
		_write_file($init_path, $init) or return { ok => 0, error => 'could not write the patched init' };
	}
	chmod 0755, $init_path;

	# Repack the initrd. cpio takes its names on stdin, so the list is a file and
	# the shell only ever sees our own two temp paths.
	my $names = "$work/names";
	my @names;
	File::Find::find({ no_chdir => 1, wanted => sub {
		my $path = $File::Find::name;
		$path =~ s{^\Q$root\E/?}{};
		push @names, '.' unless length $path;
		push @names, $path if length $path;
	} }, $root);
	_write_file($names, join("\n", @names) . "\n") or return { ok => 0, error => 'could not list the initrd' };
	my $new_cpio = "$work/new.cpio";
	my $rc = system('sh', '-c', 'cd "$1" && "$3" -o -H newc --quiet < "$2" > "$4"',
		'sh', $root, $names, _tool('cpio'), $new_cpio);
	return { ok => 0, error => 'could not repack the initrd' } if $rc != 0;
	my $gz = _capture(_tool('gzip'), '-9', '-n', '-c', $new_cpio);
	return { ok => 0, error => 'could not compress the initrd' } unless defined $gz && length $gz;

	my $new_header = _uimage_header($header, $gz);
	_write_file($uboot, $new_header . $gz) or return { ok => 0, error => 'could not write the new initrd' };

	my $tmp_out = "$work/bios.out";
	$rc = system($mkfs, '-N', 'little', '-b', '4096', $tree, $tmp_out);
	return { ok => 0, error => 'mkfs.cramfs refused the tree' } if $rc != 0;
	return { ok => 0, error => 'the rebuilt BIOS does not check out' }
		if system($fsck, $tmp_out) != 0;
	File::Copy::copy($tmp_out, $out) or return { ok => 0, error => "could not write $out" };
	return { ok => 1, bytes => -s $out };
}

# The legacy uImage header: size at 12, data CRC at 24, header CRC at 4. The
# rest (load address, entry, OS, arch, type, compression) is the stock BIOS's.
sub _uimage_header {
	my ($old, $data) = @_;
	my $header = $old;
	substr($header, 4, 4)  = "\0\0\0\0";
	substr($header, 12, 4) = pack('N', length $data);
	substr($header, 24, 4) = pack('N', Compress::Raw::Zlib::crc32($data));
	substr($header, 4, 4)  = pack('N', Compress::Raw::Zlib::crc32($header));
	return $header;
}

# --- patch a BOOT partition ---------------------------------------------------
sub _on_boot_partition {
	my ($dev, $relative) = @_;
	my $part = _first_partition($dev);
	_die("no BOOT partition on $dev") unless defined $part && -e $part;
	my $mount = File::Temp::tempdir('gou-boot-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	my $rc = system(_tool('mount'), $part, $mount);
	_die("could not mount $part") if $rc != 0;
	my $result = eval { _patch_tree($mount, $relative) };
	my $error = $@;
	system(_tool('umount'), $mount);
	die $error if $error;
	return $result;
}

sub _first_partition {
	my ($dev) = @_;
	my $out = _capture(_tool('lsblk'), '-lno', 'NAME,TYPE', '--', $dev);
	if (defined $out) {
		for my $line (split /\n/, $out) {
			my ($name, $type) = split /\s+/, $line;
			next unless defined $type && $type eq 'part';
			return "/dev/$name";
		}
	}
	return $dev . 'p1' if $dev =~ m{/dev/(?:mmcblk|nvme)\d+};
	return $dev . '1';
}

sub _patch_tree {
	my ($mount, $relative) = @_;
	my $bios = "$mount/$relative";
	_die("no $relative on the BOOT partition") unless -f $bios;
	my $stamp = "$mount/$STAMP";
	if (-f $stamp && _is_patched($bios)) {
		return { changed => 0 };
	}
	my $tmp = "$mount/.ODROIDBIOS.BIN.new";
	my $r = _patch_cramfs($bios, $tmp);
	unlink $tmp unless $r->{'ok'};
	_die($r->{'error'} // 'the BIOS could not be patched') unless $r->{'ok'};
	rename($tmp, $bios) or do { unlink $tmp; _die('could not replace the BIOS') };
	chmod 0644, $bios;
	_write_file($stamp, $STAMP_TEXT) or _die('could not write the BIOS marker');
	system('sync');
	return { changed => 1 };
}
