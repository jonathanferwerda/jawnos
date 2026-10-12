#!/usr/bin/env perl
# help_audit.pl - check the Help registry against the tree.
#
# Verifies every topic's related links resolve, its listed templates still exist,
# the controls it names are still on-screen hints in the app, and whether the
# app's files have changed since the topic was last vetted. Reports orphan app
# templates that have no topic.
#
#   perl scripts/help_audit.pl            # full report
#   perl scripts/help_audit.pl --quiet    # errors and stale only
#   perl scripts/help_audit.pl --all      # also list fragment templates with no topic
#
# Exit code is non-zero when there is an error (a broken link, a missing
# template, a control that has moved). Stale and advisory findings do not fail:
# they are a to-do list, not a wall.
use strict;
use warnings;
use FindBin;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './help.pl';

my $quiet = grep { $_ eq '--quiet' } @ARGV;
my $all = grep { $_ eq '--all' } @ARGV;

my @findings = help::audit();
my %bucket;
push @{$bucket{ $_->[0] }}, $_ for @findings;

my @order = (
	[ 'error', 'ERRORS (must fix)',               ],
	[ 'stale', 'STALE (source changed since vetted)' ],
	[ 'warn',  'WARNINGS'                         ],
	[ 'info',  'INFO (app templates with no topic)' ],
);

my $errors = scalar @{ $bucket{'error'} || [] };

foreach my $o (@order) {
	my ($sev, $label) = @{$o};
	next if $quiet && ($sev eq 'warn' || $sev eq 'info');
	next if !$all && $sev eq 'info';
	my @rows = @{ $bucket{$sev} || [] };
	printf "\n%s\n", $label;
	if (!@rows) { print "  (none)\n"; next; }
	printf "  %-24s %s\n", $_->[1], $_->[2] for @rows;
}

printf "\n%d error(s), %d stale, %d warning(s), %d info\n",
	$errors,
	scalar @{ $bucket{'stale'} || [] },
	scalar @{ $bucket{'warn'} || [] },
	scalar @{ $bucket{'info'} || [] };

print "\nHelp registry OK.\n" unless $errors;
exit($errors ? 1 : 0);
