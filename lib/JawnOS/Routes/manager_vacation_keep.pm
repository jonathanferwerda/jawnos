package JawnOS::Routes::manager_vacation_keep;

use strict;
use warnings;

sub routes {
	return (
	[60010, 'get', '/manager/vacation/keep', 'action_60010'],
	[60011, 'post', '/manager/vacation/keep', 'action_60011'],
	);
}

1;
