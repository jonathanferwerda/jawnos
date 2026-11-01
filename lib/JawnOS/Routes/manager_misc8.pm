package JawnOS::Routes::manager_misc8;

use strict;
use warnings;

sub routes {
	return (
	[26376, 'post', '/manager/search/engine/probe', 'action_26376'],
	[26590, 'get', '/manager/search/web', 'action_26590'],
	[26602, 'post', '/manager/search/ai', 'action_26602'],
	[26628, 'post', '/manager/clipboard_setter', 'action_26628'],
	[26639, 'get', '/manager/clipboard_getter', 'action_26639'],
	[26651, 'get', '/manager/search_engine_grabber', 'action_26651'],
	[26677, 'get', '/manager/web', 'action_26677'],
	[26690, 'get', '/manager/web/measure/toggle', 'action_26690'],
	[26706, 'post', '/manager/web/measure/set', 'action_26706'],
	[26750, 'post', '/manager/web/measure/submit', 'action_26750'],
	[26776, 'post', '/manager/web/measure/delete', 'action_26776'],
	[26789, 'post', '/manager/web/delete', 'action_26789'],
	[26810, 'post', '/manager/usage/session', 'action_26810'],
	[26850, 'get', '/manager/usage/summary', 'action_26850'],
	[26872, 'get', '/manager/usage/timeline', 'action_26872'],
	[26892, 'post', '/manager/web/measure/live', 'action_26892'],
	[26928, 'get', '/manager/internet', 'action_26928'],
	[27089, 'get', '/manager/home_status', 'action_27089'],
	[27129, 'get', '/manager/internet/sites', 'action_27129'],
	[27172, 'post', '/manager/internet/site/app', 'action_27172'],
	[27187, 'get', '/manager/website_get', 'action_27187'],
	[27369, 'get', '/manager/browser', 'action_27369'],
	[27400, 'get', '/manager/media_window', 'action_27400'],
	[27426, 'get', '/manager/window_maker', 'action_27426'],
	[27624, 'get', '/manager/text_editor/create', 'action_27624'],
	);
}

1;
