/* [[js-split]]
   windows.js is part 1. The rest live in windows/ in name order:
     01_storage.js  - windowSaver, retriever, appWindowOpener, windowjOpener
     02_fit.js  - minimise/restore/move, draggable, viewport/fit, phone check
     03_stack.js  - stacker, close, z-order, everythingMoves, dimension setter, background, drawer
     04_act.js  - appActSync, the act panel open/close message the beat no longer carries
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */

var windows = [];

// A window's identity is its timestamp: window_<timestamp>,
// window_contents_<timestamp>, little_window_<timestamp>. Date.now() alone is
// not enough - a restore opens the whole desk in one pass, so several windows
// would mint the same millisecond and share one id, and closeWindow() (which
// addresses a window by id) could then take the wrong one down with it. This
// hands out a stamp no window on this page has used.
// [[window-timestamp]]
var jawnosLastWindowStamp = 0;
function jawnosWindowTimestamp(requested) {
	var stamp = parseInt(requested, 10);
	if (isNaN(stamp) || stamp <= 0) { stamp = Date.now(); }
	if (stamp <= jawnosLastWindowStamp) { stamp = jawnosLastWindowStamp + 1; }
	while (document.getElementById('window_' + stamp)) { stamp++; }
	jawnosLastWindowStamp = stamp;
	return stamp;
}
// [[/window-timestamp]]

var appt_containers = {
	're_details': 'det',
	'inventory_details': 'inventory',
	'app_details': 'reset',
	'appointment_display': 'appointment_configuration_grabber',
	're_tasks': 'tasks',
	're_measures': 'measures',
	're_register': 'register'
};

// The app_act row (measures, tasks, reset, configure, inventory, details,
// register) opens one panel at a time: opening any of them closes whichever
// other one was showing, so a second tap never leaves two panels stacked.
function appActExclusive(app, keep) {
	var appointment = $('.appointment[app="' + app + '"]');
	$.each(appt_containers, function(container, opener) {
		if (opener == keep) { return; }
		var panel = appointment.find('.' + container);
		if (panel.is(':visible')) { panel.hide(); }
	});
}

var config_appt_containers = {
	'me_setting_list': 'me_settings',
	'backup_list': 'restore_list',
	'device_list': 'device_lister',
	'system_list': 'system_setting_lister',
	'configure_appointment_list': 'appointment_list_grabber',
	'misc_setting_list': 'misc_setting',
	'plat_setting_list': 'plat_setting',
	'pseudonym_list': 'pseudonym_setting_lister',
	'store_list': 'store_setting_lister',
	'tunnel_list': 'tunnel_lister'
}
var top_level_now = 100;
var winLine = 0;
var fullXCount = 0;
var fullYCount = 0;
var jws = undefined;
var jopen = undefined;


function window_initializer(id) {
	var win = $(document.createElement('div'));
	win.setAttribute('id', id + '_window');
	var wind = $(win);
	var element = $('#' + id);
	var app = element.find('div');
	windows[id] = { formatted_name: app.attr('formatted_name') };
	// The name is a label, not markup: build the bar as DOM so a name with
	// angle brackets in it stays text.
	wind.empty().append($('<div>').attr('id', id + '_window').text(windows[id]['formatted_name'] || ''));
	wind.css({ 'left': '30%', 'bottom': 0, 'background-color': 'red', 'height': '80%', 'width': '70%' }).show();
}

// A window tile's identity, stable enough to keep a dragged order: a dialog's
// own id, a Terminal's session, a Folders window's id, or the app itself for
// the single-window apps (which the window maker reuses rather than doubling).
function jawnosTaskbarWindowKey(v) {
	var el = $(v);
	var dialog_id = el.attr('data-dialog-id') || '';
	if (dialog_id) { return 'dialog:' + dialog_id; }
	var app = el.attr('app') || '';
	var terminal_id = el.attr('data-terminal-id') || '';
	if (terminal_id) { return 'terminal:' + terminal_id; }
	var window_id = el.attr('data-window-id') || '';
	if (window_id) { return 'window:' + window_id; }
	return 'app:' + app;
}

// When a window entered the list. The server stamps every window with the
// moment it opened; a dialog is handed a sequence the first time it is seen (it
// is appended in the order it opened), so with no dragged order the tiles read
// left-to-right in the order they came up.
var jawnosTaskbarSeqSeen = 0;
function jawnosTaskbarWindowSeq(v) {
	var el = $(v);
	var timestamp = parseInt(el.attr('timestamp'), 10);
	if (!isNaN(timestamp) && timestamp > 0) { return timestamp; }
	var seen = parseInt(el.attr('data-taskbar-seq'), 10);
	if (!isNaN(seen) && seen > 0) { return seen; }
	jawnosTaskbarSeqSeen = Math.max(Date.now(), jawnosTaskbarSeqSeen + 1);
	el.attr('data-taskbar-seq', jawnosTaskbarSeqSeen);
	return jawnosTaskbarSeqSeen;
}

// The tiles in the order the person left them. Saved keys that no longer name
// an open window are dropped - a closed window has gone, so opening it again is
// a new one and belongs on the right - and tiles with no saved key follow in
// the order they were opened.
function jawnosTaskbarWindowOrderTiles(tiles) {
	var saved = (typeof jawnosBars != 'undefined' && jawnosBars.window_order) ? jawnosBars.window_order.slice() : [];
	var live = {};
	tiles.forEach(function (t) { live[t.key] = 1; });
	var pruned = saved.filter(function (k) { return live[k]; });
	if (pruned.length != saved.length && typeof jawnosBars != 'undefined') {
		jawnosBars.window_order = pruned;
		if (typeof jawnosTaskbarSave == 'function') { jawnosTaskbarSave('taskbar_window_order', JSON.stringify(pruned)); }
	}
	var pos = {};
	pruned.forEach(function (k, i) { if (pos[k] === undefined) { pos[k] = i; } });
	tiles.sort(function (a, b) {
		var ia = pos[a.key];
		var ib = pos[b.key];
		if (ia === undefined && ib === undefined) { return (a.seq - b.seq) || (a.index - b.index); }
		if (ia === undefined) { return 1; }
		if (ib === undefined) { return -1; }
		return (ia - ib) || (a.index - b.index);
	});
	return tiles;
}

// The taskbar's window list: one button per open window, in the order the
// windows were opened - oldest on the left, newest on the right - until the
// person drags a tile somewhere else. A dragged order is kept (the misc setting
// taskbar_window_order holds the window keys), and a window opened after that
// joins at the right-hand end. Raising a window never changes its place: the
// order is not the z-order. Dialog boxes count as windows too - the Alert, a
// folder question and a job's progress each get a tile - so any of them can be
// brought back or minimised from here.
function taskbarDisplayer(destination) {
	if (!destination) {
		destination = '#taskbar_windows';
	}
	if ($(destination).length == 0) { return; }
	var tiles = [];
	var timestamp = Date.now();
	$('.wind').each(function(i,v) {
		var z = numeral($(v).css('z-index')).value();
		var icon = $(v).find('.window_icon');
		var formatted_name = $(v).find('.name_text').text();
		var new_icon = icon.clone();

		new_icon.attr('formatted_name', formatted_name);
		var terminal_id = $(v).attr('data-terminal-id') || '';
		if (terminal_id) { new_icon.attr('data-terminal-id', terminal_id); }
		// a named window instance (Folders, now) gets its own tile too
		var window_id = $(v).attr('data-window-id') || '';
		if (window_id) { new_icon.attr('data-window-id', window_id); }
		if (!new_icon.attr('src')) {
			new_icon.css({ 'font-size': '30px', 'height': '60px' });
		}
		// the icon's own press belongs to the window it was cloned from (it calls
		// windowRestorer); in the bar the button's answer is the only one wanted,
		// or a press on a background window raises it and then toggles it away
		new_icon.removeAttr('onclick');
		new_icon.removeClass('window_icon');
		new_icon.addClass('window_toggle_icon little_thumb');

		tiles.push({ z: z, key: jawnosTaskbarWindowKey(v), seq: jawnosTaskbarWindowSeq(v), index: tiles.length, html: new_icon.wrap('<span/>').parent().html() });

		new_icon.show();
	});
	// A dialog is a window for the bar's purposes: a minimised one keeps its
	// tile, while a closed Alert carries hidden="yes" and stays out of the list.
	$('.dialog_box').each(function(i,v) {
		if ($(v).is('[hidden]')) { return; }
		var dialog_id = $(v).attr('data-dialog-id');
		if (!dialog_id) {
			dialog_id = 'dialog_' + Math.random().toString(36).substring(2);
			$(v).attr('data-dialog-id', dialog_id);
		}
		var title = $(v).attr('data-dialog-title') || $(v).find('.jawnos_dialog_title, .folders_dialog_title').first().text() || 'Dialog';
		var icon_src = $(v).attr('data-dialog-icon') || '/images/decipherable/windows.png';
		var icon = $('<img class="window_toggle_icon little_thumb">').attr('src', icon_src)
			.attr('app', 'dialog').attr('formatted_name', title)
			.attr('data-dialog-id', dialog_id);
		tiles.push({ z: numeral($(v).css('z-index')).value(), key: jawnosTaskbarWindowKey(v), seq: jawnosTaskbarWindowSeq(v), index: tiles.length, html: icon.wrap('<span/>').parent().html() });
	});
	// The dragged order when there is one, otherwise the order the windows were
	// opened in (see jawnosTaskbarWindowOrderTiles).
	jawnosTaskbarWindowOrderTiles(tiles);
	var html = '';
	var stamp = '';
	// The stamp deliberately leaves the z-index out: raising a window is not a
	// change to the list, and rebuilding identical tiles on every focus made the
	// buttons blink. The state pass (jawnosTaskbarPinsRefresh) still runs.
	$.each(tiles, function(i,v) { html += v.html; stamp += v.html + '\u0002'; });
	// The view poll calls windowBackgroundAdjuster every few seconds, and that
	// calls this. Rebuilding identical tiles emptied and refilled the bar each
	// time, which made every window button blink. Paint only when the list (its
	// order, names, icons or dialogs) really changed; the state pass below still
	// runs from jawnosTaskbarPinsRefresh on every call.
	if ($(destination).attr('data-taskbar-stamp') === stamp) {
		appointment_chron();
		return;
	}
	$(destination).attr('data-taskbar-stamp', stamp);
	$(destination).html(html);
	$(destination).find('.window_toggle_name').remove();
	$(destination).find('.window_toggle_icon').each(function(i,v) {
		var app = $(v).attr('app');
		var named = $(v).attr('formatted_name') || format_name(app);
		var terminal_id = $(v).attr('data-terminal-id') || '';
		var window_id = $(v).attr('data-window-id') || '';
		var dialog_id = $(v).attr('data-dialog-id') || '';
		var rand = Math.random().toString(36).substring(2);
		// The button answers for its window itself (see the .window_toggle click):
		// the name is a plain label, and the shorthand rides beside it for a bar
		// too narrow to spell the name out. The label used to carry its own
		// windowRestorer, so pressing the name restored the window and then fell
		// through to the button's own answer, which is what made a press behave
		// like something other than a window manager's.
		// The app, the names and the ids are attributes, and a window's name is
		// text: build the wrapper as DOM so a name with markup stays a label.
		var wrapper = $('<span class="hover window_toggle" style="text-align:center;"></span>')
			.attr('id', rand).attr('app', app).attr('formatted_name', named);
		if (terminal_id) { wrapper.attr('data-terminal-id', terminal_id); }
		if (window_id) { wrapper.attr('data-window-id', window_id); }
		if (dialog_id) { wrapper.attr('data-dialog-id', dialog_id); }
		$(v).wrap(wrapper);
		$('#' + rand).append(' ').append($('<span class="window_toggle_name_text"></span>').text(named));
		$('#' + rand).append(' ').append($('<span class="window_toggle_shorthand"></span>').text(shorthand_name(named, 5)));
	});


	appointment_chron();
}

function startMenuDisplayer(destination) {
	if (!destination) {
		// the open windows live in the taskbar now, and its own displayer is the
		// one that knows their look; a named destination (the app switcher) keeps
		// the table below
		return taskbarDisplayer();
	}
	$(destination).html('');
	var html = '';
	$('.wind').sort(function(a, b) {
    var valueA = numeral($(a).css('z-index')).value();
    var valueB = numeral($(b).css('z-index')).value();

    return valueA - valueB; }).each(function(i,v) {
		var icon = $(v).find('.window_icon');
		var formatted_name = $(v).find('.name_text').text();
		var new_icon = icon.clone();

		new_icon.attr('formatted_name', formatted_name);
		if (!new_icon.attr('src')) {
			new_icon.css({ 'font-size': '30px', 'height': '60px' });
		}
		new_icon.removeClass('window_icon');
		new_icon.addClass('window_toggle large_thumb');
		html += '<td class="app">' + new_icon.wrap('<span/>').parent().html(); + '</td>';

		new_icon.show();
	});
	$(destination).html('<table style="text-align:center;"><tbody><tr>' + html + '</tr></tbody></table>');
	$(destination).find('.window_toggle_name').remove();
	$('.window_toggle').each(function(i,v) {
		var app = $(v).attr('app');
		var label = $('<span class="hover window_toggle_name" style="vertical-align:top;text-align:center;"></span>')
			.attr('app', app)
			.append($('<b></b>').text($(v).attr('formatted_name') || ''))
			.append('<br>');
		$(v).before(label);
	});
	appointment_chron();
}


$(document).on('click', '.window_toggle', function() {
	// a tile that was just dragged into a new place must not also answer as a
	// press (raise or minimise the window it holds)
	if (typeof jawnosTaskbarWindowDragAt != 'undefined' && Date.now() - jawnosTaskbarWindowDragAt < 300) { return; }

	var timestamp = Date.now();
	var dialog_id = $(this).attr('data-dialog-id') || '';
	// a dialog's tile answers for the dialog, not an app window
	if (dialog_id) {
		if (typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse($(this)); }
		jawnosDialogToggle(dialog_id);
		return;
	}
	var app = $(this).attr('app');
	// the tile beats while the window it answers for comes up
	if (typeof jawnosLoadingPulse == 'function') { jawnosLoadingPulse($(this)); }
	var terminal_id = $(this).attr('data-terminal-id') || '';
	var window_id = $(this).attr('data-window-id') || '';
	if (terminal_id || window_id) {
		// Several Terminal windows share the app name, and so do several Folders
		// windows, so the tile answers for the one window wearing its own id
		// rather than every window of the app.
		var tw = terminal_id
			? $('.wind[data-terminal-id="' + terminal_id + '"]')
			: $('.wind[data-window-id="' + window_id + '"]');
		if (!tw.length) { return; }
		if (!tw.is(':visible')) {
			tw.show().attr('visible', 'yes');
			topLevelNow(tw);
			return;
		}
		var topmost = null, topz = -1;
		$('.wind:visible').each(function () {
			var z = parseInt($(this).css('z-index'), 10) || 0;
			if (z >= topz) { topz = z; topmost = this; }
		});
		if (topmost === tw.get(0)) {
			tw.hide().attr('view', 'minimized');
		}
		else {
			topLevelNow(tw);
		}
		return;
	}
	var win = $('.wind[app="' + app + '"]');
	// a button on the taskbar answers for its window: a minimized one comes
	// back, the top one steps down, and any other rises
	if (!win.is(':visible')) {
		windowRestorer(timestamp,app);
		return;
	}
	var topApp = topWindow();
	if (app == topApp) {
		windowMinimizer(timestamp,app);
	} else {
		topLevelNow(win);
	}

});

// A real tap/click/keypress marks intent. windowMaker brings an existing
// window to the top only when one happened a moment ago, so the background
// re-renders that refresh windows don't steal the top spot from what the
// person is actually looking at. Intentional opens (start menu, centre view,
// swipes) all come from a gesture, so they always qualify.
var lastUserGesture = 0;
$(document).on('mousedown touchstart keydown click', function () { lastUserGesture = Date.now(); });

// A rendered window is parsed once as inert DOM and read from there. jQuery
// used to re-parse the whole response for every attribute it read - ten parses
// of 40 KB on an ordinary app open. A template parse does not run the window's
// script; windowMaker still appends the response string, so the script runs
// exactly when it did before.
function windowResponseFragment(response) {
	var template = document.createElement('template');
	template.innerHTML = response;
	return template.content;
}

// $(response).filter('.wind') only ever matched a top-level element.
function windowResponseRoot(fragment) {
	var children = fragment.children;
	for (var i = 0; i < children.length; i++) {
		if (children[i].classList.contains('wind')) { return children[i]; }
	}
	return null;
}

function windowMaker(response, fragment) {
	if (response == '') { return; }
	fragment = fragment || windowResponseFragment(response);
	var first_element = fragment.firstElementChild;
	var root = windowResponseRoot(fragment);
	var window_id = root ? root.getAttribute('id') : undefined;
	var window_app = root ? root.getAttribute('app') : undefined;
	var window_terminal_id = (root && root.getAttribute('data-terminal-id')) || '';
	var window_instance_id = (root && root.getAttribute('data-window-id')) || '';
	var app = window_app;

	var timestamp = root ? root.getAttribute('timestamp') : undefined;
	// $(response).find('.window_contents').html(), read from the same parse
	var contents_element = fragment.querySelector('.window_contents');
	var contents_html = contents_element ? contents_element.innerHTML : '';
	var json_storage = storage || sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) ? JSON.parse(json_storage) : {};
	var matches = 0;
	var locked = 'no';
	var carry_on = 0;
	try {
		// One native pass over the windows instead of a jQuery wrap per node.
		var winds = document.querySelectorAll('.wind');
		for (var wi = 0; wi < winds.length; wi++) {
			var v = winds[wi];
			var app_attr = v.getAttribute('app');
			var app_timestamp = v.getAttribute('timestamp');
			var existing_terminal_id = v.getAttribute('data-terminal-id') || '';
			var existing_instance_id = v.getAttribute('data-window-id') || '';
			// Terminals are several windows of one app, and so are Folders windows.
			// Only the same session (or the same named window) may refresh a window;
			// a different one is a new window, not a redraw.
			if (app_attr == window_app && (!window_terminal_id || !existing_terminal_id || existing_terminal_id == window_terminal_id) && (!window_instance_id || !existing_instance_id || existing_instance_id == window_instance_id)) {
				var wind_el = $(v);
				var ow = wind_el.width();
				var oh = wind_el.height();
				var ol = wind_el.css('left');
				var ot = wind_el.css('top');
				matches = 1;
				var id = first_element ? first_element.getAttribute('id') : undefined;
				var response_timestamp = first_element ? first_element.getAttribute('timestamp') : undefined;
				if (response_timestamp >= (numeral(app_timestamp).value())) {
					var window_saver = sessionStorage.getItem('window_storage');


					var view = JSON.parse(window_saver) || {};
					wind_el.find('script').remove();
					var blci = wind_el.find('.budget_current_information');
					if (app_attr == 'video' || app_attr == 'screen' || app_attr == 'camera') {

					}
					else {
						wind_el.find('.window_contents').html(contents_html);
						$('#' + id).width(ow).height(oh);
						$('#' + id).css({ 'left': ol, 'top': ot });
					}

					locked = v.getAttribute('locked');
					var new_v = $('#' + id);
					if (new_v.attr('pre_dimensioned') != 1) {
					//	new_v.css({ 'top': view[window_app].top, 'left': (view[window_app].left), 'height': view[window_app].height, 'width': view[window_app].width});
					}
					if (view[window_app].wc == false) {
						$('#window_contents_' + timestamp).hide();
					}
					// Reopening the app brings it to the top; a background refresh
					// that merely re-renders it does not. This used to target the
					// timestamp of the *response*, which is not the window on the
					// page yet, so it raised nothing at all.
					if (Date.now() - lastUserGesture < 1500) {
						topLevelNow(wind_el);
					}
					var blci2 = $(new_v).attr('current_information');
					if (blci.attr('status') == 'open' || blci2) {
						var circumstance = blci2 || blci.attr('circumstance');
						if (typeof budgetLight === 'function') { budgetLight(app_attr,circumstance,'open'); }
					}
					carry_on = 1;
				}
				else { matches = 1; }
			}
		}
		
		if (matches == 0 && response != "null") {
			$('#browser').append('' + response + '');
			// A window that is new to this page never inherits a media unlock: the
			// token belongs to the window that asked for the print. A restored
			// window (or one opened beside another) draws its locked view.
			if (app == 'gallery' || app == 'music' || app == 'folders') {
				var media_root = $('#' + window_id).find('#' + app).first();
				if (media_root.length && media_root.attr('unlock')) {
					if (typeof jawnosMediaLockdown === 'function') { jawnosMediaLockdown(app, true); }
					else { media_root.attr('unlock', ''); }
					if (typeof jawnosMediaRefresh === 'function') {
						setTimeout(function () { jawnosMediaRefresh([app]); }, 0);
					}
				}
			}
			websocketStart(app);
			// a window closed with its budget light open comes back with the light
			// open: the server rendered the app's ci setting onto the panel
			if (typeof budgetLightRestore === 'function') { budgetLightRestore(app); }
			carry_on = 1;
			// a pinned window keeps the place it was saved at, rescaled onto this
			// screen; an unpinned one cascades in with the others
			if (typeof windowPlaceRestore === 'function') { windowPlaceRestore($('#' + window_id)); }
			if ($('#' + window_id).attr('pre_dimensioned') != 1) {
				windowReorganizer(window_id);
			}
			else {
				topLevelNow($('#' + window_id));
			}
		}
		jws = undefined;
		if (carry_on == 1) {
			// A Weather window re-rendered by a background refresh lost its
			// reading with the old markup; ask for it again. Its own opener does
			// the same on a restore, and weatherLoad drops the duplicate.
			if (app == 'weather' && matches == 1 && typeof weatherLoad === 'function') {
				weatherBind();
				weatherLoad();
			}
			if (!windowPhoneChecker() && !$('#window_id').hasClass('ui-draggable')) {

			}
			else if (windowPhoneChecker() && matches == 0) {
				$('#' + window_id).css( {'width':'100%','height':'71.28%'});
			}
			windowFit($('#' + window_id));
			$('#' + window_id).find('.unlock').droppable({
				drop: function(event, ui) {
					var app = $(this).attr('app');
					qrcode_generator(app);
				}
			});
			win = $('#' + window_id);
			windowDraggable(win);
			// The details form is fetched on demand. Asking for it once the window
			// is drawn keeps the first press of the details control instant without
			// putting the form back on the page: the fetch lands hidden, and the
			// press just shows it. Idle time is used when the browser offers it, so
			// the open itself is never delayed by it.
			if (typeof appSectionGrabber === 'function') {
				var details_here = win.find('.app_section_placeholder[section="details"]');
				if (details_here.length) {
					var prefetch = function() { appSectionGrabber(app, 'details', win); };
					if (window.requestIdleCallback) { requestIdleCallback(prefetch, { timeout: 2500 }); }
					else { setTimeout(prefetch, 600); }
				}
			}
			if (isJson(jopen)) {
				var v = {};
				v.jopen = JSON.parse(jopen);
				jopen = undefined;
				v.scrollTop = win.attr('scrollTop');
				windowjOpener(win,v);

			}

			if (us['in'][app]) {
				us['out'][app] = document.getElementById(app + '_scr');
				us['out'][app].srcObject = us['in'][app].stream;
			}
			if (me['in'][app]) {
				me['out'][app] = document.getElementById(app + '_vid');
				me['out'][app].srcObject = me['in'][app].stream;
			}
			var appointments = win.find('.appointment');
			$.each(appointments, function(n,val) {
				var notes = jawnosAppFieldGet(app, 'notes');
				var ago = jawnosAppFieldGet(app, 'ago');
				var duration = jawnosAppFieldGet(app, 'duration');
				$(val).find('.notes').val(notes);
				$(val).find('.ago').val(ago);
				$(val).find('.duration').val(duration);
			});
			transactionStorageRetriever(app);
			if (typeof jawnosTimePreviewPaintApp === 'function') { jawnosTimePreviewPaintApp(app); }
			// A terminal rendered or re-rendered by the window manager gets its
			// engine bound here; its own opener has already done this on a fresh open.
			if (typeof terminalInit === 'function' && win.find('.terminal_app').length) { terminalInit(); }
			windowSaver();
			openAttributeReopener(app);
			appointment_chron();
			// the bottom line comes back on the reading the person last chose,
			// not on the evaluation a fresh render starts with
			if (typeof appointmentStatsRestore === 'function') { appointmentStatsRestore(win); }
			textareaUpgrader();
			if (!appDetailsScroll[app]) { appDetailsScroll[app] = { reload: 0, position: 1 }; }

			if (win.width() >= numeral($(window).width() * .98).value() ) {
				if (windowPhoneChecker()) {
					if (win.height() >= numeral($(window).height() * .89).value() ) {
						win.find('.restore_button').show();
						win.find('.maximize_button').hide();
					}
				}
				else {
					win.find('.restore_button').show();
					win.find('.maximize_button').hide();
					win.width($(window).width());
				}
			}
			if (numeral(win.css('left')).value() >= numeral($(window).width() - 40 ).value() ) {
				win.css({'left':'0px'});
			}
			if (numeral(win.css('top')).value() <= 40 ) {
				win.css({'top':'40px'});
			}
			if (numeral(win.css('top')).value() >= numeral($(window).height() - 40).value() ) {
				win.css({'top':'40px'});
			}
			if (numeral(win.css('right')).value() > numeral($(window).width() + 80).value()) {
				win.css({'left': '0px' });
			}
		}
	} catch (err) { console.log('no win: ', err); }
	// a press that answered with a window already on the desk has no new slot:
	// give the reserved one back
	windowTiledRelease(timestamp);
	windowDimensionSetter($('#' + window_id));
	return window_id;
}

// Where a window's top may sit: under the reserved line, and under the
// clothesline too when the desk wears one - on every device, not only phones.
function windowTopLimit() {
	var limit = reservedSpots['header'] || 0;
	if (clothesLinePos['exists'] == 1) {
		limit = limit + clothesLineHeight + clothesLinePos['bordersize'];
	}
	return limit;
}

// The same ceiling for the panels that float over the desk instead of riding in
// a window - a keyboard, the Guide's associate, a Coding agent - so a drag above
// the clothesline lands them just under it, as a window would.
function panelTopLimit() {
	return (typeof windowTopLimit == 'function') ? Math.max(0, windowTopLimit()) : 0;
}

// The foot of the screen a window in a half or maximized state leaves free: a
// bottom taskbar first, then the strip a bottom dock keeps on screen while it is
// tucked (its search, or the sliver the pointer rests on to call it back).
function windowBottomClearance() {
	var bar = (typeof jawnosTaskbarEdge == 'function') ? jawnosTaskbarEdge('bottom') : 0;
	if (typeof jawnosDockWindowReserve == 'function') { bar += jawnosDockWindowReserve(); }
	return bar;
}

// The tile is one or more ordered stacks. A stack is a cascade of windows that
// share a `stack` id and stand on an anchor: the default stack keeps the desk's
// top-left corner, and a stack made by dropping a window on another stands where
// that window stood, so a desk can hold several piles. Each window in a pile
// wears its slot as `tile`, its pile as `stack`, and the pile's anchor as
// `stack_at` ("left,top"), so a reload rebuilds every pile where it stood. The
// slot, not the order the windows sit on the page, is what the tile acts on: a
// reload restores the windows in whatever order their responses arrive, so the
// page order no longer matches the stack, but the slot travels with the window.
// A pinned window and one dragged out of the stack (a free window) carry no
// slot: they keep their own place and do not step.
var windowTiledDefaultStack = '0';
// the pile each stack was last touched in, so the pile worked in most recently
// is the front one; a pile not touched since a reload starts from its saved z
var windowTiledStackTouch = {};
var windowTiledStackSeq = 0;

function windowTiledSlot(win) {
	var slot = parseInt($(win).attr('tile'), 10);
	return isNaN(slot) ? -1 : slot;
}

function windowTiledStackId(win) {
	var stack = $(win).attr('stack');
	return (stack === undefined || stack === null || stack === '') ? windowTiledDefaultStack : String(stack);
}

// Every pile on the desk, in no particular order: the id is read from the
// windows that hold a slot, so a free or pinned window does not name one.
function windowTiledStackIds() {
	var ids = [];
	$('.wind').each(function() {
		if (windowTiledSlot(this) < 0) { return; }
		var id = windowTiledStackId(this);
		if (ids.indexOf(id) < 0) { ids.push(id); }
	});
	return ids;
}

// The anchor a pile stands on: where its head (slot 0) sits. The default pile
// rides the desk's top-left corner, under the reserved line, so its anchor
// follows the clothesline and the top bar; any other pile remembers the place
// its head was at.
function windowTiledAnchor(stack) {
	if (stack === undefined || stack === windowTiledDefaultStack) {
		return { left: 0, top: windowTopLimit() };
	}
	var at = null;
	$('.wind').each(function() {
		if (windowTiledStackId(this) !== stack) { return; }
		var saved = $(this).attr('stack_at');
		if (!saved) { return; }
		var parts = String(saved).split(',');
		var left = parseFloat(parts[0]);
		var top = parseFloat(parts[1]);
		if (!isNaN(left) && !isNaN(top)) { at = { left: left, top: top }; }
	});
	return at || { left: 0, top: windowTopLimit() };
}

// A pile of its own: an id no window on the page wears. The timestamp keeps ids
// apart across a reload; the counter separates two piles made in one tick.
function windowTiledNewStack() {
	var id;
	do {
		windowTiledStackSeq++;
		id = 's' + Date.now() + '_' + windowTiledStackSeq;
	} while (windowTiledStackIds().indexOf(id) >= 0);
	return id;
}

// The front of a pile's own layer, so the pile under the pointer can be told
// from the ones behind it.
function windowTiledStackTopZ(stack) {
	var z = -Infinity;
	$('.wind').each(function() {
		if (windowTiledSlot(this) < 0 || windowTiledStackId(this) !== stack) { return; }
		var zz = parseInt($(this).css('z-index'), 10);
		if (!isNaN(zz) && zz > z) { z = zz; }
	});
	return z;
}

// Work in a pile brings that pile to the front. Laying a pile out (a restore, a
// close) does not: a reload must not reorder the piles by whichever response
// happened to arrive last.
function windowTiledStackRaise(stack) {
	windowTiledStackTouch[stack] = Date.now();
	windowTiledFront();
}

// A window's own identity, so a reload can find it again after the server has
// minted a new timestamp: one window per app, but Terminal sessions and Folders
// windows are several of one app and are told apart by their instance id.
function windowTiledIdentity(el) {
	var app = $(el).attr('app') || '';
	var instance = $(el).attr('data-terminal-id') || $(el).attr('data-window-id') || '';
	return app + '|' + instance;
}

// A window that joins a pile takes the size a fresh window opens at. The two
// numbers are Part22.pm's $default_width/$default_height; t/74 keeps them in
// step. A window the person sized for themselves shrinks back to the standard
// when it joins, so a pile reads as one stack instead of a row of odd shapes.
var windowTileDefaultWidth = 480;
var windowTileDefaultHeight = 640;

function windowTiledSizeReset(win) {
	win = $(win);
	win.css({ 'width': windowTileDefaultWidth + 'px', 'height': windowTileDefaultHeight + 'px' });
	win.removeAttr('free_dimensions').removeAttr('fit_height').removeAttr('fit_shrunk');
	win.attr('view', '');
	win.find('.maximize_button').show();
	win.find('.restore_button').hide();
}

// The next free slot at the end of one pile: the tiled windows already in it and
// the presses still waiting for their windows (a press always opens into the
// default pile, so only that one counts reservations). A pinned or free window
// has no slot and so does not push it along; a reservation nobody ever answers
// gives its slot back after a while.
function windowNextTileSlot(stack) {
	stack = (stack === undefined) ? windowTiledDefaultStack : stack;
	var next = 0;
	$('.wind').each(function() {
		if (windowTiledStackId(this) !== stack) { return; }
		var slot = windowTiledSlot(this);
		if (slot >= next) { next = slot + 1; }
	});
	if (stack !== windowTiledDefaultStack) { return next; }
	var now = Date.now();
	var pruned = false;
	for (var stamp in windowTiledPending) {
		var p = windowTiledPending[stamp];
		if (!p) { continue; }
		if (now - p.at > 20000) {
			delete windowTiledPending[stamp];
			if (p.app && windowTiledPendingApp[p.app] === stamp) { delete windowTiledPendingApp[p.app]; }
			pruned = true;
			continue;
		}
		if (p.slot >= next) { next = p.slot + 1; }
	}
	// an open that never made a window leaves a hole where it had reserved; tidy
	// the stack once the other opens have landed
	if (pruned && typeof windowTiledSettleSoon === 'function') { windowTiledSettleSoon(); }
	return next;
}

// Hold the next slot for a press before its window exists. A window already on
// the desk answers a press by refreshing, so it takes no new slot - but the
// press is still a press on that window, and on the tile that means walking to
// the foot. The walk happens now, at the press, so it stays in press order even
// while another press's window is still on its way.
function windowTiledReserve(timestamp, app) {
	if (!timestamp || !app || windowTiledPending[timestamp]) { return; }
	var open = null;
	$('.wind').each(function() {
		var el = $(this);
		// a window that is one of several of its app (a terminal session, a second
		// folders window) does not answer the press: a new window is made, so the
		// press reserves a slot instead of walking the one already there
		if (el.attr('app') === app && !el.attr('data-terminal-id') && !el.attr('data-window-id')) {
			open = this;
			return false;
		}
	});
	if (open) {
		if (typeof windowTiledPress === 'function') { windowTiledPress(open); }
		return;
	}
	windowTiledPending[timestamp] = { slot: windowNextTileSlot(windowTiledDefaultStack), at: Date.now(), app: app };
	windowTiledPendingApp[app] = String(timestamp);
}

function windowTiledRelease(timestamp) {
	if (!timestamp) { return; }
	var pending = windowTiledPending[timestamp];
	delete windowTiledPending[timestamp];
	if (pending && pending.app && windowTiledPendingApp[pending.app] === String(timestamp)) {
		delete windowTiledPendingApp[pending.app];
	}
}

// The step a tiled window takes across, per slot. The same 50 windowReorganizer
// cascades with, kept in one place so closing a gap steps back by the step the
// window was placed with.
var windowTileAcrossStep = 50;

// A window being restored after a reload carries the tile slot (or the fact that
// it had been dragged out of the tile) it held in the last session.
// appWindowOpenerNow hands it over just before the window is rendered, and
// windowReorganizer consumes it.
var windowTiledRestore = {};
// A slot held for an app the person has pressed but whose window has not
// rendered yet, keyed by the timestamp the server will use for its id. A later
// press's window can arrive first, so the earlier press's place has to be kept
// for it; windowReorganizer claims the reservation when the window lands.
var windowTiledPending = {};
// the latest press for each app, so a bespoke opener that changes its timestamp
// claims the press it is answering and never an older reservation for the app
var windowTiledPendingApp = {};
var windowTiledDragging = false;
var windowTiledSettleTimer = null;
// a saved pile map waiting to be replayed, once the restore burst has settled
var windowTiledStacksPending = false;
var windowTiledStacksTries = 0;

// Close the slot a window leaves: every tiled window below it in this pile (a
// higher slot) steps up by one bar and one across-step, and its own slot number
// comes down with it. Slots are what the stack acts on, so this lands on the
// right windows even when the page order was scrambled by a reload, and the
// pile's own anchor keeps its other piles where they are.
function windowTiledStepUp(slot, stack) {
	stack = (stack === undefined) ? windowTiledDefaultStack : stack;
	$('.wind').each(function() {
		if (windowTiledStackId(this) !== stack) { return; }
		var s = windowTiledSlot(this);
		if (s <= slot) { return; }
		var bar = $(this).find('.top_navbar');
		var vAdvance = (bar.outerHeight() || 40) - (parseFloat(bar.css('border-top-width')) || 0);
		$(this).css({
			// a window dragged toward an edge steps back only as far as the desk
			'left': Math.max(0, (parseFloat($(this).css('left')) || 0) - windowTileAcrossStep),
			'top': Math.max(windowTopLimit(), (parseFloat($(this).css('top')) || 0) - vAdvance)
		});
		$(this).attr('tile', String(s - 1));
	});
	windowTiledFront();
}

// Closing a tiled window closes the slot it held in its own pile. A pinned or
// free window has no slot, so closing it leaves the pile alone; a phone re-parks
// its whole pile in windowStacker and takes none of this.
function windowTiledGapClose(win) {
	if (windowPhoneChecker()) { return; }
	var slot = windowTiledSlot(win);
	if (slot < 0) { return; }
	windowTiledStepUp(slot, windowTiledStackId(win));
}

// A window dragged out of a stack leaves the tile: it floats where it was put,
// and the windows below it close the slot it held. `float` marks it free (a drag
// does; pinning takes it out of the tile without making it free), so a reload
// knows to leave it where it is instead of stepping it back into line. The pile
// it leaves is named before the attributes go, so the right pile is closed up.
function windowTiledLeave(win, float) {
	if (windowPhoneChecker()) { return; }
	win = $(win);
	var slot = windowTiledSlot(win);
	if (slot < 0) { return; }
	var stack = windowTiledStackId(win);
	win.removeAttr('tile').removeAttr('stack').removeAttr('stack_at');
	if (float) { win.attr('free', '1'); }
	else { win.removeAttr('free'); }
	windowTiledStepUp(slot, stack);
	if (typeof windowSaver === 'function') { windowSaver(); }
}

// A window's box as its own style has it, so the ground the stack covers can be
// measured without laying anything out.
function windowTiledRect(win) {
	var left = parseFloat($(win).css('left')) || 0;
	var top = parseFloat($(win).css('top')) || 0;
	return {
		left: left,
		top: top,
		right: left + (parseFloat($(win).css('width')) || 0),
		bottom: top + (parseFloat($(win).css('height')) || 0)
	};
}

// A block member's box where the drag picked it up: its start left/top with the
// size it has (a drag moves a window, it does not resize one). A group recorded
// without a start box (a caller that never moved it) is measured where it sits.
function windowTiledHomeRect(g) {
	var el = (g && g.el) ? g.el : g;
	if (!g || g.left === undefined) { return windowTiledRect(el); }
	return windowTiledBox(g);
}

// A box with its far edges filled in, whichever pair a caller gave: the drag
// records left/top/width/height, and the stack tests compare right/bottom.
function windowTiledBox(r) {
	if (!r) { return null; }
	return {
		left: r.left,
		top: r.top,
		right: (r.right !== undefined) ? r.right : r.left + (r.width || 0),
		bottom: (r.bottom !== undefined) ? r.bottom : r.top + (r.height || 0)
	};
}

// Is the pointer right over one of this pile's windows? Each window's own box,
// not the pile's bounding box: the empty corner a stagger leaves is the desk, and
// a drop there is not a drop on the stack. A window the drag carries stands on the
// box it was picked up from (home), so carrying a block away leaves its pile
// behind while a drag back over its old place finds it.
function windowTiledOverArea(homeEl, homeRect, stack, group, at) {
	if (!at) { return false; }
	var homes = [];
	if (homeEl) { homes.push({ el: $(homeEl)[0], rect: windowTiledBox(homeRect) }); }
	$.each(group || [], function(i, g) {
		homes.push({ el: (g && g.el) ? g.el : g, rect: windowTiledHomeRect(g) });
	});
	var over = false;
	$('.wind').each(function() {
		if (stack !== undefined && windowTiledStackId(this) !== stack) { return; }
		var home = null;
		for (var h = 0; h < homes.length; h++) {
			if (homes[h].el === this) { home = homes[h].rect; break; }
		}
		var r;
		if (home !== null) {
			if (!home) { return; }
			r = home;
		}
		else if (windowTiledSlot(this) >= 0) {
			r = windowTiledRect(this);
		}
		else { return; }
		if (at.x >= r.left && at.x <= r.right && at.y >= r.top && at.y <= r.bottom) { over = true; }
	});
	return over;
}

function windowTiledBarMiddle(win) {
	var bar = $(win).find('.top_navbar');
	return (parseFloat($(win).css('top')) || 0) + ((bar.outerHeight() || 40) / 2);
}

// Where the dragged title bar sits among this pile's bars: the number of its
// tiled bars whose middle is above it, counting the pile as if the gap the
// window leaves were already closed. That is the slot it takes; the bar's own
// place, not the finger on it, is what decides, so grabbing high or low on the
// bar does not move the drop a place. A window dragged out of another pile is
// not part of this one, so its old slot is not counted here.
function windowTiledInsertSlot(at, skip, stack) {
	stack = (stack === undefined) ? windowTiledDefaultStack : stack;
	var anchor = windowTiledAnchor(stack);
	var dragged = skip ? $(skip) : null;
	var want = (dragged && dragged.length) ? windowTiledBarMiddle(dragged[0]) : ((at && at.y) || 0);
	var skipSlot = dragged ? windowTiledSlot(dragged) : -1;
	if (skipSlot >= 0 && dragged && windowTiledStackId(dragged[0]) !== stack) { skipSlot = -1; }
	var slot = 0;
	$('.wind').each(function() {
		if (dragged && this === dragged[0]) { return; }
		if (windowTiledStackId(this) !== stack) { return; }
		var s = windowTiledSlot(this);
		if (s < 0) { return; }
		if (skipSlot >= 0 && s > skipSlot) { s = s - 1; }
		var bar = $(this).find('.top_navbar');
		var step = (bar.outerHeight() || 40) - (parseFloat(bar.css('border-top-width')) || 0);
		var middle = anchor.top + s * step + ((bar.outerHeight() || 40) / 2);
		if (middle < want) { slot++; }
	});
	return slot;
}

// Put a tiled window in the step of its pile's cascade that its slot names,
// measured from the pile's own anchor rather than the desk's corner.
function windowTiledPlace(win, slot, stack) {
	var anchor = windowTiledAnchor(stack);
	var bar = $(win).find('.top_navbar');
	var vAdvance = (bar.outerHeight() || 40) - (parseFloat(bar.css('border-top-width')) || 0);
	$(win).css({
		'left': anchor.left + slot * windowTileAcrossStep,
		'top': anchor.top + slot * vAdvance
	});
}

function windowTiledRelayout(stack) {
	$('.wind').each(function() {
		var slot = windowTiledSlot(this);
		if (slot < 0) { return; }
		if (stack !== undefined && windowTiledStackId(this) !== stack) { return; }
		windowTiledPlace(this, slot, windowTiledStackId(this));
	});
	windowTiledFront();
}

// Each pile is a layer of its own: the pile worked in most recently is the front
// one, and inside it the window at the foot is the front window. Its depth is
// the slot order, so the bottom step wears the highest z, and a window dragged
// or pressed into the middle is behind the ones below it. A restore leaves the
// order alone; windowTiledStackRaise is the one that names the pile worked in.
function windowTiledFront() {
	if (windowPhoneChecker()) { return; }
	var stacks = {};
	var any = false;
	$('.wind').each(function() {
		var slot = windowTiledSlot(this);
		if (slot < 0) { return; }
		var id = windowTiledStackId(this);
		if (!stacks[id]) { stacks[id] = []; }
		stacks[id].push({ el: this, slot: slot, z: parseInt($(this).css('z-index'), 10) || 0 });
		any = true;
	});
	if (!any) { return; }
	var ids = Object.keys(stacks);
	$.each(ids, function(i, id) {
		if (windowTiledStackTouch[id] === undefined) {
			// a pile not touched since the reload starts from its saved z, so the
			// desk comes back with the front pile still in front
			var top = -Infinity;
			$.each(stacks[id], function(k, w) { if (w.z > top) { top = w.z; } });
			windowTiledStackTouch[id] = top;
		}
	});
	ids.sort(function(a, b) {
		var ta = windowTiledStackTouch[a], tb = windowTiledStackTouch[b];
		if (ta !== tb) { return ta - tb; }
		return (a < b) ? -1 : ((a > b) ? 1 : 0);
	});
	var base = Number(top_level_now) || 100;
	$('.wind').each(function() {
		var z = parseInt($(this).css('z-index'), 10);
		if (!isNaN(z) && z > base) { base = z; }
	});
	var z = base;
	$.each(ids, function(i, id) {
		stacks[id].sort(function(a, b) { return a.slot - b.slot; });
		$.each(stacks[id], function(k, w) {
			z++;
			var win = $(w.el);
			win.css({ 'z-index': z, '--frame_z': Math.max(2147483000, z + 3) });
			win.find('.window_contents').css({ 'z-index': z });
			win.find('.top_navbar').css({ 'z-index': z + 1 });
			win.attr('last_top', Date.now());
		});
	});
	top_level_now = z;
	if (typeof jawnosTaskbarPinsRefresh === 'function') { jawnosTaskbarPinsRefresh(); }
	// the front window wears the full-strength title bar, so that cue has to
	// follow the pile as well as the taskbar
	if (typeof jawnosWindowFocusApply === 'function') { jawnosWindowFocusApply(); }
}

// A press on a tiled window's title bar walks it to the foot of its own pile -
// it leaves its slot, the pile closes up, and it joins at the end - so it becomes
// the front. Returns false for a free or pinned window, which keeps its place
// and just rises.
function windowTiledBump(win) {
	if (windowPhoneChecker()) { return false; }
	win = $(win);
	if (win.attr('pre_dimensioned') == 1) { return false; }
	var slot = windowTiledSlot(win);
	if (slot < 0) { return false; }
	var stack = windowTiledStackId(win);
	var last = true;
	$('.wind').each(function() {
		if (this === win[0]) { return; }
		if (windowTiledStackId(this) !== stack) { return; }
		if (windowTiledSlot(this) > slot) { last = false; return false; }
	});
	if (last) { windowTiledStackRaise(stack); return true; }
	win.removeAttr('tile');
	windowTiledStepUp(slot, stack);
	windowTiledInsertAt(win, windowNextTileSlot(stack), stack);
	windowTiledStackRaise(stack);
	if (typeof windowDimensionSetter === 'function') { windowDimensionSetter(win); }
	if (typeof windowSaver === 'function') { windowSaver(); }
	return true;
}

function windowTiledPress(win) {
	if (typeof windowTiledBump === 'function' && windowTiledBump(win)) { return; }
	topLevelNow($(win));
}

// A restore inserts windows at the slots they saved, which can leave gaps while
// slower responses are still coming in. Once they have settled, number each pile
// straight again: the order is already right, only the numbers have holes.
function windowTiledSettle() {
	if (windowTiledDragging && $('.wind.ui-draggable-dragging').length) { windowTiledSettleSoon(); return; }
	windowTiledDragging = false;
	if (windowTiledStacksPending) { windowTiledStacksPending = false; windowStacksApply(); }
	var now = Date.now();
	for (var stamp in windowTiledPending) {
		var p = windowTiledPending[stamp];
		if (!p || now - p.at > 20000) {
			if (p && p.app && windowTiledPendingApp[p.app] === stamp) { delete windowTiledPendingApp[p.app]; }
			delete windowTiledPending[stamp];
		}
	}
	var ids = windowTiledStackIds();
	$.each(ids, function(k, id) {
		var order = [];
		$('.wind').each(function() {
			if (windowTiledStackId(this) !== id) { return; }
			var slot = windowTiledSlot(this);
			if (slot >= 0) { order.push({ el: this, slot: slot }); }
		});
		order.sort(function(a, b) { return a.slot - b.slot; });
		for (var i = 0; i < order.length; i++) { $(order[i].el).attr('tile', String(i)); }
	});
	windowTiledRelayout();
}

function windowTiledSettleSoon() {
	clearTimeout(windowTiledSettleTimer);
	windowTiledSettleTimer = setTimeout(windowTiledSettle, 1200);
}

// The window wearing this identity: one window per app, or the session or
// instance that tells two windows of one app apart.
function windowTiledByKey(key) {
	var found = null;
	$('.wind').each(function() {
		if (found) { return; }
		if (windowTiledIdentity(this) === key) { found = this; }
	});
	return found ? $(found) : $();
}

// windowSaver wrote the piles down in depth order, each pile's members in slot
// order. Replaying that map after the open burst puts every window back in its
// own pile at its own slot - even a window whose own restore record was missed -
// and restores the depth order of the piles, which the arrival order alone would
// shuffle. It keeps asking while a member is still on its way, and then leaves
// the desk to the person.
function windowStacksApply() {
	var json_storage = sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) || {};
	var map = storage['window_stacks'];
	if (!map || !map.piles) { return; }
	var raised = 0;
	var missing = 0;
	$.each(map.piles, function(i, pile) {
		var stack = String(pile.id || windowTiledDefaultStack);
		var found = 0;
		$.each(pile.members || [], function(slot, key) {
			var win = windowTiledByKey(key);
			if (!win.length) { missing++; return; }
			win.attr('tile', String(slot));
			if (stack === windowTiledDefaultStack) { win.removeAttr('stack').removeAttr('stack_at'); }
			else { win.attr('stack', stack).attr('stack_at', pile.at || ''); }
			found++;
		});
		if (!found) { return; }
		// the map runs back to front, so a later pile is the front one
		raised++;
		windowTiledStackTouch[stack] = raised;
	});
	// a slow opener (or a window that was closed after the save) can leave a
	// member out; try again a few times, then let the desk stand
	if (missing && windowTiledStacksTries < 6) {
		windowTiledStacksTries++;
		windowTiledStacksPending = true;
		setTimeout(windowTiledSettle, 800);
	}
}

// Ask for the map once the restore burst is in; windowTiledSettle applies it.
function windowStacksRestoreSoon() {
	windowTiledStacksPending = true;
	windowTiledStacksTries = 0;
	setTimeout(windowTiledSettle, 1500);
}

// A restored window takes the slot it held before the reload, and a window
// already in that slot steps down to make room. That keeps the saved order when
// the responses arrive in another order, and keeps two windows out of one slot
// when a fresh one opened while the restore was still coming in. A slot still
// empty is its own place: filling it moves nobody.
function windowTiledInsertAt(win, to, stack) {
	win = $(win);
	stack = (stack === undefined) ? windowTiledStackId(win) : stack;
	var taken = false;
	$('.wind').each(function() {
		if (this === win[0]) { return; }
		if (windowTiledStackId(this) !== stack) { return; }
		if (windowTiledSlot(this) === to) { taken = true; }
	});
	if (taken) {
		$('.wind').each(function() {
			if (this === win[0]) { return; }
			if (windowTiledStackId(this) !== stack) { return; }
			var s = windowTiledSlot(this);
			if (s >= to) { $(this).attr('tile', String(s + 1)); }
		});
	}
	win.attr('tile', String(to));
	if (stack !== windowTiledDefaultStack) { win.attr('stack', stack); }
	windowTiledRelayout(stack);
}

// The window under the pointer that is not in a pile - an anchored or a free
// one. A half or maximized window owns its own place and does not become a pile
// head, and a hidden window is not under the pointer at all. The windows the drag
// carries are skipped: they sit under the pointer too, and one of them must never
// be mistaken for the window the pile would start on.
function windowTiledWindowAt(at, skip, group) {
	if (!at) { return null; }
	var skipEl = skip ? $(skip)[0] : null;
	var carried = [];
	$.each(group || [], function(i, g) { carried.push((g && g.el) ? g.el : g); });
	var found = null;
	var found_z = -Infinity;
	$('.wind').each(function() {
		if (skipEl && this === skipEl) { return; }
		if (carried.indexOf(this) >= 0) { return; }
		if (windowTiledSlot(this) >= 0) { return; }
		if ($(this).css('display') == 'none') { return; }
		var view = $(this).attr('view');
		if (view == 'max' || view == 'left' || view == 'right') { return; }
		var r = windowTiledRect(this);
		if (at.x < r.left || at.x > r.right || at.y < r.top || at.y > r.bottom) { return; }
		var z = parseInt($(this).css('z-index'), 10);
		if (isNaN(z)) { z = 0; }
		if (z >= found_z) { found_z = z; found = this; }
	});
	return found;
}

// What a drop over `at` would do: join the pile whose ground is under the
// pointer (the front one when two overlap), start a new pile on a window that is
// not in one, or nothing at all. `from` names the pile the window was picked up
// from, whose ground uses `home` - the box it left - so a drag back over its own
// place still finds the pile after the others have stepped up. `group` is carried
// with the held window, so its ground is measured where the block was picked up.
function windowTiledDropTarget(at, skip, home, from, group) {
	if (!at) { return null; }
	var skipEl = skip ? $(skip)[0] : null;
	var best = null;
	var best_z = -Infinity;
	var ids = windowTiledStackIds();
	$.each(ids, function(i, id) {
		// the carried block is measured where it was picked up, and only against the
		// pile it came from: its home boxes belong to no other pile, and lending
		// them to one would make a pile reach across the desk to catch the drag
		var over = (id === from)
			? windowTiledOverArea(skipEl, home, id, group, at)
			: windowTiledOverArea(null, null, id, null, at);
		if (!over) { return; }
		var z = windowTiledStackTopZ(id);
		if (z >= best_z) { best_z = z; best = { stack: id }; }
	});
	if (best) { return best; }
	var under = windowTiledWindowAt(at, skip, group);
	return under ? { window: under } : null;
}

// The block a drag carries: the held window and every window below it in its
// pile (a higher slot). They move together and leave together, so the pile never
// ends up with its tail stranded where the head was.
function windowTiledBlockEls(win, group) {
	var els = [];
	var lead = $(win)[0];
	if (lead) { els.push(lead); }
	$.each(group || [], function(i, g) {
		var el = (g && g.el) ? g.el : g;
		if (el && el !== lead) { els.push(el); }
	});
	return els;
}

// Take the whole block out of the tile: each floats free where the drag has it.
// The windows below the held one that the block does not carry step up into its
// place, so a pile is never left with a hole (a block normally carries them all).
function windowTiledBlockLeave(win, group) {
	var winEl = $(win);
	var slot = windowTiledSlot(winEl);
	var stack = slot >= 0 ? windowTiledStackId(winEl) : null;
	var left = false;
	$.each(windowTiledBlockEls(win, group), function(i, el) {
		var w = $(el);
		if (windowTiledSlot(w) < 0) { return; }
		w.removeAttr('tile').removeAttr('stack').removeAttr('stack_at').attr('free', '1');
		left = true;
	});
	if (!left) { return; }
	if (slot >= 0) { windowTiledStepUp(slot, stack); }
	else { windowTiledFront(); }
	if (typeof windowSaver === 'function') { windowSaver(); }
}

// Carrying a window off its pile is what takes it out, not letting go: the pile
// closes the gap the moment the pointer leaves its ground, and a drag carried
// back over any pile joins it again when the window is dropped. The windows
// below the held one come with it, so the pile is never split.
function windowTiledDragLeave(win, at, home, from, group) {
	win = $(win);
	if (from === undefined) { from = (windowTiledSlot(win) >= 0) ? windowTiledStackId(win) : null; }
	if (!at || windowTiledSlot(win) < 0) { return; }
	if (windowTiledOverArea(win, home, from, group, at)) { return; }
	windowTiledBlockLeave(win, group);
}

// Put a block into a pile at the slot its held title bar is over: the block
// takes that slot and the windows from there down step the block's length, then
// the pile is laid out again. An anchored window that joins is anchored no
// longer - the pile has its place now - and every window that joins takes the
// standard window size, so a pile reads as one stack rather than a row of odd
// shapes.
function windowTiledStackJoin(win, stack, at, group) {
	win = $(win);
	var els = windowTiledBlockEls(win, group);
	var slot = windowTiledSlot(win);
	var from = slot >= 0 ? windowTiledStackId(win) : null;
	var anchor = windowTiledAnchor(stack);
	// a window already in this pile is reordering, not joining: it keeps the size
	// the person gave it, and only the windows arriving from outside are resized
	var joining = [];
	$.each(els, function(i, el) {
		var w = $(el);
		joining.push(!(windowTiledSlot(w) >= 0 && windowTiledStackId(w) === stack));
	});
	// the block leaves the pile it is still in before the slot is read, so the
	// insertion point is measured with its place in the old pile already closed
	$.each(els, function(i, el) { $(el).removeAttr('tile').removeAttr('stack').removeAttr('stack_at'); });
	if (slot >= 0) { windowTiledStepUp(slot, from); }
	var to = windowTiledInsertSlot(at, win, stack);
	$('.wind').each(function() {
		if (windowTiledStackId(this) !== stack) { return; }
		var s = windowTiledSlot(this);
		if (s >= to) { $(this).attr('tile', String(s + els.length)); }
	});
	$.each(els, function(i, el) {
		var w = $(el);
		w.removeAttr('free').attr('tile', String(to + i));
		if (stack === windowTiledDefaultStack) { w.removeAttr('stack').removeAttr('stack_at'); }
		else { w.attr('stack', stack).attr('stack_at', anchor.left + ',' + anchor.top); }
		if (typeof windowAnchorRelease === 'function') { windowAnchorRelease(w); }
		if (joining[i]) { windowTiledSizeReset(w); }
	});
	windowTiledRelayout(stack);
	windowTiledStackRaise(stack);
	if (typeof windowDimensionSetter === 'function') { $.each(els, function(i, el) { windowDimensionSetter($(el)); }); }
	if (typeof windowSaver === 'function') { windowSaver(); }
}

// Dropping a window over one that is not in a pile starts a pile there: the
// window under stays its head, where it already stood, and the dropped window
// (and the windows below it that came with it) join at its foot. An anchored
// window under the drop is anchored no longer.
function windowTiledStackStart(win, head, group) {
	win = $(win);
	head = $(head);
	if (!head.length || head[0] === win[0]) { return; }
	var els = windowTiledBlockEls(win, group);
	// the head must be a window of its own: if the pointer is over one of the
	// carried windows, there is no pile to start on, only the block itself
	if (els.indexOf(head[0]) >= 0) { return; }
	var stack = windowTiledNewStack();
	var at = windowTiledRect(head);
	var anchor = at.left + ',' + at.top;
	if (typeof windowAnchorRelease === 'function') {
		windowAnchorRelease(win);
		windowAnchorRelease(head);
	}
	head.removeAttr('free').attr('stack', stack).attr('tile', '0').attr('stack_at', anchor);
	windowTiledSizeReset(head);
	$.each(els, function(i, el) {
		var w = $(el);
		w.removeAttr('free').attr('stack', stack).attr('tile', String(i + 1)).attr('stack_at', anchor);
		if (typeof windowAnchorRelease === 'function') { windowAnchorRelease(w); }
		windowTiledSizeReset(w);
	});
	windowTiledRelayout(stack);
	windowTiledStackRaise(stack);
	if (typeof windowDimensionSetter === 'function') {
		windowDimensionSetter(head);
		$.each(els, function(i, el) { windowDimensionSetter($(el)); });
	}
	if (typeof windowSaver === 'function') { windowSaver(); }
}

// A block put down on open desk stays a pile: the held window becomes its head
// where it was dropped, and the windows it carries fall in below it. A moved
// stack is still a stack, and the next grab of its top takes it whole again.
function windowTiledBlockStart(win, group) {
	win = $(win);
	var els = windowTiledBlockEls(win, group);
	var stack = windowTiledNewStack();
	var at = windowTiledRect(win);
	var anchor = at.left + ',' + at.top;
	$.each(els, function(i, el) {
		var w = $(el);
		w.removeAttr('free').removeAttr('tile').attr('stack', stack).attr('tile', String(i)).attr('stack_at', anchor);
		if (typeof windowAnchorRelease === 'function') { windowAnchorRelease(w); }
		windowTiledSizeReset(w);
	});
	windowTiledRelayout(stack);
	windowTiledStackRaise(stack);
	if (typeof windowDimensionSetter === 'function') { $.each(els, function(i, el) { windowDimensionSetter($(el)); }); }
	if (typeof windowSaver === 'function') { windowSaver(); }
}

// A drag ends either in a pile or outside every pile. The pile under the pointer
// is joined at the slot the held title bar is over, so reordering is the same
// gesture; a window that is not in a pile starts one with the window under the
// drop; and off every pile a single window floats free while a block stays a
// pile where it was put. `home` is the box the window was picked up from, `from`
// the pile it came from, and `group` the windows the drag carried with it.
function windowTiledJoinOrLeave(win, at, home, from, group) {
	if (windowPhoneChecker()) { return; }
	win = $(win);
	if (from === undefined) { from = (windowTiledSlot(win) >= 0) ? windowTiledStackId(win) : null; }
	// leaving happened in the hand; the drop only decides where it lands
	windowTiledDragLeave(win, at, home, from, group);
	var target = windowTiledDropTarget(at, win, home, from, group);
	if (!target) {
		if (win.attr('pre_dimensioned') == 1) {
			// an anchored window put down on open desk keeps its anchor
			win.removeAttr('free');
		}
		else if (group && group.length) {
			// a pile move stays a pile: the block stands as its own pile here
			windowTiledBlockStart(win, group);
			return;
		}
		else { windowTiledBlockLeave(win, group); }
		if (typeof windowSaver === 'function') { windowSaver(); }
		return;
	}
	if (target.stack) { windowTiledStackJoin(win, target.stack, at, group); return; }
	windowTiledStackStart(win, target.window, group);
}

// The slot a dragged window would join, drawn while it is still in the hand.
// The same rule as the drop - the pile under the pointer, or the new pile the
// drop would start - so what the outline shows is where the block's head lands;
// at an edge that owns the half snap it is hidden.
function windowTiledPreview(win, at, home, from, group) {
	var box = $('#window_tile_preview');
	if (!box.length) { box = $('<div id="window_tile_preview"></div>').appendTo('body'); }
	win = $(win);
	if (windowPhoneChecker() || !at) { box.hide(); return; }
	if (from === undefined) { from = (windowTiledSlot(win) >= 0) ? windowTiledStackId(win) : null; }
	// the drag takes the window out of its pile as soon as it is away from it
	windowTiledDragLeave(win, at, home, from, group);
	var ww = $(window).width();
	if (at.x < (ww / 10) || at.x > (ww - (ww / 10))) { box.hide(); return; }
	var target = windowTiledDropTarget(at, win, home, from, group);
	var to;
	var anchor;
	if (target && target.stack) {
		anchor = windowTiledAnchor(target.stack);
		to = windowTiledInsertSlot(at, win, target.stack);
	}
	else if (target && target.window) {
		anchor = windowTiledRect(target.window);
		to = 1;
	}
	else { box.hide(); return; }
	var bar = win.find('.top_navbar');
	var vAdvance = (bar.outerHeight() || 40) - (parseFloat(bar.css('border-top-width')) || 0);
	box.css({
		'left': anchor.left + to * windowTileAcrossStep,
		'top': anchor.top + to * vAdvance,
		'width': win.css('width'),
		'height': win.css('height')
	}).show();
}

function windowReorganizer(window_id) {
	var windows = [];
	var startingV = windowTopLimit();
	var vSpace = 40;
	if (!window_id) { 
		$('.wind').each(function(i,v) {
			windows.push($(v).attr('id'));
		});
	}
	else {
		windows.push(window_id);
	}
	$.each(windows, function(i,v) {
		window_id = v;
		var win = $('#' + window_id);
		var window_app = win.attr('app');
		var app = window_app;
		var winCount = $('.wind').length;
	//	if (!windowPhoneChecker()) {
			winCount = winCount - 1;
	//	}
		// if this window is being restored, it brings the slot it held before the
		// reload (or the fact that it had been dragged out of the tile); a fresh
		// press brings the slot reserved when it was pressed
		var window_stamp = String(window_id).replace(/^window_/, '');
		var restored = windowTiledRestore[window_app];
		delete windowTiledRestore[window_app];
		var pending = windowTiledPending[window_stamp];
		if (!pending) {
			// some bespoke openers render with a timestamp of their own, not the one
			// the press carried; the latest press for that app is the one to claim
			var pending_stamp = windowTiledPendingApp[window_app];
			if (pending_stamp) {
				pending = windowTiledPending[pending_stamp];
				delete windowTiledPending[pending_stamp];
				if (pending) { delete windowTiledPendingApp[window_app]; }
			}
		}
		if (pending) {
			delete windowTiledPending[window_stamp];
			if (pending.app && windowTiledPendingApp[pending.app] === window_stamp) {
				delete windowTiledPendingApp[pending.app];
			}
		}
		topLevelNow(win);
		var thisWinTop = Number(numeral(win.css('top')).format());
		// A pinned window has a place of its own, and the saved view is it. An
		// unpinned window belongs to the tile, so the slot decides where it goes:
		// the saved view is only the place some earlier session left it in, and
		// using it here gave the window that fixed place and no slot at all, so it
		// stood outside the pile.
		if (jws != undefined && isJson(jws) && !windowPhoneChecker() && win.attr('pre_dimensioned') == 1) {
			var view = JSON.parse(jws);
			jws = undefined;
			win.css({ 'top': view[window_app].top, 'left': (view[window_app].left), 'height': view[window_app].height, 'width': view[window_app].width});
		}
		else {
			// The title bar is the step a cascade takes - down a phone's stack
			// of bars or across the desk - so each bar rides on the tail of the
			// one before. Measured, not the fixed 40 that outlived the bar's
			// thinning to 36 and left a sliver of the window underneath showing
			// between one bar and the next.
			var vStep = win.find('.top_navbar').outerHeight() || vSpace;
			// The bars cascade flush, so a bar's foot and the frame of the window
			// below would both draw at the seam and read as a double line. Step each
			// window down by the bar less its border, so the two frames land on one
			// another as a single line.
			var vAdvance = vStep - (parseFloat(win.find('.top_navbar').css('border-top-width')) || 0);
			if (!windowPhoneChecker() && restored && restored.free == 1) {
				// it had been dragged out of the stack: it floats where it was left,
				// and the opener puts its saved geometry back on it
				win.attr('free', '1');
				win.show();
			}
			else if (!windowPhoneChecker() && win.attr('pre_dimensioned') != 1) {
				// its saved slot keeps its pile in the same order after a reload,
				// whatever order the windows arrive in; a new window joins the default
				// pile at the end. Inserting at a taken slot moves that window down, so a
				// fresh window opened while a restore is still arriving is never covered.
				// The pile's id and anchor travel with each member, so a pile away from
				// the corner comes back where it stood.
				var tileStack = (restored && restored.stack !== undefined && restored.stack !== null && restored.stack !== '') ? String(restored.stack) : windowTiledDefaultStack;
				if (tileStack !== windowTiledDefaultStack) {
					win.attr('stack', tileStack);
					if (restored.stack_at) { win.attr('stack_at', restored.stack_at); }
					else if (restored.left !== undefined) { win.attr('stack_at', restored.left + ',' + restored.top); }
				}
				var tileCount = windowTiledSlot(win);
				if (tileCount < 0) {
					if (pending) {
						// the slot was held when the app was pressed, so an earlier press
						// that answered later still lands above a later one; a press opens
						// into the default pile
						tileCount = pending.slot;
						tileStack = windowTiledDefaultStack;
					}
					else if (restored && restored.tile !== undefined && restored.tile !== null && restored.tile !== '') {
						tileCount = parseInt(restored.tile, 10);
					}
					if (isNaN(tileCount) || tileCount < 0) { tileCount = windowNextTileSlot(tileStack); }
					windowTiledInsertAt(win, tileCount, tileStack);
				}
				else {
					windowTiledRelayout(windowTiledStackId(win));
				}
				win.show();
			}
			else {
				var temp_placement = ( vAdvance * winCount ) + startingV;
				win.css({'top': temp_placement });

				if (temp_placement > ($(window).height() - 100)) {
					thisWinTop = Number(numeral(win.css('top')).format());
					fullYCount = winCount;
					win.css({ 'top': thisWinTop - (vAdvance * fullYCount) + startingV });
				}

			}
		}
		// a restore can leave a gap until every saved window has arrived
		if (restored) { windowTiledSettleSoon(); }
		// Keep a window on the screen (and phones it is the width of the screen,
		// pinned left), with its contents scrolling rather than spilling.
		windowFit(win);
		var note = jawnosAppFieldGet(app, 'note');
		var ago = jawnosAppFieldGet(app, 'ago');
		var duration = jawnosAppFieldGet(app, 'duration');
		win.find('.notes').val(note);
		win.find('.ago').val(ago);
		win.find('.duration').val(duration);
		if (typeof jawnosTimePreviewPaintApp === 'function') { jawnosTimePreviewPaintApp(app); }
	});
	startMenuDisplayer();
}
