package JawnOS::Routes::manager_security2;

use strict;
use warnings;

sub routes {
	return (
	[39714, 'post', '/manager/security/fingerprint_unlock', 'action_39714'],
	[39809, 'get', '/manager/security/fingerprint_unlock_status', 'action_39809'],
	[39861, 'get', '/manager/security/go_status', 'action_39861'],
	[39906, 'post', '/manager/security/go_ask', 'action_39906'],
	[39930, 'post', '/manager/security/go_approve', 'action_39930'],
	[40000, 'get', '/manager/security/go_open_peer', 'action_40000'],
	[40024, 'get', '/manager/security/go_clear_peer', 'action_40024'],
	[40080, 'post', '/manager/security/biometric_challenge', 'action_40080'],
	[40103, 'post', '/manager/security/biometric_enroll', 'action_40103'],
	[40145, 'post', '/manager/security/biometric_unlock', 'action_40145'],
	[40212, 'post', '/manager/security/padlock_challenge', 'action_40212'],
	[40232, 'post', '/manager/security/padlock_unlock', 'action_40232'],
	[40314, 'get', '/manager/security/padlock_open_peer', 'action_40314'],
	);
}

1;
