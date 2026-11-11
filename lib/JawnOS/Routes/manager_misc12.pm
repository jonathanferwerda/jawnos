package JawnOS::Routes::manager_misc12;

use strict;
use warnings;

sub routes {
	return (
	[41046, 'post', '/manager/lorawan/settings', 'action_41046'],
	[41086, 'post', '/manager/lorawan/join', 'action_41086'],
	[41091, 'post', '/manager/lorawan/send', 'action_41091'],
	[41096, 'get', '/manager/lorawan/status', 'action_41096'],
	[41140, 'post', '/manager/sms/message', 'action_41140'],
	[41155, 'post', '/manager/delete_app', 'action_41155'],
	[41370, 'post', '/manager/delete_file', 'action_41370'],
	[41431, 'get', '/manager/edit_app', 'action_41431'],
	[41468, 'post', '/manager/edit_app', 'action_41468'],
	[41568, 'post', '/manager/clone_app', 'action_41568'],
	[41622, 'post', '/manager/delete_whole_app', 'action_41622'],
	[41731, 'get', '/manager/clothesline', 'action_41731'],
	[41744, 'post', '/manager/clothesline', 'action_41744'],
	[41801, 'get', '/manager/volume_control', 'action_41801'],
	[41867, 'post', '/manager/clothesline', 'action_41867'],
	[41877, 'post', '/manager/calculate', 'action_41877'],
	[41893, 'get', '/manager/keyboard/convert', 'action_41893'],
	[41907, 'get', '/manager/keyboard/ime', 'action_41907'],
	[41969, 'get', '/manager/credentials/status', 'action_41969'],
	[42020, 'post', '/manager/credentials/save', 'action_42020'],
	[42085, 'post', '/manager/credentials/fill', 'action_42085'],
	[42101, 'post', '/manager/credentials/forget', 'action_42101'],
	);
}

1;
