#!/usr/bin/env perl
# sync_kick.pl - clear what has stalled this machine's sync and nudge a pass.
#
#   perl scripts/sync_kick.pl          # clear markers/backoff/hub, nudge the pass
#   perl scripts/sync_kick.pl --now    # also run the sync pass in this process
#
# The utility controller runs the same subs::sync_kick as the "Sync kick" job,
# so a stuck box can be recovered from a shell or from Configure -> Sys.
use strict;
use warnings;
use FindBin;

chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $now = grep { $_ eq '--now' } @ARGV;
my $note = &subs::sync_kick();
print $note, "\n";
if ($now) {
	&subs::remote_machine_negotiator({});
	print "sync pass started\n";
}
