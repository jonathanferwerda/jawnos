use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", "t/lib";
use Test::More;
use JawnOSTest;

# A reopened Music window replays the queue it was last showing (a list the
# guide, the folders app or an artist pick put together cannot be rebuilt from
# the saved search). Replaying it is only safe on the library that assembled it,
# and getting that wrong is how a peer's movie list would surface on this
# machine. What a window may *list* is a separate question, answered per file by
# music_queue_file_visible, so a queue is not thrown away just because the
# window's grant changed - every window is reopened without a token.

my $queue = sub {
	my (%over) = @_;
	return { files => ['/home/jawn/Music/a.flac', '/home/jawn/Music/b.flac'], library => 'local', permissive => 0, %over };
};

ok(subs::music_queue_applies($queue->(), 'local'),
	'a local queue replays on this machine');

ok(subs::music_queue_applies($queue->(), undef),
	'an unset library counts as local');

ok(subs::music_queue_applies($queue->(library => undef), 'local'),
	'a queue stored without a library counts as local');

is(subs::music_queue_applies($queue->(library => 'peer-uuid'), 'local'), 0,
	"a peer's queue is not replayed onto this machine");

ok(subs::music_queue_applies($queue->(library => 'peer-uuid'), 'peer-uuid'),
	"a peer's queue replays on that peer");

# the stored grant is a record of how the list was assembled, not a gate: the
# grant is not on the window when the app is reopened, and refusing on it lost
# the queue every time
ok(subs::music_queue_applies($queue->(permissive => 1), 'local'),
	'a queue assembled while unlocked still replays');
ok(subs::music_queue_applies($queue->(permissive => 1, library => 'local'), undef),
	'an unlocked queue replays into a window with no library set');

is(subs::music_queue_applies(undef, 'local'), 0, 'no queue means search as before');
is(subs::music_queue_applies({}, 'local'), 0, 'a queue with no files means search as before');
is(subs::music_queue_applies({ files => [] }, 'local'), 0, 'an empty queue is not a queue');
is(subs::music_queue_applies({ files => 'a.flac' }, 'local'), 0, 'files must be a list');
is(subs::music_queue_applies([], 'local'), 0, 'a queue must be a hash');

done_testing();
