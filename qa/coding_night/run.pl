#!/usr/bin/perl

# qa/coding_night/run.pl - the 06:00 coding nightly.
#
#   perl qa/coding_night/run.pl                 # up to the configured note limit
#   perl qa/coding_night/run.pl --dry-run       # print the plan, change nothing
#   perl qa/coding_night/run.pl --limit 2       # override the panel (clamped 1..25)
#   perl qa/coding_night/run.pl --ignore-device # a test/owner run, not the timer
#
# One note at a time, never parallel:
#
#   gate    qa/device_target.pl says this machine is the chosen one, else exit 0
#   read    the top open JawnOS notes (mode=ro), up to the note limit
#   fetch   git fetch, then a worktree at <root>/work/<stamp>-<n> on
#           qa/nightly-<stamp>-<n> from origin/working
#   agent   the hook named by JAWNOS_CODING_AGENT or __president/qa_coding_agent,
#           run with cwd = the worktree and JAWNOS_NOTE_ID/TITLE/TEXT in its env
#   suite   qa/run.pl --source worktree --root <root>/nightly --layers l0,l1
#           (+ l2,l3 when the change touches templates, JS or perl routes)
#   green   version bump, one commit, push the branch to the configured push
#           target, then queue it on the working trunk with
#           scripts/land_enqueue.pl --trunk working --wait. Exit 0 landed:
#           mark the note completed through POST /manager/note_save and file a
#           Handbook report note (category journal). Exit 1 refused or 2 no
#           verdict: the worktree and branch stay and the note stays open. It
#           never merges main, pushes main or restarts the house; the landing
#           coordinator moves the trunk and the weekly promotion restarts.
#
# A red suite goes back to the same agent in the same worktree with the failing
# lines and a bounded tail of the log, up to --repair-attempts times (default 2).
# Still red after that stops the night: the worktree stays for inspection, the
# branch is detached and deleted, the note stays open, and the report names the
# failure. With no agent configured the run exits 3 before it fetches, adds a worktree or
# creates a branch. There is no live SQL here except the read-only SQLite URI;
# the one live write is the app's own note_save route.
#
# Teardown never runs the manager killer and never asks a QA tree for a
# graceful shutdown: a bound process is SIGKILLed. The coding night itself
# never restarts the house; only the landing promotion does.

use strict;
use warnings;

# A systemd unit exports no PERL5LIB. Find the user's local::lib the way ./jawn
# does, before Mojo (for the note_save POST) is needed.
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
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/lib";

use Cwd qw(abs_path);
use Fcntl qw(:flock);
use File::Path qw(make_path);
use File::Copy qw(copy);
use File::Spec;
use JSON::PP;
use POSIX ();
use Time::HiRes qw(time sleep);

require CodingContext;
require CodingNight;
require QaSetting;

my %opt = (
	dry_run       => 0,
	limit         => undef,
	repo          => undef,
	root          => undef,
	db            => undef,
	stamp         => undef,
	agent         => undef,
	ticket        => undef,
	live_url      => undef,
	suite_timeout => 3600,
	repair_attempts => 2,
	ignore_device => 0,
	lanes         => undef,
);
my @argv = @ARGV;
while (my $arg = shift @argv) {
	if ($arg eq '--dry-run')      { $opt{'dry_run'} = 1; next }
	if ($arg eq '--ignore-device'){ $opt{'ignore_device'} = 1; next }
	if ($arg eq '--lanes')        { $opt{'lanes'} = shift @argv; next }
	if ($arg =~ /^--lanes=(.*)$/) { $opt{'lanes'} = $1; next }
	if ($arg eq '--limit')        { $opt{'limit'} = shift @argv; next }
	if ($arg =~ /^--limit=(.*)$/) { $opt{'limit'} = $1; next }
	if ($arg eq '--repo')         { $opt{'repo'} = shift @argv; next }
	if ($arg =~ /^--repo=(.*)$/)  { $opt{'repo'} = $1; next }
	if ($arg eq '--root')         { $opt{'root'} = shift @argv; next }
	if ($arg =~ /^--root=(.*)$/)  { $opt{'root'} = $1; next }
	if ($arg eq '--db')           { $opt{'db'} = shift @argv; next }
	if ($arg =~ /^--db=(.*)$/)    { $opt{'db'} = $1; next }
	if ($arg eq '--stamp')        { $opt{'stamp'} = shift @argv; next }
	if ($arg =~ /^--stamp=(.*)$/) { $opt{'stamp'} = $1; next }
	if ($arg eq '--agent')        { $opt{'agent'} = shift @argv; next }
	if ($arg =~ /^--agent=(.*)$/) { $opt{'agent'} = $1; next }
	if ($arg eq '--ticket')       { $opt{'ticket'} = shift @argv // ''; next }
	if ($arg =~ /^--ticket=(.*)$/){ $opt{'ticket'} = $1; next }
	if ($arg eq '--live-url')     { $opt{'live_url'} = shift @argv // ''; next }
	if ($arg =~ /^--live-url=(.*)$/) { $opt{'live_url'} = $1; next }
	# Accepted for older units and a hand run; the night no longer restarts
	# the house or probes a health route, so the value is read and ignored.
	if ($arg eq '--health-url' || $arg eq '--health-wait') { shift @argv; next }
	if ($arg =~ /^--health-(?:url|wait)=/) { next }
	if ($arg eq '--suite-timeout'){ $opt{'suite_timeout'} = shift @argv // 3600; next }
	if ($arg =~ /^--suite-timeout=(.*)$/) { $opt{'suite_timeout'} = $1; next }
	if ($arg eq '--repair-attempts') { $opt{'repair_attempts'} = shift @argv; next }
	if ($arg =~ /^--repair-attempts=(.*)$/) { $opt{'repair_attempts'} = $1; next }
	if ($arg eq '--help' || $arg eq '-h') { usage(); exit 0 }
	die "qa/coding_night: unknown argument: $arg\n";
}

# A repair is an extra agent run plus an extra suite, so it is bounded hard.
# Anything outside 0..3 is a usage error, not a silent fallback to the default.
{
	my $n = $opt{'repair_attempts'};
	$n = '' unless defined $n;
	$n =~ s/^\s+|\s+$//g;
	unless ($n =~ /^\d+$/ && $n <= 3) {
		print STDERR "qa/coding_night: --repair-attempts must be 0, 1, 2 or 3\n";
		exit 2;
	}
	$opt{'repair_attempts'} = $n;
}

my $here = abs_path(__FILE__) || __FILE__;
$opt{'repo'} ||= abs_path( dirname($here) . '/../..' );
my $repo = abs_path( $opt{'repo'} ) || $opt{'repo'};
die "qa/coding_night: no JawnOS checkout at $repo\n" unless -d "$repo/qa";
die "qa/coding_night: $repo is not a git checkout\n" unless -d "$repo/.git";

my $root = $opt{'root'};
$root = $ENV{'JAWNOS_QA_ROOT'} unless defined $root && length $root;
$root = $ENV{'QA_ROOT'} unless defined $root && length $root;
$root = (($ENV{'HOME'} || '') . '/jawnos-qa') unless defined $root && length $root;
$root = abs_path($root) || $root;
my $db = $opt{'db'} || "$repo/database/jawnos.db";
my $stamp = $opt{'stamp'}
	|| POSIX::strftime('%Y%m%d-%H%M%S', localtime);

# --- the gate ---------------------------------------------------------------
# systemd already carries ExecCondition, but a hand-started run must honour the
# same choice before it reads anything or touches a branch. Exit 0 is a skip,
# not a failure.
unless ($opt{'ignore_device'}) {
	my $gate = "$repo/qa/device_target.pl";
	if (-f $gate) {
		my ($rc) = run_cmd(cmd => [$^X, $gate], cwd => $repo);
		if ($rc != 0) {
			print "qa/coding_night: this is not the chosen nightly machine; nothing to do\n";
			exit 0;
		}
	}
}

# The note limit is read after the gate so an unchosen machine does no work at
# all. `--limit` is the override; both go through the same 1..25 clamp.
my $limit = defined $opt{'limit'}
	? QaSetting::clamp_note_limit($opt{'limit'})
	: QaSetting::read_note_limit($db);

# The lanes are read after the gate too: an unchosen machine does no work.
# The panel and this reader share one rule (QaSetting), so a hand-made POST
# cannot add a source this runner does not know.
my @lanes = defined $opt{'lanes'}
	? QaSetting::clamp_coding_lanes($opt{'lanes'})
	: QaSetting::read_coding_lanes($db);

# --- the agent hook ---------------------------------------------------------
my $agent_line = defined $opt{'agent'} ? $opt{'agent'} : $ENV{'JAWNOS_CODING_AGENT'};
# The in-tree agent is the default hook, so a configured model is enough.
$agent_line = "$^X $FindBin::Bin/agent.pl" unless defined $opt{'agent'} || (defined $agent_line && length $agent_line);
$agent_line = QaSetting::read_coding_agent($db)
	unless defined $opt{'agent'} || (defined $agent_line && length $agent_line);
my $agent = CodingNight::agent_command($agent_line);

# --- the plan ---------------------------------------------------------------
my $queue = eval {
	CodingNight::select_queue($db,
		lanes => \@lanes, limit => $limit, qa_root => $root, lane_max => 2);
};
my $note_error = $@;
$queue = [] unless ref $queue eq 'ARRAY';

if ($opt{'dry_run'}) {
	print "qa/coding_night dry run - nothing is fetched, created, pushed or posted\n";
	print "  repo: $repo\n";
	print "  database: $db (read-only)\n";
	print "  notes per night: $limit\n";
	print '  lanes: ' . join(',', @lanes) . "\n";
	print "  agent: " . (($agent_line // '') =~ /\S/ ? $agent_line : 'NONE - the 06:00 run would exit 3') . "\n";
	if ($note_error) {
		print "  queue: could not be read: $note_error";
		exit 0;
	}
	print '  queue: ' . scalar(@{$queue}) . " item(s)\n";
	my $n = 0;
	for my $note ( @{$queue} ) {
		$n++;
		my $app   = (($note->{'source'} || 'notes') eq 'notes') && CodingNight::is_app_note($note);
		my $paths = $app
			? CodingNight::plan_app_paths($root, $stamp, $n)
			: CodingNight::plan_paths($root, $stamp, $n);
		print '    ' . $n . '. [' . $note->{'id'} . '] (' . ($note->{'source'} || 'notes') . ') ' . $note->{'title'} . "\n";
		print '       lane:     ' . ($app ? 'app (' . CodingNight::app_repo_dir() . ')' : 'repo') . "\n";
		print '       worktree: ' . $paths->{'worktree'} . "\n";
		print '       branch:   ' . $paths->{'branch'} . "\n";
	}
	print "  report would be: $root/coding/$stamp/report.json\n";
	exit 0;
}

# No agent is a skip with a distinct code, before anything is fetched or a
# branch exists. Silence must never look like a night's work.
unless ($agent) {
	print STDERR "qa/coding_night: no coding agent configured; set JAWNOS_CODING_AGENT"
		. " or __president/qa_coding_agent. Nothing was fetched, created or pushed.\n";
	exit 3;
}
die "qa/coding_night: the note queue could not be read: $note_error" if $note_error;

# --- one run at a time ------------------------------------------------------
make_path($root);
my $lock_path = "$root/.coding-night.lock";
open(my $lock, '>>', $lock_path) or die "qa/coding_night: $lock_path: $!\n";
unless (flock($lock, LOCK_EX | LOCK_NB)) {
	print "qa/coding_night: another run holds $lock_path; nothing to do\n";
	exit 0;
}

my $report_dir = "$root/coding/$stamp";
make_path($report_dir);
my $report = {
	schema    => 1,
	generated => POSIX::strftime('%Y-%m-%dT%H:%M:%S%z', localtime),
	source    => 'qa/coding_night/run.pl',
	stamp     => $stamp,
	repo      => $repo,
	root      => $root,
	limit     => $limit,
	agent     => ($agent_line // ''),
	dry_run   => 0,
	notes     => scalar(@{$queue}),
	lanes     => [ @lanes ],
	sources   => { map { my $lane = $_; ($lane => scalar(grep { ($_->{'source'} || 'notes') eq $lane } @{$queue})) } @lanes },
	runs      => [],
};
{
	my $preview = CodingNight::push_target($db, 'repo');
	$report->{'push_repo'} = {
		setting   => $preview->{'setting'},
		value     => $preview->{'value'},
		effective => $preview->{'effective'},
		ok        => $preview->{'ok'},
	};
}

print 'JawnOS coding nightly ' . $stamp . ' - ' . scalar(@{$queue}) . ' item(s) ['
	. join(',', @lanes) . "], limit $limit\n";

my $failed = 0;
my $n = 0;
for my $note ( @{$queue} ) {
	$n++;
	my $is_note = (($note->{'source'} || 'notes') eq 'notes');
	my $paths = CodingNight::plan_paths($root, $stamp, $n);
	my $worktree = $paths->{'worktree'};
	my $branch   = $paths->{'branch'};
	my $log      = sub { "$report_dir/note-$n-$_[0].log" };
	my %run = (
		n         => $n,
		note_id   => $note->{'id'},
		source    => ($note->{'source'} || 'notes'),
		title     => $note->{'title'},
		branch    => $branch,
		worktree  => $worktree,
		status    => 'pending',
		agent_exit   => undef,
		suite_exit   => undef,
		repair_attempts => 0,
		repair_exits    => [],
		repair_suite_exits => [],
		layers       => 'l0,l1',
		pushed       => 0,
		land_exit    => undef,
		land_verdict => '',
		landed       => 0,
		marked_completed => 0,
		handbook_filed   => 0,
		push_target      => '',
		failure_note_filed => 0,
	);
	push @{$report->{'runs'}}, \%run;

	print '  [' . $n . '] ' . $note->{'title'} . "\n";

	# --- the app lane -----------------------------------------------------
	# An Android note is built, committed and published in the app checkout.
	# Nothing in this repository's tree is touched: no fetch, no suite, no
	# restart. The app checkout itself may hold another agent's WIP, so every
	# write happens in the worktree and the checkout is only fast-forwarded when
	# it is clean and already on the base branch.
	if ($is_note && CodingNight::is_app_note($note)) {
		my $app = CodingNight::app_repo_dir();
		my $app_paths = CodingNight::plan_app_paths($root, $stamp, $n);
		$worktree = $app_paths->{'worktree'};
		$branch   = $app_paths->{'branch'};
		$run{'lane'}      = 'app';
		$run{'app_repo'}  = $app;
		$run{'worktree'}  = $worktree;
		$run{'branch'}    = $branch;
		$run{'layers'}    = 'app';
		$run{'staged'}    = 0;
		$run{'publish'}   = 'not attempted';
		$run{'ff_jawnos'} = 0;

		unless (defined $app && -d "$app/.git") {
			$run{'status'} = 'app_repo_missing';
			$run{'error'}  = 'no Android app checkout at ' . ($app // '(unset)')
				. ' (set JAWNOS_APP_DIR)'; 
			$failed = 1;
			last;
		}

		# Where this lane pushes. A fork named in Configure -> Dev replaces the
		# checkout's `fork` remote for both the nightly branch and jawnos; an
		# unreachable or unauthenticated target stops the night before any build,
		# merge or stage.
		my $app_push = CodingNight::push_target($db, 'app');
		$run{'push_target'} = $app_push->{'effective'};
		unless ($app_push->{'ok'}) {
			$run{'status'} = 'push_target_invalid';
			$run{'error'}  = 'the configured app push repo is not valid: ' . ($app_push->{'error'} // 'unknown');
			$failed = 1;
			last;
		}
		my ($app_reach_rc) = run_cmd(
			cmd => ['git', 'ls-remote', $app_push->{'target'}],
			cwd => $app, log => $log->('push-check'), timeout => 60);
		if ($app_reach_rc != 0) {
			$run{'status'} = 'push_target_unreachable';
			$run{'error'}  = 'the app push target ' . $app_push->{'target'}
				. " is unreachable or unauthenticated (exit $app_reach_rc); nothing was built, merged or staged";
			$failed = 1;
			last;
		}
		if (-e $worktree) {
			$run{'status'} = 'name_clash';
			$run{'error'}  = "the worktree $worktree already exists; nothing was overwritten";
			$failed = 1;
			last;
		}

		my ($wt_rc) = run_cmd(
			cmd => ['git', 'worktree', 'add', $worktree, '-b', $branch, CodingNight::app_base_branch()],
			cwd => $app, log => $log->('worktree'));
		if ($wt_rc != 0) {
			$run{'status'} = 'worktree_failed';
			$run{'error'}  = "git worktree add failed in the app checkout (exit $wt_rc); see " . $log->('worktree');
			$failed = 1;
			last;
		}

		# The agent's context is the app checkout, not this repository: its
		# AGENTS.md is the rulebook for an APK change.
		my %app_env = (%{ CodingNight::note_env($note) }, %{ CodingNight::app_lane_env($app) });
		my ($agent_rc) = run_cmd(
			cmd     => $agent,
			cwd     => $worktree,
			env     => \%app_env,
			log     => $log->('agent'),
			timeout => $opt{'suite_timeout'},
		);
		$run{'agent_exit'} = $agent_rc;
		record_agent_accounting(\%run, $log->('agent'));
		if ($agent_rc != 0) {
			$run{'status'} = 'agent_failed';
			$run{'error'}  = "the coding agent exited $agent_rc; the app worktree is left for inspection";
			$failed = 1;
			last;
		}

		my @app_files = changed_files($worktree, CodingNight::app_base_branch());
		if (!@app_files) {
			$run{'status'} = 'no_change';
			$run{'error'}  = 'the agent exited 0 but left no change; the note stays open';
			run_cmd(cmd => ['git', 'worktree', 'remove', '--force', $worktree], cwd => $app, log => $log->('cleanup'));
			run_cmd(cmd => ['git', 'branch', '-D', $branch], cwd => $app, log => $log->('cleanup'));
			next;
		}

		# 1. the build is the gate. A failed build has bumped nothing, committed
		# nothing, pushed nothing and staged nothing.
		# A fresh worktree has no local.properties (the SDK path is untracked),
		# so Gradle would not find the SDK at all. Carry the checkout's copy in;
		# the file is build configuration, not source, and stays out of the commit.
		{
			my $from = File::Spec->catfile($app, 'local.properties');
			my $to   = File::Spec->catfile($worktree, 'local.properties');
			if (-f $from && !-f $to) {
				copy($from, $to) or warn "qa/coding_night: local.properties: $!\n";
			}
		}

		my $build_env = { JAVA_HOME => CodingNight::app_java_home() };
		my ($build_rc) = run_cmd(
			cmd     => CodingNight::app_build_command(),
			cwd     => $worktree,
			env     => $build_env,
			log     => $log->('gradle'),
			timeout => $opt{'suite_timeout'},
		);
		$run{'build_exit'} = $build_rc;

		# The build is this lane's suite, so a red build gets the same repair
		# turns: the same worktree goes back to the agent with the compiler's
		# errors and a bounded tail of the Gradle log. A bad build has bumped,
		# committed, pushed and staged nothing, so trying again in place is safe.
		my @repair_exits;
		my @repair_build_exits;
		my $repair = 0;
		while ($build_rc != 0 && $repair < $opt{'repair_attempts'}) {
			$repair++;
			my $gradle_log = $log->('gradle');
			my $repair_note = CodingNight::repair_note(
				note    => $note,
				attempt => $repair,
				max     => $opt{'repair_attempts'},
				failing => build_failure_lines($gradle_log),
				tail    => log_tail($gradle_log),
			);
			print '  app repair ' . $repair . ' of ' . $opt{'repair_attempts'}
				. ": the build was red; asking the same agent again\n";
			my %repair_env = (
				%{ CodingNight::note_env($repair_note) },
				%{ CodingNight::app_lane_env($app) },
			);
			my ($repair_rc) = run_cmd(
				cmd     => $agent,
				cwd     => $worktree,
				env     => \%repair_env,
				log     => $log->("agent-repair-$repair"),
				timeout => $opt{'suite_timeout'},
			);
			push @repair_exits, $repair_rc;
			record_agent_accounting(\%run, $log->("agent-repair-$repair"));
			# An agent that cannot run is not a repair: stop and report the build.
			last if $repair_rc != 0;

			@app_files = changed_files($worktree, CodingNight::app_base_branch());
			($build_rc) = run_cmd(
				cmd     => CodingNight::app_build_command(),
				cwd     => $worktree,
				env     => $build_env,
				log     => $log->("gradle-repair-$repair"),
				timeout => $opt{'suite_timeout'},
			);
			push @repair_build_exits, $build_rc;
			$run{'build_exit'} = $build_rc;
		}
		$run{'repair_attempts'}    = scalar @repair_exits;
		$run{'repair_exits'}       = \@repair_exits;
		$run{'repair_suite_exits'} = \@repair_build_exits;

		if ($build_rc != 0) {
			$run{'status'} = 'build_failed';
			$run{'error'}  = "the Gradle build failed (exit $build_rc)"
				. (@repair_exits ? ' after ' . scalar(@repair_exits) . ' repair attempt(s)' : '')
				. '; no bump, push or stage was made; see ' . $log->('gradle');
			$failed = 1;
			last;
		}

		if (!@app_files) {
			# A repair can undo the only change; a green build of nothing is not work.
			$run{'status'} = 'no_change';
			$run{'error'}  = 'the build was green but the worktree has no change; the note stays open';
			run_cmd(cmd => ['git', 'worktree', 'remove', '--force', $worktree], cwd => $app, log => $log->('cleanup'));
			run_cmd(cmd => ['git', 'branch', '-D', $branch], cwd => $app, log => $log->('cleanup'));
			next;
		}

		# 2. only a green build earns the version bump, and the bumped version is
		# then built again so the APK carries it.
		my ($version, $bump_error) = CodingNight::bump_app_version($worktree);
		if (!$version) {
			$run{'status'} = 'bump_failed';
			$run{'error'}  = 'the app version could not be bumped: ' . ($bump_error // 'unknown reason');
			$failed = 1;
			last;
		}
		$run{'app_version_code'} = $version->{'versionCode'};
		$run{'app_version_name'} = $version->{'versionName'};
		my ($rebuild_rc) = run_cmd(
			cmd     => CodingNight::app_build_command(),
			cwd     => $worktree,
			env     => $build_env,
			log     => $log->('gradle'),
			timeout => $opt{'suite_timeout'},
		);
		if ($rebuild_rc != 0) {
			$run{'status'} = 'build_failed';
			$run{'error'}  = "the rebuild after the version bump failed (exit $rebuild_rc); nothing was committed";
			$failed = 1;
			last;
		}

		my $subject = 'v' . $version->{'versionName'} . ' - '
			. ($note->{'title'} || 'nightly note');
		my ($add_rc) = run_cmd(cmd => ['git', 'add', '-A'], cwd => $worktree, log => $log->('commit'));
		my ($commit_rc) = run_cmd(cmd => ['git', 'commit', '-m', $subject], cwd => $worktree, log => $log->('commit'));
		if ($add_rc != 0 || $commit_rc != 0) {
			$run{'status'} = 'commit_failed';
			$run{'error'}  = "the app commit failed (exit $commit_rc); the worktree is left";
			$failed = 1;
			last;
		}
		$run{'commit'} = $subject;

		my ($push_rc) = run_cmd(
			cmd => ['git', 'push', '-u', $app_push->{'target'}, $branch],
			cwd => $worktree, log => $log->('push'));
		if ($push_rc != 0) {
			$run{'status'} = 'push_failed';
			$run{'error'}  = "git push of $branch to " . $app_push->{'target'}
				. " failed (exit $push_rc); nothing was staged";
			$failed = 1;
			last;
		}
		$run{'pushed'} = 1;

		# 3. Fast-forward the app checkout's jawnos branch - but only when that
		# checkout is clean and already on it. A dirty checkout is another agent's
		# work and is never merged, reset or committed around.
		my $app_status = capture($app, 'git', 'status', '--porcelain');
		my $app_branch = capture($app, 'git', 'rev-parse', '--abbrev-ref', 'HEAD');
		$app_branch =~ s/\s+//g;
		if ($app_status =~ /\S/ || $app_branch ne CodingNight::app_base_branch()) {
			$run{'warning'} = 'the app checkout is not clean on '
				. CodingNight::app_base_branch()
				. '; it was left untouched and jawnos was not fast-forwarded';
			print '  app checkout has uncommitted work or is off '
				. CodingNight::app_base_branch() . "; jawnos was not fast-forwarded\n";
		}
		else {
			my ($ff_rc) = run_cmd(cmd => ['git', 'merge', '--ff-only', $branch],
				cwd => $app, log => $log->('ff'));
			if ($ff_rc != 0) {
				$run{'status'} = 'merge_failed';
				$run{'error'}  = "jawnos did not fast-forward to $branch (exit $ff_rc); the branch is pushed and left";
				$failed = 1;
				last;
			}
			$run{'ff_jawnos'} = 1;
			my ($push_jawnos_rc) = run_cmd(
				cmd => ['git', 'push', $app_push->{'target'}, CodingNight::app_base_branch()],
				cwd => $app, log => $log->('push-jawnos'));
			if ($push_jawnos_rc != 0) {
				$run{'status'} = 'push_failed';
				$run{'error'}  = 'jawnos was fast-forwarded but pushing it to '
					. $app_push->{'target'} . " failed (exit $push_jawnos_rc); nothing was staged";
				$failed = 1;
				last;
			}
			$run{'jawnos_pushed'} = 1;
		}

		# 4. stage, then publish if gh is authenticated. A skipped publish is
		# reported as skipped; it is never called published.
		my $apk = CodingNight::app_apk($worktree);
		if (!$apk) {
			$run{'status'} = 'apk_missing';
			$run{'error'}  = 'the build finished but no app/build/outputs/apk/*/*.apk was found';
			$failed = 1;
			last;
		}
		$run{'apk'} = $apk;

		# The staged APKs are gitignored blobs, so a bad stage or publish cannot be
		# undone with git. Copy them (and the manifest) before either script runs.
		my $release_backup = CodingNight::releases_backup($repo, "$report_dir/releases-$n");
		if (!$release_backup->{'ok'}) {
			$run{'status'} = 'backup_failed';
			$run{'error'}  = 'the release backup failed before staging: ' . ($release_backup->{'error'} // 'unknown');
			$failed = 1;
			last;
		}
		$run{'releases_backup'} = $release_backup->{'dir'};

		my ($stage_rc) = run_cmd(
			cmd => [$^X, "$repo/scripts/app_release.pl", $apk],
			cwd => $repo, log => $log->('stage'));
		if ($stage_rc != 0) {
			my $restore = CodingNight::releases_restore($repo, $release_backup);
			$run{'releases_restored'} = $restore->{'ok'} ? 1 : 0;
			$run{'status'} = 'stage_failed';
			$run{'error'}  = "scripts/app_release.pl failed (exit $stage_rc); the staged APKs were "
				. ($restore->{'ok'} ? 'restored' : 'NOT restored: ' . ($restore->{'error'} // 'unknown'))
				. ' and the note stays open';
			$failed = 1;
			last;
		}
		$run{'staged'} = 1;

		my ($auth_rc) = run_cmd(cmd => ['gh', 'auth', 'status'], cwd => $repo, log => $log->('gh-auth'));
		if ($auth_rc == 0) {
			my @publish = ($^X, "$repo/scripts/app_publish.pl");
			push @publish, '--repo', $app_push->{'slug'} if length $app_push->{'slug'};
			my ($publish_rc) = run_cmd(
				cmd => \@publish,
				cwd => $repo, log => $log->('publish'));
			if ($publish_rc != 0) {
				my $restore = CodingNight::releases_restore($repo, $release_backup);
				$run{'releases_restored'} = $restore->{'ok'} ? 1 : 0;
				$run{'status'}  = 'publish_failed';
				$run{'publish'} = 'failed';
				$run{'error'}   = "scripts/app_publish.pl failed (exit $publish_rc); the staged APKs were "
					. ($restore->{'ok'} ? 'restored' : 'NOT restored: ' . ($restore->{'error'} // 'unknown'));
				$failed = 1;
				last;
			}
			$run{'publish'} = 'published';
		}
		else {
			$run{'publish'} = 'skipped (no gh auth)';
			print "  publish: skipped (no gh auth)\n";
		}

		# 5. the work shipped to the app branch and was staged/published, so the
		# note is complete. There is no manager restart: the APK is not this
		# process.
		my $res = eval {
			mark_note_completed(
				note_id => $note->{'id'},
				live_url => live_url($repo, $opt{'live_url'}),
				ticket   => ticket_url($repo, $opt{'ticket'}),
			);
		};
		if (!$res) {
			$run{'status'} = 'mark_failed';
			$run{'error'}  = 'the app work shipped but the note could not be marked completed: '
				. ($@ || 'unknown');
			$failed = 1;
			last;
		}
		$run{'marked_completed'} = 1;
		$run{'status'} = 'green';

		my $md = CodingNight::report_markdown({ %{$report}, runs => [ \%run ], ok => 1 })
			. context_md([ \%run ]);
		my $filed = eval {
			post_note(
				live_url => live_url($repo, $opt{'live_url'}),
				ticket   => ticket_url($repo, $opt{'ticket'}),
				text     => $md,
				category => 'journal',
			);
		};
		$run{'handbook_filed'} = $filed ? 1 : 0;

		run_cmd(cmd => ['git', 'worktree', 'remove', '--force', $worktree], cwd => $app, log => $log->('cleanup'));
		run_cmd(cmd => ['git', 'branch', '-d', $branch], cwd => $app, log => $log->('cleanup'));
		next;
	}

	# 1. fetch, then a fresh worktree from origin/working. Agents branch from
	# the working trunk, not main: main moves only on a release, so a night
	# based on it tests stale code and lands against the wrong tip.
	my ($fetch_rc) = run_cmd(cmd => ['git', 'fetch', 'origin'], cwd => $repo, log => $log->('fetch'));
	if ($fetch_rc != 0) {
		$run{'status'} = 'fetch_failed';
		$run{'error'} = "git fetch failed (exit $fetch_rc); see " . $log->('fetch');
		$failed = 1;
		last;
	}

	if (-e $worktree) {
		$run{'status'} = 'name_clash';
		$run{'error'} = "the worktree $worktree already exists; nothing was overwritten";
		$failed = 1;
		last;
	}
	my ($wt_rc) = run_cmd(
		cmd => ['git', 'worktree', 'add', $worktree, '-b', $branch, 'origin/working'],
		cwd => $repo, log => $log->('worktree'));
	if ($wt_rc != 0) {
		$run{'status'} = 'worktree_failed';
		$run{'error'} = "git worktree add failed (exit $wt_rc); see " . $log->('worktree');
		$failed = 1;
		last;
	}

	# 2. the agent, inside the worktree, with the note in its environment
	my ($agent_rc) = run_cmd(
		cmd   => $agent,
		cwd   => $worktree,
		env   => CodingNight::note_env($note),
		log   => $log->('agent'),
		timeout => $opt{'suite_timeout'},
	);
	$run{'agent_exit'} = $agent_rc;
	record_agent_accounting(\%run, $log->('agent'));
	if ($agent_rc != 0) {
		$run{'status'} = 'agent_failed';
		$run{'error'} = "the coding agent exited $agent_rc; the worktree is left for inspection";
		abandon_branch($repo, $worktree, $branch);
		$failed = 1;
		last;
	}

	my @files = changed_files($worktree);
	my $layers = CodingNight::layers_for_files(\@files);
	$run{'layers'} = $layers;

	# 3. the suite, inside the worktree, on the worktree's own copy. It runs
	# whenever the agent returned 0, even if the change list looks empty - a
	# green no-change night is a decision made after the suite, not instead of it.
	my ($suite_rc) = run_cmd(
		cmd => [$^X, "$worktree/qa/run.pl", '--source', 'worktree',
			'--root', "$root/nightly", '--layers', $layers],
		cwd     => $worktree,
		log     => $log->('suite'),
		timeout => $opt{'suite_timeout'},
	);
	$run{'suite_exit'} = $suite_rc;
	$run{'suite_log'} = $log->('suite');

	# A red suite is a repair, not yet a verdict. The agent gets the same
	# worktree back with the failing lines and a bounded tail of the log, so it
	# fixes its own change instead of starting over. Each attempt is built from
	# the ORIGINAL note text, never the previous attempt's, so the failure block
	# cannot snowball across retries.
	my @repair_exits;
	my @repair_suite_exits;
	my $repair = 0;
	while ($suite_rc != 0 && $repair < $opt{'repair_attempts'}) {
		$repair++;
		my $repair_note = CodingNight::repair_note(
			note    => $note,
			attempt => $repair,
			max     => $opt{'repair_attempts'},
			failing => failure_lines($run{'suite_log'}),
			tail    => log_tail($run{'suite_log'}),
		);
		print '  repair ' . $repair . ' of ' . $opt{'repair_attempts'}
			. ": the suite was red; asking the same agent again\n";
		my ($repair_rc) = run_cmd(
			cmd     => $agent,
			cwd     => $worktree,
			env     => CodingNight::note_env($repair_note),
			log     => $log->("agent-repair-$repair"),
			timeout => $opt{'suite_timeout'},
		);
		push @repair_exits, $repair_rc;
		record_agent_accounting(\%run, $log->("agent-repair-$repair"));
		# An agent that cannot run is not a repair: stop and leave today's red
		# handling to report it, rather than retrying a broken hook twice.
		last if $repair_rc != 0;

		# The repair may touch a template or JS file the first pass did not, so
		# the layers are chosen again from the current change list.
		@files  = changed_files($worktree);
		$layers = CodingNight::layers_for_files(\@files);
		$run{'layers'} = $layers;
		($suite_rc) = run_cmd(
			cmd => [$^X, "$worktree/qa/run.pl", '--source', 'worktree',
				'--root', "$root/nightly", '--layers', $layers],
			cwd     => $worktree,
			log     => $log->("suite-repair-$repair"),
			timeout => $opt{'suite_timeout'},
		);
		push @repair_suite_exits, $suite_rc;
		$run{'suite_exit'} = $suite_rc;
		$run{'suite_log'}  = $log->("suite-repair-$repair");
	}
	$run{'repair_attempts'}    = scalar @repair_exits;
	$run{'repair_exits'}       = \@repair_exits;
	$run{'repair_suite_exits'} = \@repair_suite_exits;

	if ($suite_rc != 0) {
		$run{'status'} = 'red';
		$run{'error'} = "the suite failed (exit $suite_rc, layers $layers)";
		$run{'error'} .= ' after ' . scalar(@repair_exits) . ' repair attempt(s)' if @repair_exits;
		$run{'error'} .= '; the worktree is left for inspection';
		abandon_branch($repo, $worktree, $branch);
		$failed = 1;
		last;
	}

	if (!@files) {
		# A green agent that changed nothing did no work: the note stays open,
		# and the empty worktree is not worth keeping.
		$run{'status'} = 'no_change';
		$run{'error'} = 'the agent exited 0 but left no change; the note stays open';
		run_cmd(cmd => ['git', 'worktree', 'remove', '--force', $worktree], cwd => $repo, log => $log->('cleanup'));
		run_cmd(cmd => ['git', 'branch', '-D', $branch], cwd => $repo, log => $log->('cleanup'));
		next;
	}

	# 4. green: the push target is checked before anything is pushed. A fork
	# named in Configure -> Dev receives the nightly branch; the landing queue
	# backs it up to origin itself. An unreachable or unauthenticated target
	# stops the night here, with the trunk untouched and the note open.
	my $push = CodingNight::push_target($db, 'repo');
	$run{'push_target'} = $push->{'effective'};
	unless ($push->{'ok'}) {
		$run{'status'} = 'push_target_invalid';
		$run{'error'} = 'the configured coding push repo is not valid: ' . ($push->{'error'} // 'unknown');
		$failed = 1;
		last;
	}
	my ($reach_rc) = run_cmd(
		cmd => ['git', 'ls-remote', $push->{'target'}],
		cwd => $repo, log => $log->('push-check'), timeout => 60);
	if ($reach_rc != 0) {
		$run{'status'} = 'push_target_unreachable';
		$run{'error'} = 'the push target ' . $push->{'target'}
			. " is unreachable or unauthenticated (exit $reach_rc); nothing was pushed";
		$failed = 1;
		last;
	}

	# 5. green: bump, commit, push the branch, then queue it on the working
	# trunk. The night never merges main, pushes main or restarts the house: the
	# coordinator lands the branch and the weekly promotion restarts.
	my ($bump_rc) = run_cmd(cmd => [$^X, 'scripts/version_bump.pl'], cwd => $worktree, log => $log->('bump'));
	if ($bump_rc != 0) {
		$run{'status'} = 'bump_failed';
		$run{'error'} = "scripts/version_bump.pl failed (exit $bump_rc)";
		$failed = 1;
		last;
	}
	my $version = capture($worktree, 'cat', 'VERSION');
	$version =~ s/\s+//g;
	unless ($version =~ /^\d+\.\d+\.\d+/) {
		$run{'status'} = 'bump_failed';
		$run{'error'} = 'VERSION did not read as a version after the bump';
		$failed = 1;
		last;
	}
	my $subject = "v$version - " . ($note->{'title'} || 'nightly note');
	my ($add_rc) = run_cmd(cmd => ['git', 'add', '-A'], cwd => $worktree, log => $log->('commit'));
	my ($commit_rc) = run_cmd(cmd => ['git', 'commit', '-m', $subject], cwd => $worktree, log => $log->('commit'));
	if ($add_rc != 0 || $commit_rc != 0) {
		$run{'status'} = 'commit_failed';
		$run{'error'} = "the commit failed (exit $commit_rc); the worktree is left";
		$failed = 1;
		last;
	}
	$run{'version'} = $version;
	$run{'commit'} = $subject;

	my ($push_rc) = run_cmd(cmd => ['git', 'push', '-u', $push->{'target'}, $branch], cwd => $worktree, log => $log->('push'));
	if ($push_rc != 0) {
		$run{'status'} = 'push_failed';
		$run{'error'} = "git push of $branch to " . $push->{'target'}
			. " failed (exit $push_rc); the branch and the note stay as they were";
		$failed = 1;
		last;
	}
	$run{'pushed'} = 1;

	# The landing queue is the contract: exit 0 landed, 1 refused, 2 no verdict.
	# It backs the branch up to origin and waits for the coordinator in this
	# turn. The worktree belongs to the ticket until that verdict.
	my $land_log = $log->('land');
	my ($land_rc) = run_cmd(
		cmd     => [$^X, "$worktree/scripts/land_enqueue.pl", '--trunk', 'working', '--wait'],
		cwd     => $worktree,
		log     => $land_log,
		timeout => 900,
	);
	$run{'land_exit'}    = $land_rc;
	$run{'land_verdict'} = land_verdict($land_log);

	if ($land_rc == 1) {
		$run{'status'} = 'land_refused';
		$run{'error'}  = 'the landing queue refused ' . $branch
			. ($run{'land_verdict'} ? ' (' . $run{'land_verdict'} . ')' : '')
			. '; the worktree and branch are left and the note stays open';
		$failed = 1;
		last;
	}
	if ($land_rc != 0) {
		$run{'status'} = 'land_timeout';
		$run{'error'}  = 'the landing queue gave no verdict for ' . $branch
			. ($run{'land_verdict'} ? ' (' . $run{'land_verdict'} . ')' : '')
			. '; the worktree and branch are left and the note stays open';
		$failed = 1;
		last;
	}
	$run{'landed'} = 1;

	# The branch landed on the working trunk; the app's own route marks the note
	# completed. A report-derived item (ux, security, installers) has no note
	# row: the next report is what says whether it is still there.
	if ($is_note) {
		my $res = eval {
			mark_note_completed(
				note_id => $note->{'id'},
				live_url => live_url($repo, $opt{'live_url'}),
				ticket   => ticket_url($repo, $opt{'ticket'}),
			);
		};
		if (!$res) {
			$run{'status'} = 'mark_failed';
			$run{'error'} = 'the code landed but the note could not be marked completed: ' . ($@ || 'unknown');
			$failed = 1;
			last;
		}
		$run{'marked_completed'} = 1;
	}
	else {
		$run{'marked_completed'} = 0;
		$run{'completed_by'} = 'report';
	}
	$run{'status'} = 'green';

	# A report note is a journal note, not a JawnOS note: the queue must never
	# consume its own diary of the night.
	my $md = CodingNight::report_markdown({
		%{$report}, runs => [ \%run ], ok => 1,
	}) . context_md([ \%run ]);
	my $filed = eval {
		post_note(
			live_url => live_url($repo, $opt{'live_url'}),
			ticket   => ticket_url($repo, $opt{'ticket'}),
			text     => $md,
			category => 'journal',
		);
	};
	$run{'handbook_filed'} = $filed ? 1 : 0;

	# Landed: the coordinator rebased the branch, so `git branch -d` declines;
	# the commit is on the trunk and the local branch is a stale pointer. Remove
	# the worktree and force-delete only this run's branch.
	run_cmd(cmd => ['git', 'worktree', 'remove', '--force', $worktree], cwd => $repo, log => $log->('cleanup'));
	run_cmd(cmd => ['git', 'branch', '-D', $branch], cwd => $repo, log => $log->('cleanup'));
}

# A failed night is handed over in failure.md and a JawnOS note. A land refusal
# or timeout has already left the worktree and branch for the next person; the
# night never tries to undo a trunk it did not move.
if ($failed && @{$report->{'runs'}}) {
	my $failed_run = $report->{'runs'}->[-1];
	write_failure_md($report_dir, $report, $failed_run, $repo);
	my $body = failure_note_text($report, $failed_run, $report_dir);
	my $filed = eval {
		post_note(
			live_url => live_url($repo, $opt{'live_url'}),
			ticket   => ticket_url($repo, $opt{'ticket'}),
			text     => $body,
			category => 'jawnos',
			status   => 'open',
		);
		1;
	};
	$failed_run->{'failure_note_filed'} = $filed ? 1 : 0;
	print STDERR 'qa/coding_night: the failure note could not be filed: ' . ($@ || 'unknown') . "\n" unless $filed;
}

$report->{'ok'} = !$failed;
$report->{'runs'} ||= [];

my $json_path = "$report_dir/report.json";
open(my $json_fh, '>', $json_path) or die "qa/coding_night: $json_path: $!\n";
print $json_fh JSON::PP->new->canonical->pretty->encode($report);
close $json_fh;

my $md_path = "$report_dir/report.md";
open(my $md_fh, '>', $md_path) or die "qa/coding_night: $md_path: $!\n";
print $md_fh CodingNight::report_markdown($report) . context_md($report->{'runs'});
close $md_fh;

my $green = grep { ($_->{'status'} // '') eq 'green' } @{$report->{'runs'}};

# The panel reads every QA job through reports/<kind>/<stamp>. Write the same
# shape here, with one table row per item, so the coding night sits beside the
# other jobs instead of only in coding/<stamp>/.
{
	my $tsv = "$report_dir/notes.tsv";
	if (open(my $tsv_fh, '>', $tsv)) {
		print {$tsv_fh} "Note\tResult\tStatus\n";
		for my $r ( @{$report->{'runs'}} ) {
			my $note = $r->{'title'} // '';
			$note =~ s/[\t\r\n]+/ /g;
			my $result = $r->{'status'} // 'unknown';
			my $status = $r->{'marked_completed'} ? 'completed'
				: (($r->{'source'} // 'notes') eq 'notes' ? 'open' : 'report');
			print {$tsv_fh} join("\t", $note, $result, $status), "\n";
		}
		close $tsv_fh;
	}
	else {
		print STDERR "qa/coding_night: could not write $tsv: $!\n";
	}
	my @g = gmtime;
	my $utc = sprintf('%04d%02d%02dT%02d%02d%02dZ',
		$g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);
	my $panel_status = $report->{'ok'} ? 'ok' : 'failed';
	my $panel_note = scalar(@{$report->{'runs'}}) . ' item(s), ' . $green . ' green'
		. ($report->{'ok'} ? '' : ', attention needed');
	my ($panel_rc) = run_cmd(
		cmd => [$^X, "$repo/scripts/qa_report.pl",
			'--kind=coding', '--schedule=nightly', "--status=$panel_status",
			'--title=Coding nightly', "--note=$panel_note", "--stamp=$utc",
			"--table=Notes:$tsv", "--root=$root"],
		cwd => $repo, log => "$report_dir/qa-report.log", timeout => 120);
	print STDERR "qa/coding_night: scripts/qa_report.pl exited $panel_rc; the run report is still at $json_path\n"
		if $panel_rc != 0;
}
print 'report: ' . $md_path . "\n";
for my $r ( @{$report->{'runs'}} ) {
	next unless defined $r->{'context_bytes'};
	print 'context: note ' . ($r->{'n'} // '?') . ' - ' . CodingContext::context_summary($r) . "\n";
}
print 'done: ' . scalar(@{$report->{'runs'}}) . " note(s), $green green, "
	. ($failed ? 'attention needed' : 'ok') . "\n";

exit($failed ? 1 : 0);

# ---------------------------------------------------------------------------

sub usage {
	print <<'TEXT';
qa/coding_night/run.pl - the 06:00 coding nightly

  --dry-run         print the plan; fetch, create, push and post nothing
  --limit N         notes this night (clamped 1..25; default the QA panel setting)
  --lanes LIST      what to work on: notes,ux,security,installers (default the QA panel setting)
  --repo DIR        the checkout (default this file's repo)
  --root DIR        QA root (default ~/jawnos-qa)
  --db PATH         live database, read with mode=ro (default <repo>/database/jawnos.db)
  --stamp STAMP     run stamp (default YYYYmmdd-HHMMSS); names branch and worktree
  --agent LINE      the coding agent command (default JAWNOS_CODING_AGENT or the setting)
  --live-url URL    the live manager base for note_save (default config.json working_port)
  --ticket URL      box_office ticket URL (default <repo>/.shots/ticket.txt)
  --suite-timeout S seconds for the agent and the suite (default 3600)
  --repair-attempts N retry a red suite with the same agent (0..3; default 2)
  --ignore-device   skip qa/device_target.pl (a test or an owner's manual run)

A green night pushes its branch and queues it on the working trunk
(scripts/land_enqueue.pl --trunk working --wait); it never merges main or
restarts the house.
TEXT
}

sub dirname {
	my ($path) = @_;
	$path =~ s{/[^/]*$}{};
	return length $path ? $path : '.';
}

# fork + exec, no shell. The child gets its own session, so a bound command can
# be SIGKILLed with everything it spawned (never a graceful QA shutdown).
sub run_cmd {
	my (%a) = @_;
	my @cmd = @{ $a{'cmd'} || [] };
	return (127, 'no command') unless @cmd;
	my $log = $a{'log'};
	my $cwd = $a{'cwd'};
	my $pid = fork();
	return (127, "fork: $!") unless defined $pid;
	if (!$pid) {
		POSIX::setsid();
		if ($log) {
			open(STDOUT, '>', $log) or exit 126;
			open(STDERR, '>&', \*STDOUT) or exit 126;
		}
		else {
			open(STDOUT, '>', '/dev/null') or exit 126;
			open(STDERR, '>&', \*STDOUT) or exit 126;
		}
		chdir $cwd if defined $cwd && length $cwd;
		local %ENV = (%ENV, %{ $a{'env'} || {} });
		exec @cmd;
		exit 127;
	}
	my $deadline = defined $a{'timeout'} ? time + $a{'timeout'} : undef;
	while (1) {
		my $got = waitpid($pid, POSIX::WNOHANG());
		if ($got == $pid) {
			my $st = $?;
			return (($st & 127) ? 128 + ($st & 127) : ($st >> 8), '');
		}
		if ($deadline && time > $deadline) {
			kill 'KILL', -$pid;
			kill 'KILL', $pid;
			waitpid($pid, 0);
			return (124, "timed out after $a{'timeout'}s");
		}
		select undef, undef, undef, 0.05;
	}
}

sub capture {
	my ($cwd, @cmd) = @_;
	my $pid = open(my $fh, '-|');
	return '' unless defined $pid;
	if (!$pid) {
		chdir $cwd if defined $cwd && length $cwd;
		open(STDERR, '>', '/dev/null');
		exec @cmd;
		exit 127;
	}
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return $out;
}

# Uncommitted work the agent left, plus any commits it made on the branch.
# $base defaults to origin/working; the app lane passes jawnos instead.
sub changed_files {
	my ($worktree, $base) = @_;
	$base = 'origin/working' unless defined $base && length $base;
	my %seen;
	my @files;
	for my $line (split /\n/, capture($worktree, 'git', 'status', '--porcelain', '-uall')) {
		next unless length $line;
		my $path = length($line) > 3 ? substr($line, 3) : '';
		$path =~ s/^"(.*)"$/$1/;
		$path =~ s/\s+->\s+.*//;
		next unless length $path;
		push @files, $path unless $seen{$path}++;
	}
	for my $path (split /\n/, capture($worktree, 'git', 'diff', '--name-only', "$base...HEAD")) {
		next unless length $path;
		push @files, $path unless $seen{$path}++;
	}
	return @files;
}

# Leave the files for inspection, but take the branch out of the namespace:
# a branch cannot be deleted while a worktree has it checked out, so detach
# first. The worktree itself stays.
sub abandon_branch {
	my ($repo, $worktree, $branch) = @_;
	run_cmd(cmd => ['git', 'checkout', '--detach'], cwd => $worktree);
	run_cmd(cmd => ['git', 'branch', '-D', $branch], cwd => $repo);
}

# --- the failure path -------------------------------------------------------
# The exact failing line, not a summary of it: a person reading failure.md can
# paste it into a shell or a test file. A suite log is the only place that line
# lives, so it is read here and capped. The browser layers name a real failure
# as `FAIL l3 ...` or `probe: ...`; their startup noise (fuse, dbus, the portal,
# a certificate issuer) is dropped from both the list and the repair tail so it
# cannot crowd the cause out. A sub, not a file-scope regex, so it is available
# while the main loop runs above this section.
sub browser_noise { return qr/(?:fuse init failed|No matching issuer|\bdbus\b|xdg-desktop-portal|\borg\.freedesktop\.portal\b)/i }

sub failure_lines {
	my ($path) = @_;
	return [] unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return [];
	my @lines;
	while (my $line = <$fh>) {
		chomp $line;
		next if $line =~ browser_noise();
		push @lines, $line
			if $line =~ /^\s*(?:not\s+ok\b|#\s+Failed test|#\s+Looks like|FAIL\s+l\d+\b|probe:|FAILED\b|Error:)/i;
	}
	close $fh;
	@lines = @lines[0 .. 19] if scalar @lines > 20;
	return \@lines;
}

# The coordinator's last word on a ticket: `landed`, `refused` or `no verdict`.
# It is printed to the land log; a timeout or a usage error leaves the tail.
sub land_verdict {
	my ($path) = @_;
	my $tail = log_tail($path, 20);
	my @lines = grep { /\S/ } split /\n/, $tail;
	return '' unless @lines;
	for my $line ( reverse @lines ) {
		$line =~ s/^\s+|\s+$//g;
		return $line if $line =~ /(?:landed|refused|no verdict)/i;
	}
	my $last = $lines[-1];
	$last =~ s/^\s+|\s+$//g;
	return $last;
}

# The app lane's suite is Gradle: its failures do not look like TAP. Keep the
# lines that name a compiler error or a failed task, so a repair prompt carries
# the real diagnostic rather than only the tail.
sub build_failure_lines {
	my ($path) = @_;
	return [] unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return [];
	my @lines;
	while (my $line = <$fh>) {
		chomp $line;
		push @lines, $line
			if $line =~ /^\s*(?:e:\s|error:|FAILURE:|What went wrong|Execution failed|>\s+Task\b.*FAILED|BUILD FAILED|Caused by:)/i;
		last if @lines >= 20;
	}
	close $fh;
	return \@lines;
}

# The last few lines of a log for the repair prompt: enough to see the shape of
# the failure without pasting a whole suite's output into the agent's context.
sub log_tail {
	my ($path, $count) = @_;
	$count = 40 unless defined $count && $count =~ /^\d+$/ && $count > 0;
	return '' unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return '';
	my $noise = browser_noise();
	my @lines = grep { !/$noise/ } <$fh>;
	close $fh;
	@lines = @lines[-$count .. -1] if @lines > $count;
	my $text = join('', @lines);
	$text = substr($text, -4096) if length($text) > 4096;
	return $text;
}

# --- the agent's own account -------------------------------------------------
# agent.pl prints one ACCOUNTING line (context bytes/tokens and the per-section
# list) and one REPLY line per turn to its stdout, which run_cmd writes to the
# agent log. CodingContext reads them back so the report's numbers are the
# agent's numbers - there is no second estimate in this file.
sub record_agent_accounting {
	my ($run, $log_path) = @_;
	my ($acc, $replies) = CodingContext::read_agent_log($log_path);
	return 0 unless $acc;
	$run->{'context_bytes'}        = $acc->{'context_bytes'};
	$run->{'context_est_tokens'}   = $acc->{'context_est_tokens'};
	$run->{'context_system_bytes'} = $acc->{'system_bytes'};
	$run->{'context_sections'}     = $acc->{'sections'};
	$run->{'context_repo'}         = $acc->{'repo'};
	$run->{'context_index'}        = $acc->{'index'};
	$run->{'reply_cap'}            = $acc->{'reply_cap'};
	$run->{'reply_bytes'}          = [ map { $_->{'bytes'} } @{$replies} ];
	print '  ' . CodingContext::context_summary($run) . "\n";
	return 1;
}

# The "## Context" section report.md and the report note get: one line per note,
# the same summary this run prints. Appended after CodingNight's own markdown,
# so a failed note still carries what it spent.
sub context_md {
	my ($runs) = @_;
	my @lines;
	for my $run ( @{ ref $runs eq 'ARRAY' ? $runs : [] } ) {
		next unless ref $run eq 'HASH' && defined $run->{'context_bytes'};
		push @lines, '- note ' . ($run->{'n'} // '?') . ': '
			. CodingContext::context_summary($run);
	}
	return '' unless @lines;
	return "\n## Context\n\n" . join("\n", @lines) . "\n";
}

# The failure.md beside the report is the plain-text handover: what failed, the
# exact test line, the worktree, the tag, and what a person should do next.
sub write_failure_md {
	my ($dir, $report, $run, $repo) = @_;
	my @failing = @{ failure_lines($run->{'suite_log'}) };
	my $path = "$dir/failure.md";
	open(my $fh, '>', $path) or die "qa/coding_night: $path: $!\n";
	print {$fh} '# Nightly failure - ' . ($report->{'stamp'} // '') . "\n\n";
	print {$fh} '- note: `' . ($run->{'note_id'} // '') . '` ' . ($run->{'title'} // '') . "\n";
	print {$fh} '- status: ' . ($run->{'status'} // 'unknown') . "\n";
	print {$fh} '- error: ' . ($run->{'error'} // '') . "\n";
	print {$fh} '- worktree: `' . ($run->{'worktree'} // '') . "`\n";
	print {$fh} '- branch: `' . ($run->{'branch'} // '') . "`\n";
	print {$fh} '- push target: `' . ($run->{'push_target'} // 'origin') . "`\n";
	print {$fh} '- land: ' . CodingNight::land_line($run) . "\n"
		if ($run->{'lane'} // 'repo') ne 'app';
	print {$fh} CodingNight::repair_summary($run);
	print {$fh} '- report: `' . $dir . "/report.json`\n";
	print {$fh} '- ' . CodingContext::context_summary($run) . "\n"
		if defined $run->{'context_bytes'};
	if (@failing) {
		print {$fh} "\n## Failing test lines\n\n";
		print {$fh} "    $_\n" for @failing;
	}
	print {$fh} "\n## Next action\n\n";
	my $status = $run->{'status'} // '';
	if ($status =~ /^land_(?:refused|timeout)$/) {
		print {$fh} 'The landing queue did not take `' . ($run->{'branch'} // '') . '` ('
			. CodingNight::land_line($run)
			. "). The worktree and branch are left; fix or re-queue the branch, then rerun. The note stays open.\n";
	}
	else {
		print {$fh} "The branch was not landed by this note. Inspect the worktree, fix the failure, and rerun; the note stays open.\n";
	}
	close $fh;
	return $path;
}

sub failure_note_text {
	my ($report, $run, $dir) = @_;
	my $title = 'Nightly failed: ' . ($run->{'title'} || ('note ' . ($run->{'note_id'} // '')));
	my @failing = @{ failure_lines($run->{'suite_log'}) };
	my $text = $title . "\n\n";
	$text .= 'The ' . ($report->{'stamp'} // '') . " coding night failed.\n";
	$text .= '- status: ' . ($run->{'status'} // 'unknown') . "\n";
	$text .= '- error: ' . ($run->{'error'} // '') . "\n";
	$text .= '- worktree: ' . ($run->{'worktree'} // '') . "\n";
	$text .= '- branch: ' . ($run->{'branch'} // '') . "\n";
	$text .= '- push target: ' . ($run->{'push_target'} // 'origin') . "\n";
	$text .= '- land: ' . CodingNight::land_line($run) . "\n"
		if ($run->{'lane'} // 'repo') ne 'app';
	$text .= "- report: $dir/report.json\n";
	$text .= CodingNight::repair_summary($run);
	$text .= "- failure: $dir/failure.md\n";
	if (@failing) {
		$text .= "\nFailing test lines:\n" . join("\n", @failing) . "\n";
	}
	$text .= ($run->{'source'} || 'notes') eq 'notes'
		? "\nThe original note is still open.\n"
		: "\nThe report will offer this item again on its next run.\n";
	return $text;
}

sub config {
	my ($repo) = @_;
	my $path = "$repo/config.json";
	return {} unless -f $path;
	open(my $fh, '<', $path) or return {};
	local $/;
	my $json = <$fh> // '';
	close $fh;
	my $cfg = eval { JSON::PP->new->utf8->decode($json) };
	return ref $cfg eq 'HASH' ? $cfg : {};
}

sub default_base {
	my ($repo) = @_;
	my $cfg = config($repo);
	my $port = $cfg->{'working_port'} || 3000;
	return "https://127.0.0.1:$port";
}

sub live_url {
	my ($repo, $given) = @_;
	return $given if defined $given && length $given;
	return default_base($repo);
}

sub ticket_url {
	my ($repo, $given) = @_;
	return $given if defined $given;
	my $path = "$repo/.shots/ticket.txt";
	return '' unless -f $path;
	open(my $fh, '<', $path) or return '';
	my $url = <$fh> // '';
	close $fh;
	$url =~ s/^\s+|\s+$//g;
	return $url;
}

# The one live write: the app's own route, behind the ticket-minted session.
sub post_note {
	my (%a) = @_;
	require Mojo::UserAgent;
	my $ua = Mojo::UserAgent->new(insecure => 1, max_redirects => 5, request_timeout => 30);
	if (defined $a{'ticket'} && length $a{'ticket'}) {
		my $tx = $ua->get($a{'ticket'});
		die "the ticket did not mint a session (" . ($tx->res->code // 'no answer') . ")\n"
			unless $tx->res->is_success;
	}
	my $tx = $ua->post($a{'live_url'} . '/manager/note_save' => form => {
		text     => $a{'text'},
		category => $a{'category'} || 'journal',
		(defined $a{'uuid'} ? (uuid => $a{'uuid'}) : ()),
		(defined $a{'status'} ? (status => $a{'status'}) : ()),
	});
	die "note_save answered " . ($tx->res->code // 'no answer') . "\n"
		unless $tx->res->is_success;
	my $json = eval { $tx->res->json } || {};
	return $json;
}

sub mark_note_completed {
	my (%a) = @_;
	my $json = post_note(
		live_url => $a{'live_url'},
		ticket   => $a{'ticket'},
		uuid     => $a{'note_id'},
		status   => 'completed',
	);
	die "note_save did not return the note uuid\n" unless $json->{'uuid'};
	return $json;
}
