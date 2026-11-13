package JawnOS::Routes::manager_controllers;

use strict;
use warnings;

sub routes {
	return (
	[54001, 'get',  '/manager/controllers',          'action_54001'],
	[54002, 'get',  '/manager/controllers/list',     'action_54002'],
	[54003, 'post', '/manager/controllers/request',  'action_54003'],
	[54004, 'post', '/manager/controllers/approve',  'action_54004'],
	[54005, 'get',  '/manager/controllers/storage',  'action_54005'],
	[54006, 'post', '/manager/controllers/storage',  'action_54006'],
	[54007, 'get',  '/manager/controllers/roms',     'action_54007'],
	[54008, 'post', '/manager/controllers/roms/copy', 'action_54008'],
	[54009, 'post', '/manager/controllers/new/scan',  'action_54009'],
	[54010, 'post', '/manager/controllers/new/flash', 'action_54010'],
	);
}

1;
