package JawnOS::Routes::manager_intelligence;

use strict;
use warnings;

sub routes {
	return (
		[92001, 'get', '/manager/intelligence', 'action_92001'],
		[92002, 'post', '/manager/intelligence/cadence', 'action_92002'],
	);
}

1;
