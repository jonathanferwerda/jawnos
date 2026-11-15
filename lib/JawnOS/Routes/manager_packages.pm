package JawnOS::Routes::manager_packages;

use strict;
use warnings;

# The Packages app. The reads answer a JSON status and three lists; the five
# writes each take the machine's package lock and require confirm=1.
sub routes {
	return (
		[54020, 'get',  '/manager/packages',          'action_54020'],
		[54021, 'get',  '/manager/packages/status',   'action_54021'],
		[54022, 'get',  '/manager/packages/list',     'action_54022'],
		[54023, 'get',  '/manager/packages/outdated', 'action_54023'],
		[54024, 'get',  '/manager/packages/search',   'action_54024'],
		[54025, 'post', '/manager/packages/update',   'action_54025'],
		[54026, 'post', '/manager/packages/upgrade',  'action_54026'],
		[54027, 'post', '/manager/packages/install',  'action_54027'],
		[54028, 'post', '/manager/packages/remove',   'action_54028'],
		[54029, 'post', '/manager/packages/file',     'action_54029'],
	);
}

1;
