package JawnOS::Routes::public_view_misc;

use strict;
use warnings;

sub routes {
	return (
	[6221, 'get', '/public_view/:type/:uuid/:cx_uuid', 'action_6221'],
	);
}

1;
