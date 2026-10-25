#!/usr/bin/perl
# Print the PPH comparator: discharging drain grouped by whether the scheduled
# wake or the old permanent lock was in force. It reads the battery history the
# manager already keeps, so running it does not itself keep the phone awake.
#
#   perl scripts/pph_compare.pl
#
# A group needs at least three samples and twenty minutes before it prints a
# number; until then it reads "not enough samples".

use strict;
use warnings;
use FindBin qw($Bin);

chdir "$Bin/.." or die "cannot enter the jawnos tree: $!\n";
require './subroutines.pl';
require './gb.pl';

my $report = &subs::pph_compare_report();
print "PPH comparator (discharging samples only)\n";
print "A PPH is percent of battery per hour while discharging.\n\n";
printf "%-16s %6s %8s %8s\n", 'State', 'Points', 'Hours', 'PPH';
foreach my $row ( @{$report->{'rows'}} ) {
	printf "%-16s %6d %8s %8s\n",
		$row->{'label'},
		$row->{'points'},
		($row->{'hours'} ? sprintf('%.1f', $row->{'hours'}) : '-'),
		(defined $row->{'pph'} ? sprintf('%.2f', $row->{'pph'}) : 'not enough samples');
}
print "\n" . $report->{'note'} . "\n" if $report->{'note'};
