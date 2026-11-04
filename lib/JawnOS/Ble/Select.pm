package JawnOS::Ble::Select;

# jawn-bt waits on its bridge socket with a short deadline. IO::Select->can_read
# returns at once with nothing when the handle is no longer selectable (or the
# select itself failed) - and it does so forever. The listen loop polls for the
# life of the tree, so that turned into a core pinned at 100% with zero bytes
# read or written: 5000 iterations in 5 ms on this box, no voluntary context
# switches, almost all of it system time. A real timeout is cheap, so this
# wrapper counts the fast empty returns instead of hiding them: the caller
# stops the client after a run, and the supervisor starts a fresh one.

use strict;
use warnings;
use Time::HiRes qw(time);

# A select that comes back before this share of its timeout read nothing and
# did not wait: it failed or the handle went away, rather than timing out.
our $FAST_SHARE = 0.5;

# Shorter waits are the tail of a deadline; a timeout there is normal.
our $MIN_WAIT = 0.05;

# wait_ready($select, $seconds, \$run) -> ready handles
# Sets $$run to the number of consecutive fast empty returns (0 on a timeout or
# data) and leaves $! as select left it so the caller can report the reason.
sub wait_ready {
	my ( $sel, $wait, $run ) = @_;
	my $t0 = time();
	my @ready = $sel->can_read($wait);
	my $err = $!;
	if (@ready) {
		$$run = 0;
		return @ready;
	}
	my $spent = time() - $t0;
	$$run = ( $wait >= $MIN_WAIT && $spent < $wait * $FAST_SHARE ) ? $$run + 1 : 0;
	$! = $err;
	return;
}

1;
