package JawnOS::Routes::manager_misc7;

use strict;
use warnings;

sub routes {
	return (
	[25444, 'get', '/manager/appointment_details', 'action_25444'],
	[25646, 'post', '/manager/delete_duty', 'action_25646'],
	[25674, 'post', '/manager/appointment/autostop', 'action_25674'],
	[25772, 'post', '/manager/palette', 'action_25772'],
	[25890, 'get', '/manager/share', 'action_25890'],
	[25901, 'get', '/manager/note_retriever', 'action_25901'],
	[25914, 'get', '/manager/torch', 'action_25914'],
	[25928, 'get', '/manager/centre_view', 'action_25928'],
	[26091, 'get', '/manager/search_index', 'action_26091'],
	[26142, 'get', '/manager/keyup_search', 'action_26142'],
	[26178, 'get', '/manager/search', 'action_26178'],
	[26236, 'get', '/manager/search/apps', 'action_26236'],
	[26296, 'get', '/manager/search/engines', 'action_26296'],
	[26305, 'post', '/manager/search/engines/toggle', 'action_26305'],
	[26321, 'post', '/manager/search/engines/remove', 'action_26321'],
	[26361, 'post', '/manager/search/engines/add', 'action_26361'],
	);
}

1;
