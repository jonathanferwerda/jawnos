package JawnOS::Routes::manager_mail2;

use strict;
use warnings;

sub routes {
	return (
	[31987, 'post', '/manager/mail/email/template/save', 'action_31987'],
	[32024, 'get', '/manager/mail/email/template', 'action_32024'],
	[32033, 'post', '/manager/mail/email/send', 'action_32033'],
	[32126, 'get', '/manager/mail/email/attachment_preparer', 'action_32126'],
	[32167, 'get', '/manager/mail/scroll', 'action_32167'],
	[32176, 'post', '/manager/mail/public_channel', 'action_32176'],
	[32554, 'get', '/manager/mail/config', 'action_32554'],
	[32572, 'post', '/manager/mail/config', 'action_32572'],
	[32585, 'post', '/manager/mail/delete_conversation', 'action_32585'],
	[32612, 'get', '/manager/mail/qr_generator', 'action_32612'],
	);
}

1;
