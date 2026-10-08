
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

var config_appt_containers = {
	'me_setting_list': 'me_settings',
	'backup_list': 'restore_list',
	'device_list': 'device_lister',
	'system_list': 'system_setting_lister',
	'configure_appointment_list': 'appointment_list_grabber',
	'misc_setting_list': 'misc_setting',
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

function taskbarDisplayer(destination) {
	if (!destination) {
		destination = '#start_apps';
	}
	$(destination).html('');
	var html = '';
	var timestamp = Date.now();
	$('.wind').sort(function(a, b) {
    var valueA = numeral($(a).css('z-index')).value();
    var valueB = numeral($(b).css('z-index')).value();

    return valueB - valueA; }).each(function(i,v) {
		var icon = $(v).find('.window_icon');
		var formatted_name = $(v).find('.name_text').text();
		var new_icon = icon.clone();

		new_icon.attr('formatted_name', formatted_name);
		if (!new_icon.attr('src')) {
			new_icon.css({ 'font-size': '30px', 'height': '60px' });
		}
		new_icon.removeClass('window_icon');
		new_icon.addClass('window_toggle_icon little_thumb');

		html += new_icon.wrap('<span/>').parent().html();

		new_icon.show();
	});
	$('#start_apps').html(html);
	$('.window_toggle_name').remove();
	$('.window_toggle_icon').each(function(i,v) {
		var app = $(v).attr('app');
		var rand = Math.random().toString(36).substring(2);
		$(v).wrap('<span class="hover window_toggle_icon window_toggle" style="border:solid;border-radius:2px;" id="' + rand + '" app="' + app + '" style="vertical-align:top;text-align:center;"></span>');
		$('#' + rand).html($('#' + rand).html() + ' <span onclick="windowRestorer(' + timestamp + ',\'' + app + '\')">' + format_name(app) + '</span>');
	});


	appointment_chron();
}

function startMenuDisplayer(destination) {
	if (!destination) {
		destination = '#start_apps';
	}
	$(destination).html('');
	var html = '';
	$('.wind').sort(function(a, b) {
    var valueA = numeral($(a).css('z-index')).value();
    var valueB = numeral($(b).css('z-index')).value();

    return valueB - valueA; }).each(function(i,v) {
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
	var win = $('.wind[app="' + app + '"]');
	var app = $(this).attr('app');
	var topApp = topWindow();
	if (app == topApp && win.is(':visible')) {
		windowMinimizer(timestamp,app);
	} else {
		topLevelNow(win);
	}

});

function windowMaker(response) {
	if (response == '') { return; }
	var window_id = $(response).filter('.wind').attr('id');
	var window_app = $(response).filter('.wind').attr('app');
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
			if (app_attr == window_app) {
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
					if(view[window_app].wc == false) {
						$('#window_contents_' + timestamp).hide();
					}
					topLevelNow($('#' + id));
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
			websocketStart(app);
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
				var notes = localStorage.getItem(app + '_notes');
				var ago = localStorage.getItem(app + '_ago');
				var duration = localStorage.getItem(app + '_duration');
				$(val).find('.notes').val(notes);
				$(val).find('.ago').val(ago);
				$(val).find('.duration').val(duration);
			});
			transactionStorageRetriever(app);
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

function windowReorganizer(window_id) {
	var windows = [];
	var startingV = reservedSpots['header'];
	if (clothesLinePos['exists'] == 1 && windowPhoneChecker()) {
		startingV = (startingV + clothesLineHeight + clothesLinePos['bordersize']);
	}
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
			if (!windowPhoneChecker() && $('#' + window_id).attr('pre_dimensioned') != 1) {
				win.css({ 'left': winCount * 50, 'top': winCount * vSpace + startingV });
				win.show();


				if (thisWinLeft > $(window).width()) {
					winLine = winLine + 1;
					win.css({ 'top': thisWinTop + ( vSpace * winLine + startingV) });
					fullXCount = winCount
				}
				if (fullXCount * (winLine ) > winCount) {
					win.css({'left': thisWinLeft - (vSpace * winCount) + startingV});
				}
			}
			else {
				var temp_placement = ( vSpace * winCount ) + startingV;
				win.css({'top': temp_placement });

				if (temp_placement > ($(window).height() - 100)) {
					thisWinTop = Number(numeral(win.css('top')).format());
					fullYCount = winCount;
					win.css({ 'top': thisWinTop - (vSpace * fullYCount) + startingV });
				}

			}
		}
		if (win.width() > $(document).width()) {
			win.width($(document).width());
		}
		if (win.height() > $(document).height()) {
			win.height($(document).height());
		}
		var note = localStorage.getItem(app + '_note');
		var ago = localStorage.getItem(app + '_ago');
		var duration = localStorage.getItem(app + '_duration');
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
		var tnh = sessionStorage.getItem('tnh_' + timestamp);
		var tnw = sessionStorage.getItem('tnw_' + timestamp);
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
			if (localStorage.getItem(i + '_dynamic')) {
				var css = JSON.parse(localStorage.getItem(i + '_dynamic'));
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
	if (i == 'budget' || i == 'folders' || i == 'relational' || i == 'warehouse' || i == 'measures' || i == 'market' || i == 'music' || i == 'web' || i == 'handbook' || i == 'video' || i == 'security' || i == 'library' || i == 'gallery' || i == 'twirl' || i == 'store' || i == 'studio' || i == 'marker' || i == 'ide' || i == 'terminal' || i == 'travel' || i == 'mailbox' || i == 'editor' || i == 'tetris' || i == 'synth' || i == 'cards' || i == 'embedded' || i == 'terminal' || i == 'configure' || i == 'box_office' ) {
//				var preload = sessionStorage.getItem('preload_' + i);
		var scope = localStorage.getItem('scope');
		var article_uuid = localStorage.getItem('editor_article');
		var mail_contact = localStorage.getItem('mail_contact');
		var picked = JSON.stringify(mail_picker());
		if (i == 'gallery') {
			imageViewer({ 'view': 'load', 'loadImages': 1 });
		}
		else if (i == 'handbook') {
			handbookGrabber(localStorage.getItem('handbook_chapter'), localStorage.getItem('handbook_page'));
		}
		else if (i == 'embedded') {
			embeddedDevicesOpener();
		}
		else if (i == 'mailbox') {
			mailMaker();
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
					if (v.top > 0 && v.left < window_w && v.top < window_h && v.left > 0) {
						window.css({ 'top': v.top, 'left': v.left, 'height': v.height, 'width': v.width, 'z-index': v.zindex });
						if (numeral(v.zindex).value() > top_level_now) {
							top_level_now = numeral(v.zindex).value();
						}
					}

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

				if (v.top > 0 && v.left < window_w && v.top < window_h && v.left > 0) {
					window.css({ 'top': v.top, 'left': v.left, 'height': v.height, 'width': v.width, 'z-index': v.zindex });
				}

				if (refresh_jopen) {
					windowjOpener(window, { jopen: refresh_jopen, scrollTop: v.scrollTop });
				}
				if (v.current_information) {
					budgetLight(v.app,v['current_information'],'open');
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

		sessionStorage.setItem('tnh_' + timestamp,tnh);
		sessionStorage.setItem('tnw_' + timestamp,tnw);

	} else { 
		$('#window_contents_' + timestamp).show();
		if (windowPhoneChecker()) { 
			$('#window_contents_' + timestamp).css({'overflow': 'scroll'});
		}

		var tnh = sessionStorage.getItem('tnh_' + timestamp);
		var tnw = sessionStorage.getItem('tnw_' + timestamp);
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
		var ok = reservedSpots['header'] + 2;
		var ww = $(window).width();
		var height = $(window).height() - headerHeight - $('#search').height() - 10;
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
	if (windowPhoneChecker()) {
		win.css({ 
			'position':'fixed', 
			'height': '80%', 
			'width': '98%',
			'left': '0px',
			'top': reservedSpots['header']
		});
	}
	else {
		win.css({ 
			'position':'fixed', 
			'height': '90%', 
			'width': '100%',
			'left': '0px',
			'top': reservedSpots['header']
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
				else if (d.y < reservedSpots['header'] + 10) {
					var ok = reservedSpots['header'];
					if (clothesLinePos['exists'] == 1 && windowPhoneChecker()) {
						ok = (ok + clothesLineHeight + clothesLinePos['bordersize']);
					}
					var point = document.elementFromPoint(d.x, d.y) || 'null';
					var pd = $('#' + p.target.id).closest('.wind');
					
					pd.css({ 'top': ok });
				}
				else if (now - windows[p.target.id] < 250) {
					var point = document.elementFromPoint(d.x, d.y) || 'null';

					var wc = $('#window_contents_' + timestamp);
					wc.show();

					var tnh = sessionStorage.getItem('tnh_' + timestamp);
					var tnw = sessionStorage.getItem('tnw_' + timestamp);

					$('#window_' + timestamp).css({'height': tnh, 'width': tnw });
				}
				markerDragger(p.target.id,'stop');
				windowDimensionSetter($('#' + p.target.id));
			}
		});
		setTimeout(function() {
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
    // click from landing on whatever sits underneath it
    jawnosSuppressClick();
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
  
	windowRestore(timestamp,app);
});

$(document).on('click touchend', '.minimize_button', function(e) {
  // Prevent the event from bubbling up to the draggable container
  e.stopPropagation();
  e.preventDefault();
  
  // Retrieve the variables from data attributes
  var app = $(this).attr('app');
  var timestamp = $(this).attr('timestamp');
  
	windowMinimizer(timestamp,app);
});


function windowPhoneChecker() {
	if (navigator.userAgent.match('Android') || navigator.userAgent.match('Mobile')) {
		if ($(window).width() < 500) {
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

function windowStacker() {
	var json_storage = sessionStorage.getItem('window_storage');
	var storage = JSON.parse(json_storage) ? JSON.parse(json_storage) : {};
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
		data: { timestamp: timestamp, app: app },
		success: function(response) {
			websocketStop(app);
		}
	});
	windowSaver();
	startMenuDisplayer();
	windowBackgroundAdjuster();
}

$(document).on('click', '.wind', function() {
	var app = $(this).attr('app');
	topLevelNow($(this));
});

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
	$('#background').css({ 'width': '100%', 'left': '0px' });
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
			$('#' + layout).css({ 'width': half, 'left': '0%', 'position': 'fixed' });
		}
		else if (rightFree == 1) {
			$('#background').css({ 'width': half, 'left': half, 'position': 'fixed' });
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

