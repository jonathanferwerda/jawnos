#!/usr/bin/perl

# Keep the last N QA runs under $root/runs and delete the rest.
#
#   perl qa/prune.pl                 # keep the newest 14
#   perl qa/prune.pl --keep 30
#   perl qa/prune.pl --root DIR
#
# Only directories whose name is one of this suite's stamps
# (YYYYMMDD-HHMMSS-PID) are touched, and only inside $root/runs. Everything else
# in the QA root is left alone.

use strict;
use warnings;

use File::Path qw(remove_tree);
use Getopt::Long qw(GetOptions);

my $root = (($ENV{'HOME'} || '/tmp') . '/jawnos-qa');
my $keep = 14;
GetOptions('keep=i' => \$keep, 'root=s' => \$root)
	or die "usage: prune.pl [--keep N] [--root DIR]\n";
die "prune: --keep must be positive\n" unless $keep > 0;

my $runs = "$root/runs";
unless (-d $runs) {
	print "prune: no runs under $runs\n";
	exit 0;
}

opendir(my $dh, $runs) or die "prune: $runs: $!\n";
my @stamps = sort { $b cmp $a }
	grep { /^\d{8}-\d{6}-\d+$/ && -d "$runs/$_" } readdir($dh);
closedir $dh;

my $removed = 0;
if (@stamps > $keep) {
	for my $stamp (@stamps[$keep .. $#stamps]) {
		remove_tree("$runs/$stamp", { error => \my $err });
		if ($err && @$err) {
			warn "prune: could not remove $runs/$stamp\n";
			next;
		}
		$removed++;
	}
}

printf "prune: kept %d, removed %d (root %s)\n",
	(@stamps < $keep ? scalar @stamps : $keep), $removed, $root;
exit 0;
