#!/usr/bin/env perl
# Push the current code to the neighbour machines over ssh, using the encrypted
# credentials the remote_machines table already holds. Every device also pulls
# on its own (the 60-second git watcher in President.pl), so this is the
# force-it-now lever: fast-forward the repo, reinstall the desktop app where one
# is installed, and ask jawn to restart.
#
#   perl scripts/deploy_neighbours.pl              # every machine with creds
#   perl scripts/deploy_neighbours.pl Table Fe     # only these hostnames
#   perl scripts/deploy_neighbours.pl --dry-run    # list, change nothing
#
# Run it from the jawn tree while jawn is up (it reads the same database).
use strict;
use warnings;
use FindBin;

chdir "$FindBin::Bin/.." or die "cannot chdir to the jawn tree: $!\n";
require './subroutines.pl';

my @wanted;
my $dry_run = 0;
foreach my $arg (@ARGV) {
	if ($arg eq '--dry-run') { $dry_run = 1; next; }
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
	unless ($rm->{'username'} && $rm->{'password'}) {
		print "$label: no ssh credentials on file\n";
		next;
	}
	if ($dry_run) {
		print "$label: would deploy as $rm->{'username'}\n";
		next;
	}
	my $res = &subs::remote_deploy($rm);
	my $out = $res->{'output'} || '';
	$out =~ s/\s+/ /g;
	print "$label: " . $res->{'message'} . " [" . substr($out, 0, 200) . "]\n";
}
