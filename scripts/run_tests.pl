#!/usr/bin/perl

# Run the t/ regression suite in parallel.
#
#   perl scripts/run_tests.pl                  every test, min(8, cores) jobs
#   perl scripts/run_tests.pl -v t/01-names.t  switches and targets go to prove
#   perl scripts/run_tests.pl --jobs 4         a specific job count
#   perl scripts/run_tests.pl --serial         one job (prove's default)
#   perl scripts/run_tests.pl --dry-run        print the command, run nothing
#
# Each test file is an independent process with its own temp sandbox
# (t/lib/JawnOSTest.pm), so files can run at once. Measured on the 12-core
# house box: serial ~46 s, -j4 ~20.5 s, -j6 ~16 s, -j8 ~14.5 s, -j12 ~15 s.
# Past 8 jobs the suite's own CPU roughly doubles and stops helping, so the
# default caps at 8 (and never exceeds the core count) to leave room for the
# running app on this shared machine.

use strict;
use warnings;

my $MAX_JOBS = 8;

my ($jobs, $serial, $dry, $jobs_given);
my @pass;
while (@ARGV) {
	my $arg = shift @ARGV;
	if    ($arg eq '--serial')  { $serial = 1 }
	elsif ($arg eq '--dry-run') { $dry = 1 }
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

# prove runs t/ when it is given no target; say so explicitly.
push @pass, 't' unless grep { !/^-/ } @pass;

my @cmd = ('prove', '-l');
push @cmd, ('-j', $jobs) unless $serial;
push @cmd, @pass;

if ($dry) {
	print join(' ', @cmd), "\n";
	exit 0;
}

exec @cmd;
die "run_tests: cannot run prove: $!\n";

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
Usage: perl scripts/run_tests.pl [prove switches/targets...]

  --jobs N   run N test files at once (clamped to the core count)
  --serial   run one file at a time
  --dry-run  print the prove command and exit
  --help     show this message

With no arguments this runs the whole suite with min(8, cores) jobs.
USAGE
}
