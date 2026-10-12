// The Notes app: everything the watch heard that was not a command. The list is
// built server-side from the appointments subs::voice_note_store writes, so the
// window is just fetched and drawn like any other app.
$(document).on('click', '#notes_toggle', function() {
	notesMaker();
});

function notesMaker(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/notes',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			if (response) { windowMaker(response); }
		}
	});
}

// The server pushes notesReload() the moment a note is filed, so an open Notes
// window shows the new line at once instead of on the next reopen. With no
// Notes window open there is nothing to redraw and this does nothing.
function notesReload() {
	var w = $('.wind[app="notes"]');
	if (!w.length) { return; }
	$.ajax({
		url: '/manager/notes',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: w.attr('timestamp') },
		success: function(response) {
			var fresh = $(response).find('#notes');
			if (fresh.length) { w.find('#notes').replaceWith(fresh); }
		}
	});
}

// Two-click delete, the same arm-then-delete the other app rows use: the first
// press turns the X red and arms it for two seconds; a second press inside that
// window removes the note. The row's own uuid keys the delete.
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
