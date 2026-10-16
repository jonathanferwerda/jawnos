// The Email app. It is Mailbox's email section as an app of its own: the panel it
// opens is the shared mailbox render, scoped to this one section (see
// /manager/email and mail_checker), so the folder list, the address picker, the
// conversation view and the socket all come from the one place.
//
// The email window reads and writes in place rather than in the window drawer:
// opening a letter (or Compose) fills #mail_reader over the list, and Back (or
// Cancel, or a completed Send) returns to it. Switching a folder or an address
// refetches just #mail_list. The list loads a page at a time as it is scrolled
// (/manager/mail/email/list) and the Search box asks the server, which can read
// the sealed words (/manager/mail/email/search). Everything here is scoped to
// .wind[app="email"] so the Mailbox umbrella and Chat keep their own behaviour.
$(document).on('click', '#email_toggle', function () {
	$.ajax({
		url: '/manager/email',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function (response) { windowMaker(response); }
	});
});

// ---- the list, a page at a time ---------------------------------------------
var emailLoadingMore = 0;

// Pull just the list pane (the folder's first page, or the account picker) and
// swap it in, so the window and the folder rail are left alone.
function emailListRefresh(done) {
	$.ajax({
		url: '/manager/email',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes', email: localStorage.getItem('mail_email') },
		success: function (response) {
			var fresh = $(response).find('#mail_list').html();
			if (fresh !== undefined && fresh !== null) { $('#mail_list').html(fresh); }
			emailLoadingMore = 0;
			$('#mail_list').attr('searching', 'no').scrollTop(0);
			if (typeof mailDotClear == 'function') { mailDotClear(); }
			if (typeof done == 'function') { done(); }
		}
	});
}

// The next page of the current folder, appended below what is already shown.
function emailLoadMore() {
	var m = $('#email_list_more');
	if (emailLoadingMore || m.attr('data-more') != '1') { return; }
	emailLoadingMore = 1;
	m.text('Loading more\u2026');
	$.ajax({
		url: '/manager/mail/email/list',
		type: 'GET',
		data: { folder: m.attr('data-folder'), offset: m.attr('data-offset'), limit: 50 },
		success: function (r) {
			$('#email_list_body').append(r.html);
			m.attr('data-offset', r.offset).attr('data-more', r.more ? '1' : '0');
			m.text(r.more ? 'Loading more\u2026' : '');
			emailLoadingMore = 0;
		},
		error: function () { emailLoadingMore = 0; m.text(''); }
	});
}

// The list loads the next page as it is scrolled to the foot. A scroll does not
// bubble, so this is a capture-phase listener rather than a delegated one (the
// list element is kept and only its insides are swapped, so one listener lasts).
document.addEventListener('scroll', function (e) {
	var t = e.target;
	if (!t || t.id !== 'mail_list') { return; }
	var m = document.getElementById('email_list_more');
	if (!m || m.getAttribute('data-more') != '1') { return; }
	if (t.scrollTop + t.clientHeight >= t.scrollHeight - 160) { emailLoadMore(); }
}, true);

// A folder: remember it, mark it, reload the list (and leave the reading pane).
function emailFolder(button) {
	settingSetter({ 'app': 'mail', 'setting': 'email_folder_selection', 'value': button });
	$('.email_folder_button').removeClass('selected');
	$('.email_folder_button[button="' + button + '"]').addClass('selected');
	$('#email_search').val('');
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
	// a compose body is a rich editor (textarea[upgradeable]) - the upgrader runs
	// on render, so tell it the pane changed or the quoted letter shows as raw html
	if (typeof textareaUpgrader == 'function') { textareaUpgrader(); }
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

// Search the words themselves: subject, body, sender and the copies. The server
// decrypts to match, so this is a request rather than a filter of what is
// already on screen.
var emailSearchTimeout;
function emailSearchRun(q) {
	clearTimeout(emailSearchTimeout);
	emailSearchTimeout = setTimeout(function () {
		if (q.length < 2) {
			$('#mail_list').attr('searching', 'no');
			emailListRefresh();
			return;
		}
		$.ajax({
			url: '/manager/mail/email/search',
			type: 'GET',
			data: { q: q, folder: $('.email_folder_button.selected').attr('button') },
			success: function (r) {
				$('#email_list_body').html(r.html);
				$('#email_list_more').attr('data-more', '0').text('');
				$('#mail_list').attr('searching', 'yes');
				if (typeof emailToast == 'function') {
					emailToast(r.count + (r.count == 1 ? ' message' : ' messages') + ' for \u201c' + q + '\u201d');
				}
			}
		});
	}, 300);
}
$(document).on('input', '#email_search', function () { emailSearchRun($(this).val()); });

$(document).on('click', '#email_refresh', function () {
	$('#email_search').val('');
	$('#mail_list').attr('searching', 'no');
	emailListRefresh();
});

$(document).on('click', '#email_mark_read', function () {
	var folder = $('.email_folder_button.selected').attr('button') || 'inbox';
	$.post('/manager/mail/email/mark_read', { folder: folder }, function (r) {
		emailListRefresh();
		emailToast((r.count || 0) + ' marked read');
	});
});

$(document).on('click', '#email_empty_trash', function () {
	$.post('/manager/mail/email/empty_trash', {}, function (r) {
		emailListRefresh();
		emailToast((r.count || 0) + ' deleted from Trash');
	});
});

// Open one message (its whole thread) in the pane from the list or a flag change.
function emailOpenMessage(uuid) {
	$.ajax({
		url: '/manager/mail/email/read',
		type: 'GET',
		data: { uuid: uuid },
		success: function (response) { emailReaderOpen(response.html); }
	});
}

// The reading pane's actions: Reply / Reply all / Forward (the server builds the
// draft from the letter it answers), Edit a draft, Star, mark Unread, Restore
// out of Trash, Archive, and Move. Compose and Cancel ride the shared code.
$(document).on('click', '.wind[app="email"] .mail_action', function () {
	var action = $(this).attr('mail_action');
	var uuid = $(this).attr('uuid');
	var folder = $(this).closest('.mail_reader_message').attr('folder') || '';
	if (action == 'edit') { emailCompose('email', uuid); return; }
	if (action == 'reply' || action == 'reply_all' || action == 'forward') {
		$.ajax({
			url: '/manager/mail/email/compose',
			type: 'GET',
			data: { app: 'email', mode: action, in_reply_to: uuid, email: localStorage.getItem('mail_email') },
			success: function (response) { emailReaderOpen(response.html); }
		});
		return;
	}
	if (action == 'star') {
		var next = $(this).attr('starred') == 'yes' ? 'no' : 'yes';
		$.post('/manager/mail/email/flag', { uuid: uuid, flag: 'starred', value: next }, function () { emailOpenMessage(uuid); });
		return;
	}
	if (action == 'unread') {
		$.post('/manager/mail/email/flag', { uuid: uuid, flag: 'seen', value: 'no' }, function () { emailReaderClose(); });
		return;
	}
	if (action == 'restore') {
		$.post('/manager/mail/email/restore', { uuid: uuid }, function () {
			emailReaderClose();
			emailToast('Restored to Inbox');
		});
		return;
	}
	if (action == 'move') {
		emailMoveMenu(uuid, $(this), folder);
		return;
	}
});

// The move-to-folder menu: the folders a letter can be filed into (Trash is the
// soft delete). In Trash it offers the way back and the real delete instead. It
// floats under the button and closes on the next click elsewhere.
function emailMoveMenu(uuid, $btn, folder) {
	$('#email_move_menu').remove();
	var items = (folder == 'trash')
		? [ ['restore', 'Restore to Inbox'], ['delete_forever', 'Delete forever'] ]
		: [ ['inbox', 'Inbox'], ['archive', 'Archive'], ['drafts', 'Drafts'], ['sent', 'Sent'], ['trash', 'Trash'] ];
	var m = $('<div id="email_move_menu" class="email_move_menu"></div>');
	$.each(items, function (i, it) {
		m.append($('<button class="email_move_item"></button>').attr('uuid', uuid).attr('to', it[0]).text(it[1]));
	});
	var r = $btn[0].getBoundingClientRect();
	m.css({ position: 'fixed', left: Math.round(r.left) + 'px', top: Math.round(r.bottom + 4) + 'px' });
	$('body').append(m);
}

$(document).on('click', '#email_move_menu .email_move_item', function () {
	var uuid = $(this).attr('uuid');
	var to = $(this).attr('to');
	$('#email_move_menu').remove();
	if (to == 'delete_forever') {
		$.post('/manager/mail/email/delete', { uuid: uuid }, function () { emailReaderClose(); });
		return;
	}
	if (to == 'restore') {
		$.post('/manager/mail/email/restore', { uuid: uuid }, function () { emailReaderClose(); });
		return;
	}
	$.post('/manager/mail/email/move', { uuid: uuid, to: to }, function () { emailReaderClose(); });
});

$(document).on('click', function (e) {
	if (!$(e.target).closest('#email_move_menu').length && !$(e.target).closest('.mail_action').length) { $('#email_move_menu').remove(); }
});

// The star in a list row: flip the flag and reload the list, without opening the
// thread (the shared row handler skips clicks on .email_star).
$(document).on('click', '.wind[app="email"] .email_star', function () {
	var uuid = $(this).attr('uuid');
	var next = $(this).attr('starred') == 'yes' ? 'no' : 'yes';
	$.post('/manager/mail/email/flag', { uuid: uuid, flag: 'starred', value: next }, function () { emailListRefresh(); });
});

// ---- deleting: Trash, with an Undo ------------------------------------------
// A delete is a move to Trash and nothing is thrown away there until it is
// emptied, so the toast's Undo simply puts it back. The row's trash icon and the
// reading pane's both come through here (the shared mailbox handler stands down
// inside this window).
function emailTrash(uuid, closeReader) {
	$.post('/manager/mail/email/move', { uuid: uuid, to: 'trash' }, function () {
		if (closeReader) { emailShowList(); }
		emailListRefresh();
		emailToast('Moved to Trash', 'Undo', function () {
			$.post('/manager/mail/email/restore', { uuid: uuid }, function () { emailListRefresh(); });
		});
	});
}

$(document).on('click', '.wind[app="email"] .email_deleter', function (e) {
	e.stopPropagation();
	var uuid = $(this).attr('uuid');
	if (!uuid) { return; }
	var inReader = $(this).closest('#mail_reader').length > 0;
	// a second press in the reader deletes for good (the letter is already in Trash)
	if (inReader && $(this).closest('.mail_reader_message').attr('folder') == 'trash') {
		if ($(this).attr('armed') == 'yes') {
			$(this).attr('armed', 'no');
			$.post('/manager/mail/email/delete', { uuid: uuid }, function () { emailReaderClose(); });
		}
		else {
			$(this).attr('armed', 'yes');
			emailToast('Press Delete again to remove it for good');
		}
		return;
	}
	emailTrash(uuid, inReader);
});

// ---- the toast --------------------------------------------------------------
function emailToast(text, actionLabel, onAction) {
	$('#email_toast').remove();
	var t = $('<div id="email_toast" class="email_toast"></div>');
	t.append($('<span class="email_toast_text"></span>').text(text));
	if (actionLabel) {
		t.append($('<button class="email_toast_action"></button>').text(actionLabel).on('click', function () {
			$('#email_toast').remove();
			onAction();
		}));
	}
	$('body').append(t);
	setTimeout(function () { $('#email_toast').fadeOut(200, function () { $(this).remove(); }); }, 6000);
}
