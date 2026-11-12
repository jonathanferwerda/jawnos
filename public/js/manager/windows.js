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
	$('.window_toggle_name').remove();
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
	$('.window_toggle_name').remove();
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

// The tile is an ordered stack, and each window in it wears its slot as a
// `tile` attribute. The slot, not the order the windows sit on the page, is what
// the tile acts on: a reload restores the windows in whatever order their
// responses arrive, so the page order no longer matches the stack, but the slot
// travels with the window. A pinned window and one dragged out of the stack (a
// free window) carry no slot: they keep their own place and do not step.
function windowTiledSlot(win) {
	var slot = parseInt($(win).attr('tile'), 10);
	return isNaN(slot) ? -1 : slot;
}

// The next free slot at the end of the stack. A window that opens joins there;
// a pinned or free window has no slot and so does not push it along.
function windowNextTileSlot() {
	var next = 0;
	$('.wind').each(function() {
		var slot = windowTiledSlot(this);
		if (slot >= next) { next = slot + 1; }
	});
	return next;
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

// Close the slot a window leaves: every tiled window below it in the stack (a
// higher slot) steps up by one bar and one across-step, and its own slot number
// comes down with it. Slots are what the stack acts on, so this lands on the
// right windows even when the page order was scrambled by a reload.
function windowTiledStepUp(slot) {
	$('.wind').each(function() {
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
}

// Closing a tiled window closes the slot it held. A pinned or free window has
// no slot, so closing it leaves the stack alone; a phone re-parks its whole pile
// in windowStacker and takes none of this.
function windowTiledGapClose(win) {
	if (windowPhoneChecker()) { return; }
	var slot = windowTiledSlot(win);
	if (slot < 0) { return; }
	windowTiledStepUp(slot);
}

// A window dragged out of the stack leaves the tile: it floats where it was put,
// and the windows below it close the slot it held. `float` marks it free (a drag
// does; pinning takes it out of the tile without making it free), so a reload
// knows to leave it where it is instead of stepping it back into line.
function windowTiledLeave(win, float) {
	if (windowPhoneChecker()) { return; }
	win = $(win);
	var slot = windowTiledSlot(win);
	if (slot < 0) { return; }
	win.removeAttr('tile');
	if (float) { win.attr('free', '1'); }
	else { win.removeAttr('free'); }
	windowTiledStepUp(slot);
	if (typeof windowSaver === 'function') { windowSaver(); }
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
		// reload (or the fact that it had been dragged out of the tile)
		var restored = windowTiledRestore[window_app];
		delete windowTiledRestore[window_app];
		topLevelNow(win);
		var thisWinLeft = Number(numeral(win.css('left')).format()) + Number(numeral(win.css('width')).format());
		var thisWinTop = Number(numeral(win.css('top')).format());
		if (jws != undefined && isJson(jws) && !windowPhoneChecker()) {
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
				// its saved slot keeps the stack in the same order after a reload,
				// whatever order the windows arrive in; a new window joins at the end
				var tileCount = windowTiledSlot(win);
				if (tileCount < 0 && restored && restored.tile !== undefined && restored.tile !== null && restored.tile !== '') {
					tileCount = parseInt(restored.tile, 10);
				}
				if (isNaN(tileCount) || tileCount < 0) { tileCount = windowNextTileSlot(); }
				win.attr('tile', String(tileCount));
				win.css({ 'left': tileCount * windowTileAcrossStep, 'top': tileCount * vAdvance + startingV });
				win.show();


				if (thisWinLeft > $(window).width()) {
					winLine = winLine + 1;
					win.css({ 'top': thisWinTop + ( vAdvance * winLine + startingV) });
					fullXCount = tileCount
				}
				if (fullXCount * (winLine ) > tileCount) {
					win.css({'left': thisWinLeft - (vStep * tileCount) + startingV});
				}
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
