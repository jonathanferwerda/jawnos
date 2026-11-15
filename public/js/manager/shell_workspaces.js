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

$(function () {
	if (typeof jawnosWorkspaceWidgetSync == 'function') { jawnosWorkspaceWidgetSync(); }
});
