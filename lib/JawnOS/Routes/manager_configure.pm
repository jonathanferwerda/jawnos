package JawnOS::Routes::manager_configure;

use strict;
use warnings;

sub routes {
	return (
	[6572, 'post', '/manager/configure/attribute_copy', 'action_6572'],
	[6704, 'post', '/manager/configure/attribute_upload', 'action_6704'],
	[7061, 'get', '/manager/configure/store_list', 'action_7061'],
	[7789, 'get', '/manager/configure/device_lister', 'action_7789'],
	[7966, 'get', '/manager/configure/printer_ink', 'action_7966'],
	[52020, 'get', '/manager/configure/printer_list', 'action_52020'],
	[52021, 'post', '/manager/configure/printer_default', 'action_52021'],
	[52022, 'post', '/manager/configure/printer_sync', 'action_52022'],
	[7970, 'post', '/manager/configure/device_purpose', 'action_7970'],
	[8043, 'get', '/manager/configure/me_settings', 'action_8043'],
	[8054, 'get', '/manager/configure/plat_setting_list', 'action_8054'],
	[8061, 'get', '/manager/configure/crypto_panel', 'action_8061'],
	[8065, 'post', '/manager/configure/crypto_refresh', 'action_8065'],
	[8074, 'get', '/manager/configure/pay_panel', 'action_8074'],
	[8791, 'get', '/manager/configure/oauth_panel', 'action_8791'],
	[8794, 'post', '/manager/configure/oauth_client/add', 'action_8794'],
	[8800, 'post', '/manager/configure/oauth_client/save', 'action_8800'],
	[8814, 'post', '/manager/configure/oauth_client/remove', 'action_8814'],
	[8827, 'get', '/manager/configure/dns_panel', 'action_8827'],
	[8831, 'post', '/manager/configure/dns_client/add', 'action_8831'],
	[8838, 'post', '/manager/configure/dns_client/save', 'action_8838'],
	[8861, 'post', '/manager/configure/dns_client/remove', 'action_8861'],
	[8869, 'post', '/manager/configure/dns_client/test', 'action_8869'],
	[8878, 'post', '/manager/configure/dns_client/from_ai', 'action_8878'],
	[8894, 'post', '/manager/configure/dns_client/to_ai', 'action_8894'],
	[8910, 'post', '/manager/configure/domain/house', 'action_8910'],
	[8922, 'post', '/manager/configure/domain/host', 'action_8922'],
	[9257, 'post', '/manager/configure/me_setting', 'action_9257'],
	[9304, 'post', '/manager/configure/mugshot_upload', 'action_9304'],
	[9374, 'post', '/manager/configure/logo_upload', 'action_9374'],
	[9391, 'get', '/manager/configure/misc_setting_list', 'action_9391'],
	[9421, 'post', '/manager/configure/misc_setting', 'action_9421'],
	[9455, 'post', '/manager/configure/misc_settings', 'action_9455'],
	[9480, 'post', '/manager/configure/theme_save', 'action_9480'],
	[9541, 'post', '/manager/configure/theme_delete', 'action_9541'],
	);
}

1;
