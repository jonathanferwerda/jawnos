package JawnOS::Routes::manager_configure2;

use strict;
use warnings;

sub routes {
	return (
	[9562, 'get', '/manager/configure/ping', 'action_9562'],
	[9798, 'get', '/manager/configure/backup_status', 'action_9798'],
	[9974, 'post', '/manager/configure/remote_rsync', 'action_9974'],
	[10035, 'post', '/manager/configure/remote_upgrade', 'action_10035'],
	[10100, 'post', '/manager/configure/migrate', 'action_10100'],
	[10157, 'get', '/manager/configure/migrate/status', 'action_10157'],
	[10205, 'post', '/manager/configure/deploy_neighbours', 'action_10205'],
	[10222, 'post', '/manager/configure/update_now', 'action_10222'],
	[11684, 'post', '/manager/configure/remote_device_disconnect', 'action_11684'],
	[11695, 'get', '/manager/configure/remote_device_connect', 'action_11695'],
	[12141, 'post', '/manager/configure/remote_machine_input', 'action_12141'],
	[12160, 'post', '/manager/configure/remote_machine_key_reset', 'action_12160'],
	[12181, 'post', '/manager/configure/remote_machine_grant', 'action_12181'],
	[12224, 'post', '/manager/configure/remote_machine/tunnel/toggle', 'action_12224'],
	[12258, 'get', '/manager/configure/tunnel/list', 'action_12258'],
	[12285, 'post', '/manager/configure/remote_machine/tunnel/request', 'action_12285'],
	[12334, 'post', '/manager/configure/remote_machine/tunnel/confirm', 'action_12334'],
	[12364, 'post', '/manager/configure/remote_machine/tunnel/close', 'action_12364'],
	[50001, 'get', '/manager/configure/qa_device_ready', 'action_50001'],
	[50002, 'post', '/manager/configure/qa_device_target', 'action_50002'],
	[50003, 'post', '/manager/configure/qa_device_install', 'action_50003'],
	[50004, 'get', '/manager/configure/qa_schedule', 'action_50004'],
	[50005, 'post', '/manager/configure/qa_schedule_save', 'action_50005'],
	[50006, 'post', '/manager/configure/qa_run', 'action_50006'],
	);
}

1;
