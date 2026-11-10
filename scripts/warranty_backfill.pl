#!/usr/bin/perl

# warranty_backfill.pl - give the session rows that were born without a warranty
# the warranty their app says they should have.
#
#   perl scripts/warranty_backfill.pl           # dry run: count what would change
#   perl scripts/warranty_backfill.pl --apply   # write the warranties
#
# appointment_writer used to insert a start/record/usual row before it filled the
# warranty, and the refresh at the foot does not carry that column, so sessions
# the writer started itself (a home plate, a timer, a relayed start) have none.
# A NULL warranty is never expired - the culler's cast(warranty) < now is false
# for NULL - so those rows live forever. The fix in v0.1.2525 stops new ones;
# this fills the old ones from the app's own warranty setting. Safe to re-run.
use strict;
use warnings;
use FindBin;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $apply = (grep { $_ eq '--apply' } @ARGV) ? 1 : 0;

my $res  = subs::appointment_warranty_backfill($apply);
my $rows = $res->{'rows'};
my %apps = %{ $res->{'apps'} || {} };

printf "%d session row(s) with no warranty across %d app(s).\n", scalar @{$rows}, scalar(keys %apps);
foreach my $app ( (sort { $apps{$b} <=> $apps{$a} || $a cmp $b } keys %apps)[0 .. 9] ) {
	next unless defined $app;
	printf "  %-30s %d\n", $app, $apps{$app};
}
printf "%s\n", $apply ? 'Updated.' : 'Dry run - pass --apply to write.';
