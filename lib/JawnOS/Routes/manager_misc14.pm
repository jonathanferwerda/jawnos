package JawnOS::Routes::manager_misc14;

use strict;
use warnings;

sub routes {
	return (
	[45297, 'get', '/manager/time_preview', 'action_45297'],
	[45396, 'get', '/manager/ago', 'action_45396'],
	[45403, 'post', '/manager/assistant', 'action_45403'],
	[46078, 'post', '/manager/president', 'action_46078'],
	[46090, 'post', '/manager/president/restart', 'action_46090'],
	[46107, 'get', '/manager/remote_auth_test', 'action_46107'],
	[46274, 'get', '/manager/sync_history', 'action_46274'],
	[47847, 'get', '/manager/remote_refresh', 'action_47847'],
	[48331, 'get', '/manager/ws_close', 'action_48331'],
	);
}

1;
