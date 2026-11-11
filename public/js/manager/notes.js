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
			// The chips and their counts are redrawn with the rows, so the count a
			// save changes is right without reopening the window; the filter the
			// person is looking through is re-applied after the swap.
			var fresh = $(response).find('#notes_body');
			if (fresh.length) { w.find('#notes_body').replaceWith(fresh); }
			else {
				var list = $(response).find('#notes_list');
				if (list.length) { w.find('#notes_list').replaceWith(list); }
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

// ---- the note's own screen --------------------------------------------------
// Clicking a row does not edit it in the composer any more: the whole note gets
// the window, with Back (leave it as it was) and Save (write it). The textarea is
// upgradeable, so the editor brings its toolbox and dictation.
var notesEditUuid = null;

function notesEditHtml(text) {
	return $('<div>').text(text == null ? '' : String(text)).html().replace(/\n/g, '<br>');
}

function notesEditFocus(box) {
	if (!box || !box.length) { return; }
	try { box.focus(); } catch (e) {}
	try {
		var el = box[0];
		var range = document.createRange();
		range.selectNodeContents(el);
		range.collapse(false);
		var sel = window.getSelection();
		sel.removeAllRanges();
		sel.addRange(range);
	} catch (e) {}
}

// The upgrade request is async, so a very fast click can arrive before the
// contenteditable exists. Fill the hidden textarea at once (that is what the
// person sees until the upgrade lands) and retry the editor briefly.
function notesEditFill(uuid, text, tries) {
	tries = tries || 0;
	if (notesEditUuid != uuid) { return; }
	var box = $('#notes_edit_view .text_editor').first();
	if (box.length) {
		box.html(notesEditHtml(text));
		notesEditFocus(box);
		return;
	}
	if (tries >= 40) {
		$('#notes_edit_input').val(text).focus();
		return;
	}
	setTimeout(function() { notesEditFill(uuid, text, tries + 1); }, 50);
}

function notesEditOpen(uuid) {
	var note = null;
	notesHeaderRows().each(function() {
		if (($(this).attr('uuid') || '') == uuid) { note = $(this); }
	});
	if (!note) { return; }
	var text = note.attr('data-text');
	if (text === undefined) { text = note.find('.note_text').text(); }
	notesEditUuid = uuid;
	$('#notes_edit_category').val(note.attr('category') || 'uncategorized');
	$('#notes_edit_status').val(note.attr('status') || 'open');
	$('#notes_edit_input').val(text);
	$('#notes').addClass('edit_open');
	if (typeof textareaUpgrader == 'function') { textareaUpgrader(); }
	notesEditFill(uuid, text, 0);
}

function notesEditClose() {
	notesEditUuid = null;
	$('#notes').removeClass('edit_open');
}

// The upgraded editor holds HTML (a newline is a <br> or a block). A note is
// stored as plain words, so turn the editor back into text before saving; the
// server trims the ends and never sees markup.
function notesEditorPlainText() {
	var box = $('#notes_edit_view .text_editor').first();
	if (!box.length) { return $('#notes_edit_input').val() || ''; }
	var html = box.html() || '';
	html = html.replace(/<br\s*\/?>/gi, '\n');
	html = html.replace(/<\/(div|p|li|h[1-6])>/gi, '\n');
	html = html.replace(/<(div|p|li|h[1-6])(\s[^>]*)?>/gi, '');
	html = html.replace(/<[^>]*>/g, '');
	var decoder = document.createElement('textarea');
	decoder.innerHTML = html;
	return decoder.value.replace(/\u00a0/g, ' ').replace(/\n{3,}/g, '\n\n').replace(/^\s+|\s+$/g, '');
}

function notesEditSave() {
	var uuid = notesEditUuid;
	if (!uuid) { return; }
	var text = notesEditorPlainText();
	if (text.replace(/\s/g, '') == '') { return; }
	$.ajax({
		url: '/manager/note_save',
		type: 'POST',
		data: {
			uuid: uuid,
			text: text,
			category: $('#notes_edit_category').val() || '',
			status: $('#notes_edit_status').val() || '',
			timestamp: Date.now()
		},
		success: function(response) {
			delete notesHeaderCache[uuid];
			notesEditClose();
			notesReload();
		}
	});
}

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
