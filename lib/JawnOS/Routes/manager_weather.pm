package JawnOS::Routes::manager_weather;

use strict;
use warnings;

sub routes {
	return (
		[52010, 'get', '/manager/weather', 'action_52010'],
		[52011, 'get', '/manager/weather/data', 'action_52011'],
	);
}

1;
