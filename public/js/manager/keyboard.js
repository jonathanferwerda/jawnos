/* [[js-split]]
   keyboard.js is part 1. The rest live in keyboard/ in name order:
     01_side_dock.js       - side dock slide, keyboard drag bars, pseudonym home, draggable init, rooms, media
     02_keyboard_maker.js  - keyboardMaker, music receivers, sensitivity, work claims, notifications, initializer
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

// ---- apps on the dock ------------------------------------------------------
// The server renders the dock from the pseudonym list, so an app with no
// pseudonym cannot be one of its faces. The apps a person adds are kept by this
// browser (localStorage family dock_apps, keyed by the app's own name) as
// { hint, src }, and drawn as ordinary .pseudonym.bar tiles beside the server's
// faces: they take a slot in the row or the side stack, shrink with the rest,
// and follow the same on/off and tuck rules. The trade-off is deliberate - the
// dock's app faces, like each icon's on/off, belong to this browser's profile,
// not to the whole house; the pseudonym list itself is the house's.
function jawnosDockApps() {
	var data = (typeof jawnosStore != 'undefined') ? (jawnosStore.read('dock_apps') || {}) : {};
	var list = [];
	$.each(data, function(app, raw) {
		if (!app || raw === undefined || raw === null) { return; }
		var info = raw;
		if (typeof raw == 'string') {
			try { info = JSON.parse(raw) || {}; } catch (e) { info = {}; }
		}
		if (typeof info != 'object') { info = {}; }
		list.push({ app: app, hint: info.hint || app, src: info.src || '' });
	});
	return list;
}
function jawnosDockAppHas(app) {
	if (!app) { return false; }
	var data = (typeof jawnosStore != 'undefined') ? (jawnosStore.read('dock_apps') || {}) : {};
	return Object.prototype.hasOwnProperty.call(data, app);
}
// The dock face the house already ships under this name, if any. An app whose
// name is already a pseudonym is added and removed by flipping that face's
// dock_icons state rather than growing a second, identical face.
function jawnosDockPseudonymFor(name) {
	var found = null;
	if (!name) { return found; }
	$('#pseudonym_bar .pseudonym').not('.dock_app').each(function() {
		var p = $(this);
		if (p.attr('toggle') === name || p.attr('name') === name) { found = p; return false; }
	});
	return found;
}
// Is this name on the dock, whether as a pseudonym face or a browser-added app?
function jawnosDockHas(name) {
	if (jawnosDockAppHas(name)) { return true; }
	var ps = jawnosDockPseudonymFor(name);
	if (ps) { return jawnosDockIconState(ps.attr('toggle')) == 'on'; }
	return false;
}
function jawnosDockAppSave(app, info) {
	if (!app || typeof jawnosStore == 'undefined') { return; }
	info = info || {};
	jawnosStore.set('dock_apps', app, JSON.stringify({ hint: info.hint || app, src: info.src || '' }));
}
function jawnosDockAppAdd(app, hint, src) {
	if (!app) { return; }
	var ps = jawnosDockPseudonymFor(app);
	if (ps) {
		// one face, not two: a pseudonym of the same name wins
		if (typeof jawnosStore != 'undefined') {
			jawnosStore.remove('dock_apps', app);
			jawnosStore.remove('dock_icons', 'app:' + app);
		}
		jawnosDockAppsRender();
		jawnosDockIconSet(ps.attr('toggle'), 'on');
		jawnosDockReveal();
		return;
	}
	jawnosDockAppSave(app, { hint: hint, src: src });
	jawnosDockAppsRender();
	jawnosDockReveal();
}
function jawnosDockAppRemove(app) {
	if (!app) { return; }
	var ps = jawnosDockPseudonymFor(app);
	if (typeof jawnosStore != 'undefined' && jawnosDockAppHas(app)) {
		jawnosStore.remove('dock_apps', app);
		jawnosStore.remove('dock_icons', 'app:' + app);
		jawnosDockAppsRender();
	}
	if (ps) {
		jawnosDockIconSet(ps.attr('toggle'), 'off');
		if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
		return;
	}
	if (typeof pseudonymFreeSpaceFinder == 'function') { pseudonymFreeSpaceFinder(); }
}
function jawnosDockAppToggle(entry) {
	if (!entry || !entry.app) { return; }
	if (jawnosDockHas(entry.app)) { jawnosDockAppRemove(entry.app); }
	else { jawnosDockAppAdd(entry.app, entry.hint, entry.src); }
}
// Draw (or redraw) the browser's own app faces at the end of the row. The
// server's pseudonyms stay where the template put them; these are appended.
function jawnosDockAppsRender() {
	var bar = $('#pseudonym_bar');
	if (!bar.length) { return; }
	bar.children('.draggable_icon.dock_app_wrap').remove();
	$.each(jawnosDockApps(), function(i, entry) {
		var src = entry.src || '/images/decipherable/gear.png';
		var icon = $('<img class="ps bar pseudonym keyboard hover theme_surface dock_app">').attr({
			'id': 'dock_app_' + encodeURIComponent(entry.app) + '_toggle',
			'dock_app': entry.app,
			'name': entry.app,
			'hint': entry.hint || entry.app,
			'toggle': 'app:' + entry.app,
			'src': src,
			'jawnos_icon': src
		});
		icon.css('background-color', 'var(--panel-2)');
		bar.append($('<div class="draggable_icon dock_app_wrap"></div>').append(icon));
	});
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
function jawnosDockMenuOpen(x, y, rows, label) {
	$('.taskbar_context').remove();
	if (!rows || !rows.length) { return; }
	var menu = $('<div class="taskbar_context"></div>');
	if (label) { $('<div class="taskbar_context_label"></div>').text(label).appendTo(menu); }
	$.each(rows, function(i, row) { jawnosDockMenuRow(menu, row); });
	$('body').append(menu);
	var w = menu.outerWidth();
	var h = menu.outerHeight();
	var left = Math.max(4, Math.min(x, $(window).width() - w - 4));
	var top = Math.max(4, Math.min(y, $(window).height() - h - 4));
	menu.css({ left: left + 'px', top: top + 'px' });
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
$(document).on('click', '.taskbar_context_selection[act^="dock_"]', function() {
	var row = $(this);
	var act = row.attr('act');
	if (act == 'dock_app_toggle') {
		jawnosDockAppToggle({ app: row.attr('dock_app'), hint: row.attr('dock_hint'), src: row.attr('dock_src') });
	}
	else if (act == 'dock_app_remove') {
		jawnosDockAppRemove(row.attr('dock_app'));
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
	}
	$('.taskbar_context').remove();
});
// A right-click on a dock face: take it off the dock. An app face is removed
// from this browser's list; a pseudonym face is switched off in dock_icons (the
// server still ships it, and the background menu can bring it back).
$(document).on('contextmenu', '#pseudonym_bar .pseudonym', function(e) {
	e.preventDefault();
	e.stopPropagation();
	var icon = $(this);
	var app = icon.attr('dock_app');
	if (app) {
		jawnosDockMenuOpen(e.clientX, e.clientY, [{
			act: 'dock_app_remove', app: app, icon: icon.attr('src'),
			label: jawnosDockText('dock.remove', 'Remove from dock')
		}], icon.attr('hint') || app);
		return;
	}
	var toggle = icon.attr('toggle');
	if (!toggle) { return; }
	jawnosDockMenuOpen(e.clientX, e.clientY, [{
		act: 'dock_hide_toggle', toggle: toggle, icon: icon.attr('src'),
		label: jawnosDockText('dock.remove', 'Remove from dock')
	}], icon.attr('hint') || toggle);
});
// A right-click on the dock's own background (the pill, or the strip it keeps
// while tucked) lists the faces this browser has switched off, so a removal can
// be undone from the same bar. The search keeps its native menu (paste).
$(document).on('contextmenu', '#pseudonym_home', function(e) {
	if ($(e.target).closest('#search_entanglement, #pseudonym_bar .pseudonym').length) { return; }
	var rows = [];
	$('#pseudonym_bar .pseudonym').each(function() {
		var p = $(this);
		if (p.hasClass('dock_app')) { return; }
		var toggle = p.attr('toggle');
		if (!toggle) { return; }
		if (jawnosDockIconState(toggle) == 'on') { return; }
		rows.push({ act: 'dock_show_toggle', toggle: toggle, icon: p.attr('src'), label: p.attr('hint') || toggle });
	});
	if (!rows.length) { return; }
	e.preventDefault();
	jawnosDockMenuOpen(e.clientX, e.clientY, rows, jawnosDockText('dock.add', 'Add to dock'));
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
	jawnosDockAppsRender();
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
		if (!icons_hidden && jawnosDockIconState(toggle) == 'on') {
			icon.show();
			visible.push(el);
		}
		else {
			icon.hide();
		}
	});
	// the dock keeps at least the remote control in it
	if (!icons_hidden && visible.length == 0 && icons.length > 0) {
		jawnosDockIconSet('remote_control', 'on');
		$.each(icons, function(i,el) {
			if ($(el).attr('toggle') == 'remote_control') {
				$(el).show();
				visible.push(el);
			}
		});
	}
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
