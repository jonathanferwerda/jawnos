// The Controller app: the roster, adding a controller, confirming its code,
// and then the selected controller's storage and ROMs. The page itself is
// drawn by GET /manager/controllers; the roster, the two pairing calls, the
// storage setting and the ROM copy all answer JSON. The posts go through
// $.ajax like the other apps' posts, so jQuery's X-Requested-With header
// satisfies the manager's CSRF check without a bespoke fetch wrapper.
//
// The selection is page-local: a controller's uuid is kept in one variable
// and the two lower sections redraw from it. Nothing outside this page needs
// to know which controller is being looked at.
$(document).on('click', '#controllers_toggle', function() {
	controllerOpener();
});

function controllerOpener() {
	$.ajax({
		url: '/manager/controllers',
		type: 'GET',
		data: { timestamp: Date.now() },
		success: function(response) {
			// The route may hand back the window itself or a { window: ... } /
			// { html: ... } envelope, depending on how it wrapped the page.
			var html = (response && (response.window || response.html)) || response;
			if (html) { windowMaker(html); }
			controllerRosterLoad();
		},
		error: function() {
			jawnosAlertText(controllerT('The Controller could not be opened.'));
		}
	});
}

// The house's translation helper, with a fallback so a page that loads before
// translate.js still shows its words. Extra arguments fill the engine's {0},
// {1} placeholders; the fallback fills them the same way.
function controllerT(text) {
	if (typeof jawnosT === 'function') { return jawnosT.apply(null, arguments); }
	var said = text;
	for (var i = 1; i < arguments.length; i++) {
		said = said.split('{' + (i - 1) + '}').join(arguments[i]);
	}
	return said;
}

function controllerStatus(id, text, bad) {
	var el = $('#' + id);
	if (!el.length) { return; }
	el.text(text || '');
	el.toggleClass('controller_error', !!bad);
}

// ---- roster ----------------------------------------------------------------
function controllerRosterLoad() {
	var roster = $('#controller_roster');
	if (!roster.length) { return; }
	$.ajax({
		url: '/manager/controllers/list',
		type: 'GET',
		data: { timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			controllerRosterDraw((response && response.controllers) || []);
		},
		error: function() {
			roster.empty().append($('<div class="controller_empty"></div>')
				.text(controllerT('The controllers could not be read.')));
		}
	});
}

// A controller's last_seen is a moment when the server sends one and a word or
// nothing otherwise, so a number is read as epoch seconds or milliseconds and
// anything else is shown as it came.
function controllerSeenText(value) {
	if (value === undefined || value === null || value === '') { return controllerT('Never seen'); }
	var said = String(value);
	var n = Number(said);
	if (said.replace(/^\s+|\s+$/g, '') !== '' && !isNaN(n) && isFinite(n)) {
		var d = new Date(n < 1e12 ? n * 1000 : n);
		if (!isNaN(d.getTime())) { return d.toLocaleString(); }
	}
	return said;
}

// The selected controller is a page-local pair: its uuid is what the routes
// want and its name is only for the line above the sections.
var controllerSelection = null;
var controllerRosterData = [];

function controllerRosterDraw(list) {
	var roster = $('#controller_roster');
	roster.empty();
	controllerRosterData = list || [];
	if (!controllerRosterData.length) {
		roster.append($('<div class="controller_empty"></div>').text(controllerT('No controllers yet.')));
		if (controllerSelection) { controllerSelection = null; }
		controllerSelectionApply();
		controllerSectionsRender();
		return;
	}
	var still_there = false;
	for (var i = 0; i < controllerRosterData.length; i++) {
		var c = controllerRosterData[i] || {};
		var selected = !!(controllerSelection && c.uuid && controllerSelection.uuid === c.uuid);
		if (selected) { still_there = true; }
		var row = $('<div class="controller_row"></div>');
		if (selected) { row.addClass('controller_row_selected'); }
		row.append($('<span class="controller_name"></span>').text(c.name || controllerT('Unnamed controller')));
		var where = [];
		if (c.hostname) { where.push(c.hostname); }
		if (c.ip && c.ip !== c.hostname) { where.push(c.ip); }
		row.append($('<span class="controller_where"></span>').text(where.join(' · ')));
		if (c.pending) {
			row.append($('<span class="controller_badge"></span>').text(controllerT('Pending')));
		}
		if (c.uuid) {
			var select = $('<button type="button" class="controller_select"></button>')
				.text(selected ? controllerT('Selected') : controllerT('Select'))
				.attr('aria-pressed', selected ? 'true' : 'false')
				.attr('aria-label', controllerT('Select {0}', c.name || controllerT('Unnamed controller')))
				.data('uuid', c.uuid)
				.data('name', c.name || '');
			if (selected) { select.addClass('controller_select_on'); }
			row.append(select);
		}
		row.append($('<span class="controller_seen"></span>').text(controllerSeenText(c.last_seen)));
		roster.append(row);
	}
	// A controller that left the roster cannot stay selected: its storage and
	// ROMs would no longer have a uuid the routes accept.
	if (controllerSelection && !still_there) { controllerSelection = null; }
	controllerSelectionApply();
	controllerSectionsRender();
}

$(document).on('click', '.controller_select', function() {
	var button = $(this);
	var uuid = button.data('uuid') || '';
	if (!uuid) { return; }
	controllerSelection = { uuid: uuid, name: button.data('name') || '' };
	controllerRosterDraw(controllerRosterData);
});

function controllerSelectionApply() {
	var note = $('#controllers_selected');
	if (!note.length) { return; }
	note.text((controllerSelection && controllerSelection.uuid)
		? controllerT('Selected controller: {0}', controllerSelection.name || controllerT('Unnamed controller'))
		: controllerT('Select a controller above to set its storage and copy its ROMs.'));
	$('#controllers_refresh_button').prop('disabled', !(controllerSelection && controllerSelection.uuid));
}

// ---- storage ---------------------------------------------------------------
// The eight folders the house keeps on a controller's card. The route may
// send their paths and presence; these names keep the grid complete even when
// it sends only the folders it could see.
var controllerFolderNames = ['Documents', 'Downloads', 'Recordings', 'Games', 'Scans', 'Pictures', 'Videos', 'Music'];

function controllerBool(value) {
	if (value === undefined || value === null) { return false; }
	if (typeof value === 'boolean') { return value; }
	if (typeof value === 'number') { return value !== 0; }
	var said = String(value).toLowerCase();
	return (said === '1' || said === 'true' || said === 'yes' || said === 'present');
}

// `present` answers as a map by folder name, a list of names, or a single
// flag for the whole card; a folder row may also carry its own. Anything else
// is unknown rather than a false "missing".
function controllerFolderPresent(name, folder, data) {
	if (folder && folder.present !== undefined && folder.present !== null) {
		return controllerBool(folder.present);
	}
	var present = data ? data.present : undefined;
	if (present && typeof present === 'object') {
		if (present.length !== undefined) {
			for (var i = 0; i < present.length; i++) {
				if (String(present[i]) === name) { return true; }
			}
			return false;
		}
		var key = null;
		for (var k in present) {
			if (Object.prototype.hasOwnProperty.call(present, k) && k.toLowerCase() === name.toLowerCase()) { key = k; break; }
		}
		if (key !== null) { return controllerBool(present[key]); }
	}
	if (typeof present === 'boolean') { return present; }
	return null;
}

function controllerSectionsRender() {
	controllerSelectionApply();
	controllerStorageLoad();
	controllerRomsLoad();
}

$(document).on('click', '#controllers_refresh_button', function() {
	controllerStatus('controllers_roms_status', '', false);
	controllerStorageLoad();
	controllerRomsLoad();
});

function controllerStoragePrompt() {
	var box = $('#controllers_storage');
	if (!box.length) { return; }
	box.empty().append($('<div class="controller_empty"></div>').text(controllerT('Select a controller above to set its storage.')));
}

function controllerStorageLoad(notice) {
	var box = $('#controllers_storage');
	if (!box.length) { return; }
	if (!controllerSelection || !controllerSelection.uuid) {
		controllerStoragePrompt();
		return;
	}
	var uuid = controllerSelection.uuid;
	box.empty().append($('<div class="controller_empty"></div>').text(controllerT('Reading the storage...')));
	$.ajax({
		url: '/manager/controllers/storage',
		type: 'GET',
		data: { uuid: uuid, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!controllerSelection || controllerSelection.uuid !== uuid) { return; }
			if (!response || !response.ok) {
				controllerStorageError((response && response.error) ? String(response.error) : controllerT('The storage could not be read.'));
				return;
			}
			controllerStorageDraw(response);
			if (notice) { controllerStatus('controllers_storage_status', notice, false); }
		},
		error: function() {
			if (!controllerSelection || controllerSelection.uuid !== uuid) { return; }
			controllerStorageError(controllerT('The storage could not be read.'));
		}
	});
}

function controllerStorageError(text) {
	var box = $('#controllers_storage');
	if (!box.length) { return; }
	box.empty().append($('<div class="controller_status controller_error"></div>').text(text));
}

function controllerStorageDraw(data) {
	var box = $('#controllers_storage').empty();

	var field = $('<div class="controller_field"></div>');
	field.append($('<label class="controller_field_label" for="controllers_archive_dir"></label>').text(controllerT('Archive folder')));
	field.append($('<input type="text" id="controllers_archive_dir">')
		.val(data.archive_dir || '')
		.attr('placeholder', controllerT('Blank - nothing is merged')));
	box.append(field);

	var actions = $('<div class="controller_field"></div>');
	var archive = $('<label class="controller_check"></label>');
	archive.append($('<input type="checkbox" id="controllers_archive_flag">').prop('checked', controllerBool(data.archive)));
	archive.append($('<span></span>').text(controllerT('Merge this card into the archive')));
	actions.append(archive);
	actions.append($('<button type="button" id="controllers_storage_save"></button>').text(controllerT('Save')));
	actions.append($('<div id="controllers_storage_status" class="controller_status" aria-live="polite"></div>'));
	box.append(actions);

	box.append($('<div class="controller_group_title"></div>').text(controllerT('Folders')));
	var known = {};
	var given = (data.folders || []);
	for (var i = 0; i < given.length; i++) {
		var folder = given[i] || {};
		if (folder.name) { known[String(folder.name).toLowerCase()] = folder; }
	}
	var grid = $('<div class="controller_folders"></div>');
	for (var j = 0; j < controllerFolderNames.length; j++) {
		var name = controllerFolderNames[j];
		var row = known[name.toLowerCase()];
		var present = controllerFolderPresent(name, row, data);
		var item = $('<div class="controller_folder"></div>');
		if (present === true) { item.addClass('controller_folder_present'); }
		if (present === false) { item.addClass('controller_folder_missing'); }
		if (row && row.path) { item.attr('title', row.path); }
		item.append($('<span class="controller_folder_name"></span>').text(controllerT(name)));
		item.append($('<span class="controller_folder_state"></span>').text(
			present === null ? controllerT('Unknown') : (present ? controllerT('Present') : controllerT('Missing'))));
		grid.append(item);
	}
	box.append(grid);
}

$(document).on('click', '#controllers_storage_save', function() {
	controllerStorageSave();
});

$(document).on('keydown', '#controllers_archive_dir', function(e) {
	if (e.key == 'Enter') { e.preventDefault(); controllerStorageSave(); }
});

function controllerStorageSave() {
	if (!controllerSelection || !controllerSelection.uuid) { return; }
	var input = $('#controllers_archive_dir');
	if (!input.length) { return; }
	var dir = (input.val() || '').replace(/^\s+|\s+$/g, '');
	var archive = $('#controllers_archive_flag').prop('checked') ? 1 : 0;
	var button = $('#controllers_storage_save').prop('disabled', true);
	controllerStatus('controllers_storage_status', controllerT('Saving...'), false);
	$.ajax({
		url: '/manager/controllers/storage',
		type: 'POST',
		data: { uuid: controllerSelection.uuid, archive_dir: dir, archive: archive, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				controllerStatus('controllers_storage_status', (response && response.error) ? String(response.error) : controllerT('The storage setting was not saved.'), true);
				return;
			}
			controllerStorageLoad(controllerT('Saved.'));
		},
		error: function() {
			button.prop('disabled', false);
			controllerStatus('controllers_storage_status', controllerT('The storage setting was not saved.'), true);
		}
	});
}

// ---- ROMs ------------------------------------------------------------------
var controllerRomSides = { emmc: 'eMMC', sd: 'SD' };

function controllerRomsPrompt() {
	var box = $('#controllers_roms');
	if (!box.length) { return; }
	box.empty().append($('<div class="controller_empty"></div>').text(controllerT('Select a controller above to see its ROMs.')));
	controllerStatus('controllers_roms_status', '', false);
}

function controllerRomsLoad() {
	var box = $('#controllers_roms');
	if (!box.length) { return; }
	if (!controllerSelection || !controllerSelection.uuid) {
		controllerRomsPrompt();
		return;
	}
	controllerRomsFrame();
	controllerRomsColumnLoad('emmc');
	controllerRomsColumnLoad('sd');
}

function controllerRomsFrame() {
	var box = $('#controllers_roms');
	if (box.find('.controller_roms_col').length === 2) { return; }
	box.empty();
	var order = ['emmc', 'sd'];
	for (var i = 0; i < order.length; i++) {
		var where = order[i];
		var column = $('<section class="controller_roms_col"></section>').attr('data-where', where);
		column.append($('<h3 class="controller_roms_title"></h3>').text(controllerT(controllerRomSides[where])));
		column.append($('<div class="controller_roms_list"></div>')
			.append($('<div class="controller_empty"></div>').text(controllerT('Reading the ROMs...'))));
		box.append(column);
	}
}

function controllerRomsColumn(where) {
	return $('#controllers_roms .controller_roms_col').filter(function() {
		return $(this).attr('data-where') === where;
	}).find('.controller_roms_list');
}

function controllerRomsColumnLoad(where) {
	if (!controllerSelection || !controllerSelection.uuid) { return; }
	var uuid = controllerSelection.uuid;
	var list = controllerRomsColumn(where);
	if (!list.length) { return; }
	list.empty().append($('<div class="controller_empty"></div>').text(controllerT('Reading the ROMs...')));
	$.ajax({
		url: '/manager/controllers/roms',
		type: 'GET',
		data: { uuid: uuid, where: where, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!controllerSelection || controllerSelection.uuid !== uuid) { return; }
			if (!response || !response.ok) {
				list.empty().append($('<div class="controller_status controller_error"></div>')
					.text((response && response.error) ? String(response.error) : controllerT('The ROMs could not be read.')));
				return;
			}
			controllerRomsDraw(where, list, response);
		},
		error: function() {
			if (!controllerSelection || controllerSelection.uuid !== uuid) { return; }
			list.empty().append($('<div class="controller_status controller_error"></div>').text(controllerT('The ROMs could not be read.')));
		}
	});
}

function controllerSizeText(value) {
	if (value === undefined || value === null || value === '') { return ''; }
	var bytes = Number(value);
	if (!isFinite(bytes) || bytes < 0) { return String(value); }
	if (bytes >= 1073741824) { return (bytes / 1073741824).toFixed(1) + ' GB'; }
	if (bytes >= 1048576) { return Math.round(bytes / 1048576) + ' MB'; }
	if (bytes >= 1024) { return Math.round(bytes / 1024) + ' KB'; }
	return bytes + ' B';
}

function controllerRomsDraw(where, list, data) {
	var items = (data && data.items) || [];
	list.empty();
	if (!items.length) {
		list.append($('<div class="controller_empty"></div>').text(controllerT('No ROMs here.')));
		return;
	}
	var to = (where === 'emmc') ? 'sd' : 'emmc';
	var to_label = controllerT(controllerRomSides[to]);
	for (var i = 0; i < items.length; i++) {
		var item = items[i] || {};
		var title = item.game || item.name || '';
		var row = $('<div class="controller_rom_row"></div>');
		var name = $('<span class="controller_rom_name"></span>').text(title || controllerT('Unnamed ROM'));
		if (item.name && item.name !== title) { name.attr('title', item.name); }
		row.append(name);
		row.append($('<span class="controller_rom_size"></span>').text(controllerSizeText(item.size)));
		var copy = $('<button type="button" class="controller_rom_copy"></button>').text(controllerT('Copy'));
		var said = controllerT('Copy {0} to {1}', title || controllerT('this ROM'), to_label);
		copy.attr('aria-label', said).attr('title', said);
		copy.data('name', item.name || '');
		copy.data('from', where);
		copy.data('to', to);
		if (!item.name) { copy.prop('disabled', true); }
		row.append(copy);
		list.append(row);
	}
}

$(document).on('click', '.controller_rom_copy', function() {
	controllerRomCopy($(this));
});

function controllerRomCopy(button) {
	if (!controllerSelection || !controllerSelection.uuid) { return; }
	var name = button.data('name') || '';
	var from = button.data('from') || '';
	var to = button.data('to') || '';
	if (!name || !from || !to) { return; }
	button.prop('disabled', true);
	controllerStatus('controllers_roms_status', controllerT('Copying {0}...', name), false);
	$.ajax({
		url: '/manager/controllers/roms/copy',
		type: 'POST',
		data: { uuid: controllerSelection.uuid, name: name, from: from, to: to, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			if (!response || !response.ok) {
				button.prop('disabled', false);
				controllerStatus('controllers_roms_status', (response && response.error) ? String(response.error) : controllerT('The ROM was not copied.'), true);
				return;
			}
			controllerStatus('controllers_roms_status', controllerT('Copied {0} to {1}.', name, controllerT(controllerRomSides[to])), false);
			controllerRomsColumnLoad(from);
			controllerRomsColumnLoad(to);
		},
		error: function() {
			button.prop('disabled', false);
			controllerStatus('controllers_roms_status', controllerT('The ROM was not copied.'), true);
		}
	});
}

// ---- adding a controller ---------------------------------------------------
$(document).on('click', '#controller_add_button', function() {
	controllerRequest();
});

$(document).on('keydown', '#controller_name', function(e) {
	if (e.key == 'Enter') { e.preventDefault(); controllerRequest(); }
});

function controllerRequest() {
	var name = ($('#controller_name').val() || '').replace(/^\s+|\s+$/g, '');
	if (!name) {
		controllerStatus('controller_add_status', controllerT('Type the controller\'s name first.'), true);
		$('#controller_name').focus();
		return;
	}
	var button = $('#controller_add_button');
	button.prop('disabled', true);
	controllerStatus('controller_add_status', controllerT('Adding...'), false);
	$.ajax({
		url: '/manager/controllers/request',
		type: 'POST',
		data: { name: name, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				controllerStatus('controller_add_status', (response && response.error) || controllerT('The controller could not be added.'), true);
				return;
			}
			controllerStatus('controller_add_status', controllerT('Added. Confirm the code below.'), false);
			if (response.code) {
				$('#controller_code').text(response.code).prop('hidden', false);
				$('#controller_code_note').prop('hidden', false);
			}
			controllerRosterLoad();
		},
		error: function() {
			button.prop('disabled', false);
			controllerStatus('controller_add_status', controllerT('The controller could not be added.'), true);
		}
	});
}

// ---- approving a code ------------------------------------------------------
$(document).on('click', '#controllers_approve_button', function() {
	controllerApprove();
});

$(document).on('keydown', '#controllers_approve_code', function(e) {
	if (e.key == 'Enter') { e.preventDefault(); controllerApprove(); }
});

function controllerApprove() {
	var code = ($('#controllers_approve_code').val() || '').replace(/^\s+|\s+$/g, '');
	if (!code) {
		controllerStatus('controllers_approve_status', controllerT('Type the code first.'), true);
		$('#controllers_approve_code').focus();
		return;
	}
	var button = $('#controllers_approve_button');
	button.prop('disabled', true);
	controllerStatus('controllers_approve_status', controllerT('Approving...'), false);
	$.ajax({
		url: '/manager/controllers/approve',
		type: 'POST',
		data: { code: code, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				controllerStatus('controllers_approve_status', (response && response.error) || controllerT('The code was not approved.'), true);
				return;
			}
			$('#controllers_approve_code').val('');
			$('#controller_code').text('').prop('hidden', true);
			$('#controller_code_note').prop('hidden', true);
			controllerStatus('controllers_approve_status', controllerT('Approved.'), false);
			controllerRosterLoad();
		},
		error: function() {
			button.prop('disabled', false);
			controllerStatus('controllers_approve_status', controllerT('The code was not approved.'), true);
		}
	});
}
