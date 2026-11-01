package JawnOS::Routes::passkey_misc;

use strict;
use warnings;

sub routes {
	return (
	[9089, 'get', '/passkey', 'action_9089'],
	[9107, 'post', '/passkey/begin', 'action_9107'],
	[9132, 'post', '/passkey/finish', 'action_9132'],
	);
}

1;
