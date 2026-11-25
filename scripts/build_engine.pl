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
# than without an engine.
#
# $ENV{CARGO} names the toolchain (default `cargo` on PATH), and
# $ENV{CARGO_TARGET_DIR} is honoured so a test can build into a scratch folder.
use strict;
use warnings;

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
		( "$root/engine/Cargo.toml", "$root/engine/Cargo.lock", "$root/engine/src" );
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

	local $ENV{'ANDROID_NDK_HOME'} = $ndk;
	local $ENV{'CC_aarch64-linux-android'}   = $clang;
	local $ENV{'CXX_aarch64-linux-android'}  = $clangxx;
	local $ENV{'AR_aarch64-linux-android'}   = $ar;
	local $ENV{'CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER'} = $clang;

	my $target = ( defined $ENV{'CARGO_TARGET_DIR'} && length $ENV{'CARGO_TARGET_DIR'} )
		? $ENV{'CARGO_TARGET_DIR'}
		: File::Spec->catdir( $root, 'engine', 'target' );
	my $profile = $debug ? 'debug' : 'release';

	my @cmd = (
		$cargo, 'build', '--manifest-path', $manifest, '--lib', '--target',
		'aarch64-linux-android', '--features', 'oboe', '-j', '4'
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
	exit 0;
}

my $target = ( defined $ENV{'CARGO_TARGET_DIR'} && length $ENV{'CARGO_TARGET_DIR'} )
	? $ENV{'CARGO_TARGET_DIR'}
	: File::Spec->catdir( $root, 'engine', 'target' );
my $profile = $debug ? 'debug' : 'release';

my @base = ( $cargo, 'build', '--manifest-path', $manifest );
push @base, '--release' unless $debug;

my @cmd = @base;
push @cmd, ( '--features', $build_features ) if length $build_features;
print "+ @cmd\n";
my $built = system(@cmd) == 0;

# A machine with libasound but no libjack is the normal case (the house's
# audio interfaces do not need JACK at all), so drop features one at a time
# before giving up: ALSA alone still records, monitors and plays. Falling
# straight from `alsa,jack` to nothing would stage a silent engine on exactly
# the machine that has the interface plugged in.
for my $fallback ( 'alsa', '' ) {
	last if $built;
	next if length $fallback && $fallback eq $build_features;
	print "note: the device build failed with features `$build_features`;\n";
	print "note: retrying with " . ( length $fallback ? "features `$fallback`" : 'no features' ) . "\n";
	@cmd = @base;
	push @cmd, ( '--features', $fallback ) if length $fallback;
	print "+ @cmd\n";
	$built = system(@cmd) == 0;
	print "note: no device backend in the staged binary (null only)\n"
		if $built && !length $fallback;
	$build_features = $fallback if $built;
}

die "cargo build failed\n" unless $built;

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
