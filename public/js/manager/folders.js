/* [[js-split]]
   folders.js is part 1. The rest live in folders/ in name order:
     01_view_and_commands.js  - view, selection, marquee, drag and drop, opening, context menu and commands
     02_archive_and_keyboard.js  - drawers, jobs, archive, sidebar, drawers and keyboard handling
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
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
	show_hidden: 0,
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
	show_hidden: 0,
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

// Dotfiles are hidden by default. The background menu toggles them for every
// Folders window and remembers the choice on this screen.
function foldersShowHidden() {
	try { return localStorage.getItem('folders_show_hidden') === 'yes' ? 1 : 0; } catch (e) { return 0; }
}
function foldersToggleHidden() {
	var on = foldersShowHidden() ? 0 : 1;
	try { localStorage.setItem('folders_show_hidden', on ? 'yes' : 'no'); } catch (e) {}
	$.each(folders_instances, function (id, inst) {
		$.each(inst.tabs || [], function (i, tab) { tab.show_hidden = on; });
	});
	desk.show_hidden = on;
	folders.show_hidden = on;
	foldersRefreshWindows();
}

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
		show_hidden: foldersShowHidden(),
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

// The same presentation the server gives the address bar and the title bar
// (subs::format_name): underscores read as spaces and each word is capitalised.
// It is for the eye only - paths, history and commands keep the real name.
function foldersFormatName(name) {
	var words = String(name || '').toLowerCase().replace(/_/g, ' ').split(/\s+/).filter(Boolean);
	return words.map(function (word) { return word.charAt(0).toUpperCase() + word.slice(1); }).join(' ');
}

function foldersApplyWindowName(inst) {
	if (!inst || !inst.root || !inst.root.length) { return; }
	var tab = inst.tabs[inst.active];
	var folder = (tab && tab.folder) ? tab.folder : '';
	var wind = inst.root.closest('.wind');
	if (!wind.length) { return; }
	// the bar names the folder being read, not its whole path, in the address
	// bar's own words
	var label = (tab && tab.display_name) ? tab.display_name : (folder ? foldersFormatName(foldersTabLabel(folder)) : '');
	var name = jawnosT('Folders') + (label ? ' - ' + label : '');
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
		$('<span class="folders_tab_label"></span>').text((tab.place == 'cloud') ? jawnosT('CloudSync') : foldersTabLabel(tab.folder)).appendTo(button);
		$('<span class="folders_tab_close" aria-label="' + jawnosT('Close') + '">×</span>').appendTo(button);
		bar.append(button);
	});
	bar.append($('<button type="button" class="folders_tab_new" aria-label="' + jawnosT('New tab') + '">+</button>'));
}

function foldersSidebarApply(root) {
	root = (root && root.length) ? root : foldersRoot();
	if (!root.length) { return; }
	// Places needs 176px beside the listing. A wide window keeps it open by
	// itself; a thin one shows the toolbar button, and the button opens the same
	// column over the listing so CloudSync stays reachable.
	var wide = root.width() >= 720;
	var pref = localStorage.getItem('folders_sidebar');
	var show = wide || pref == 'on';
	root.toggleClass('folders_sidebar_overlay', !wide && show);
	root.find('.folders_sidebar').toggle(show);
	root.find('.folders_sidebar_toggle').toggle(!wide).attr('data-on', show ? 'yes' : 'no');
}

// A place was chosen: on a thin window the overlay has done its job, so put it
// away and remember that. A wide window keeps its column where it is.
function foldersSidebarClose(root) {
	root = (root && root.length) ? root : foldersRoot();
	if (!root.length || root.width() >= 720) { return; }
	try { localStorage.setItem('folders_sidebar', 'off'); } catch (e) {}
	foldersSidebarApply(root);
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
	if (data['show_hidden'] !== undefined) { tab.show_hidden = data['show_hidden'] ? 1 : 0; }
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
			show_hidden: (tab.show_hidden ? 1 : 0),
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
			tab.place = undefined;
			tab.display_name = response.fo.display_name || '';
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


