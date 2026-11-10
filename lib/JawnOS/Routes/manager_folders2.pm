package JawnOS::Routes::manager_folders2;

use strict;
use warnings;

sub routes {
	return (
	[30356, 'post', '/manager/folders/archive/fetch', 'action_30356'],
	[30392, 'get', '/manager/folders/archive', 'action_30392'],
	[30436, 'post', '/manager/folders/archive/manifest/append', 'action_30436'],
	[30474, 'post', '/manager/folders/archive/manifest', 'action_30474'],
	[30505, 'post', '/manager/folders/archive/manifest/rescan', 'action_30505'],
	[30530, 'get', '/manager/folders/archive/dirs', 'action_30530'],
	[30537, 'post', '/manager/folders/archive/probe', 'action_30537'],
	[30562, 'post', '/manager/folders/archive/receive', 'action_30562'],
	[30651, 'post', '/manager/folders/file/open', 'action_30651'],
	[30660, 'post', '/manager/folders/archive/discard', 'action_30660'],
	[30700, 'post', '/manager/folders/cloud', 'action_30700'],
	[30701, 'post', '/manager/folders/cloud/start', 'action_30701'],
	[30702, 'get', '/manager/folders/cloud', 'action_30702'],
	[30703, 'post', '/manager/folders/cloud/remove', 'action_30703'],
	[30704, 'post', '/manager/folders/cloud/now', 'action_30704'],
	[30710, 'post', '/manager/folders/cloud/space', 'action_30710'],
	[30711, 'post', '/manager/folders/cloud/probe', 'action_30711'],
	[30712, 'post', '/manager/folders/cloud/receive', 'action_30712'],
	[30713, 'post', '/manager/folders/cloud/discard', 'action_30713'],
	[30715, 'post', '/manager/folders/cloud/register', 'action_30715'],
	[30716, 'post', '/manager/folders/cloud/unregister', 'action_30716'],
	[30717, 'post', '/manager/folders/cloud/delete', 'action_30717'],
	);
}

1;
