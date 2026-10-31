#!/usr/bin/perl
# Assemble the JawnOS Android runtime (M3, docs/leaving-termux.md).
#
#   perl scripts/runtime_build.pl --from /path/to/prefix [--out FILE] [--dry-run]
#   perl scripts/runtime_build.pl --from PREFIX --list      # what would ship
#
# The runtime is what a clean install unpacks into $PREFIX before jawn starts:
# one Perl, the modules the tree loads, and only the tools M3 chose to keep.
# It is deliberately NOT the Termux bootstrap: no pkg, no apt/dpkg, no repo
# metadata, no package manager at all, and no man pages or pods. The app unpacks
# this archive once, on first run, and never installs anything again.
#
# The source prefix is a built tree (on a device: `--from $PREFIX`; on a desktop
# build box: a staging directory). Nothing here downloads or compiles; that is
# M3b. This script is the diet and the manifest.
#
# Exit status: 0 on success. --dry-run prints the plan and touches nothing.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Temp qw(tempdir);
use File::Find ();
use File::Path qw(make_path remove_tree);
use File::Basename qw(basename dirname);
use File::Spec ();
use JSON::PP;
use Digest::SHA qw(sha256_hex);

my $root = abs_path("$FindBin::Bin/..");

# --- the diet ---------------------------------------------------------------
# M3's decision table, executable. "Keep bundled" is here; the replacements
# (espeak→TextToSpeech, tesseract→ML Kit, convert→BitmapFactory, ffmpeg→
# MediaCodec) are gone from the runtime; node/tmux/qrencode/zbarimg are dropped
# (only dev scripts and the QR share reach them, and the share has a bridge).
my %TOOL = map { $_ => 1 } qw(
	perl openssl sqlite3 argon2 curl ssh sshpass rsync git zip unzip tar gzip xz zstd
	bash sh env sed awk grep egrep fgrep cut tr head tail sort uniq wc
	cat ls cp mv rm mkdir rmdir ln chmod chown touch date sleep find xargs
	basename dirname readlink stat id whoami uname hostname printf echo test [
	pgrep pkill ps kill killall nohup tee which
	sshd scp sftp ssh-keygen
	base64 timeout ip ss ping
	ffmpeg ffprobe magick convert
);
# ffmpeg and ImageMagick stay on purpose (2026-10-30). The plan was MediaCodec
# and BitmapFactory, but those cover a codec call, not the 51 places the tree
# pipes a film through `ffmpeg -i ... -vframes 1 | magick - -resize` for a
# thumbnail, or the loudness pass, or subtitle extraction, or Music's video
# stream. Dropping them today would not be a diet, it would be a regression;
# when a native path exists for a call site, that call site moves and the
# binary follows it out.

# Never ship, even if the source has it: the package manager and its state.
my %NEVER = map { $_ => 1 } qw(
	pkg apt apt-get dpkg cpanm cpan perldoc pod2man pod2text corelist
	man mandoc less more vi vim nano emacs
);

# Directory trees outside bin/ that ship. Anything not named here is left out,
# which is the point: a prefix carries a lot of history.
# Libraries are not decided here: whichever file in the selection names a
# library in its DT_NEEDED gets it (see elf_needed below), transitively. That is
# what shipped libandroid-utimes.so when no name list had heard of it.
my @LIB_DIRS = (
	'lib/perl5',          # core, site and vendor modules (+ CORE/libperl.so)
);
# git runs its subcommands and its https helper out of libexec/git-core (all
# symlinks to bin/git, plus the one real git-remote-http).
my @LIBEXEC_DIRS = (
	'libexec/git-core',
);
my @SHARE_DIRS = (
	'share/terminfo',     # TERM=xterm-256color resolves here
	'share/misc/terminfo',
	'etc/tls',            # CA bundle for Net::SSLeay / IO::Socket::SSL
	'etc/openssl',
	'etc/ssh',            # sshd_config, moduli (keys are generated, not shipped)
);
# Perl's own manual pages are most of a core install and no device reads them.
my @PRUNE = (
	qr{/pod/}, qr{/man/}, qr{\.pod$}, qr{\.man$}, qr{\.html$},
	qr{/CORE/.*\.h$}, qr{/CORE/.*\.o$}, qr{/CORE/.*\.a$},
	qr{/perllocal\.pod$}, qr{/\.packlist$}, qr{/\.meta/}, qr{/\.git/},
);

# --- options ----------------------------------------------------------------
my ($from, $out, $dry, $list, $help, $abi);
while ( defined(my $a = shift @ARGV) ) {
	if ($a eq '--from') { $from = shift @ARGV }
	elsif ($a eq '--out') { $out = shift @ARGV }
	elsif ($a eq '--abi') { $abi = shift @ARGV }
	elsif ($a eq '--dry-run') { $dry = 1 }
	elsif ($a eq '--list') { $list = 1 }
	elsif ($a eq '--help' || $a eq '-h') { $help = 1 }
	else { die "runtime_build.pl: unknown option $a\n" }
}
if ($help) {
	print <<'USAGE';
perl scripts/runtime_build.pl --from PREFIX [--out FILE] [--abi ABI] [--dry-run] [--list]

  --from     the built prefix to pack (a device's $PREFIX, or a staging dir)
  --out      the archive to write (default releases/jawnrt-<abi>-<VERSION>.zip)
  --abi      the archive's ABI, for the manifest (default aarch64)
  --dry-run  print the plan and the size; write nothing
  --list     print every path that would ship, one per line
USAGE
	exit 0;
}
die "runtime_build.pl: --from is required\n" unless defined $from && length $from;
die "runtime_build.pl: no such prefix: $from\n" unless -d $from;
$from = abs_path($from);
$abi ||= 'aarch64';
die "runtime_build.pl: --abi looks wrong: $abi\n" unless $abi =~ m{^[A-Za-z0-9_]+$};

my $version = 'unknown';
if (open(my $vf, '<', "$root/VERSION")) { $version = <$vf> // 'unknown'; close $vf; $version =~ s/\s+//g }
$out ||= "$root/releases/jawnrt-$abi-$version.zip";

# --- select ----------------------------------------------------------------
sub wanted_path {
	my ($rel) = @_;
	return 1 if $rel =~ m{^bin/[^/]+$} && $TOOL{ basename($rel) } && !$NEVER{ basename($rel) };
	foreach my $d (@LIB_DIRS, @SHARE_DIRS, @LIBEXEC_DIRS) {
		my $re = $d;
		$re =~ s{([.\[\](){}*+?^$|\\])}{\\$1}g;
		$re =~ s/\\\*/.*/g;
		return 1 if $rel =~ m{^$re(?:/|$)};
	}
	return 0;
}

my @files;
for my $top (qw(bin lib libexec share etc)) {
	my $dir = "$from/$top";
	next unless -d $dir;
	File::Find::find({
		no_chdir => 1,
		wanted   => sub {
			my $path = $File::Find::name;
			return unless -f $path || -l $path;
			my $rel = $path;
			$rel =~ s{^\Q$from\E/}{};
			return unless wanted_path($rel);
			return if !-l $path && grep { $rel =~ $_ } @PRUNE;
			push @files, $rel;
		},
	}, $dir);
}
# --- what an ELF file asks the loader for -----------------------------------
# A runtime has to carry the libraries its own tools and modules link against.
# A name list cannot know them: the shipped perl needed libandroid-utimes.so,
# which nothing in the diet had ever mentioned, so `perl` refused to start after
# an unpack that looked perfect. Read DT_NEEDED straight out of the ELF header
# instead: it works on a device (where there is no readelf) and on the desktop
# alike, and it is the only list that cannot go stale.
sub elf_needed {
	my ($path) = @_;
	open(my $fh, '<', $path) or return ();
	binmode $fh;
	my $hdr = '';
	return () unless read($fh, $hdr, 64) == 64;
	return () unless substr($hdr, 0, 4) eq "\x7fELF";
	my $class = ord(substr($hdr, 4, 1));   # 1 = 32-bit, 2 = 64-bit
	my $data  = ord(substr($hdr, 5, 1));   # 1 = little endian (all of Android, both ABIs)
	return () unless $data == 1 && ($class == 1 || $class == 2);
	my $u32 = sub { unpack('V', $_[0]) };
	my $u64 = sub { unpack('Q<', $_[0]) };
	my $shoff = $class == 2 ? $u64->(substr($hdr, 0x28, 8)) : $u32->(substr($hdr, 0x20, 4));
	my $shentsize = unpack('v', substr($hdr, $class == 2 ? 0x3A : 0x2E, 2));
	my $shnum = unpack('v', substr($hdr, $class == 2 ? 0x3C : 0x30, 2));
	return () unless $shoff && $shnum && $shentsize >= ($class == 2 ? 64 : 40);
	seek($fh, $shoff, 0) or return ();
	my @sh;
	for (1 .. $shnum) {
		my $s = '';
		last unless read($fh, $s, $shentsize) == $shentsize;
		push @sh, {
			type   => $u32->(substr($s, 4, 4)),
			offset => $class == 2 ? $u64->(substr($s, 0x18, 8)) : $u32->(substr($s, 0x10, 4)),
			size   => $class == 2 ? $u64->(substr($s, 0x20, 8)) : $u32->(substr($s, 0x14, 4)),
			link   => $u32->($class == 2 ? substr($s, 0x28, 4) : substr($s, 0x18, 4)),
		};
	}
	my ($dyn) = grep { $_->{type} == 6 } @sh;   # SHT_DYNAMIC
	return () unless $dyn && $dyn->{link} < @sh && $dyn->{size} && $dyn->{size} < (1 << 20);
	my $str = $sh[$dyn->{link}];
	return () unless $str->{size} && $str->{size} < (1 << 24);
	my ($blob, $strblob) = ('', '');
	seek($fh, $dyn->{offset}, 0) or return ();
	read($fh, $blob, $dyn->{size}) or return ();
	seek($fh, $str->{offset}, 0) or return ();
	read($fh, $strblob, $str->{size}) or return ();
	my $entsize = $class == 2 ? 16 : 8;
	my @need;
	for (my $o = 0; $o + $entsize <= length($blob); $o += $entsize) {
		my $tag = $class == 2 ? unpack('q<', substr($blob, $o, 8)) : unpack('l<', substr($blob, $o, 4));
		last if $tag == 0;                       # DT_NULL
		next unless $tag == 1;                   # DT_NEEDED
		my $val = $class == 2 ? $u64->(substr($blob, $o + 8, 8)) : $u32->(substr($blob, $o + 4, 4));
		my $name = substr($strblob, $val);
		$name =~ s/\0.*//s;
		push @need, $name if length $name;
	}
	close $fh;
	return @need;
}

# A tool in bin/ is often a symlink to a shared multi-call binary (busybox,
# coreutils, gawk), and the diet's name list never mentions that binary: the
# archive then unpacks into dangling symlinks and `sh` or `awk` cannot run.
# Likewise every binary and module names the libraries it loads. Pull in what
# the selection points at, inside the prefix, until nothing new appears. A
# target the diet forbids stays out (the symlink is reported below instead).
my %have = map { $_ => 1 } @files;
my @pruned = ();
my @linked = ();
# Android supplies these; everything else a shipped ELF names has to be in the
# archive, or the tool dies on the device with "library not found".
my %SYSTEM = map { $_ => 1 } qw(
	libc.so libm.so libdl.so liblog.so libandroid.so libstdc++.so
	libz.so libEGL.so libGLESv1_CM.so libGLESv2.so libvulkan.so
	libOpenSLES.so libmediandk.so libnativewindow.so libsync.so libui.so
);
my %missing = ();
for (my $i = 0; $i < @files; $i++) {
	my $rel = $files[$i];
	my $path = "$from/$rel";
	my @add;
	if (-l $path) {
		my $target = readlink $path;
		if (defined $target && length $target && $target !~ m{^/}) {
			my $abs = File::Spec->rel2abs($target, dirname($path));
			my $trel = $abs;
			$trel =~ s{^\Q$from\E/}{};
			@add = ($trel) if $trel ne $abs && !$NEVER{ basename($trel) };
		}
	}
	else {
		my @need = elf_needed($path);
		foreach my $name (@need) {
			next unless $name =~ m{\.so(?:\.\d+)*$};
			# Only the prefix's own libraries: libc, libm, libdl and liblog
			# belong to Android, and shipping one would shadow the device's.
			if (!-f "$from/lib/$name") {
				$missing{$name} = 1 unless $SYSTEM{$name};
				next;
			}
			push @add, "lib/$name";
			push @linked, $name unless $have{"lib/$name"};
		}
	}
	foreach my $rel2 (@add) {
		next if $have{$rel2};
		push @files, $rel2;
		$have{$rel2} = 1;
	}
}
@files = sort @files;
@linked = sort keys %{{ map { $_ => 1 } @linked }};
print "runtime_build: +" . scalar(@linked) . " linked librar" . (@linked == 1 ? 'y' : 'ies') . ": @linked\n" if @linked;

# A library nobody in the prefix provides is a broken runtime: say which, and
# refuse. The source prefix, not this script, has to grow.
if (%missing) {
	print "runtime_build: missing libraries: " . join(' ', sort keys %missing) . "\n";
	print "  nothing in $from/lib provides those\n";
	exit 1;
}

my $source_bytes = 0;
$source_bytes += -l "$from/$_" ? 0 : (-s "$from/$_" || 0) foreach @files;

if ($list) { print "$_\n" foreach @files; exit 0 }

# A symlink whose target is still missing would unpack broken; say so rather
# than ship it silently.
foreach my $rel (@files) {
	next unless -l "$from/$rel";
	my $target = readlink "$from/$rel";
	next unless defined $target && length $target;
	my $abs = File::Spec->rel2abs($target, dirname("$from/$rel"));
	my $trel = $abs;
	$trel =~ s{^\Q$from\E/}{};
	push @pruned, $rel if $trel eq $abs || !$have{$trel};
}
print "runtime_build: warning: " . scalar(@pruned) . " symlink(s) point outside the runtime: @pruned\n" if @pruned;

my $total = scalar @files;
my $mb = sprintf '%.1f', $source_bytes / (1024 * 1024);
if (!@files) {
	print "runtime_build: nothing selected from $from (is that a prefix?)\n";
	exit 1;
}

# The two things a runtime is useless without.
my $has_perl = grep { $_ eq 'bin/perl' } @files;
my $has_libperl = grep { m{/CORE/libperl\.so$} } @files;
if (!$has_perl || !$has_libperl) {
	print "runtime_build: incomplete - bin/perl: " . ($has_perl ? 'yes' : 'NO')
		. ", CORE/libperl.so: " . ($has_libperl ? 'yes' : 'NO') . "\n";
	print "  expected a built prefix (see docs/leaving-termux.md M3b)\n";
	exit 1;
}

printf "runtime_build: %d files, %s MB uncompressed, from %s\n", $total, $mb, $from;

if ($dry) {
	my %by;
	foreach my $f (@files) {
		my ($top) = split m{/}, $f;
		$by{$top}++;
	}
	print "  $_: $by{$_}\n" foreach sort keys %by;
	print "  would write $out\n";
	exit 0;
}

# --- pack ------------------------------------------------------------------
# A zip, not a tar: the app unpacks it with ZipInputStream, so there is no tar
# binary to depend on and no decompressor to ship. Modes survive as the zip's
# external attributes.
my $tmp = tempdir(CLEANUP => 1);
make_path(dirname($out)) unless -d dirname($out);
my $stage = "$tmp/stage";
make_path($stage);

foreach my $rel (@files) {
	my $src = "$from/$rel";
	my $dst = "$stage/$rel";
	make_path(dirname($dst));
	if (-l $src) {
		my $target = readlink $src;
		symlink($target, $dst) or die "symlink $rel: $!";
	}
	else {
		# hard link where possible: the stage is temporary and the source is read-only
		link($src, $dst) or do {
			open(my $in, '<', $src) or die "$rel: $!";
			binmode $in;
			open(my $out, '>', $dst) or die "$dst: $!";
			binmode $out;
			my $buf;
			while (read($in, $buf, 1 << 20)) { print {$out} $buf }
			close $out;
			close $in;
			# A hard link shares the source's inode (and so its mode), but a
			# copy is created with the umask's - and Android's run-as umask is
			# 000, which made every tool in the archive 0666: the unpacked perl
			# was not executable. Give the copy the source's mode back.
			chmod((stat($src))[2] & 07777, $dst);
		};
	}
}

my $zip = "$root/scripts/runtime_zip.pl";
system($^X, $zip, $stage, $out) == 0 or die "runtime_build: zip failed\n";

my $size = -s $out || 0;
my $sha = sha256_hex(do { open(my $fh, '<', $out) or die $!; binmode $fh; local $/; <$fh> });

my $manifest = {
	'product'  => 'runtime',
	'abi'      => $abi,
	'version'  => $version,
	'built'    => time,
	'filename' => basename($out),
	'sha256'   => $sha,
	'size'     => $size,
	'files'    => $total,
};
my $mfile = "$out.json";
open(my $mf, '>', $mfile) or die $!;
print {$mf} JSON::PP->new->canonical->encode($manifest), "\n";
close $mf;

printf "runtime_build: wrote %s (%.1f MB, %d files, sha256 %s)\n",
	$out, $size / (1024 * 1024), $total, substr($sha, 0, 16) . '...';
print "  manifest: $mfile\n";
