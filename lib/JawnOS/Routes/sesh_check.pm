package JawnOS::Routes::sesh_check;

use strict;
use warnings;

sub routes {
	return (
	[7519, 'post', '/sesh_check', 'action_7519'],
	);
}

1;
