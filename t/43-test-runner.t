# tests-for: scripts/run_tests.pl scripts/run_tests_fork.pl
# covers:    the suite runner - the fork engine, its job cap, the prove fallback,
#            and the commit stamp that names the tree a run actually tested

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

# Same run, streams kept apart: the moved-HEAD warning has to be on STDERR and
# the summary on STDOUT, or a script reading one gets the other's words.
sub run_engine_split {
	my @args = @_;
	my $err = gensym;
	my $pid = open3(my $in, my $out, $err, $^X, $runner, @args);
	close $in;
	local $/;
	my $stdout = <$out> // '';
	my $stderr = <$err> // '';
	waitpid($pid, 0);
	return ($? >> 8, $stdout, $stderr);
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

# --- the commit stamp --------------------------------------------------------
# The box auto-updates: a watcher pulls into the checkout and restarts the app,
# sometimes while a suite runs. The summary names the commit the run started on,
# and a HEAD that moves under the run is warned about without failing a green
# run. A stand-in git answers HEAD from a per-probe file, so both cases are
# exercised without this checkout's refs ever moving; every other subcommand is
# the real git, which the front door needs to seed a worktree.

sub write_pass {
	my ($dir, $name) = @_;
	my $path = "$dir/$name";
	open(my $fh, '>', $path) or die "$path: $!";
	print $fh "use Test::More;\nok(1, 'fine');\ndone_testing;\n";
	close $fh;
	return $path;
}

sub repo_head {
	open(my $fh, '-|', 'git', '-C', "$FindBin::Bin/..", 'rev-parse', '--short', 'HEAD')
		or return '';
	my $out = <$fh>;
	close $fh;
	chomp $out if defined $out;
	return defined $out && $out =~ /^[0-9a-f]{4,40}$/ ? $out : '';
}

# Returns the bin dir to prepend to PATH, or undef when the test cannot stand
# in for git. Answers live in $JAWNOS_FAKE_GIT_HEAD.1, .2, ... - one per probe.
sub fake_git {
	my ($dir) = @_;
	my $real = '';
	for my $path (split /:/, ($ENV{PATH} // '')) {
		next unless length $path && -f "$path/git" && -x "$path/git";
		$real = "$path/git" if "$path/git" =~ m{^[\w./+-]+$};
		last if $real;
	}
	return undef unless $real;

	my $bin = "$dir/bin";
	mkdir $bin or return undef;
	my $script = <<'SH';
#!/bin/sh
case " $* " in
*" rev-parse "*" HEAD "*)
	n=$(cat "$JAWNOS_FAKE_GIT_HEAD.n" 2>/dev/null || echo 0)
	n=$((n + 1))
	echo "$n" > "$JAWNOS_FAKE_GIT_HEAD.n"
	if [ -f "$JAWNOS_FAKE_GIT_HEAD.$n" ]; then
		cat "$JAWNOS_FAKE_GIT_HEAD.$n"
		exit 0
	fi
	echo "fatal: not a git repository (or any of the parent directories): .git" >&2
	exit 128
	;;
esac
exec REAL_GIT "$@"
SH
	$script =~ s{REAL_GIT}{$real};
	open(my $fh, '>', "$bin/git") or return undef;
	print $fh $script;
	close $fh;
	chmod 0755, "$bin/git" or return undef;
	return $bin;
}

# 10. every run names the commit it tested, on the summary line
subtest 'the summary names the commit the run tested' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my ($rc, $out) = run_engine(write_pass($dir, 'pass.t'));
	is($rc, 0, 'a passing run exits 0');
	like($out, qr/s wallclock \(HEAD [0-9a-f]{4,40}\)\n/,
		'the summary carries the short HEAD');
	my $head = repo_head();
	if (length $head) {
		like($out, qr/\(HEAD \Q$head\E\)/, "and it is this checkout's HEAD ($head)");
	}
	unlike($out, qr/\bWARNING\b/, 'one tree, so no warning');
};

# 11. a pull landing under the suite is named, and does not fail the run
subtest 'a run that spans two commits warns and still passes' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $bin = fake_git($dir) or plan skip_all => 'no git on PATH to stand in for';
	for my $spec ([1, 'a1b2c3d'], [2, 'e5f6a7b']) {
		open(my $fh, '>', "$dir/HEAD.$spec->[0]") or die "$dir/HEAD.$spec->[0]: $!";
		print $fh "$spec->[1]\n";
		close $fh;
	}

	local $ENV{PATH} = "$bin:$ENV{PATH}";
	local $ENV{JAWNOS_FAKE_GIT_HEAD} = "$dir/HEAD";
	my ($rc, $out, $err) = run_engine_split(write_pass($dir, 'pass.t'));
	is($rc, 0, 'a green run stays green when HEAD moves');
	like($out, qr/\(HEAD a1b2c3d\)/, 'the summary names the commit the run started on');
	like($err, qr/\bWARNING\b/, 'the move is warned about on STDERR');
	like($err, qr/a1b2c3d/, 'the warning names the starting commit');
	like($err, qr/e5f6a7b/, 'and the one it finished on');
	like($err, qr/span two trees/, 'and says the results span two trees');
	unlike($out, qr/\bWARNING\b/, 'stdout stays parseable');
};

# 12. an unreadable HEAD is said out loud, quietly, and is not fatal
subtest 'an unreadable HEAD is reported as unknown, not fatal' => sub {
	my $dir = tempdir(CLEANUP => 1);
	my $bin = fake_git($dir) or plan skip_all => 'no git on PATH to stand in for';

	local $ENV{PATH} = "$bin:$ENV{PATH}";
	local $ENV{JAWNOS_FAKE_GIT_HEAD} = "$dir/HEAD";    # no .1 answer exists
	my ($rc, $out, $err) = run_engine_split(write_pass($dir, 'pass.t'));
	is($rc, 0, 'the suite still runs without a readable HEAD');
	like($out, qr/s wallclock \(HEAD unknown\)/, 'the summary says the tree is unknown');
	unlike($err, qr/fatal:/, "git's complaint is not leaked into the run");
	unlike($out, qr/\bWARNING\b/, 'nothing to warn about');
};

done_testing();
