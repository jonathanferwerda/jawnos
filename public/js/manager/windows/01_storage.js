


// windowSaver(1) is the heartbeat's copy: the beat tells the server where the
// windows are, and appActSync() tells it, in a frame of its own, which panels
// are open. Leaving jopen out is what keeps a panel toggle from re-sending the
// whole layout.
function windowSaver(skip_act) {

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
			// Configure scrolls inside its own #configure panel, not in an element
			// named for the window timestamp, so read the offset from the panel that
			// actually moves (and hand it back through jopen).
			scrollTop = (app == 'configure') ? $('#configure').scrollTop() : $('#' + timestamp).scrollTop();
		}
		var wc = $('#window_contents_' + timestamp).is(':visible');
		var tnh = jawnosWindowSizeGet(timestamp, 'h');
		var tnw = jawnosWindowSizeGet(timestamp, 'w');
		var jopen = skip_act ? undefined : windowjOpenSaver($(v));
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
			terminal_id: $(v).attr('data-terminal-id') || '',
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
			appWindowLoader(i,v);
		}
		else if (v.type == 'keyboard') {
			// the old floating keyboard and calculator panels are retired; their
			// saved windows now open the docked on-screen keyboard instead
			if (i == 'keyboard' || i == 'calculator') { return; }
			
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
	appWindowOpener(i, jawnosWindowTimestamp(), v);
}

// Load (or reload) a window the right way for its app: some apps have bespoke
// openers, everything else falls back to the centre view. Shared by
// windowRetriever (restoring saved windows) and the icon-set refresh.
//
// The app's own scripts are a lazy chunk now; wait for them before the window
// opener calls an init function (pianoInit, studioInit, travelViewer, ...).
function appWindowOpener(i,timestamp,v) {
	if (!i) {
		return;
	}
	timestamp = jawnosWindowTimestamp(timestamp);
	if (typeof jawnosLoadApp === 'function') {
		jawnosLoadApp(i, function () { appWindowOpenerNow(i, timestamp, v); });
		return;
	}
	appWindowOpenerNow(i, timestamp, v);
}

function appWindowOpenerNow(i,timestamp,v) {
	if (!i) {
		return;
	}
	v = v || {};
	timestamp = timestamp || jawnosWindowTimestamp();
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
			// the saved id is what rejoins the coding chat and the pty; '' mints a
			// fresh one for a brand-new window
			terminalOpener({ 'window_maker': 'yes', 'terminal_id': (v && v.terminal_id) || '' });
		}
		else if (i == 'folders') {
			foldersOpener();
		}
		// Process Monitor is an app, not an appointment: a refresh restores the
		// window through its own route instead of opening a centre view.
		else if (i == 'process_monitor') {
			monitorOpener();
		}
		// Weather is a shell until its opener asks for a reading; a restore that
		// took the generic path left it blank. Its own opener is the one path.
		else if (i == 'weather') {
			if (typeof weatherMaker === 'function') { weatherMaker(timestamp); }
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
					if (typeof budgetLight === 'function') { budgetLight(i,v['current_information'],'open'); }
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
		// The panel is tall and the reader may be deep in it; the offset rides
		// with the open panel so a re-render (a theme's icon set, say) can put
		// them back where they were.
		var configure_scroller = window.find('#configure');
		jopen[app]['scroll'] = configure_scroller.length ? (configure_scroller.scrollTop() || 0) : 0;
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
				if (app == 'configure') {
					// the saved offset is the panel's own; restore it once the saved tab
					// has drawn, and keep the bar visible for the jump
					var at = (state.scroll != null) ? state.scroll : v.scrollTop;
					if (typeof jawnosConfigureScrollRestore === 'function') {
						jawnosConfigureScrollRestore(at || 0);
					}
					else {
						window.find('#configure').scrollTop(at || 0);
					}
				}
				else if (window.attr('scrollTop') != undefined) {
					var scrollTop = window.attr('scrollTop');
					$('#' + (window.attr('timestamp') || 'hey')).scrollTop(scrollTop);
				}
				else {
					$('#' + (window.attr('timestamp') || 'hey')).scrollTop(v.scrollTop);
				}
				windowSaver();
				appActSync(window);
			}
			clearInterval(windowjOpenerTimers[app]);
			windowjOpenerTimers[app] = null;
			windowjOpenerStatus[app] = 'done';
		}
	}, 300);
}


