# tests-for: qa/budget.pl qa/budgets.json qa/lib/ qa/run.pl
# covers:    The budgets are the part of the suite that turns measurements into a verdict.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../qa/lib", "qa/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JSON::PP;
use Budget;
use Monitor;

my $json = JSON::PP->new;

# The budgets are the part of the suite that turns measurements into a verdict.
# If they silently stop applying - a typo'd metric name, a level that is not a
# level, a report shape the converter does not understand - every run stays
# green while memory doubles. These checks pin the contract.

my $qa = "$FindBin::Bin/../qa";

is(system($^X, '-c', "$qa/lib/Budget.pm"), 0, 'Budget.pm compiles');

# --- the file itself ----------------------------------------------------------
my $cfg = eval { Budget->load("$qa/budgets.json") };
ok($cfg, 'budgets.json loads') or diag($@);

my %known = map { $_ => 1 } Budget->known_metrics();
my @named;
for my $layer (sort keys %$cfg) {
	next if $layer =~ /^_/ || $layer eq 'note' || $layer eq 'version';
	my $m = $cfg->{$layer};
	is(ref $m, 'HASH', "$layer is a set of metrics");
	for my $key (sort keys %{ $m || {} }) {
		next if $key =~ /^_/;
		my $name = "$layer.$key";
		push @named, $name;
		ok($known{$name}, "$name is a metric Budget.pm knows how to read");
		my $e = $m->{$key};
		is(ref $e, 'HASH', "$name is an object with a level");
		my %n = (Budget::entry($key, $e));
		like($n{'limit'}, qr/^\d+(?:\.\d+)?$/, "$name has a numeric limit");
		ok($n{'level'} eq 'warn' || $n{'level'} eq 'fail', "$name level is warn or fail");
		ok(length($n{'why'}), "$name says why the limit is what it is");
	}
}
ok(@named >= 10, 'the budget covers the layers that measure something');

# An unknown name in the file would be skipped silently by check(); the test
# above is what stops that. A bare number defaults to a warning, never a failure.
{
	my %n = (Budget::entry('x', 5));
	is($n{'level'}, 'warn', 'a bare number is a warning by default');
	my %f = (Budget::entry('x', { limit => 5, level => 'failure' }));
	is($f{'level'}, 'warn', 'an invented level is not treated as fail');
}

# --- check semantics ----------------------------------------------------------
{
	my $b = { l1 => { p50_ms => { limit => 100, level => 'warn' },
	               max_ms => { limit => 10, level => 'fail' } } };

	my $rows = Budget->check({ 'l1.p50_ms' => 50, 'l1.max_ms' => 5 }, $b);
	is_deeply([ map { $_->{'verdict'} } @$rows ], [ 'pass', 'pass' ], 'under every limit passes');

	$rows = Budget->check({ 'l1.p50_ms' => 500, 'l1.max_ms' => 5 }, $b);
	my %v = map { $_->{'metric'} => $_->{'verdict'} } @$rows;
	is($v{'l1.p50_ms'}, 'warn', 'a warning limit warns and does not fail');
	is($v{'l1.max_ms'}, 'pass', 'the other metric is unaffected');

	$rows = Budget->check({ 'l1.p50_ms' => 1, 'l1.max_ms' => 500 }, $b);
	%v = map { $_->{'metric'} => $_->{'verdict'} } @$rows;
	is($v{'l1.max_ms'}, 'fail', 'a fail limit fails');

	$rows = Budget->check({}, $b);
	is_deeply([ map { $_->{'verdict'} } @$rows ], [ 'skip', 'skip' ],
		'a metric that was not measured is skip, never pass');

	$rows = Budget->check({ 'l1.max_ms' => 10 }, $b);
	%v = map { $_->{'metric'} => $_->{'verdict'} } @$rows;
	is($v{'l1.max_ms'}, 'pass', 'exactly on the limit passes');

	# A minimum is a different question: seven captured pages against a minimum
	# of eight is the regression, not a value 'under the limit'.
	my $min = { l3 => { pages_captured => { limit => 8, min => 1, level => 'warn' } } };
	$rows = Budget->check({ 'l3.pages_captured' => 7 }, $min);
	is($rows->[0]->{'verdict'}, 'warn', 'fewer pages than the minimum warns');
	$rows = Budget->check({ 'l3.pages_captured' => 9 }, $min);
	is($rows->[0]->{'verdict'}, 'pass', 'more pages than the minimum passes');
	$rows = Budget->check({ 'l3.pages_captured' => 8 }, $min);
	is($rows->[0]->{'verdict'}, 'pass', 'exactly the minimum passes');
}

# --- report -> metrics --------------------------------------------------------
{
	my $r = {
		timings => { requests => 201, p50 => 0.014, p95 => 0.089, max => 40.2 },
		monitor => { pss_peak_kb => 1055 * 1024, rss_peak_kb => 2048 * 1024,
			cpu_peak => 3.2, cpu_seconds => 121.7, procs_peak => 9,
			pss_slope_mb_per_h => 2.5 },
		db => [ { name => 'integrity', ok => 1 }, { name => 'fk', ok => 0 } ],
		ui => [
			{ name => 'webkit GET /manager', ok => 1, detail => 'QAHouse, 479 nodes' },
			{ name => 'chromium GET /manager', ok => 1, detail => 'status 200, 479 nodes' },
			{ name => 'chromium GET /manager/store', ok => 1, detail => 'not captured: timeout' },
			{ name => 'chromium GET /manager/help', ok => 0, detail => 'the route killed the instance' },
		],
		device => { 'l5.health_s' => 303, 'l5.host_rss_mb' => 2100 },
	};
	my $m = Budget->metrics_from_report($r);
	is($m->{'l1.p50_ms'}, 14, 'seconds become milliseconds');
	is($m->{'l1.p95_ms'}, 89, 'p95 converts');
	is($m->{'l1.max_ms'}, 40200, 'max converts (and keeps the slow page visible)');
	is($m->{'monitor.pss_peak_mb'}, 1055, 'kB become MB');
	is($m->{'monitor.cpu_seconds'}, 121, 'CPU seconds are an integer');
	is($m->{'monitor.rss_slope_mb_per_h'}, 2.5, 'the soak slope is carried through');
	is($m->{'l2.db_failures'}, 1, 'failed database checks are counted');
	is($m->{'l3.ui_failures'}, 1, 'failed UI checks are counted');
	is($m->{'l3.pages_captured'}, 1, 'a page that was not captured is not a captured page');
	is($m->{'l5.health_s'}, 303, 'device metrics pass through');

	# A layer that did not run must not be scored as if it ran and scored zero: an
	# absent UI array is "not measured", not "0 of 8 pages captured".
	my $absent = Budget->metrics_from_report({ ui => [], db => [] });
	ok(!exists $absent->{'l3.pages_captured'}, 'no UI rows means pages_captured was not measured');
	ok(!exists $absent->{'l3.ui_failures'}, 'no UI rows means ui_failures was not measured');
	ok(!exists $absent->{'l2.db_failures'}, 'no DB rows means db_failures was not measured');
}

# --- apply(): the verdict lands on the report ---------------------------------
{
	my $report = { monitor => { pss_peak_kb => 5000 * 1024 }, failures => [], warnings => 0 };
	my $rows = Budget->apply($report, { monitor => { pss_peak_mb => { limit => 100, level => 'fail' } } });
	is(scalar @{ $report->{'failures'} }, 1, 'a failed budget is a failure');
	like($report->{'failures'}->[0], qr/pss_peak_mb/, 'the failure names the metric');
	is($report->{'budget_failures'}, 1, 'the count is recorded');
	is(scalar @$rows, 1, 'the row is recorded for the report');
}

# --- the soak slope -----------------------------------------------------------
{
	my $dir = tempdir(CLEANUP => 1);

	my $flat = "$dir/flat.jsonl";
	write_file($flat, join('', map { $json->encode({ t => $_ * 120, pss_kb => 200 * 1024, dt => 1 }) . "\n" } 0 .. 9));
	my $s = Monitor->summarise($flat);
	cmp_ok(abs($s->{'pss_slope_mb_per_h'}), '<', 1, 'a flat series has no slope');

	my $rising = "$dir/rising.jsonl";
	write_file($rising, join('', map { $json->encode({ t => $_ * 120, pss_kb => (200 + $_) * 1024, dt => 1 }) . "\n" } 0 .. 9));
	$s = Monitor->summarise($rising);
	# 1 MB per 120 s = 30 MB per hour
	cmp_ok(abs($s->{'pss_slope_mb_per_h'} - 30), '<', 1, 'one MB per 120 s is 30 MB per hour');

	my $short = "$dir/short.jsonl";
	write_file($short, $json->encode({ t => 0, pss_kb => 1024 }) . "\n");
	$s = Monitor->summarise($short);
	ok(!defined $s->{'pss_slope_mb_per_h'}, 'one sample is not a slope');

	my $brief = "$dir/brief.jsonl";
	write_file($brief, join('', map { $json->encode({ t => $_, pss_kb => (200 + $_) * 1024, dt => 1 }) . "\n" } 0 .. 9));
	$s = Monitor->summarise($brief);
	ok(!defined $s->{'pss_slope_mb_per_h'}, 'a ten-second boot ramp is not a soak slope');
}

# --- the CLI a device script calls --------------------------------------------
{
	my $dir = tempdir(CLEANUP => 1);
	my $ok_file = "$dir/ok.json";
	write_file($ok_file, '{"l5.health_s": 60, "l5.host_rss_mb": 2100}');
	is(system($^X, "$qa/budget.pl", $ok_file), 0, 'the CLI passes a device inside its limits');

	my $bad_file = "$dir/bad.json";
	write_file($bad_file, '{"l5.health_s": 60, "l5.host_rss_mb": 9000}');
	is(system($^X, "$qa/budget.pl", $bad_file), 256, 'the CLI fails a device past a fail limit');

	my $report_file = "$dir/report.json";
	write_file($report_file, $json->encode({ timings => { requests => 3, p50 => 0.01, p95 => 0.02, max => 0.1 } }));
	is(system($^X, "$qa/budget.pl", $report_file), 0, 'the CLI reads a runner report too');
}

# --- the runner actually uses it ---------------------------------------------
{
	my $src = read_file("$qa/run.pl");
	like($src, qr/use Budget;/, 'run.pl loads the budget module');
	like($src, qr/Budget->apply\(\s*\\%report/, 'run.pl applies the budgets to the report');
	like($src, qr/--budgets/, 'the limits can be overridden for an experiment');
	like($src, qr/pss_slope_mb_per_h/, 'the report prints the soak slope');
}

done_testing();
