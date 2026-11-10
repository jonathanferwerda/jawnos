#!/usr/bin/perl

# duration_backfill.pl - teach every app the usual length its own stops show.
#
#   perl scripts/duration_backfill.pl           # dry run: print what would change
#   perl scripts/duration_backfill.pl --apply   # write the duration settings
#   perl scripts/duration_backfill.pl --all     # also list apps already correct
#
# A stopped session teaches its app how long it usually runs
# (subs::session_duration_learn). An app whose sessions were always ended by a
# writer that did not learn still carries the old guess until its next stop;
# this fills it from the last 40 closed sessions it already has. Safe to re-run:
# it recomputes the same average and rewrites only the setting.
use strict;
use warnings;
use FindBin;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

# The parentheses matter: grep is a list operator, so without them the whole
# `grep {...} @ARGV ? 1 : 0` reads as one grep and --apply is never a match.
my $apply = (grep { $_ eq '--apply' } @ARGV) ? 1 : 0;
my $all   = (grep { $_ eq '--all' } @ARGV) ? 1 : 0;

my $rows = subs::session_duration_backfill($apply);
my $changed = grep { $_->{'changed'} } @{$rows};
my $width = 0;
foreach my $row ( @{$rows} ) {
	$width = length($row->{'app'}) if length($row->{'app'}) > $width;
}
$width = 20 if $width < 20;

printf "%-*s  %-16s  %-16s\n", $width, 'app', 'was', 'usual (last 40 stops)';
foreach my $row ( @{$rows} ) {
	next if !$all && !$row->{'changed'};
	printf "%-*s  %-16s  %s\n", $width, $row->{'app'}, ($row->{'was'} || '-'), $row->{'value'};
}
printf "\n%d app(s) with closed sessions; %d %s.\n", scalar @{$rows}, $changed,
	$apply ? 'updated' : 'would change (dry run - pass --apply to write)';
