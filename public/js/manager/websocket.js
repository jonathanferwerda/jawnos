/* [[js-split]]
   websocket.js is part 1. The rest live in websocket/ in name order:
     01_message_handler.js  - wsMessageHandler, the incoming message dispatcher
     02_heartbeat_and_reload.js  - heartbeat settle, media/neighbour handlers, stop/lock and in-place reload
     03_watchdog.js  - local liveness watch, wake-by-clock-jump, reconnect resync
   /js/manager/bundle.js concatenates the index and these parts.
   [[/js-split]] */
var ws = {};
var remote_ws = {};
var heartbeat = {};
// The liveness beat. Every beat is a network round trip that wakes the radio,
// and an open tab has two or three sockets beating, so the cadence is
// deliberately slow. A socket is only declared dead when the server has not
// answered for two beats; the visibility/resume handlers rebuild at once, so a
// locked phone never waits for this check.
var stayingAliveInterval = 10000;
// The tab socket re-sends the (relatively costly) window layout on this cadence
// even when nothing moved, and the localStorage debrief far more rarely.
var windowResendInterval = 60000;
var debrieferInterval = 300000;
var windowWsWindows = '';
var windowWsDebriefer = 0;
var windowWsDebrieferJson = '';
var windowVisible = 1;
// Reconnect pacing. A page someone is looking at must not wait: every wake
// signal rebuilds at once. A hidden page waits longer on each attempt, because
// a phone pays for every handshake it cannot show, and there is no tight poll -
// one timer per failed socket, doubling to the cap. A test reads these names.
var wsVisibleRetryDelay = 1000;
var wsVisibleRetryMax = 30000;
var wsHiddenReconnectDelay = 30000;
var wsHiddenReconnectMax = 300000;
var wsRetryTimer = 0;
var wsRetryFailures = 0;
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
	wsWatchdogStart();
});

function wsStatusChecker() {
	var timestamp = Date.now();
	$.each(ws, function(i,v) {
		if (windowVisible == 1 && ( ws[i]['status'] == 'alive' || ws[i]['status'] == 'connect' || ws[i]['status'] == 'open' )) {
			var ws_heard = ws[i]['ackAt'] || ws[i]['stayingAlive'];
			if (ws_heard && timestamp > (ws_heard + (stayingAliveInterval * 2))) {
				clearInterval(heartbeat[i]);
				websocketStop(i);
			}
		}
	});
	// A socket that never opened - the tree restarted, or the plain listener it
	// remembered is gone - is retried by nothing else: onclose only marks it, and
	// a page left open then looked alive and heard nothing until a reload. Ask
	// again on a slow beat, on the page's own origin after a failed open.
	if (windowVisible == 1 && !jawn_resting() && (timestamp - (lastSocketRebuild || 0)) > 20000) {
		var dead = 0;
		$.each(['server', 'tab'], function(i, app) {
			if (!ws[app] || ws[app].readyState > 1) { dead = 1; }
		});
		if (dead) { websocketRebuild(); }
	}
}

// One liveness pass per beat is enough to notice a missing answer.
var wsStatusInterval = setInterval(wsStatusChecker, stayingAliveInterval);

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
		var ws_heard = socket['ackAt'] || socket['stayingAlive'];
		if (ws_heard && Date.now() > (ws_heard + (stayingAliveInterval * 2))) { return 1; }
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

// A page that is visible never waits out a backoff set while it was hidden.
function websocketRetryClear() {
	wsRetryFailures = 0;
	if (wsRetryTimer) {
		clearTimeout(wsRetryTimer);
		wsRetryTimer = 0;
	}
}

// One paced retry per failed socket, never a loop. Visible, the delay starts at
// a second and doubles to half a minute; hidden, it starts long and doubles to
// the cap. A visible wake resets the count and rebuilds at once.
function websocketRetryLater() {
	if (wsRetryTimer) { return; }
	wsRetryFailures = Math.min((wsRetryFailures || 0) + 1, 8);
	var delay;
	if (document.hidden || windowVisible != 1) {
		delay = Math.min(wsHiddenReconnectMax, wsHiddenReconnectDelay * Math.pow(2, wsRetryFailures - 1));
	}
	else {
		delay = Math.min(wsVisibleRetryMax, wsVisibleRetryDelay * Math.pow(2, wsRetryFailures - 1));
	}
	wsRetryTimer = setTimeout(function() {
		wsRetryTimer = 0;
		if (document.hidden) { websocketRebuild(); }
		else { websocketWake(1); }
	}, delay);
}

// The page is back: rebuild the sockets at once, restart the heartbeats, and
// put the status check on duty again. `force` is every foreground signal; a
// real visibilitychange also forces it because a socket that slept still reads
// readyState 1 and sends into the void.
function websocketWake(force) {
	windowVisible = 1;
	if (!wsStatusInterval) { wsStatusInterval = setInterval(wsStatusChecker, stayingAliveInterval); }
	websocketRetryClear();
	wsWatchdogStart();
	var away = pageHiddenAt ? (Date.now() - pageHiddenAt) : 0;
	pageHiddenAt = 0;
	if (!Object.keys(ws).length) {
		websocketStart();
		return;
	}
	if (force || away > 0 || websocketLooksDead()) {
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
	// caught right here rather than on the next status pass
	wsStatusChecker();
}

// A wake does not always show up as visibilitychange: a locked phone can come
// back through the bfcache as pageshow, through focus, through the page
// lifecycle's resume, or through the app's own coming-to-front signal. Any one
// of them is the first sign of life, so any one may carry the rebuild.
function websocketFront() {
	if (document.hidden) { return; }
	websocketWake(1);
}

// The cheaper wake: only rebuild when there is a reason to (a dead socket, a
// pending retry, or a status beat that is not running). Used by the signals
// that can also arrive while everything is healthy.
function websocketWakeIfNeeded() {
	if (document.hidden) { return; }
	if (wsRetryTimer || pageHiddenAt || websocketLooksDead() || !wsStatusInterval) { websocketWake(1); }
}

// Timers are what chew through phone batteries. When the page isn't visible
// there is nothing to animate or report, so stop the heartbeats and the status
// check entirely and only restart them once we're back. A socket that dies
// while hidden is retried on the long hidden backoff, not on a poll.
document.addEventListener('visibilitychange', function() {
	if (document.hidden) {
		pageHiddenAt = Date.now();
		windowVisible = 0;
		clearInterval(wsStatusInterval);
		wsStatusInterval = null;
		wsWatchdogStop();
		Object.keys(heartbeat).forEach(function(app) {
			clearInterval(heartbeat[app]);
			delete heartbeat[app];
		});
		Object.keys(heartbeatSettle).forEach(function(app) {
			clearTimeout(heartbeatSettle[app]);
			delete heartbeatSettle[app];
		});
	}
	else {
		websocketFront();
	}
});

document.addEventListener('resume', websocketFront);
window.addEventListener('pageshow', function(event) {
	// a bfcache restore is a real return; an ordinary first load is already
	// connecting and must not be torn down under itself
	if (event && event.persisted) { websocketFront(); }
	else { websocketWakeIfNeeded(); }
});
window.addEventListener('focus', websocketFront);
window.addEventListener('online', websocketWakeIfNeeded);
// The app's own coming-to-front signal: an Android onResume can reach the
// WebView without a visibilitychange, and any bridge can call this directly.
document.addEventListener('jawnos:visible', websocketFront);
document.addEventListener('jawnos:foreground', websocketFront);
window.jawnosWebsocketWake = websocketFront;
// last resort: a wake that slipped past every event still gets caught by the
// first tap, before the tap's own handlers can send into a dead socket
document.addEventListener('pointerdown', websocketWakeIfNeeded, { capture: true, passive: true });

// The plain ws listener (PORT_WS_PLAIN) is a second port beside the one the page
// came from. A page left open can remember a listener a restart left behind, and
// nothing used to ask again: the tab looked alive and heard nothing. A socket that
// fails falls back to the page's own origin (which upgrades on the same port the
// page was served from) and the status beat retries.
var ws_origin_only = 0;
function wsSocketUrl(base, tail) {
	if (ws_origin_only && window.location && window.location.host) {
		var origin = (window.location.protocol === 'https:') ? 'wss://' : 'ws://';
		var match = base.match(/^wss?:\/\/[^\/]+(\/.*)$/);
		if (match) { base = origin + window.location.host + match[1]; }
	}
	var sep = (base.indexOf('?') >= 0) ? '&' : '?';
	return base + sep + tail;
}

function websocketStart(appt,address) {

	var timestamp = Date.now();
	// The music socket is a permanent line, not the music window's own: every
	// music socket advertises this device's playback on its beat and receives the
	// house's (another device starting, stopping, seeking), so it stays open for
	// as long as the manager page does. The music window still calls
	// websocketStart('music') when it opens; that call now finds the socket
	// already up and leaves it alone.
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
		// A remote address keeps its own host. Only the local socket takes the
		// page's origin when the plain listener is gone.
		var tail = 'timestamp=' + timestamp + '&app=' + app + '&browser_tab_id=' + browser_tab_id + '&browser_tab=' + browser_tab + '&user_agent=' + uA;
		ws[app] = new WebSocket(address || wsSocketUrl(ws_url, tail));
		ws[app]['stayingAlive'] = Date.now();
		ws[app]['status'] = 'connect';
		ws[app].onopen = function (event) {
			wsOpener(event,app,origin);
		};
		ws[app].onmessage = function (event) {
			// any frame is an ack: the watchdog measures silence from here
			wsTouched(app);
			wsMessageHandler(event);
		};
		ws[app].onclose = function(event){
			// closed before it ever opened: a listener that moved, not an app the
			// person shut. The next attempt uses the page's own origin.
			if (!address && ws[app] && ws[app]['status'] == 'connect') { ws_origin_only = 1; }
			// A socket still on duty that closed on its own is retried on the
			// paced backoff. A deliberate close (rebuild/stop) has already
			// replaced the handle, so this test keeps it quiet.
			if (ws[app] === this) { websocketRetryLater(); }

		}
	});
}

var windowWsMouseMove = {}
function wsOpener(event,app,origin) {
	// A socket that answered ends any backoff earned by one that did not. The
	// retry timer is left alone: it may belong to another app's dead socket.
	wsRetryFailures = 0;
	// The first open of this page needs nothing rebuilt; every later open is a
	// reconnect, and a reconnect may have missed frames while it was away.
	var ws_reopened = wsOpenedBefore[app] ? 1 : 0;
	wsOpenedBefore[app] = 1;
	wsTouched(app);
	var browser_tab_id = sessionStorage.getItem('browser_tab_id');
	var browser_tab = localStorage.getItem('browser_tab');
	var uA = navigator.userAgent;
	ws[app]['status'] = 'open';
	// A reconnected socket may be a restarted tree, whose boot dropped every
	// media grant. The real test is the server's boot stamp (handled in
	// wsMessageHandler): a socket that merely flapped keeps the same boot, so
	// it must not re-fetch the media windows. Until a server that sends one has
	// answered, fall back to the old gap check - but only for a window that is
	// actually unlocked, which is the only one that has a grant to lose. A
	// locked window was already locked, so re-rendering it changed nothing but
	// cost a fresh listing every time a flapping socket came back.
	if (app === 'server') {
		var media_now = Date.now();
		if (!window.jawnosMediaBoot && window.jawnosMediaServerAt
			&& media_now - window.jawnosMediaServerAt > 20000
			&& typeof jawnosMediaRefresh === 'function') {
			var unlocked = [];
			$.each(['gallery', 'music', 'folders'], function (i, name) {
				var root = $('#' + name);
				if (root.length && root.attr('unlock')) { unlocked.push(name); }
			});
			if (unlocked.length) { jawnosMediaRefresh(unlocked); }
		}
		window.jawnosMediaServerAt = media_now;
	}
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
	// The beat is a radio wake, so a socket that comes back while the page is
	// hidden does not restart it: waking the page does (websocketWake).
	if (!document.hidden) {
		heartbeatStart(app);
		// beat once now so a rebuilt socket catches up on the spot, not in two seconds
		heartbeatSend(app);
	}
	// A socket that just came back may have missed a padlock request (the phone
	// wakes, the Wi-Fi changes, the worker restarts). The request is also kept
	// server-side for exactly this case; ask for it as soon as the link is up.
	if (app == 'server' && typeof jawnPadlockKeyCheck === 'function') {
		jawnPadlockKeyCheck(true);
	}
	// The same absence can hide a start or stop: its header was pushed while the
	// socket was gone. Ask for the open windows' current headers once the link
	// is back, so the screen is truthful the moment the connection is.
	if (ws_reopened) { wsResyncSoon(); }
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
			pathname: window.location.pathname,
			// the controller is the only thing that renders a neighbour list,
			// so the server can answer with a bare liveness ack while it is shut
			controller_visible: $('#controller').is(':visible') ? 'yes' : 'no'
		};

		if (app == 'tab' || apper == 'tab') {
			var mm = mouse_position();
			if ((mm['x'] != windowWsMouseMove['x'] && mm['y'] != windowWsMouseMove['y']) || ( mm['lastTs'] < now - windowResendInterval)) {
				// the geometry only: an act opening or closing is appActSync()'s
				// message, so a panel toggle does not dirty the layout blob
				var windows_json = windowSaver(1);
				// only ship the layout when it actually changed
				if (windows_json != windowWsWindows) {
					windowWsWindows = windows_json;
					data['windows'] = windows_json;
				}
				windowWsMouseMove = mm;
			}
			// The localStorage debrief is for auditing, not for liveness. The
			// snapshot is a whole-store blob written to a ticket row, so only ship
			// it when the store actually moved since the last one.
			if (now - windowWsDebriefer > debrieferInterval) {
				windowWsDebriefer = now;
				var debrief = JSON.stringify(localStorage);
				if (debrief != windowWsDebrieferJson) {
					windowWsDebrieferJson = debrief;
					data['debriefer'] = debrief;
				}
			}
			// A start or stop pushes the header once. A tab that was reconnecting
			// can miss that one frame, so name the version each open window is
			// wearing; the server answers any newer header on this beat.
			var seen_headers = {};
			$('.wind').each(function () {
				var ha = $(this).attr('app');
				if (!ha) { return; }
				var hh = $(this).find('.appointment_header_background');
				if (!hh.length) { return; }
				seen_headers[ha] = hh.attr('last_updated') || hh.attr('last_update') || '';
			});
			data['headers_at'] = seen_headers;
		}
		// The music socket now beats on pages that never opened the music app. A
		// track on screen is the only thing the writer can report: the window
		// closing takes its play element with it, the media lock clears
		// tree.sound, and either way the writer would read empty selectors and
		// send a hollow record that other devices draw as "undefined". Report
		// nothing in that case, so this tab drops out of their music list until
		// the player has a track again.
		else if (app == 'music' || apper == 'music') {
			if (tree['music_data'] != undefined && tree.sound && $('.track_item.playing').length) {
				tree['music_data'] = musicAppointmentWriter('data_entry');
				data['music_data'] = tree['music_data']
			}
			else if (tree['music_data'] != undefined) {
				tree['music_data'] = '';
				data['music_data'] = '';
			}
		}
		else if ((app == 'server' || apper == 'server')) {
			data['ws'] = [];
			$.each(ws, function(i,v) {
				data['ws'].push(i);
			});
			if (advertise_watching == 'on') {
				data['jp_data'] = jpWatcher();
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

// Ask for a liveness round trip now instead of waiting for the scheduled beat.
// A panel that has just finished drawing calls this, so the server writes the
// fresh row and answers with the current neighbour list at once.
function stayingAliveNow(app) {
	app = app || 'server';
	var socket = ws[app];
	if (!socket || socket.readyState != 1) {
		if (!document.hidden) { websocketStart(); }
		return false;
	}
	heartbeatSend(app);
	return true;
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

