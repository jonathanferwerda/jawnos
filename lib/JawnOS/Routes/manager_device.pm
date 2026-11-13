package JawnOS::Routes::manager_device;

use strict;
use warnings;

sub routes {
	return (
	[37919, 'post', '/manager/device/pair', 'action_37919'],
	[37941, 'post', '/manager/device/challenge', 'action_37941'],
	[37952, 'post', '/manager/device/login', 'action_37952'],
	[37983, 'post', '/manager/device/app_challenge', 'action_37983'],
	[38011, 'post', '/manager/device/app_login', 'action_38011'],
	[38048, 'get', '/manager/device/app_status', 'action_38048'],
	[38076, 'post', '/manager/device/app_identify', 'action_38076'],
	[38088, 'post', '/manager/device/app_request', 'action_38088'],
	[38456, 'post', '/manager/device/shares/request', 'action_38456'],
	[38481, 'get', '/manager/device/shares/status', 'action_38481'],
	[38500, 'post', '/manager/device/recover', 'action_38500'],
	[38547, 'post', '/manager/device/request', 'action_38547'],
	[38584, 'post', '/manager/device/request_status', 'action_38584'],
	[38590, 'post', '/manager/device/join', 'action_38590'],
	);
}

1;
