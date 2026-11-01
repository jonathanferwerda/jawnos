package JawnOS::Routes::apps_misc;

use strict;
use warnings;

sub routes {
	return (
	[27002, 'get', '/apps/icon', 'action_27002'],
	[27037, 'get', '/apps/list', 'action_27037'],
	[27049, 'get', '/apps/start', 'action_27049'],
	);
}

1;
