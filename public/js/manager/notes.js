/* [[js-split]]
   notes.js is part 1. The rest live in notes/ in name order:
     01_edit.js - the note's own screen
     02_categories.js - adding, renaming and removing categories
     03_row.js - row clicks, the inline editor, delete, drag and the chip filter
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// The Notes app: what the watch heard when it was not a command, plus anything typed
// here. The list comes from the notes table (its own store, not appointments). A
// row shows a one-line heading - the Guide's condensation when a model is
// configured, the server's word cut otherwise - and clicking it opens the whole
// note on a screen of its own. A row can also be dragged onto an appointment
// window to fold into that app's notes, and removed with the two-click X.
$(document).on('click', '#notes_toggle', function() {
	notesMaker();
});

// The composer only writes new notes now (an existing note opens on its own
// screen, with its own Save), so this stays null; the save still names it so an
// edit accidentally routed here would never become a second note.
var notesEditing = null;

function notesMaker(timestamp) {
	if (!timestamp) { timestamp = Date.now(); }
	$.ajax({
		url: '/manager/notes',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: timestamp },
		success: function(response) {
			if (response) { windowMaker(response); notesDraggable(); notesCategoryApply(); notesHeaderPaint(); }
		}
	});
}

// One select's options traded for the freshly rendered ones, keeping the value
// the person already had when it still exists. Used after a list reload so the
// composer and the note screen never offer a category the chips no longer have.
function notesSelectRefresh(select, fresh) {
	if (!select.length || !fresh.length) { return; }
	var keep = select.val();
	select.empty();
	fresh.find('option').each(function() {
		select.append($(this).clone());
	});
	if (keep && select.find('option[value="' + keep + '"]').length) { select.val(keep); }
	else { select.val(select.find('option').first().val() || ''); }
}

// The server pushes notesReload() the moment a note is filed or changed, so an
// open Notes window stays live instead of waiting for a reopen. A category save
// takes the same path: the body (chips and rows) is replaced, the composer and
// note-screen pickers are refreshed from the same render, and the category
// screen is rewritten unless the person is editing in it right now.
function notesReload() {
	var w = $('.wind[app="notes"]');
	if (!w.length) { return; }
	$.ajax({
		url: '/manager/notes',
		type: 'GET',
		data: { window_maker: 'yes', timestamp: w.attr('timestamp') },
		success: function(response) {
			var doc = $('<div>').html(response);
			// The chips and their counts are redrawn with the rows, so the count a
			// save changes is right without reopening the window; the filter the
			// person is looking through is re-applied after the swap.
			var fresh = doc.find('#notes_body');
			if (fresh.length) { w.find('#notes_body').replaceWith(fresh); }
			else {
				var list = doc.find('#notes_list');
				if (list.length) { w.find('#notes_list').replaceWith(list); }
			}
			notesSelectRefresh(w.find('#notes_category'), doc.find('#notes_category'));
			notesSelectRefresh(w.find('#notes_edit_category'), doc.find('#notes_edit_category'));
			notesSelectRefresh(w.find('#notes_edit_status'), doc.find('#notes_edit_status'));
			// A category removed on another machine (or by this save) must not leave the
			// list filtered to a chip that no longer exists.
			if (notesCategoryFilter && !w.find('#notes_category_bar .notes_chip[category="' + notesCategoryFilter + '"]').length) {
				notesCategoryFilter = '';
			}
			if (!w.find('#notes').hasClass('categories_open')) {
				var fresh_categories = doc.find('#notes_categories_view');
				if (fresh_categories.length) { w.find('#notes_categories_view').replaceWith(fresh_categories); }
			}
			// The fresh rows carry blank .time spans; paint them now, in the same
			// frame as the swap, instead of waiting for the next one-second tick.
			// Otherwise the list is briefly one line shorter and then grows.
			if (typeof appointment_chron === 'function') { appointment_chron(); }
			notesDraggable();
			notesCategoryApply();
			notesHeaderPaint();
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
		data: { uuid: notesEditing, text: text, category: $('#notes_category').val() || '', timestamp: Date.now() },
		success: function(response) {
			input.val('');
			notesEditing = null;
			notesReload();
		}
	});
}

// ---- headings ---------------------------------------------------------------
// The list is one line per note. The server already drew the word cut; the Guide
// is asked for a better heading only when a model is configured (the #notes
// data-header-agent flag), and only for the rows the person can see. The answer
// is cached against the row's signature, so a re-render, a scroll back, or a
// second window does not spend another model call. A saved note gets a new
// signature and its heading is asked for again.
var notesHeaderCache = {};
var notesHeaderPending = {};
var notesHeaderObserver = null;

function notesHeaderRows() {
	return $('#notes_list .note');
}

function notesHeaderApply(uuid, sig, header) {
	notesHeaderRows().each(function() {
		var n = $(this);
		if ((n.attr('uuid') || '') != uuid) { return; }
		if ((n.attr('data-sig') || '') != sig) { return; }
		n.find('.note_text').text(header);
	});
}

// A note that already fits the heading budget IS its heading, so a model call
// could only repeat it. Only the long rows ask the Guide; the rest keep the
// server's own line and cost nothing.
function notesHeaderNeeded(note) {
	var text = note.attr('data-text');
	if (text === undefined) { return true; }
	var line = String(text).replace(/\s+/g, ' ').replace(/^ | $/g, '');
	if (!line.length) { return false; }
	return !(line.length <= 60 && line.split(' ').length <= 12);
}

function notesHeaderRequest(note) {
	if (($('#notes').attr('data-header-agent') || '0') != '1') { return; }
	if (!notesHeaderNeeded(note)) { return; }
	var uuid = note.attr('uuid') || '';
	var sig = note.attr('data-sig') || '';
	if (!uuid) { return; }
	var cached = notesHeaderCache[uuid];
	if (cached && cached.sig == sig) { return; }
	var key = uuid + ':' + sig;
	if (notesHeaderPending[key]) { return; }
	notesHeaderPending[key] = 'yes';
	$.ajax({
		url: '/manager/note_header',
		type: 'POST',
		data: { uuid: uuid, timestamp: Date.now() },
		success: function(response) {
			delete notesHeaderPending[key];
			if (!response || !response.header) { return; }
			notesHeaderCache[uuid] = { sig: sig, header: response.header };
			notesHeaderApply(uuid, sig, response.header);
		},
		error: function() { delete notesHeaderPending[key]; }
	});
}

function notesHeaderPaint() {
	var list = $('#notes_list');
	if (!list.length) { return; }
	if (notesHeaderObserver) { notesHeaderObserver.disconnect(); notesHeaderObserver = null; }
	var rows = notesHeaderRows();
	// A cached heading wins over the server's cut; a changed note (a new data-sig)
	// drops the heading it no longer matches instead of showing yesterday's words.
	rows.each(function() {
		var n = $(this);
		var uuid = n.attr('uuid') || '';
		var sig = n.attr('data-sig') || '';
		if (!uuid) { return; }
		if (notesHeaderCache[uuid] && notesHeaderCache[uuid].sig == sig) {
			n.find('.note_text').text(notesHeaderCache[uuid].header);
		}
		else { delete notesHeaderCache[uuid]; }
	});
	if (($('#notes').attr('data-header-agent') || '0') != '1') { return; }
	if (typeof IntersectionObserver !== 'function') {
		rows.each(function() { notesHeaderRequest($(this)); });
		return;
	}
	// Only the rows on screen ask: a long notebook does not become one model call
	// per note, and opening a category is what fetches that category's rows.
	notesHeaderObserver = new IntersectionObserver(function(entries) {
		for (var i = 0; i < entries.length; i++) {
			if (entries[i].isIntersecting) { notesHeaderRequest($(entries[i].target)); }
		}
	}, { root: list[0], rootMargin: '160px 0px' });
	rows.each(function() { notesHeaderObserver.observe(this); });
}
