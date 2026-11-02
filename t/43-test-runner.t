# tests-for: scripts/run_tests.pl
# covers:    The suite runs in parallel from scripts/run_tests.pl: each test file is an independent process with its own te...

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

# The suite runs in parallel from scripts/run_tests.pl: each test file is an
# independent process with its own temp sandbox, so prove can run several at
# once. The runner's job count is what the pre-push hook uses, so pin the
# command it builds: one job per core by default, capped at 8, never more jobs
# than cores even when asked, and a serial escape hatch.
#
# These checks use --dry-run only - they must never launch the suite from
# inside the suite.

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

sub detected_cores {
	for my $cmd ('nproc', 'getconf _NPROCESSORS_ONLN') {
		my $n = qx{$cmd 2>/dev/null};
		chomp $n;
		return $n if defined $n && $n =~ /^\d+$/ && $n > 0;
	}
	return undef;
}

my $cores = detected_cores();

# 1. bare invocation: parallel, capped at 8, and defaulting to t/
my ($rc, $out) = dry();
is($rc, 0, 'the runner exits cleanly');
like($out, qr/^prove -l -j (\d+) t\n$/, 'bare run is parallel and defaults to t/');
my ($jobs) = $out =~ /-j (\d+)/;
my $expected = defined $cores && $cores < 8 ? $cores : 8;
is($jobs, $expected, "the default job count is min(8, cores) (cores=$cores)");

# 2. --serial turns parallel off
($rc, $out) = dry('--serial');
like($out, qr/^prove -l t\n$/, '--serial drops the job flag');

# 3. an explicit job count passes through, clamped to the cores
($rc, $out) = dry('--jobs=3');
like($out, qr/^prove -l -j 3 t\n$/, '--jobs=3 is honoured');

if (defined $cores) {
	($rc, $out) = dry('--jobs', $cores + 40);
	my ($asked) = $out =~ /-j (\d+)/;
	is($asked, $cores, 'a job count above the core count is clamped');
}

# 4. prove switches and targets pass through, with t/ appended only when there
#    is no target
($rc, $out) = dry('-v', 't/01-names.t');
like($out, qr/^prove -l -j \d+ -v t\/01-names\.t\n$/, 'targets pass through untouched');

($rc, $out) = dry('-v');
like($out, qr/^prove -l -j \d+ -v t\n$/, 'a switch alone still gets the t/ target');

# 5. a bad --jobs is refused rather than silently serialised
($rc, $out) = dry('--jobs=0');
isnt($rc, 0, '--jobs=0 is refused');

done_testing();
