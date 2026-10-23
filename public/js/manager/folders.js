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
	history: [],
	history_index: -1,
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

var folders_instances = {};
var folders_last_window = undefined;
var folders_window_seq = 0;
var folders_drag_state = undefined;
var folders_last_drag = 0;
var folders_typeahead = '';
var folders_typeahead_at = 0;
var folders_marquee = undefined;

// The canonical ids live on one window at a time. A second Folders window has
// the same markup with classes only; activating it moves the ids to it, so the
// older code paths that ask for #folders_contents still mean the window the
// person is working in.
var folders_id_map = {
	folders: 'folders_app',
	folders_toolbar: 'folders_toolbar',
	folders_tabs: 'folders_tabs',
	folders_mainview: 'folders_mainview',
	folders_sidebar: 'folders_sidebar',
	folders_sidebar_toggle: 'folders_sidebar_toggle',
	folders_listing_pane: 'folders_listing_pane',
	folders_list_header: 'folders_list_header',
	folders_contents: 'folders_contents',
	folders_breadcrumb: 'folders_breadcrumb',
	folders_address: 'folders_address',
	folders_path_toggle: 'folders_path_toggle',
	folders_machine_select: 'folders_machine_select',
	folders_view_toggle: 'folders_view_toggle',
	folders_bookmarks_toggle: 'folders_bookmarks_toggle',
	folders_archive_toggle: 'folders_archive_toggle',
	folders_refresh: 'folders_refresh',
	folders_back: 'folders_back',
	folders_forward: 'folders_forward',
	folders_bookmarks: 'folders_bookmarks',
	folders_archive_queue: 'folders_archive_queue',
	folders_padlock: 'folders_padlock',
	folders_bottom_bar: 'folders_bottom_bar'
};

function foldersNewId(prefix) {
	folders_window_seq++;
	return (prefix || 'f') + Date.now().toString(36) + folders_window_seq.toString(36) + Math.random().toString(36).slice(2, 6);
}

function foldersNewTab(folder, remote_uuid, tab_id) {
	return {
		id: tab_id || foldersNewId('t'),
		folder: (folder === undefined || folder === null) ? undefined : folder,
		remote_uuid: remote_uuid || '',
		disk: {},
		files: [],
		history: [],
		history_index: -1,
		selected: [],
		clipboard: [],
		command: undefined,
		type: undefined,
		path: undefined,
		anchor: undefined
	};
}

function foldersRootFor(id) {
	if (!id) { return $(); }
	return $('.wind[data-window-id="' + id + '"] .folders_app').first();
}

function foldersRoot() {
	if (folders && folders.window_id) {
		var active = foldersRootFor(folders.window_id);
		if (active.length) { return active; }
	}
	return $('.folders_app').first();
}

function foldersInstanceFor(root) {
	root = $(root);
	var id = root.attr('data-folders-id');
	if (!id) { return null; }
	var inst = folders_instances[id];
	if (!inst) {
		inst = { id: id, root: root, tabs: [], active: 0 };
		folders_instances[id] = inst;
	}
	inst.root = root;
	if (!inst.tabs.length) {
		inst.tabs.push(foldersNewTab(root.attr('folder') || undefined, root.attr('remote_uuid') || '', root.attr('data-tab-id')));
		inst.active = 0;
	}
	return inst;
}

function foldersNormalizeIds(active_root) {
	active_root = active_root && active_root.length ? active_root : $('.folders_app').first();
	$('.folders_app').each(function () {
		var root = $(this);
		$.each(folders_id_map, function (id, cls) {
			if (id == 'folders') { root.removeAttr('id'); }
			else { root.find('.' + cls).removeAttr('id'); }
		});
	});
	if (!active_root.length) { return; }
	$.each(folders_id_map, function (id, cls) {
		if (id == 'folders') { active_root.attr('id', 'folders'); }
		else { active_root.find('.' + cls).first().attr('id', id); }
	});
}

function foldersTabLabel(folder) {
	if (!folder) { return jawnosT('Home'); }
	var parts = String(folder).replace(/\/+$/, '').split('/').filter(Boolean);
	return parts.length ? parts[parts.length - 1] : '/';
}

function foldersApplyWindowName(inst) {
	if (!inst || !inst.root || !inst.root.length) { return; }
	var tab = inst.tabs[inst.active];
	var folder = (tab && tab.folder) ? tab.folder : '';
	var wind = inst.root.closest('.wind');
	if (!wind.length) { return; }
	// the bar names the folder being read, not its whole path
	var name = jawnosT('Folders') + (folder ? ' - ' + foldersTabLabel(folder) : '');
	var text = wind.find('.appointment_name .name_text').first();
	// every click activates the window; only a real name change repaints the bar
	if (text.length && text.text() === name) { return; }
	text.text(name);
	if (typeof taskbarDisplayer == 'function') { taskbarDisplayer(); }
}

function foldersTabsRender(inst) {
	if (!inst || !inst.root || !inst.root.length) { return; }
	var bar = inst.root.find('.folders_tabs');
	if (!bar.length) { return; }
	var signature = inst.active + '|' + $.map(inst.tabs, function (tab) { return tab.id + '=' + (tab.folder || ''); }).join('|');
	if (bar.attr('data-signature') === signature) { return; }
	bar.attr('data-signature', signature);
	bar.empty();
	if (inst.tabs.length <= 1) { bar.hide(); return; }
	bar.show();
	$.each(inst.tabs, function (i, tab) {
		var button = $('<button type="button" class="folders_tab"></button>')
			.attr({ 'data-tab-id': tab.id, title: tab.folder || '' });
		if (i == inst.active) { button.addClass('active'); }
		$('<span class="folders_tab_label"></span>').text(foldersTabLabel(tab.folder)).appendTo(button);
		$('<span class="folders_tab_close" aria-label="' + jawnosT('Close') + '">×</span>').appendTo(button);
		bar.append(button);
	});
	bar.append($('<button type="button" class="folders_tab_new" aria-label="' + jawnosT('New tab') + '">+</button>'));
}

function foldersSidebarApply(root) {
	root = (root && root.length) ? root : foldersRoot();
	if (!root.length) { return; }
	var wide = root.width() >= 720;
	var pref = localStorage.getItem('folders_sidebar');
	var show = wide && pref != 'off';
	root.find('.folders_sidebar').toggle(show);
	root.find('.folders_sidebar_toggle').toggle(wide).attr('data-on', show ? 'yes' : 'no');
}

function foldersActivate(root) {
	var inst = foldersInstanceFor(root);
	if (!inst) { return null; }
	var tab = inst.tabs[inst.active];
	if (!tab) {
		tab = foldersNewTab(inst.root.attr('folder') || undefined, inst.root.attr('remote_uuid') || '', inst.root.attr('data-tab-id'));
		inst.tabs.push(tab);
		inst.active = 0;
	}
	folders = tab;
	folders.window_id = inst.id;
	folders.tab_id = tab.id;
	folders_last_window = inst.id;
	foldersNormalizeIds(inst.root);
	foldersApplyWindowName(inst);
	foldersTabsRender(inst);
	foldersSidebarApply(inst.root);
	foldersHistoryApply();
	return inst;
}

function foldersActivateFrom(el) {
	var root = $(el).closest('.folders_app');
	if (root.length) { foldersActivate(root); return true; }
	return false;
}

function foldersState(surface) { return (surface == 'desk') ? desk : folders; }
function foldersContainer(surface) {
	if (surface == 'desk') { return $('#desk_layer'); }
	return foldersRoot().find('.folders_contents');
}
function foldersSurfaceOf(el) { return ($(el).closest('#desk_layer').length) ? 'desk' : 'folders'; }

// A long press on a file, folder or the listing background opens its menu on touch
if (typeof jawnosContextMenuOn == 'function') { jawnosContextMenuOn('.folders_file, .folders_contents, #desk_layer'); }
$(document).on('click', '#folders_toggle', function() {
	// Like Terminal, the menu's Folders row opens another window. A window is
	// added beside the one already open, with its own tab strip and history.
	foldersOpener({ new_window: true });
});

// the media padlock: sealed names and a hidden app's files are not listed
// until a paired phone signs the house open. An open padlock shuts again on a
// press; a shut one asks the house to show the unlock page.
$(document).on('click', '.folders_lock', function () {
	foldersActivateFrom(this);
	var root = $(this).closest('.folders_app');
	if (root.attr('unlock')) {
		root.attr('unlock', '');
		if (typeof jawnosMediaLockApp === 'function') {
			jawnosMediaLockApp('folders', function () { foldersRefreshWindows(); });
		}
		else { foldersRefreshWindows(); }
	}
	else {
		root.find('.folders_mainview').hide();
		root.find('.folders_padlock').show();
		if (typeof padlockAskPhone === 'function') { padlockAskPhone('folders'); }
	}
});
$(document).on('click', '.folders_cancel_padlock', function () {
	var root = $(this).closest('.folders_app');
	root.find('.folders_padlock').hide();
	root.find('.folders_mainview').show();
});

function foldersOpener(data) {
	if (!data) { data = {}; }
	var window_id = data['window_id'];
	if (!window_id && data['new_window']) { window_id = foldersNewId('f'); }
	if (!window_id && folders && folders.window_id && folders_instances[folders.window_id]) { window_id = folders.window_id; }
	if (!window_id) { window_id = foldersNewId('f'); }
	var inst = folders_instances[window_id];
	if (!inst) {
		inst = { id: window_id, root: foldersRootFor(window_id), tabs: [], active: 0 };
		folders_instances[window_id] = inst;
	}
	var tab = null;
	if (data['tab_id']) {
		$.each(inst.tabs, function (i, t) { if (t.id == data['tab_id']) { tab = t; } });
	}
	if (!tab && data['keep_tab'] && inst.tabs.length) { tab = inst.tabs[inst.active]; }
	if (!tab && inst.tabs.length && !data['new_window']) { tab = inst.tabs[inst.active]; }
	if (!tab) {
		var seed_folder = data['folder'];
		var seed_remote = data['remote_uuid'];
		// A plain open (the menu's Folders row, a new window) comes back to the
		// last folder read, on the machine it was read from. An explicit folder,
		// machine or command is the person's choice and always wins.
		if (seed_folder === undefined && seed_remote === undefined && data['command'] === undefined) {
			try {
				seed_folder = localStorage.getItem('folders_last_folder') || undefined;
				seed_remote = localStorage.getItem('folders_last_remote_uuid') || '';
			} catch (e) {}
		}
		tab = foldersNewTab(seed_folder, seed_remote, data['tab_id']);
		inst.tabs.push(tab);
		inst.active = inst.tabs.length - 1;
	}
	if (data['folder'] === undefined && tab.folder !== undefined) { data['folder'] = tab.folder; }
	if (data['remote_uuid'] === undefined) { data['remote_uuid'] = tab.remote_uuid || ''; }
	var remote_uuid = (data['remote_uuid'] !== undefined) ? data['remote_uuid'] : (tab.remote_uuid || '');
	var timestamp = Date.now();
	var previous_folder = tab.folder;
	var previous_remote = tab.remote_uuid;
	var history_mode = data['history'];
	var quiet = data['quiet'];
	var target_root = foldersRootFor(window_id);
	var previous_scroll = target_root.length ? (target_root.find('.folders_contents').scrollTop() || 0) : 0;
	var unlock = target_root.length
		? (target_root.attr('unlock') || '')
		: (data['new_window'] ? '' : ($('#folders').attr('unlock') || ''));
	$.ajax({
		url: '/manager/folders',
		type: 'POST',
		data: {
			timestamp: timestamp,
			window_id: window_id,
			tab_id: tab.id,
			folder: data['folder'],
			command: data['command'],
			remote_uuid: remote_uuid,
			device_uuid: (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : '',
			browser_tab_id: (typeof jawnosMediaTab === 'function') ? jawnosMediaTab() : '',
			// the window's own unlock token: a fresh open has none and stays
			// locked; the refresh after a phone signs carries the one it minted
			unlock: unlock
		},
		success: function(response) {
			var same_folder = (previous_folder !== undefined && response.fo.folder === previous_folder);
			var changed = (previous_folder !== undefined && response.fo.folder !== previous_folder);
			var machine_changed = (previous_remote !== undefined && previous_remote !== remote_uuid);
			windowMaker(response.html);
			var root = foldersRootFor(window_id);
			inst.root = root;
			tab.folder = response.fo.folder;
			tab.disk = response.fo.disk;
			tab.files = response.fo.files;
			tab.remote_uuid = remote_uuid;
			try {
				localStorage.setItem('folders_last_folder', response.fo.folder || '');
				localStorage.setItem('folders_last_remote_uuid', remote_uuid || '');
			} catch (e) {}
			tab.selected = [];
			tab.path = undefined;
			tab.type = undefined;
			tab.anchor = undefined;
			if (!response.unlocked) { root.attr('unlock', ''); }
			// A back/forward visit already moved the index; a new visit truncates
			// what was ahead and appends itself. A refresh of the same folder
			// leaves the trail alone.
			if (history_mode == 'skip') {
				if (tab.history_index >= 0 && tab.history.length) {
					tab.history[tab.history_index] = response.fo.folder;
				}
			}
			else {
				if (machine_changed) { tab.history = []; tab.history_index = -1; }
				if (!tab.history.length) {
					tab.history.push(response.fo.folder);
					tab.history_index = 0;
				}
				else if (changed) {
					tab.history = tab.history.slice(0, tab.history_index + 1);
					if (tab.history[tab.history.length - 1] !== response.fo.folder) {
						tab.history.push(response.fo.folder);
					}
					tab.history_index = tab.history.length - 1;
				}
				else if (tab.history[tab.history_index] !== response.fo.folder) {
					tab.history[tab.history_index] = response.fo.folder;
				}
				while (tab.history.length > 50) {
					tab.history.shift();
					tab.history_index--;
				}
			}
			var is_active = (folders && folders.window_id == window_id && folders.tab_id == tab.id);
			if (!quiet || is_active) {
				folders = tab;
				folders.window_id = window_id;
				folders.tab_id = tab.id;
				folders_last_window = window_id;
				foldersNormalizeIds(root);
				is_active = true;
			}
			else {
				foldersNormalizeIds(foldersRootFor(folders.window_id));
			}
			var scoped_root = foldersRootFor(window_id);
			var machine_select = scoped_root.find('.folders_machine_select');
			// A peer that has not been updated renders the listing without a row
			// for itself (it is "self" there). Keep the toolbar naming the machine
			// being read rather than letting the choice fall back to This machine.
			if (remote_uuid && !machine_select.find('option').filter(function () { return this.value === remote_uuid; }).length) {
				machine_select.append($('<option></option>').attr('value', remote_uuid).text(remote_uuid));
			}
			machine_select.val(remote_uuid);
			scoped_root.find('.folders_toolbar').attr('data-remote', remote_uuid ? 'yes' : '');
			foldersApplyView(scoped_root);
			foldersDraggable();
			if (is_active) {
				foldersSelectionSync('folders');
				foldersHistoryApply();
			}
			foldersApplyWindowName(inst);
			foldersTabsRender(inst);
			foldersSidebarApply(scoped_root);
			foldersObserveRoot(scoped_root);
			if (typeof appointment_chron == 'function') { appointment_chron(); }
			if (is_active) {
				if (same_folder) { scoped_root.find('.folders_contents').scrollTop(previous_scroll); }
				scoped_root.find('.folders_contents').focus();
			}
		}
	});
}

function foldersRefreshWindows() {
	var ids = [];
	$('.folders_app').each(function () { var inst = foldersInstanceFor(this); if (inst) { ids.push(inst.id); } });
	$.each(ids, function (i, id) {
		var inst = folders_instances[id];
		var tab = inst && inst.tabs[inst.active];
		if (!tab) { return; }
		foldersOpener({ window_id: id, tab_id: tab.id, folder: tab.folder, remote_uuid: tab.remote_uuid, history: 'skip', keep_tab: true, quiet: true });
	});
	if (typeof deskRefreshIfVisible == 'function') { deskRefreshIfVisible(); }
}

function foldersOpenInTab(folder, remote_uuid, window_id) {
	// an empty folder is Home: the server fills it in
	if (folder === undefined || folder === null) { return; }
	var inst = null;
	if (window_id) { inst = folders_instances[window_id] || null; }
	if (!inst && folders_last_window) { inst = folders_instances[folders_last_window] || null; }
	if (!inst) {
		foldersOpener({ new_window: true, folder: folder, remote_uuid: remote_uuid || '' });
		return;
	}
	var tab = foldersNewTab(folder, remote_uuid || '');
	inst.tabs.push(tab);
	inst.active = inst.tabs.length - 1;
	folders = tab;
	folders.window_id = inst.id;
	folders.tab_id = tab.id;
	foldersOpener({ window_id: inst.id, tab_id: tab.id, folder: folder, remote_uuid: remote_uuid || '', keep_tab: true });
}

function foldersOpenInWindow(folder, remote_uuid) {
	foldersOpener({ new_window: true, folder: folder, remote_uuid: remote_uuid || '' });
}

$(document).on('change', '#folders_machine_select', function () {
	// a new machine starts at its own home: this machine's paths mean nothing
	// over there, and neither does the trail that reached one of them
	foldersActivateFrom(this);
	folders.history = [];
	folders.history_index = -1;
	foldersOpener({ window_id: folders.window_id, tab_id: folders.tab_id, remote_uuid: $(this).val(), folder: '', keep_tab: true });
});

function foldersHistoryApply() {
	$('#folders_back').prop('disabled', !(folders.history && folders.history_index > 0));
	$('#folders_forward').prop('disabled', !(folders.history && folders.history_index >= 0 && folders.history_index < folders.history.length - 1));
}
function foldersHistoryMove(delta) {
	if (!folders.history || !folders.history.length) { return; }
	var next = folders.history_index + delta;
	if (next < 0 || next >= folders.history.length) { return; }
	folders.history_index = next;
	foldersOpener({ window_id: folders.window_id, tab_id: folders.tab_id, folder: folders.history[next], history: 'skip', keep_tab: true });
}
$(document).on('click', '#folders_back', function () { foldersActivateFrom(this); foldersHistoryMove(-1); });
$(document).on('click', '#folders_forward', function () { foldersActivateFrom(this); foldersHistoryMove(1); });

// ---- tabs ------------------------------------------------------------------
$(document).on('click', '.folders_tab', function (e) {
	if ($(e.target).closest('.folders_tab_close').length) { return; }
	var root = $(this).closest('.folders_app');
	var inst = foldersActivate(root);
	if (!inst) { return; }
	var id = $(this).attr('data-tab-id');
	$.each(inst.tabs, function (i, tab) {
		if (tab.id == id) { foldersSwitchTab(inst, i); return false; }
	});
});
$(document).on('click', '.folders_tab_close', function (e) {
	e.stopPropagation();
	var root = $(this).closest('.folders_app');
	var inst = foldersActivate(root);
	if (!inst) { return; }
	var id = $(this).closest('.folders_tab').attr('data-tab-id');
	$.each(inst.tabs, function (i, tab) {
		if (tab.id == id) { foldersCloseTab(inst, i); return false; }
	});
});
$(document).on('click', '.folders_tab_new', function () {
	var root = $(this).closest('.folders_app');
	var inst = foldersActivate(root);
	if (!inst) { return; }
	var tab = inst.tabs[inst.active];
	foldersOpenInTab('', tab ? tab.remote_uuid : '', inst.id);
});

function foldersSwitchTab(inst, index) {
	if (!inst || index < 0 || index >= inst.tabs.length) { return; }
	inst.active = index;
	var tab = inst.tabs[index];
	folders = tab;
	folders.window_id = inst.id;
	folders.tab_id = tab.id;
	foldersOpener({ window_id: inst.id, tab_id: tab.id, folder: tab.folder, remote_uuid: tab.remote_uuid, history: 'skip', keep_tab: true });
}

function foldersCloseTab(inst, index) {
	var tab = inst.tabs[index];
	if (!tab) { return; }
	if (inst.tabs.length <= 1) {
		var wind = inst.root.closest('.wind');
		var close = wind.find('.close_button');
		if (close.length) { close.trigger('click'); }
		else { wind.remove(); }
		delete folders_instances[inst.id];
		if (folders_last_window == inst.id) { folders_last_window = undefined; }
		return;
	}
	inst.tabs.splice(index, 1);
	if (index < inst.active) { inst.active--; }
	else if (index == inst.active) { inst.active = Math.min(index, inst.tabs.length - 1); }
	foldersSwitchTab(inst, inst.active);
}


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

// ---- sidebar ---------------------------------------------------------------
// One observer per window instance. The window's contents are replaced on every
// navigation, so the observer is re-made for the fresh root each time.
var folders_observers = {};
function foldersObserveRoot(root) {
	if (!root || !root.length || typeof ResizeObserver == 'undefined') { return; }
	var id = root.attr('data-folders-id');
	if (!id) { return; }
	var old = folders_observers[id];
	if (old) { try { old.disconnect(); } catch (e) { /* already gone */ } }
	var observer = new ResizeObserver(function () { foldersSidebarApply(root); });
	observer.observe(root[0]);
	folders_observers[id] = observer;
}
$(document).on('click', '#folders_sidebar_toggle', function () {
	foldersActivateFrom(this);
	var root = $(this).closest('.folders_app');
	var pref = localStorage.getItem('folders_sidebar');
	localStorage.setItem('folders_sidebar', pref == 'off' ? 'on' : 'off');
	foldersSidebarApply(root);
});
$(document).on('click', '.folders_sidebar_place', function () {
	var root = $(this).closest('.folders_app');
	foldersActivate(root);
	var path = $(this).attr('path');
	if (path) { foldersOpener({ folder: path }); }
});

// ---- drawers ---------------------------------------------------------------
$(document).on('click', '#folders_bookmarks_toggle', function () {
	foldersActivateFrom(this);
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
	foldersActivateFrom(this);
	var path = $(this).attr('path');
	$('#folders_bookmarks').hide();
	foldersOpener({ folder: path });
});

$(document).on('click', '#folders_archive_toggle', function () {
	foldersActivateFrom(this);
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
		items.not('.desk_place').addClass('selected');
		foldersSelectionSync(surface, items.not('.desk_place').last());
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
			else if (typeof appWindowOpener == 'function') { appWindowOpener(chosen.attr('app'), Date.now(), { visible: 'yes' }); }
			return;
		}
		if (chosen.length && chosen.hasClass('desk_place')) {
			foldersOpener({ folder: chosen.attr('path'), remote_uuid: '' });
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
		// Alt+Left/Right is the file-manager way back and forward through the
		// folders already visited; plain arrows walk the listing
		if (surface == 'folders' && e.altKey && (key == 'ArrowLeft' || key == 'ArrowRight')) {
			foldersHistoryMove((key == 'ArrowLeft') ? -1 : 1);
			return;
		}
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
