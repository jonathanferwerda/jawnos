// The Email app. It is Mailbox's email section as an app of its own: the panel it
// opens is the shared mailbox render, scoped to this one section (see
// /manager/email and mail_checker), so the folder list, the address picker, the
// conversation view and the socket all come from the one place.
//
// The email window reads and writes in place rather than in the window drawer:
// opening a letter (or Compose) fills #mail_reader over the list, and Back (or
// Cancel, or a completed Send) returns to it. Switching a folder or an address
// refetches just #mail_list. Everything here is scoped to .wind[app="email"] so
// the Mailbox umbrella and Chat keep their own behaviour.
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
			emailSearchApply();
			if (typeof mailDotClear == 'function') { mailDotClear(); }
			if (typeof done == 'function') { done(); }
		}
	});
}

// A folder: remember it, mark it, reload the list (and leave the reading pane).
function emailFolder(button) {
	settingSetter({ 'app': 'mail', 'setting': 'email_folder_selection', 'value': button });
	$('.email_folder_button').removeClass('selected');
	$('.email_folder_button[button="' + button + '"]').addClass('selected');
	emailShowList();
	emailListRefresh();
}

// The list is the resting view; the reader covers it.
function emailShowList() {
	$('#mail_reader').hide();
	$('#mail_reader_content').empty();
	$('#mail_list').show();
}

// ---- the reading pane -------------------------------------------------------
function emailReaderOpen(html) {
	$('#mail_reader_content').html(html);
	$('#mail_list').hide();
	$('#mail_reader').show();
	$('#mail_reader').scrollTop(0);
}
function emailReaderClose() {
	emailShowList();
	// the folder may have moved (a send lands in Sent, a delete leaves), so the
	// list is refetched rather than trusted
	emailListRefresh();
}

$(document).on('click', '#mail_reader_back', function () { emailReaderClose(); });

$(document).on('click', '.wind[app="email"] .email_folder_button', function () {
	emailFolder($(this).attr('button'));
});

// An address: remember it (the shared sender and the socket read it), mark it,
// and show its folder.
$(document).on('click', '.wind[app="email"] .email_account_row', function () {
	var email = $(this).attr('email');
	localStorage.setItem('mail_email', email);
	localStorage.removeItem('mail_phone');
	$('.email_account_row').removeClass('active');
	$(this).addClass('active');
	$('#mail_sidebar .email_rail_account').text(email);
	emailShowList();
	emailListRefresh();
});

// ---- the rail, the search, and the row actions ------------------------------
$(document).on('click', '#email_rail_toggle', function () {
	$('#mail_sidebar').toggle();
});

function emailSearchApply() {
	var q = ($('#email_search').val() || '').toLowerCase();
	$('#mail_list tr.email_message').each(function () {
		var hay = ($(this).find('.email_party').text() + ' ' + $(this).find('.email_subject').text()).toLowerCase();
		$(this).toggle(q == '' || hay.indexOf(q) >= 0);
	});
}
$(document).on('input', '#email_search', function () { emailSearchApply(); });

// Reply, Reply all, Forward (the server builds the draft from the letter it
// answers) and Edit (reopen a draft). Compose and Cancel ride the shared code.
$(document).on('click', '.wind[app="email"] .mail_action', function () {
	var action = $(this).attr('mail_action');
	var uuid = $(this).attr('uuid');
	if (action == 'edit') { emailCompose('email', uuid); return; }
	$.ajax({
		url: '/manager/mail/email/compose',
		type: 'GET',
		data: { app: 'email', mode: action, in_reply_to: uuid, email: localStorage.getItem('mail_email') },
		success: function (response) { emailReaderOpen(response.html); }
	});
});

// Deleting from the reading pane should return to the list once the second press
// has actually deleted it (the shared handler arms on the first, deletes on the
// second, so the pane's own flag mirrors that).
$(document).on('click', '#mail_reader .email_deleter', function () {
	var d = $(this);
	if (d.attr('reader_armed') == 'yes') {
		d.attr('reader_armed', 'no');
		setTimeout(emailReaderClose, 400);
	}
	else {
		d.attr('reader_armed', 'yes');
	}
});
