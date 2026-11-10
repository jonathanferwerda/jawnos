#!/usr/bin/env perl

# One named job, one process: the non-fork half of subs::subprocessor.
#
# JawnOS::Platform::Job starts this with --name and JAWNOS_JOB_ARGS. The name
# is the call site's exact subprocessor name, and perl/jobs.pl maps it to the
# body. subroutines.pl is loaded first because every job reads $config, $log,
# $device and the domain layer from it.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/../lib";

chdir "$FindBin::Bin/.." or die "subprocessor_worker: cannot chdir to $FindBin::Bin/..: $!";

use Mojo::JSON qw(decode_json);

my $name;
while (@ARGV) {
	my $arg = shift @ARGV;
	if ($arg eq '--name') { $name = shift @ARGV; next }
	if ($arg =~ /^--name=(.*)$/s) { $name = $1; next }
}

my $args = {};
if (defined $ENV{'JAWNOS_JOB_ARGS'} && length $ENV{'JAWNOS_JOB_ARGS'}) {
	my $decoded = eval { decode_json($ENV{'JAWNOS_JOB_ARGS'}) };
	$args = $decoded if ref $decoded eq 'HASH';
}

require './perl/subroutines.pl';
require './perl/jobs.pl';
# The utility scheduler's bodies live outside jobs.pl so the require graph stays
# acyclic; load them only for the job that runs them.
require './perl/utility_jobs.pl' if defined $name && $name eq 'utility functions';

my $job = (defined $name && length $name) ? $jobs::JOB{$name} : undef;
unless ($job) {
	print STDERR 'subprocessor worker: unknown job '
		. (defined $name && length $name ? "'$name'" : '(no name given)') . "\n";
	exit 2;
}

$job->($args);
# A finite job ends here; a resident one never returns.
exit 0;
