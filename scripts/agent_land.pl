#!/usr/bin/perl

# Land one agent's committed work onto the shared trunk, once, behind a lock.
#
# More than one agent on this box is normal, and they all finish the same way:
# bump, push, restart. Those three steps are global - VERSION is one counter, the
# suite is eight cores, and the master is one process on one checkout - so ten
# agents doing them by hand race each other and the loser's work is silently
# overwritten. This script is the only lander:
#
#   git worktree add .worktrees/<task> -b agent/<task> origin/main
#   ... commit in the worktree ...
#   perl scripts/agent_land.pl
#
# It takes a lock shared through the git common dir (so every worktree of this
# repo contends for it), rebases the branch onto origin/main, resolves the shared
# VERSION hunk in trunk's favour, runs the suite ONCE (the pre-push hook is told
# not to repeat it), bumps VERSION on the rebased tip, rewrites that subject to
# v<new> - <summary>, pushes fast-forward only, fast-forwards the *primary*
# checkout (the master does not pull on restart) and restarts, so the dev server
# is always on what was just landed.
#
# The generated agent index and the baked protocols describe the tree, so they
# are refreshed on the rebased tip before the suite: a landing that rebases onto
# a newer trunk must test the tree it is about to push.
#
#   perl scripts/agent_land.pl                  land the current branch
#   perl scripts/agent_land.pl --branch agent/pen
#   perl scripts/agent_land.pl --dry-run        print the plan, change nothing
#   perl scripts/agent_land.pl --no-restart
#   perl scripts/agent_land.pl --defer-restart  stop before the restart; the
#                                               landing queue restarts once per
#                                               wave (scripts/land_coordinator.pl)
#   perl scripts/agent_land.pl --json           one machine-readable result on
#                                               stdout; progress stays on stderr
#   perl scripts/agent_land.pl --jobs 4         suite job count (default 2:
#                                               other agents share the cores)
#   perl scripts/agent_land.pl --wait 60        seconds for the gate (default
#                                               300; the branch is pushed to
#                                               origin before the wait starts,
#                                               so a timeout never loses work)
#   perl scripts/agent_land.pl --keep            keep the worktree afterwards
#                                               (default: remove it, with its
#                                               merged branch, once landed -
#                                               but not while an open agent
#                                               checkpoint says the task is not
#                                               over)
#   perl scripts/agent_land.pl --remove          remove it even with an open
#                                               checkpoint (an explicit order)
#   perl scripts/agent_land.pl --reason "..."   restart reason (default: the
#                                               landed subject)
#
# Exit: 0 landed (and restarted) - 1 refused, nothing pushed - 2 bad usage -
# 4 another landing held the lock past --wait - 5 pushed, but the dev server is
# not on it (primary checkout dirty or diverged, or the restart was refused).
#
# A failed landing keeps the worktree: the crash is the thing to look at, and
# the branch is on origin either way.
#
# The branch is expected to be committed: a dirty worktree is refused rather
# than swept up, because the agent knows which hunks are its own and this script
# does not. VERSION hunks in the branch are discarded - the counter belongs to
# the trunk, and bumping it here is what makes the number unique.

use strict;
use warnings;

use Cwd qw(abs_path);
use Fcntl qw(:flock);
use File::Temp qw(tempfile);
use Getopt::Long qw(GetOptions);
use IO::Handle ();
use IPC::Open3 qw(open3);
use JSON::PP ();
use Symbol qw(gensym);

my %opt = (
	'trunk'         => 'main',
	'jobs'          => 2,
	'wait'          => 300,
	'restart'       => 1,
	'remove'        => 1,
	'force'         => 0,
	'json'          => 0,
	'defer_restart' => 0,
);
GetOptions(
	'branch=s'      => \$opt{'branch'},
	'reason=s'      => \$opt{'reason'},
	'trunk=s'       => \$opt{'trunk'},
	'jobs=s'        => \$opt{'jobs'},
	'wait=s'        => \$opt{'wait'},
	'json'          => \$opt{'json'},
	'defer-restart' => \$opt{'defer_restart'},
	'no-restart'    => sub { $opt{'restart'} = 0 },
	'keep'       => sub { $opt{'remove'} = 0 },
	'remove'     => sub { $opt{'remove'} = 1; $opt{'force'} = 1 },
	'dry-run'    => \$opt{'dry'},
	'help'       => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'jobs'} =~ /^\d+$/ && $opt{'jobs'} > 0;
usage(2) unless $opt{'wait'} =~ /^\d+$/;

# A rebase may ask for a message; never let it wait on an editor.
$ENV{'GIT_EDITOR'} = 'true';

# --- the repo we are in ----------------------------------------------------

# Named here so finish() can put the branch in a --json result even when the
# failure happens before the branch is resolved.
my $branch;

sub capture {
	my @cmd = @_;
	open(my $fh, '-|', @cmd) or return (127, "cannot run @cmd: $!");
	local $/;
	my $out = <$fh>;
	$out = '' unless defined $out;
	close $fh;
	return ($? >> 8, $out);
}

sub git {
	my @args = @_;
	my ($code, $out) = capture('git', @args);
	$out =~ s/\s+$// if defined $out;
	return ($code, $out);
}

# restart.pl puts the reason a verdict was not reached on stderr, and the plain
# capture above reads only stdout. The class of the refusal (busy, timeout, no
# master) is the whole decision, so this one keeps both streams.
sub capture_both {
	my @cmd = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, @cmd);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout . $stderr);
}

sub say_step {
	# stderr, so a wrapper that pipes stdout (| tail -40) still shows progress while
	# the landing runs; an agent that sees nothing for two minutes drives again.
	print STDERR 'agent_land: ', $_[0], "\n";
}

sub refuse {
	my ($why, $class) = @_;
	print STDERR "agent_land: refused: $why\n";
	print STDERR 'agent_land: a refusal ends the attempt - fix it and run the gate again deliberately, '
		. "or report it; do not retry in a loop.\n";
	finish(1, reason_class => ($class || 'refused'), message => $why);
}

# One exit, so --json always ends with exactly one machine-readable line while
# the progress lines stay on stderr.
my $finished = 0;
sub finish {
	my ($code, %result) = @_;
	return if $finished++;
	$result{'ok'}     = $code == 0 ? 1 : 0;
	$result{'code'}   = $code;
	$result{'branch'} = $branch if defined $branch && length $branch;
	if ($opt{'json'}) {
		print JSON::PP->new->canonical->encode(\%result), "\n";
	}
	exit $code;
}

# The master reports the version it booted, so "my code is live" is a version
# comparison, not a restart call that happened to return 0.
sub version_ge {
	my ($a, $b) = @_;
	my @a = (($a // '') =~ /^v?(\d+)\.(\d+)\.(\d+)/) ? ($1, $2, $3) : (0, 0, 0);
	my @b = (($b // '') =~ /^v?(\d+)\.(\d+)\.(\d+)/) ? ($1, $2, $3) : (0, 0, 0);
	for my $i (0 .. 2) {
		return 1 if $a[$i] > $b[$i];
		return 0 if $a[$i] < $b[$i];
	}
	return 1;
}

my ($rc, $root) = git('rev-parse', '--show-toplevel');
refuse("not inside a git worktree\n$root", 'not_worktree') if $rc != 0 || !length $root;
$root = abs_path($root);
chdir $root or refuse("cannot enter $root: $!", 'enter');

# The common dir is shared by every worktree; the lock and the shared refs live
# there. It has to be the common dir, not this worktree's .git.
my ($crc, $common) = git('rev-parse', '--path-format=absolute', '--git-common-dir');
if ($crc != 0 || $common !~ m{^/}) {
	($crc, my $rel) = git('rev-parse', '--git-common-dir');
	$common = $rel =~ m{^/} ? $rel : abs_path($rel);
}
refuse('cannot find the git common dir', 'not_repo') unless defined $common && length $common;

# The primary checkout is the master's tree: the first entry in the worktree
# list. Landing must move it forward - restart does not pull.
my ($wrc, $wlist) = git('worktree', 'list', '--porcelain');
refuse('cannot list worktrees', 'not_repo') if $wrc != 0;
my ($primary) = $wlist =~ /^worktree\s+(.+)$/m;
refuse('cannot find the primary worktree', 'not_repo') unless defined $primary && length $primary;

$branch = $opt{'branch'};
if (!defined $branch) {
	my ($brc, $b) = git('rev-parse', '--abbrev-ref', 'HEAD');
	refuse("cannot read the current branch\n$b", 'not_repo') if $brc != 0;
	$branch = $b;
}
refuse("$branch is the trunk; work in a worktree "
	. "(git worktree add .worktrees/<task> -b agent/<task> origin/main) and land that", 'trunk') if $branch eq $opt{'trunk'};

my $lock_path = "$common/jawnos-land.lock";

# --- the plan changes nothing, so it does not take the lock -----------------

my $reason = $opt{'reason'};

if ($opt{'dry'}) {
	say_step("would back up $branch to origin/$branch (so the work survives a busy gate)");
	say_step("would lock $lock_path");
	say_step("would fetch origin and rebase $branch onto origin/$opt{'trunk'}");
	say_step('would refresh the generated agent index and baked protocols on the rebased tree');
	say_step("would run: $^X scripts/run_tests.pl --jobs $opt{'jobs'}");
	say_step("would bump VERSION, rewrite the tip subject, and push HEAD:refs/heads/$opt{'trunk'}");
	say_step("would bump the firmware version of every board this landing changed");
	say_step("would fast-forward the primary checkout at $primary");
	say_step($opt{'restart'} ? 'would restart the dev server' : 'would not restart (--no-restart)');
	say_step($opt{'remove'} ? 'would remove this worktree afterwards' : 'would leave the worktree in place');
	exit 0;
}

# --- refuse before anything moves -----------------------------------------
# A test that leaves the live repo bare takes every git command with it, and the
# lander would otherwise push out of a repo whose refs a fixture has moved. This
# is the corruption we have seen, not a branch problem, so name it as such.
sub repo_is_bare {
	my ($code, $out) = capture('git', '-C', $primary, 'config', '--get', 'core.bare');
	return ($out // '') =~ /^\s*true\s*$/ ? 1 : 0;
}
sub heal_bare {
	git('-C', $primary, 'config', 'core.bare', 'false');
}

if (repo_is_bare()) {
	heal_bare();
	refuse('the repository was bare (core.bare=true), which stops every git command. '
		. 'It has been reset to false; nothing was landed. Re-run the gate deliberately.', 'bare');
}

my ($drc, $dirty) = git('status', '--porcelain');
refuse("the worktree has uncommitted work; commit it first:\n$dirty", 'dirty_worktree') if length $dirty;

my ($prc, $pdirty) = capture('git', '-C', $primary, 'status', '--porcelain', '--untracked-files=no');
if ($prc != 0 || length $pdirty) {
	refuse("the primary checkout at $primary has uncommitted changes; "
		. "commit or stash them, or the dev server cannot take this landing:\n$pdirty", 'dirty_primary');
}

# --- back the branch up before waiting ------------------------------------
# The gate serializes landings, and a queue can outlast an agent's patience.
# Pushing the branch itself needs no lock and collides with nobody, so the work
# is on origin whether or not this run gets the gate. --no-verify: the gate's
# suite is the authority, not a backup push of a branch nobody has merged.
say_step("backing up $branch to origin/$branch");
my ($bkrc, $bkout) = git('push', '--no-verify', '--force-with-lease',
		'origin', "HEAD:refs/heads/$branch");
say_step("the branch backup did not go through; the gate still can:\n$bkout") if $bkrc != 0;

# --- the lock: one landing at a time, across every worktree ---------------

sub lock_holder {
	open(my $fh, '<', $lock_path) or return '';
	my $line = <$fh>;
	close $fh;
	return defined $line ? $line : '';
}

my $lock;
open($lock, '>>', $lock_path) or refuse("cannot open $lock_path: $!", 'lock');
$lock->autoflush(1);

my $deadline = time + $opt{'wait'};
my $waited   = 0;
while (!flock($lock, LOCK_EX | LOCK_NB)) {
	if (time >= $deadline) {
		my $holder = lock_holder();
		$holder =~ s/\s+$//;
		print STDERR "agent_land: the gate is busy"
			. ($holder =~ /^(\d+)\s*(.*)$/ && $2 ne '' ? " (pid $1 on $2)" : '')
			. "; waited $opt{'wait'} s. This branch is already on origin/$branch, so "
			. "the work is safe — land again later rather than retrying in a loop.\n";
		finish(4, reason_class => 'busy',
			message => "the gate is busy; waited $opt{'wait'} s; the branch is safe on origin/$branch");
	}
	$waited++;
	sleep 1;
}
seek($lock, 0, 0);
truncate($lock, 0);
print $lock "$$ $branch\n";

# --- fetch, rebase --------------------------------------------------------

say_step("rebasing $branch onto origin/$opt{'trunk'}");
my ($frc, $fout) = git('fetch', 'origin', '--quiet');
refuse("git fetch failed:\n$fout", 'fetch') if $frc != 0;

while (1) {
	my ($rrc, $rout) = git('rebase', "origin/$opt{'trunk'}");
	last if $rrc == 0;

	my (undef, $unmerged) = git('diff', '--name-only', '--diff-filter=U');
	my @unmerged = grep { length } split /\n/, $unmerged;
	if (@unmerged && !grep { $_ ne 'VERSION' } @unmerged) {
		# VERSION is shared; the trunk's copy wins and the bump below moves it
		# past whatever trunk reached, so the number stays unique.
		say_step('VERSION conflicts with the trunk; keeping the trunk copy and re-bumping');
		git('checkout', '--ours', '--', 'VERSION');
		git('add', '--', 'VERSION');
		my ($crc, $cout) = git('rebase', '--continue');
		refuse("git rebase --continue failed:\n$cout", 'rebase') if $crc != 0;
		next;
	}

	git('rebase', '--abort');
	refuse("the branch does not rebase onto origin/$opt{'trunk'}:\n$rout", 'rebase');
}

# --- nothing to land is a refusal, not an empty bump -----------------------
# Re-running the gate on a branch already merged would otherwise rebase to zero
# commits, bump VERSION and amend *trunk's* tip - a duplicate version on a commit
# that was not this agent's. An agent told to "just land again" must get a clear
# no, not a rewritten trunk.
my ($nrc, $ahead) = git('rev-list', '--count', "origin/$opt{'trunk'}..HEAD");
refuse("nothing to land: $branch has no commits ahead of origin/$opt{'trunk'} "
	. '(it is already merged)', 'nothing')
	if $nrc == 0 && ($ahead // '') eq '0';

# The rebase just changed the tree, and the index and baked protocols describe
# the tree. Refresh them here, before the suite, so t/97 and t/98 judge what will
# be pushed rather than a trunk that moved under the branch.
refresh_generated();

# --- the suite is the gate ------------------------------------------------

# The trunk in the primary checkout must not move while the suite runs: the gate
# holds the lock, so no other agent can be landing, and a move is a fixture
# commit from a test. Record it, then check it after the suite.
my (undef, $trunk_before) = git('-C', $primary, 'rev-parse', "refs/heads/$opt{'trunk'}");
$trunk_before = '' unless defined $trunk_before;

say_step("running the suite (--jobs $opt{'jobs'})");
my ($src, $sout) = capture($^X, 'scripts/run_tests.pl', '--jobs', $opt{'jobs'});
if ($src != 0) {
	print STDERR $sout unless length $sout > 20000;
	refuse('the suite failed; fix it and land again', 'suite');
}
if (repo_is_bare()) {
	heal_bare();
	refuse('the suite left the repository bare (core.bare=true). It has been reset to '
		. 'false and nothing was pushed - this is the test-corruption bug, not this branch. '
		. 'Report it, and land again once it is fixed.', 'suite_bare');
}

my (undef, $trunk_after) = git('-C', $primary, 'rev-parse', "refs/heads/$opt{'trunk'}");
$trunk_after = '' unless defined $trunk_after;
if (length $trunk_before && length $trunk_after && $trunk_after ne $trunk_before) {
	my (undef, $who) = capture('git', '-C', $primary, 'log', '-1', '--format=%ae %ce', $trunk_after);
	if (($who // '') =~ /\@example\.(?:invalid|test)\b|\@jawnos\.invalid\b/) {
		git('-C', $primary, 'reset', '--mixed', $trunk_before);
		refuse("the suite moved $opt{'trunk'} in the primary checkout to a fixture commit "
			. "($trunk_before -> $trunk_after). It has been put back; nothing was pushed.", 'suite_moved');
	}
	refuse("$opt{'trunk'} moved in the primary checkout during the suite "
		. "($trunk_before -> $trunk_after); nothing was pushed. Commit or revert it by hand, then land again.", 'suite_moved');
}

# --- bump, rewrite the tip subject ---------------------------------------

say_step('bumping VERSION');
my ($brc, $new) = capture($^X, 'scripts/version_bump.pl');
refuse("version_bump.pl failed:\n$new", 'bump') if $brc != 0;
$new =~ s/\s+$//;
refuse("version_bump.pl printed no version:\n$new", 'bump') unless $new =~ /^\d+\.\d+\.\d+$/;

# A board's firmware version is its own, but the landing owns the bookkeeping:
# a board whose firmware this landing changed takes a patch bump, and a board
# still on the old major.minor follows the house's scheme. Both go into the tip
# commit, so the number in the tree is the number the next image carries.
say_step('bumping the firmware versions this landing touched');
my @fw_version_files = grep { -f $_ } qw(jt/VERSION jw/VERSION jp/alarmclock/VERSION);
if (-f 'scripts/fw_bump.pl' && @fw_version_files) {
	my ($fwrc, $fwout) = capture($^X, 'scripts/fw_bump.pl', '--sync',
		'--from', "origin/$opt{'trunk'}", '--house', $new);
	refuse("fw_bump.pl failed:\n$fwout", 'bump') if $fwrc != 0;
	$fwout =~ s/\s+$//;
	say_step($fwout) if length $fwout;
}

my (undef, $subject) = git('log', '-1', '--format=%s');
my (undef, $body)    = git('log', '-1', '--format=%b');
$subject =~ s/^\s*v\d+\.\d+\.\d+\s+-\s+//;   # never stack two version prefixes
$subject =~ s/\s+$//;
refuse('the branch tip has no commit', 'no_subject') unless length $subject;
$body =~ s/\s+$//;
my $message = "v$new - $subject" . (length $body ? "\n\n$body" : '');

git('add', '--', 'VERSION', @fw_version_files);
my ($fh, $msg_path) = tempfile(UNLINK => 1, SUFFIX => '.msg');
print $fh $message;
close $fh;
my ($amrc, $amout) = git('commit', '--amend', '-F', $msg_path);
refuse("amending the tip failed:\n$amout", 'commit') if $amrc != 0;
unlink $msg_path;

# --- push, then move the primary checkout ---------------------------------

say_step("pushing HEAD:refs/heads/$opt{'trunk'}");
# The suite just ran above, under the landing lock. Tell the pre-push hook, or it
# runs it a second time - which doubles every landing and flakes the timing tests
# at the hook's default parallelism.
$ENV{'JAWNOS_SUITE_ALREADY_RUN'} = 1;
my ($pusc, $puso) = git('push', 'origin', "HEAD:refs/heads/$opt{'trunk'}");
delete $ENV{'JAWNOS_SUITE_ALREADY_RUN'};
refuse("the push was refused (rebase and land again):\n$puso", 'push') if $pusc != 0;

# The backup branch has done its job: its work is on the trunk now, and leaving
# it on origin is what puts every finished task in GitHub's "Compare & pull
# request" list. Best effort - a failed delete is not a failed landing.
say_step("deleting the backup branch origin/$branch");
my ($delrc, $delout) = git('push', 'origin', '--delete', $branch);
say_step("origin/$branch was not deleted (remove it by hand): $delout") if $delrc != 0;

say_step("fast-forwarding the primary checkout at $primary");
my ($pfrc, $pfout) = capture('git', '-C', $primary, 'fetch', 'origin', '--quiet');
if ($pfrc != 0) {
	my $why = "landed and pushed v$new, but the primary checkout could not fetch: $pfout";
	print STDERR "agent_land: $why\n";
	finish(5, reason_class => 'apply', version => $new, subject => $subject, message => $why);
}
my ($mrc, $mout) = capture('git', '-C', $primary, 'merge', '--ff-only', "origin/$opt{'trunk'}");
if ($mrc != 0) {
	my $why = "landed and pushed v$new, but the primary checkout at $primary is not on it: $mout";
	print STDERR "agent_land: $why\n";
	finish(5, reason_class => 'apply', version => $new, subject => $subject, message => $why);
}

# --- restart, so the server is on what just landed -----------------------

if ($opt{'defer_restart'}) {
	say_step("landed v$new (restart deferred: the queue owns it)");
	remove_worktree();
	finish(0, reason_class => 'landed', version => $new, subject => $subject, restart_deferred => 1);
}

if (!$opt{'restart'}) {
	say_step("landed v$new (not restarting: --no-restart)");
	remove_worktree();
	finish(0, reason_class => 'landed', version => $new, subject => $subject, restart => 0);
}

$reason = "v$new - $subject" unless defined $reason && length $reason;
say_step("restarting: $reason");
my ($rok, $rdetail) = restart_and_verify($primary, $reason, $new);
if (!$rok) {
	my $why = "landed and pushed v$new, but the restart was refused: $rdetail";
	print STDERR "agent_land: $why\n";
	finish(5, reason_class => 'apply', version => $new, subject => $subject, message => $why);
}

say_step("landed v$new and restarted");
remove_worktree();
finish(0, reason_class => 'landed', version => $new, subject => $subject);

# A worktree is scratch: after a successful landing its files are on origin and
# on the trunk. Removing it is the default, because nothing else does and a
# finished agent is not coming back; --keep spares it. A refusal keeps it too -
# that is where the failure is. So does an open .shots/AGENT-CHECKPOINT.md: that
# file is the repo's own "this task is not over" marker (the sweep reads it the
# same way), and a thread can land a first piece of work and go on from the same
# worktree, so deleting it there would take the shots and probes the agent is
# still using. --remove overrides, for a checkpoint left behind on purpose.
# Removal is forced (the suite leaves a test database and a copied config behind)
# and is only ever attempted from the primary checkout, so an agent's own shell
# can sit in the worktree.
sub remove_worktree {
	if (!$opt{'remove'}) {
		say_step("worktree kept: git worktree remove '$root' && git branch -d $branch");
		return;
	}
	if (!$opt{'force'} && -e "$root/.shots/AGENT-CHECKPOINT.md") {
		say_step("worktree kept: an agent checkpoint is open ($root/.shots/AGENT-CHECKPOINT.md), "
			. 'so the task may not be over; delete it when it is, then: '
			. "git worktree remove '$root' && git branch -d $branch");
		return;
	}
	my ($wrc, $wout) = capture('git', '-C', $primary, 'worktree', 'remove', '--force', $root);
	if ($wrc != 0) {
		print STDERR "agent_land: the landing is safe, but the worktree could not be removed:\n$wout\n"
			. "agent_land: git -C '$primary' worktree remove '$root'\n";
		return;
	}
	my ($brc, $bout) = capture('git', '-C', $primary, 'branch', '-d', $branch);
	print STDERR "agent_land: the worktree is gone; the branch was not deleted:\n$bout\n" if $brc != 0;
	say_step("removed the worktree at $root (its .shots/ scratch went with it)");
}

# The index and the baked protocols are generated from the tree, and the rebase
# just changed it. A no-op refresh adds no commit; a real one rides the landing
# tip, so the landing stays one commit and the suite still tests it.
sub refresh_generated {
	return unless -f 'scripts/agent_help.pl' || -f 'scripts/bake_agents_rules.pl';

	# The scan wants the app's config and database the way the suite does. The
	# seeder is idempotent and writes only gitignored files.
	capture($^X, 'scripts/worktree_seed.pl') if -f 'scripts/worktree_seed.pl';

	if (-f 'scripts/agent_help.pl') {
		my ($rc, $out) = capture($^X, 'scripts/agent_help.pl', '--write-index');
		refuse("agent_help.pl --write-index failed:\n$out", 'generated') if $rc != 0;
	}
	if (-f 'scripts/bake_agents_rules.pl' && -f 'AGENTS.md') {
		my ($rc, $out) = capture($^X, 'scripts/bake_agents_rules.pl');
		refuse("bake_agents_rules.pl failed:\n$out", 'generated') if $rc != 0;
	}

	my @paths = grep { -e $_ } qw(qa/coding_night/agent-index.md docs/coding_agent_protocols.md);
	return unless @paths;
	my (undef, $dirty) = git('status', '--porcelain', '--', @paths);
	return unless length $dirty;

	say_step('refreshing the generated agent index and baked protocols for the rebased tree');
	git('add', '--', @paths);
	my ($rc, $out) = git('commit', '--amend', '--no-edit');
	refuse("amending the refreshed generated files failed:\n$out", 'generated') if $rc != 0;
}

# A restart is one request to one master, and a second caller while one is
# pending is told busy. The work is already on the trunk and the primary is
# already fast-forwarded, so busy is not a failed landing: wait for the pending
# restart to settle, then check the version the tree actually booted.
sub restart_and_verify {
	my ($primary, $reason, $want) = @_;
	my ($rc, $out) = capture_both($^X, "$primary/scripts/restart.pl", '--reason', $reason);
	print STDERR $out if length $out;
	return (1, '') if $rc == 0;

	# A missing master is not something to wait for. A busy master and a timed-out
	# verdict are both "the restart may be under way": check what the tree booted.
	return (0, $out) if $out =~ /no[ -]?master/i;
	my $busy    = $out =~ /already pending|busy/i;
	my $timeout = $out =~ /did not answer|no answer|timed? ?out/i;
	return (0, $out) unless $busy || $timeout;

	say_step($busy ? 'a restart is already pending; waiting for the tree it boots'
		: 'the restart verdict timed out; checking the version it booted');
	my $deadline = time + ($busy ? 180 : 60);
	while (time < $deadline) {
		my ($src, $sout) = capture($^X, "$primary/scripts/restart.pl", '--status', '--json');
		if ($src == 0) {
			my $reply = eval { JSON::PP->new->decode($sout) };
			if (ref $reply eq 'HASH' && !$reply->{'pending'}) {
				return (1, '') if version_ge($reply->{'version'}, $want);
				last;
			}
		}
		sleep 2;
	}

	say_step('asking for the restart again');
	my ($rrc, $rout) = capture_both($^X, "$primary/scripts/restart.pl", '--reason', $reason);
	print STDERR $rout if length $rout;
	return (1, '') if $rrc == 0;
	return (0, $rout);
}

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
agent_land.pl - land one agent's branch onto the trunk, once, behind a lock
  perl scripts/agent_land.pl [--branch B] [--trunk main] [--jobs 2] [--wait 300]
                             [--dry-run] [--no-restart] [--defer-restart]
                             [--json] [--keep] [--reason TEXT]
USAGE
	exit $code;
}
