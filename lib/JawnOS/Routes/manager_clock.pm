package JawnOS::Routes::manager_clock;

use strict;
use warnings;

sub routes {
	return (
	[22718, 'get', '/manager/clock', 'action_22718'],
	[22738, 'get', '/manager/clock/state', 'action_22738'],
	[22744, 'post', '/manager/clock/alarm', 'action_22744'],
	[23042, 'post', '/manager/clock/preview', 'action_23042'],
	[23058, 'post', '/manager/clock/timer', 'action_23058'],
	);
}

1;
