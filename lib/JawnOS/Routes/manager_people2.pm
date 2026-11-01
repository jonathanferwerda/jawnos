package JawnOS::Routes::manager_people2;

use strict;
use warnings;

sub routes {
	return (
	[24511, 'post', '/manager/people/crest/vouch', 'action_24511'],
	[24540, 'post', '/manager/people/house_name', 'action_24540'],
	[24564, 'get', '/manager/people/crest_image', 'action_24564'],
	);
}

1;
