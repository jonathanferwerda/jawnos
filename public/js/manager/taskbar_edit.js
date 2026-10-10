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

// A press on a pin hands the press to the thing it was cloned from, so the pin
// opens the app exactly as its menu row would. The start menu's content is only
// in the DOM after it has been opened once; if it is not there, the menu is
// fetched (the same call the menu itself makes) and the press happens after.
function jawnosTaskbarPress(sel) {
	var target = $(document).find(sel).first();
	if (target.length) { target.trigger('click'); return; }
	$.ajax({
		url: '/manager/start_menu', type: 'GET', data: { menu: 'app' },
		success: function (response) {
			if (typeof startMenuRender == 'function') { startMenuRender(response.html, $('#start_menu_toggle')); }
			setTimeout(function () {
				var t2 = $(document).find(sel).first();
				if (t2.length) { t2.trigger('click'); }
			}, 250);
		}
	});
}

// One pinned tile. A menu pin (a start-menu row or a keyboard) is a plain
// picture that hands its press over to the live icon. An app pin (a window the
// user pinned) is a window button: when its window is open it wears the name and
// the same states as the open windows, so pin and window are one tile, not two.
function jawnosTaskbarPinMake(item) {
	if (item.app) { return jawnosTaskbarAppPinMake(item); }
	var pin = $('<img class="taskbar_pin little_thumb hover" draggable="false">');
	pin.attr('sel', item.sel).attr('hint', item.hint || '').attr('src', item.src || '');
	pin.on('click', function () {
		if (jawnosTaskbarEditing()) { return; }
		jawnosTaskbarPress(pin.attr('sel'));
	});
	return pin;
}

function jawnosTaskbarAppPinMake(item) {
	var pin = $('<span class="window_toggle taskbar_pin taskbar_app_pin" draggable="false"></span>');
	pin.attr('app', item.app).attr('hint', item.hint || '');
	pin.append($('<img class="window_toggle_icon little_thumb" draggable="false">').attr('src', item.src || ''));
	pin.append($('<span class="window_toggle_name_text" style="display:none;"></span>').text(item.hint || item.app));
	return pin;
}

// A press on an app pin is a press on its window when one is open (raise, step
// down or restore - the window button's own manners), and a launch when it is
// not.
function jawnosTaskbarAppPinPress(app) {
	if (jawnosTaskbarEditing()) { return; }
	var win = $('.wind[app="' + app + '"]');
	var timestamp = Date.now();
	if (!win.length || !win.is(':visible')) {
		if (win.length) { windowRestorer(timestamp, app); }
		else { appointmentGrabber(app, timestamp); }
		return;
	}
	var topApp = topWindow();
	if (app == topApp) { windowMinimizer(timestamp, app); }
	else { topLevelNow(win); }
}

// Lay the bar's furniture along the order, building pins as they come. Slots
// that are not listed keep a home at the end rather than vanish.
function jawnosTaskbarOrderApply() {
	var bar = $('#taskbar');
	if (!bar.length) { return; }
	var slots = jawnosTaskbarSlots();
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order.slice() : jawnosTaskbarDefaultOrder();
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
				order.push({ k: 'pin', app: el.attr('app'), hint: el.attr('hint'), src: el.find('img').attr('src') });
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
// live menu, or a fetched copy). Each pin is a picture and the selector that
// finds the live icon, so a press can hand itself over.
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
		pins.push({ sel: sel, hint: hint, src: src });
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

// Is this pin already on the bar?
function jawnosTaskbarPinned(sel) {
	return $('#taskbar').children('.taskbar_pin[sel="' + sel + '"]').length > 0;
}
function jawnosTaskbarAppPinned(app) {
	return $('#taskbar').children('.taskbar_app_pin[app="' + app + '"]').length > 0
		|| (jawnosBars.order || []).some(function (it) { return it && it.app == app; });
}

function jawnosTaskbarAddPin(pin) {
	var order = (jawnosBars.order && jawnosBars.order.length) ? jawnosBars.order.slice() : jawnosTaskbarDefaultOrder();
	order.push({ k: 'pin', sel: pin.sel, hint: pin.hint, src: pin.src });
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

// Keep the bar truthful about the windows: an app pin whose window exists (open
// or minimized) shows the name and stands in for the window button - the
// duplicate is hidden - and every window tile wears its state: the top one sunk,
// the rest that are open raised.
function jawnosTaskbarPinsRefresh() {
	var bar = $('#taskbar');
	if (!bar.length) { return; }
	bar.find('.taskbar_app_pin').each(function () {
		var pin = $(this);
		var app = pin.attr('app');
		var win = $('.wind[app="' + app + '"]');
		pin.find('.window_toggle_name_text').toggle(win.length > 0);
		if (win.length) { bar.find('#taskbar_windows .window_toggle[app="' + app + '"]').hide(); }
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

function jawnosTaskbarContextBuild(app) {
	var editing = jawnosTaskbarEditing();
	var selected = function (on) { return on ? '✓' : ''; };
	var context = $('<div class="taskbar_context"></div>');

	// a right-click on a window button can pin that app to the bar
	if (app) {
		var pinned = jawnosTaskbarAppPinned(app);
		context.append('<div class="taskbar_context_selection" act="pin_app" app="' + app + '">' + (pinned ? 'Unpin from taskbar' : 'Pin to taskbar') + '</div>');
		context.append('<div class="taskbar_context_label">Taskbar</div>');
	}

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
			var on = jawnosTaskbarPinned(pin.sel);
			var row = $('<div class="taskbar_context_app"></div>');
			row.attr('pin_sel', pin.sel).attr('pin_hint', pin.hint).attr('pin_src', pin.src);
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
	// the apps are only in the DOM once the start menu has been opened; otherwise
	// they are fetched the way the menu itself fetches them
	var live = jawnosTaskbarAppPins();
	if (live.length) { fill_apps(live); }
	else {
		var loading = $('<div class="taskbar_context_label">Loading apps…</div>').appendTo(list);
		$.ajax({
			url: '/manager/start_menu', type: 'GET', data: { menu: 'app' },
			success: function (response) {
				loading.remove();
				fill_apps(jawnosTaskbarPinsFrom($('<div>').html(response.html || '')));
			},
			error: function () { loading.text('Could not load the apps'); }
		});
	}
	var keyboards = jawnosTaskbarKeyboardPins();
	if (keyboards.length) { add_label('Keyboards'); add_rows(keyboards); }
	context.append(add);

	return context;
}

function jawnosTaskbarContextOpen(x, y, app) {
	jawnosTaskbarContextClose();
	var context = jawnosTaskbarContextBuild(app);
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

// long press on a touch screen opens the same menu
(function () {
	var timer = null;
	$(document).on('touchstart', '#taskbar', function (e) {
		var t = e.originalEvent.touches[0];
		var x = t.clientX, y = t.clientY;
		timer = setTimeout(function () { timer = null; jawnosTaskbarContextOpen(x, y); }, 550);
	});
	$(document).on('touchend touchmove touchcancel', '#taskbar', function () {
		if (timer) { clearTimeout(timer); timer = null; }
	});
})();

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
});

// an app pin answers as its window would
$(document).on('click', '.taskbar_app_pin', function () {
	if (jawnosTaskbarEditing()) { return; }
	jawnosTaskbarAppPinPress($(this).attr('app'));
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
	if (jawnosTaskbarPinned(sel)) {
		jawnosTaskbarRemovePin(sel);
		$(this).find('.taskbar_context_check').text('');
	}
	else {
		jawnosTaskbarAddPin({ sel: sel, hint: $(this).attr('pin_hint'), src: $(this).attr('pin_src') });
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
