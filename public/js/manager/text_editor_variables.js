// The variable legend on an upgraded text editor - and on the plain fields
// (the compose subject) that speak the same names: a bar across the top of
// the words, chips naming what this field can say about the thing it is
// about, and a click that puts a name back where the caret was left. The
// semicolon comes with it, because that is how the magic knows the name is
// finished; when the chip carries a value the editor can answer for, the
// magic is asked at once and the value takes the words' place. A chip without
// a value is a name for later - a template owns it now, a document will
// answer it.

// where the caret was last seen, per field, so a chip can hand it back: a
// range for the rich editors, a pair of numbers for the plain ones
var textEditorCaret = {};
var textFieldCaret = {};

$(document).on('selectionchange', function() {
	var sel = window.getSelection();
	if (!sel.rangeCount) { return; }
	if (!sel.anchorNode) { return; }
	var box = $(sel.anchorNode).closest('.text_editor');
	if (!box.length) { return; }
	textEditorCaret[box.attr('id')] = sel.getRangeAt(0).cloneRange();
});

$(document).on('keyup click select focus', 'input[magic_vars]', function() {
	textFieldCaret[this.id] = { start: this.selectionStart, end: this.selectionEnd };
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
	var bar = chip.closest('.text_editor_variables_bar');
	var target = bar.attr('target');
	if (target) {
		textEditorVariableIntoField(chip, $('#' + target));
		return;
	}
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

// a chip for a plain field: the name goes in at the caret the field keeps,
// with its semicolon; the change it makes is what asks the magic to say the
// words, so a chip and a typing hand are answered by the same path
function textEditorVariableIntoField(chip, field) {
	if (!field.length) { return; }
	var variable = chip.attr('variable');
	field.focus();
	var value = field.val();
	var caret = textFieldCaret[field.attr('id')] || { start: value.length, end: value.length };
	var start = Math.min(caret.start, value.length);
	var end = Math.min(caret.end, value.length);
	field.val(value.slice(0, start) + variable + ';' + value.slice(end));
	var after = start + variable.length + 1;
	field[0].setSelectionRange(after, after);
	field.trigger('change');
}

// a plain field asks over the socket; the answer comes back as text, because
// there are no spans for it to wear
function textEditorPlainMagic(field) {
	ws['tab'].send(JSON.stringify({
		method: 'textAreaMagic',
		plain: 1,
		text: field.val(),
		id: field.attr('id'),
		magic_vars: field.attr('magic_vars') || ''
	}));
}

// a subject that has finished being typed has its words said; a value that
// comes back wearing an arrow just asks once more and is told nothing
$(document).on('change', 'input[magic_vars]', function() {
	if (!$(this).attr('magic_vars')) { return; }
	if ($(this).val().indexOf('->') >= 0) {
		textEditorPlainMagic($(this));
	}
});
