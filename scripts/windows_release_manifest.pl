#!/usr/bin/perl
# Write the update-feed manifest for a JawnOS Windows installer.
#
#   perl scripts/windows_release_manifest.pl --version 0.1.2727 \
#       --file dist/JawnOS-0.1.2727-Setup.exe \
#       --url https://github.com/<repo>/releases/download/releases/JawnOS-0.1.2727-Setup.exe \
#       --notes "JawnOS 0.1.2727 for Windows" \
#       --out dist/windows_release.json --sums dist/SHA256SUMS
#
# The feed is the fixed `releases` GitHub release, mirroring the Android feed
# (app_release.json beside the APK): the manifest and the Setup.exe always have
# the same URL, and the version inside is what moves. The manifest carries the
# digest of the exact bytes that are published, so signing must regenerate it.
#
# Core modules only: this runs on a bare Strawberry Perl during the release
# build, before any cpanm'd module is available.

use strict;
use warnings;

use Getopt::Long qw(GetOptions);
use Digest::SHA ();
use File::Basename qw(basename dirname);
use File::Spec;
use JSON::PP ();

my %opt = (
	'min-os' => '10.0.19044',
	'signed' => 0,
);

GetOptions(
	\%opt,
	'version=s',
	'file=s',
	'url=s',
	'notes=s',
	'out=s',
	'min-os=s',
	'signed=i',
	'sums=s',
) or usage(2);

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
usage: windows_release_manifest.pl --version VERSION --file SETUP_EXE --url URL
                                   [--notes TEXT] [--out MANIFEST]
                                   [--min-os VERSION] [--signed 0|1]
                                   [--sums SHA256SUMS]
USAGE
	exit $code;
}

sub fail {
	my ($message) = @_;
	print STDERR "windows_release_manifest: $message\n";
	exit 2;
}

# --- version and versionCode ------------------------------------------------
# The updater orders Windows builds the same way it orders the Android app:
# major*100000000 + minor*1000000 + patch. 0.1.2727 -> 1002727.

my $version = defined $opt{'version'} ? $opt{'version'} : '';
$version =~ s/^\s+|\s+$//g;
fail('--version is required') unless length $version;
fail("not a version (want MAJOR.MINOR.PATCH): $version")
	unless $version =~ /\A(\d+)\.(\d+)\.(\d+)\z/;
my $version_code = $1 * 100000000 + $2 * 1000000 + $3;

# --- the installer ----------------------------------------------------------

my $file = defined $opt{'file'} ? $opt{'file'} : '';
fail('--file is required') unless length $file;
fail("no such file: $file") unless -e $file;
fail("not a regular file: $file") unless -f $file;
my $filename = basename($file);
my $expected = "JawnOS-$version-Setup.exe";
fail("filename must be $expected, not $filename") unless $filename eq $expected;

my $url = defined $opt{'url'} ? $opt{'url'} : '';
$url =~ s/^\s+|\s+$//g;
fail('--url is required') unless length $url;

my $signed = $opt{'signed'} ? 1 : 0;
fail('--signed must be 0 or 1') unless $opt{'signed'} == 0 || $opt{'signed'} == 1;
my $min_os = defined $opt{'min-os'} && length $opt{'min-os'} ? $opt{'min-os'} : '10.0.19044';
my $notes = defined $opt{'notes'} ? $opt{'notes'} : '';

my $size = -s $file;
fail("could not read the size of $file") unless defined $size;

my $digest = eval { Digest::SHA->new(256)->addfile($file)->hexdigest };
fail("could not hash $file: $@") unless defined $digest && $digest =~ /\A[0-9a-f]{64}\z/;

# --- the manifest -----------------------------------------------------------
# Exactly these keys; the schema is the contract the updater reads.

my $manifest = {
	'product'     => 'windows',
	'version'     => $version,
	'versionCode' => $version_code,
	'filename'    => $filename,
	'sha256'      => $digest,
	'size'        => $size,
	'url'         => $url,
	'notes'       => $notes,
	'min_os'      => $min_os,
	'signed'      => $signed,
};

my $out = defined $opt{'out'} && length $opt{'out'}
	? $opt{'out'}
	: File::Spec->catfile(dirname($file), 'windows_release.json');

my $json = JSON::PP->new->canonical->encode($manifest) . "\n";
open(my $out_fh, '>', $out) or fail("could not write $out: $!");
print {$out_fh} $json or fail("could not write $out: $!");
close $out_fh or fail("could not close $out: $!");

if (defined $opt{'sums'} && length $opt{'sums'}) {
	open(my $sums_fh, '>', $opt{'sums'}) or fail("could not write $opt{'sums'}: $!");
	print {$sums_fh} "$digest  $filename\n" or fail("could not write $opt{'sums'}: $!");
	close $sums_fh or fail("could not close $opt{'sums'}: $!");
}

printf "windows_release_manifest: %s %s (versionCode %d, %d bytes, %s)\n",
	$filename, $version, $version_code, $size, $signed ? 'signed' : 'unsigned';
print "wrote $out\n";
print "wrote $opt{'sums'}\n" if defined $opt{'sums'} && length $opt{'sums'};

exit 0;
