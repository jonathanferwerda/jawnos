package JawnOS::Routes::manifest_json_misc;

use strict;
use warnings;

sub routes {
	return (
	[13042, 'get', '/manifest.json', 'action_13042'],
	);
}

1;
