package JawnOS::Routes::manager_ws;

use strict;
use warnings;

sub routes {
	return (
	[719, 'websocket', '/device/ws', 'action_719'],
	[47050, 'websocket', '/manager/ws', 'action_47050'],
	[47101, 'post', '/manager/device_ws', 'action_47101'],
	);
}

1;
