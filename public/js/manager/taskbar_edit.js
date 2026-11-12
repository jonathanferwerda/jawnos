/* [[js-split]]
   taskbar_edit.js is part 1. The rest live in taskbar_edit/ in name order:
     01_window_events.js  - window context build and taskbar/clock event bindings
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
// The taskbar's edit mode and the menu that turns it on: the bar's furniture -
// the open windows, the clock, the start button and lock, the search when it
// rides here, and any app or keyboard the user pins - are slots this file drags
// into the order the user wants. The order is a misc setting; a right-click (or
// long press) on the bar opens a context menu with the edit toggle, the bar's
// edge, autohide, and the clock's own face.
//
// It leans on taskbar.js: jawnosBars carries the parsed order, jawnosBarsApply
// lays everything out, and jawnosTaskbarSave writes a setting through the same
// route the configure panel uses.

// Where the bar's slots live. Order keys that are plain strings name these; a
// pin (an app or keyboard the user added) is an object and builds its own tile,
// and so does a widget (battery, network).
function jawnosTaskbarSlots() {
	return {
		'search': '#search_entanglement',
		'windows': '#taskbar_windows',
		'clock': '#taskbar_clock',
		'icons': '#taskbar_icons'
	};
}

// The widgets the Add items list offers. A widget is not a pin: it has no
// window of its own, it polls one reading, and it has three display modes.
// `off` keeps the entry in the order (so it is not re-added as a default) but
// builds no element, which is what makes Disabled stick across reloads.
var jawnosTaskbarWidgets = {
	power: { hint: 'Battery', icon: '/icons/power.svg' },
	network: { hint: 'Network', icon: '/icons/network.svg' },
	sound: { hint: 'Sound', icon: '/icons/sound.svg' },
	notifications: { hint: 'Notifications', icon: '/icons/notifications.svg' }
};

function jawnosTaskbarWidgetItem(w, mode) {
	return { k: 'widget', w: w, mode: mode || 'full' };
}

// The order before the user has ever dragged anything: the window list, the
// clock and the start button, with the search at the leading edge when it lives
// here. The old start-button side setting is honoured once, so a bar that had
// the button on the left keeps it there until it is dragged. The battery widget
// is on by default, because a bar that has one should say so until told not to.
function jawnosTaskbarDefaultOrder() {
	var left = (typeof jawnosBars != 'undefined' && jawnosBars.start_side == 'left');
	var widgets = [jawnosTaskbarWidgetItem('power', 'full'), jawnosTaskbarWidgetItem('notifications', 'full')];
	return left ? ['icons', 'search', 'windows'].concat(widgets, ['clock'])
		: ['search', 'windows'].concat(widgets, ['clock', 'icons']);
}

function jawnosTaskbarEditing() {
	return $('#taskbar').hasClass('taskbar_edit');
}

// A press on a plain launcher pin hands the press to the thing it was cloned
// from. The start menu's content is only in the DOM after it has been opened
// once; if it is not there, the menu is fetched (the same call the menu makes),
// rendered without ever being shown, pressed, and put away - so an action pin
// does not flash the menu on the screen for a moment.
function jawnosTaskbarPress(sel) {
	var target = $(document).find(sel).first();
	if (target.length) { target.trigger('click'); return; }
	var was_open = $('#start_menu').is(':visible');
	$.ajax({
		url: '/manager/start_menu', type: 'GET', data: { menu: 'app' },
		success: function (response) {
			if (typeof startMenuRender == 'function') { startMenuRender(response.html, $('#start_menu_toggle')); }
			// startMenuRender shows the menu; keep it invisible for the press unless it
			// was already up (no paint happens between here and the timeout)
			if (!was_open) { $('#start_menu').css('visibility', 'hidden'); }
			setTimeout(function () {
				var t2 = $(document).find(sel).first();
				if (t2.length) { t2.trigger('click'); }
				if (!was_open) { $('#start_menu').hide().css('visibility', ''); }
			}, 60);
		}
	});
}

// The app a start-menu toggle opens, when it can be named. Its id is the app in
// nearly every case (music_toggle -> music); a few are actions rather than apps,
// and one or two wear a different name, so those are spelled out here.
function jawnosTaskbarAppForToggle(id) {
	if (!id) { return null; }
	var action = { backup_now: 1, stop_all: 1, upload: 1, nfc_benign_reader: 1, sms_list_check: 1, permission_asker: 1, torch_toggle: 1, now_toggle: 1, keyboard_toggle: 1, calculator_toggle: 1 };
	if (action[id]) { return null; }
	var alias = { image_toggle: 'gallery', ticketmaker: 'box_office' };
	if (alias[id]) { return alias[id]; }
	var m = /^(.*)_toggle$/.exec(id);
	if (m) { return m[1]; }
	if (id == 'budget' || id == 'folders') { return id; }
	return null;
}

// One pinned tile. A launcher pin (an action, or a toggle with no app name) is a
// plain picture. An app pin is a slot: closed it shows the app's icon, and while
// its window is open the window button is parked here in its place (see
// jawnosTaskbarPinsRefresh), so a pinned app and its window are never two tiles.
function jawnosTaskbarPinMake(item) {
	if (item.app) {
		var pin = $('<span class="taskbar_pin taskbar_app_pin" draggable="false"></span>');
		pin.attr('app', item.app).attr('sel', item.sel || '').attr('hint', item.hint || '');
		var icon = $('<img class="taskbar_app_pin_icon little_thumb hover" draggable="false">').attr('src', item.src || '');
		pin.append(icon);
		icon.on('click', function () {
			if (jawnosTaskbarEditing()) { return; }
			// while the window is parked here its own button answers
			if (pin.children('.window_toggle').length) { return; }
			if (typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse(pin); }
			jawnosTaskbarPinPress(pin);
		});
		return pin;
	}
	var launcher = $('<img class="taskbar_pin little_thumb hover" draggable="false">');
	launcher.attr('sel', item.sel).attr('hint', item.hint || '').attr('src', item.src || '');
	launcher.on('click', function () {
		if (jawnosTaskbarEditing()) { return; }
		if (typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse(launcher); }
		jawnosTaskbarPress(launcher.attr('sel'));
	});
	return launcher;
}

// A press on a closed app pin: the app opens by name - no menu is fetched, so
// there is no flash. (An app-less launcher uses jawnosTaskbarPress above.)
function jawnosTaskbarPinPress(pin) {
	if (jawnosTaskbarEditing()) { return; }
	var app = pin.attr('app');
	var win = $('.wind[app="' + app + '"]');
	var timestamp = Date.now();
	if (win.length) {
		// the button should be parked here already; this is a safety net
		if (!win.is(':visible')) { windowRestorer(timestamp, app); }
		else if (app == topWindow()) { windowMinimizer(timestamp, app); }
		else { topLevelNow(win); }
		return;
	}
	if (app) {
		// open the app the way its own opener does (a centre view is the
		// fallback for a bare appointment, which is not what a pinned app is).
		// Ask for it visible: the generic opener hides a window it was not told
		// to show (that is how a restore keeps a minimized window down), so a
		// fresh press would otherwise land minimized.
		if (typeof appWindowOpener == 'function') { appWindowOpener(app, timestamp, { visible: 'yes' }); }
		else { appointmentGrabber(app, timestamp); }
		return;
	}
	var sel = pin.attr('sel');
	if (sel) { jawnosTaskbarPress(sel); }
}

// The app a pin names, if its start-menu selector has one (an older pin stores
// only the selector; this lets it merge with its window like a newer one).
function jawnosTaskbarDeriveApp(sel) {
	var m = /#start_menu #(.+)$/.exec(sel || '');
	if (!m) { return null; }
	return jawnosTaskbarAppForToggle(m[1]);
}

// Lay the bar's furniture along the order, building pins as they come. Slots
// that are not listed keep a home at the end rather than vanish.
function jawnosTaskbarOrderApply() {
	var bar = $('#taskbar');
	if (!bar.length) { return; }
	var slots = jawnosTaskbarSlots();
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order.slice() : jawnosTaskbarDefaultOrder();
	// upgrade a pin that names a start-menu row but not the app behind it, and
	// undo an older pin that mistook an action (now) for an app. The first
	// battery widget was a bare 'power' string; it becomes the widget object.
	order = order.map(function (item) {
		if (item === 'power' || item === 'network') { return jawnosTaskbarWidgetItem(item, 'full'); }
		if (item && typeof item === 'object' && item.k == 'pin' && item.sel) {
			var derived = jawnosTaskbarDeriveApp(item.sel);
			if (derived && !item.app) { return { k: 'pin', app: derived, sel: item.sel, hint: item.hint, src: item.src }; }
			if (!derived && item.app && /#start_menu #/.test(item.sel)) { return { k: 'pin', sel: item.sel, hint: item.hint, src: item.src }; }
		}
		return item;
	});
	// A bar saved before widgets existed gains the battery widget; a bar that has
	// a widget entry - even a disabled one - is left exactly as the person left it.
	var has_widget = order.some(function (item) { return item && typeof item === 'object' && item.k == 'widget'; });
	if (!has_widget) {
		var clock_at = order.indexOf('clock');
		order.splice(clock_at < 0 ? order.length : clock_at, 0, jawnosTaskbarWidgetItem('power', 'full'));
	}
	jawnosBars.order = order;
	// the fixed slots never fall off the bar; the search only counts while
	// the taskbar is its home
	['windows', 'clock', 'icons'].forEach(function (k) {
		if (order.indexOf(k) < 0) { order.push(k); }
	});
	if (jawnosBars.search == 'taskbar' && order.indexOf('search') < 0) { order.push('search'); }

	bar.children('.taskbar_pin, .taskbar_widget').remove();
	// A parked window button was a child of the pin just removed; the next
	// displayer must rebuild its tile instead of trusting an unchanged stamp.
	bar.find('#taskbar_windows').removeAttr('data-taskbar-stamp');
	order.forEach(function (item) {
		var el = null;
		if (item && typeof item === 'object' && item.k == 'pin') {
			el = jawnosTaskbarPinMake(item);
		}
		else if (item && typeof item === 'object' && item.k == 'widget') {
			if ((item.mode || 'full') == 'off') { return; }
			el = jawnosTaskbarWidgetMake(item);
		}
		else if (typeof item === 'string' && slots[item]) {
			if (item == 'search' && jawnosBars.search != 'taskbar') { return; }
			el = bar.find(slots[item]);
		}
		if (el && el.length) { bar.append(el); }
	});
	// the search answers to jawnosSearchPlace when it lives elsewhere; make sure
	// a bar that is not its home carries no stray one
	if (jawnosBars.search != 'taskbar' && bar.children('#search_entanglement').length) {
		jawnosSearchPlace();
	}
}

// ---- the open windows' own order -------------------------------------------
// The bar's furniture has its order (above); the window tiles inside it have
// their own. They arrive in the order they were opened and stay there while
// they are raised. Dragging a tile writes the order they were left in, and a
// window opened later joins at the right-hand end (windows.js does the sort; a
// saved key that no longer names an open window is dropped there).
var jawnosTaskbarWindowDragAt = 0;

function jawnosTaskbarWindowOrderSave() {
	var order = [];
	// every tile on the bar, including an app pin's parked window button, so a
	// pinned window keeps its place when it is unpinned
	$('#taskbar .window_toggle').each(function () {
		order.push(jawnosTaskbarWindowKey(this));
	});
	if (typeof jawnosBars == 'undefined') { return; }
	jawnosBars.window_order = order;
	jawnosTaskbarSave('taskbar_window_order', JSON.stringify(order));
}

// A window tile drags within the window list, on any bar state except edit mode
// (there the whole list is one slot being dragged). `distance` leaves a plain
// press - raise, minimise, restore - a press; only a real drag sorts.
function jawnosTaskbarWindowDragInit() {
	var list = $('#taskbar_windows');
	if (!list.length || list.hasClass('ui-sortable')) { return; }
	list.sortable({
		items: '> .window_toggle',
		axis: 'x',
		distance: 8,
		tolerance: 'pointer',
		placeholder: 'taskbar_window_placeholder',
		forcePlaceholderSize: true,
		start: function () { list.addClass('taskbar_window_dragging'); },
		stop: function () {
			list.removeClass('taskbar_window_dragging');
			jawnosTaskbarWindowDragAt = Date.now();
			jawnosTaskbarWindowOrderSave();
		}
	});
	if (jawnosTaskbarEditing()) { list.sortable('disable'); }
}

// ---- which window has the keyboard -----------------------------------------
// The front window's title bar is drawn at full strength and every other one
// is greyed, so before a key is pressed it is plain where the press will land.
// The comparison is by element, not app: a Terminal or a Folders window can
// have siblings of its own, and only the one in front has the focus.
function jawnosWindowFocusApply() {
	var top = null;
	var topz = -1;
	$('.wind').filter(':visible').each(function () {
		var z = parseInt($(this).css('z-index'), 10) || 0;
		if (z >= topz) { topz = z; top = this; }
	});
	$('.wind').each(function () {
		var bar = $(this).find('.top_navbar').first();
		if (!bar.length) { return; }
		bar.attr('data-focus', (this === top) ? 'on' : 'off');
	});
	// the dock's window faces and app pins wear the same state
	if (typeof jawnosDockWindowsState == 'function') { jawnosDockWindowsState(); }
}

// Read the bar back into an order and keep it. Called when a drag settles.
function jawnosTaskbarOrderSave() {
	var order = [];
	$('#taskbar').children().each(function () {
		var el = $(this);
		if (el.is('#taskbar_windows')) { order.push('windows'); }
		else if (el.is('#taskbar_clock')) { order.push('clock'); }
		else if (el.is('#taskbar_icons')) { order.push('icons'); }
		else if (el.is('#search_entanglement')) { order.push('search'); }
		else if (el.hasClass('taskbar_widget')) {
			order.push({ k: 'widget', w: el.attr('widget'), mode: el.attr('mode') || 'full' });
		}
		else if (el.hasClass('taskbar_pin')) {
			if (el.hasClass('taskbar_app_pin')) {
				order.push({ k: 'pin', app: el.attr('app'), sel: el.attr('sel') || undefined, hint: el.attr('hint'), src: el.children('img').first().attr('src') });
			}
			else {
				order.push({ k: 'pin', sel: el.attr('sel'), hint: el.attr('hint'), src: el.attr('src') });
			}
		}
	});
	// A disabled widget has no element to read back; keep its entry (and its
	// disabled mode) so the default does not put it back on the bar.
	var seen = {};
	order.forEach(function (item) { if (item && item.k == 'widget') { seen[item.w] = 1; } });
	(jawnosBars.order || []).forEach(function (item) {
		if (item && typeof item === 'object' && item.k == 'widget' && !seen[item.w]) {
			order.push({ k: 'widget', w: item.w, mode: item.mode || 'off' });
		}
	});
	jawnosBars.order = order;
	jawnosTaskbarSave('taskbar_order', JSON.stringify(order));
	// the dock's app and widget faces follow this order
	if (typeof jawnosDockAppsRender == 'function') { jawnosDockAppsRender(); }
}

// Write a misc setting the way the configure panel does, and re-lay the bars.
function jawnosTaskbarSave(setting, value) {
	$.ajax({
		url: '/manager/configure/misc_setting',
		type: 'POST',
		data: {
			setting: setting,
			value: value,
			device: (typeof device != 'undefined') ? device : '',
			timestamp: Date.now()
		}
	});
}

function jawnosTaskbarEdit(on) {
	var bar = $('#taskbar');
	if (!bar.length) { return; }
	// the window tiles drag on their own while the bar is not in edit mode; in
	// edit mode the whole window list is the slot being dragged
	var tiles = bar.find('#taskbar_windows');
	if (on) {
		if (tiles.hasClass('ui-sortable')) { tiles.sortable('disable'); }
		bar.addClass('taskbar_edit');
		if (!bar.hasClass('ui-sortable')) {
			bar.sortable({
				items: '> #taskbar_windows, > #taskbar_clock, > .taskbar_widget, > #taskbar_icons, > #search_entanglement, > .taskbar_pin',
				tolerance: 'pointer',
				placeholder: 'taskbar_slot_placeholder',
				stop: function () { jawnosTaskbarOrderSave(); }
			});
		}
		bar.sortable('enable');
	}
	else {
		if (bar.hasClass('ui-sortable')) { bar.sortable('disable'); }
		bar.removeClass('taskbar_edit');
		if (tiles.hasClass('ui-sortable')) { tiles.sortable('enable'); }
	}
}

// ---- the context menu -----------------------------------------------------

function jawnosTaskbarContextClose() {
	$('.taskbar_context').remove();
}

// The app rows a start menu carries, read out of whatever root holds them (the
// live menu, or a fetched copy). Each pin is a picture, the selector that finds
// the live icon, and - when the toggle opens a window - the app name, so the pin
// merges with that window.
function jawnosTaskbarPinsFrom(root) {
	var pins = [];
	root.find('.start_menu_main_display img').each(function () {
		var img = $(this);
		var hint = img.attr('hint') || '';
		if (!hint) { return; }
		var id = img.attr('id');
		var sel = id ? ('#start_menu #' + id) : ('#start_menu .start_menu_main_display img[hint="' + hint + '"]');
		var src = img.attr('src') || '';
		if (pins.some(function (p) { return p.sel == sel; })) { return; }
		pins.push({ sel: sel, hint: hint, src: src, app: jawnosTaskbarAppForToggle(id) });
	});
	return pins;
}

function jawnosTaskbarAppPins() {
	return jawnosTaskbarPinsFrom($('#start_menu'));
}

// The keyboards off the dock: each pseudonym opens its own keyboard when pressed.
// App faces added to the dock are apps, and already appear in the Apps list.
function jawnosTaskbarKeyboardPins() {
	var pins = [];
	$('#pseudonym_home .pseudonym').not('.dock_app, .dock_widget, .dock_launcher').each(function () {
		var p = $(this);
		var id = p.attr('id');
		if (!id) { return; }
		pins.push({ sel: '#pseudonym_home #' + id, hint: p.attr('hint') || p.attr('name') || id, src: p.attr('src') || '' });
	});
	return pins;
}

// The start menu's foot buttons - leave, the site type, now, the assistant,
// the navigation button and the bird. They are launchers (an action, not an app
// window), keyed by a selector into the live menu.
function jawnosTaskbarFootPinsFrom(root) {
	var pins = [];
	root.find('.leave, .site_type_manual_changer_toggle, #now_toggle, #assistant, #navigation_now, .fuck_you').each(function () {
		var img = $(this);
		var id = img.attr('id');
		var sel;
		if (id) { sel = '#start_menu #' + id; }
		else if (img.hasClass('leave')) { sel = '#start_menu .leave'; }
		else if (img.hasClass('site_type_manual_changer_toggle')) { sel = '#start_menu .site_type_manual_changer_toggle'; }
		else if (img.hasClass('fuck_you')) { sel = '#start_menu .fuck_you'; }
		else { return; }
		if (pins.some(function (p) { return p.sel == sel; })) { return; }
		var hint = img.attr('hint') || (id == 'assistant' ? 'Assistant' : (id || ''));
		pins.push({ sel: sel, hint: hint, src: img.attr('src') || '' });
	});
	return pins;
}

// Is this launcher pin already on the bar? (Compare the attribute rather than
// build an attribute selector: a hint-only pin's sel carries its own quotes.)
function jawnosTaskbarPinned(sel) {
	var found = false;
	$('#taskbar').children('img.taskbar_pin').each(function () {
		if ($(this).attr('sel') === sel) { found = true; }
	});
	return found;
}
function jawnosTaskbarAppPinned(app) {
	return $('#taskbar').children('.taskbar_app_pin[app="' + app + '"]').length > 0
		|| (jawnosBars.order || []).some(function (it) { return it && it.app == app; });
}

// The widget entry in the order, including the short-lived shape the first
// battery widget used (a bare 'power' string). A missing entry is "off".
function jawnosTaskbarWidgetEntry(w) {
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order : [];
	for (var i = 0; i < order.length; i++) {
		var item = order[i];
		if (item && typeof item === 'object' && item.k == 'widget' && item.w == w) { return item; }
		if (item === w) { return jawnosTaskbarWidgetItem(w, 'full'); }
	}
	return null;
}

function jawnosTaskbarWidgetMode(w) {
	var entry = jawnosTaskbarWidgetEntry(w);
	return entry ? (entry.mode || 'full') : 'off';
}

function jawnosTaskbarWidgetOn(w) {
	return jawnosTaskbarWidgetMode(w) != 'off';
}

// Set one widget's mode and keep the order. `off` keeps the entry, so a widget
// the person disabled stays disabled instead of being re-added as a default.
function jawnosTaskbarWidgetSet(w, mode) {
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order.slice() : jawnosTaskbarDefaultOrder();
	var found = false;
	order = order.map(function (item) {
		if (item === w) { found = true; return jawnosTaskbarWidgetItem(w, mode); }
		if (item && typeof item === 'object' && item.k == 'widget' && item.w == w) {
			found = true;
			return $.extend({}, item, { mode: mode });
		}
		return item;
	});
	if (!found && mode != 'off') {
		var at = order.indexOf('clock');
		order.splice(at < 0 ? order.length : at, 0, jawnosTaskbarWidgetItem(w, mode));
	}
	jawnosBars.order = order;
	jawnosTaskbarSave('taskbar_order', JSON.stringify(order));
	jawnosBarsApply();
}

function jawnosTaskbarWidgetToggle(w) {
	jawnosTaskbarWidgetSet(w, jawnosTaskbarWidgetOn(w) ? 'off' : 'full');
}

// Build one widget's element. The pollers (taskbar_power.js, taskbar_network.js)
// find it by id and fill it; the mode is an attribute the CSS reads.
function jawnosTaskbarWidgetMake(item) {
	var w = item && item.w;
	var spec = jawnosTaskbarWidgets[w];
	if (!spec) { return $(); }
	var mode = item.mode || 'full';
	var el = $('<span class="taskbar_widget taskbar_widget_' + w + '" id="taskbar_' + w + '" widget="' + w + '" mode="' + mode + '" hidden></span>');
	if (w == 'power') {
		el.append('<span class="taskbar_power_glyph"><span class="taskbar_power_fill"></span></span>');
		el.append('<span class="taskbar_power_text taskbar_widget_text"></span>');
		setTimeout(function () { if (typeof jawnosPowerTaskbarLoad === 'function') { jawnosPowerTaskbarLoad(); } }, 0);
	}
	else if (w == 'network') {
		el.append('<span class="taskbar_network_glyph"><span class="taskbar_network_bars"><i></i><i></i><i></i><i></i></span><span class="taskbar_network_wire"></span></span>');
		el.append('<span class="taskbar_network_bluetooth" aria-hidden="true"></span>');
		el.append('<span class="taskbar_network_text taskbar_widget_text"></span>');
		setTimeout(function () { if (typeof jawnosNetworkTaskbarLoad === 'function') { jawnosNetworkTaskbarLoad(); } }, 0);
	}
	else if (w == 'sound') {
		el.append('<span class="taskbar_sound_glyph"><span class="taskbar_sound_cone"></span><span class="taskbar_sound_waves"><i></i><i></i><i></i></span></span>');
		el.append('<span class="taskbar_sound_text taskbar_widget_text"></span>');
		setTimeout(function () { if (typeof jawnosSoundTaskbarLoad === 'function') { jawnosSoundTaskbarLoad(); } }, 0);
	}
	else if (w == 'notifications') {
		el.append('<span class="taskbar_notifications_glyph"><img src="/icons/notifications.svg" alt=""></span>');
		el.append('<span class="taskbar_notifications_badge">0</span>');
		el.append('<span class="taskbar_notifications_text taskbar_widget_text"></span>');
		setTimeout(function () { if (typeof jawnosNotificationsTaskbarLoad === 'function') { jawnosNotificationsTaskbarLoad(); } }, 0);
	}
	return el;
}

function jawnosTaskbarAddPin(pin) {
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order.slice() : jawnosTaskbarDefaultOrder();
	if (pin.app) { order.push({ k: 'pin', app: pin.app, sel: pin.sel || undefined, hint: pin.hint, src: pin.src }); }
	else { order.push({ k: 'pin', sel: pin.sel, hint: pin.hint, src: pin.src }); }
	jawnosBars.order = order;
	jawnosTaskbarSave('taskbar_order', JSON.stringify(order));
	jawnosBarsApply();
}

// Pin a window's app: an app-keyed pin, so when the window is open the tile
// doubles as its window button instead of standing beside it.
function jawnosTaskbarAddAppPin(pin) {
	if (jawnosTaskbarAppPinned(pin.app)) { return; }
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order.slice() : jawnosTaskbarDefaultOrder();
	order.push({ k: 'pin', app: pin.app, hint: pin.hint, src: pin.src });
	jawnosBars.order = order;
	jawnosTaskbarSave('taskbar_order', JSON.stringify(order));
	jawnosBarsApply();
}

function jawnosTaskbarRemovePin(sel) {
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order.slice() : jawnosTaskbarDefaultOrder();
	order = order.filter(function (item) { return !(item && typeof item === 'object' && item.sel == sel && !item.app); });
	jawnosBars.order = order;
	jawnosTaskbarSave('taskbar_order', JSON.stringify(order));
	jawnosBarsApply();
}

function jawnosTaskbarRemoveAppPin(app) {
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order.slice() : jawnosTaskbarDefaultOrder();
	order = order.filter(function (item) { return !(item && typeof item === 'object' && item.app == app); });
	jawnosBars.order = order;
	jawnosTaskbarSave('taskbar_order', JSON.stringify(order));
	jawnosBarsApply();
}

// Keep the bar truthful about the windows. An app pin whose window exists has the
// window button parked in its place (the pin's icon hides), so a pinned app and
// its window are one tile; when the window closes the button goes and the pin's
// icon returns. Every window tile wears its state: the top one sunk, the rest of
// the open ones raised. It is idempotent: a pass that runs without a taskbar
// rebuild (topLevelNow calls it) must leave an already-parked button alone rather
// than remove it and find nothing to re-park.
function jawnosTaskbarPinsRefresh() {
	var bar = $('#taskbar');
	if (!bar.length) { return; }
	var windows = bar.find('#taskbar_windows');
	bar.find('.taskbar_app_pin').each(function () {
		var pin = $(this);
		var app = pin.attr('app');
		var win = $('.wind[app="' + app + '"]');
		var btn = windows.find('.window_toggle[app="' + app + '"]');
		var parked = pin.children('.window_toggle');
		if (win.length && (btn.length || parked.length)) {
			// a fresh button (after a rebuild) replaces the parked copy; with no
			// rebuild the parked one is the button, so it stays
			if (btn.length) { parked.remove(); btn.appendTo(pin); }
			pin.children('.taskbar_app_pin_icon').hide();
		}
		else {
			parked.remove();
			pin.children('.taskbar_app_pin_icon').show();
		}
	});
	var top = (typeof topWindow == 'function') ? topWindow() : null;
	bar.find('.window_toggle').each(function () {
		var el = $(this);
		var app = el.attr('app');
		var win = $('.wind[app="' + app + '"]');
		var visible = win.length > 0 && win.is(':visible');
		el.removeAttr('state');
		if (visible) { el.attr('state', (app == top) ? 'active' : 'open'); }
	});
	// the window in front keeps a bright title bar; the rest are greyed
	if (typeof jawnosWindowFocusApply == 'function') { jawnosWindowFocusApply(); }
}

function jawnosTaskbarClockZones() {
	var zones = [];
	try {
		if (window.Intl && Intl.supportedValuesOf) { zones = Intl.supportedValuesOf('timeZone'); }
	}
	catch (e) { zones = []; }
	if (!zones.length) {
		zones = ['UTC', 'America/Toronto', 'America/New_York', 'America/Chicago', 'America/Denver',
			'America/Los_Angeles', 'Europe/London', 'Europe/Paris', 'Europe/Berlin', 'Asia/Tokyo',
			'Asia/Shanghai', 'Asia/Kolkata', 'Australia/Sydney'];
	}
	return zones;
}

function jawnosTaskbarContextBuild() {
	var editing = jawnosTaskbarEditing();
	var selected = function (on) { return on ? '✓' : ''; };
	var context = $('<div class="taskbar_context"></div>');

	context.append('<div class="taskbar_context_selection" act="edit">Edit mode<span class="taskbar_context_check">' + selected(editing) + '</span></div>');

	context.append('<div class="taskbar_context_label">Position</div>');
	['top', 'bottom', 'hidden'].forEach(function (edge) {
		var label = edge == 'bottom' ? 'Bottom' : (edge == 'top' ? 'Top' : 'Hidden');
		context.append('<div class="taskbar_context_selection" act="pos" val="' + edge + '">' + label + '<span class="taskbar_context_check">' + selected(jawnosBars.taskbar == edge) + '</span></div>');
	});

	context.append('<div class="taskbar_context_selection" act="autohide">Autohide<span class="taskbar_context_check">' + selected(jawnosBars.autohide == 'on') + '</span></div>');

	context.append('<div class="taskbar_context_selection" act="clock">Clock<span class="taskbar_context_check">▸</span></div>');
	var clock = $('<div class="taskbar_context_sub" sub="clock" style="display:none;"></div>');
	var format = $('<label>Face <select class="taskbar_clock_format"><option value="24">24 hour</option><option value="12">12 hour</option></select></label>');
	format.find('select').val(jawnos_clock_format || '24');
	clock.append(format);
	var zone = $('<label>Time zone <select class="taskbar_clock_zone"></select></label>');
	zone.find('select').append('<option value="">Local</option>');
	jawnosTaskbarClockZones().forEach(function (z) {
		zone.find('select').append($('<option></option>').attr('value', z).text(z));
	});
	zone.find('select').val((typeof jawnos_clock_timezone != 'undefined' && jawnos_clock_timezone) ? jawnos_clock_timezone : '');
	clock.append(zone);
	var notify = $('<label style="flex-direction:row;display:flex;gap:8px;align-items:center;"><input type="checkbox" class="taskbar_clock_notifications"> Notifications</label>');
	notify.find('input').prop('checked', (typeof jawnos_clock_notifications == 'undefined' || jawnos_clock_notifications != 'off'));
	clock.append(notify);
	context.append(clock);

	context.append('<div class="taskbar_context_selection" act="add">Add items<span class="taskbar_context_check">▸</span></div>');
	var add = $('<div class="taskbar_context_sub" sub="add" style="display:none;"></div>');
	// the rows live in their own fixed-height scroller, so a long list is read by
	// scrolling rather than running off the screen
	var list = $('<div class="taskbar_context_apps"></div>').appendTo(add);
	var add_label = function (text) { list.append('<div class="taskbar_context_label">' + text + '</div>'); };
	var add_rows = function (pins) {
		pins.forEach(function (pin) {
			var on = pin.app ? jawnosTaskbarAppPinned(pin.app) : jawnosTaskbarPinned(pin.sel);
			var row = $('<div class="taskbar_context_app"></div>');
			row.attr('pin_sel', pin.sel).attr('pin_hint', pin.hint).attr('pin_src', pin.src);
			if (pin.app) { row.attr('pin_app', pin.app); }
			row.append($('<img>').attr('src', pin.src));
			row.append($('<span></span>').text(pin.hint || pin.sel));
			row.append('<span class="taskbar_context_check">' + selected(on) + '</span>');
			list.append(row);
		});
	};
	var fill_apps = function (pins) {
		if (!pins.length) { add_label('No apps found'); return; }
		add_label('Apps');
		add_rows(pins);
	};
	var fill_foot = function (pins) {
		if (!pins.length) { return; }
		add_label('Start Menu');
		add_rows(pins);
	};
	var fill_keyboards = function () {
		var keyboards = jawnosTaskbarKeyboardPins();
		if (keyboards.length) { add_label('Keyboards'); add_rows(keyboards); }
	};
	var fill_widgets = function () {
		add_label('Widgets');
		Object.keys(jawnosTaskbarWidgets).forEach(function (w) {
			var spec = jawnosTaskbarWidgets[w];
			var row = $('<div class="taskbar_context_app"></div>');
			row.attr('pin_widget', w);
			row.append($('<img>').attr('src', spec.icon));
			row.append($('<span></span>').text(jawnosT(spec.hint)));
			row.append('<span class="taskbar_context_check">' + selected(jawnosTaskbarWidgetOn(w)) + '</span>');
			list.append(row);
		});
	};
	// the menu's markup is only in the DOM once it has been opened; otherwise it
	// is fetched the way the menu itself fetches it
	fill_widgets();
	var live = jawnosTaskbarAppPins();
	if (live.length) {
		fill_apps(live);
		fill_foot(jawnosTaskbarFootPinsFrom($('#start_menu')));
		fill_keyboards();
	}
	else {
		var loading = $('<div class="taskbar_context_label">Loading apps…</div>').appendTo(list);
		$.ajax({
			url: '/manager/start_menu', type: 'GET', data: { menu: 'app' },
			success: function (response) {
				loading.remove();
				var root = $('<div>').html(response.html || '');
				fill_apps(jawnosTaskbarPinsFrom(root));
				fill_foot(jawnosTaskbarFootPinsFrom(root));
				fill_keyboards();
			},
			error: function () { loading.text('Could not load the apps'); }
		});
	}
	context.append(add);

	return context;
}

// A widget's own menu: its three display modes first, then the bar's normal
// menu (edit mode, position, autohide, clock, add items) underneath. The base
// menu is built by jawnosTaskbarContextBuild and its children are moved here,
// so the widget menu never has to keep a second copy of those handlers.
function jawnosTaskbarWidgetContextBuild(w) {
	var spec = jawnosTaskbarWidgets[w] || { hint: w };
	var mode = jawnosTaskbarWidgetMode(w);
	var selected = function (on) { return on ? '✓' : ''; };
	var context = $('<div class="taskbar_context"></div>');
	context.append('<div class="taskbar_context_label">' + jawnosT(spec.hint) + ' ' + jawnosT('widget') + '</div>');
	[['icon', 'Icon'], ['full', 'Icon and status'], ['off', 'Disabled']].forEach(function (pair) {
		context.append('<div class="taskbar_context_selection" act="widget_mode" w="' + w + '" mode="' + pair[0] + '">'
			+ jawnosT(pair[1]) + '<span class="taskbar_context_check">' + selected(mode == pair[0]) + '</span></div>');
	});
	var base = jawnosTaskbarContextBuild();
	context.append('<div class="taskbar_context_label">' + jawnosT('Taskbar') + '</div>');
	context.append(base.children());
	return context;
}

// A window is maximized when its own Restore control is showing, or when its
// view is 'max' (a window dragged to 95%+ of the screen records the view even
// though the buttons may not have flipped). The view attribute is only kept off
// phones, so the control's own state is the tell there.
