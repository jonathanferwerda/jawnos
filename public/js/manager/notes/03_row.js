
// A row is a click target, except on its own controls. A drag sets the guard so
// releasing a note over an appointment window does not also open it.
$(document).on('click', '#notes_list .note', function(e) {
	if ($(e.target).closest('.note_delete, .note_editor, .note_edit, button, select, option, a, input, textarea').length) { return; }
	if ($(this).data('notes_dragged')) { return; }
	var uuid = $(this).attr('uuid') || '';
	if (uuid) { notesEditOpen(uuid); }
});

$(document).on('click', '#notes_edit_back', function() { notesEditClose(); });
$(document).on('click', '#notes_edit_save', function() { notesEditSave(); });

// The small editor on each row: category and status change in place. The same
// save route the composer uses persists them. The words are NOT sent: the row now
// shows a heading, so sending .note_text would replace the note with its own
// heading. The server leaves a field it is not handed alone, which is exactly
// what a category/status change wants.
$(document).on('change', '.note_category_edit, .note_status_edit', function() {
	var note = $(this).closest('.note');
	var uuid = note.attr('uuid');
	if (!uuid) { return; }
	var category = note.find('.note_category_edit').val() || 'uncategorized';
	var status = note.find('.note_status_edit').val() || 'open';
	$.ajax({
		url: '/manager/note_save',
		type: 'POST',
		data: {
			uuid: uuid,
			category: category,
			status: status,
			timestamp: Date.now()
		},
		success: function(response) { notesReload(); }
	});
});

// Two-click delete, the same arm-then-delete the other app rows use: the first
// press turns the X red and arms it for two seconds; a second press inside that
// window removes the note.
$(document).on('click', '.note_delete', function() {
	var a = $(this);
	if (a.attr('armed') == 'yes') {
		$.ajax({
			url: '/manager/note_delete',
			type: 'POST',
			data: { uuid: a.attr('uuid'), timestamp: Date.now() },
			success: function(response) {
				a.closest('.note').remove();
			}
		});
	}
	else {
		a.attr('armed', 'yes');
		var bgcolor = a.css('background-color');
		a.css({ 'background-color': 'red' });
		setTimeout(function() {
			a.css({ 'background-color': bgcolor });
			a.attr('armed', 'no');
		}, 2000);
	}
});

// Drag a note out of the list. What it lands on decides where it goes: an
// appointment window takes the note's text into that app's notes (the server
// encrypts it the way a reset's notes are encrypted).
function notesDraggable() {
	$('#notes_list .note').each(function(i, v) {
		var n = $(v);
		if (n.hasClass('ui-draggable')) { return; }
		n.draggable({
			appendTo: 'body',
			// Freeze the clone at the row's own width: out of the Notes window's
			// layout it re-wraps and collapses, which is the shrink that was seen.
			helper: function() {
				var el = $(this);
				var w = el.outerWidth();
				return el.clone().css({ width: w + 'px', maxWidth: w + 'px' });
			},
			revert: 'invalid',
			zIndex: 999999,
			cancel: '.note_delete, .note_editor, .note_edit',
			start: function(p, ui) {
				// A drag is not a click: releasing over an appointment window must fold
				// the note in, not open its editor. The click that follows mouseup sees
				// this guard (it is cleared a moment later).
				n.data('notes_dragged', true);
				$(ui.helper).css({ 'opacity': '0.85' });
			},
			stop: function(p, ui) {
				setTimeout(function() { n.data('notes_dragged', false); }, 120);
				// The helper rides under the cursor, and a full-screen background canvas
				// sits over the windows, so a plain elementFromPoint finds one of those
				// instead of the window. Walk the whole stack instead and take the first
				// appointment (and appointment row) under the cursor.
				var helper = (ui && ui.helper) ? $(ui.helper) : $('.ui-draggable-dragging');
				helper.hide();
				var stack = document.elementsFromPoint(p.clientX, p.clientY) || [];
				helper.show();
				var detail = null, appt = null;
				for (var i = 0; i < stack.length; i++) {
					var t = $(stack[i]);
					if (!appt && t.closest('.appointment').length) { appt = t.closest('.appointment'); }
					if (!detail && t.closest('.appointment_detail').length) { detail = t.closest('.appointment_detail'); }
				}
				if (!appt) { return; }
				// Landed on one of the window's appointment rows: append the note to
				// that appointment. Anywhere else on the window: the server makes a
				// new appointment for the app.
				$.ajax({
					url: '/manager/note_to_appt',
					type: 'POST',
					data: {
						uuid: n.attr('uuid'),
						app: appt.attr('app'),
						appt_uuid: detail ? detail.attr('uuid') : '',
						timestamp: Date.now()
					},
					success: function(response) {
						if (!response || (!response.uuid && !response.created)) { console.log('note drop failed', response); }
					}
				});
			}
		});
	});
}

// --- Categories ---------------------------------------------------
// The six categories a note is filed under. The chips, their counts and the
// picker are drawn by the server with their translated labels, so this script
// only moves them: which chip is showing, which rows belong under it, and the
// one link a category hands off to. Roadmap opens Store, Shopping opens Market,
// Dreams opens the Handbook's Today (where dreams are planted), Social opens
// People; Journal and JawnOS stay here, because JawnOS is the queue the nightly
// agent reads.
var notesCategoryFilter = '';

function notesCategoryApply() {
	var w = $('.wind[app="notes"]');
	if (!w.length) { return; }
	var filter = notesCategoryFilter || '';
	w.find('#notes_category_bar .notes_chip').each(function() {
		var chip = $(this);
		var on = (chip.attr('category') || '') == filter;
		chip.css({
			'opacity': (on ? '1' : '0.8'),
			'font-weight': (on ? 'bold' : 'normal'),
			'border-color': (on ? 'var(--ink, var(--line))' : 'var(--line)')
		});
	});
	w.find('#notes_list .note').each(function() {
		var note = $(this);
		note.toggle(filter == '' || (note.attr('category') || '') == filter);
	});
	w.find('.notes_category_open').each(function() {
		var link = $(this);
		link.toggle(filter != '' && (link.attr('category') || '') == filter);
	});
	// An empty category says so instead of showing a blank list.
	w.find('#notes_empty').toggle(filter != '' && w.find('#notes_list .note:visible').length == 0);
}

$(document).on('click', '#notes_category_bar .notes_chip', function() {
	notesCategoryFilter = $(this).attr('category') || '';
	var category = notesCategoryFilter;
	// A note written while a category is showing is filed under it.
	if (category) { $('#notes_category').val(category); }
	notesCategoryApply();
});

// The hand-off. Store, Market and People are windowMaker apps, so they open
// through appWindowOpener, which loads a lazy app's chunk first. The Handbook is
// not one: its own grabber is what its links use, and it opens on Today.
$(document).on('click', '.notes_category_open', function() {
	var target = $(this).attr('target') || '';
	if (!target) { return; }
	if (target == 'handbook') {
		if (typeof handbookGrabber == 'function') { handbookGrabber('today'); }
		return;
	}
	if (typeof appWindowOpener == 'function') { appWindowOpener(target, Date.now(), { visible: 'yes' }); }
});
