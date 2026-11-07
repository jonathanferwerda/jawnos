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

# A non-interactive ssh session exports no PERL5LIB and may not even put prove
# on PATH. ./jawn finds the user's local::lib from $HOME; do the same here,
# before `use Harness` needs Mojo and before prove needs Sereal.
BEGIN {
	my $base = (($ENV{'HOME'} || '') . '/perl5/lib/perl5');
	if ($base =~ m{/} && -d $base) {
		my @dirs = ($base);
		if (opendir(my $dh, $base)) {
			for my $name (sort readdir $dh) {
				my $dir = "$base/$name";
				push @dirs, $dir
					if $name ne '.' && $name ne '..' && -d $dir
					&& ($name =~ /-linux-/ || $name =~ /^[0-9]+\.[0-9]+/);
			}
			closedir $dh;
		}
		my %in_inc = map { $_ => 1 } @INC;
		unshift @INC, grep { !$in_inc{$_} } @dirs;
		my $lib = join ':', @dirs;
		$ENV{'PERL5LIB'} = $ENV{'PERL5LIB'}
			? "$lib:$ENV{'PERL5LIB'}" : $lib;
	}
}

use FindBin;
use lib "$FindBin::Bin/lib", "qa/lib";
use Cwd qw(abs_path);
use JSON::PP;
use POSIX ();
use Time::HiRes qw(time);

use Harness;
use Probe;
use Monitor;
use Db;
use Ui;
use Budget;

my %opt = (
	layers => 'l0,l1',
	profile => 'smoke',
	source => 'head',
	root => undef,
	anon => 1,
	keep => 1,
	namespace => 1,
	budgets => undef,
	apk => undef,
	image => undef,
	contract => 0,
	ux_limit => 5,
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
	if ($arg eq '--budgets')     { $opt{'budgets'} = shift @argv; next }
	if ($arg =~ /^--budgets=(.*)$/) { $opt{'budgets'} = $1; next }
	if ($arg eq '--apk')         { $opt{'apk'} = shift @argv; next }
	if ($arg =~ /^--apk=(.*)$/)  { $opt{'apk'} = $1; next }
	if ($arg eq '--image')       { $opt{'image'} = shift @argv; next }
	if ($arg =~ /^--image=(.*)$/){ $opt{'image'} = $1; next }
	if ($arg eq '--device-contract') { $opt{'contract'} = 1; next }
	if ($arg eq '--ux-limit')    { $opt{'ux_limit'} = shift @argv // 5; next }
	if ($arg =~ /^--ux-limit=(.*)$/) { $opt{'ux_limit'} = $1; next }
	if ($arg eq '--help' || $arg eq '-h') { usage(); exit 0 }
	die "qa: unknown argument: $arg\n";
}

$opt{'anon'} = 1 if $opt{'profile'} eq 'full';

my @layers = grep { length } split /,/, $opt{'layers'};
die "qa: --layers wants l0, l1 and/or l2\n" unless @layers;
for my $l (@layers) {
	die "qa: unknown layer '$l' (known: l0 l1 l2 l3 l4 l5 l6)\n" unless $l =~ /^l[0-6]$/;
}

# t/76 uses this to prove `--layers l6` is accepted without booting a copy.
if ($ENV{'JAWNOS_QA_PLAN_ONLY'}) {
	print 'plan: layers=' . join(',', @layers) . "\n";
	exit 0;
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
		$say->("\n[l0] perl scripts/run_tests.pl");
		my $t0 = time;
		# run_tests.pl boots the harness once and forks one child per test, so a
		# non-interactive ssh session needs no prove on PATH. The prove fallback
		# is only for a tree older than the runner.
		my $rc = -f 'scripts/run_tests.pl'
			? system($^X, 'scripts/run_tests.pl')
			: system($^X, '-MApp::Prove', '-e',
				'my $p = App::Prove->new; $p->process_args(@ARGV); exit($p->run ? 0 : 1)',
				'--', '-l', 't');
		$l0_result = {
			exit => ($rc >> 8), seconds => time - $t0,
			ok => ($rc == 0 ? 1 : 0),
		};
	}
}

my $want_l2 = grep { $_ eq 'l2' } @layers;
my $want_l3 = grep { $_ eq 'l3' } @layers;
my $want_l1 = grep { $_ eq 'l1' } @layers;
my $want_l6 = grep { $_ eq 'l6' } @layers;
if (!$want_l1 && !$want_l2 && !$want_l3 && !$want_l6
	&& !(grep { $_ eq 'l4' || $_ eq 'l5' } @layers)) {
	my $ok = $l0_result && $l0_result->{'ok'};
	$say->(sprintf('[l0] %s in %.1fs',
		($ok ? 'ok' : 'FAILED'), $l0_result ? $l0_result->{'seconds'} : 0))
		if $l0_result;
	$say->('RESULT: ' . ($ok ? 'PASS' : 'FAIL'));
	exit($ok ? 0 : 1);
}

# l1 needs the fence. Re-exec inside it, carrying l0's verdict with us.
if (($want_l1 || $want_l2 || $want_l3
		|| ($want_l6 && !(grep { $_ eq 'l4' || $_ eq 'l5' } @layers)))
	&& !$ENV{"JAWNOS_QA_NS"} && !$ENV{"JAWNOS_QA_NO_NS"}) {
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

# A killed runner must not leave a tree, a browser or the sampler behind. The
# child that matters is the instance (its cwd is the QA copy); this stops all
# of them without ever naming the live tree.
our $CLEANUP;
END { eval { $CLEANUP->() }; warn "qa cleanup: $@" if $@ }
$CLEANUP = sub {
	eval { $h->stop_all() }; warn "qa: cleanup h: $@" if $@;
	eval { Monitor->stop($monitor_pid) } if $monitor_pid; warn "qa: cleanup m: $@" if $@;
};
$SIG{'INT'} = $SIG{'TERM'} = sub { $CLEANUP->(); exit 1 };

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
	ui       => [],
	ux       => {},
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
# l2 - the database contracts (the copy only; nothing to boot)
# ---------------------------------------------------------------------------

if ($want_l2) {
	# The factory seed is the schema as it shipped; a boot runs the app's own
	# migrations and app_schema_ensure. Checking an un-booted copy would report
	# tables the seed simply has not grown yet as missing.
	if (!$want_l1) {
		# live=1 gives the loopback session, and app_schema_ensure runs on the
		# first request - booting alone is not enough for the app tables.
		$h->write_config(live => 1);
		my $b = eval { $h->boot(name => 'db', timeout => 180) };
		if ($b) { $h->session(); $h->stop('db') }
		else { $fatal->('l2: could not boot the copy to run migrations: ' . ($@ || 'unknown')) }
	}

	my $cfg = Db::load_config("$FindBin::Bin/db.checks.json");
	my $tree = $h->tree;
	my $rows = Db->checks(
		db     => "$tree/database/jawnos.db",
		schema => "$tree/database/schema.sql",
		config => $cfg,
	);
	$report{'db'} = $rows;
	my @bad = grep { !$_->{'ok'} } @$rows;
	$fatal->('l2 ' . $_->{'name'} . ': ' . $_->{'detail'}) for @bad;
	$say->(sprintf('[l2] %d checks, %d failed', scalar(@$rows), scalar(@bad)));
}

# ---------------------------------------------------------------------------
# l3 - the UI, in Chromium for breadth and WebKitGTK for the real engine
# ---------------------------------------------------------------------------

if ($want_l3) {
	$h->write_config(live => 1);
	my $boot = eval { $h->boot(name => 'ui', timeout => 180) };
	if (!$boot) {
		$fatal->('l3: the UI instance did not boot: ' . ($@ || 'unknown'));
	}
	else {
		$h->session();
		my $results = $h->results;
		my @paths = ('/manager', '/manager/help', '/manager/chat',
			'/manager/people', '/manager/clock', '/manager/warehouse',
			'/manager/configure', '/manager/store');
		my @urls = map { $h->url_for($_) } @paths;
		my $out = "$results/ui";

		# The WebKitGTK fallback runs first: a Chromium pass that trips a
		# handler bug can take the tree down, and then WebKit would only record
		# the connection refused that followed.
		my $w = Ui->webkit(url => $h->url_for('/manager'), out => "$out/webkit.json");
		if ($w->{'error'}) {
			$report{'warnings'}++;
			$say->('  warn webkit: ' . $w->{'error'});
			push @{ $report{'ui'} }, {
				name => 'webkit GET /manager', ok => 1,
				detail => 'not run: ' . $w->{'error'},
			};
		}
		else {
			push @{ $report{'ui'} }, {
				name => 'webkit GET /manager',
				ok => ($w->{'hasMenu'} ? 1 : 0),
				detail => ($w->{'title'} || '') . ', ' . ($w->{'nodes'} // '?') . ' nodes',
			};
			$fatal->('l3 webkit GET /manager: start menu missing') unless $w->{'hasMenu'};

			# An appointment view renders the budget light on a page that never
			# opened the Budget app. The probe clicks a synthetic one in the real
			# engine: if budgetLight() or its handler is not in the core bundle
			# the click throws or reaches nothing, and the panel stays empty
			# (v0.1.1810). A UI change is not green just because the page loads.
			my $light = $w->{'budgetLight'} || {};
			if ($light->{'defined'} && $light->{'handled'}) {
				push @{ $report{'ui'} }, {
					name => 'webkit appointment budget light', ok => 1,
					detail => 'a click reaches /manager/budget/current_information',
				};
			}
			else {
				my $why = $light->{'error'}
					|| 'budgetLight is not a core function, or its click reached nothing';
				push @{ $report{'ui'} }, {
					name => 'webkit appointment budget light', ok => 0, detail => $why,
				};
				$fatal->('l3 webkit: the appointment budget light is dead in the real engine: ' . $why);
			}
		}

		my $r = Ui->probe(urls => \@urls, out => $out);
		if ($r->{'error'}) {
			$fatal->('l3 chromium: ' . $r->{'error'});
		}
		else {
			for my $p (@{ $r->{'pages'} || [] }) {
				(my $path = $p->{'url'} // '') =~ s{^https?://[^/]+}{};
				if ($p->{'error'}) {
					$report{'warnings'}++;
					$say->("  warn ui $path: " . substr($p->{'error'}, 0, 110));
					push @{ $report{'ui'} }, {
						name => "chromium GET $path", ok => 1,
						detail => 'not captured: ' . $p->{'error'},
					};
					next;
				}
				my $verdict = 'pass';
				my $reason = '';
				unless (defined $p->{'status'}) {
					# A navigate timeout on a house whose tree is still alive is a
					# slow page. If the tree is gone, the route killed it - the
					# finding this layer exists for.
					if ($h->alive()) {
						$report{'warnings'}++;
						push @{ $report{'ui'} }, {
							name => "chromium GET $path", ok => 1,
							detail => 'not captured: navigate timeout (slow page)',
						};
						next;
					}
					$verdict = 'fail';
					$reason = 'the route killed the instance';
					push @{ $report{'crashes'} }, "chromium GET $path";
					my $ok = eval { $h->restart('ui'); $h->session(); 1 };
					if (!$ok) {
						$fatal->("l3 chromium GET $path: the instance died and could not be restarted");
						last;
					}
				}
				elsif ($p->{'status'} >= 500) {
					$verdict = 'fail';
					$reason = 'no answer or 5xx';
				}
				elsif ($path eq '/manager' && !$p->{'probe'}->{'hasMenu'}) {
					$verdict = 'fail';
					$reason = 'start menu missing';
				}
				push @{ $report{'ui'} }, {
					name => "chromium GET $path",
					ok => ($verdict eq 'pass' ? 1 : 0),
					detail => ($reason || "status " . ($p->{'status'} // '?')
						. ', ' . ($p->{'probe'}->{'nodes'} // '?') . ' nodes'),
				};
				$fatal->("l3 chromium GET $path: $reason") if $verdict eq 'fail';

				if (@{ $p->{'consoleErrors'} || [] }) {
					$report{'warnings'}++;
					$say->("  warn JS $path: " . substr($p->{'consoleErrors'}->[0], 0, 110));
				}
				if (@{ $p->{'badAssets'} || [] }) {
					$report{'warnings'}++;
					$say->("  warn asset $path: " . substr($p->{'badAssets'}->[0], 0, 110));
				}
				if (@{ $p->{'failed'} || [] }) {
					$report{'warnings'}++;
					$say->("  warn net $path: " . substr($p->{'failed'}->[0], 0, 110));
				}
				if ($p->{'probe'}->{'overflow'}) {
					$report{'warnings'}++;
					$say->("  warn overflow $path");
				}
				my $un = ($p->{'probe'}->{'unlabeled'} || 0)
					+ ($p->{'probe'}->{'unlabeledInputs'} || 0)
					+ ($p->{'probe'}->{'imgsNoAlt'} || 0);
				if ($un) {
					$report{'warnings'}++;
					$say->("  warn a11y $path: $un unlabelled control(s)/image(s)");
				}
			}
			if ($r->{'partial'}) {
				$report{'warnings'}++;
				$say->('[l3] chromium probe was partial: a page hung and was not captured');
			}
		}

		$h->stop('ui');
		$say->('[l3] ' . scalar(@{ $report{'ui'} }) . ' UI checks');
	}
}

# ---------------------------------------------------------------------------
# l4 / l5 - the device layers
# ---------------------------------------------------------------------------
#
# These are not fenced the way l1-l3 are. They drive a real emulator and a real
# VM, and the script in qa/android / qa/qemu is the authority for what happens
# inside them: it boots with a snapshot or a throwaway overlay, and it never
# points a device at the host's live tree. The runner's job is narrower - give
# the script an output directory, keep its log, and merge the metrics it writes
# so the budgets can judge them.

if (grep { $_ eq 'l4' || $_ eq 'l5' } @layers) {
	$report{'device'} = {};
	$report{'device_logs'} = [];

	my $merge = sub {
		my ($layer, $path) = @_;
		if (!-f $path) {
			$fatal->("$layer: the device script wrote no metrics ($path)");
			return;
		}
		open(my $fh, '<', $path) or do { $fatal->("$layer: $path: $!"); return };
		local $/;
		my $text = <$fh>;
		close $fh;
		my $m = eval { JSON::PP->new->decode($text) };
		if (ref $m ne 'HASH') {
			$fatal->("$layer: $path is not a JSON object");
			return;
		}
		for my $k (sort keys %$m) {
			$report{'device'}->{$k} = $m->{$k};
			$say->(sprintf('  %-28s %s', $k,
				(defined $m->{$k} ? $m->{$k} : '-'))) if $k =~ /^l[45]\./;
		}
	};

	my $run = sub {
		my ($layer, $script, $log, $env, @args) = @_;
		my $rc = run_device($script, $log, $env, @args);
		push @{ $report{'device_logs'} }, $log;
		if ($rc != 0) {
			my @tail = tail_lines($log, 4);
			$fatal->("$layer: the device script failed (exit $rc): " . join(' / ', @tail));
			return 0;
		}
		return 1;
	};

	if (grep { $_ eq 'l4' } @layers) {
		my $apk = $opt{'apk'};
		if (!$apk) {
			my @apks = sort { (stat($b))[9] <=> (stat($a))[9] } glob("$repo/releases/*.apk");
			$apk = $apks[0];
		}
		if (!$apk || !-f $apk) {
			$fatal->('l4: no APK to install (pass --apk, or stage one in releases/)');
		}
		else {
			$say->("\n[l4] android emulator, $apk");
			my $log = $h->logs . '/android.log';
			my $ok = $run->('l4', "$FindBin::Bin/android/run.sh", $log,
				{ QA_OUT => $h->results . '/android', QA_RESULTS => $h->results }, $apk);
			$merge->('l4', $h->results . '/device.json') if $ok;
		}
	}

	if (grep { $_ eq 'l5' } @layers) {
		my $img = $opt{'image'} || $ENV{'JAWNOS_QA_IMAGE'};
		if (!$img) {
			my @imgs = sort { (stat($b))[9] <=> (stat($a))[9] }
				glob("$repo/desktop/mkosi/output/*.raw");
			$img = $imgs[0];
		}
		if (!$img || !-f $img) {
			$fatal->('l5: no image to boot (pass --image, set JAWNOS_QA_IMAGE, or build one)');
		}
		else {
			$say->("\n[l5] qemu image, $img");
			my $log = $h->logs . '/qemu.log';
			my @args = ($opt{'contract'} ? ('--contract') : (), $img);
			my $ok = $run->('l5', "$FindBin::Bin/qemu/run.sh", $log,
				{ QA_OUT => $h->results . '/qemu' }, @args);
			$merge->('l5', $h->results . '/qemu/results/device.json') if $ok;
		}
	}

	# An old artefact proves old code. Say which versions disagreed; the budget
	# cannot see this, because a version is a string.
	if (($report{'device'}->{'l5.version_match'} || '') eq 'no') {
		$report{'warnings'}++;
		$say->(sprintf('  warn l5: the image is %s but this tree is %s',
			$report{'device'}->{'l5.image_version'} // '?',
			$report{'device'}->{'l5.repo_version'} // '?'));
	}
}

# ---------------------------------------------------------------------------
# l6 - the UX evaluation loop
# ---------------------------------------------------------------------------
#
# qa/ux/run owns the work: it reads the live notes with a mode=ro URI, seeds
# them into its own Harness copy, and drives that copy. Here we only hand it an
# output directory, keep its log, and merge the flat l6.* metrics so the budget
# can judge them - the same shape l4/l5 use.

if ($want_l6) {
	my $log = $h->logs . '/ux.log';
	my $metrics = $h->results . '/ux.json';
	my $results = $h->results . '/ux';
	my @args = ('--root', $h->root, '--results', $results,
		'--metrics', $metrics, '--limit', $opt{'ux_limit'});
	$say->("\n[l6] UX evaluation, newest $opt{'ux_limit'} JawnOS note(s)");
	my $rc = run_program($^X, "$FindBin::Bin/ux/run", $log, {}, @args);
	push @{ $report{'device_logs'} ||= [] }, $log;
	if ($rc != 0) {
		my @tail = tail_lines($log, 6);
		$fatal->("l6: the UX runner failed (exit $rc): " . join(' / ', @tail));
	}
	elsif (!-f $metrics) {
		$fatal->("l6: the UX runner wrote no metrics ($metrics)");
	}
	else {
		open(my $fh, '<', $metrics) or $fatal->("l6: $metrics: $!");
		if ($fh) {
			local $/;
			my $text = <$fh>;
			close $fh;
			my $m = eval { JSON::PP->new->utf8->decode($text) };
			if (ref $m ne 'HASH') {
				$fatal->("l6: $metrics is not a JSON object");
			}
			else {
				for my $k (sort keys %$m) {
					$report{'ux'}->{$k} = $m->{$k};
					$say->(sprintf('  %-28s %s', $k, $m->{$k})) if $k =~ /^l6\./;
				}
			}
		}
	}
}

# ---------------------------------------------------------------------------
# results
# ---------------------------------------------------------------------------

Monitor->stop($monitor_pid);
$monitor_pid = 0;   # the END cleanup must not reap it again
$report{"monitor"} = Monitor->summarise($monitor_out);
$report{'live_after'} = $h->live_snapshot();

# The numbers the layers collected finally get a verdict. This runs before
# `ok` is computed, so a failed budget is a failed run.
{
	my $cfg = eval { Budget->load($opt{'budgets'} || "$FindBin::Bin/budgets.json") };
	if (!$cfg) {
		$fatal->('budgets: ' . ($@ || 'could not be loaded'));
	}
	else {
		my $rows = Budget->apply(\%report, $cfg);
		for my $row (@$rows) {
			next unless $row->{'verdict'} eq 'fail';
			$say->(sprintf('  budget %s: %.1f %s %d (%s)', $row->{'metric'},
				$row->{'value'}, ($row->{'min'} ? '<' : '>'), $row->{'limit'},
				$row->{'detail'}));
		}
		$report{'warnings'} += $report{'budget_warnings'};
		$say->(sprintf('[budgets] %d metric(s): %d fail, %d warn, %d pass, %d not measured',
			scalar(@$rows), $report{'budget_failures'}, $report{'budget_warnings'},
			scalar(grep { $_->{'verdict'} eq 'pass' } @$rows),
			scalar(grep { $_->{'verdict'} eq 'skip' } @$rows)));
	}
}

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
exit($report{"ok"} ? 0 : 1);

# ---------------------------------------------------------------------------

sub run_device {
	my ($script, $log, $env, @args) = @_;
	return run_program('sh', $script, $log, $env, @args);
}

sub run_program {
	my ($prog, $script, $log, $env, @args) = @_;
	my $pid = fork();
	die "qa: fork: $!\n" unless defined $pid;
	if (!$pid) {
		open(STDOUT, '>', $log) or POSIX::_exit(127);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(127);
		$ENV{$_} = $env->{$_} for keys %$env;
		exec $prog, $script, @args;
		POSIX::_exit(127);
	}
	waitpid($pid, 0);
	return $? >> 8;
}

sub tail_lines {
	my ($path, $n) = @_;
	open(my $fh, '<', $path) or return ();
	my @keep;
	while (my $line = <$fh>) {
		chomp $line;
		next unless length $line;
		push @keep, $line;
		shift @keep if @keep > $n;
	}
	close $fh;
	return @keep;
}

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

	if (@{ $r->{'db'} || [] }) {
		$md .= "## Database\n\n| check | result | detail |\n| --- | --- | --- |\n";
		for my $row (@{ $r->{'db'} }) {
			my $detail = ($row->{'detail'} // '');
			$detail =~ s/\s+/ /g;
			$detail = substr($detail, 0, 120);
			$md .= '| ' . $row->{'name'} . ' | ' . ($row->{'ok'} ? 'ok' : 'FAIL')
				. ' | ' . $detail . " |\n";
		}
		$md .= "\n";
	}

	if (@{ $r->{'ui'} || [] }) {
		$md .= "## UI\n\n| check | result | detail |\n| --- | --- | --- |\n";
		for my $row (@{ $r->{'ui'} }) {
			$md .= '| ' . $row->{'name'} . ' | ' . ($row->{'ok'} ? 'ok' : 'FAIL')
				. ' | ' . ($row->{'detail'} // '') . " |\n";
		}
		$md .= "\n- screenshots: `results/ui/shots/` (WebP when ImageMagick is present)\n\n";
	}

	if (my $t = $r->{'timings'}->{'requests'}) {
		$md .= "## Route timings\n\n";
		$md .= sprintf("- %d requests in %.1fs\n", $t, $r->{'timings'}->{'seconds'});
		$md .= sprintf("- p50 %d ms, p95 %d ms, max %d ms\n\n",
			$r->{'timings'}->{'p50'} * 1000,
			$r->{'timings'}->{'p95'} * 1000,
			$r->{'timings'}->{'max'} * 1000);
	}

	if (@{ $r->{'budgets'} || [] }) {
		$md .= "## Budgets\n\n| metric | value | limit | verdict |\n| --- | --- | --- | --- |\n";
		for my $b (@{ $r->{'budgets'} }) {
			$md .= '| `' . $b->{'metric'} . '` | '
				. (defined $b->{'value'} ? sprintf('%.1f', $b->{'value'}) : '-') . ' | '
				. sprintf('%.0f', $b->{'limit'}) . ' | '
				. ($b->{'verdict'} eq 'pass' ? 'ok' : uc $b->{'verdict'})
				. ($b->{'verdict'} eq 'pass' || $b->{'verdict'} eq 'skip' ? '' : ' - ' . $b->{'detail'})
				. " |\n";
		}
		$md .= "\n";
	}

	if (my $d = $r->{'device'}) {
		my @keys = sort keys %$d;
		if (@keys) {
			$md .= "## Devices\n\n| metric | value |\n| --- | --- |\n";
			for my $k (@keys) {
				my $v = $d->{$k};
				$v = 'null' unless defined $v;
				$md .= "| `$k` | $v |\n";
			}
			$md .= "\n";
		}
		if (@{ $r->{'device_logs'} || [] }) {
			$md .= "- device logs: " . join(', ', map { "`$_`" } @{ $r->{'device_logs'} }) . "\n\n";
		}
	}

	my $m = $r->{'monitor'} || {};
	if (($m->{'samples'} || 0) > 0) {
		$md .= "## CPU and memory\n\n";
		$md .= sprintf("- samples: %d over %.0fs\n", $m->{'samples'}, $m->{'seconds'});
		$md .= sprintf("- peak instance memory (PSS): %.1f MB\n", ($m->{'pss_peak_kb'} || 0) / 1024);
		$md .= sprintf("- peak instance RSS (shared pages counted again): %.1f MB\n", $m->{'rss_peak_kb'} / 1024);
		$md .= sprintf("- peak instance CPU: %.2f cores\n", $m->{'cpu_peak'});
		$md .= sprintf("- CPU seconds used: %.1f\n", $m->{'cpu_seconds'});
		$md .= sprintf("- peak processes: %d\n", $m->{'procs_peak'});
		$md .= sprintf("- PSS drift: %+.1f MB/hour\n", $m->{'pss_slope_mb_per_h'})
			if defined $m->{'pss_slope_mb_per_h'};
		$md .= "\n";
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
  --budgets FILE     limits to check (default qa/budgets.json)
  --apk FILE         l4: install this APK (default: newest in releases/)
  --image FILE       l5: boot this raw image (default: newest mkosi output)
  --device-contract  l5: also install to a blank disk and boot it twice
  --help

The run writes tree/, home/, logs/ and results/ under --root and never touches
the live database. Every instance is SIGKILLed at the end.
USAGE
}
