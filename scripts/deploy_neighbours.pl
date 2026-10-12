#!/usr/bin/env perl
# Ask the neighbour machines to pull + restart, over http (the self_deploy
# route), rather than pushing code to them over ssh. Every device also pulls on
# its own (the 60-second git watcher in President.pl), so this is the
# force-it-now lever.
#
#   perl scripts/deploy_neighbours.pl              # every machine
#   perl scripts/deploy_neighbours.pl Table Fe     # only these hostnames
#   perl scripts/deploy_neighbours.pl --dry-run    # list, change nothing
#   perl scripts/deploy_neighbours.pl --force      # also reset a diverged
#                                                  # tree hard to origin/main
#
# Run it from the jawn tree while jawn is up (it reads the same database).
use strict;
use warnings;
use FindBin;

chdir "$FindBin::Bin/.." or die "cannot chdir to the jawn tree: $!\n";
require './subroutines.pl';
$ENV{PURPOSE} = '';
require './Manager.pl';

my @wanted;
my $dry_run = 0;
my $force = 0;
foreach my $arg (@ARGV) {
	if ($arg eq '--dry-run') { $dry_run = 1; next; }
	if ($arg eq '--force') { $force = 1; next; }
	push @wanted, $arg;
}

my @machines;
if (@wanted) {
	foreach my $host (@wanted) {
		my $rm = &subs::db_select('remote_machines', undef, { hostname => $host })->hashes->[0];
		if ($rm) { push @machines, $rm; }
		else { print "$host: no such machine\n"; }
	}
}
else {
	@machines = @{ &subs::db_select('remote_machines')->hashes };
}

foreach my $rm (@machines) {
	my $label = $rm->{'hostname'} || $rm->{'fqdn'} || $rm->{'ip'};
	if ($dry_run) {
		print "$label: would deploy\n";
		next;
	}
	my $res = &subs::remote_deploy($rm, force => $force);
	my $out = $res->{'output'} || '';
	$out =~ s/\s+/ /g;
	print "$label: " . $res->{'message'} . " [" . substr($out, 0, 200) . "]\n";
}
