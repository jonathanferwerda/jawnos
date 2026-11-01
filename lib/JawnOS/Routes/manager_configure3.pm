package JawnOS::Routes::manager_configure3;

use strict;
use warnings;

sub routes {
	return (
	[12455, 'post', '/manager/configure/remote_device_locker', 'action_12455'],
	[12504, 'post', '/manager/configure/device_domain_updater', 'action_12504'],
	[12513, 'post', '/manager/configure/device/neighbour_delete', 'action_12513'],
	[12534, 'post', '/manager/configure/device_deleter', 'action_12534'],
	[12542, 'post', '/manager/configure/nfc/setting', 'action_12542'],
	[12567, 'post', '/manager/configure/nfc/delete', 'action_12567'],
	[12591, 'post', '/manager/configure/contact/setting', 'action_12591'],
	[12611, 'post', '/manager/configure/contact/delete', 'action_12611'],
	[13484, 'get', '/manager/configure/pseudonym_list', 'action_13484'],
	[13496, 'post', '/manager/configure/pseudonym_setter', 'action_13496'],
	[13517, 'get', '/manager/configure/pseudonym_defaulter', 'action_13517'],
	[13530, 'post', '/manager/configure/pseudonym_icon_changer', 'action_13530'],
	[14608, 'post', '/manager/configure/site_type/manual_change', 'action_14608'],
	[15000, 'post', '/manager/configure/image_function', 'action_15000'],
	[15072, 'post', '/manager/configure/image_function_tool', 'action_15072'],
	[15171, 'post', '/manager/configure/map_helper', 'action_15171'],
	[15216, 'post', '/manager/configure/map_rotate', 'action_15216'],
	[15262, 'post', '/manager/configure/ai_availability_clear', 'action_15262'],
	[15302, 'post', '/manager/configure/image_name', 'action_15302'],
	[16761, 'post', '/manager/configure/stop_all_appointments', 'action_16761'],
	[17661, 'post', '/manager/configure/app_measure_configuration_adder', 'action_17661'],
	[17694, 'post', '/manager/configure/app_measure_configurator', 'action_17694'],
	);
}

1;
