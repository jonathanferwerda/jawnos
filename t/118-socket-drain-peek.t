# tests-for: lib/JawnOS/Domain/Calendar.pm
# covers:    socket_drain_peek drains a push's written-back reply and reports EOF,
#            without warning. recv() returns the sender's address, not a byte
#            count, so comparing it to 0 warned on every push; the flood filled
#            the pty and blocked the workers (v0.1.1850).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib", "$FindBin::Bin/../lib";
use Socket qw(AF_UNIX SOCK_STREAM PF_UNSPEC);
use Test::More;
use JawnOSTest;

subs::preload('socket_drain_peek');

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };

socketpair(my $a, my $b, AF_UNIX, SOCK_STREAM, PF_UNSPEC) or die "socketpair: $!";

# A live peer with a reply waiting: the drain empties it, the peer is still there.
syswrite($b, 'a-uuid-reply');
is(&subs::socket_drain_peek($a, 1), 0, 'a live peer with a pending reply is not EOF');
is(scalar @warnings, 0, 'draining the reply warns about nothing');

# Without the drain, the pending byte is left for the peek to see.
syswrite($b, 'more');
is(&subs::socket_drain_peek($a, 0), 0, 'a peek with no drain is not EOF');
is(scalar @warnings, 0, 'peeking warns about nothing');

# The peer goes away.
close $b;
is(&subs::socket_drain_peek($a, 1), 1, 'a closed peer reads as EOF');
is(scalar @warnings, 0, 'EOF detection warns about nothing');

is(scalar @warnings, 0, 'the whole sequence is warning-free');

close $a;
done_testing();
