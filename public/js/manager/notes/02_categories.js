
// ---- categories -------------------------------------------------------------
// The house's category list. A kept row posts its code; an added row posts none
// and the server gives it a fresh code. Back reloads (a discard); Save writes the
// list and reloads, so the chips, pickers and row labels all follow at once.

function notesCategoryText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

function notesCategoriesOpen() {
	$('#notes').removeClass('edit_open').addClass('categories_open');
	$('#notes_categories_status').text('');
	$('#notes_categories_new').val('');
	setTimeout(function() { $('#notes_categories_new').focus(); }, 0);
}

// Back and Save both end on the list. Reloading is what makes Back a discard:
// once the screen is closed the reload rewrites it from the server, so an edited
// or removed row cannot survive as a phantom.
function notesCategoriesClose() {
	$('#notes').removeClass('categories_open');
	notesReload();
}

// The server pushes this after a category save, so every other local tab redraws
// its chips, pickers and category screen from the new list.
function notesCategoriesReload() {
	notesReload();
}

function notesCategoriesRow(label, code, def) {
	var row = $('<div>').addClass('notes_category_row').attr('data-code', code || '').attr('data-default', def || '');
	$('<input>').addClass('notes_category_name').attr({ type: 'text', maxlength: '40' }).val(label || '').appendTo(row);
	$('<button>').addClass('notes_category_remove').attr({ type: 'button', title: notesCategoryText('Delete') }).text('X').appendTo(row);
	return row;
}

function notesCategoriesAdd() {
	var input = $('#notes_categories_new');
	var label = $.trim(input.val() || '');
	if (!label) { input.focus(); return; }
	var duplicate = false;
	$('#notes_categories_list .notes_category_name').each(function() {
		if ($.trim($(this).val()).toLowerCase() == label.toLowerCase()) { duplicate = true; }
	});
	if (duplicate) {
		$('#notes_categories_status').text(notesCategoryText('That category already exists.'));
		return;
	}
	$('#notes_categories_list').append(notesCategoriesRow(label, '', ''));
	input.val('');
	$('#notes_categories_status').text('');
	input.focus();
}

function notesCategoriesSave() {
	var list = [];
	var bad = null;
	$('#notes_categories_list .notes_category_row').each(function() {
		var row = $(this);
		var input = row.find('.notes_category_name');
		var code = row.attr('data-code') || '';
		var def = row.attr('data-default') || '';
		var label = $.trim(input.val() || '');
		if (!label) {
			// Clearing a shipped category's name restores its translated default;
			// a custom category has no default to fall back to.
			if (code && def) { list.push({ code: code, label: '' }); return; }
			bad = input;
			return false;
		}
		// An untouched shipped label is sent as no override, so it keeps its
		// translated core string instead of freezing today's language in the list.
		list.push({ code: code, label: (def && label == def) ? '' : label });
	});
	if (bad) { bad.focus(); return; }
	$('#notes_categories_status').text('');
	$.ajax({
		url: '/manager/notes_categories',
		type: 'POST',
		data: { categories: JSON.stringify(list), timestamp: Date.now() },
		success: function(response) {
			if (!response || !response.ok) {
				$('#notes_categories_status').text((response && response.error) ? response.error : notesCategoryText('The category list could not be saved.'));
				return;
			}
			// A filter on a category that was just deleted would hide every row.
			if (notesCategoryFilter && notesCategoryFilter != 'uncategorized') {
				var kept = false;
				for (var i = 0; i < (response.categories || []).length; i++) {
					if (response.categories[i].code == notesCategoryFilter) { kept = true; }
				}
				if (!kept) { notesCategoryFilter = ''; }
			}
			$('#notes').removeClass('categories_open');
			notesReload();
		},
		error: function() {
			$('#notes_categories_status').text(notesCategoryText('The category list could not be saved.'));
		}
	});
}

$(document).on('click', '#notes_categories_manage', function() { notesCategoriesOpen(); });
$(document).on('click', '#notes_categories_back', function() { notesCategoriesClose(); });
$(document).on('click', '#notes_categories_save', function() { notesCategoriesSave(); });
$(document).on('click', '#notes_categories_add_button', function() { notesCategoriesAdd(); });
$(document).on('keydown', '#notes_categories_new', function(e) {
	if (e.key == 'Enter') {
		e.preventDefault();
		notesCategoriesAdd();
	}
});
$(document).on('click', '.notes_category_remove', function() {
	$(this).closest('.notes_category_row').remove();
});
