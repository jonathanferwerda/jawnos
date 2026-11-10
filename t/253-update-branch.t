# tests-for: lib/JawnOS/Domain/Run.pm lib/JawnOS/Domain/Git.pm lib/JawnOS/Domain/Records2.pm lib/JawnOS/Domain/Loader.pm templates/configure/device_lister/body.html.ep templates/configure/device_lister.html.ep public/js/manager/configure.js perl/help/topics_configure.pl
# covers:    the per-machine update branch - its setting, the pull it drives,
#           and the Dev panel control beside the update cadence

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use JawnOSTest;

my $have_git = `git --version 2>/dev/null`;
plan skip_all => 'git is not installed' unless $have_git;

subs::preload($_) for qw(git_repo_update git_origin_has_tree sync_update_branch_get);

# --- the setting -------------------------------------------------------------
# A machine's branch is a setting like its cadence: main is the released code
# and working is the newest tested code. An unset or unknown value must fall
# back to main, never to a branch nobody publishes.
sub with_setting {
	my ($value, $code) = @_;
	local *subs::setting_grabber = sub {
		my ($q) = @_;
		return undef unless ref $q eq 'HASH' && ($q->{'setting'} // '') eq 'update_branch';
		return $value;
	};
	return $code->();
}

is(with_setting(undef, sub { subs::sync_update_branch_get('test') }), 'main',
	'an unset branch falls back to main');
is(with_setting('main', sub { subs::sync_update_branch_get('test') }), 'main',
	'main is kept as chosen');
is(with_setting('working', sub { subs::sync_update_branch_get('test') }), 'working',
	'working is accepted');
is(with_setting('feature/x', sub { subs::sync_update_branch_get('test') }), 'main',
	'an unknown branch falls back to main');

# --- the pull ----------------------------------------------------------------
# The watcher must fetch and fast-forward the branch this machine chose. Both
# branches exist on origin; a clone of main learns nothing from working unless
# the branch is named.
my $tmp    = tempdir(CLEANUP => 1);
my $origin = "$tmp/origin.git";
my $seed   = "$tmp/seed";
my $dev    = "$tmp/dev";
my $dev2   = "$tmp/dev2";

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

run($tmp, 'init', '--bare', '-q', '--initial-branch=main', $origin);
run($tmp, 'clone', '-q', $origin, $seed);
run($seed, 'config', 'user.email', 'test@jawnos.invalid');
run($seed, 'config', 'user.name', 'JawnOS test');

write_file("$seed/VERSION", "0.1.1\n");
write_file("$seed/code.txt", "one\n");
run($seed, 'add', '-A');
run($seed, 'commit', '-qm', 'v0.1.1 - one');
run($seed, 'push', '-q', 'origin', 'main');

run($seed, 'checkout', '-q', '-b', 'working');
write_file("$seed/VERSION", "0.1.2\n");
write_file("$seed/code.txt", "two\n");
run($seed, 'add', '-A');
run($seed, 'commit', '-qm', 'v0.1.2 - two');
run($seed, 'push', '-q', 'origin', 'working');
run($seed, 'checkout', '-q', 'main');

run($tmp, 'clone', '-q', $origin, $dev);
run($tmp, 'clone', '-q', $origin, $dev2);

my ($st, $out) = subs::git_repo_update({ repo => $dev, branch => 'working' });
is($st, 'updated', 'the chosen branch is the one it fast-forwards') or diag($out);
is(capture($dev, 'rev-parse', 'HEAD'), capture($seed, 'rev-parse', 'working'),
	'HEAD is the working tip');

my ($main_st, $main_out) = subs::git_repo_update({ repo => $dev2, branch => 'main' });
is($main_st, 'current', 'a machine on main is already current, though working is ahead')
	or diag($main_out);
is(capture($dev2, 'rev-parse', 'HEAD'), capture($seed, 'rev-parse', 'main'),
	'and it stays on the main tip');

my $working_tree = capture($seed, 'rev-parse', 'working^{tree}');
is(subs::git_origin_has_tree($dev2, $working_tree, 'working'), 1,
	'the working tree is known upstream when the branch is named');
is(subs::git_origin_has_tree($dev2, $working_tree, 'main'), 0,
	'and not on main');

# --- the control -------------------------------------------------------------
# The choice lives in the Dev panel beside Check every, is per machine, and the
# watcher and the Update now button both read it.
my $body = read_file("$FindBin::Bin/../templates/configure/device_lister/body.html.ep");
like($body, qr/id="update_branch_select"[^>]*class="update_branch_select"/,
	'the Dev panel has the branch select');
like($body, qr/class="update_branch_select"[^>]*data-device=/, 'it is saved for this machine');
like($body, qr/value="working"/, 'working is offered');
like($body, qr/value="main"/, 'and main is offered');
like(read_file("$FindBin::Bin/../templates/configure/device_lister.html.ep"),
	qr/sync_update_branch_get/, 'the page reads the setting');
like(read_file("$FindBin::Bin/../public/js/manager/configure.js"),
	qr/setting: 'update_branch'/, 'the select saves it');
like(read_file("$FindBin::Bin/../lib/JawnOS/Domain/Git.pm"),
	qr/sync_update_branch_get/, 'the watcher follows the machine branch');
like(read_file("$FindBin::Bin/../lib/JawnOS/Domain/Records2.pm"),
	qr/sub sync_update_branch_get/, 'the setting has one reader');
like(read_file("$FindBin::Bin/../lib/JawnOS/Domain/Run.pm"),
	qr/\$branch = \$opts->\{'branch'\} \|\| 'main'/,
	'the pull takes the branch it was given and defaults to main');

done_testing();
