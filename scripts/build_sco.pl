#!/usr/bin/perl
# Build perl/sco/sco_helper, the Bluetooth SCO audio half of the phone gateway.
#
# The helper is checked in as C because it is the one part of the house that
# has to survive outside Perl: it holds the eSCO socket for the length of a
# call. Build it on the machine that has the adapter (the laptop now, the
# Odroid Go when it is charged); perl/Sco.pl only starts when the binary is
# here and executable, so a machine without BlueZ dev headers simply has no
# gateway.
#
#   perl scripts/build_sco.pl          # build in place
#   perl scripts/build_sco.pl --check  # report whether it is built, change nothing
use strict;
use warnings;
use FindBin;
use File::Spec;

my $root = File::Spec->rel2abs("$FindBin::Bin/..");
my $src = "$root/perl/sco/sco_helper.c";
my $out = "$root/perl/sco/sco_helper";
my $check = grep { $_ eq '--check' } @ARGV;

if ($check) {
	if (-x $out) {
		print "built: $out\n";
		exit 0;
	}
	print "missing: $out\n";
	exit 1;
}

die "no $src\n" unless -e $src;

# -lbluetooth is BlueZ; -lm is the tone generator; -lasound is the BlueALSA
# PCM path the gateway uses when a Hands-Free stack owns the link. -O2 keeps the 7.5 ms frame
# loop well inside a frame on the Odroid's Cortex-A35.
my @cmd = ('cc', '-O2', '-Wall', '-Wextra', '-o', $out, $src, '-lbluetooth', '-lm', '-lasound');
print "+ @cmd\n";
system(@cmd) == 0 or die "build failed\n";
chmod 0755, $out;
print "built $out\n";
