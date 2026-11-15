// The desk side of workspaces: a window belongs to the desk it was opened on,
// the pile it sits in belongs to that desk too, and switching desks hides one
// set and shows the other. shell_layout.js owns the layout and the bars; this
// file owns the windows and the switcher widget.
//
// Each workspace gets its own default pile id, so the hidden windows of one
// desk never number the slots of another. A window the person had minimised
// stays minimised when its desk comes back: `ws_visible` is the state it was
// left in, while the class marks the hide that belongs to the switch itself.

function jawnosWorkspaceActiveId() {
	if (typeof jawnosShellActiveWorkspace == 'function') {
		var ws = jawnosShellActiveWorkspace();
		if (ws && ws.id) { return ws.id; }
	}
	return 'ws-main';
}

function jawnosWorkspaceMainId() {
	if (typeof jawnosShellLayout == 'function') {
		var layout = jawnosShellLayout();
		if (layout.workspaces && layout.workspaces[0] && layout.workspaces[0].id) {
			return layout.workspaces[0].id;
		}
	}
	return 'ws-main';
}

// The default pile a desk opens a window into. The first desk keeps the old
// shared stack so its saved piles still restore; every other desk names its own.
function jawnosWorkspaceStackDefault(id) {
	id = id || jawnosWorkspaceActiveId();
	return (id && id != jawnosWorkspaceMainId()) ? ('ws-' + id) : windowTiledDefaultStack;
}

// The pile a window belongs to, whether it set one when it joined a pile or is
// still falling back to its desk's default.
function jawnosWorkspaceWindowStack(win) {
	var stack = $(win).attr('stack');
	if (stack !== undefined && stack !== null && stack !== '') { return String(stack); }
	return jawnosWorkspaceStackDefault($(win).attr('workspace') || jawnosWorkspaceActiveId());
}

// A window carries the desk it was opened on. The stored record is the truth
// for a restored window; a fresh one belongs to the desk in front.
function jawnosWorkspaceWindowTag(win, id) {
	win = (win && win.jquery) ? win : $(win);
	if (!win.length) { return ''; }
	id = id || win.attr('workspace') || jawnosWorkspaceActiveId();
	win.attr('workspace', id);
	if (!win.attr('stack')) {
		var stack = jawnosWorkspaceStackDefault(id);
		if (stack != windowTiledDefaultStack) { win.attr('stack', stack); }
	}
	if (!win.attr('ws_visible')) {
		win.attr('ws_visible', win.is(':visible') ? 'yes' : 'no');
	}
	return id;
}

// Read the saved record for a window that is being restored. A window opened
// for the first time has none and takes the desk in front; a saved one carries
// its desk and its pile, including a legacy main-desk stack that has to be
// lifted to the desk it is restored into.
function jawnosWorkspaceWindowNew(win) {
	win = (win && win.jquery) ? win : $(win);
	if (!win.length) { return; }
	var stored = {};
	try {
		var all = JSON.parse(sessionStorage.getItem('window_storage') || '{}') || {};
		stored = all[win.attr('app') || ''] || {};
	}
	catch (e) { stored = {}; }
	var id = stored.workspace || jawnosWorkspaceActiveId();
	if (stored.stack !== undefined && stored.stack !== null && stored.stack !== ''
		&& String(stored.stack) != windowTiledDefaultStack) {
		win.attr('stack', String(stored.stack));
	}
	else if (id != jawnosWorkspaceMainId()) {
		win.attr('stack', jawnosWorkspaceStackDefault(id));
	}
	jawnosWorkspaceWindowTag(win, id);
	if (stored.ws_visible == 'yes' || stored.ws_visible == 'no') {
		win.attr('ws_visible', stored.ws_visible);
	}
	jawnosWorkspaceWindowApplyOne(win);
}

// A window restored through an opener rather than the generic window maker:
// apply the saved desk and the saved visibility once its own opener has shown
// or hidden it.
function jawnosWorkspaceWindowRestore(win, v) {
	win = (win && win.jquery) ? win : $(win);
	if (!win.length) { return; }
	var id = (v && v.workspace) || win.attr('workspace') || jawnosWorkspaceActiveId();
	win.attr('workspace', id);
	if (v && (v.ws_visible == 'yes' || v.ws_visible == 'no')) {
		win.attr('ws_visible', v.ws_visible);
	}
	else if (!win.attr('ws_visible')) {
		win.attr('ws_visible', win.is(':visible') ? 'yes' : 'no');
	}
	if (v && v.stack !== undefined && v.stack !== null && v.stack !== ''
		&& String(v.stack) != windowTiledDefaultStack) {
		win.attr('stack', String(v.stack));
	}
	else if (!win.attr('stack') && id != jawnosWorkspaceMainId()) {
		win.attr('stack', jawnosWorkspaceStackDefault(id));
	}
	jawnosWorkspaceWindowApplyOne(win);
}

// Is this window's desk the one in front? A window with no desk yet belongs to
// the one in front, which is what a restore of an old record means.
function jawnosWorkspaceWindowHere(win) {
	win = (win && win.jquery) ? win : $(win);
	var id = win.attr('workspace') || jawnosWorkspaceActiveId();
	return id == jawnosWorkspaceActiveId();
}

// Put one window in the state its desk and its own minimise say it should be.
// The class marks a hide this switcher made, so a switch never mistakes a
// window the person minimised for one it put away.
function jawnosWorkspaceWindowApplyOne(win) {
	win = (win && win.jquery) ? win : $(win);
	if (!win.length) { return; }
	if (!win.attr('ws_visible')) {
		win.attr('ws_visible', win.is(':visible') ? 'yes' : 'no');
	}
	var here = jawnosWorkspaceWindowHere(win);
	if (!here) {
		if (!win.hasClass('jawnos_ws_away')) {
			// First move away from this desk: the state on screen is the one to
			// remember. Later switches leave it alone.
			win.attr('ws_visible', win.is(':visible') ? 'yes' : 'no');
			win.addClass('jawnos_ws_away');
		}
		win.hide();
		return;
	}
	if (!win.hasClass('jawnos_ws_away')) { return; }
	win.removeClass('jawnos_ws_away');
	if (win.attr('ws_visible') == 'no') { win.hide(); }
	else { win.show(); }
}

// Lay every window back on its own desk after the active desk changes: hide the
// ones that are not here, and give the ones that are their own state back.
function jawnosWorkspaceApplyWindows() {
	$('.wind').each(function () {
		var win = $(this);
		if (!win.attr('workspace')) { jawnosWorkspaceWindowTag(win); }
		jawnosWorkspaceWindowApplyOne(win);
	});
}

// Send a window to another desk. A tiled window joins that desk's own pile; a
// pinned, maximized or free one keeps the place it has. It leaves its old pile
// closed behind it and waits on the target desk in the state it was in.
function jawnosWorkspaceWindowMove(win, target) {
	win = (win && win.jquery) ? win : $(win);
	if (!win.length) { return; }
	var layout = jawnosShellLayout();
	var to = null;
	$.each(layout.workspaces || [], function (i, ws) { if (ws && ws.id == target) { to = ws; } });
	if (!to || to.kind == 'peer' || to.id == jawnosWorkspaceActiveId()) { return; }
	var state = win.hasClass('jawnos_ws_away') ? (win.attr('ws_visible') || 'no') : (win.is(':visible') ? 'yes' : 'no');
	var free = win.attr('free') == '1';
	var keep = free
		|| win.attr('pre_dimensioned') == '1'
		|| win.attr('view') == 'max' || win.attr('view') == 'left' || win.attr('view') == 'right'
		|| (typeof windowPlaceIsLocked == 'function' && windowPlaceIsLocked(win));
	// Close the slot it held on the desk it is leaving.
	if (typeof windowTiledLeave == 'function') { windowTiledLeave(win, free); }
	win.attr('workspace', to.id).attr('ws_visible', state);
	win.removeAttr('tile').removeAttr('stack_at');
	if (keep) {
		win.removeAttr('stack');
		if (free) { win.attr('free', '1'); }
	}
	else {
		var stack = jawnosWorkspaceStackDefault(to.id);
		if (stack != windowTiledDefaultStack) { win.attr('stack', stack); }
		else { win.removeAttr('stack'); }
		if (typeof windowTiledInsertAt == 'function' && typeof windowNextTileSlot == 'function') {
			windowTiledInsertAt(win, windowNextTileSlot(stack), stack);
		}
	}
	// It is on the other desk now, and waits there in the state it had.
	win.addClass('jawnos_ws_away').hide();
	if (typeof jawnosWorkspaceApplyWindows == 'function') { jawnosWorkspaceApplyWindows(); }
	if (typeof taskbarDisplayer == 'function') { taskbarDisplayer(); }
	if (typeof jawnosDockWindowsRender == 'function') { jawnosDockWindowsRender(); }
	if (typeof windowSaver == 'function') { windowSaver(); }
	if (typeof jawnosWorkspaceWidgetSync == 'function') { jawnosWorkspaceWidgetSync(); }
}

// ---- the switcher widget ---------------------------------------------------

function jawnosWorkspaceWidgetSync() {
	var widget = $('#taskbar_workspaces');
	if (!widget.length) { return; }
	var layout = jawnosShellLayout();
	var active = jawnosShellActiveWorkspace();
	var at = 0;
	$.each(layout.workspaces, function (i, ws) { if (ws.id == active.id) { at = i; } });
	var glyph = widget.find('.taskbar_workspaces_glyph').empty();
	$.each(layout.workspaces.slice(0, jawnosShellMaxWorkspaces), function (i, ws) {
		var dot = $('<i></i>');
		if (i == at) { dot.addClass('on'); }
		if (ws.kind == 'peer') { dot.addClass('peer'); }
		else if (ws.kind == 'room') { dot.addClass('room'); }
		glyph.append(dot);
	});
	var name = (active && active.name) ? active.name : jawnosT('Workspace');
	widget.attr('state', layout.workspaces.length > 1 ? 'multi' : 'single');
	widget.attr('title', jawnosT('Workspaces') + ' — ' + name + ' (' + (at + 1) + '/' + layout.workspaces.length + ')');
	widget.find('.taskbar_workspaces_text').text(name);
	widget.removeAttr('hidden').show();
}

// ---- saved rooms and peer machines -----------------------------------------
// The console's named rooms and the house's other machines are the two sources a
// desk can be made from. Both are read once per page and cached; a desk is made
// on demand, and a second press on the same source returns to its desk.
var jawnosWorkspaceSources = { rooms: null, machines: null, loading: false, at: 0 };

function jawnosWorkspaceSourcesLoad() {
	if (jawnosWorkspaceSources.loading) { return; }
	jawnosWorkspaceSources.loading = true;
	jawnosWorkspaceSources.at = Date.now();
	var pending = 2;
	var done = function () {
		if (--pending > 0) { return; }
		jawnosWorkspaceSources.loading = false;
		// The panel may have been rebuilt while the reads were out; rebuild the
		// one on the page rather than the detached copy this call started with.
		jawnosWorkspaceWidgetPanelRebuild();
	};
	$.getJSON('/manager/shell/rooms', function (response) {
		jawnosWorkspaceSources.rooms = (response && response.rooms) || [];
	}).fail(function () { jawnosWorkspaceSources.rooms = []; }).always(done);
	$.getJSON('/manager/shell/machines', function (response) {
		jawnosWorkspaceSources.machines = (response && response.machines) || [];
	}).fail(function () { jawnosWorkspaceSources.machines = []; }).always(done);
}

// A room becomes a desk once; a press on the same room again returns to it.
function jawnosWorkspaceRoomDesk(room) {
	if (!room || !room.name) { return; }
	var layout = jawnosShellLayout();
	var found = null;
	$.each(layout.workspaces, function (i, ws) {
		if (ws.kind == 'room' && ws.room && ws.room.name == room.name) { found = ws; }
	});
	if (found) { jawnosShellWorkspaceSet(found.id); return; }
	if (layout.workspaces.length >= jawnosShellMaxWorkspaces) { return; }
	var ws = jawnosShellWorkspaceAdd('room', {
		name: room.name,
		room: { name: room.name, timestamp: room.timestamp }
	});
	if (ws) { jawnosWorkspaceRoomEnter(ws); }
}

// The console's own recall call, with the room's window set handed to the
// retriever. The windows are stamped with this desk so they come back here.
function jawnosWorkspaceRoomEnter(ws) {
	if (!ws || !ws.room || !ws.room.timestamp) { return; }
	$.ajax({
		url: '/manager/past_life_recall',
		type: 'GET',
		data: { direction: 'load', timestamp: ws.room.timestamp },
		success: function (response) {
			var json = response && response.json_windows;
			if (!json) { return; }
			var parsed = {};
			try { parsed = JSON.parse(json) || {}; } catch (e) { parsed = {}; }
			$.each(parsed, function (k, v) {
				if (!v || v.type != 'window') { return; }
				v.workspace = ws.id;
				// A legacy main-desk pile is lifted to this desk's own pile.
				if (v.stack === undefined || v.stack === null || v.stack === ''
					|| String(v.stack) == windowTiledDefaultStack) {
					v.stack = jawnosWorkspaceStackDefault(ws.id);
				}
			});
			if (typeof windowRetriever == 'function') { windowRetriever(JSON.stringify(parsed)); }
			if (typeof portfolioMaker == 'function' && response.portfolio) { portfolioMaker(response.portfolio); }
			// The console's room recall also carries the view to the moment the
			// room was saved; this desk keeps that reading too.
			if (typeof quality_inventory == 'function') {
				var zone = quality_inventory(ws.room.timestamp);
				if (zone) {
					sessionStorage.setItem('time_machine', zone);
					if ($('#time_machine').length) { $('#time_machine').val(zone); }
				}
			}
			setTimeout(function () {
				if (typeof jawnosWorkspaceApplyWindows == 'function') { jawnosWorkspaceApplyWindows(); }
			}, 0);
		}
	});
}

// A machine becomes a desk whose live Manager is opened in its own window; the
// local desk stays empty and is the way back.
function jawnosWorkspaceMachineDesk(machine) {
	if (!machine || (!machine.uuid && !machine.manager)) { return; }
	var layout = jawnosShellLayout();
	var found = null;
	$.each(layout.workspaces, function (i, ws) {
		if (ws.kind != 'peer' || !ws.peer) { return; }
		if (machine.uuid && ws.peer.uuid == machine.uuid) { found = ws; }
		else if (!found && machine.manager && ws.peer.manager == machine.manager) { found = ws; }
	});
	if (found) {
		// WorkspaceSet opens the peer's Manager for a peer desk.
		jawnosShellWorkspaceSet(found.id);
		return;
	}
	if (layout.workspaces.length >= jawnosShellMaxWorkspaces) { return; }
	var ws = jawnosShellWorkspaceAdd('peer', {
		name: machine.hostname || machine.device || machine.uuid || machine.manager,
		peer: { uuid: machine.uuid || '', manager: machine.manager || '', hostname: machine.hostname || '' }
	});
	if (!ws) { return; }
	if (typeof jawnosRemoteManagerOpen == 'function') {
		jawnosRemoteManagerOpen(machine.uuid || '', machine.manager || '');
	}
}

function jawnosWorkspaceWidgetPanelBuild(panel) {
	if (!panel || !panel.length) { return; }
	panel.empty();
	var layout = jawnosShellLayout();
	var active = jawnosShellActiveWorkspace();
	var section = $('<div class="taskbar_panel_section"></div>');
	section.append($('<h4></h4>').text(jawnosT('Workspaces')));
	$.each(layout.workspaces, function (i, ws) {
		var row = $('<button type="button" class="taskbar_panel_row taskbar_panel_workspace"></button>')
			.attr('data-workspace', ws.id)
			.attr('aria-pressed', ws.id == active.id ? 'true' : 'false');
		if (ws.id == active.id) { row.addClass('taskbar_panel_active'); }
		row.append($('<span class="taskbar_panel_label"></span>').text(ws.name || jawnosT('Workspace')));
		if (ws.kind == 'peer') { row.append($('<span class="taskbar_panel_badge"></span>').text(jawnosT('Remote'))); }
		else if (ws.kind == 'room') { row.append($('<span class="taskbar_panel_badge"></span>').text(jawnosT('Saved'))); }
		section.append(row);
	});
	if (layout.workspaces.length < jawnosShellMaxWorkspaces) {
		section.append($('<button type="button" class="taskbar_panel_open" data-workspace-add="1"></button>').text(jawnosT('Add workspace')));
	}
	else {
		section.append($('<p class="taskbar_panel_note"></p>').text(jawnosT('Seven workspaces is the most')));
	}
	if (layout.workspaces.length > 1 && active.id != layout.workspaces[0].id) {
		section.append($('<button type="button" class="taskbar_panel_open" data-workspace-remove="1"></button>').text(jawnosT('Remove this workspace')));
	}
	panel.append(section);

	// Saved rooms from the console.
	var saved = $('<div class="taskbar_panel_section"></div>');
	saved.append($('<h4></h4>').text(jawnosT('Saved')));
	var rooms = jawnosWorkspaceSources.rooms;
	if (rooms === null) {
		saved.append($('<p class="taskbar_panel_empty"></p>').text(jawnosT('Loading…')));
	}
	else if (!rooms.length) {
		saved.append($('<p class="taskbar_panel_empty"></p>').text(jawnosT('No saved rooms')));
	}
	else {
		$.each(rooms, function (i, room) {
			var row = $('<button type="button" class="taskbar_panel_row taskbar_panel_workspace"></button>')
				.attr('data-room-index', i);
			row.append($('<span class="taskbar_panel_label"></span>').text(room.name));
			row.append($('<span class="taskbar_panel_value"></span>').text(room.windows || 0));
			saved.append(row);
		});
	}
	panel.append(saved);

	// The other machines in the house.
	var machines = $('<div class="taskbar_panel_section"></div>');
	machines.append($('<h4></h4>').text(jawnosT('Machines')));
	var peers = jawnosWorkspaceSources.machines;
	if (peers === null) {
		machines.append($('<p class="taskbar_panel_empty"></p>').text(jawnosT('Loading…')));
	}
	else if (!peers.length) {
		machines.append($('<p class="taskbar_panel_empty"></p>').text(jawnosT('No machines')));
	}
	else {
		$.each(peers, function (i, machine) {
			var row = $('<button type="button" class="taskbar_panel_row taskbar_panel_workspace"></button>')
				.attr('data-machine-index', i);
			row.append($('<span class="taskbar_panel_dot"></span>').attr('data-online', machine.online ? '1' : '0'));
			row.append($('<span class="taskbar_panel_label"></span>').text(machine.hostname || machine.device || machine.uuid || machine.manager));
			if (machine.device) {
				row.append($('<span class="taskbar_panel_badge"></span>').text(jawnosT(machine.device)));
			}
			machines.append(row);
		});
	}
	panel.append(machines);

	if (jawnosWorkspaceSources.rooms === null || jawnosWorkspaceSources.machines === null
		|| Date.now() - jawnosWorkspaceSources.at > 30000) {
		jawnosWorkspaceSourcesLoad();
	}
}

function jawnosWorkspaceWidgetPanelRebuild() {
	var panel = $('#taskbar_workspaces_panel');
	if (panel.length) { jawnosWorkspaceWidgetPanelBuild(panel); }
}

// Every bar carries a copy of the widget, and a copy has no id: the handler is
// bound by the widget's name so the switcher answers from any desk's bar.
$(document).on('click', '.taskbar_widget[widget="workspaces"]', function () {
	if (typeof jawnosTaskbarEditing == 'function' && jawnosTaskbarEditing()) { return; }
	if (typeof jawnosTaskbarPanelToggle != 'function') { return; }
	jawnosTaskbarPanelToggle('taskbar_workspaces_panel', $(this), jawnosWorkspaceWidgetPanelBuild);
});

$(document).on('click', '#taskbar_workspaces_panel [data-workspace]', function () {
	jawnosShellWorkspaceSet($(this).attr('data-workspace'));
	jawnosWorkspaceWidgetPanelRebuild();
});

$(document).on('click', '#taskbar_workspaces_panel [data-workspace-add]', function () {
	jawnosShellWorkspaceAdd();
	jawnosWorkspaceWidgetPanelRebuild();
});

$(document).on('click', '#taskbar_workspaces_panel [data-workspace-remove]', function () {
	var active = jawnosShellActiveWorkspace();
	if (active) { jawnosShellWorkspaceRemove(active.id); }
	jawnosWorkspaceWidgetPanelRebuild();
});

$(document).on('click', '#taskbar_workspaces_panel [data-room-index]', function () {
	var i = parseInt($(this).attr('data-room-index'), 10);
	var rooms = jawnosWorkspaceSources.rooms || [];
	if (rooms[i]) { jawnosWorkspaceRoomDesk(rooms[i]); }
	jawnosWorkspaceWidgetPanelRebuild();
});

$(document).on('click', '#taskbar_workspaces_panel [data-machine-index]', function () {
	var i = parseInt($(this).attr('data-machine-index'), 10);
	var machines = jawnosWorkspaceSources.machines || [];
	if (machines[i]) { jawnosWorkspaceMachineDesk(machines[i]); }
	jawnosWorkspaceWidgetPanelRebuild();
});

$(function () {
	if (typeof jawnosWorkspaceWidgetSync == 'function') { jawnosWorkspaceWidgetSync(); }
});
