# tests-for: lib/JawnOS/Domain/Run.pm
# covers:    a code update repairs a tree or moves it forward, never onto older code

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JawnOSTest;

# A checkout that is ahead of origin can still be handed an older tree: a code
# sync copies a peer's pack over the working tree (no .git), and the update
# resets that tree to origin/main. When origin itself is behind - a rewritten
# history, a stale fetch, or a peer whose advertised version outran its actual
# tree - that reset is a downgrade. Every push bumps VERSION, so a reset whose
# target reads older than HEAD is refused; a real fast-forward never asks.
#
# The peer half matters too: a peer bundle is fetched into FETCH_HEAD only, so
# it can never move refs/remotes/origin/main - the test pins that, because it is
# what rules out the "a peer dragged origin/main back" explanation.

my $have_git = `git --version 2>/dev/null`;
plan skip_all => 'git is not installed' unless $have_git;

subs::preload($_) for qw(git_repo_update git_peer_update git_checkout_normalize);

my $tmp = tempdir(CLEANUP => 1);

# Every refused downgrade has to say so: the guard writes the two versions it
# compared to the manager log.
my $log = "$tmp/manager.log";
write_file($log, '');
$subs::logfile = $log;
my $origin = "$tmp/origin.git";
my $seed   = "$tmp/seed";
my $dev    = "$tmp/device";

sub run {
	my ($cwd, @args) = @_;
	system('git', '-C', $cwd, @args) == 0
		or die "git -C $cwd @args failed\n";
}

sub capture {
	my ($cwd, @args) = @_;
	my $out = `git -C "$cwd" @args 2>&1`;
	chomp $out;
	return $out;
}

sub commit_version {
	my ($v, $msg) = @_;
	write_file("$seed/VERSION", "0.1.$v\n");
	write_file("$seed/code.txt", "version $v\n");
	run($seed, 'add', '-A');
	run($seed, 'commit', '-qm', $msg);
	return capture($seed, 'rev-parse', 'HEAD');
}

sub head_version {
	my ($repo) = @_;
	my $v = read_file("$repo/VERSION");
	$v =~ s/\s+//g;
	return $v;
}

run($tmp, 'init', '--bare', '-q', '--initial-branch=main', $origin);
run($tmp, 'clone', '-q', $origin, $seed);
for my $repo ($seed, $dev) {
	run($repo, 'config', 'user.email', 'test@jawnos.invalid') if -d $repo;
	run($repo, 'config', 'user.name', 'JawnOS test') if -d $repo;
}

my $v1 = commit_version(1, 'one');
run($seed, 'push', '-q', 'origin', 'main');

run($tmp, 'clone', '-q', $origin, $dev);
run($dev, 'config', 'user.email', 'test@jawnos.invalid');
run($dev, 'config', 'user.name', 'JawnOS test');

my $v2 = commit_version(2, 'two');
run($seed, 'push', '-q', 'origin', 'main');
my $v3 = commit_version(3, 'three');
run($seed, 'push', '-q', 'origin', 'main');

# ---- a genuine fast-forward still moves -----------------------------------
{
	my ($status, $out) = &subs::git_repo_update({ repo => $dev });
	is($status, 'updated', 'a genuine fast-forward updates the checkout');
	is(capture($dev, 'rev-parse', 'HEAD'), $v3, 'and lands on the authority tip');
	is(head_version($dev), '0.1.3', 'with the new VERSION in the worktree');
}

# ---- the incident shape: origin is rewritten one commit back --------------
run($seed, 'reset', '--hard', '-q', $v2);
run($seed, 'push', '-q', '--force', 'origin', 'main');
{
	my ($status, $out) = &subs::git_repo_update({ repo => $dev });
	is($status, 'ahead', 'a clean checkout ahead of a rewritten origin is left alone');
	is(capture($dev, 'rev-parse', 'HEAD'), $v3, 'and is not reset to the older origin');
}

# ---- a code sync lays the older peer tree over the newer checkout ---------
run($dev, 'checkout', '-q', $v2, '--', '.');
ok(length capture($dev, 'status', '--porcelain', '--untracked-files=no'),
	'the synced tree is dirty against the newer HEAD');
{
	my ($status, $out) = &subs::git_checkout_normalize({ repo => $dev, label => 'test' });
	is($status, 'reset', 'the code-sync normalize repairs the tree');
	is(capture($dev, 'rev-parse', 'HEAD'), $v3,
		'and restores HEAD instead of following the older origin');
	is(head_version($dev), '0.1.3', 'so the worktree keeps the newer VERSION');
	is(capture($dev, 'status', '--porcelain', '--untracked-files=no'), '',
		'and the checkout is clean again');
	like(read_file($log), qr/code sync: refused to reset to origin\/main \(0\.1\.2 is older than HEAD 0\.1\.3\)/,
		'and the refusal names the two versions in the log');
}

# ---- the watcher's dirty path has the same guard --------------------------
run($dev, 'checkout', '-q', $v2, '--', '.');
{
	my ($status, $out) = &subs::git_repo_update({ repo => $dev });
	is($status, 'reset', 'the watcher repairs a synced dirty tree');
	is(capture($dev, 'rev-parse', 'HEAD'), $v3,
		'without resetting it to the older origin');
	is(head_version($dev), '0.1.3', 'and the worktree runs the newer code');
}

# ---- a dirty sync still follows a newer authority forward -----------------
my $v6 = do {
	run($seed, 'reset', '--hard', '-q', $v3);
	commit_version(6, 'six');
};
{
	run($seed, 'push', '-q', 'origin', 'main');
	run($dev, 'checkout', '-q', $v2, '--', '.');
	my ($status, $out) = &subs::git_repo_update({ repo => $dev });
	is($status, 'reset', 'a dirty tree whose content origin has is repaired');
	is(capture($dev, 'rev-parse', 'HEAD'), $v6,
		'and follows a genuinely newer authority forward');
	is(head_version($dev), '0.1.6', 'with the authority VERSION');
}

# ---- an offline sync of an older tree cannot be committed as a downgrade --
{
	my $saved = capture($dev, 'remote', 'get-url', 'origin');
	run($dev, 'remote', 'set-url', 'origin', "$tmp/no-such-origin.git");
	run($dev, 'checkout', '-q', $v2, '--', '.');
	my ($status, $out) = &subs::git_checkout_normalize({ repo => $dev, label => 'offline test' });
	run($dev, 'remote', 'set-url', 'origin', $saved);
	is(capture($dev, 'rev-parse', 'HEAD'), $v6,
		'an offline sync of older code is not committed over the newer HEAD');
	is(head_version($dev), '0.1.6', 'and the newer VERSION stays in the worktree');
	is(capture($dev, 'status', '--porcelain', '--untracked-files=no'), '',
		'and the stale synced files are gone');
	like(read_file($log), qr/code sync: the synced tree \(0\.1\.2\) is older than HEAD; restored HEAD/,
		'and the refusal is logged with the reason');
}

# ---- a peer bundle is fetched into FETCH_HEAD, never origin/main ----------
{
	package FakePeerResponse;
	sub new { bless { body => $_[1] }, $_[0] }
	sub result { $_[0] }
	sub is_success { 1 }
	sub body { $_[0]->{'body'} }
	package FakePeerUA;
	sub new { bless { body => $_[1] }, $_[0] }
	sub inactivity_timeout { $_[0] }
	sub get { FakePeerResponse->new($_[0]->{'body'}) }
	package main;

	sub bundle_body {
		my ($rev) = @_;
		run($seed, 'reset', '--hard', '-q', $rev);
		my $path = "$tmp/peer-$$.bundle";
		run($seed, 'bundle', 'create', '-q', $path, 'HEAD');
		open(my $fh, '<:raw', $path) or die "open $path: $!\n";
		local $/;
		my $body = <$fh>;
		close $fh;
		return $body;
	}

	my $origin_before = capture($dev, 'rev-parse', 'refs/remotes/origin/main');
	my $older = bundle_body($v2);
	{
		my $ua = FakePeerUA->new($older);
		local *subs::peer_useragent = sub { ($ua, { manager => 'http://peer.invalid' }) };
		local *subs::signatorial_designer = sub { 'test-signatorial' };
		my ($status, $out) = &subs::git_peer_update({ repo => $dev, rm => { signatorial => 'x' }, force => 1 });
		is($status, 'diverged', 'an older peer cannot force the checkout back');
		is(capture($dev, 'rev-parse', 'HEAD'), $v6, 'so HEAD stays on the newer tree');
	}
	is(capture($dev, 'rev-parse', 'refs/remotes/origin/main'), $origin_before,
		'and the peer fetch never moved refs/remotes/origin/main');

	my $newer = do {
		run($seed, 'reset', '--hard', '-q', $v6);
		commit_version(7, 'seven');
		bundle_body('HEAD');
	};
	{
		my $ua = FakePeerUA->new($newer);
		local *subs::peer_useragent = sub { ($ua, { manager => 'http://peer.invalid' }) };
		local *subs::signatorial_designer = sub { 'test-signatorial' };
		my ($status, $out) = &subs::git_peer_update({ repo => $dev, rm => { signatorial => 'x' }, force => 1 });
		is($status, 'reset', 'a peer that really is newer still updates');
		is(head_version($dev), '0.1.7', 'and its code lands on the checkout');
	}
}

done_testing();
