package JawnOS::Routes::manager_silence;

use strict;
use warnings;

sub routes {
	return (
		[53041, 'get',  '/manager/silence',      'action_53041'],
		[53042, 'post', '/manager/silence/peer', 'action_53042'],
	);
}

1;
