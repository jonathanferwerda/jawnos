package JawnOS::Routes::pay_misc;

use strict;
use warnings;

sub routes {
	return (
	[8568, 'get', '/pay/:provider/start', 'action_8568'],
	[8586, 'get', '/pay/:provider/return', 'action_8586'],
	[8614, 'any', '/pay/:provider/webhook', 'action_8614'],
	[8660, 'post', '/pay/interac/hook', 'action_8660'],
	);
}

1;
