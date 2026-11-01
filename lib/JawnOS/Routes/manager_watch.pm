package JawnOS::Routes::manager_watch;

use strict;
use warnings;

sub routes {
	return (
	[43926, 'post', '/manager/watch/assign', 'action_43926'],
	[43995, 'post', '/manager/watch/setting', 'action_43995'],
	[44078, 'get', '/manager/watch/diagram', 'action_44078'],
	[44096, 'post', '/manager/watch/diagram', 'action_44096'],
	[44117, 'post', '/manager/watch/measure', 'action_44117'],
	[44452, 'get', '/manager/watch/set_proxy', 'action_44452'],
	[44484, 'get', '/manager/watch/list_proxy', 'action_44484'],
	[44538, 'post', '/manager/watch/proxy_load', 'action_44538'],
	[44552, 'post', '/manager/watch/proxy_here', 'action_44552'],
	[44570, 'post', '/manager/watch/proxy_save', 'action_44570'],
	[44606, 'post', '/manager/watch/delete_proxy', 'action_44606'],
	);
}

1;
