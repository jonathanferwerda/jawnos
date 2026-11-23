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
		[53025, 'post', '/manager/sound/level',   'action_53025'],
		[53026, 'post', '/manager/sound/profile', 'action_53026'],
		[53030, 'post', '/manager/sound/plan',    'action_53030'],
		[53031, 'get',  '/manager/sound/plan',    'action_53031'],
		[53032, 'post', '/manager/sound/manage',  'action_53032'],
		[53033, 'post', '/manager/sound/param',   'action_53033'],
		[53034, 'post', '/manager/sound/device',  'action_53034'],
		[53035, 'get',  '/manager/sound/apps',    'action_53035'],
		[53036, 'post', '/manager/sound/app',     'action_53036'],
		[53037, 'post', '/manager/sound/monitor', 'action_53037'],
	);
}

1;
