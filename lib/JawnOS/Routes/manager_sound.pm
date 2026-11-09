package JawnOS::Routes::manager_sound;

use strict;
use warnings;

sub routes {
	return (
		[53020, 'get',  '/manager/sound',         'action_53020'],
		[53021, 'get',  '/manager/sound_status',  'action_53021'],
		[53022, 'post', '/manager/sound/volume',  'action_53022'],
		[53023, 'post', '/manager/sound/mute',    'action_53023'],
		[53024, 'post', '/manager/sound/default', 'action_53024'],
	);
}

1;
