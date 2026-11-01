package JawnOS::Routes::manager_mail;

use strict;
use warnings;

sub routes {
	return (
	[31173, 'get', '/manager/mail/picker', 'action_31173'],
	[31181, 'get', '/manager/mail/contact', 'action_31181'],
	[31188, 'get', '/manager/mail/phone', 'action_31188'],
	[31196, 'get', '/manager/mail/email', 'action_31196'],
	[31203, 'get', '/manager/mail/email/configure', 'action_31203'],
	[31217, 'post', '/manager/mail/email/oauth/start', 'action_31217'],
	[31240, 'post', '/manager/mail/email/oauth/poll', 'action_31240'],
	[31262, 'get', '/manager/mail/email/receive', 'action_31262'],
	[31274, 'post', '/manager/mail/email/configure', 'action_31274'],
	[31306, 'post', '/manager/mail/email/server/add', 'action_31306'],
	[31319, 'post', '/manager/mail/email/server/delete', 'action_31319'],
	[31328, 'post', '/manager/mail/email/server/delete', 'action_31328'],
	[31344, 'get', '/manager/mail/email/compose', 'action_31344'],
	[31463, 'post', '/manager/mail/email/draft', 'action_31463'],
	[31513, 'get', '/manager/mail/email/read', 'action_31513'],
	[31546, 'post', '/manager/mail/email/flag', 'action_31546'],
	[31558, 'post', '/manager/mail/email/move', 'action_31558'],
	[31570, 'post', '/manager/mail/email/delete', 'action_31570'],
	[31577, 'post', '/manager/mail/email/empty_trash', 'action_31577'],
	[31584, 'post', '/manager/mail/email/restore', 'action_31584'],
	[31592, 'post', '/manager/mail/email/mark_read', 'action_31592'],
	[31606, 'post', '/manager/mail/email/bulk', 'action_31606'],
	[31634, 'post', '/manager/mail/email/folder/add', 'action_31634'],
	[31650, 'post', '/manager/mail/email/folder/remove', 'action_31650'],
	[31664, 'post', '/manager/mail/email/sender_app', 'action_31664'],
	[31701, 'get', '/manager/mail/email/rail', 'action_31701'],
	[31717, 'get', '/manager/mail/email/list', 'action_31717'],
	[31756, 'get', '/manager/mail/email/search', 'action_31756'],
	);
}

1;
