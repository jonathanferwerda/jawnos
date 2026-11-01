package JawnOS::Routes::manager_configure4;

use strict;
use warnings;

sub routes {
	return (
	[17823, 'post', '/manager/configure/packaging/save', 'action_17823'],
	[17845, 'post', '/manager/configure/packaging/suggest', 'action_17845'],
	[17880, 'post', '/manager/configure/packaging/delete', 'action_17880'],
	[18883, 'post', '/manager/configure/colour_update', 'action_18883'],
	[18904, 'get', '/manager/configure/appointment_list', 'action_18904'],
	[18921, 'get', '/manager/configure/appointment_display', 'action_18921'],
	[18970, 'post', '/manager/configure/permissions', 'action_18970'],
	[19004, 'get', '/manager/configure', 'action_19004'],
	[19033, 'post', '/manager/configure', 'action_19033'],
	[19179, 'any', '/manager/configure/system_list', 'action_19179'],
	[19216, 'post', '/manager/configure/sys_setting', 'action_19216'],
	[19225, 'post', '/manager/configure/system_monitor', 'action_19225'],
	[19236, 'get', '/manager/configure/utility_controller', 'action_19236'],
	[19245, 'post', '/manager/configure/utility_controller/save', 'action_19245'],
	[19305, 'post', '/manager/configure/utility_pools/save', 'action_19305'],
	[19355, 'post', '/manager/configure/utility_batch_group/save', 'action_19355'],
	[19387, 'get', '/manager/configure/restore_list', 'action_19387'],
	);
}

1;
