package JawnOS::Routes::embedded_misc;

use strict;
use warnings;

sub routes {
	return (
	[9845, 'get', '/embedded/teletype/backup', 'action_9845'],
	);
}

1;
