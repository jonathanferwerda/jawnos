// Studio layout: four interior panel windows, their taskbar and the dynamic
// track list. The channel state itself still lives in mixer[] and
// studioAudio.channels[]; these helpers only move the existing controls around
// and call the same apply functions.

var STUDIO_MAX_TRACKS = 32;
var studioPanelDrag = null;
var studioPanelResize = null;
var studioLayoutQuiet = false;

function studioLayoutText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}

// ---- panel windows ---------------------------------------------------------
//
// Every studio panel is an interior window on the desk (#studio_grid): its own
// title bar, its own box, its own place in the panel stack. A panel can be
// dragged by its title, resized from its corner, minimized to the taskbar in
// the layout bar, or maximized to the whole desk and restored. The taskbar is
// the one place every panel is always reachable, however its window is left.

var studioPanelSelectors = {
	transport: '#studio_transport_panel',
	tracks: '#studio_tracks_panel',
	mixer: '#studio_mixer',
	drums: '#studio_drums'
};

var studioPanelNames = ['transport', 'tracks', 'mixer', 'drums'];
var studioPanelState = {};
var studioPanelZ = 10;
// Pinning is a stacking choice, not a geometry: pinned panels live in their own
// z band, high enough that raising an unpinned panel can never cover one.
var STUDIO_PINNED_Z = 100000;
var studioPanelPinnedZ = STUDIO_PINNED_Z;
var studioPanelObserver = null;
var studioPanelObservedDesk = null;

// The previous layout stored Hiding as its own setting. A first open after the
// upgrade reads it once, so a panel the person had hidden stays minimized until
// they press its taskbar entry; the new state carries `minimized` from then on.
var studioLegacyHidden = {
	transport: 'hide_transport',
	tracks: 'hide_tracks',
	mixer: 'hide_channel_strips',
	drums: 'hide_drums'
};

var STUDIO_PANEL_MIN_WIDTH = 180;
var STUDIO_PANEL_MIN_HEIGHT = 90;

function studioPanelElement(name) {
	var selector = studioPanelSelectors[name];
	return selector ? $(selector) : $();
}

function studioPanelNameForElement(element) {
	var found = '';
	$.each(studioPanelSelectors, function (name) {
		if (studioPanelElement(name)[0] === element) { found = name; }
	});
	return found;
}

function studioPanelStateFor(name) {
	if (!studioPanelState[name]) { studioPanelState[name] = {}; }
	return studioPanelState[name];
}

function studioPanelDesk() {
	return $('#studio_grid');
}

// The desk's own inner size. While the window is still hidden the box can
// measure zero, so fall back to the Studio window and then to a sane default.
function studioPanelDeskSize() {
	var desk = studioPanelDesk()[0];
	var width = desk ? desk.clientWidth : 0;
	var height = desk ? desk.clientHeight : 0;
	if (!width) { width = Math.max(320, ($('#studio').width() || 600) - 20); }
	if (!height) { height = Math.max(240, ($('#studio').height() || 500) - 60); }
	return { width: width, height: height };
}

// Fit a box to the desk: every edge stays inside, and no window is smaller
// than the grip can be aimed at.
function studioPanelBox(left, top, width, height, size) {
	size = size || studioPanelDeskSize();
	width = Math.max(STUDIO_PANEL_MIN_WIDTH, Math.min(width || STUDIO_PANEL_MIN_WIDTH, Math.max(STUDIO_PANEL_MIN_WIDTH, size.width)));
	height = Math.max(STUDIO_PANEL_MIN_HEIGHT, Math.min(height || STUDIO_PANEL_MIN_HEIGHT, Math.max(STUDIO_PANEL_MIN_HEIGHT, size.height)));
	var maxLeft = Math.max(0, size.width - width);
	var maxTop = Math.max(0, size.height - height);
	return {
		left: Math.max(0, Math.min(left, maxLeft)),
		top: Math.max(0, Math.min(top, maxTop)),
		width: width,
		height: height
	};
}

// The first-open layout, and what Arrange lays down: the DAW reading order in
// interior windows. A narrow desk stacks the same panels one above the other.
function studioDefaultPanelLayout(size) {
	size = size || studioPanelDeskSize();
	var gap = 4;
	var width = size.width;
	var height = size.height;
	if (width < 720) {
		var transportH = Math.max(64, Math.min(104, Math.round(height * 0.18)));
		var drumsH = Math.max(110, Math.min(190, Math.round(height * 0.24)));
		var mixerH = Math.max(110, Math.min(170, Math.round(height * 0.24)));
		var tracksH = Math.max(STUDIO_PANEL_MIN_HEIGHT, height - transportH - drumsH - mixerH - gap * 3);
		var drumsTop = transportH + gap + tracksH + gap;
		var mixerTop = drumsTop + drumsH + gap;
		return {
			transport: { left: 0, top: 0, width: width, height: transportH },
			tracks: { left: 0, top: transportH + gap, width: width, height: tracksH },
			drums: { left: 0, top: drumsTop, width: width, height: drumsH },
			mixer: { left: 0, top: mixerTop, width: width, height: mixerH }
		};
	}
	var transportHeight = Math.max(64, Math.min(112, Math.round(height * 0.16)));
	var mixerHeight = Math.max(120, Math.min(220, Math.round(height * 0.28)));
	var middleTop = transportHeight + gap;
	var middleHeight = Math.max(STUDIO_PANEL_MIN_HEIGHT, height - transportHeight - mixerHeight - gap * 2);
	var drumsWidth = Math.max(300, Math.min(380, Math.round(width * 0.36)));
	var tracksWidth = Math.max(STUDIO_PANEL_MIN_WIDTH, width - drumsWidth - gap);
	return {
		transport: { left: 0, top: 0, width: width, height: transportHeight },
		tracks: { left: 0, top: middleTop, width: tracksWidth, height: middleHeight },
		drums: { left: tracksWidth + gap, top: middleTop, width: drumsWidth, height: middleHeight },
		mixer: { left: 0, top: height - mixerHeight, width: width, height: mixerHeight }
	};
}

function studioApplyPanelGeometry(name) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var state = studioPanelStateFor(name);
	panel.toggleClass('studio_panel_minimized', !!state.minimized);
	panel.toggleClass('studio_panel_maximized', !!state.maximized);
	panel.attr('data-studio-name', name);
	studioPanelReflectPin(name);
	if (typeof state.z === 'number') { panel.css('z-index', state.z); }
	else { studioPanelAssignZ(name); }
	if (state.maximized) {
		panel.css({ left: '0px', top: '0px', width: '100%', height: '100%' });
		if (!state.minimized) { studioPanelContentRelayout(name); }
		return;
	}
	var box = studioPanelBox(state.left, state.top, state.width, state.height);
	state.left = box.left;
	state.top = box.top;
	state.width = box.width;
	state.height = box.height;
	panel.css({
		left: box.left + 'px',
		top: box.top + 'px',
		width: box.width + 'px',
		height: box.height + 'px'
	});
	if (!state.minimized) { studioPanelContentRelayout(name); }
}

// The mixer's fader is a percentage of the strip, so it needs the strip box to
// be resolved against the window. A hidden or freshly restored panel measures
// zero, so ask the strip part to re-measure after the box is written.
function studioPanelContentRelayout(name) {
	if (name !== 'mixer' || typeof studioMixerRelayout !== 'function') { return; }
	if (typeof requestAnimationFrame === 'function') { requestAnimationFrame(studioMixerRelayout); }
	else { setTimeout(studioMixerRelayout, 0); }
}

function studioApplyPanelGeometries() {
	$.each(studioPanelNames, function (i, name) { studioApplyPanelGeometry(name); });
}

function studioCapturePanelBox(name) {
	var panel = studioPanelElement(name);
	var desk = studioPanelDesk()[0];
	if (!panel.length || !desk) { return; }
	var rect = panel[0].getBoundingClientRect();
	var deskRect = desk.getBoundingClientRect();
	var state = studioPanelStateFor(name);
	state.left = Math.round(rect.left - deskRect.left);
	state.top = Math.round(rect.top - deskRect.top);
	state.width = Math.round(rect.width);
	state.height = Math.round(rect.height);
}

function studioPersistPanelState(name) {
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	var state = studioPanelStateFor(name);
	var value = {
		left: Math.round(state.left || 0),
		top: Math.round(state.top || 0),
		width: Math.round(state.width || 0),
		height: Math.round(state.height || 0),
		minimized: !!state.minimized,
		maximized: !!state.maximized,
		pinned: !!state.pinned
	};
	var setting = 'studio_panel_position_' + name;
	var text = JSON.stringify(value);
	mixer.settings[setting] = text;
	studioSaveSettings([{ setting: setting, value: text }]);
}

function studioLoadPanelStates() {
	var layout = studioDefaultPanelLayout(studioPanelDeskSize());
	var any_saved = false;
	$.each(studioPanelNames, function (i, name) {
		var state = studioPanelStateFor(name);
		var raw = (mixer && mixer.settings) ? mixer.settings['studio_panel_position_' + name] : undefined;
		var saved = null;
		if (raw) { try { saved = JSON.parse(raw); } catch (e) { saved = null; } }
		var base = layout[name];
		if (saved && typeof saved.left == 'number' && typeof saved.top == 'number') {
			any_saved = true;
			state.width = (typeof saved.width == 'number' && saved.width > 0) ? saved.width : base.width;
			state.height = (typeof saved.height == 'number' && saved.height > 0) ? saved.height : base.height;
			state.left = saved.left;
			state.top = saved.top;
			state.minimized = (typeof saved.minimized == 'boolean')
				? saved.minimized
				: (String(((mixer && mixer.settings) || {})[studioLegacyHidden[name]] || '') == 'yes');
			state.maximized = !!saved.maximized;
			state.pinned = !!saved.pinned;
		}
		else {
			// No geometry yet (a first open, or an older saved dock/float record):
			// the preset gives the panel a place, and the person can move it.
			state.left = base.left;
			state.top = base.top;
			state.width = base.width;
			state.height = base.height;
			state.minimized = (saved && typeof saved.minimized == 'boolean')
				? saved.minimized
				: (String(((mixer && mixer.settings) || {})[studioLegacyHidden[name]] || '') == 'yes');
			state.maximized = !!(saved && saved.maximized);
			state.pinned = !!(saved && saved.pinned);
		}
		var box = studioPanelBox(state.left, state.top, state.width, state.height);
		state.left = box.left;
		state.top = box.top;
		state.width = box.width;
		state.height = box.height;
	});
	if (!any_saved) {
		$.each(studioPanelNames, function (i, name) { studioPersistPanelState(name); });
	}
}

// Arrange is a one-press preset: every panel comes back visible, unmaximized
// and laid out in the DAW reading order.
function studioArrangeWindows(persist) {
	var layout = studioDefaultPanelLayout(studioPanelDeskSize());
	$.each(studioPanelNames, function (i, name) {
		var state = studioPanelStateFor(name);
		var box = layout[name];
		state.left = box.left;
		state.top = box.top;
		state.width = box.width;
		state.height = box.height;
		state.minimized = false;
		state.maximized = false;
		studioApplyPanelGeometry(name);
		if (persist) { studioPersistPanelState(name); }
	});
	studioPanelRaise('tracks');
	studioPanelTaskbarRefresh();
}

$(document).on('click', '#studio_arrange', function () { studioArrangeWindows(true); });

// Cascade is the other preset: every window the same size, stepped down and
// right so each title bar stays in reach.
function studioCascadeWindows(persist) {
	var size = studioPanelDeskSize();
	var step = Math.max(18, Math.min(36, Math.round(Math.min(size.width, size.height) * 0.045)));
	var width = Math.max(STUDIO_PANEL_MIN_WIDTH, Math.min(size.width - step * 3, Math.round(size.width * 0.62)));
	var height = Math.max(STUDIO_PANEL_MIN_HEIGHT, Math.min(size.height - step * 3, Math.round(size.height * 0.62)));
	var left = 8;
	var top = 8;
	$.each(studioPanelNames, function (i, name) {
		var state = studioPanelStateFor(name);
		state.left = left;
		state.top = top;
		state.width = width;
		state.height = height;
		state.minimized = false;
		state.maximized = false;
		studioApplyPanelGeometry(name);
		if (persist) { studioPersistPanelState(name); }
		left += step;
		top += step;
	});
	studioPanelRaise('tracks');
	studioPanelTaskbarRefresh();
}

function studioPanelAnyVisible() {
	var any = false;
	$.each(studioPanelNames, function (i, name) {
		if (!studioPanelStateFor(name).minimized) { any = true; }
	});
	return any;
}

function studioPanelToggleAllMinimized(persist) {
	var any = studioPanelAnyVisible();
	$.each(studioPanelNames, function (i, name) {
		studioPanelSetMinimized(name, any, persist !== false);
	});
	if (!any) { studioPanelRaise('tracks'); }
}

// Right-click the taskbar for the window presets. The menu is the same themed
// card the timeline uses, so it needs no new chrome.
function studioPanelMenuPlace(menu, x, y) {
	$('body').append(menu);
	var width = menu.outerWidth() || 180;
	var height = menu.outerHeight() || 100;
	menu.css({
		left: Math.max(8, Math.min(x, $(window).width() - width - 8)),
		top: Math.max(8, Math.min(y, $(window).height() - height - 8))
	});
}

function studioPanelMenu(x, y) {
	$('.studio_menu').remove();
	var menu = $('<div class="studio_menu studio_panel_menu"></div>').css({ position: 'fixed', left: 0, top: 0 });
	$('<div class="studio_menu_head"></div>').text(studioLayoutText('Panels')).appendTo(menu);
	var row = function (action, label) {
		$('<button type="button" class="studio_menu_row"></button>')
			.attr('data-studio-panel-action', action)
			.text(studioLayoutText(label))
			.appendTo(menu);
	};
	row('tile', 'Tile all');
	row('cascade', 'Cascade');
	row('minimize', studioPanelAnyVisible() ? 'Minimize all' : 'Restore all');
	studioPanelMenuPlace(menu, x, y);
}

$(document).on('contextmenu', '#studio_panel_taskbar', function (e) {
	e.preventDefault();
	studioPanelMenu(e.clientX, e.clientY);
});

$(document).on('click', '.studio_panel_menu .studio_menu_row', function () {
	var action = $(this).attr('data-studio-panel-action');
	$('.studio_menu').remove();
	if (action === 'tile') { studioArrangeWindows(true); }
	else if (action === 'cascade') { studioCascadeWindows(true); }
	else if (action === 'minimize') { studioPanelToggleAllMinimized(true); }
});

// Keyboard: Ctrl+Alt+1..4 raises that panel (or brings it back), 0 toggles all
// minimized, T tiles and C cascades. The drum key map ignores modifiers, so the
// same letters still play drums without Ctrl+Alt.
function studioPanelShortcutTyping(e) {
	var target = e.target;
	if (!target) { return false; }
	if (target.isContentEditable) { return true; }
	var tag = String(target.tagName || '').toUpperCase();
	return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT';
}

$(document).on('keydown', function (e) {
	if (!e.ctrlKey || !e.altKey || e.metaKey || e.shiftKey) { return; }
	if (!$('#studio').is(':visible')) { return; }
	if (typeof topWindow === 'function' && (topWindow() || '') !== 'studio') { return; }
	if (studioPanelShortcutTyping(e)) { return; }
	var key = String(e.key || '').toLowerCase();
	var panel_keys = { '1': 'transport', '2': 'tracks', '3': 'mixer', '4': 'drums' };
	if (panel_keys[key]) {
		studioPanelSetMinimized(panel_keys[key], false, true);
		studioPanelRaise(panel_keys[key]);
		e.preventDefault();
		return;
	}
	if (key === '0') { studioPanelToggleAllMinimized(true); e.preventDefault(); return; }
	if (key === 't') { studioArrangeWindows(true); e.preventDefault(); return; }
	if (key === 'c') { studioCascadeWindows(true); e.preventDefault(); return; }
});

// ---- the panel stack and its taskbar ---------------------------------------

// Give a panel a place in its band. Pinned panels share one band above every
// unpinned one, so a press on an unpinned panel raises it within its band but
// never over a pinned panel.
function studioPanelAssignZ(name) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var state = studioPanelStateFor(name);
	if (state.pinned) {
		studioPanelPinnedZ += 1;
		state.z = studioPanelPinnedZ;
	}
	else {
		studioPanelZ += 1;
		state.z = studioPanelZ;
	}
	panel.css('z-index', state.z);
}

// Reflect the pin in the window and its title-bar button. Geometry does not
// change: a pinned panel keeps its box.
function studioPanelReflectPin(name) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var state = studioPanelStateFor(name);
	panel.toggleClass('studio_panel_pinned', !!state.pinned);
	$('.studio_panel_pin').each(function () {
		if ($(this).attr('data-panel') === name) {
			$(this).attr('aria-pressed', state.pinned ? 'true' : 'false');
		}
	});
}

function studioPanelSetPinned(name, pinned, persist) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var state = studioPanelStateFor(name);
	state.pinned = !!pinned;
	studioPanelAssignZ(name);
	studioPanelReflectPin(name);
	studioPanelTaskbarRefresh();
	if (persist !== false) { studioPersistPanelState(name); }
}

function studioPanelFront() {
	var front = '';
	var top = -1;
	$.each(studioPanelNames, function (i, name) {
		var panel = studioPanelElement(name);
		if (!panel.length || panel.hasClass('studio_panel_minimized') || !panel.is(':visible')) { return; }
		var z = parseInt(panel.css('z-index'), 10) || 0;
		if (z >= top) { top = z; front = name; }
	});
	return front;
}

function studioPanelTaskbarRefresh() {
	var front = studioPanelFront();
	$('.studio_panel_task').each(function () {
		var button = $(this);
		var name = button.attr('data-panel');
		var state = studioPanelState[name] || {};
		var minimized = !!state.minimized;
		button.toggleClass('studio_task_active', !minimized && name === front)
			.toggleClass('studio_task_minimized', minimized)
			.attr('aria-pressed', minimized ? 'false' : 'true');
	});
	$('.studio_panel_max').each(function () {
		var name = $(this).attr('data-panel');
		var state = studioPanelState[name] || {};
		$(this).attr('aria-pressed', state.maximized ? 'true' : 'false');
	});
}

function studioPanelRaise(name) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	studioPanelAssignZ(name);
	$('.studio_panel').removeClass('studio_panel_raised');
	panel.addClass('studio_panel_raised');
	studioPanelTaskbarRefresh();
}

function studioPanelSetMinimized(name, minimized, persist) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var state = studioPanelStateFor(name);
	state.minimized = !!minimized;
	panel.toggleClass('studio_panel_minimized', state.minimized);
	if (!state.minimized) { studioPanelContentRelayout(name); }
	if (persist !== false) { studioPersistPanelState(name); }
	studioPanelTaskbarRefresh();
}

function studioPanelToggleMaximized(name, persist) {
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var state = studioPanelStateFor(name);
	// Keep the box the panel will come back to before it fills the desk.
	if (!state.maximized && !state.minimized) { studioCapturePanelBox(name); }
	state.maximized = !state.maximized;
	studioApplyPanelGeometry(name);
	studioPanelRaise(name);
	if (persist !== false) { studioPersistPanelState(name); }
}

// A taskbar entry answers for its panel the way the desk's taskbar answers for
// a window: a minimized panel comes back, the front panel steps down, and any
// other panel rises.
$(document).on('click', '.studio_panel_task', function () {
	var name = $(this).attr('data-panel');
	var state = studioPanelStateFor(name);
	if (state.minimized) {
		studioPanelSetMinimized(name, false, true);
		studioPanelRaise(name);
		return;
	}
	if (studioPanelFront() === name) { studioPanelSetMinimized(name, true, true); }
	else { studioPanelRaise(name); }
});

$(document).on('click', '.studio_panel_min', function (e) {
	e.stopPropagation();
	studioPanelSetMinimized($(this).attr('data-panel'), true, true);
});

$(document).on('click', '.studio_panel_max', function (e) {
	e.stopPropagation();
	studioPanelToggleMaximized($(this).attr('data-panel'), true);
});

// The pin is a toggle, not a raise: the press belongs to the button, so the
// panel's own pointerdown handler leaves it alone and this click does the work.
$(document).on('click', '.studio_panel_pin', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var name = $(this).attr('data-panel');
	if (!name) { return; }
	var state = studioPanelStateFor(name);
	studioPanelSetPinned(name, !state.pinned, true);
});

// Any press inside a panel window brings it forward, the same way a press on a
// desk window does. Nested controls keep their own handlers; this only stacks.
$(document).on('pointerdown', '.studio_panel', function (e) {
	if ($(e.target).closest('.studio_panel_pin').length) { return; }
	var name = $(this).attr('data-studio-name') || studioPanelNameForElement(this);
	if (name) { studioPanelRaise(name); }
});

// ---- pointer drag and resize -----------------------------------------------

// Snap a drag to the 8px grid and, within 8px, to a neighbour's edge/size.
function studioSnapTo(value, candidates) {
	var best = Math.round(value / 8) * 8;
	var best_d = 8.01;
	(candidates || []).forEach(function (c) {
		if (!isFinite(c)) { return; }
		var d = Math.abs(c - value);
		if (d <= 8 && d < best_d) { best = c; best_d = d; }
	});
	return Math.round(best);
}

function studioPanelNeighbourSizes(panel) {
	var widths = [], heights = [];
	$('.studio_panel').not(panel).each(function () {
		var r = this.getBoundingClientRect();
		if (r.width < 1 || r.height < 1) { return; }
		widths.push(Math.round(r.width));
		heights.push(Math.round(r.height));
	});
	return { widths: widths, heights: heights };
}

$(document).on('pointerdown', '.studio_drag_handle', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var name = $(this).attr('data-studio-drag');
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	var state = studioPanelStateFor(name);
	// Dragging a maximized panel gives it its old box back first, so the drag
	// starts where the pointer grabbed rather than at the desk's corner.
	if (state.maximized) {
		state.maximized = false;
		studioApplyPanelGeometry(name);
	}
	var rect = panel[0].getBoundingClientRect();
	studioPanelDrag = {
		name: name,
		panel: panel,
		dx: e.originalEvent.clientX - rect.left,
		dy: e.originalEvent.clientY - rect.top
	};
	panel.addClass('studio_panel_dragging');
	studioPanelRaise(name);
	try { this.setPointerCapture(e.originalEvent.pointerId); } catch (err) {}
	e.preventDefault();
});

function studioPanelBeginResize(name, panel, e, axis, handle) {
	var state = studioPanelStateFor(name);
	if (state.maximized) {
		// Resize from the full desk box, not from the hidden restore box.
		var full = panel[0].getBoundingClientRect();
		var deskRect = studioPanelDesk()[0].getBoundingClientRect();
		state.left = Math.round(full.left - deskRect.left);
		state.top = Math.round(full.top - deskRect.top);
		state.width = Math.round(full.width);
		state.height = Math.round(full.height);
		state.maximized = false;
		studioApplyPanelGeometry(name);
	}
	var rect = panel[0].getBoundingClientRect();
	studioPanelResize = {
		name: name,
		panel: panel,
		axis: axis || 'xy',
		x: e.originalEvent.clientX,
		y: e.originalEvent.clientY,
		left: parseFloat(panel.css('left')) || 0,
		top: parseFloat(panel.css('top')) || 0,
		width: rect.width,
		height: rect.height
	};
	panel.addClass('studio_panel_resizing');
	studioPanelRaise(name);
	try { handle.setPointerCapture(e.originalEvent.pointerId); } catch (err) {}
	e.preventDefault();
	e.stopPropagation();
}

$(document).on('pointerdown', '.studio_resize_handle', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var name = $(this).attr('data-studio-resize');
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	studioPanelBeginResize(name, panel, e, 'xy', this);
});

$(document).on('pointerdown', '.studio_panel_bottom', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var name = $(this).attr('data-studio-bottom');
	var panel = studioPanelElement(name);
	if (!panel.length) { return; }
	studioPanelBeginResize(name, panel, e, 'y', this);
});

$(document).on('pointermove', function (e) {
	var original = e.originalEvent || {};
	if (studioPanelResize) {
		var sizes = studioPanelNeighbourSizes(studioPanelResize.panel);
		var w = (studioPanelResize.axis === 'y')
			? studioPanelResize.width
			: studioSnapTo(studioPanelResize.width + (original.clientX - studioPanelResize.x), sizes.widths);
		var h = (studioPanelResize.axis === 'x')
			? studioPanelResize.height
			: studioSnapTo(studioPanelResize.height + (original.clientY - studioPanelResize.y), sizes.heights);
		var box = studioPanelBox(studioPanelResize.left, studioPanelResize.top, w, h);
		studioPanelResize.panel.css({
			left: box.left + 'px',
			top: box.top + 'px',
			width: box.width + 'px',
			height: box.height + 'px'
		});
		if (studioPanelResize.panel.attr('data-studio-name') === 'mixer' && typeof studioMixerRelayout === 'function') {
			studioMixerRelayout();
		}
		e.preventDefault();
		return;
	}
	if (!studioPanelDrag) { return; }
	var desk = studioPanelDesk()[0];
	if (!desk) { return; }
	var deskRect = desk.getBoundingClientRect();
	var state = studioPanelStateFor(studioPanelDrag.name);
	var left = original.clientX - deskRect.left - studioPanelDrag.dx;
	var top = original.clientY - deskRect.top - studioPanelDrag.dy;
	var box = studioPanelBox(left, top, state.width, state.height);
	studioPanelDrag.panel.css({ left: box.left + 'px', top: box.top + 'px' });
	e.preventDefault();
});

$(document).on('pointerup pointercancel', function () {
	if (studioPanelResize) {
		var resize = studioPanelResize;
		studioPanelResize = null;
		resize.panel.removeClass('studio_panel_resizing');
		var state = studioPanelStateFor(resize.name);
		state.maximized = false;
		studioCapturePanelBox(resize.name);
		studioPersistPanelState(resize.name);
		return;
	}
	if (!studioPanelDrag) { return; }
	var drag = studioPanelDrag;
	studioPanelDrag = null;
	drag.panel.removeClass('studio_panel_dragging');
	var dragState = studioPanelStateFor(drag.name);
	dragState.maximized = false;
	studioCapturePanelBox(drag.name);
	studioPersistPanelState(drag.name);
});

// ---- keeping the windows on the desk ---------------------------------------

// The outer window can be resized, which changes the desk under every interior
// window. Maximized panels follow it; the others are pulled back inside it.
function studioPanelClampAll() {
	$.each(studioPanelNames, function (i, name) {
		var state = studioPanelStateFor(name);
		if (state.maximized) { studioApplyPanelGeometry(name); return; }
		var box = studioPanelBox(state.left, state.top, state.width, state.height);
		if (box.left === state.left && box.top === state.top
			&& box.width === state.width && box.height === state.height) { return; }
		state.left = box.left;
		state.top = box.top;
		state.width = box.width;
		state.height = box.height;
		studioApplyPanelGeometry(name);
	});
}

function studioPanelObserveDesk() {
	if (typeof ResizeObserver !== 'function') { return; }
	var desk = studioPanelDesk()[0];
	if (!desk) { return; }
	// A closed and reopened Studio window brings a new grid; the old observer
	// must let go of the detached node and watch the desk now on screen.
	if (studioPanelObserver && studioPanelObservedDesk === desk) { return; }
	if (studioPanelObserver) { studioPanelObserver.disconnect(); }
	studioPanelObservedDesk = desk;
	studioPanelObserver = new ResizeObserver(function () { studioPanelClampAll(); });
	studioPanelObserver.observe(desk);
}

$(window).on('resize', function () { studioPanelClampAll(); });

function studioApplyLayoutSettings() {
	studioLoadPanelStates();
	studioApplyPanelGeometries();
	// the timeline is the working surface, so it starts at the front
	var front = 'tracks';
	if (studioPanelStateFor('tracks').minimized) {
		$.each(studioPanelNames, function (i, name) {
			if (!studioPanelStateFor(name).minimized) { front = name; return false; }
		});
	}
	studioPanelRaise(front);
	studioPanelTaskbarRefresh();
	studioPanelObserveDesk();
	if (typeof studioMixerObserveLayout === 'function') { studioMixerObserveLayout(); }
	studioUpdateTrackCount();
}

$(document).on('click', '#studio_pedalboard_close', function () {
	studioPedalboardOpen(false);
});

// ---- track row height ------------------------------------------------------

// A track keeps a default row height inside the timeline window; its bottom
// edge drags it taller or shorter. The height belongs to the song
// (studioSaver writes track_height), the timeline scrolls, and the automation
// lane keeps its own height.
var studioTrackResize = null;

function studioTrackHeightClamp(h) {
	var panel = $('#studio_tracks_panel');
	var limit = panel.length ? panel[0].clientHeight - 48 : 280;
	if (!limit || limit < 64) { limit = 280; }
	return Math.max(64, Math.min(Math.min(280, limit), Math.round(h)));
}

$(document).on('pointerdown', '.studio_track_resize', function (e) {
	if (e.originalEvent && e.originalEvent.button) { return; }
	var row = $(this).closest('.studio_track');
	if (!row.length) { return; }
	studioTrackResize = {
		row: row,
		channel: String(row.attr('data-channel') || ''),
		y: e.originalEvent.clientY,
		startH: row[0].getBoundingClientRect().height
	};
	row.addClass('studio_track_resizing');
	try { this.setPointerCapture(e.originalEvent.pointerId); } catch (err) {}
	e.preventDefault();
	e.stopPropagation();
});

$(document).on('pointermove', function (e) {
	if (!studioTrackResize) { return; }
	var h = studioTrackHeightClamp(studioTrackResize.startH + ((e.originalEvent || {}).clientY - studioTrackResize.y));
	studioTrackResize.row.css('height', h + 'px');
	e.preventDefault();
});

$(document).on('pointerup pointercancel', function () {
	if (!studioTrackResize) { return; }
	var ch = studioTrackResize.channel;
	studioTrackResize.row.removeClass('studio_track_resizing');
	studioTrackResize = null;
	if (typeof studioDrawChannel === 'function' && ch) { studioDrawChannel(ch); }
	studioSaver();
});

// ---- the dynamic track list ------------------------------------------------

// Binding the pedal drop on a strip or a per-track panel. The channel number is
// the class suffix on a strip and the channel attribute on a track panel. The
// whole tile is draggable, artwork or drawn, so the drop reads its effect name.
function studioBindChannelDrop(node) {
	node.droppable({
		accept: '.pedal',
		tolerance: 'pointer',
		drop: function (event, ui) {
			var name = ui.draggable.attr('data-effect') || ui.draggable.attr('hint');
			var m = (String($(this).attr('class')) || '').match(/channel_(\d+)/);
			var ch = m ? m[1] : $(this).attr('channel');
			if (!name || !ch) { return; }
			var channel = studioAudio.channels[ch];
			studioSelectedChannel = ch;
			studioSetInsert(ch, name, !(channel && channel.insertByName[name]));
			studioPaletteLabel();
			studioSaver();
		}
	});
}

function studioTrackNumbers() {
	var numbers = [];
	$('#studio_viewer .studio_track').each(function () {
		var n = parseInt($(this).attr('data-channel'), 10);
		if (n > 0) { numbers.push(n); }
	});
	numbers.sort(function (a, b) { return a - b; });
	return numbers;
}

function studioNextTrackNumber() {
	for (var n = 1; n <= STUDIO_MAX_TRACKS; n++) {
		if (!document.getElementById('studio_track_row_' + n)) { return n; }
	}
	return 0;
}

function studioUpdateTrackCount() {
	var count = studioTrackNumbers().length;
	$('#studio_viewer').attr('channel_count', count);
	$('#studio_track_count').text(count + ' / ' + STUDIO_MAX_TRACKS);
}

function studioSaveTrackCount() {
	var count = studioTrackNumbers().length;
	mixer = mixer || {};
	mixer.settings = mixer.settings || {};
	mixer.settings['channel_count'] = String(count);
	studioSaveSettings([{ setting: 'channel_count', value: String(count) }]);
	studioUpdateTrackCount();
}

// ---- track colour ----------------------------------------------------------

// A new track takes a colour from the theme's own family - a random hue at the
// saturation and lightness the theme already uses for its panels - rather than
// an arbitrary neon swatch. The last hue is remembered so two tracks added in a
// row do not collide outright.
var STUDIO_TRACK_COLOUR = '#145abe';
var STUDIO_TRACK_COLOUR_RE = /^#[0-9a-f]{6}$/i;
var studioTrackHue = -1;

function studioHexColour(value) {
	value = String(value || '').trim();
	return STUDIO_TRACK_COLOUR_RE.test(value) ? value.toLowerCase() : '';
}

// Dark themes want a brighter, lighter swatch to read on a near-black panel;
// the body class is the theme's own word for it, and the background is a
// fallback for a page that has not set the class yet.
function studioThemeIsDark() {
	if (document.body && document.body.classList && document.body.classList.contains('dark_theme')) { return true; }
	var bg = '';
	try { bg = getComputedStyle(document.body).backgroundColor || ''; } catch (e) { bg = ''; }
	var m = bg.match(/rgba?\(([^)]+)\)/);
	if (!m) { return false; }
	var p = m[1].split(',');
	if (p.length < 3) { return false; }
	var lum = (0.2126 * (p[0] - 0) + 0.7152 * (p[1] - 0) + 0.0722 * (p[2] - 0)) / 255;
	return lum < 0.5;
}

function studioRandomTrackColour() {
	var h = Math.floor(Math.random() * 360);
	if (h === studioTrackHue) { h = (h + 47) % 360; }
	studioTrackHue = h;
	var dark = studioThemeIsDark();
	var s = 0.55 + Math.random() * 0.15;
	var l = dark ? 0.62 + Math.random() * 0.10 : 0.42 + Math.random() * 0.10;
	if (typeof jawnosHslToHex !== 'function') {
		// an older bundle may not carry the universal helper: a small themed palette
		var fallback = dark
			? ['#6ea8ff', '#7fd6a8', '#ff9f7a', '#c79bff', '#ffd06e', '#7ad4e0']
			: ['#145abe', '#1f8a5b', '#b2412a', '#6a3fb0', '#a0781f', '#1f6f8a'];
		return fallback[Math.floor(Math.random() * fallback.length)];
	}
	return jawnosHslToHex(h, s, l);
}

// The swatch is the song's word for the colour; the row's custom property is
// what the stylesheet reads, and the fallback keeps an old row paintable.
function studioTrackColour(ch) {
	ch = String(ch);
	var input = $('.studio_track_colour[channel="' + ch + '"]');
	if (input.length) {
		var picked = studioHexColour(input.val());
		if (picked) { return picked; }
	}
	var row = document.getElementById('studio_track_row_' + ch);
	if (row && row.style) {
		var prop = studioHexColour(row.style.getPropertyValue('--studio-track-colour'));
		if (prop) { return prop; }
	}
	return STUDIO_TRACK_COLOUR;
}

// Turn a hex into the translucent fill a canvas wants. Anything unparseable is
// handed back untouched, so a caller can pass a named colour or an rgba().
function studioColourRgba(colour, alpha) {
	var m = String(colour || '').match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
	if (!m) { return colour; }
	if (alpha === undefined) { alpha = 1; }
	var hex = m[1];
	if (hex.length == 3) { hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]; }
	var r = parseInt(hex.slice(0, 2), 16);
	var g = parseInt(hex.slice(2, 4), 16);
	var b = parseInt(hex.slice(4, 6), 16);
	return 'rgba(' + r + ',' + g + ',' + b + ',' + alpha + ')';
}

function studioApplyTrackColour(ch, colour) {
	var hex = studioHexColour(colour);
	if (!hex) { return; }
	ch = String(ch);
	var input = $('.studio_track_colour[channel="' + ch + '"]');
	if (input.length) { input.val(hex); }
	var row = document.getElementById('studio_track_row_' + ch);
	if (row) {
		$(row).attr('data-colour', hex);
		if (row.style) { row.style.setProperty('--studio-track-colour', hex); }
	}
	if (typeof studioDrawChannel === 'function') { studioDrawChannel(ch); }
}

// Give every rendered row a colour: the song's where it has one, a fresh
// theme-family one where the server rendered the row without one. Also the
// initial paint, so the first frame already has the right edges and clips.
function studioApplyTrackColours() {
	$('#studio_viewer .studio_track').each(function () {
		var ch = $(this).attr('data-channel');
		if (!ch) { return; }
		var colour = $(this).attr('data-colour') ? studioTrackColour(ch) : studioRandomTrackColour();
		studioApplyTrackColour(ch, colour);
	});
	if (typeof studioDrawTracks === 'function') { studioDrawTracks(); }
	if (typeof studioDrawRuler === 'function') { studioDrawRuler(); }
}

// Rewrite the channel number a cloned row or strip carries.
function studioRewireChannel(node, from, to) {
	from = String(from);
	to = String(to);
	if (from == to) { return node; }
	var classRe = new RegExp('_' + from + '\\b', 'g');
	var idRe = new RegExp('_' + from + '$');
	node.find('[channel]').addBack('[channel]').each(function () {
		if (String($(this).attr('channel')) == from) { $(this).attr('channel', to); }
	});
	node.find('[data-channel]').addBack('[data-channel]').each(function () {
		if (String($(this).attr('data-channel')) == from) { $(this).attr('data-channel', to); }
	});
	node.find('[id]').addBack('[id]').each(function () {
		if (this.id) { this.id = this.id.replace(idRe, '_' + to); }
	});
	node.find('[class]').addBack('[class]').each(function () {
		this.className = String(this.className).replace(classRe, '_' + to);
	});
	return node;
}

function studioResetChannelMarkup(node, ch) {
	node.find('.armed').attr('state', 'off').text('O');
	node.find('.channel_volume').val(1);
	node.find('.channel_fx').empty();
	node.find('.studio_channel_information').text('');
	node.find('.knob_control').val(50);
	node.find('.knob').css('transform', '');
	node.find('.studio_track_name').val(studioLayoutText('Track') + ' ' + ch);
	node.find('.studio_track_automation').attr('aria-pressed', 'false');
	// A reused clone starts audible and unsoloed. The state belongs to the
	// channel, so it is cleared here too; studioCreateTrack gives a brand-new
	// channel its own false values after this reset.
	if (mixer[ch]) { mixer[ch].mute = false; mixer[ch].solo = false; }
	node.find('.studio_strip_mute, .studio_strip_solo').removeAttr('aria-pressed');
	node.find('.studio_strip_led').removeClass('lit');
	node.removeClass('studio_solo_muted');
	node.find('.studio_solo_muted').removeClass('studio_solo_muted');
	node.removeClass('selected_channel studio_track_automation_on');
	node.find('.selected_channel').removeClass('selected_channel');
	// a recycled clone must not wear the first track's colour
	node.removeAttr('data-colour');
	node.find('[data-colour]').removeAttr('data-colour');
	var clearTrackColour = function () {
		if (this.style) { this.style.removeProperty('--studio-track-colour'); }
	};
	node.each(clearTrackColour);
	node.find('.studio_track').each(clearTrackColour);
	node.find('.studio_track_colour').val(STUDIO_TRACK_COLOUR);
	node.find('canvas').each(function () { this.width = 0; this.height = 0; });
	var resetVideo = function () {
		this.removeAttribute('src');
		this.srcObject = null;
		this.style.display = 'none';
	};
	node.filter('video').each(resetVideo);
	node.find('video').each(resetVideo);
}

function studioCreateTrack(ch) {
	ch = parseInt(ch, 10);
	if (!(ch > 0 && ch <= STUDIO_MAX_TRACKS)) { return null; }
	if (document.getElementById('studio_track_row_' + ch)) { return ch; }
	var rowTemplate = $('#studio_viewer .studio_track').first();
	var stripTemplate = $('#studio_mixer_strips .channel').first();
	if (!rowTemplate.length || !stripTemplate.length) { return null; }
	var from = parseInt(rowTemplate.attr('data-channel'), 10) || 1;
	var stripFrom = parseInt((String(stripTemplate.attr('class')).match(/channel_(\d+)/) || [])[1], 10) || from;

	var wasQuiet = studioLayoutQuiet;
	studioLayoutQuiet = true;
	var row = studioRewireChannel(rowTemplate.clone(), from, ch);
	var strip = studioRewireChannel(stripTemplate.clone(), stripFrom, ch);
	studioResetChannelMarkup(row, ch);
	studioResetChannelMarkup(strip, ch);
	var monitorTemplate = $('#studio_video_monitors video').first();
	var monitor = $();
	if (monitorTemplate.length) {
		var monitorFrom = parseInt((String(monitorTemplate.attr('id')).match(/_(\d+)$/) || [])[1], 10) || from;
		monitor = studioRewireChannel(monitorTemplate.clone(), monitorFrom, ch);
		studioResetChannelMarkup(monitor, ch);
		monitor.attr('id', 'studio_video_monitor_' + ch).hide();
	}

	$('#studio_viewer').append(row);
	$('#studio_mixer_strips').append(strip);
	if (monitor.length) { $('#studio_video_monitors').append(monitor); }

	// keep the list in channel order even when a gap is filled
	studioPlaceTrackRow(row, ch, '#studio_viewer');
	studioPlaceTrackRow(strip, ch, '#studio_mixer_strips', '#studio_master_rack');
	studioBindChannelDrop(row.find('.studio_track_panel'));
	studioBindChannelDrop(strip);

	if (!mixer[ch]) { mixer[ch] = {}; }
	if (!mixer[ch].media) { mixer[ch].media = { out: [], rec: [] }; }
	if (!mixer[ch].armed) { mixer[ch].armed = { state: 'off', text: 'O' }; }
	// a new channel is audible and unsoloed before anything can click it
	mixer[ch].mute = false;
	mixer[ch].solo = false;
	studioChannelEngine(ch);
	studioApplyChannel(ch);
	$('.knob_control[channel="' + ch + '"]').trigger('change');
	// the cloned buttons lost their pressed state in the reset above; paint the
	// new strip (and refresh the solo dimming) from mixer
	if (typeof studioStripMuteSoloRender === 'function') { studioStripMuteSoloRender(); }
	// the reset above cleared the clone's inherited colour; give this track its own
	row.removeAttr('data-colour');
	if (row[0] && row[0].style) { row[0].style.removeProperty('--studio-track-colour'); }
	studioApplyTrackColour(ch, studioRandomTrackColour());
	studioDrawChannel(ch);
	studioLayoutQuiet = wasQuiet;
	studioUpdateTrackCount();
	return ch;
}

function studioAddTrack() {
	var ch = studioNextTrackNumber();
	if (!ch) { return; }
	if (studioCreateTrack(ch)) {
		studioSaveTrackCount();
		studioSaver();
	}
}

function studioEnsureTracks(count) {
	count = Math.min(Math.max(parseInt(count, 10) || 0, 0), STUDIO_MAX_TRACKS);
	for (var ch = 1; ch <= count; ch++) {
		if (!document.getElementById('studio_track_row_' + ch)) { studioCreateTrack(ch); }
	}
	studioUpdateTrackCount();
}

function studioEnsureTracksForSong(song) {
	var highest = 0;
	$.each(song || {}, function (key) {
		if (/^[0-9]+$/.test(key)) {
			var n = parseInt(key, 10);
			if (n > highest) { highest = n; }
		}
	});
	if (highest) { studioEnsureTracks(highest); }
}

// Move a freshly cloned row or strip into channel order. A container's tail
// (the master rack) has no channel number of its own, so a row that fills a
// gap after the last channel still goes before it: Master is always the last
// strip, and a new track must never land to its right.
function studioPlaceTrackRow(node, ch, container, tail) {
	var placed = false;
	$(container).children().each(function () {
		var other = parseInt($(this).attr('data-channel'), 10);
		if (!other) {
			var m = String($(this).attr('class') || '').match(/channel_(\d+)/);
			other = m ? parseInt(m[1], 10) : 0;
		}
		if (!other && tail && $(this).is(tail)) { $(this).before(node); placed = true; return false; }
		if (other > ch) { $(this).before(node); placed = true; return false; }
	});
	if (!placed) { $(container).append(node); }
}

// A loaded song owns its track list: build what it needs and drop the rows the
// previous song left behind. Quiet, because this is not a user edit.
function studioSyncTrackList(song) {
	var wanted = {};
	$.each(song || {}, function (key) {
		if (/^[0-9]+$/.test(key)) { wanted[String(key)] = true; }
	});
	if (!Object.keys(wanted).length) { return; }
	studioEnsureTracksForSong(song);
	var wasQuiet = studioLayoutQuiet;
	studioLayoutQuiet = true;
	studioTrackNumbers().forEach(function (ch) {
		if (!wanted[String(ch)]) { studioRemoveTrack(ch, true); }
	});
	studioLayoutQuiet = wasQuiet;
	studioUpdateTrackCount();
}

function studioRemoveTrack(ch, quiet) {
	ch = String(ch);
	if (studioTrackNumbers().length <= 1) {
		$('.studio_track_delete[channel="' + ch + '"]').attr('armed', 'no').css('background-color', '');
		return;
	}
	var media = mixer[ch] && mixer[ch].media;
	if (media && media.rec) {
		$.each(media.rec, function (i, recorder) {
			if (recorder && recorder.state && recorder.state != 'inactive') {
				try { recorder.stop(); } catch (e) {}
			}
		});
	}
	// A channel send is an edge on another channel's output. Drop the edges that
	// name this channel before its nodes go, then re-route those sources to the
	// master once it is gone.
	var incoming = [];
	$.each(studioAudio.channels, function (src) {
		if (String(src) === ch) { return; }
		var out = (typeof studioChannelOutputInfo === 'function') ? studioChannelOutputInfo(src) : null;
		if (out && out['type'] === 'channel' && String(out['sid']) === ch) {
			$('.studio_channel_information[direction="output"][channel="' + src + '"]').text('');
			incoming.push(String(src));
		}
	});
	var own_out = (typeof studioChannelOutputInfo === 'function') ? studioChannelOutputInfo(ch) : null;
	var own_dest = (own_out && own_out['type'] === 'channel' && own_out['sid']) ? String(own_out['sid']) : '';
	var channel = studioAudio.channels[ch];
	if (channel) {
		['trim', 'bass', 'mid', 'treble', 'recGain', 'recAnalyser', 'recDest', 'playBus', 'playPan', 'monGain'].forEach(function (key) {
			if (channel[key] && channel[key].disconnect) {
				try { channel[key].disconnect(); } catch (e) {}
			}
		});
		(channel.inserts || []).forEach(function (insert) {
			if (insert.destroy) { try { insert.destroy(); } catch (e) {} }
		});
	}
	delete studioAudio.channels[ch];
	delete mixer[ch];
	$('#studio_track_row_' + ch).remove();
	$('#studio_mixer_strips .channel_' + ch).remove();
	$('#studio_video_monitor_' + ch).remove();
	$('#studio_track_container .studio_video[id^="studio_channel_' + ch + '_\"]').remove();
	$.each(incoming, function (i, src) {
		if (studioAudio.channels[src] && typeof studioRebuildOutputs === 'function') { studioRebuildOutputs(src); }
	});
	if (own_dest && own_dest !== ch && studioAudio.channels[own_dest]) {
		var own_input = $('.studio_channel_information[direction="input"][channel="' + own_dest + '"]');
		if (isJson(own_input.text())) {
			try {
				var own_info = JSON.parse(own_input.text());
				if (own_info['type'] === 'channel' && String(own_info['sid']) === ch) { own_input.text(''); }
			} catch (e) {}
		}
		if (typeof studioInputStreamGrabber === 'function') { studioInputStreamGrabber(own_dest, 'off'); }
	}
	if (String(studioSelectedChannel) == ch) {
		var left = studioTrackNumbers();
		studioSelectedChannel = left.length ? left[0] : 0;
	}
	// The channel is gone, so a solo it held is gone with it: the remaining
	// strips must not stay dimmed behind a solo that no longer exists.
	if (typeof studioStripMuteSoloRender === 'function') { studioStripMuteSoloRender(); }
	studioTakesChanged();
	studioUpdateTrackCount();
	if (typeof studioUpdatePedalLamps === 'function') { studioUpdatePedalLamps(); }
	// the sheet was showing the removed track's chain, so it draws the new one
	if (typeof studioRackRender === 'function') { studioRackRender(studioSelectedChannel); }
	if (!quiet) {
		studioSaveTrackCount();
		studioSaver();
	}
}

$(document).on('click', '#studio_add_track', function () { studioAddTrack(); });

$(document).on('click', '.studio_track_delete', function () {
	var button = $(this);
	if (button.attr('armed') != 'yes') {
		button.attr('armed', 'yes').css({ 'background-color': 'red' });
		clearTimeout(button.data('studioDeleteTimer'));
		button.data('studioDeleteTimer', setTimeout(function () {
			button.attr('armed', 'no').css({ 'background-color': '' });
		}, 2000));
		return;
	}
	studioRemoveTrack(button.attr('channel'));
});

$(document).on('change', '.studio_track_name', function () {
	var ch = $(this).attr('channel');
	if (!/^[0-9]+$/.test(ch)) { return; }
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].name = $(this).val();
	studioSaver();
});

$(document).on('click', '.studio_track_automation', function () {
	var button = $(this);
	var ch = button.attr('channel');
	var on = button.attr('aria-pressed') != 'true';
	button.attr('aria-pressed', on ? 'true' : 'false');
	$('#studio_track_row_' + ch).toggleClass('studio_track_automation_on', on);
	if (!mixer[ch]) { mixer[ch] = {}; }
	mixer[ch].automation_view = on ? 1 : 0;
	studioSaver();
});

$(document).on('click', '.studio_track_fx', function () {
	var ch = $(this).attr('channel');
	// FX selects this track and opens the pedalboard, which is the one place a
	// chain is drawn. The panel keeps its fixed height whatever is in the chain.
	studioSelectedChannel = ch;
	$('.channel, .studio_track_panel').removeClass('selected_channel');
	$('#studio_track_row_' + ch + ' .studio_track_panel').addClass('selected_channel');
	$('#studio_mixer_strips .channel_' + ch).addClass('selected_channel');
	studioRackRender(ch);
	studioPaletteLabel();
	studioPedalboardOpen(true);
});
