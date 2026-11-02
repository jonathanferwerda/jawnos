#!/usr/bin/perl
#
# Check a measurement file against the budgets.
#
#   perl qa/budget.pl results/report.json          # a runner report
#   perl qa/budget.pl results/android.json         # flat device metrics
#   echo '{"l4.cold_start_s": 12}' | perl qa/budget.pl -
#
# A device layer has no report to merge into, so it writes its own flat file:
#
#   { "l4.cold_start_s": 6.2, "l4.pss_mb": 113, "l4.jank_pct": 95 }
#
# Exit 0 = no fail-level limit was crossed (warnings may exist), 1 = a budget
# failed, 2 = the input could not be read.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", 'qa/lib';
use JSON::PP;
use Getopt::Long qw(GetOptions);
use Budget;

my $budgets = "$FindBin::Bin/budgets.json";
my $help    = 0;
GetOptions('budgets=s' => \$budgets, 'help|h' => \$help) or die "qa-budget: bad options\n";
if ($help || !@ARGV) {
	print <<'USAGE';
Usage: perl qa/budget.pl <report.json | metrics.json | -> [--budgets FILE]

A runner report (it has timings/monitor/ui) is converted the same way run.pl
does it. A flat file of "layer.metric": value pairs is checked as-is.
USAGE
	exit 0;
}

my $path = shift @ARGV;
my $text;
if ($path eq '-') { local $/; $text = <STDIN> }
else {
	open(my $fh, '<', $path) or do { warn "qa-budget: $path: $!\n"; exit 2 };
	local $/;
	$text = <$fh>;
	close $fh;
}

my $doc = eval { JSON::PP->new->utf8->decode($text) };
if (ref $doc ne 'HASH') { warn "qa-budget: $path is not a JSON object\n"; exit 2 }

my $metrics;
if ($doc->{'metrics'} && ref $doc->{'metrics'} eq 'HASH') { $metrics = $doc->{'metrics'} }
elsif (grep { $doc->{$_} } qw(timings monitor ui db device)) {
	$metrics = Budget->metrics_from_report($doc);
}
else { $metrics = $doc }

my $cfg = eval { Budget->load($budgets) };
die "qa-budget: $budgets: $@\n" unless $cfg;

my $rows = Budget->check($metrics, $cfg);
my $fail = 0;
my $warn = 0;
printf "%-28s %10s %10s  %s\n", 'metric', 'value', 'limit', 'verdict';
for my $r (@$rows) {
	printf "%-28s %10s %10s  %s%s\n",
		$r->{'metric'},
		(defined $r->{'value'} ? sprintf('%.1f', $r->{'value'}) : '-'),
		sprintf('%.0f', $r->{'limit'}),
		uc $r->{'verdict'},
		$r->{'verdict'} eq 'pass' ? '' : " ($r->{'detail'})";
	$fail++ if $r->{'verdict'} eq 'fail';
	$warn++ if $r->{'verdict'} eq 'warn';
}
print "\n", ($fail ? "FAIL" : 'PASS'), " - $fail budget failure(s), $warn warning(s), "
	. scalar(@$rows) . " metric(s)\n";
exit($fail ? 1 : 0);
