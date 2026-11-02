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
	);
}

1;
