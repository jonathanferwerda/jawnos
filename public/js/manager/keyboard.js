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
function pseudonymSideSlide() {
	if (!pseudonymSideLayout) { return; }
	var L = pseudonymSideLayout;
	var offset = pseudonymSideTucked ? Math.max(0, L.home_w - pseudonymSideReach) : 0;
	var slide = L.left ? -offset : offset;
	if (L.left) {
		$('#pseudonym_home').css({ 'left': -offset + 'px', 'right': 'auto' });
	}
	else {
		$('#pseudonym_home').css({ 'right': -offset + 'px', 'left': 'auto' });
	}
	$('#pseudonym_bar .pseudonym.bar').css({ 'left': (L.icon_left + slide) + 'px' });
	// the tiles slip away with the pill: only the strip stays, and a sliver of
	// tiles along it would be litter. The dock's own on/off rule decides which
	// ones come back, so a switched-off icon stays off.
	$('#pseudonym_bar .pseudonym.bar').each(function () {
		if (pseudonymSideTucked) { $(this).hide(); }
		else if (!(typeof jawnosDockIconsHidden == 'function' && jawnosDockIconsHidden()) && jawnosDockIconState($(this).attr('toggle')) == 'on') { $(this).show(); }
	});
	if (L.search_in_dock) {
		$('#search_toggle').css({ 'left': (L.icon_left + slide) + 'px' });
		if (pseudonymSideTucked) { $('#search_toggle').hide(); }
		else { $('#search_toggle').show(); }
		if (L.left) {
			$('#search_entanglement').css({ 'left': (L.home_w + 8 + slide) + 'px', 'right': 'auto' });
		}
		else {
			$('#search_entanglement').css({ 'right': (L.home_w + 8 - slide) + 'px', 'left': 'auto' });
		}
	}
}

// Tuck a side dock away, or call it back out. An open search keeps the pill
// with it - the panel hangs beside the pill, and tucking the pill out from
// under an input being typed in would send the words away with it.
function pseudonymSideSettle(tucked) {
	if (typeof jawnosSideDock != 'function' || !jawnosSideDock()) { return 0; }
	if (tucked && typeof jawnosSideSearchVisible == 'function' && jawnosSideSearchVisible()) { tucked = 0; }
	pseudonymSideTucked = tucked ? 1 : 0;
	pseudonymSideSlide();
	return 1;
}

// the dock is sized for whichever edge it lives on, so a new screen shape
// means new sizes
$(window).on('resize', function() {
	pseudonymFreeSpaceFinder();
});

$(document).on('click', '.keyboard.bc,.keyboard_tab', function(i) {
	// the bar across the top is a handle, not a claim button
	if ($(i.target).closest('.keyboard_drag_bar').length > 0) { return; }
	var keyboard = $(this);
	var id = i.target.id;
	if ($(this).hasClass('keyboard_tab')) {
		keyboard = $(this).closest('.keyboard');
		var id = keyboard.attr('id');
	}
	keyboardDragEnabler(keyboard,id);
});

// the bar's own X sends the panel away; the pseudonym that called it brings it
// back, and it is the only other way to drag it that goes with it
$(document).on('click', '.keyboard_closer', function(e) {
	e.stopPropagation();
	$(this).closest('.keyboard').hide();
});

function keyboardDragEnabler(k,id,state) {

	if (k.attr('id') != id) { return; }

	if (k.attr('claimed') == 'yes' && state != 'on') {
		k.attr('claimed','no');
	}
	else {
		k.attr('claimed', 'yes');
	}
	keyboardDragBarMaker(k);
}

// A keyboard panel is moved by the thin bar across its top, so the body stays
// free for tapping buttons and typing: a drag only ever starts on the bar. The
// bar carries the panel's close button at its own right end. The bar is added
// once; safe to call again on the same panel.
function keyboardDragBarMaker(k) {
	k = $(k);
	if (k.length == 0) { return; }
	if (k.children('.keyboard_drag_bar').length == 0) {
		k.prepend('<div class="keyboard_drag_bar"><span class="keyboard_closer hover" hint="Close">✕</span></div>');
	}
	if (!k.hasClass('ui-draggable')) {
		k.draggable({
			handle: '.keyboard_drag_bar',
			cancel: '.keyboard_closer',
			start: function(p) {
				var panel = $(this);
				pseudonyms[panel.attr('id')] = Date.now();
				keyboardIntervals = Date.now();
			},
			drag: function(p, ui) {
				keyboardIntervals = Date.now();
				// a floating panel stops at the clothesline, like a window does
				if ($(this).css('position') == 'fixed') {
					ui.position.top = Math.max(panelTopLimit(), ui.position.top);
				}
			},
			stop: function(p) {
				// the computed style is the only record of where the panel sits
				// once it has been moved, so keep the lot (minus the claim border)
				var panel = $(this);
				var id = panel.attr('id');
				if (panel.css('position') == 'fixed') {
					var top = parseFloat(panel.css('top'));
					if (!isNaN(top) && top < panelTopLimit()) {
						panel.css({ 'top': panelTopLimit() + 'px' });
					}
				}
				var css = {};
				var style = panel[0].style;
				$.each(style, function(i,v) {
					if (!v.match('border-left')) {
						css[v] = panel.css(v);
					}
				});
				var jcss = JSON.stringify(css);
				jawnosWindowStyleSet(id, jcss);
				jawnosWindowPlaceSet(id, jcss);
			}
		});
	}
	else {
		k.draggable('enable');
	}
}

// Whether a hit-tested element belongs to the pseudonym dock. A tucked dock
// rides its bars and keys outside #pseudonym_home's own box, so an id-only test
// misses them and the dock slid away from under the pointer.
function jawnosDockElement(el) {
	el = $(el);
	return el.attr('id') == 'pseudonym_home'
		|| el.hasClass('pseudonym')
		|| el.hasClass('keyboard')
		|| el.hasClass('window_toggle')
		|| el.hasClass('manager_search_result')
		|| el.closest('#pseudonym_home').length > 0;
}

function pseudonymHomeShower(x,y,interval) { 
	var was = 0;
	var okay = 1;
	var dock_top = (typeof jawnosDockTop == 'function') && jawnosDockTop();
	var dock_side = (typeof jawnosSideDock == 'function') && jawnosSideDock();
	var elements = document.elementsFromPoint(x, y);

	if (interval) {
		pseudonymHIntervals = interval;
		was++;
		okay = 1;
	}
	else if (!windowPhoneChecker()) {
		pseudonymHIntervals = 100;
	}
	else {
		pseudonymHIntervals = 4000;
	}
	if (!interval) {
		$.each(elements, function(i,v) {
			if (jawnosDockElement(v)) {
				was++;
			}
			if ($(v).attr('id') == 'search' || $(v).attr('id') == 'search_toggle' || $(v).attr('id') == 'manager_search_results') {
				okay = 0;
			}

		});
	}
	var t = $('#pseudonym_home').offset();

	if (t && okay == 1) {
		var w = $('#pseudonym_home').width();
		var h = $('#pseudonym_home').height();
		var wh = $(window).height();
		if (was > 0) {
			// a side dock slides straight back out over its strip
			if (dock_side) {
				pseudonymSideSettle(0);
				pseudonymIntervals = Date.now();
			}
			// a dock on the top edge answers by slipping its row back down over
			// the search strip; the row rides the home's top, so moving the home
			// is all it takes
			else if (dock_top) {
				$('#pseudonym_home').css({ 'top': jawnosDockTopOffset() });
				pseudonymFreeSpaceFinder();
				var so = $('#search').offset();
				$('#search_results').css({ 'top': Math.round(so.top + $('#search').outerHeight() + 8), 'bottom': 'auto' });
				pseudonymIntervals = Date.now();
			}
			else {
				$('.pseudonym.bar').each(function() {
					var kbg = $(this);
					var bottom = kbg.css('bottom');
					var toggle = kbg.attr('toggle');
					var diff = (0 - (h * .9));
					var d = Number(numeral(bottom).format());
					var diff_body = diff + d;

					var diffplus =  Math.abs( d ) + Math.abs( diff );
					if (diffplus == 80 && bottom != 80) {
						if (was > 0) {
							kbg.css({'bottom': diffplus });

						}
					}
					var ls = jawnosDockIconState(toggle);
					if (ls == 'on' && !(typeof jawnosDockIconsHidden == 'function' && jawnosDockIconsHidden())) {
						$('.pseudonym.keyboard[toggle="' + toggle + '"]').show();
					}
					else if (kbg.hasClass('window_toggle')) {
						kbg.show();
					}
				});
				$('#pseudonym_home').css({ 'bottom': ((typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0) });
				var o = $('#search').offset();
				$('#search_results').css({ 'bottom': $(window).height() - o.top });
				pseudonymIntervals = Date.now();
			}
		}
		else if (Date.now() >= pseudonymIntervals + pseudonymHIntervals && !interval) {
			pseudonymHomeHider(pseudonymHIntervals);
		}

		pseudonymHiderTimeout = setTimeout(function() {
			console.log('clearing');
			if (Date.now() >= pseudonymIntervals + pseudonymHIntervals) {
				pseudonymHomeHider(pseudonymHIntervals);
			}
		},pseudonymHIntervals)
	}
}


// The top dock's resting place: the home slips up until only its search strip
// stays on screen, and the icon row rides above the visible edge with it. That
// strip is where the mouse rests to call the row back down. Answers 0 for any
// other edge, so the caller knows to size the dock the plain way instead.
function pseudonymHomeTopSettle() {
	if (typeof jawnosDockTop != 'function' || !jawnosDockTop()) { return 0; }
	var home = $('#pseudonym_home');
	// size the box for the top edge first - its height is what the tuck reaches
	// past - then tuck it and let the row ride up with it. The strip it keeps is
	// the search's row, or the sliver when the search rides elsewhere.
	pseudonymFreeSpaceFinder();
	home.css({ 'top': jawnosDockTopOffset() + Math.min(0, pseudonymDockStrip() - home.outerHeight()) });
	pseudonymFreeSpaceFinder();
	return 1;
}

function pseudonymHomeHider(interval) {
	// both edges tuck away: the bottom slips down keeping the search and a strip
	// beneath it on screen, the top slips up keeping its search strip on screen
	// with the icon row above the visible edge. A hidden dock is already gone.
	if (typeof jawnosDockHidden == 'function' && jawnosDockHidden()) { return; }
	var dock_top = (typeof jawnosDockTop == 'function') && jawnosDockTop();
	var dock_side = (typeof jawnosSideDock == 'function') && jawnosSideDock();
	pseudonymFreeSpaceFinder();
	var m = mouse_position();
	// a desk whose mouse has never moved has no position yet; it counts as away
	// from the dock rather than crashing elementsFromPoint on a non-finite
	var was = 0;
	if (isFinite(m.x) && isFinite(m.y)) {
		var elements = document.elementsFromPoint(m.x, m.y);
		$.each(elements, function(i,v) {
			if (jawnosDockElement(v)) {
				was++;
			}
		});
	}

	interval = interval || pseudonymHIntervals;
	if (Date.now() >= pseudonymIntervals + interval && was == 0) {
		if (dock_side) {
			// the pill slips off its own edge, keeping the strip the pointer rests
			// on to call it back
			pseudonymSideSettle(1);
		}
		else if (dock_top) {
			pseudonymHomeTopSettle();
		}
		else {
			// tuck the dock down, but keep the search and a strip beneath it on
			// screen: that strip is where the mouse rests to call the icons back. A
			// taskbar sharing the bottom edge takes its height first, so the strip
			// rests above the bar instead of lying across it.
			var h = $('#pseudonym_home').outerHeight();
			var edge = (typeof jawnosDockBottomOffset == 'function') ? jawnosDockBottomOffset() : 0;
			var diff = Math.min(0, pseudonymDockStrip() - h) + edge;
			$('#pseudonym_home').css({ 'bottom': diff });
			$('.pseudonym.bar').hide();
			$('.keyboard').each(function() {
				var kbg = $(this);
				var bottom = kbg.css('bottom');
				var d = Number(numeral(bottom).format());
				var diff_body = diff + d;

				if (d == 80) {
					kbg.css({'bottom': diff_body });
				}
				var o = $('#search').offset();
				$('#search_results').css({ 'bottom': $(window).height() - o.top });
			});
		}
	}
	else {
		// the pointer is on the dock: push the hide back instead of hiding
		pseudonymIntervals = Date.now();
	}
}

function pseudonymDraggableInitializer() {
  $( ".pseudonym" ).draggable({
    start: function(p) {
			var id = p.target.id;
			var timestamp = Date.now();
			pseudonyms[p.target.id] = timestamp;
			pseudonymIntervals = Date.now();
    },
    drag: function(p) {
			pseudonymIntervals = Date.now();
			var d = mouse_position();
			pseudonymIntervals = Date.now();
			pseudonymHomeShower(d.x,d.y,5000);
			console.log('dragging');
    },
    stop: function(p) {
			var d = {
				top: p.originalEvent.target.offsetTop,
				left: p.originalEvent.target.offsetLeft
			}
			var data = JSON.stringify(d);
			jawnosWindowPlaceSet(p.target.id, data);

			pseudonymIntervals = Date.now();

			setTimeout(function() {
				if (Date.now() >= pseudonymIntervals + pseudonymHideWait) {
					pseudonymFreeSpaceFinder();
				}
			}, pseudonymHideWait);
			setTimeout(function() {
				pseudonymHomeHider(pseudonymHIntervals);
			}, pseudonymHIntervals);
    }

  });
}

$(document).ready(function() {
	mouse_position();
	setTimeout(function() {
		pseudonymHomeHider(pseudonymHIntervals);
	}, 10);
	pseudonymDraggableInitializer();
});


$(document).on('click', '.wind,.background', function() {
	$('.keyboard.bc').each(function() {
		var it = $(this);
		var toggle = it.attr('id');
		if (it.is(':visible') && it.attr('claimed') != 'yes') {
			it.hide();
			if (toggle == 'remote_control') {
				$('#search').val('');
			}
		}
	});
});

$(document).on('click','#room_check,#windshield_wiper,#drawing_check', function() {
	var id = $(this).attr('id');
	var value = $(this).prop('checked');
	localStorage.setItem(id,value);

});

$(document).on('click', '.past_life,.life_direction', function() {
	// the view's own timestamp stands in for whatever the pressed line does not
	// carry; the whole payload it used to be fished out of is not kept any more
	var timestamp = $(this).attr('timestamp') || sessionStorage.getItem('appts_timestamp');

	var direction = $(this).attr('direction');
	var room_check = $('#room_check').is(':checked');
	var drawing_check = $('#drawing_check').is(':checked');
	var start_menu = $(this).attr('start_menu');
	$.ajax({
		url: '/manager/past_life_recall',
		type: 'GET',
		data: { timestamp: timestamp, direction: direction, room_check: room_check, drawing_check: drawing_check },
		success:function(response) {
			var json = JSON.stringify(response);
			if (start_menu != 'yes') {
				timestamp = response.timestamp;
				$('#time_machine').val(quality_inventory(response.timestamp));
				localStorage.setItem('time_machine', quality_inventory(response.timestamp));
			}


			$('#life').html(response.appt_count);
			$('#room_name').val(response.room || '');
			$('#room_name').attr('timestamp', response.timestamp);
			$('#room_name').attr('browser_tab_id', response.browser_tab_id);
			$('#playbook').html(response.playbook);
			if (response['portfolio'] && response['portfolio'].length > 0) {
				$.each(response['portfolio'], function(i,v) {
					$('#playbook').append('<img class="medium_thumb" id="' + v.uuid + '_thumb">');
					document.getElementById(v.uuid + '_thumb').src = '/file_open?file=' + v.f + '&server_time=' + v.server_time;
				});

			}
			$('.past_life,.life_direction').attr('timestamp', response.timestamp );
			if ($('#windshield_wiper').is(':checked') || start_menu == 'yes' ){ $('.wind').each(function(i,v) { var ts = $(v).attr('timestamp'); closeWindow(ts)}); }
			if (direction == 'load') {
				manager_play(response);
			}
			windowSaver();
		}
	});
});



$(document).on('click', '.media_picker', function() {
	var mp = $(this);
	var type = mp.attr('type');
	var kind = mp.attr('kind');
	var device_id = mp.attr('device_id');
	var selected = jawnosDevicePickGet(kind, device_id);

	$('.media_picker[kind="' + kind + '"]').each(function(i,v) {
		$(v).attr('status', 'off');
		var d = $(v).attr('device_id');
		jawnosDevicePickSet(kind, d, 'off');

	});
	if (selected == 'off') {
		selected = 'on';
		if (kind == 'speaker') {
			document.getElementById('video').setSinkId(device_id);
		}
	}
	else {
		selected = 'off';
	}
	mp.attr('status',selected);
	jawnosDevicePickSet(kind, device_id, selected);
});


function manager_play(response) {
	windowRetriever(response['json_windows']);
	//bti = response['browser_tab_id'];
	//sessionStorage.setItem('browser_tab_id', bti);
	var timestamp = Date.now();
	var time = timestamp - response.timestamp;

	var zone = quality_inventory(response.timestamp);

	portfolioMaker(response['portfolio']);
	sessionStorage.setItem('time_machine', zone);
	$('#time_machine').val(zone);	
}

$(document).on('click', '#new_room', function() {
	var app = $('#room_name').text();
	var timestamp = sessionStorage.getItem('appts_timestamp');
	$.ajax({
		url: '/manager/new_room',
		type: 'POST',
		data: { app: app, timestamp: timestamp },
		success: function(response) {
			$('#room_name').val(response['room_name']);
			bti = response['browser_tab_id'];
			sessionStorage.setItem('browser_tab_id', bti);
			websocketStop();
			websocketStart();
		}
	});
});

$(document).on('click','#delete room', function(){
	var timestamp = $(this).attr('timestamp');

});

$(document).on('change', '#room_name', function() {
	var room_name = $(this).val();
	var timestamp = $(this).attr('timestamp');
	var browser_tab_id = $(this).attr('browser_tab_id');
	$.ajax({
		url: 'manager/room_namer',
		type: 'POST',
		data: { browser_tab_id: browser_tab_id, timestamp: timestamp, room_name: room_name },
		success: function(response) {
			$('#room_name').val(response['room_name']);
			websocketStop();
			websocketStart();
		}
	});
});

async function keyboardMaker(data) {
	var toggle = data['toggle'];
	var state = data['state'];
	var remote_uuid = data['remote_uuid'];
	var timestamp = Date.now();
	var pseudonym = $('#' + toggle + '_toggle');
	if (!toggle) {
		return;
	}
	var t = $('#' + toggle);
	var h = $(window).height();
	var w = $(window).width();
	var o = pseudonym.offset();
	var d = Number(numeral(pseudonym.width()).format()) * 1.07;
	var bottom = h - o.top;

	var av = [];
	try {
		if (navigator.mediaDevices && navigator.mediaDevices.enumerateDevices) {
			av = await navigator.mediaDevices.enumerateDevices();
		}
	}
	catch (e) { av = []; }
	var avData = JSON.stringify(av);

	if (toggle == 'walkboy') {
		var seen = 0;
		$.each(av, function(i,v) {
			if (v.deviceId != '') {
				seen++;
			}
		});

		if (seen == 0) {
			permissionAsker('media');
			return;
		}
	}
	// Where the panel was left. Its own drag bar keeps the whole spot (the style
	// dump the bar's stop writes); a panel never moved falls back to the place its
	// dock icon was dropped in, or to its default against the dock. The panel's own
	// spot wins, because that is the one a person moves.
	var css = null;
	var kept_style = jawnosWindowStyleGet(toggle);
	if (kept_style) {
		try { css = JSON.parse(kept_style); } catch (e) { css = null; }
	}
	if (css == null) {
		var pos = jawnosWindowPlaceGet(toggle + '_toggle');
		if (pos) {
			var ps = JSON.parse(pos);
			var top = ps.top + 60;
			var left = ps.left;
			css = { 'position': 'fixed', 'top': top, 'left': left };
			if (bottom < h / 4) {
				delete css['top'];
				css['bottom'] = 20;
				css['height'] = $('#' + toggle).height();
				css['width'] = $('#pseudonym_home').width();
				css['left'] = $('#pseudonym_home').offset().left;
			}
			else {
				css['height'] = $('#' + toggle).height();
				var jcss = JSON.stringify(css);
				jawnosWindowStyleSet(toggle, jcss);
				jawnosWindowPlaceSet(toggle, jcss);
			}
		}
	}
	if (css) {
		// A panel restored from its saved spot can be above the clothesline; the
		// drag clamps a moved one, so clamp the first paint too.
		if (css.position == 'fixed' && css.top != null) {
			var top = parseFloat(css.top);
			if (isFinite(top) && top < panelTopLimit()) { css.top = panelTopLimit() + 'px'; }
		}
		$('#' + toggle).css(css);
	}
	if (!t.is(':visible') && !t.hasClass('keyboard') || state == 'on') {
		var data = {
			timestamp: timestamp,
			toggle: toggle,
			avData: avData,
			browser_tab_id: bti,
			remote_uuid: remote_uuid
		};

		$.ajax({ 
			url: '/manager/keyboard',
			type: 'POST',
			data: data,
			success: function(response) {
				$('#' + toggle).remove();
				if (typeof response.keyboard === 'string') { $('#keyboard_container').append(response.keyboard); }
				if (toggle == 'remote_control') {
					// keep the picker on the machine that was just chosen, and take
					// the Manager button with it (the setting POST can land after this
					// render, so the server's selected option may still be the old one)
					if (typeof remote_uuid === 'string') { $('#remote_control_machine_select').val(remote_uuid); }
					keyboardManagerButton();
					jawnosVpnRefresh();
					if (typeof jawnosPublicIpRefresh == 'function') { jawnosPublicIpRefresh(); }
					if (typeof jawnosRemoteInputInit == 'function') { jawnosRemoteInputInit(); }
				}


				var t = $('#' + toggle);
				t.show();
				$('.typewriter').show();
				$('#time_machine').val(localStorage.getItem('time_machine')	);
				initializer();
				// a re-rendered panel starts on the markup's idle text; ask once
				musicReceiverRefresh();
				if (css) {
					css['width'] = t.width();
					t.css(css);
				}
				t.attr('claimed', 'yes');
				keyboardDragBarMaker(t);
			}
		});
	}
	else if (!t.is(':visible')) {
		$('#' + toggle).show();
		$('#' + toggle).css(css);
		$('#' + toggle).attr('claimed', 'yes');
		keyboardDragBarMaker($('#' + toggle));
	}
	else if (state != 'on') {
		$('#' + toggle).parent().remove();
		if (toggle == 'remote_control') {
			$('#search').val('');
			if (typeof jawnosRemoteInputStop == 'function') { jawnosRemoteInputStop(); }
		}
	}
	var togglerInterval = setInterval(function() {
		var l = $('#' + toggle).offset();
		if (l != undefined) {
			setTimeout(function() {
				clearInterval(togglerInterval);
				// nothing was kept to clamp: the panel is wearing its own CSS default
				if (!css) { return; }
				var wow = l.left;
				var toggle_width = $('#' + toggle).width();
				var wow_right = wow + toggle_width;

				if (wow_right >= w) {

					css['left'] = w - toggle_width;
					css['width'] = toggle_width;
				//	css['max-width'] = "100%";
					delete css['right'];
				}
				else if (wow <= 0) {

					css['left'] = 0;
					css['width'] = toggle_width;
				//	css['max-width'] = "100%";
					delete css['right'];
				}
				$('.media_picker').each(function(i,v) {
					var kind = $(v).attr('kind');
					var deviceId = $(v).attr('device_id');
					var status = 'off';


						var input = jawnosDevicePickGet(kind, deviceId);

						if (input == 'on') { status = 'on' }
						$(v).attr('selected','selected');
				});
				$('#' + toggle).css(css);
			},1);
		}
	},100);
}

// Music sent here by another machine is played by the receiver with `play`:
// there is no window and no player to press, only the two markers the receiver
// leaves. The keyboard's strip reports what is arriving, stops it, and can
// refuse further transmissions to this machine.
function musicReceiverText(words) {
	return (typeof jawnosT === 'function') ? jawnosT(words) : words;
}
function musicReceiverDraw(state) {
	var boxes = $('.music_receiver_control');
	if (!boxes.length) { return; }
	var file = (state && state.file) ? String(state.file).split('/').pop() : '';
	var playing = !!(state && state.playing);
	var blocked = !!(state && state.blocked);
	boxes.each(function () {
		var box = $(this);
		var title = box.find('.music_receiver_title');
		if (playing) {
			title.text(musicReceiverText('Receiving') + (file ? ': ' + file : ''));
		}
		else if (blocked) {
			title.text(musicReceiverText('Music from other devices is off'));
		}
		else {
			title.text(musicReceiverText('No music is playing here'));
		}
		box.attr('status', playing ? 'playing' : (blocked ? 'blocked' : 'idle'));
		box.find('.music_receiver_stop').css({ 'display': playing ? '' : 'none' });
		box.find('.music_receiver_block').prop('checked', blocked);
	});
}
function musicReceiverRefresh() {
	if (!$('.music_receiver_control:visible').length) { return; }
	$.ajax({
		url: '/manager/music/receiver',
		type: 'GET',
		dataType: 'json',
		success: musicReceiverDraw
	});
}
$(document).on('click', '.music_receiver_stop', function() {
	var button = $(this);
	button.prop('disabled', true);
	$.post('/manager/music/receiver/stop', {}, function (state) {
		button.prop('disabled', false);
		musicReceiverDraw(state);
	});
});
$(document).on('change', '.music_receiver_block', function() {
	$.post('/manager/music/receiver/block', { blocked: $(this).is(':checked') ? 'on' : 'off' }, musicReceiverDraw);
});
setInterval(musicReceiverRefresh, 5000);

// The Go button follows the machine picker at once, rather than waiting for
// the setting POST and the next render.
function keyboardManagerButton(select) {
	var s = select ? $(select) : $('#remote_control_machine_select');
	var picked = s.find('option:selected');
	var buttons = $('#remote_control_go');
	if (!buttons.length) { return; }
	if (!picked.length || !picked.val()) {
		buttons.hide().removeAttr('uuid').removeAttr('manager');
		return;
	}
	buttons.attr('uuid', picked.val()).attr('manager', picked.attr('manager') || '').show();
}

function keyboardConfigToggle(toggle) {
	var keyboard = $('#' + toggle);
	var config = $('.keyboard_config[toggle="' + toggle + '"]')
	var remote_uuid = config.attr('remote_uuid');

	var content = keyboard.find('.keyboard_content');
	if (config.is(':visible')) {
		config.hide();
		content.show();
	}
	else {
		content.hide();

		$.ajax({
			url: '/manager/keyboard/config',
			type: 'GET',
			data: { toggle: toggle, remote_uuid: remote_uuid },
			success: function(response) {

				config.html(response.html);
				config.show();
			}
		});
	}
}

// The delorean's config: the two sensitivities ride on the globals the timeline
// and the clothesline actually read, so a change is felt at once, and each is
// kept on the server per device (settingSetter sends no device, which is how
// the server reads it as this one).
var keyboard_sensitivity_setter;
$(document).on('input', '.keyboard_sensitivity', function() {
	var slider = $(this);
	var setting = slider.attr('setting');
	var value = numeral(slider.val()).value();
	$('.keyboard_sensitivity_viewer[setting="' + setting + '"]').text(value);
	if (typeof keyboard_sensitivity == 'undefined') { keyboard_sensitivity = {}; }
	if (setting == 'clothesline_sensitivity') {
		clotheslineSensitivity = value;
		keyboard_sensitivity['clothesline'] = value;
	}
	else {
		trackpadSensitivity = value;
		keyboard_sensitivity['trackpad'] = value;
	}
	// one save once the slider settles, not one per step
	clearTimeout(keyboard_sensitivity_setter);
	keyboard_sensitivity_setter = setTimeout(function() {
		settingSetter({ 'app': 'keyboard', 'setting': setting, 'value': value });
	}, 500);
});

$(document).on('change', '#timestamp_in_view', function() {
	var value = $(this).is(':checked') ? 'checked' : 'unchecked';
	settingSetter({ 'app': 'keyboard', 'setting': 'timestamp_in_view', 'value': value });
});

// Ghost appointments: the events the records say will probably happen. The setting
// rides the server (it builds the ghosts into the viewer's payload), so a change
// only has to re-fetch the view.
$(document).on('change', '#ghost_appointments', function() {
	var value = $(this).is(':checked') ? 'checked' : 'unchecked';
	settingSetter({ 'app': 'keyboard', 'setting': 'ghost_appointments', 'value': value });
	if (typeof calculator == 'function') { calculator(); }
});

$(document).on('change', '#clothesline_on', function() {
	var value = $(this).is(':checked') ? 'on' : 'off';
	settingSetter({ 'app': 'misc', 'setting': 'clothesline_on', 'value': value });
	if (typeof clotheslineToggleApply == 'function') { clotheslineToggleApply(value); }
});

// A work claim says which machine is on a job, so two agents do not take the same
// one. It rides the 'claims' app, which the mesh carries to every machine.
$(document).on('click', '.work_claim_take, .work_claim_release', function(e) {
	e.preventDefault();
	var link = $(this);
	var url = link.hasClass('work_claim_release') ? '/manager/work_claim/release' : '/manager/work_claim';
	$.post(url, { task: link.attr('task') }, function () {
		keyboardConfigToggle('delorean');
		keyboardConfigToggle('delorean');
	});
});

$(document).on('click', '.keyboard_base', function() {
	var b = $(this);
	var toggle = b.attr('toggle');
	var p = $('.pseudonym.keyboard[toggle="' + toggle + '"]');
	var q = jawnosDockIconGet(toggle);

	if (q == 'on') {
		p.hide();
		b.css({'background-color': 'yellow' });
		jawnosDockIconSet(toggle, 'off');
	}
	else {
		p.show();
		jawnosDockIconSet(toggle, 'on');
		b.css({'background-color': 'green' });
	}
	//say_it(b.attr('speech'));

});


$(document).on('click','.pseudonym', function() {
	var toggle = $(this).attr('toggle');
	// A browser-added app face opens its app window (or raises/minimises it);
	// it has no keyboard panel of its own.
	if ($(this).hasClass('dock_app')) {
		jawnosDockAppOpen($(this).attr('dock_app'));
		return;
	}
	// The old floating keyboard and calculator are gone: both dock icons now
	// open the JawnOS on-screen keyboard (the calculator on its own page).
	if ((toggle == 'keyboard' || toggle == 'calculator') && typeof softKbDockOpen == 'function') {
		softKbDockOpen(toggle == 'calculator' ? 'calc' : 'letters');
		return;
	}
	var panel = $('#' + toggle);
	// A click is the open gesture. The dock's own state can lag the panel (the
	// first click used to render and the click then remove it before it showed),
	// so decide by what is actually on screen: open when it is hidden, close
	// when it is visible.
	if (panel.length && panel.is(':visible')) {
		panel.remove();
	}
	else {
		keyboardMaker({ toggle: toggle, state: 'on' });
	}
});



$(document).on('click', '.notification_remove', function() {
	var b = $(this);
	var timestamp = b.attr('timestamp');
	var title = b.attr('title');
	var tag = b.attr('tag');
	var uuid = b.attr('uuid');
	var scope = b.attr('scope');
	var app = b.attr('app');
	var server_time = b.attr('server_time');
	var filter = $('#notification_app_select').val();
	var search = $('#notification_search').val();

	$.ajax({
		url: '/manager/notifications/remove',
		type: 'POST',
		data: { timestamp: timestamp, tag: tag, filter: filter, search: search, scope: scope, title: title, uuid: uuid, app: app, server_time: server_time },
		success: function(response) {
			$.each(response, function(i,v) {
				$('.notification[uuid="' + v + '"]').remove();
			});
			notificationScrollLoader();
		}
	});
});

$(document).on('change', '#notification_app_select', function() {
	var app = $(this).val();

	$.ajax({ 
		url: '/manager/notifications/filter',
		type: 'GET',
		data: { app: app },
		success: function(response) {
			$('#notifications_content').html(response.content);
		}
	});
});

$(document).on('keyup', '#notification_search', function() {
	var search = $(this).val();

	$.ajax({
		url: '/manager/notifications/search',
		type: 'GET',
		data: { search: search },
		success: function(response) {
			$('#notifications_content').html(response.content);
		}
	});
});

var notificationReload = { reload: 0, position: 1 };

$(document).on('mousewheel touchmove', '#notifications_content', function() {
	notificationScrollLoader();

});

function notificationScrollLoader() {
	var nc = $('#notifications_content');
	var scroll = nc.offset().top;
	var height = nc.height();
	var cheight = $('#notifications').height();

	if ((height - (cheight + Math.abs(scroll))) < 530) {
		if (notificationReload['reload'] == 0) {
			notificationReload['reload'] = 1;
			$.ajax({
				url: '/manager/notifications/scroll',
				type: 'GET',
				data: { position: notificationReload['position'] },
				success: function(response) {
					$('#notifications_content').append(response.content);
					notificationReload['reload'] = 0;
					notificationReload['position']++;
				}
			});
		}
		
	}
}

function initializer() {
	var scope = localStorage.getItem('scope');
	var timeshift = localStorage.getItem('timeshift');
	var timeshift_scope = localStorage.getItem('timeshift_scope');
	var sorts = localStorage.getItem('sorts');
	var filter = localStorage.getItem('filter');
	var layout = localStorage.getItem('layout');
	var update_frequency = localStorage.getItem('update_frequency');
	var keyboard = localStorage.getItem('keyboard');
	var search = localStorage.getItem('search');
	var time_machine = localStorage.getItem('time_machine');
	var project = localStorage.getItem('project');
	var account = localStorage.getItem('account');
	var room_check = localStorage.getItem('room_check');
	var windshield_wiper = localStorage.getItem('windshield_wiper');
	var background_images = localStorage.getItem('background_images');
	var background_images_opacity = localStorage.getItem('background_images_opacity');
	if (!scope) {
		keyboard = 'none';
		localStorage.setItem('keyboard', keyboard);
		update_frequency = 'no';
		localStorage.setItem('update_frequency', update_frequency);
		scope = 'hour';
		localStorage.setItem('scope', scope);
		timeshift_scope = 's';
		localStorage.setItem('timeshift_scope', timeshift_scope);
		layout = 'leaderboard';
		localStorage.setItem('layout', layout);
		sorts = 'timestamp';
		localStorage.setItem('sorts', sorts);
		timeshift = 0;
		localStorage.setItem('timeshift', timeshift);
		localStorage.setItem('filter', filter);
		time_machine = '';
		localStorage.setItem('time_machine',time_machine);
		project = 'def';
		localStorage.setItem('project',project);
		account = 'def';
		localStorage.setItem('account',account);
	}
	if ($('#scope').is(':visible')) {
		$('#scope').val(scope);
		$('#layout').val(layout);
		$('#sorts').val(sorts);
		$('#timeshift').val(timeshift);
		$('#timeshift_scope').val(timeshift_scope);
		$('#update_frequency').val(update_frequency);
		$('#time_machine').val(time_machine);
		$('#filter').val(filter);
		$('#projects').val(project);
		$('#accounts').val(account);
		$('#background_images_opacity').val(background_images_opacity);
		if (background_images == 'on') {
			$('#background_images').prop('checked', true);
		}
	}
	if ($('#layout').is(':visible')) {
		$('#layout').val(layout);
	}
	$.each(['room_check','windshield_wiper'], function(i,v) {
		if (localStorage.getItem(v) == 'true') {
			$('#' + v).prop('checked',true);
		}

	});

	clearInterval(calculateInterval);
	var frequency_value = numeral(update_frequency).value();
	if (frequency_value < 1000) { frequency_value = 1000; }
	if (update_frequency != "no") {
		calculateInterval = setInterval(function() {
			calculator();
		}, frequency_value);
	}
	timestampDater();
	appointment_chron();
	var shadow = localStorage.getItem('mouse_shadow');
	if (shadow) {
		$('#mouse_shadow').css(JSON.parse(localStorage.getItem('mouse_shadow')));
	}
	debrief_setter();
}

function debrief_setter() {
	$('#timeshift_viewer').html($('#timeshift').val() + $('#timeshift_scope').val());
}


$(document).on('mousemove', function(m) {
	mouse = m;
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
});

$(document).on('mousemove', '#pseudonym_home', function(m) {
	mouse = m;
	var x = m.originalEvent.clientX;
	var y = m.originalEvent.clientY;
	pseudonymHomeShower(x,y);
});

function textareaUpgrader() {
	$('textarea[upgradeable="yes"').each(function(i,v) {
		if ($(v).attr('upgraded') != 'yes') {
			var ta = $(v);
			var id = ta.attr('id');

			if (ta.attr('id') == undefined || ta.attr('id') == '') {
				id = Math.random().toString(36).substring(2);
				ta.attr('id', id);
			}
			var classList = [];
			$.each(ta[0].classList, function(ic,vc) {
				classList.push(vc);
			});
			var attributes = {};
			$.each(ta[0].attributes, function(ic, vc) {
				attributes[vc.name] = vc.value;
			});

			var placeholder = ta.attr('placeholder');
			var contents = ta.val();
			$.ajax({
				url: '/manager/text_editor/create',
				type: 'GET',
				data: { id: id, contents: contents, placeholder: placeholder, magic_vars: ta.attr('magic_vars') || '' },
				success: function(response) {
					var p_id = response.p_id;
					id = response.id;
					ta.attr('upgraded', 'yes');
					var $prepender = $(response.html);
					ta.before($prepender);
					$.each(classList, function(io, vo) {
						ta.removeClass(vo);
						$('#' + p_id).addClass(vo);
					});
					$.each(attributes, function(io, vo) {
						if (io != 'id' && io != 'class') {

							$('#' + p_id).attr(io, vo);
						}
					});
					// The container is not a scroll box: its heights are all auto, so the
					// overflow only ever clipped. The variable legend lives in the toolbox
					// now and opens upward from there, and nothing may cut it at the edge.
					$prepender.css({ 'overflow':'visible' });
					$(document).on('change', '#' + id, function() {

						var te = textEditorProcessor($('#' + id));
						$('#' + p_id).html(te);
					});
					$(document).on('keyup', '#' + p_id, function(e) {
						var box = $('#' + p_id);
						$('#' + id).val(box.text());
						if (e.keyCode != 186) { return; }
						// ${vape}->duration; names the variable outright, so it is eaten
						// without the wand; anything else waits to be asked for
						var word = (box.text().match(/(\S+);$/) || [])[1] || '';
						var named = /\$\{[^}\s]+\}->[A-Za-z0-9_]+$/.test(word) || /\$[A-Za-z_][A-Za-z0-9_]*->[A-Za-z0-9_]+$/.test(word);
						textEditorMagic(box, named);
					});

					ta.hide();
					// the editor exists now; a draft from another device can fill it
					if (typeof jawnosAppDraftHydrate === 'function') { jawnosAppDraftHydrate(ta.attr('app')); }
				}
			});
		}
	});
}

// The toolbox is shown once the editor is being used, not on hover: a toolbar
// that appears under a moving pointer is a button pressed by accident.
$(document).on('focus click', '.text_editor_container', function(e) {
	var source_id = $(this).attr('source_id');
	$('.text_editor_toolbox[source_id="' + source_id + '"]').show();
});

// A click on the padding or the toolbox row is a click meant for the text.
$(document).on('click', '.text_editor_container', function(e) {
	if ($(e.target).closest('.text_editor_toolbox').length == 0 && !$(e.target).closest('.text_editor').length) {
		$(this).find('.text_editor').focus();
	}
});

$(document).on('blur', '.text_editor_container', function(e) {
	if (!$(e.target).closest('.text_editor_container')) {
		var source_id = $(this).attr('source_id');
		$('.text_editor_toolbox[source_id="' + source_id + '"]').hide();
	}
});

$(document).on('click', '.teb_style', function() {
	var ts = $(this);
	var tb = ts.closest('.text_editor_toolbox');
	var id = tb.attr('t_id');
	var ta = $('#' + id);
	var tag = ts.attr('tag');
	var status = ts.attr('status');
	if (status == 'on') {
		status = 'off';
		if (tag) {
			ta.html(ta.html() + '</' + tag + '>');
		}
	} else {
		status = 'on';
		$(this).attr('status', status);
		if (tag) {
			ta.html(ta.html() + '<' + tag + '>');
		}
		if (ts.attr('utility') == 'magic_wand') {
			textEditorMagic(ta);
		}
	}
	ta.focus();
	$(this).attr('status', status);
});

function textEditorMagic(dom, force) {
	var text = dom.html();
	var id = dom.attr('id');
	var container = dom.closest('.text_editor_container');
	var toolbox = container.find('.text_editor_toolbox');
	var wand = toolbox.find('.teb_style[utility="magic_wand"]');
	var source_id = dom.attr('source_id');
	if (wand.attr('status') == 'on' || force) {

		// magic_vars says what ${self} is about here - the appointment the editor
		// sits in, or the quote/invoice and customer the compose was opened for
		var data = { method: 'textAreaMagic', text: text, id: id, source_id: source_id, magic_vars: dom.attr('magic_vars') || '' };

		var jdata = JSON.stringify(data);

		ws['tab'].send(jdata);
	}

}

$(document).on('click', '.text_editor_illusion', function() {
	var tei = $(this);
	var original = tei.attr('original');
	var trick = tei.attr('trick');
	var displaying = tei.attr('displaying');
	if (displaying == 'original') {
		tei.text(trick);
		tei.attr('displaying', 'trick');
	} else {
		tei.text(original);
		tei.attr('displaying', 'original');
	}
});

function textEditorProcessor(text) {

	text = text.replace(/\r\n|\r|\n/g, '<br>');
	if (text == '<br>') {
		text = '';
	}
	return text;
}


// Marker (paint board) shortcuts, kept here with the rest of the key
// handling. Returns true when the key was used, so the keyboard app leaves it
// alone.
function markerShortcut(e) {
	if (typeof markerUndo != 'function') { return false; }
	if ($('#whiteboard').length == 0 || !$('#whiteboard').is(':visible')) { return false; }
	if ($(e.target).is('input, textarea, select, [contenteditable], .text-editor')) { return false; }
	var key = (e.key || '').toLowerCase();
	if (e.ctrlKey || e.metaKey) {
		if (e.altKey) { return false; }
		if (key == 'z') {
			if (e.shiftKey) { markerRedoStep(); } else { markerUndo(); }
			e.preventDefault();
			return true;
		}
		if (key == 'y') { markerRedoStep(); e.preventDefault(); return true; }
		return false;
	}
	// the plain keys only act while the board is the window in front
	var marker_app = $('#whiteboard').closest('.wind').attr('app') || 'marker';
	if (topWindow() != marker_app) { return false; }
	if (key == '+' || key == '=') { markerZoomCentre(1.25); e.preventDefault(); return true; }
	if (key == '-' || key == '_') { markerZoomCentre(1 / 1.25); e.preventDefault(); return true; }
	if (key == '0') { markerViewFit(); e.preventDefault(); return true; }
	return false;
}

$(document).on('keydown', function(e) {
	var timestamp = Date.now();
	keysPressed[jawnosKeyCode(e)] = { key: e.key, timestamp: timestamp };
	var app = topWindow();
	var dialog = topDialog();
	var win = $('.wind[app="' + app + '"]');

	var movInc = 5;
	if (markerShortcut(e)) { return; }
	if (e.keyCode == 13) {
		if ($('.dialog_box').length > 0) {
			e.preventDefault();
			var d = $($('.dialog_box')[$('.dialog_box').length - 1]);
			d.find('.ok').trigger('click');
			console.log('dialog box showing');
		}
		if (app == 'folders') {
			e.preventDefault();
			if ($(e.target).not('input')) {
				foldersFileOpener()
			}
		}
	}
	else if (e.keyCode == 27) {
		if ($('.dialog_box').length > 0) {
			e.preventDefault();
			var d = $($('.dialog_box')[$('.dialog_box').length - 1]);
			d.find('.cancel').trigger('click');
		}
	}
	else if (e.keyCode == 65 && e.ctrlKey == true) {
		if (topWindow() == 'folders') {
			
			e.preventDefault();
			foldersCommand({ command: 'select_all' });
		}
	}
	else if (e.keyCode == 18 && e.ctrlKey == true) {
		startMenuToggle();
	} else if (e.keyCode == 37 && keysPressed[91]) { //left

		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// the window may hang up to half off the side, but the titlebar
				// buttons (top right) have to stay reachable
				var minLeft = -Math.min(win.width() / 2, win.width() - 95);
				var l = numeral(win.css('left')).value() - movInc;
				if (l > minLeft) {
					win.css({ 'left': l });
				}
			}
		}
		else {
			if ($('#app_switcher').is(':visible')) {
				appSwitcher('subtract');
			} else {
				var app = topWindow();
				var win = $('.wind[app="' + app + '"]');
				windowHalfski(win,'left');
			}
		}
	} else if (e.keyCode == 39 && keysPressed[91]) { //right
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// pushed right the buttons leave the screen first, so a right push
				// stops with the window's right edge still on screen: all three
				// stay visible and clickable
				var maxLeft = $(window).width() - win.width();
				var l = numeral(win.css('left')).value() + movInc;
				if (l < maxLeft) {
					win.css({ 'left': l });
				}
			}
		}
		else {
			if ($('#app_switcher').is(':visible')) {
				appSwitcher();
			} else {
				var app = topWindow();
				var win = $('.wind[app="' + app + '"]');
				windowHalfski(win,'right');
			}
		}
	} else if (e.keyCode == 38 && keysPressed[91]) { //up
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				// a strip of the titlebar (and its buttons) stays on screen
				var l = numeral(win.css('top')).value() - movInc;
				if (l > -18) {
					win.css({ 'top': l });
				}
			}
		}
		else {
			var app = topWindow();
			var win = $('.wind[app="' + app + '"]');
			var timestamp = win.attr('timestamp');
			if (win.attr('view') == 'max') {
				windowRestore(timestamp,app);
			} else {
				windowMaximizer(timestamp, app);
			}
		}
	} else if (e.keyCode == 40 && keysPressed[91]) { //down
		if (e.ctrlKey == true) {
			if (win.attr('view') == '') {
				var topNavbarHeight = numeral(win.find('.top_navbar').css('height')).value();
				var l = numeral(win.css('top')).value() + movInc;
				if (l < $(window).height() - topNavbarHeight) {
					win.css({ 'top': l });
				}
			}
		}
		else {
			var app = topWindow();
			var win = $('.wind[app="' + app + '"]');
			var timestamp = win.attr('timestamp');
			windowMinimizer(timestamp, app);
			topLevelNow($('.wind[app="' + topWindow() + '"]'));
		}
	} else if (e.keyCode == 81 && keysPressed[91]) { //Q
		var app = topWindow();
		var win = $('.wind[app="' + app + '"]');
		var timestamp = win.attr('timestamp');
		closeWindow(timestamp);
	} else if (e.keyCode == 16 && keysPressed[91]) {
		appSwitcher();
	} else if (!$(e.target).is('input') && !$(e.target).is('textarea') && !$(e.target).is('select') && !$(e.target).hasClass('.text_editor') && e.ctrlKey == false && topWindow() == 'music') {
			e.preventDefault();
			if (e.keyCode == 32 && !keysPressed[91]) {
				console.log('space bar');
				$('#play').trigger('click');
			}
			if (e.keyCode == 37 && !keysPressed[91]) {
				$('#prev').trigger('click');
			}
			if (e.keyCode == 38 && !keysPressed[91]) {
				$('.next_chapter').trigger('click');
			}
			if (e.keyCode == 39 && !keysPressed[91]) {
				$('#next').trigger('click');
			}
			if (e.keyCode == 40 && !keysPressed[91]) {
				$('.last_chapter').trigger('click');
			}
			if (e.keyCode == 70 && !keysPressed[91]) {
				// music.js owns the target: an audio track has no picture, so the
				// whole player goes fullscreen (the visualisation rides along)
				if (typeof musicPlayerFullscreen == 'function') { musicPlayerFullscreen(); }
				else { tree.sound.requestFullscreen(); }
			}
		}


/*
	if (e.keyCode == 83 && e.ctrlKey == true && e.altKey == true) { // ctrl+alt+s
		configureToggle();
	}
	if (e.keyCode == 77 && e.ctrlKey == true && e.altKey == true) { // ctrl+alt+m
		musicToggle();
	}
*/
});

$(document).on('keyup', function(e) {
	var jawnos_code = jawnosKeyCode(e);
	delete keysPressed[jawnos_code];
	if (jawnos_code == 91) {
		appSwitcher('chose');
	}
});

function appSwitcher(duty) {
	var as = $('#app_switcher');
	as.find('.app').css({ 'border':'none', 'background-color': 'transparent' });
	if (duty == 'chose') {
		if (as.is(':visible')) {
			as.hide();
			var s = $(as.find('.app')[appSwitcherSelected]);
			var app = s.find('.window_toggle_name').attr('app');
			topLevelNow($('.wind[app="' + app + '"]'));
			$('.wind[app="' + app + '"]').show();
			appSwitcherSelected = 0;
		}
	}
	else {
		if (!as.is(':visible')) {
			startMenuDisplayer('#app_switcher');
		}
		var count = as.find('.app').length;
		if (duty == 'subtract') {
			appSwitcherSelected--;
			if (appSwitcherSelected < 0) {
				appSwitcherSelected = count - 1;
			}
		} else {
			appSwitcherSelected++;
			if (appSwitcherSelected >= count) {
				appSwitcherSelected = 0;
			}
		}
		$(as.find('.app')[appSwitcherSelected]).css({ 'border':'solid', 'border-width': '5px', 'background-color': 'yellow', 'border-radius': '5%' });
		as.css({'display': 'flex' }).show();
	}
}

// The remote_control panel's command box: tell the selected machine what to do.
// The command is sent as plain words and read by that machine's own guide, so it
// stays on that machine; the reply is what it reports back.
function jawnosRemoteCommand() {
	var uuid = $('#remote_control_machine_select').val();
	var text = $.trim($('#remote_command_text').val() || '');
	var reply = $('#remote_command_reply');
	if (!uuid) { reply.text('Pick a machine other than Me first.'); return; }
	if (!text) { return; }
	reply.text('Sending...');
	$.post('/manager/remote_command/send', { remote_uuid: uuid, text: text }, function (r) {
		reply.text((r && (r.observation || r.error)) || 'no reply');
	}).fail(function () { reply.text('no reply'); });
}

// The remote_control panel's VPN button: set this device's tailnet exit node to
// the machine picked above, so this device's web traffic leaves at that
// machine's address. Android answers through the JawnVPN bridge (the embedded
// client owns the VPN); a Linux peer asks its own manager, which drives the
// local tailscale. The button only offers a machine that advertises an exit
// node, and turning it off comes back to this device's own network.
function jawnosVpnSelected() {
	var opt = $('#remote_control_machine_select').find('option:selected');
	return { uuid: opt.val() || '', ip: opt.attr('data-tailnet') || '' };
}

function jawnosVpnStatus(cb) {
	if (window.JawnVPN && typeof window.JawnVPN.status === 'function') {
		try { cb(JSON.parse(window.JawnVPN.status())); return; } catch (e) {}
	}
	$.getJSON('/manager/tailnet/status', function (s) { cb(s || {}); })
		.fail(function () { cb({ available: 0, exit: '', peers: [] }); });
}

function jawnosVpnPaint(on, available) {
	var b = $('#remote_control_vpn');
	if (!b.length) { return; }
	b.attr('status', on ? 'on' : (available ? 'off' : 'unavailable'));
	b.prop('disabled', !on && !available);
	b.css({
		'opacity': (on || available) ? 1 : 0.45,
		'background-color': on ? 'var(--jawnos-ok, #4caf50)' : ''
	});
	b.attr('hint', on ? jawnosT('Turn the VPN off') : jawnosT("Route this device's web traffic through the selected machine when it offers an exit node"));
}

function jawnosVpnRefresh() {
	var b = $('#remote_control_vpn');
	if (!b.length) { return; }
	var picked = jawnosVpnSelected();
	if (!picked.ip) {
		// "Me" has no exit node to switch to, but keep the button in sight so
		// the choice is discoverable; picking a machine enables it.
		b.show();
		jawnosVpnPaint(false, false);
		b.attr('hint', jawnosT('Pick a machine that offers an exit node'));
		return;
	}
	jawnosVpnStatus(function (s) {
		var peers = (s && s.peers) || [];
		var peer = null;
		for (var i = 0; i < peers.length; i++) {
			if (peers[i] && peers[i].ip === picked.ip) { peer = peers[i]; break; }
		}
		var on = !!(s && s.exit && s.exit === picked.ip);
		// Linux reports online as 1/0, Android as true/false.
		var available = !!(peer && peer.exit && peer.online);
		b.show();
		jawnosVpnPaint(on, available);
		if (!available && !on) { b.attr('hint', jawnosT('That machine does not offer an exit node')); }
	});
}

// The Me view's public address. With a VPN exit node in force it is that
// machine's address; without one it is this device's ISP address, so the line is
// the quickest check that the VPN is really carrying the traffic.
function jawnosPublicIpPaint(ip) {
	var el = $('#local_public_ip');
	if (!el.length) { return; }
	if (ip) {
		el.text(ip).css('opacity', 1);
	}
	else {
		el.text(jawnosT('not known')).css('opacity', .65);
	}
}

function jawnosPublicIpRefresh(refresh) {
	if (!$('#local_public_ip').length) { return; }
	$('#local_public_ip_row').show();
	$('#local_public_ip').text(jawnosT('checking…')).css('opacity', .65);
	$.getJSON('/manager/public_ip' + (refresh ? '?refresh=1' : ''), function (r) {
		if (r && r.disabled) { $('#local_public_ip_row').hide(); return; }
		jawnosPublicIpPaint((r && r.ip) || '');
	}).fail(function () { jawnosPublicIpPaint(''); });
}

function jawnosVpnToggle() {
	var picked = jawnosVpnSelected();
	if (!picked.ip) { return; }
	var b = $('#remote_control_vpn');
	var on = b.attr('status') === 'on';
	var target = on ? '' : picked.ip;
	b.prop('disabled', true);
	var finish = function (r) {
		b.prop('disabled', false);
		if (!r || r.ok === false || r.ok === 0) {
			b.attr('hint', (r && r.error) || jawnosT('The VPN could not be changed'));
			return;
		}
		jawnosVpnRefresh();
		// The route can take a moment to appear in the tailnet status, so ask
		// again rather than leaving the button reading "off" after a success.
		setTimeout(jawnosVpnRefresh, 1200);
		// The public address is the proof the route actually moved, so look it up
		// again after the change settles instead of leaving the old ISP answer.
		if (typeof jawnosPublicIpRefresh == 'function') {
			$('#local_public_ip').text(jawnosT('checking…'));
			setTimeout(function () { jawnosPublicIpRefresh(true); }, 1500);
		}
	};
	if (window.JawnVPN && typeof window.JawnVPN.setExitNode === 'function') {
		try { finish(JSON.parse(window.JawnVPN.setExitNode(target))); return; } catch (e) { finish({ ok: false, error: '' + e }); return; }
	}
	$.post('/manager/tailnet/exit', { ip: target }, finish, 'json').fail(function () { finish({ ok: false }); });
}
$(document).on('click', '#remote_command_send', function () { jawnosRemoteCommand(); });
$(document).on('click', '#remote_control_vpn', function () { jawnosVpnToggle(); });
// While the Me view is open, keep the public address fresh: the VPN can also be
// switched from the desktop or another window, not only by this panel's button.
setInterval(function () {
	if ($('#local_public_ip').length && $('#local_public_ip').is(':visible')) { jawnosPublicIpRefresh(); }
}, 60000);
