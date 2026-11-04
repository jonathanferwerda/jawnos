package JawnOS::Routes::manager_phone;

use strict;
use warnings;

sub routes {
	return (
	[23201, 'get', '/manager/phone', 'action_23201'],
	[24603, 'post', '/manager/phone/dial', 'action_24603'],
	[24636, 'post', '/manager/phone/call', 'action_24636'],
	[24755, 'get', '/manager/phone/sync', 'action_24755'],
	[24760, 'post', '/manager/phone/ivr', 'action_24760'],
	);
}

1;
