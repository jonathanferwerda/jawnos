# tests-for: .githooks/pre-commit docs/AGENTS-concurrency.md
# covers:    A commit whose author or committer would not be the house identity
#            is refused in the house tree - whether the name came from
#            -c user.name, --author, or GIT_AUTHOR_*/GIT_COMMITTER_* - with the
#            correct command and a named escape in the refusal. The throwaway
#            repos t/ builds (no AGENTS.md, no scripts/agent_land.pl) still
#            commit as their own fixture identity.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Slurp qw(read_file write_file);
use File::Temp qw(tempdir);

my $root       = "$FindBin::Bin/..";
my $hook       = "$root/.githooks/pre-commit";
my $house_name = 'Jonathan Ferwerda';
my $house_mail = 'jonathan.ferwerda@outlook.com';

# t/172 owns the primary-checkout refusal. These throwaway repos are lone
# checkouts, so take its escape to reach the identity check that is under test.
$ENV{'JAWNOS_ALLOW_PRIMARY_COMMIT'} = '1';

# --- the hook's shape --------------------------------------------------------
my $hook_text = read_file($hook);
like($hook_text, qr/JAWNOS_ALLOW_FOREIGN_COMMIT/, 'the hook names the deliberate escape');
like($hook_text, qr/\Q$house_name\E/, 'it names the house author');
like($hook_text, qr/\Q$house_mail\E/, 'and the house email');
like($hook_text, qr/git var GIT_AUTHOR_IDENT/, 'it reads the identity git resolved');
like($hook_text, qr/git var GIT_COMMITTER_IDENT/, 'for author and committer alike');
like($hook_text, qr/\[ -f AGENTS\.md \].*\[ -f scripts\/agent_land\.pl \]/s,
	'it claims only the house tree');
unlike($hook_text, qr/\[\[/, 'the hook stays POSIX sh (no [[ ]])');
my $syntax = `sh -n '$hook' 2>&1`;
is($? >> 8, 0, 'the hook parses under sh') or diag($syntax);

# --- the docs an agent reads say the same ------------------------------------
my $doc = read_file("$root/docs/AGENTS-concurrency.md");
like($doc, qr/\Q$house_name <$house_mail>\E/, 'the worktree doc names the identity');
like($doc, qr/git -c user\.name=Zed/, 'and the shape that reached the trunk');
like($doc, qr/JAWNOS_ALLOW_FOREIGN_COMMIT=1/, 'and the escape');
like(read_file("$root/AGENTS.md"), qr/commit identity/,
	'the map points an agent at the identity rule');

# --- run the real hook in a throwaway repo -----------------------------------
sub shq { my $s = shift; $s =~ s/'/'\\''/g; return "'$s'" }

sub git {
	my ($dir, @args) = @_;
	my $cmd = join ' ', map { &shq($_) } @args;
	my $out = `cd @{[ &shq($dir) ]} && git $cmd 2>&1`;
	$out =~ s/\s+\z//;
	return ($? >> 8, $out);
}

sub git_env {
	my ($dir, $env, @args) = @_;
	my $cmd  = join ' ', map { &shq($_) } @args;
	my $vars = join ' ', map {
		my ($key, $value) = split /=/, $_, 2;
		"$key=" . &shq($value // '')
	} @$env;
	my $out = `cd @{[ &shq($dir) ]} && env $vars git $cmd 2>&1`;
	$out =~ s/\s+\z//;
	return ($? >> 8, $out);
}

sub new_repo {
	my (%opt) = @_;
	my $repo = tempdir(CLEANUP => 1);
	make_path("$repo/.githooks", "$repo/scripts");
	copy($hook, "$repo/.githooks/pre-commit") or die "copy hook: $!";
	chmod 0755, "$repo/.githooks/pre-commit";
	# The two files the guard uses to tell the house tree from a fixture repo.
	if ($opt{'house'}) {
		write_file("$repo/AGENTS.md", "# house\n");
		write_file("$repo/scripts/agent_land.pl", "# lander\n");
	}
	&git($repo, 'init', '-q');
	&git($repo, 'config', 'user.name', $opt{'name'} // $house_name);
	&git($repo, 'config', 'user.email', $opt{'mail'} // $house_mail);
	&git($repo, 'config', 'commit.gpgsign', 'false');
	&git($repo, 'config', 'core.hooksPath', '.githooks');
	write_file("$repo/tracked.txt", "one\n");
	&git($repo, 'add', 'tracked.txt');
	return $repo;
}

my $repo = &new_repo('house' => 1);
my ($rc, $out) = &git($repo, 'commit', '-m', 'base');
is($rc, 0, 'the house identity commits') or diag($out);
my ($ident_rc, $ident) = &git($repo, 'log', '-1', '--format=%an <%ae>|%cn <%ce>');
is($ident_rc, 0, 'the base commit is readable');
is($ident, "$house_name <$house_mail>|$house_name <$house_mail>",
	'author and committer are both the house');

my $base_head = (&git($repo, 'rev-parse', 'HEAD'))[1];

# Each shape that has put a stranger on the trunk, and the command that carries
# it. Every one must be refused, and leave HEAD alone.
my @refusals = (
	{
		label => '-c user.name/user.email (the Zed agent)',
		env   => [],
		args  => ['-c', 'user.name=Zed', '-c', 'user.email=zed@jawnos.local', 'commit', '-m', 'zed'],
		seen  => qr/Zed <zed\@jawnos\.local>/,
	},
	{
		label => '-c with the QA fixture identity',
		env   => [],
		args  => ['-c', 'user.name=JawnOS test', '-c', 'user.email=test@jawnos.invalid', 'commit', '-m', 'qa'],
		seen  => qr/JawnOS test <test\@jawnos\.invalid>/,
	},
	{
		label => '--author',
		env   => [],
		args  => ['commit', '--author=Other Person <other@example.invalid>', '-m', 'other'],
		seen  => qr/Other Person <other\@example\.invalid>/,
	},
	{
		label => 'GIT_AUTHOR_NAME/GIT_AUTHOR_EMAIL',
		env   => ['GIT_AUTHOR_NAME=Env Name', 'GIT_AUTHOR_EMAIL=env@example.invalid'],
		args  => ['commit', '-m', 'env author'],
		seen  => qr/Env Name <env\@example\.invalid>/,
	},
	{
		label => 'GIT_COMMITTER_NAME/GIT_COMMITTER_EMAIL',
		env   => ['GIT_COMMITTER_NAME=Env Committer', 'GIT_COMMITTER_EMAIL=committer@example.invalid'],
		args  => ['commit', '-m', 'env committer'],
		seen  => qr/Env Committer <committer\@example\.invalid>/,
	},
);

for my $case (@refusals) {
	write_file("$repo/tracked.txt", "change for $case->{'label'}\n");
	&git($repo, 'add', 'tracked.txt');
	($rc, $out) = &git_env($repo, $case->{'env'}, @{ $case->{'args'} });
	isnt($rc, 0, "$case->{'label'} is refused");
	like($out, qr/commit refused: git would record/, 'the refusal says what it would record');
	like($out, $case->{'seen'}, 'and names the identity it saw');
	like($out, qr/\Q$house_name <$house_mail>\E/, 'and the identity this checkout publishes as');
	like($out, qr/plain git commit/, 'and how to commit correctly');
	like($out, qr/JAWNOS_ALLOW_FOREIGN_COMMIT=1/, 'and the named escape');
	is((&git($repo, 'rev-parse', 'HEAD'))[1], $base_head, 'the refused commit never happened');
}

# The escape is deliberate: importing somebody else's patch keeps its author.
($rc, $out) = &git_env(
	$repo,
	['JAWNOS_ALLOW_FOREIGN_COMMIT=1'],
	'-c', 'user.name=Zed', '-c', 'user.email=zed@jawnos.local', 'commit', '-m', 'imported',
);
is($rc, 0, 'the named escape lets the commit through') or diag($out);
($ident_rc, $ident) = &git($repo, 'log', '-1', '--format=%an <%ae>|%s');
is($ident, 'Zed <zed@jawnos.local>|imported', 'and the imported author is preserved');

# A fixture repo is not the house tree: t/172 builds one and commits as QA.
my $fixture = &new_repo('name' => 'QA', 'mail' => 'qa@example.invalid');
($rc, $out) = &git($fixture, 'commit', '-m', 'fixture');
is($rc, 0, 'a fixture repo still commits as its own identity') or diag($out);
($ident_rc, $ident) = &git($fixture, 'log', '-1', '--format=%an <%ae>');
is($ident, 'QA <qa@example.invalid>', 'and the fixture identity is unchanged');

done_testing();
