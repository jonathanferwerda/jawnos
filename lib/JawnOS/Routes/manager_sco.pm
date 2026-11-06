package JawnOS::Routes::manager_sco;

use strict;
use warnings;

sub routes {
	return (
	[52001, 'get',  '/manager/sco/status',    'action_52001'],
	[52002, 'post', '/manager/sco/arm',       'action_52002'],
	[52003, 'post', '/manager/sco/cancel',    'action_52003'],
	[52004, 'get',  '/manager/sco/result',    'action_52004'],
	[52005, 'get',  '/manager/sco/recording', 'action_52005'],
	[52006, 'post', '/manager/sco/rtc',       'action_52006'],
	[52007, 'post', '/manager/sco/say',       'action_52007'],
	[52008, 'post', '/manager/sco/hold',      'action_52008'],
	[52009, 'post', '/manager/sco/flow',      'action_52009'],
	[52010, 'post', '/manager/sco/voicemail', 'action_52010'],
	[52011, 'post', '/manager/sco/hangup',    'action_52011'],
	[52012, 'get',  '/manager/sco/transcript', 'action_52012'],
	);
}

1;
