var ws = {};
var remote_ws = {};
var heartbeat = {};
var stayingAliveInterval = 2000;
// The tab socket re-sends the (relatively costly) window layout on this cadence
// even when nothing moved, and the localStorage debrief far more rarely.
var windowResendInterval = 60000;
var debrieferInterval = 300000;
var windowWsWindows = '';
var windowWsDebriefer = 0;
var windowVisible = 1;
var dotTimeout = {};
var seenWsMessages = [];
$(document).ready(function() {
	websocketStart();
});

function wsStatusChecker() {
	var timestamp = Date.now();
	$.each(ws, function(i,v) {
		if (windowVisible == 1 && ( ws[i]['status'] == 'alive' || ws[i]['status'] == 'connect' || ws[i]['status'] == 'open' )) {
			if (ws[i]['stayingAlive'] && timestamp > (ws[i]['stayingAlive'] + (stayingAliveInterval * 2))) {
				clearInterval(heartbeat[i]);
				websocketStop(i);
			}
		}
	});
}

var wsStatusInterval = setInterval(wsStatusChecker, 3000);

// Timers are what chew through phone batteries. When the page isn't visible
// there is nothing to animate or report, so stop the heartbeats and the status
// check entirely and only restart them once we're back.
document.addEventListener('visibilitychange', function() {
	if (document.hidden) {
		windowVisible = 0;
		clearInterval(wsStatusInterval);
		wsStatusInterval = null;
		Object.keys(heartbeat).forEach(function(app) {
			clearInterval(heartbeat[app]);
			delete heartbeat[app];
		});
		Object.keys(heartbeating).forEach(function(app) {
			clearInterval(heartbeating[app]);
			delete heartbeating[app];
		});
		clearTimeout(heartbeater);
	}
	else {
		windowVisible = 1;
		if (!wsStatusInterval) { wsStatusInterval = setInterval(wsStatusChecker, 3000); }
		$.each(ws, function(app, socket) {
			if (socket && ( socket.readyState == 1 || socket['status'] == 'alive' || socket['status'] == 'open' )) {
				heartbeatStart(app);
			}
		});
	}
});

function websocketStart(appt,address) {

	var timestamp = Date.now();
	var wappts = ['server','tab','music'];
	var origin = 'self';
	if (appt != undefined) {
	//	wappts.push(appt);
		wappts = [appt];
	}
	$('.wind').each(function(i,v) {
		var seen = 0;
		$.each(wappts, function(ie,ve) {
			if ($(v).attr('app') == ve) {
				seen = 1;
			}
		});
		if (seen == 0) {
			wappts.push($(v).attr('app'));
		}
	});
	var devices = {};
	var uA = navigator.userAgent;
	var browser_tab_id = bti || sessionStorage.getItem('browser_tab_id') ? sessionStorage.getItem('browser_tab_id') : '';
	var browser_tab = localStorage.getItem('browser_tab') ? localStorage.getItem('browser_tab') : '';
	$.each(wappts, function(i,app) {

		if ((ws[app] && ws[app] != null && ws[app].readyState == 1) || (ws[app] && ws[app]['status'] != 'alive')) {  return true; }
		ws[app] = { readyState: 4, stayingAlive: 1 };
		var http_escaped = encodeURIComponent(app);
		ws[app] = new WebSocket(address || ws_url + '?timestamp=' + timestamp + '&app=' + app + '&browser_tab_id=' + browser_tab_id + '&browser_tab=' + browser_tab + '&user_agent=' + uA );
		ws[app]['stayingAlive'] = Date.now();
		ws[app]['status'] = 'connect';
		ws[app].onopen = function (event) {
			wsOpener(event,app,origin);
		};
		ws[app].onmessage = function (event) {
			wsMessageHandler(event);
		};
		ws[app].onclose = function(event){
			if (app == 'server' && ws[i] != null) { ws['server'].send({ type: 'lock_screen', browser_tab_id: bti }); }

		}
	});
}

var windowWsMouseMove = {}
function wsOpener(event,app,origin) {
	var browser_tab_id = sessionStorage.getItem('browser_tab_id');
	var browser_tab = localStorage.getItem('browser_tab');
	var uA = navigator.userAgent;
	ws[app]['status'] = 'open';
	var data = JSON.stringify({ 
		browser_tab_id: browser_tab_id,
		browser_tab: browser_tab,
		timestamp: timestamp,
		app: app,
		from: uA,
		type: 'begin',
		href: window.location.href,
		pathname: window.location.pathname,
	});
	if (browser_tab_id && ws[app].readyState != 3) {
		ws[app].send(data);
	}
	var closer = $('.close_appointment[app="' + app + '"]');
	closer.css({'background-color':'green'});
	heartbeatStart(app);
}

// (Re)start the liveness heartbeat for one socket. Called when a socket opens
// and again when the page becomes visible after being hidden.
function heartbeatStart(app) {
	clearInterval(heartbeat[app]);
	heartbeat[app] = window.setInterval(function () {
		var apper = app.split('@')[0];
		var now = Date.now();
		var browser_tab_id = sessionStorage.getItem('browser_tab_id') || '';
		var browser_tab = localStorage.getItem('browser_tab') || '';
		var uA = navigator.userAgent;
		if (!ws[app]) { clearInterval(heartbeat[app]); websocketStop(app); return; }
		ws[app]['status'] = 'alive';
		if (!document.hidden) {
			var data = {
				browser_tab_id: browser_tab_id,
				browser_tab: browser_tab,
				timestamp: now,
				app: app,
				from: uA,
				type: 'stayingAlive',
				href: window.location.href,
				pathname: window.location.pathname
			};

			if (app == 'tab' || apper == 'tab') {
				var mm = mouse_position();
				if ((mm['x'] != windowWsMouseMove['x'] && mm['y'] != windowWsMouseMove['y']) || ( mm['lastTs'] < now - windowResendInterval)) {
					var windows_json = windowSaver();
					// only ship the layout when it actually changed
					if (windows_json != windowWsWindows) {
						windowWsWindows = windows_json;
						data['windows'] = windows_json;
					}
					windowWsMouseMove = mm;
				}
				// the localStorage debrief is for auditing, not for liveness
				if (now - windowWsDebriefer > debrieferInterval) {
					windowWsDebriefer = now;
					data['debriefer'] = JSON.stringify(localStorage);
				}
			}
			else if ((app == 'music' || apper == 'music') && tree['music_data'] != undefined) {
				tree['music_data'] = musicAppointmentWriter('data_entry');
				data['music_data'] = tree['music_data']
			}
			else if ((app == 'server' || apper == 'server')) {
				data['ws'] = [];
				$.each(ws, function(i,v) {
					data['ws'].push(i);
				});
				if (advertise_watching == 'on') {
					data['jp_data'] = jpWatcher();
				}
				if ($('#controller').is(':visible')) {
					data['controller_visible'] = 'yes';
				}
				if (errorInfo.length > 0) {
					var errors = JSON.stringify(errorInfo);
					$.ajax({
						url: '/manager/terminal/error_report',
						type: 'POST',
						data: { errors: errors },
						success: function(response) {
							errorInto = [];
						}
					});
				}
			}
			var json_data = JSON.stringify(data);
			if (ws[app] && ws[app] != null && ws[app]['readyState'] == 1) {
				ws[app].send(json_data);
			}
			else {
				websocketStop(app);
				delete heartbeat[app];
				websocketStart();
			}
		}
	}, stayingAliveInterval);
}

function wsMessageHandler(event) {
	if (isJson(event.data)) {
		var data = JSON.parse(event.data);
		var seenWs = $.grep(seenWsMessages, function(t,i) { return i.uuid == data.uuid });
		if (seenWs.length > 0) {
			return;
		}
		seenWsMessages.shift({ uuid: data.uuid });
		if (seenWsMessages.length > 10) {
			seenWsMessages.splice(10);
		}
		if (data['type'] == 'notification') {
			var notification = new Notification(data['title'], { icon: data['icon'], body: data['message'] });
			if ($('#notifications').is(':visible')) {
				$('#notifications').prepend(data['html']);
				appointment_chron();
			}
		}
		else if (data['type'] == 'stayingAlive') {
			var scrollT = $('#controller').scrollTop();
			var scrollL = $('#controller').scrollLeft();
			stayingAlive(data);
			$('#controller').scrollTop(scrollT);
			$('#controller').scrollLeft(scrollL);
		}
		if ( data['padlock'] ) {
			var height = numeral($(window).height()).format('0.00');
			var width = numeral($(window).width()).format('0.00');
			if ($('#everything').is(':visible')) {
				var pf = $('#padlock_frame');
				pf.html(data['padlock']);


				pf.css({'position': 'fixed','z-index': 60000, 'background-color': '#' + data['colour'] }).show();
				var pff = pf.find('.padlock_frame');
				pff.css({ 'height': '100%' });
				var pwidth = numeral(pff.width()).format('0.00');
				var pheight = numeral(pff.height()).format('0.00');
				var left = width / 2 - pwidth / 2;
				var bottom = height / 2 - pheight / 2;
				left = left + 'px';
				bottom = bottom + 'px';
				pff.css({ 'left': left, bottom: '10%' });
			}
			else {
				$('#padlock_frame').css({'background-color': '#' + data['colour'] }).show();
				$('#padlock_taunts').text(data['taunts']).css({ 'position':'fixed','max-width': width + 'px', 'width':'100%', 'height': '40%', 'left': '0px', 'top': '1%', 'text-align': 'centre', 'width': '120%'});
			}
			$('#everything').hide();

		//	websocketStop();
		}
		else if ( data['console'] ) {
			if (data['view'] == 'errors') {
				var tv = $('#terminal_error_view');
				tv.append('<span class="terminal_error" style="color:blue;"><b>' + data['whoami'] + '@' + data['hostname'] + ':</b></span> ' + data['console']['code'] + ' ' + data['console']['msg'] + '<br>');
				tv.scrollTop(tv.height() * 4000);
			}
			else if (data['view'] == 'log') {
				var tv = $('#terminal_log_view');
				tv.append('<span class="terminal_log" style="color:blue;"><b>' + data['whoami'] + '@' + data['hostname'] + ':</b></span> ' + data['console']['msg'] + '<br>');
				tv.scrollTop(tv.height() * 4000);
			}
			else {
				var returns = eval(data['console']);
				if (!returns instanceof jQuery && (Array.isArray(returns) || Object.keys(returns).length > 0)) {
					returns = JSON.stringify(returns);
				}
			
				var tv = $('#terminal_view');
				tv.append('<span style="color:blue;"><b>' + data['whoami'] + '@' + data['hostname'] + ':</b></span> ' + data['console'] + '<br>' + returns + '<br>');
				tv.scrollTop(tv.height() * 4000);
				appointment_chron()
			}
		}
		else if (data['terminal']) {
			console.log(data);
			terminalDataReceiver(data);
		}
		else if ( data['utility_controller'] ) {
			
			if (!$(document.activeElement).is('.utility_controller') && $('#utility_controls').is(':visible')) {
				utilityControllerReloader();
			}
		}
		else if ( data['type'] == 'command' ) {
			if (data['return']) {
				data['return'] = data['return'].replace(/(?:\r\n|\r|\n)/g, '<br>');
				var tv = $('#terminal_view');
				tv.append('<span style="color:red;"><b>' + data['whoami'] + '@' + data['hostname'] + ':</b></span> ' + data['command'] + '<br>' + data['return'] + '<br>');
				tv.scrollTop(tv.height() * 4000);
			}
		}
		else if ( data['type'] == 'append' ) {
			var s = $(data['selector']);
			var current_height = s.height();
			s.append(data['content']);
			var new_height = s.height();
		//	s.scrollTop(s.height() + current_height);
		}
		else if ( data['type'] == 'replaceWith' ) {
			var s = $(data['selector']);
			s.replaceWith($(data['content']).clone());
			appointment_chron()
		}
		else if ( data['type'] == 'mailbox_message' ) {
			var s = $(data['selector']);
			s.replaceWith($(data['content']).clone());
			appointment_chron()
			mailScrollBottom();
		}
		else if ( data['type'] == 'html' ) {
			var s = $(data['selector']);
			s.html(data['content']);
			appointment_chron();
		}
		else if ( data['type'] == 'gallery_images' ) {

			var count = 0;
			for (var n = data['last_send']; n <= data['total_files']; n++) {

				images[n] = data['images'][count];
				count++;
			}
			if (typeof galleryTargetUuid !== 'undefined' && galleryTargetUuid != '') {
				var chosen = -1;
				for (var n = 0; n < images.length; n++) {
					if (images[n] && images[n]['uuid'] == galleryTargetUuid) { chosen = n; break; }
				}
				if (chosen > -1) {
					image_number = chosen;
					galleryTargetUuid = '';
					imageDiscover();
				}
				else {
					var target = data['count'];
					if (images[target]) {
						image_number = target;
						imageDiscover();
					}
				}
			}
			else {
				var target = data['count'];
				if (images[target]) {
					image_number = target;
					imageDiscover();
				}
			}
		}
		else if ( data['alert'] ) {

			if ((!$('#alert').attr('uuid') || $('#alert').attr('uuid') == data['uuid']) && $('#alert').attr('hidden') != 'yes') {
				$('#alert').html(data['alert']).show();
			}
			$('#alert').attr('uuid', data['uuid']);
			if (data['close'] == 'yes') { 
				$('#alert').hide();

				$('#alert').attr('uuid', undefined);
				$('#alert').attr('hidden', undefined);
			}
		}
		else if ( data['red'] ) {
			clearTimeout(dotTimeout['red']);
			$('#red_dot').show();
			$('#red_dot').find('.dot_info').html(data['red']);
			if (data['close'] == 'yes') { 
				$('#red_dot').hide();
			}
			dotTimeout['red'] = setTimeout(function() { $('#red_dot').hide(); }, 10000);
		}
		else if ( data['yellow'] ) {
			clearTimeout(dotTimeout['yellow']);
			$('#yellow_dot').show();
			var info = $('#yellow_dot').find('.dot_info');
			if (data['colour']) {
				info.css({'background-color': data['colour'] });
			}
			else {
				info.css({'background-color': 'white' });
			}
			info.html(data['yellow']);
			if (data['close'] == 'yes') { 
				$('#yellow_dot').hide();
			}
			dotTimeout['yellow'] = setTimeout(function() { $('#yellow_dot').hide(); }, 20000);
		}
		else if ( data['green'] ) {
			clearTimeout(dotTimeout['green']);
			$('#green_dot').show();
			$('#green_dot').find('.dot_info').html(data['green']);
			if (data['close'] == 'yes') { 
				$('#green_dot').hide();
			}
			dotTimeout['green'] = setTimeout(function() { $('#green_dot').hide(); }, 10000);
		}
		else if ( data['key'] ) {
			typing(data['key'],data['toggle']);
		}
		else if (data['id']) {
			$('#' + data['id']).html(data['html']);
		}
		else if (data['magic_wand']) {
			if (data['action'] == 'closed') {
				$('.magic_wand[destination="' + data['magic_wand'] + '"').remove();
			}
			if (data['action'] == 'open') {
				$('.magic_wands.keyboard_cauldron').append('<img destination="' + data['magic_wand'] + '" class="keyboard_destination magic_wand tiny_thumb" style="background-color:navy;" src="/images/make believe/key.png">');
			}
		}
		else if (data['textAreaMagic']) {
			var d = data['textAreaMagic'];
			var ta = $('#' + d.id);
			if (d.plain) {
				// a plain field (the compose subject) takes the words back as
				// text: there are no spans for it to wear
				ta.val(d.text);
				ta.trigger('change');
			}
			else {
				ta.html(d.text);
				// whatever reads the hidden textarea behind the editor keeps up with
				// what was eaten
				var source = $('#' + ta.attr('source_id'));
				if (source.length) { source.val(ta.text()); }
				// and whatever saves on change hears about the eaten words too
				ta.trigger('change');
				// the server names the spans it wrote, so the caret can be put after
				// the last of them instead of guessing where the word used to be
				if (d.token) {
					var eaten = ta.find('span[te_token="' + d.token + '"]').last()[0];
					if (eaten) {
						var range = document.createRange();
						range.setStartAfter(eaten);
						range.collapse(true);
						var sel = window.getSelection();
						ta.focus();
						sel.removeAllRanges();
						sel.addRange(range);
					}
				}
			}
		}
		if (data['appts']) {

			var remote_appts = JSON.parse(data['appts']);

			var dappts = remote_appts['appts'];
			appts = { ...appts, ...dappts };
		}


		if (data['type'] == 'remote_control') {
			if (data['value'] && data['value'] != '') {
				if (data['control'] == 'progress_bar') {
					var seek_to = data['value'] * tree.sound.duration;
					tree.sound.currentTime = seek_to;
				}
				else if (data['control'] == 'volume_control') {
					var new_volume = data['value'];
					tree.sound.volume = new_volume;
					$('#volume_control').attr('value', new_volume);
				}
				else {
					$('#' + data['control']).val(data['value']);
				}							
			}
			else {
				$('#' + data['control']).trigger('click');
			}
		}

		if ( data['type'] == 'connect' ) {
		//	appointmentDetailsUpdater(app);
		}
		else if (data['window']) {
			windowMaker(data['window']);
			appointment_chron();
		}
		else if ( data['type'] == 'header' ) {
			var header = $('.wind[app="' + data['app'] + '"]').find('.appointment_header_background');
			var blci = $('.budget_current_information[app="' + data['app'] + '"]');
			var status = blci.attr('status');
			header.replaceWith('' + data['header'] + '');
			var now = data['timestamp'];
			header = $('.wind[app="' + data['app'] + '"]').find('.appointment_header_background');
			header.attr('last_updated', now);
			var circumstance = blci.attr('circumstance');
			if (circumstance && blci.is(':visible')) {
				budgetLight(data['app'],circumstance,'open');
			}
			appointment_chron()
		}
		else if ( data['type'] == 'budget' ) {
			var blci = $('.budget_current_information[app="' + data['app'] + '"]');
			var circumstance = blci.attr('circumstance');
			$('.budget_light[app="' + data['app'] + '"][circumstance="' + data['budget']['circumstance'] + '"]').css({ 'background-color': data['budget']['colour'] });
			if (circumstance && blci.is(':visible')) {
				budgetLight(data['app'],circumstance,'open');
			}
			appointment_chron()
		}
		else if (data['type'] == 'transmitter') {
			var timestamp = Date.now();
			//tree.sound.currentTime = numeral(data['seek']).value() + ((timestamp - data['timestamp']) / 1000);
			if (mao['me'] == 'on') {
				tree.sound.volume = master_volume;
			}
		}
		else if (data['command'] == 'mouse') {
			var i = $('#mouse_pointer');
			if (!i.is(':visible')) {
				i.show();
				var w = $(window).width() / 2;
				var h = $(window).height() / 2;
				i.offset({ 'left': w, 'top': h });
			}
			var inc = 14;
			var offset = i.offset();
			if (data['movement'] == 'left') {
				var mov = offset['left'] - inc;
				i.offset({ 'left': mov });
			}
			else if (data['movement'] == 'right') {
				var mov = offset['left'] + inc;
				i.offset({ 'left': mov });
			}
			else if (data['movement'] == 'up') {
				var mov = offset['top'] - inc;
				i.offset({ 'top': mov });
			}
			else if (data['movement'] == 'down') {
				var mov = offset['top'] + inc;
				i.offset({ 'top': mov });
			}
			else if (data['movement'] == 'button') {
				var elements = document.elementsFromPoint(offset['left'], offset['top']);
				var top_now = 0;
				var trigger_element;
				$.each(elements, function(n,val) {
					var z = $(val).css('z-index');
					if (Number(z) > top_now && $(val).attr('id') != 'mouse_pointer') {
						trigger_element = val;
						top_now = $(val).css('z-index');
					}
				});
				$(trigger_element).trigger('click');
			}
		}
		else if (data['command'] == 'touch') {
			var i = $('#mouse_pointer');
			if (!i.is(':visible')) {
				i.show();
				var w = $(window).width() / 2;
				var h = $(window).height() / 2;
				i.offset({ 'left': w, 'top': h });
			}
			var resolution_x = data['resolution_x'];
			var resolution_y = data['resolution_y'];
			var x = data['y'];
			var y = resolution_y - data['x'];
			var screen_x = $(window).width();
			var screen_y = $(window).height();
			x = (screen_x / resolution_x) * x;
			y = (screen_y / resolution_y) * y;
			$('#mouse_pointer').offset({ 'top': y, 'left': x });
		}
		else if (data['type'] == 'move') {
			var allowed = 1;
			var attributes = '';
			var classList = '';
			$.each(data['attributes'], function(i,v) {
				attributes += '[' + v['attr'] + '="' + v['value'] + '"]';
			});
			$.each(data['classList'], function(i,v) {
				classList += '.' + v;
				$.each(forbidden, function(ie,ve) {
					if (v == ve ) {
						allowed = 0;
					}
				});
			});
			$.each(data['scrolls'], function(i,v) {
				var dom = $('.wind[app="' + data['app'] + '"]').find( v.classList );
				 	
				dom.scrollTop(v.scrollTop);
			});
			if (allowed == 1) {
				$(classList + attributes).trigger(data['movement']);
				$(classList + attributes).val(data['value']);
			}
		}
	}
}

var heartbeater;
var heartbeating = {};
function stayingAlive(data) {
	var now = Date.now();

	ws[data.app]['stayingAlive'] = now;
	var closer = $('.close_appointment[app="' + data.app + '"]');
	var neighbours = $('.neighbours[app="' + data.app + '"]');
	neighbours.find('.neighbour').each((i,n) => { n.remove() });
	clearTimeout(heartbeater);
	clearInterval(heartbeating[data.app]);
	$('#controller_toggle').css({'transform': 'transform 0.25s ease scale(1.1)', '-webkit-transform':'scale(1.1)' });
	$('.heartbeating[app="' + data.app + '"]').css({'transform': 'transform 0.25s ease scale(1.1)', '-webkit-transform':'scale(1.1)' });
	// this was a 200ms interval that kept running until the next heartbeat (or
	// forever if heartbeats stopped) - a single timeout is all the pulse needs
	heartbeater = setTimeout(function() {
		$('#controller_toggle').css({'transform': 'transform 0.25s ease scale(1.0)', '-webkit-transform':'scale(1.0)' });
		$('.heartbeating[app="' + data.app + '"]').css({'transform': 'transform 0.25s ease scale(1.0)', '-webkit-transform':'scale(1.0)' });
	},250);
	data.neighbours = data.neighbours.sort((a, b) => a.browser_tab_id.localeCompare(b.browser_tab_id));
	if ($('#controller').is(':visible')) {
		$.each(data.neighbours, function(i,n) {

			var neighbour = neighbours.find('.neighbour[browser_tab_id="' + n['browser_tab_id'] + '"]');
			if (neighbour.length > 0) {
				var neighbour_check = $.grep(data.neighbours, function(t,it) { return n.browser_tab_id == t.browser_tab_id });

				if (neighbour_check.length != 0 ) { 
					// remove
					$.each(neighbour, function(u,m) { $('.neighbour[browser_tab_id="' + n.browser_tab_id + '"').remove() }); 
				}
				else {
					var neighbour = neighbours.find('.neighbour[browser_tab_id="' + n['browser_tab_id'] + '"]');
					$.each(neighbour,function(i,v) { 
						$(v).css({'background-color': 'green'}); 
					});
				}

			}
			else {
				var windows = JSON.parse(n.windows) ? JSON.parse(n.windows) : {};
				var neighbour_windows = '';
				$('#musicData').html('');
				if (data['app'] == 'tab') {
					neighbour_windows += '<img class="little_thumb neighbour_link" bti="' + n.browser_tab_id + '" src="/images/make believe/clover.png">';
					neighbour_windows += '<img class="little_thumb neighbour_refresh" bti="' + n.browser_tab_id + '" src="/icons/lymeboard/star.png">';

					$.each(windows, function(item,value) {
						if (value.type == 'window') {
							neighbour_windows += ' <button onClick="appointmentGrabber(\'' + value['app'] + '\',\'' + now + '\')" class="neighbour_window" style="border: solid; border-radius:12px; font-size:21px; padding-top:2px;" app="' + 
								item + '" shorthand="' + value['shorthand_name'] + '" formatted_name="' + value['formatted_name'] + '">' + value['shorthand_name'] + 
								'</button>';
						}
						$('#musicData').append(value['shorthand_name']);
					});
					neighbours.append('<span style="word-break:break-word;" browser_tab_id="' + n.browser_tab_id + '" local_address="' + n.local_address + '"' +
						'remote_address="' + n.remote_address + '" class="neighbour"  style="height: 30px; overflow:scroll;" >' +
						'<div><b>' + n.room +'<b></div><br>' + n.pathname + '<br><i>' + n.remote_address + '</i> on ' + n.local_address + '<br><b>' + n.user_agent + '</b><br>' +
						'<span class="neighbour_windows">' + neighbour_windows + '</span></span>'
					);
				}

				else if (data['app'] == 'music') {

					if ( n.music_data != undefined) {
						var md = JSON.parse(n.music_data) ? JSON.parse(n.music_data) : {};
						var height = 200;
						var width = height * md.title.ratio;
						var vidya = '';
						if (md.title.image) {
							vidya = '<img class="video_preview" width="' + width + '" height="' + height + '" style="border:2px;border-radius:12px;" file="' + md.file + '" current_time="' + md.current_time + '" src="' + md.title.image + '">';
						}
						var volume = 1;
						if (md.interface) {
							volume = $(md.interface).find('#volume_control').val();
						}
						neighbours.append('<span style="" class="neighbour" browser_tab_id="' + n.browser_tab_id + '">' +
						'<br><span class="media_controls">' + 
						'<img class="little_thumb remote_media_control" control="prev" browser_tab_id="' + n.browser_tab_id + '" src="/icons/prev.jpg">' +
						'<img class="little_thumb remote_media_control" control="play" browser_tab_id="' + n.browser_tab_id + '" src="/icons/play.jpg">' +
						'<img class="little_thumb remote_media_control" control="next" browser_tab_id="' + n.browser_tab_id + '" src="/icons/next.jpg"><br>' + vidya + '<br>' +
							'<progress style="width:100%;height:30px;" value="' + md.currentTime + '" control="progress_bar" class="remote_media_control" data-label="Progress" max="' + md.total_time + '"></progress><br>' +
							'<progress style="width:100%;height:30px;" class="remote_media_control" control="volume_control" value="' + volume + '" data-label="Volume"></progress>' +
							'</span><br>' +
							md.title.artist + '<br>' + md.title.album + '<br>' + md.title.song + '<br>' + 
							numeral(md.currentTime).format('00:00:00') + '/' + numeral(Math.abs(md.total_time)).format('00:00:00') + 
							'<br><div class="track_item_preview" style="display:none;">' + md.title.playing + '</div></span>'
						);
					}
				}
				else if (data['app'] == 'server') {
					var jd = JSON.parse(n.jp_data) ? JSON.parse(n.jp_data) : {};
					$.each(jd, function(ji,jv) {
						var height = 200;
						var width = height * jd.ratio;
						neighbours.append('<span class="neighbour" browser_tab_id="' + n.browser_tab_id + '"><br>' +
							'<img class="jp_preview video_preview" style="border:2px;border-radius:12px;" height="' + height + '" width="' + width + '" src="' + jv.image + '">' +
							'</span>'
						);
					});
					if (data['template']) { 
						if (data['template'] != $('.server_neighbour[browser_tab_id="' + n.browser_tab_id + '"]').html() ) {
							neighbours.append(data['template']); 
						}
					}

				}
				else if (data['app'] == 'mail') {
					neihbbours.append('mail');
				}
				else {
					var everything = [];
					var seen = 0;
					$('#everything_socket').find('button').each(function(i,v) {
						if ($(v).attr('app') == data.app) {
							seen = 1;
						}
					});
					if (data['template']) {
						if (seen == 0) {
							$('#everything_socket').append('<span style="" status="active" app="' + data.app + '" class="everything_neighbour neighbour">' + 
								data['template'] + 
								'</span><br><button onClick="appointmentGrabber(\'' + data.app + '\',\'' + now + '\')" class="heartbeating everything" timestamp="' + now + '" app="' + data.app + '">' + format_name(data.app) + '</button>'
							);
						}
						else if (seen == 1) {
							$('#everything_socket').find('.heartbeating.everything[app="' + data.app + '"]').attr('timestamp', now);
							$('#everything_socket').find('.everything_neighbour[app="' + data.app + '"]').html(data['template']);
						}
					}
					else {
						if (seen == 0) {
							$('#everything_socket').append('<button onClick="appointmentGrabber(\'' + data.app + '\',\'' + now + '\')" class="heartbeating everything" timestamp="' + now + '" app="' + data.app + '">' + format_name(data.app) + '</button>');
						}
						else if (seen == 1) {
							$('#everything_socket').find('.heartbeating.everything[app="' + data.app + '"]').attr('timestamp', now);
						}
					}
				}
			}
		});

		heartbeating[data.app] = setInterval(function() {
			var beating = $('.heartbeating[app="' + data.app + '"]');
			// nothing left to animate - stop ticking
			if (beating.length == 0) { clearInterval(heartbeating[data.app]); delete heartbeating[data.app]; return; }
			beating.css({'transform': 'transform 0.25s ease scale(1.0)', '-webkit-transform':'scale(1.0)' });
			var now = Date.now();
			$('.everything.heartbeating[app="' + data.app + '"]').each(function(i,v) {
				if ($(v).attr('timestamp') < (now - (stayingAliveInterval * 5))) {
					$(v).remove();
				}
			});
		},200);
		$('.heartbeating').each(function(i,v) {
			if ($(v).attr('timestamp') < ( now - stayingAliveInterval * 7) ) {
				$(v).remove();
			}
		});
	}
}


$(document).on('click', '.remote_media_control', function(e) {
	var control = $(this).attr('control');
	var destination = $(this).attr('browser_tab_id');
	var value = $(this).val();
	if ($(this).is('progress')) {
		 var total_width = $(this).width();
	  var current_location = e.offsetX;
	  value = (current_location / total_width);
	}
	var data = {
		app: 'music',
		control: control,
		destination: destination,
		value: value,
		type: 'remote_control'
	};
	$.ajax({
		url: 'manager/ws/remote_control',
		type: 'POST',
		data: data,
		success: function(response) {
			$(this).css({'transform': 'transform 0.25s ease scale(1.1)', '-webkit-transform':'scale(1.1)' });
			setTimeout(function() {
				$(this).css({'transform': 'transform 0.25s ease scale(1.0)', '-webkit-transform':'scale(1.0)' });
			},300);
		}
	});
});

$(document).on('click', '.neighbour_link', function() {
	var l = $(this);
	var browser_tab_id = l.attr('bti');
	var status = 'off';
	if (l.hasClass('active')) {
		l.removeClass('active');
	}
	else {
		l.addClass('active');
	}
});


$(document).on('click', '.neighbour_publish', function() {
	var ip = $(this).attr('ip');
	var uuid = $(this).attr('uuid');
	var browser_tab_id = $(this).attr('browser_tab_id');
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/magazine/neighbour_publish',
		data: { ip: ip, timestamp: timestamp, browser_tab_id: browser_tab_id, uuid: uuid },
		success: function(response) {
			if (response == 'success') {
				$('#websocket_list').css({ 'background-color': 'green' });
				setTimeout(function() {
					$('#websocket_list').css({ 'background-color': 'yellow' });
				},2000);
			}
		}
	});
});

$(document).on('click', '.neighbour_status', function() {
	var s = $(this);
	var status = s.attr('status');
	var timestamp = Date.now();
	var ip = s.attr('ip');
	$.ajax({
		url: '/manager/neighbour_status',
		type: 'POST',
		data: { timestamp: timestamp, status: status, ip: ip },
		success: function(response) {
			s.attr('status', response['status']);			
		}
	});
});

$(document).on('click', '.video_preview', function() {
	var preview = $(this);
	if (tree.sound.playing != undefined) {
		tree.sound.currentTime = preview.attr('current_time');
	}
	else {
		mediaMaker({ file: preview.attr('file'), currentTime: preview.attr('current_time') });
		var track_preview = preview.closest('.neighbour').find('.track_item_preview').html();
		$('#files').prepend(track_preview);
	}

});

function websocketStop(app) {
	var timestamp = Date.now();
	var closer = $('.close_appointment[app="' + app + '"]');
	var browser_tab_id = sessionStorage.getItem('browser_tab_id');

	if (app && ws[app]) {
		if ( ws[app] ) { ws[app].close(); ws[app] = null;	delete ws[app]; };
		clearInterval(heartbeat[app]);

		$.each(ws, function(i,v) {
			if (i.match(app + '@')) {
				ws[i].close(); ws[i] = null;	delete ws[i];
			}
		});
		//closer.trigger('click');
		closer.css({'background-color':'red'});
	}
	else if (!ws[app] && app) {
		$.ajax({
			url: '/manager/ws_close',
			type: 'GET',
			data: { 
				browser_tab_id: browser_tab_id,
				app: app,
				timestamp: timestamp
			},
			success: function(response) {
				
			},
			error: function(err) {console.log('Error:', err) }
		});
	}
	else if (!app) {
		$.each(ws, function(i,v) {
			if (i != 'tab' || i != 'music' || i != 'server') {
				closer = $('.close_appointment[app="' + i + '"]');
				if (ws[i] != null) { ws[i].close(); }
				ws[i] = null;
				delete ws[i];
				clearInterval(heartbeat[app]);
				//closer.trigger('click');
			}
		});

	}
	delete heartbeat[app]; 
	if (windowVisible == 1) {
		websocketStart();
	}
}

function lockScreen() {

}
function unlockScreen() {}


document.addEventListener("visibilitychange", function(e) {
	if (e.returnValue == true) {
	//	windowVisible = 1;
	//	websocketStop();
	//	mailWebSocketStop();
		unlockScreen();
	}
	else {
	//	windowVisible = 0;
		//websocketStop();
		lockScreen();
		//mailWebSocketStop();
		$('#search').val('');
	}
});
