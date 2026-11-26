#!/usr/bin/perl
#
# gou_provision.pl - scan for an ODROID Go Ultra eMMC over USB and flash it.
#
# The manager runs this through `sudo -n` when it writes: a flash opens a raw
# block device and mounts the flashed rootfs. An argument list is never joined
# into a shell string, so a person's SSID, hostname or join token stays a value.
#
#   --scan                       list candidate devices as JSON
#   --flash                      write the image to the one candidate
#   --device PATH                name the block device instead of finding one
#   --image PATH                 default the newest gou-emmc-*.img.zst in
#                                /home/jawn/gou (JAWNOS_GOU_IMAGE_DIR moves it)
#   --wifi-ssid S --wifi-psk P   write a NetworkManager profile
#   --wifi-psk-stdin             read the password from stdin instead of argv
#   --hostname NAME              default 'gou'
#   --join-token FILE            JSON copied to
#                                /home/jawn/jawnos/.controller-join.json
#   --no-autopopulate            skip the rootfs writes
#   --no-reboot                  leave the board in recovery; do not ask it to restart
#   --reboot-wait SECONDS        how long to wait for the board to restart (default 8)
#   --dry-run                    do everything except write to the device/mount
#   --backup PATH                read the current eMMC here before writing
#
# Both modes print JSON on stdout; progress and every human word go to stderr.
# Exit codes: 0 ok, 2 no device, 3 bad fingerprint, 4 image/option invalid,
# 5 write or verify failed.

use strict;
use warnings;

use Cwd ();
use Digest::SHA ();
use File::Basename ();
use File::Copy ();
use File::Path ();
use File::Temp ();
use Getopt::Long ();
use JSON::PP ();
use Time::HiRes ();

# The ODROID Go Ultra's eMMC as the USB gadget presents it: 15,634,268,160
# bytes. A device with any other size is a different disk and is refused.
my $EMMC_SIZE = 30_535_680;
# The staged eMMC images. The directory is pruned as a build is replaced, so the
# flash names the newest one there instead of a constant filename: a fixed name
# is a file that has been deleted by the time the button is pressed, and the
# New-controller panel sends no image at all.
my $IMAGE_DIR = (defined $ENV{'JAWNOS_GOU_IMAGE_DIR'} && length $ENV{'JAWNOS_GOU_IMAGE_DIR'})
	? $ENV{'JAWNOS_GOU_IMAGE_DIR'} : '/home/jawn/gou';
# The recovery card image. It is copied onto the flashed rootfs, so a board
# always carries the way back even when the card in its slot is formatted.
my $DEFAULT_RECOVERY = '/home/jawn/gou/sdcard_recovery.img';
my $DEFAULT_HOSTNAME = 'gou';

my $JSON = JSON::PP->new->utf8(1)->canonical(1);

# A flash is long and a person watches it. When the manager starts one it names
# a progress file; this script owns that file from then on, so a panel restart
# still finds the truth. The last state written is what the Controllers page
# shows: writing with a byte count and a rate, then verifying, preparing, and
# done, failed or cancelled. No secret is ever written here.
my $PROGRESS_PATH;
my $PROGRESS_STARTED;
my $CANCELLED = 0;

my %opt;
Getopt::Long::Configure('no_ignore_case');
Getopt::Long::GetOptions(
	'scan'            => \$opt{'scan'},
	'flash'           => \$opt{'flash'},
	'device=s'        => \$opt{'device'},
	'image=s'         => \$opt{'image'},
	'wifi-ssid=s'     => \$opt{'wifi_ssid'},
	'wifi-psk=s'      => \$opt{'wifi_psk'},
	'wifi-psk-stdin'  => \$opt{'wifi_psk_stdin'},
	'hostname=s'      => \$opt{'hostname'},
	'join-token=s'    => \$opt{'join_token'},
	'progress=s'      => \$opt{'progress'},
	'recovery-image=s' => \$opt{'recovery_image'},
	'no-autopopulate' => \$opt{'no_autopopulate'},
	'no-reboot'       => \$opt{'no_reboot'},
	'reboot-wait=i'   => \$opt{'reboot_wait'},
	'dry-run'         => \$opt{'dry_run'},
	'backup=s'        => \$opt{'backup'},
	'help|h'          => \$opt{'help'},
) or _fail(4, 'bad options');

# From here on every failure and every phase goes to the progress file, so the
# page sees more than "it stopped". A helper that exits before this line has no
# file to write, and the caller reports the failure it got on stdout.
$PROGRESS_PATH = $opt{'progress'} if defined $opt{'progress'} && length $opt{'progress'};
$PROGRESS_STARTED = _now_ms();

if ($opt{'help'}) {
	print <<'USAGE';
gou_provision.pl --scan | --flash [--device /dev/sdX]
  [--image FILE] [--wifi-ssid S --wifi-psk P | --wifi-psk-stdin] [--hostname NAME]
  [--join-token FILE] [--progress FILE] [--recovery-image FILE] [--no-autopopulate] [--no-reboot] [--dry-run] [--backup PATH]
USAGE
	exit 0;
}

if ($opt{'scan'} && $opt{'flash'}) {
	_fail(4, 'choose one of --scan and --flash');
}
elsif ($opt{'scan'}) {
	_scan();
}
elsif ($opt{'flash'}) {
	_flash();
}
else {
	_fail(4, 'choose --scan or --flash');
}

# ---------------------------------------------------------------------------
# Output

sub _emit {
	my ($data, $code) = @_;
	print $JSON->encode($data), "\n";
	exit(defined $code ? $code : 0);
}

sub _fail {
	my ($code, $message) = @_;
	$message = _clean($message) || 'the provisioner failed';
	_progress_write('failed', error => $message) if defined $PROGRESS_PATH;
	print STDERR "gou_provision: $message\n";
	_emit({ ok => 0, error => $message }, $code);
}

sub _note {
	my ($message) = @_;
	$message = _clean($message);
	print STDERR "gou_provision: $message\n" if length $message;
}

sub _clean {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\s+/ /g;
	$text =~ s/^\s+|\s+$//g;
	return substr($text, 0, 400);
}

# ---------------------------------------------------------------------------
# The progress file
#
# Written atomically (a rename, so a reader never sees half a JSON object) and
# owned by this process: state, bytes, total, rate, and the pid of the process
# group the manager must signal to cancel. The manager starts this script in its
# own session, so a panel restart neither kills the write nor loses the count.

sub _now_ms { return int(Time::HiRes::time() * 1000) }

# /proc/<pid>/stat's start time (field 22). The pid-reuse guard: a recycled pid
# starts later, so the manager can tell "still my flash" from "a stranger".
sub _start_ticks {
	my ($pid) = @_;
	return '' unless defined $pid && $pid =~ /^\d+$/;
	open my $fh, '<', "/proc/$pid/stat" or return '';
	my $line = <$fh> // '';
	close $fh;
	return '' unless length $line;
	# The command name is parenthesised and may contain spaces; split after it.
	$line =~ s/^.*\)\s+//;
	my @field = split /\s+/, $line;
	return $field[19] // '';
}

sub _progress_write {
	my ($state, %extra) = @_;
	return unless defined $PROGRESS_PATH && length $PROGRESS_PATH;
	my $group = getpgrp();
	my $now = _now_ms();
	my %data = (
		state => $state,
		pid => $group,
		start_ticks => _start_ticks($group),
		started_ms => $PROGRESS_STARTED,
		updated_ms => $now,
		# The manager seeded these before the exec; carry them forward so a
		# later write does not erase where the token is or which board this is.
		token_path => ($ENV{'JAWNOS_FLASH_TOKEN_PATH'} // ''),
		hostname => ($ENV{'JAWNOS_FLASH_HOSTNAME'} // ''),
		%extra,
	);
	my $tmp = $PROGRESS_PATH . '.' . $$ . '.tmp';
	return unless open(my $fh, '>', $tmp);
	print {$fh} $JSON->encode(\%data);
	close $fh;
	# This runs as root through sudo, under the manager's umask 0077. The file holds
	# no secret and the manager must read it, so give it a mode the service account
	# can open; a 0600 root file read as an empty job and every poll said "stopped".
	chmod 0644, $tmp;
	rename($tmp, $PROGRESS_PATH) or unlink $tmp;
	return 1;
}

# ---------------------------------------------------------------------------
# Small file and process helpers. Every command runs from a list, never a shell.

sub _slurp {
	my ($path) = @_;
	open my $fh, '<:raw', $path or return '';
	local $/;
	my $bytes = <$fh>;
	close $fh;
	return defined $bytes ? $bytes : '';
}

sub _trim {
	my ($value) = @_;
	$value = '' unless defined $value;
	$value =~ s/^\s+|\s+$//g;
	return $value;
}

sub _command_path {
	my ($name) = @_;
	for my $dir (split /:/, ($ENV{'PATH'} // '/usr/local/sbin:/usr/sbin:/sbin:/usr/local/bin:/usr/bin:/bin')) {
		next unless length $dir;
		my $candidate = "$dir/$name";
		return $candidate if -x $candidate;
	}
	return undef;
}

sub _capture {
	my (@args) = @_;
	open my $fh, '-|', @args or return undef;
	local $/;
	my $out = <$fh>;
	close $fh;
	return defined $out ? $out : '';
}

sub _write_file {
	my ($path, $bytes) = @_;
	open my $fh, '>:raw', $path or return 0;
	my $printed = print {$fh} $bytes;
	my $closed = close $fh;
	return ($printed && $closed) ? 1 : 0;
}

# A 32-hex machine-id. It has to be written before the board boots: systemd
# cannot mint one while the root is still read-only, and an invalid id makes
# systemd-journald restart forever ahead of sysinit.target, which stops the
# whole boot (see _autopopulate).
sub _fresh_machine_id {
	open my $fh, '<:raw', '/dev/urandom' or return undef;
	my $bytes = '';
	my $got = read($fh, $bytes, 16);
	close $fh;
	return undef unless defined $got && $got == 16;
	return unpack('H*', $bytes);
}

# ---------------------------------------------------------------------------
# sysfs: the device's own answer, never a guess from lsblk.

# The image to write when the caller names none: the newest staged one. Only a
# finished build is staged, so its mtime is the build's order.
sub _default_image {
	my @staged = sort { (stat($b))[9] <=> (stat($a))[9] } glob("$IMAGE_DIR/gou-emmc-*.img.zst");
	return $staged[0] if @staged;
	return '';
}

sub _block_names {
	opendir my $dh, '/sys/block' or return ();
	my @names = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;
	return sort @names;
}

sub _attr {
	my ($name, $attr) = @_;
	return _trim(_slurp("/sys/block/$name/$attr"));
}

# The fingerprint the manager must see before it writes: the USB mass-storage
# gadget's model string and exactly the eMMC's sector count. The kernel marks
# the gadget removable=0 (it is a fixed LUN), so that flag cannot be the test.
sub _fingerprint {
	my ($dev) = @_;
	unless (defined $dev && $dev =~ m{^/dev/([A-Za-z0-9._-]+)$}) {
		return { ok => 0, error => 'not a device path: ' . ($dev // '') };
	}
	my $name = $1;
	return { ok => 0, error => "$dev is not a whole block device" } unless -d "/sys/block/$name";
	my $model = _attr($name, 'device/model');
	return { ok => 0, error => "$dev is not a File-Stor Gadget: " . ($model || 'no model') }
		unless $model =~ /File-Stor\s+Gadget/i;
	my $size = _attr($name, 'size');
	return { ok => 0, error => "$dev has no readable size" } unless $size =~ /^\d+$/;
	return { ok => 0, error => "$dev is $size sectors, not $EMMC_SIZE" } unless $size == $EMMC_SIZE;
	return {
		ok => 1,
		name => $name,
		size_sectors => $size + 0,
		model => $model,
	};
}

# The disks that look like the GOU's eMMC. A blank model is not a reason to
# hide a disk that has exactly the eMMC's size; a size mismatch is still shown,
# so the page can say why the flash would refuse it.
sub _candidates {
	my @devices;
	for my $name (_block_names()) {
		next if $name =~ /^(?:loop|ram|dm-|md|zd|sr|nbd)/;
		my $model = _attr($name, 'device/model');
		my $size = _attr($name, 'size');
		next unless $model =~ /File-Stor\s+Gadget/i || (defined $size && $size eq $EMMC_SIZE);
		push @devices, {
			dev => "/dev/$name",
			size_sectors => ($size =~ /^\d+$/ ? $size + 0 : undef),
			model => $model,
			removable => (_attr($name, 'removable') eq '1' ? 1 : 0),
		};
	}
	return @devices;
}

sub _scan {
	my @devices = _candidates();
	_emit({ ok => 1, devices => \@devices, count => scalar @devices }, 0);
}

# The disk / is mounted from, reduced to the whole-disk name (sda3 -> sda,
# nvme0n1p2 -> nvme0n1). A container's overlay or a network root answers ''.
sub _disk_of_source {
	my ($source) = @_;
	return '' unless defined $source && $source =~ m{^/dev/};
	(my $name = $source) =~ s{^/dev/}{};
	return $1 if $name =~ /^((?:nvme\d+n\d+|mmcblk\d+))p\d+$/;
	return $1 if $name =~ /^((?:md|zd)\d+)$/;
	return $1 if $name =~ /^([A-Za-z]+)\d+$/;
	return $name;
}

sub _root_disk {
	for my $line (split /\n/, _slurp('/proc/mounts')) {
		my ($source, $mount) = split /\s+/, $line;
		next unless defined $mount && $mount eq '/';
		return _disk_of_source($source);
	}
	return '';
}

sub _unmount_escape {
	my ($path) = @_;
	$path =~ s/\\040/ /g;
	$path =~ s/\\011/\t/g;
	$path =~ s/\\012/\n/g;
	$path =~ s/\\134/\\/g;
	return $path;
}

# Any mount of the whole device or one of its partitions counts as mounted.
sub _mounted_path {
	my ($needle) = @_;
	return '' unless defined $needle && length $needle;
	for my $line (split /\n/, _slurp('/proc/mounts')) {
		my ($source, $mount) = split /\s+/, $line;
		next unless defined $source;
		if ($source eq $needle) {
			return defined $mount ? _unmount_escape($mount) : '/';
		}
		my $real = eval { Cwd::realpath($source) };
		return defined $mount ? _unmount_escape($mount) : '/'
			if defined $real && $real eq $needle;
	}
	return '';
}

sub _device_mounted {
	my ($dev) = @_;
	return 1 if length _mounted_path($dev);
	my $partition = qr/^\Q$dev\E(?:p?\d+)$/;
	for my $line (split /\n/, _slurp('/proc/mounts')) {
		my ($source) = split /\s+/, $line;
		return 1 if defined $source && $source =~ $partition;
	}
	for my $line (split /\n/, _slurp('/proc/swaps')) {
		next if $line =~ /^\s*(?:Filename|$)/;
		my ($source) = split /\s+/, $line;
		return 1 if defined $source && ($source eq $dev || $source =~ $partition);
	}
	return 0;
}

# ---------------------------------------------------------------------------
# Image: size, sibling checksum, and the exact uncompressed byte count.

sub _file_sha256 {
	my ($path) = @_;
	open my $fh, '<:raw', $path or return undef;
	my $sha = Digest::SHA->new(256);
	$sha->addfile($fh);
	close $fh;
	return $sha->hexdigest;
}

sub _sibling_sha256 {
	my ($image) = @_;
	my @tries = ("$image.sha256");
	if ($image =~ /\.zst$/i) {
		(my $bare = $image) =~ s/\.zst$//i;
		push @tries, "$bare.sha256";
	}
	for my $path (@tries) {
		next unless -f $path;
		return lc $1 if _slurp($path) =~ /\b([0-9a-fA-F]{64})\b/;
	}
	return undef;
}

# zstd -l -v prints the exact byte count in parentheses next to the human
# figure ("Decompressed Size: 6.00 GiB (6442450944 B)"). The parenthesised
# number is what the read-back uses; an older zstd that only prints the human
# figure leaves the count to dd, which reports exactly what it wrote.
sub _uncompressed_length {
	my ($image) = @_;
	return -s $image if $image !~ /\.zst$/i;
	my $out = _capture('zstd', '-l', '-v', '--', $image);
	return undef unless defined $out;
	return $1 + 0 if $out =~ /Decompressed\s+Size:.*?\((\d+)\s*B\)/is;
	if ($out =~ /Decompressed\s+Size:\s*([\d.]+)\s*([KMGTP]i?B)/i) {
		my %mult = (
			'B' => 1,
			'KiB' => 1024, 'MiB' => 1024**2, 'GiB' => 1024**3, 'TiB' => 1024**4,
			'KB' => 1000, 'MB' => 1000**2, 'GB' => 1000**3, 'TB' => 1000**4,
			'PB' => 1000**5,
		);
		return undef unless $mult{$2};
		return int($1 * $mult{$2} + 0.5);
	}
	return undef;
}

sub _backup_device {
	my ($dev, $path) = @_;
	my $dir = File::Basename::dirname($path);
	File::Path::make_path($dir) unless -d $dir;
	# dd reads a block device to its end, so the backup is the whole disk.
	my $rc = system('dd', "if=$dev", "of=$path", 'bs=8M');
	return { ok => 0, error => "could not back up $dev to $path" } if $rc != 0;
	system('sync');
	return { ok => 1 };
}

# Stream the image into dd. Hashing the source stream while it is fed and then
# reading the same number of bytes back is what proves the write, not dd's word
# for it. A compressed image is decompressed on the fly; no 6 GB temp file.
sub _write_image {
	my ($image, $dev, $dry, $expected) = @_;
	my $compressed = ($image =~ /\.zst$/i) ? 1 : 0;
	if ($compressed && !_command_path('zstd')) {
		return { ok => 0, error => 'zstd is not installed' };
	}
	if ($dry) {
		_note('dry run: would write ' . $image . ' to ' . $dev
			. ($compressed ? ' through zstd -dc' : '')
			. (defined $expected ? " ($expected bytes)" : ''));
		return { ok => 1, bytes => $expected, sha256_match => undef };
	}
	local $SIG{'PIPE'} = 'IGNORE';
	my $dd_open = open(my $dd, '|-', 'dd', "of=$dev", 'bs=8M', 'conv=fsync');
	return { ok => 0, error => "could not start dd: $!" } unless $dd_open;
	my ($src, $src_open);
	if ($compressed) {
		$src_open = open($src, '-|', 'zstd', '-dc', '--', $image);
	}
	else {
		$src_open = open($src, '<:raw', $image);
	}
	unless ($src_open) {
		close $dd;
		return { ok => 0, error => "could not read $image" };
	}
	my $sha = Digest::SHA->new(256);
	my $count = 0;
	my $error = '';
	my $started = Time::HiRes::time();
	my $last_report = $started;
	while (1) {
		last if $CANCELLED;
		my $read = read($src, my $buffer, 8 * 1024 * 1024);
		unless (defined $read) {
			$error = "reading $image failed: $!" unless $CANCELLED;
			last;
		}
		last unless $read > 0;
		$sha->add($buffer);
		my $offset = 0;
		while ($offset < $read) {
			my $wrote = syswrite($dd, $buffer, $read - $offset, $offset);
			unless (defined $wrote && $wrote > 0) {
				$error = 'dd stopped accepting data: ' . ($! || 'write returned 0') unless $CANCELLED;
				last;
			}
			$offset += $wrote;
		}
		last if length $error;
		$count += $read;
		my $now = Time::HiRes::time();
		if ($now - $last_report >= 0.5) {
			$last_report = $now;
			my $elapsed = $now - $started;
			my $rate = $elapsed > 0 ? int($count / $elapsed) : 0;
			_progress_write('writing', bytes => $count, total => $expected, rate => $rate);
		}
	}
	close $src;
	my $src_status = $?;
	close $dd;
	my $dd_status = $?;
	return { ok => 0, cancelled => 1, bytes => $count, error => 'cancelled' } if $CANCELLED;
	return { ok => 0, error => $error } if length $error;
	return { ok => 0, error => 'reading ' . $image . ' failed' } if $src_status != 0;
	return { ok => 0, error => 'dd failed writing ' . $dev } if $dd_status != 0;
	if (defined $expected && $expected != $count) {
		return { ok => 0, error => "wrote $count bytes, expected $expected" };
	}
	my $elapsed = Time::HiRes::time() - $started;
	_progress_write('verifying', bytes => $count, total => $expected,
		rate => ($elapsed > 0 ? int($count / $elapsed) : 0));
	system('sync');
	system('blockdev', '--flushbufs', $dev) if _command_path('blockdev');

	# Read the first N bytes back and compare digests. N comes from zstd -l or
	# the file size; dd's own count is the same number and is the fallback.
	my $length = defined $expected ? $expected : $count;
	my $back = Digest::SHA->new(256);
	# The read-back goes through dd, not read(2): the USB gadget answers a raw
	# read in a few kilobytes, so a plain loop made one syscall per 4 KB - a
	# silent ten-minute crawl at a bar pinned on 100% for a 6.8 GB image. dd
	# asks for whole blocks and its count is bounded by the image, not by the
	# 14.6 GB disk behind it.
	my $blocks = int(($length + 8 * 1024 * 1024 - 1) / (8 * 1024 * 1024));
	my $left = $length;
	my $read_back = 0;
	my $verify_started = Time::HiRes::time();
	my $verify_report = $verify_started;
	_progress_write('verifying', bytes => 0, total => $length, rate => 0);
	open my $device, '-|', 'dd', "if=$dev", 'bs=8M', "count=$blocks", 'status=none'
		or return { ok => 0, error => "could not reread $dev: $!" };
	while ($left > 0) {
		last if $CANCELLED;
		my $want = $left > 4 * 1024 * 1024 ? 4 * 1024 * 1024 : $left;
		my $got = read($device, my $buffer, $want);
		last unless defined $got && $got > 0;
		$got = $left if $got > $left;
		$back->add($buffer);
		$left -= $got;
		$read_back += $got;
		my $now = Time::HiRes::time();
		if ($now - $verify_report >= 0.5) {
			$verify_report = $now;
			my $elapsed = $now - $verify_started;
			_progress_write('verifying', bytes => $read_back, total => $length,
				rate => ($elapsed > 0 ? int($read_back / $elapsed) : 0));
		}
	}
	close $device;
	my $read_status = $?;
	return { ok => 0, cancelled => 1, bytes => $count, error => 'cancelled' } if $CANCELLED;
	my $match = ($left == 0 && $back->hexdigest eq $sha->hexdigest) ? 1 : 0;
	return {
		ok => $match,
		bytes => $count,
		sha256_match => $match,
		($match ? () : (error => $left == 0
			? 'the read-back does not match the image'
			: 'the read-back stopped before the end of the image')),
	};
}

# The BOOT partition of the flashed eMMC is the bootloader's: boot.ini and the
# recovery BIOS live there. The provisioner puts the eMMC's own way back into
# recovery there, so a board never depends on a microSD to be recovered.
sub _first_partition {
	my ($dev) = @_;
	my $out = _capture('lsblk', '-lno', 'NAME,TYPE', '--', $dev);
	if (defined $out) {
		for my $line (split /\n/, $out) {
			my ($name, $type) = split /\s+/, _trim($line);
			next unless defined $type && $type eq 'part';
			return "/dev/$name";
		}
	}
	return $dev . 'p1' if $dev =~ m{/dev/(?:mmcblk|nvme)\d+};
	return $dev . '1';
}

# The bootloader's recovery entry. It boots the BIOS already on this partition
# with bootmode=recovery, which starts the USB mass-storage gadget instead of
# JawnOS. Nothing here is needed on the normal path, and a board without the
# marker boots exactly as it did before.
sub _recovery_entry {
	return <<'ENTRY';

# --- JawnOS recovery --------------------------------------------------------
# A board that must come back in recovery carries the marker file RECOVERY on
# this BOOT partition; scripts/gou_recovery.pl writes it and a reflash removes
# it. The BIOS is already here, so this needs no microSD.
if test "x${devno}" = "x"; then setenv devno 0; fi
if test "x${cramfsaddr}" = "x"; then setenv cramfsaddr 0x20000000; fi
if load mmc ${devno}:1 0x1F000000 RECOVERY; then
	setenv bootmode recovery
	setenv bootdev mmc
	load mmc ${devno}:1 ${cramfsaddr} ODROIDBIOS.BIN
	cramfsload 0x2000000 uImage
	cramfsload 0x3000000 rootfs.cpio.uboot
	cramfsload 0x1000000 meson64_odroid${variant}.dtb
	setenv bootargs "root=/dev/ram0 init=/init console=tty0 console=ttyS0,115200 no_console_suspend earlyprintk=aml-uart,0xff803000 ramoops.pstore_en1=1 ramoops.record_size=0x8000 ramoops.console_size=0x4000 logo=osd0,loaded,0x3d800000 vout=${hdmimode},enable hdmimode=${hdmimode} voutmode=dvi disablehpd=true osd_reverse=0 video_reverse=0 bootdev=mmc bootmode=recovery reboot_mode=normal quiet fbcon=rotate:3"
	bootm 0x2000000 0x3000000 0x1000000
fi
ENTRY
}

sub _install_recovery_entry {
	my ($path) = @_;
	my $text = _slurp($path);
	return 0 unless length $text;
	return 0 if index($text, 'load mmc ${devno}:1 0x1F000000 RECOVERY') >= 0;
	my $anchor = "setenv outputmode \"panel\"\n";
	my $at = index($text, $anchor);
	return 0 if $at < 0;
	$at += length $anchor;
	my $fresh = substr($text, 0, $at) . _recovery_entry() . substr($text, $at);
	return _write_file($path, $fresh) ? 1 : 0;
}

# The stock boot.ini starts by sourcing a boot.ini from the card in the slot.
# With a card inserted the board leaves JawnOS for the card (or stops at the
# HardKernel logo) instead of starting the eMMC. A card is data here, so remove
# that look with the same helper the image builder uses.
sub _disable_sd_chainload {
	my ($path) = @_;
	return 0 unless defined $path && -f $path;
	my $helper = File::Basename::dirname(Cwd::abs_path($0)) . '/gou_boot_ini.pl';
	return 0 unless -f $helper;
	my $said = _capture($^X, $helper, '--no-sd-chainload', $path);
	return 0 unless $? == 0;
	return _trim($said) eq 'removed' ? 1 : 0;
}

# Put the recovery entry and the reboot-capable BIOS on the BOOT partition, then
# ask the board to restart. A stock recovery BIOS (a microSD) has no watcher, so
# the wait ends without a restart and the page says to use F3+F6; a board that
# carries this BIOS restarts on its own.
sub _prepare_boot {
	my ($dev) = @_;
	$dev = '/dev/sda' unless defined $dev && length $dev;
	my $p1 = _first_partition($dev);
	return { patched => 0, reboot => 0, reason => "could not find the boot partition of $dev" }
		unless defined $p1 && -e $p1;
	my $mount = _mounted_path($p1);
	my $mounted_here = 0;
	if (!length $mount) {
		$mount = File::Temp::tempdir('gou-boot-XXXXXX', TMPDIR => 1, CLEANUP => 1);
		return { patched => 0, reboot => 0, reason => "could not mount $p1" }
			if system('mount', $p1, $mount) != 0;
		$mounted_here = 1;
	}
	my (@done, @notes);
	push @done, 'sd-chainload' if _disable_sd_chainload("$mount/boot.ini");
	push @done, 'recovery-entry' if _install_recovery_entry("$mount/boot.ini");
	my $patched = 0;
	my $patcher = File::Basename::dirname(Cwd::abs_path($0)) . '/gou_bios_patch.pl';
	if (-f $patcher && -f "$mount/ODROIDBIOS.BIN") {
		my $fresh = "$mount/.ODROIDBIOS.BIN.new";
		if (system($^X, $patcher, '--bios', "$mount/ODROIDBIOS.BIN", '--out', $fresh) == 0
			&& -s $fresh) {
			if (rename($fresh, "$mount/ODROIDBIOS.BIN")) {
				chmod 0644, "$mount/ODROIDBIOS.BIN";
				$patched = _write_file("$mount/JNBIOS.TXT", "jawnos-reboot=1\n") ? 1 : 0;
				push @done, 'reboot-watch' if $patched;
			}
			else {
				unlink $fresh;
				push @notes, 'the recovery BIOS could not be replaced';
			}
		}
		else {
			unlink $fresh;
			push @notes, 'the recovery BIOS could not be rebuilt; the board will not restart on its own';
		}
	}
	my $marker = 0;
	if ($patched && !$opt{'no_reboot'}) {
		$marker = _write_file("$mount/JNREBOOT", "reboot\n") ? 1 : 0;
	}
	system('sync');
	system('umount', $mount) if $mounted_here;
	my $result = { patched => $patched, reboot => $marker, done => \@done, notes => \@notes };
	if ($marker) {
		my $wait = defined $opt{'reboot_wait'} ? $opt{'reboot_wait'} : 8;
		$result->{'rebooted'} = _wait_for_reboot($dev, $wait);
	}
	return $result;
}

# The board restarts by taking its gadget away. A host-side eject would also
# make the device node vanish while the board is still up, so this only watches
# for the board's own departure.
sub _wait_for_reboot {
	my ($dev, $wait) = @_;
	system('blockdev', '--flushbufs', $dev) if _command_path('blockdev');
	my $until = time + ($wait > 0 ? $wait : 0);
	while (time <= $until) {
		return 1 unless -e $dev;
		select(undef, undef, undef, 0.5);
	}
	return 0;
}

# ---------------------------------------------------------------------------
# Autopopulate the flashed rootfs: hostname, the house WiFi, the join token.

# Both rk8xx PMICs are in the device tree, and only one of them can cut the
# power. The kernel installs pm_power_off for the node that carries
# `rockchip,system-power-controller`, so it has to be the rk818 on the always-on
# bus - the one holding vddcpu_a and vddao_3v3. A handler on the rk817 beside it
# writes a charger register instead: the SoC halts, the rails stay up and the
# board sits there with its red light on. The image's DTB carries neither, so
# every flashed board keeps that behaviour until this runs.
sub _pmic_poweroff {
	my ($dev) = @_;
	# Every early return says why. The first board that flashed without this
	# reported nothing at all, and a silent gap in the flash result is the
	# hardest kind to chase: the board is the only place the answer lives.
	unless (_command_path('fdtput') && _command_path('fdtget')) {
		_note('pmic: this host has no dtc tools, so the board keeps the image DTB');
		return 0;
	}
	my $p1 = &_first_partition($dev);
	unless (defined $p1 && -e $p1) {
		_note('pmic: the boot partition is not visible yet (' . (defined $p1 ? $p1 : '?') . ')');
		return 0;
	}
	my $mount = File::Temp::tempdir('gou-boot-XXXXXX', TMPDIR => 1, CLEANUP => 1);
	unless (system('mount', $p1, $mount) == 0) {
		_note("pmic: could not mount $p1");
		return 0;
	}
	my $patched = 0;
	my $dtb = "$mount/amlogic/meson64_odroidgou.dtb";
	my $system = '/soc/bus@ff800000/i2c@5000/pmic@1c';
	my $charger = '/soc/bus@ffd00000/i2c@1c000/pmic@20';
	if (-f $dtb) {
		if ((_capture('fdtget', '-p', $dtb, $charger) // '') =~ /system-power-controller/) {
			system('fdtput', '-d', $dtb, $charger, 'rockchip,system-power-controller');
		}
		$patched = 1 if system('fdtput', $dtb, $system, 'rockchip,system-power-controller') == 0;
		_note('pmic: fdtput refused the device tree') unless $patched;
	}
	else {
		_note("pmic: no $dtb on the boot partition");
	}
	system('sync');
	system('umount', $mount);
	return $patched;
}

sub _second_partition {
	my ($dev) = @_;
	my $out = _capture('lsblk', '-lno', 'NAME,TYPE', '--', $dev);
	if (defined $out) {
		my @parts;
		for my $line (split /\n/, $out) {
			my ($name, $type) = split /\s+/, _trim($line);
			next unless defined $type && $type eq 'part';
			push @parts, $name;
		}
		return "/dev/$parts[1]" if @parts >= 2;
	}
	# Kernel naming: /dev/sdb2, /dev/mmcblk1p2, /dev/nvme0n1p2.
	return $dev . 'p2' if $dev =~ m{/dev/(?:mmcblk|nvme)\d+};
	return $dev . '2';
}

sub _network_manager_profile {
	my ($ssid, $psk) = @_;
	return "[connection]\n"
		. "id=jawn-house\n"
		. "type=wifi\n"
		. "autoconnect=true\n"
		. "\n[wifi]\n"
		. "mode=infrastructure\n"
		. "ssid=$ssid\n"
		. "\n[wifi-security]\n"
		. "key-mgmt=wpa-psk\n"
		. "psk=$psk\n"
		. "\n[ipv4]\n"
		. "method=auto\n";
}

# The one unit a flashed board runs before the house does: redeem the token,
# find its card, then get out of the way. A oneshot with no token left is a
# no-op, so it stays enabled and costs nothing after the first boot.
# The kiosk guard: one pass every fifteen seconds that returns the panel when
# no game owns it. It is a oneshot, so a pass with nothing to heal has to
# succeed - the image's copy ended on a window search and failed forever.
# The first-run questions, on the panel, before the launcher and before the
# root pass that applies the answers: the code that becomes this board's sudo
# password, and the one press that lets its card be erased.
sub _first_run_unit {
	return <<'UNIT';
[Unit]
Description=First-run setup on the controller panel
After=gou-x.service gou-rotate.service
Wants=gou-x.service
Before=jawnos-first-boot.service jawnos-kiosk.service

[Service]
Type=oneshot
User=jawn
Group=jawn
Environment=HOME=/home/jawn
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1001
# A dialog that cannot draw must never hold the boot: the pass behind it sees
# no answers and simply does nothing of its own.
ExecStart=-/usr/bin/python3 /home/jawn/jawnos/scripts/gou_first_run.py
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
}

sub _kiosk_guard_unit {
	return <<'UNIT';
[Unit]
Description=Return the JawnOS kiosk when no game or dark idle owns the panel

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gou-kiosk-guard
UNIT
}

sub _kiosk_guard_timer {
	return <<'UNIT';
[Unit]
Description=Check the kiosk every fifteen seconds

[Timer]
OnBootSec=20s
OnUnitActiveSec=15s

[Install]
WantedBy=timers.target
UNIT
}

# The 8821CU combo adapter can fail to enumerate after a warm reboot. The boot
# service is the first attempt; the timer repeats it, because a board whose
# adapter appeared and then vanished (or whose first pass ran too early) has no
# other way back without a hand on the power switch.
sub _wifi_reset_unit {
	return <<'UNIT';
[Unit]
Description=Reset the ODROID USB WiFi adapter if it did not enumerate
After=NetworkManager.service bluetooth.service
Wants=NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/gou-wifi-reset

[Install]
WantedBy=multi-user.target
UNIT
}

sub _wifi_reset_timer {
	return <<'UNIT';
[Unit]
Description=Retry the WiFi adapter reset while wlan0 is missing

[Timer]
OnBootSec=45s
OnUnitActiveSec=60s

[Install]
WantedBy=timers.target
UNIT
}

# A flashed card may carry a RetroArch built against an OpenSSL newer than its
# openssl package. The games installer stages the needed sonames privately, but
# a card that already has the emulators never runs that install. This oneshot
# runs the same helper once at boot, before the manager, so a fresh flash starts
# with a working frontend. It is idempotent: with the layer present it only
# verifies the loader and the binary.
sub _openssl_compat_unit {
	return <<'UNIT';
[Unit]
Description=Give RetroArch the OpenSSL its build needs
After=network-online.target
Wants=network-online.target
Before=jawnos.service

[Service]
Type=oneshot
ExecStart=/usr/bin/perl /home/jawn/jawnos/scripts/jawnos_game_openssl.pl
StandardOutput=null
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
}

sub _first_boot_unit {
	return <<'UNIT';
[Unit]
Description=JawnOS first boot: the board's card and the house join
Wants=network-online.target
After=network-online.target gou-wifi-reset.service gou-first-run.service
Before=jawnos.service

[Service]
Type=oneshot
# The mount and the mkfs need root, but the files this pass writes belong to the
# board's own account: HOME is that account so `~` in the script names its home,
# not root's.
Environment=HOME=/home/jawn
ExecStart=/usr/bin/perl /home/jawn/jawnos/scripts/gou_first_boot.pl
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
}

# A wants link is relative to the directory that holds it. Pointing at the bare
# unit name makes the link resolve to itself, and systemd refuses the loop.
sub _wants_link {
	my ($wants, $unit) = @_;
	my $link = "$wants/$unit";
	my $target = "../$unit";
	unlink $link if -l $link && readlink($link) ne $target;
	symlink($target, $link) unless -l $link;
	return 1;
}

# The mark on the panel while the Manager starts. gou-rotate presents the X
# root, so painting the root puts the mark up the moment the kernel console
# goes away; a kiosk that never arrives leaves the mark rather than a bare
# cursor. The script composes one full-screen frame (black, one centred mark,
# its halo, the step and a progress bar); the old unit handed the icon straight
# to display(1), which tiled it three times across the root.
sub _splash_unit {
	return <<'UNIT';
[Unit]
Description=JawnOS boot splash on the panel
After=gou-x.service gou-rotate.service
Wants=gou-x.service
Before=jawnos-kiosk.service

[Service]
Type=simple
User=jawn
Group=jawn
Environment=HOME=/home/jawn
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=/run/user/1001
ExecStart=-/usr/bin/perl /home/jawn/jawnos/scripts/gou_splash.pl --watch
Restart=no

[Install]
WantedBy=multi-user.target
UNIT
}

# The panel's rotation presenter is the stock unit, which requires X. X can
# fail its first start while the display is coming up, and a failed dependency
# then killed the presenter for the whole boot; the panel stayed on the kernel
# console. The drop-in drops the hard dependency, so the presenter starts
# anyway and its own Restart=always waits for X.
sub _rotate_dropin {
	return <<'UNIT';
[Unit]
Requires=
Wants=gou-x.service
UNIT
}

# jawn exits 3 when another master is already serving. On a controller the
# kiosk owns that master, so the service must accept the status instead of
# restarting into the same answer every five seconds.
sub _standdown_dropin {
	return <<'UNIT';
[Service]
SuccessExitStatus=3
RestartPreventExitStatus=3
UNIT
}

# The panel is 480x854 on a 2 GB board, and Qt WebEngine is the largest thing
# on it. These flags are Chromium's own low-memory mode: one renderer, the
# small-heap profile, and shared memory in /tmp (the tiny /dev/shm fills first).
# They go after the script's own export so both sets apply.
sub _tune_kiosk {
	my ($mount) = @_;
	my $path = "$mount/home/jawn/.local/bin/jawnos-kiosk.sh";
	my $script = _slurp($path);
	return 0 unless length $script;
	return 0 if index($script, 'enable-low-end-device-mode') >= 0;
	my $decl = index($script, 'export QTWEBENGINE_CHROMIUM_FLAGS');
	return 0 if $decl < 0;
	my $eol = index($script, "\n", $decl);
	return 0 if $eol < 0;
	my $line = 'export QTWEBENGINE_CHROMIUM_FLAGS="$QTWEBENGINE_CHROMIUM_FLAGS'
		. ' --enable-low-end-device-mode --renderer-process-limit=1 --disable-dev-shm-usage"' . "\n";
	my $fresh = substr($script, 0, $eol + 1) . $line . substr($script, $eol + 1);
	return _write_file($path, $fresh) ? 1 : 0;
}

# The image is a copy of another card. Everything that makes that card itself
# - its config, database, keys, runtime state, saved networks and host identity
# - has to go before this board introduces itself. The builder's exclusion list
# removes most of it; this is the last pass, so an image built before that list
# existed still comes out a new board rather than a clone.
sub _scrub_copied_machine {
	my ($mount) = @_;
	my $home = "$mount/home/jawn";
	my $tree = "$home/jawnos";
	my @done;

	my $identity = 0;
	foreach my $path ("$home/.jawnos_signatorial", "$home/.jawnos_signatorial_id",
		"$tree/database/.jawnos_signatorial_id", "$home/.house.key",
		"$home/.peer.key", "$home/.peer.pub",
		"$tree/server/fullchain.pem", "$tree/server/privkey.pem",
		"$tree/server/peer-fullchain.pem", "$tree/server/peer-privkey.pem",
		"$tree/server/house-ca.key", "$tree/.shots/ticket.txt",
		"$home/.local/share/jawnos/.shots/ticket.txt",
		"$home/UNLOCK-CODE.txt", "$home/unlock-code.txt") {
		$identity = 1 if -f $path && unlink $path;
	}
	# The desktop shell's own config and ticket store. A copied ticket.enc wins
	# over the fresh .shots ticket the first boot writes, so a board that kept it
	# tried to log in with the source machine's token and parked at the Gate.
	if (-d "$home/.config/jawnos") {
		File::Path::remove_tree("$home/.config/jawnos");
		$identity = 1;
	}
	# machine-id is this system's identity to journald and dbus; systemd mints a
	# new one when the file is absent. The SSH host keys are the same story.
	$identity = 1 if -f "$mount/etc/machine-id" && unlink("$mount/etc/machine-id");
	foreach my $key (glob("$mount/etc/ssh/ssh_host_*")) {
		$identity = 1 if -f $key && unlink $key;
	}
	push @done, 'identity' if $identity;

	my $config = "$tree/config.json";
	push @done, 'config' if -f $config && unlink $config;

	my $database = 0;
	foreach my $path ("$tree/database/jawnos.db", "$tree/database/jawnos.db-wal",
		"$tree/database/jawnos.db-shm") {
		$database = 1 if -f $path && unlink $path;
	}
	if (-d "$tree/database/backups") {
		File::Path::remove_tree("$tree/database/backups");
		$database = 1;
	}
	push @done, 'database' if $database;

	my $state = 0;
	if (-d "$home/.president") {
		File::Path::remove_tree("$home/.president");
		$state = 1;
	}
	push @done, 'state' if $state;

	# The source card's saved Wi-Fi is the source's network; the provisioner
	# writes this board's own profile after this pass. The USB gadget stays: it is
	# how a board with no Wi-Fi is reached.
	my $networks = 0;
	foreach my $profile (glob("$mount/etc/NetworkManager/system-connections/*.nmconnection")) {
		next if $profile =~ m{/usb-gadget\.nmconnection$};
		$networks = 1 if -f $profile && unlink $profile;
	}
	push @done, 'network' if $networks;

	return @done;
}

sub _autopopulate {
	my ($dev, $hostname, $ssid, $psk, $join) = @_;
	system('blockdev', '--rereadpt', $dev) if _command_path('blockdev');
	system('partprobe', $dev) if _command_path('partprobe');
	sleep 1;
	my $part = _second_partition($dev);
	return { ok => 0, error => "could not find the second partition of $dev" }
		unless defined $part && -e $part;
	my $mount = _mounted_path($part);
	my $mounted_here = 0;
	if (length $mount) {
		# udev may already have mounted the rootfs; use it and leave it alone.
		_note("using the existing mount of $part at $mount");
	}
	else {
		$mount = File::Temp::tempdir('gou-rootfs-XXXXXX', TMPDIR => 1, CLEANUP => 1);
		my $rc = system('mount', $part, $mount);
		return { ok => 0, error => "could not mount $part" } if $rc != 0;
		$mounted_here = 1;
	}
	my (@done, $error);
	# The image is a copy of another card: everything that makes that card
	# itself goes before this board writes anything of its own.
	push @done, &_scrub_copied_machine($mount);
	my $etc = "$mount/etc";
	File::Path::make_path($etc) unless -d $etc;
	# The scrub removed the copied machine-id. systemd is supposed to mint one on
	# the first boot, but it runs before the initrd's root is remounted writable,
	# so it writes the sentinel `uninitialized` instead - and systemd-journald,
	# which restarts forever ahead of sysinit.target, then never lets the boot
	# leave early userspace. Write a real id now, one per board.
	my $machine_id = _fresh_machine_id();
	if (defined $machine_id && _write_file("$etc/machine-id", "$machine_id\n")) {
		chmod 0644, "$etc/machine-id";
		chown 0, 0, "$etc/machine-id";
		push @done, 'machine-id';
	}
	else {
		$error = 'could not write /etc/machine-id';
	}
	if (!length $error && _write_file("$etc/hostname", "$hostname\n")) {
		chmod 0644, "$etc/hostname";
		chown 0, 0, "$etc/hostname";
		push @done, 'hostname';
	}
	else {
		$error = 'could not write /etc/hostname';
	}
	if (!length $error && defined $ssid && defined $psk) {
		my $dir = "$mount/etc/NetworkManager/system-connections";
		File::Path::make_path($dir) unless -d $dir;
		my $path = "$dir/jawn-house.nmconnection";
		if (_write_file($path, _network_manager_profile($ssid, $psk))
			&& chmod(0600, $path) && chown(0, 0, $path)) {
			push @done, 'wifi';
		}
		else {
			$error = 'could not write the WiFi profile';
		}
	}
	if (!length $error && defined $join) {
		my $dir = "$mount/home/jawn/jawnos";
		File::Path::make_path($dir) unless -d $dir;
		my $path = "$dir/.controller-join.json";
		# The token is read on the board as JSON, and a token file that has gone
		# (the house cleaned it up while a twenty-minute write ran) used to be
		# copied as an empty file and reported as filled in. The board then stopped
		# on "the join token is not JSON" before it reached the card, so a wipe the
		# person asked for never happened. Refuse it here, where the flash can say
		# so, instead of shipping a board that cannot finish its first boot.
		my $token = _slurp($join);
		$token = '' unless defined $token;
		my $parsed = length $token ? eval { JSON::PP->new->decode($token); 1 } : 0;
		if (!$parsed) {
			$error = "the join token at $join is empty or not JSON";
		}
		elsif (_write_file($path, $token)
			&& chmod(0600, $path) && chown(1001, 1001, $path)) {
			push @done, 'join-token';
		}
		elsif (!length $error) {
			$error = 'could not copy the join token';
		}
		# The source card's identity, config and database went in the scrub above;
		# the first boot mints this board's own before it introduces itself (see
		# gou_first_boot.pl).
	}
	# The board redeems that token, and looks for its card, before the house
	# starts. The unit is enabled by its wants symlink rather than by running
	# systemctl against the image, so nothing here needs the board booted.
	if (!length $error) {
		# The scripts come from this tree, not from the image: the image is a copy
		# of another card, whose tree may predate it (or not be a tree at all),
		# and a unit or a person that calls a missing script would fail silently
		# on the boot that matters.
		my $source_dir = File::Basename::dirname(Cwd::abs_path($0));
		my $dir = "$mount/home/jawn/jawnos/scripts";
		File::Path::make_path($dir) unless -d $dir;
		for my $name (qw(gou_first_boot.pl gou_boot_ini.pl gou_recovery.pl gou_splash.pl gou_first_run.py jawnos_game_openssl.pl)) {
			my $source = "$source_dir/$name";
			my $script = -f $source ? _slurp($source) : '';
			my $path = "$dir/$name";
			unless (length $script
				&& _write_file($path, $script)
				&& chmod(0755, $path) && chown(1001, 1001, $path)) {
				$error = "could not copy $name";
				last;
			}
			push @done, $name eq 'gou_first_boot.pl' ? 'first-boot-script'
				: $name eq 'gou_boot_ini.pl' ? 'boot-ini'
				: $name eq 'gou_splash.pl' ? 'splash-script'
				: $name eq 'gou_first_run.py' ? 'first-run-dialog'
				: $name eq 'jawnos_game_openssl.pl' ? 'openssl-script' : 'recovery-script';
		}
	}
	if (!length $error) {
		my $units = "$etc/systemd/system";
		File::Path::make_path($units) unless -d $units;
		my $unit = "$units/jawnos-first-boot.service";
		my $wants = "$units/multi-user.target.wants";
		File::Path::make_path($wants) unless -d $wants;
		if (_write_file($unit, _first_boot_unit())
			&& chmod(0644, $unit) && chown(0, 0, $unit)) {
			# The target is relative to the wants directory. A bare
			# 'jawnos-first-boot.service' made the link point at itself, and
			# systemd refused the loop ("too many levels of symbolic links"), so
			# the unit never ran: no config seed, no join, no kiosk ticket.
			&_wants_link($wants, 'jawnos-first-boot.service');
			push @done, 'first-boot';
		}
		else {
			$error = 'could not write the first-boot unit';
		}
	}
	if (!length $error) {
		my $units = "$etc/systemd/system";
		my $wants = "$units/multi-user.target.wants";
		File::Path::make_path($wants) unless -d $wants;
		my $splash = "$units/gou-splash.service";
		if (_write_file($splash, _splash_unit()) && chmod(0644, $splash) && chown(0, 0, $splash)) {
			&_wants_link($wants, 'gou-splash.service');
			push @done, 'splash';
		}
		else {
			$error = 'could not write the splash unit';
		}
	}
	if (!length $error) {
		my $dir = "$etc/systemd/system/gou-rotate.service.d";
		File::Path::make_path($dir) unless -d $dir;
		my $dropin = "$dir/20-wants.conf";
		if (_write_file($dropin, _rotate_dropin()) && chmod(0644, $dropin) && chown(0, 0, $dropin)) {
			push @done, 'rotate-presenter';
		}
		else {
			$error = 'could not write the rotation presenter drop-in';
		}
	}
	if (!length $error) {
		my $dir = "$etc/systemd/system/jawnos.service.d";
		File::Path::make_path($dir) unless -d $dir;
		my $dropin = "$dir/10-standdown.conf";
		if (_write_file($dropin, _standdown_dropin()) && chmod(0644, $dropin) && chown(0, 0, $dropin)) {
			push @done, 'standdown';
		}
		else {
			$error = 'could not write the stand-down unit drop-in';
		}
	}
	if (!length $error) {
		my $units = "$etc/systemd/system";
		my $wants = "$units/multi-user.target.wants";
		File::Path::make_path($wants) unless -d $wants;
		my $unit = "$units/gou-first-run.service";
		if (_write_file($unit, _first_run_unit()) && chmod(0644, $unit) && chown(0, 0, $unit)) {
			&_wants_link($wants, 'gou-first-run.service');
			push @done, 'first-run-unit';
		}
		else {
			$error = 'could not write the first-run unit';
		}
	}
	if (!length $error) {
		# The panel's guard. Written from this tree rather than trusted to the
		# image, which is a copy of an older card: the installer's guard failed
		# on every run, so the timer left the unit failed for a board's whole
		# life. The script and its two units travel together.
		my $source = File::Basename::dirname(Cwd::abs_path($0)) . '/gou_kiosk_guard.sh';
		my $body = -f $source ? _slurp($source) : '';
		my $sbin = "$mount/usr/local/sbin";
		File::Path::make_path($sbin) unless -d $sbin;
		my $path = "$sbin/gou-kiosk-guard";
		if (length $body && _write_file($path, $body) && chmod(0755, $path) && chown(0, 0, $path)) {
			my $units = "$etc/systemd/system";
			my $wants = "$units/timers.target.wants";
			File::Path::make_path($wants) unless -d $wants;
			my $svc = "$units/gou-kiosk-guard.service";
			my $timer = "$units/gou-kiosk-guard.timer";
			if (_write_file($svc, _kiosk_guard_unit()) && chmod(0644, $svc) && chown(0, 0, $svc)
				&& _write_file($timer, _kiosk_guard_timer()) && chmod(0644, $timer) && chown(0, 0, $timer)) {
				&_wants_link($wants, 'gou-kiosk-guard.timer');
				push @done, 'kiosk-guard';
			}
			else {
				$error = 'could not write the kiosk guard units';
			}
		}
		else {
			$error = 'could not copy the kiosk guard script';
		}
	}
	if (!length $error) {
		# The Realtek 8821CU combo adapter can miss the USB enumeration after a
		# warm reboot, leaving a board with no wlan0 and no way back but a hard
		# power-cycle. The script and its units travel with the flash, so a
		# reimaged card keeps the recovery the live card learned the hard way.
		my $source = File::Basename::dirname(Cwd::abs_path($0)) . '/gou_wifi_reset.sh';
		my $body = -f $source ? _slurp($source) : '';
		my $sbin = "$mount/usr/local/sbin";
		File::Path::make_path($sbin) unless -d $sbin;
		my $path = "$sbin/gou-wifi-reset";
		if (length $body && _write_file($path, $body) && chmod(0755, $path) && chown(0, 0, $path)) {
			my $units = "$etc/systemd/system";
			my $boot_wants = "$units/multi-user.target.wants";
			my $timer_wants = "$units/timers.target.wants";
			File::Path::make_path($boot_wants) unless -d $boot_wants;
			File::Path::make_path($timer_wants) unless -d $timer_wants;
			my $svc = "$units/gou-wifi-reset.service";
			my $timer = "$units/gou-wifi-reset.timer";
			if (_write_file($svc, _wifi_reset_unit()) && chmod(0644, $svc) && chown(0, 0, $svc)
				&& _write_file($timer, _wifi_reset_timer()) && chmod(0644, $timer) && chown(0, 0, $timer)) {
				&_wants_link($boot_wants, 'gou-wifi-reset.service');
				&_wants_link($timer_wants, 'gou-wifi-reset.timer');
				push @done, 'wifi-guard';
			}
			else {
				$error = 'could not write the WiFi guard units';
			}
		}
		else {
			$error = 'could not copy the WiFi guard script';
		}
	}
	if (!length $error) {
		# The emulator's private OpenSSL layer is applied once, before the
		# manager starts. A card that was flashed with the emulators already in
		# place never presses "Install emulators", so the install helper cannot be
		# the only caller.
		my $units = "$etc/systemd/system";
		my $wants = "$units/multi-user.target.wants";
		File::Path::make_path($wants) unless -d $wants;
		my $unit = "$units/gou-openssl-compat.service";
		if (_write_file($unit, _openssl_compat_unit()) && chmod(0644, $unit) && chown(0, 0, $unit)) {
			&_wants_link($wants, 'gou-openssl-compat.service');
			push @done, 'openssl-compat-unit';
		}
		else {
			$error = 'could not write the OpenSSL compat unit';
		}
	}
	if (!length $error) {
		push @done, 'low-memory-kiosk' if &_tune_kiosk($mount);
	}
	if (!length $error) {
		# The card in the slot is often blank and the New form may format it on
		# first start. The board keeps its own copy of the recovery image, so a
		# recovery card can be made again from the board or from this tree.
		my $recovery = defined $opt{'recovery_image'} && length $opt{'recovery_image'}
			? $opt{'recovery_image'} : $DEFAULT_RECOVERY;
		if (-f $recovery) {
			my $dir = "$mount/home/jawn/jawnos/recovery";
			File::Path::make_path($dir) unless -d $dir;
			my $path = "$dir/sdcard_recovery.img";
			if (File::Copy::copy($recovery, $path) && chmod(0644, $path) && chown(1001, 1001, $path)) {
				push @done, 'recovery';
			}
			else {
				unlink $path;
				_note('the recovery image could not be copied; the board carries none');
			}
		}
	}
	system('sync');
	if ($mounted_here) {
		my $rc = system('umount', $mount);
		$error = "could not unmount $mount" if !length $error && $rc != 0;
	}
	return { ok => 0, error => $error } if length $error;
	return { ok => 1, done => \@done };
}

# ---------------------------------------------------------------------------
# --flash

sub _flash {
	# A person's own fields are checked first: a name, a password or a hostname
	# that cannot be written is answered before the device is looked for, and
	# never leaves the person watching a scan for a board that would be refused.
	local $SIG{'TERM'} = sub { $CANCELLED = 1 };
	local $SIG{'INT'} = sub { $CANCELLED = 1 };
	# Say who is running before any check. The image hash can take half a minute,
	# and the status route needs this pid to leave a waiting job alone.
	_progress_write('starting', bytes => 0, rate => 0);
	my $hostname = defined $opt{'hostname'} && length $opt{'hostname'} ? $opt{'hostname'} : $DEFAULT_HOSTNAME;
	unless ($hostname =~ /^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$/) {
		_fail(4, 'invalid hostname');
	}
	my ($ssid, $psk) = ($opt{'wifi_ssid'}, $opt{'wifi_psk'});
	# The manager hands the password over on stdin (--wifi-psk-stdin) so a secret
	# is not visible in `ps` while the write runs; a person flashing by hand may
	# still name it on the command line.
	if ($opt{'wifi_psk_stdin'}) {
		_fail(4, 'give one of --wifi-psk and --wifi-psk-stdin') if defined $psk;
		my $piped = <STDIN>;
		$piped = '' unless defined $piped;
		$piped =~ s/\r?\n\z//;
		$psk = $piped;
	}
	if (defined $ssid || defined $psk) {
		_fail(4, 'give both the WiFi name and its password') unless defined $ssid && defined $psk;
		_fail(4, 'invalid WiFi SSID') unless length $ssid && length($ssid) <= 32;
		_fail(4, 'invalid WiFi password') unless length($psk) >= 8 && length($psk) <= 63;
		_fail(4, 'invalid WiFi value') if $ssid =~ /[\r\n]/ || $psk =~ /[\r\n]/;
	}
	my $join = $opt{'join_token'};
	if (defined $join && length $join) {
		_fail(4, "join token not found: $join") unless -f $join;
		my $parsed = eval { JSON::PP->new->decode(_slurp($join)) };
		_fail(4, 'the join token is not JSON') unless defined $parsed;
	}
	else {
		$join = undef;
	}

	my $image = (defined $opt{'image'} && length $opt{'image'}) ? $opt{'image'} : _default_image();
	unless (length $image && -f $image) {
		_fail(4, 'image not found: ' . (length $image ? $image : "no gou-emmc-*.img.zst in $IMAGE_DIR"));
	}
	my $length = _uncompressed_length($image);
	# The hash of a multi-gigabyte image takes a while and comes before the first
	# write; say so, or the page sits on "starting" with no total to show.
	_progress_write('checking', image => $image, total => $length, hostname => $hostname, bytes => 0, rate => 0);
	my $want = _sibling_sha256($image);
	if (defined $want) {
		my $got = _file_sha256($image);
		_fail(4, 'could not read the image to check its sha256') unless defined $got;
		_fail(4, "the image's sha256 does not match its .sha256 sibling") unless $got eq $want;
		_note("image sha256 verified: $got");
	}
	my $dev = $opt{'device'};
	if (!defined $dev || !length $dev) {
		my @candidates = _candidate_devices();
		_fail(2, 'no device') unless @candidates;
		_fail(2, 'more than one candidate device; name one with --device') if @candidates > 1;
		$dev = $candidates[0];
	}
	my $check = _fingerprint($dev);
	_fail(3, $check->{'error'}) unless $check->{'ok'};
	my $root = _root_disk();
	_fail(3, "refusing the root disk $dev") if length $root && $root eq $check->{'name'};
	_fail(3, "refusing a mounted device $dev") if _device_mounted($dev);
	_fail(5, 'this helper must run as root to flash') if $< != 0 && !$opt{'dry_run'};

	my $backup = $opt{'backup'};
	if (defined $backup && length $backup) {
		if ($opt{'dry_run'}) {
			_note("dry run: would back up $dev to $backup");
		}
		else {
			_note("backing up $dev to $backup");
			my $saved = _backup_device($dev, $backup);
			_fail(5, $saved->{'error'}) unless $saved->{'ok'};
		}
	}

	_note('flashing ' . $image . ' to ' . $dev
		. (defined $length ? " ($length bytes)" : ''));
	_progress_write('writing',
		device => $dev, image => $image, total => $length, bytes => 0, rate => 0,
		hostname => $hostname, device_bytes => $EMMC_SIZE * 512);
	my $write = _write_image($image, $dev, $opt{'dry_run'}, $length);
	if ($write->{'cancelled'}) {
		_progress_write('cancelled', device => $dev, image => $image, total => $length,
			bytes => ($write->{'bytes'} // 0), hostname => $hostname);
		_emit({ ok => 0, cancelled => 1, error => 'cancelled' }, 1);
	}
	_fail(5, $write->{'error'}) unless $write->{'ok'};

	my @done;
	if (!$opt{'dry_run'}) {
		system('blockdev', '--rereadpt', $dev) if _command_path('blockdev');
		system('partprobe', $dev) if _command_path('partprobe');
		push @done, 'pmic-poweroff' if &_pmic_poweroff($dev);
	}
	if (!$opt{'no_autopopulate'} && !$opt{'dry_run'}) {
		_progress_write('preparing', device => $dev, image => $image, total => $length,
			bytes => $write->{'bytes'}, hostname => $hostname);
		my $populated = _autopopulate($dev, $hostname, $ssid, $psk, $join);
		_fail(5, $populated->{'error'}) unless $populated->{'ok'};
		@done = @{ $populated->{'done'} || [] };
	}

	my $boot = {};
	if (!$opt{'dry_run'}) {
		_progress_write('finishing', device => $dev, image => $image, total => $length,
			bytes => $write->{'bytes'}, hostname => $hostname);
		$boot = _prepare_boot($dev);
		_note($_) for @{ $boot->{'notes'} || [] };
		push @done, @{ $boot->{'done'} || [] };
	}

	_progress_write('done',
		device => $dev, image => $image, total => $length,
		bytes => $write->{'bytes'}, hostname => $hostname,
		sha256_match => $write->{'sha256_match'}, autopopulated => \@done,
		reboot => ($boot->{'reboot'} ? 1 : 0),
		rebooted => ($boot->{'rebooted'} ? 1 : 0),
		($opt{'dry_run'} ? (dry_run => 1) : ()));

	_emit({
		ok => 1,
		device => $dev,
		image => $image,
		bytes_written => $write->{'bytes'},
		sha256_match => $write->{'sha256_match'},
		autopopulated => \@done,
		reboot => ($boot->{'reboot'} ? 1 : 0),
		rebooted => ($boot->{'rebooted'} ? 1 : 0),
		($opt{'dry_run'} ? (dry_run => 1) : ()),
		(defined $backup && length $backup ? (backup => $backup) : ()),
	}, 0);
}

# The devices _scan would show, as bare paths.
sub _candidate_devices {
	return map { $_->{'dev'} } _candidates();
}
