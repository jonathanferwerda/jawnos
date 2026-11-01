package JawnOS::Routes::observer_misc;

use strict;
use warnings;

sub routes {
	return (
	[45545, 'websocket', '/observer/ws', 'action_45545'],
	);
}

1;
