package JawnOS::Routes::manager_box_office;

use strict;
use warnings;

sub routes {
	return (
	[14039, 'get', '/manager/box_office', 'action_14039'],
	[14274, 'post', '/manager/box_office/approve', 'action_14274'],
	[14300, 'post', '/manager/box_office/decline', 'action_14300'],
	[14316, 'post', '/manager/box_office/blacklist', 'action_14316'],
	[14341, 'post', '/manager/box_office/blacklist/remove', 'action_14341'],
	[14353, 'post', '/manager/box_office/policy', 'action_14353'],
	[24775, 'post', '/manager/box_office/blacklist/number', 'action_24775'],
	);
}

1;
