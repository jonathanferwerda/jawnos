#!/usr/bin/perl
# Build engine/, the native audio engine, and stage it as perl/audio/jawn-audio.
#
# The engine is optional, exactly like perl/sco/sco_helper: a machine with no
# Rust toolchain simply has no engine, and every caller falls back to the
# browser's WebAudio path (docs/studio-audio-roadmap.md). The source is tracked;
# the staged binary is not.
#
#   perl scripts/build_engine.pl                  # device backends if possible
#   perl scripts/build_engine.pl --features alsa  # exactly these features
#   perl scripts/build_engine.pl --check          # report whether it is staged
#   perl scripts/build_engine.pl --if-stale      # build only when engine/ is newer
#   perl scripts/build_engine.pl --debug         # build without --release
#   perl scripts/build_engine.pl --android [--ndk PATH] [--out-dir DIR]
#                                                # cross-compile libjawn_audio.so
#                                                # for arm64-v8a (API 26)
#
# --if-stale is what a pull and a supervisor start call: the staged binary is a
# build artifact, and a tree that moved must not boot the previous engine. It
# answers `fresh:` (exit 0) when the binary is at least as new as every file
# that affects the binary (Cargo.toml, Cargo.lock and engine/src), and otherwise
# builds exactly as a normal run does. tests do not affect the binary and are
# not compared.
#
# The default feature set is `alsa,jack`. A build that cannot find the headers
# or library for one of them is not fatal: the script retries with no features,
# and says plainly that the staged binary has no device backend. That keeps a
# machine without libjack or ALSA development files on the null device rather
# than without an engine. Only those two hardware backends may be dropped: a
# requested `sherpa` build that cannot link fails loudly (docs/engine-asr.md).
#
# `sherpa` also stages `perl/audio/jawn-asr` and the shared libraries it loads,
# with an `$ORIGIN` rpath so the pair moves together.
#
# $ENV{CARGO} names the toolchain (default `cargo` on PATH), and
# $ENV{CARGO_TARGET_DIR} is honoured so a test can build into a scratch folder.
#
# Windows is not a target: the house hears sound through the browser there
# (docs/platform-roadmap.md), so a Windows run says so once and stages nothing.
use strict;
use warnings;

use File::Basename ();
use File::Copy qw(copy);
use File::Find ();
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempfile);
use FindBin;

my $root     = File::Spec->rel2abs("$FindBin::Bin/..");
my $manifest = "$root/engine/Cargo.toml";
my $out      = "$root/perl/audio/jawn-audio";
my $check    = grep { $_ eq '--check' } @ARGV;
my $if_stale = grep { $_ eq '--if-stale' } @ARGV;
my $debug    = grep { $_ eq '--debug' } @ARGV;
my $android  = grep { $_ eq '--android' } @ARGV;

my ( $ndk_arg, $out_dir_arg );
for ( my $i = 0; $i < @ARGV; $i++ ) {
	if ( $ARGV[$i] eq '--ndk' ) {
		die "--ndk wants a path to an Android NDK\n" unless defined $ARGV[ $i + 1 ];
		$ndk_arg = $ARGV[ ++$i ];
	}
	elsif ( $ARGV[$i] eq '--out-dir' ) {
		die "--out-dir wants a path, e.g. app/src/main/jniLibs\n"
			unless defined $ARGV[ $i + 1 ];
		$out_dir_arg = $ARGV[ ++$i ];
	}
}

# `--features LIST` overrides the default; an empty list asks for no features.
my $features;
for ( my $i = 0; $i < @ARGV; $i++ ) {
	if ( $ARGV[$i] eq '--features' ) {
		die "--features wants a list, e.g. --features alsa,jack\n"
			unless defined $ARGV[ $i + 1 ];
		$features = $ARGV[ ++$i ];
	}
}
my $build_features = defined $features ? $features : 'alsa,jack';

# The feature list is kept apart so a retry can drop only `alsa` or `jack`.
# `sherpa` is never dropped: build.rs links the C libraries from
# SHERPA_ONNX_LIB_DIR, and a link failure must be loud (docs/engine-asr.md).
my @build_feature_list = grep { length } split /\s*,\s*/, $build_features;
my $sherpa_requested = scalar grep { $_ eq 'sherpa' } @build_feature_list;
my $sherpa_lib_dir;

# Windows has no engine: the sound there is the browser's. Say so once instead
# of failing inside cargo, and keep --check honest - a machine that cannot
# stage the binary reports it missing. --android still cross-compiles, since
# that is the phone's library, not this machine's engine.
if ( $^O eq 'MSWin32' && !$android ) {
	if ($check) {
		print "missing: the audio engine is not built on Windows\n";
		exit 1;
	}
	print "skip: the audio engine is not built on Windows; the browser plays the sound\n";
	exit 0;
}

if ($check) {
	if ( -x $out ) {
		print "built: $out\n";
		exit 0;
	}
	print "missing: $out\n";
	exit 1;
}

# The newest file that can change the staged binary. A missing source tree is 0,
# which makes --if-stale build (and then fail honestly) rather than call a
# binary that has no source fresh.
sub newest_source_mtime {
	my $newest = 0;
	my @roots = grep { -e $_ }
		( "$root/engine/Cargo.toml", "$root/engine/Cargo.lock",
		  "$root/engine/build.rs", "$root/engine/src" );
	foreach my $path (@roots) {
		if ( -d $path ) {
			File::Find::find(
				{
					no_chdir => 1,
					wanted   => sub {
						return unless -f $_;
						my $mtime = ( stat($_) )[9];
						$newest = $mtime if defined $mtime && $mtime > $newest;
					},
				},
				$path
			);
		}
		else {
			my $mtime = ( stat($path) )[9];
			$newest = $mtime if defined $mtime && $mtime > $newest;
		}
	}
	return $newest;
}

if ($if_stale) {
	my $source = newest_source_mtime();
	if ( -x $out ) {
		my $staged = ( stat($out) )[9] || 0;
		if ( !$source || $staged >= $source ) {
			print "fresh: $out\n";
			exit 0;
		}
	}
}

die "no $manifest\n" unless -e $manifest;

my $cargo = ( defined $ENV{'CARGO'} && length $ENV{'CARGO'} ) ? $ENV{'CARGO'} : 'cargo';

# A desktop launch (an .desktop entry or the app) never sources a shell, so
# ~/.cargo/bin is often not on PATH. The same tree that finds the engine's
# source should find the toolchain the person installed for it.
if ( $cargo eq 'cargo' ) {
	my $on_path = grep { -x File::Spec->catfile( $_, 'cargo' ) } File::Spec->path;
	my $local   = ( defined $ENV{'HOME'} && length $ENV{'HOME'} )
		? "$ENV{'HOME'}/.cargo/bin/cargo" : '';
	$cargo = $local if !$on_path && length $local && -x $local;
}

# Probe the toolchain before building. A machine without Rust is the ordinary
# case, not an error in the house: say so in a sentence rather than letting the
# shell report a missing command in the middle of a build.
my $banner = '';
{
	my $pid = open( my $probe, '-|', $cargo, '--version' );
	die "no cargo ($cargo): the engine is optional, and everything falls back to the browser\n"
		unless $pid;
	$banner = <$probe> // '';
	close $probe;
	die "no cargo ($cargo): the engine is optional, and everything falls back to the browser\n"
		unless $? == 0;
}
chomp $banner;
print "$banner\n";

# --- the Android library -----------------------------------------------------
# The app loads `libjawn_audio.so`; the house machines keep `jawn-audio`. The
# NDK's clang is the linker and the C++ compiler oboe-sys needs, so the script
# drives it directly through the environment instead of requiring cargo-ndk
# (docs/studio-oboe-slice.md §2.7, §4).
if ($android) {
	my $ndk = resolve_ndk($ndk_arg);
	if ( !defined $ndk || !-d $ndk ) {
		die "no Android NDK"
			. ( defined $ndk ? " at $ndk" : '' )
			. ": pass --ndk PATH or set ANDROID_NDK_HOME; the engine is optional\n";
	}
	my $host_bin = ndk_host_bin($ndk);
	my $api      = 26;    # the app's minSdk (docs/studio-oboe-slice.md §2.7)
	my $clang    = File::Spec->catfile( $host_bin, "aarch64-linux-android$api-clang" );
	my $clangxx  = File::Spec->catfile( $host_bin, "aarch64-linux-android$api-clang++" );
	my $ar       = File::Spec->catfile( $host_bin, 'llvm-ar' );
	for my $tool ( $clang, $clangxx, $ar ) {
		die "the NDK at $ndk has no $tool; the engine is optional\n" unless -x $tool;
	}

	my $out_dir = $out_dir_arg;
	if ( !defined $out_dir ) {
		$out_dir = File::Spec->catdir( $root, 'app', 'src', 'main', 'jniLibs' );
		die "no --out-dir, and $out_dir does not exist: pass --out-dir DIR\n"
			unless -d $out_dir;
	}

	# The recogniser joins the app only when the shared libraries it links are
	# already staged: SHERPA_ONNX_LIB_DIR must name the Android aarch64 `lib/`
	# directory, not the host's. No directory means plain oboe, not a failure
	# (docs/engine-asr.md).
	my $android_features = 'oboe';
	my $android_sherpa_dir;
	if ( sherpa_libs_present( $ENV{'SHERPA_ONNX_LIB_DIR'} ) ) {
		$android_sherpa_dir = $ENV{'SHERPA_ONNX_LIB_DIR'};
		$android_features .= ',sherpa';
	}

	local $ENV{'ANDROID_NDK_HOME'} = $ndk;
	local $ENV{'CC_aarch64-linux-android'}   = $clang;
	local $ENV{'CXX_aarch64-linux-android'}  = $clangxx;
	local $ENV{'AR_aarch64-linux-android'}   = $ar;
	local $ENV{'CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER'} = $clang;

	# The cdylib statically links Oboe's C++ but leaves the runtime symbols to
	# the loader. Name libc++_shared in its own link so those symbols come from
	# its dependency graph; System.loadLibrary does not put the STL in the
	# global scope, and a preload cannot promote an already-loaded library.
	my $android_rustflags = ( defined $ENV{'CARGO_ENCODED_RUSTFLAGS'} && length $ENV{'CARGO_ENCODED_RUSTFLAGS'} )
		? $ENV{'CARGO_ENCODED_RUSTFLAGS'} : '';
	local $ENV{'CARGO_ENCODED_RUSTFLAGS'} = join("\x1f",
		( length $android_rustflags ? $android_rustflags : () ),
		'-C', 'link-arg=-Wl,--no-as-needed',
		'-C', 'link-arg=-lc++_shared');

	my $target = ( defined $ENV{'CARGO_TARGET_DIR'} && length $ENV{'CARGO_TARGET_DIR'} )
		? $ENV{'CARGO_TARGET_DIR'}
		: File::Spec->catdir( $root, 'engine', 'target' );
	my $profile = $debug ? 'debug' : 'release';

	my @cmd = (
		$cargo, 'build', '--manifest-path', $manifest, '--lib', '--target',
		'aarch64-linux-android', '--features', $android_features, '-j', '4'
	);
	push @cmd, '--release' unless $debug;
	print "+ @cmd\n";
	die "cargo build (Android) failed\n" unless system(@cmd) == 0;

	my $library = File::Spec->catfile(
		$target, 'aarch64-linux-android', $profile, 'libjawn_audio.so'
	);
	die "cargo reported success but $library is missing\n" unless -f $library;

	my $abi_dir = File::Spec->catdir( $out_dir, 'arm64-v8a' );
	make_path($abi_dir);
	my $staged = File::Spec->catfile( $abi_dir, 'libjawn_audio.so' );
	my ( $tmp_fh, $tmp ) = tempfile( 'libjawn_audio.XXXXXX', DIR => $abi_dir, UNLINK => 0 );
	close $tmp_fh;
	if ( !copy( $library, $tmp ) || !chmod( 0644, $tmp ) || !rename( $tmp, $staged ) ) {
		my $err = $!;
		unlink $tmp if -e $tmp;
		die "cannot stage $staged: $err\n";
	}
	print "built: $staged\n";

	# The app's loader resolves DT_NEEDED by soname from the same native
	# library directory, so the sherpa `.so`s sit beside libjawn_audio.so.
	if ( defined $android_sherpa_dir ) {
		for my $lib ( sherpa_libs($android_sherpa_dir) ) {
			stage_file( File::Spec->catfile( $android_sherpa_dir, $lib ),
				File::Spec->catfile( $abi_dir, $lib ), 0644 );
		}
		print "staged: sherpa-onnx shared libraries beside libjawn_audio.so\n";
	}
	exit 0;
}

my $target = ( defined $ENV{'CARGO_TARGET_DIR'} && length $ENV{'CARGO_TARGET_DIR'} )
	? $ENV{'CARGO_TARGET_DIR'}
	: File::Spec->catdir( $root, 'engine', 'target' );
my $profile = $debug ? 'debug' : 'release';

# A requested sherpa build is resolved before cargo runs: a missing variable
# or library dies here in one line, and the recogniser's siblings are found
# through the `$ORIGIN` rpath when it runs from perl/audio (docs/engine-asr.md).
if ($sherpa_requested) {
	$sherpa_lib_dir = resolve_sherpa_lib_dir();
	add_rustflag( '-C', 'link-arg=-Wl,-rpath,$ORIGIN' );
}

my @base = ( $cargo, 'build', '--manifest-path', $manifest );
push @base, '--release' unless $debug;

# A machine with libasound but no libjack is the normal case (the house's
# audio interfaces do not need JACK at all), so drop the two hardware
# backends one at a time before giving up: ALSA alone still records, monitors
# and plays. Everything else the person asked for stays in every attempt; a
# requested `sherpa` that cannot link is a loud failure, not a smaller engine
# (docs/engine-asr.md).
my $has_alsa = grep { $_ eq 'alsa' } @build_feature_list;
my @keep = grep { $_ ne 'alsa' && $_ ne 'jack' } @build_feature_list;
my @attempts = ( join( ',', @build_feature_list ) );
push @attempts, join( ',', ( @keep, 'alsa' ) ) if $has_alsa;
push @attempts, ( @keep ? join( ',', @keep ) : '' );
my %seen;
@attempts = grep { !$seen{$_}++ } @attempts;

my $built = 0;
my $attempt = '';
for my $candidate (@attempts) {
	$attempt = $candidate;
	my @cmd = @base;
	push @cmd, ( '--features', $attempt ) if length $attempt;
	print "+ @cmd\n";
	$built = system(@cmd) == 0;
	last if $built;
	print "note: the build failed with features `"
		. ( length $attempt ? $attempt : 'none' ) . "`;\n";
}

die "cargo build failed\n" unless $built;
$build_features = $attempt;
print "note: no device backend in the staged binary (null only)\n"
	unless $build_features =~ /(?:^|,)(?:alsa|jack)(?:,|$)/;

my $binary = File::Spec->catfile( $target, $profile, 'jawn-audio' );
die "cargo reported success but $binary is missing\n" unless -x $binary;

my $audio_dir = File::Spec->catdir( $root, 'perl', 'audio' );
make_path($audio_dir);

# A running engine holds its own image on disk, so writing straight into $out
# fails with ETXTBSY. Stage into a temp file in the same directory and rename
# it over the destination: rename swaps the inode, the process that is already
# running keeps the old binary, and the next spawn gets the new one.
my ( $tmp_fh, $tmp ) = tempfile( 'jawn-audio.XXXXXX', DIR => $audio_dir, UNLINK => 0 );
close $tmp_fh;
if ( !copy( $binary, $tmp ) || !chmod( 0755, $tmp ) || !rename( $tmp, $out ) ) {
	my $err = $!;
	unlink $tmp if -e $tmp;
	die "cannot stage $out: $err\n";
}
print "built: $out\n";

# A sherpa build also stages the recogniser and the shared libraries it loads.
# The `$ORIGIN` rpath added before the build makes the siblings independent of
# the caller's LD_LIBRARY_PATH; a manual cargo build needs that variable
# instead (docs/engine-asr.md).
if ( defined $sherpa_lib_dir ) {
	my $asr = File::Spec->catfile( $target, $profile, 'jawn-asr' );
	die "cargo reported success but $asr is missing: sherpa was requested\n"
		unless -x $asr;
	my $staged_asr = File::Spec->catfile( $audio_dir, 'jawn-asr' );
	stage_file( $asr, $staged_asr, 0755 );
	print "built: $staged_asr\n";
	for my $lib ( sherpa_libs($sherpa_lib_dir) ) {
		stage_file( File::Spec->catfile( $sherpa_lib_dir, $lib ),
			File::Spec->catfile( $audio_dir, $lib ), 0644 );
	}
	print "staged: sherpa-onnx shared libraries beside jawn-asr\n";
}

# The NDK a cross-build uses: an explicit --ndk, then the conventional
# environment variables, then the newest NDK under a known SDK root. Nothing
# here starts a download; an absent NDK is an ordinary "engine is optional".
sub resolve_ndk {
	my ($given) = @_;
	return $given if defined $given && length $given;
	for my $var (qw(ANDROID_NDK_HOME NDK_HOME ANDROID_NDK_ROOT)) {
		my $value = $ENV{$var};
		return $value if defined $value && length $value;
	}
	my @roots;
	for my $base (qw(ANDROID_SDK_ROOT ANDROID_HOME)) {
		push @roots, File::Spec->catdir( $ENV{$base}, 'ndk' )
			if defined $ENV{$base} && length $ENV{$base};
	}
	push @roots, File::Spec->catdir( $ENV{'HOME'}, 'android-sdk', 'ndk' )
		if defined $ENV{'HOME'} && length $ENV{'HOME'};
	for my $root (@roots) {
		next unless -d $root;
		opendir( my $dh, $root ) or next;
		my @versions = sort grep { !/^\.\.?$/ && -d File::Spec->catdir( $root, $_ ) } readdir $dh;
		closedir $dh;
		return File::Spec->catdir( $root, $versions[-1] ) if @versions;
	}
	return undef;
}

# --- sherpa-onnx helpers -----------------------------------------------------

# The `.so` files in a prebuilt asset's lib/ directory. Versioned names
# (`libfoo.so.1`) count; symlinks are copied by content when staged.
sub sherpa_libs {
	my ($dir) = @_;
	opendir( my $dh, $dir ) or return ();
	my @libs = sort grep { !/^\.\.?$/ && /\.so(?:\.|$)/ } readdir $dh;
	closedir $dh;
	return @libs;
}

# The two libraries build.rs links. A directory that lacks either is not a
# sherpa-onnx shared asset.
sub sherpa_libs_present {
	my ($dir) = @_;
	return 0 unless defined $dir && length $dir && -d $dir;
	my @libs = sherpa_libs($dir);
	return 0 unless grep { /^libsherpa-onnx-c-api\.so/ } @libs;
	return 0 unless grep { /^libonnxruntime\.so/ } @libs;
	return 1;
}

# Resolve a requested sherpa build or die in one actionable line. Never fall
# back to a smaller engine (docs/engine-asr.md).
sub resolve_sherpa_lib_dir {
	my $dir = $ENV{'SHERPA_ONNX_LIB_DIR'};
	die "the sherpa feature needs SHERPA_ONNX_LIB_DIR: point it at the lib/ "
		. "directory of a sherpa-onnx-v2.0.3 shared asset (docs/engine-asr.md)\n"
		unless defined $dir && length $dir;
	die "SHERPA_ONNX_LIB_DIR=$dir does not exist: point it at the lib/ "
		. "directory of a sherpa-onnx-v2.0.3 shared asset (docs/engine-asr.md)\n"
		unless -d $dir;
	die "SHERPA_ONNX_LIB_DIR=$dir has no libsherpa-onnx-c-api.so and "
		. "libonnxruntime.so: point it at the lib/ directory of a "
		. "sherpa-onnx-v2.0.3 shared asset (docs/engine-asr.md)\n"
		unless sherpa_libs_present($dir);
	return $dir;
}

# Append rustc flags to the encoded environment cargo already reads. Values
# containing spaces must stay one flag, hence the \x1f separator.
sub add_rustflag {
	my (@flags) = @_;
	my $existing = ( defined $ENV{'CARGO_ENCODED_RUSTFLAGS'}
		&& length $ENV{'CARGO_ENCODED_RUSTFLAGS'} )
		? $ENV{'CARGO_ENCODED_RUSTFLAGS'} : '';
	$ENV{'CARGO_ENCODED_RUSTFLAGS'} = join( "\x1f",
		( length $existing ? $existing : () ), @flags );
}

# Stage over a destination with a rename: a running image keeps its inode,
# and a sibling shared library is never half-written.
sub stage_file {
	my ( $src, $dst, $mode ) = @_;
	my $dir = File::Basename::dirname($dst);
	my ( $fh, $tmp ) = tempfile( 'jawn-stage.XXXXXX', DIR => $dir, UNLINK => 0 );
	close $fh;
	if ( !copy( $src, $tmp ) || !chmod( $mode, $tmp ) || !rename( $tmp, $dst ) ) {
		my $err = $!;
		unlink $tmp if -e $tmp;
		die "cannot stage $dst: $err\n";
	}
}

# The NDK ships one prebuilt toolchain per build host (linux-x86_64 here).
sub ndk_host_bin {
	my ($ndk) = @_;
	my $prebuilt = File::Spec->catdir( $ndk, 'toolchains', 'llvm', 'prebuilt' );
	die "the NDK at $ndk has no toolchains/llvm/prebuilt; the engine is optional\n"
		unless -d $prebuilt;
	opendir( my $dh, $prebuilt ) or die "cannot read $prebuilt: $!\n";
	my @hosts = sort grep { !/^\.\.?$/ && -d File::Spec->catdir( $prebuilt, $_ ) } readdir $dh;
	closedir $dh;
	die "the NDK at $ndk has no prebuilt toolchain; the engine is optional\n"
		unless @hosts;
	return File::Spec->catdir( $prebuilt, $hosts[0], 'bin' );
}
