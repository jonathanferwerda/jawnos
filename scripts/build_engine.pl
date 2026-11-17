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
#   perl scripts/build_engine.pl --debug          # build without --release
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
use File::Path qw(make_path);
use File::Spec;
use FindBin;

my $root     = File::Spec->rel2abs("$FindBin::Bin/..");
my $manifest = "$root/engine/Cargo.toml";
my $out      = "$root/perl/audio/jawn-audio";
my $check    = grep { $_ eq '--check' } @ARGV;
my $debug    = grep { $_ eq '--debug' } @ARGV;

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

die "no $manifest\n" unless -e $manifest;

my $cargo = ( defined $ENV{'CARGO'} && length $ENV{'CARGO'} ) ? $ENV{'CARGO'} : 'cargo';

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

if ( !$built && length $build_features ) {
	print "note: the device build failed with features `$build_features`;\n";
	print "note: retrying with no features so the engine still runs the null device\n";
	@cmd = @base;
	print "+ @cmd\n";
	$built = system(@cmd) == 0;
	print "note: no device backend in the staged binary (null only)\n" if $built;
}

die "cargo build failed\n" unless $built;

my $binary = File::Spec->catfile( $target, $profile, 'jawn-audio' );
die "cargo reported success but $binary is missing\n" unless -x $binary;

make_path( File::Spec->catdir( $root, 'perl', 'audio' ) );
copy( $binary, $out ) or die "cannot stage $out: $!\n";
chmod( 0755, $out );
print "built: $out\n";
