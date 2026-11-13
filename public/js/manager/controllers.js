// The Controller app: the roster, adding a controller, confirming its code,
// flashing a blank board, and then the selected controller's storage and ROMs.
// The page itself is drawn by GET /manager/controllers; the roster, the two
// pairing calls, the flash calls, the storage setting and the ROM copy all
// answer JSON. The posts go through $.ajax like the other apps' posts, so
// jQuery's X-Requested-With header satisfies the manager's CSRF check without
// a bespoke fetch wrapper.
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
			controllerNewAvailability(response && response.computer);
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

// The last storage answer, so the walkthrough can redraw from it when it is
// opened or toggled; null means no controller is selected.
var controllerStorageAnswer = null;
var controllerWalkthroughOpen = false;

function controllerStoragePrompt() {
	var box = $('#controllers_storage');
	if (!box.length) { return; }
	box.empty().append($('<div class="controller_empty"></div>').text(controllerT('Select a controller above to set its storage.')));
	controllerStorageAnswer = null;
	controllerWalkthroughDraw(null);
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
	controllerStorageAnswer = data;
	var box = $('#controllers_storage').empty();

	// The card the controller found is the first thing the section says: it may
	// be holding a decision nobody has made yet.
	var card = controllerCardDraw(data);
	if (card) { box.append(card); }

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
	controllerWalkthroughDraw(data);
}

// ---- the card the controller found -----------------------------------------
// The board reports what its slot held on its first boot, and the person's
// answer here is applied the next time the board starts. A card that already
// holds the archive needs no choice, and a card with another filesystem is
// never formatted by this page without being asked twice.
var controllerCardStates = {
	archive: 'A card is ready and holds the archive.',
	foreign: 'The card holds another filesystem. Adopt it as it is, or format it.',
	blank: 'The card has no filesystem. It can only be formatted.',
	none: 'No card is in the slot.'
};

function controllerCardDraw(data) {
	var card = data && data.card;
	if (!card || !card.state) { return null; }
	var box = $('<div class="controller_card_finding"></div>');
	box.append($('<div class="controller_group_title"></div>').text(controllerT('Card')));
	box.append($('<div class="controller_new_state"></div>').text(controllerT(controllerCardStates[card.state] || 'The card could not be read.')));
	var details = [];
	if (card.fstype) { details.push(String(card.fstype)); }
	var size = Number(card.size);
	if (isFinite(size) && size > 0) { details.push((size / 1073741824).toFixed(1) + ' GB'); }
	if (card.label) { details.push(String(card.label)); }
	if (card.archive_dir) { details.push(String(card.archive_dir)); }
	if (details.length) {
		box.append($('<div class="controller_new_detail"></div>').text(details.join(' \u00b7 ')));
	}
	var buttons = $('<div class="controller_new_actions"></div>');
	if (card.state === 'foreign') {
		buttons.append($('<button type="button" class="controller_card_choice" data-choice="adopt"></button>').text(controllerT('Adopt the card')));
	}
	if (card.state === 'foreign' || card.state === 'blank') {
		buttons.append($('<button type="button" class="controller_card_choice" data-choice="format"></button>').text(controllerT('Format the card')));
	}
	if (buttons.children().length) { box.append(buttons); }
	if (card.choice) {
		box.append($('<div class="controller_note controller_card_pending"></div>')
			.text(controllerT('{0} is set. The controller applies it the next time it starts.', controllerT(card.choice === 'format' ? 'Format' : 'Adopt'))));
	}
	box.append($('<div id="controllers_card_status" class="controller_status" aria-live="polite"></div>'));
	return box;
}

$(document).on('click', '.controller_card_choice', function() {
	var button = $(this);
	var choice = button.attr('data-choice') || '';
	if (choice !== 'adopt' && choice !== 'format') { return; }
	if (choice === 'format') {
		jawnosConfirm(controllerT('Format the card in this controller? Everything on it is erased.'), function() {
			controllerCardChoose(choice, button);
		});
		return;
	}
	controllerCardChoose(choice, button);
});

function controllerCardChoose(choice, button) {
	if (!controllerSelection || !controllerSelection.uuid) { return; }
	button.prop('disabled', true);
	controllerStatus('controllers_card_status', controllerT(choice === 'format' ? 'Formatting...' : 'Adopting...'), false);
	$.ajax({
		url: '/manager/controllers/card',
		type: 'POST',
		data: { uuid: controllerSelection.uuid, choice: choice, timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				controllerStatus('controllers_card_status', (response && response.error) ? String(response.error) : controllerT('The choice was not saved.'), true);
				return;
			}
			// No redraw: the answer is not the board's state until it starts again,
			// and a redraw would drop the sentence that says so.
			$('#controllers_storage .controller_card_choice').prop('disabled', true);
			controllerStatus('controllers_card_status', controllerT('Saved. The controller applies it the next time it starts.'), false);
		},
		error: function() {
			button.prop('disabled', false);
			controllerStatus('controllers_card_status', controllerT('The choice was not saved.'), true);
		}
	});
}

// ---- setting up the card ---------------------------------------------------
// A walkthrough over the Storage card rather than a second form: every step is
// read from the same answer Save produces, and its button presses the control
// the step names, so the two cannot drift. Open or closed is page-local state,
// like the controller selection.
$(document).on('click', '#controllers_walkthrough_button', function() {
	controllerWalkthroughOpen = !controllerWalkthroughOpen;
	controllerWalkthroughDraw(controllerStorageAnswer);
});

$(document).on('click', '.controller_walkthrough_act', function() {
	var act = $(this).attr('data-act') || '';
	if (act === 'folder') { $('#controllers_archive_dir').focus(); }
	else if (act === 'save') { controllerStorageSave(); }
	else if (act === 'roms') {
		var roms = $('#controllers_roms');
		if (roms.length) { roms[0].scrollIntoView({ block: 'start' }); }
	}
});

// The steps in the order the person does them. A folder the route could not stat
// (a peer's card, or no folder named yet) is unknown, and unknown is not done.
function controllerWalkthroughSteps(data) {
	var dir = (data && data.archive_dir) || '';
	var card = !!(data && controllerBool(data.present));
	var made = 0;
	var games = false;
	var given = (data && data.folders) || [];
	for (var i = 0; i < given.length; i++) {
		var row = given[i] || {};
		if (controllerFolderPresent(row.name, row, data) === true) {
			made++;
			if (row.name === 'Games') { games = true; }
		}
	}
	return [
		{
			text: controllerT('Put the controller\'s card in this computer and mount it. The house can only read the card while it is mounted.'),
			done: card
		},
		{
			text: controllerT('Type the folder the card is mounted at.'),
			done: dir.length > 0,
			act: 'folder',
			action: controllerT('Type the folder')
		},
		{
			text: controllerT('Press Save. The house makes the eight folders on the card.'),
			done: made >= controllerFolderNames.length,
			act: 'save',
			action: controllerT('Save')
		},
		{
			text: controllerT('Games go in Games. The ROMs section below copies them between the two cards.'),
			done: games,
			act: 'roms',
			action: controllerT('Show the ROMs')
		}
	];
}

function controllerWalkthroughDraw(data) {
	var box = $('#controllers_walkthrough');
	if (!box.length) { return; }
	$('#controllers_walkthrough_button').attr('aria-expanded', controllerWalkthroughOpen ? 'true' : 'false');
	if (!controllerWalkthroughOpen) { box.empty().prop('hidden', true); return; }
	box.empty().prop('hidden', false);
	if (!controllerSelection || !controllerSelection.uuid) {
		box.append($('<div class="controller_empty"></div>').text(controllerT('Select a controller above first.')));
		return;
	}
	var steps = controllerWalkthroughSteps(data);
	var list = $('<ol class="controller_walkthrough"></ol>');
	var next = true;
	for (var i = 0; i < steps.length; i++) {
		var step = steps[i];
		var item = $('<li class="controller_walkthrough_step"></li>');
		if (step.done) { item.addClass('is-done'); }
		else if (next) { item.addClass('is-next'); next = false; }
		else { item.addClass('is-todo'); }
		item.append($('<span class="controller_walkthrough_text"></span>').text(step.text));
		if (step.act && !step.done) {
			item.append($('<button type="button" class="controller_walkthrough_act"></button>')
				.attr('data-act', step.act).text(step.action));
		}
		list.append(item);
	}
	box.append(list);
	box.append($('<p class="controller_note"></p>').text(controllerT('A blank folder merges nothing: the card has to be mounted for merging to work.')));
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

// ---- a new controller ------------------------------------------------------
// "New controller" writes the house image to a blank board over USB. Only the
// computer that can reach a board may offer it, so the roster's list route says
// `computer` and the section is not drawn at all anywhere else.
var controllerComputer = false;

// The board's own recovery steps, kept verbatim: they are what the person does
// with their hands, so the words are not paraphrased.
var controllerNewSteps = [
	'Power off completely (hold power 7-8 s) until every rear LED is dark.',
	'Connect the USB-C cable to this computer.',
	'Press and hold the recovery button on the back.',
	'Press power, wait 1-2 s, then release the recovery button when the Hardkernel logo appears.',
	'Wait for the red LED to blink like a heartbeat with the blue LED solid.'
];

$(document).on('click', '#controllers_new_button', function() {
	controllerNewScan();
});

$(document).on('click', '.controllers_new_scan', function() {
	controllerNewScan();
});

$(document).on('click', '.controllers_new_flash', function() {
	controllerNewFlash();
});

function controllerNewAvailability(on) {
	var section = $('#controllers_new_section');
	if (!section.length) { return; }
	controllerComputer = controllerBool(on);
	if (controllerComputer) {
		section.prop('hidden', false);
		return;
	}
	// Off this computer the section renders nothing, and a panel left over from
	// an answer that once said `computer` cannot reappear when it flips back.
	section.prop('hidden', true);
	controllerNewReset();
}

function controllerNewReset() {
	$('#controllers_new_panel').empty().prop('hidden', true);
	controllerStatus('controllers_new_status', '', false);
	$('#controllers_new_button').prop('disabled', false);
	controllerNewNetworkLocked(false);
}

// The panel is the state: each answer empties it and draws exactly one state.
function controllerNewPanel() {
	var box = $('#controllers_new_panel');
	if (!box.length) { return $(); }
	return box.empty().prop('hidden', false);
}

function controllerNewScanButton() {
	return $('<button type="button" class="controllers_new_scan"></button>').text(controllerT('Scan'));
}

// One scan, no polling: count >= 1 is a board to flash, count 0 is the person's
// hands on the board, and anything the route refuses is its own words.
function controllerNewScan() {
	if (!controllerComputer) { return; }
	var button = $('#controllers_new_button').prop('disabled', true);
	controllerStatus('controllers_new_status', controllerT('Scanning for a board...'), false);
	controllerNewPanel().append($('<div class="controller_new_state"></div>').text(controllerT('Scanning for a board...')));
	$.ajax({
		url: '/manager/controllers/new/scan',
		type: 'POST',
		data: { timestamp: Date.now() },
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			if (!response || !response.ok) {
				controllerNewFailure((response && response.error) ? String(response.error) : controllerT('The board could not be found.'));
				return;
			}
			var devices = response.devices || [];
			if (Number(response.count) >= 1 && devices.length) {
				controllerNewConfirm(devices);
			} else {
				controllerNewRecovery();
			}
		},
		error: function() {
			button.prop('disabled', false);
			controllerNewFailure(controllerT('The board could not be found.'));
		}
	});
}

// A board's size arrives as 512-byte sectors, so a number here is a sector count
// and never an already-formatted byte size.
function controllerNewSizeGb(sectors) {
	var n = Number(sectors);
	if (!isFinite(n) || n <= 0) { return ''; }
	return (n * 512 / 1073741824).toFixed(1);
}

function controllerNewConfirm(devices) {
	var panel = controllerNewPanel();
	if (!panel.length) { return; }
	panel.append($('<div class="controller_new_state"></div>').text(controllerT('Board found. Flashing writes the house image to it.')));
	var list = $('<div class="controller_new_devices"></div>');
	for (var i = 0; i < devices.length; i++) {
		var device = devices[i] || {};
		var row = $('<div class="controller_new_device"></div>');
		row.append($('<span class="controller_new_dev"></span>').text(device.dev || controllerT('Unknown device')));
		var size = controllerNewSizeGb(device.size_sectors);
		if (size) { row.append($('<span class="controller_new_size"></span>').text(controllerT('{0} GB', size))); }
		if (device.model) { row.append($('<span class="controller_new_model"></span>').text(String(device.model))); }
		list.append(row);
	}
	panel.append(list);
	panel.append($('<div class="controller_new_actions"></div>').append(
	$('<button type="button" class="controllers_new_flash"></button>').text(controllerT('Flash'))));
}

function controllerNewRecovery() {
	var panel = controllerNewPanel();
	if (!panel.length) { return; }
	panel.append($('<div class="controller_new_state"></div>').text(controllerT('No board is in recovery mode. Put it there, then scan again.')));
	var steps = $('<ol class="controller_new_steps"></ol>');
	for (var i = 0; i < controllerNewSteps.length; i++) {
		steps.append($('<li></li>').text(controllerT(controllerNewSteps[i])));
	}
	panel.append(steps);
	panel.append($('<div class="controller_new_actions"></div>').append(controllerNewScanButton()));
}

// The route's own words, verbatim: a refusal names the device it refused and
// rewriting it here would lose that.
function controllerNewFailure(text) {
	controllerStatus('controllers_new_status', '', false);
	var panel = controllerNewPanel();
	if (!panel.length) { return; }
	panel.append($('<div class="controller_status controller_error"></div>').text(text));
	panel.append($('<div class="controller_new_actions"></div>').append(controllerNewScanButton()));
}

// The board's network, read once for a flash. The provisioner refuses the same
// shapes; saying it here keeps a typo off a 900-second press.
function controllerNewNetwork() {
	var ssid = ($('#controllers_wifi_ssid').val() || '').replace(/^\s+|\s+$/g, '');
	var psk = $('#controllers_wifi_psk').val() || '';
	if (!ssid && !psk) { return { ssid: '', psk: '' }; }
	if (!ssid) {
		return { error: controllerT('Type the network name, or clear the password to leave the board off the network.'), focus: '#controllers_wifi_ssid' };
	}
	if (!psk) {
		return { error: controllerT('Type the network password, or clear the network name to leave the board off the network.'), focus: '#controllers_wifi_psk' };
	}
	if (ssid.length > 32) {
		return { error: controllerT('A network name is at most 32 characters.'), focus: '#controllers_wifi_ssid' };
	}
	if (psk.length < 8 || psk.length > 63) {
		return { error: controllerT('A Wi-Fi password is 8 to 63 characters.'), focus: '#controllers_wifi_psk' };
	}
	return { ssid: ssid, psk: psk };
}

// The board's own name, read once for a flash. It is the name it answers to on
// the network and the row the house files it under, so the same rule as the
// provisioner's applies here: letters, numbers, dots and dashes, and no dot or
// dash at either end.
function controllerNewHostname() {
	var name = ($('#controllers_hostname').val() || '').replace(/^\s+|\s+$/g, '');
	if (!name) { return 'gou'; }
	if (!/^[A-Za-z0-9](?:[A-Za-z0-9.-]{0,61}[A-Za-z0-9])?$/.test(name)) {
		return { error: controllerT('A name is letters, numbers, dots and dashes, and cannot start or end with a dot or a dash.'), focus: '#controllers_hostname' };
	}
	return name;
}

// The fields are the flash's input, so they are held still while it runs and
// handed back when it answers.
function controllerNewNetworkLocked(locked) {
	$('#controllers_hostname, #controllers_wifi_ssid, #controllers_wifi_psk').prop('disabled', !!locked);
}

function controllerNewFlash() {
	if (!controllerComputer) { return; }
	// The board's name and network are written into the flashed rootfs, so they
	// are read before the press starts and refused here, not by the provisioner.
	var name = controllerNewHostname();
	if (name.error) {
		controllerStatus('controllers_new_status', name.error, true);
		$(name.focus).focus();
		return;
	}
	var network = controllerNewNetwork();
	if (network.error) {
		controllerStatus('controllers_new_status', network.error, true);
		$(network.focus || '#controllers_wifi_ssid').focus();
		return;
	}
	var panel = $('#controllers_new_panel');
	var button = $('#controllers_new_button').prop('disabled', true);
	panel.find('button').prop('disabled', true);
	controllerNewNetworkLocked(true);
	controllerStatus('controllers_new_status', controllerT('Flashing...'), false);
	// One blocking write on the other side, so a plain state rather than a
	// progress bar that would have to invent a percentage.
	panel.empty().append($('<div class="controller_new_state"></div>').text(controllerT('Flashing...')));
	$.ajax({
		url: '/manager/controllers/new/flash',
		type: 'POST',
		data: {
			timestamp: Date.now(),
			hostname: name,
			'wifi-ssid': network.ssid,
			'wifi-psk': network.psk
		},
		dataType: 'json',
		success: function(response) {
			button.prop('disabled', false);
			controllerNewNetworkLocked(false);
			if (!response || !response.ok) {
				controllerNewFailure((response && response.error) ? String(response.error) : controllerT('The board was not flashed.'));
				return;
			}
			// The password has served its purpose; a secret is not left sitting in
			// the page for the next person at the desk.
			$('#controllers_wifi_psk').val('');
			controllerNewDone(response);
			controllerStatus('controllers_new_status', controllerT('Flashed.'), false);
			// The flashed board may already be in the roster, and its card is new:
			// re-read the roster and the two sections that follow the selection.
			controllerRosterLoad();
			controllerStorageLoad();
			controllerRomsLoad();
		},
		error: function() {
			button.prop('disabled', false);
			controllerNewNetworkLocked(false);
			controllerNewFailure(controllerT('The board was not flashed.'));
		}
	});
}

function controllerNewDone(data) {
	var panel = controllerNewPanel();
	if (!panel.length) { return; }
	panel.append($('<div class="controller_new_state"></div>').text(controllerT('The board is flashed.')));
	if (data.device) {
		panel.append($('<div class="controller_new_detail"></div>').text(controllerT('Device: {0}', String(data.device))));
	}
	var bytes = (data.bytes_written === undefined || data.bytes_written === null)
	? controllerT('unknown') : String(data.bytes_written);
	panel.append($('<div class="controller_new_detail"></div>').text(controllerT('Bytes written: {0}', bytes)));
	panel.append($('<div class="controller_new_detail"></div>').text(controllerT('SHA-256 matches: {0}',
	controllerBool(data.sha256_match) ? controllerT('yes') : controllerT('no'))));
	var filled = data.autopopulated || [];
	if (filled.length) {
		panel.append($('<div class="controller_new_subtitle"></div>').text(controllerT('Filled in on the board')));
		var list = $('<ul class="controller_new_list"></ul>');
		for (var i = 0; i < filled.length; i++) {
			list.append($('<li></li>').text(controllerNewFieldName(filled[i])));
		}
		panel.append(list);
	} else {
		panel.append($('<div class="controller_new_detail"></div>').text(controllerT('Nothing was filled in on the board.')));
	}
}

// `autopopulated` names the fields the flash filled in, as bare names or as rows
// carrying one. Only the name is painted: a value could be the Wi-Fi password,
// and the screen must not show it.
var controllerNewFields = { wifi: 'Wi-Fi network', hostname: 'Name', 'join-token': 'House token' };

function controllerNewFieldName(item) {
	if (item === undefined || item === null) { return ''; }
	if (typeof item === 'string' || typeof item === 'number') {
		return controllerNewFields[String(item)] ? controllerT(controllerNewFields[String(item)]) : String(item);
	}
	var name = String(item.name || item.field || item.key || item.label || '');
	return controllerNewFields[name] ? controllerT(controllerNewFields[name]) : name;
}
