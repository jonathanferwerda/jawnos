package JawnOS::Routes::manager_scan;

use strict;
use warnings;

sub routes {
	return (
	[52326, 'get', '/manager/scan', 'action_52326'],
	[52327, 'get', '/manager/scan/pool', 'action_52327'],
	[52328, 'post', '/manager/scan/capture', 'action_52328'],
	[52329, 'post', '/manager/scan/discard', 'action_52329'],
	);
}

1;
