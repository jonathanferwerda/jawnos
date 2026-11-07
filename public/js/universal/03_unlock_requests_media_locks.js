// ---- asking a paired phone or laptop to confirm an unlock --------------------
// The dial and the camera key are gone. The only remote key is a paired
// phone/tablet signing a one-time challenge; the paper recovery code is the
// emergency. A locked screen cannot open its own door, so pressing Unlock asks
// the house to put a fingerprint prompt in front of the other devices.
// The page's identity, with the server-rendered value as a fallback. A fresh
// browser that reached the locked page through a ticket has no localStorage
// entry yet, but the server still knows which paired device it is.
function jawnDeviceUuid() {
	var uuid = '';
	try { uuid = localStorage.getItem('device_uuid') || ''; } catch (e) { uuid = ''; }
	// The Android app mirrors the id in SharedPreferences so the view can move
	// to 127.0.0.1 (a different origin) without looking like an unpaired
	// browser. A browser has no JawnAppStorage and is unchanged.
	if (!uuid && window.JawnAppStorage) {
		try { uuid = window.JawnAppStorage.get('device_uuid') || ''; } catch (e) { uuid = ''; }
	}
	if (!uuid && window.jawnLockedDevice) { uuid = window.jawnLockedDevice; }
	return uuid;
}

// Keep the per-origin value and the app's mirror in step.
function jawnDeviceUuidSave(uuid) {
	uuid = uuid || '';
	try { localStorage.setItem('device_uuid', uuid); } catch (e) {}
	if (uuid && window.JawnAppStorage) {
		try { window.JawnAppStorage.set('device_uuid', uuid); } catch (e) {}
	}
}
// First load on the app's old origin: mirror what localStorage already holds,
// so the next origin can restore it.
(function () {
	try {
		var u = localStorage.getItem('device_uuid') || '';
		if (u && window.JawnAppStorage && !window.JawnAppStorage.get('device_uuid')) {
			window.JawnAppStorage.set('device_uuid', u);
		}
	} catch (e) {}
})();

// ---- app-only access ---------------------------------------------------------
// The private manager needs a proof from a key the browser cannot hold: the
// phone's Android Keystore biometric key, or the desktop app's Ed25519 key.
// The server checks the signature and gives the session a 12-hour app window.
function jawnDesktopCall(action, args) {
	return new Promise(function (resolve, reject) {
		if (!window.JawnDesktop || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.jawnos) {
			reject({ error: 'unavailable' }); return;
		}
		var id = 'app' + Date.now() + Math.random().toString(36).slice(2);
		var done = false;
		// A desktop app that rejects the origin (or an older build that never
		// replies) must not leave the app gate on "Checking this app" forever.
		var timer = setTimeout(function () {
			if (done) { return; }
			done = true;
			window.__jawnAppResult = null;
			reject({ error: 'timeout' });
		}, 2500);
		window.__jawnAppResult = function (rid, res) {
			if (rid !== id || done) { return; }
			done = true;
			clearTimeout(timer);
			window.__jawnAppResult = null;
			if (res && res.ok) { resolve(res); } else { reject(res || { error: 'failed' }); }
		};
		try {
			window.webkit.messageHandlers.jawnos.postMessage(JSON.stringify({ action: action, id: id, args: args || {} }));
		}
		catch (e) {
			clearTimeout(timer);
			window.__jawnAppResult = null;
			reject({ error: 'unavailable' });
		}
	});
}

var jawnAppLoginPending = null;
function jawnAppLogin(force) {
	if (jawnAppLoginPending) { return jawnAppLoginPending; }
	var uuid = jawnDeviceUuid();
	if (!uuid) { return Promise.resolve(false); }
	var phone = !!window.JawnBiometricKey;
	var desktop = !!window.JawnDesktop;
	if (!phone && !desktop) { return Promise.resolve(false); }
	if (!force) {
		var until = 0;
		try { until = parseInt(localStorage.getItem('jawn_app_until') || '0', 10) || 0; } catch (e) { until = 0; }
		if (until > Date.now()) { return Promise.resolve(true); }
	}
	function sign(msg) {
		if (phone) {
			return jawnosBiometricKeyCall('sign', [jawnosB64(new TextEncoder().encode(msg)), 'Unlock the house']).then(function (res) {
				if (!res || !res.ok || !res.signature) { throw { error: (res && res.error) || 'not accepted' }; }
				return res.signature;
			});
		}
		return jawnDesktopCall('app_sign', { message: jawnosB64(new TextEncoder().encode(msg)) }).then(function (res) {
			if (!res || !res.ok || !res.signature) { throw { error: (res && res.error) || 'not accepted' }; }
			return res.signature;
		});
	}
	jawnAppLoginPending = $.post('/manager/device/app_challenge', { device_uuid: uuid, purpose: 'login' }).then(function (ch) {
		if (!ch || !ch.ok || !ch.nonce) { throw { error: (ch && ch.error) || 'challenge' }; }
		return sign('app-login\n' + uuid + '\n' + ch.nonce).then(function (sig) {
			return $.post('/manager/device/app_login', { device_uuid: uuid, nonce: ch.nonce, signature: sig, kind: (phone ? 'ec' : 'ed25519') });
		});
	}).then(function (res) {
		if (!res || !res.ok) { throw { error: (res && res.error) || 'not accepted' }; }
		try { localStorage.setItem('jawn_app_until', String(res.until || 0)); } catch (e) {}
		return true;
	}).catch(function (err) {
		jawnAppLoginPending = null;
		// The session window this cache describes is gone (or never took); do not
		// let another page trust it and reload in a loop.
		try { localStorage.removeItem('jawn_app_until'); } catch (e) {}
		throw err;
	});
	return jawnAppLoginPending;
}

// A desktop app that has no key yet asks the house for one; the phone approves
// the request before the key is accepted. A browser can make the same request,
// but only the phone can approve it.
function jawnAppEnrollDesktop() {
	if (!window.JawnDesktop) { return Promise.resolve(false); }
	var uuid = jawnDeviceUuid();
	if (!uuid) { return Promise.resolve(false); }
	// Bind this session to the app's device first: an unsigned request is
	// accepted only for the device the session itself holds (see app_request).
	return $.getJSON('/manager/security/padlock_state', { device_uuid: uuid }).then(function () {
		return $.getJSON('/manager/device/app_status', { device_uuid: uuid });
	}).then(function (s) {
		if (!s || !s.ok) { throw { error: 'not paired' }; }
		if (s.has_app) { return true; }
		if (s.pending) { throw { error: 'pending' }; }
		return jawnDesktopCall('app_pubkey', {}).then(function (res) {
			if (!res || !res.ok || !res.pubkey) { throw { error: 'no key' }; }
			return $.post('/manager/device/app_challenge', { device_uuid: uuid, purpose: 'enroll' }).then(function (ch) {
				if (!ch || !ch.ok || !ch.nonce) { throw { error: 'challenge' }; }
				function send(sig) {
					return $.post('/manager/device/app_request', {
						device_uuid: uuid, nonce: ch.nonce, app_pubkey: res.pubkey, app_kind: 'ed25519',
						device_signature: sig || '', name: 'Desktop app'
					});
				}
				return jawnosSha256Hex(res.pubkey).then(function (hash) {
					var msg = 'app-request\n' + uuid + '\n' + ch.nonce + '\n' + hash;
					// The device pairing key signs when this app still has it. A
					// migrated WebKit profile can have the uuid without the key; the
					// request then goes unsigned and waits for approval on a trusted
					// app, bound to this session's own device server-side.
					return jawnosDeviceKeyGet().then(function (key) {
						if (!key) { return send(''); }
						return crypto.subtle.sign('Ed25519', key, new TextEncoder().encode(msg)).then(function (sig) {
							return send(jawnosB64(sig));
						});
					}).catch(function () { return send(''); });
				});
			});
		});
	});
}

function padlockAskPhone(mode, target) {
	mode = mode || 'locker';
	if (typeof target === 'undefined') { target = jawnDeviceUuid(); }
	// The tab that pressed the button is the only window the minted app token
	// belongs to: another tab of the same screen, or a peer, must stay shut.
	var tab = '';
	try { tab = sessionStorage.getItem('browser_tab_id') || ''; } catch (e) { tab = ''; }
	$.post('/manager/security/padlock_phone_show', {
		mode: mode,
		target: target,
		device_uuid: jawnDeviceUuid(),
		browser_tab_id: tab
	});
}

// ---- media padlocks belong to one screen and one window -----------------------
// gallery, music and folders open locked. The token for an open one is minted
// for the device that asked for the print and kept for that window alone, so a
// closed app, a closed screen, a new window, a peer or a restarted tree has no
// way in without a fresh print.
function jawnosMediaTab() {
	try { return sessionStorage.getItem('browser_tab_id') || ''; } catch (e) { return ''; }
}

function jawnosMediaLockApp(app, then) {
	$.ajax({
		url: '/manager/security/media_lock',
		type: 'POST',
		data: { app: app || '', device_uuid: jawnDeviceUuid(), browser_tab_id: jawnosMediaTab() },
		complete: function () { if (typeof then === 'function') { then(); } }
	});
}

// The page is leaving (an app window closing, the screen going dark, a reload or
// a restart). A beacon is the only request a closing page is allowed to make.
function jawnosMediaLockBeacon(app) {
	var body = 'app=' + encodeURIComponent(app || '') +
		'&device_uuid=' + encodeURIComponent(jawnDeviceUuid()) +
		'&browser_tab_id=' + encodeURIComponent(jawnosMediaTab());
	// the same browser's other tabs clear at once, without waiting for a fetch
	try { localStorage.setItem('jawnos_media_lock', String(Date.now())); } catch (e) {}
	if (navigator.sendBeacon) {
		try {
			navigator.sendBeacon('/manager/security/media_lock', new Blob([body], { type: 'application/x-www-form-urlencoded' }));
			return;
		} catch (e) {}
	}
	$.ajax({ url: '/manager/security/media_lock', type: 'POST', async: false, data: { app: app || '', device_uuid: jawnDeviceUuid(), browser_tab_id: jawnosMediaTab() } });
}

// Private apps belong to a private place and still need a fingerprint. A grant
// is device-wide (the Security padlock or an app's own lock); this redraws every
// surface that lists apps without changing which window is in front. opened=1
// says a grant was just made, so a denial window that was asking for one can
// now open the app it named.
var jawnosPrivateIdleTimer = null;
var jawnosPrivateIdleAt = 0;
var jawnosPrivateIdleMs = 5 * 60 * 1000;

function jawnosPrivateIdleStop() {
	if (jawnosPrivateIdleTimer) { clearTimeout(jawnosPrivateIdleTimer); }
	jawnosPrivateIdleTimer = null;
	jawnosPrivateIdleAt = 0;
}

function jawnosPrivateIdleStart() {
	jawnosPrivateIdleStop();
	jawnosPrivateIdleAt = Date.now();
	jawnosPrivateIdleTimer = setTimeout(jawnosPrivateIdleExpire, jawnosPrivateIdleMs);
}

// Five minutes with no movement on the screen relocks private: drop the grant
// on the server, close this tab's private windows, and redraw the lists.
function jawnosPrivateIdleExpire() {
	jawnosPrivateIdleStop();
	$.ajax({
		url: '/manager/security/media_lock',
		type: 'POST',
		data: {
			app: 'private',
			device_uuid: (typeof jawnDeviceUuid === 'function') ? jawnDeviceUuid() : '',
			browser_tab_id: (typeof jawnosMediaTab === 'function') ? jawnosMediaTab() : ''
		},
		complete: function () {
			if (typeof jawnosPrivateRefresh === 'function') { jawnosPrivateRefresh(0); }
		}
	});
}

function jawnosPrivateIdleTouch() {
	if (!jawnosPrivateIdleTimer) { return; }
	var now = Date.now();
	if (now - jawnosPrivateIdleAt < 1000) { return; }
	jawnosPrivateIdleStart();
}

$(document).on('mousemove mousedown keydown touchstart scroll wheel', function () {
	jawnosPrivateIdleTouch();
});

function jawnosPrivateRefresh(opened) {
	if (opened === 1) { jawnosPrivateIdleStart(); }
	else if (opened === 0) { jawnosPrivateIdleStop(); }
	if (typeof calculator === 'function') { calculator(); }
	if (typeof appointment_chron === 'function') { appointment_chron(); }
	if (typeof galleryFetch === 'function' && $('#gallery').length) { galleryFetch(true); }
	if (typeof foldersOpener === 'function' && $('#folders').length) { foldersOpener(); }
	if (typeof searchMusic === 'function' && $('#music').length) { searchMusic(); }
	// the start menu's markup is cached per tab, so a locked menu would keep
	// naming a private app until the cache is dropped
	if (typeof startMenuHtml !== 'undefined') { startMenuHtml = {}; }
	if ($('#start_menu').is(':visible') && typeof startMenuToggle === 'function') { startMenuToggle({ source: 'private' }); }
	if (opened === 1) {
		var frame = $('.padlock_frame[data-open-app]').filter(':visible').first();
		if (frame.length) {
			var app = frame.attr('data-open-app') || '';
			var ts = frame.attr('data-open-timestamp') || Date.now();
			var deny = frame.closest('.wind');
			var deny_id = deny.attr('id') || '';
			if (/^window_/.test(deny_id) && typeof closeWindow === 'function') { closeWindow(deny_id.replace('window_', '')); }
			if (app && typeof appointmentGrabber === 'function') { appointmentGrabber(app, ts); }
		}
	}
}

// Clear the visible state at once and ask the app to draw its locked view when
// the page is visible; a hidden tab defers the draw until it comes back.
function jawnosMediaLockdown(app, defer) {
	var apps = app ? [app] : ['gallery', 'music', 'folders'];
	apps.forEach(function (a) {
		if (a === 'gallery') {
			if (typeof galleryUnlockRemember === 'function') { galleryUnlockRemember(''); }
			$('#gallery').attr('unlock', '');
			if (typeof gallery !== 'undefined' && gallery) { gallery.unlock = ''; }
			$('#gallery_grid').empty();
			$('#gallery_albums').empty();
		} else if (a === 'folders') {
			$('#folders').attr('unlock', '');
		} else if (a === 'music') {
			$('#music').attr('unlock', undefined);
			$('#music').show();
			$('#music_padlock').hide();
		}
	});
	window.jawnosMediaLockPending = apps;
	if (defer || document.hidden) { return; }
	jawnosMediaRefresh(apps);
	if (typeof jawnosPrivateRefresh === 'function') { jawnosPrivateRefresh(); }
}

function jawnosMediaRefresh(apps) {
	apps = apps || window.jawnosMediaLockPending || [];
	window.jawnosMediaLockPending = null;
	if ($.inArray('gallery', apps) > -1 && typeof galleryFetch === 'function' && $('#gallery').length) { galleryFetch(true); }
	if ($.inArray('folders', apps) > -1 && typeof foldersOpener === 'function' && $('#folders').length) { foldersOpener(); }
	if ($.inArray('music', apps) > -1 && typeof searchMusic === 'function' && $('#music').length) { searchMusic(); }
}

// Put the token an unlock's own reply carried into this window and redraw it.
// The websocket push normally does this; the reply is the fallback for a socket
// that is asleep, and it is only used for the screen named in the reply.
function jawnosMediaApplyToken(app, token, target) {
	if (!app || !token) { return; }
	if (target && target !== jawnDeviceUuid()) { return; }
	// Private has no window of its own: its grant changes what the server will
	// list, so every surface is redrawn instead of one app's token attribute.
	if (app === 'private') {
		if (typeof jawnosPrivateRefresh === 'function') { jawnosPrivateRefresh(1); }
		return;
	}
	var root = $('#' + app);
	if (!root.length) { return; }
	root.attr('unlock', token);
	if (app === 'gallery') {
		if (typeof gallery !== 'undefined' && gallery) { gallery.unlock = token; }
		if (typeof galleryUnlockRemember === 'function') { galleryUnlockRemember(token); }
	}
	jawnosMediaRefresh([app]);
}

// A closing page cannot wait for the reply; the grant is gone by the time the
// app is opened again, and no peer is touched.
window.addEventListener('pagehide', function () {
	if (typeof jawnosMediaLockdown === 'function') { jawnosMediaLockdown('', true); }
	if (typeof jawnosPrivateIdleStop === 'function') { jawnosPrivateIdleStop(); }
	jawnosMediaLockBeacon('');
});

// A lock in one window is a lock in every window of this browser.
window.addEventListener('storage', function (e) {
	if (e && e.key === 'jawnos_media_lock' && typeof jawnosMediaLockdown === 'function') {
		jawnosMediaLockdown('', document.hidden);
	}
});

// A page that has just opened is a new window, and a media unlock belongs to
// the window that asked for the print. Any manager page - a browser tab, a
// webui window, a refreshed one - starts this screen's media padlocks shut.
$(function () {
	if ((location.pathname || '').indexOf('/manager') !== 0) { return; }
	if (!jawnDeviceUuid()) { return; }
	jawnosMediaLockBeacon('');
});
// The app locks (gallery, music, folders) still carry the padlock partial's own
// Unlock button; it asks the house for the same in-place prompt.
$(document).on('click', '.padlock_ask_phone', function () {
	var button = $(this);
	var frame = button.closest('.padlock_frame');
	var mode = frame.attr('mode') || 'locker';
	var target = frame.attr('target') || jawnDeviceUuid() || '';
	padlockAskPhone(mode, target);
	button.text('Sent.');
});

