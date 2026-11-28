package JawnOS::Routes::voice_music_extra;

use strict;
use warnings;

# One route for voice's Music transport control. The browser owns the player
# (musicTransportLocal), so the route only names the console command; the
# controller that answers it lives in lib/JawnOS/Controller/voice_music_extra.pm.
# The module name has to join JawnOS::Routes' @NAMES for the server to dispatch
# it; it is kept out of the existing groups so no other agent's file is edited.

sub routes {
	return (
	[99710, 'post', '/manager/music/transport', 'action_99710'],
	);
}

1;
