// The desk's own copy of the windows it can paint without asking the house.
//
// A reload used to ask for every open window separately (appWindowOpenerNow), so
// the desk waited on the manager's render queue - the slowest thing on a busy box
// - before it had a taskbar row or a window to look at. The shells a window was
// last seen with are kept here instead: the window chrome, its appointment
// controls and the header it last wore. A reload installs the shell at once and
// the server's own render replaces it when it lands. The store also holds the
// press-time preview (06_emerge.js), so one record per app serves both.
//
// Everything on the disk is sealed with AES-GCM under a device key that never
// leaves IndexedDB (a non-extractable CryptoKey), and the record's key is a
// SHA-256 of the app's identity, so the store does not even name the apps it
// keeps. A private app is never written at all: window_maker marks it
// data-private and the capture refuses it, which is the same rule the server's
// cache follows (a hidden app never reads a cached render).
//
// A window's identity is its app plus its session id and its named window id, so
// Terminal and Folders keep one shell per instance. A preview is per app, so it
// writes the empty-suffix identity; that is also the one-shell identity of every
// single-window app.
var JAWNOS_WINDOWS_DB = 'jawnos_windows';
var JAWNOS_WINDOWS_VERSION = 1;
var JAWNOS_WINDOWS_STORE = 'windows';
var JAWNOS_WINDOWS_KEYS = 'keys';
var JAWNOS_WINDOWS_KEY_ID = 'payload';
var JAWNOS_WINDOWS_META_ID = 'meta';
// The same budget the preview store kept: thirty-two apps is a day's desk with
// the room a fifth more asks for, and fifty megabytes is the whole store. The
// oldest go first when either limit is reached.
var JAWNOS_WINDOWS_MAX_APPS = 32;
var JAWNOS_WINDOWS_MAX_BYTES = 52428800;
// One window's markup: a gallery with its photographs trimmed is ~40KB and a
// heavy app a couple of hundred, so 1.5MB is a whole window of any of them.
var JAWNOS_WINDOWS_MAX_WINDOW_BYTES = 1500000;
// A photograph embedded in a window is no part of a shell that has to be
// restored: the box stays, the picture is a blank of the same size.
var JAWNOS_WINDOWS_IMAGE = 8000;
var JAWNOS_WINDOWS_BLANK = 'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';

var jawnosWindowsDb = null;
var jawnosWindowsReadyPromise = null;
var jawnosWindowsKeyCache = null;
// Reads and writes run one after another: a preview save and the shell capture
// that accompanies it are two patches of the same record, and a lost update
// would drop whichever field was written first.
var jawnosWindowsWriteChain = Promise.resolve();
var jawnosWindowsCaptureTimers = {};
var jawnosWindowsEncoder = (typeof TextEncoder == 'function') ? new TextEncoder() : null;
var jawnosWindowsDecoder = (typeof TextDecoder == 'function') ? new TextDecoder() : null;
var jawnosWindowsOldStoreRetired = 0;

function jawnosWindowsSupported() {
	return !!(window.indexedDB && window.crypto && window.crypto.subtle && jawnosWindowsEncoder && jawnosWindowsDecoder);
}

// The machine's own identity, the person signed in when the page was rendered,
// and the build that wrote the shells. A cache from another house, another
// session or another build can never be read back: a scope change wipes the
// store and mints a new key. The build belongs in the scope because a shell is
// markup painted before the server answers - one from the previous build shows
// last build's chrome around a freshly rendered window until it is closed and
// opened again. A plain restart keeps the same build, so its shells survive;
// an update changes the build and reaps them.
function jawnosWindowsScope() {
	var machine = '';
	var person = '';
	var build = '';
	try { machine = String(window.signatorial || ''); } catch (e) { machine = ''; }
	try { person = String(window.jawnos_session_scope || ''); } catch (e) { person = ''; }
	try { build = String(window.jawnos_version || ''); } catch (e) { build = ''; }
	return machine + '|' + person + '|' + build;
}

// Private mode is never written to the disk. A private place, or an open private
// grant, turns the store off for every app - not just a private one - because a
// public window opened there may still carry what the place holds, and reopening
// it in public must not reveal that. The page carries both marks; the server also
// writes one onto each window it renders in a private place, so a window built
// under the grant is refused even before the page's own toggle catches up.
function jawnosWindowsPublicNow(el) {
	if (typeof document == 'undefined' || !document.body) { return true; }
	if (typeof $ == 'function' && el) { el = $(el)[0]; }
	var body = document.body;
	if (body.getAttribute) {
		if (body.getAttribute('data-private-place') === 'yes') { return false; }
		if (body.getAttribute('data-private-mode') === 'yes') { return false; }
	}
	if (el && el.getAttribute && el.getAttribute('data-private-mode') === 'yes') { return false; }
	return true;
}

function jawnosWindowsIdb() {
	if (jawnosWindowsDb) { return Promise.resolve(jawnosWindowsDb); }
	return new Promise(function (res, rej) {
		var request = indexedDB.open(JAWNOS_WINDOWS_DB, JAWNOS_WINDOWS_VERSION);
		request.onupgradeneeded = function () {
			var db = request.result;
			if (!db.objectStoreNames.contains(JAWNOS_WINDOWS_STORE)) {
				db.createObjectStore(JAWNOS_WINDOWS_STORE, { keyPath: 'k' });
			}
			if (!db.objectStoreNames.contains(JAWNOS_WINDOWS_KEYS)) {
				db.createObjectStore(JAWNOS_WINDOWS_KEYS);
			}
		};
		request.onsuccess = function () {
			jawnosWindowsDb = request.result;
			// a later version of the page (or another tab) asking for an upgrade
			// must not be held back by this connection
			jawnosWindowsDb.onversionchange = function () {
				try { jawnosWindowsDb.close(); } catch (e) {}
				jawnosWindowsDb = null;
			};
			res(jawnosWindowsDb);
		};
		request.onerror = function () { rej(request.error); };
	});
}

function jawnosWindowsMetaGet(db) {
	return new Promise(function (res, rej) {
		var query = db.transaction(JAWNOS_WINDOWS_KEYS, 'readonly').objectStore(JAWNOS_WINDOWS_KEYS).get(JAWNOS_WINDOWS_META_ID);
		query.onsuccess = function () { res(query.result || null); };
		query.onerror = function () { rej(query.error); };
	});
}

function jawnosWindowsKeyGet(db) {
	return new Promise(function (res, rej) {
		var query = db.transaction(JAWNOS_WINDOWS_KEYS, 'readonly').objectStore(JAWNOS_WINDOWS_KEYS).get(JAWNOS_WINDOWS_KEY_ID);
		query.onsuccess = function () { res(query.result || null); };
		query.onerror = function () { rej(query.error); };
	});
}

function jawnosWindowsKeyPut(db, key) {
	return new Promise(function (res, rej) {
		var tx = db.transaction(JAWNOS_WINDOWS_KEYS, 'readwrite');
		tx.objectStore(JAWNOS_WINDOWS_KEYS).put(key, JAWNOS_WINDOWS_KEY_ID);
		tx.oncomplete = function () { res(key); };
		tx.onerror = function () { rej(tx.error); };
	});
}

function jawnosWindowsMetaPut(db, meta) {
	return new Promise(function (res, rej) {
		var tx = db.transaction(JAWNOS_WINDOWS_KEYS, 'readwrite');
		tx.objectStore(JAWNOS_WINDOWS_KEYS).put(meta, JAWNOS_WINDOWS_META_ID);
		tx.oncomplete = function () { res(meta); };
		tx.onerror = function () { rej(tx.error); };
	});
}

function jawnosWindowsWipe(db) {
	jawnosWindowsKeyCache = null;
	return new Promise(function (res) {
		var tx = db.transaction([JAWNOS_WINDOWS_STORE, JAWNOS_WINDOWS_KEYS], 'readwrite');
		try {
			tx.objectStore(JAWNOS_WINDOWS_STORE).clear();
			tx.objectStore(JAWNOS_WINDOWS_KEYS).clear();
		}
		catch (e) {}
		tx.oncomplete = function () { res(); };
		tx.onerror = function () { res(); };
	});
}

// The key is made once per scope and kept in the same database. It is not
// extractable, so a copied database yields nothing without this profile's key.
function jawnosWindowsReady() {
	if (jawnosWindowsKeyCache) { return Promise.resolve(jawnosWindowsKeyCache); }
	if (jawnosWindowsReadyPromise) { return jawnosWindowsReadyPromise; }
	if (!jawnosWindowsSupported()) { return Promise.reject(new Error('no indexeddb')); }
	// The old preview store held plaintext markup, including whatever window
	// was last settled (a private app's, before this rule). It is never read
	// again: remove it once, when the sealed store first opens.
	if (!jawnosWindowsOldStoreRetired) {
		jawnosWindowsOldStoreRetired = 1;
		try { indexedDB.deleteDatabase('jawn_emerge'); } catch (e) {}
	}
	jawnosWindowsReadyPromise = jawnosWindowsIdb().then(function (db) {
		return jawnosWindowsMetaGet(db).then(function (meta) {
			return jawnosWindowsKeyGet(db).then(function (key) {
				var scope = jawnosWindowsScope();
				if (key && meta && meta.scope === scope && meta.v === JAWNOS_WINDOWS_VERSION) {
					jawnosWindowsKeyCache = key;
					return key;
				}
				// no key, or one for another machine or person: the old ciphertext
				// can never be opened again, so it goes rather than lingering
				return jawnosWindowsWipe(db).then(function () {
					return jawnosWindowsMetaPut(db, { scope: scope, v: JAWNOS_WINDOWS_VERSION });
				}).then(function () {
					return crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
				}).then(function (fresh) {
					return jawnosWindowsKeyPut(db, fresh);
				}).then(function (fresh) {
					jawnosWindowsKeyCache = fresh;
					return fresh;
				});
			});
		});
	});
	jawnosWindowsReadyPromise.then(null, function () { jawnosWindowsReadyPromise = null; });
	return jawnosWindowsReadyPromise;
}

// The store's key: a hash of the identity, so a record does not name its app on
// the disk. The payload is sealed under a fresh IV on every write.
function jawnosWindowsHash(text) {
	return crypto.subtle.digest('SHA-256', jawnosWindowsEncoder.encode(String(text))).then(function (buffer) {
		var bytes = new Uint8Array(buffer);
		var out = '';
		for (var i = 0; i < bytes.length; i++) { out += ('0' + bytes[i].toString(16)).slice(-2); }
		return out;
	});
}

function jawnosWindowsSeal(key, value) {
	var bytes = jawnosWindowsEncoder.encode(JSON.stringify(value));
	var iv = crypto.getRandomValues(new Uint8Array(12));
	return crypto.subtle.encrypt({ name: 'AES-GCM', iv: iv }, key, bytes).then(function (ciphertext) {
		return { iv: iv.buffer, ct: ciphertext };
	});
}

function jawnosWindowsUnseal(key, row) {
	if (!row || !row.iv || !row.ct) { return Promise.resolve(null); }
	return crypto.subtle.decrypt({ name: 'AES-GCM', iv: new Uint8Array(row.iv) }, key, row.ct)
		.then(function (buffer) {
			return JSON.parse(jawnosWindowsDecoder.decode(new Uint8Array(buffer)));
		})
		.then(null, function () { return null; });
}

function jawnosWindowsRowGet(k) {
	return jawnosWindowsIdb().then(function (db) {
		return new Promise(function (res, rej) {
			var query = db.transaction(JAWNOS_WINDOWS_STORE, 'readonly').objectStore(JAWNOS_WINDOWS_STORE).get(k);
			query.onsuccess = function () { res(query.result || null); };
			query.onerror = function () { rej(query.error); };
		});
	});
}

function jawnosWindowsRowPut(row) {
	return jawnosWindowsIdb().then(function (db) {
		return new Promise(function (res, rej) {
			var tx = db.transaction(JAWNOS_WINDOWS_STORE, 'readwrite');
			tx.objectStore(JAWNOS_WINDOWS_STORE).put(row);
			tx.oncomplete = function () { res(true); };
			tx.onerror = function () { rej(tx.error); };
		});
	});
}

function jawnosWindowsRowDelete(k) {
	return jawnosWindowsIdb().then(function (db) {
		return new Promise(function (res, rej) {
			var tx = db.transaction(JAWNOS_WINDOWS_STORE, 'readwrite');
			tx.objectStore(JAWNOS_WINDOWS_STORE).delete(k);
			tx.oncomplete = function () { res(true); };
			tx.onerror = function () { rej(tx.error); };
		});
	});
}

// A window's identity: the app, its terminal session, and its named window (the
// two ways this codebase tells several windows of one app apart).
function jawnosWindowsIdentity(app, v) {
	v = v || {};
	return String(app || '') + '|' + String(v.terminal_id || '') + '|' + String(v.window_id || '');
}

function jawnosWindowsIdentityOf(el) {
	if (!el || !el.getAttribute) { return ''; }
	var app = el.getAttribute('app') || '';
	if (!app) { return ''; }
	return app + '|' + (el.getAttribute('data-terminal-id') || '') + '|' + (el.getAttribute('data-window-id') || '');
}

// Read-modify-write, one at a time, so a header capture and a preview save of
// the same app cannot erase each other. A failed write is swallowed: a full
// disk or a closed connection must never take the window down with it.
function jawnosWindowsSave(identity, patch) {
	var run = function () {
		if (!identity || !patch) { return Promise.resolve(false); }
		return jawnosWindowsReady().then(function (key) {
			return jawnosWindowsHash(identity).then(function (k) {
				return jawnosWindowsRowGet(k).then(function (row) {
					return jawnosWindowsUnseal(key, row);
				}).then(function (value) {
					value = (value && typeof value == 'object') ? value : {};
					for (var field in patch) {
						if (patch.hasOwnProperty(field)) { value[field] = patch[field]; }
					}
					// the write itself is the use: the prune keeps what was touched last
					value.at = (patch.at !== undefined && patch.at !== null) ? patch.at : Date.now();
					value.identity = identity;
					return jawnosWindowsSeal(key, value).then(function (sealed) {
						// A window shell and preview are markup; the timeline's view
						// (07_timeshift.js) is one JSON object of its own, so it is counted
						// by that. A shell-only patch pays nothing for the branch.
						return jawnosWindowsRowPut({
							k: k,
							iv: sealed.iv,
							ct: sealed.ct,
							at: value.at,
							bytes: (String(value.shell || '')).length + (String(value.preview || '')).length
								+ (value.view ? JSON.stringify(value.view).length : 0)
						});
					});
				});
			});
		}).then(null, function () { return false; });
	};
	jawnosWindowsWriteChain = jawnosWindowsWriteChain.then(run, run);
	return jawnosWindowsWriteChain;
}

function jawnosWindowsGet(identity) {
	if (!identity) { return Promise.resolve(null); }
	return jawnosWindowsReady().then(function (key) {
		return jawnosWindowsHash(identity).then(function (k) {
			return jawnosWindowsRowGet(k).then(function (row) {
				return jawnosWindowsUnseal(key, row);
			});
		});
	}).then(null, function () { return null; });
}

function jawnosWindowsAll() {
	return jawnosWindowsReady().then(function (key) {
		return jawnosWindowsIdb().then(function (db) {
			return new Promise(function (res, rej) {
				var query = db.transaction(JAWNOS_WINDOWS_STORE, 'readonly').objectStore(JAWNOS_WINDOWS_STORE).getAll();
				query.onsuccess = function () { res(query.result || []); };
				query.onerror = function () { rej(query.error); };
			});
		}).then(function (rows) {
			return Promise.all(rows.map(function (row) { return jawnosWindowsUnseal(key, row); }));
		}).then(function (values) {
			var out = [];
			for (var i = 0; i < values.length; i++) {
				if (values[i] && typeof values[i] == 'object') { out.push(values[i]); }
			}
			return out;
		});
	}).then(null, function () { return []; });
}

function jawnosWindowsDelete(identity) {
	if (!identity) { return Promise.resolve(false); }
	var run = function () {
		return jawnosWindowsHash(identity).then(function (k) {
			return jawnosWindowsRowDelete(k);
		}).then(null, function () { return false; });
	};
	jawnosWindowsWriteChain = jawnosWindowsWriteChain.then(run, run);
	return jawnosWindowsWriteChain;
}

// The oldest go first, by the time they were last written, and the store is also
// held to the bytes it takes rather than only to a count.
function jawnosWindowsPrune() {
	var run = function () {
		return jawnosWindowsIdb().then(function (db) {
			return new Promise(function (res, rej) {
				var query = db.transaction(JAWNOS_WINDOWS_STORE, 'readonly').objectStore(JAWNOS_WINDOWS_STORE).getAll();
				query.onsuccess = function () { res(query.result || []); };
				query.onerror = function () { rej(query.error); };
			});
		}).then(function (rows) {
			rows.sort(function (a, b) { return (b.at || 0) - (a.at || 0); });
			var held = 0;
			var drop = [];
			for (var i = 0; i < rows.length; i++) {
				held += (rows[i].bytes || 0);
				if (i < JAWNOS_WINDOWS_MAX_APPS && held <= JAWNOS_WINDOWS_MAX_BYTES) { continue; }
				drop.push(rows[i].k);
			}
			return Promise.all(drop.map(function (k) { return jawnosWindowsRowDelete(k); }));
		}).then(function () { return true; })
		  .then(null, function () { return false; });
	};
	jawnosWindowsWriteChain = jawnosWindowsWriteChain.then(run, run);
	return jawnosWindowsWriteChain;
}

// Nothing live belongs in a restorable shell: no scripts, no sound, no second
// page loading behind it. The handlers stay - the shell is the real window - but
// a stored video or iframe source would start over on the next reload.
function jawnosWindowsShellSanitize(node) {
	if (!node || node.nodeType !== 1) { return node; }
	var children = node.children || [];
	for (var i = children.length - 1; i >= 0; i--) {
		var child = children[i];
		if (!child) { continue; }
		var tag = String(child.tagName || '').toUpperCase();
		if (tag == 'SCRIPT' || tag == 'NOSCRIPT') {
			if (node.removeChild) { node.removeChild(child); }
			continue;
		}
		if (tag == 'VIDEO' || tag == 'AUDIO' || tag == 'IFRAME' || tag == 'OBJECT' || tag == 'EMBED') {
			if (child.removeAttribute) {
				child.removeAttribute('src');
				child.removeAttribute('data');
				child.removeAttribute('autoplay');
			}
		}
		if (tag == 'IMG' && child.getAttribute && child.setAttribute) {
			var src = child.getAttribute('src') || '';
			if (src.length > JAWNOS_WINDOWS_IMAGE && /^data:/i.test(src)) {
				child.setAttribute('src', JAWNOS_WINDOWS_BLANK);
			}
		}
		jawnosWindowsShellSanitize(child);
	}
	return node;
}

// A window's ids are minted from its timestamp, and the restore gives it a new
// one. The stored markup is re-stamped as one string: the stamp appears in ids,
// attributes, inline handlers and the window's own script, so a single pass over
// the text moves all of them together.
function jawnosWindowsRestamp(html, from, to) {
	if (!html || !from || !to) { return html || ''; }
	from = String(from);
	to = String(to);
	if (from === to) { return html; }
	return String(html).split(from).join(to);
}

function jawnosWindowsHasWindow(identity) {
	if (!identity || typeof $ != 'function') { return false; }
	var parts = identity.split('|');
	var app = parts[0] || '';
	var terminal = parts[1] || '';
	var instance = parts[2] || '';
	if (!app) { return false; }
	var found = false;
	$('.wind').each(function () {
		if ($(this).attr('app') !== app) { return; }
		if (terminal && ($(this).attr('data-terminal-id') || '') !== terminal) { return; }
		if (instance && ($(this).attr('data-window-id') || '') !== instance) { return; }
		found = true;
		return false;
	});
	return found;
}

// One window as it was last seen: its markup, and the stamp those ids wear.
function jawnosWindowsShellCapture(win) {
	if (typeof $ != 'function') { return false; }
	var el = $(win)[0];
	if (!el || el.nodeType !== 1 || !el.parentNode) { return false; }
	var app = el.getAttribute('app') || '';
	if (!app || app == 'Denied') { return false; }
	// Private is a lock, and this one is written to the disk: never keep it.
	if (el.getAttribute('data-private') === 'yes') {
		jawnosWindowsDelete(jawnosWindowsIdentityOf(el));
		return false;
	}
	// a private place or an open grant: nothing is written until it closes
	if (!jawnosWindowsPublicNow(el)) { return false; }
	// A lockdown draws a denial instead of the app; do not keep either the
	// denial as a shell or a window captured before the lockdown as one.
	if (typeof $('#start_menu').hasClass == 'function' && $('#start_menu').hasClass('lockdown')) { return false; }
	if ($(el).find('#denial_window, .lockdown_window').length) { return false; }
	var identity = jawnosWindowsIdentityOf(el);
	var stamp = el.getAttribute('timestamp') || '';
	if (!identity || !stamp) { return false; }
	var node = null;
	try { node = el.cloneNode(true); } catch (e) { return false; }
	if (!node) { return false; }
	jawnosWindowsShellSanitize(node);
	var html = '';
	try { html = node.outerHTML || ''; } catch (e) { return false; }
	if (!html || html.length > JAWNOS_WINDOWS_MAX_WINDOW_BYTES) { return false; }
	jawnosWindowsSave(identity, { shell: html, ts: stamp, app: app, at: Date.now() });
	return true;
}

// A live push that changed a window (a header, a re-render) is written back a
// moment later, so a press's burst of frames costs one capture and a reload
// still shows what the person was last looking at.
function jawnosWindowsShellCaptureSoon(win, delay) {
	if (typeof $ != 'function') { return false; }
	var el = $(win)[0];
	if (!el) { return false; }
	var key = jawnosWindowsIdentityOf(el) || 'window';
	if (jawnosWindowsCaptureTimers[key]) { clearTimeout(jawnosWindowsCaptureTimers[key]); }
	jawnosWindowsCaptureTimers[key] = setTimeout(function () {
		delete jawnosWindowsCaptureTimers[key];
		if (el.isConnected === false) { return; }
		if (typeof jawnosWindowsShellCapture == 'function') { jawnosWindowsShellCapture(el); }
	}, delay || 1200);
	return true;
}

// Paint a reload from the stored shell. It is only for a restore - a press has
// the emerge preview for its instant picture, and the server's own window for
// everything else. The opener's timestamp is written into the copy so the fresh
// render patches this same window when it lands.
function jawnosWindowsShellRestore(app, timestamp, v) {
	if (!app || !v || v.type != 'window') { return false; }
	if (typeof windowMaker != 'function') { return false; }
	if ($('#start_menu').hasClass('lockdown')) { return false; }
	// Only the desk's own saved set is painted from the store. A room's set (or
	// any opener that hands in a window of its own) is not in window_storage, and
	// windowMaker's match path reads that entry; a shell there would change the
	// path a window takes, not just how fast it paints.
	var saved = {};
	try { saved = JSON.parse(sessionStorage.getItem('window_storage') || '{}') || {}; } catch (e) { saved = {}; }
	if (!saved || !saved[app]) { return false; }
	var identity = jawnosWindowsIdentity(app, v);
	if (jawnosWindowsHasWindow(identity)) { return false; }
	jawnosWindowsGet(identity).then(function (row) {
		if (!row || !row.shell || !row.ts) { return; }
		// the server may have answered while the store was being read
		if (jawnosWindowsHasWindow(identity)) { return; }
		if ($('#start_menu').hasClass('lockdown')) { return; }
		windowMaker(jawnosWindowsRestamp(row.shell, row.ts, timestamp));
		// a window that was minimised when it was put away must not flash open
		// for the render's round trip
		if (v.visible !== undefined && v.visible != 'yes') { $('#window_' + timestamp).hide(); }
	}).then(null, function () {});
	return true;
}
