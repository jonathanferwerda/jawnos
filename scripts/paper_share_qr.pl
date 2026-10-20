#!/usr/bin/env perl
# paper_share_qr.pl - turn a file of share codes into QR images.
#
#   perl scripts/paper_share_qr.pl shares.txt
#
# Accepts the old base64 share lines or the PS1 paper codes, one per line. It
# writes share-1.png ... under ~/.jawnos_paper_shares/<stamp>/ (mode 0700, files
# 0600) and prints only the folder and counts. It never prints a share or the
# house key.
use strict;
use warnings;
use FindBin qw($RealBin);

my $repo = $RealBin;
$repo =~ s{/scripts$}{};
chdir $repo or die "cannot chdir $repo: $!";
require "$repo/subroutines.pl";

my $file = shift @ARGV;
die "usage: $0 <shares.txt>\n" unless defined $file && length $file;
open my $fh, '<', $file or die "cannot read $file: $!\n";
my @lines = <$fh>;
close $fh;

my @shares;
foreach my $line ( @lines ) {
	$line =~ s/^\s+|\s+$//g;
	next unless length $line;
	my $s = &subs::shamir_share_decode($line);
	push @shares, $s if $s && $s->{'x'} >= 1 && $s->{'x'} <= 255;
}
die "no share codes decoded from $file\n" unless @shares;

my @paper = map { &subs::shamir_share_encode_paper($_) } @shares;
my $qr = &subs::shamir_qr_save(\@paper, 'paper shares');
die "could not write the QR images (is qrencode installed?)\n" unless $qr && $qr->{'dir'};

print "decoded " . scalar(@shares) . " shares\n";
print "wrote " . scalar(@{ $qr->{'images'} }) . " QR images\n";
print "folder: " . $qr->{'dir'} . "\n";
print "missing: " . $qr->{'missing'} . "\n" if $qr->{'missing'};
print "The QR images are the shares; keep them apart.\n";
exit 0;
