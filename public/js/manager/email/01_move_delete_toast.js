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

// An attachment from a sender the house does not know is a button, not a link:
// the download only happens when it is pressed.
$(document).on('click', '.wind[app="email"] .mail_att_download', function () {
	var href = $(this).attr('data-href');
	if (!href) { return; }
	var a = document.createElement('a');
	a.href = href;
	a.download = $(this).attr('data-name') || '';
	document.body.appendChild(a);
	a.click();
	a.remove();
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
