package JawnOS::Routes::box_office_misc;

use strict;
use warnings;

sub routes {
	return (
	[14132, 'any', '/box_office/ticket_request', 'action_14132'],
	[14382, 'get', '/box_office/:uuid', 'action_14382'],
	);
}

1;
