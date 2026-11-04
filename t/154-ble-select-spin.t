# tests-for: lib/JawnOS/Ble/Select.pm scripts/jawn-bt
# covers:    the BLE client never spins on a select that returns at once with
#           nothing. A dead handle made IO::Select return instantly forever,
#           and `jawn-bt listen` held a phone core at 100% with zero bytes read
#           or written. The wrapper counts the run, the client stops after it,
#           and the real timeout/data paths still clear the count.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib", 'lib';
use Test::More;
use IO::Select;
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Time::HiRes qw(time);
use JawnOS::Ble::Select;

# ---- the shipped shape ------------------------------------------------------
open( my $fh, '<', "$FindBin::Bin/../scripts/jawn-bt" ) or die "$!";
my $src = do { local $/; <$fh> };
close $fh;
like( $src, qr/JawnOS::Ble::Select::wait_ready/, 'the client waits through the guarded select' );
like( $src, qr/select spin/, 'the client names the spin it refuses to run' );

# ---- a dead handle: the observed failure ------------------------------------
# IO::Select keeps the handle, so closing it leaves a selector that returns at
# once with nothing, every time. This is the shape that pinned the core.
socketpair( my $dead, my $peer, AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!";
my $bad = IO::Select->new($dead);
close $dead;
my $run  = 0;
my @none = ();
my $t0   = time;
@none = JawnOS::Ble::Select::wait_ready( $bad, 0.2, \$run ) for 1 .. 10;
is( scalar @none, 0, 'a dead handle yields no event' );
cmp_ok( time - $t0, '<', 0.5, 'ten dead-handle selects do not wait out their timeouts' );
is( $run, 10, 'every fast empty return is counted' );

# ---- a real timeout clears the run ------------------------------------------
socketpair( my $idle, my $writer, AF_UNIX, SOCK_STREAM, PF_UNSPEC ) or die "socketpair: $!";
my $good = IO::Select->new($idle);
$run = 5;
my $t1 = time;
my @r1 = JawnOS::Ble::Select::wait_ready( $good, 0.15, \$run );
cmp_ok( time - $t1, '>=', 0.10, 'an idle handle waits out its timeout' );
is( scalar @r1, 0, 'a timeout carries no event' );
is( $run, 0, 'a real timeout clears the run' );

# ---- data clears the run and is returned ------------------------------------
print $writer "hello\n";
$writer->flush;
$run = 7;
my @r2 = JawnOS::Ble::Select::wait_ready( $good, 0.2, \$run );
is( scalar @r2, 1, 'a readable handle is returned' );
is( $run, 0, 'data clears the run' );

done_testing();
