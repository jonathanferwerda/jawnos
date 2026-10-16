// The Email app. It is Mailbox's email section as an app of its own: the panel it
// opens is the shared mailbox render, scoped to this one section (see
// /manager/email and mail_checker), so the folder list, the address picker, the
// conversation view and the socket all come from the one place.
//
// Switching a folder or an address only changes the list, so it is refreshed in
// place here rather than through the shared mailMaker(), which re-rendered the
// whole window: windowMaker then re-dimensioned it and left a second window
// behind. The markup these handlers drive lives in templates/apps/email.html.ep;
// both are scoped to .wind[app="email"] so the Mailbox umbrella and Chat keep
// their own behaviour.
$(document).on('click', '#email_toggle', function () {
	$.ajax({
		url: '/manager/email',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) { windowMaker(response); }
	});
});

// Pull just the list pane (the folder's messages, or the account picker) and swap
// it in, so the window and the folder rail are left alone.
function emailListRefresh(done) {
	$.ajax({
		url: '/manager/email',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes', email: localStorage.getItem('mail_email') },
		success: function (response) {
			var fresh = $(response).find('#mail_list').html();
			if (fresh !== undefined && fresh !== null) { $('#mail_list').html(fresh); }
			if (typeof mailDotClear == 'function') { mailDotClear(); }
			if (typeof done == 'function') { done(); }
		}
	});
}

// A folder: remember it, mark it, and reload the list.
function emailFolder(button) {
	settingSetter({ 'app': 'mail', 'setting': 'email_folder_selection', 'value': button });
	$('.email_folder_button').removeClass('selected');
	$('.email_folder_button[button="' + button + '"]').addClass('selected');
	emailListRefresh();
}

$(document).on('click', '.wind[app="email"] .email_folder_button', function () {
	emailFolder($(this).attr('button'));
});

// An address: remember it (that is what the shared sender and the socket read),
// mark it, and show its folder.
$(document).on('click', '.wind[app="email"] .email_account_row', function () {
	var email = $(this).attr('email');
	localStorage.setItem('mail_email', email);
	localStorage.removeItem('mail_phone');
	$('.email_account_row').removeClass('active');
	$(this).addClass('active');
	$('#mail_sidebar .email_rail_account').text(email);
	emailListRefresh();
});
