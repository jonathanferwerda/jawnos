#!/usr/bin/perl

# Run the t/ regression suite in parallel.
#
#   perl scripts/run_tests.pl                  every test, min(8, cores) jobs
#   perl scripts/run_tests.pl -v t/01-names.t  one file, verbose
#   perl scripts/run_tests.pl --jobs 4         a specific job count
#   perl scripts/run_tests.pl --serial         one file at a time
#   perl scripts/run_tests.pl --prove          the old prove path
#   perl scripts/run_tests.pl --dry-run        print the command, run nothing
#
# The engine is scripts/run_tests_fork.pl: it boots subroutines.pl once and
# forks one child per test file, instead of starting a fresh Perl and re-loading
# the app for every file (prove's way). The tests are unchanged - each still
# gets its own process and temp sandbox - and the TAP is parsed the same way.
#
# A prove switch the fork engine does not know (--timer, --failures, -Q, ...)
# falls back to prove automatically, as does --prove.
#
# Measured on the 12-core house box: the whole suite is ~12-20s with the fork
# engine. `prove -l t` is serial (~46s) and `prove -l -j8 t` is ~15s on an idle
# box; either way, never run bare `prove -l t` when iterating.
#
# The pre-push hook calls this script.

use strict;
use warnings;

my $MAX_JOBS = 8;

my ($jobs, $serial, $dry, $jobs_given, $prove);
my @pass;
while (@ARGV) {
	my $arg = shift @ARGV;
	if    ($arg eq '--serial')  { $serial = 1 }
	elsif ($arg eq '--dry-run') { $dry = 1 }
	elsif ($arg eq '--prove')   { $prove = 1 }
	elsif ($arg eq '--help')    { print_usage(); exit 0 }
	elsif ($arg eq '--jobs')    { $jobs_given = 1; $jobs = shift @ARGV }
	elsif ($arg =~ /^--jobs=(.*)$/) { $jobs_given = 1; $jobs = $1 }
	else                        { push @pass, $arg }
}
if ($jobs_given) {
	die "run_tests: --jobs needs a positive number\n" unless defined $jobs && $jobs =~ /^\d+$/ && $jobs > 0;
	my $cores = cores();
	$jobs = $cores if defined $cores && $jobs > $cores;
}
if (!$jobs_given) {
	my $cores = cores();
	$jobs = defined $cores ? $cores : 4;
	$jobs = $MAX_JOBS if $jobs > $MAX_JOBS;
	$jobs = 1 if $jobs < 1;
}
$serial = 1 if $jobs == 1;

# The fork engine understands -v/--verbose/--quiet; anything else is prove's.
my @switches = grep { /^-/ } @pass;
my @unknown  = grep { !($_ eq '-v' || $_ eq '--verbose' || $_ eq '--quiet') } @switches;
my @targets  = grep { !/^-/ } @pass;
my $engine   = ($prove || @unknown) ? 'prove' : 'fork';

my @cmd;
if ($engine eq 'fork') {
	@cmd = ($^X, 'scripts/run_tests_fork.pl');
	push @cmd, $serial ? '--serial' : ('--jobs', $jobs);
	push @cmd, grep { $_ eq '--quiet' } @switches;
	push @cmd, '-v' if grep { $_ eq '-v' || $_ eq '--verbose' } @switches;
	push @cmd, @targets ? @targets : 't';
}
else {
	@cmd = ('prove', '-l');
	push @cmd, ('-j', $jobs) unless $serial;
	push @cmd, @pass;
	push @cmd, 't' unless @targets;
}

if ($dry) {
	print join(' ', @cmd), "\n";
	exit 0;
}

exec @cmd;
die "run_tests: cannot run @cmd: $!\n";

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

sub print_usage {
	print <<'USAGE';
Usage: perl scripts/run_tests.pl [options] [test files or prove switches...]

  --jobs N   run N test files at once (clamped to the core count)
  --serial   run one file at a time
  --prove    use prove instead of the forking engine
  --dry-run  print the command and exit
  --help     show this message

With no paths this runs the whole suite with min(8, cores) jobs. A prove
switch the fork engine does not recognise falls back to prove.
USAGE
}
