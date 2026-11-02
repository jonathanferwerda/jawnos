/* [[js-split]]
   windows.js is part 1. The rest live in windows/ in name order:
     01_storage.js  - windowSaver, retriever, appWindowOpener, windowjOpener
     02_fit.js  - minimise/restore/move, draggable, viewport/fit, phone check
     03_stack.js  - stacker, close, z-order, everythingMoves, dimension setter, background, drawer
     04_act.js  - appActSync, the act panel open/close message the beat no longer carries
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */

var windows = [];
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
	var top_bar = '<div id="' + id + '_window">' + windows[id]['formatted_name'] + '</div>';

	wind.html(top_bar);
	wind.css({ 'left': '30%', 'bottom': 0, 'background-color': 'red', 'height': '80%', 'width': '70%' }).show();
}

// The taskbar's window list: one button per open window, oldest on the left and
// newest on the right (ascending z-index, so the most recently raised window
// sits at the right hand end), each wearing the window's own icon and name.
// This is the list the start menu used to carry at its foot, so every caller
// that kept the menu's strip fresh keeps the bar fresh by the same name. Dialog
// boxes count as windows too - the Alert, a folder question and a job's progress
// each get a tile - so any of them can be brought back or minimised from here.
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

		tiles.push({ z: z, html: new_icon.wrap('<span/>').parent().html() });

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
		tiles.push({ z: numeral($(v).css('z-index')).value(), html: icon.wrap('<span/>').parent().html() });
	});
	tiles.sort(function(a, b) { return a.z - b.z; });
	var html = '';
	var stamp = '';
	$.each(tiles, function(i,v) { html += v.html; stamp += v.z + '\u0001' + v.html + '\u0002'; });
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
		$(v).wrap('<span class="hover window_toggle" id="' + rand + '" app="' + app + '" formatted_name="' + named + '" ' + (terminal_id ? 'data-terminal-id="' + terminal_id + '" ' : '') + (window_id ? 'data-window-id="' + window_id + '" ' : '') + (dialog_id ? 'data-dialog-id="' + dialog_id + '" ' : '') + 'style="text-align:center;"></span>');
		$('#' + rand).append(' <span class="window_toggle_name_text">' + named + '</span>');
		$('#' + rand).append(' <span class="window_toggle_shorthand">' + shorthand_name(named, 5) + '</span>');
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
		$(v).before('<span class="hover window_toggle_name" app="' + app + '" style="vertical-align:top;text-align:center;"><b>' + $(v).attr('formatted_name') + '</b><br></span>');
	});
	appointment_chron();
}


$(document).on('click', '.window_toggle', function() {

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
			if ($('#' + window_id).attr('pre_dimensioned') != 1) {
				windowReorganizer(window_id);
			}
			else {
				topLevelNow($('#' + window_id));
			}
		}
		jws = undefined;
		if (carry_on == 1) {
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

function windowReorganizer(window_id) {
	var windows = [];
	var startingV = windowTopLimit();
	var vSpace = 40;
	var hSpace = 50;
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
			if (!windowPhoneChecker() && $('#' + window_id).attr('pre_dimensioned') != 1) {
				win.css({ 'left': winCount * 50, 'top': winCount * vAdvance + startingV });
				win.show();


				if (thisWinLeft > $(window).width()) {
					winLine = winLine + 1;
					win.css({ 'top': thisWinTop + ( vAdvance * winLine + startingV) });
					fullXCount = winCount
				}
				if (fullXCount * (winLine ) > winCount) {
					win.css({'left': thisWinLeft - (vStep * winCount) + startingV});
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
