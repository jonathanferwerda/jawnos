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
// pin (an app or keyboard the user added) is an object and builds its own tile.
function jawnosTaskbarSlots() {
	return {
		'search': '#search_entanglement',
		'windows': '#taskbar_windows',
		'clock': '#taskbar_clock',
		'icons': '#taskbar_icons'
	};
}

// The order before the user has ever dragged anything: the window list, the
// clock and the start button, with the search at the leading edge when it lives
// here. The old start-button side setting is honoured once, so a bar that had
// the button on the left keeps it there until it is dragged.
function jawnosTaskbarDefaultOrder() {
	var left = (typeof jawnosBars != 'undefined' && jawnosBars.start_side == 'left');
	return left ? ['icons', 'search', 'windows', 'clock'] : ['search', 'windows', 'clock', 'icons'];
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
	var action = { backup_now: 1, stop_all: 1, upload: 1, voice_prompt: 1, nfc_benign_reader: 1, sms_list_check: 1, permission_asker: 1, torch_toggle: 1, now_toggle: 1 };
	if (action[id]) { return null; }
	var alias = { image_toggle: 'gallery' };
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
		// fallback for a bare appointment, which is not what a pinned app is)
		if (typeof appWindowOpener == 'function') { appWindowOpener(app, timestamp); }
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
	// undo an older pin that mistook an action (now) for an app
	order = order.map(function (item) {
		if (item && typeof item === 'object' && item.k == 'pin' && item.sel) {
			var derived = jawnosTaskbarDeriveApp(item.sel);
			if (derived && !item.app) { return { k: 'pin', app: derived, sel: item.sel, hint: item.hint, src: item.src }; }
			if (!derived && item.app && /#start_menu #/.test(item.sel)) { return { k: 'pin', sel: item.sel, hint: item.hint, src: item.src }; }
		}
		return item;
	});
	jawnosBars.order = order;
	// the three fixed slots never fall off the bar; the search only counts while
	// the taskbar is its home
	['windows', 'clock', 'icons'].forEach(function (k) {
		if (order.indexOf(k) < 0) { order.push(k); }
	});
	if (jawnosBars.search == 'taskbar' && order.indexOf('search') < 0) { order.push('search'); }

	bar.children('.taskbar_pin').remove();
	order.forEach(function (item) {
		var el = null;
		if (item && typeof item === 'object' && item.k == 'pin') {
			el = jawnosTaskbarPinMake(item);
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

// Read the bar back into an order and keep it. Called when a drag settles.
function jawnosTaskbarOrderSave() {
	var order = [];
	$('#taskbar').children().each(function () {
		var el = $(this);
		if (el.is('#taskbar_windows')) { order.push('windows'); }
		else if (el.is('#taskbar_clock')) { order.push('clock'); }
		else if (el.is('#taskbar_icons')) { order.push('icons'); }
		else if (el.is('#search_entanglement')) { order.push('search'); }
		else if (el.hasClass('taskbar_pin')) {
			if (el.hasClass('taskbar_app_pin')) {
				order.push({ k: 'pin', app: el.attr('app'), sel: el.attr('sel') || undefined, hint: el.attr('hint'), src: el.children('img').first().attr('src') });
			}
			else {
				order.push({ k: 'pin', sel: el.attr('sel'), hint: el.attr('hint'), src: el.attr('src') });
			}
		}
	});
	jawnosBars.order = order;
	jawnosTaskbarSave('taskbar_order', JSON.stringify(order));
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
	if (on) {
		bar.addClass('taskbar_edit');
		if (!bar.hasClass('ui-sortable')) {
			bar.sortable({
				items: '> #taskbar_windows, > #taskbar_clock, > #taskbar_icons, > #search_entanglement, > .taskbar_pin',
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
function jawnosTaskbarKeyboardPins() {
	var pins = [];
	$('#pseudonym_home .pseudonym').each(function () {
		var p = $(this);
		var id = p.attr('id');
		if (!id) { return; }
		pins.push({ sel: '#pseudonym_home #' + id, hint: p.attr('hint') || p.attr('name') || id, src: p.attr('src') || '' });
	});
	return pins;
}

// The start menu's foot buttons - leave, the site type, now, the assistant and
// the bird. They are launchers (an action, not an app window), keyed by a
// selector into the live menu.
function jawnosTaskbarFootPinsFrom(root) {
	var pins = [];
	root.find('.leave, .site_type_manual_changer_toggle, #now_toggle, #assistant, .fuck_you').each(function () {
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
// the open ones raised.
function jawnosTaskbarPinsRefresh() {
	var bar = $('#taskbar');
	if (!bar.length) { return; }
	var windows = bar.find('#taskbar_windows');
	// drop the button parked by the previous pass; the fresh list is what is moved
	bar.find('.taskbar_app_pin > .window_toggle').remove();
	bar.find('.taskbar_app_pin').each(function () {
		var pin = $(this);
		var app = pin.attr('app');
		var win = $('.wind[app="' + app + '"]');
		var btn = windows.find('.window_toggle[app="' + app + '"]');
		if (win.length && btn.length) {
			btn.appendTo(pin);
			pin.children('.taskbar_app_pin_icon').hide();
		}
		else {
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
	// the menu's markup is only in the DOM once it has been opened; otherwise it
	// is fetched the way the menu itself fetches it
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

// A window is maximized when its own Restore control is showing, or when its
// view is 'max' (a window dragged to 95%+ of the screen records the view even
// though the buttons may not have flipped). The view attribute is only kept off
// phones, so the control's own state is the tell there.
function jawnosWindowMaximized(app) {
	var wind = $('.wind[app="' + app + '"]');
	return wind.find('.restore_button').is(':visible') || wind.attr('view') == 'max';
}

// A window's own menu: the things a window manager offers, plus the pin the bar
// already had. Right-clicking (or holding) a window button raises this instead
// of the bar's menu.
function jawnosWindowContextBuild(app) {
	var selected = function (on) { return on ? '✓' : ''; };
	var context = $('<div class="taskbar_context"></div>');
	context.append('<div class="taskbar_context_selection" act="win_close" app="' + app + '">Close</div>');
	context.append('<div class="taskbar_context_selection" act="win_max" app="' + app + '">' + (jawnosWindowMaximized(app) ? 'Restore' : 'Maximize') + '</div>');
	context.append('<div class="taskbar_context_selection" act="win_min" app="' + app + '">Minimize</div>');
	var moving = (typeof jawnos_move_app != 'undefined' && jawnos_move_app == app);
	context.append('<div class="taskbar_context_selection" act="win_move" app="' + app + '">Move<span class="taskbar_context_check">' + selected(moving) + '</span></div>');
	context.append('<div class="taskbar_context_label">Taskbar</div>');
	var pinned = jawnosTaskbarAppPinned(app);
	context.append('<div class="taskbar_context_selection" act="pin_app" app="' + app + '">' + (pinned ? 'Unpin from taskbar' : 'Pin to taskbar') + '</div>');
	return context;
}

function jawnosTaskbarContextOpen(x, y, app) {
	jawnosTaskbarContextClose();
	var context = app ? jawnosWindowContextBuild(app) : jawnosTaskbarContextBuild();
	$('body').append(context);
	// keep it on screen
	var w = context.outerWidth();
	var h = context.outerHeight();
	var left = Math.max(4, Math.min(x, $(window).width() - w - 4));
	var top = Math.max(4, Math.min(y, $(window).height() - h - 4));
	context.css({ left: left + 'px', top: top + 'px' });
}

$(document).on('contextmenu', '#taskbar', function (e) {
	e.preventDefault();
	// the app under the pointer, if the press landed on a window button
	var win = $(e.target).closest('.window_toggle');
	var app = win.length ? win.attr('app') : null;
	jawnosTaskbarContextOpen(e.clientX, e.clientY, app);
});

// a long press opens the same menu on touch: the shared handler dispatches a
// contextmenu at the finger, which the handler above catches
if (typeof jawnosContextMenuOn == 'function') { jawnosContextMenuOn('#taskbar'); }

// any press elsewhere, or Escape, puts it away
$(document).on('click', function (e) {
	if ($(e.target).closest('.taskbar_context, #taskbar').length == 0) { jawnosTaskbarContextClose(); }
});
$(document).on('keyup', function (e) {
	if (e.keyCode == 27) { jawnosTaskbarContextClose(); }
});

$(document).on('click', '.taskbar_context_selection', function () {
	var act = $(this).attr('act');
	if (act == 'edit') {
		jawnosTaskbarEdit(!jawnosTaskbarEditing());
		jawnosTaskbarContextClose();
	}
	else if (act == 'pos') {
		jawnosBars.taskbar = $(this).attr('val');
		jawnosTaskbarSave('taskbar_position', jawnosBars.taskbar);
		jawnosBarsApply();
		jawnosTaskbarContextClose();
	}
	else if (act == 'autohide') {
		jawnosBars.autohide = (jawnosBars.autohide == 'on') ? 'off' : 'on';
		jawnosTaskbarSave('taskbar_autohide', jawnosBars.autohide);
		jawnosBarsApply();
		jawnosTaskbarContextClose();
	}
	else if (act == 'clock') {
		$('.taskbar_context_sub[sub="clock"]').toggle();
		$('.taskbar_context_sub[sub="add"]').hide();
	}
	else if (act == 'add') {
		$('.taskbar_context_sub[sub="add"]').toggle();
		$('.taskbar_context_sub[sub="clock"]').hide();
	}
	else if (act == 'pin_app') {
		var app = $(this).attr('app');
		if (jawnosTaskbarAppPinned(app)) { jawnosTaskbarRemoveAppPin(app); }
		else {
			var btn = $('#taskbar .window_toggle[app="' + app + '"]').first();
			var hint = btn.attr('formatted_name') || ((typeof format_name == 'function') ? format_name(app) : app);
			var src = btn.find('.window_toggle_icon').attr('src') || '';
			jawnosTaskbarAddAppPin({ app: app, hint: hint, src: src });
		}
		jawnosTaskbarContextClose();
	}
	else if (act == 'win_close' || act == 'win_max' || act == 'win_min') {
		// press the window's own button, so its handler does the work
		var wapp = $(this).attr('app');
		var wind = $('.wind[app="' + wapp + '"]');
		if (act == 'win_close') { wind.find('.close_button').trigger('click'); }
		else if (act == 'win_max') {
			// press whichever control the window is showing: a maximized one
			// restores, an ordinary one maximizes
			if (jawnosWindowMaximized(wapp)) { wind.find('.restore_button').trigger('click'); }
			else { wind.find('.maximize_button').trigger('click'); }
		}
		else { windowMinimizer(Date.now(), wapp); }
		jawnosTaskbarContextClose();
	}
	else if (act == 'win_move') {
		// the window is dragged from anywhere for one move, or until pressed again
		var mapp = $(this).attr('app');
		if (typeof jawnosWindowMoveMode == 'function') { jawnosWindowMoveMode(mapp); }
		jawnosTaskbarContextClose();
	}
});

// the clock's own face, written where it is changed
$(document).on('change', '.taskbar_clock_format', function () {
	jawnos_clock_format = $(this).val();
	jawnosTaskbarSave('clock_format', jawnos_clock_format);
	jawnosClockShow();
});
$(document).on('change', '.taskbar_clock_zone', function () {
	jawnos_clock_timezone = $(this).val();
	jawnosTaskbarSave('clock_timezone', jawnos_clock_timezone);
	jawnosClockShow();
});
$(document).on('change', '.taskbar_clock_notifications', function () {
	jawnos_clock_notifications = $(this).prop('checked') ? 'on' : 'off';
	jawnosTaskbarSave('clock_notifications', jawnos_clock_notifications);
});

// a press on an app in the add list pins it, or unpins a pinned one
$(document).on('click', '.taskbar_context_app', function () {
	var sel = $(this).attr('pin_sel');
	var app = $(this).attr('pin_app') || '';
	var on = app ? jawnosTaskbarAppPinned(app) : jawnosTaskbarPinned(sel);
	if (on) {
		if (app) { jawnosTaskbarRemoveAppPin(app); } else { jawnosTaskbarRemovePin(sel); }
		$(this).find('.taskbar_context_check').text('');
	}
	else {
		jawnosTaskbarAddPin({ sel: sel, app: app || null, hint: $(this).attr('pin_hint'), src: $(this).attr('pin_src') });
		$(this).find('.taskbar_context_check').text('✓');
	}
});

// The bar is laid out afresh on every apply, so it takes the order again. The
// window displayer is wrapped so the pins and the states are refreshed every
// time the window list is rebuilt, whatever rebuilt it.
$(document).ready(function () {
	if (typeof taskbarDisplayer == 'function' && !taskbarDisplayer.__jawnos_wrapped) {
		var base = taskbarDisplayer;
		taskbarDisplayer = function () {
			var result = base.apply(this, arguments);
			if (typeof jawnosTaskbarPinsRefresh == 'function') { jawnosTaskbarPinsRefresh(); }
			return result;
		};
		taskbarDisplayer.__jawnos_wrapped = true;
	}
	if (typeof jawnosTaskbarOrderApply == 'function') { jawnosTaskbarOrderApply(); }
	if (typeof jawnosTaskbarPinsRefresh == 'function') { jawnosTaskbarPinsRefresh(); }
});
