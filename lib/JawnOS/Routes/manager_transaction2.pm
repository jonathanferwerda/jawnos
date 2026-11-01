package JawnOS::Routes::manager_transaction2;

use strict;
use warnings;

sub routes {
	return (
	[16986, 'post', '/manager/transaction/record', 'action_16986'],
	[17895, 'get', '/manager/transaction/movement', 'action_17895'],
	);
}

1;
