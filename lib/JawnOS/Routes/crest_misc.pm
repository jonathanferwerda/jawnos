package JawnOS::Routes::crest_misc;

use strict;
use warnings;

sub routes {
	return (
	[23546, 'get', '/crest/:uuid/profile', 'action_23546'],
	);
}

1;
