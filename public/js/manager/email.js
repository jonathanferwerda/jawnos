// The Email app. It is Mailbox's email section as an app of its own: the panel
// it opens is the shared mailbox render, scoped to this one section (see
// /manager/email and mail_checker), so the folder list, the address picker, the
// conversation view and the socket all come from the one place. The section's
// own markup and behaviour move out of the umbrella in the commits that follow.
$(document).on('click', '#email_toggle', function () {
	$.ajax({
		url: '/manager/email',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) { windowMaker(response); }
	});
});
