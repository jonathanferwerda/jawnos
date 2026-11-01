package JawnOS::Routes::manager_configure5;

use strict;
use warnings;

sub routes {
	return (
	[19406, 'post', '/manager/configure/new_database', 'action_19406'],
	[19489, 'post', '/manager/configure/restore_now', 'action_19489'],
	[19541, 'get', '/manager/configure/database_vacuum', 'action_19541'],
	[19574, 'post', '/manager/configure/database_vacuum_confirm', 'action_19574'],
	[19589, 'get', '/manager/configure/database_doctor', 'action_19589'],
	[19632, 'post', '/manager/configure/database_doctor_confirm', 'action_19632'],
	[19703, 'get', '/manager/configure/vacuum_app', 'action_19703'],
	[19713, 'post', '/manager/configure/vacuum_app_confirm', 'action_19713'],
	[19724, 'post', '/manager/configure/merge_database', 'action_19724'],
	[24799, 'post', '/manager/configure/notification_sound', 'action_24799'],
	[25152, 'get', '/manager/configure/backup_now', 'action_25152'],
	[25173, 'post', '/manager/configure/delete_backup', 'action_25173'],
	[25688, 'post', '/manager/configure/home_plate/save', 'action_25688'],
	[25711, 'post', '/manager/configure/home_plate/manual', 'action_25711'],
	[25725, 'post', '/manager/configure/home_plate/settings', 'action_25725'],
	[25757, 'post', '/manager/configure/home_plate/settings/delete', 'action_25757'],
	[26620, 'post', '/manager/configure/environment/qr', 'action_26620'],
	[41150, 'get', '/manager/configure/sms_list_check', 'action_41150'],
	[41659, 'get', '/manager/configure/adopt_app', 'action_41659'],
	[41704, 'post', '/manager/configure/adopt_app_confirm', 'action_41704'],
	[42942, 'post', '/manager/configure/password_update', 'action_42942'],
	[43843, 'post', '/manager/configure/ble_scan', 'action_43843'],
	);
}

1;
