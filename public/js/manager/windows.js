
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

function windowMaker(response) {
	if (response == '') { return; }
	var window_id = $(response).filter('.wind').attr('id');
	var window_app = $(response).filter('.wind').attr('app');
	var window_terminal_id = $(response).filter('.wind').attr('data-terminal-id') || '';
	var window_instance_id = $(response).filter('.wind').attr('data-window-id') || '';
	var app = window_app;

	var timestamp = $(response).filter('.wind').attr('timestamp');
	var window_contents = $(response).find('#window_contents_' + timestamp).show();
	var json_storage = storage || sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) ? JSON.parse(json_storage) : {};
	var matches = 0;
	var locked = 'no';
	var carry_on = 0;
	try {
		$('.wind').each(function(i,v){
			var app_attr = $(v).attr('app');
			var app_timestamp = $(v).attr('timestamp');
			var existing_terminal_id = $(v).attr('data-terminal-id') || '';
			var existing_instance_id = $(v).attr('data-window-id') || '';
			// Terminals are several windows of one app, and so are Folders windows.
			// Only the same session (or the same named window) may refresh a window;
			// a different one is a new window, not a redraw.
			if (app_attr == window_app && (!window_terminal_id || !existing_terminal_id || existing_terminal_id == window_terminal_id) && (!window_instance_id || !existing_instance_id || existing_instance_id == window_instance_id)) {
				var ow = $(v).width();
				var oh = $(v).height();
				var ol = $(v).css('left');
				var ot = $(v).css('top');
				matches = 1;
				var id = $(response).attr('id');
				var response_timestamp = $(response).attr('timestamp');
				if (response_timestamp >= (numeral(app_timestamp).value())) {
					var window_saver = sessionStorage.getItem('window_storage');


					var view = JSON.parse(window_saver) || {};
					$(v).find('script').remove();
					var blci = $(v).find('.budget_current_information');
					if (app_attr == 'video' || app_attr == 'screen' || app_attr == 'camera') {

					}
					else {
						$(v).find('.window_contents').html($(response).find('.window_contents').html());
						$('#' + id).width(ow).height(oh);
						$('#' + id).css({ 'left': ol, 'top': ot });
					}

					locked = $(v).attr('locked');
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
						topLevelNow($(v));
					}
					var blci2 = $(new_v).attr('current_information');
					if (blci.attr('status') == 'open' || blci2) {
						var circumstance = blci2 || blci.attr('circumstance');
						budgetLight(app_attr,circumstance,'open');
					}
					carry_on = 1;
				}
				else { matches = 1; }
			}
		});
		
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
	});
	startMenuDisplayer();
}



function windowSaver() {

	var json_storage = sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) ? JSON.parse(json_storage) : {};

	$('.wind').each(function(i,v) {
		var app = $(v).attr('app');
		var data = [];
		if (app == 'marker') {
			data = marker;
		}

		var left = numeral($(v).css('left')).value();
		var top = numeral($(v).css('top')).value();
		var height = numeral($(v).css('height')).value();
		var width = numeral($(v).css('width')).value();
		var zindex = $(v).css('z-index');
		var timestamp = $(v).attr('timestamp');
		var locked = $(v).attr('locked');
		var visible = $(v).attr('visible');
		var headerUpdate = $(v).find('.appointment_header_background').attr('last_updated') || timestamp;
		var scrollTop;
		if (timestamp) {
			scrollTop = $('#' + timestamp).scrollTop();
		}
		var wc = $('#window_contents_' + timestamp).is(':visible');
		var tnh = jawnosWindowSizeGet(timestamp, 'h');
		var tnw = jawnosWindowSizeGet(timestamp, 'w');
		var jopen = windowjOpenSaver($(v));
		var current_information;
		var blci = $(v).find('.budget_current_information');
		if  (blci.is(':visible')) {
			current_information = blci.attr('circumstance');
		}
		var special_configuration;
		if ($(v).find('.special_configuration_container').is(':visible')) {
			special_configuration = 1;
		}

		storage[app] = {
			type: 'window',
			visible: visible,
			app: app,
			top: top,
			left: left,
			height: height,
			headerUpdate: headerUpdate,
			current_information: current_information,
			width: width,
			tnh: tnh,
			tnw: tnw,
			wc: wc,
			scrollTop: scrollTop,
			scc: special_configuration,
			jopen: jopen,
			locked: locked,
			zindex: zindex,
			timestamp: timestamp,
			browser_tab_id: bti,
			data: data,
		};
		// NOTE: this used to serialise the whole #browser to HTML (and re-parse it)
		// once per window, then throw the result away. That is very expensive and
		// runs on every heartbeat windowSaver() call, so it was removed.
	});
	$('.keyboard.bc').each(function(i,v) {
		var left = $(v).css('left');
		var top = $(v).css('top');
		var height = $(v).css('height');
		var width = $(v).css('width');
		var zindex = $(v).css('z-index');
		var toggle = $(v).attr('id');
//		var html = $(v).closest('.typewriter').html();
		storage[toggle] = {
			type: 'keyboard',
			top: top,
			left: left,
			height: height,
			width: width,
			zindex: zindex,
			browser_tab_id: bti,
			toggle: $(v).attr('toggle'),
	//		typewriter: html
		};
	});
	$.each(storage,function(i,v) {
		if (v.type == 'window') {
			if (!$('#window_' + v['timestamp'])) {
				delete storage[i];
			}
		}
		else if (v.type == 'keyboard') {
			if (!$('#' + i).is(':visible')) {
				delete storage[i];
			}
		}
	});

	storage['musicData'] = tree['musicData'];
	var json_storage = JSON.stringify(storage);
	sessionStorage.setItem('window_storage',json_storage);
	return json_storage;
}

function ticketWindowRetriever() {
	if (!sessionStorage.getItem('window_storage')) {

		$.ajax({
			url: '/manager/window_retriever',
			type: 'GET',
			data: {},
			success:function(response) {
				if (response.tab.windows) {
					var windows = response.tab.windows;
					sessionStorage.setItem('window_storage', windows);
					windowRetriever();
				}
			}
		});



	}
}

function windowRetriever() {
	var json_storage = storage || sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) ? JSON.parse(json_storage) : {};
	var window_w = $(window).width();
	var window_h = $(window).height();
	ticketWindowRetriever()

	$.each(storage, function(i,v) {
		if (v.type == 'window') {
			var app = JSON.stringify({ name: i });
			var timestamp = Date.now();
			appWindowLoader(i,v);
		}
		else if (v.type == 'keyboard') {
			
		//	$('#keyboard_container').append('<div class="typewriter">' + v.typewriter + '</div>');

			keyboardMaker(i);
			var window = $('#' + i);
			window.parent().show();
			var toggle = window.parent().attr('toggle');
			var kept_style = jawnosWindowStyleGet(i);
			if (kept_style) {
				var css = JSON.parse(kept_style);
				window.css(css);
			}
			else {

				window.css({ 'top': v.top, 'left': v.left, 'height': v.height, 'width': v.width, 'z-index': v.zindex });
			}
			window.show();
			window.attr('claimed', 'no');
			keyboardDragEnabler(window,i,'off');
		}
	});

	// A phone shows its windows as a cascade, and a restore renders them all at
	// once - so their z-order and sizes drift as the renders settle. Once, after
	// the burst, put each window back in its saved place and re-cascade the pile.
	if (windowPhoneChecker()) {
		var saved = {};
		$.each(storage, function(i,v) {
			if (v.type == 'window') { saved[i] = { z: v.zindex, h: v.height, w: v.width }; }
		});
		setTimeout(function() {
			$.each(saved, function(app, s) {
				var w = $('.wind[app="' + app + '"]');
				if (!w.length) { return; }
				if (s.z) { w.css('z-index', s.z); }
				if (s.h) { w.css('height', s.h); }
				if (s.w) { w.css('width', s.w); }
			});
			if (typeof windowStacker == 'function') { windowStacker(); }
		}, 1500);
	}
}

function appWindowLoader(i,v) {
	if (!i) {
		return;
	}
	var json_storage = storage || sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) ? JSON.parse(json_storage) : {};
	if (!v) { v = storage[i] };
	appWindowOpener(i, Date.now(), v);
}

// Load (or reload) a window the right way for its app: some apps have bespoke
// openers, everything else falls back to the centre view. Shared by
// windowRetriever (restoring saved windows) and the icon-set refresh.
function appWindowOpener(i,timestamp,v) {
	if (!i) {
		return;
	}
	v = v || {};
	timestamp = timestamp || Date.now();
	// Every window the guide opens is one it may want to look over: if the app's
	// name does not match its part of speech, the guide sets the right one. The
	// server marks what it has seen, so this is a no-op after the first time and
	// on a machine with no model.
	if (typeof i === 'string' && i) { $.post('/manager/help/review', { app: i }); }
	var window_w = $(window).width();
	var window_h = $(window).height();
	var app = JSON.stringify({ name: i });
	// Preserve whatever sub-panels the window already has open, so a re-render
	// (e.g. an icon-set swap) reopens the same sections instead of collapsing them.
	// Only when the window is already on screen; a fresh restore is handled by the
	// server-emitted `jopen` script inside windowMaker.
	var refresh_jopen = null;
	if (!v.jopen) {
		var existing_window = $('.wind[app="' + i + '"]');
		if (existing_window.length > 0) {
			try {
				var live_jopen = windowjOpenSaver(existing_window);
				if (live_jopen[i] && live_jopen[i].containers && live_jopen[i].containers.length > 0) {
					refresh_jopen = live_jopen;
				}
			} catch (e) {}
		}
	}
	// the built-in apps come from the server (jawnos_builtin_apps, stamped by the
	// layout from gb::known_appts), so there is one list, not two that drift
	if (jawnos_builtin_apps[i]) {
//				var preload = sessionStorage.getItem('preload_' + i);
		var scope = localStorage.getItem('scope');
		var article_uuid = localStorage.getItem('editor_article');
		var mail_contact = localStorage.getItem('mail_contact');
		var picked = JSON.stringify(mail_picker());
		if (i == 'gallery') {
			imageViewer({ 'view': 'load', 'loadImages': 1 });
		}
		else if (i == 'help') {
			helpOpener();
		}
		else if (i == 'handbook') {
			// the daily page is the front door now; a chapter already open is kept
			var handbook_chapter = localStorage.getItem('handbook_chapter') || 'today';
			if (handbook_chapter == 'undefined' || handbook_chapter == 'null') { handbook_chapter = 'today'; }
			handbookGrabber(handbook_chapter, localStorage.getItem('handbook_page'));
		}
		else if (i == 'embedded') {
			embeddedDevicesOpener();
		}
		else if (i == 'mailbox') {
			mailMaker(null, 'mailbox');
		}
		// the split mail apps restore through their own window too (their routes
		// wrap the panel with their own app name); without a branch they fall to the
		// generic else below, which answers with the panel as a centre view
		else if (i == 'email') {
			mailMaker(null, 'email');
		}
		else if (i == 'chat') {
			mailMaker(null, 'chat');
		}
		else if (i == 'pen') {
			mailMaker(null, 'pen');
		}
		else if (i == 'box_office') {
			// box office runs its own opener: the ticket key and the chosen view
			// come with it, so the pinned icon opens exactly what the start menu's
			// Tickets row does
			boxOffice();
		}
		else if (i == 'store') {
			storeOpener();
		}
		else if (i == 'warehouse') {
			warehouseInitializer();
		}
		else if (i == 'market') {
			marketOpener();
		}
		else if (i == 'measures') {
			measuresOpener();
		}
		else if (i == 'budget') {
			budgetInit()
		}
		else if (i == 'studio') {
			studioInit();
		}
		else if (i == 'terminal') {
			terminalOpener({ 'window_maker': 'yes' }); 
		}
		else if (i == 'folders') {
			foldersOpener();
		}
		// Process Monitor is an app, not an appointment: a refresh restores the
		// window through its own route instead of opening a centre view.
		else if (i == 'process_monitor') {
			monitorOpener();
		}
		else {
			$.ajax({
				url: '/manager/' + i,
				type: 'GET',
				data: {
					timestamp: timestamp,
					scope: scope,
					article_uuid: article_uuid,
					window_maker: 'yes',
					picker: picked,
					mail_contact: mail_contact
				},
				success: function(response) {
					if (typeof response != 'object') {
						centreViewWriter(response);
					}


					var id = $(response).attr('id');
					var window = $('#' + id);
					if (window.length == 0) { window = $('.wind[app="' + i + '"]'); }

					if (i == 'travel') {
						travelViewer({ timestamp: timestamp });
					}
					if (i == 'music') {
						musicInit();
					}
					else if (i == 'twirl') {
						twirlGame();
					}
					else if (i == 'cards') {
					//	cardPicker();
					}
					else if (i == 'marker') {
						markerInit();
					}
					else if (i == 'editor') {
						editorInit();
					}
					else if (i == 'synth') {
						pianoInit();
					}
					else if (i == 'ide') {
						centreViewWriter(response.html);
						ideTabPopulator(response);
					}
					else if (i == 'relational') {
						relationalInit(response);
					}
					if (refresh_jopen) {
						windowjOpener(window, { jopen: refresh_jopen, scrollTop: v.scrollTop });
					}
					if (v.visible != 'yes') {
						window.hide();
					}
					if (v.top > 0 && v.left < window_w && v.top < window_h && v.left >= 0) {
						window.css({ 'top': v.top, 'left': v.left, 'height': v.height, 'width': v.width, 'z-index': v.zindex });
						if (numeral(v.zindex).value() > top_level_now) {
							top_level_now = numeral(v.zindex).value();
						}
					}
					windowFit(window);

				},
				error: function(e) { console.log(e); }
			});
		}
	}
	else {
		$.ajax({ 
			url: '/manager/centre_view',
			type: 'GET',
			data: { app: app, timestamp: timestamp },
			success: function(response) {
				centreViewWriter(response);
				var id = $(response).attr('id');
				var window = $('#' + id);
				if (window.length == 0) { window = $('.wind[app="' + i + '"]'); }

				if (v.top > 0 && v.left < window_w && v.top < window_h && v.left >= 0) {
					window.css({ 'top': v.top, 'left': v.left, 'height': v.height, 'width': v.width, 'z-index': v.zindex });
				}
				windowFit(window);

				if (refresh_jopen) {
					windowjOpener(window, { jopen: refresh_jopen, scrollTop: v.scrollTop });
				}
				if (v.current_information) {
					budgetLight(i,v['current_information'],'open');
				}
				else if (typeof budgetLightRestore === 'function') {
					budgetLightRestore(i);
				}
				if (v.visible != 'yes') {
					window.hide();
				}
			}
		});
	}
}

function windowjOpenSaver(window) {
	var jopen = {};
	var app = window.attr('app');
	jopen[app] = { 'containers': [], 're_details': {}, 'lists': [] };
	var re_data = $('.detail_json[app="' + app + '"]');
	if (re_data.length > 0 && re_data.text() != '' ) {
		var data = re_data.text() || '{}';
		jopen[app]['re_details'] = JSON.parse(data);
	}
	jopen[app]['configure'] = [];
	jopen[app]['attribute'] = [];
	$('.app_configure_input[app="' + app + '"]').each(function(i,v) {
		if ($(v).is(':visible')) {
			jopen[app]['configure'].push($(v).attr('setting'));
		}
	});
	$('.attribute_contents[app="' + app + '"]').each(function(i,v) {
		if ($(v).is(':visible')) {
			jopen[app]['attribute'].push($(v).attr('uuid'));
		}
	});
	$.each(appt_containers, function(no,noc) {
		var container = window.find('.' + no);
		if (container.is(':visible')) {
			jopen[app]['containers'].push(no);
		}
	});
	if (window.attr('app') == 'configure') {
		$.each(config_appt_containers, function(no,noc) {
			var container = window.find('#' + no);
			if (container.is(':visible')) {
				jopen[app]['containers'].push(no);
			}
		});
	}
	window.find('.appointment_list').each(function(i,v) {
		if ($(v).is(':visible')) {
			var uuid = $(v).closest('.appointment_detail').attr('uuid');
			var list = $(v).attr('list');
			jopen[app]['lists'].push({ 'uuid': uuid, 'list': list });
		}
	});
	return jopen;
}

var windowjOpenerStatus = {};
var windowjOpenerTimers = {};
function windowjOpener(window,v) {
	var app = window.attr('app');
	if (!v || !v.jopen || !v.jopen[app]) { return; }

	if (windowjOpenerTimers[app]) {
		clearInterval(windowjOpenerTimers[app]);
		windowjOpenerTimers[app] = null;
	}
	windowjOpenerStatus[app] = 'running';

	var state = v.jopen[app];
	var containers = state.containers || [];

	if (containers.length > 0) {
		$.each(containers, function(no,noc) {

			if (noc == 're_details' && state.re_details && state.re_details['app']) {
				var jdata = JSON.stringify(state.re_details);
				$('.detail_json[app="' + app + '"]').text(jdata);
				$('.re_details[app="' + app + '"]').show();
				appointmentDetailsUpdater(app);
			}
			else {
				if (app == 'configure') {
					var c = window.find('#' + config_appt_containers[noc]);
					c.attr('original_text', c.text());
					c.trigger('click');

				}
				else {
					window.find('.' + appt_containers[noc]).trigger('click');
				}
			}
		});
	}

	var attempts = 0;
	windowjOpenerTimers[app] = setInterval(function() {
		attempts++;
		var jopenSuccess = 0;
		$.each(containers, function(no,noc) {
			var selector = (app == 'configure' ? '#' : '.') + noc;
			if (window.find(selector).is(':visible')) {
				jopenSuccess++;
			}
		});
		var complete = (jopenSuccess == containers.length);
		// give up after a while so a container that never loads can't leak an interval
		if (complete || attempts >= 20) {
			if (complete) {
				$.each(state.configure || [], function(i, s) {
					$('.app_configure_input[app="' + app + '"][setting="' + s + '"]').show();
				});
				$.each(state.attribute || [], function(i, s) {
					$('.attribute_contents[app="' + app + '"][uuid="' + s + '"]').show();
					if (!openAttributes[app]) { openAttributes[app] = {}; }
					openAttributes[app][s] = 'open';
				});
				$.each(state.lists || [], function(i, s) {
					$('.appointment_detail[uuid="' + s.uuid + '"]').find('.appointment_list[list="' + s.list + '"]').show();
				});
				if (window.attr('scrollTop') != undefined) {
					var scrollTop = window.attr('scrollTop');
					$('#' + (window.attr('timestamp') || 'hey')).scrollTop(scrollTop);
				}
				else {
					$('#' + (window.attr('timestamp') || 'hey')).scrollTop(v.scrollTop);
				}
				windowSaver();
			}
			clearInterval(windowjOpenerTimers[app]);
			windowjOpenerTimers[app] = null;
			windowjOpenerStatus[app] = 'done';
		}
	}, 300);
}


function windowMinimizer(timestamp,app) {
	var win = $('#window_' + timestamp);
	if (app) {
		win = $('.wind[app="' + app + '"]');
	}
	if (win.is(':visible')) { 
		win.hide();
		win.attr('view', 'minimized');
		var tnh = win.height();
		var tnw = win.width();

		jawnosWindowSizeSet(timestamp, 'h', tnh);
		jawnosWindowSizeSet(timestamp, 'w', tnw);

	} else { 
		$('#window_contents_' + timestamp).show();
		if (windowPhoneChecker()) { 
			$('#window_contents_' + timestamp).css({'overflow': 'scroll'});
		}

		var tnh = jawnosWindowSizeGet(timestamp, 'h');
		var tnw = jawnosWindowSizeGet(timestamp, 'w');
		$('#window_' + timestamp).css({'height': tnh, 'width': tnw });
	}
	windowDimensionSetter(win);
}

function windowHalfski(win,side) {

	var mouse = { x: null, y: null };
	if (!side) {
		mouse = mouse_position();
	}
	if (!windowPhoneChecker()) {
		// the top sits flush under a taskbar on the top edge - headerHeight is the
		// bar's own height - so the titlebar is not tucked under the bar. (The old
		// reservedSpots['header'] + 2 left a 2px overlap.)
		var ok = (typeof headerHeight != 'undefined') ? headerHeight : (reservedSpots['header'] || 0);
		var ww = $(window).width();
		// The half window reaches the foot of the screen, stopping only for what
		// holds the bottom edge: a bottom taskbar, and the strip a bottom dock keeps
		// on screen while it is tucked (windowBottomClearance carries both). That
		// leaves the dock's reach on screen instead of burying it - and the window's
		// own foot controls, which sit at its very bottom, clear the dock instead of
		// hiding under it. While the search rides the dock its panel may be out, so
		// the foot also stops on the dock's own top edge.
		var foot = $(window).height() - windowBottomClearance();
		var search_in_dock = $('#search_entanglement').closest('#pseudonym_home').length > 0;
		var dock_on_bottom = (typeof jawnosDockTop == 'function' && !jawnosDockTop())
			&& (typeof jawnosSideDock == 'function' && !jawnosSideDock())
			&& (typeof jawnosDockHidden == 'function' && !jawnosDockHidden());
		if (search_in_dock && dock_on_bottom) {
			var dock = $('#pseudonym_home');
			if (dock.length) { foot = Math.min(foot, dock.offset().top); }
		}
		var height = foot - ok;
		if (mouse.x > (ww - (ww / 10)) || side == 'right') {

			win.css({ 
				'position':'fixed', 
				'height': height, 
				'width': '50%',
				'left': '50%',
				'top': ok
			});
		}
		else if (mouse.x < (ww / 10) || side == 'left') {
			win.css({ 
				'position':'fixed', 
				'height': height, 
				'width': '50%',
				'left': '0%',
				'top': ok
			});
		}
		windowDimensionSetter(win);
	}
}

$(document).on('click', '.maximize_button', function() {
	var timestamp = $(this).closest('.wind').attr('timestamp');
	var app = $(this).closest('.wind').attr('app');
	windowMaximizer(timestamp,app);
});

function windowMaximizer(timestamp, app) {
	var win = $('#window_' + timestamp );
	$('#window_' + timestamp + '_restore').show();
	$('#window_' + timestamp + '_maximize').hide();
	// A maximized window fills the space between the top limit and the foot
	// clearance - a bottom taskbar and the strip a bottom dock keeps on screen - so
	// no band of desktop shows beneath it and its own foot controls clear the dock.
	// The old fixed percentages left that band (and overran the foot on a short
	// screen). The phone keeps its own shorter face.
	var hidden = (typeof jawnosDockIconsHidden == 'function') && jawnosDockIconsHidden();
	if (windowPhoneChecker()) {
		var tall = hidden ? Math.max(200, $(window).height() - windowTopLimit() - windowBottomClearance() - 6) + 'px' : null;
		win.css({ 
			'position':'fixed', 
			'height': tall || '80%', 
			'width': '98%',
			'left': '0px',
			'top': windowTopLimit()
		});
	}
	else {
		win.css({ 
			'position':'fixed', 
			'height': Math.max(200, $(window).height() - windowTopLimit() - windowBottomClearance()) + 'px', 
			'width': '100%',
			'left': '0px',
			'top': windowTopLimit()
		});
	}
	$('#window_contents_' + timestamp ).css({ 'width': '100%' });
	windowDimensionSetter($('#window_' + timestamp ));
}

function windowRestore(timestamp,app) {
	var win = $('#window_' + timestamp + '');


	$('#window_' + timestamp + '_maximize').show(); 
	$('#window_' + timestamp + '_restore').hide(); 
	if (windowPhoneChecker()) {
		win.css({ 'position':'fixed', 'height': '500px', 'width': '98%' });
	} else {
		if (win.attr('free_dimensions')) {
			var d = JSON.parse(win.attr('free_dimensions'));
			win.css({ 'position':'fixed', 'height': d.height, 'width': d.width, 'top': d.top, 'left': d.left });
		} else {
			win.css({ 'position':'fixed', 'height': '500px', 'width': '450px' });
		}
	}
	windowDimensionSetter(win);
}

function windowRestorer(timestamp,app) {
	var win = $('#window_' + timestamp);
	if (app) {
		win = $('.wind[app="' + app + '"]');
	}
	if (!win.is(':visible')) {
		if (win.length == 0) {
			if ($('.wind[app="' + app + '"]').length == 0) {
				appointmentGrabber(app);
			//	$('#window_icon_' + timestamp).remove();
			}
			else {
				win.show();
			}
		}
		else {
			win.show();
		}
		win.attr('visible', 'yes');
	}
	else {
		win.hide();
		win.attr('visible', 'no');
	}
	windowDimensionSetter(win);

}

var reservedSpots = {};

// Move mode: a window put into it is dragged from anywhere on it (not just its
// navbar) for one move, or until it is turned off again from the window's menu.
// Only one window moves at a time.
var jawnos_move_app = null;
function jawnosWindowMoveMode(app) {
	if (jawnos_move_app && jawnos_move_app != app) { jawnosWindowMoveModeOff(jawnos_move_app); }
	if (jawnos_move_app == app) { jawnosWindowMoveModeOff(app); return; }
	var win = $('.wind[app="' + app + '"]');
	if (!win.length) { return; }
	jawnos_move_app = app;
	windowDraggable(win);
	if (win.hasClass('ui-draggable')) { win.draggable('option', 'handle', false); }
	win.addClass('window_move_mode');
	win.off('dragstop.jawnos_move').on('dragstop.jawnos_move', function () { jawnosWindowMoveModeOff(app); });
}
function jawnosWindowMoveModeOff(app) {
	var win = $('.wind[app="' + app + '"]');
	win.removeClass('window_move_mode');
	if (win.hasClass('ui-draggable')) { win.draggable('option', 'handle', '.top_navbar'); }
	win.off('dragstop.jawnos_move');
	if (jawnos_move_app == app) { jawnos_move_app = null; }
}

function windowDraggable(win) {
	if (!win.hasClass('ui-draggable')) {

		win.draggable({
			cancel: 'input,textarea,button,select,option,.save_appointment,.app_act,.edit_app,.delete_app,.delete_location,.minimize_button,.restore_button,.maximize_button,.close_button',
			handle: '.top_navbar',
			start: function(p,ui) {
				windows[p.target.id] = Date.now();
				if (win.attr('view') == 'max' && win.attr('free_dimensions')) {
					var d = JSON.parse(win.attr('free_dimensions'));
					var top = win.css('top');
					var mouse = mouse_position();
					var left = (mouse.x - (numeral(d.width).value() / 2));
					win.css({'position': 'fixed', 'height': d.height, 'width': d.width });
					ui.position.left = left;
					win.find('.maximize_button').show();
					win.find('.restore_button').hide();
					windowDimensionSetter(win);
				}
			},
			drag: function(p,ui) {
				markerDragger(p.target.id,'drag');
			},
			stop: function(p,ui) {
				var d = mouse_position();
				var data = JSON.stringify(d);
				var now = Date.now();
				var halfski = windowHalfski(win);
				$('#marker_targeting').hide();
				if (halfski == 'ya') {

				}
				else if (d.y < windowTopLimit() + 10) {
					var ok = windowTopLimit();
					var point = document.elementFromPoint(d.x, d.y) || 'null';
					var pd = $('#' + p.target.id).closest('.wind');
					
					pd.css({ 'top': ok });
				}
				else if (now - windows[p.target.id] < 250) {
					var point = document.elementFromPoint(d.x, d.y) || 'null';

					var wc = $('#window_contents_' + timestamp);
					wc.show();

					var tnh = jawnosWindowSizeGet(timestamp, 'h');
					var tnw = jawnosWindowSizeGet(timestamp, 'w');

					$('#window_' + timestamp).css({'height': tnh, 'width': tnw });
				}
				markerDragger(p.target.id,'stop');
				windowDimensionSetter($('#' + p.target.id));
				// a phone's pile is a cascade; a drag would leave the window over the
				// others' bars and swallow their taps, so restack it - to the top of
				// the pile - the moment the drag ends
				if (windowPhoneChecker()) { windowStacker(win.attr('app'), true); }
			}
		});
		// a phone keeps its windows the width of the screen: vertical only
		if (windowPhoneChecker()) { win.draggable('option', 'axis', 'y'); }
		setTimeout(function () {
			win.removeClass('active');
		},50);
	}
}


$(document).on('click touchend', '.close_button', function(e) {
  // Prevent the event from bubbling up to the draggable container
  e.stopPropagation();
  e.preventDefault();
  if (e.type == 'touchend' && typeof jawnosSuppressClick == 'function') {
    // the window leaves the page under the finger; keep the browser's delayed
    // click from landing on whatever sits underneath it. Only a click at the
    // finger is held back, so the next tap elsewhere - a dot on the timeline,
    // say - keeps its click instead of paying for the closed window
    var t = (e.originalEvent && e.originalEvent.changedTouches) ? e.originalEvent.changedTouches[0] : undefined;
    jawnosSuppressClick(t ? t.clientX : undefined, t ? t.clientY : undefined);
  }
  
  // Retrieve the variables from data attributes
  var app = $(this).attr('app');
  var timestamp = $(this).attr('timestamp');
  
  // Execute your functions; a websocket that will not stop is no reason to
  // leave the window open
  try { websocketStop(app); } catch (err) { console.log('close: websocket stop failed', err); }
  closeWindow(timestamp);
});

$(document).on('click touchend', '.restore_button', function(e) {
  // Prevent the event from bubbling up to the draggable container
  e.stopPropagation();
  e.preventDefault();
  
  // Retrieve the variables from data attributes
  var app = $(this).attr('app');
  var timestamp = $(this).attr('timestamp');
  
	windowRestore(timestamp);
});

$(document).on('click touchend', '.minimize_button', function(e) {
  // Prevent the event from bubbling up to the draggable container
  e.stopPropagation();
  e.preventDefault();
  
  // Retrieve the variables from data attributes
  var app = $(this).attr('app');
  var timestamp = $(this).attr('timestamp');
  
	windowMinimizer(timestamp);
});


// Keep a window on the screen. These used to clamp against $(document) sizes,
// so any tall element that stretched the document let windows grow past the
// viewport. A phone window is always the full width of the screen, pinned
// left; anything overflowing gets its contents scrolled instead of spilled.
//
// The visual viewport is the one to trust for the on-screen keyboard: Android
// shrinks it while the keys are up and grows it back when they go. A window
// clamped for the keyboard remembers the height it wanted, and a later resize
// restores it instead of leaving the window small for the rest of the session.
function windowViewport() {
	var vv = window.visualViewport;
	var width = (vv && vv.width) ? vv.width : $(window).width();
	var height = (vv && vv.height) ? vv.height : $(window).height();
	return { width: Math.round(width), height: Math.round(height) };
}

function windowFit(win) {
	if (win.length == 0) { return; }
	var view = windowViewport();
	var viewW = view.width;
	var viewH = view.height;
	if (windowPhoneChecker()) {
		win.css({ 'left': 0, 'width': viewW });
	}
	var winLeft = Number(numeral(win.css('left')).format()) || 0;
	var winTop = Number(numeral(win.css('top')).format()) || 0;
	if (winLeft + win.width() > viewW) {
		win.width(Math.max(240, viewW - winLeft));
	}
	var wanted = parseFloat(win.attr('fit_height')) || 0;
	if (win.attr('fit_shrunk') == 'yes' && wanted && winTop + wanted <= viewH) {
		// the keyboard is gone (or the screen grew back): return the window to
		// the size it had before the shrink
		win.height(wanted);
		win.removeAttr('fit_shrunk').removeAttr('fit_height');
	}
	if (winTop + win.height() > viewH) {
		if (win.attr('fit_shrunk') != 'yes') {
			win.attr('fit_height', win.height()).attr('fit_shrunk', 'yes');
		}
		win.height(Math.max(240, viewH - winTop));
	}
	win.find('.window_contents').each(function () {
		var el = this;
		var cs = getComputedStyle(el);
		if (cs.overflow != 'visible') { return; }
		if (el.scrollHeight > el.clientHeight + 4 || el.scrollWidth > el.clientWidth + 4) {
			$(el).css('overflow', 'auto');
		}
	});
}

var windowFitTimer;
var windowFitLast = { width: 0, height: 0 };
function windowFitAllSoon() {
	clearTimeout(windowFitTimer);
	windowFitTimer = setTimeout(function () {
		var view = windowViewport();
		// ignore a viewport that moved but did not really change (the browser's
		// collapsing bar nudges it on every scroll)
		if (Math.abs(view.width - windowFitLast.width) < 2 && Math.abs(view.height - windowFitLast.height) < 2) { return; }
		windowFitLast = view;
		$('.wind').each(function () { windowFit($(this)); });
	}, 60);
}
$(window).on('resize orientationchange', windowFitAllSoon);
if (window.visualViewport) { window.visualViewport.addEventListener('resize', windowFitAllSoon); }
$(document).on('resizestop', '.wind', function () {
	// a person's own resize is the new wanted size
	$(this).removeAttr('fit_shrunk').removeAttr('fit_height');
	windowFit($(this));
});

function windowPhoneChecker() {
	if (navigator.userAgent.match('Android') || navigator.userAgent.match('Mobile')) {
		// the short side of the screen decides: a phone is still a phone in
		// landscape, and a tablet does not become one just by being narrow
		if (Math.min(screen.width, screen.height) < 500) {
			return true;
		}
		return false;
	}

	else {
		return false;
	}
}

function windowAligner() {
	
	$('.wind').each(function(i,v) {
		var width = $(this).width();
		$(this).css({'width': '100%' });		
	});
}

// Phones cascade their windows: windowReorganizer parks each one a title bar
// below the last, so the bars step down the screen and the window in front sits
// at the foot of the cascade. "Top of the pile" means by z-index, not height: the
// front window is the one wearing the highest z, and its bar is the lowest. That
// gives two jobs. Closing a window should close the gap - the bars below step up
// into its place - and a tap on a title bar should walk the pile: the top of the
// pile (the front window) drops to the bottom of the stack, and a window tapped
// lower down rises to the top of the pile. A tap on a window's body, and the end
// of a drag, restack too - they lift that window to the top of the pile - so no
// window is left lying over the others' bars, swallowing their taps. Desks place
// windows by hand wherever they like, so none of this applies there and it is a
// no-op.
function windowStacker(app, raise) {
	if (!windowPhoneChecker()) { return; }
	var visible = $('.wind').filter(':visible');
	if (visible.length == 0) { return; }

	// the pile by z-index - the back (lowest z) first, so the top of the pile
	// (the front window, highest z) is last. z is the pile's own order: a window
	// dragged about on screen keeps its place in it, where sorting by height would
	// mistake a window merely dragged low for the one in front.
	var order = visible.sort(function (a, b) {
		var za = parseInt($(a).css('z-index'), 10) || 0;
		var zb = parseInt($(b).css('z-index'), 10) || 0;
		if (za !== zb) { return za - zb; }
		return (parseFloat($(a).css('top')) || 0) - (parseFloat($(b).css('top')) || 0);
	}).toArray();

	if (app) {
		var target = $('.wind[app="' + app + '"]').get(0);
		if (!target || order.length < 2) { return; }
		// the top of the pile is the front window - the one wearing the highest
		// z-index, which is the last in the order below
		var front = order[order.length - 1];
		var rest = order.filter(function (el) { return el !== front; });
		if (raise) {
			// a press that is not the pile's walk - a tap on a window's body, or the
			// end of a drag - lifts that window to the top of the pile and leaves the
			// rest in order, rather than the walk's front-to-foot rotation
			order = order.filter(function (el) { return el !== target; }).concat([target]);
		} else if (target === front) {
			// a tap on the top of the pile walks it down to the bottom of the stack
			order = [front].concat(rest);
		} else {
			// a tap lower down lifts it to the top of the pile and drops the old
			// top to the bottom of the stack
			order = [front].concat(rest.filter(function (el) { return el !== target; }), [target]);
		}
		// z climbs with the order, so the last in the order is the front
		$(order).each(function (slot) { $(this).css({ 'z-index': top_level_now + slot + 1 }); });
		top_level_now = top_level_now + order.length;
	}

	// re-cascade the pile by that order: a closed window leaves no gap. Step each
	// window down by the height of the bar above it - not one measured step for
	// the whole pile - so the bars sit flush even when their heights differ (a
	// single step against a bar of another height leaves a gap, or an overlap).
	// Then pull it up by the bar's own border, so this bar's foot and the next
	// window's frame land on one another and read as a single line, not two.
	var y = windowTopLimit();
	$(order).each(function () {
		var win = $(this);
		win.css({ 'top': y });
		var bar = win.find('.top_navbar');
		var border = parseFloat(bar.css('border-top-width')) || 0;
		y = y + (bar.outerHeight() || 40) - border;
	});

	// raise the new front through topLevelNow so its frame ring and the taskbar
	// pins follow the order
	if (app) { topLevelNow($(order[order.length - 1])); }
}

function windowRefresher(app) {
	var json_storage = sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) ? JSON.parse(json_storage) : {};
	var view = $.grep(storage, function(i,v) {
		return app == i;
	});
	if (view[0]) {
		$('.wind[app="' + app + '"]').css({ 'top': view[0].top, 'left': view[0].left, 'height': view[0].height, 'width': view[0].width });
	}
}

function closeWindow(timestamp) {

	var win = $('#window_' + timestamp);
	win.find('.window_script').remove();
	var app = win.attr('app');
	if (app == 'twirl') {
		twirlRunning = false;
	}
	if (app == 'mailbox' && typeof mailSocketClose == 'function') { mailSocketClose(); }
	// closing the app closes its padlock in this tab as well as on the server
	if ((app == 'gallery' || app == 'music' || app == 'folders') && typeof jawnosMediaLockdown === 'function') {
		jawnosMediaLockdown(app, true);
	}
	$('#window_' + timestamp ).remove();
	$('#window_icon_' + timestamp).remove();
	//pseudonymFreeSpaceFinder();
	$('#little_window_' + timestamp).remove();
	var window_saver = sessionStorage.getItem('window_storage');
	var open_windows = JSON.parse(window_saver) || {};
	delete open_windows[app];
	var new_windows = JSON.stringify(open_windows);
	sessionStorage.setItem('window_storage', new_windows);
	$('#window_script_' + timestamp).remove();
	$('.window_script_' + timestamp).remove();
	$.ajax({
		url: '/manager/window_closer',
		type: 'POST',
		data: { timestamp: timestamp, app: app, browser_tab_id: sessionStorage.getItem('browser_tab_id') || (typeof bti !== 'undefined' ? bti : ''), device_uuid: (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : '' },
		success: function(response) {
			websocketStop(app);
		}
	});
	windowSaver();
	startMenuDisplayer();
	windowBackgroundAdjuster();
	// a phone layers its windows on one another, so the layers left behind
	// want re-parking against the smaller count
	if (windowPhoneChecker()) { windowStacker(); }
}

$(document).on('click', '.wind', function(e) {
	var app = $(this).attr('app');
	if (windowPhoneChecker()) {
		if ($(e.target).closest('.top_navbar').length) {
			// a phone's title-bar tap is a stack walk, handled by windowStacker
			// from the .top_navbar handler; do not also touch the pile here
			return;
		}
		// a press on a window's body lifts it to the top of the pile and restacks,
		// so a window dragged over the others' bars cannot pin them and swallow
		// their taps
		windowStacker(app, true);
		return;
	}
	topLevelNow($(this));
});

// A scroll is a touch on that window. Scrolling a window that is not at the
// front lifts it there, the same way a press does, so the window you are
// reading and scrolling takes the focus - and its taskbar tile - without a
// separate press. The front check keeps a burst of wheel events from restacking
// every tick; the phone's pile walk is left to a tap, which is what it has.
$(document).on('wheel', '.wind', function() {
	if (windowPhoneChecker()) { return; }
	var win = $(this);
	if (windowIsFront(win)) { return; }
	topLevelNow(win);
});

function windowIsFront(win) {
	var z = parseInt(win.css('z-index'), 10) || 0;
	var front = true;
	$('.wind').filter(':visible').each(function() {
		if (this !== win[0] && (parseInt($(this).css('z-index'), 10) || 0) > z) {
			front = false;
			return false;
		}
	});
	return front;
}

function topLevelNow(win) {

	if (win.length > 0) {
		if (win.find('.window_contents')) {
			$('.wind').each(function(i,v) {
				var z = numeral($(v).css('z-index')).value();
				if (z > top_level_now) {
					top_level_now = z;
				}
			});

			var now = Date.now();
			win.find('.window_contents').css({ 'z-index': top_level_now + 1 });
			win.find('.top_navbar').css({ 'z-index': top_level_now + 2 });
			// The frame ring must out-paint both of those whatever they climb to: a
			// restored window can carry a z-index past the ring's own huge default,
			// which would lift the bar over its own frame. Tracking the same base
			// keeps the ring on top; the floor keeps it above every template's
			// in-window z-index in the ordinary case, where it stays the huge value.
			win.css('--frame_z', Math.max(2147483000, top_level_now + 3));
			win.css({ 'z-index': top_level_now + 1 });
			top_level_now = (Number(top_level_now) + 1);
			win.attr('last_top', now);
		}
		else {
			top_level_now = (Number(top_level_now) + 1);
		}
		win.resizable({
			start: function(p) {
			},
			stop: function(p) { 
			}
		});
	}
	// the taskbar's window tiles wear the state: the raised one sinks
	if (typeof jawnosTaskbarPinsRefresh == 'function') { jawnosTaskbarPinsRefresh(); }
	return top_level_now;
}

var everythingMoves = {};
var forbidden = [ 'save_appointment', 'delete_app', 'edit_app_submit', 'task_admin_input', 'task_input', 'delete_task' ];
$(document).on('mousewheel touchmove click keyup change','.wind',function(e) {
	var wind = $(this);
	var app = wind.attr('app');
	var allowed = 1;
	if (!everythingMoves[app]) {
		everythingMoves[app] = { moves: [], lastTimestamp: Date.now(), timeouts: {} };
	}

	//var scroll = wind.scrollTop();
	var offset = wind.offset();
	var movement = e.type;
	var contents = wind.find('.appointment_contents');
	var appt_contents_scroll = contents.scrollTop();
	var appointment = 0;
	if (wind.find('.appointment_contents').length > 0) {
		appointment = 1;
		//scroll = appt_contents_scroll;
	}
	var scrolls = [];
	wind.find('div,span').each(function(i,v) {
   if ($(v).css('overflow') == 'scroll') {

			var sclassList = [];
			$.each($(v)[0].classList, function(i,v) {
				sclassList.push(v);
			});
			var rsclassList = '';
			$.each(sclassList, function(i,v) {
				rsclassList += '.' + v;
			});
			var height = $(v).height();
			var width = $(v).width();

			var scrollTop = $(v).scrollTop();
			var scrollPercent = scrollTop / height;
      scrolls.push({ classList: rsclassList, scrollTop: scrollTop, scrollPercent: scrollPercent });
   }
	});;
	var classList = [];
	$.each(e.target.classList, function(i,v) {
		classList.push(v);
	});
	var attributes = [];
	$.each(e.target.attributes, function(i,v) {
		if (v.name != 'style') {
			attributes.push({ attr: v.name, value: v.value } );
		}
	});
	var value = e.target.value;
	var rattributes = '';
	var rclassList = '';
	$.each(attributes, function(i,v) {
		rattributes += '[' + v['attr'] + '="' + v['value'] + '"]';
	});
	$.each(classList, function(i,v) {
		$.each(forbidden, function(ie,ve) {
			if (v == ve ) {
				allowed = 0;
			}
		});
		rclassList += '.' + v;
	});

	var data = { 
		app: app, 
		attributes: attributes, 
		classList: classList, 
		movement: movement, 
		scrolls: scrolls,
		offset: offset,
		appointment: appointment,
		value: value,
		type: 'move',
		allowed: allowed
	};
	everythingMoves[app].moves.push(data);
	if (ws[app].readyState == 1 && e.isTrigger != 3 && allowed == 1) {
		everythingMoves[app].timeouts[e.type] = setTimeout(function() {
			clearTimeout(everythingMoves[app].timeouts[e.type]);
			data = everythingMoves[app].moves[everythingMoves[app].moves.length - 1];
			everythingMoves[app].moves = [];
			var jdata = JSON.stringify(data);
			//$.each(ws, function(i,v) {
			//	if (i.match(app + '@')) {
			//		ws[i].send(jdata);
			//	}
			//});
			ws[app].send(jdata);
		},10);
	}
	var ac = wind.find('.transaction_autocomplete');
	if (ac.is(':visible')) {
		
	}
});

function selectorMaker(target,censored) {
	var classList = [];
	var allowed = 1;

	if (target != undefined) {
		$.each(target.classList, function(i,v) {
			classList.push(v);
		});
		var attributes = [];
		$.each(target.attributes, function(i,v) {
			if (v.name != 'style') {
				attributes.push({ attr: v.name, value: v.value } );
			}
		});
		var rattributes = '';
		var rclassList = '';
		$.each(attributes, function(i,v) {
			if (v['attr'] != 'class') {
				if (v['value'] != '') {
					rattributes += '[' + v['attr'] + '="' + v['value'] + '"]';
				}
				else {
					rattributes += '[' + v['attr'] + ']';
				}
			}
		});
		$.each(classList, function(i,v) {
			if (censored == 'yes') {
				$.each(forbidden, function(ie,ve) {
					if (v == ve && movement == 'click') {
						allowed = 0;
					}
				});
			}
			rclassList += '.' + v;
		});
	}
	else { return ''; }
	if (allowed == 1) {
		return rclassList + rattributes;
	}
	else {
		return '';
	}
}

function topWindow(apper) {
	var windows = [];
	var zindex = 0;
	$('.wind').each(function(i,v) {
		var app = $(v).attr('app');
		if (app != apper && $(v).css('z-index') > zindex && $(v).is(':visible')) {
			zindex = $(v).css('z-index');
			windows.push(app);
		}
	});
	return windows[windows.length - 1];
}

function topDialog() {
	var dialogs = [];
	var zindex = 0;
	$('.dialog_box').each(function(i,v) {

	});

}


$(document).on('resize', '.wind', function() { 
	var w = $(this);
	windowDimensionSetter(w);
});

function windowDimensionSetter(w) {
	var view = w.attr('view');
	if (!windowPhoneChecker() && w.length > 0) {
		var app = w.attr('app');
		var height = w.height();
		var width = w.width();
		var top = w.offset().top;
		var left = w.offset().left;
		var right = (left + width);
		var dimensions = JSON.stringify({ 'width': width, 'height': height, 'top': top, 'left': left });
		settingSetter({ 'app': app, 'setting': 'dimensions', 'value': dimensions });
		if ((width / $(window).width()) > .95) {
			w.attr('view', 'max');
		} else if (left <= 1 && (right <= ($(window).width() / 2 + 5) && right >= ($(window).width() / 2 - 5))) {
			w.attr('view', 'left');
		} else if (right > $(window).width() - 1 && (left >= ($(window).width() / 2 - 5) && left <= ($(window).width() /2 + 5))) {
			w.attr('view', 'right');
		} else { 
			w.attr('view', '');
			w.attr('free_dimensions', dimensions);
		}
	}
	if (w.attr('view') != view) {
		windowBackgroundAdjuster();
	}
}

function windowBackgroundAdjuster(data) {
	if (!data) { data = {}; }
	var background_set = $('#background, #desk_layer');
	background_set.css({ 'width': '100%', 'left': '0px' });
	$('.background').css({ 'width': '100%', 'left': '0px' });
	var leftFree = 1;
	var rightFree = 1;
	if ($('.wind[view="left"]:visible').length > 0) {
		leftFree = 0;
	}
	if ($('.wind[view="right"]:visible').length > 0) {
		rightFree = 0;
	}
	if (leftFree != rightFree) {
		var half = $(window).width() / 2;
		var layout = localStorage.getItem('layout');
		if (leftFree == 1) {
			$('#background').css({ 'width': half, 'left': '0%', 'position': 'fixed' });
			$('#desk_layer').css({ 'width': half, 'left': '0%', 'position': 'fixed' });
			$('#' + layout).css({ 'width': half, 'left': '0%', 'position': 'fixed' });
		}
		else if (rightFree == 1) {
			$('#background').css({ 'width': half, 'left': half, 'position': 'fixed' });
			$('#desk_layer').css({ 'width': half, 'left': half, 'position': 'fixed' });
			$('#' + layout).css({ 'width': half, 'left': half, 'position': 'fixed' });
		}
	}
	if (data['caller'] != 'calculator') {
		calculator();
	}
	taskbarDisplayer();
}

function windowDrawerOpener(app,content) {
	var wind = $('.wind[app="' + app + '"]');
	wind.find('.window_drawer_contents').html(content).show();
	wind.find('.window_drawer').show();
	wind.find('.window_contents').hide();
	textareaUpgrader();
}

$(document).on('click', '.window_drawer_closer', function() {
	var wind = $(this).closest('.wind');
	var app = wind.attr('app');
	windowDrawerCloser(app);
});

function windowDrawerCloser(app) {
	var wind = $('.wind[app="' + app + '"]');
	wind.find('.window_drawer').hide();
	wind.find('.window_contents').show();
}

function windowDrawerToggle(app) {

}

