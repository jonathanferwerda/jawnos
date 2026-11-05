# tests-for: scripts/worktree_gc.pl
# covers:    the sweep - it removes only a merged, clean, idle worktree, and it
#           never touches the primary, unmerged work, or uncommitted files

use strict;
use warnings;

use Cwd qw(getcwd);
use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Path qw(make_path);
use File::Slurp qw(write_file);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

my $script = "$FindBin::Bin/../scripts/worktree_gc.pl";

sub sh {
	my @cmd = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, @cmd);
	close $in;
	local $/;
	my $o = <$out> // '';
	my $e = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $o . $e);
}

sub git {
	my $dir = shift;
	my ($code, $out) = sh('git', '-C', $dir, @_);
	$out =~ s/\s+$//;
	return ($code, $out);
}

sub gc {
	my ($primary, @args) = @_;
	my $cwd = getcwd();
	chdir $primary or die "chdir: $!";
	my ($code, $out) = sh($^X, $script, '--no-fetch', @args);
	chdir $cwd or die "chdir back: $!";
	return ($code, $out);
}

my $dir     = tempdir(CLEANUP => 1);
my $origin  = "$dir/origin.git";
my $primary = "$dir/primary";
make_path($primary);

my ($ic) = sh('git', 'init', '--bare', '-b', 'main', $origin);
die "bare origin\n" if $ic != 0;
($ic) = sh('git', 'init', '-b', 'main', $primary);
die "primary\n" if $ic != 0;
git($primary, 'config', 'user.email', 'gc@example.test');
git($primary, 'config', 'user.name',  'gc test');
write_file("$primary/README", "base\n");
git($primary, 'add', '.');
git($primary, 'commit', '-q', '-m', 'base');
git($primary, 'remote', 'add', 'origin', $origin);
git($primary, 'push', '-q', '-u', 'origin', 'main');

# A merged branch: commit on it, merge it into main, push both.
git($primary, 'checkout', '-q', '-b', 'agent/merged');
write_file("$primary/merged.txt", "merged\n");
git($primary, 'add', '.');
git($primary, 'commit', '-q', '-m', 'merged work');
git($primary, 'checkout', '-q', 'main');
git($primary, 'merge', '-q', '--ff-only', 'agent/merged');
git($primary, 'push', '-q', 'origin', 'main');

# An unmerged branch with real work on it.
git($primary, 'checkout', '-q', '-b', 'agent/unmerged');
write_file("$primary/unmerged.txt", "unmerged\n");
git($primary, 'add', '.');
git($primary, 'commit', '-q', '-m', 'unmerged work');
git($primary, 'checkout', '-q', 'main');

# A merged branch, but with an uncommitted file in its worktree.
git($primary, 'checkout', '-q', '-b', 'agent/dirty');
write_file("$primary/dirty.txt", "dirty\n");
git($primary, 'add', '.');
git($primary, 'commit', '-q', '-m', 'dirty work');
git($primary, 'checkout', '-q', 'main');
git($primary, 'merge', '-q', '--ff-only', 'agent/dirty');
git($primary, 'push', '-q', 'origin', 'main');

my $wt_merged   = "$dir/wt-merged";
my $wt_unmerged = "$dir/wt-unmerged";
my $wt_dirty    = "$dir/wt-dirty";
git($primary, 'worktree', 'add', '-q', $wt_merged,   'agent/merged');
git($primary, 'worktree', 'add', '-q', $wt_unmerged, 'agent/unmerged');
git($primary, 'worktree', 'add', '-q', $wt_dirty,    'agent/dirty');
write_file("$wt_dirty/loose.txt", "not committed\n");

sub merged_branch {
	my ($name) = @_;
	git($primary, 'checkout', '-q', '-b', "agent/$name");
	write_file("$primary/$name.txt", "$name\n");
	git($primary, 'add', '.');
	git($primary, 'commit', '-q', '-m', "$name work");
	git($primary, 'checkout', '-q', 'main');
	git($primary, 'merge', '-q', '--ff-only', "agent/$name");
	git($primary, 'push', '-q', 'origin', 'main');
}

merged_branch('stash');
merged_branch('check');

# --- report only changes nothing ------------------------------------------
my ($rc, $out) = gc($primary, '--older-than', '0');
is($rc, 0, 'the report exits cleanly');
like($out, qr/would\s+remove \Q$wt_merged\E/, 'a merged, clean worktree is a candidate');
	like($out, qr/wip\s+\Q$wt_unmerged\E \[agent\/unmerged\] \(not merged/, 'an unmerged branch is WIP');
	like($out, qr/wip\s+\Q$wt_dirty\E \[agent\/dirty\] \(uncommitted/, 'uncommitted work is WIP');
like($out, qr/keep\s+\Q$primary\E \(the primary checkout\)/, 'the primary is never a candidate');
ok(-d $wt_merged, 'report-only removed nothing');

# --- the idle threshold keeps a fresh worktree ----------------------------
($rc, $out) = gc($primary, '--apply');
	like($out, qr/idle\s+\Q$wt_merged\E \[agent\/merged\] \(younger than 24 h/,
	'a fresh worktree is idle, not done');
ok(-d $wt_merged, 'and it is still there');

# --- apply removes exactly the safe one -----------------------------------
($rc, $out) = gc($primary, '--apply', '--older-than', '0');
is($rc, 0, 'the sweep exits cleanly') or diag($out);
like($out, qr/removed \Q$wt_merged\E/, 'the merged, clean, idle worktree is removed');
ok(!-d $wt_merged, 'its directory is gone');
	ok(-d $wt_unmerged, 'the unmerged worktree survives');
	ok(-d $wt_dirty, 'the worktree with uncommitted work survives');
ok(-d $primary, 'the primary checkout survives');

my ($brc) = git($primary, 'rev-parse', '--verify', 'refs/heads/agent/merged');
isnt($brc, 0, 'the landed branch is deleted with it');
($brc) = git($primary, 'rev-parse', '--verify', 'refs/heads/agent/unmerged');
is($brc, 0, 'the unmerged branch is untouched');

# --- WIP that git status does not see is still WIP ------------------------
# A stash is shared by every worktree (refs/stash is one ref), so it is checked
# last and only here: while any stash waits, the sweep touches nothing.
my $wt_stash = "$dir/wt-stash";
my $wt_check = "$dir/wt-check";
my $wt_det   = "$dir/wt-detached";
git($primary, 'worktree', 'add', '-q', $wt_stash, 'agent/stash');
git($primary, 'worktree', 'add', '-q', $wt_check, 'agent/check');
git($primary, 'worktree', 'add', '-q', '--detach', $wt_det, 'agent/unmerged');

make_path("$wt_check/.shots");
write_file("$wt_check/.shots/AGENT-CHECKPOINT.md", "goal: still open\n");

($rc, $out) = gc($primary, '--older-than', '0');
like($out, qr/wip\s+\Q$wt_check\E \[agent\/check\] \(an agent checkpoint is open\)/,
	'an open agent checkpoint is WIP');
	like($out, qr/wip\s+\Q$wt_det\E \[\(detached\)\] \(detached at a commit not on origin\/main\)/,
	'a detached head with an unmerged commit is WIP');

# and it really is a stash: the clean tree alone would have looked finished
write_file("$wt_stash/stashed.txt", "not committed\n");
git($wt_stash, 'add', '.');
git($wt_stash, 'stash', 'push', '-q', '-m', 'wip');
($rc, $out) = gc($primary, '--older-than', '0', '--apply');
like($out, qr/wip\s+\Q$wt_stash\E .*\(a stash is waiting in this repo\)/,
	'the stash alone stops the sweep');
	ok(-d $wt_stash, 'the worktree with a stash survives --apply');
	ok(-d $wt_check, 'the worktree with an open checkpoint survives --apply');
	ok(-d $wt_det, 'the detached worktree with unmerged work survives --apply');

# --- backup branches on origin -------------------------------------------
# The lander pushes a branch to origin before it waits for the gate. After the
# landing that branch is redundant, and every one left behind is a "Compare &
# pull request" banner. Only agent/* is touched, and only when the work is on
# the trunk.
subtest 'the remote sweep deletes landed backup branches only' => sub {
	git($primary, 'push', '-q', 'origin', 'agent/stash');
	git($primary, 'push', '-q', 'origin', 'agent/unmerged');

	my ($rc, $out) = gc($primary, '--remote-only', '--apply');
	is($rc, 0, 'the remote sweep exits cleanly') or diag($out);
	like($out, qr/removed origin\/agent\/stash/, 'a landed backup branch is deleted');
	like($out, qr/wip\s+origin\/agent\/unmerged/, 'an unlanded one is kept');

	my ($gc1) = git($origin, 'rev-parse', '--verify', 'refs/heads/agent/stash');
	isnt($gc1, 0, 'the landed one is gone from origin');
	my ($gc2) = git($origin, 'rev-parse', '--verify', 'refs/heads/agent/unmerged');
	is($gc2, 0, 'the unlanded one is still on origin');
};

done_testing();
