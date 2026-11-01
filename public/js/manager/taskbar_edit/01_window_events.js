function jawnosWindowMaximized(app) {
	var wind = $('.wind[app="' + app + '"]');
	return wind.find('.restore_button').is(':visible') || wind.attr('view') == 'max';
}

// A window's own menu: the things a window manager offers, plus the pin the bar
// already had. Right-clicking (or holding) a window button raises this instead
// of the bar's menu.
function jawnosWindowContextBuild(app) {
	var selected = function (on) { return on ? '✓' : ''; };
	var t = function (key, english) { return (typeof jawnosDockText == 'function') ? jawnosDockText(key, english) : (english || key); };
	var context = $('<div class="taskbar_context"></div>');
	context.append('<div class="taskbar_context_selection" act="win_close" app="' + app + '">Close</div>');
	context.append('<div class="taskbar_context_selection" act="win_max" app="' + app + '">' + (jawnosWindowMaximized(app) ? 'Restore' : 'Maximize') + '</div>');
	context.append('<div class="taskbar_context_selection" act="win_min" app="' + app + '">Minimize</div>');
	var moving = (typeof jawnos_move_app != 'undefined' && jawnos_move_app == app);
	context.append('<div class="taskbar_context_selection" act="win_move" app="' + app + '">Move<span class="taskbar_context_check">' + selected(moving) + '</span></div>');
	context.append('<div class="taskbar_context_label">Taskbar</div>');
	var pinned = jawnosTaskbarAppPinned(app);
	context.append('<div class="taskbar_context_selection" act="pin_app" app="' + app + '">' + (pinned ? 'Unpin from taskbar' : 'Pin to taskbar') + '</div>');
	// The same app can ride the dock instead of (or as well as) the taskbar.
	// dock_app_toggle is handled in keyboard.js, beside the dock's own faces;
	// the hint and icon are taken from the window button the menu was raised on.
	if (typeof jawnosDockHas == 'function') {
		var docked = jawnosDockHas(app);
		var wbtn = $('#taskbar .window_toggle').filter(function () { return $(this).attr('app') == app; }).first();
		var dock_src = wbtn.find('.window_toggle_icon').attr('src') || '';
		var dock_hint = wbtn.attr('formatted_name') || ((typeof format_name == 'function') ? format_name(app) : app);
		var dockrow = $('<div class="taskbar_context_selection" act="dock_app_toggle"></div>')
			.attr('dock_app', app).attr('dock_hint', dock_hint).attr('dock_src', dock_src);
		if (dock_src) {
			$('<img class="miniscule_thumb">').attr('src', dock_src)
				.css({ width: '20px', height: '20px', objectFit: 'contain' }).appendTo(dockrow);
		}
		$('<span></span>').text(docked ? t('dock.remove', 'Remove from dock') : t('dock.add', 'Add to dock')).appendTo(dockrow);
		context.append(dockrow);
	}
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
	// An app pin is a launcher, not a window: its menu is the dock's add/remove.
	var pin = $(e.target).closest('.taskbar_app_pin');
	if (pin.length && typeof jawnosDockAppMenu == 'function') {
		jawnosDockAppMenu(e.clientX, e.clientY, {
			app: pin.attr('app'),
			hint: pin.attr('hint'),
			src: pin.find('img').attr('src') || ''
		});
		return;
	}
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
