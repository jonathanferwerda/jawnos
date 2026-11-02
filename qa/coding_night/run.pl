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
#           qa/nightly-<stamp>-<n> from origin/main
#   agent   the hook named by JAWNOS_CODING_AGENT or __president/qa_coding_agent,
#           run with cwd = the worktree and JAWNOS_NOTE_ID/TITLE/TEXT in its env
#   suite   qa/run.pl --source worktree --root <root>/nightly --layers l0,l1
#           (+ l2,l3 when the change touches templates, JS or perl routes)
#   green   version bump, one commit, push the branch, ff-only merge into main,
#           push main, restart, require HTTP 200 from /manager/health, then mark
#           the note completed through POST /manager/note_save and file a
#           Handbook report note (category journal).
#
# A red suite stops the night: the worktree stays for inspection, the branch is
# detached and deleted, the note stays open, and the report names the failure.
# With no agent configured the run exits 3 before it fetches, adds a worktree or
# creates a branch. There is no live SQL here except the read-only SQLite URI;
# the one live write is the app's own note_save route.
#
# Teardown never runs the manager killer and never asks a QA tree for a
# graceful shutdown: a bound process is SIGKILLed, and a restart goes through
# scripts/restart.pl, which is the master's own path.

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
	health_url    => undef,
	health_wait   => 60,
	suite_timeout => 3600,
	ignore_device => 0,
);
my @argv = @ARGV;
while (my $arg = shift @argv) {
	if ($arg eq '--dry-run')      { $opt{'dry_run'} = 1; next }
	if ($arg eq '--ignore-device'){ $opt{'ignore_device'} = 1; next }
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
	if ($arg eq '--health-url')   { $opt{'health_url'} = shift @argv // ''; next }
	if ($arg =~ /^--health-url=(.*)$/) { $opt{'health_url'} = $1; next }
	if ($arg eq '--health-wait')  { $opt{'health_wait'} = shift @argv // 60; next }
	if ($arg =~ /^--health-wait=(.*)$/) { $opt{'health_wait'} = $1; next }
	if ($arg eq '--suite-timeout'){ $opt{'suite_timeout'} = shift @argv // 3600; next }
	if ($arg =~ /^--suite-timeout=(.*)$/) { $opt{'suite_timeout'} = $1; next }
	if ($arg eq '--help' || $arg eq '-h') { usage(); exit 0 }
	die "qa/coding_night: unknown argument: $arg\n";
}

my $here = abs_path(__FILE__) || __FILE__;
$opt{'repo'} ||= abs_path( dirname($here) . '/../..' );
my $repo = abs_path( $opt{'repo'} ) || $opt{'repo'};
die "qa/coding_night: no JawnOS checkout at $repo\n" unless -d "$repo/qa";
die "qa/coding_night: $repo is not a git checkout\n" unless -d "$repo/.git";

my $root = $opt{'root'} || (($ENV{'HOME'} || '') . '/jawnos-qa');
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

# --- the agent hook ---------------------------------------------------------
my $agent_line = defined $opt{'agent'} ? $opt{'agent'} : $ENV{'JAWNOS_CODING_AGENT'};
# The in-tree agent is the default hook, so a configured model is enough.
$agent_line = "$^X $FindBin::Bin/agent.pl" unless defined $opt{'agent'} || (defined $agent_line && length $agent_line);
$agent_line = QaSetting::read_coding_agent($db)
	unless defined $opt{'agent'} || (defined $agent_line && length $agent_line);
my $agent = CodingNight::agent_command($agent_line);

# --- the plan ---------------------------------------------------------------
my $notes = eval { CodingNight::select_notes($db, limit => $limit) };
my $note_error = $@;
$notes = [] unless ref $notes eq 'ARRAY';

if ($opt{'dry_run'}) {
	print "qa/coding_night dry run - nothing is fetched, created, pushed or posted\n";
	print "  repo: $repo\n";
	print "  database: $db (read-only)\n";
	print "  notes per night: $limit\n";
	print "  agent: " . (($agent_line // '') =~ /\S/ ? $agent_line : 'NONE - the 06:00 run would exit 3') . "\n";
	if ($note_error) {
		print "  queue: could not be read: $note_error";
		exit 0;
	}
	print '  queue: ' . scalar(@{$notes}) . " note(s)\n";
	my $n = 0;
	for my $note ( @{$notes} ) {
		$n++;
		my $app   = CodingNight::is_app_note($note);
		my $paths = $app
			? CodingNight::plan_app_paths($root, $stamp, $n)
			: CodingNight::plan_paths($root, $stamp, $n);
		print '    ' . $n . '. [' . $note->{'id'} . '] ' . $note->{'title'} . "\n";
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
my $health_url = health_url($repo, $opt{'health_url'});
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
	notes     => scalar @{$notes},
	rollback_tag    => '',
	rollback_script => "$report_dir/rollback.sh",
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

print 'JawnOS coding nightly ' . $stamp . ' - ' . scalar(@{$notes}) . " note(s), limit $limit\n";

my $failed = 0;
my $n = 0;
for my $note ( @{$notes} ) {
	$n++;
	my $paths = CodingNight::plan_paths($root, $stamp, $n);
	my $worktree = $paths->{'worktree'};
	my $branch   = $paths->{'branch'};
	my $log      = sub { "$report_dir/note-$n-$_[0].log" };
	my %run = (
		n         => $n,
		note_id   => $note->{'id'},
		title     => $note->{'title'},
		branch    => $branch,
		worktree  => $worktree,
		status    => 'pending',
		agent_exit   => undef,
		suite_exit   => undef,
		layers       => 'l0,l1',
		pushed       => 0,
		merged       => 0,
		restarted    => 0,
		health_ok    => 0,
		marked_completed => 0,
		handbook_filed   => 0,
		rolled_back      => 'no',
		rollback_tag     => '',
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
	if (CodingNight::is_app_note($note)) {
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
		my $build_env = { JAVA_HOME => CodingNight::app_java_home() };
		my ($build_rc) = run_cmd(
			cmd     => CodingNight::app_build_command(),
			cwd     => $worktree,
			env     => $build_env,
			log     => $log->('gradle'),
			timeout => $opt{'suite_timeout'},
		);
		$run{'build_exit'} = $build_rc;
		if ($build_rc != 0) {
			$run{'status'} = 'build_failed';
			$run{'error'}  = "the Gradle build failed (exit $build_rc); no bump, push or stage was made"
				. '; see ' . $log->('gradle');
			$failed = 1;
			last;
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

	# 1. fetch, then a fresh worktree from origin/main
	my ($fetch_rc) = run_cmd(cmd => ['git', 'fetch', 'origin'], cwd => $repo, log => $log->('fetch'));
	if ($fetch_rc != 0) {
		$run{'status'} = 'fetch_failed';
		$run{'error'} = "git fetch failed (exit $fetch_rc); see " . $log->('fetch');
		$failed = 1;
		last;
	}

	# The tag is the whole recovery: a commit id, not a moving branch. It is
	# made before the worktree or any merge, so a failure after the merge can
	# put main back on exactly the tree the night started from. rollback.sh is
	# the human path beside it and refuses if the tag has gone.
	my $tag = "nightly-pre-$stamp";
	my ($tag_rc) = run_cmd(cmd => ['git', 'tag', $tag], cwd => $repo, log => $log->('tag'));
	if ($tag_rc != 0) {
		my $exists = capture($repo, 'git', 'rev-parse', '--verify', '--quiet', "refs/tags/$tag");
		if ($exists !~ /\S/) {
			$run{'status'} = 'tag_failed';
			$run{'error'} = "could not tag main as $tag (exit $tag_rc); nothing was merged";
			$failed = 1;
			last;
		}
	}
	$run{'rollback_tag'} = $tag;
	$report->{'rollback_tag'} ||= $tag;
	my ($rollback_path, $rollback_error) = CodingNight::write_rollback_script(
		$report_dir,
		tag     => $tag,
		repo    => $repo,
		health  => $health_url,
		restart => 'scripts/restart.pl',
	);
	if (!$rollback_path) {
		$run{'status'} = 'rollback_script_failed';
		$run{'error'} = $rollback_error // 'rollback.sh could not be written';
		$failed = 1;
		last;
	}
	$report->{'rollback_script'} = $rollback_path;

	if (-e $worktree) {
		$run{'status'} = 'name_clash';
		$run{'error'} = "the worktree $worktree already exists; nothing was overwritten";
		$failed = 1;
		last;
	}
	my ($wt_rc) = run_cmd(
		cmd => ['git', 'worktree', 'add', $worktree, '-b', $branch, 'origin/main'],
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
	if ($suite_rc != 0) {
		$run{'status'} = 'red';
		$run{'error'} = "the suite failed (exit $suite_rc, layers $layers); the worktree is left for inspection";
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

	# The house tree has other agents' work in it on a normal day. A merge is
	# only safe when main has nothing uncommitted to lose.
	my $dirty = capture($repo, 'git', 'status', '--porcelain');
	if ($dirty =~ /\S/) {
		$run{'status'} = 'house_dirty';
		$run{'error'} = 'the house tree has uncommitted work; not merging. The worktree and branch are left';
		$failed = 1;
		last;
	}

	# 4. green: the push target is checked before anything is merged. A fork
	# named in Configure -> Dev is the authority the branch and main go to; an
	# unreachable or unauthenticated target stops the night here, with main
	# still untouched and the note open.
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
			. " is unreachable or unauthenticated (exit $reach_rc); nothing was merged";
		$failed = 1;
		last;
	}

	# 5. green: bump, commit, push the branch, merge, push main
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
		$run{'error'} = "git push of $branch to " . $push->{'target'} . " failed (exit $push_rc); main was not touched";
		$failed = 1;
		last;
	}
	$run{'pushed'} = 1;

	my ($merge_rc) = run_cmd(cmd => ['git', 'merge', '--ff-only', $branch], cwd => $repo, log => $log->('merge'));
	if ($merge_rc != 0) {
		$run{'status'} = 'merge_failed';
		$run{'error'} = "main did not fast-forward to $branch (exit $merge_rc); the branch is pushed and left";
		$failed = 1;
		last;
	}
	$run{'merged'} = 1;

	my ($push_main_rc) = run_cmd(cmd => ['git', 'push', $push->{'target'}, 'HEAD:main'], cwd => $repo, log => $log->('push-main'));
	if ($push_main_rc != 0) {
		$run{'status'} = 'push_main_failed';
		$run{'error'} = 'main was merged but git push ' . $push->{'target'} . " HEAD:main failed (exit $push_main_rc)";
		$failed = 1;
		last;
	}

	# 6. restart through the master's own path, then health 200
	my $reason = $subject;
	my ($restart_rc) = run_cmd(
		cmd => [$^X, "$repo/scripts/restart.pl", '--reason', $reason],
		cwd => $repo, log => $log->('restart'), timeout => 300);
	$run{'restarted'} = ($restart_rc == 0) ? 1 : 0;
	if ($restart_rc != 0) {
		$run{'status'} = 'restart_failed';
		$run{'error'} = "scripts/restart.pl exited $restart_rc (see " . $log->('restart')
			. "); the note stays open until the live house is healthy";
		$failed = 1;
		last;
	}

	if (!health_ok($health_url, $opt{'health_wait'})) {
		$run{'status'} = 'health_failed';
		$run{'error'} = "the restart was accepted but $health_url did not answer 200; the note stays open";
		$failed = 1;
		last;
	}
	$run{'health_ok'} = 1;

	# 6. only now: the app's own route marks the note completed
	my $res = eval {
		mark_note_completed(
			note_id => $note->{'id'},
			live_url => live_url($repo, $opt{'live_url'}),
			ticket   => ticket_url($repo, $opt{'ticket'}),
		);
	};
	if (!$res) {
		$run{'status'} = 'mark_failed';
		$run{'error'} = 'the code shipped but the note could not be marked completed: ' . ($@ || 'unknown');
		$failed = 1;
		last;
	}
	$run{'marked_completed'} = 1;
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

	# merged and healthy: the worktree has served its purpose
	run_cmd(cmd => ['git', 'worktree', 'remove', '--force', $worktree], cwd => $repo, log => $log->('cleanup'));
	run_cmd(cmd => ['git', 'branch', '-d', $branch], cwd => $repo, log => $log->('cleanup'));
}

# A failure after the merge is the one that can leave the live house broken.
# Put main back on the tag made before the night started, restart through the
# master's own path, and require health 200. Anything less is reported loudly.
if ($failed && @{$report->{'runs'}}) {
	my $failed_run = $report->{'runs'}->[-1];
	my $status = $failed_run->{'status'} // '';
	if ($failed_run->{'merged'} && $status =~ /^(?:push_main_failed|restart_failed|health_failed)$/) {
		automatic_rollback($failed_run, $report_dir, $repo, $health_url, $opt{'health_wait'});
	}
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
  --repo DIR        the checkout (default this file's repo)
  --root DIR        QA root (default ~/jawnos-qa)
  --db PATH         live database, read with mode=ro (default <repo>/database/jawnos.db)
  --stamp STAMP     run stamp (default YYYYmmdd-HHMMSS); names branch and worktree
  --agent LINE      the coding agent command (default JAWNOS_CODING_AGENT or the setting)
  --live-url URL    the live manager base for note_save (default config.json working_port)
  --health-url URL  the health route (default <live>/manager/health)
  --ticket URL      box_office ticket URL (default <repo>/.shots/ticket.txt)
  --health-wait SEC seconds to wait for HTTP 200 (default 60)
  --suite-timeout S seconds for the agent and the suite (default 3600)
  --ignore-device   skip qa/device_target.pl (a test or an owner's manual run)
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
# $base defaults to origin/main; the app lane passes jawnos instead.
sub changed_files {
	my ($worktree, $base) = @_;
	$base = 'origin/main' unless defined $base && length $base;
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
# lives, so it is read here and capped.
sub failure_lines {
	my ($path) = @_;
	return [] unless defined $path && length $path && -f $path;
	open(my $fh, '<', $path) or return [];
	my @lines;
	while (my $line = <$fh>) {
		chomp $line;
		push @lines, $line
			if $line =~ /^\s*(?:not\s+ok\b|#\s+Failed test|#\s+Looks like|FAILED\b|Error:)/i;
	}
	close $fh;
	@lines = @lines[0 .. 19] if scalar @lines > 20;
	return \@lines;
}

sub automatic_rollback {
	my ($run, $report_dir, $repo, $health_url, $health_wait) = @_;
	my $tag = $run->{'rollback_tag'} // '';
	return unless length $tag;
	my $log = "$report_dir/note-" . ($run->{'n'} // '?') . "-rollback.log";
	$run->{'rolled_back'} = 'yes';

	my ($reset_rc) = run_cmd(cmd => ['git', 'reset', '--hard', $tag], cwd => $repo, log => $log);
	$run->{'rollback_reset_ok'} = $reset_rc == 0 ? 1 : 0;
	if ($reset_rc != 0) {
		$run->{'rollback_restart_ok'} = 0;
		$run->{'rollback_health_ok'} = 0;
		$run->{'rollback_error'} = "git reset --hard $tag failed (exit $reset_rc)";
		print STDERR "!!! ROLLBACK RESET FAILED: main is NOT on $tag (exit $reset_rc). A person must fix it by hand.\n";
		return;
	}

	my ($restart_rc) = run_cmd(
		cmd => [$^X, "$repo/scripts/restart.pl", '--reason',
			"rollback to $tag (nightly " . ($run->{'status'} // 'failed') . ')'],
		cwd => $repo, log => $log, timeout => 300);
	$run->{'rollback_restart_ok'} = $restart_rc == 0 ? 1 : 0;
	if ($restart_rc != 0) {
		$run->{'rollback_health_ok'} = 0;
		$run->{'rollback_error'} = "the rollback reset main to $tag but scripts/restart.pl exited $restart_rc";
		print STDERR "!!! ROLLBACK RESTART FAILED: main is on $tag but scripts/restart.pl exited $restart_rc."
			. " THE LIVE HOUSE MAY STILL RUN THE BAD CODE - RESTART IT BY HAND.\n";
		return;
	}

	my $ok = health_ok($health_url, $health_wait);
	$run->{'rollback_health_ok'} = $ok ? 1 : 0;
	$run->{'rollback_health'} = $ok ? 200 : 'not 200';
	print STDERR "!!! ROLLBACK HEALTH FAILED: main is on $tag and the restart was accepted, but $health_url is not 200.\n"
		unless $ok;
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
	print {$fh} '- rollback tag: `' . ($run->{'rollback_tag'} // '') . "`\n";
	print {$fh} '- push target: `' . ($run->{'push_target'} // 'origin') . "`\n";
	print {$fh} '- rolled back: ' . ($run->{'rolled_back'} // 'no');
	if (($run->{'rolled_back'} // '') eq 'yes') {
		print {$fh} ' (reset ' . (defined $run->{'rollback_reset_ok'} ? ($run->{'rollback_reset_ok'} ? 'ok' : 'FAILED') : '?') . ',\n'
			. '  restart ' . (defined $run->{'rollback_restart_ok'} ? ($run->{'rollback_restart_ok'} ? 'ok' : 'FAILED') : '?') . ',\n'
			. '  health 200 ' . (defined $run->{'rollback_health_ok'} ? ($run->{'rollback_health_ok'} ? 'yes' : 'no') : 'not checked') . ')';
	}
	print {$fh} "\n";
	print {$fh} '- report: `' . $dir . "/report.json`\n";
	print {$fh} '- rollback script: `' . $dir . "/rollback.sh`\n";
	print {$fh} '- ' . CodingContext::context_summary($run) . "\n"
		if defined $run->{'context_bytes'};
	if (@failing) {
		print {$fh} "\n## Failing test lines\n\n";
		print {$fh} "    $_\n" for @failing;
	}
	print {$fh} "\n## Next action\n\n";
	if (($run->{'rolled_back'} // '') eq 'yes' && defined $run->{'rollback_restart_ok'} && !$run->{'rollback_restart_ok'}) {
		print {$fh} "Main is on `" . ($run->{'rollback_tag'} // '') . "`, but the rollback restart was refused. Restart the house by hand now, then rerun the night.\n";
	}
	elsif (($run->{'rolled_back'} // '') eq 'yes') {
		print {$fh} "Main is back on `" . ($run->{'rollback_tag'} // '') . "`. The note stays open; fix the failure and rerun.\n";
	}
	else {
		print {$fh} "Main was not merged by this note. Inspect the worktree, fix the failure, and rerun; the note stays open.\n";
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
	$text .= '- rollback tag: ' . ($run->{'rollback_tag'} // '') . "\n";
	$text .= '- push target: ' . ($run->{'push_target'} // 'origin') . "\n";
	$text .= '- rolled back: ' . ($run->{'rolled_back'} // 'no');
	if (($run->{'rolled_back'} // '') eq 'yes') {
		$text .= ' (restart ' . (defined $run->{'rollback_restart_ok'} ? ($run->{'rollback_restart_ok'} ? 'ok' : 'FAILED') : '?')
			. ', health 200 ' . (defined $run->{'rollback_health_ok'} ? ($run->{'rollback_health_ok'} ? 'yes' : 'no') : 'not checked') . ')';
	}
	$text .= "\n- report: $dir/report.json\n";
	$text .= "- failure: $dir/failure.md\n";
	$text .= "- rollback script: $dir/rollback.sh\n";
	if (@failing) {
		$text .= "\nFailing test lines:\n" . join("\n", @failing) . "\n";
	}
	$text .= "\nThe original note is still open.\n";
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

sub health_url {
	my ($repo, $given) = @_;
	return $given if defined $given && length $given;
	return default_base($repo) . '/manager/health';
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

sub health_ok {
	my ($url, $wait) = @_;
	$wait = 60 unless defined $wait && $wait =~ /^\d+$/;
	require HTTP::Tiny;
	my $deadline = time + $wait;
	while (1) {
		my $res = HTTP::Tiny->new(verify_SSL => 0, timeout => 10)->get($url);
		return 1 if $res->{'status'} == 200;
		last if time >= $deadline;
		sleep 2;
	}
	return 0;
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
