package JawnOS::Routes::manager_relational;

use strict;
use warnings;

sub routes {
	return (
	[28581, 'get', '/manager/relational', 'action_28581'],
	[28834, 'get', '/manager/relational/workspace', 'action_28834'],
	[28839, 'post', '/manager/relational/link', 'action_28839'],
	[28851, 'get', '/manager/relational/select', 'action_28851'],
	[28867, 'post', '/manager/relational/adder', 'action_28867'],
	[28891, 'get', '/manager/relational/search', 'action_28891'],
	[28905, 'post', '/manager/relational/sorter', 'action_28905'],
	[28968, 'post', '/manager/relational/autocalc', 'action_28968'],
	[29051, 'get', '/manager/relational/tree', 'action_29051'],
	);
}

1;
