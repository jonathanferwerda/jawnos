// The variable legend on an upgraded text editor: a bar across the top of the
// words, chips naming what this editor can say about the thing it is about,
// and a click that puts a name back where the caret was left. The semicolon
// comes with it, because that is how the magic knows the name is finished;
// when the chip carries a value the editor can answer for, the magic is asked
// at once and the value takes the words' place. A chip without a value is a
// name for later - a template owns it now, a document will answer it.

// where the caret was last seen, per editor, so a chip can hand it back
var textEditorCaret = {};

$(document).on('selectionchange', function() {
	var sel = window.getSelection();
	if (!sel.rangeCount) { return; }
	if (!sel.anchorNode) { return; }
	var box = $(sel.anchorNode).closest('.text_editor');
	if (!box.length) { return; }
	textEditorCaret[box.attr('id')] = sel.getRangeAt(0).cloneRange();
});

$(document).on('click', '.text_editor_variables_toggle', function() {
	var panel = $(this).closest('.text_editor_variables_bar').find('.text_editor_variables_panel');
	panel.toggle();
});

// a press anywhere else is a dismissal for every open legend
$(document).on('mousedown', function(e) {
	if ($(e.target).closest('.text_editor_variables_bar').length == 0) {
		$('.text_editor_variables_panel').hide();
	}
});

$(document).on('click', '.text_editor_variable', function() {
	var chip = $(this);
	var box = chip.closest('.text_editor_container').find('.text_editor');
	if (!box.length) { return; }
	// the words go back where the caret was left; the panel never moves them
	box.focus();
	var caret = textEditorCaret[box.attr('id')];
	if (caret) {
		var sel = window.getSelection();
		sel.removeAllRanges();
		sel.addRange(caret);
	}
	document.execCommand('insertText', false, chip.attr('variable') + ';');
	// the hidden textarea and everyone watching keep up, as on a keystroke
	$('#' + box.attr('source_id')).val(box.text());
	box.trigger('keyup');
	box.trigger('change');
	// where this editor has an answer, say it now
	if (chip.attr('value')) {
		textEditorMagic(box, true);
	}
});
