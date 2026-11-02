package JawnOS::Routes::manager_misc11;

use strict;
use warnings;

sub routes {
	return (
	[35907, 'post', '/manager/remote_input', 'action_35907'],
	[35942, 'websocket', '/manager/remote_input/ws', 'action_35942'],
	[36160, 'post', '/manager/remote_input/send', 'action_36160'],
	[36175, 'get', '/manager/tailnet/status', 'action_36175'],
	[36179, 'post', '/manager/tailnet/exit', 'action_36179'],
	[36190, 'get', '/manager/public_ip', 'action_36190'],
	[37173, 'get', '/manager/work_claims', 'action_37173'],
	[37177, 'post', '/manager/work_claim', 'action_37177'],
	[37185, 'post', '/manager/work_claim/release', 'action_37185'],
	[37193, 'get', '/manager/agents/list', 'action_37193'],
	[37211, 'get', '/manager/agents/thread', 'action_37211'],
	[37223, 'post', '/manager/agents/save', 'action_37223'],
	[37256, 'post', '/manager/agents/delete', 'action_37256'],
	[37270, 'post', '/manager/assistant/say', 'action_37270'],
	[37291, 'post', '/manager/coding/heal', 'action_37291'],
	[37338, 'post', '/manager/coding/forget', 'action_37338'],
	[37352, 'get', '/manager/records/audit', 'action_37352'],
	[37365, 'post', '/manager/records/repair', 'action_37365'],
	[37412, 'post', '/manager/records/scan', 'action_37412'],
	[37418, 'get', '/manager/records/fixes', 'action_37418'],
	[37432, 'get', '/manager/records/fixes_fixed', 'action_37432'],
	[37437, 'post', '/manager/records/fixes_apply', 'action_37437'],
	[37441, 'post', '/manager/records/fixes_discard', 'action_37441'],
	[37446, 'post', '/manager/records/fixes_retry', 'action_37446'],
	[37453, 'post', '/manager/records/fixes_ask', 'action_37453'],
	[37461, 'post', '/manager/records/fixes_exempt', 'action_37461'],
	[37470, 'post', '/manager/records/fixes_clear', 'action_37470'],
	[37481, 'get', '/manager/coding/fixes', 'action_37481'],
	[37511, 'get', '/manager/coding/fixes_fixed', 'action_37511'],
	[37534, 'post', '/manager/coding/fixes_discard', 'action_37534'],
	[37542, 'post', '/manager/coding/fixes_retry', 'action_37542'],
	[37553, 'post', '/manager/coding/fixes_clear', 'action_37553'],
	[37560, 'post', '/manager/coding/fixes_apply', 'action_37560'],
	[37568, 'post', '/manager/coding/restart', 'action_37568'],
	[37569, 'get', '/manager/coding/run', 'action_37569'],
	[37570, 'post', '/manager/coding/cancel', 'action_37570'],
	[37571, 'post', '/manager/coding/approve', 'action_37571'],
	[37572, 'post', '/manager/coding/reject', 'action_37572'],
	[37578, 'post', '/manager/js_error', 'action_37578'],
	[37667, 'post', '/manager/handbook/settings', 'action_37667'],
	[40591, 'get', '/manager/telephony', 'action_40591'],
	[40666, 'post', '/manager/sms/device', 'action_40666'],
	[40678, 'post', '/manager/sms/result', 'action_40678'],
	[40709, 'post', '/manager/sms/mms', 'action_40709'],
	[41040, 'get', '/manager/lorawan/settings', 'action_41040'],
	);
}

1;
