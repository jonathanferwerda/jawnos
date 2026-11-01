package JawnOS::Routes::teletype_misc;

use strict;
use warnings;

sub routes {
	return (
	[43123, 'get', '/teletype/neighbours', 'action_43123'],
	);
}

1;
