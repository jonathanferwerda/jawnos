package JawnOS::Routes::js_misc;

use strict;
use warnings;

sub routes {
	return (
	[7407, 'get', '/js/manager/bundle.js', 'action_7407'],
	[7408, 'get', '/js/manager/app.js', 'action_7408'],
	);
}

1;
