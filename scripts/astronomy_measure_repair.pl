#!/usr/bin/perl

# astronomy_measure_repair.pl - give the sky's daily readings the warranty every
# permanent measure row carries, and mark them as already announced.
#
#   perl scripts/astronomy_measure_repair.pl           # dry run: count what would change
#   perl scripts/astronomy_measure_repair.pl --apply   # write
#
# The moon, space weather and magnetometer write one measure row a day. Before
# v0.1.3775 the writer set neither `seen` nor a warranty, so a reading had no
# term and the alarm could announce it as the next appointment. This fills the
# old rows from their own moment, the way the session warranty backfill does.
# Safe to re-run: only a row missing a value is touched.
#
# Run it from this tree. To write into the live house's database while running a
# worktree's copy of the code, point the store at the house:
#
#   JAWNOS_STORE_DIR=/home/jawn/jawnos perl scripts/astronomy_measure_repair.pl --apply
use strict;
use warnings;
use FindBin;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $apply = (grep { $_ eq '--apply' } @ARGV) ? 1 : 0;

my $res  = subs::astronomy_measure_repair($apply);
my $rows = $res->{'rows'};
my %apps = %{ $res->{'apps'} || {} };

printf "%d sky row(s) missing a warranty or a seen mark across %d app(s).\n",
	scalar @{$rows}, scalar(keys %apps);
foreach my $app ( sort keys %apps ) {
	printf "  %-16s %d\n", $app, $apps{$app};
}
printf "%s\n", $apply ? 'Updated.' : 'Dry run - pass --apply to write.';
