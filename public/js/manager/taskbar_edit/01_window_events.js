function jawnosWindowMaximized(app) {
	var wind = $('.wind[app="' + app + '"]');
	return wind.find('.restore_button').is(':visible') || wind.attr('view') == 'max';
}

// A window's own menu: the things a window manager offers, plus the pin the bar
// already had. Right-clicking (or holding) a window button raises this instead
// of the bar's menu.
function jawnosWindowContextBuild(app, timestamp) {
	var selected = function (on) { return on ? '✓' : ''; };
	var context = $('<div class="taskbar_context"></div>');
	context.append('<div class="taskbar_context_selection" act="win_close" app="' + app + '">Close</div>');
	context.append('<div class="taskbar_context_selection" act="win_max" app="' + app + '">' + (jawnosWindowMaximized(app) ? 'Restore' : 'Maximize') + '</div>');
	context.append('<div class="taskbar_context_selection" act="win_min" app="' + app + '">Minimize</div>');
	var moving = (typeof jawnos_move_app != 'undefined' && jawnos_move_app == app);
	context.append('<div class="taskbar_context_selection" act="win_move" app="' + app + '">Move<span class="taskbar_context_check">' + selected(moving) + '</span></div>');
	// A local window may move to another desk; a peer desk holds no local window,
	// and a dialog is not a window of any one desk.
	if (app != 'dialog' && typeof jawnosShellLayout == 'function') {
		var layout = jawnosShellLayout();
		var active = (typeof jawnosShellActiveWorkspace == 'function') ? jawnosShellActiveWorkspace() : null;
		var multi = (app == 'terminal' || app == 'folders' || app == 'now');
		var others = $.grep(layout.workspaces || [], function (ws) {
			if (!ws || ws.id == (active && active.id) || ws.kind == 'peer') { return false; }
			// A single-window app cannot live on two desks at once: a desk that
			// already holds it is left out rather than duplicating it.
			if (multi) { return true; }
			var clash = false;
			$('.wind').each(function () {
				if ($(this).attr('app') == app && $(this).attr('workspace') == ws.id) { clash = true; }
			});
			return !clash;
		});
		context.append($('<div class="taskbar_context_label"></div>').text(jawnosT('Move to desktop')));
		if (!others.length) {
			context.append($('<div class="taskbar_context_label"></div>').text(jawnosT('No other desktop')));
		}
		else {
			$.each(others, function (i, ws) {
				var name = ws.name || jawnosT('Workspace');
				if (ws.kind == 'room') { name += ' — ' + jawnosT('Saved'); }
				context.append($('<div class="taskbar_context_selection" act="win_ws"></div>')
					.attr('app', app).attr('ws', ws.id).attr('timestamp', timestamp || '')
					.append($('<span></span>').text(name)));
			});
		}
	}
	context.append('<div class="taskbar_context_label">Taskbar</div>');
	var pinned = jawnosTaskbarAppPinned(app);
	context.append('<div class="taskbar_context_selection" act="pin_app" app="' + app + '">' + (pinned ? 'Unpin from taskbar' : 'Pin to taskbar') + '</div>');
	// The dock shows the same pin: one list feeds both bars.
	return context;
}

function jawnosTaskbarContextOpen(x, y, app, widget, bar, timestamp) {
	jawnosTaskbarContextClose();
	var context = app ? jawnosWindowContextBuild(app, timestamp)
		: (widget ? jawnosTaskbarWidgetContextBuild(widget, bar) : jawnosTaskbarContextBuild(bar));
	$('body').append(context);
	// keep it on screen
	var w = context.outerWidth();
	var h = context.outerHeight();
	var left = Math.max(4, Math.min(x, $(window).width() - w - 4));
	var top = Math.max(4, Math.min(y, $(window).height() - h - 4));
	context.css({ left: left + 'px', top: top + 'px' });
}

$(document).on('contextmenu', '.jawnos_taskbar', function (e) {
	e.preventDefault();
	var bar = $(this);
	// A widget is not a pin or a window: its menu adds the three display modes
	// above the bar's normal furniture.
	var widget = $(e.target).closest('.taskbar_widget');
	if (widget.length) {
		jawnosTaskbarContextOpen(e.clientX, e.clientY, null, widget.attr('widget'), bar);
		return;
	}
	// A window button wins over the pin that may carry it: while a pinned app's
	// window is open its own button is parked inside the pin, so the press asks
	// for that window's menu - Close, Maximize, Minimize, Move, another desktop
	// and Unpin - not the pin's lone add/remove row.
	var win = $(e.target).closest('.window_toggle');
	if (win.length) {
		jawnosTaskbarContextOpen(e.clientX, e.clientY, win.attr('app'), null, bar, win.attr('timestamp') || '');
		return;
	}
	// A closed app pin is a launcher: its menu is the dock's add/remove.
	var pin = $(e.target).closest('.taskbar_app_pin');
	if (pin.length && typeof jawnosDockAppMenu == 'function') {
		jawnosDockAppMenu(e.clientX, e.clientY, {
			app: pin.attr('app'),
			hint: pin.attr('hint'),
			src: pin.find('img').attr('src') || ''
		});
		return;
	}
	jawnosTaskbarContextOpen(e.clientX, e.clientY, null, null, bar, '');
});

// a long press opens the same menu on touch: the shared handler dispatches a
// contextmenu at the finger, which the handler above catches
if (typeof jawnosContextMenuOn == 'function') { jawnosContextMenuOn('.jawnos_taskbar'); }

// any press elsewhere, or Escape, puts it away
$(document).on('click', function (e) {
	if ($(e.target).closest('.taskbar_context, .jawnos_taskbar').length == 0) { jawnosTaskbarContextClose(); }
});
$(document).on('keyup', function (e) {
	if (e.keyCode == 27) { jawnosTaskbarContextClose(); }
});

$(document).on('click', '.taskbar_context_selection', function () {
	var act = $(this).attr('act');
	var bar_id = $(this).closest('.taskbar_context').attr('bar_id') || '';
	if (act == 'edit') {
		jawnosTaskbarEdit(!jawnosTaskbarEditing());
		jawnosTaskbarContextClose();
	}
	else if (act == 'pos') {
		var val = $(this).attr('val');
		if (bar_id && typeof jawnosShellBarIsPrimary == 'function' && !jawnosShellBarIsPrimary(bar_id)) {
			jawnosShellBarEdgeSet(bar_id, val);
		}
		else {
			jawnosBars.taskbar = val;
			jawnosTaskbarSave('taskbar_position', jawnosBars.taskbar);
			jawnosBarsApply();
		}
		jawnosTaskbarContextClose();
	}
	else if (act == 'shell_add_bar') {
		jawnosShellBarAdd($(this).attr('kind') || 'taskbar');
		jawnosTaskbarContextClose();
	}
	else if (act == 'shell_remove_bar') {
		jawnosShellBarRemove(bar_id);
		jawnosTaskbarContextClose();
	}
	else if (act == 'shell_ws') {
		jawnosShellWorkspaceSet($(this).attr('val'));
		jawnosTaskbarContextClose();
	}
	else if (act == 'shell_ws_add') {
		jawnosShellWorkspaceAdd();
		jawnosTaskbarContextClose();
	}
	else if (act == 'shell_ws_remove') {
		var ws = (typeof jawnosShellActiveWorkspace == 'function') ? jawnosShellActiveWorkspace() : null;
		if (ws) { jawnosShellWorkspaceRemove(ws.id); }
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
	else if (act == 'widget_mode') {
		jawnosTaskbarWidgetSet($(this).attr('w'), $(this).attr('mode'));
		jawnosTaskbarContextClose();
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
	else if (act == 'win_ws') {
		// The tile carries the window's own stamp, so a second Terminal or
		// Folders window moves instead of the first one of its app.
		var wts = $(this).attr('timestamp') || '';
		var wapp = $(this).attr('app') || '';
		var wind = wts ? $('#window_' + wts) : $('.wind[app="' + wapp + '"]').first();
		if (wind.length && typeof jawnosWorkspaceWindowMove == 'function') {
			jawnosWorkspaceWindowMove(wind, $(this).attr('ws'));
		}
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

// a press on an app in the add list pins it, or unpins a pinned one; a press on
// a widget row enables or disables that widget
$(document).on('click', '.taskbar_context_app', function () {
	var widget = $(this).attr('pin_widget');
	if (widget) {
		jawnosTaskbarWidgetToggle(widget);
		$(this).find('.taskbar_context_check').text(jawnosTaskbarWidgetOn(widget) ? '✓' : '');
		return;
	}
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
			if (typeof jawnosDockWindowsRender == 'function') { jawnosDockWindowsRender(); }
			// every extra taskbar reads the same windows; the guard in the shell
			// keeps this from calling itself through the displayer below
			if (!jawnosShell.syncing && typeof jawnosShellTaskbarSync == 'function') { jawnosShellTaskbarSync(); }
			return result;
		};
		taskbarDisplayer.__jawnos_wrapped = true;
	}
	if (typeof jawnosTaskbarOrderApply == 'function') { jawnosTaskbarOrderApply(); }
	if (typeof jawnosTaskbarWindowDragInit == 'function') { jawnosTaskbarWindowDragInit(); }
	if (typeof jawnosTaskbarPinsRefresh == 'function') { jawnosTaskbarPinsRefresh(); }
	if (typeof jawnosDockWindowsRender == 'function') { jawnosDockWindowsRender(); }
});
