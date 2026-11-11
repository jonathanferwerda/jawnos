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

// ---- the taskbar's pins and widgets on the dock ----------------------------
// The dock draws the same pinned apps and widgets as the taskbar: one list
// (the house's taskbar_order) feeds both bars, so a pin shows on both and a
// removal takes it off both. The taskbar's fixed slots - its window list, the
// clock and the search - are not faces. A keyboard pseudonym keeps its own
// server face; these faces follow the taskbar's order instead of dock_order.
function jawnosDockTaskbarOrder() {
	if (typeof jawnosBars == 'undefined') { return []; }
	if (jawnosBars.order && jawnosBars.order.length) { return jawnosBars.order; }
	return (typeof jawnosTaskbarDefaultOrder == 'function') ? jawnosTaskbarDefaultOrder() : [];
}
function jawnosDockApps() {
	var faces = [];
	$.each(jawnosDockTaskbarOrder(), function(i, item) {
		if (!item || typeof item != 'object') { return; }
		if (item.k == 'pin') {
			if (item.app) { faces.push({ kind: 'app', app: item.app, hint: item.hint || item.app, src: item.src || '' }); }
			else if (item.sel) { faces.push({ kind: 'launcher', sel: item.sel, hint: item.hint || item.sel, src: item.src || '' }); }
		}
		else if (item.k == 'widget' && (item.mode || 'full') != 'off') {
			var spec = (typeof jawnosTaskbarWidgets != 'undefined') ? jawnosTaskbarWidgets[item.w] : null;
			if (spec) { faces.push({ kind: 'widget', widget: item.w, hint: spec.hint, src: spec.icon }); }
		}
	});
	return faces;
}
function jawnosDockAppHas(app) {
	return !!(app && typeof jawnosTaskbarAppPinned == 'function' && jawnosTaskbarAppPinned(app));
}
// Is this name on the dock? The dock's apps and widgets are the taskbar's.
function jawnosDockHas(name) {
	return jawnosDockAppHas(name);
}
function jawnosDockAppAdd(app, hint, src) {
	if (!app || typeof jawnosTaskbarAddAppPin != 'function') { return; }
	jawnosTaskbarAddAppPin({ app: app, hint: hint || app, src: src || '' });
	jawnosDockReveal();
}
function jawnosDockAppRemove(app) {
	if (!app || typeof jawnosTaskbarRemoveAppPin != 'function') { return; }
	jawnosTaskbarRemoveAppPin(app);
	jawnosDockReveal();
}
function jawnosDockAppToggle(entry) {
	if (!entry || !entry.app) { return; }
	if (jawnosDockHas(entry.app)) { jawnosDockAppRemove(entry.app); }
	else { jawnosDockAppAdd(entry.app, entry.hint, entry.src); }
}
// A widget is pinned when the bar carries it; enabling or disabling it is the
// same action on either surface. A press on the dock's widget face opens the
// app that widget stands for.
function jawnosDockWidgetHas(w) {
	return typeof jawnosTaskbarWidgetOn == 'function' && jawnosTaskbarWidgetOn(w);
}
function jawnosDockWidgetToggle(w) {
	if (typeof jawnosTaskbarWidgetToggle == 'function') { jawnosTaskbarWidgetToggle(w); }
	jawnosDockReveal();
}
function jawnosDockWidgetOpen(w) {
	var app = { power: 'power', network: 'network', sound: 'sound', notifications: 'notifications' }[w] || w;
	jawnosDockAppOpen(app);
}
// A browser that added app faces to the dock before the taskbar owned the list
// keeps them: on the first load after this change each becomes a taskbar pin
// (the pin the two bars now share), and the old per-browser list is cleared.
function jawnosDockMigrateApps() {
	if (typeof jawnosStore == 'undefined' || typeof jawnosTaskbarAddAppPin != 'function') { return; }
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
		if (!jawnosDockAppHas(app)) {
			jawnosTaskbarAddAppPin({ app: app, hint: info.hint || app, src: info.src || '' });
		}
	});
	try { localStorage.removeItem('dock_apps'); } catch (e) {}
	jawnosDockAppsRender();
}
// Draw (or redraw) the taskbar's pins and widgets at the end of the row. The
// server's pseudonyms stay where the template put them; these faces follow the
// taskbar's order and dock_order does not move them.
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
	var w = menu.outerWidth();
	var h = menu.outerHeight();
	var left = Math.max(4, Math.min(x, $(window).width() - w - 4));
	var top = Math.max(4, Math.min(y, $(window).height() - h - 4));
	menu.css({ left: left + 'px', top: top + 'px' });
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
// taskbar's pins and widgets are not saved here - they follow the taskbar's
// own order. This is the browser's own list, like each pseudonym's on/off.
function jawnosDockOrderSave() {
	var order = [];
	$('#pseudonym_bar').children('.draggable_icon').not('.dock_taskbar_face').each(function() {
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
		// the taskbar's own faces keep the order the bar gave them
		if ($(w).hasClass('dock_taskbar_face')) { return; }
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
	if (same) { return; }
	$.each(placed, function(i, w) { bar.append(w); });
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
	if ($(target).closest('.dock_taskbar_face').length) { return false; }
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

// The dock's menu. It reuses the taskbar's builder for the bar's own furniture
// (so Edit mode, Position, Clock and Add items never drift apart from the
// taskbar's copy) and lays the dock's rows above it: Edit dock, Dock position,
// Show/Hide icons and an Add items list of the start menu's apps and the faces
// this browser has removed.
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

	context.append('<div class="taskbar_context_selection" act="dock_add">'
		+ jawnosDockText('dock.add_items', 'Add items') + '<span class="taskbar_context_check">▸</span></div>');
	var add = $('<div class="taskbar_context_sub" sub="dock_add" style="display:none;"></div>');
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
		$('#pseudonym_bar .pseudonym').not('.dock_app, .dock_widget, .dock_launcher').each(function() {
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
	// The widgets are the taskbar's four readings, pinned or disabled by the
	// same setting that puts them on the bar.
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
	context.append(add);

	if (typeof jawnosTaskbarContextBuild == 'function') {
		var base = jawnosTaskbarContextBuild();
		context.append($('<div class="taskbar_context_label"></div>').text(jawnosDockText('dock.taskbar', 'Taskbar')));
		context.append(base.children());
	}
	return context;
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
	else if (act == 'dock_add') {
		$('.taskbar_context_sub[sub="dock_add"]').toggle();
		$('.taskbar_context_sub[sub="add"], .taskbar_context_sub[sub="clock"]').hide();
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
		if (typeof jawnosTaskbarWidgetSet == 'function') { jawnosTaskbarWidgetSet(row.attr('dock_widget'), 'off'); }
	}
	else if (act == 'dock_launcher_remove') {
		if (typeof jawnosTaskbarRemovePin == 'function') { jawnosTaskbarRemovePin(row.attr('dock_sel')); }
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
});

// A right-click on a dock face opens the same menu with a Remove row for that
// face at the top: an app or launcher unpins it from the taskbar (and so from
// the dock), a widget is disabled on both bars, and a pseudonym face is switched
// off in dock_icons (the menu can bring it back).
$(document).on('contextmenu', '#pseudonym_bar .pseudonym', function(e) {
	e.preventDefault();
	e.stopPropagation();
	var icon = $(this);
	var app = icon.attr('dock_app');
	var widget = icon.attr('dock_widget');
	var launcher = icon.attr('dock_sel');
	var toggle = (app || widget || launcher) ? null : icon.attr('toggle');
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
		// the taskbar's pins and widgets are shown whenever the bar carries
		// them; their dock_icons entry is not a second switch
		var taskbar_face = icon.hasClass('dock_app') || icon.hasClass('dock_widget') || icon.hasClass('dock_launcher');
		if (!icons_hidden && (taskbar_face || jawnosDockIconState(toggle) == 'on')) {
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
