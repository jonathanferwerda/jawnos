package JawnOS::Routes::manager_budget;

use strict;
use warnings;

sub routes {
	return (
	[21514, 'get', '/manager/budget', 'action_21514'],
	[21971, 'post', '/manager/budget/edit', 'action_21971'],
	[22020, 'post', '/manager/budget/display/save', 'action_22020'],
	[22048, 'post', '/manager/budget/display/delete', 'action_22048'],
	[22060, 'post', '/manager/budget/import', 'action_22060'],
	[22088, 'post', '/manager/budget/reconcile', 'action_22088'],
	[22099, 'post', '/manager/budget/journal/rebuild', 'action_22099'],
	);
}

1;
