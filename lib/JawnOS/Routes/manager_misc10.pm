package JawnOS::Routes::manager_misc10;

use strict;
use warnings;

sub routes {
	return (
	[30882, 'post', '/manager/ide/folder_toggle', 'action_30882'],
	[30894, 'post', '/manager/ide/file_create', 'action_30894'],
	[30901, 'post', '/manager/ide/file_delete', 'action_30901'],
	[30917, 'get', '/manager/ide/file_open', 'action_30917'],
	[30999, 'post', '/manager/ide/file_close', 'action_30999'],
	[31008, 'post', '/manager/ide/save', 'action_31008'],
	[31017, 'get', '/manager/mailbox', 'action_31017'],
	[31030, 'get', '/manager/email', 'action_31030'],
	[31042, 'get', '/manager/chat', 'action_31042'],
	[31062, 'get', '/manager/junderground/config', 'action_31062'],
	[31076, 'post', '/manager/junderground/config', 'action_31076'],
	[31088, 'post', '/manager/junderground/register', 'action_31088'],
	[31093, 'post', '/manager/junderground/dial', 'action_31093'],
	[31099, 'post', '/manager/junderground/room', 'action_31099'],
	[31105, 'post', '/manager/junderground/join', 'action_31105'],
	[31111, 'post', '/manager/junderground/leave', 'action_31111'],
	[31119, 'post', '/manager/junderground/friend', 'action_31119'],
	[31150, 'post', '/manager/junderground/translate', 'action_31150'],
	[31162, 'get', '/manager/pen', 'action_31162'],
	[32799, 'get', '/manager/apps/search', 'action_32799'],
	[32830, 'get', '/manager/home_plates', 'action_32830'],
	[34484, 'get', '/manager/handbook/:chapter', 'action_34484'],
	[34525, 'post', '/manager/handbook/journal', 'action_34525'],
	[34548, 'post', '/manager/handbook/plant', 'action_34548'],
	[34739, 'post', '/manager/dictate', 'action_34739'],
	[34966, 'post', '/manager/translate', 'action_34966'],
	[34997, 'get', '/manager/translate/languages', 'action_34997'],
	[35584, 'get', '/manager/resolve', 'action_35584'],
	[35592, 'post', '/manager/resolve/alias', 'action_35592'],
	[35597, 'post', '/manager/resolve/alias/remove', 'action_35597'],
	[35739, 'post', '/manager/remote_command', 'action_35739'],
	[35774, 'post', '/manager/remote_command/send', 'action_35774'],
	);
}

1;
