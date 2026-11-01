package JawnOS::Routes::manager_help;

use strict;
use warnings;

sub routes {
	return (
	[34641, 'get', '/manager/help', 'action_34641'],
	[34659, 'get', '/manager/help/body', 'action_34659'],
	[34675, 'get', '/manager/help/welcome', 'action_34675'],
	[34679, 'post', '/manager/help/welcome', 'action_34679'],
	[34687, 'post', '/manager/help/ask', 'action_34687'],
	[34775, 'post', '/manager/help/listen', 'action_34775'],
	[34799, 'post', '/manager/help/feedback', 'action_34799'],
	[34818, 'post', '/manager/help/act', 'action_34818'],
	[35016, 'get', '/manager/help/find', 'action_35016'],
	[35025, 'get', '/manager/help/lookup', 'action_35025'],
	[35405, 'get', '/manager/help/where', 'action_35405'],
	[35412, 'get', '/manager/help/place', 'action_35412'],
	[35508, 'get', '/manager/help/measure', 'action_35508'],
	[35573, 'get', '/manager/help/music', 'action_35573'],
	[35579, 'get', '/manager/help/permitted', 'action_35579'],
	[36628, 'post', '/manager/help/schedule', 'action_36628'],
	[36632, 'post', '/manager/help/stage', 'action_36632'],
	[36644, 'post', '/manager/help/promote', 'action_36644'],
	[36648, 'post', '/manager/help/discard', 'action_36648'],
	[36656, 'post', '/manager/help/update', 'action_36656'],
	[36667, 'post', '/manager/help/stop', 'action_36667'],
	[36675, 'post', '/manager/help/delete', 'action_36675'],
	[36684, 'post', '/manager/help/undo', 'action_36684'],
	[36716, 'post', '/manager/help/generate', 'action_36716'],
	[36739, 'get', '/manager/help/staged', 'action_36739'],
	[36835, 'get', '/manager/help/verbs', 'action_36835'],
	[36839, 'post', '/manager/help/verbs', 'action_36839'],
	[36856, 'post', '/manager/help/verb', 'action_36856'],
	[37610, 'post', '/manager/help/review', 'action_37610'],
	);
}

1;
