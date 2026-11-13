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
#   --image PATH                 default /home/jawn/gou/gou-emmc-0.1.2807.img.zst
#   --wifi-ssid S --wifi-psk P   write a NetworkManager profile
#   --wifi-psk-stdin             read the password from stdin instead of argv
#   --hostname NAME              default 'gou'
#   --join-token FILE            JSON copied to
#                                /home/jawn/jawnos/.controller-join.json
#   --no-autopopulate            skip the rootfs writes
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
use File::Path ();
use File::Temp ();
use Getopt::Long ();
use JSON::PP ();

# The ODROID Go Ultra's eMMC as the USB gadget presents it: 15,634,268,160
# bytes. A device with any other size is a different disk and is refused.
my $EMMC_SIZE = 30_535_680;
my $DEFAULT_IMAGE = '/home/jawn/gou/gou-emmc-0.1.2807.img.zst';
my $DEFAULT_HOSTNAME = 'gou';

my $JSON = JSON::PP->new->utf8(1)->canonical(1);

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
	'no-autopopulate' => \$opt{'no_autopopulate'},
	'dry-run'         => \$opt{'dry_run'},
	'backup=s'        => \$opt{'backup'},
	'help|h'          => \$opt{'help'},
) or _fail(4, 'bad options');

if ($opt{'help'}) {
	print <<'USAGE';
gou_provision.pl --scan | --flash [--device /dev/sdX]
  [--image FILE] [--wifi-ssid S --wifi-psk P | --wifi-psk-stdin] [--hostname NAME]
  [--join-token FILE] [--no-autopopulate] [--dry-run] [--backup PATH]
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

# ---------------------------------------------------------------------------
# sysfs: the device's own answer, never a guess from lsblk.

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
	while (1) {
		my $read = read($src, my $buffer, 8 * 1024 * 1024);
		unless (defined $read) {
			$error = "reading $image failed: $!";
			last;
		}
		last unless $read > 0;
		$sha->add($buffer);
		my $offset = 0;
		while ($offset < $read) {
			my $wrote = syswrite($dd, $buffer, $read - $offset, $offset);
			unless (defined $wrote && $wrote > 0) {
				$error = 'dd stopped accepting data: ' . ($! || 'write returned 0');
				last;
			}
			$offset += $wrote;
		}
		last if length $error;
		$count += $read;
	}
	close $src;
	my $src_status = $?;
	close $dd;
	my $dd_status = $?;
	return { ok => 0, error => $error } if length $error;
	return { ok => 0, error => 'reading ' . $image . ' failed' } if $src_status != 0;
	return { ok => 0, error => 'dd failed writing ' . $dev } if $dd_status != 0;
	if (defined $expected && $expected != $count) {
		return { ok => 0, error => "wrote $count bytes, expected $expected" };
	}
	system('sync');
	system('blockdev', '--flushbufs', $dev) if _command_path('blockdev');

	# Read the first N bytes back and compare digests. N comes from zstd -l or
	# the file size; dd's own count is the same number and is the fallback.
	my $length = defined $expected ? $expected : $count;
	my $back = Digest::SHA->new(256);
	open my $device, '<:raw', $dev or return { ok => 0, error => "could not reread $dev: $!" };
	my $left = $length;
	while ($left > 0) {
		my $want = $left > 8 * 1024 * 1024 ? 8 * 1024 * 1024 : $left;
		my $got = read($device, my $buffer, $want);
		last unless defined $got && $got > 0;
		$back->add($buffer);
		$left -= $got;
	}
	close $device;
	my $match = ($left == 0 && $back->hexdigest eq $sha->hexdigest) ? 1 : 0;
	return {
		ok => $match,
		bytes => $count,
		sha256_match => $match,
		($match ? () : (error => 'the read-back does not match the image')),
	};
}

# ---------------------------------------------------------------------------
# Autopopulate the flashed rootfs: hostname, the house WiFi, the join token.

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
sub _first_boot_unit {
	return <<'UNIT';
[Unit]
Description=JawnOS first boot: the board's card and the house join
Wants=network-online.target
After=network-online.target
Before=jawnos.service

[Service]
Type=oneshot
ExecStart=/usr/bin/perl /home/jawn/jawnos/scripts/gou_first_boot.pl
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
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
	my $etc = "$mount/etc";
	File::Path::make_path($etc) unless -d $etc;
	if (_write_file("$etc/hostname", "$hostname\n")) {
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
		if (_write_file($path, _slurp($join))
			&& chmod(0600, $path) && chown(1001, 1001, $path)) {
			push @done, 'join-token';
		}
		else {
			$error = 'could not copy the join token';
		}
		# The image is a copy of another card, so it carries that card's machine
		# identity. A board flashed as a new controller must introduce itself under
		# its own id, or two boards would overwrite each other's roster row; the
		# first boot mints one when none is here (see gou_first_boot.pl).
		foreach my $identity ("$mount/home/jawn/.jawnos_signatorial_id",
			"$mount/home/jawn/jawnos/database/.jawnos_signatorial_id") {
			unlink $identity if -f $identity;
		}
		push @done, 'identity';
	}
	# The board redeems that token, and looks for its card, before the house
	# starts. The unit is enabled by its wants symlink rather than by running
	# systemctl against the image, so nothing here needs the board booted.
	if (!length $error) {
		# The script comes from this tree, not from the image: the image is a copy
		# of another card, whose tree may predate it (or not be a tree at all),
		# and a unit that calls a missing script would fail silently on the boot
		# that matters.
		my $source = File::Basename::dirname(Cwd::abs_path($0)) . '/gou_first_boot.pl';
		my $script = -f $source ? _slurp($source) : '';
		my $dir = "$mount/home/jawn/jawnos/scripts";
		File::Path::make_path($dir) unless -d $dir;
		my $path = "$dir/gou_first_boot.pl";
		if (length $script
			&& _write_file($path, $script)
			&& chmod(0755, $path) && chown(1001, 1001, $path)) {
			push @done, 'first-boot-script';
		}
		else {
			$error = 'could not copy the first-boot script';
		}
	}
	if (!length $error) {
		my $units = "$etc/systemd/system";
		File::Path::make_path($units) unless -d $units;
		my $unit = "$units/jawnos-first-boot.service";
		my $wants = "$units/multi-user.target.wants";
		File::Path::make_path($wants) unless -d $wants;
		my $link = "$wants/jawnos-first-boot.service";
		if (_write_file($unit, _first_boot_unit())
			&& chmod(0644, $unit) && chown(0, 0, $unit)) {
			symlink('jawnos-first-boot.service', $link) unless -e $link || -l $link;
			push @done, 'first-boot';
		}
		else {
			$error = 'could not write the first-boot unit';
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

	my $image = defined $opt{'image'} && length $opt{'image'} ? $opt{'image'} : $DEFAULT_IMAGE;
	unless (-f $image) {
		_fail(4, "image not found: $image");
	}
	my $length = _uncompressed_length($image);
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
	my $write = _write_image($image, $dev, $opt{'dry_run'}, $length);
	_fail(5, $write->{'error'}) unless $write->{'ok'};

	my @done;
	if (!$opt{'no_autopopulate'} && !$opt{'dry_run'}) {
		my $populated = _autopopulate($dev, $hostname, $ssid, $psk, $join);
		_fail(5, $populated->{'error'}) unless $populated->{'ok'};
		@done = @{ $populated->{'done'} || [] };
	}

	_emit({
		ok => 1,
		device => $dev,
		image => $image,
		bytes_written => $write->{'bytes'},
		sha256_match => $write->{'sha256_match'},
		autopopulated => \@done,
		($opt{'dry_run'} ? (dry_run => 1) : ()),
		(defined $backup && length $backup ? (backup => $backup) : ()),
	}, 0);
}

# The devices _scan would show, as bare paths.
sub _candidate_devices {
	return map { $_->{'dev'} } _candidates();
}
