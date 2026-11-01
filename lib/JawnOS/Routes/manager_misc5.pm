package JawnOS::Routes::manager_misc5;

use strict;
use warnings;

sub routes {
	return (
	[14716, 'get', '/manager/download_file', 'action_14716'],
	[14764, 'post', '/manager/upload_file', 'action_14764'],
	[15230, 'any', '/manager/ai_chat', 'action_15230'],
	[15390, 'post', '/manager/continent/record', 'action_15390'],
	[15400, 'post', '/manager/navigation/nearby', 'action_15400'],
	[15450, 'get', '/manager/navigation/position', 'action_15450'],
	[15618, 'post', '/manager/continent/record_anyway', 'action_15618'],
	[15715, 'post', '/manager/continent/delete', 'action_15715'],
	[15836, 'post', '/manager/reset', 'action_15836'],
	[17621, 'post', '/manager/app_measures', 'action_17621'],
	[17778, 'post', '/manager/configuration/app_measure_configuration_matcher', 'action_17778'],
	[17807, 'post', '/manager/app_measure_delete', 'action_17807'],
	[17913, 'post', '/manager/inventory/evaluate', 'action_17913'],
	[17930, 'post', '/manager/inventory/evaluate/nightly', 'action_17930'],
	[17947, 'get', '/manager/inventory/information', 'action_17947'],
	[17984, 'get', '/manager/inventory/summary', 'action_17984'],
	[18252, 'get', '/manager/inventory/details', 'action_18252'],
	);
}

1;
