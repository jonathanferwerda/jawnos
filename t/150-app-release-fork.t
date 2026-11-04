# tests-for: lib/JawnOS/Controller/manager_misc3.pm
# covers:    the on-demand app-release sync runs in a forked child, not inline
#            in the request worker.

use strict;
use warnings;
no warnings 'once';

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;
use File::Slurp qw(read_file);

# The route's own comment promises "a forked child (a slow peer or a 35 MB
# download must not block the event loop)"; the call had lost its fork, so a
# sync across every peer (a 20s timeout each, one socket per peer) held a
# prefork worker for minutes. The phone showed that as one worker pinned at 100%
# with no sync job to blame. Pin the call, not just the comment.
my $source = read_file('lib/JawnOS/Controller/manager_misc3.pm');
my $at = index($source, '&subs::app_release_sync');
ok( $at > 0, 'the on-demand release sync is still in the controller' );
# The call's options sit just after it; enough to see the fork without
# parsing Perl.
my $call = $at > 0 ? substr($source, $at, 300) : '';
like( $call, qr/fork\s*=>\s*1/, 'and it is a real child, never inline in the request worker' );

done_testing();
