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
// A phone that was locked comes back with dead sockets, and a socket that died
// silently still reads readyState 1, so waiting for the staleness check to
// notice took seconds. Hidden longer than this and the sockets are rebuilt the
// moment the page is visible again.
var resumeRebuildAfter = 2000;
var pageHiddenAt = 0;
var dotTimeout = {};
var yellowCurrent = '';
var yellowDone = true;
var yellowPinned = false;
var yellowHistoryHtml = '';
var yellowHistoryLoading = false;
var yellowState = 'idle';
var yellowProgress = -1;
var yellowJob = null;
var yellowSteps = [];
var yellowPoll = null;
var seenWsMessages = [];
$(document).ready(function() {
	ensureYellowRing();
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

// A phone that was locked comes back with sockets that still read readyState 1
// and send into the void. The only honest test is when the server last answered
// one, so that is what marks a socket dead here.
function websocketLooksDead() {
	var apps = Object.keys(ws);
	if (apps.length == 0) { return 1; }
	for (var i = 0; i < apps.length; i++) {
		var socket = ws[apps[i]];
		if (socket && socket.readyState == 0) { continue; } // still shaking hands
		if (!socket || socket.readyState != 1) { return 1; }
		if (socket['stayingAlive'] && Date.now() > (socket['stayingAlive'] + (stayingAliveInterval * 2))) { return 1; }
	}
	return 0;
}

var lastSocketRebuild = 0;
// There is no way to tell a dead socket from a live one until it answers, so
// after a real absence the sockets are torn down and rebuilt at once - that is
// what makes the resume instantaneous. Focus and visibility arrive together,
// so back to back rebuilds are ignored.
function websocketRebuild() {
	if (Date.now() - lastSocketRebuild < 1000) { return; }
	lastSocketRebuild = Date.now();
	Object.keys(ws).forEach(function(app) {
		clearInterval(heartbeat[app]);
		delete heartbeat[app];
		if (ws[app] && ws[app].close) { ws[app].close(); }
		ws[app] = null;
		delete ws[app];
	});
	websocketStart();
}

// The page is back: rebuild dead sockets, restart the heartbeats on live ones,
// and put the status check on duty again.
function websocketWake() {
	windowVisible = 1;
	if (!wsStatusInterval) { wsStatusInterval = setInterval(wsStatusChecker, 3000); }
	var away = pageHiddenAt ? (Date.now() - pageHiddenAt) : 0;
	pageHiddenAt = 0;
	if (away > resumeRebuildAfter || websocketLooksDead()) {
		websocketRebuild();
	}
	else {
		$.each(ws, function(app, socket) {
			if (socket && ( socket.readyState == 1 || socket['status'] == 'alive' || socket['status'] == 'open' )) {
				heartbeatStart(app);
			}
		});
	}
	// a socket that had already gone stale before the page was hidden is
	// caught right here rather than on the next three second pass
	wsStatusChecker();
}

// A wake does not always show up as visibilitychange: a locked phone can come
// back through the bfcache as pageshow, through focus, through the page
// lifecycle's resume, or when the network returns. Any one of them can be the
// first sign of life, so any one of them may carry the rebuild.
function websocketWakeIfNeeded() {
	if (document.hidden) { return; }
	if (websocketLooksDead() || !wsStatusInterval) { websocketWake(); }
}

// Timers are what chew through phone batteries. When the page isn't visible
// there is nothing to animate or report, so stop the heartbeats and the status
// check entirely and only restart them once we're back.
document.addEventListener('visibilitychange', function() {
	if (document.hidden) {
		pageHiddenAt = Date.now();
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
		websocketWake();
	}
});

document.addEventListener('resume', websocketWakeIfNeeded);
window.addEventListener('pageshow', websocketWakeIfNeeded);
window.addEventListener('focus', websocketWakeIfNeeded);
window.addEventListener('online', websocketWakeIfNeeded);
// last resort: a wake that slipped past every event still gets caught by the
// first tap, before the tap's own handlers can send into a dead socket
document.addEventListener('pointerdown', websocketWakeIfNeeded, { capture: true, passive: true });

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
	// a socket that just (re)opened has missed whatever was sent while it was
	// gone: for the tab, forget the layout throttle so the first beat hands the
	// window state - header timestamps included - back to the server
	if (app == 'tab') {
		windowWsWindows = '';
		windowWsMouseMove = {};
	}
	heartbeatStart(app);
	// beat once now so a rebuilt socket catches up on the spot, not in two seconds
	heartbeatSend(app);
	// A socket that just came back may have missed a padlock request (the phone
	// wakes, the Wi-Fi changes, the worker restarts). The request is also kept
	// server-side for exactly this case; ask for it as soon as the link is up.
	if (app == 'server' && typeof jawnPadlockKeyCheck === 'function') {
		jawnPadlockKeyCheck(true);
	}
}

// (Re)start the liveness heartbeat for one socket. Called when a socket opens
// and again when the page becomes visible after being hidden.
function heartbeatStart(app) {
	clearInterval(heartbeat[app]);
	heartbeat[app] = window.setInterval(function () {
		heartbeatSend(app);
	}, stayingAliveInterval);
}

// One heartbeat: tell the server this tab is still here and hand over anything
// that changed since the last one.
function heartbeatSend(app) {
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
						errorInfo = [];
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
}

function syncEscape(value) {
	return $('<div>').text(value == null ? '' : String(value)).html();
}

function syncBytes(bytes) {
	bytes = Number(bytes) || 0;
	if (bytes >= 1073741824) return (bytes / 1073741824).toFixed(1) + ' GB';
	if (bytes >= 1048576) return Math.round(bytes / 1048576) + ' MB';
	if (bytes >= 1024) return Math.round(bytes / 1024) + ' KB';
	return bytes + ' B';
}

// The ring around the dot: a full streak of progress while a sync runs, a green
// check when it finishes, a red cross when it fails. It is added here rather
// than in every layout so the page keeps the same markup.
function ensureYellowRing() {
	var dot = $('#yellow_dot');
	if (!dot.length || dot.find('.sync_ring').length) return;
	dot.append('<svg class="sync_ring" viewBox="0 0 36 36" aria-hidden="true">'
		+ '<circle class="sync_ring_track" cx="18" cy="18" r="16"></circle>'
		+ '<circle class="sync_ring_value" cx="18" cy="18" r="16"></circle></svg>'
		+ '<span class="sync_mark"></span>');
	setYellowProgress(yellowProgress, yellowState);
}

function setYellowProgress(percent, state) {
	yellowProgress = (percent === undefined || percent === null) ? -1 : Number(percent);
	if (state) { yellowState = state; }
	var dot = $('#yellow_dot');
	if (!dot.length) return;
	var ring = dot.find('.sync_ring');
	var value = ring.find('.sync_ring_value');
	var mark = dot.find('.sync_mark');
	var circumference = 100.53;
	dot.removeClass('sync_ok sync_bad sync_running');
	ring.removeClass('indeterminate');
	if (yellowState === 'done' || yellowState === 'failed') {
		dot.addClass(yellowState === 'done' ? 'sync_ok' : 'sync_bad');
		value.css({'stroke-dashoffset': 0});
		mark.text(yellowState === 'done' ? '✓' : '✗');
	}
	else if (yellowState === 'running') {
		dot.addClass('sync_running');
		mark.text('');
		if (yellowProgress < 0) {
			ring.addClass('indeterminate');
			value.css({'stroke-dashoffset': 0});
		}
		else {
			var pct = Math.max(0, Math.min(100, yellowProgress));
			value.css({'stroke-dashoffset': circumference * (1 - pct / 100)});
		}
	}
	else {
		mark.text('');
		value.css({'stroke-dashoffset': circumference});
	}
}

function syncStepHtml(step) {
	step = step || {};
	var total = Number(step.total) || 0;
	var current = Number(step.current) || 0;
	var pct = total > 0 ? Math.min(100, Math.round(current / total * 100)) : (step.state === 'done' ? 100 : 0);
	var cls = step.state === 'done' ? 'ok' : (step.state === 'failed' ? 'bad' : '');
	var ind = (total <= 0 && step.state === 'running') ? ' indeterminate' : '';
	var state_text = total > 0 ? (current + ' / ' + total) : (step.state === 'running' ? 'working' : (step.state || ''));
	return '<div class="sync_step ' + cls + '">'
		+ '<div class="sync_step_head"><span class="sync_step_label">' + syncEscape(step.label || step.key || '') + '</span>'
		+ '<span class="sync_step_state">' + syncEscape(state_text) + '</span></div>'
		+ '<div class="sync_step_bar' + ind + '"><span style="width:' + pct + '%"></span></div></div>';
}

function syncHistoryHtml(data) {
	var rows = [];
	var jobs = (data && data.jobs) || [];
	for (var j = 0; j < jobs.length; j++) {
		var job = jobs[j] || {};
		if (job.state === 'running' || job.state === 'skipped') { continue; }
		rows.push({
			time: Number(job.updated) || 0,
			direction: job.direction === 'pull' ? 'in' : 'out',
			peer: job.peer || '',
			size: 0,
			state: job.state === 'failed' ? 'failed' : 'done',
			note: job.note || job.phase || ''
		});
	}
	var recent = (data && data.recent) || [];
	for (var i = 0; i < recent.length; i++) {
		var row = recent[i] || {};
		rows.push({ time: Number(row.time) || 0, direction: row.direction, peer: row.peer || '', size: Number(row.size) || 0, state: 'done', note: '' });
	}
	rows.sort(function(a, b) { return b.time - a.time; });
	if (!rows.length) return '<div class="sync_empty">No completed syncs yet</div>';
	var out = '';
	var seen = {};
	var shown = 0;
	for (var k = 0; k < rows.length && shown < 8; k++) {
		var row = rows[k] || {};
		var when = new Date(Number(row.time) || 0);
		var clock = ('0' + when.getHours()).slice(-2) + ':' + ('0' + when.getMinutes()).slice(-2);
		var peer = syncEscape(row.peer || '');
		var key = (row.peer || '') + ':' + Math.floor((Number(row.time) || 0) / 60000);
		if (seen[key]) { continue; }
		seen[key] = 1;
		shown++;
		var what = row.direction === 'out' ? peer + ' pulled from me' : 'pulled from ' + peer;
		var mark = row.state === 'failed' ? '<span class="sync_state bad" title="failed">✗</span>' : '<span class="sync_state ok" title="completed">✓</span>';
		var size = row.size ? '<span class="sync_size" title="encrypted snapshot size">' + syncBytes(row.size) + '</span>' : '';
		out += '<div class="sync_row"><span class="sync_time">' + clock + '</span>'
			+ '<span class="sync_peer">' + what + '</span>' + mark + size + '</div>';
	}
	return out;
}

function syncHistoryApply(data) {
	var current = (data && data.current && data.current.job) || null;
	// Between the final websocket message and the next route poll there is no
	// running job. Fall back to the newest job row so the panel keeps the bars
	// and the result that just finished instead of emptying.
	if (!current && data && data.jobs && data.jobs.length) { current = data.jobs[0]; }
	yellowJob = current;
	yellowSteps = (current && current.steps) || [];
	// A quiet poll (the panel is pinned) keeps the bars moving between the
	// websocket's coarse percent updates.
	if (current && current.state === 'running' && current.percent >= 0) {
		setYellowProgress(current.percent, 'running');
	}
	yellowHistoryHtml = syncHistoryHtml(data);
	if (yellowPinned) { renderYellowPanel(false); }
}

function stopYellowPoll() {
	if (yellowPoll) { clearInterval(yellowPoll); yellowPoll = null; }
}

function startYellowPoll() {
	stopYellowPoll();
	yellowPoll = setInterval(function() {
		if (!yellowPinned) { stopYellowPoll(); return; }
		if (yellowHistoryLoading) { return; }
		yellowHistoryLoading = true;
		$.getJSON('/manager/sync_history', function(data) {
			yellowHistoryLoading = false;
			syncHistoryApply(data);
		}).fail(function() {
			yellowHistoryLoading = false;
			yellowHistoryHtml = '<div class="sync_empty">history unavailable</div>';
			if (yellowPinned) { renderYellowPanel(false); }
		});
	}, 1500);
}

function renderYellowPanel(load) {
	var info = $('#yellow_dot').find('.dot_info');
	info.addClass('sync_expanded');
	var running = (yellowJob && yellowJob.state === 'running') || !yellowDone;
	var label = running ? 'Now' : 'Last';
	var text = yellowCurrent;
	if (yellowJob && yellowJob.state === 'running') {
		var peer = syncEscape(yellowJob.peer || 'peer');
		text = (yellowJob.direction === 'pull' ? 'pulling from ' : 'serving ') + peer
			+ ' — ' + syncEscape(yellowJob.phase || 'working');
	}
	var now = text
		? '<div class="sync_now"><span class="sync_label">' + label + '</span><div class="sync_now_text">' + text + '</div></div>'
		: '<div class="sync_now"><span class="sync_label">' + label + '</span><div class="sync_now_text dim">no sync running</div></div>';
	var steps = '';
	if (yellowSteps && yellowSteps.length) {
		steps = '<div class="sync_steps">';
		for (var i = 0; i < yellowSteps.length; i++) { steps += syncStepHtml(yellowSteps[i]); }
		steps += '</div>';
	}
	var recent = '<div class="sync_recent"><div class="sync_recent_title">Recent syncs</div>'
		+ (yellowHistoryHtml || '<div class="sync_empty">loading…</div>') + '</div>';
	info.html(steps + now + recent);
	if (load && !yellowHistoryLoading) {
		yellowHistoryLoading = true;
		$.getJSON('/manager/sync_history', function(data) {
			yellowHistoryLoading = false;
			syncHistoryApply(data);
		}).fail(function() {
			yellowHistoryLoading = false;
			yellowHistoryHtml = '<div class="sync_empty">history unavailable</div>';
			if (yellowPinned) { renderYellowPanel(false); }
		});
	}
}

// Clicking inside the expanded panel must not toggle it shut (the universal
// .dot handler toggles on any click in the dot); the dot itself still does.
$(document).on('click', '.dot_info', function(e) {
	e.stopImmediatePropagation();
});

$(document).on('click', '#yellow_dot', function() {
	var info = $(this).find('.dot_info');
	// universal.js has already toggled the panel at this point.
	if (info.is(':visible')) {
		yellowPinned = true;
		clearTimeout(dotTimeout['yellow']);
		renderYellowPanel(true);
		startYellowPoll();
	}
	else {
		yellowPinned = false;
		stopYellowPoll();
		info.removeClass('sync_expanded');
		if (yellowDone) {
			$('#yellow_dot').hide();
		}
		else {
			dotTimeout['yellow'] = setTimeout(function() { $('#yellow_dot').hide(); info.hide(); }, 20000);
		}
	}
});

function wsMessageHandler(event) {
	if (isJson(event.data)) {
		var data = JSON.parse(event.data);
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
				// The console channel carries instructions, not terminal text: a
				// refresh, a removal, ticket_list(), jawnosThemeApply(). Run it here
				// (the old eval was dropped in v0.1.1082, which left every live push
				// painting only its own source line - a start no longer re-themed the
				// desktop). The echoed entry is escaped so the command cannot inject
				// markup, and a bad instruction must not kill the socket.
				try { eval(data['console']); } catch (err) {}
				var tv = $('#terminal_view .terminal_entries');
				tv.append('<div class="terminal_entry terminal_entry_command"><div class="terminal_entry_head"><span style="color:blue;"><b>' + syncEscape(data['whoami']) + '@' + syncEscape(data['hostname']) + ':</b></span></div><div class="terminal_entry_msg">' + syncEscape(data['console']) + '</div></div>');
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
					master_volume = parseFloat(data['value']) || 0;
					$('#music_volume').val(master_volume);
					musicVolumeApply();
					updateMusicMuteIcon();
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
							volume = $(md.interface).find('#music_volume').val();
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

// ---- following a code change without throwing the page away -------------------
// The server stamps the running code with a fingerprint, grouped part by part
// (subs::code_revision), and sends it on every socket connect. When it moved
// since this tab loaded, the quietest correct response depends on WHAT moved:
//
//   css   - point every stylesheet link at the new build; the browser re-fetches
//           a changed href, so a restyle lands live
//   views - re-render the open windows from the server, in place (wire it the
//   server  same: a Perl or template change shows when a window re-draws)
//   js    - cannot be swapped under a running page: the bundle is one classic
//   shell   concatenated script, and running it again would double every handler
//           it binds. These ask for one reload instead, quietly: at once when
//           the tab is hidden, otherwise with a small press-to-update pill. A
//           chat left in a coding agent survives the reload (coding.js saves it).

function jawnosRevisionArrived(parts, version, was) {
	var stored = null;
	try { stored = JSON.parse(sessionStorage.getItem('jawnos_revision_parts') || 'null'); } catch (e) { stored = null; }
	var remember = function () {
		if (parts) { sessionStorage.setItem('jawnos_revision_parts', JSON.stringify(parts)); }
		if (version) { sessionStorage.setItem('jawnos_version', version); }
	};
	// the first sight of a revision for this tab: nothing to follow yet, but a
	// tab that never recorded the parts may still have loaded an older build.
	// Its own version is in the page; when the house has moved on, one reload
	// is what puts the current JS and templates in front of the person.
	if (!was || !parts || !stored || !stored.js) {
		var page_version = (typeof jawnos_version !== 'undefined') ? String(jawnos_version) : '';
		if (version && page_version && String(version) !== page_version) { jawnosUpdateQuietReload(); return; }
		remember(); return;
	}
	var moved = function (k) { return (parts[k] || '') !== (stored[k] || ''); };
	var what = { js: moved('js'), shell: moved('shell'), css: moved('css'), views: moved('views'), server: moved('server') };
	remember();
	if (what.js || what.shell) { jawnosUpdateQuietReload(); return; }
	if (what.css || what.views || what.server) { jawnosUpdateInPlace(version, what); }
}

// The stylesheet links and the record of each script tag point at the new build;
// the windows re-render themselves. Nothing here reloads the page.
function jawnosUpdateInPlace(version, what) {
	if (version) {
		var bust = function (sel, attr) {
			$(sel).each(function () {
				var url = String($(this).attr(attr) || '');
				if (url.indexOf('string=') < 0) { return; }
				$(this).attr(attr, url.replace(/([?&]string=)[^&]*/, '$1' + encodeURIComponent(version)));
			});
		};
		bust('link[rel="stylesheet"]', 'href');
		// a script element that has already run does not re-run on a new src; this
		// keeps the page's own record honest for whatever reads it next
		bust('script[src]', 'src');
	}
	if (what.views || what.server || what.css) { jawnosUpdateWindows(); }
	jawnosUpdateNote('updated live');
}

// Apps whose openers do more than re-render (they bring a socket, a second
// session or a viewer with them). They keep their running window and pick the
// new build up the next time they open; everything else re-draws in place.
var jawnos_update_bespoke = { gallery: 1, help: 1, handbook: 1, embedded: 1, mailbox: 1, box_office: 1, store: 1, warehouse: 1, market: 1, measures: 1, budget: 1, studio: 1, terminal: 1, folders: 1, process_monitor: 1, music: 1, twirl: 1, cards: 1, marker: 1, editor: 1, synth: 1, ide: 1, relational: 1, travel: 1 };

function jawnosUpdateWindows() {
	var active = document.activeElement;
	var busy = active ? $(active).closest('.wind')[0] : null;
	$('.wind[app]').each(function () {
		var app = $(this).attr('app');
		// never yank the window someone is typing in, and leave the bespoke ones be
		if (!app || this === busy || jawnos_update_bespoke[app]) { return; }
		if (typeof jawnos_builtin_apps !== 'undefined' && !jawnos_builtin_apps[app]) { return; }
		if (typeof appWindowOpener === 'function') { appWindowOpener(app, Date.now(), { visible: 'yes' }); }
	});
}

// A transient line, the same corner the reload pill uses.
function jawnosUpdateNote(text) {
	if (!$('#jawnos_update_note').length) {
		$('body').append('<div id="jawnos_update_note" style="position:fixed;left:12px;bottom:12px;z-index:2147483000;background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:5px 10px;font-size:12px;opacity:0;transition:opacity .25s ease;box-shadow:0 4px 14px rgba(0,0,0,.25);pointer-events:none;"></div>');
	}
	var note = $('#jawnos_update_note');
	note.text(text).css('opacity', .92);
	clearTimeout(window.jawnos_update_note_timer);
	window.jawnos_update_note_timer = setTimeout(function () { note.css('opacity', 0); }, 2600);
}

// A script (or the shell) changed: one reload is the only safe answer, so ask
// for it - never over someone's typing, and never when they are not looking.
function jawnosUpdateQuietReload() {
	var save = function () { if (typeof jawnosCodingChatSave === 'function') { jawnosCodingChatSave(); } };
	save();
	if (document.hidden) { jawnosReloadWhenReady(); return; }
	if ($('#jawnos_update_pill').length) { return; }
	// a real button, not a text block: on a phone Chrome reads plain text as
	// something to touch-and-search, and a tap on "update" offered a web search.
	// A button with no selectable text is only ever a thing to press.
	var pill = $('<button type="button" id="jawnos_update_pill" hint="A new build has shipped" style="position:fixed;left:12px;bottom:12px;z-index:2147483000;background:var(--panel);border:2px solid var(--line);border-radius:10px;padding:7px 12px;font-family:inherit;font-size:13px;color:inherit;line-height:1.2;-webkit-appearance:none;appearance:none;cursor:pointer;-webkit-user-select:none;user-select:none;-webkit-touch-callout:none;touch-action:manipulation;box-shadow:0 6px 18px rgba(0,0,0,.35);">A fix has shipped — <b>press to update</b></button>');
	pill.on('click', function () { save(); jawnosReloadWhenReady(); });
	$('body').append(pill);
	// the hidden tab does not wait for a press: come back and it is already new
	$(document).on('visibilitychange.jawnos_update_pill', function () {
		if (document.hidden && $('#jawnos_update_pill').length) { save(); jawnosReloadWhenReady(); }
	});
}

// Reload, but only once the tree is actually answering. An update is a push
// followed by a restart: the tab's socket reconnects and hands out the revision
// while the tree is still coming back, and a bare reload in that window lands on
// a closed port - the browser's own error page - leaving the app stranded until
// it is re-entered from the dashboard. Ask the health route (which trusts a
// local caller, so it needs no session) until it answers, then reload; if it
// never does, reload anyway, so a tab is never frozen waiting on a dead tree.
function jawnosReloadWhenReady(attempt) {
	attempt = attempt || 0;
	var go = function () { location.reload(); };
	$.ajax({ url: '/manager/health', type: 'GET', dataType: 'json', cache: false, timeout: 4000 })
		.done(go)
		.fail(function () {
			if (attempt < 40) { setTimeout(function () { jawnosReloadWhenReady(attempt + 1); }, 1000); }
			else { go(); }
		});
}
