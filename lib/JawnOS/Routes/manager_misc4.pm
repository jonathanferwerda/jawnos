package JawnOS::Routes::manager_misc4;

use strict;
use warnings;

sub routes {
	return (
	[12377, 'websocket', '/manager/tunnel/ws', 'action_12377'],
	[12416, 'post', '/manager/tunnel/alive', 'action_12416'],
	[12483, 'post', '/manager/neighbour_status', 'action_12483'],
	[12622, 'post', '/manager/nfc/read', 'action_12622'],
	[12771, 'post', '/manager/nfc/write', 'action_12771'],
	[12791, 'post', '/manager/leave', 'action_12791'],
	[12848, 'post', '/manager/lock_session', 'action_12848'],
	[13070, 'get', '/manager', 'action_13070'],
	[13131, 'get', '/manager/window_retriever', 'action_13131'],
	[13150, 'get', '/manager/start_menu', 'action_13150'],
	[13157, 'post', '/manager/start_menu/used', 'action_13157'],
	[13164, 'post', '/manager/start_menu/forget', 'action_13164'],
	[13286, 'get', '/manager/start_menu/htop_viewer', 'action_13286'],
	[13872, 'get', '/manager/qrcode_generator', 'action_13872'],
	[14367, 'post', '/manager/ticket_privilege', 'action_14367'],
	[14550, 'get', '/manager/delete_ticket', 'action_14550'],
	[14563, 'get', '/manager/suspend_ticket', 'action_14563'],
	[14575, 'get', '/manager/renew_ticket', 'action_14575'],
	[14595, 'get', '/manager/reinstate_ticket', 'action_14595'],
	[14630, 'get', '/manager/random_word', 'action_14630'],
	[14686, 'post', '/manager/cache_set', 'action_14686'],
	[14697, 'post', '/manager/cache_delete', 'action_14697'],
	[14706, 'get', '/manager/cache_get', 'action_14706'],
	[20001, 'post', '/manager/power', 'action_20001'],
	);
}

1;
