// A local liveness watch beside the heartbeat. The beat is a network round trip
// every ten seconds, and only the server's answer proves a socket is real; this
// watch costs no network at all. It reads the wall clock and the age of the last
// frame each socket actually heard, so two failures the events miss are caught:
//
//   - a machine that slept. A resume does not always arrive as visibilitychange
//     or focus (a WebKitGTK desktop waking, a WebView whose screen was off), but
//     a suspended process cannot run timers, so the first tick after the gap sees
//     a clock jump. That is the wake signal, whatever the engine forgot to send.
//   - a socket that still reads OPEN while the server has gone silent - the
//     phone that changed networks, the worker that restarted. One late beat is
//     probed at once; a probe that is not answered rebuilds the sockets.
//
// The names stay clear of websocketWake/websocketFront/websocketRetry on
// purpose: this is the only watcher that polls, and a test pins that the others
// do not.

var wsWatchdogPeriod = 1000;
var wsWatchdogProbeWait = 8000;
var wsWatchdogConnectGrace = 8000;
var wsWatchdogTimer = 0;
var wsWatchdogLast = 0;
// The app sockets that have opened at least once. A reopen is a reconnect, and
// a reconnect is the only time the page can have missed a frame.
var wsOpenedBefore = {};
var wsResyncTimer = 0;

function wsWatchdogStart() {
	if (wsWatchdogTimer) { return; }
	wsWatchdogLast = Date.now();
	wsWatchdogTimer = setInterval(wsWatchdogTick, wsWatchdogPeriod);
}

function wsWatchdogStop() {
	if (wsWatchdogTimer) {
		clearInterval(wsWatchdogTimer);
		wsWatchdogTimer = 0;
	}
}

function wsWatchdogTick() {
	var now = Date.now();
	var since = now - (wsWatchdogLast || now);
	wsWatchdogLast = now;
	if (document.hidden || windowVisible != 1) { return; }
	// The process was suspended: timers do not run while the machine sleeps, so
	// a gap much wider than the tick is a wake that no event announced. A long
	// blocking script looks the same from here, but a beat was missed either way
	// and the honest answer - a fresh handshake - is the same for both.
	if (since > stayingAliveInterval * 2 && websocketLooksDead()) {
		websocketRebuild();
		return;
	}
	var apps = Object.keys(ws);
	if (apps.length == 0) {
		// never poll around the paced retry: it owns the next attempt
		if (!wsRetryTimer) { websocketStart(); }
		return;
	}
	var rebuild = 0;
	for (var i = 0; i < apps.length; i++) {
		var app = apps[i];
		var socket = ws[app];
		if (!socket) { rebuild = 1; continue; }
		if (socket.readyState == 0) {
			// a handshake that never completes is a listener that moved or a
			// network that dropped it; retry instead of waiting forever
			if (!socket['connectingAt']) { socket['connectingAt'] = now; }
			if (now - socket['connectingAt'] > wsWatchdogConnectGrace) { rebuild = 1; }
			continue;
		}
		if (socket.readyState != 1) { rebuild = 1; continue; }
		var heard = socket['ackAt'] || socket['stayingAlive'] || 0;
		var age = now - heard;
		if (age > stayingAliveInterval * 2) { rebuild = 1; continue; }
		if (age > stayingAliveInterval) {
			// A beat is late: probe now, and once more before calling the socket
			// dead. A tree that is restarting, or a worker under load, answers
			// late; one unanswered probe must not tear down every socket and
			// make the page pay a full reconnect for a transient delay.
			// Any inbound frame clears probedAt and probeCount (wsTouched).
			if (!socket['probedAt']) {
				socket['probedAt'] = now;
				socket['probeCount'] = 1;
				heartbeatSend(app);
			}
			else if (now - socket['probedAt'] > wsWatchdogProbeWait) {
				if ((socket['probeCount'] || 1) < 2) {
					socket['probeCount'] = (socket['probeCount'] || 1) + 1;
					socket['probedAt'] = now;
					heartbeatSend(app);
				}
				else {
					rebuild = 1;
				}
			}
		}
	}
	if (rebuild) { websocketRebuild(); }
}

// Every inbound frame is proof of life, not only the liveness ack: a header, a
// console instruction or a notification all mean the link just carried bytes.
function wsTouched(app) {
	if (!ws[app]) { return; }
	ws[app]['ackAt'] = Date.now();
	delete ws[app]['probedAt'];
	delete ws[app]['probeCount'];
	delete ws[app]['connectingAt'];
}

// A socket that came back may have missed the frames that moved the screen
// while it was gone - above all the appointment header a start or stop sends.
// Ask for the open windows' current headers once, after a short debounce, so a
// rebuild of three sockets asks once rather than three times. The first open of
// a page asks nothing: the page arrived already rendered.
function wsResyncSoon() {
	if (wsResyncTimer) { clearTimeout(wsResyncTimer); }
	wsResyncTimer = setTimeout(function () {
		wsResyncTimer = 0;
		// A laptop that woke missed the frames a screening sent while it slept;
		// the panel asks the gateway for the call's state before it re-lists the
		// windows, so Connect me is there on the device just opened.
		if (typeof jawnScreenPoll === 'function') { jawnScreenPoll(); }
		wsResync();
	}, 400);
}

function wsResync() {
	if (document.hidden) { return; }
	// the tab socket owns the layout and headers; another open socket can carry
	// the request when it is the one that came back
	var chosen = '';
	var apps = Object.keys(ws);
	for (var i = 0; i < apps.length; i++) {
		var s = ws[apps[i]];
		if (!s || s.readyState != 1) { continue; }
		if (!chosen || apps[i] == 'tab') { chosen = apps[i]; }
		if (apps[i] == 'tab') { break; }
	}
	if (!chosen) { return; }
	var open_apps = [];
	$('.wind').each(function () {
		var a = $(this).attr('app');
		if (a && open_apps.indexOf(a) < 0) { open_apps.push(a); }
	});
	if (open_apps.length > 30) { open_apps = open_apps.slice(0, 30); }
	ws[chosen].send(JSON.stringify({
		type: 'resync',
		app: chosen,
		browser_tab_id: sessionStorage.getItem('browser_tab_id') || '',
		browser_tab: localStorage.getItem('browser_tab') || '',
		timestamp: Date.now(),
		apps: open_apps,
		theme: 1
	}));
}

// The doctor's answer for a support call: one call shows whether the sockets are
// open, how long each has been quiet, and whether a retry is pending. It reads
// only, so asking costs nothing.
function jawnosWebsocketStatus() {
	var now = Date.now();
	var out = { visible: (windowVisible == 1 && !document.hidden) ? 1 : 0, retry_pending: wsRetryTimer ? 1 : 0, failures: wsRetryFailures, sockets: {} };
	Object.keys(ws).forEach(function (app) {
		var s = ws[app];
		out.sockets[app] = {
			ready_state: s ? s.readyState : -1,
			quiet_ms: (s && s['ackAt']) ? (now - s['ackAt']) : null,
			status: (s && s['status']) || ''
		};
	});
	return out;
}
