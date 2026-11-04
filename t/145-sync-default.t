# tests-for: perl/gb/01_state_and_defaults.pl
# covers:    the built-in utility switches a fresh machine starts from - the sync
#            pass runs on its own timer so a box with no LAN presence still syncs.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# The defaults are what a machine clones into its utility row when that row does
# not exist yet, so a job switched off here stays off on a new box until someone
# opens Configure and finds it.
my $root = root();
require "$root/perl/gb/01_state_and_defaults.pl";

my $sync = $gb::timeouts->{'remote_machine_sync'};
ok(ref $sync eq 'HASH', 'the sync pass is a declared utility');
is($sync->{'toggle'}, 'on',
	'the sync pass starts on: a machine with no LAN presence wake (a VM, a LXC reached over the tailnet) still syncs');

# The pace is the fast pool's, not the job's own interval, so the switch turning
# on does not mean a copy every two minutes.
is($sync->{'group'}, 'fast', 'the sync pass runs in the fast pool');
ok(($sync->{'timeout'} || 0) >= 900, 'its slot is long enough for a full snapshot merge');

# An unrelated switch keeps its old default; this change is scoped to sync.
is($gb::timeouts->{'navigation'}->{'toggle'}, 'off', 'navigation still starts off');

done_testing();
