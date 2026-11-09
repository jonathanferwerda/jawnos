package JawnOS::Routes::manager_misc2;

use strict;
use warnings;

sub routes {
	return (
	[7112, 'post', '/manager/magazine/publishing_receive', 'action_7112'],
	[7170, 'post', '/manager/editor/save', 'action_7170'],
	[7226, 'post', '/manager/editor/delete', 'action_7226'],
	[7767, 'get', '/manager/debrief_grabber', 'action_7767'],
	[7783, 'post', '/manager/fuck_you', 'action_7783'],
	[7845, 'get', '/manager/network', 'action_7845'],
	[7849, 'get', '/manager/network/bluetooth/status', 'action_7849'],
	[7852, 'post', '/manager/network/bluetooth/scan', 'action_7852'],
	[7855, 'post', '/manager/network/bluetooth/action', 'action_7855'],
	[7857, 'get', '/manager/network/status', 'action_7857'],
	[7863, 'post', '/manager/network/wifi_scan', 'action_7863'],
	[7874, 'post', '/manager/network/wifi_connect', 'action_7874'],
	[7894, 'post', '/manager/network/wifi_disconnect', 'action_7894'],
	[7917, 'post', '/manager/network/radio', 'action_7917'],
	[7928, 'post', '/manager/network/interface', 'action_7928'],
	[7940, 'post', '/manager/network/vpn', 'action_7940'],
	[7943, 'get', '/manager/network/public_ip', 'action_7943'],
	[7944, 'post', '/manager/network/public_ip_lookup', 'action_7944'],
	[7994, 'get', '/manager/time_jump', 'action_7994'],
	[8094, 'post', '/manager/pay/setting', 'action_8094'],
	[8127, 'post', '/manager/pay/test', 'action_8127'],
	[8131, 'post', '/manager/pay/interac/scan', 'action_8131'],
	[8135, 'post', '/manager/pay/interac/record', 'action_8135'],
	[8139, 'post', '/manager/pay/interac/ignore', 'action_8139'],
	[8143, 'post', '/manager/pay/interac/token', 'action_8143'],
	[8965, 'get', '/manager/webauthn/list', 'action_8965'],
	[8987, 'post', '/manager/webauthn/register/begin', 'action_8987'],
	[9012, 'post', '/manager/webauthn/register/finish', 'action_9012'],
	[9050, 'post', '/manager/webauthn/remove', 'action_9050'],
	[9070, 'post', '/manager/webauthn/enroll_link', 'action_9070'],
	[9172, 'post', '/manager/webauthn/login/begin', 'action_9172'],
	[9190, 'post', '/manager/webauthn/login/finish', 'action_9190'],
	[9241, 'post', '/manager/tls/issue', 'action_9241'],
	[9253, 'get', '/manager/tls/status', 'action_9253'],
	[9711, 'get', '/manager/rsync_pack', 'action_9711'],
	[9720, 'post', '/manager/rsync_unpack', 'action_9720'],
	[9743, 'get', '/manager/backup_serve', 'action_9743'],
	);
}

1;
