package JawnOS::Routes::manager_budget2;

use strict;
use warnings;

sub routes {
	return (
	[22114, 'post', '/manager/budget/payable/add', 'action_22114'],
	[22201, 'post', '/manager/budget/payable/pay', 'action_22201'],
	[22236, 'post', '/manager/budget/payable/delete', 'action_22236'],
	[22249, 'post', '/manager/budget/payable/schedule/delete', 'action_22249'],
	[22257, 'post', '/manager/budget/payable/schedule/toggle', 'action_22257'],
	[22269, 'get', '/manager/budget/current_information', 'action_22269'],
	[22542, 'get', '/manager/budget/autocalc', 'action_22542'],
	);
}

1;
