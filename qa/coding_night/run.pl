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
$agent_line = QaSetting::read_coding_agent($db)
	unless defined $agent_line && length $agent_line;
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
		my $paths = CodingNight::plan_paths($root, $stamp, $n);
		print '    ' . $n . '. [' . $note->{'id'} . '] ' . $note->{'title'} . "\n";
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
	notes     => scalar @{$notes},
	runs      => [],
};

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
	);
	push @{$report->{'runs'}}, \%run;

	print '  [' . $n . '] ' . $note->{'title'} . "\n";

	# 1. fetch, then a fresh worktree from origin/main
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

	# 4. green: bump, commit, push the branch, merge, push main
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

	my ($push_rc) = run_cmd(cmd => ['git', 'push', '-u', 'origin', $branch], cwd => $worktree, log => $log->('push'));
	if ($push_rc != 0) {
		$run{'status'} = 'push_failed';
		$run{'error'} = "git push of $branch failed (exit $push_rc); main was not touched";
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

	my ($push_main_rc) = run_cmd(cmd => ['git', 'push', 'origin', 'main'], cwd => $repo, log => $log->('push-main'));
	if ($push_main_rc != 0) {
		$run{'status'} = 'push_main_failed';
		$run{'error'} = "main was merged but git push origin main failed (exit $push_main_rc)";
		$failed = 1;
		last;
	}

	# 5. restart through the master's own path, then health 200
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

	my $health_url = health_url($repo, $opt{'health_url'});
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
	});
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

$report->{'ok'} = !$failed;
$report->{'runs'} ||= [];

my $json_path = "$report_dir/report.json";
open(my $json_fh, '>', $json_path) or die "qa/coding_night: $json_path: $!\n";
print $json_fh JSON::PP->new->canonical->pretty->encode($report);
close $json_fh;

my $md_path = "$report_dir/report.md";
open(my $md_fh, '>', $md_path) or die "qa/coding_night: $md_path: $!\n";
print $md_fh CodingNight::report_markdown($report);
close $md_fh;

my $green = grep { ($_->{'status'} // '') eq 'green' } @{$report->{'runs'}};
print 'report: ' . $md_path . "\n";
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
sub changed_files {
	my ($worktree) = @_;
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
	for my $path (split /\n/, capture($worktree, 'git', 'diff', '--name-only', 'origin/main...HEAD')) {
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
