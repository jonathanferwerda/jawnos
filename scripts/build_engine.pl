#!/usr/bin/perl
# Build engine/, the native audio engine, and stage it as perl/audio/jawn-audio.
#
# The engine is optional, exactly like perl/sco/sco_helper: a machine with no
# Rust toolchain simply has no engine, and every caller falls back to the
# browser's WebAudio path (docs/studio-audio-roadmap.md). The source is tracked;
# the staged binary is not.
#
#   perl scripts/build_engine.pl           # build and stage
#   perl scripts/build_engine.pl --check   # report whether it is staged
#   perl scripts/build_engine.pl --debug   # build without --release
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

my @cmd = ( $cargo, 'build', '--manifest-path', $manifest );
push @cmd, '--release' unless $debug;
print "+ @cmd\n";
system(@cmd) == 0 or die "cargo build failed\n";

my $built = File::Spec->catfile( $target, $profile, 'jawn-audio' );
die "cargo reported success but $built is missing\n" unless -x $built;

make_path( File::Spec->catdir( $root, 'perl', 'audio' ) );
copy( $built, $out ) or die "cannot stage $out: $!\n";
chmod( 0755, $out );
print "built: $out\n";
