package JawnOS::Routes::manager_intelligence;

use strict;
use warnings;

sub routes {
	return (
		[92001, 'get', '/manager/intelligence', 'action_92001'],
		[92002, 'post', '/manager/intelligence/cadence', 'action_92002'],
		[92003, 'post', '/manager/intelligence/spread', 'action_92003'],
	);
}

1;
