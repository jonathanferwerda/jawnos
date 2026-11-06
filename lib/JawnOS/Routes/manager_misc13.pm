package JawnOS::Routes::manager_misc13;

use strict;
use warnings;

sub routes {
	return (
	[42519, 'get', '/manager/keyboard/config', 'action_42519'],
	[42557, 'get', '/manager/keyboard_alias', 'action_42557'],
	[42585, 'get', '/manager/say_it', 'action_42585'],
	[42985, 'post', '/manager/teletype/enable_tty', 'action_42985'],
	[43001, 'get', '/manager/teletype/wifi_update', 'action_43001'],
	[43028, 'post', '/manager/teletype/appearance', 'action_43028'],
	[43050, 'post', '/manager/teletype/wifi_config', 'action_43050'],
	[43067, 'post', '/manager/teletype/wifi_update', 'action_43067'],
	[43851, 'post', '/manager/ble/relay', 'action_43851'],
	[44615, 'get', '/manager/past_life_recall', 'action_44615'],
	[44680, 'get', '/manager/marker', 'action_44680'],
	[44701, 'post', '/manager/snapshot_save', 'action_44701'],
	[44729, 'post', '/manager/marker/save', 'action_44729'],
	[44767, 'post', '/manager/marker/delete', 'action_44767'],
	[44779, 'get', '/manager/marker/gallery', 'action_44779'],
	[44844, 'post', '/manager/marker/session/save', 'action_44844'],
	[44868, 'get', '/manager/marker/session/list', 'action_44868'],
	[44874, 'get', '/manager/marker/session/load', 'action_44874'],
	[44881, 'post', '/manager/marker/session/delete', 'action_44881'],
	[44889, 'post', '/manager/room_namer', 'action_44889'],
	[44901, 'post', '/manager/new_room', 'action_44901'],
	[44913, 'get', '/manager/update_database', 'action_44913'],
	[44922, 'get', '/manager/version', 'action_44922'],
	[45064, 'get', '/manager/health', 'action_45064'],
	[45074, 'post', '/manager/health_report', 'action_45074'],
	[45121, 'post', '/manager/available', 'action_45121'],
	[45146, 'post', '/manager/address_report', 'action_45146'],
	[45147, 'post', '/manager/address_directory', 'action_45147'],
	[45148, 'get', '/manager/address_lookup', 'action_45148'],
	[45150, 'get', '/manager/health/page', 'action_45150'],
	[45199, 'post', '/manager/setting_setter', 'action_45199'],
	[45278, 'get', '/manager/setting_grabber', 'action_45278'],
	[45284, 'post', '/manager/setting_deleter', 'action_45284'],
	[45290, 'get', '/manager/settings_grabber', 'action_45290'],
	[45410, 'post', '/manager/volume', 'action_45410'],
	);
}

1;
