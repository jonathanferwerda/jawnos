package JawnOS::Routes::manager_market;

use strict;
use warnings;

sub routes {
	return (
	[3422, 'get', '/manager/market', 'action_3422'],
	[3429, 'post', '/manager/market/item_add', 'action_3429'],
	[3451, 'post', '/manager/market/item_kind', 'action_3451'],
	[3463, 'post', '/manager/market/item_delete', 'action_3463'],
	[3474, 'post', '/manager/market/item_flag', 'action_3474'],
	[3490, 'post', '/manager/market/cancel', 'action_3490'],
	[3497, 'post', '/manager/market/checkout', 'action_3497'],
	[3600, 'post', '/manager/market/packaging_add', 'action_3600'],
	[3694, 'get', '/manager/market/cameras', 'action_3694'],
	[3781, 'post', '/manager/market/scan/remote', 'action_3781'],
	[4102, 'post', '/manager/market/scan/session/start', 'action_4102'],
	[4136, 'post', '/manager/market/scan/session/device/add', 'action_4136'],
	[4162, 'post', '/manager/market/scan/session/device/remove', 'action_4162'],
	[4184, 'post', '/manager/market/scan/collect', 'action_4184'],
	[4249, 'get', '/manager/market/scan/session', 'action_4249'],
	[4255, 'post', '/manager/market/scan/session/done', 'action_4255'],
	[4301, 'post', '/manager/market/scan/session/cancel', 'action_4301'],
	[4317, 'post', '/manager/market/scan', 'action_4317'],
	[4355, 'post', '/manager/market/need', 'action_4355'],
	[4362, 'post', '/manager/market/refresh', 'action_4362'],
	);
}

1;
