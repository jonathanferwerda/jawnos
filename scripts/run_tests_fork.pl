#!/usr/bin/perl

# Run the regression suite in forked children from one boot.
#
# `prove` starts a Perl process per test file, and each one re-loads
# subroutines.pl (about half a second, ~50s of CPU across the suite). This
# runner boots the harness once, then forks one child per test file. The child
# inherits the loaded app, gets its own copy-on-write address space, and runs
# exactly as it would under prove - the same Test::More output, captured to a
# temp file and parsed here.
#
#   perl scripts/run_tests_fork.pl                 every t/*.t, min(8, cores) at once
#   perl scripts/run_tests_fork.pl --jobs 4        a specific job count
#   perl scripts/run_tests_fork.pl --serial        one test at a time
#   perl scripts/run_tests_fork.pl -v t/01-names.t verbose TAP
#   perl scripts/run_tests_fork.pl t/01-names.t t/02-formatters.t
#
# Every run names the short commit it started on, on the same summary line as
# the file and assertion counts, and warns on stderr if HEAD moved under it (the
# auto-updater pulling mid-suite). The tests that ran still pass; the results,
# though, belong to neither commit alone, so they are not attributed to one.
#
# This is what scripts/run_tests.pl uses. `prove -l t` still works if you want
# the old path (scripts/run_tests.pl --prove).
#
# Each child gets `$0` and `$FindBin::Bin` pointed at its own test file, so the
# `use lib "$FindBin::Bin/lib"` line every test opens with still resolves.
# Nothing is shared after the fork: a test that chdirs, localises %ENV, or opens
# a socket cannot affect its siblings.

use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use File::Basename qw(dirname basename);
use File::Spec ();
use File::Temp qw(tempfile);
use FindBin ();
use Getopt::Long qw(GetOptions);
use POSIX ();
use Time::HiRes qw(time);

my $MAX_JOBS = 8;

my $root = abs_path("$FindBin::Bin/..");
die "run_tests_fork: cannot find the repo root\n"
	unless defined $root && -f "$root/perl/subroutines.pl";
chdir $root or die "run_tests_fork: chdir $root: $!\n";
$ENV{JAWNOS_ROOT} = $root;

# A pre-push hook exports GIT_DIR (and friends) to the suite. Every test that
# builds a throwaway git repo would inherit it, and `git -C <temp>` would act on
# this checkout. Start every run with the git environment cleared.
delete @ENV{qw(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR)};

# The box auto-updates: a git watcher pulls and restarts the app, sometimes while
# a suite is mid-flight. One run that began on one commit and ended on another
# still prints one summary, and that summary is then credited to whichever
# commit happened to be HEAD. Stamp the tree here, stamp it again once the last
# child is reaped, and say so when the two disagree.
my $head_before = head_commit();

my ($jobs, $serial, $verbose, $quiet);
GetOptions(
	'jobs=s'    => \$jobs,
	'serial'    => sub { $serial = 1 },
	'verbose|v' => \$verbose,
	'quiet'     => \$quiet,
	'help|h'    => sub { usage(); exit 0 },
) or do { usage(); exit 2 };

if (defined $jobs && $jobs !~ /^\d+$/) {
	print STDERR "run_tests_fork: --jobs needs a positive number\n";
	exit 2;
}
if (defined $jobs && $jobs < 1) {
	print STDERR "run_tests_fork: --jobs needs a positive number\n";
	exit 2;
}
$serial = 1 if defined $jobs && $jobs == 1;
$jobs = 1 if $serial;
if (!defined $jobs) {
	my $cores = cores();
	$jobs = defined $cores ? $cores : 4;
	$jobs = $MAX_JOBS if $jobs > $MAX_JOBS;
	$jobs = 1 if $jobs < 1;
}

# --- the test list -----------------------------------------------------------

my @targets = @ARGV ? @ARGV : ('t');
my @tests;
for my $target (@targets) {
	my $path = $target =~ m{^/} ? $target : "$root/$target";
	$path = abs_path($path) // $path;
	if    (-d $path) { push @tests, sort glob("$path/*.t") }
	elsif (-f $path) { push @tests, $path }
	else             { print STDERR "run_tests_fork: no such test: $target\n"; exit 2 }
}
my %seen;
@tests = grep { !$seen{$_}++ } @tests;
if (!@tests) {
	print STDERR "run_tests_fork: no test files matched\n";
	exit 2;
}

# Longest first: a 10-second test started last sets the wall time even when
# every other job is idle. Durations from the previous run are a hint only;
# an unknown test sorts after the known ones.
my %hint = read_hints();
@tests = sort { ($hint{$b} // 0) <=> ($hint{$a} // 0) } @tests;

# --- boot once ---------------------------------------------------------------

# `use JawnOSTest` in a test must see this same load, so the module is required
# under the name that is on @INC (not by its absolute path).
unshift @INC, "$root/t/lib";
my $booted = eval { require 'JawnOSTest.pm'; 1 };
if (!$booted) {
	print STDERR "run_tests_fork: cannot boot the test harness: $@\n";
	exit 2;
}

# Booting JawnOSTest above swept abandoned scratch first (see _setup): the sweep
# has to happen before the harness asks tmpfs for its sandbox, or a full tmpfs
# stops the cleanup that would fix it. A dir whose stamped pid is dead goes now;
# a dir whose stamp never landed waits out a short grace, and any dir a live
# process names or still owns is left for the run using it.

# --- run ---------------------------------------------------------------------

my $started = time();
my (%running, @failed, @passed, %durations);
my $assertions = 0;

my @queue = @tests;
while (@queue || keys %running) {
	while (@queue && keys(%running) < $jobs) {
		start_test(shift @queue);
	}
	my $pid = waitpid(-1, 0);
	next unless $pid > 0 && $running{$pid};
	my $result = delete $running{$pid};
	finish_test($result, $?);
}

my $wall = time() - $started;
write_hints(%durations);

# --- say it ------------------------------------------------------------------

# The second stamp, taken before anything is printed so the warning cannot lag
# the numbers it is about.
my $head_after = head_commit();

if (@failed) {
	for my $f (@failed) {
		print "\n--- $f->{'display'} failed\n";
		print failure_excerpt($f);
	}
	print "\n";
}
# The commit stays on the existing summary line, after the numbers, so a
# reader grepping "N files, N assertions" is unaffected and every run names
# the tree it tested - an unknown tree is said out loud, never guessed.
printf "%d files, %d assertions, %.1f s wallclock (HEAD %s)\n",
	scalar(@tests), $assertions, $wall,
	(length $head_before ? $head_before : 'unknown');
print @failed ? "Result: FAIL (" . scalar(@failed) . " test file(s))\n"
              : "Result: PASS\n";

# A moved HEAD is a warning, not a failure: the tests that ran did pass. It is
# the attribution that is wrong, and only the person reading can decide what the
# result is worth, so both trees are named.
if (length $head_before && length $head_after && $head_after ne $head_before) {
	print STDERR "\nrun_tests_fork: WARNING: HEAD moved during this run: $head_before -> $head_after\n",
		"run_tests_fork: WARNING: these results span two trees; do not attribute them to either commit alone.\n";
}

exit(@failed ? 1 : 0);

# --- helpers -----------------------------------------------------------------

sub start_test {
	my ($test) = @_;
	my $display = $test;
	$display =~ s{^\Q$root\E/+}{};

	my ($fh, $tap) = tempfile('jawnos-tap-XXXXXX', TMPDIR => 1, UNLINK => 0);
	close $fh;

	my $pid = fork();
	die "run_tests_fork: fork: $!\n" unless defined $pid;

	if ($pid == 0) {
		# the child: all TAP goes to the temp file, never to our terminal
		open(STDOUT, '>', $tap) or POSIX::_exit(127);
		open(STDERR, '>&', \*STDOUT) or POSIX::_exit(127);
		# Test::Builder finalises in END; an unflushed STDERR would be lost if
		# that path leaves through POSIX::_exit. TAP goes to STDOUT, so it needs the
		# same: a child that stopped through one of the guards above, or on a
		# handled signal, flushed nothing and the run reported a failure with no
		# assertion to read (that is how t/75 once failed with no 'not ok').
		select(STDERR); $| = 1; select(STDOUT); $| = 1;
		chdir $root or POSIX::_exit(127);

		# Each test gets its own copy of the house database; see JawnOSTest.
		if (!eval { JawnOSTest::isolate(); 1 }) {
			print STDERR "\n# run_tests_fork: database isolation failed: $@\n";
		}

		# FindBin was loaded for the runner; point it at this test before the
		# test's `use lib "$FindBin::Bin/lib"` compiles.
		$0 = $test;
		my $dir = dirname($test);
		$FindBin::Bin = $FindBin::RealBin = $dir;
		$FindBin::Script = $FindBin::RealScript = basename($test);

		# `do FILE` catches a runtime die into $@ instead of propagating it. A
		# caught require inside a module (IO::Compress::Zip probes optional
		# adapters) also lands there, so only report it when the test never got
		# as far as declaring a plan - that is the shape of a real die.
		$@ = '';
		do $test;
		my $err = $@;
		my $planned = 0;
		if (defined $Test::Builder::Test) {
			$planned = eval { $Test::Builder::Test->has_plan ? 1 : 0 };
		}
		if ($err && !$planned) {
			print STDERR "\n# run_tests_fork: $err\n";
			exit 3;
		}
		exit 0;
	}

	$running{$pid} = {
		test    => $test,
		display => $display,
		tap     => $tap,
		start   => time(),
	};
	return;
}

sub finish_test {
	my ($result, $status) = @_;
	my $tap = slurp($result->{'tap'});
	unlink $result->{'tap'};

	my $elapsed = time() - $result->{'start'};
	my $exit    = $status >> 8;
	my $signal  = $status & 127;
	my ($bail)  = $tap =~ /^Bail out!/m ? 1 : 0;
	# a TODO failure is an expected failure; an ok with TODO is an unexpected
	# success, which is a failure
	my $fails = 0;
	for my $line (split /\n/, $tap) {
		if ($line =~ /^not ok\b/) {
			$fails++ unless $line =~ /#\s*TODO\b/i;
		}
		elsif ($line =~ /^ok\b/ && $line =~ /#\s*TODO\b/i) {
			$fails++;
		}
	}
	my ($plan)  = $tap =~ /^1\.\.(\d+)/m;
	my $passing = defined $plan && !$fails && !$bail && !$signal && $exit == 0;

	$assertions += $plan if defined $plan;
	$durations{ $result->{'display'} } = $elapsed;

	print $tap if $verbose;
	printf "%-34s %s %6d ms\n", $result->{'display'},
		($passing ? 'ok' : 'FAIL'), $elapsed * 1000
		unless $quiet && $passing;

	if ($passing) {
		push @passed, $result;
	}
	else {
		$result->{'tap'} = $tap;
		$result->{'exit'} = $exit;
		$result->{'signal'} = $signal;
		push @failed, $result;
	}
	return;
}

sub failure_excerpt {
	my ($result) = @_;
	my $tap = $result->{'tap'} // '';
	my @lines = split /\n/, $tap;
	unless (@lines) {
		# Name how it ended, so the next silent death says which kind it was.
		my $exit   = $result->{'exit'}   // 0;
		my $signal = $result->{'signal'} // 0;
		return "  (no output; the child exited $exit"
			. ($signal ? " on signal $signal" : '')
			. " before printing TAP)\n";
	}

	# the failing assertions and their diagnostics, plus the last lines that
	# explain a die or a missing plan
	my @out;
	for my $i (0 .. $#lines) {
		next unless $lines[$i] =~ /^not ok\b/ || $lines[$i] =~ /^#\s*Looks like/
			|| $lines[$i] =~ /^#\s*run_tests_fork:/;
		push @out, @lines[$i .. ($i + 3 > $#lines ? $#lines : $i + 3)];
	}
	@out = @lines[-20 .. $#lines] if !@out && @lines > 20;
	@out = @lines if !@out;
	@out = @out[0 .. 39] if @out > 40;
	return join('', map { "  $_\n" } @out);
}

# --- duration hints ---------------------------------------------------------
# A scratch file, not repo state: it only decides the start order.

sub times_file {
	return $ENV{'JAWNOS_TEST_TIMES'} if defined $ENV{'JAWNOS_TEST_TIMES'};
	return "/tmp/jawnos-test-times-$<";
}

sub read_hints {
	open(my $fh, '<', times_file()) or return ();
	my %h;
	while (my $line = <$fh>) {
		chomp $line;
		next unless $line =~ /^(\d+(?:\.\d+)?)\t(.+)$/;
		$h{$2} = $1;
	}
	close $fh;
	return %h;
}

sub write_hints {
	my (%h) = @_;
	return unless %h;
	my %all = read_hints();          # keep the tests this run did not run
	$all{$_} = $h{$_} for keys %h;
	my $file = times_file();
	my $tmp  = "$file.$$";
	open(my $fh, '>', $tmp) or return;
	print $fh "$all{$_}\t$_\n" for sort keys %all;
	close $fh;
	rename($tmp, $file) or unlink $tmp;
	return;
}

sub slurp {
	my ($file) = @_;
	open(my $fh, '<', $file) or return '';
	local $/;
	my $text = <$fh>;
	close $fh;
	return defined $text ? $text : '';
}

# The short HEAD, or '' when nothing can be read. A tarball checkout, a missing
# git, or a broken repository must not stop the suite - and git's own "fatal:
# not a git repository" is not this run's news, so the probe is silent. The
# summary then says the tree is unknown instead of naming the wrong one.
sub head_commit {
	my $pid = open(my $fh, '-|');
	return '' unless defined $pid;
	if (!$pid) {
		open(STDERR, '>', File::Spec->devnull);
		exec('git', '-C', $root, 'rev-parse', '--short', 'HEAD')
			or POSIX::_exit(127);
	}
	my $out = <$fh>;
	close $fh;
	return '' unless defined $out && $out =~ /^([0-9a-f]{4,40})\s*$/;
	return $1;
}

sub cores {
	my @probes = (
		['nproc'],
		['getconf', '_NPROCESSORS_ONLN'],
		['sysctl', '-n', 'hw.ncpu'],
	);
	for my $probe (@probes) {
		open(my $fh, '-|', @$probe) or next;
		my $out = <$fh>;
		close $fh;
		next unless defined $out && $out =~ /^\s*(\d+)\s*$/;
		return $1 if $1 > 0;
	}
	return undef;
}

sub usage {
	print <<'USAGE';
Usage: perl scripts/run_tests_fork.pl [options] [test files or directories...]

  --jobs N   run N test files at once (clamped to the core count by
             scripts/run_tests.pl; this script honours what it is given)
  --serial   run one file at a time
  -v         print each test's TAP
  --quiet    only print failures

With no paths this runs every t/*.t. The app environment is booted once and
forked per test; scripts/run_tests.pl is the front door.
USAGE
}
