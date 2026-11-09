# tests-for: scripts/run_tests.pl scripts/run_tests_fork.pl
# covers:    the suite runner - the fork engine, its job cap, and the prove fallback

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# scripts/run_tests.pl boots the harness once and forks one child per test
# (scripts/run_tests_fork.pl); prove remains the fallback for switches the
# engine does not understand. This file pins the command the runner builds,
# the job cap the pre-push hook relies on, and - by actually running the engine
# on two tiny tests - that a failure still fails the run.
#
# The command checks use --dry-run only; they must never launch the suite from
# inside the suite. The engine checks run two synthetic tests outside t/.

my $runner = "$FindBin::Bin/../scripts/run_tests.pl";

sub dry {
	my @args = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $runner, '--dry-run', @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout . $stderr);
}

sub run_engine {
	my @args = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $runner, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout . $stderr);
}

sub detected_cores {
	for my $cmd ('nproc', 'getconf _NPROCESSORS_ONLN') {
		my $n = qx{$cmd 2>/dev/null};
		chomp $n;
		return $n if defined $n && $n =~ /^\d+$/ && $n > 0;
	}
	return undef;
}

my $cores = detected_cores();

# 1. bare invocation: the fork engine, parallel, capped at 8, defaulting to t/
my ($rc, $out) = dry();
is($rc, 0, 'the runner exits cleanly');
like($out, qr{^\S*perl scripts/run_tests_fork\.pl --jobs (\d+) t\n$},
	'bare run uses the fork engine and defaults to t/');
my ($jobs) = $out =~ /--jobs (\d+)/;
my $expected = defined $cores && $cores < 8 ? $cores : 8;
is($jobs, $expected, "the default job count is min(8, cores) (cores=$cores)");

# 2. --serial turns parallel off
($rc, $out) = dry('--serial');
like($out, qr{^\S*perl scripts/run_tests_fork\.pl --serial t\n$},
	'--serial drops the job flag');

# 3. an explicit job count passes through, clamped to the cores
($rc, $out) = dry('--jobs=3');
like($out, qr{^\S*perl scripts/run_tests_fork\.pl --jobs 3 t\n$}, '--jobs=3 is honoured');

if (defined $cores) {
	($rc, $out) = dry('--jobs', $cores + 40);
	my ($asked) = $out =~ /--jobs (\d+)/;
	is($asked, $cores, 'a job count above the core count is clamped');
}

# 4. -v and targets pass through to the engine; t/ is appended only when there
#    is no target
($rc, $out) = dry('-v', 't/01-names.t');
like($out, qr{^\S*perl scripts/run_tests_fork\.pl --jobs \d+ -v t/01-names\.t\n$},
	'targets pass through untouched');
($rc, $out) = dry('-v');
like($out, qr{^\S*perl scripts/run_tests_fork\.pl --jobs \d+ -v t\n$},
	'a switch alone still gets the t/ target');

# 5. --prove builds the old prove command
($rc, $out) = dry('--prove');
like($out, qr{^prove -l -j \d+ t\n$}, '--prove is the old path');

($rc, $out) = dry('--prove', '--timer', 't/01-names.t');
like($out, qr{^prove -l -j \d+ --timer t/01-names\.t\n$},
	'--prove passes prove switches through');

# 6. a prove switch the engine does not know falls back automatically
($rc, $out) = dry('--timer');
like($out, qr{^prove -l -j \d+ --timer t\n$},
	'an unknown switch falls back to prove');

# 7. a bad --jobs is refused rather than silently serialised
($rc, $out) = dry('--jobs=0');
isnt($rc, 0, '--jobs=0 is refused');

# 8. the engine actually runs tests, and a failure is a failure
subtest 'the fork engine reports pass and failure' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $pass = "$dir/pass.t";
	my $fail = "$dir/fail.t";
	my $dies = "$dir/dies.t";
	for my $spec ([$pass, 'ok(1, \'fine\')'], [$fail, 'ok(0, \'broken\')']) {
		open(my $fh, '>', $spec->[0]) or die "$spec->[0]: $!";
		print $fh "use Test::More;\n$spec->[1];\ndone_testing;\n";
		close $fh;
	}
	open(my $dh, '>', $dies) or die "$dies: $!";
	print $dh "use Test::More;\nok(1, 'before');\ndie \"boom\\n\";\n";
	close $dh;

	my ($rc, $out) = run_engine($pass);
	is($rc, 0, 'a passing test exits 0');
	like($out, qr/pass\.t\s+ok/, 'and is reported ok');

	# one run with all three: a failure must fail the run, the passing test
	# must still pass, and a die must show its error
	($rc, $out) = run_engine($pass, $fail, $dies);
	isnt($rc, 0, 'a failure in any file fails the run');
	like($out, qr/pass\.t\s+ok/, 'the passing test still passes');
	like($out, qr/fail\.t\s+FAIL/, 'the failing test is reported FAIL');
	like($out, qr/not ok 1 - broken/, 'the failing assertion is printed');
	like($out, qr/boom/, 'a test that dies shows its error');
};

# 9. a worktree is seeded before the engine runs (config.json, test database)
{
	open(my $fh, '<', $runner) or die "$runner: $!";
	local $/;
	my $source = <$fh>;
	close $fh;
	like($source, qr/worktree_seed\.pl/,
		'the runner seeds a worktree before it starts the engine');
}

done_testing();
