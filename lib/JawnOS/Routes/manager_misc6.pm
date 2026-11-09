package JawnOS::Routes::manager_misc6;

use strict;
use warnings;

sub routes {
	return (
	[18867, 'get', '/manager/icons', 'action_18867'],
	[22696, 'get', '/manager/notifications/list', 'action_22696'],
	[22699, 'get', '/manager/notifications', 'action_22699'],
	[22702, 'get', '/manager/notes', 'action_22702'],
	[23193, 'get', '/manager/camera', 'action_23193'],
	[24039, 'post', '/manager/crest/cosign', 'action_24039'],
	[24861, 'get', '/manager/app_draft', 'action_24861'],
	[24875, 'post', '/manager/app_draft', 'action_24875'],
	[24915, 'post', '/manager/app_draft/backfill', 'action_24915'],
	[24950, 'post', '/manager/note_save', 'action_24950'],
	[24980, 'post', '/manager/note_delete', 'action_24980'],
	[24989, 'post', '/manager/note_to_appt', 'action_24989'],
	[25102, 'post', '/manager/notifications/remove', 'action_25102'],
	[25133, 'get', '/manager/notifications/filter', 'action_25133'],
	[25140, 'get', '/manager/notifications/search', 'action_25140'],
	[25147, 'get', '/manager/notifications/scroll', 'action_25147'],
	[25150, 'get', '/manager/notifications/status', 'action_25150'],
	[25183, 'get', '/manager/appointment_viewer', 'action_25183'],
	[25345, 'get', '/manager/clothesline_rail', 'action_25345'],
	[25356, 'get', '/manager/tasks', 'action_25356'],
	[25364, 'post', '/manager/tasks', 'action_25364'],
	[25413, 'post', '/manager/tasks/delete', 'action_25413'],
	[25425, 'get', '/manager/appointment_measures', 'action_25425'],
	);
}

1;
