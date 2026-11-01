package JawnOS::Routes::manager_folders;

use strict;
use warnings;

sub routes {
	return (
	[29094, 'post', '/manager/folders', 'action_29094'],
	[29220, 'get', '/manager/folders/desk', 'action_29220'],
	[29258, 'get', '/manager/folders/desk/apps', 'action_29258'],
	[29285, 'post', '/manager/folders/desk/apps', 'action_29285'],
	[29301, 'post', '/manager/folders/desk/folder', 'action_29301'],
	[29880, 'post', '/manager/folders/context', 'action_29880'],
	[29898, 'get', '/manager/folders/context/command', 'action_29898'],
	[30034, 'post', '/manager/folders/context/command', 'action_30034'],
	[30174, 'get', '/manager/folders/job', 'action_30174'],
	[30195, 'post', '/manager/folders/job/cancel', 'action_30195'],
	[30215, 'post', '/manager/folders/open_with', 'action_30215'],
	[30229, 'post', '/manager/folders/archive', 'action_30229'],
	[30272, 'post', '/manager/folders/archive/cancel', 'action_30272'],
	[30291, 'post', '/manager/folders/archive/retry', 'action_30291'],
	[30317, 'post', '/manager/folders/archive/locate', 'action_30317'],
	);
}

1;
