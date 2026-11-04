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
	);
}

1;
