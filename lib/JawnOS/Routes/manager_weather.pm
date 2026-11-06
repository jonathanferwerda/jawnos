package JawnOS::Routes::manager_weather;

use strict;
use warnings;

sub routes {
	return (
		[52010, 'get', '/manager/weather', 'action_52010'],
		[52011, 'get', '/manager/weather/data', 'action_52011'],
		[52012, 'get', '/manager/weather/history', 'action_52012'],
		[52013, 'post', '/manager/weather/backfill', 'action_52013'],
		[52014, 'get', '/manager/weather/accuracy', 'action_52014'],
		[52015, 'get', '/manager/weather/automations', 'action_52015'],
		[52016, 'post', '/manager/weather/automation', 'action_52016'],
		[52017, 'post', '/manager/weather/observe', 'action_52017'],
	);
}

1;
