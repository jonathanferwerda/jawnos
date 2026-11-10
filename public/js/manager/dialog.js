// The dialog layer. Every .dialog_box is a small themed window - the Alert, a
// Folders question and a job's progress all wear the same shape (see
// templates/folders/dialog_box.html.ep and the #alert_dialog shell in
// manager.html.ep). A dialog rides above the windows; its taskbar tile brings
// it back or minimises it, its title bar drags it, and its own X closes it.

var jawnos_dialog_top = 10000;

function jawnosDialogRefresh() {
	if (typeof taskbarDisplayer == 'function') { taskbarDisplayer(); }
}

// Send a dialog to the top of the dialog stack and make it the one a second
// press on its taskbar tile minimises.
function jawnosDialogRaise(box) {
	box = $(box);
	if (!box.length) { return; }
	jawnos_dialog_top += 1;
	box.css('z-index', jawnos_dialog_top).attr('data-top', 'yes').show();
	$('.dialog_box').not(box).removeAttr('data-top');
	jawnosDialogRefresh();
}

// A dialog's taskbar tile: bring a minimised one back, raise a covered one, or
// minimise the one already on top - the same answer a window's tile gives.
function jawnosDialogToggle(id) {
	var box = $('.dialog_box[data-dialog-id="' + id + '"]');
	if (!box.length) { return; }
	if (!box.is(':visible')) {
		box.removeAttr('hidden').show();
		jawnosDialogRaise(box);
		return;
	}
	if (box.attr('data-top') == 'yes') {
		box.hide().removeAttr('data-top');
		jawnosDialogRefresh();
		return;
	}
	// the topmost visible dialog is the one a press minimises; any other is
	// covered and rises instead, as a window does
	var topz = -1, topbox = null;
	$('.dialog_box:visible').each(function() {
		var z = parseInt($(this).css('z-index'), 10) || 0;
		if (z >= topz) { topz = z; topbox = this; }
	});
	if (topbox === box[0]) {
		box.hide().removeAttr('data-top');
		jawnosDialogRefresh();
	}
	else {
		jawnosDialogRaise(box);
	}
}

// The Alert's #alert div is the dialog's body, so every caller that writes into
// it keeps working; this shell supplies the frame, the title and the close.
function jawnosDialogT(s) {
	return (typeof jawnosT === 'function') ? jawnosT(s) : s;
}

function jawnosAlert(html, options) {
	options = options || {};
	var dialog = $('#alert_dialog');
	var content = $('#alert');
	jawnosConfirmClear();
	if (!dialog.length) {
		// a page without the shell (an older template): the old behaviour
		if (html !== undefined) { content.html(html); }
		content.show();
		return;
	}
	if (html !== undefined) {
		content.html(html);
		$('#alert_message').text('');
	}
	// Back to the shell's own title if this Alert replaced a question.
	dialog.find('.jawnos_dialog_title').text(
		options.title || dialog.attr('data-dialog-title') || jawnosDialogT('Alert'));
	if (options.uuid) {
		content.attr('uuid', options.uuid);
		dialog.attr('uuid', options.uuid);
	}
	content.removeAttr('hidden');
	dialog.removeAttr('hidden').show();
	jawnosDialogRaise(dialog);
}

// A question with an OK and a Cancel, in the Alert's own shell. The engine's
// confirm() is a Qt, Android or OS box: it looks different on every machine and
// is unreadable where the house forces a black ground. This one is the house
// dialog, so the live image, the phone and the browser all ask the same way.
// The answer is a callback: on_yes runs only on OK, never on Cancel, the X or
// Escape. The message is text, not markup - it may name a record or a network.
var jawnos_confirm_yes = null;

function jawnosConfirm(message, on_yes, options) {
	options = options || {};
	var dialog = $('#alert_dialog');
	if (!dialog.length) {
		// a page without the shell (an older template): the browser's question
		if (typeof window.confirm === 'function' && !window.confirm(message)) { return; }
		if (typeof on_yes === 'function') { on_yes(); }
		return;
	}
	jawnos_confirm_yes = (typeof on_yes === 'function') ? on_yes : null;
	var content = $('#alert');
	content.text(message === undefined ? '' : message);
	$('#alert_message').text('');
	$('#alert_buttons').html(
		'<button type="button" class="cancel" id="alert_confirm_cancel">' + jawnosDialogT('Cancel') + '</button>' +
		'<button type="button" class="ok" id="alert_confirm_ok">' + jawnosDialogT('OK') + '</button>'
	).removeAttr('hidden').show();
	dialog.find('.jawnos_dialog_title').text(options.title || jawnosDialogT('Confirm'));
	content.removeAttr('hidden');
	dialog.removeAttr('hidden').show();
	jawnosDialogRaise(dialog);
}

// Drop a pending question without running it. Closing the shell is the same
// thing for an Alert, so both go through here first.
function jawnosConfirmClear() {
	jawnos_confirm_yes = null;
	$('#alert_buttons').hide().empty();
}

function jawnosAlertClose() {
	jawnosConfirmClear();
	var dialog = $('#alert_dialog');
	var content = $('#alert');
	$('#alert_message').text('');
	content.html('').attr('hidden', 'hidden');
	if (dialog.length) {
		dialog.hide().attr('hidden', 'hidden');
	}
	else {
		content.hide();
	}
	jawnosDialogRefresh();
}

$(document).on('click', '#alert_close', function() {
	jawnosAlertClose();
});

$(document).on('click', '#alert_confirm_ok', function() {
	var yes = jawnos_confirm_yes;
	jawnosAlertClose();
	if (typeof yes === 'function') { yes(); }
});

$(document).on('click', '#alert_confirm_cancel', function() {
	jawnosAlertClose();
});

// Drag a dialog by its title bar. A fixed, centred box is converted to left/top
// on the first move, so the drag does not fight its centring transform.
var jawnos_dialog_drag = null;
$(document).on('mousedown touchstart', '.dialog_box .jawnos_dialog_header, .dialog_box .folders_dialog_header', function(e) {
	if ($(e.target).closest('button, input, select, textarea, a').length) { return; }
	var box = $(this).closest('.dialog_box');
	var oe = e.originalEvent;
	var pt = (oe.touches && oe.touches.length) ? oe.touches[0] : oe;
	var off = box.offset();
	box.css({ left: off.left + 'px', top: off.top + 'px', transform: 'none' });
	jawnos_dialog_drag = { box: box, x: pt.clientX, y: pt.clientY, left: off.left, top: off.top };
	jawnosDialogRaise(box);
	e.preventDefault();
});
$(document).on('mousemove touchmove', function(e) {
	if (!jawnos_dialog_drag) { return; }
	var oe = e.originalEvent;
	var pt = (oe.touches && oe.touches.length) ? oe.touches[0] : oe;
	var dx = pt.clientX - jawnos_dialog_drag.x;
	var dy = pt.clientY - jawnos_dialog_drag.y;
	jawnos_dialog_drag.box.css({
		left: Math.max(0, jawnos_dialog_drag.left + dx) + 'px',
		top: Math.max(0, jawnos_dialog_drag.top + dy) + 'px'
	});
	e.preventDefault();
});
$(document).on('mouseup touchend touchcancel', function() { jawnos_dialog_drag = null; });

// A press anywhere in a dialog raises it, as a press on a window would. The
// raised one keeps data-top, so repeated presses inside it do no work.
$(document).on('mousedown touchstart', '.dialog_box', function() {
	if (!$(this).attr('data-top')) { jawnosDialogRaise(this); }
});

// Folders appends and removes its dialog boxes itself; keep the bar's tiles in
// step without asking every caller to remember.
$(function() {
	var holder = document.getElementById('dialog_boxes');
	if (holder && window.MutationObserver) {
		new MutationObserver(function() { jawnosDialogRefresh(); }).observe(holder, { childList: true });
	}
});
