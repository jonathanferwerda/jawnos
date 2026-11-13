package JawnOS::Routes::manager_weather;

use strict;
use warnings;

sub routes {
	return (
		[52320, 'get', '/manager/weather', 'action_52320'],
		[52321, 'get', '/manager/weather/data', 'action_52321'],
		[52322, 'get', '/manager/weather/history', 'action_52322'],
		[52013, 'post', '/manager/weather/backfill', 'action_52013'],
		[52014, 'get', '/manager/weather/accuracy', 'action_52014'],
		[52015, 'get', '/manager/weather/automations', 'action_52015'],
		[52016, 'post', '/manager/weather/automation', 'action_52016'],
		[52017, 'post', '/manager/weather/observe', 'action_52017'],
		[52018, 'post', '/manager/weather/location', 'action_52018'],
		[52019, 'post', '/manager/weather/measure_rule', 'action_52019'],
		[52323, 'post', '/manager/weather/location/delete', 'action_52323'],
		[52324, 'post', '/manager/weather/location/anchor', 'action_52324'],
		[52325, 'get', '/manager/weather/sources', 'action_52325'],
		[52023, 'post', '/manager/weather/sources', 'action_52023'],
	);
}

1;
