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
#   2. its branch is an ancestor of origin/<trunk> (the work is on the trunk);
#   3. `git status --porcelain` there is empty (no modified or untracked file);
#   4. no process has its cwd inside it (an agent may still be working);
#   5. its directory is older than --older-than hours (default 24; 0 ignores).
# Dead registrations (the directory is already gone) are pruned in either mode:
# that is bookkeeping, not deletion.
#
# Exit: 0 always unless the repo cannot be read - the report is the product.

use strict;
use warnings;

use Getopt::Long qw(GetOptions);

my %opt = (trunk => 'main', 'older-than' => 24, fetch => 1, apply => 0);
GetOptions(
	'trunk=s'       => \$opt{'trunk'},
	'older-than=s'  => \$opt{'older-than'},
	'apply'         => \$opt{'apply'},
	'no-fetch'      => sub { $opt{'fetch'} = 0 },
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

my ($removed, $kept, $pruned) = (0, 0, 0);

for my $w (@records) {
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

	if (length $branch && $branch eq $opt{'trunk'}) {
		say_line("keep    $path [$name] (the trunk is checked out here)");
		$kept++;
		next;
	}

	my $ahead = $w->{'head'} // '';
	if (length $branch && length $ahead) {
		my ($mrc) = git('merge-base', '--is-ancestor', $ahead, $trunk_ref);
		if ($mrc != 0) {
			say_line("keep    $path [$name] (not merged into $trunk_ref)");
			$kept++;
			next;
		}
	}
	elsif (length $branch) {
		say_line("keep    $path [$name] (no commit to compare)");
		$kept++;
		next;
	}

	my (undef, $dirty) = capture('git', '-C', $path, 'status', '--porcelain');
	if (length $dirty) {
		say_line("keep    $path [$name] (uncommitted work)");
		$kept++;
		next;
	}

	if (in_use($path)) {
		say_line("keep    $path [$name] (a process is working in it)");
		$kept++;
		next;
	}

	if ($opt{'older-than'} > 0) {
		my $age_h = -M $path;
		if (!defined $age_h || $age_h * 24 < $opt{'older-than'}) {
			say_line("keep    $path [$name] (younger than $opt{'older-than'} h)");
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
	}
	say_line("removed $path [$name]");
	$removed++;
}

if ($pruned) {
	git('worktree', 'prune');
	say_line("# pruned $pruned dead registration(s)");
}

my $verb = $opt{'apply'} ? 'removed' : 'would remove';
say_line("# $verb $removed worktree(s); kept $kept");
exit 0;

sub usage {
	my ($code) = @_;
	print STDERR <<'USAGE';
worktree_gc.pl - sweep agent worktrees whose work is landed and idle
  perl scripts/worktree_gc.pl [--apply] [--older-than HOURS] [--trunk main] [--no-fetch]
  report only unless --apply; a worktree is safe only when its branch is merged
  into origin/<trunk>, its tree is clean, no process is in it, and it is idle.
USAGE
	exit $code;
}
