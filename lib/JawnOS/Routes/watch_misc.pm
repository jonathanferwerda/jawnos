package JawnOS::Routes::watch_misc;

use strict;
use warnings;

sub routes {
	return (
	[41105, 'any', '/watch/lorawan', 'action_41105'],
	);
}

1;
