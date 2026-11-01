package JawnOS::Routes::mail_ws;

use strict;
use warnings;

sub routes {
	return (
	[45571, 'websocket', '/mail/ws', 'action_45571'],
	);
}

1;
