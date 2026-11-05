#!/usr/bin/perl

# Sweep agent worktrees that are finished with: landed, clean, idle, unused.
#
# A worktree is scratch, not an archive. Once its branch is merged into the
# trunk the directory is 170 MB of files that exist on origin and in the primary
# checkout, and nothing removes it - git never deletes a worktree. This reports
# what can go and, with --apply, removes it.
#
#   perl scripts/worktree_gc.pl                    # report only (the default)
#   perl scripts/worktree_gc.pl --apply            # remove the safe ones
#   perl scripts/worktree_gc.pl --apply --older-than 6
#   perl scripts/worktree_gc.pl --no-fetch         # judge against the local ref
#
# A worktree is removed only when ALL of these hold:
#   1. it is not the primary checkout and not the worktree you are standing in;
#   2. its commit (branch or detached head) is an ancestor of origin/<trunk>;
#   3. no stash is waiting in it and no .shots/AGENT-CHECKPOINT.md is open;
#   4. `git status --porcelain` there is empty (no modified or untracked file);
#   5. no process has its cwd inside it (an agent may still be working);
#   6. it has been idle for --older-than hours (default 24; 0 ignores). Idle is
#      the newer of the directory and the last commit.
# Anything with unfinished work is reported `wip` and kept, whatever its age:
# that is what makes this safe to run while someone is working. Dead
# registrations (the directory is already gone) are pruned in either mode:
# that is bookkeeping, not deletion.
#
# Exit: 0 always unless the repo cannot be read - the report is the product.

use strict;
use warnings;

use Getopt::Long qw(GetOptions);

my %opt = (trunk => 'main', 'older-than' => 24, fetch => 1, apply => 0, remote => 1, 'remote-only' => 0);
GetOptions(
	'trunk=s'       => \$opt{'trunk'},
	'older-than=s'  => \$opt{'older-than'},
	'apply'         => \$opt{'apply'},
	'no-fetch'      => sub { $opt{'fetch'} = 0 },
	'no-remote'     => sub { $opt{'remote'} = 0 },
	'remote-only'   => \$opt{'remote-only'},
	'help'          => \$opt{'help'},
) or usage(2);
usage(0) if $opt{'help'};
usage(2) unless $opt{'older-than'} =~ /^\d+$/;

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

sub say_line { print $_[0], "\n" }

my ($rc, $root) = git('rev-parse', '--show-toplevel');
if ($rc != 0 || !length $root) {
	# A detached shell (or the primary marked bare) still has a git dir; fall
	# back to the first worktree so a broken checkout can still be swept.
	my ($lrc, $list) = git('worktree', 'list', '--porcelain');
	die "worktree_gc: not inside a git worktree\n" if $lrc != 0 || $list !~ /^worktree\s+(.+)$/m;
	$root = $1;
}
chdir $root or die "worktree_gc: chdir $root: $!\n";

my $trunk_ref = "origin/$opt{'trunk'}";
if ($opt{'fetch'}) {
	my ($frc, $fout) = git('fetch', 'origin', '--quiet');
	say_line("# fetch failed, judging against the local $trunk_ref: $fout") if $frc != 0;
}

my ($lrc, $list) = git('worktree', 'list', '--porcelain');
die "worktree_gc: cannot list worktrees\n" if $lrc != 0;

my @records;
my $cur = {};
for my $line (split /\n/, $list) {
	if ($line =~ /^worktree\s+(.+)$/) {
		push @records, $cur if $cur->{'path'};
		$cur = { path => $1 };
	}
	elsif ($line =~ /^HEAD\s+(\S+)$/)      { $cur->{'head'} = $1 }
	elsif ($line =~ /^branch\s+(.+)$/)     { $cur->{'branch'} = $1 }
	elsif ($line =~ /^detached$/)          { $cur->{'detached'} = 1 }
	elsif ($line =~ /^prunable\b(.*)$/)    { $cur->{'prunable'} = 1 }
}
push @records, $cur if $cur->{'path'};

my $primary = $records[0]->{'path'};
my ($here_rc, $here) = git('rev-parse', '--show-toplevel');
$here = ($here_rc == 0 && defined $here) ? $here : '';

sub in_use {
	my ($path) = @_;
	my $slash = "$path/";
	opendir(my $dh, '/proc') or return 0;
	for my $pid (grep { /^\d+$/ } readdir $dh) {
		my $cwd = readlink("/proc/$pid/cwd");
		next unless defined $cwd;
		return 1 if $cwd eq $path || index($cwd, $slash) == 0;
	}
	closedir $dh;
	return 0;
}

my ($removed, $kept, $pruned, $remotes) = (0, 0, 0, 0);

# A landed branch is rebased and re-versioned by the gate, so its patch id is not
# the trunk's and merge-base cannot see it. The subject survives both, and that
# is what says the work is on the trunk.
sub remote_landed {
	my ($sha, $ref) = @_;
	my ($mrc) = git('merge-base', '--is-ancestor', $sha, $trunk_ref);
	return 1 if $mrc == 0;
	my ($src, $subject) = capture('git', 'log', '-1', '--format=%s', $ref);
	return 0 unless $src == 0 && (defined $subject && length $subject);
	$subject =~ s/^\s*v\d+\.\d+\.\d+\s+-\s+//;
	$subject =~ s/\s+$//;
	return 0 unless length $subject;
	my (undef, $subjects) = capture('git', 'log', $trunk_ref, '--format=%s');
	return (defined $subjects && index($subjects, $subject) >= 0) ? 1 : 0;
}

for my $w ($opt{'remote-only'} ? () : @records) {
	my $path = $w->{'path'};

	if ($w->{'prunable'} || !-d $path) {
		say_line("prune   $path (directory is gone)");
		$pruned++;
		next;
	}
	if ($path eq $primary) {
		say_line("keep    $path (the primary checkout)");
		$kept++;
		next;
	}
	if (length $here && $path eq $here) {
		say_line("keep    $path (you are standing in it)");
		$kept++;
		next;
	}

	my $branch = $w->{'branch'} // '';
	$branch =~ s{^refs/heads/}{};
	my $name = length $branch ? $branch : '(detached)';
	my $head = $w->{'head'} // '';

	if (length $branch && $branch eq $opt{'trunk'}) {
		say_line("keep    $path [$name] (the trunk is checked out here)");
		$kept++;
		next;
	}

	# WIP is decided before age: a worktree with any unfinished work is never a
	# candidate, however long it has sat there. A detached head is judged by its
	# commit, not skipped - an unmerged commit is work like any other.
	my $wip = '';
	if (!length $head) {
		$wip = 'no commit to compare';
	}
	else {
		my ($mrc) = git('merge-base', '--is-ancestor', $head, $trunk_ref);
		$wip = length $branch ? "not merged into $trunk_ref"
			: "detached at a commit not on $trunk_ref" if $mrc != 0;
	}
	if (length $wip) {
		say_line("wip     $path [$name] ($wip)");
		$kept++;
		next;
	}

	# Work that is not a commit still counts as WIP: a stash, or the checkpoint
	# an agent leaves while its task is open. Both live outside the tree git
	# status sees, so neither would stop a sweep on its own.
	my (undef, $stash) = git('-C', $path, 'stash', 'list');
	if (length $stash) {
		say_line("wip     $path [$name] (a stash is waiting in this repo)");
		$kept++;
		next;
	}
	if (-e "$path/.shots/AGENT-CHECKPOINT.md") {
		say_line("wip     $path [$name] (an agent checkpoint is open)");
		$kept++;
		next;
	}

	my (undef, $dirty) = capture('git', '-C', $path, 'status', '--porcelain');
	if (length $dirty) {
		say_line("wip     $path [$name] (uncommitted work)");
		$kept++;
		next;
	}

	if (in_use($path)) {
		say_line("wip     $path [$name] (a process is working in it)");
		$kept++;
		next;
	}

	# Activity is the newer of the directory and the last commit: an agent that
	# only edited files moves the directory, one that only committed moves %ct.
	if ($opt{'older-than'} > 0) {
		my $age_h = -M $path;
		my ($crc, $ct) = capture('git', '-C', $path, 'log', '-1', '--format=%ct');
		if ($crc == 0 && (defined $ct) && $ct =~ /^\s*(\d+)/) {
			my $commit_age = (time - $1) / 3600;
			$age_h = $commit_age if !defined $age_h || $commit_age < $age_h;
		}
		if (!defined $age_h || $age_h * 24 < $opt{'older-than'}) {
			say_line("idle    $path [$name] (younger than $opt{'older-than'} h)");
			$kept++;
			next;
		}
	}

	if (!$opt{'apply'}) {
		say_line("would   remove $path [$name]");
		$removed++;
		next;
	}

	my ($rrc, $rout) = git('worktree', 'remove', '--force', $path);
	if ($rrc != 0) {
		say_line("keep    $path [$name] (remove failed: $rout)");
		$kept++;
		next;
	}
	if (length $branch) {
		my ($brc, $bout) = git('branch', '-d', $branch);
		say_line("        branch $branch not deleted: $bout") if $brc != 0;
		if ($opt{'remote'}) {
			my ($rrc, $rout) = capture('git', 'push', 'origin', '--delete', $branch);
			say_line("        origin/$branch not deleted: $rout") if $rrc != 0;
		}
	}
	say_line("removed $path [$name]");
	$removed++;
}

if ($pruned) {
	git('worktree', 'prune');
	say_line("# pruned $pruned dead registration(s)");
}

# --- backup branches on origin --------------------------------------------
# agent_land backs a branch up to origin before it waits for the gate. After the
# landing the branch is redundant, and every one left behind is a "Compare & pull
# request" banner in GitHub. Only the agent/ namespace is touched: any other
# remote branch may be someone's deliberate work.
if ($opt{'remote'}) {
	my ($rls, $heads) = capture('git', 'ls-remote', '--heads', 'origin', 'refs/heads/agent/*');
	if ($rls != 0) {
		say_line('# could not list origin branches; skipped the remote sweep');
	}
	else {
		for my $line (split /\n/, $heads // '') {
			my ($sha, $ref) = split /\s+/, $line;
			next unless defined $ref && $ref =~ m{^refs/heads/(agent/.+)$};
			my $name = $1;
			if (!remote_landed($sha, "origin/$name")) {
				say_line("wip     origin/$name (its work is not on $trunk_ref)");
				$kept++;
				next;
			}
			if (!$opt{'apply'}) {
				say_line("would   remove origin/$name");
				$remotes++;
				next;
			}
			my ($drc, $dout) = capture('git', 'push', 'origin', '--delete', $name);
			if ($drc != 0) {
				say_line("keep    origin/$name (delete failed: $dout)");
				next;
			}
			say_line("removed origin/$name");
			$remotes++;
		}
	}
}

my $verb = $opt{'apply'} ? 'removed' : 'would remove';
say_line("# $verb $removed worktree(s) and $remotes origin branch(es); kept $kept");
exit 0;

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
worktree_gc.pl - sweep agent worktrees whose work is landed and idle
  perl scripts/worktree_gc.pl [--apply] [--older-than HOURS] [--trunk main] [--no-fetch]
                              [--remote-only] [--no-remote]
  report only unless --apply; a worktree is safe only when its work is landed,
  its tree is clean, nothing is open or waiting in it, and it is idle.
  The remote sweep deletes merged origin/agent/* branches (the lander's backups).
USAGE
	exit $code;
}
