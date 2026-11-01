package JawnOS::Routes::mail_misc;

use strict;
use warnings;

sub routes {
	return (
	[32633, 'get', '/mail/homepage_form', 'action_32633'],
	[45946, 'post', '/mail/msg', 'action_45946'],
	);
}

1;
