package JawnOS::Routes::manager_power;

use strict;
use warnings;

sub routes {
	return (
		[53010, 'get',  '/manager/power',          'action_53010'],
		[53011, 'get',  '/manager/power_status',   'action_53011'],
		[53012, 'post', '/manager/power/plan',     'action_53012'],
		[53013, 'post', '/manager/power/auto',     'action_53013'],
		[53014, 'post', '/manager/power/apply',    'action_53014'],
		[53015, 'post', '/manager/power/sleep',    'action_53015'],
		[53016, 'post', '/manager/power/sleep_now', 'action_53016'],
		[53017, 'post', '/manager/power/charge',   'action_53017'],
		[53018, 'post', '/manager/power/manage',   'action_53018'],
	);
}

1;
