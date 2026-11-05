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
#   perl scripts/agent_land.pl                  land the current branch
#   perl scripts/agent_land.pl --branch agent/pen
#   perl scripts/agent_land.pl --dry-run        print the plan, change nothing
#   perl scripts/agent_land.pl --no-restart
#   perl scripts/agent_land.pl --jobs 4         suite job count (default 2:
#                                               other agents share the cores)
#   perl scripts/agent_land.pl --wait 60        seconds for the gate (default
#                                               300; the branch is pushed to
#                                               origin before the wait starts,
#                                               so a timeout never loses work)
#   perl scripts/agent_land.pl --remove         delete the worktree afterwards
#   perl scripts/agent_land.pl --reason "..."   restart reason (default: the
#                                               landed subject)
#
# Exit: 0 landed (and restarted) - 1 refused, nothing pushed - 2 bad usage -
# 4 another landing held the lock past --wait - 5 pushed, but the dev server is
# not on it (primary checkout dirty or diverged, or the restart was refused).
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

my %opt = (
	'trunk'   => 'main',
	'jobs'    => 2,
	'wait'    => 300,
	'restart' => 1,
	'remove'  => 0,
);
GetOptions(
	'branch=s'   => \$opt{'branch'},
	'reason=s'   => \$opt{'reason'},
	'trunk=s'    => \$opt{'trunk'},
	'jobs=s'     => \$opt{'jobs'},
	'wait=s'     => \$opt{'wait'},
	'no-restart' => sub { $opt{'restart'} = 0 },
	'remove'     => \$opt{'remove'},
	'dry-run'    => \$opt{'dry'},
	'help'       => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'jobs'} =~ /^\d+$/ && $opt{'jobs'} > 0;
usage(2) unless $opt{'wait'} =~ /^\d+$/;

# A rebase may ask for a message; never let it wait on an editor.
$ENV{'GIT_EDITOR'} = 'true';

# --- the repo we are in ----------------------------------------------------

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

sub say_step {
	# stderr, so a wrapper that pipes stdout (| tail -40) still shows progress while
	# the landing runs; an agent that sees nothing for two minutes drives again.
	print STDERR 'agent_land: ', $_[0], "\n";
}

sub refuse {
	my ($why) = @_;
	print STDERR "agent_land: refused: $why\n";
	print STDERR 'agent_land: a refusal ends the attempt - fix it and run the gate again deliberately, '
		. "or report it; do not retry in a loop.\n";
	exit 1;
}

my ($rc, $root) = git('rev-parse', '--show-toplevel');
refuse("not inside a git worktree\n$root") if $rc != 0 || !length $root;
$root = abs_path($root);
chdir $root or refuse("cannot enter $root: $!");

# The common dir is shared by every worktree; the lock and the shared refs live
# there. It has to be the common dir, not this worktree's .git.
my ($crc, $common) = git('rev-parse', '--path-format=absolute', '--git-common-dir');
if ($crc != 0 || $common !~ m{^/}) {
	($crc, my $rel) = git('rev-parse', '--git-common-dir');
	$common = $rel =~ m{^/} ? $rel : abs_path($rel);
}
refuse('cannot find the git common dir') unless defined $common && length $common;

# The primary checkout is the master's tree: the first entry in the worktree
# list. Landing must move it forward - restart does not pull.
my ($wrc, $wlist) = git('worktree', 'list', '--porcelain');
refuse('cannot list worktrees') if $wrc != 0;
my ($primary) = $wlist =~ /^worktree\s+(.+)$/m;
refuse('cannot find the primary worktree') unless defined $primary && length $primary;

my $branch = $opt{'branch'};
if (!defined $branch) {
	my ($brc, $b) = git('rev-parse', '--abbrev-ref', 'HEAD');
	refuse("cannot read the current branch\n$b") if $brc != 0;
	$branch = $b;
}
refuse("$branch is the trunk; work in a worktree "
	. "(git worktree add .worktrees/<task> -b agent/<task> origin/main) and land that") if $branch eq $opt{'trunk'};

my $lock_path = "$common/jawnos-land.lock";

# --- the plan changes nothing, so it does not take the lock -----------------

my $reason = $opt{'reason'};

if ($opt{'dry'}) {
	say_step("would back up $branch to origin/$branch (so the work survives a busy gate)");
	say_step("would lock $lock_path");
	say_step("would fetch origin and rebase $branch onto origin/$opt{'trunk'}");
	say_step("would run: $^X scripts/run_tests.pl --jobs $opt{'jobs'}");
	say_step("would bump VERSION, rewrite the tip subject, and push HEAD:refs/heads/$opt{'trunk'}");
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
		. 'It has been reset to false; nothing was landed. Re-run the gate deliberately.');
}

my ($drc, $dirty) = git('status', '--porcelain');
refuse("the worktree has uncommitted work; commit it first:\n$dirty") if length $dirty;

my ($prc, $pdirty) = capture('git', '-C', $primary, 'status', '--porcelain', '--untracked-files=no');
if ($prc != 0 || length $pdirty) {
	refuse("the primary checkout at $primary has uncommitted changes; "
		. "commit or stash them, or the dev server cannot take this landing:\n$pdirty");
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
open($lock, '>>', $lock_path) or refuse("cannot open $lock_path: $!");
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
		exit 4;
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
refuse("git fetch failed:\n$fout") if $frc != 0;

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
		refuse("git rebase --continue failed:\n$cout") if $crc != 0;
		next;
	}

	git('rebase', '--abort');
	refuse("the branch does not rebase onto origin/$opt{'trunk'}:\n$rout");
}

# --- nothing to land is a refusal, not an empty bump -----------------------
# Re-running the gate on a branch already merged would otherwise rebase to zero
# commits, bump VERSION and amend *trunk's* tip - a duplicate version on a commit
# that was not this agent's. An agent told to "just land again" must get a clear
# no, not a rewritten trunk.
my ($nrc, $ahead) = git('rev-list', '--count', "origin/$opt{'trunk'}..HEAD");
refuse("nothing to land: $branch has no commits ahead of origin/$opt{'trunk'} "
	. '(it is already merged)')
	if $nrc == 0 && ($ahead // '') eq '0';

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
	refuse('the suite failed; fix it and land again');
}
if (repo_is_bare()) {
	heal_bare();
	refuse('the suite left the repository bare (core.bare=true). It has been reset to '
		. 'false and nothing was pushed - this is the test-corruption bug, not this branch. '
		. 'Report it, and land again once it is fixed.');
}

my (undef, $trunk_after) = git('-C', $primary, 'rev-parse', "refs/heads/$opt{'trunk'}");
$trunk_after = '' unless defined $trunk_after;
if (length $trunk_before && length $trunk_after && $trunk_after ne $trunk_before) {
	my (undef, $who) = capture('git', '-C', $primary, 'log', '-1', '--format=%ae %ce', $trunk_after);
	if (($who // '') =~ /\@example\.(?:invalid|test)\b|\@jawnos\.invalid\b/) {
		git('-C', $primary, 'reset', '--mixed', $trunk_before);
		refuse("the suite moved $opt{'trunk'} in the primary checkout to a fixture commit "
			. "($trunk_before -> $trunk_after). It has been put back; nothing was pushed.");
	}
	refuse("$opt{'trunk'} moved in the primary checkout during the suite "
		. "($trunk_before -> $trunk_after); nothing was pushed. Commit or revert it by hand, then land again.");
}

# --- bump, rewrite the tip subject ---------------------------------------

say_step('bumping VERSION');
my ($brc, $new) = capture($^X, 'scripts/version_bump.pl');
refuse("version_bump.pl failed:\n$new") if $brc != 0;
$new =~ s/\s+$//;
refuse("version_bump.pl printed no version:\n$new") unless $new =~ /^\d+\.\d+\.\d+$/;

my (undef, $subject) = git('log', '-1', '--format=%s');
my (undef, $body)    = git('log', '-1', '--format=%b');
$subject =~ s/^\s*v\d+\.\d+\.\d+\s+-\s+//;   # never stack two version prefixes
$subject =~ s/\s+$//;
refuse('the branch tip has no commit') unless length $subject;
$body =~ s/\s+$//;
my $message = "v$new - $subject" . (length $body ? "\n\n$body" : '');

git('add', '--', 'VERSION');
my ($fh, $msg_path) = tempfile(UNLINK => 1, SUFFIX => '.msg');
print $fh $message;
close $fh;
my ($amrc, $amout) = git('commit', '--amend', '-F', $msg_path);
refuse("amending the tip failed:\n$amout") if $amrc != 0;
unlink $msg_path;

# --- push, then move the primary checkout ---------------------------------

say_step("pushing HEAD:refs/heads/$opt{'trunk'}");
# The suite just ran above, under the landing lock. Tell the pre-push hook, or it
# runs it a second time - which doubles every landing and flakes the timing tests
# at the hook's default parallelism.
$ENV{'JAWNOS_SUITE_ALREADY_RUN'} = 1;
my ($pusc, $puso) = git('push', 'origin', "HEAD:refs/heads/$opt{'trunk'}");
delete $ENV{'JAWNOS_SUITE_ALREADY_RUN'};
refuse("the push was refused (rebase and land again):\n$puso") if $pusc != 0;

# The backup branch has done its job: its work is on the trunk now, and leaving
# it on origin is what puts every finished task in GitHub's "Compare & pull
# request" list. Best effort - a failed delete is not a failed landing.
say_step("deleting the backup branch origin/$branch");
my ($delrc, $delout) = git('push', 'origin', '--delete', $branch);
say_step("origin/$branch was not deleted (remove it by hand): $delout") if $delrc != 0;

say_step("fast-forwarding the primary checkout at $primary");
my ($pfrc, $pfout) = capture('git', '-C', $primary, 'fetch', 'origin', '--quiet');
if ($pfrc != 0) {
	print STDERR "agent_land: landed and pushed v$new, but the primary checkout "
		. "could not fetch:\n$pfout\n";
	exit 5;
}
my ($mrc, $mout) = capture('git', '-C', $primary, 'merge', '--ff-only', "origin/$opt{'trunk'}");
if ($mrc != 0) {
	print STDERR "agent_land: landed and pushed v$new, but the primary checkout at "
		. "$primary is not on it:\n$mout\n";
	exit 5;
}

# --- restart, so the server is on what just landed -----------------------

if (!$opt{'restart'}) {
	say_step("landed v$new (not restarting: --no-restart)");
	remove_worktree();
	exit 0;
}

$reason = "v$new - $subject" unless defined $reason && length $reason;
say_step("restarting: $reason");
my ($rrc, $rout) = capture($^X, "$primary/scripts/restart.pl", '--reason', $reason);
print $rout if length $rout;
if ($rrc != 0) {
	print STDERR "agent_land: landed and pushed v$new, but the restart was refused "
		. "(see the report above)\n";
	exit 5;
}

say_step("landed v$new and restarted");
remove_worktree();
exit 0;

# A worktree is scratch: its files are on origin and on the trunk now. Never
# remove it silently - an agent's shell may still be sitting in it - but say the
# command, and do it only when asked.
sub remove_worktree {
	if (!$opt{'remove'}) {
		say_step("worktree kept: git worktree remove '$root' && git branch -d $branch");
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
	say_step("removed the worktree at $root");
}

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
agent_land.pl - land one agent's branch onto the trunk, once, behind a lock
  perl scripts/agent_land.pl [--branch B] [--trunk main] [--jobs 2] [--wait 300]
                             [--dry-run] [--no-restart] [--remove] [--reason TEXT]
USAGE
	exit $code;
}
