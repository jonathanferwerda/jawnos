package JawnOS::Routes::manager_controllers;

use strict;
use warnings;

sub routes {
	return (
	[54001, 'get',  '/manager/controllers',          'action_54001'],
	[54002, 'get',  '/manager/controllers/list',     'action_54002'],
	[54003, 'post', '/manager/controllers/request',  'action_54003'],
	[54004, 'post', '/manager/controllers/approve',  'action_54004'],
	);
}

1;
