// The Pen app. It is the mailbox's assistant section as an app of its own: the
// panel it opens is the shared mailbox render scoped to the pen section (see
// /manager/pen and mail_checker), so the conversation picker, the thread and
// the socket all come from the one place, and the window carries no switcher -
// the pen is the only section it owns.
$(document).on('click', '#pen_toggle', function () {
	$.ajax({
		url: '/manager/pen',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) { windowMaker(response); }
	});
});
