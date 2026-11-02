#!/usr/bin/env perl
# Ask the neighbour machines to pull + restart, over http (the self_deploy
# route), rather than pushing code to them over ssh. Every device also pulls on
# its own (the 60-second git watcher in President.pl), so this is the
# force-it-now lever.
#
#   perl scripts/deploy_neighbours.pl              # every machine
#   perl scripts/deploy_neighbours.pl Table fe     # only these machines
#   perl scripts/deploy_neighbours.pl --dry-run    # list, change nothing
#   perl scripts/deploy_neighbours.pl --force      # also reset a diverged
#                                                  # tree hard to origin/main
#
# A machine may be named by hostname, signatorial, uuid or ip; an ambiguous
# term is refused and the candidates are printed.
#
# Run it from the jawn tree while jawn is up (it reads the same database).
use strict;
use warnings;

package Jawn::DeployNeighbours;

use FindBin;

chdir "$FindBin::Bin/.." or die "cannot chdir to the jawn tree: $!\n";
require './perl/subroutines.pl';
$ENV{PURPOSE} = '';
require './perl/Manager.pl';

# The rows to deploy, and one line per name that did not resolve.
#
# A machine may be named the way a person names it (hostname, signatorial, uuid
# or ip). The roster is read once by the caller: two Android devices both report
# the hostname 'localhost', so matching on the hostname alone answered "no such
# machine" for a real device - or, worse, deployed whichever row happened first.
sub select_machines {
	my ($wanted, $rows) = @_;
	my @machines;
	my @refused;
	if (@{ $wanted || [] }) {
		foreach my $term (@{ $wanted }) {
			my ($rm, $why) = &subs::peer_resolve($term, $rows);
			if ($rm) { push @machines, $rm; }
			else { push @refused, $term . ': ' . ($why || 'no such machine') . "\n"; }
		}
	}
	else {
		@machines = @{ $rows || [] };
	}
	return (\@machines, \@refused);
}

sub main {
	my @args = @_;
	my @wanted;
	my $dry_run = 0;
	my $force = 0;
	foreach my $arg (@args) {
		if ($arg eq '--dry-run') { $dry_run = 1; next; }
		if ($arg eq '--force') { $force = 1; next; }
		push @wanted, $arg;
	}

	my $rows = [ @{ &subs::db_select('remote_machines')->hashes || [] } ];
	my ($machines, $refused) = select_machines(\@wanted, $rows);
	print @{$refused};

	foreach my $rm (@{$machines}) {
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
	return 0;
}

main(@ARGV) unless caller;
