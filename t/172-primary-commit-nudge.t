# tests-for: .githooks/pre-commit docs/AGENTS-concurrency.md
# covers:    A commit made in the primary checkout is refused whether or not a
#            linked worktree exists, with the move recipe printed and a named
#            lone-checkout escape; a commit in a linked worktree is allowed. A
#            commit from a worktree is refused while the primary has
#            uncommitted tracked changes (the write an agent left behind),
#            naming the files; untracked files such as config.json are not that
#            write.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

# The gate already refuses a dirty primary at landing time, but by then the work
# is committed in the wrong checkout and the lander cannot replay it. The
# pre-commit hook stops it at the first commit: the primary is the place the dev
# server runs, a linked worktree is the place to work. A warning would be easy to
# ignore, so this is a refusal with the stash -> worktree -> pop recipe. It moves
# no files itself; the deliberate lone-checkout escape is named. The guard does
# not wait for a linked worktree to exist, so a fresh lone checkout is caught on
# its first commit.

my $root = "$FindBin::Bin/..";
my $hook = "$root/.githooks/pre-commit";
my $hook_text = read_file($hook);

# --- the hook's shape --------------------------------------------------------
like($hook_text, qr/JAWNOS_ALLOW_PRIMARY_COMMIT/, 'the hook names the lone-checkout escape');
like($hook_text, qr/git worktree list --porcelain/, 'it reads the worktree list');
like($hook_text, qr/git stash push --include-untracked/, 'and prints the stash step');
like($hook_text, qr/git worktree add \.worktrees\//, 'the worktree step');
like($hook_text, qr/cd \.worktrees\/<task> && git stash pop/, 'and the pop step');
like($hook_text, qr{perl ~/jawnos/scripts/agent_land\.pl}, 'and the primary lander');
like($hook_text, qr/unset GIT_DIR GIT_WORK_TREE/, 'it drops the hook\'s GIT_DIR before reading the primary');
like($hook_text, qr/git status --porcelain --untracked-files=no/,
	'it reads the primary for tracked changes only');
like($hook_text, qr/JAWNOS_ALLOW_DIRTY_PRIMARY/, 'and names the dirty-primary escape');
like($hook_text, qr/do not revert it/, 'and says the writer is not to be reverted by the next agent');
unlike($hook_text, qr/\[\[/, 'the hook stays POSIX sh (no [[ ]])');
my $syntax = `sh -n '$hook' 2>&1`;
is($? >> 8, 0, 'the hook parses under sh') or diag($syntax);

# --- the doc an agent reads says the same ----------------------------------
my $doc = read_file("$root/docs/AGENTS-concurrency.md");
like($doc, qr/git config core\.hooksPath \.githooks/, 'the doc says how to enable the hooks');
like($doc, qr/refuses a commit in the primary/, 'and what the pre-commit hook refuses');
like($doc, qr/even when no linked worktree exists/, 'the refusal does not need a linked worktree');
like($doc, qr/JAWNOS_ALLOW_PRIMARY_COMMIT=1/, 'and names the override');
like($doc, qr/uncommitted tracked changes/, 'the doc names the primary-write refusal too');
like($doc, qr/JAWNOS_ALLOW_DIRTY_PRIMARY=1/, 'and its escape');
like($doc, qr/writes nothing tracked, so the checkout cannot go dirty/,
	'and says the seeded config.json and test database cannot dirty it');

# --- run the real hook in a throwaway repo ---------------------------------
sub quote { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }

sub git {
	my ($dir, @args) = @_;
	my $cmd = join(' ', map { &quote($_) } @args);
	my $out = `cd @{[ &quote($dir) ]} && git $cmd 2>&1`;
	return ($? >> 8, $out);
}

sub git_with_env {
	my ($dir, $env, @args) = @_;
	my $cmd = join(' ', map { &quote($_) } @args);
	my $assign = $env =~ /^(\w+)=(.*)$/s ? "$1=" . &quote($2) : '';
	my $out = `cd @{[ &quote($dir) ]} && $assign git $cmd 2>&1`;
	return ($? >> 8, $out);
}

my $repo = tempdir(CLEANUP => 1);
my $hookdir = "$repo/.githooks";
make_path($hookdir);
copy($hook, "$hookdir/pre-commit") or die "copy hook: $!";
chmod 0755, "$hookdir/pre-commit";

my ($rc, $out) = &git($repo, 'init', '-q');
is($rc, 0, 'a throwaway repo starts') or diag($out);
&git($repo, 'config', 'user.email', 'qa@example.invalid');
&git($repo, 'config', 'user.name', 'QA');
&git($repo, 'config', 'commit.gpgsign', 'false');
&git($repo, 'config', 'core.hooksPath', $hookdir);

write_file("$repo/base.txt", "base\n");
&git($repo, 'add', 'base.txt');
($rc, $out) = &git($repo, 'commit', '-m', 'base');
isnt($rc, 0, 'a lone checkout is refused, not only a shared one');
like($out, qr/commit refused: this is the primary checkout/, 'the lone refusal names the primary');
like($out, qr/JAWNOS_ALLOW_PRIMARY_COMMIT=1/, 'and names the escape');
($rc, $out) = &git_with_env($repo, 'JAWNOS_ALLOW_PRIMARY_COMMIT=1', 'commit', '-m', 'base');
is($rc, 0, 'the named escape seeds the base commit') or diag($out);

# A linked worktree makes this a shared checkout: the primary must not commit.
($rc, $out) = &git($repo, 'worktree', 'add', "$repo/wt", '-b', 'agent/test');
is($rc, 0, 'a linked worktree is added') or diag($out);

write_file("$repo/primary.txt", "primary\n");
&git($repo, 'add', 'primary.txt');
($rc, $out) = &git($repo, 'commit', '-m', 'primary');
isnt($rc, 0, 'a commit in the primary is refused while a worktree exists');
like($out, qr/commit refused: this is the primary checkout/, 'the refusal names the primary');
like($out, qr/git stash push --include-untracked/, 'and gives the stash recipe');
like($out, qr/JAWNOS_ALLOW_PRIMARY_COMMIT=1/, 'and the deliberate escape');

# The refused change is still staged, so the escape can take it.
($rc, $out) = &git_with_env($repo, 'JAWNOS_ALLOW_PRIMARY_COMMIT=1', 'commit', '-m', 'primary');
is($rc, 0, 'the named escape lets a single-agent commit through') or diag($out);
($rc, $out) = &git($repo, 'log', '-1', '--format=%s');
like($out, qr/^primary$/m, 'and the commit is the one that was staged');

# A linked worktree is the place the work is allowed to be committed.
write_file("$repo/wt/wt.txt", "wt\n");
&git("$repo/wt", 'add', 'wt.txt');
($rc, $out) = &git("$repo/wt", 'commit', '-m', 'worktree');
is($rc, 0, 'a linked worktree may commit') or diag($out);

# --- the write an agent left behind in the primary ---------------------------
# Untracked is not that write: config.json is copied in by design and only lets
# the suite boot, so it can never dirty the checkout or reach a commit.
write_file("$repo/config.json", "{}\n");
write_file("$repo/wt/wt.txt", "wt with config\n");
&git("$repo/wt", 'add', 'wt.txt');
($rc, $out) = &git("$repo/wt", 'commit', '-m', 'untracked primary');
is($rc, 0, 'an untracked config.json in the primary is not a source write') or diag($out);
unlink "$repo/config.json";

# A tracked edit there is the failure: the lander refuses every landing until it
# is gone, and by then the writer may be long done.
write_file("$repo/base.txt", "left behind\n");
&git($repo, 'add', 'base.txt');
my $wt_head = (&git("$repo/wt", 'rev-parse', 'HEAD'))[1];
write_file("$repo/wt/wt.txt", "wt blocked\n");
&git("$repo/wt", 'add', 'wt.txt');
($rc, $out) = &git("$repo/wt", 'commit', '-m', 'blocked');
isnt($rc, 0, 'a commit from a worktree is refused while the primary has tracked changes');
like($out, qr/uncommitted tracked changes/, 'the refusal names the failure');
like($out, qr/base\.txt/, 'and lists the file left in the primary');
like($out, qr/primary is read-only for agents/, 'and says why it is refused');
like($out, qr/git stash push -m "move to worktree"/, 'and how to move it out');
like($out, qr/do not revert it/, 'and not to revert somebody else\'s work');
like($out, qr/JAWNOS_ALLOW_DIRTY_PRIMARY=1/, 'and names the escape');
is((&git("$repo/wt", 'rev-parse', 'HEAD'))[1], $wt_head, 'the refused commit never happened');

# Unstaged is the same failure as staged.
&git($repo, 'reset', '--quiet');
($rc, $out) = &git("$repo/wt", 'commit', '-m', 'blocked again');
isnt($rc, 0, 'an unstaged edit in the primary refuses the commit too');
like($out, qr/base\.txt/, 'naming the same file');

# The escape is deliberate; a clean primary lets the commit through.
($rc, $out) = &git_with_env("$repo/wt", 'JAWNOS_ALLOW_DIRTY_PRIMARY=1', 'commit', '-m', 'escaped');
is($rc, 0, 'the named escape lets the worktree commit through') or diag($out);
&git($repo, 'checkout', '--', 'base.txt');
write_file("$repo/wt/wt.txt", "wt after clean\n");
&git("$repo/wt", 'add', 'wt.txt');
($rc, $out) = &git("$repo/wt", 'commit', '-m', 'clean primary again');
is($rc, 0, 'a clean primary lets the worktree commit again') or diag($out);

# With the worktree gone, the guard still refuses: it no longer depends on a
# linked worktree existing.
($rc, $out) = &git($repo, 'worktree', 'remove', '--force', "$repo/wt");
is($rc, 0, 'the worktree is removed') or diag($out);
write_file("$repo/lone.txt", "lone\n");
&git($repo, 'add', 'lone.txt');
($rc, $out) = &git($repo, 'commit', '-m', 'lone');
isnt($rc, 0, 'a lone checkout is refused again');
like($out, qr/JAWNOS_ALLOW_PRIMARY_COMMIT=1/, 'and names the escape');
($rc, $out) = &git_with_env($repo, 'JAWNOS_ALLOW_PRIMARY_COMMIT=1', 'commit', '-m', 'lone');
is($rc, 0, 'the escape commits in the lone checkout') or diag($out);

done_testing();
