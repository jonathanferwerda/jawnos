package JawnOS::Routes::manager_travel;

use strict;
use warnings;

sub routes {
	return (
	[15354, 'post', '/manager/travel/delete_map', 'action_15354'],
	[32638, 'get', '/manager/travel', 'action_32638'],
	[32651, 'get', '/manager/travel/nearby', 'action_32651'],
	[32878, 'post', '/manager/travel/plate', 'action_32878'],
	[33472, 'get', '/manager/travel/continent', 'action_33472'],
	[33508, 'post', '/manager/travel/guess_gap', 'action_33508'],
	[33680, 'get', '/manager/travel/guess_image', 'action_33680'],
	[33700, 'get', '/manager/travel/viewer', 'action_33700'],
	);
}

1;
