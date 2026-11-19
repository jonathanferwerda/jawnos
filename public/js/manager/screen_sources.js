/* The desktop app's screen picker.
 *
 * A page cannot enumerate screens or windows: getDisplayMedia normally asks
 * the embedder to show its own picker. The Qt shell instead hands the request's
 * screen/window model to the page, so a JawnOS panel can show a plain select.
 * The page asks for the list (a preflight getDisplayMedia the shell cancels),
 * then names the chosen row before the real capture. A browser with no desktop
 * bridge falls back to the browser's own getDisplayMedia picker.
 *
 * The shell calls window.jawnosScreenSources({sources: [...]}) while a
 * preflight request is pending. Each source is {id, kind, index, label}.
 */
(function () {
	'use strict';

	var sources = null;
	var listing = null;
	var pending = null;
	var ready = [];

	function bridge() {
		try {
			return (window.webkit && window.webkit.messageHandlers &&
				window.webkit.messageHandlers.jawnos) || null;
		} catch (e) {
			return null;
		}
	}

	function available() {
		return !!bridge();
	}

	function post(action, data) {
		var handler = bridge();
		if (!handler) { return false; }
		data = data || {};
		data.action = action;
		try {
			handler.postMessage(JSON.stringify(data));
			return true;
		} catch (e) {
			return false;
		}
	}

	// The shell calls this once it has stored what the page asked for, so the
	// media request cannot overtake screen_list or screen_want on the bridge.
	window.jawnosScreenReady = function () {
		var next = ready.shift();
		if (next) { next(); }
	};

	function whenReady(action, data) {
		return new Promise(function (resolve) {
			ready.push(resolve);
			post(action, data);
			setTimeout(resolve, 300);
		});
	}

	// The shell's answer to screen_list: the rows of its pending request.
	window.jawnosScreenSources = function (payload) {
		var rows = (payload && payload.sources) || [];
		sources = rows;
		if (pending) {
			var done = pending;
			pending = null;
			done(rows);
		}
	};

	// The rows are keyed by a stable per-request string (screen:0, window:2)
	// because Qt's model has display names only; the shell finds the row by
	// that key, then falls back to the name, then to the first screen.
	function list() {
		if (!available()) { return Promise.resolve([]); }
		if (sources) { return Promise.resolve(sources); }
		if (listing) { return listing; }
		listing = whenReady('screen_list').then(function () {
			var media = navigator.mediaDevices;
			if (!media || !media.getDisplayMedia) { return []; }
			return new Promise(function (resolve) {
				pending = resolve;
				// The shell set list mode before it called ready, so this request
				// is held open and answered with the model's rows.
				media.getDisplayMedia({ video: true, audio: false }).then(function (stream) {
					stream.getTracks().forEach(function (track) {
						try { track.stop(); } catch (e) {}
					});
					// The shell may already have answered; if not, it will.
				}).catch(function () {
					// A cancelled preflight is the normal path.
				});
				// A shell that does not answer must not leave the panel waiting.
				setTimeout(function () {
					if (pending === resolve) {
						pending = null;
						resolve([]);
					}
				}, 2500);
			});
		}).then(function (rows) {
			post('screen_cancel');
			listing = null;
			return rows;
		});
		return listing;
	}

	// Capture the chosen source. The shell selects that row of the request;
	// without the bridge the browser's own picker decides.
	function capture(id) {
		var media = navigator.mediaDevices;
		if (!media || !media.getDisplayMedia) {
			return Promise.reject(new Error('screen capture is not available'));
		}
		var start = function () {
			return media.getDisplayMedia({
				video: { displaySurface: 'monitor' },
				audio: true
			});
		};
		if (!available()) { return start(); }
		return whenReady('screen_want', { id: String(id || '') }).then(start);
	}

	window.JawnScreen = {
		available: available,
		list: list,
		capture: capture,
		refresh: function () {
			sources = null;
			return list();
		}
	};
})();
