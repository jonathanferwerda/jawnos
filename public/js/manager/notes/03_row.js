
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
			cancel: '.note_delete, .note_editor, .note_edit, .note_select',
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
// The house's categories are drawn by the server with their translated labels;
// this script decides which of them are showing. The filter is one dropdown of
// checkboxes, so several categories can stay on screen at once. The choice is
// kept in the page (as the old single chip was), not in a setting: reopening the
// app starts on All. Roadmap opens Store, Shopping opens Market, Dreams opens
// the Handbook's Today (where dreams are planted), Social opens People; Journal
// and JawnOS stay here, because JawnOS is the queue the nightly agent reads.
var notesCategoryFilter = null; // null = every category; an array = the chosen few

// The categories the dropdown currently offers. The boxes are redrawn with the
// rows, so after a reload this is the fresh list.
function notesFilterCodes() {
	var codes = [];
	$('#notes_filter_menu .notes_filter_cat').each(function() {
		codes.push($(this).val() || '');
	});
	return codes;
}

function notesFilterShowing(code) {
	return notesCategoryFilter === null || notesCategoryFilter.indexOf(code) >= 0;
}

// A category removed on another machine must not leave the filter pointing at
// nothing. Selected codes that still exist stay; if the whole selection
// disappeared, fall back to All rather than a permanently empty list. An empty
// array the person chose with None stays empty.
function notesFilterReconcile() {
	if (notesCategoryFilter === null) { return; }
	var have = notesFilterCodes();
	var kept = [];
	for (var i = 0; i < notesCategoryFilter.length; i++) {
		if (have.indexOf(notesCategoryFilter[i]) >= 0) { kept.push(notesCategoryFilter[i]); }
	}
	notesCategoryFilter = (kept.length || !notesCategoryFilter.length) ? kept : null;
}

function notesCategoryApply() {
	var w = $('.wind[app="notes"]');
	if (!w.length) { return; }
	w.find('#notes_filter_menu .notes_filter_cat').each(function() {
		$(this).prop('checked', notesFilterShowing($(this).val() || ''));
	});
	w.find('#notes_list .note').each(function() {
		var note = $(this);
		note.toggle(notesFilterShowing(note.attr('category') || ''));
	});
	w.find('.notes_category_open').each(function() {
		var link = $(this);
		// A hand-off belongs to a category the person is reading, not to All.
		var on = notesCategoryFilter !== null && notesCategoryFilter.indexOf(link.attr('category') || '') >= 0;
		link.toggle(on);
	});
	// A filter that matches nothing says so instead of showing a blank list.
	var listed = w.find('#notes_list .note').length;
	w.find('#notes_empty').toggle(listed > 0 && w.find('#notes_list .note:visible').length == 0);
	notesSelectionRefresh();
}

// A note written while exactly one category is showing is filed under it.
function notesCategoryFilterAfterChange() {
	if (notesCategoryFilter !== null && notesCategoryFilter.length == 1) {
		$('#notes_category').val(notesCategoryFilter[0]);
	}
	notesCategoryApply();
}

$(document).on('click', '#notes_filter_toggle', function(e) {
	e.stopPropagation();
	$('#notes_filter_menu').toggle();
});

$(document).on('click', '#notes_filter_menu', function(e) {
	// A press inside the menu does not close it; the document handler closes it
	// only for a press elsewhere.
	e.stopPropagation();
});

$(document).on('click', function() {
	$('#notes_filter_menu').hide();
});

$(document).on('change', '.notes_filter_cat', function() {
	var code = $(this).val() || '';
	if (notesCategoryFilter === null) {
		// Dropping out of All takes the boxes as they now stand.
		notesCategoryFilter = [];
		$('#notes_filter_menu .notes_filter_cat').each(function() {
			if ($(this).prop('checked')) { notesCategoryFilter.push($(this).val() || ''); }
		});
	}
	else {
		var at = notesCategoryFilter.indexOf(code);
		if ($(this).prop('checked')) {
			if (at < 0) { notesCategoryFilter.push(code); }
		}
		else if (at >= 0) {
			notesCategoryFilter.splice(at, 1);
		}
	}
	notesCategoryFilterAfterChange();
});

$(document).on('click', '#notes_filter_all', function() {
	notesCategoryFilter = null;
	notesCategoryApply();
});

$(document).on('click', '#notes_filter_none', function() {
	notesCategoryFilter = [];
	notesCategoryApply();
});

// --- Selecting rows -------------------------------------------------
// Each row carries a tick. The bar above the list selects every row the current
// filter shows, clears the ticks, and deletes the ticked notes in one request.
// A single X still deletes one note its own way.
function notesSelectedUuids() {
	var uuids = [];
	$('#notes_list .note .note_select:checked').each(function() {
		var uuid = $(this).attr('uuid') || $(this).closest('.note').attr('uuid') || '';
		if (uuid) { uuids.push(uuid); }
	});
	return uuids;
}

function notesSelectionRefresh() {
	var count = notesSelectedUuids().length;
	var button = $('#notes_delete_selected');
	button.prop('disabled', count == 0);
	button.attr('data-count', count);
}

$(document).on('change', '.note_select', function() { notesSelectionRefresh(); });

$(document).on('click', '#notes_select_all', function() {
	$('#notes_list .note:visible .note_select').prop('checked', true);
	notesSelectionRefresh();
});

$(document).on('click', '#notes_clear_all', function() {
	$('#notes_list .note .note_select').prop('checked', false);
	notesSelectionRefresh();
});

// One Delete selected for the whole ticked set. The first press arms it for two
// seconds like a row's X, so a single stray click cannot remove a notebook; the
// second posts every uuid at once. The server tombstones them one by one through
// the same delete the X uses.
$(document).on('click', '#notes_delete_selected', function() {
	var button = $(this);
	var uuids = notesSelectedUuids();
	if (!uuids.length) { return; }
	if (button.attr('armed') != 'yes') {
		button.attr('armed', 'yes');
		var bgcolor = button.css('background-color');
		button.data('notes_delete_bg', bgcolor).css({ 'background-color': 'red' });
		setTimeout(function() {
			button.css({ 'background-color': button.data('notes_delete_bg') });
			button.attr('armed', 'no');
		}, 2000);
		return;
	}
	button.attr('armed', 'no').css({ 'background-color': button.data('notes_delete_bg') });
	button.prop('disabled', true);
	$.ajax({
		url: '/manager/notes_delete',
		type: 'POST',
		data: { uuids: JSON.stringify(uuids), timestamp: Date.now() },
		success: function(response) { notesReload(); },
		error: function() { notesSelectionRefresh(); }
	});
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
