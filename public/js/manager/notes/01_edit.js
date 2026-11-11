
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
	// Keep every space and blank line the person had: the editor shows pre-wrap,
	// and the server only trims the ends of the field. A non-breaking space is
	// how a browser remembers a run of spaces; it becomes a real space again.
	return decoder.value.replace(/\u00a0/g, ' ').replace(/^\s+|\s+$/g, '');
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
