use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# A reopened Music window replays the queue it was last showing (the list the
# guide, the folders app or an artist pick put together cannot be rebuilt from
# the saved search). Replaying it is only safe when it still describes the same
# situation, and getting that wrong is how a peer's movie list or a sealed
# track's name would surface in the wrong window. These are the rules; the
# storing and the replay live in Music.pl (music_queue_remember/recall).

my $queue = sub {
	my (%over) = @_;
	return { files => ['/home/jawn/Music/a.flac', '/home/jawn/Music/b.flac'], library => 'local', permissive => 0, %over };
};

ok(subs::music_queue_applies($queue->(), 'local', 0),
	'a local queue with no grant replays into a local locked window');

ok(subs::music_queue_applies($queue->(), undef, 0),
	'an unset library counts as local');

ok(subs::music_queue_applies($queue->(library => undef), 'local', 0),
	'a queue stored without a library counts as local');

ok(subs::music_queue_applies($queue->(permissive => 1), 'local', 1),
	'a queue assembled while unlocked replays into an unlocked window');

is(subs::music_queue_applies($queue->(permissive => 1), 'local', 0), 0,
	'an unlocked queue is not replayed into a locked window');

is(subs::music_queue_applies($queue->(permissive => 0), 'local', 1), 0,
	'a locked queue is not replayed into an unlocked window either');

is(subs::music_queue_applies($queue->(library => 'peer-uuid'), 'local', 0), 0,
	"a peer's queue is not replayed onto this machine");

ok(subs::music_queue_applies($queue->(library => 'peer-uuid'), 'peer-uuid', 0),
	"a peer's queue replays on that peer");

is(subs::music_queue_applies(undef, 'local', 0), 0, 'no queue means search as before');
is(subs::music_queue_applies({}, 'local', 0), 0, 'a queue with no files means search as before');
is(subs::music_queue_applies({ files => [] }, 'local', 0), 0, 'an empty queue is not a queue');
is(subs::music_queue_applies({ files => 'a.flac' }, 'local', 0), 0, 'files must be a list');
is(subs::music_queue_applies([], 'local', 0), 0, 'a queue must be a hash');

done_testing();
