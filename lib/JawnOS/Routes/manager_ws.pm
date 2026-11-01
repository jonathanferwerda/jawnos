package JawnOS::Routes::manager_ws;

use strict;
use warnings;

sub routes {
	return (
	[47050, 'websocket', '/manager/ws', 'action_47050'],
	);
}

1;
