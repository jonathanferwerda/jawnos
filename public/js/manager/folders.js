// Folders - the file browser. One selection model serves both the window's
// listing and the desk behind it: a click picks one item, Ctrl/Cmd toggles one,
// Shift takes the run between the last click and this one, a drag on the empty
// background draws a marquee, and the keyboard walks, opens, renames and deletes.
// Dragging carries every selected item; a drop moves it (Ctrl/Cmd copies) into
// the folder under the pointer, the folder being looked at, or the desk.

var folders = {
	selected: [],
	clipboard: [],
	command: undefined,
	folder: undefined,
	disk: {},
	files: [],
	type: undefined,
	path: undefined,
	remote_uuid: undefined,
	anchor: undefined
};

// The desk is a second surface over the same listing and the same commands: its
// home is ~/Desktop (or ~ when the house has none), and it lives on the page
// rather than in a window.
var desk = {
	selected: [],
	clipboard: [],
	command: undefined,
	folder: undefined,
	disk: {},
	files: [],
	apps: [],
	app: undefined,
	type: undefined,
	path: undefined,
	remote_uuid: '',
	anchor: undefined
};

var folders_drag_state = undefined;
var folders_last_drag = 0;
var folders_typeahead = '';
var folders_typeahead_at = 0;
var folders_marquee = undefined;

function foldersState(surface) { return (surface == 'desk') ? desk : folders; }
function foldersContainer(surface) { return (surface == 'desk') ? $('#desk_layer') : $('#folders_contents'); }
function foldersSurfaceOf(el) { return ($(el).closest('#desk_layer').length) ? 'desk' : 'folders'; }

// A long press on a file, folder or the listing background opens its menu on touch
if (typeof jawnosContextMenuOn == 'function') { jawnosContextMenuOn('.folders_file, .folders_contents, #desk_layer'); }
$(document).on('click', '#folders_toggle', function() {
	foldersOpener();
});

// the media padlock: sealed names and a hidden app's files are not listed
// until a paired phone signs the house open. An open padlock shuts again on a
// press; a shut one asks the house to show the unlock page.
$(document).on('click', '.folders_lock', function () {
	if ($('#folders').attr('unlock')) {
		$('#folders').attr('unlock', '');
		if (typeof jawnosMediaLockApp === 'function') {
			jawnosMediaLockApp('folders', function () { foldersOpener(); });
		}
		else { foldersOpener(); }
	}
	else {
		$('#folders_mainview').hide();
		$('#folders_padlock').show();
		if (typeof padlockAskPhone === 'function') { padlockAskPhone('folders'); }
	}
});
$(document).on('click', '.folders_cancel_padlock', function () {
	$('#folders_padlock').hide();
	$('#folders_mainview').show();
});

function foldersOpener(data) {
	if (!data) { data = {}; }
	// which machine is being browsed: an explicit choice, else whatever the
	// window was rendered for, else this machine
	if (folders.remote_uuid === undefined) {
		folders.remote_uuid = $('#folders').attr('remote_uuid') || '';
	}
	var remote_uuid = (data['remote_uuid'] !== undefined) ? data['remote_uuid'] : folders.remote_uuid;
	var timestamp = Date.now();
	var previous_folder = folders.folder;
	var previous_scroll = $('#folders_contents').scrollTop() || 0;
	$.ajax({
		url: '/manager/folders',
		type: 'POST',
		data: {
			timestamp: timestamp,
			folder: data['folder'],
			command: data['command'],
			remote_uuid: remote_uuid,
			device_uuid: (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : '',
			browser_tab_id: (typeof jawnosMediaTab === 'function') ? jawnosMediaTab() : '',
			// the window's own unlock token: a fresh open has none and stays
			// locked; the refresh after a phone signs carries the one it minted
			unlock: $('#folders').attr('unlock') || ''
		},
		success:function(response) {
			var same_folder = (previous_folder !== undefined && response.fo.folder === previous_folder);
			windowMaker(response.html);
			folders['folder'] = response.fo.folder;
			folders['disk'] = response.fo.disk;
			folders['files'] = response.fo.files;
			folders['remote_uuid'] = remote_uuid;
			folders['selected'] = [];
			folders['path'] = undefined;
			folders['type'] = undefined;
			folders['anchor'] = undefined;
			$('#folders_machine_select').val(remote_uuid);
			// a remote listing is read-only, and worth saying so at a glance
			$('#folders_toolbar').attr('data-remote', remote_uuid ? 'yes' : '');
			foldersApplyView();
			foldersDraggable();
			foldersSelectionSync('folders');
			if (typeof appointment_chron == 'function') { appointment_chron(); }
			if (same_folder) { $('#folders_contents').scrollTop(previous_scroll); }
			$('#folders_contents').focus();
		}
	});
}

$(document).on('change', '#folders_machine_select', function () {
	// a new machine starts at its own home: this machine's paths mean nothing
	// over there
	foldersOpener({ remote_uuid: $(this).val(), folder: '' });
});

// ---- view ------------------------------------------------------------------
// The grid is the default; the list gives every item its type, size and date.
// The choice is remembered per screen, like the desk layout.
function foldersView() {
	return (localStorage.getItem('folders_view') == 'list') ? 'list' : 'grid';
}
function foldersApplyView() {
	var view = foldersView();
	$('#folders_contents').attr('data-view', view);
	$('#folders_mainview').attr('data-view', view);
	var toggle = $('#folders_view_toggle');
	var icon = (view == 'list') ? toggle.attr('data-icon-grid') : toggle.attr('data-icon-list');
	if (icon) { toggle.find('img').attr('src', icon); }
}
$(document).on('click', '#folders_view_toggle', function () {
	localStorage.setItem('folders_view', (foldersView() == 'list') ? 'grid' : 'list');
	foldersApplyView();
	$('#folders_contents').focus();
});

// ---- selection -------------------------------------------------------------
// Kept in the state object and mirrored onto the DOM (.selected, aria-selected).
function foldersSelectionSync(surface, activeEl) {
	var container = foldersContainer(surface);
	var st = foldersState(surface);
	var selected = [];
	container.find('.folders_file').each(function () {
		var el = $(this);
		if (el.hasClass('selected')) {
			// app shortcuts are selected visually, but they are not files: they
			// must not reach a paste, a delete or a properties read
			if (!el.hasClass('desk_app') && el.attr('path')) {
				selected.push({ path: el.attr('path'), type: el.attr('type') });
			}
		}
		el.attr('aria-selected', el.hasClass('selected') ? 'true' : 'false');
	});
	st.selected = selected;
	if (activeEl && activeEl.length) {
		st.path = activeEl.attr('path');
		st.type = activeEl.attr('type');
	}
	if (!selected.length) {
		st.path = undefined;
		st.type = undefined;
		st.anchor = undefined;
	}
	if (surface == 'folders') {
		var total = container.find('.folders_file').length;
		var word = selected.length
			? jawnosT('{0} of {1} selected', selected.length, total)
			: jawnosT('{0} items', total);
		$('#folders .folders_selected_info').text(word);
	}
	foldersApplyCut(surface);
}

function foldersApplyCut(surface) {
	var st = foldersState(surface);
	var container = foldersContainer(surface);
	var cut = {};
	if (st.command == 'cut') {
		$.each(st.clipboard || [], function (i, item) { if (item['path']) { cut[item['path']] = 1; } });
	}
	container.find('.folders_file').each(function () {
		$(this).toggleClass('folders_cut', !!cut[$(this).attr('path')]);
	});
}

function foldersClearSelection(surface) {
	var container = foldersContainer(surface);
	container.find('.folders_file').removeClass('selected');
	foldersState(surface).anchor = undefined;
	foldersSelectionSync(surface);
}

function foldersSelectOnly(surface, el) {
	var container = foldersContainer(surface);
	container.find('.folders_file').removeClass('selected');
	el.addClass('selected');
	foldersState(surface).anchor = container.find('.folders_file').index(el);
	foldersSelectionSync(surface, el);
}

$(document).on('click', '.folders_file', function(e) {
	var el = $(this);
	if (Date.now() - folders_last_drag < 300) { return; }
	var surface = foldersSurfaceOf(el);
	var container = foldersContainer(surface);
	var st = foldersState(surface);
	var items = container.find('.folders_file');
	var index = items.index(el);
	if (e.shiftKey && st.anchor !== undefined && items.eq(st.anchor).length) {
		var from = Math.min(st.anchor, index);
		var to = Math.max(st.anchor, index);
		items.removeClass('selected');
		items.slice(from, to + 1).addClass('selected');
	}
	else if (e.ctrlKey || e.metaKey) {
		el.toggleClass('selected');
		st.anchor = index;
	}
	else {
		items.removeClass('selected');
		el.addClass('selected');
		st.anchor = index;
	}
	foldersSelectionSync(surface, el);
	if (surface == 'folders') { container.focus(); }
	else { $('#desk_layer').focus(); }
});

// A press on the listing's own background clears the selection. A right-click
// is left to the context menu, which reads the same target.
$(document).on('click', '#folders_contents, #desk_layer', function(e) {
	if ($(e.target).closest('.folders_file').length) { return; }
	foldersClearSelection(foldersSurfaceOf(this));
});

$(document).on('dblclick', '.folders_file', function() {
	var el = $(this);
	if (el.hasClass('desk_app')) {
		if (typeof deskOpenApp == 'function') { deskOpenApp(el.attr('app')); }
		else if (typeof appWindowOpener == 'function') { appWindowOpener(el.attr('app'), Date.now()); }
		else if (typeof jawnosSearchOpen == 'function') { jawnosSearchOpen(el.attr('app')); }
		return;
	}
	var surface = foldersSurfaceOf(el);
	var st = foldersState(surface);
	st.path = el.attr('path');
	st.type = el.attr('type');
	if (st.type == 'folder') {
		var open_data = { folder: st.path };
		if (surface == 'desk') { open_data.remote_uuid = ''; }
		foldersOpener(open_data);
	}
	else {
		foldersFileOpener(st);
	}
});

// ---- marquee ---------------------------------------------------------------
// A press on the empty listing and a drag draws a selection rectangle; every
// item it touches joins the selection (Ctrl/Cmd keeps what was there).
$(document).on('mousedown', '#folders_contents, #desk_layer', function(e) {
	if (e.which != 1) { return; }
	if ($(e.target).closest('.folders_file').length) { return; }
	if ($(e.target).closest('#folders_list_header').length) { return; }
	var surface = foldersSurfaceOf(this);
	var container = $(this);
	if (!(e.ctrlKey || e.metaKey || e.shiftKey)) { foldersClearSelection(surface); }
	folders_marquee = {
		surface: surface,
		container: container,
		x0: e.clientX,
		y0: e.clientY,
		moved: 0,
		additive: (e.ctrlKey || e.metaKey || e.shiftKey)
	};
});
$(document).on('mousemove', function(e) {
	if (!folders_marquee) { return; }
	var dx = e.clientX - folders_marquee.x0;
	var dy = e.clientY - folders_marquee.y0;
	if (Math.abs(dx) < 3 && Math.abs(dy) < 3) { return; }
	folders_marquee.moved = 1;
	var left = Math.min(folders_marquee.x0, e.clientX);
	var top = Math.min(folders_marquee.y0, e.clientY);
	var width = Math.abs(dx);
	var height = Math.abs(dy);
	var box = $('#folders_marquee_box');
	if (!box.length) { box = $('<div id="folders_marquee_box" class="folders_marquee"></div>').appendTo('body'); }
	box.css({ left: left, top: top, width: width, height: height });
	var rect = { left: left, top: top, right: left + width, bottom: top + height };
	var container = folders_marquee.container;
	container.find('.folders_file').each(function () {
		var el = $(this);
		var r = this.getBoundingClientRect();
		var hit = !(r.right < rect.left || r.left > rect.right || r.bottom < rect.top || r.top > rect.bottom);
		if (hit) { el.addClass('selected'); }
		else if (!folders_marquee.additive) { el.removeClass('selected'); }
	});
});
$(document).on('mouseup', function() {
	if (!folders_marquee) { return; }
	var moved = folders_marquee.moved;
	var surface = folders_marquee.surface;
	$('#folders_marquee_box').remove();
	folders_marquee = undefined;
	foldersSelectionSync(surface);
	if (!moved) { return; }
});

// ---- drag and drop ---------------------------------------------------------
// Each item carries the whole selection. Dropping on a folder's tile puts the
// items inside that folder; dropping on a listing's empty space puts them in
// the folder being looked at. Ctrl/Cmd copies instead of moving.
function foldersDraggable() {
	var can_drag = (typeof windowPhoneChecker != 'function') || windowPhoneChecker() == false;
	$('.folders_file').each(function() {
		var item = $(this);
		// an app shortcut has no file behind it to move
		if (item.hasClass('desk_app')) { return; }
		// a remote listing is read-only: its paths mean something on the other
		// machine, so neither the item nor a folder in it takes a drop
		var remote = (foldersSurfaceOf(item) == 'folders' && folders.remote_uuid);
		if (can_drag && !remote && !item.hasClass('ui-draggable')) {
			item.draggable({
				appendTo: 'body',
				helper: 'clone',
				revert: 'invalid',
				zIndex: 999999,
				cursorAt: { top: 24, left: 24 },
				distance: 4,
				cancel: '',
				start: function(p, ui) {
					var el = $(this);
					var surface = foldersSurfaceOf(el);
					if (!el.hasClass('selected')) { foldersSelectOnly(surface, el); }
					var st = foldersState(surface);
					var items = (st.selected && st.selected.length) ? st.selected.slice() : [ { path: el.attr('path'), type: el.attr('type') } ];
					folders_drag_state = { surface: surface, items: items };
					el.addClass('folders_drag_source');
					ui.helper.addClass('folders_drag_helper');
					if (items.length > 1) {
						$('<span class="folders_drag_count"></span>').text(items.length).appendTo(ui.helper);
					}
				},
				stop: function() {
					$(this).removeClass('folders_drag_source');
					folders_drag_state = undefined;
					folders_last_drag = Date.now();
				}
			});
		}
		if (!remote && item.attr('type') == 'folder' && !item.hasClass('ui-droppable')) {
			item.droppable({
				accept: '.folders_file',
				tolerance: 'pointer',
				over: function() { $(this).addClass('folders_drop_active'); },
				out: function() { $(this).removeClass('folders_drop_active'); },
				drop: function(e) {
					$(this).removeClass('folders_drop_active');
					foldersDropTo($(this).attr('path'), e.ctrlKey || e.metaKey);
				}
			});
		}
	});
	foldersSurfaceDroppable('#folders_contents', 'folders');
	foldersSurfaceDroppable('#desk_layer', 'desk');
}

function foldersSurfaceDroppable(selector, surface) {
	if (surface == 'folders' && folders.remote_uuid) { return; }
	var surface_el = $(selector);
	if (!surface_el.length || surface_el.hasClass('ui-droppable')) { return; }
	surface_el.droppable({
		accept: '.folders_file',
		tolerance: 'pointer',
		over: function() { $(this).addClass('folders_drop_active'); },
		out: function() { $(this).removeClass('folders_drop_active'); },
		drop: function(e) {
			$(this).removeClass('folders_drop_active');
			var st = foldersState(surface);
			foldersDropTo(st.folder, e.ctrlKey || e.metaKey);
		}
	});
}

function foldersDropTo(target, copy) {
	if (!folders_drag_state || !target) { return; }
	var items = [];
	$.each(folders_drag_state.items || [], function (i, item) {
		var path = item['path'];
		if (!path || path == target) { return; }
		// never drop a folder into itself or into one of its own descendants
		if (target.indexOf(path + '/') == 0) { return; }
		// dropping into the folder it already lives in would only fail
		var parent = path.replace(/\/[^\/]*$/, '');
		if (parent == target) { return; }
		items.push({ path: path, type: item['type'] });
	});
	if (!items.length) { return; }
	// the paste command already knows how to move or copy a run of items
	foldersCommandPOST({ command: 'paste' }, {
		folder: target,
		clipboard: items,
		command: copy ? 'copy' : 'cut',
		selected: [],
		path: undefined,
		type: undefined,
		remote_uuid: ''
	});
}

// ---- opening ---------------------------------------------------------------
function foldersFileOpener(state) {
	var st = state || folders;
	$.ajax({
		url: '/manager/folders/file/open',
		type: 'POST',
		data: {
			folders: JSON.stringify(st)
		},
		success: function(response) {
			if (response['app'] == 'gallery') {
				imageViewer({ 'files': response['files'], loadImages: 1, shuffle: 'off' });
			} else if (response['app'] == 'music') {
				musicToggle(response['raw_files']);
			} else if (response['app'] == 'studio') {
				studioImport(response['files']);
			} else if (response['app'] == 'ide') {
				$.each(response['raw_files'], function(i,v) {
					ideFileOpen({
						location: st['folder'],
						file: v
					});
				});
			}
		}
	});
}

// ---- context menu ----------------------------------------------------------
$(document).on('contextmenu', '.folders_file, #folders_contents, #desk_layer', function(e) {
	// a pinned app has its own short menu (Open, Unpin) in desk.js
	if ($(e.target).closest('.desk_app').length) { return; }
	e.preventDefault();
	var press_x = e.clientX, press_y = e.clientY;
	var surface = foldersSurfaceOf(this);
	var st = foldersState(surface);
	st.app = undefined;
	var container = foldersContainer(surface);
	// a remote listing is read-only: every command here would run on this
	// machine against a path that only exists on the other one
	if (surface == 'folders' && folders.remote_uuid) { return; }
	var context = 'file';
	var target = $(e.target);
	if (target.closest('.folders_file').length) {
		target = target.closest('.folders_file');
		st.path = target.attr('path');
		st.type = target.attr('type');
		// a right-click on one of several selected items keeps the run
		if (!target.hasClass('selected')) { foldersSelectOnly(surface, target); }
		else { foldersSelectionSync(surface, target); }
		if (st.type == 'folder') { context = 'folder'; }
	}
	else {
		st.path = undefined;
		st.type = undefined;
		foldersClearSelection(surface);
		context = 'folder_background';
	}
	var jstate = JSON.stringify(st);
	$.ajax({
		url: '/manager/folders/context',
		type: 'POST',
		data: { path: st.path, type: st.type, folders: jstate, context: context },
		success:function(response) {
			var menu = $(response.html).attr('surface', surface);
			$('body').append(menu);
			var margin = 6;
			var left = Math.min(press_x, $(window).width() - menu.outerWidth() - margin);
			var top = Math.min(press_y, $(window).height() - menu.outerHeight() - margin);
			menu.css({ 'left': Math.max(margin, left), 'top': Math.max(margin, top), 'position': 'fixed' });
			if (surface == 'folders') { container.focus(); }
		}
	});
});

$(document).on('click contextmenu', function() {
	$('.folders_context').remove();
});

$(document).on('click', '.folders_command', function() {
	var command = $(this).attr('command');
	var folder = $('#folders').attr('folder');
	foldersOpener({ folder: folder, command: command });
});

$(document).on('click', '#folders_refresh', function() {
	foldersOpener({ folder: $('#folders').attr('folder') || folders.folder });
});

$(document).on('keyup', '#folders_address', function(e) {
	if (e.keyCode == 13) {
		foldersOpener({ folder: $(this).val() });
		foldersPathEdit(false);
	}
	else if (e.keyCode == 27) {
		foldersPathEdit(false);
	}
});

$(document).on('click', '.folders_crumb', function() {
	foldersOpener({ folder: $(this).attr('path') });
});

function foldersPathEdit(show) {
	if (show) {
		$('#folders').addClass('edit_path');
		$('#folders_address').val($('#folders').attr('folder') || folders.folder || '').focus().select();
	}
	else {
		$('#folders').removeClass('edit_path');
	}
}
$(document).on('click', '#folders_path_toggle', function() {
	foldersPathEdit(!$('#folders').hasClass('edit_path'));
});

$(document).on('click','.folders_context_selection', function() {
	var menu = $(this).closest('.folders_context');
	var surface = menu.attr('surface') || 'folders';
	foldersCommand({ command: $(this).attr('command') }, foldersState(surface));
});

function foldersCommand(data, state) {
	if (!data) { return; }
	var st = state || folders;
	var surface = (st === desk) ? 'desk' : 'folders';
	// fetching is the one thing that makes sense while looking at another
	// machine, so it is answered before the read-only gate below
	if (data['command'] == 'fetch_home') { foldersFetchHome(st); return; }
	if (surface == 'folders' && folders.remote_uuid) { return; }
	var command = data['command'];
	if (command == 'copy') {
		st.clipboard = (st.selected || []).slice();
		st.command = 'copy';
		foldersApplyCut(surface);
	}
	else if (command == 'cut') {
		st.clipboard = (st.selected || []).slice();
		st.command = 'cut';
		foldersApplyCut(surface);
	}
	else if (command == 'select_all') {
		foldersContainer(surface).find('.folders_file').addClass('selected');
		foldersSelectionSync(surface);
	}
	else if (command == 'open') {
		if (st.type == 'folder') {
			var open_data = { folder: st.path };
			if (surface == 'desk') { open_data.remote_uuid = ''; }
			foldersOpener(open_data);
		}
		else {
			foldersFileOpener(st);
		}
	}
	else if (command == 'open_with') {
		foldersOpenWith(st);
	}
	else if (command == 'paste') {
		foldersPaste(st);
	}
	else if (command == 'pin_app') {
		if (typeof deskAppPicker == 'function') { deskAppPicker(); }
	}
	else if (command == 'open_app') {
		if (st.app && typeof deskOpenApp == 'function') { deskOpenApp(st.app); }
		else if (st.app && typeof jawnosSearchOpen == 'function') { jawnosSearchOpen(st.app); }
	}
	else if (command == 'unpin_app') {
		if (st.app && typeof deskUnpinApp == 'function') { deskUnpinApp(st.app); }
	}
	else if (command == 'desk_folder') {
		foldersDeskFolder(st.path || st.folder);
	}
	else if (command == 'desk_folder_reset') {
		foldersDeskFolder('');
	}
	else if (command == 'archive') {
		foldersArchive(st);
	}
	else {
		$.ajax({
			url: '/manager/folders/context/command',
			type: 'GET',
			data: {
				command: command,
				folders: JSON.stringify(st)
			},
			success:function(response) {
				if (response && response.dialog) {
					var box = $(response.dialog).attr('state_surface', surface);
					$('#dialog_boxes').append(box);
					appointment_chron();
				}
			}
		});
	}
}

// The toolbar is as thick as its items need - even one row of icons is taller
// than the bar's own minimum - so a drawer asks where its bottom is before
// hanging from it.
function foldersDrawerTop() {
	return $('#folders_toolbar').outerHeight() + 5;
}

// Bring what is selected - or the folder being looked at - back to this
// machine. The paths are on the machine being browsed, and it is that machine
// which says where they belong; the queue panel shows the work as it goes.
function foldersFetchHome(state) {
	var st = state || folders;
	var items = st.selected || [];
	if (!items.length) {
		var path = st.path || st.folder;
		if (path) { items = [ { path: path } ]; }
	}
	var remote_uuid = st.remote_uuid || $('#folders').attr('remote_uuid') || '';
	$.each(items, function (i, item) {
		$.ajax({
			url: '/manager/folders/archive/fetch',
			type: 'POST',
			data: { path: item['path'], remote_uuid: remote_uuid }
		});
	});
	$('#folders_archive_queue').css({ 'top': foldersDrawerTop() }).show();
	foldersArchiveQueue();
}

function foldersCommandConfirm(uuid) {
	var box = $('.dialog_box[uuid="' + uuid + '"]');
	var command = box.attr('command');
	// the app picker saves a list of names, not a file command
	if (command == 'pin_app') {
		var pinned = [];
		box.find('.desk_pin_check:checked').each(function () { pinned.push($(this).val()); });
		box.remove();
		if (typeof deskPinsSaveList == 'function') { deskPinsSaveList(pinned); }
		return;
	}
	var surface = box.attr('state_surface') || 'folders';
	var st = (surface == 'desk') ? desk : folders;
	var inputs = {};
	box.find('input').each(function() {
		inputs[$(this).attr('name')] = $(this).val();
	});
	box.remove();
	if (!command) { return; }
	foldersCommandPOST({ command: command, inputs: inputs }, st);
}

// Choose (or reset) the folder the desk shows. The machine saves it; a visible
// desk is read again at once.
function foldersDeskFolder(folder) {
	$.ajax({
		url: '/manager/folders/desk/folder',
		type: 'POST',
		data: { folder: folder || '' },
		success: function(response) {
			if (response && response['ok'] && typeof deskRefreshIfVisible == 'function') {
				deskRefreshIfVisible();
			}
		}
	});
}

// The properties card's two buttons: put the path on the clipboard, or open its
// folder in the browser.
$(document).on('click', '.folders_copy_path', function () {
	var button = $(this);
	var path = button.attr('path') || '';
	var done = function () {
		button.text(jawnosT('Copied'));
		setTimeout(function () { button.text(jawnosT('Copy path')); }, 1200);
	};
	if (navigator.clipboard && navigator.clipboard.writeText) {
		navigator.clipboard.writeText(path).then(done, done);
	}
	else {
		var field = $('<textarea>').val(path).css({ position: 'fixed', left: '-9999px' }).appendTo('body');
		field[0].select();
		try { document.execCommand('copy'); } catch (e) { /* older engines */ }
		field.remove();
		done();
	}
});
$(document).on('click', '.folders_open_parent', function () {
	var path = $(this).attr('path');
	if (path) { foldersOpener({ folder: path, remote_uuid: ($(this).attr('remote') || '') }); }
});

// What a command with nothing more to ask does: the clipboard going into the
// folder on screen, and the desktop's own opener for a file.
function foldersPaste(state) {
	var st = state || folders;
	var surface = (st === desk) ? 'desk' : 'folders';
	foldersCommandPOST({ command: 'paste' }, st);
	// the paste is on its way, so a second one does not queue it again
	st.clipboard = [];
	st.command = undefined;
	foldersApplyCut(surface);
}

function foldersOpenWith(state) {
	$.ajax({
		url: '/manager/folders/open_with',
		type: 'POST',
		data: { folders: JSON.stringify(state || folders) }
	});
}

// A command from a dialog's OK, or one that needs no dialog at all. The answer
// is a dialog when there is something to say - a job's progress, or why the
// command would not go - and the folder is read again when it went.
function foldersCommandPOST(data, state) {
	var st = state || folders;
	var surface = (st === desk) ? 'desk' : 'folders';
	return $.ajax({
		url: '/manager/folders/context/command',
		type: 'POST',
		data: {
			command: data['command'],
			inputs: JSON.stringify(data['inputs'] || {}),
			folders: JSON.stringify(st)
		},
		success: function(response) {
			if (response && response['dialog']) {
				var box = $(response['dialog']).attr('state_surface', surface);
				$('#dialog_boxes').append(box);
				appointment_chron();
				foldersJobWatcher();
			}
			if (response && response['status'] == 'ok') {
				foldersRefreshAll();
			}
		}
	});
}

// Read every surface again: the window (when it is open) and the desk (when it
// is the chosen background). A job's own dialog calls this when it finishes.
function foldersRefreshAll() {
	if ($('#folders').length) {
		foldersOpener({ folder: $('#folders').attr('folder') || folders.folder });
	}
	if (typeof deskRefreshIfVisible == 'function') { deskRefreshIfVisible(); }
}
function foldersRefresh() { foldersRefreshAll(); }

// A job's progress lives in the dialog box that started it: the box carries
// the job's id and asks after it once a second until the job is finished or
// failed, when the box keeps the last word and the folder is read again. The
// asking stops when no box is watching anything.
var folders_job_interval;
function foldersJobWatcher() {
	if (folders_job_interval) { return; }
	folders_job_interval = setInterval(function() {
		var boxes = $('.dialog_box[job]');
		if (!boxes.length) {
			clearInterval(folders_job_interval);
			folders_job_interval = undefined;
			return;
		}
		boxes.each(function() {
			var box = $(this);
			$.ajax({
				url: '/manager/folders/job',
				type: 'GET',
				data: { id: box.attr('job') },
				success: function(job) {
					if (!job || job['status'] != 'ok') {
						box.removeAttr('job').find('.job_progress').text('that job is gone');
						return;
					}
					var word = job['progress'] || job['state'];
					if (job['errors'] && job['errors'].length) { word = word + '\n' + job['errors'].join('\n'); }
					box.find('.job_progress').text(word);
					if (job['state'] == 'finished' || job['state'] == 'failed') {
						box.removeAttr('job');
						box.find('.job_stop').remove();
						foldersRefreshAll();
					}
				}
			});
		});
	}, 1000);
}

$(document).on('click', '.job_stop', function() {
	var button = $(this);
	button.closest('.dialog_box').find('.job_progress').text('stopping...');
	$.ajax({
		url: '/manager/folders/job/cancel',
		type: 'POST',
		data: { id: button.attr('job') }
	});
});

// ---- archive ---------------------------------------------------------------
// Put the selection (or the folder being looked at) on the archive queue. The
// machine decides which location each item belongs to and where it goes; what
// comes back is how many were queued and why anything was not.
function foldersArchive(state) {
	var st = state || folders;
	$('body').css({ 'cursor': 'progress' });
	$.ajax({
		url: '/manager/folders/archive',
		type: 'POST',
		data: { folders: JSON.stringify(st) },
		success: function (response) {
			$('body').css({ 'cursor': 'auto' });
			if (response && response.dialog) {
				$('#dialog_boxes').append(response.dialog);
			}
			if ($('#folders_archive_queue').is(':visible')) { foldersArchiveQueue(); }
		},
		error: function () {
			$('body').css({ 'cursor': 'auto' });
		}
	});
}

var folders_archive_interval;
var folders_archive_locations = [];
function foldersArchiveQueue() {
	$.ajax({
		url: '/manager/folders/archive',
		type: 'GET',
		success: function (response) {
			var box = $('#folders_archive_queue').empty();
			folders_archive_locations = (response && response['locations']) || [];
			if (folders_archive_locations.length) {
				var pick = $('<select>').appendTo(box);
				$.each(folders_archive_locations, function (i, l) {
					$('<option>').attr('value', l['location']).text(l['location'] + (l['remote_hostname'] ? ' on ' + l['remote_hostname'] : '')).appendTo(pick);
				});
				$('<button>').addClass('hover').text('rescan').css({ 'float': 'right' }).on('click', function () {
					foldersArchiveRescan(pick.val());
				}).appendTo(box);
			}
			var jobs = (response && response['jobs']) || [];
			if (!jobs.length) {
				$('<i>').text('Nothing is queued for the archive.').appendTo(box);
				return;
			}
			$.each(jobs, function (i, job) {
				var item = job['item'] || {};
				var name = (item['relative'] && item['relative'].length) ? item['relative'] : (item['path'] || '');
				var line = $('<div>').css({ 'border-bottom': 'solid 1px', 'padding': '3px', 'overflow-wrap': 'break-word' });
				var buttons = $('<span>').css({ 'float': 'right' });
				if (job['state'] == 'failed' || job['state'] == 'finished') {
					$('<button>').addClass('hover').text('retry').on('click', function () { foldersArchiveJob('retry', job['id']); }).appendTo(buttons);
				}
				else {
					$('<button>').addClass('hover').text('stop').on('click', function () { foldersArchiveJob('cancel', job['id']); }).appendTo(buttons);
				}
				buttons.appendTo(line);
				$('<b>').text(job['state']).appendTo(line);
				if (job['task'] == 'archive_manifest_rescan') {
					$('<span>').text(' reading ' + (item['location'] || '?') + ' again').appendTo(line);
				}
				else {
					$('<span>').text(' ' + name + '  ->  ' + (item['location'] || '?') + ' on ' + (item['remote_hostname'] || '?')).appendTo(line);
				}
				if (job['errors'] && job['errors'].length) {
					$('<div>').css({ 'font-size': '13px' }).text(job['errors'].join('; ')).appendTo(line);
				}
				else if (job['progress']) {
					$('<div>').css({ 'font-size': '13px' }).text(job['progress']).appendTo(line);
				}
				else if (job['sent'] || job['skipped']) {
					$('<div>').css({ 'font-size': '13px' }).text((job['sent'] || 0) + ' sent, ' + (job['skipped'] || 0) + ' already there').appendTo(line);
				}
				box.append(line);
			});
		}
	});
}

function foldersArchiveJob(action, id) {
	$.ajax({
		url: '/manager/folders/archive/' + action,
		type: 'POST',
		data: { id: id },
		success: function () { foldersArchiveQueue(); }
	});
}

// Ask the machine holding a location's archive to read that location again.
// The work happens there, where the drive is, not here.
function foldersArchiveRescan(location) {
	var remote_uuid = '';
	$.each(folders_archive_locations, function (i, l) {
		if (l['location'] == location) { remote_uuid = l['remote_uuid']; }
	});
	$.ajax({
		url: '/manager/folders/archive/manifest/rescan',
		type: 'POST',
		data: { location: location, remote_uuid: remote_uuid },
		success: function () { foldersArchiveQueue(); }
	});
}

// ---- drawers ---------------------------------------------------------------
$(document).on('click', '#folders_bookmarks_toggle', function () {
	var box = $('#folders_bookmarks');
	if (box.is(':visible')) {
		box.hide();
	}
	else {
		box.css({ 'top': foldersDrawerTop() }).show();
	}
});

// A bookmark is navigation only, so it works the same on a remote machine:
// the path means something there, and the machine being browsed stays put.
$(document).on('click', '.folders_bookmark', function () {
	var path = $(this).attr('path');
	$('#folders_bookmarks').hide();
	foldersOpener({ folder: path });
});

$(document).on('click', '#folders_archive_toggle', function () {
	var box = $('#folders_archive_queue');
	if (box.is(':visible')) {
		box.hide();
		clearInterval(folders_archive_interval);
	}
	else {
		box.css({ 'top': foldersDrawerTop() }).show();
		foldersArchiveQueue();
		folders_archive_interval = setInterval(foldersArchiveQueue, 3000);
	}
});

// ---- keyboard --------------------------------------------------------------
// The listing is one focusable control. A focused item is the selection, so the
// arrows walk it, Shift+arrows take a run, and the usual file-manager keys work.
function foldersGridColumns(container) {
	if (container.attr('data-view') == 'list') { return 1; }
	var first = container.find('.folders_file').first();
	if (!first.length) { return 1; }
	var item_width = first.outerWidth(true) || 110;
	return Math.max(1, Math.floor((container.innerWidth() || $(window).width()) / item_width));
}

function foldersMoveSelection(surface, delta, extend, jump) {
	var container = foldersContainer(surface);
	var st = foldersState(surface);
	var items = container.find('.folders_file');
	if (!items.length) { return; }
	var current = items.filter('.selected');
	var index = current.length ? items.index(current.last()) : -1;
	var next;
	if (jump == 'home') { next = 0; }
	else if (jump == 'end') { next = items.length - 1; }
	else if (index < 0) { next = (delta > 0) ? 0 : items.length - 1; }
	else { next = Math.min(items.length - 1, Math.max(0, index + delta)); }
	if (extend && st.anchor !== undefined && items.eq(st.anchor).length) {
		var from = Math.min(st.anchor, next);
		var to = Math.max(st.anchor, next);
		items.removeClass('selected');
		items.slice(from, to + 1).addClass('selected');
	}
	else {
		items.removeClass('selected');
		items.eq(next).addClass('selected');
		st.anchor = next;
	}
	var el = items.eq(next);
	foldersSelectionSync(surface, el);
	if (el.length) { el[0].scrollIntoView({ block: 'nearest' }); }
}

function foldersKey(e, surface) {
	var container = foldersContainer(surface);
	if (!container.length) { return; }
	if ($(e.target).is('input, textarea, select, [contenteditable="true"]')) { return; }
	var st = foldersState(surface);
	var items = container.find('.folders_file');
	var key = e.key || '';
	var ctrl = e.ctrlKey || e.metaKey;
	if (ctrl && (key == 'a' || key == 'A')) {
		e.preventDefault();
		items.addClass('selected');
		foldersSelectionSync(surface, items.last());
		return;
	}
	if (ctrl && (key == 'c' || key == 'C')) { e.preventDefault(); foldersCommand({ command: 'copy' }, st); return; }
	if (ctrl && (key == 'x' || key == 'X')) { e.preventDefault(); foldersCommand({ command: 'cut' }, st); return; }
	if (ctrl && (key == 'v' || key == 'V')) { e.preventDefault(); foldersCommand({ command: 'paste' }, st); return; }
	if (ctrl && (key == 'l' || key == 'L') && surface == 'folders') { e.preventDefault(); foldersPathEdit(true); return; }
	if (key == 'Escape') {
		e.preventDefault();
		if ($('#folders').hasClass('edit_path')) { foldersPathEdit(false); }
		else { foldersClearSelection(surface); }
		return;
	}
	if (key == 'Delete') {
		e.preventDefault();
		if (st.selected && st.selected.length) { foldersCommand({ command: e.shiftKey ? 'shred' : 'delete' }, st); }
		return;
	}
	if (key == 'F2') {
		e.preventDefault();
		if (st.selected && st.selected.length == 1) { foldersCommand({ command: 'rename' }, st); }
		return;
	}
	if (key == 'Enter') {
		e.preventDefault();
		var chosen = items.filter('.selected').last();
		if (chosen.length && chosen.hasClass('desk_app')) {
			if (typeof deskOpenApp == 'function') { deskOpenApp(chosen.attr('app')); }
			else if (typeof appWindowOpener == 'function') { appWindowOpener(chosen.attr('app'), Date.now()); }
			return;
		}
		if (st.selected && st.selected.length == 1) {
			st.path = st.selected[0]['path'];
			st.type = st.selected[0]['type'];
			foldersCommand({ command: 'open' }, st);
		}
		return;
	}
	if (key == 'ArrowLeft' || key == 'ArrowRight' || key == 'ArrowUp' || key == 'ArrowDown') {
		e.preventDefault();
		var delta = 0;
		if (key == 'ArrowRight') { delta = 1; }
		else if (key == 'ArrowLeft') { delta = -1; }
		else {
			var cols = foldersGridColumns(container);
			delta = (key == 'ArrowDown') ? cols : -cols;
		}
		foldersMoveSelection(surface, delta, e.shiftKey);
		return;
	}
	if (key == 'Home' || key == 'End') {
		e.preventDefault();
		foldersMoveSelection(surface, 0, e.shiftKey, (key == 'Home') ? 'home' : 'end');
		return;
	}
	if (key.length == 1 && !ctrl && !e.altKey) {
		var now = Date.now();
		if (now - folders_typeahead_at > 900) { folders_typeahead = ''; }
		folders_typeahead += key.toLowerCase();
		folders_typeahead_at = now;
		var match = null;
		items.each(function () {
			if (match) { return; }
			if (($(this).attr('data-name') || '').toLowerCase().indexOf(folders_typeahead) == 0) { match = $(this); }
		});
		if (match) {
			e.preventDefault();
			items.removeClass('selected');
			match.addClass('selected');
			st.anchor = items.index(match);
			foldersSelectionSync(surface, match);
			match[0].scrollIntoView({ block: 'nearest' });
		}
	}
}
$(document).on('keydown', '#folders_contents', function(e) { foldersKey(e, 'folders'); });
$(document).on('keydown', '#desk_layer', function(e) { foldersKey(e, 'desk'); });
