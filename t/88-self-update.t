# tests-for: perl/Manager.pl scripts/jawnos_update.pl
# covers:    The boot self-update (scripts/jawnos_update.pl) is how a machine that was installed from an image follows orig...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use Cwd qw(abs_path);
use File::Path qw(make_path);
use File::Slurp qw(read_file);
use File::Temp qw(tempdir);
use RepoSource;

# The boot self-update (scripts/jawnos_update.pl) is how a machine that was
# installed from an image follows origin/main without a person. Two bugs made it
# fail every time, and both were invisible on a developer box because the tree
# there is updated by hand:
#
#   1. it syntax-checked 'Manager.pl' while capture_in_repo had already cd'd to
#      the repo root, where the launcher is 'perl/Manager.pl'. Every run
#      fast-forwarded, failed the check and rolled back.
#   2. it compared &git(...) to 0 in scalar context, where git() returns its
#      *output* (the last list element), not the exit code - so the
#      --is-ancestor test always looked true.
#
# This file pins both, and proves the launcher compiles from where the updater
# actually stands.

my $root = repo_root();
my $src  = read_file("$root/scripts/jawnos_update.pl");

like( $src, qr/'perl',\s*'-c',\s*'perl\/Manager\.pl'/,
	'the compile check names the launcher with its directory' );
unlike( $src, qr/'perl',\s*'-c',\s*'Manager\.pl'/,
	'and never the bare launcher name capture_in_repo cannot find' );

unlike( $src, qr/if\s*\(\s*&git\([^\n]*\)\s*==\s*0\s*\)/,
	'no git() exit status is read in scalar context' );
unlike( $src, qr/if\s*&git\([^\n]*\)\s*==\s*0\s*;/,
	'no git() exit status is read in scalar context (postfix form)' );

# The updater's own proof, run from the same directory it uses.
my $out = `cd '$root' && perl -c perl/Manager.pl 2>&1`;
is( $?, 0, 'the launcher compiles from the repo root' ) or diag($out);

# --- functional: a broken checkout re-bootstraps, a healthy one follows ------ 
#
# A first boot that is killed mid-checkout (the update unit's 120s bound did
# this on VM 103) leaves a .git with no readable HEAD and zero-byte tracked
# files. The updater used to call fast_forward() on that and report 'error' on
# every boot. Both trees below are built with git in a temp dir; the version URL
# is a local file, so no network is used and the checkout the suite runs from is
# never touched.

sub write_text {
	my ( $path, $text ) = @_;
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh $text;
	close $fh;
}

sub version_of {
	my $v = read_file($_[0]);
	$v =~ s/\s+//g;
	return $v;
}

# Run a command and return (exit code, merged output).
sub run_in {
	my ( $dir, @command ) = @_;
	my $pid = open(my $fh, '-|');
	die "fork: $!" unless defined $pid;
	if ( !$pid ) {
		chdir $dir or exit 127;
		open STDERR, '>&', \*STDOUT or exit 127;
		exec @command;
		exit 127;
	}
	local $/;
	my $text = <$fh>;
	close $fh;
	return ( $? >> 8, defined $text ? $text : '' );
}

sub git_ok {
	my ( $dir, @args ) = @_;
	my ( $code, $output ) = run_in( $dir, 'git', @args );
	die "git @args failed in $dir: $output" if $code;
	return $output;
}

sub run_updater {
	my (%env) = @_;
	my $pid = open(my $fh, '-|');
	die "fork: $!" unless defined $pid;
	if ( !$pid ) {
		$ENV{$_} = $env{$_} for keys %env;
		exec $^X, "$root/scripts/jawnos_update.pl";
		exit 127;
	}
	local $/;
	my $text = <$fh>;
	close $fh;
	return ( $? >> 8, defined $text ? $text : '' );
}

my $tmp = tempdir( 'jawnos-update-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
make_path( "$tmp/home", "$tmp/published", "$tmp/seed/perl", "$tmp/src/perl" );

# The seed the image ships, used by rollback when a bootstrap fails.
write_text( "$tmp/seed/VERSION",        "0.1.1000\n" );
write_text( "$tmp/seed/perl/Manager.pl", "#!/usr/bin/perl\n1;\n" );
write_text( "$tmp/seed/tracked.txt",     "pristine\n" );

# A bare origin whose main has two commits: the second is what a checkout follows.
my $origin = "$tmp/origin.git";
git_ok( $tmp, 'init', '--bare', $origin );
git_ok( $origin, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
git_ok( "$tmp/src", 'init' );
git_ok( "$tmp/src", 'symbolic-ref', 'HEAD', 'refs/heads/main' );
write_text( "$tmp/src/VERSION",        "0.1.2000\n" );
write_text( "$tmp/src/perl/Manager.pl", "#!/usr/bin/perl\n1;\n" );
write_text( "$tmp/src/tracked.txt",     "one\n" );
git_ok( "$tmp/src", '-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'add', '-A' );
git_ok( "$tmp/src", '-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-m', 'seed' );
git_ok( "$tmp/src", 'remote', 'add', 'origin', $origin );
git_ok( "$tmp/src", 'push', '-u', 'origin', 'main' );

# The healthy checkout starts at the first commit.
my $healthy = "$tmp/healthy";
git_ok( $tmp, 'clone', $origin, $healthy );

# And one with a valid HEAD but an unreadable index: git status fails, which is
# the other broken-checkout shape the updater must repair.
my $corrupt = "$tmp/corrupt";
git_ok( $tmp, 'clone', $origin, $corrupt );

write_text( "$tmp/src/VERSION",     "0.1.2001\n" );
write_text( "$tmp/src/tracked.txt", "two\n" );
git_ok( "$tmp/src", '-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'add', '-A' );
git_ok( "$tmp/src", '-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-m', 'next' );
git_ok( "$tmp/src", 'push', 'origin', 'main' );
write_text( "$tmp/published/VERSION", "0.1.2001\n" );
write_text( "$corrupt/.git/index", "this is not a git index\n" );
my ($index_head) = run_in( $corrupt, 'git', 'rev-parse', '--verify', 'HEAD' );
is( $index_head, 0, 'the corrupt-index tree still has a readable HEAD' );

# What an interrupted first boot left behind: files at zero-byte-adjacent state,
# a .git with a zero-length branch ref and no commit to read.
my $broken = "$tmp/broken";
make_path("$broken/perl", "$broken/.git/refs/heads");
write_text( "$broken/VERSION",        "0.1.1900\n" );
write_text( "$broken/perl/Manager.pl", "#!/usr/bin/perl\n1;\n" );
write_text( "$broken/tracked.txt",     "old-broken\n" );
git_ok( $broken, 'init' );
git_ok( $broken, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
git_ok( $broken, 'remote', 'add', 'origin', $origin );
write_text( "$broken/.git/refs/heads/main", '' );
my ($broken_head) = run_in( $broken, 'git', 'rev-parse', '--verify', 'HEAD' );
isnt( $broken_head, 0, 'the broken tree really has no readable HEAD' );

# A third tree whose bootstrap cannot fetch, so the seed rollback is exercised.
my $failed = "$tmp/failed";
make_path("$failed/perl", "$failed/.git/refs/heads");
write_text( "$failed/VERSION",        "0.1.1900\n" );
write_text( "$failed/perl/Manager.pl", "#!/usr/bin/perl\n1;\n" );
write_text( "$failed/tracked.txt",     "local-work\n" );
git_ok( $failed, 'init' );
git_ok( $failed, 'symbolic-ref', 'HEAD', 'refs/heads/main' );
git_ok( $failed, 'remote', 'add', 'origin', "$tmp/does-not-exist.git" );
write_text( "$failed/.git/refs/heads/main", '' );

my %common = (
	HOME               => "$tmp/home",
	JAWNOS_BRANCH      => 'main',
	JAWNOS_HOME        => "$tmp/home",
	JAWNOS_REMOTE      => $origin,
	JAWNOS_SEED_TREE   => "$tmp/seed",
	JAWNOS_UPDATE_LOG  => "$tmp/update.log",
	JAWNOS_USER        => ( ( getpwuid($<) )[0] || 'root' ),
	JAWNOS_VERSION_URL => "file://$tmp/published/VERSION",
);

# 1. The healthy path still fast-forwards.
my ( $code, $output ) = run_updater( %common, JAWNOS_REPO => $healthy );
is( $code, 0, 'the healthy update exits 0' ) or diag($output);
like( $output, qr/^JAWNOS_UPDATE_STATUS=updated$/m, 'the healthy checkout is updated' ) or diag($output);
is( version_of("$healthy/VERSION"), '0.1.2001', 'the healthy checkout follows the published version' );
is( read_file("$healthy/tracked.txt"), "two\n", 'and its tracked files moved with it' );

# 2. A broken checkout is re-bootstrapped instead of becoming a permanent error.
( $code, $output ) = run_updater( %common, JAWNOS_REPO => $broken );
is( $code, 0, 'the broken update exits 0' ) or diag($output);
like( $output, qr/^JAWNOS_UPDATE_STATUS=updated$/m, 'the broken checkout is re-bootstrapped' ) or diag($output);
is( version_of("$broken/VERSION"), '0.1.2001', 'the tracked VERSION is restored from the fetched commit' );
is( read_file("$broken/tracked.txt"), "two\n", 'the other tracked files are restored too' );
my ($repaired_head) = run_in( $broken, 'git', 'rev-parse', '--verify', 'HEAD' );
is( $repaired_head, 0, 'the re-bootstrapped checkout has a valid HEAD' );
like( read_file("$tmp/update.log"), qr/checkout is broken/, 'the log records the re-bootstrap' );

# 3. A valid HEAD with a corrupt index is repaired the same way.
( $code, $output ) = run_updater( %common, JAWNOS_REPO => $corrupt );
is( $code, 0, 'the corrupt-index update exits 0' ) or diag($output);
like( $output, qr/^JAWNOS_UPDATE_STATUS=updated$/m, 'a failing git status triggers a re-bootstrap' ) or diag($output);
is( version_of("$corrupt/VERSION"), '0.1.2001', 'the corrupt-index tree is restored too' );
my ($corrupt_status) = run_in( $corrupt, 'git', 'status', '--porcelain' );
is( $corrupt_status, 0, 'a fresh checkout has a working index again' );

# 4. A bootstrap that cannot fetch rolls back to the seed and removes the .git.
( $code, $output ) = run_updater( %common, JAWNOS_REMOTE => "$tmp/does-not-exist.git", JAWNOS_REPO => $failed );
is( $code, 0, 'a failed bootstrap still exits 0' ) or diag($output);
like( $output, qr/^JAWNOS_UPDATE_STATUS=error$/m, 'a failed bootstrap reports error' ) or diag($output);
is( read_file("$failed/tracked.txt"), "pristine\n", 'the seed tree was restored over the checkout' );
ok( !-d "$failed/.git", 'and the failed .git was removed for the next boot' );

done_testing();
