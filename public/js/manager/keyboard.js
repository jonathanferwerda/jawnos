/* [[js-split]]
   keyboard.js is part 1. The rest live in keyboard/ in name order:
     01_side_dock.js       - side dock slide, keyboard drag bars, pseudonym home, draggable init, rooms, media
     02_music_and_handlers.js - music receivers, sensitivity, work claims, initializer
     03_editor_switcher.js - text editor upgrade, magic/processor, marker shortcut, key bindings, app switcher, VPN
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var timestamp = Date.now();
var calculateInterval = 0;
var pseudonyms = {};
var pseudonymIntervals = Date.now() - 4000;
var keyboardIntervals = Date.now() - 5000;
var pseudonymHiderTimeout;
var pseudonymHIntervals = 4000;
var pseudonymHideWait = 5000;
// how much of a tucked dock stays on screen - the strip the mouse rests on to
// call the icons back. The bottom dock keeps its top strip (the search); the
// top one keeps its bottom strip, which is the search too, pushed below the
// row by the CSS. With the search away, only a sliver of the pill stays - just
// enough to hover and call the dock out.
var pseudonymDockReach = 47;
var pseudonymDockSliver = 15;
// The strip a tucked row dock keeps: the search's own row while the input rides
// the dock, the sliver otherwise.
function pseudonymDockStrip() {
	var search_in_dock = $('#search_entanglement').closest('#pseudonym_home').length > 0;
	return search_in_dock ? pseudonymDockReach : pseudonymDockSliver;
}
// how much of a tucked side dock stays on screen - the strip the pointer rests
// on to call the pill back - and the state its slide answers to
var pseudonymSideReach = 20;
var pseudonymSideTucked = 0;
var pseudonymSideLayout = null;

var text_editor = {};
var keysPressed = {};
var appSwitcherSelected = 0;

// The Super/Meta key as the shortcuts below expect it: they track it as
// keysPressed[91]. Chrome and Firefox report keyCode 91 for it, but WebKitGTK --
// the desktop app's embedded view -- reports keyCode 0 with key "Super" and
// never sets metaKey, so the Super shortcuts silently did nothing there. Map it
// to 91 so `keysPressed[91]` works on every engine.
function jawnosKeyCode(e) {
	if (e.keyCode) { return e.keyCode; }
	if (e.key === 'Super' || e.key === 'Meta'
		|| e.code === 'MetaLeft' || e.code === 'MetaRight'
		|| e.code === 'OSLeft' || e.code === 'OSRight') {
		return 91;
	}
	return 0;
}

// Is Super/Meta held right now? e.metaKey is unreliable (WebKitGTK never sets
// it), so fall back to the tracked key state -- keyboard.js's document keydown
// runs before any other handler, so keysPressed[91] is current by the time a
// later handler asks.
function jawnosSuperKey(e) {
	return !!(e.metaKey || keysPressed[91]);
}

// The apps' embedded views expose a way back to their dashboard: the desktop's
// WebKit view a `jawnos` script-message handler, the Android view a `JawnAdmin`
// interface (JawnWebViewActivity). Mark the document so CSS can show the
// admin-console icon only there (a plain browser tab has no dashboard to go
// back to), and expose the press.
$(function () {
	if ((window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.jawnos) || window.JawnAdmin) {
		$('html').addClass('jawnos_webview');
	}
});

function jawnosAdminConsole() {
	try { window.webkit.messageHandlers.jawnos.postMessage('admin_console'); } catch (e) {}
	try { window.JawnAdmin && window.JawnAdmin.open(); } catch (e) {}
}
// The dock at the bottom of the screen: one centred row of pseudonyms. Icons that
// are switched off hide, and the rest share the row, shrinking below their full
// size when there are too many to fit, so the dock never runs off the screen.
//
// An icon's on/off is this browser's own (dock_icons), but the server renders the
// dock with exactly the pseudonyms whose status is 'on', so a name the browser
// has never kept an entry for follows the server and is on. Persisting an absent
// entry as 'on' is what makes that stick; before this, only names a toggle had
// written ever showed, so a fresh browser - or one whose store predates a
// pseudonym - hid most of the row until each was clicked off and on again.
function jawnosDockIconState(toggle) {
	var state = jawnosDockIconGet(toggle);
	if (state === null || state === undefined) {
		state = 'on';
		jawnosDockIconSet(toggle, 'on');
	}
	return state;
}

// ---- the dock's own pins and widgets --------------------------------------
// The dock keeps its own list (the misc setting dock_pins), separate from the
// taskbar's taskbar_order: adding an item here puts a face on the dock and
// nothing on the bar, and removing it takes it off the dock alone. The first
// load after the split copies the taskbar's current pins and enabled widgets
// once, so the dock keeps the faces it was already showing; after that the two
// lists never move each other.
function jawnosDockTaskbarOrder() {
	if (typeof jawnosBars == 'undefined') { return []; }
	if (jawnosBars.order && jawnosBars.order.length) { return jawnosBars.order; }
	return (typeof jawnosTaskbarDefaultOrder == 'function') ? jawnosTaskbarDefaultOrder() : [];
}
// The dock's list, or null when the setting has never been written. An empty
// array is a real answer - the person took every face off - so it is not
// confused with "not set yet".
function jawnosDockPins() {
	var raw = (typeof jawnosBars != 'undefined') ? jawnosBars.dock_pins : null;
	if (raw === undefined || raw === null) { return null; }
	if (Array.isArray(raw)) { return raw; }
	if (typeof raw == 'string') {
		if (!raw.length) { return null; }
		try {
			var parsed = JSON.parse(raw);
			return Array.isArray(parsed) ? parsed : [];
		}
		catch (e) { return []; }
	}
	return [];
}
function jawnosDockPinsEnsure() {
	var pins = jawnosDockPins();
	if (pins !== null) { return pins; }
	// first load with the dock's own list: copy what the dock was showing (the
	// taskbar's pins and its enabled widgets), then let the two lists part ways
	pins = [];
	$.each(jawnosDockTaskbarOrder(), function(i, item) {
		if (!item || typeof item != 'object') { return; }
		if (item.k == 'pin' && item.app) {
			pins.push({ k: 'pin', app: item.app, hint: item.hint || item.app, src: item.src || '' });
		}
		else if (item.k == 'pin' && item.sel) {
			pins.push({ k: 'pin', sel: item.sel, hint: item.hint || item.sel, src: item.src || '' });
		}
		else if (item.k == 'widget' && (item.mode || 'full') != 'off') {
			pins.push({ k: 'widget', w: item.w });
		}
	});
	jawnosDockPinsSave(pins, true);
	return pins;
}
function jawnosDockPinsSave(pins, quiet) {
	if (typeof jawnosBars != 'undefined') { jawnosBars.dock_pins = pins; }
	if (typeof jawnosTaskbarSave == 'function') { jawnosTaskbarSave('dock_pins', JSON.stringify(pins)); }
	if (!quiet) {
		if (typeof jawnosDockAppsRender == 'function') { jawnosDockAppsRender(); }
		if (typeof jawnosDockWindowsRender == 'function') { jawnosDockWindowsRender(); }
		if (typeof jawnosDockReveal == 'function') { jawnosDockReveal(); }
	}
}
function jawnosDockApps() {
	var faces = [];
	$.each(jawnosDockPinsEnsure(), function(i, item) {
		if (!item || typeof item != 'object') { return; }
		if (item.k == 'pin') {
			if (item.app) { faces.push({ kind: 'app', app: item.app, hint: item.hint || item.app, src: item.src || '' }); }
			else if (item.sel) { faces.push({ kind: 'launcher', sel: item.sel, hint: item.hint || item.sel, src: item.src || '' }); }
		}
		else if (item.k == 'widget') {
			var spec = (typeof jawnosTaskbarWidgets != 'undefined') ? jawnosTaskbarWidgets[item.w] : null;
			if (spec) { faces.push({ kind: 'widget', widget: item.w, hint: spec.hint, src: spec.icon }); }
		}
	});
	return faces;
}
function jawnosDockAppHas(app) {
	if (!app) { return false; }
	return jawnosDockPinsEnsure().some(function(item) { return item && item.k == 'pin' && item.app == app; });
}
// Is this name on the dock? Only the dock's own list answers.
function jawnosDockHas(name) {
	return jawnosDockAppHas(name);
}
function jawnosDockAppAdd(app, hint, src) {
	if (!app || jawnosDockAppHas(app)) { return; }
	var pins = jawnosDockPinsEnsure().slice();
	pins.push({ k: 'pin', app: app, hint: hint || app, src: src || '' });
	jawnosDockPinsSave(pins);
}
function jawnosDockAppRemove(app) {
	if (!app) { return; }
	var pins = jawnosDockPinsEnsure().filter(function(item) { return !(item && item.k == 'pin' && item.app == app); });
	jawnosDockPinsSave(pins);
}
function jawnosDockLauncherRemove(sel) {
	if (!sel) { return; }
	var pins = jawnosDockPinsEnsure().filter(function(item) { return !(item && item.k == 'pin' && item.sel == sel && !item.app); });
	jawnosDockPinsSave(pins);
}
function jawnosDockAppToggle(entry) {
	if (!entry || !entry.app) { return; }
	if (jawnosDockHas(entry.app)) { jawnosDockAppRemove(entry.app); }
	else { jawnosDockAppAdd(entry.app, entry.hint, entry.src); }
}
// A widget face on the dock is its own entry too: enabling or disabling it
// here says nothing about the bar's widget. A press opens the app it stands for.
function jawnosDockWidgetHas(w) {
	if (!w) { return false; }
	return jawnosDockPinsEnsure().some(function(item) { return item && item.k == 'widget' && item.w == w; });
}
function jawnosDockWidgetToggle(w) {
	if (!w) { return; }
	var pins = jawnosDockPinsEnsure().slice();
	if (jawnosDockWidgetHas(w)) {
		pins = pins.filter(function(item) { return !(item && item.k == 'widget' && item.w == w); });
	}
	else { pins.push({ k: 'widget', w: w }); }
	jawnosDockPinsSave(pins);
}
function jawnosDockWidgetRemove(w) {
	if (!w) { return; }
	var pins = jawnosDockPinsEnsure().filter(function(item) { return !(item && item.k == 'widget' && item.w == w); });
	jawnosDockPinsSave(pins);
}
function jawnosDockWidgetOpen(w) {
	var app = { power: 'power', network: 'network', sound: 'sound', notifications: 'notifications' }[w] || w;
	jawnosDockAppOpen(app);
}
// A browser that added app faces to the dock before the taskbar owned the list
// keeps them: on the first load after this split each becomes a dock pin (the
// dock's own list), and the old per-browser list is cleared.
function jawnosDockMigrateApps() {
	if (typeof jawnosStore == 'undefined' || typeof jawnosDockAppAdd != 'function') { return; }
	var data = jawnosStore.read('dock_apps') || {};
	var apps = Object.keys(data);
	if (!apps.length) { return; }
	$.each(apps, function(i, app) {
		var raw = data[app];
		var info = raw;
		if (typeof raw == 'string') {
			try { info = JSON.parse(raw) || {}; } catch (e) { info = {}; }
		}
		if (typeof info != 'object' || info === null) { info = {}; }
		if (!jawnosDockAppHas(app)) { jawnosDockAppAdd(app, info.hint || app, info.src || ''); }
	});
	try { localStorage.removeItem('dock_apps'); } catch (e) {}
	jawnosDockAppsRender();
}
// Draw (or redraw) the dock's own pins and widgets at the end of the row. The
// server's pseudonyms stay where the template put them; these faces follow the
// dock's list and dock_order does not move them.
function jawnosDockAppsRender() {
	var bar = $('#pseudonym_bar');
	if (!bar.length) { return; }
	bar.children('.draggable_icon.dock_taskbar_face').remove();
	$.each(jawnosDockApps(), function(i, entry) {
		var src = entry.src || '/images/decipherable/gear.png';
		var icon = $('<img class="ps bar pseudonym keyboard hover theme_surface">').attr({
			'hint': entry.hint || '',
			'src': src,
			'jawnos_icon': src
		});
		if (entry.kind == 'app') {
			icon.addClass('dock_app');
			icon.attr({
				'id': 'dock_app_' + encodeURIComponent(entry.app) + '_toggle',
				'dock_app': entry.app,
				'name': entry.app,
				'toggle': 'app:' + entry.app
			});
		}
		else if (entry.kind == 'widget') {
			icon.addClass('dock_widget');
			icon.attr({
				'id': 'dock_widget_' + encodeURIComponent(entry.widget) + '_toggle',
				'dock_widget': entry.widget,
				'toggle': 'widget:' + entry.widget
			});
		}
		else {
			icon.addClass('dock_launcher');
			icon.attr({
				'id': 'dock_launcher_' + encodeURIComponent(entry.sel) + '_toggle',
				'dock_sel': entry.sel,
				'toggle': 'launch:' + entry.sel
			});
		}
		icon.css('background-color', 'var(--panel-2)');
		bar.append($('<div class="draggable_icon dock_taskbar_face"></div>').append(icon));
	});
	jawnosDockOrderApply();
}
// Call the dock back out after an add: a tucked row or side pill must show the
// new face instead of staying away until the pointer finds the strip again.
function jawnosDockReveal() {
	if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
	if (typeof jawnosSideDock == 'function' && jawnosSideDock()) {
		if (typeof pseudonymSideSettle == 'function') { pseudonymSideSettle(0); }
		return;
	}
	if (typeof jawnosDockTop == 'function' && jawnosDockTop()) {
		$('#pseudonym_home').css({ 'top': (typeof jawnosDockTopOffset == 'function') ? jawnosDockTopOffset() : 0 });
	}
	else {
		$('#pseudonym_home').css({ 'bottom': (typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0 });
	}
	if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
}
// A press on an app face opens its window, or raises/minimises it the way the
// taskbar's own tile does. The app's name is compared as an attribute, never
// pasted into a selector, so a name with a quote is safe.
function jawnosDockAppOpen(app) {
	if (!app) { return; }
	var win = $('.wind').filter(function() { return $(this).attr('app') === app; }).first();
	if (win.length) {
		if (!win.is(':visible') && typeof windowRestorer == 'function') { windowRestorer(Date.now(), app); }
		else if (typeof topWindow == 'function' && typeof windowMinimizer == 'function' && topWindow() == app) { windowMinimizer(Date.now(), app); }
		else if (typeof topLevelNow == 'function') { topLevelNow(win); }
		return;
	}
	if (typeof appWindowOpener == 'function') { appWindowOpener(app, Date.now(), { visible: 'yes' }); }
	else if (typeof deskOpenApp == 'function') { deskOpenApp(app); }
	else if (typeof windowRestorer == 'function') { windowRestorer(Date.now(), app); }
}

// ---- the dock's open windows ----------------------------------------------
// Open windows ride the dock as their own faces beside the pins: one per window
// (or dialog), in the taskbar's own order, so the dock can bring a window back,
// raise it or put it away without reaching for the bar. A window whose app is
// pinned is left to the pin face instead of doubling it.
function jawnosDockFaceAlwaysOn(el) {
	el = $(el);
	return el.hasClass('dock_app') || el.hasClass('dock_widget') || el.hasClass('dock_launcher') || el.hasClass('dock_window');
}
function jawnosDockWindowsOn() {
	return !(typeof jawnosBars != 'undefined' && jawnosBars.dock_windows == 'off');
}
function jawnosDockWindowsSet(state) {
	state = state == 'off' ? 'off' : 'on';
	if (typeof jawnosBars != 'undefined') { jawnosBars.dock_windows = state; }
	if (typeof jawnosTaskbarSave == 'function') { jawnosTaskbarSave('dock_windows', state); }
	jawnosDockWindowsRender();
	jawnosDockReveal();
}
// The window a face stands for, by the same key the taskbar tile uses.
function jawnosDockWindowByKey(key) {
	if (!key) { return $(); }
	var id;
	if (key.indexOf('dialog:') === 0) {
		id = key.slice('dialog:'.length);
		return $('.dialog_box').filter(function() { return $(this).attr('data-dialog-id') === id; }).first();
	}
	if (key.indexOf('terminal:') === 0) {
		id = key.slice('terminal:'.length);
		return $('.wind').filter(function() { return $(this).attr('data-terminal-id') === id; }).first();
	}
	if (key.indexOf('window:') === 0) {
		id = key.slice('window:'.length);
		return $('.wind').filter(function() { return $(this).attr('data-window-id') === id; }).first();
	}
	id = key.indexOf('app:') === 0 ? key.slice('app:'.length) : key;
	return $('.wind').filter(function() { return $(this).attr('app') === id; }).first();
}
// Answering through the bar's own tile keeps one answer for a window: the tile
// already knows about Terminal and Folders ids, dialogs and the loading beat.
function jawnosDockWindowTile(key) {
	var nodes = $('#taskbar_windows .window_toggle');
	if (!nodes.length || !key) { return $(); }
	var id;
	if (key.indexOf('dialog:') === 0) {
		id = key.slice('dialog:'.length);
		return nodes.filter(function() { return $(this).attr('data-dialog-id') === id; }).first();
	}
	if (key.indexOf('terminal:') === 0) {
		id = key.slice('terminal:'.length);
		return nodes.filter(function() { return $(this).attr('data-terminal-id') === id; }).first();
	}
	if (key.indexOf('window:') === 0) {
		id = key.slice('window:'.length);
		return nodes.filter(function() { return $(this).attr('data-window-id') === id; }).first();
	}
	id = key.indexOf('app:') === 0 ? key.slice('app:'.length) : key;
	return nodes.filter(function() {
		var el = $(this);
		return el.attr('app') === id && !el.attr('data-terminal-id') && !el.attr('data-window-id') && !el.attr('data-dialog-id');
	}).first();
}
function jawnosDockWindowPress(icon) {
	if (!icon || !icon.length) { return; }
	var key = icon.attr('dock_window_key') || '';
	var tile = jawnosDockWindowTile(key);
	if (tile.length) { tile.trigger('click'); return; }
	// the bar has not built its list yet: answer directly
	var dialog = icon.attr('dock_window_dialog') || '';
	if (dialog && typeof jawnosDialogToggle == 'function') { jawnosDialogToggle(dialog); return; }
	var app = icon.attr('dock_window_app') || '';
	if (app && app != 'dialog') { jawnosDockAppOpen(app); }
}
// One entry per open window and dialog, in the bar's order, with the pin's own
// face left to speak for a pinned app's single window.
function jawnosDockWindowFaces() {
	var faces = [];
	if (!jawnosDockWindowsOn()) { return faces; }
	var tiles = [];
	$('.wind').each(function(i, v) {
		var el = $(v);
		var app = el.attr('app') || '';
		var key = (typeof jawnosTaskbarWindowKey == 'function') ? jawnosTaskbarWindowKey(v) : ('app:' + app);
		var icon = el.find('.window_icon').first();
		tiles.push({
			key: key,
			seq: (typeof jawnosTaskbarWindowSeq == 'function') ? jawnosTaskbarWindowSeq(v) : i,
			index: i,
			app: app,
			hint: el.find('.name_text').first().text() || app,
			src: icon.attr('src') || '',
			terminal: el.attr('data-terminal-id') || '',
			window: el.attr('data-window-id') || '',
			dialog: ''
		});
	});
	$('.dialog_box').each(function(i, v) {
		var el = $(v);
		if (el.is('[hidden]')) { return; }
		var dialog_id = el.attr('data-dialog-id');
		if (!dialog_id) {
			dialog_id = 'dialog_' + Math.random().toString(36).substring(2);
			el.attr('data-dialog-id', dialog_id);
		}
		tiles.push({
			key: 'dialog:' + dialog_id,
			seq: (typeof jawnosTaskbarWindowSeq == 'function') ? jawnosTaskbarWindowSeq(v) : 1000 + i,
			index: 1000 + i,
			app: 'dialog',
			hint: el.attr('data-dialog-title') || el.find('.jawnos_dialog_title, .folders_dialog_title').first().text() || 'Dialog',
			src: el.attr('data-dialog-icon') || '/images/decipherable/windows.png',
			terminal: '',
			window: '',
			dialog: dialog_id
		});
	});
	if (typeof jawnosTaskbarWindowOrderTiles == 'function') { jawnosTaskbarWindowOrderTiles(tiles); }
	// a pinned app's ordinary window is already its pin face, so it is left out
	// of the faces now that the order has been read (the full list had to reach
	// that reader, or the bar's saved window order would drop the pinned ones)
	return $.grep(tiles, function(t) {
		return !(!t.terminal && !t.window && !t.dialog && t.app && jawnosDockAppHas(t.app));
	});
}
var jawnosDockWindowStamp = null;
function jawnosDockWindowsRender() {
	var bar = $('#pseudonym_bar');
	if (!bar.length) { return; }
	var faces = jawnosDockWindowFaces();
	var stamp = $.map(faces, function(f) { return f.key + '\u0001' + f.hint + '\u0001' + f.src; }).join('\u0002');
	if (stamp !== jawnosDockWindowStamp) {
		jawnosDockWindowStamp = stamp;
		bar.children('.dock_window_face').remove();
		$.each(faces, function(i, f) {
			var src = f.src || '/images/decipherable/gear.png';
			var icon = $('<img class="ps bar pseudonym keyboard hover theme_surface dock_window">').attr({
				'hint': f.hint || '',
				'src': src,
				'jawnos_icon': src,
				'id': 'dock_window_' + encodeURIComponent(f.key) + '_toggle',
				'dock_window_key': f.key,
				'dock_window_app': f.app || '',
				'toggle': 'window:' + f.key
			});
			if (f.dialog) { icon.attr('dock_window_dialog', f.dialog); }
			if (f.terminal) { icon.attr('dock_window_terminal', f.terminal); }
			if (f.window) { icon.attr('dock_window_window', f.window); }
			icon.css('background-color', 'var(--panel-2)');
			bar.append($('<div class="draggable_icon dock_window_face"></div>').append(icon));
		});
		jawnosDockOrderApply();
		if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
	}
	jawnosDockWindowsState();
}
function jawnosDockWindowsState() {
	var bar = $('#pseudonym_bar');
	if (!bar.length) { return; }
	var top = null, topz = -1;
	$('.wind:visible, .dialog_box:visible').each(function() {
		var z = parseInt($(this).css('z-index'), 10) || 0;
		if (z >= topz) { topz = z; top = this; }
	});
	bar.children('.dock_window_face, .dock_taskbar_face').each(function() {
		var icon = $(this).children('.pseudonym').first();
		if (!icon.length) { return; }
		var win = icon.hasClass('dock_window')
			? jawnosDockWindowByKey(icon.attr('dock_window_key'))
			: $('.wind').filter(function() { return $(this).attr('app') === icon.attr('dock_app'); }).first();
		if (!win || !win.length) { icon.removeAttr('state'); return; }
		if (!win.is(':visible')) { icon.attr('state', 'minimized'); return; }
		icon.attr('state', win[0] === top ? 'active' : 'open');
	});
}

// ---- the dock's own context menu ------------------------------------------
// One menu for a dock face (remove it), the dock's empty background (add a face
// back) and an app in the start menu or on the taskbar (add it to the dock). It
// borrows the taskbar context menu's classes, so it looks and closes the same
// way; the rows are built when it opens so the labels go through jawnosT.
function jawnosDockText(key, english) {
	if (typeof jawnosT == 'function') {
		var s = jawnosT(key);
		if (s !== key) { return s; }
	}
	return english || key;
}
function jawnosDockMenuRow(menu, opts) {
	var row = $('<div class="taskbar_context_selection"></div>').attr('act', opts.act || '');
	if (opts.app) { row.attr('dock_app', opts.app); }
	if (opts.toggle) { row.attr('dock_toggle', opts.toggle); }
	if (opts.hint) { row.attr('dock_hint', opts.hint); }
	if (opts.src) { row.attr('dock_src', opts.src); }
	if (opts.icon) {
		$('<img class="miniscule_thumb">').attr('src', opts.icon).css({ width: '20px', height: '20px', objectFit: 'contain' }).appendTo(row);
	}
	$('<span></span>').text(opts.label || '').appendTo(row);
	menu.append(row);
	return row;
}
// Put a built menu at the pointer, kept on screen. The dock's larger menu is
// built by jawnosDockContextBuild and arrives here already assembled.
function jawnosDockMenuPlace(menu, x, y) {
	$('.taskbar_context').remove();
	if (!menu || !menu.length) { return; }
	$('body').append(menu);
	menu.addClass('dock_context_menu');
	var vw = $(window).width();
	var vh = $(window).height();
	var w = menu.outerWidth();
	var h = menu.outerHeight();
	var left = Math.max(4, Math.min(x, vw - w - 4));
	var top = Math.max(4, Math.min(y, vh - h - 4));
	// a menu taller than the room below its top scrolls inside that room, so a
	// menu opened at the foot of the screen never runs off it
	menu.css({ left: left + 'px', top: top + 'px', 'max-height': (vh - top - 4) + 'px' });
	// the dock's menus also put themselves away after a spell without a press
	jawnosDockMenuArm();
}
function jawnosDockMenuOpen(x, y, rows, label) {
	if (!rows || !rows.length) { return; }
	var menu = $('<div class="taskbar_context"></div>');
	if (label) { $('<div class="taskbar_context_label"></div>').text(label).appendTo(menu); }
	$.each(rows, function(i, row) { jawnosDockMenuRow(menu, row); });
	jawnosDockMenuPlace(menu, x, y);
}
// The app a start-menu picture opens, if it names one. The taskbar's own table
// of aliases and actions is the authority; without it, a *_toggle class is the
// app's name (a name with no _toggle has no app to add).
function jawnosDockAppForImage(img) {
	if (!img || !img.length) { return null; }
	var id = img.attr('id');
	var app = (typeof jawnosTaskbarAppForToggle == 'function') ? jawnosTaskbarAppForToggle(id) : null;
	if (app) { return app; }
	// Some menu pictures carry no id, only a *_toggle class (measures, market,
	// warehouse, process monitor). Ask the same table about that toggle name so
	// actions (torch, now) still resolve to nothing.
	var classes = String(img.attr('class') || '').split(/\s+/);
	for (var i = 0; i < classes.length; i++) {
		var m = /^(.*)_toggle$/.exec(classes[i]);
		if (!m) { continue; }
		if (typeof jawnosTaskbarAppForToggle == 'function') {
			var known = jawnosTaskbarAppForToggle(classes[i]);
			if (known) { return known; }
		}
		else { return m[1]; }
	}
	return null;
}
function jawnosDockAppMenu(x, y, entry) {
	if (!entry || !entry.app) { return; }
	var on = jawnosDockHas(entry.app);
	jawnosDockMenuOpen(x, y, [{
		act: 'dock_app_toggle',
		app: entry.app,
		hint: entry.hint || entry.app,
		src: entry.src || '',
		icon: entry.src || '',
		label: on ? jawnosDockText('dock.remove', 'Remove from dock') : jawnosDockText('dock.add', 'Add to dock')
	}], entry.hint || entry.app);
}

// ---- dock edit mode, face order and the menu it opens ----------------------
// The dock's faces are the server's pseudonyms plus the apps this browser
// added. Both are wrappers in #pseudonym_bar, so one reorder pass serves them:
// a face's key is its toggle (a pseudonym) or 'app:<name>' (an added app), and
// the order is this browser's own (dock_order).
var jawnosDockDrag = null;

function jawnosDockEditing() {
	return $('#pseudonym_home').hasClass('dock_edit');
}

// Edit dock: the row is dragged to reorder it. The library's per-icon drag
// moves a face anywhere, so it stands down while the dock is being edited and
// comes back when the mode ends; a side dock's slide is untouched by either.
function jawnosDockEdit(on) {
	var home = $('#pseudonym_home');
	if (!home.length) { return; }
	if (typeof on == 'undefined') { on = !jawnosDockEditing(); }
	home.toggleClass('dock_edit', !!on);
	$('.pseudonym').filter('.ui-draggable').each(function() {
		if (on) { $(this).draggable('disable'); }
		else { $(this).draggable('enable'); }
	});
	if (!on) { jawnosDockOrderSave(); }
	jawnosDockReveal();
}

function jawnosDockFaceKey(el) {
	el = $(el);
	var app = el.attr('dock_app');
	if (app) { return 'app:' + app; }
	var toggle = el.attr('toggle');
	if (toggle) { return toggle; }
	return el.attr('id') || '';
}

function jawnosDockOrder() {
	if (typeof jawnosStore == 'undefined') { return []; }
	var raw = jawnosStore.read('dock_order') || {};
	var order = raw.order;
	if (typeof order == 'string') {
		try { order = JSON.parse(order); } catch (e) { order = null; }
	}
	return Array.isArray(order) ? order : [];
}

// Keep the order the wrappers are in now: a pseudonym by its toggle. The
// dock's pinned faces and the open windows are not saved here - they follow
// their own lists. This is the browser's own list, like each pseudonym's
// on/off.
function jawnosDockOrderSave() {
	var order = [];
	$('#pseudonym_bar').children('.draggable_icon').not('.dock_taskbar_face, .dock_window_face').each(function() {
		var icon = $(this).children('.pseudonym.bar').first();
		if (!icon.length) { return; }
		var key = jawnosDockFaceKey(icon);
		if (key) { order.push(key); }
	});
	if (typeof jawnosStore != 'undefined') { jawnosStore.set('dock_order', 'order', JSON.stringify(order)); }
	return order;
}

// Lay the wrappers out in the saved order: the named faces first, in their
// saved order, then any face the store has not seen yet (a new pseudonym, a new
// app) in the order the server or the add list gave it. The DOM is only touched
// when it is actually out of order, so a plain render costs no moves.
function jawnosDockOrderApply() {
	var bar = $('#pseudonym_bar');
	if (!bar.length) { return; }
	var wrappers = bar.children('.draggable_icon').toArray();
	if (!wrappers.length) { return; }
	var saved = jawnosDockOrder();
	var by_key = {};
	$.each(wrappers, function(i, w) {
		// the dock's own faces and the open windows keep the order they came in
		if ($(w).hasClass('dock_taskbar_face') || $(w).hasClass('dock_window_face')) { return; }
		var icon = $(w).children('.pseudonym.bar').first();
		if (!icon.length) { return; }
		var key = jawnosDockFaceKey(icon);
		if (!key || by_key[key]) { return; }
		by_key[key] = w;
	});
	var placed = [];
	$.each(saved, function(i, key) {
		if (by_key[key] && placed.indexOf(by_key[key]) < 0) { placed.push(by_key[key]); }
	});
	$.each(wrappers, function(i, w) {
		if (placed.indexOf(w) < 0) { placed.push(w); }
	});
	var same = placed.length == wrappers.length;
	for (var i = 0; same && i < wrappers.length; i++) {
		if (placed[i] !== wrappers[i]) { same = false; }
	}
	if (!same) { $.each(placed, function(i, w) { bar.append(w); }); }
	// The open windows ride at the end of the row, after the pins, whatever
	// appended them last.
	var windows = bar.children('.dock_window_face').toArray();
	if (windows.length) {
		var tail = bar.children().toArray().slice(-windows.length);
		var at_end = tail.length == windows.length;
		for (var j = 0; at_end && j < windows.length; j++) {
			if (tail[j] !== windows[j]) { at_end = false; }
		}
		if (!at_end) { $.each(windows, function(i, w) { bar.append(w); }); }
	}
}

// Where a dragged face belongs: the first visible face whose centre is past
// the pointer, on the dock's own axis (a row is horizontal, a side dock is
// vertical). The dragged face itself does not count.
function jawnosDockReorderAt(x, y, drag) {
	if (!drag) { return; }
	var bar = $('#pseudonym_bar');
	if (!bar.length) { return; }
	var side = (typeof jawnosSideDock == 'function') && jawnosSideDock();
	var pos = side ? y : x;
	var wrappers = bar.children('.draggable_icon').toArray();
	var self = drag.wrapper[0];
	var target = null;
	$.each(wrappers, function(i, w) {
		if (w === self) { return; }
		var icon = $(w).children('.pseudonym.bar').first();
		if (!icon.length || !icon.is(':visible')) { return; }
		var r = icon[0].getBoundingClientRect();
		if (!(r.width > 0 && r.height > 0)) { return; }
		var mid = side ? (r.top + r.height / 2) : (r.left + r.width / 2);
		if (pos < mid) { target = w; return false; }
	});
	var changed = false;
	if (target) {
		if ($(target).prev()[0] !== self) { $(target).before(self); changed = true; }
	}
	else {
		var after = null;
		for (var j = wrappers.length - 1; j >= 0; j--) {
			var w = wrappers[j];
			if (w === self) { continue; }
			var icon = $(w).children('.pseudonym.bar').first();
			if (!icon.length || !icon.is(':visible')) { continue; }
			var r = icon[0].getBoundingClientRect();
			if (r.width > 0 && r.height > 0) { after = w; break; }
		}
		if (after) {
			if ($(after).next()[0] !== self) { $(after).after(self); changed = true; }
		}
		else { bar.append(self); changed = true; }
	}
	if (changed) {
		drag.dragged = true;
		if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
	}
}

function jawnosDockDragStart(x, y, target) {
	if (!jawnosDockEditing()) { return false; }
	// the taskbar's faces keep the bar's order; Edit dock reorders pseudonyms
	if ($(target).closest('.dock_taskbar_face, .dock_window_face').length) { return false; }
	var icon = $(target).closest('#pseudonym_bar .pseudonym.bar');
	if (!icon.length) { return false; }
	var wrapper = icon.closest('.draggable_icon');
	if (!wrapper.length) { return false; }
	jawnosDockDrag = { wrapper: wrapper, dragged: false };
	$('#pseudonym_home').addClass('dock_dragging');
	return true;
}

function jawnosDockDragMove(x, y) {
	if (!jawnosDockDrag) { return; }
	jawnosDockReorderAt(x, y, jawnosDockDrag);
}

function jawnosDockDragEnd() {
	if (!jawnosDockDrag) { return; }
	jawnosDockDrag = null;
	$('#pseudonym_home').removeClass('dock_dragging');
	jawnosDockOrderSave();
	if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
}

// Bind the reorder drag once. It only answers while Edit dock is on; a press
// outside that mode falls through to the library's own per-icon drag.
function jawnosDockDragBind() {
	if (jawnosDockDragBind.done) { return; }
	jawnosDockDragBind.done = true;
	$(document).on('mousedown', '#pseudonym_home.dock_edit #pseudonym_bar .pseudonym.bar', function(e) {
		if (e.which && e.which != 1) { return; }
		if (!jawnosDockDragStart(e.clientX, e.clientY, this)) { return; }
		e.preventDefault();
	});
	$(document).on('mousemove', function(e) { jawnosDockDragMove(e.clientX, e.clientY); });
	$(document).on('mouseup', function() { jawnosDockDragEnd(); });
	$(document).on('touchstart', '#pseudonym_home.dock_edit #pseudonym_bar .pseudonym.bar', function(e) {
		var t = e.originalEvent.touches && e.originalEvent.touches[0];
		if (!t || !jawnosDockDragStart(t.clientX, t.clientY, this)) { return; }
		e.preventDefault();
	});
	$(document).on('touchmove', function(e) {
		if (!jawnosDockDrag) { return; }
		var t = e.originalEvent.touches && e.originalEvent.touches[0];
		if (!t) { return; }
		jawnosDockDragMove(t.clientX, t.clientY);
		e.preventDefault();
	});
	$(document).on('touchend touchcancel', function() { jawnosDockDragEnd(); });
}

// The dock's position and icons are the same misc settings the configure panel
// writes; the menu writes them through the same route and lays the bars out
// again at once.
function jawnosDockPositionSet(pos) {
	if (!pos) { return; }
	if (typeof jawnosBars != 'undefined') { jawnosBars.dock = pos; }
	if (typeof jawnosTaskbarSave == 'function') { jawnosTaskbarSave('dock_position', pos); }
	if (typeof jawnosBarsApply == 'function') { jawnosBarsApply(); }
	else { jawnosDockReveal(); }
}
function jawnosDockIconsSet(state) {
	state = state == 'hidden' ? 'hidden' : 'shown';
	if (typeof jawnosBars != 'undefined') { jawnosBars.icons = state; }
	if (typeof jawnosTaskbarSave == 'function') { jawnosTaskbarSave('dock_icons', state); }
	if (typeof jawnosBarsApply == 'function') { jawnosBarsApply(); }
	else if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
}
// A see-through dock: the faces and the search keep their own backing, the
// pill's slab steps aside. The class is applied to the live dock at once and
// the value is written away, so a reload comes back the same.
function jawnosDockTransparentSet(state) {
	state = state == 'on' ? 'on' : 'off';
	if (typeof jawnosBars != 'undefined') { jawnosBars.transparent = state; }
	var home = $('#pseudonym_home');
	if (home.length) { home.toggleClass('dock_transparent', state == 'on'); }
	if (typeof jawnosTaskbarSave == 'function') { jawnosTaskbarSave('dock_transparent', state); }
}

// The dock's menu. It holds only the dock's own rows - Edit dock, Dock
// position, Show/Hide icons, Open windows, Transparent and an Add items flyout
// of the start menu's apps, the widgets and the faces this browser has removed.
// The taskbar's menu is its own and stays on the bar.
function jawnosDockContextBuild() {
	var selected = function (on) { return on ? '✓' : ''; };
	var context = $('<div class="taskbar_context"></div>');
	context.append($('<div class="taskbar_context_label"></div>').text(jawnosDockText('dock.title', 'Dock')));
	context.append('<div class="taskbar_context_selection" act="dock_edit">'
		+ jawnosDockText('dock.edit', 'Edit dock')
		+ '<span class="taskbar_context_check">' + selected(jawnosDockEditing()) + '</span></div>');

	context.append($('<div class="taskbar_context_label"></div>').text(jawnosDockText('dock.position', 'Dock position')));
	[['bottom', 'Bottom'], ['top', 'Top'], ['left', 'Left'], ['right', 'Right'], ['hidden', 'Hidden']].forEach(function(pair) {
		var on = (typeof jawnosBars != 'undefined') && jawnosBars.dock == pair[0];
		context.append('<div class="taskbar_context_selection" act="dock_pos" val="' + pair[0] + '">'
			+ jawnosDockText('dock.pos.' + pair[0], pair[1])
			+ '<span class="taskbar_context_check">' + selected(on) + '</span></div>');
	});

	var icons_hidden = (typeof jawnosBars != 'undefined') && jawnosBars.icons == 'hidden';
	context.append('<div class="taskbar_context_selection" act="dock_icons">'
		+ (icons_hidden ? jawnosDockText('dock.show_icons', 'Show icons') : jawnosDockText('dock.hide_icons', 'Hide icons'))
		+ '<span class="taskbar_context_check">' + selected(!icons_hidden) + '</span></div>');

	var windows_on = !(typeof jawnosBars != 'undefined' && jawnosBars.dock_windows == 'off');
	context.append('<div class="taskbar_context_selection" act="dock_windows">'
		+ jawnosDockText('dock.open_windows', 'Open windows')
		+ '<span class="taskbar_context_check">' + selected(windows_on) + '</span></div>');

	var transparent = (typeof jawnosBars != 'undefined') && jawnosBars.transparent == 'on';
	context.append('<div class="taskbar_context_selection" act="dock_transparent">'
		+ jawnosDockText('dock.transparent', 'Transparent')
		+ '<span class="taskbar_context_check">' + selected(transparent) + '</span></div>');

	// Add items is a flyout, not an inline submenu: the menu would otherwise
	// grow off the bottom of a bottom-edge dock. The list is built with the menu
	// (so its rows are ready) but stays detached until the row is pressed.
	context.append('<div class="taskbar_context_selection" act="dock_add">'
		+ jawnosDockText('dock.add_items', 'Add items') + '<span class="taskbar_context_check">▸</span></div>');
	var add = $('<div class="taskbar_context dock_context_menu dock_add_flyout"></div>');
	var list = $('<div class="taskbar_context_apps"></div>').appendTo(add);
	var add_label = function (text) { list.append($('<div class="taskbar_context_label"></div>').text(text)); };
	var add_face = function (app, hint, src, toggle) {
		// not taskbar_context_app: that class belongs to the taskbar's own add
		// list, whose press pins to the taskbar. These rows only answer the dock.
		var row = $('<div class="taskbar_context_selection dock_context_app"></div>');
		if (app) { row.attr('dock_app', app); }
		if (toggle) { row.attr('dock_toggle', toggle); }
		row.attr('dock_hint', hint || app || toggle || '').attr('dock_src', src || '');
		if (src) { $('<img>').attr('src', src).appendTo(row); }
		$('<span></span>').text(hint || app || toggle || '').appendTo(row);
		row.append('<span class="taskbar_context_check">' + selected(app ? jawnosDockHas(app) : false) + '</span>');
		row.attr('act', app ? 'dock_add_app' : 'dock_show_toggle');
		return row;
	};
	// The panels that moved into an app have no keyboard panel left to open, so
	// they are not offered as a face to put back.
	var retired_panels = { keyboard: 1, calculator: 1, notifications: 1, controller: 1, delorean: 1, walkboy: 1, sessions: 1, remote_control: 1 };
	var fill_hidden = function () {
		var rows = [];
		$('#pseudonym_bar .pseudonym').not('.dock_app, .dock_widget, .dock_launcher, .dock_window').each(function() {
			var p = $(this);
			var toggle = p.attr('toggle');
			if (!toggle || retired_panels[toggle] || jawnosDockIconState(toggle) == 'on') { return; }
			rows.push({ hint: p.attr('hint') || toggle, src: p.attr('src') || '', toggle: toggle });
		});
		if (rows.length) {
			add_label(jawnosDockText('dock.removed_faces', 'Removed faces'));
			$.each(rows, function(i, r) { list.append(add_face(null, r.hint, r.src, r.toggle)); });
		}
		return rows.length;
	};
	var fill_apps = function (pins) {
		var rows = [];
		$.each(pins || [], function(i, pin) {
			if (!pin || !pin.app) { return; }
			rows.push(pin);
		});
		if (rows.length) {
			add_label(jawnosDockText('dock.apps', 'Apps'));
			$.each(rows, function(i, pin) { list.append(add_face(pin.app, pin.hint, pin.src, null)); });
		}
		return rows.length;
	};
	// The widgets the dock can carry; each is its own dock entry, not the bar's
	// widget setting. A press on a widget face opens the app it stands for.
	var fill_widgets = function () {
		if (typeof jawnosTaskbarWidgets == 'undefined') { return 0; }
		add_label(jawnosDockText('dock.widgets', 'Widgets'));
		var count = 0;
		Object.keys(jawnosTaskbarWidgets).forEach(function (w) {
			var spec = jawnosTaskbarWidgets[w];
			var row = $('<div class="taskbar_context_selection dock_context_app"></div>');
			row.attr('act', 'dock_widget_toggle').attr('dock_widget', w);
			if (spec.icon) { $('<img>').attr('src', spec.icon).appendTo(row); }
			$('<span></span>').text(jawnosDockText(spec.hint, spec.hint)).appendTo(row);
			row.append('<span class="taskbar_context_check">' + selected(jawnosDockWidgetHas(w)) + '</span>');
			list.append(row);
			count++;
		});
		return count;
	};
	var hidden_count = fill_hidden();
	var live = (typeof jawnosTaskbarAppPins == 'function') ? jawnosTaskbarAppPins() : [];
	if (live.length) {
		if (!fill_apps(live) && !hidden_count) { add_label(jawnosDockText('dock.no_apps', 'No apps found')); }
	}
	else {
		var loading = $('<div class="taskbar_context_label"></div>').text(jawnosDockText('dock.loading', 'Loading apps…')).appendTo(list);
		$.ajax({
			url: '/manager/start_menu', type: 'GET', data: { menu: 'app' },
			success: function (response) {
				loading.remove();
				var root = $('<div>').html(response.html || '');
				var pins = (typeof jawnosTaskbarPinsFrom == 'function') ? jawnosTaskbarPinsFrom(root) : [];
				if (!fill_apps(pins) && !hidden_count) { add_label(jawnosDockText('dock.no_apps', 'No apps found')); }
			},
			error: function () { loading.text(jawnosDockText('dock.load_error', 'Could not load the apps')); }
		});
	}
	fill_widgets();
	// the flyout travels with its menu: the close path removes every
	// .taskbar_context, and the menu keeps the panel to open beside its row
	context.data('dock_add_panel', add);
	return context;
}

// ---- the Add items flyout and the menu's idle timeout ---------------------
// The flyout is its own menu beside the dock's, so a bottom-edge dock never has
// to scroll the parent to reach it. It opens to the right when that edge has
// room, to the left otherwise, and is clamped on screen like its parent.
var jawnosDockMenuTimer = null;
var jawnosDockMenuWait = 8000;

function jawnosDockMenuArm() {
	clearTimeout(jawnosDockMenuTimer);
	jawnosDockMenuTimer = setTimeout(function() { jawnosDockMenuFade(); }, jawnosDockMenuWait);
}
function jawnosDockMenuDisarm() {
	clearTimeout(jawnosDockMenuTimer);
	jawnosDockMenuTimer = null;
}
// The idle timeout closes the dock's menus the way the open animation came in:
// a short fade, then the nodes go. A menu already gone is simply done.
function jawnosDockMenuFade() {
	jawnosDockMenuDisarm();
	var menu = $('.dock_context_menu');
	if (!menu.length) { return; }
	menu.addClass('taskbar_context_closing');
	setTimeout(function() { menu.remove(); }, 140);
}
function jawnosDockFlyoutToggle(row, menu) {
	var panel = menu.data('dock_add_panel');
	if (!panel || !panel.length) { return; }
	$('.dock_add_flyout').not(panel).remove();
	if (panel.parent().length) {
		panel.remove();
		row.find('.taskbar_context_check').text('▸');
		return;
	}
	$('body').append(panel);
	var w = panel.outerWidth();
	var h = panel.outerHeight();
	var vw = $(window).width();
	var vh = $(window).height();
	var m = menu[0].getBoundingClientRect();
	var r = row[0].getBoundingClientRect();
	var gap = 4;
	var right_edge = m.right + gap;
	var left_edge = m.left - w - gap;
	var place_left;
	if (right_edge + w <= vw - 4) { place_left = right_edge; }
	else if (left_edge >= 4) { place_left = left_edge; }
	// neither side holds the whole list: take the roomier side and let the
	// panel's own scroller (and its max-height) do the rest
	else { place_left = ((vw - m.right) >= m.left) ? Math.max(4, vw - w - 4) : 4; }
	var top = Math.max(4, Math.min(r.top, vh - h - 4));
	if (h > vh - 8) { top = 4; }
	panel.css({ left: place_left + 'px', top: top + 'px', 'max-height': (vh - top - 4) + 'px' });
	// the arrow leans the way the panel opened
	row.find('.taskbar_context_check').text(place_left < m.left ? '◂' : '▸');
	jawnosDockMenuArm();
}

$(document).on('click', '.taskbar_context_selection[act^="dock_"]', function() {
	var row = $(this);
	var act = row.attr('act');
	if (act == 'dock_edit') {
		jawnosDockEdit();
	}
	else if (act == 'dock_pos') {
		jawnosDockPositionSet(row.attr('val'));
	}
	else if (act == 'dock_icons') {
		jawnosDockIconsSet((typeof jawnosBars != 'undefined' && jawnosBars.icons == 'hidden') ? 'shown' : 'hidden');
	}
	else if (act == 'dock_windows') {
		jawnosDockWindowsSet((typeof jawnosBars != 'undefined' && jawnosBars.dock_windows != 'off') ? 'off' : 'on');
	}
	else if (act == 'dock_transparent') {
		jawnosDockTransparentSet((typeof jawnosBars != 'undefined' && jawnosBars.transparent == 'on') ? 'off' : 'on');
	}
	else if (act == 'dock_add') {
		jawnosDockFlyoutToggle(row, row.closest('.taskbar_context'));
		return;
	}
	else if (act == 'dock_add_app') {
		var app = row.attr('dock_app');
		if (jawnosDockHas(app)) { jawnosDockAppRemove(app); }
		else { jawnosDockAppAdd(app, row.attr('dock_hint'), row.attr('dock_src')); }
		row.find('.taskbar_context_check').text(jawnosDockHas(app) ? '✓' : '');
		return;
	}
	else if (act == 'dock_app_toggle') {
		jawnosDockAppToggle({ app: row.attr('dock_app'), hint: row.attr('dock_hint'), src: row.attr('dock_src') });
	}
	else if (act == 'dock_app_remove') {
		jawnosDockAppRemove(row.attr('dock_app'));
	}
	else if (act == 'dock_widget_toggle') {
		var w = row.attr('dock_widget');
		jawnosDockWidgetToggle(w);
		row.find('.taskbar_context_check').text(jawnosDockWidgetHas(w) ? '✓' : '');
		return;
	}
	else if (act == 'dock_widget_remove') {
		jawnosDockWidgetRemove(row.attr('dock_widget'));
	}
	else if (act == 'dock_launcher_remove') {
		jawnosDockLauncherRemove(row.attr('dock_sel'));
	}
	else if (act == 'dock_hide_toggle') {
		var toggle = row.attr('dock_toggle');
		if (toggle) {
			jawnosDockIconSet(toggle, 'off');
			if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
		}
	}
	else if (act == 'dock_show_toggle') {
		var show = row.attr('dock_toggle');
		if (show) {
			jawnosDockIconSet(show, 'on');
			jawnosDockReveal();
		}
		row.find('.taskbar_context_check').text('✓');
		return;
	}
	if (typeof jawnosTaskbarContextClose == 'function') { jawnosTaskbarContextClose(); }
	else { $('.taskbar_context').remove(); }
	jawnosDockMenuDisarm();
});

// A pointer or a key inside a dock menu counts as use: the idle timeout starts
// again rather than closing a menu that is being read.
$(document).on('mousemove keydown click', '.dock_context_menu', function() {
	if (jawnosDockMenuTimer) { jawnosDockMenuArm(); }
});

// A right-click on a dock face opens the same menu with a Remove row for that
// face at the top: an app, launcher or widget takes that face off the dock
// alone, and a pseudonym face is switched off in dock_icons (the menu can bring
// it back). A window face has no Remove row - its window is its state.
$(document).on('contextmenu', '#pseudonym_bar .pseudonym', function(e) {
	e.preventDefault();
	e.stopPropagation();
	var icon = $(this);
	var app = icon.attr('dock_app');
	var widget = icon.attr('dock_widget');
	var launcher = icon.attr('dock_sel');
	var window_face = icon.hasClass('dock_window');
	var toggle = (app || widget || launcher || window_face) ? null : icon.attr('toggle');
	var row = null;
	if (app) { row = $('<div class="taskbar_context_selection" act="dock_app_remove"></div>').attr('dock_app', app); }
	else if (widget) { row = $('<div class="taskbar_context_selection" act="dock_widget_remove"></div>').attr('dock_widget', widget); }
	else if (launcher) { row = $('<div class="taskbar_context_selection" act="dock_launcher_remove"></div>').attr('dock_sel', launcher); }
	else if (toggle) { row = $('<div class="taskbar_context_selection" act="dock_hide_toggle"></div>').attr('dock_toggle', toggle); }
	var menu = jawnosDockContextBuild();
	if (row) {
		if (icon.attr('src')) {
			$('<img class="miniscule_thumb">').attr('src', icon.attr('src'))
				.css({ width: '20px', height: '20px', objectFit: 'contain' }).appendTo(row);
		}
		$('<span></span>').text(jawnosDockText('dock.remove', 'Remove from dock')).appendTo(row);
		menu.prepend(row);
		menu.prepend($('<div class="taskbar_context_label"></div>').text(icon.attr('hint') || app || widget || launcher || toggle));
	}
	jawnosDockMenuPlace(menu, e.clientX, e.clientY);
});

// A right-click on the dock's own background (the pill, or the strip it keeps
// while tucked) opens the same menu, so a face removed a moment ago, the dock's
// edge, the icon row and the apps to add are all in one place. The search keeps
// its native menu (paste).
$(document).on('contextmenu', '#pseudonym_home', function(e) {
	if ($(e.target).closest('#search_entanglement, #pseudonym_bar .pseudonym').length) { return; }
	e.preventDefault();
	e.stopPropagation();
	jawnosDockMenuPlace(jawnosDockContextBuild(), e.clientX, e.clientY);
});

// A right-click on an app in the start menu offers the same add/remove. Only a
// picture that names a real app is taken over; the rest keep the browser menu.
$(document).on('contextmenu', '#start_menu .start_menu_main_display img', function(e) {
	var img = $(this);
	var app = jawnosDockAppForImage(img);
	if (!app) { return; }
	e.preventDefault();
	e.stopPropagation();
	jawnosDockAppMenu(e.clientX, e.clientY, { app: app, hint: img.attr('hint') || app, src: img.attr('src') || '' });
});

$(document).ready(function() {
	jawnosDockMigrateApps();
	jawnosDockAppsRender();
	jawnosDockWindowsRender();
	jawnosDockOrderApply();
	jawnosDockDragBind();
	// In Edit dock a press reorders the row; it must not also open the face's
	// panel. The handler sits on the dock itself so it runs before the document's
	// own .pseudonym press.
	var home = $('#pseudonym_home');
	if (home.length) {
		home.on('click', '.pseudonym', function(e) {
			if (!jawnosDockEditing()) { return; }
			e.preventDefault();
			e.stopPropagation();
		});
	}
});

// A hold does what a right-click does on the dock and the start menu's apps.
if (typeof jawnosContextMenuOn == 'function') {
	jawnosContextMenuOn('#pseudonym_home');
	jawnosContextMenuOn('#start_menu .start_menu_main_display');
}

function pseudonymFreeSpaceFinder(type) {
	var w = $(window).width();
	var h = $(window).height();
	var icons = $('#pseudonym_bar .pseudonym.bar').toArray();
	var visible = [];

	// 60px is the comfortable size; past that the icons share what the screen
	// has, down to a floor so they stay recognisable
	var full = 60;
	var floor = 14;
	var gap = 4;
	var home_chrome = 68; // #pseudonym_home padding + border
	var home = $('#pseudonym_home');
	var search_in_dock = $('#search_entanglement').closest('#pseudonym_home').length > 0;
	var dock_top = (typeof jawnosDockTop == 'function') && jawnosDockTop();
	var dock_side = (typeof jawnosSideDock == 'function') && jawnosSideDock();
	var dock_left = (typeof jawnosDockLeft == 'function') && jawnosDockLeft();
	var dock_edge = (typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0;
	var icons_hidden = (typeof jawnosDockIconsHidden == 'function') && jawnosDockIconsHidden();
	var count = Math.max(1, visible.length);

	$.each(icons, function(i,el) {
		var icon = $(el);
		var toggle = icon.attr('toggle');
		// the dock's pins, widgets and open windows are shown whenever the row is;
		// their dock_icons entry is not a second switch
		var always_on = jawnosDockFaceAlwaysOn(icon);
		if (!icons_hidden && (always_on || jawnosDockIconState(toggle) == 'on')) {
			icon.show();
			visible.push(el);
		}
		else {
			icon.hide();
		}
	});
	count = Math.max(1, visible.length);

	// the search's own button: it rides with the input while the search sits in
	// the dock's row, and keeps the foot of the stack on a side dock, where the
	// input panel stays hidden until the button calls it out
	if (search_in_dock && dock_side) {
		if ($('#search_toggle').closest('#search_entanglement').length > 0) { $('#search_toggle').appendTo('#pseudonym_home'); }
	}
	else if (!$('#search_toggle').closest('#search_entanglement').length) {
		$('#search_toggle').insertAfter($('#search'));
	}

	// a toggle left hidden by a side dock's tuck comes back whenever it is not
	// riding a tucked side pill (the slide below hides it again when it is)
	if (!(dock_side && search_in_dock && pseudonymSideTucked)) { $('#search_toggle').show(); }

	if (dock_side) {
		// a side dock stacks its icons: the search button takes a slot at the foot
		// of the stack, and the whole pill is centred between the bars. The stack
		// rides the home's own edge, so it slides out of sight with the home when
		// the dock tucks - only the width and height are the finder's to set, and
		// the edge offsets belong to pseudonymSideSettle() and its reveal
		var edge_top = (typeof jawnosTaskbarEdge == 'function') ? jawnosTaskbarEdge('top') : 0;
		// with the icons switched off only the search takes a slot; nothing at all
		// still holds one, so the pill keeps a shape to tuck from
		var drawn = visible.length;
		var slots = Math.max(1, drawn + (search_in_dock ? 1 : 0));
		var room = h - edge_top - dock_edge - 26;
		var size = Math.floor((room - (gap * (slots - 1))) / slots);
		size = Math.max(floor, Math.min(full, size));
		var stack = (size * slots) + (gap * (slots - 1));
		var start = edge_top + Math.round((h - edge_top - dock_edge - (stack + 26)) / 2) + 13;
		// the pill hugs the edge it lives on, so its own geometry is known here
		// rather than measured - a measurement taken mid-slide would read the
		// tuck, not the layout. The revealed layout it leaves behind is what
		// pseudonymSideSlide() applies the tuck on top of. Its chrome is the 2px
		// border and the 11px padding the side dock wears.
		var home_w = size + 26;
		var home_h = stack + 26;
		var icon_left = dock_left ? 13 : (w - 13 - size);

		$.each(visible, function(i,el) {
			$(el).css({
				'width': size,
				'height': size,
				'left': icon_left,
				'top': start + Math.round(i * (size + gap))
			});
		});
		if (search_in_dock) {
			$('#search_toggle').css({
				'position': 'fixed',
				'width': size,
				'height': size,
				'top': start + Math.round(drawn * (size + gap))
			});
			// the panel waits beside the pill, wherever the pill has slid to
			$('#search_entanglement').css({
				'top': '50%',
				'width': Math.min(320, w - size - 68) + 'px'
			});
		}
		home.css({
			'width': home_w + 'px',
			'height': home_h + 'px',
			'top': (start - 13) + 'px',
			'bottom': 'auto'
		});
		pseudonymSideLayout = {
			left: dock_left,
			search_in_dock: search_in_dock,
			icon_left: icon_left,
			home_w: home_w
		};
		pseudonymSideSlide();
	}
	else {
		// a row dock owns its own edges: the side slide has nothing to hold
		pseudonymSideLayout = null;
		pseudonymSideTucked = 0;
		var lane = Math.min(w - 8, 720) - home_chrome;
		var size = Math.floor((lane - (gap * (count - 1))) / count);
		size = Math.max(floor, Math.min(full, size));
		var total = (size * count) + (gap * (count - 1));
		var start = Math.round((w - total) / 2);
		// a dock on the top edge hangs its row from its own top - riding down with
		// the home when the search strip calls it - and the bottom one keeps its
		// 15px from the edge, raised over the taskbar when the two share the bottom
		var dock_row_top = Math.round(numeral(home.css('top')).value()) + 15;

		$.each(visible, function(i,el) {
			$(el).css({
				'width': size,
				'height': size,
				'left': start + Math.round(i * (size + gap)),
				'top': Math.round(dock_top ? dock_row_top : (h - 15 - size - dock_edge))
			});
		});

		// the home wraps the row, wide enough for the search box at the least, and
		// just tall enough for the search row, the icon row and the air between
		// them - a phone's small icons no longer wear a box with an empty middle.
		// A hidden box measures its children at nothing, so the search row is only
		// read once the home is on screen (it may have been hidden with the icons
		// off a moment ago).
		if (search_in_dock) { home.show(); }
		var search_row = search_in_dock ? Math.round(($('#search_entanglement').outerHeight() || 0) + 6) : 0;
		// the home wraps the row. While the search rides the dock the box keeps
		// room for it (the 320px floor is the search's own); with the search away
		// there is nothing else to hold, so the box just hugs the row - the same
		// 15px of air at its sides as above and below, not a wide strip of backing.
		var home_width = search_in_dock
			? Math.min(Math.min(w - 8, 720), Math.max(total + home_chrome, 320))
			: Math.min(Math.min(w - 8, 720), total + 30);
		home.css({ 'width': home_width + 'px', 'left': Math.round((w - home_width) / 2) + 'px', 'right': 'auto' });
		$('#search_entanglement').css({ 'top': '', 'left': '', 'right': '' });
		// the button comes back to the search's own row: the nudge the row wears,
		// and none of the strip's own placement
		if (search_in_dock) {
			$('#search_toggle').css({ 'position': 'relative', 'top': '-7px', 'left': '', 'width': '', 'height': '' });
		}
		if (dock_top) {
			// the row hangs from the padding, the search below it in the last 47px;
			// with no icon row the search takes the box itself. With the search
			// riding elsewhere there is nothing under the row, so the box wraps it
			// with the same 15px above and below instead of reserving a strip.
			if (icons_hidden) {
				home.css({ 'padding-top': '', 'height': (search_row + 15) + 'px' });
			}
			else if (search_in_dock) {
				home.css({ 'padding-top': (15 + size + 12) + 'px', 'height': (15 + size + 12 + 40) + 'px' });
			}
			else {
				home.css({ 'padding-top': '0px', 'height': (15 + size + 15) + 'px' });
			}
		}
		else {
			// the row hugs its edge 15px up; the search, when it rides the dock,
			// takes the top of the box above the icons. With the search away the box
			// wraps the row evenly - the same 15px above it as below - so the icons
			// sit centred rather than jammed against the top.
			var row_pad = search_in_dock ? 0 : 15;
			home.css({ 'padding-top': '', 'height': Math.min(120, search_row + (icons_hidden ? 0 : size) + 15 + row_pad) + 'px' });
		}
	}

	if (visible.length > 0 || (icons_hidden && search_in_dock)) {
		home.show();
	}
	else {
		home.hide();
	}
	// a home that is tucked away takes its icons with it
	if (numeral(home.css('bottom')).value() < 0) {
		$('.pseudonym').hide();
	}
	// the search: sized by the dock while it rides there in a row, and nudged
	// there to sit level with the icons; the taskbar centres its own items, so a
	// search riding the bar takes that nudge back off - it used to sit high in
	// the bar, the dock's -7px still on it
	if (search_in_dock && !dock_side) {
		$('#search_entanglement').css({'width': '100%'});
		$('#search').css({'width': '80%'});

		$.each(['search','search_toggle'], function(i,v) {
			if ($('#' + v).attr('adjusted_already') != "done") {
				var se = $('#' + v).offset();
				$('#' + v).offset({ top: se.top - 7 });
				$('#' + v).attr('adjusted_already', 'done');
			}
		});
	}
	else if (!search_in_dock) {
		$('#search, #search_toggle').each(function () {
			if ($(this).attr('adjusted_already') != "done") { return; }
			$(this).css({ 'position': '', 'top': '', 'left': '' });
			$(this).removeAttr('adjusted_already');
		});
		// a search that has left the dock leaves the dock's own width and edge
		// offsets behind; the taskbar and the menu lay it out themselves
		$('#search_entanglement').css({ 'width': '', 'left': '', 'right': '', 'top': '' });
	}
}

// A side dock slides between its edge and a tucked-away resting place that
// keeps a strip of the pill on screen - the pointer's perch to call it back.
// The pill, the icons riding it, the search button at the stack's foot and the
// panel that waits beside it travel together. The revealed layout is the
// finder's; this only adds the slide, so a resize mid-tuck still lands right.
