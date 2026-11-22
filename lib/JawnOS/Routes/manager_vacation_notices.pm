package JawnOS::Routes::manager_vacation_notices;

use strict;
use warnings;

sub routes {
	return (
	[60020, 'get', '/manager/vacation/notices', 'action_60020'],
	);
}

1;
