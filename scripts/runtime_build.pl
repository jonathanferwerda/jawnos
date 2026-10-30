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
);

# Never ship, even if the source has it: the package manager and its state.
my %NEVER = map { $_ => 1 } qw(
	pkg apt apt-get dpkg cpanm cpan perldoc pod2man pod2text corelist
	man mandoc less more vi vim nano emacs
);

# Directory trees outside bin/ that ship. Anything not named here is left out,
# which is the point: a prefix carries a lot of history.
my @LIB_DIRS = (
	'lib/perl5',          # core, site and vendor modules (+ CORE/libperl.so)
	'lib/libcrypto*',     # OpenSSL, for CryptX / Net::SSLeay
	'lib/libssl*',
	'lib/libsqlite3*',    # DBD::SQLite
	'lib/libz.*', 'lib/libz.so*',
	'lib/libffi*',
	'lib/libncursesw*',
	'lib/libpanelw*',
	'lib/libreadline*',
	'lib/libc++_shared*',
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
my ($from, $out, $dry, $list, $help);
while ( defined(my $a = shift @ARGV) ) {
	if ($a eq '--from') { $from = shift @ARGV }
	elsif ($a eq '--out') { $out = shift @ARGV }
	elsif ($a eq '--dry-run') { $dry = 1 }
	elsif ($a eq '--list') { $list = 1 }
	elsif ($a eq '--help' || $a eq '-h') { $help = 1 }
	else { die "runtime_build.pl: unknown option $a\n" }
}
if ($help) {
	print <<'USAGE';
perl scripts/runtime_build.pl --from PREFIX [--out FILE] [--dry-run] [--list]

  --from     the built prefix to pack (a device's $PREFIX, or a staging dir)
  --out      the archive to write (default releases/jawnrt-aarch64-<VERSION>.zip)
  --dry-run  print the plan and the size; write nothing
  --list     print every path that would ship, one per line
USAGE
	exit 0;
}
die "runtime_build.pl: --from is required\n" unless defined $from && length $from;
die "runtime_build.pl: no such prefix: $from\n" unless -d $from;
$from = abs_path($from);

my $version = 'unknown';
if (open(my $vf, '<', "$root/VERSION")) { $version = <$vf> // 'unknown'; close $vf; $version =~ s/\s+//g }
$out ||= "$root/releases/jawnrt-aarch64-$version.zip";

# --- select ----------------------------------------------------------------
sub wanted_path {
	my ($rel) = @_;
	return 1 if $rel =~ m{^bin/[^/]+$} && $TOOL{ basename($rel) } && !$NEVER{ basename($rel) };
	# Every shared object that sits directly in lib/: an interpreter or a tool
	# links against whatever its build needed (Termux's perl needs
	# libandroid-utimes.so, which no name list would have guessed), and these
	# are a few MB against a 90 MB payload. The directories beside them
	# (python3.x, clang, perl5) are still decided by @LIB_DIRS.
	if ($rel =~ m{^lib/[^/]+\.so(?:\.[0-9]+)*$}) {
		# ... but not a compiler toolchain someone installed beside it. Those
		# are the biggest files in a prefix (libLLVM alone is over 100 MB) and
		# nothing jawn runs links against them.
		return 0 if $rel =~ m{^lib/(?:libLLVM|libclang|libpython|libnode|libtcc|libgcc)_?};
		return 1;
	}
	foreach my $d (@LIB_DIRS, @SHARE_DIRS) {
		my $re = $d;
		$re =~ s{([.\[\](){}*+?^$|\\])}{\\$1}g;
		$re =~ s/\\\*/.*/g;
		return 1 if $rel =~ m{^$re(?:/|$)};
	}
	return 0;
}

my @files;
my $source_bytes = 0;
for my $top (qw(bin lib share etc)) {
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
			$source_bytes += -l $path ? 0 : (-s $path || 0);
		},
	}, $dir);
}
# A tool in bin/ is often a symlink to a shared multi-call binary (busybox,
# coreutils, gawk), and the diet's name list never mentions that binary: the
# archive then unpacks into dangling symlinks and `sh` or `awk` cannot run.
# Pull in whatever a selected symlink points at, inside the prefix, until
# nothing new appears. A target the diet forbids stays out (the symlink is
# reported below instead).
my %have = map { $_ => 1 } @files;
my @pruned = ();
my $grew = 1;
while ($grew) {
	$grew = 0;
	foreach my $rel (@files) {
		next unless -l "$from/$rel";
		my $target = readlink "$from/$rel";
		next unless defined $target && length $target;
		next if $target =~ m{^/};            # outside the prefix
		my $abs = File::Spec->rel2abs($target, dirname("$from/$rel"));
		my $trel = $abs;
		$trel =~ s{^\Q$from\E/}{};
		next if $trel eq $abs;               # resolved outside $from
		next if $have{$trel};
		next if $NEVER{ basename($trel) };
		push @files, $trel;
		$have{$trel} = 1;
		$grew = 1;
	}
}
@files = sort @files;

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
	'abi'      => 'aarch64',
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
