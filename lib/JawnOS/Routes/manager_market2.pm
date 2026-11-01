package JawnOS::Routes::manager_market2;

use strict;
use warnings;

sub routes {
	return (
	[4700, 'post', '/manager/market/receipt', 'action_4700'],
	[4765, 'post', '/manager/market/receipt/apply', 'action_4765'],
	[4828, 'get', '/manager/market/receipt/progress', 'action_4828'],
	[4866, 'get', '/manager/market/receipt/preview', 'action_4866'],
	[4883, 'get', '/manager/market/receipt/image', 'action_4883'],
	[4898, 'post', '/manager/market/receipt/cancel', 'action_4898'],
	[4913, 'get', '/manager/market/receipt_page', 'action_4913'],
	);
}

1;
