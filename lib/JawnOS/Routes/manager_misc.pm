package JawnOS::Routes::manager_misc;

use strict;
use warnings;

sub routes {
	return (
	[832, 'post', '/manager/take_picture', 'action_832'],
	[875, 'post', '/manager/unclaimed/claim', 'action_875'],
	[933, 'get', '/manager/unclaimed', 'action_933'],
	[959, 'get', '/manager/unclaimed/appointments', 'action_959'],
	[1141, 'post', '/manager/scan_document', 'action_1141'],
	[1360, 'post', '/manager/thumbs', 'action_1360'],
	[2946, 'post', '/manager/appointment/writer', 'action_2946'],
	[3017, 'get', '/manager/home', 'action_3017'],
	[3083, 'get', '/manager/register_grabber', 'action_3083'],
	[3104, 'get', '/manager/measures', 'action_3104'],
	[3134, 'post', '/manager/measures/assign', 'action_3134'],
	[3160, 'post', '/manager/measures/edit', 'action_3160'],
	[3186, 'post', '/manager/measures/delete', 'action_3186'],
	[4940, 'get', '/manager/process_monitor', 'action_4940'],
	[4950, 'get', '/manager/process_monitor/data', 'action_4950'],
	[5391, 'get', '/manager/warehouse', 'action_5391'],
	[5419, 'get', '/manager/warehouse/listing', 'action_5419'],
	[5455, 'post', '/manager/warehouse/stock_in', 'action_5455'],
	[5474, 'get', '/manager/warehouse/journal', 'action_5474'],
	[5502, 'get', '/manager/warehouse/on_hand', 'action_5502'],
	[7071, 'get', '/manager/editor', 'action_7071'],
	[7077, 'get', '/manager/magazine/neighbour_publish', 'action_7077'],
	);
}

1;
