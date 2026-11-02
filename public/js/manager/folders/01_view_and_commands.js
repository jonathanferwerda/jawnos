// ---- view ------------------------------------------------------------------
// The grid is the default; the list gives every item its type, size and date.
// The choice is remembered per screen, like the desk layout.
function foldersView() {
	return (localStorage.getItem('folders_view') == 'list') ? 'list' : 'grid';
}
function foldersApplyView(root) {
	var view = foldersView();
	root = (root && root.length) ? root : foldersRoot();
	root.find('.folders_contents').attr('data-view', view);
	root.find('.folders_mainview').attr('data-view', view);
	var toggle = root.find('.folders_view_toggle');
	var icon = (view == 'list') ? toggle.attr('data-icon-grid') : toggle.attr('data-icon-list');
	if (icon) { toggle.find('img').attr('src', icon); }
}
$(document).on('click', '#folders_view_toggle', function () {
	foldersActivateFrom(this);
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
			// app shortcuts and desk places are selected visually, but they are not
			// files: they must not reach a paste, a delete or a properties read
			if (!el.hasClass('desk_app') && !el.hasClass('desk_place') && el.attr('path')) {
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
		var total = container.find('.folders_file').not('.desk_place').length;
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
	foldersActivateFrom(this);
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
	foldersActivateFrom(this);
	if ($(e.target).closest('.folders_file').length) { return; }
	foldersClearSelection(foldersSurfaceOf(this));
});

$(document).on('dblclick', '.folders_file', function() {
	foldersActivateFrom(this);
	var el = $(this);
	if (el.hasClass('desk_app')) {
		if (typeof deskOpenApp == 'function') { deskOpenApp(el.attr('app')); }
		else if (typeof appWindowOpener == 'function') { appWindowOpener(el.attr('app'), Date.now(), { visible: 'yes' }); }
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
	foldersActivateFrom(this);
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
		// a desk place is a fixed door, not part of a selection run
		if (el.hasClass('desk_place')) { return; }
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
		// an app shortcut has no file behind it to move, and a desk place is a
		// fixed door, not something to drag
		if (item.hasClass('desk_app') || item.hasClass('desk_place')) { return; }
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
			folders: JSON.stringify(st),
			// the window's own padlock token, so a sibling in a hidden app's folder
			// is listed on the same terms the window already saw it
			unlock: (typeof foldersRoot == 'function') ? ($('#folders').attr('unlock') || '') : '',
			browser_tab_id: (typeof jawnosMediaTab == 'function') ? jawnosMediaTab() : ''
		},
		success: function(response) {
			if (response['app'] == 'gallery') {
				imageViewer({ 'files': response['files'], 'target': response['target'], loadImages: 1, shuffle: 'off' });
			} else if (response['app'] == 'music') {
				musicToggle(response['raw_files']);
			} else if (response['app'] == 'studio') {
				if (typeof studioImport === 'function') { studioImport(response['files']); }
			} else if (response['app'] == 'ide') {
				if (typeof ideFileOpen !== 'function') { return; }
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
	// a pinned app and a desk place each have their own short menu (desk.js)
	if ($(e.target).closest('.desk_app, .desk_place').length) { return; }
	foldersActivateFrom(this);
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
	var jstate = JSON.stringify($.extend({}, st, { surface: surface }));
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
	foldersActivateFrom(this);
	var command = $(this).attr('command');
	var folder = $('#folders').attr('folder');
	foldersOpener({ folder: folder, command: command });
});

$(document).on('click', '#folders_refresh', function() {
	foldersActivateFrom(this);
	foldersOpener({ folder: $('#folders').attr('folder') || folders.folder });
});

$(document).on('keyup', '#folders_address', function(e) {
	foldersActivateFrom(this);
	if (e.keyCode == 13) {
		foldersOpener({ folder: $(this).val() });
		foldersPathEdit(false);
	}
	else if (e.keyCode == 27) {
		foldersPathEdit(false);
	}
});

$(document).on('click', '.folders_crumb', function() {
	foldersActivateFrom(this);
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
	foldersActivateFrom(this);
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
	// fetching and the display toggle make sense while looking at another
	// machine, so they are answered before the read-only gate below
	if (data['command'] == 'fetch_home') { foldersFetchHome(st); return; }
	if (data['command'] == 'toggle_hidden') { foldersToggleHidden(); return; }
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
	else if (command == 'open_tab' || command == 'open_window') {
		var target = st.folder;
		if (st.path) {
			// a file opens the folder it lives in; a folder opens itself
			target = (st.type == 'folder') ? st.path : (String(st.path).replace(/\/[^\/]*$/, '') || '/');
		}
		if (command == 'open_tab') {
			foldersOpenInTab(target, st.remote_uuid || '', (st.window_id || undefined));
		}
		else {
			foldersOpenInWindow(target, st.remote_uuid || '');
		}
	}
	else if (command == 'restore_trash') {
		foldersCommandPOST({ command: 'restore_trash' }, st);
	}
	else if (command == 'open_trash') {
		var trash = (st === desk) ? (desk.trash_folder || (desk.trash && desk.trash['path'])) : '';
		if (trash) { foldersOpener({ folder: trash, remote_uuid: '' }); }
	}
	else if (command == 'browser_back') {
		window.history.back();
	}
	else if (command == 'browser_refresh') {
		window.location.reload();
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
