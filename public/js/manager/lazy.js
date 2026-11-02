// Lazy app scripts.
//
// The page used to download every manager script before the desktop appeared.
// Now the core bundle carries only what a window needs before an app is opened;
// an app's own scripts arrive from /js/manager/app.js the first time the app is
// used, and are never requested again on this page.
//
// Three pieces make that safe:
//
//   * jawnosLoadApp queues a request and runs the callback after the chunk has
//     executed. One request is in flight at a time, so two apps that share a
//     script (the synth in Studio, the travel markers) cannot execute it twice.
//   * The start-menu icons/menu rows are drawn by the server, but each app used
//     to register its own click handler inside its script. The click dispatcher
//     below catches the first one, loads the chunk, then replays the click so
//     the app's own handler (or the Handbook's core handler) runs for real.
//   * Some core code calls an app function directly (Handbook's Today cards,
//     People opening Relational). The stubs installed here load the app and then
//     call the real definition, which replaces the stub when the chunk runs.
//
// JavaScript that has run cannot be unloaded from the page; this keeps it out of
// the page until it is needed. Closing an app releases its runtime objects where
// the app does that itself.

var jawnos_loaded_scripts = {};
var jawnos_load_busy = false;
var jawnos_load_queue = [];
var jawnos_toggle_replay = false;
var jawnos_toggle_pending = {};

function jawnosAppFiles(app) {
	var map = window.jawnos_app_scripts || {};
	return map[app] || [];
}

function jawnosAppIsLoaded(app) {
	var files = jawnosAppFiles(app);
	if (!files.length) { return true; }
	for (var i = 0; i < files.length; i++) {
		if (!jawnos_loaded_scripts[files[i]]) { return false; }
	}
	return true;
}

function jawnosLoadApp(app, callback) {
	if (jawnosAppIsLoaded(app)) {
		if (typeof callback === 'function') { callback(); }
		return;
	}
	jawnos_load_queue.push({ app: app, callback: callback });
	jawnosLoadPump();
}

function jawnosPrefetchApp(app) {
	jawnosLoadApp(app, null);
}

function jawnosLoadPump() {
	if (jawnos_load_busy || !jawnos_load_queue.length) { return; }
	var job = jawnos_load_queue.shift();
	var files = jawnosAppFiles(job.app);
	var need = [];
	for (var i = 0; i < files.length; i++) {
		if (!jawnos_loaded_scripts[files[i]]) { need.push(files[i]); }
	}
	if (!need.length) {
		jawnosCall(job);
		jawnosLoadPump();
		return;
	}
	jawnos_load_busy = true;
	var key = need.join(',');
	var script = document.createElement('script');
	script.src = '/js/manager/app.js?files=' + encodeURIComponent(key) + '&string=' + encodeURIComponent(window.jawnos_version || '');
	script.async = true;
	script.onload = function () {
		for (var i = 0; i < need.length; i++) { jawnos_loaded_scripts[need[i]] = 1; }
		jawnos_load_busy = false;
		jawnosCall(job);
		jawnosLoadPump();
	};
	script.onerror = function () {
		// Leave the scripts unmarked so the next press retries. The app does not
		// open this time; a failed chunk is a network problem, not a lost click.
		jawnos_load_busy = false;
		delete jawnos_toggle_pending[job.app];
		console.error('jawnos: could not load scripts for ' + job.app + ' (' + key + ')');
		jawnosLoadPump();
	};
	document.head.appendChild(script);
}

function jawnosCall(job) {
	if (typeof job.callback !== 'function') { return; }
	try { job.callback(); }
	catch (e) { console.error('jawnos: lazy app ' + job.app, e); }
}

// The first click on a lazy app's icon, before its script is there. Returns the
// app and the id/class token that matched, so the replay can find the icon
// again if the start menu was re-rendered while the chunk was loading.
function jawnosToggleApp(el) {
	var map = window.jawnos_toggle_apps || {};
	var node = el;
	for (var depth = 0; depth < 5 && node && node.nodeType === 1; depth++) {
		var id = node.id || '';
		if (id && map[id]) { return { app: map[id], token: id }; }
		var cls = (node.getAttribute ? node.getAttribute('class') : '') || '';
		cls = cls.split(/\s+/);
		for (var i = 0; i < cls.length; i++) {
			if (cls[i] && map[cls[i]]) { return { app: map[cls[i]], token: cls[i] }; }
		}
		node = node.parentNode;
	}
	return null;
}

function jawnosToggleTarget(el, token) {
	if (el && document.documentElement.contains(el)) { return $(el); }
	if (!token) { return $([]); }
	var again = $('#' + token);
	if (again.length) { return again.first(); }
	return $('.' + token).first();
}

$(document).on('click', function (e) {
	if (jawnos_toggle_replay) { return; }
	var hit = jawnosToggleApp(e.target);
	if (!hit || jawnosAppIsLoaded(hit.app)) { return; }
	e.preventDefault();
	e.stopImmediatePropagation();
	var app = hit.app;
	if (jawnos_toggle_pending[app]) { return; }
	jawnos_toggle_pending[app] = 1;
	var el = e.target;
	if (typeof jawnosLoadingPulse === 'function') {
		jawnosLoadingPulse($(el).closest('.start_menu_item'));
	}
	jawnosLoadApp(app, function () {
		delete jawnos_toggle_pending[app];
		var target = jawnosToggleTarget(el, hit.token);
		jawnos_toggle_replay = true;
		try {
			if (target.length) { target.trigger('click'); }
			else if (typeof appWindowOpener === 'function') { appWindowOpener(app, Date.now(), { visible: 'yes' }); }
		}
		finally { jawnos_toggle_replay = false; }
	});
});

// A press is a better prefetch than hover: the click is already on its way, so
// the chunk is usually in place by the time the click handler runs.
$(document).on('pointerdown mousedown touchstart', function (e) {
	var hit = jawnosToggleApp(e.target);
	if (hit && !jawnosAppIsLoaded(hit.app)) { jawnosPrefetchApp(hit.app); }
});

// Stubs for the entry points core code may call directly. The app's own
// definition replaces the stub when the chunk executes.
(function () {
	var entries = window.jawnos_app_entry || {};
	for (var app in entries) {
		if (!entries.hasOwnProperty(app)) { continue; }
		var names = entries[app] || [];
		for (var i = 0; i < names.length; i++) {
			(function (app, name) {
				if (typeof window[name] === 'function') { return; }
				var stub = function () {
					var args = arguments;
					var self = this;
					jawnosLoadApp(app, function () {
						if (window[name] === stub) {
							console.error('jawnos: ' + app + ' loaded without defining ' + name);
							return;
						}
						window[name].apply(self, args);
					});
				};
				window[name] = stub;
			})(app, names[i]);
		}
	}
})();
