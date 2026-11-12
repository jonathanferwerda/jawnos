// The shell layer: more than one workspace, more than one taskbar, more than
// one dock. The first pair of bars are the ones the layout always drew, and they
// keep their ids and their legacy edge settings. Every bar beyond them is a
// descriptor in the shell_layout misc setting: which workspace it belongs to,
// whether it is locked to an edge or floating, and where it stands.
//
// The bars share the desk's content for now. Every taskbar shows the same open
// windows, the same pins and the same live widget readings; every dock shows the
// same faces. What belongs to a bar alone is its place: an edge, or a floating
// box. That is the part this file owns, together with the edit-mode handle that
// drags a bar to an edge (a lock) or away from one (a float).
//
// taskbar.js calls jawnosShellApply() at the end of every jawnosBarsApply(), so
// the legacy edge rules run first and a floating bar is never pulled back.

var jawnosShell = {
	layout: null,
	syncing: false,
	drag: null
};

var jawnosShellEdges = ['bottom', 'top', 'left', 'right'];
var jawnosShellSnapDistance = 48;

function jawnosShellPrimaryId(kind) {
	return kind == 'taskbar' ? 'bar-taskbar-main' : 'bar-dock-main';
}

function jawnosShellNewId(kind) {
	return 'bar-' + kind + '-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 7);
}

function jawnosShellText(text) {
	return (typeof jawnosT == 'function') ? jawnosT(text) : text;
}

// The setting rides as JSON in the layout; accept an object too, because the
// template embeds it parsed while an older or hand-set value may be text.
function jawnosShellParse(raw) {
	if (!raw) { return null; }
	if (typeof raw == 'object') { return raw; }
	if (typeof raw == 'string' && raw.length) {
		try { return JSON.parse(raw); }
		catch (e) { return null; }
	}
	return null;
}

function jawnosShellLegacyEdge(kind) {
	var value = (typeof jawnosBars != 'undefined')
		? (kind == 'taskbar' ? jawnosBars.taskbar : jawnosBars.dock)
		: 'bottom';
	return value || 'bottom';
}

// The starting layout: one workspace holding the two bars the page already has,
// on the edges their legacy settings name.
function jawnosShellSeed() {
	var taskbar_edge = jawnosShellLegacyEdge('taskbar');
	var dock_edge = jawnosShellLegacyEdge('dock');
	var taskbar = {
		id: jawnosShellPrimaryId('taskbar'), kind: 'taskbar', primary: true,
		mode: taskbar_edge == 'floating' ? 'floating' : 'edge',
		edge: taskbar_edge == 'floating' ? 'bottom' : taskbar_edge
	};
	var dock = {
		id: jawnosShellPrimaryId('dock'), kind: 'dock', primary: true,
		mode: dock_edge == 'floating' ? 'floating' : 'edge',
		edge: dock_edge == 'floating' ? 'bottom' : dock_edge
	};
	return {
		version: 1,
		active: 'ws-main',
		workspaces: [
			{ id: 'ws-main', name: 'Main', bars: [taskbar, dock] }
		]
	};
}

// Fill in anything a hand-edited or older layout leaves out. The first pair is
// always present somewhere: without a taskbar there is no menu to add one from.
function jawnosShellNormalize(layout) {
	if (!layout || typeof layout != 'object' || !Array.isArray(layout.workspaces) || !layout.workspaces.length) {
		layout = jawnosShellSeed();
	}
	layout.version = 1;
	layout.workspaces = $.grep(layout.workspaces, function (ws) {
		return ws && typeof ws == 'object';
	});
	if (!layout.workspaces.length) { layout.workspaces = jawnosShellSeed().workspaces; }
	$.each(layout.workspaces, function (i, ws) {
		if (!ws.id) { ws.id = 'ws-' + i + '-' + Date.now().toString(36); }
		if (!ws.name) { ws.name = i ? ('Workspace ' + (i + 1)) : 'Main'; }
		if (!Array.isArray(ws.bars)) { ws.bars = []; }
		ws.bars = $.grep(ws.bars, function (bar) {
			return bar && typeof bar == 'object' && bar.id && (bar.kind == 'taskbar' || bar.kind == 'dock');
		});
		$.each(ws.bars, function (j, bar) {
			if (bar.mode != 'floating') { bar.mode = 'edge'; }
			if (!bar.edge || $.inArray(bar.edge, ['bottom', 'top', 'left', 'right', 'hidden']) < 0) { bar.edge = 'bottom'; }
		});
	});
	var found = { taskbar: null, dock: null };
	$.each(layout.workspaces, function (i, ws) {
		$.each(ws.bars, function (j, bar) {
			if (bar.primary && found[bar.kind]) { bar.primary = false; }
			else if (bar.primary) { found[bar.kind] = ws; }
		});
	});
	$.each(['taskbar', 'dock'], function (i, kind) {
		if (found[kind]) { return; }
		var edge = jawnosShellLegacyEdge(kind);
		layout.workspaces[0].bars.unshift({
			id: jawnosShellPrimaryId(kind), kind: kind, primary: true,
			mode: edge == 'floating' ? 'floating' : 'edge',
			edge: edge == 'floating' ? 'bottom' : edge
		});
	});
	var active = null;
	$.each(layout.workspaces, function (i, ws) { if (ws.id == layout.active) { active = ws; } });
	if (!active) { layout.active = layout.workspaces[0].id; }
	return layout;
}

function jawnosShellLayout() {
	if (!jawnosShell.layout) {
		var raw = (typeof jawnos_bar_settings != 'undefined' && jawnos_bar_settings) ? jawnos_bar_settings.shell_layout : null;
		jawnosShell.layout = jawnosShellNormalize(jawnosShellParse(raw) || jawnosShellSeed());
	}
	jawnosShellNormalize(jawnosShell.layout);
	return jawnosShell.layout;
}

function jawnosShellSave() {
	var layout = jawnosShellLayout();
	var text = JSON.stringify(layout);
	if (typeof jawnos_bar_settings != 'undefined' && jawnos_bar_settings) { jawnos_bar_settings.shell_layout = text; }
	if (typeof jawnosTaskbarSave == 'function') { jawnosTaskbarSave('shell_layout', text); }
}

function jawnosShellActiveWorkspace() {
	var layout = jawnosShellLayout();
	var active = null;
	$.each(layout.workspaces, function (i, ws) { if (ws.id == layout.active) { active = ws; } });
	return active || layout.workspaces[0];
}

// The workspace and descriptor a bar id names, or null.
function jawnosShellBarFound(id) {
	if (!id) { return null; }
	var layout = jawnosShellLayout();
	var found = null;
	$.each(layout.workspaces, function (i, ws) {
		$.each(ws.bars, function (j, bar) {
			if (bar.id == id && !found) { found = { workspace: ws, bar: bar }; }
		});
	});
	return found;
}

function jawnosShellBarGet(id) {
	var found = jawnosShellBarFound(id);
	return found ? found.bar : null;
}

function jawnosShellBarIsPrimary(id) {
	var bar = jawnosShellBarGet(id);
	return !!(bar && bar.primary);
}

function jawnosShellBarEl(id) {
	return $('.jawnos_bar').filter(function () { return $(this).attr('data-bar-id') == id; }).first();
}

// The two bars the template drew keep their ids and their legacy settings; the
// shell only names them so the rest of this file can find them.
function jawnosShellMarkPrimary() {
	var taskbar = $('#taskbar');
	if (taskbar.length) {
		taskbar.addClass('jawnos_bar jawnos_taskbar')
			.attr('data-bar-kind', 'taskbar')
			.attr('data-bar-primary', '1')
			.attr('data-bar-id', jawnosShellPrimaryId('taskbar'));
	}
	var dock = $('#pseudonym_home');
	if (dock.length) {
		dock.addClass('jawnos_bar jawnos_dock')
			.attr('data-bar-kind', 'dock')
			.attr('data-bar-primary', '1')
			.attr('data-bar-id', jawnosShellPrimaryId('dock'));
	}
}

// The drag handle: the bar's own grip, on its left edge, shown only while that
// kind of bar is in edit mode (the CSS reads taskbar_edit / dock_edit).
function jawnosShellHandleEnsure(el) {
	el = $(el);
	if (!el.length || el.children('.jawnos_bar_handle').length) { return; }
	var hint = jawnosShellText('Drag this bar: drop it on an edge to lock it there, or anywhere else to float it');
	var handle = $('<span class="jawnos_bar_handle" role="button" tabindex="0"></span>')
		.attr('hint', hint)
		.attr('aria-label', hint)
		.text('⠿');
	el.prepend(handle);
}

// Build the DOM for a descriptor that has none yet. The first pair is already in
// the page; every other bar is a small, fixed arrangement of the same slots the
// primary bar carries, filled by the sync passes below.
function jawnosShellBarBuild(desc, workspace) {
	if (desc.primary || jawnosShellBarEl(desc.id).length) { return; }
	var el;
	if (desc.kind == 'taskbar') {
		el = $('<div class="jawnos_bar jawnos_taskbar theme_surface_soft" data-bar-kind="taskbar" data-bar-primary="0"></div>');
		el.append('<span class="taskbar_windows" data-role="windows"></span>');
		el.append('<span class="taskbar_widgets" data-role="widgets"></span>');
		el.append('<span class="taskbar_pins" data-role="pins"></span>');
		el.append('<span class="taskbar_clock" data-role="clock"></span>');
	}
	else {
		el = $('<div class="jawnos_bar jawnos_dock theme_surface" data-bar-kind="dock" data-bar-primary="0"></div>');
		el.append('<span class="pseudonym_bar"></span>');
	}
	el.attr('data-bar-id', desc.id)
		.attr('data-workspace', workspace.id)
		.addClass('jawnos_workspace_off');
	$('body').append(el);
	jawnosShellHandleEnsure(el);
}

// Put a bar where its descriptor says: an edge (the lock) or a floating box.
// The first pair's edge placement stays with the legacy CSS and the dock's own
// free-space maths; only a floating first pair is placed here, and the dock's
// finder is wrapped at the foot of this file to leave it alone.
function jawnosShellPlace(el, desc) {
	var mode = desc.mode == 'floating' ? 'floating' : 'edge';
	var edge = desc.edge || 'bottom';
	el.attr('data-bar-mode', mode);
	el.attr('data-edge', mode == 'floating' ? 'floating' : edge);
	// the first pair keeps its own placement: the legacy CSS (taskbar) and the
	// dock's free-space maths own their edge, and clearing it here would undo
	// the left the dock's finder just wrote
	if (desc.primary && mode == 'edge') {
		el.attr('position', edge);
		return;
	}
	el.css({ left: '', right: '', top: '', bottom: '', width: '', height: '', transform: '' });
	if (mode == 'floating') {
		var w = parseInt(desc.w, 10) || (desc.kind == 'taskbar' ? 560 : 360);
		var h = parseInt(desc.h, 10) || (desc.kind == 'taskbar' ? 44 : 120);
		var x = (typeof desc.x == 'number') ? desc.x : Math.max(8, ($(window).width() - w) / 2);
		var y = (typeof desc.y == 'number') ? desc.y : Math.max(8, ($(window).height() - h) / 2);
		el.attr('position', 'floating');
		el.css({
			left: Math.max(0, x) + 'px',
			top: Math.max(0, y) + 'px',
			right: 'auto',
			bottom: 'auto',
			width: Math.min(w, $(window).width()) + 'px',
			height: Math.min(h, $(window).height()) + 'px'
		});
		return;
	}
	el.attr('position', edge);
	// the first pair keeps its own placement; the CSS owns both of them
	if (desc.primary) { return; }
}

// The primary descriptors follow the legacy position settings, which the context
// menu, the configure panel and a drag all still write. A change keeps the saved
// layout in step without a settings write on every layout pass.
function jawnosShellPrimarySync() {
	if (typeof jawnosBars == 'undefined') { return; }
	var changed = false;
	$.each([['taskbar', jawnosBars.taskbar], ['dock', jawnosBars.dock]], function (i, pair) {
		var desc = jawnosShellBarGet(jawnosShellPrimaryId(pair[0]));
		if (!desc) { return; }
		var edge = pair[1] || 'bottom';
		if (edge == 'floating') {
			if (desc.mode != 'floating') { desc.mode = 'floating'; changed = true; }
		}
		else if (desc.mode != 'edge' || desc.edge != edge) {
			desc.mode = 'edge';
			desc.edge = edge;
			changed = true;
		}
	});
	if (changed) { jawnosShellSave(); }
}

function jawnosShellApply() {
	var layout = jawnosShellLayout();
	jawnosShellMarkPrimary();
	jawnosShellPrimarySync();
	var active = jawnosShellActiveWorkspace();
	// draw every bar of every workspace once; switching then only toggles them
	$.each(layout.workspaces, function (i, ws) {
		$.each(ws.bars, function (j, desc) {
			jawnosShellBarBuild(desc, ws);
		});
	});
	$('.jawnos_bar').each(function () {
		var el = $(this);
		var found = jawnosShellBarFound(el.attr('data-bar-id'));
		if (!found) {
			// a descriptor that was removed takes its bar with it; the first pair
			// always stays because normalize() puts it back
			if (el.attr('data-bar-primary') != '1') { el.remove(); }
			return;
		}
		el.attr('data-workspace', found.workspace.id);
		el.toggleClass('jawnos_workspace_off', found.workspace.id != active.id);
		jawnosShellHandleEnsure(el);
		if (found.workspace.id == active.id) { jawnosShellPlace(el, found.bar); }
	});
	if (!jawnosShell.syncing) {
		jawnosShellTaskbarSync();
		jawnosShellDockSync();
	}
}

// Every extra taskbar reads the desk once. The window tiles are rebuilt by the
// taskbar's own displayer into each bar's list; the widgets, pins and clock are
// copied from the first bar (the pollers keep that one current).
function jawnosShellTaskbarSync() {
	if (jawnosShell.syncing || typeof taskbarDisplayer != 'function') { return; }
	var primary = $('#taskbar');
	if (!primary.length) { return; }
	jawnosShell.syncing = true;
	try {
		$('.jawnos_taskbar').not('#taskbar').each(function () {
			var el = $(this);
			var pins = el.children('[data-role="pins"]');
			pins.empty();
			primary.children('.taskbar_pin').each(function () {
				var copy = $(this).clone(true).removeAttr('id');
				pins.append(copy);
			});
			var widgets = el.children('[data-role="widgets"]');
			widgets.empty();
			primary.children('.taskbar_widget').each(function () {
				var copy = $(this).clone(true).removeAttr('id');
				widgets.append(copy);
			});
			el.children('[data-role="clock"]').html(primary.children('[data-role="clock"]').html());
			var windows = el.children('[data-role="windows"]');
			taskbarDisplayer(windows);
			// the first bar's state pass only visits the first bar: mark the
			// copies' tiles so the front window still reads as the front one
			var top = (typeof topWindow == 'function') ? topWindow() : null;
			windows.find('.window_toggle').each(function () {
				var tile = $(this);
				var app = tile.attr('app');
				var win = $('.wind[app="' + app + '"]');
				tile.removeAttr('state');
				if (win.length && win.is(':visible')) { tile.attr('state', (app == top) ? 'active' : 'open'); }
			});
		});
	}
	finally { jawnosShell.syncing = false; }
}

// An extra dock shows the first dock's faces. Its listeners are the delegated
// ones (a face press, its menu), so the copy stays live without its own render.
function jawnosShellDockSync() {
	var source = $('#pseudonym_bar');
	if (!source.length) { return; }
	$('.jawnos_dock').not('#pseudonym_home').each(function () {
		var row = $(this).children('.pseudonym_bar');
		if (!row.length) { return; }
		row.html(source.html());
		// the copy must not repeat the first dock's ids, and a side dock's faces
		// carry inline positions that belong to that edge alone
		row.find('[id]').removeAttr('id');
		row.find('.pseudonym').css({ position: '', left: '', top: '', right: '', bottom: '' });
	});
}

// ---- workspaces -----------------------------------------------------------
// Each workspace holds its own bars. The desk's windows are shared for now, so
// switching a workspace changes the bars on screen; separating the windows into
// their workspace is the next layer this one is shaped for.
function jawnosShellWorkspaceRows(context) {
	var layout = jawnosShellLayout();
	var active = jawnosShellActiveWorkspace();
	context.append($('<div class="taskbar_context_label"></div>').text(jawnosShellText('Workspaces')));
	$.each(layout.workspaces, function (i, ws) {
		var row = $('<div class="taskbar_context_selection" act="shell_ws"></div>')
			.attr('val', ws.id)
			.append($('<span></span>').text(jawnosShellText(ws.name)))
			.append('<span class="taskbar_context_check">' + (ws.id == active.id ? '✓' : '') + '</span>');
		context.append(row);
	});
	context.append('<div class="taskbar_context_selection" act="shell_ws_add">' + jawnosShellText('Add workspace') + '</div>');
}

function jawnosShellWorkspaceSet(id) {
	var layout = jawnosShellLayout();
	var found = false;
	$.each(layout.workspaces, function (i, ws) { if (ws.id == id) { found = true; } });
	if (!found) { return; }
	layout.active = id;
	jawnosShellSave();
	jawnosShellApply();
}

function jawnosShellWorkspaceAdd() {
	var layout = jawnosShellLayout();
	var n = layout.workspaces.length + 1;
	var ws = {
		id: 'ws-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 6),
		name: 'Workspace ' + n,
		bars: []
	};
	ws.bars.push({ id: jawnosShellNewId('taskbar'), kind: 'taskbar', mode: 'edge', edge: 'bottom' });
	ws.bars.push({
		id: jawnosShellNewId('dock'), kind: 'dock', mode: 'floating',
		x: Math.max(8, ($(window).width() - 360) / 2),
		y: Math.max(8, $(window).height() - 180),
		w: 360, h: 120
	});
	layout.workspaces.push(ws);
	layout.active = ws.id;
	jawnosShellSave();
	jawnosShellApply();
}

// ---- adding, moving and removing a bar ------------------------------------
function jawnosShellFreeEdge(workspace, kind) {
	var used = {};
	$.each(workspace.bars, function (i, bar) {
		if (bar.kind == kind && bar.mode != 'floating') { used[bar.edge] = 1; }
	});
	for (var i = 0; i < jawnosShellEdges.length; i++) {
		if (!used[jawnosShellEdges[i]]) { return jawnosShellEdges[i]; }
	}
	return null;
}

function jawnosShellBarAdd(kind) {
	kind = kind == 'dock' ? 'dock' : 'taskbar';
	var workspace = jawnosShellActiveWorkspace();
	var desc = { id: jawnosShellNewId(kind), kind: kind, mode: 'edge', edge: jawnosShellFreeEdge(workspace, kind) };
	if (!desc.edge) {
		desc.mode = 'floating';
		desc.edge = 'bottom';
		desc.w = kind == 'taskbar' ? 560 : 360;
		desc.h = kind == 'taskbar' ? 44 : 120;
		desc.x = Math.max(8, ($(window).width() - desc.w) / 2);
		desc.y = Math.max(8, ($(window).height() - desc.h) / 2 + (workspace.bars.length * 24));
	}
	workspace.bars.push(desc);
	jawnosShellSave();
	jawnosShellApply();
}

function jawnosShellBarRemove(id) {
	var found = jawnosShellBarFound(id);
	if (!found || found.bar.primary) { return; }
	var workspace = found.workspace;
	// never leave a workspace with no bar at all: its menu is the only way back
	if (workspace.bars.length <= 1) { return; }
	workspace.bars = $.grep(workspace.bars, function (bar) { return bar.id != id; });
	jawnosShellSave();
	var el = jawnosShellBarEl(id);
	if (el.length) { el.remove(); }
	jawnosShellApply();
}

function jawnosShellBarEdgeSet(id, edge) {
	var found = jawnosShellBarFound(id);
	if (!found) { return; }
	if (edge == 'floating') {
		found.bar.mode = 'floating';
		found.bar.w = found.bar.w || (found.bar.kind == 'taskbar' ? 560 : 360);
		found.bar.h = found.bar.h || (found.bar.kind == 'taskbar' ? 44 : 120);
		found.bar.x = (typeof found.bar.x == 'number') ? found.bar.x : Math.max(8, ($(window).width() - found.bar.w) / 2);
		found.bar.y = (typeof found.bar.y == 'number') ? found.bar.y : Math.max(8, ($(window).height() - found.bar.h) / 2);
	}
	else {
		found.bar.mode = 'edge';
		found.bar.edge = edge;
	}
	if (found.bar.primary) {
		var key = found.bar.kind == 'taskbar' ? 'taskbar' : 'dock';
		jawnosBars[key] = edge;
		jawnosTaskbarSave(key == 'taskbar' ? 'taskbar_position' : 'dock_position', edge);
		jawnosBarsApply();
		return;
	}
	jawnosShellSave();
	jawnosShellApply();
}

// ---- the drag handle ------------------------------------------------------
function jawnosShellSnapEdge(x, y) {
	var w = $(window).width();
	var h = $(window).height();
	var near = {
		top: y,
		bottom: h - y,
		left: x,
		right: w - x
	};
	var edge = null;
	var distance = jawnosShellSnapDistance + 1;
	$.each(near, function (name, value) {
		if (value <= jawnosShellSnapDistance && value < distance) { edge = name; distance = value; }
	});
	return edge;
}

function jawnosShellSnapShow(edge) {
	var preview = $('#jawnos_snap_preview');
	if (!preview.length) {
		preview = $('<div id="jawnos_snap_preview" class="jawnos_snap_preview"></div>').appendTo('body');
	}
	if (!edge) { preview.removeClass('on').removeAttr('edge'); return; }
	preview.attr('edge', edge).addClass('on');
}

function jawnosShellDragStart(x, y, handle) {
	var el = $(handle).closest('.jawnos_bar');
	var desc = jawnosShellBarGet(el.attr('data-bar-id'));
	if (!el.length || !desc) { return; }
	var rect = el[0].getBoundingClientRect();
	jawnosShell.drag = {
		el: el,
		id: desc.id,
		x0: x,
		y0: y,
		rect: { left: rect.left, top: rect.top, width: rect.width, height: rect.height },
		moved: false,
		edge: null
	};
	$('body').addClass('jawnos_bar_dragging');
}

function jawnosShellDragMove(x, y) {
	var drag = jawnosShell.drag;
	if (!drag) { return; }
	if (!drag.moved) {
		if ((Math.abs(x - drag.x0) + Math.abs(y - drag.y0)) < 4) { return; }
		drag.moved = true;
		drag.el.addClass('jawnos_bar_dragging').attr('data-bar-mode', 'floating').attr('position', 'floating');
	}
	var vw = $(window).width();
	var vh = $(window).height();
	var w = Math.min(drag.rect.width, vw);
	var h = Math.min(drag.rect.height, vh);
	var left = Math.max(0, Math.min(drag.rect.left + (x - drag.x0), vw - w));
	var top = Math.max(0, Math.min(drag.rect.top + (y - drag.y0), vh - h));
	drag.el.css({
		left: left + 'px',
		top: top + 'px',
		right: 'auto',
		bottom: 'auto',
		width: w + 'px',
		height: h + 'px',
		transform: ''
	});
	drag.edge = jawnosShellSnapEdge(x, y);
	jawnosShellSnapShow(drag.edge);
}

function jawnosShellDragEnd() {
	var drag = jawnosShell.drag;
	if (!drag) { return; }
	jawnosShell.drag = null;
	$('body').removeClass('jawnos_bar_dragging');
	drag.el.removeClass('jawnos_bar_dragging');
	jawnosShellSnapShow(null);
	if (!drag.moved) { return; }
	var found = jawnosShellBarFound(drag.id);
	if (!found) { return; }
	var desc = found.bar;
	if (drag.edge) {
		// dropped near an edge: the bar locks there, so the edge owns it again
		desc.mode = 'edge';
		desc.edge = drag.edge;
		desc.x = desc.y = desc.w = desc.h = undefined;
		// the drag left a floating box inline; an edge bar takes the CSS again
		drag.el.css({ left: '', right: '', top: '', bottom: '', width: '', height: '', transform: '' });
	}
	else {
		// dropped in the open: the bar keeps the box it was dragged into
		desc.mode = 'floating';
		desc.x = parseInt(drag.el.css('left'), 10) || 0;
		desc.y = parseInt(drag.el.css('top'), 10) || 0;
		desc.w = parseInt(drag.el.css('width'), 10) || drag.rect.width;
		desc.h = parseInt(drag.el.css('height'), 10) || drag.rect.height;
	}
	if (desc.primary) {
		var key = desc.kind == 'taskbar' ? 'taskbar' : 'dock';
		jawnosBars[key] = drag.edge || 'floating';
		jawnosTaskbarSave(key == 'taskbar' ? 'taskbar_position' : 'dock_position', jawnosBars[key]);
		jawnosBarsApply();
		return;
	}
	jawnosShellSave();
	jawnosShellApply();
}

function jawnosShellDragBind() {
	if (jawnosShellDragBind.done) { return; }
	jawnosShellDragBind.done = true;
	$(document).on('mousedown', '.jawnos_bar_handle', function (e) {
		if (e.which && e.which != 1) { return; }
		jawnosShellDragStart(e.clientX, e.clientY, this);
		e.preventDefault();
	});
	$(document).on('touchstart', '.jawnos_bar_handle', function (e) {
		var touch = e.originalEvent.touches && e.originalEvent.touches[0];
		if (!touch) { return; }
		jawnosShellDragStart(touch.clientX, touch.clientY, this);
		e.preventDefault();
	});
	$(document).on('mousemove', function (e) { jawnosShellDragMove(e.clientX, e.clientY); });
	$(document).on('mouseup', function () { jawnosShellDragEnd(); });
	$(document).on('touchmove', function (e) {
		if (!jawnosShell.drag) { return; }
		var touch = e.originalEvent.touches && e.originalEvent.touches[0];
		if (!touch) { return; }
		jawnosShellDragMove(touch.clientX, touch.clientY);
		e.preventDefault();
	});
	$(document).on('touchend touchcancel', function () { jawnosShellDragEnd(); });
}

// A floating first dock is placed by this file, so the dock's own free-space
// finder must not compute a row position for it.
function jawnosShellWrapDockFinder() {
	if (typeof pseudonymFreeSpaceFinder != 'function' || pseudonymFreeSpaceFinder.__jawnos_shell_wrapped) { return; }
	var base = pseudonymFreeSpaceFinder;
	pseudonymFreeSpaceFinder = function () {
		var home = $('#pseudonym_home');
		if (home.length && home.attr('position') == 'floating') { return; }
		return base.apply(this, arguments);
	};
	pseudonymFreeSpaceFinder.__jawnos_shell_wrapped = true;
}

$(document).ready(function () {
	// the widget page seeds bar settings too, but it has no bars of its own: do
	// not write a shell layout for it
	if (!$('#taskbar').length && !$('#pseudonym_home').length) { return; }
	jawnosShellWrapDockFinder();
	jawnosShellDragBind();
	jawnosShellApply();
	// a layout that has never been written is written once, so this desk's next
	// load starts from the same pair of bars
	if (typeof jawnos_bar_settings == 'undefined' || !jawnos_bar_settings.shell_layout) { jawnosShellSave(); }
});
