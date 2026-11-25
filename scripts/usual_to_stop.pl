#!/usr/bin/perl

# usual_to_stop.pl - turn the person's historical usual rows into stop rows.
#
#   perl scripts/usual_to_stop.pl           # dry run: print what would change
#   perl scripts/usual_to_stop.pl --apply   # change the type, in one statement
#
# Every old usual press is a completed appointment: its timestamp is the press
# and the sign of its duration says which end that press was (positive = the
# end, negative = the start). A stop row is the same record; only the type was
# different. The script never rewrites the timestamp, duration or stop_timestamp:
# the learner reads the sign, so the span stays exactly as the person wrote it.
#
# It leaves the task/default/guide children alone (source task/default/guide,
# or a source_uuid): they are steps of another appointment, not sessions.
use strict;
use warnings;
use FindBin;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $apply = (grep { $_ eq '--apply' } @ARGV) ? 1 : 0;
my $now = &subs::rightNow();
my $where = "type = 'usual'"
	. " and coalesce(source, '') in ('', 'press')"
	. " and coalesce(source_uuid, '') = ''"
	. " and (stop_timestamp is null or stop_timestamp = '')"
	. " and cast(timestamp as integer) < ?";

my $total = &subs::db_query("select count(*) as n from appointments where $where", $now)->hash->{'n'} || 0;
my $apps = &subs::db_query("select app, count(*) as n from appointments where $where group by app order by n desc", $now)->hashes || [];
print "old usual rows: $total across " . scalar(@{$apps}) . " app(s)\n";
my $shown = 0;
foreach my $row ( @{$apps} ) {
	last if $shown++ >= 20;
	print "  " . $row->{'app'} . "  " . $row->{'n'} . "\n";
}
print "  ...\n" if scalar(@{$apps}) > 20;

unless ($apply) {
	print "\ndry run - pass --apply to change these rows to type stop\n";
	exit 0;
}

unless (&subs::db_query(
	"update appointments set type = 'stop', stop_seen = 'yes', seen = 'yes', server_time = ? where $where",
	$now, $now
)) {
	die "the usual-to-stop update failed\n";
}
my $left = &subs::db_query("select count(*) as n from appointments where $where", $now)->hash->{'n'} || 0;
print "\nchanged $total row(s); $left old usual parent row(s) remain\n";
