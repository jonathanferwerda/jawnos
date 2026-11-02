package Budget;

# Measurements become a verdict.
#
# The layers record numbers (p95 latency, peak PSS, jank, boot time). A number
# nobody compares against anything is a chart, not a test: a tree that starts
# using 900 MB instead of 400 MB still "passes". This module holds the limits in
# qa/budgets.json and compares each measured value with its limit.
#
# Two levels, because they mean different things:
#
#   fail  the run is not green. Memory or jank past this line breaks a real
#         machine, not just a promise.
#   warn  recorded and counted, but the run can still pass. Latency on a shared
#         4-core box moves for reasons that are not this tree's fault.
#
# A metric that was not measured is `skip`, never a pass. That is the same rule
# the UI layer uses: silence must not look like success.

use strict;
use warnings;

use JSON::PP;

our $VERSION = '1';

# Every metric a budget may name, and where it comes from. A budget entry for a
# key not in this list is a typo; t/67-qa-budgets.t checks that.
my %SOURCE = (
	'l1.p50_ms'                 => 'route timings, median',
	'l1.p95_ms'                 => 'route timings, 95th percentile',
	'l1.max_ms'                 => 'route timings, slowest request',
	'l1.requests'               => 'routes actually sent',
	'monitor.pss_peak_mb'       => 'summed PSS of the instance tree',
	'monitor.rss_peak_mb'       => 'summed RSS (shared pages counted again)',
	'monitor.cpu_peak_cores'    => 'busiest one-second CPU sample',
	'monitor.cpu_seconds'       => 'CPU seconds over the whole run',
	'monitor.procs_peak'        => 'most processes seen at once',
	'monitor.rss_slope_mb_per_h'=> 'least-squares PSS drift, MB per hour',
	'l2.db_failures'            => 'failed database contracts',
	'l3.ui_failures'            => 'failed UI checks',
	'l3.pages_captured'         => 'pages the browser actually rendered',
	'l4.cold_start_s'           => 'am start -W cold start',
	'l4.pss_mb'                 => 'app PSS under the emulator',
	'l4.jank_pct'               => 'gfxinfo janky frame percentage',
	'l5.health_s'               => 'seconds until the image answers health',
	'l5.host_rss_mb'            => 'host RSS of the VM process',
);

sub known_metrics { return sort keys %SOURCE }

sub load {
	my ($class, $path) = @_;
	open(my $fh, '<', $path) or die "Budget: $path: $!\n";
	local $/;
	my $text = <$fh>;
	close $fh;
	my $cfg = eval { JSON::PP->new->utf8->decode($text) };
	die "Budget: $path is not valid JSON: $@\n" unless ref $cfg eq 'HASH';
	return $cfg;
}

# Normalise one entry to { limit, level, why, min }. A bare number is a warn: a
# limit that fails a run has to be asked for on purpose. `"min": true` means
# the metric must stay *above* the limit (pages captured, for example), so the
# direction is part of the budget, not of the caller.
sub entry {
	my ($key, $v) = @_;
	return () unless defined $v;
	return (limit => $v, level => 'warn', why => '', min => 0) unless ref $v eq 'HASH';
	my $level = $v->{'level'} || 'warn';
	$level = 'warn' unless $level eq 'fail';   # never invent a failing level
	return (limit => $v->{'limit'}, level => $level, why => $v->{'why'} || '',
		min => ($v->{'min'} ? 1 : 0));
}

# check(\%metrics, \%budget) -> arrayref of rows, in metric-name order.
#
# metrics are flat: 'monitor.pss_peak_mb' => 812.3
sub check {
	my ($class, $metrics, $cfg) = @_;
	$metrics ||= {};
	$cfg     ||= {};
	my @rows;

	for my $layer (sort keys %$cfg) {
		next if $layer =~ /^_/ || $layer eq 'note';
		my $m = $cfg->{$layer};
		next unless ref $m eq 'HASH';
		for my $key (sort keys %$m) {
			next if $key =~ /^_/;
			my %e = entry($key, $m->{$key});
			next unless defined $e{'limit'};
			my $name  = "$layer.$key";
			my $value = $metrics->{$name};

			if (!defined $value || $value !~ /^-?\d+(?:\.\d+)?$/) {
				push @rows, {
					metric => $name, value => undef, limit => $e{'limit'},
					level  => $e{'level'}, verdict => 'skip',
					detail => 'not measured this run',
				};
				next;
			}

			my $verdict = $e{'min'}
				? ($value < $e{'limit'} ? $e{'level'} : 'pass')
				: ($value > $e{'limit'} ? $e{'level'} : 'pass');
			push @rows, {
				metric  => $name,
				value   => 0 + $value,
				limit   => 0 + $e{'limit'},
				level   => $e{'level'},
				min     => $e{'min'},
				verdict => $verdict,
				detail  => $e{'why'} || ($SOURCE{$name} || ''),
			};
		}
	}

	return \@rows;
}

# The run report in, flat metrics out. Unit conversions live here and nowhere
# else, so a budget is written in the unit a person reads in the report.
sub metrics_from_report {
	my ($class, $r) = @_;
	$r ||= {};
	my %m;

	my $t = $r->{'timings'} || {};
	for my $k (qw(p50 p95 max)) {
		$m{"l1.${k}_ms"} = int(($t->{$k} || 0) * 1000) if defined $t->{$k};
	}
	$m{'l1.requests'} = $t->{'requests'} if defined $t->{'requests'};

	my $mo = $r->{'monitor'} || {};
	$m{'monitor.pss_peak_mb'}    = int($mo->{'pss_peak_kb'} / 1024) if $mo->{'pss_peak_kb'};
	$m{'monitor.rss_peak_mb'}    = int($mo->{'rss_peak_kb'} / 1024) if $mo->{'rss_peak_kb'};
	$m{'monitor.cpu_peak_cores'} = $mo->{'cpu_peak'};
	$m{'monitor.cpu_seconds'}    = int($mo->{'cpu_seconds'}) if defined $mo->{'cpu_seconds'};
	$m{'monitor.procs_peak'}     = $mo->{'procs_peak'};
	$m{'monitor.rss_slope_mb_per_h'} = $mo->{'pss_slope_mb_per_h'}
		if defined $mo->{'pss_slope_mb_per_h'};

	$m{'l2.db_failures'} = scalar(grep { !$_->{'ok'} } @{ $r->{'db'} || [] })
		if @{ $r->{'db'} || [] };

	if (my $ui = $r->{'ui'}) {
		if (@$ui) {
			$m{'l3.ui_failures'} = scalar(grep { !$_->{'ok'} } @$ui);
			$m{'l3.pages_captured'} = scalar grep {
				($_->{'name'} || '') =~ /^chromium GET /
					&& $_->{'ok'}
					&& ($_->{'detail'} || '') !~ /^not (?:captured|run)/
			} @$ui;
		}
	}

	# Device layers write their own flat metrics (see qa/budget.pl); a report
	# that merged them carries them under `device`.
	if (ref $r->{'device'} eq 'HASH') {
		for my $k (keys %{ $r->{'device'} }) {
			next unless $k =~ /^l[45]\./;
			$m{$k} = $r->{'device'}->{$k};
		}
	}

	return \%m;
}

# apply(\%report, \%budget) -> rows, and record the verdict on the report.
# Failing budgets become failures; warnings are counted, not fatal.
sub apply {
	my ($class, $report, $cfg) = @_;
	my $rows = Budget->check(Budget->metrics_from_report($report), $cfg);
	$report->{'budgets'} = $rows;

	for my $row (@$rows) {
		next unless $row->{'verdict'} eq 'fail';
		push @{ $report->{'failures'} },
			sprintf('budget %s: %.1f %s %d (%s)', $row->{'metric'},
				$row->{'value'}, ($row->{'min'} ? '<' : '>'), $row->{'limit'},
				$row->{'detail'});
	}
	$report->{'budget_warnings'} = scalar grep { $_->{'verdict'} eq 'warn' } @$rows;
	$report->{'budget_failures'} = scalar grep { $_->{'verdict'} eq 'fail' } @$rows;

	return $rows;
}

1;
