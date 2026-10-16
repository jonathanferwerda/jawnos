// The Email app. It is Mailbox's email section as an app of its own: the panel it
// opens is the shared mailbox render, scoped to this one section (see
// /manager/email and mail_checker), so the folder list, the address picker, the
// conversation view and the socket all come from the one place.
//
// The email window reads and writes in place rather than in the window drawer:
// opening a letter (or Compose) fills #mail_reader over the list, and Back (or
// Cancel, or a completed Send) returns to it. The list loads a page at a time
// (/manager/mail/email/list) in the chosen order - date, sender or subject,
// ascending or descending, remembered as a setting. The rows are always in
// ascending order; a descending list starts at its foot and loads more above it.
// Letters can be ticked (a checkbox each, or Select all) for the bulk bar and
// dragged onto a folder to be filed. Everything here is scoped to
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

// The whole window's list pane, used only for the Contacts folder (the address
// picker), which the paged endpoint does not serve.
function emailListFull(done) {
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

function emailCurrentFolder() {
	return $('.email_folder_button.selected').attr('button') || 'inbox';
}

// The first page of the current folder in the current order, at the end the
// direction asks for (a descending list starts at its newest, its foot).
function emailListReset(done) {
	if (emailCurrentFolder() === 'contacts') { emailListFull(done); return; }
	var folder = emailCurrentFolder();
	var sort = $('#email_sort_by').val() || 'date';
	var dir = $('#email_sort_dir').attr('dir') || 'desc';
	$.ajax({
		url: '/manager/mail/email/list',
		type: 'GET',
		data: { folder: folder, sort: sort, dir: dir, offset: 0, limit: 50 },
		success: function (r) {
			$('#email_list_body').html(r.html);
			$('#email_list_more').attr('data-sort', sort).attr('data-dir', dir).attr('data-offset', r.offset).attr('data-more-up', r.more_up).attr('data-more-down', r.more_down);
			emailLoadingMore = 0;
			$('#mail_list').attr('searching', 'no');
			emailSelectionClear();
			emailAnchor();
			if (typeof mailDotClear == 'function') { mailDotClear(); }
			if (typeof done == 'function') { done(); }
		}
	});
}

function emailAnchor() {
	var l = $('#mail_list')[0];
	if (!l) { return; }
	if ($('#email_list_more').attr('data-dir') === 'desc') { l.scrollTop = l.scrollHeight; }
	else { l.scrollTop = 0; }
}

// The next page: appended below an ascending list, prepended above a descending
// one (and the scroll kept steady while the rows come in above).
function emailLoadMore() {
	var m = $('#email_list_more');
	if (emailLoadingMore) { return; }
	var dir = m.attr('data-dir');
	if (dir === 'desc' ? m.attr('data-more-up') !== '1' : m.attr('data-more-down') !== '1') { return; }
	emailLoadingMore = 1;
	var l = $('#mail_list')[0];
	var before = l.scrollHeight;
	$.ajax({
		url: '/manager/mail/email/list',
		type: 'GET',
		data: { folder: m.attr('data-folder'), sort: m.attr('data-sort'), dir: dir, offset: m.attr('data-offset'), limit: 50 },
		success: function (r) {
			if (dir === 'desc') { $('#email_list_body').prepend(r.html); }
			else { $('#email_list_body').append(r.html); }
			m.attr('data-offset', r.offset).attr('data-more-up', r.more_up).attr('data-more-down', r.more_down);
			if (dir === 'desc') { l.scrollTop += (l.scrollHeight - before); }
			emailLoadingMore = 0;
		},
		error: function () { emailLoadingMore = 0; }
	});
}

// A scroll does not bubble, so this is a capture-phase listener rather than a
// delegated one (the list element is kept and only its insides are swapped).
// A descending list loads more as it is scrolled *up*; an ascending one down.
document.addEventListener('scroll', function (e) {
	var t = e.target;
	if (!t || t.id !== 'mail_list') { return; }
	var m = document.getElementById('email_list_more');
	if (!m) { return; }
	if (m.getAttribute('data-dir') === 'desc') {
		if (m.getAttribute('data-more-up') === '1' && t.scrollTop < 160) { emailLoadMore(); }
	}
	else if (m.getAttribute('data-more-down') === '1' && t.scrollTop + t.clientHeight >= t.scrollHeight - 160) {
		emailLoadMore();
	}
}, true);

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
	emailListReset();
}

$(document).on('click', '#mail_reader_back', function () { emailReaderClose(); });

// A folder: remember it, mark it, reload the list (and leave the reading pane).
function emailFolder(button) {
	if (button === 'contacts') {
		settingSetter({ 'app': 'mail', 'setting': 'email_folder_selection', 'value': button });
		$('.email_folder_button').removeClass('selected');
		$('.email_folder_button[button="' + button + '"]').addClass('selected');
		$('#email_search').val('');
		emailShowList();
		emailListFull();
		return;
	}
	settingSetter({ 'app': 'mail', 'setting': 'email_folder_selection', 'value': button });
	$('.email_folder_button').removeClass('selected');
	$('.email_folder_button[button="' + button + '"]').addClass('selected');
	$('#email_search').val('');
	emailShowList();
	emailListReset();
}

$(document).on('click', '.wind[app="email"] .email_folder_button', function (e) {
	if ($(e.target).hasClass('email_folder_remove')) { return; }
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
	emailListFull();
});

// ---- the rail, the search, and the sort -------------------------------------
$(document).on('click', '#email_rail_toggle', function () {
	$('#mail_sidebar').toggle();
});

// Refetch the rail so a new (or removed) folder, and the counts, show at once.
function emailRailRefresh(done) {
	$.ajax({
		url: '/manager/mail/email/rail',
		type: 'GET',
		data: { email: localStorage.getItem('mail_email') || '' },
		success: function (r) {
			$('#mail_sidebar').html(r.html);
			emailBulkFolders();
			if (typeof done == 'function') { done(); }
		}
	});
}

// Keep the bulk bar's folder list in step with the rail.
function emailBulkFolders() {
	var sel = $('#email_bulk_folder');
	var cur = sel.val();
	sel.find('option:not(:first)').remove();
	$('#email_main_buttons .email_folder_button').each(function () {
		var f = $(this).attr('button');
		if (f === 'contacts' || f === 'starred' || f === 'outbox') { return; }
		sel.append($('<option></option>').attr('value', f).text($(this).find('.email_folder_name').text()));
	});
	sel.val(cur || '');
}

$(document).on('click', '#email_new_folder', function () {
	var name = window.prompt('New folder name');
	if (!name) { return; }
	$.post('/manager/mail/email/folder/add', { name: name }, function (r) {
		if (r.result === 'ok') { emailRailRefresh(); emailToast('Folder made'); }
		else if (r.result === 'exists') { emailToast('That folder already exists'); }
		else { emailToast('That name cannot be used'); }
	});
});

$(document).on('click', '.email_folder_remove', function () {
	var name = $(this).attr('folder');
	$.post('/manager/mail/email/folder/remove', { name: name }, function (r) {
		if (r.result !== 'ok') { return; }
		emailRailRefresh(function () {
			if (emailCurrentFolder() === name) {
				settingSetter({ 'app': 'mail', 'setting': 'email_folder_selection', 'value': 'inbox' });
				$('.email_folder_button').removeClass('selected');
				$('.email_folder_button[button="inbox"]').addClass('selected');
			}
			emailListReset();
		});
		emailToast('Folder removed; its mail is back in the Inbox');
	});
});

function emailSortPersist() {
	var by = $('#email_sort_by').val() || 'date';
	var dir = $('#email_sort_dir').attr('dir') || 'desc';
	settingSetter({ 'app': 'mail', 'setting': 'email_sort', 'value': JSON.stringify({ by: by, dir: dir }) });
	$('#email_search').val('');
	$('#mail_list').attr('searching', 'no');
	emailListReset();
}
$(document).on('change', '#email_sort_by', emailSortPersist);
$(document).on('click', '#email_sort_dir', function () {
	var b = $(this);
	var next = b.attr('dir') === 'asc' ? 'desc' : 'asc';
	b.attr('dir', next).html(next === 'asc' ? '&uarr;' : '&darr;');
	emailSortPersist();
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
			emailListReset();
			return;
		}
		$.ajax({
			url: '/manager/mail/email/search',
			type: 'GET',
			data: { q: q, folder: emailCurrentFolder(), sort: $('#email_sort_by').val(), dir: $('#email_sort_dir').attr('dir') },
			success: function (r) {
				$('#email_list_body').html(r.html);
				$('#email_list_more').attr('data-more-up', '0').attr('data-more-down', '0').attr('data-offset', '0').attr('data-dir', r.dir);
				$('#mail_list').attr('searching', 'yes').scrollTop(0);
				emailSelectionClear();
				emailToast(r.count + (r.count == 1 ? ' message' : ' messages') + ' for \u201c' + q + '\u201d');
			}
		});
	}, 300);
}
$(document).on('input', '#email_search', function () { emailSearchRun($(this).val()); });

$(document).on('click', '#email_refresh', function () {
	$('#email_search').val('');
	$('#mail_list').attr('searching', 'no');
	emailListReset();
	emailRailRefresh();
});

$(document).on('click', '#email_mark_read', function () {
	$.post('/manager/mail/email/mark_read', { folder: emailCurrentFolder() }, function (r) {
		emailListReset();
		emailRailRefresh();
		emailToast((r.count || 0) + ' marked read');
	});
});

$(document).on('click', '#email_empty_trash', function () {
	$.post('/manager/mail/email/empty_trash', {}, function (r) {
		emailListReset();
		emailRailRefresh();
		emailToast((r.count || 0) + ' deleted from Trash');
	});
});

// ---- the selection and the bulk bar -----------------------------------------
var emailSelection = {};
function emailSelectionCount() { return Object.keys(emailSelection).length; }
function emailSelectionSync() {
	var n = emailSelectionCount();
	$('#email_bulk_bar').toggle(n > 0);
	$('#email_bulk_count').text(n + ' selected');
	var all = $('#email_list_body .email_check').length;
	var checked = $('#email_list_body .email_check:checked').length;
	$('#email_select_all').prop('checked', all > 0 && all === checked);
}
function emailSelectionClear() {
	emailSelection = {};
	$('#email_list_body .email_check').prop('checked', false);
	emailSelectionSync();
}

$(document).on('change', '.wind[app="email"] .email_check', function () {
	var uuid = $(this).attr('uuid');
	if (this.checked) { emailSelection[uuid] = true; } else { delete emailSelection[uuid]; }
	emailSelectionSync();
});
$(document).on('change', '.wind[app="email"] #email_select_all', function () {
	var on = this.checked;
	$('#email_list_body .email_check').each(function () {
		this.checked = on;
		var uuid = $(this).attr('uuid');
		if (on) { emailSelection[uuid] = true; } else { delete emailSelection[uuid]; }
	});
	emailSelectionSync();
});

function emailBulk(action, folder, uuids) {
	var list = uuids || Object.keys(emailSelection);
	if (!list.length) { return; }
	$.post('/manager/mail/email/bulk', { action: action, folder: folder || '', uuids: list.join(',') }, function () {
		emailSelectionClear();
		emailListReset();
		emailRailRefresh();
		if (action === 'delete') { emailToast('Moved to Trash'); }
		else if (action === 'move' && folder) { emailToast('Moved to ' + folder); }
	});
}
$(document).on('change', '#email_bulk_folder', function () {
	var to = $(this).val();
	if (!to) { return; }
	$(this).val('');
	emailBulk('move', to);
});
$(document).on('click', '#email_bulk_read', function () { emailBulk('read'); });
$(document).on('click', '#email_bulk_unread', function () { emailBulk('unread'); });
$(document).on('click', '#email_bulk_delete', function () { emailBulk('delete'); });
$(document).on('click', '#email_bulk_clear', function () { emailSelectionClear(); });

// ---- drag and drop onto a folder --------------------------------------------
var emailDragUuids = [];
$(document).on('dragstart', '.wind[app="email"] .email_message', function (e) {
	var uuid = $(this).attr('uuid');
	emailDragUuids = emailSelection[uuid] ? Object.keys(emailSelection) : [uuid];
	var dt = e.originalEvent && e.originalEvent.dataTransfer;
	if (dt) { dt.setData('text/plain', emailDragUuids.join(',')); dt.effectAllowed = 'move'; }
	$(this).addClass('email_dragging');
});
$(document).on('dragend', '.wind[app="email"] .email_message', function () {
	$(this).removeClass('email_dragging');
	$('.email_drop_hover').removeClass('email_drop_hover');
});
$(document).on('dragover', '.wind[app="email"] .email_folder_button[data-nodrop!="1"]', function (e) {
	e.preventDefault();
	$(this).addClass('email_drop_hover');
});
$(document).on('dragleave', '.wind[app="email"] .email_folder_button', function () {
	$(this).removeClass('email_drop_hover');
});
$(document).on('drop', '.wind[app="email"] .email_folder_button[data-nodrop!="1"]', function (e) {
	e.preventDefault();
	$(this).removeClass('email_drop_hover');
	var to = $(this).attr('button');
	var raw = (e.originalEvent && e.originalEvent.dataTransfer.getData('text/plain')) || emailDragUuids.join(',');
	var list = raw.split(',').filter(function (x) { return x; });
	if (!list.length) { return; }
	emailBulk(to === 'trash' ? 'delete' : 'move', to === 'trash' ? '' : to, list);
});

// Open one message (its whole thread) in the pane.
function emailOpenMessage(uuid) {
	$.ajax({
		url: '/manager/mail/email/read',
		type: 'GET',
		data: { uuid: uuid },
		success: function (response) { emailReaderOpen(response.html); }
	});
}

// The reading pane's actions: Reply / Reply all / Forward, Edit a draft, Star,
// mark Unread, Restore out of Trash, and Move.
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
// soft delete). In Trash it offers the way back and the real delete instead.
function emailMoveMenu(uuid, $btn, folder) {
	$('#email_move_menu').remove();
	var folders = [];
	$('#email_main_buttons .email_folder_button').each(function () {
		var f = $(this).attr('button');
		if (f === 'contacts' || f === 'starred' || f === 'outbox') { return; }
		folders.push([f, $(this).find('.email_folder_name').text()]);
	});
	var items = (folder == 'trash')
		? [ ['restore', 'Restore to Inbox'], ['delete_forever', 'Delete forever'] ]
		: folders.concat([ ['trash', 'Trash'] ]);
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
	$.post('/manager/mail/email/flag', { uuid: uuid, flag: 'starred', value: next }, function () { emailListReset(); });
});

// ---- deleting: Trash, with an Undo ------------------------------------------
function emailTrash(uuid, closeReader) {
	$.post('/manager/mail/email/move', { uuid: uuid, to: 'trash' }, function () {
		if (closeReader) { emailShowList(); }
		emailListReset();
		emailRailRefresh();
		emailToast('Moved to Trash', 'Undo', function () {
			$.post('/manager/mail/email/restore', { uuid: uuid }, function () { emailListReset(); emailRailRefresh(); });
		});
	});
}

$(document).on('click', '.wind[app="email"] .email_deleter', function (e) {
	e.stopPropagation();
	var uuid = $(this).attr('uuid');
	if (!uuid) { return; }
	var inReader = $(this).closest('#mail_reader').length > 0;
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

// keep the bulk bar's folder list current on first open
$(function () { if ($('.wind[app="email"]').length) { emailBulkFolders(); } });
