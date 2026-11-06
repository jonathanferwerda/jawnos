// Frames arrive in bursts: one server action often sends several (a header, a
// console instruction, a neighbour update), and every one of them used to run
// the whole dispatcher at once - jQuery lookups, innerHTML, layout - with the
// browser free to reflow between frames. Collect the frames of a turn and run
// them in one pass instead: the same work, without the churn between it.
// setTimeout, not requestAnimationFrame: a hidden tab still takes its messages
// (a notification, a padlock, terminal output), and rAF stops while hidden.
var wsMessageQueue = [];
var wsMessageFlushTimer = null;

// One place that puts a freshly rendered appointment header on the screen. A
// live push, a reset response and a reconnect's catch-up all carry one, so all
// three land the same way: the wrapper, its timestamp, and the clock that reads
// it. A window that is not open has no header to replace, so nothing happens.
function jawnosHeaderApply(app, html, timestamp) {
	if (!app || !html) { return; }
	var header = $('.wind[app="' + app + '"]').find('.appointment_header_background');
	if (!header.length) { return; }
	header.replaceWith('' + html + '');
	header = $('.wind[app="' + app + '"]').find('.appointment_header_background');
	header.attr('last_updated', timestamp || Date.now());
	if (typeof appointment_chron === 'function') { appointment_chron(); }
}

function wsMessageHandler(event) {
	wsMessageQueue.push(event.data);
	if (wsMessageFlushTimer) { return; }
	wsMessageFlushTimer = setTimeout(function () {
		wsMessageFlushTimer = null;
		var batch = wsMessageQueue;
		wsMessageQueue = [];
		for (var i = 0; i < batch.length; i++) {
			try {
				wsMessageDispatch(batch[i]);
			}
			catch (err) {
				// one bad frame must not swallow the ones behind it, and a real
				// error still reaches the page's own reporter by leaving the timer
				setTimeout(function () { throw err; }, 0);
			}
		}
	}, 0);
}

function wsMessageDispatch(raw) {
	if (isJson(raw)) {
		var data = JSON.parse(raw);
		// the machine's code revision arrives on every connect. Storing it first is
		// the reload loop-guard: the reloaded page compares against what is in
		// sessionStorage, so a value that is not stored first reloads forever.
		// When it changed since this tab loaded, the tab follows the change the
		// quiet way - jawnosRevisionArrived decides between updating in place and
		// asking for one reload (a concatenated classic script cannot run twice
		// under a live document without doubling every handler it binds).
		if (data['revision']) {
			var rv = sessionStorage.getItem('jawnos_revision');
			sessionStorage.setItem('jawnos_revision', data['revision']);
			jawnosRevisionArrived(data['revision_parts'], data['version'], rv);
		}
		// The coding worker pushes this after every state change of a run (a step,
		// a live tick, the wait for approval, the verdict), so the panel that owns
		// the run can poll at once instead of waiting out its timer.
		if (data['coding_run'] && typeof jawnosCodingRunPushed === 'function') {
			jawnosCodingRunPushed(data['coding_run'], data['coding_conversation']);
		}
		// The reception's live transcript: the sentence being recognised, then the
		// finished line. Pushed on the phone's channel, so only the Phone pane
		// draws it; a pane that missed the push catches up from the status poll.
		if (data['type'] === 'sco_transcript' && typeof jawnPhoneTranscriptPushed === 'function') {
			jawnPhoneTranscriptPushed(data);
		}
		// The "Connect me" bridge's answer and candidates, on the same channel.
		if (data['type'] === 'sco_rtc' && typeof jawnScreenRtcPushed === 'function') {
			jawnScreenRtcPushed(data);
		}
		// A screening began or the line is free: every open window gets the
		// floating panel, so a call answered by the receptionist is visible on
		// the tablet and the laptop too, not only on the phone.
		if (data['type'] === 'sco_screen' && typeof jawnScreenPushed === 'function') {
			jawnScreenPushed(data);
		}
		// Every connect carries the tree's boot stamp. A new boot is the one
		// event that drops a media grant, so that - not the length of a socket
		// outage - is what re-fetches the open media windows. The first stamp of
		// a page load only records; a reconnect in the same boot re-lists nothing.
		if (data['boot']) {
			// A window that slept through the screening's start push asks again
			// on every connect: the boot stamp is what a reconnect carries.
			if (typeof jawnScreenPoll === 'function') { jawnScreenPoll(); }
			var boot = window.jawnosMediaBoot;
			window.jawnosMediaBoot = data['boot'];
			if (boot && boot !== data['boot'] && typeof jawnosMediaRefresh === 'function') {
				jawnosMediaRefresh(['gallery', 'music', 'folders']);
			}
		}
		// The Terminal toolbar names the machine its shell is running on, and a
		// connect or a dropped ssh link changes that without re-rendering anything.
		if (data['terminal_shell'] && typeof terminalShellStatus === 'function') {
			terminalShellStatus(data['terminal_shell']);
		}
		if (data['terminal_opened'] !== undefined && typeof terminalOpened === 'function') {
			terminalOpened(data);
		}
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
		if (typeof data['padlock_gate'] !== 'undefined') {
			// the gate was turned on/off somewhere: the padlock in the taskbar is
			// server-rendered, so every screen gets the change here instead of
			// waiting for a refresh to show or hide the lock button
			$('#lock_session').toggle(!!data['padlock_gate']);
		}
		if (data['crypto_payment_prompt']) {
			// A payment started on a device with no fingerprint asks this one; the
			// server sends the target device ids so an unenrolled tablet ignores it.
			if (typeof jawnosCryptoPaymentPrompt === 'function') {
				jawnosCryptoPaymentPrompt(data);
			}
		}
		if (data['padlock_key_clear']) {
			// the request was answered (or withdrawn) on another screen: close it
			// here too, but never a newer request than the one named
			if (typeof jawnPadlockPromptClear === 'function') {
				jawnPadlockPromptClear(data['request_id']);
			}
		}
		if (data['padlock_key_show']) {
			// An explicit request gets a fingerprint prompt in place; it never
			// moves this page. Anything else is a legacy announcement and is
			// ignored, so a lock cannot black out a phone that is in use.
			if (data['prompt'] && typeof jawnPadlockPrompt === 'function') {
				jawnPadlockPrompt(data['mode'], data['target'], data['request_id'], data['device_name'], data['source_device'], data['source_hostname'], data['house']);
			}
			else if (typeof jawnPadlockKeyShow === 'function') {
				jawnPadlockKeyShow(data['mode'], data['target'], data['show']);
			}
		}
		if (data['padlock_open']) {
			// another device may have answered an in-place prompt; dismiss it
			// before the target check below, which is about this device's own lock
			if (typeof jawnPadlockPromptDismiss === 'function') {
				jawnPadlockPromptDismiss(data['target']);
			}
			// the phone (or the paper code) turned it: drop the overlay without
			// waiting for the page to be reloaded, on the device it was meant for
			if (typeof jawnPadlockTargetMatches === 'function' && !jawnPadlockTargetMatches(data['target'])) {
				return;
			}
			if (window.jawnLockedPoller) { clearInterval(window.jawnLockedPoller); window.jawnLockedPoller = null; }
			$('body > .padlock_screensaver').remove();
			$('#padlock_frame').html('').hide();
			$('#everything').show();
			if (!document.getElementById('everything')) { window.location.reload(); }
		}
		if ( data['padlock'] ) {
			if (typeof jawnPadlockTargetMatches === 'function' && !jawnPadlockTargetMatches(data['target'])) {
				return;
			}
			var myDevice = localStorage.getItem('device_uuid') || '';
			if (data['unlocked'] && myDevice && data['unlocked'].indexOf(myDevice) >= 0) {
				return;
			}
			var height = numeral($(window).height()).format('0.00');
			var width = numeral($(window).width()).format('0.00');
			if ($('#everything').is(':visible')) {
				var pf = $('#padlock_frame');
				pf.html(data['padlock']);


				// the black backdrop the locked page uses, not a per-lock colour:
				// a lock turned from the taskbar and one met on a refresh must look
				// the same
				pf.css({'position': 'fixed','z-index': 60000, 'background-color': '#101010' }).show();
			}
			else {
				$('#padlock_frame').css({'background-color': '#101010' }).show();
				$('#padlock_taunts').text(data['taunts']).css({ 'position':'fixed','max-width': width + 'px', 'width':'100%', 'height': '40%', 'left': '0px', 'top': '1%', 'text-align': 'centre', 'width': '120%'});
			}
			$('#everything').hide();
			// The overlay HTML is rendered by whichever screen locked. Its
			// fingerprint button (and whether this device has an enrolled one) is
			// this device's own fact, so correct it from padlock_state now.
			if (typeof jawnPadlockKeyCheck === 'function') { jawnPadlockKeyCheck(true); }

		//	websocketStop();
		}
		else if ( data['console'] ) {
			if (data['view'] == 'errors') {
				if (typeof terminalAppendError === 'function') { terminalAppendError(data); }
				else {
					var tv = $('#terminal_error_view');
					tv.append('<span class="terminal_error" style="color:blue;"><b>' + syncEscape(data['whoami']) + '@' + syncEscape(data['hostname']) + ':</b></span> ' + syncEscape(data['console']['code']) + ' ' + syncEscape(data['console']['msg']) + '<br>');
					tv.scrollTop(tv.height() * 4000);
				}
			}
			else if (data['view'] == 'log') {
				if (typeof terminalAppendLog === 'function') { terminalAppendLog(data); }
				else {
					var tv = $('#terminal_log_view');
					tv.append('<span class="terminal_log" style="color:blue;"><b>' + syncEscape(data['whoami']) + '@' + syncEscape(data['hostname']) + ':</b></span> ' + syncEscape(data['console']['msg']) + '<br>');
					tv.scrollTop(tv.height() * 4000);
				}
			}
			else {
				// The console channel carries a command object, not source. The
				// router runs a named command and refuses anything else; see
				// 00_console_router.js. The echoed entry is escaped so a command
				// name cannot inject markup, and a bad instruction must not kill
				// the socket.
				jawnosConsoleRun(data['console']);
				var shown = (typeof data['console'] === 'object' && data['console'])
					? (data['console']['cmd'] || '') : data['console'];
				var tv = $('#terminal_view .terminal_entries');
				tv.append('<div class="terminal_entry terminal_entry_command"><div class="terminal_entry_head"><span style="color:blue;"><b>' + syncEscape(data['whoami']) + '@' + syncEscape(data['hostname']) + ':</b></span></div><div class="terminal_entry_msg">' + syncEscape(shown) + '</div></div>');
				tv.scrollTop(tv.height() * 4000);
				appointment_chron()
			}
		}
		else if (data['terminal']) {
			console.log(data);
			if (typeof terminalDataReceiver === 'function') { terminalDataReceiver(data); }
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
			// the decrypted envelope is rendered for the shared Mailbox markup; a
			// Chat window needs it re-dressed as bubbles, exactly like a live one
			if (typeof chatDressMessages === 'function') { chatDressMessages(); }
			appointment_chron()
			mailScrollBottom();
			// a thread that is still filling in (the first open after a worker
			// start decrypts in a batch) stays pinned to its newest message
			if (typeof chatAutoScrollUntil !== 'undefined' && Date.now() < chatAutoScrollUntil && typeof chatScrollBottom === 'function') { chatScrollBottom(); }
		}
		else if ( data['type'] == 'mail_arrival' ) {
			// a letter the server accepted: the start menu's envelope rings until
			// the mailbox is opened
			if (typeof mailArrival == 'function') { mailArrival(data); }
		}
		else if ( data['type'] == 'ticket_request_arrival' ) {
			// a ticket request the server queued: the start menu's Tickets icon
			// rings until the box office is opened
			if (typeof ticketArrival == 'function') { ticketArrival(data); }
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

			if ((!$('#alert').attr('uuid') || $('#alert').attr('uuid') == data['uuid']) && !$('#alert').is('[hidden]')) {
				jawnosAlert(data['alert'], { uuid: data['uuid'] });
			}
			$('#alert').attr('uuid', data['uuid']);
			if (data['close'] == 'yes') { 
				jawnosAlertClose();

				$('#alert').attr('uuid', undefined);
				$('#alert').attr('hidden', undefined);
			}
		}
		else if ( data['red'] ) {
			clearTimeout(dotTimeout['red']);
			$('#red_dot').show();
			var rinfo = $('#red_dot').find('.dot_info');
			rinfo.html(data['red']);
			if (data['close'] == 'yes') {
				$('#red_dot').hide();
				rinfo.hide();
			}
			dotTimeout['red'] = setTimeout(function() { $('#red_dot').hide(); rinfo.hide(); }, 10000);
		}
		else if ( data['yellow'] ) {
			clearTimeout(dotTimeout['yellow']);
			var info = $('#yellow_dot').find('.dot_info');
			// The panel is painted with the syncing peer's colour, so its text
			// cannot trust the theme ink (a dark theme's near-white ink vanished
			// on a yellow or white panel). Below the contrast threshold it takes
			// the theme's light ink; on a light surface it is black.
			var panel_bg = data['colour'] || 'white';
			var panel_ink = (typeof jawnosSurfaceInk == 'function') ? jawnosSurfaceInk(panel_bg) : '#000000';
			info.css({ 'background-color': panel_bg, 'color': panel_ink });
			// 'close' ends a sync; keep the last real message instead of
			// painting the word "close" into the panel.
			if (data['yellow'] !== 'close') {
				yellowCurrent = data['yellow'];
			}
			yellowDone = (data['close'] == 'yes');
			var incoming = data['state'] || (yellowDone ? 'done' : 'running');
			if (incoming === 'running' && (!yellowJob || data['progress'] === 0 || data['progress'] === -1)) {
				yellowSteps = [];
				yellowHistoryHtml = '';
			}
			setYellowProgress((data['progress'] === undefined ? -1 : data['progress']), incoming);
			ensureYellowRing();
			$('#yellow_dot').show();
			if (yellowPinned) {
				// The person opened the panel: it stays until they click the dot.
				renderYellowPanel(yellowDone);
				if (incoming === 'running') { startYellowPoll(); }
				else { stopYellowPoll(); }
			}
			else {
				info.removeClass('sync_expanded');
				info.html(yellowCurrent);
				// The normal yellow lifetime: 20 s, even for the final 'close', so
				// there is time to open it and read the last result.
				dotTimeout['yellow'] = setTimeout(function() { $('#yellow_dot').hide(); info.hide(); }, 20000);
			}
		}
		else if ( data['green'] ) {
			clearTimeout(dotTimeout['green']);
			$('#green_dot').show();
			var ginfo = $('#green_dot').find('.dot_info');
			ginfo.html(data['green']);
			if (data['close'] == 'yes') {
				$('#green_dot').hide();
				ginfo.hide();
			}
			dotTimeout['green'] = setTimeout(function() { $('#green_dot').hide(); ginfo.hide(); }, 10000);
		}
		else if (data['id']) {
			$('#' + data['id']).html(data['html']);
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


		if (data['type'] == 'remote_input_result' && typeof jawnosRemoteInputResult == 'function') {
			jawnosRemoteInputResult(data);
		}

		if (data['type'] == 'remote_control') {
			if (data['value'] && data['value'] != '') {
				if (data['control'] == 'progress_bar') {
					var seek_to = data['value'] * tree.sound.duration;
					tree.sound.currentTime = seek_to;
				}
				else if (data['control'] == 'volume_control') {
					// the bar now follows the machine's mixer when one is exposed, so
					// the remote control moves the same channel a person would
					if (typeof musicVolumeSet == 'function') {
						musicVolumeSet(parseFloat(data['value']) || 0);
					}
					else {
						master_volume = parseFloat(data['value']) || 0;
						$('#music_volume').val(master_volume);
						musicVolumeApply();
						updateMusicMuteIcon();
					}
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
			if (data['app'] == 'server' && typeof jawnPadlockKeyCheck === 'function') { jawnPadlockKeyCheck(); }
		//	appointmentDetailsUpdater(app);
		}
		else if (data['window']) {
			windowMaker(data['window']);
			appointment_chron();
		}
		else if ( data['type'] == 'header' ) {
			jawnosHeaderApply(data['app'], data['header'], data['timestamp']);
			var blci = $('.budget_current_information[app="' + data['app'] + '"]');
			var circumstance = blci.attr('circumstance');
			if (circumstance && blci.is(':visible')) {
				if (typeof budgetLight === 'function') { budgetLight(data['app'],circumstance,'open'); }
			}
		}
		else if ( data['type'] == 'resync' ) {
			// The catch-up for a socket that was away: every open window's current
			// appointment header, in one frame. A start or stop that happened while
			// the link slept is painted here, without a reload.
			$.each(data['headers'] || {}, function (app, html) {
				jawnosHeaderApply(app, html, data['timestamp']);
			});
		}
		else if ( data['type'] == 'budget' ) {
			var blci = $('.budget_current_information[app="' + data['app'] + '"]');
			var circumstance = blci.attr('circumstance');
			$('.budget_light[app="' + data['app'] + '"][circumstance="' + data['budget']['circumstance'] + '"]').css({ 'background-color': data['budget']['colour'] });
			if (circumstance && blci.is(':visible')) {
				if (typeof budgetLight === 'function') { budgetLight(data['app'],circumstance,'open'); }
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

// The pulse a heartbeat paints: one timeout per app settles the scale back. A
// 200ms interval used to do this (and prune) for every app, forever - five DOM
// passes a second just to animate a dot.
