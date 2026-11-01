package JawnOS::Routes::manager_transaction;

use strict;
use warnings;

sub routes {
	return (
	[16801, 'get', '/manager/transaction/autocomplete', 'action_16801'],
	[16824, 'get', '/manager/transaction/autofill', 'action_16824'],
	[16939, 'get', '/manager/transaction/information', 'action_16939'],
	[16961, 'get', '/manager/transaction/history_retriever', 'action_16961'],
	[16974, 'post', '/manager/transaction/status', 'action_16974'],
	);
}

1;
