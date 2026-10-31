#!/usr/bin/env perl
# records_audit.pl - the records watch's dry run, from the command line.
#
#   perl scripts/records_audit.pl [--hours N] [--json]
#
# Runs the fixed audit (subs::records_audit) against this machine's database and
# prints the findings and the suggested action per row. Writes nothing: it is the
# dry run the Coding agent's reconcile would be proposed from.
use strict;
use warnings;
use FindBin;
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './subroutines.pl';

my ($hours, $json, $all, $apply) = (48, 0, 0, 0);
for (my $i = 0; $i < @ARGV; $i++) {
	$hours = $ARGV[$i + 1] if $ARGV[$i] eq '--hours' && defined $ARGV[$i + 1] && $ARGV[$i + 1] =~ /^[0-9]+$/;
	$json = 1 if $ARGV[$i] eq '--json';
	$all = 1 if $ARGV[$i] eq '--all';
	$apply = 1 if $ARGV[$i] eq '--apply';
}

my $window = $all ? 0 : $hours * 3600000;

if ($apply) {
	my $res = subs::records_reconcile($window, { apply => 1 });
	my $sum = $res->{'summary'};
	printf "reconcile APPLIED: %d action(s) - sweep %d grp / %d spare, dupes %d grp / %d spare, orphans %d, bad dates %d\n",
		$res->{'actions'}, $sum->{'sweep_groups'}, $sum->{'sweep_spare_rows'}, $sum->{'dupe_groups'}, $sum->{'dupe_spare_rows'}, $sum->{'orphans'}, ($sum->{'bad_dates'} // 0);
	foreach my $a ( @{ $res->{'list'} } ) {
		printf "  %-9s %-18s %s %s\n", $a->{'action'}, $a->{'app'}, ($a->{'uuid'} // ''), ($a->{'why'} // (defined $a->{'stop_timestamp'} ? "stop=>$a->{'stop_timestamp'} dur=>$a->{'duration'}" : ''));
	}
	exit 0;
}

my $report = subs::records_audit($window);

if ($json) {
	print Mojo::JSON::encode_json($report), "\n";
	exit 0;
}

my $s = $report->{'summary'};
printf "records audit - window %s, generated %s\n", ($report->{'window_ms'} ? $hours . 'h' : 'all time'), $report->{'generated_at'};
	printf "sweep: %d group(s) / %d spare row(s) | wrong-end: %d | dupes: %d group(s) / %d spare | orphans: %d | impossible: %d | bad dates: %d\n\n",
	$s->{'sweep_groups'}, $s->{'sweep_spare_rows'}, ($s->{'wrong_end'} // 0), $s->{'dupe_groups'}, $s->{'dupe_spare_rows'}, $s->{'orphans'}, $s->{'impossible'}, ($s->{'bad_dates'} // 0);

print "== SWEEP (one press, more than one session)\n";
foreach my $g ( @{ $report->{'sweep'} } ) {
	printf "%s  stopped %s  expected %s\n", $g->{'app'}, $g->{'stop_timestamp'}, (defined $g->{'expected_ms'} ? $g->{'expected_ms'} . 'ms' : '-');
	foreach my $r ( @{ $g->{'rows'} } ) {
		printf "   row %-8s %-9s start %s dur %-12s %s%s\n",
			$r->{'rowid'}, $r->{'suggested'}, $r->{'timestamp'}, ($r->{'duration'} // '-'), $r->{'why'},
			(defined $r->{'repair_stop_timestamp'} ? " stop=>$r->{'repair_stop_timestamp'}" : '');
	}
}

print "\n== WRONG-END (ended by a press meant for a newer session)\n";
foreach my $r ( @{ $report->{'wrong_end'} } ) {
	printf "%s row %s start %s stop %s dur %s -> repair to %s (runs %sms)\n",
		$r->{'app'}, $r->{'rowid'}, $r->{'timestamp'}, $r->{'stop_timestamp'}, ($r->{'duration'} // '-'),
		$r->{'repair_stop_timestamp'}, $r->{'expected_ms'};
}

print "== DUPES (same row written more than once)\n";
foreach my $g ( @{ $report->{'dupes'} } ) {
	printf "%s %s start %s stop %s  keep row %s, drop %s\n",
		$g->{'app'}, $g->{'type'}, $g->{'timestamp'}, ($g->{'stop_timestamp'} // '-'), $g->{'keep_rowid'}, join(',', @{ $g->{'remove_rowids'} });
}

print "\n== ORPHANS (open sessions)\n";
foreach my $r ( @{ $report->{'orphans'} } ) {
	printf "%s row %s start %s age %.1fh -> %s (%s)\n", $r->{'app'}, $r->{'rowid'}, $r->{'timestamp'}, $r->{'age_ms'} / 3600000, $r->{'suggested'}, $r->{'why'};
}

print "\n== IMPOSSIBLE (stop before start)\n";
foreach my $r ( @{ $report->{'impossible'} } ) {
	printf "%s row %s start %s stop %s\n", $r->{'app'}, $r->{'rowid'}, $r->{'timestamp'}, $r->{'stop_timestamp'};
}
print "\n== BAD DATES (a millisecond date read as a span of minutes)\n";
foreach my $r ( @{ $report->{'bad_dates'} } ) {
	printf "%-8s %s row %s %s %s -> %s\n", ($r->{'suggested'} // '?'), $r->{'app'}, $r->{'rowid'}, ($r->{'type'} // '?'), $r->{'timestamp'}, $r->{'fix'}->{'timestamp'};
}
print "\ndone - nothing written.\n";
