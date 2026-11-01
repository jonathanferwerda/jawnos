package JawnOS::Routes::manager_store2;

use strict;
use warnings;

sub routes {
	return (
	[6978, 'post', '/manager/store/appointment_option_selector', 'action_6978'],
	[8267, 'post', '/manager/store/crypto_panel', 'action_8267'],
	[8308, 'post', '/manager/store/crypto_payment', 'action_8308'],
	);
}

1;
