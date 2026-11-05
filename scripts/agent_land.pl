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
# VERSION hunk in trunk's favour, runs the suite, bumps VERSION on the rebased
# tip, rewrites that subject to v<new> - <summary>, pushes fast-forward only,
# fast-forwards the *primary* checkout (the master does not pull on restart) and
# restarts, so the dev server is always on what was just landed.
#
#   perl scripts/agent_land.pl                  land the current branch
#   perl scripts/agent_land.pl --branch agent/pen
#   perl scripts/agent_land.pl --dry-run        print the plan, change nothing
#   perl scripts/agent_land.pl --no-restart
#   perl scripts/agent_land.pl --jobs 4         suite job count (default 2:
#                                               other agents share the cores)
#   perl scripts/agent_land.pl --wait 60        seconds to wait for the lock
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
	'wait'    => 900,
	'restart' => 1,
);
GetOptions(
	'branch=s'   => \$opt{'branch'},
	'reason=s'   => \$opt{'reason'},
	'trunk=s'    => \$opt{'trunk'},
	'jobs=s'     => \$opt{'jobs'},
	'wait=s'     => \$opt{'wait'},
	'no-restart' => sub { $opt{'restart'} = 0 },
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

sub say_step { print 'agent_land: ', $_[0], "\n" }

sub refuse {
	my ($why) = @_;
	print STDERR "agent_land: refused: $why\n";
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
refuse("$branch is the trunk; land a branch, not $opt{'trunk'}") if $branch eq $opt{'trunk'};

my $lock_path = "$common/jawnos-land.lock";

# --- the plan changes nothing, so it does not take the lock -----------------

my $reason = $opt{'reason'};

if ($opt{'dry'}) {
	say_step("would lock $lock_path");
	say_step("would fetch origin and rebase $branch onto origin/$opt{'trunk'}");
	say_step("would run: $^X scripts/run_tests.pl --jobs $opt{'jobs'}");
	say_step("would bump VERSION, rewrite the tip subject, and push HEAD:refs/heads/$opt{'trunk'}");
	say_step("would fast-forward the primary checkout at $primary");
	say_step($opt{'restart'} ? 'would restart the dev server' : 'would not restart (--no-restart)');
	exit 0;
}

# --- the lock: one landing at a time, across every worktree ---------------

my $lock;
open($lock, '>>', $lock_path) or refuse("cannot open $lock_path: $!");
$lock->autoflush(1);

my $deadline = time + $opt{'wait'};
my $waited   = 0;
while (!flock($lock, LOCK_EX | LOCK_NB)) {
	if (time >= $deadline) {
		print STDERR "agent_land: another landing held the lock for $waited s; "
			. "waited $opt{'wait'} s, giving up ($lock_path)\n";
		exit 4;
	}
	$waited++;
	sleep 1;
}
seek($lock, 0, 0);
truncate($lock, 0);
print $lock "$$ $branch\n";

# --- refuse before anything moves -----------------------------------------

my ($drc, $dirty) = git('status', '--porcelain');
refuse("the worktree has uncommitted work; commit it first:\n$dirty") if length $dirty;

my ($prc, $pdirty) = capture('git', '-C', $primary, 'status', '--porcelain', '--untracked-files=no');
if ($prc != 0 || length $pdirty) {
	refuse("the primary checkout at $primary has uncommitted changes; "
		. "commit or stash them, or the dev server cannot take this landing:\n$pdirty");
}

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

# --- the suite is the gate ------------------------------------------------

say_step("running the suite (--jobs $opt{'jobs'})");
my ($src, $sout) = capture($^X, 'scripts/run_tests.pl', '--jobs', $opt{'jobs'});
if ($src != 0) {
	print STDERR $sout unless length $sout > 20000;
	refuse('the suite failed; fix it and land again');
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
my ($pusc, $puso) = git('push', 'origin', "HEAD:refs/heads/$opt{'trunk'}");
refuse("the push was refused (rebase and land again):\n$puso") if $pusc != 0;

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
exit 0;

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
agent_land.pl - land one agent's branch onto the trunk, once, behind a lock
  perl scripts/agent_land.pl [--branch B] [--trunk main] [--jobs 2] [--wait 900]
                             [--dry-run] [--no-restart] [--reason TEXT]
USAGE
	exit $code;
}
