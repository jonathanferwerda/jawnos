// The Notes app: what the watch heard that was not a command, plus anything typed
// here. The list comes from the notes table (its own store, not appointments). A
// row is clicked to edit, dragged onto an appointment window to fold into that
// app's notes, and removed with the two-click X.
$(document).on('click', '#notes_toggle', function() {
	notesMaker();
});

// The uuid of the note being edited, or null when the box is a new note.
var notesEditing = null;

function notesMaker(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/notes',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			if (response) { windowMaker(response); notesDraggable(); }
		}
	});
}

// The server pushes notesReload() the moment a note is filed or changed, so an
// open Notes window stays live instead of waiting for a reopen.
function notesReload() {
	var w = $('.wind[app="notes"]');
	if (!w.length) { return; }
	$.ajax({
		url: '/manager/notes',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: w.attr('timestamp') },
		success: function(response) {
			var fresh = $(response).find('#notes_list');
			if (fresh.length) { w.find('#notes_list').replaceWith(fresh); }
			notesDraggable();
		}
	});
}

// Enter saves; Shift+Enter is a newline on a desktop. On a phone Enter is a
// newline (as asked), so the Save button is how a phone saves.
$(document).on('keydown', '#notes_input', function(e) {
	if (e.key == 'Enter' && !e.shiftKey && !windowPhoneChecker()) {
		e.preventDefault();
		noteSave();
	}
});

$(document).on('click', '#notes_save', function() {
	noteSave();
});

function noteSave() {
	var input = $('#notes_input');
	var text = input.val();
	if (text == undefined || text.replace(/\s/g, '') == '') { return; }
	$.ajax({
		url: '/manager/note_save',
		type: 'POST',
		data: { uuid: notesEditing, text: text, timestamp: Date.now() },
		success: function(response) {
			input.val('');
			notesEditing = null;
			notesReload();
		}
	});
}

// Click a note's body to load it into the box for editing; saving updates the
// same row (notesEditing carries its uuid).
$(document).on('click', '.note_text', function(e) {
	var note = $(this).closest('.note');
	notesEditing = note.attr('uuid');
	$('#notes_input').val($(this).text()).focus();
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
			helper: 'clone',
			revert: 'invalid',
			zIndex: 999999,
			cancel: '.note_delete',
			start: function(p, ui) {
				$(ui.helper).css({ 'background-color': 'var(--panel)', 'border': 'solid', 'border-radius': '6px', 'padding': '6px', 'max-width': '320px' });
			},
			stop: function(p) {
				var el = document.elementFromPoint(p.clientX, p.clientY);
				var appt = $(el).closest('.appointment');
				if (!appt.length) { return; }
				$.ajax({
					url: '/manager/note_to_appt',
					type: 'POST',
					data: { uuid: n.attr('uuid'), app: appt.attr('app'), timestamp: Date.now() },
					success: function(response) {
						if (!response || !response.uuid) { console.log('note drop failed', response); }
					}
				});
			}
		});
	});
}
