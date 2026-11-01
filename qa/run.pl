#!/usr/bin/perl

# qa/run.pl - the JawnOS QA suite.
#
#   perl qa/run.pl                       # the smoke profile: l0 + l1
#   perl qa/run.pl --layers l1           # route layer only
#   perl qa/run.pl --profile full        # adds the anonymous gate pass
#   perl qa/run.pl --source worktree     # test uncommitted code
#   perl qa/run.pl --no-namespace        # no fence; read the warning
#   perl qa/run.pl --root ~/jawnos-qa    # where runs and results live
#
# Everything runs inside a user/PID/net/mount namespace when the kernel allows
# it (see qa/lib/Harness.pm). The live repo is bind-mounted read-only, the
# instance is a copy with a factory-seeded database, and teardown is SIGKILL.
# A run writes only under --root.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "qa/lib";
use Cwd qw(abs_path);
use JSON::PP;
use POSIX ();
use Time::HiRes qw(time);

use Harness;
use Probe;
use Monitor;

my %opt = (
	layers => 'l0,l1',
	profile => 'smoke',
	source => 'head',
	root => undef,
	anon => 1,
	keep => 1,
	namespace => 1,
);
my @argv = @ARGV;
while (my $arg = shift @argv) {
	if ($arg eq '--layers')      { $opt{'layers'} = shift @argv // ''; next }
	if ($arg =~ /^--layers=(.*)$/) { $opt{'layers'} = $1; next }
	if ($arg eq '--profile')     { $opt{'profile'} = shift @argv // 'smoke'; next }
	if ($arg =~ /^--profile=(.*)$/) { $opt{'profile'} = $1; next }
	if ($arg eq '--source')      { $opt{'source'} = shift @argv // 'head'; next }
	if ($arg =~ /^--source=(.*)$/) { $opt{'source'} = $1; next }
	if ($arg eq '--root')        { $opt{'root'} = shift @argv; next }
	if ($arg =~ /^--root=(.*)$/) { $opt{'root'} = $1; next }
	if ($arg eq '--no-anon')     { $opt{'anon'} = 0; next }
	if ($arg eq '--no-namespace') { $opt{'namespace'} = 0; next }
	if ($arg eq '--no-keep')     { $opt{'keep'} = 0; next }
	if ($arg eq '--help' || $arg eq '-h') { usage(); exit 0 }
	die "qa: unknown argument: $arg\n";
}

$opt{'anon'} = 1 if $opt{'profile'} eq 'full';

my @layers = grep { length } split /,/, $opt{'layers'};
die "qa: --layers wants l0 and/or l1\n" unless @layers;
for my $l (@layers) {
	die "qa: unknown layer '$l' (known: l0 l1)\n" unless $l =~ /^l[01]$/;
}

my $say = sub { print $_[0], "\n" };

$say->('JawnOS QA ' . ($ENV{'JAWNOS_QA_NS'} ? '[namespaced]' : '[unfenced]'));
$say->('profile=' . $opt{'profile'} . ' layers=' . join(',', @layers)
	. ' source=' . $opt{'source'});

my $repo = abs_path("$FindBin::Bin/..");

# ---------------------------------------------------------------------------
# l0 - the existing regression suite. It is hermetic by construction (t/lib's
# sandbox), so it runs outside the fence: inside a user namespace the process
# is uid 0 and two of its tests read that as a different machine.
# ---------------------------------------------------------------------------

my $l0_result;
if (grep { $_ eq 'l0' } @layers) {
	if (defined $ENV{'JAWNOS_QA_L0_EXIT'}) {
		# carried across the namespace re-exec
		$l0_result = {
			exit => 0 + $ENV{'JAWNOS_QA_L0_EXIT'},
			seconds => 0 + ($ENV{'JAWNOS_QA_L0_SECS'} || 0),
		};
		$l0_result->{'ok'} = $l0_result->{'exit'} == 0 ? 1 : 0;
	}
	else {
		$say->("\n[l0] prove -l t");
		my $t0 = time;
		my $rc = system('prove', '-l', 't');
		$l0_result = {
			exit => ($rc >> 8), seconds => time - $t0,
			ok => ($rc == 0 ? 1 : 0),
		};
	}
}

if (!grep { $_ eq 'l1' } @layers) {
	my $ok = $l0_result && $l0_result->{'ok'};
	$say->(sprintf('[l0] %s in %.1fs',
		($ok ? 'ok' : 'FAILED'), $l0_result ? $l0_result->{'seconds'} : 0))
		if $l0_result;
	$say->('RESULT: ' . ($ok ? 'PASS' : 'FAIL'));
	exit($ok ? 0 : 1);
}

# l1 needs the fence. Re-exec inside it, carrying l0's verdict with us.
if (!$ENV{'JAWNOS_QA_NS'} && !$ENV{'JAWNOS_QA_NO_NS'}) {
	if ($l0_result) {
		$ENV{'JAWNOS_QA_L0_EXIT'} = $l0_result->{'exit'};
		$ENV{'JAWNOS_QA_L0_SECS'} = $l0_result->{'seconds'};
	}
	Harness::enter_namespace(@ARGV);
}

my $h = Harness->new(
	repo => $repo,
	root => $opt{'root'},
	source => $opt{'source'},
);

$h->private_tmp();
my $ro = $h->bind_live_read_only();
$say->('fence: live repo read-only ' . ($ro ? 'yes' : 'NO'));

$h->export_tree();
$h->seed();
$h->make_certificate();
$h->pick_ports();

my $live_before = $h->live_snapshot();
my $monitor_out = $h->results . '/monitor.jsonl';
my $monitor_pid = Monitor->start(
	tree => $h->tree,
	db   => "$h->{'tree'}/database/jawnos.db",
	out  => $monitor_out,
);

my %report = (
	stamp    => $h->{'stamp'},
	version  => `git --no-optional-locks -C '$repo' rev-parse --short HEAD`,
	repo     => $repo,
	root     => $h->root,
	source   => $opt{'source'},
	profile  => $opt{'profile'},
	layers   => \@layers,
	layer_results => {},
	failures => [],
	warnings => 0,
	crashes  => [],
	routes   => [],
	skipped  => [],
	monitor  => {},
	audit    => {},
	timings  => {},
	live_before => $live_before,
);
chomp $report{'version'} if defined $report{'version'};

my $fatal = sub {
	my ($msg) = @_;
	push @{ $report{'failures'} }, $msg;
	$say->("FAIL $msg");
};

if ($l0_result) {
	$report{'layer_results'}->{'l0'} = $l0_result;
	if (!$l0_result->{'ok'}) {
		$fatal->('l0: the regression suite failed (exit ' . $l0_result->{'exit'} . ')');
	}
	else {
		$say->(sprintf('[l0] ok in %.1fs', $l0_result->{'seconds'}));
	}
}

# ---------------------------------------------------------------------------
# l1 - the route layer against a real instance
# ---------------------------------------------------------------------------

if (grep { $_ eq 'l1' } @layers) {
	my $policy = Probe::load_policy("$FindBin::Bin/routes.policy.json");
	my $routes = Probe::routes($repo);
	$say->("\n[l1] " . scalar(@$routes) . ' routes');

	# ---- the signed-in pass, on a live-boot loopback instance -------------
	$h->write_config(live => 1);
	my $boot = eval { $h->boot(name => 'main', timeout => 180) };
	if (!$boot) {
		$fatal->('l1: the instance did not boot: ' . ($@ || 'unknown'));
	}
	else {
		$say->(sprintf('[l1] booted in %.1fs', $boot->{'seconds'}));
		my $session = $h->session();
		if (!$session->{'ok'}) {
			$fatal->("l1: no loopback session (status " . ($session->{'status'} // '?') . ')');
		}
		else {
			$say->('[l1] resident session opened the manager');
		}

		my $t0 = time;
		my @timings;
		my %requested;
		for my $r (@$routes) {
			my ($skip, $why) = Probe::classify($policy, $r);
			my $key = lc($r->{'method'}) . ' ' . $r->{'path'};
			if ($skip) {
				push @{ $report{'skipped'} }, { key => $key, reason => $why };
				next;
			}
			if ($requested{$key}++) {
				push @{ $report{'skipped'} },
					{ key => $key, reason => 'shadowed by an earlier registration' };
				next;
			}

			my $res = $h->get($r->{'path'}, body => 1);
			my $status = $res->{'status'};
			my $expected = Probe::expected_status($policy, $r, 'resident');
			my $verdict = 'pass';
			my $reason = '';

			if (!defined $status || $status >= 500) {
				my $tolerated = Probe::tolerated($policy, $r);
				my $err = $res->{'error'} || '';
				if ($err =~ /timeout/i) {
					# The client gave up; the route is slow, which is a finding, but
					# not the same class as a crash. Keep the time in the row.
					$verdict = 'warn';
					$reason = 'slow: client timed out after ' . int($res->{'seconds'} * 1000) . 'ms';
				}
				# A dead tree is not this route's verdict: name it, restart, and
				# carry on so one bad handler cannot hide the next hundred routes.
				elsif (!$h->alive()) {
					$verdict = 'fail';
					$reason = 'the instance died while serving this route';
					push @{ $report{'crashes'} }, $key;
					my $ok = eval { $h->restart('main'); $h->session(); 1 };
					if (!$ok) {
						$fatal->("l1 $key: the instance died and could not be restarted");
						last;
					}
					$say->("  restart after $key");
				}
				elsif ($tolerated) {
					$verdict = 'warn';
					$reason = "$status: $tolerated";
				}
				else {
					$verdict = 'fail';
					$reason = $res->{'error'} || "status $status";
				}
			}
			elsif ($expected == 403 && $status != 403) {
				$verdict = 'fail';
				$reason = "tier not enforced: expected 403, got $status";
			}
			elsif ($status == 200
				&& $r->{'path'} ne '/gate'
				&& ($res->{'body'} // '') =~ m{<title>Gate</title>}) {
				$verdict = 'fail';
				$reason = 'gate page on a signed-in request';
			}

			push @timings, $res->{'seconds'};
			push @{ $report{'routes'} }, {
				key => $key, status => $status,
				ms => int($res->{'seconds'} * 1000),
				verdict => $verdict, reason => $reason,
			};
			$report{'warnings'}++ if $verdict eq 'warn';
			if ($verdict eq 'fail') {
				$fatal->("l1 $key: $reason");
			}
		}
		my $secs = time - $t0;
		@timings = sort { $a <=> $b } @timings;
		my $n = scalar @timings;
		$report{'timings'} = {
			requests => $n,
			seconds  => $secs,
			p50      => $n ? $timings[int($n * 0.5)] : 0,
			p95      => $n ? $timings[int($n * 0.95)] : 0,
			max      => $n ? $timings[-1] : 0,
		};
		$say->(sprintf('[l1] %d requests in %.1fs (p50 %dms, p95 %dms, max %dms)',
			$n, $secs, $timings[int($n * 0.5)] * 1000,
			$timings[int($n * 0.95)] * 1000, $timings[-1] * 1000)) if $n;

		$report{'audit'} = $h->audit();
		my $a = $report{'audit'};
		if (!$a->{'ok'}) {
			$fatal->('fence audit failed: ' . scalar(@{ $a->{'live_opens'} }) . ' live-database references');
		}
		else {
			$say->(sprintf('[fence] %d instance processes, none with the live database open', $a->{'pids'}));
		}

		$h->stop('main');

		# ---- the anonymous pass: no session, no manager -------------------
		if ($opt{'anon'}) {
			$h->write_config(live => 0);
			my $gate = eval { $h->boot(name => 'gate', timeout => 180) };
			if (!$gate) {
				$fatal->('l1: the gate instance did not boot: ' . ($@ || 'unknown'));
			}
			else {
				my ($ua) = $h->ua();
				my %want = (
					'/manager'            => 'gate',
					'/manager/configure'  => 'refused',
					'/manager/people'     => 'refused',
					'/manager/store'      => 'refused',
					'/manager/health'     => 'health',
					'/gate'               => 'gate',
					'/'                   => 'public',
					'/privacy'            => 'public',
					'/manifest.json'      => 'public',
				);
				for my $path (sort keys %want) {
					my $tx = $ua->get($h->url_for($path));
					my $code = $tx->res->code;
					my $body = $tx->res->body // '';
					my $verdict = 'pass';
					my $reason = '';
					if (!defined $code || $code >= 500) {
						$verdict = 'fail';
						$reason = 'no answer or 5xx';
					}
					elsif ($want{$path} eq 'health' && !($code < 500)) {
						$verdict = 'fail';
						$reason = "health answered $code";
					}
					elsif ($want{$path} ne 'health'
						&& $body =~ /id="start_menu_toggle"/) {
						$verdict = 'fail';
						$reason = 'manager content without a session';
					}
					push @{ $report{'routes'} }, {
						key => "anon GET $path", status => $code,
						ms => 0, verdict => $verdict, reason => $reason,
					};
					$fatal->("l1 anon GET $path: $reason") if $verdict eq 'fail';
				}
				$say->('[l1] anonymous pass: no manager content without a session');
				$h->stop('gate');
			}
		}
	}
}

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------

Monitor->stop($monitor_pid);
$report{'monitor'} = Monitor->summarise($monitor_out);
$report{'live_after'} = $h->live_snapshot();

# the live files may legitimately change while the live app is running; record
# the deltas as evidence, not as a verdict (the fence audit is the verdict)
{
	my @drift;
	for my $file (sort keys %{ $report{'live_before'} }) {
		my $a = $report{'live_before'}->{$file};
		my $b = $report{'live_after'}->{$file};
		next if !$a && !$b;
		next if $a && $b && $a->{'inode'} == $b->{'inode'} && $a->{'size'} == $b->{'size'};
		push @drift, { file => $file, before => $a, after => $b };
	}
	$report{'live_drift'} = \@drift;
}

$report{'ok'} = scalar(@{ $report{'failures'} }) ? 0 : 1;
$report{'finished'} = time;

write_report($h->results, \%report);

$say->('');
$say->('RESULT: ' . ($report{'ok'} ? 'PASS' : 'FAIL')
	. ' (' . scalar(@{ $report{'failures'} }) . ' failure(s))');
$say->('results: ' . $h->results);
exit($report{'ok'} ? 0 : 1);

# ---------------------------------------------------------------------------

sub write_report {
	my ($dir, $r) = @_;

	my $json = JSON::PP->new->canonical->pretty;
	open(my $fh, '>', "$dir/report.json") or die "qa: $dir/report.json: $!\n";
	print $fh $json->encode($r);
	close $fh;

	open(my $tsv, '>', "$dir/routes.tsv") or die "qa: routes.tsv: $!\n";
	print $tsv "method_path\tstatus\tms\tverdict\treason\n";
	for my $row (@{ $r->{'routes'} }) {
		print $tsv join("\t", $row->{'key'}, $row->{'status'} // '',
			$row->{'ms'} // '', $row->{'verdict'}, $row->{'reason'} // ''), "\n";
	}
	close $tsv;

	my $md = "# JawnOS QA $r->{'stamp'}\n\n";
	$md .= "- version: `$r->{'version'}`\n";
	$md .= "- source: $r->{'source'}\n";
	$md .= "- profile: $r->{'profile'}\n";
	$md .= "- layers: " . join(', ', @{ $r->{'layers'} }) . "\n";
	$md .= "- result: **" . ($r->{'ok'} ? 'PASS' : 'FAIL') . "**\n\n";

	if (@{ $r->{'crashes'} || [] }) {
		$md .= "## Trees that died mid-route\n\n";
		$md .= "- `$_`\n" for @{ $r->{'crashes'} };
		$md .= "\n";
	}
	$md .= "- warnings: " . ($r->{'warnings'} || 0) . "\n\n";

	$md .= "## Fence\n\n";
	my $audit = $r->{'audit'} || {};
	$md .= "- instance processes: " . ($audit->{'pids'} // 0) . "\n";
	$md .= "- live database references: " . scalar(@{ $audit->{'live_opens'} || [] }) . "\n";
	$md .= "- PID namespace: " . (($audit->{'namespace'} && $audit->{'namespace'}->{'pid'}) ? 'yes' : 'no') . "\n";
	$md .= "- net namespace: " . (($audit->{'namespace'} && $audit->{'namespace'}->{'net'}) ? 'yes' : 'no') . "\n";
	$md .= "- live repo read-only: " . (($audit->{'ro_repo'} || '') ? 'yes' : 'no') . "\n\n";

	if (my $t = $r->{'timings'}->{'requests'}) {
		$md .= "## Route timings\n\n";
		$md .= sprintf("- %d requests in %.1fs\n", $t, $r->{'timings'}->{'seconds'});
		$md .= sprintf("- p50 %d ms, p95 %d ms, max %d ms\n\n",
			$r->{'timings'}->{'p50'} * 1000,
			$r->{'timings'}->{'p95'} * 1000,
			$r->{'timings'}->{'max'} * 1000);
	}

	my $m = $r->{'monitor'} || {};
	if (($m->{'samples'} || 0) > 0) {
		$md .= "## CPU and memory\n\n";
		$md .= sprintf("- samples: %d over %.0fs\n", $m->{'samples'}, $m->{'seconds'});
		$md .= sprintf("- peak instance memory (PSS): %.1f MB\n", ($m->{'pss_peak_kb'} || 0) / 1024);
		$md .= sprintf("- peak instance RSS (shared pages counted again): %.1f MB\n", $m->{'rss_peak_kb'} / 1024);
		$md .= sprintf("- peak instance CPU: %.2f cores\n", $m->{'cpu_peak'});
		$md .= sprintf("- CPU seconds used: %.1f\n", $m->{'cpu_seconds'});
		$md .= sprintf("- peak processes: %d\n\n", $m->{'procs_peak'});
	}

	if (@{ $r->{'failures'} }) {
		$md .= "## Failures\n\n";
		$md .= "- $_\n" for @{ $r->{'failures'} };
		$md .= "\n";
	}

	my @slow = grep { defined $_->{'ms'} } @{ $r->{'routes'} };
	@slow = sort { ($b->{'ms'} // 0) <=> ($a->{'ms'} // 0) } @slow;
	splice(@slow, 15) if @slow > 15;
	$r->{'slowest'} = [ map { { key => $_->{'key'}, ms => $_->{'ms'} } } @slow ];
	if (@slow) {
		$md .= "## Slowest routes\n\n| route | status | ms |\n| --- | --- | --- |\n";
		for my $row (@slow) {
			$md .= '| `' . $row->{'key'} . '` | ' . ($row->{'status'} // '-')
				. ' | ' . $row->{'ms'} . " |\n";
		}
		$md .= "\n";
	}

	my %skipped;
	$skipped{ $_->{'reason'} }++ for @{ $r->{'skipped'} };
	if (%skipped) {
		$md .= "## Skipped\n\n";
		$md .= "- $_: $skipped{$_}\n" for sort keys %skipped;
		$md .= "\n";
	}

	open(my $mf, '>', "$dir/report.md") or die "qa: report.md: $!\n";
	print $mf $md;
	close $mf;
}

sub usage {
	print <<'USAGE';
Usage: perl qa/run.pl [options]

  --layers l0,l1     layers to run (default l0,l1)
  --profile smoke    smoke (default) or full (adds the anonymous gate pass)
  --source head      head (default) or worktree
  --root DIR         QA root (default $HOME/jawnos-qa)
  --no-anon          skip the anonymous pass even in the full profile
  --no-namespace     do not enter the fence; read the warning
  --no-keep          accepted for symmetry; runs are always kept
  --help

The run writes tree/, home/, logs/ and results/ under --root and never touches
the live database. Every instance is SIGKILLed at the end.
USAGE
}
