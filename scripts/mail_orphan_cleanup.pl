#!/usr/bin/perl

# mail_orphan_cleanup.pl - tombstone messages filed under a manager_file that is
# not a real mailbox (the init demo rows, say). Their bodies cannot be opened by
# any key the house holds; the tombstone makes every peer drop its copy too.
#
#   perl scripts/mail_orphan_cleanup.pl                          # dry run
#   perl scripts/mail_orphan_cleanup.pl --apply                  # tombstone + remove
#   perl scripts/mail_orphan_cleanup.pl --manager-file 'x y' --json
#
# The default manager_file is the invalid demo account 'jawn@init.note9 pro'.
# Safe to re-run: once the rows are gone there is nothing left to tombstone.
use strict;
use warnings;
use FindBin;
require Mojo::JSON;
chdir "$FindBin::Bin/.." or die "cannot find the jawnos root: $!";
require './perl/subroutines.pl';

my $apply = (grep { $_ eq '--apply' } @ARGV) ? 1 : 0;
my $json  = (grep { $_ eq '--json' } @ARGV) ? 1 : 0;
my $manager_file = 'jawn@init.note9 pro';
for (my $i = 0; $i < @ARGV; $i++) {
	$manager_file = $ARGV[$i + 1] if $ARGV[$i] eq '--manager-file' && defined $ARGV[$i + 1];
}

my $res = subs::mailbox_tombstone_orphans({ manager_file => $manager_file, apply => $apply });
if ($json) {
	print Mojo::JSON::encode_json($res), "\n";
	exit 0;
}
printf "mail orphan cleanup - %s\n", $apply ? 'applied' : 'dry run (pass --apply to tombstone)';
printf "  manager_file: %s\n", $res->{'manager_file'};
printf "  rows:         %d\n", $res->{'rows'};
