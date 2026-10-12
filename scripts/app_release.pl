#!/usr/bin/perl
# Stage built JawnOS APKs into the project's releases/ dir.
#
#   perl scripts/app_release.pl <apk> [<apk> ...] [--dir DIR]
#   perl scripts/app_release.pl --version-code=1003 --version-name=0.119.0 <apk>
#
# Each APK is copied to releases/jawnos-<product>-<versionCode>-<versionName>.apk,
# where product (app|api) is read from the APK's package name. The newest build
# of a product replaces older ones. This is the "copies it into the jawnos
# project directory" step: run it on whichever machine built the APK, and the
# file is a normal part of the tree from then on.
#
# The file is gitignored on purpose - it rides the mesh as a blob (every device
# replicates it) rather than through git history, which would carry ~35 MB per
# version forever. scripts/../releases/ is the conventional drop.
#
# versionCode/versionName come from `aapt dump badging`; override them with
# --version-code / --version-name when aapt is not at hand.

use strict;
use warnings;
use FindBin;
use Cwd qw(abs_path);
use File::Copy qw(copy);
use File::Basename qw(basename);
use File::Slurp qw(read_file);
use Digest::SHA qw(sha256_hex);

my $root = abs_path("$FindBin::Bin/..");
my $dir  = "$root/releases";
my (@apks, %override);
while ( defined(my $arg = shift @ARGV) ) {
	if ($arg eq '--dir')                { $dir = shift @ARGV; next; }
	if ($arg =~ /^--version-code=(.+)/) { $override{'versionCode'} = $1; next; }
	if ($arg =~ /^--version-name=(.+)/) { $override{'versionName'} = $1; next; }
	if ($arg =~ /^--product=(.+)/)      { $override{'product'} = $1; next; }
	push @apks, $arg;
}
die "usage: app_release.pl <apk> [...] [--dir DIR]\n" unless @apks;
mkdir $dir unless -d $dir;

my $aapt = find_aapt();

foreach my $apk (@apks) {
	die "$apk: no such file\n" unless -f $apk;
	my ($pkg, $vc, $vn) = apk_badging($aapt, $apk);
	my $product = $override{'product'} || ($pkg && $pkg =~ /\.api$/ ? 'api' : 'app');
	$vc = $override{'versionCode'} || $vc || die "$apk: cannot read versionCode (no aapt; pass --version-code)\n";
	$vn = $override{'versionName'} || $vn || '0';
	$vn =~ s/[^0-9A-Za-z._-]/_/g;
	my $dest = "$dir/jawnos-$product-$vc-$vn.apk";
	# one build per product: drop whatever else is staged for it
	unlink $_ for grep { $_ ne $dest } glob("$dir/jawnos-$product-*.apk");
	copy($apk, $dest) or die "copy to $dest failed: $!\n";
	printf "%-4s v%-8s -> %s (%d bytes, sha256 %s...)\n",
		$product, $vn, $dest, (-s $dest), substr(sha256_hex(read_file($dest)), 0, 16);
}

sub find_aapt {
	my $sdk = $ENV{'ANDROID_SDK_ROOT'} || "$ENV{'HOME'}/android-sdk";
	my @found;
	foreach my $p ( glob("$sdk/build-tools/*/aapt") ) {
		my ($v) = $p =~ m{/build-tools/([^/]+)/aapt$};
		my @n = split /\./, ( $v || '0' );
		push @found, [ ($n[0] || 0) * 1_000_000 + ($n[1] || 0) * 1_000 + ($n[2] || 0), $p ];
	}
	if (@found) { @found = sort { $b->[0] <=> $a->[0] } @found; return $found[0][1]; }
	foreach my $p ( split /:/, $ENV{'PATH'} || '' ) { my $x = "$p/aapt"; return $x if -x $x; }
	return undef;
}

sub apk_badging {
	my ($aapt, $apk) = @_;
	return ('', '', '') unless $aapt && -x $aapt;
	my $out = `"$aapt" dump badging "$apk" 2>/dev/null`;
	my ($pkg) = $out =~ /package: name='([^']+)'/;
	my ($vc)  = $out =~ /versionCode='([^']+)'/;
	my ($vn)  = $out =~ /versionName='([^']+)'/;
	return ($pkg, $vc, $vn);
}
