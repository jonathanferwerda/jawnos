package JawnOS::Routes::manager_crypto;

use strict;
use warnings;

sub routes {
	return (
	[8158, 'get', '/manager/crypto/apps', 'action_8158'],
	[8187, 'post', '/manager/crypto/tracking_app', 'action_8187'],
	[8469, 'post', '/manager/crypto/payment_request', 'action_8469'],
	[8527, 'post', '/manager/crypto/payment_approve', 'action_8527'],
	[8552, 'get', '/manager/crypto/payment_request', 'action_8552'],
	[8685, 'post', '/manager/crypto/proof_build', 'action_8685'],
	[8759, 'get', '/manager/crypto/qr', 'action_8759'],
	[8770, 'get', '/manager/crypto/rates', 'action_8770'],
	);
}

1;
