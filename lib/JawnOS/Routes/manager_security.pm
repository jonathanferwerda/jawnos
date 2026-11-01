package JawnOS::Routes::manager_security;

use strict;
use warnings;

sub routes {
	return (
	[37688, 'get', '/manager/security', 'action_37688'],
	[37811, 'post', '/manager/security/signatorial/selection', 'action_37811'],
	[37823, 'post', '/manager/security/neighbour_link_assign', 'action_37823'],
	[37842, 'post', '/manager/security/neighbour_link_privilege', 'action_37842'],
	[38137, 'post', '/manager/security/device_revoke', 'action_38137'],
	[38154, 'post', '/manager/security/person_assign', 'action_38154'],
	[38168, 'post', '/manager/security/person_create', 'action_38168'],
	[38192, 'post', '/manager/security/shares/create', 'action_38192'],
	[38216, 'post', '/manager/security/person_revoke', 'action_38216'],
	[38234, 'post', '/manager/security/shares/key', 'action_38234'],
	[38250, 'post', '/manager/security/shares/wrap', 'action_38250'],
	[38294, 'post', '/manager/security/shares/mine', 'action_38294'],
	[38317, 'post', '/manager/security/shares/requests', 'action_38317'],
	[38340, 'post', '/manager/security/shares/release', 'action_38340'],
	[38357, 'post', '/manager/security/recovery/create', 'action_38357'],
	[38382, 'post', '/manager/security/confirm_code', 'action_38382'],
	[38414, 'post', '/manager/security/rotate_key', 'action_38414'],
	[38439, 'post', '/manager/security/legacy_reseal', 'action_38439'],
	[38610, 'post', '/manager/security/device_request_decide', 'action_38610'],
	[38655, 'post', '/manager/security/neighbour_link_delete', 'action_38655'],
	[38663, 'post', '/manager/security/padlock', 'action_38663'],
	[38698, 'post', '/manager/security/padlock/delete', 'action_38698'],
	[38712, 'post', '/manager/security/gate/enable', 'action_38712'],
	[38741, 'post', '/manager/security/gate/disable', 'action_38741'],
	[38766, 'post', '/manager/security/lockdown_unlock', 'action_38766'],
	[38787, 'post', '/manager/security/padlock_pull', 'action_38787'],
	[39632, 'post', '/manager/security/padlock_watch', 'action_39632'],
	[39640, 'post', '/manager/security/padlock_phone_show', 'action_39640'],
	[39674, 'post', '/manager/security/padlock_request_cancel', 'action_39674'],
	[39683, 'post', '/manager/security/media_lock', 'action_39683'],
	);
}

1;
