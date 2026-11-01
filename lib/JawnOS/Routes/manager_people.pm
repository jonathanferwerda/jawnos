package JawnOS::Routes::manager_people;

use strict;
use warnings;

sub routes {
	return (
	[23753, 'get', '/manager/people', 'action_23753'],
	[23879, 'get', '/manager/people/crest/detail', 'action_23879'],
	[23959, 'post', '/manager/people/crest/lookup', 'action_23959'],
	[24024, 'post', '/manager/people/construct/public', 'action_24024'],
	[24073, 'get', '/manager/people/person', 'action_24073'],
	[24140, 'post', '/manager/people/crest/link', 'action_24140'],
	[24150, 'get', '/manager/people/crest/qr', 'action_24150'],
	[24224, 'get', '/manager/people/crest/card', 'action_24224'],
	[24235, 'post', '/manager/people/crest/card/save', 'action_24235'],
	[24307, 'post', '/manager/people/crest/scan', 'action_24307'],
	[24331, 'post', '/manager/people/crest/capture', 'action_24331'],
	[24350, 'post', '/manager/people/crest/upload', 'action_24350'],
	[24359, 'post', '/manager/people/construct/crest/upload', 'action_24359'],
	[24370, 'post', '/manager/people/crest/verify', 'action_24370'],
	[24390, 'post', '/manager/people/crest/import', 'action_24390'],
	);
}

1;
