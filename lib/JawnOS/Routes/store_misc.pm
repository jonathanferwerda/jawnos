package JawnOS::Routes::store_misc;

use strict;
use warnings;

sub routes {
	return (
	[5514, 'get', '/store', 'action_5514'],
	[5659, 'get', '/store/category_grabber', 'action_5659'],
	[5719, 'post', '/store/search', 'action_5719'],
	[5823, 'get', '/store/item', 'action_5823'],
	[6055, 'post', '/store/quote/save', 'action_6055'],
	[6126, 'post', '/store/quote/delete', 'action_6126'],
	[6143, 'post', '/store/quote/move', 'action_6143'],
	[6192, 'get', '/store/quote/load', 'action_6192'],
	[6205, 'get', '/store/print', 'action_6205'],
	[52030, 'get', '/store/print/printers', 'action_52030'],
	[52031, 'post', '/store/print/send', 'action_52031'],
	[52032, 'get', '/store/print/pdf', 'action_52032'],
	[31938, 'get', '/store/email', 'action_31938'],
	);
}

1;
