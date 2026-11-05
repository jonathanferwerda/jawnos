#!/usr/bin/perl
# Assemble the JawnOS Android runtime (M3, docs/roadmap-handoff.md).
#
#   perl scripts/runtime_build.pl --from /path/to/prefix [--out FILE] [--dry-run]
#   perl scripts/runtime_build.pl --from PREFIX --list      # what would ship
#
# --no-bin omits the executables and symlinks under bin/ and libexec/ - the
# entries the Android app supplies as jniLibs native libraries and links back
# into the prefix at start (scripts/runtime_native_bins.pl, M5b in
# docs/roadmap-handoff.md). Non-executable data files in those trees still ship,
# and the library each executable names is still selected, so the payload the
# app links to finds its libraries in the archive.
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
# MediaCodec) are gone from the runtime; node/tmux/zbarimg are dropped (only
# dev scripts and the QR share reach them, and the share has a bridge).
#
# qrencode is NOT dev-only: the Box Office ("Passes") mints every pass ticket
# by running `qrencode -o - URL`, so without it on the phone a pass saved a
# 22-byte `data:image/png;base64,` image and showed a blank thumbnail. It ships
# in bin/ like any other tool. The library pass below follows its DT_NEEDED,
# so libqrencode.so, libpng16.so and libz.so ship with it from /lib of the
# source prefix; libc/libm come from the device (the SYSMAP list) and are not
# packed. scripts/jawnos_deps.pl names Termux's libqrencode for a hand build.
my %TOOL = map { $_ => 1 } qw(
	perl openssl sqlite3 argon2 curl ssh sshpass rsync git zip unzip tar gzip xz zstd
	bash sh env sed awk grep egrep fgrep cut tr head tail sort uniq wc
	cat ls cp mv rm mkdir rmdir ln chmod chown touch date sleep find xargs
	basename dirname readlink stat id whoami uname hostname printf echo test [
	pgrep pkill ps kill killall nohup tee which
	sshd scp sftp ssh-keygen
	base64 timeout ip ss ping
	qrencode
);
# ffmpeg/ffprobe and their codec stack moved to the optional `video` part
# (2026-11-01). Their uses are film frames, loudness, subtitle extraction and
# Music's video stream; nothing that must run before a part is installed needs
# them, and they were most of the core archive's bytes. The `video` part keeps
# the pair and everything its DT_NEEDED chain names.
#
# ImageMagick is the `media` part and Tesseract the `ocr` part for the same
# reason: a fallback/optional tool should cost a download only when it is used.

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
	# OpenSSH 10 splits the daemon: bin/sshd only re-execs this session
	# helper, and without it every start dies with "sshd-session does not
	# exist or is not executable" - which is why no device had a listening
	# sshd after the runtime diet.
	'libexec/sshd-session',
	'libexec/sshd-auth',
	'libexec/ssh-keysign',
	'libexec/ssh-pkcs11-helper',
	'libexec/ssh-sk-helper',
	'libexec/sftp-server',
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

# --- parts ------------------------------------------------------------------
# The runtime used to be one archive. A part is an optional, independently
# installable slice of the SAME prefix: `media` (ImageMagick and the delegates
# its DT_NEEDED chain names) and `ocr` (Tesseract, leptonica and eng tessdata).
# The core keeps its existing behaviour and its existing archive name.
#
# Parts are packed against a pinned core archive (--baseline): every path the
# core already carries is excluded from the part, so a part never owns a core
# file. A part update therefore adds or replaces only its own paths.
#
# Executables stay out of a part's published archive (--no-bin, exactly as the
# core archive): Android cannot exec app-data files at targetSdk 29+, so
# scripts/runtime_native_bins.pl turns them into jniLibs and the app links them
# back into bin/ at start. `bins` names the executables a part unlocks even
# though the archive does not carry them.
my %PART = (
	core => {
		tools    => [ keys %TOOL ],
		dirs     => [ @LIB_DIRS, @SHARE_DIRS, @LIBEXEC_DIRS ],
		requires => [ 'bin/perl', 'lib/perl5/CORE/libperl.so' ],
	},
	media => {
		# magick is the only executable the Termux package ships; the rest are
		# the traditional aliases callers may still use.
		tools    => [qw(magick convert identify mogrify montage composite compare stream conjure display animate import)],
		dirs     => [ 'etc/ImageMagick-*', 'lib/ImageMagick-*', 'share/ImageMagick-*' ],
		requires => [ 'bin/magick' ],
		bins     => [ 'bin/magick', 'bin/convert' ],
		min_core => 1,
	},
	ocr => {
		tools    => [qw(tesseract)],
		dirs     => [ 'share/tessdata' ],
		requires => [ 'bin/tesseract', 'share/tessdata/eng.traineddata' ],
		bins     => [ 'bin/tesseract' ],
		min_core => 1,
	},
	video => {
		# The pair plus the whole DT_NEEDED closure the loader asks for. No data
		# directory: ffmpeg's codecs and formats are compiled in or linked, not
		# loaded from share/.
		tools    => [qw(ffmpeg ffprobe)],
		dirs     => [],
		requires => [ 'bin/ffmpeg', 'bin/ffprobe' ],
		bins     => [ 'bin/ffmpeg', 'bin/ffprobe' ],
		min_core => 1,
	},
);

# --- options ----------------------------------------------------------------
my ($from, $out, $dry, $list, $help, $abi, $rewrite, $perl_version, $no_bin);
my ($part, $baseline, $min_core, $version_override);
my @keep;
while ( defined(my $a = shift @ARGV) ) {
	if ($a eq '--from') { $from = shift @ARGV }
	elsif ($a eq '--out') { $out = shift @ARGV }
	elsif ($a eq '--abi') { $abi = shift @ARGV }
	elsif ($a eq '--part') { $part = shift @ARGV }
	elsif ($a eq '--baseline') { $baseline = shift @ARGV }
	elsif ($a eq '--min-core') { $min_core = shift @ARGV }
	elsif ($a eq '--keep') { push @keep, shift @ARGV }
	elsif ($a eq '--version') { $version_override = shift @ARGV }
	elsif ($a eq '--rewrite-prefix') { $rewrite = shift @ARGV }
	elsif ($a eq '--perl-version') { $perl_version = shift @ARGV }
	elsif ($a eq '--no-bin') { $no_bin = 1 }
	elsif ($a eq '--dry-run') { $dry = 1 }
	elsif ($a eq '--list') { $list = 1 }
	elsif ($a eq '--help' || $a eq '-h') { $help = 1 }
	else { die "runtime_build.pl: unknown option $a\n" }
}
if ($help) {
	print <<'USAGE';
perl scripts/runtime_build.pl --from PREFIX [--out FILE] [--abi ABI] [--no-bin]
    [--part core|media|ocr|video] [--baseline CORE_ZIP] [--min-core VERSION]
    [--keep PATH] [--version VERSION] [--dry-run] [--list]

  --from      the built prefix to pack (a device's $PREFIX, or a staging dir)
  --out       the archive to write (default releases/jawnrt-<abi>-<VERSION>.zip,
              or releases/jawnrt-<abi>-<part>-<VERSION>.zip for a part)
  --abi       the archive's ABI, for the manifest (default aarch64)
  --part      core (default) keeps the whole booted runtime; media packs
              ImageMagick + delegates; ocr packs Tesseract + eng tessdata;
              video packs ffmpeg/ffprobe + their codec libraries
  --baseline  a pinned core archive whose paths a part must not carry
  --min-core  the core version a part needs (default: this tree's VERSION)
  --keep      force an exact prefix path (usually an alias symlink such as
              lib/libz.so) into the archive; repeatable
  --version   the part/core version to record (default: this tree's VERSION)
  --no-bin    omit the executables and symlinks under bin/ and libexec/ that the
              app supplies as native libraries; data files in those trees stay
  --dry-run   print the plan and the size; write nothing
  --list      print every path that would ship, one per line
USAGE
	exit 0;
}
die "runtime_build.pl: --from is required\n" unless defined $from && length $from;
die "runtime_build.pl: no such prefix: $from\n" unless -d $from;
$from = abs_path($from);
$abi ||= 'aarch64';
$part ||= 'core';
die "runtime_build.pl: --part must be one of: " . join(', ', sort keys %PART) . "\n"
	unless $PART{$part};
die "runtime_build.pl: --baseline is only meaningful for a part\n"
	if defined $baseline && $part eq 'core';
if (defined $baseline) {
	die "runtime_build.pl: no such baseline archive: $baseline\n" unless -f $baseline;
	$baseline = abs_path($baseline);
}
die "runtime_build.pl: --abi looks wrong: $abi\n" unless $abi =~ m{^[A-Za-z0-9_]+$};
if (defined $rewrite) {
	my ($o, $n) = split /=/, $rewrite, 2;
	die "runtime_build.pl: --rewrite-prefix needs old=new\n" unless defined $n && length $o;
	die "runtime_build.pl: only an equal-length rewrite is safe\n" unless length $o == length $n;
	print "runtime_build: rewriting $o -> $n in every file\n";
}

my $version = 'unknown';
if (open(my $vf, '<', "$root/VERSION")) { $version = <$vf> // 'unknown'; close $vf; $version =~ s/\s+//g }
$version = $version_override if defined $version_override && length $version_override;
$min_core ||= $version;

# The x86_64 pin has no optional parts (the shipped app is arm64-only), so its
# monolithic core keeps the video pair the 0.1.1702 archive carried. On aarch64
# the pair rides in the video part.
if ($part eq 'core' && $abi eq 'x86_64') {
	push @{ $PART{'core'}{'tools'} }, 'ffmpeg', 'ffprobe';
}

my $part_spec = $PART{$part};
my $default_name = $part eq 'core'
	? "jawnrt-$abi-$version.zip"
	: "jawnrt-$abi-$part-$version.zip";
$out ||= "$root/releases/$default_name";

# A pinned core archive tells this build what it must NOT carry. Read the
# central directory with core Perl, so the check works on a device too.
my %baseline;
if (defined $baseline) {
	require IO::Uncompress::Unzip;
	my $uz = IO::Uncompress::Unzip->new($baseline)
		or die "runtime_build.pl: cannot read $baseline\n";
	for (my $s = 1; ; $s++) {
		my $h = $uz->getHeaderInfo;
		my $name = $h->{Name};
		last unless defined $name && length $name;
		$baseline{$name} = 1 unless $name =~ m{/$};
		last unless $uz->nextStream;
	}
	print "runtime_build: baseline $baseline owns " . scalar(keys %baseline) . " paths; a part will not carry them\n";
}

# --- select ----------------------------------------------------------------
my %TOOL_FOR = map { $_ => 1 } @{ $part_spec->{tools} };
my @DIRS_FOR = @{ $part_spec->{dirs} };
sub wanted_path {
	my ($rel) = @_;
	# An archive entry whose name climbs with .. (git-core writes some as
	# libexec/git-core/../../bin/X) resolves onto an entry that is already in
	# the list. Staging it a second time copied over the first one's hardlink -
	# truncating the SOURCE bin/git to 0 bytes - and the archive then shipped an
	# empty git. The alias is redundant; keep the real path only.
	return 0 if $rel =~ m{(?:^|/)\.\.(?:/|$)};
	# A prefix that has been updated in place keeps the module trees of every perl
	# it ever had; only the one bin/perl actually runs belongs in a runtime.
	if (defined $perl_version
		&& $rel =~ m{^lib/perl5/(?:[a-z_]+_perl/)?(\d+\.\d+\.\d+)(?:/|$)}
		&& $1 ne $perl_version) {
		return 0;
	}
	return 1 if $rel =~ m{^bin/[^/]+$} && $TOOL_FOR{ basename($rel) } && !$NEVER{ basename($rel) };
	foreach my $d (@DIRS_FOR) {
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
			# A part is additive over the pinned core: a path the core already
			# carries belongs to the core and is never owned twice.
			return if %baseline && $baseline{$rel};
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
	libbase.so libc++.so libutils.so libcutils.so libhardware.so libhidlbase.so
	libdl_android.so libnativebridge_lazy.so libnativeloader_lazy.so
	libvndksupport.so libziparchive.so libSurfaceFlingerProp.so libgraphicsenv.so
	libgfxgrab.so
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
			# The Vulkan loader belongs to the device. Termux's copy needs vendor
			# HIDL libraries (android.hardware.configstore@1.0.so, libgfxgrab.so)
			# that an app's linker namespace does not expose on Android 13+, so
			# ffmpeg failed to link. /system/lib64/libvulkan.so satisfies
			# libplacebo's DT_NEEDED and is found without shipping anything.
			next if $name eq 'libvulkan.so';
			# Only the prefix's own libraries: everything Android supplies (its
			# libc, its graphics and HIDL stacks) belongs to the device, and
			# shipping one would shadow it. A part must also leave the pinned
			# core's libraries alone - even when this staging prefix has a copy.
			next if %baseline && $baseline{"lib/$name"};
			if (!-f "$from/lib/$name") {
				$missing{$name} = 1
					unless $SYSTEM{$name} || $name =~ m{^(?:android\.hardware\.|libhidl)};
				next;
			}
			push @add, "lib/$name";
			push @linked, $name unless $have{"lib/$name"};
		}
	}
	foreach my $rel2 (@add) {
		next if %baseline && $baseline{$rel2};   # a core path stays the core's
		next if $have{$rel2};
		push @files, $rel2;
		$have{$rel2} = 1;
	}
}
@files = sort @files;
@linked = sort keys %{{ map { $_ => 1 } @linked }};
print "runtime_build: +" . scalar(@linked) . " linked librar" . (@linked == 1 ? 'y' : 'ies') . ": @linked\n" if @linked;

# --keep is for a path the closure cannot infer but the runtime must own: an
# unversioned alias symlink (lib/libz.so) that a part's ELF names in DT_NEEDED
# while every core ELF names the versioned libz.so.1. Keeping it in the core
# lets the part point at a core path instead of shipping a cross-part link.
foreach my $k (@keep) {
	die "runtime_build.pl: --keep $k is not in $from\n"
		unless -e "$from/$k" || -l "$from/$k";
	next if $have{$k};
	push @files, $k;
	$have{$k} = 1;
	print "runtime_build: keeping $k\n";
}
@files = sort @files;

# A library nobody in the prefix provides is a broken runtime: say which, and
# refuse. The source prefix, not this script, has to grow.
if (%missing) {
	print "runtime_build: missing libraries: " . join(' ', sort keys %missing) . "\n";
	print "  nothing in $from/lib provides those\n";
	exit 1;
}

# The two things a runtime is useless without, or the parts a part is useless
# without. This runs before --no-bin strips the executables: a part's binary is
# supplied as a jniLib rather than unpacked, but it must still be selected.
my $has_perl = grep { $_ eq 'bin/perl' } @files;
my $has_libperl = grep { m{/CORE/libperl\.so$} } @files;
if ($part eq 'core') {
	if (!$has_perl || !$has_libperl) {
		print "runtime_build: incomplete - bin/perl: " . ($has_perl ? 'yes' : 'NO')
			. ", CORE/libperl.so: " . ($has_libperl ? 'yes' : 'NO') . "\n";
		print "  expected a built prefix (see docs/roadmap-handoff.md M3b)\n";
		exit 1;
	}
}
else {
	my %have_file = map { $_ => 1 } @files;
	my @absent = grep { !$have_file{$_} } @{ $part_spec->{requires} || [] };
	if (@absent) {
		print "runtime_build: $part part is incomplete - missing: @absent\n";
		print "  expected a prefix with that package installed (see docs/runtime-parts.md)\n";
		exit 1;
	}
}

# A runtime the app installs no longer needs the executables in the archive:
# it carries them as jniLibs native libraries and links them back into bin/ and
# libexec/ on every start. When --no-bin is set, drop exactly the entries
# runtime_native_bins.pl converts - regular files with an execute bit, and
# symlinks - under those two trees. Non-executable data files stay (git keeps
# its mergetool helpers and shell libraries in libexec/git-core, and no app
# recreates them).
#
# The filter runs after the library pass on purpose: lib/ must be exactly what
# a full build carries, or an app-supplied executable would name a library the
# archive no longer has (curl's libssl, for one).
if ($no_bin) {
	my @kept;
	my $omitted = 0;
	foreach my $rel (@files) {
		if ($rel =~ m{^(?:bin|libexec)/}) {
			my $path = "$from/$rel";
			if (-l $path || ((stat($path))[2] & 0111)) {
				$omitted++;
				next;
			}
		}
		push @kept, $rel;
	}
	@files = @kept;
	print "runtime_build: --no-bin: omitting $omitted executables and links supplied by the app\n";
}

my $source_bytes = 0;
# The symlink-closure above can re-introduce alias paths written as
# libexec/git-core/../../bin/X (it resolves a link target through the prefix).
# They name files already in the list. Staging one a second time is what
# truncated the source bin/git to zero bytes through a shared hardlink, so drop
# every path that climbs before anything is written.
my $aliases = grep { m{(?:^|/)\.\.(?:/|$)} } @files;
@files = grep { !m{(?:^|/)\.\.(?:/|$)} } @files;
print STDERR "runtime_build: dropped $aliases alias path(s) that climb with ..\n" if $aliases;
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
			# A hardlink may already sit here: opening it for writing would
			# truncate the source file through the shared inode (that is how
			# bin/git shipped as 0 bytes). Remove it first, so the copy is a
			# new inode.
			unlink $dst if -e $dst || -l $dst;
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
system($^X, $zip, $stage, $out, (defined $rewrite ? $rewrite : ())) == 0 or die "runtime_build: zip failed\n";

my $size = -s $out || 0;
my $sha = sha256_hex(do { open(my $fh, '<', $out) or die $!; binmode $fh; local $/; <$fh> });

my $manifest = {
	'product'  => 'runtime',
	'abi'      => $abi,
	'version'  => $version,
	'part'     => $part,
	'built'    => time,
	'rewritten_from' => (defined $rewrite ? (split /=/, $rewrite, 2)[0] : undef),
	'filename' => basename($out),
	'sha256'   => $sha,
	'size'     => $size,
	'files'    => $total,
};
if ($part ne 'core') {
	# The exact prefix paths this archive unpacks. A part update/rollback is
	# defined by this list: replace these paths, delete a stale path only when
	# the new archive no longer carries it, and never touch a core path.
	$manifest->{'provides'} = [ map { "usr/$_" } @files ];
	$manifest->{'bins'}     = $part_spec->{bins} || [];
	$manifest->{'min_core'} = $min_core;
	$manifest->{'optional'} = JSON::PP::true;
	$manifest->{'baseline'} = defined $baseline ? basename($baseline) : undef;
}
my $mfile = "$out.json";
open(my $mf, '>', $mfile) or die $!;
print {$mf} JSON::PP->new->canonical->encode($manifest), "\n";
close $mf;

printf "runtime_build: wrote %s (%.1f MB, %d files, sha256 %s)\n",
	$out, $size / (1024 * 1024), $total, substr($sha, 0, 16) . '...';
print "  manifest: $mfile\n";
