package JawnOS::Routes::manager_security3;

use strict;
use warnings;

sub routes {
	return (
	[40363, 'post', '/manager/security/padlock_key_show_peer', 'action_40363'],
	[40429, 'get', '/manager/security/padlock_state', 'action_40429'],
	[40488, 'get', '/manager/security/padlock_key', 'action_40488'],
	[40496, 'get', '/manager/security/padlock_key/frame', 'action_40496'],
	[40500, 'get', '/manager/security/padlock_key/active', 'action_40500'],
	);
}

1;
