use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Slurp qw(read_file write_file);
use RepoSource;

# An update can advance HEAD and be killed before it writes the working tree.
# On the tablet the APK install killed the tree mid-checkout: 273 tracked files
# (all of perl/ and lib/, including perl/control.pl) were left missing, so the
# master could not start and the supervisor had nothing to heal it with. The
# repair lives in ./jawn, which is the one file that is running, and puts back
# only deletions: a modified file is somebody's work and must not move.

my $root = repo_root();
my $src = read_file("$root/jawn");

my $sub_at = index($src, 'sub tree_repair_deleted');
my $startup_at = index($src,
	'my ($tree_repaired) = &tree_repair_deleted($tree_root)');
my $control_at = index($src, "require './perl/control.pl'");

ok($sub_at >= 0, 'the master defines the deleted-file repair');
ok($startup_at > $sub_at, 'the master runs it at startup');
ok($control_at > $startup_at, 'before the first cwd-relative require');

my $have_git = `git --version 2>/dev/null`;

SKIP: {
	skip 'git is not installed', 9 unless $have_git;

	my $tmp = tempdir(CLEANUP => 1);
	my @git = ('git', '-C', $tmp);
	system(@git, 'init', '-q') == 0 or die "git init failed\n";
	system(@git, 'config', 'user.email', 'test@jawnos.invalid') == 0 or die;
	system(@git, 'config', 'user.name', 'JawnOS test') == 0 or die;
	write_file("$tmp/kept.txt", "kept\n");
	write_file("$tmp/changed.txt", "original\n");
	write_file("$tmp/gone.txt", "gone\n");
	system(@git, 'add', '-A') == 0 or die "git add failed\n";
	system(@git, 'commit', '-qm', 'fixture') == 0 or die "git commit failed\n";

	unlink "$tmp/gone.txt";
	write_file("$tmp/changed.txt", "work in progress\n");
	write_file("$tmp/untracked.txt", "new\n");

	my ($count, $out) = run_repair($tmp);
	is($count, 1, 'one missing tracked file restored');
	is(read_file("$tmp/gone.txt"), "gone\n", 'restored with its committed content');
	is(read_file("$tmp/changed.txt"), "work in progress\n",
		'a modified file is left alone');
	ok(-e "$tmp/untracked.txt", 'an untracked file is left alone');
	like($out, qr/restored/, 'the run says what it did');

	my ($again) = run_repair($tmp);
	is($again, 0, 'a second run has nothing to do');

	unlink "$tmp/kept.txt";
	my ($off) = run_repair($tmp, no_repair => 1);
	is($off, 0, 'JAWNOS_NO_TREE_REPAIR turns the repair off');
	ok(!-e "$tmp/kept.txt", 'and the deleted file stays deleted');

	my $bare = tempdir(CLEANUP => 1);
	write_file("$bare/loose.txt", "x\n");
	my ($none) = run_repair($bare);
	is($none, 0, 'a directory that is not a repository is left alone');
}

done_testing();

# The hook runs the repair on a named tree and exits before the master touches
# a socket, a log, or ~/.president - the same code path a real start uses.
sub run_repair {
	my ($dir, %opt) = @_;
	local $ENV{'JAWNOS_TREE_REPAIR_ONLY'} = $dir;
	local $ENV{'JAWNOS_NO_TREE_REPAIR'} = $opt{'no_repair'} ? 1 : undef;
	my $out = `$^X $root/jawn 2>&1`;
	my ($count) = $out =~ /^tree-repair: (\d+) /m;
	return (defined $count ? $count : -1, $out);
}
