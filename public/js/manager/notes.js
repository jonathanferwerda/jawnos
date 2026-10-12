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
