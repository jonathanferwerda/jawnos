package JawnOS::Routes::Root_misc;

use strict;
use warnings;

sub routes {
	return (
	[2998, 'get', '/', 'action_2998'],
	[47831, 'post', 'manager/ws/remote_control', 'action_47831'],
	);
}

1;
