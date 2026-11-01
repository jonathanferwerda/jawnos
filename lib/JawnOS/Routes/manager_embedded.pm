package JawnOS::Routes::manager_embedded;

use strict;
use warnings;

sub routes {
	return (
	[43011, 'post', '/manager/embedded/setting', 'action_43011'],
	[43099, 'post', '/manager/embedded/now_me', 'action_43099'],
	[43109, 'post', '/manager/embedded/bt_now_me', 'action_43109'],
	[43129, 'get', '/manager/embedded', 'action_43129'],
	[43287, 'get', '/manager/embedded/device_query', 'action_43287'],
	[43358, 'post', '/manager/embedded/files/delete', 'action_43358'],
	[43384, 'get', '/manager/embedded/pin_grabber', 'action_43384'],
	[43495, 'get', '/manager/embedded/wigi', 'action_43495'],
	[43536, 'post', '/manager/embedded/toggle', 'action_43536'],
	[43561, 'post', '/manager/embedded/ota_uploader', 'action_43561'],
	[43620, 'post', '/manager/embedded/ota_uploader_wifi', 'action_43620'],
	[43673, 'get', '/manager/embedded/usb_ports', 'action_43673'],
	[43677, 'post', '/manager/embedded/usb_upload', 'action_43677'],
	[43714, 'get', '/manager/embedded/usb_upload_status', 'action_43714'],
	[43737, 'post', '/manager/embedded/usb_provision', 'action_43737'],
	[43857, 'get', '/manager/embedded/teletype_backup', 'action_43857'],
	[43881, 'get', '/manager/embedded/jobs', 'action_43881'],
	[43918, 'post', '/manager/embedded/delete_job', 'action_43918'],
	);
}

1;
