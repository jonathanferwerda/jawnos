var tree = {};
var appointment_chronicler;
var appointment_windows = {};
var errorDotTimeout;
var errorInfo = [];
	// `!signatorial in window` parses as `(!signatorial) in window` and throws on
	// pages that never define it (the public homepage), so use typeof instead
	if (typeof signatorial === 'undefined' || !signatorial) {
		globalThis.signatorial = 'unknown';
	}
	// bti and bt are read by the ajaxSetup below. A layout that loads this file
	// before its own tab stamps (the locked page did) must not abort the whole
	// script here: a ReferenceError would leave every later handler unbound,
	// including the padlock's fingerprint button.
	if (typeof bti === 'undefined') { globalThis.bti = ''; }
	if (typeof bt === 'undefined') { globalThis.bt = ''; }

// The repaint work (the appointment chrons, the calculators, the little
// animations) only matters while the page is really being looked at. A hidden
// tab is the usual case; a fullscreen video is the other, and document.hidden
// stays false there - without this the chrons and the appointment poll keep
// churning behind the picture. Anything that must keep the app connected or
// aware (the websocket, the alarms, a recording in progress) must NOT be gated
// on this.
function jawn_resting() {
	return document.hidden || !!document.fullscreenElement || !!document.webkitFullscreenElement;
}
var jawn_was_resting = jawn_resting();
function jawn_rest_change() {
	var resting = jawn_resting();
	if (jawn_was_resting && !resting) {
		// back on screen: paint the chrons at once, and let the calculator resync
		// the view it stopped polling while it was covered
		appointment_chron();
		if (typeof calculator == 'function') { calculator(); }
	}
	jawn_was_resting = resting;
}
document.addEventListener('fullscreenchange', jawn_rest_change);
document.addEventListener('webkitfullscreenchange', jawn_rest_change);

$(document).ready(function() {
	appointment_chron();
});

$(document).on('keyup click change', 'textarea, .text-editor', function() {
	var ta = $(this);
	var scrollHeight = ta[0].scrollHeight;
	var scrollTop = ta.scrollTop();
	var height = ta.height();
	if (scrollHeight > (height + 5) || scrollHeight < (height - 5)) {
		if (scrollHeight < 700) {
			ta.height(scrollHeight);
		}
	}
	if (ta.val() == '') {
		ta.height(30);
	}
});


function appointment_chron() {
	clearInterval(appointment_chronicler);
	time_updater();
	appointment_chronicler = setInterval(function(){
		// no point repainting clocks while the page isn't on screen, or while a
		// fullscreen video is covering it
		if (jawn_resting()) { return; }
		time_updater();
	},1000);
	function time_updater() {
		var now = Date.now();
		$('.since, .time').each( function() {
			var header = $(this);
			var mode = $(this).attr('mode');
			var timestamp = $(this).attr('timestamp');

			if (mode == 'fixed') {
				// Fixed times never change, so paint one and skip the element for a
				// while. Clicking the element drops next_check, so the toggle back to
				// fixed paints straight away instead of waiting out this hour.
				var next_check = numeral(header.attr('next_check')).value();
				if (next_check && next_check > now) { return; }
				if (!header.attr('formatted_time')) {
					header.attr('formatted_time', fixedTimeString(numeral(timestamp).value()));
				}
				if (header.is('input') && !header.hasClass('editing')) {
					header.val(header.attr('formatted_time')).css({'background-color': 'var(--time-fixed)'});
				}
				else if (header.hasClass('editing')) {
					header.css({'background-color': 'var(--time-fixed)'})
				}
				else {
					header.text(header.attr('formatted_time'));
				}
				header.attr('next_check', now + 3600000);
			}
			else {
				// Dynamic times read "in 3m 12s" or "3d 4h ago", so they are worked out
				// every second -- the DOM is only touched when the text really changed.
				if (header.is('input') && !header.hasClass('editing')) {
					var value = quality_inventory(timestamp);
					if (header.val() != value) { header.val(value).css({'background-color': ''}); }
				}
				else if (header.hasClass('editing')) {
					header.css({'background-color': ''});
					header.attr('mode', 'dynamic');
					// while typing, keep repainting so it settles as soon as they stop
					return;
				}
				else {
					var text = quality_inventory(timestamp);
					if (header.text() != text) { header.text(text); }
				}
				header.attr('mode', 'dynamic');
			}

		});
	}
}

var mLastX = 0;
var mLastY = 0;
var mLastTs = Date.now();
$(document).on('mousemove', function(e) {
	window.event = e;
	mouse = e;
});
function mouse_position() {
  var e = window.event;
	var data = { 'lastX': mLastX, 'lastY': mLastY, lastTs: mLastTs }; 
	if(e) {
 		mLastX = e.clientX;
  	mLastY = e.clientY;
		mLastTs = Date.now();
	}
	data['x'] = mLastX;
	data['y'] = mLastY;
	data['ts'] = Date.now();
  return data;
}

function say_it(words) {
	var timestamp = Date.now();
	$.ajax({
		url: '/manager/say_it',
		type: 'GET',
		data: { 'words': words, 'timestamp': timestamp }
	});
}

function format_name(name) {
	var names = name.split('_');
	var named = [];
	var formatted = '';
	$.each(names, function(i,v) {
		v = v.charAt(0).toUpperCase() + v.slice(1);
		named.push(v);
	});
	formatted = named.join(' ');
	return formatted;
}

// The first few letters of a name, the way subs::shorthand_name() takes them:
// what a bar too narrow for the whole word can say instead.
function shorthand_name(name, shorten) {
	name = '' + (name || '');
	shorten = shorten || 5;
	return name.slice(0, shorten);
}

function quality_inventory(timestamp) {
	var now = numeral(Date.now()).value();
	var then = timestamp;


	var since = (now - then);
	var t = "";
	if (now < then) {  since = Math.abs(since); }
	var seconds = (since / 1000);
	var minutes = (seconds / 60);
	var hours = (minutes / 60);
	var days = numeral(hours / 24).format('0.000');
	var weeks = numeral( days / 7 ).format('0.000');
	var months = numeral( days / 30 ).format('0.000');
	var seasons = numeral( days / 90 ).format('0.000');
	var years = numeral( days / 365 ).format('0.000');


	if (seconds < 60) { 
		t += numeral(seconds).format('10') + 's';
	}
	if ( seconds >= 60 && minutes < 60 ) { 
		t += Math.floor(minutes) + 'm';
		var r = (minutes - Math.floor(minutes)) * 60;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 's';
		}
	}
	if (minutes >= 60 && hours <= 24 ) { 
		t += Math.floor(hours) + 'h';
		var r = (hours - Math.floor(hours)) * 60;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'm';
		}
		r = r - Math.floor(r);
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r * 60) + 's';
		}
	}
	if (hours > 24 && days <= 90) { 
		t += Math.floor(days) + 'd';
		var r = (days - Math.floor(days)) * 24;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'h';
		}
		r = (r - Math.floor(r)) * 60;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'm';
		}

	}
	if (days > 90 && months < 24) { 
		t += numeral(months).format('0,0.0000') + 'M';
	}
	if (years >= 2) { 
		t += Math.floor(years) + 'y';
		var r = years - Math.floor(years);
		r = r * 12;
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'M';
		}
		r = numeral((r - Math.floor(r)) * 30).format('0.000');
		if (Math.floor(r) > 0) {
			t += ' ' + Math.floor(r) + 'd';
		}

	}



	if (now < then) { t = 'in ' + t; since = Math.abs(since); }
	return t; 
}

var months = [
	{ 'abbrev': 'jan', name: 'January', days: 31, leap_days: 31 },
	{ 'abbrev': 'feb', name: 'February', days: 28, leap_days: 29 },
	{ 'abbrev': 'mar', name: 'March', days: 31, leap_days: 31 },
	{ 'abbrev': 'apr', name: 'April', days: 30, leap_days: 30 },
	{ 'abbrev': 'may', name: 'May', days: 31, leap_days: 31 },
	{ 'abbrev': 'jun', name: 'June', days: 30, leap_days: 30 },
	{ 'abbrev': 'jul', name: 'July', days: 31, leap_days: 31 },
	{ 'abbrev': 'aug', name: 'August', days: 31, leap_days: 31 },
	{ 'abbrev': 'sep', name: 'September', days: 30, leap_days: 30 },
	{ 'abbrev': 'oct', name: 'October', days: 31, leap_days: 31 },
	{ 'abbrev': 'nov', name: 'November', days: 30, leap_days: 30 },
	{ 'abbrev': 'dec', name: 'December', days: 31, leap_days: 31 },
];

$(document).on('dblclick', '.time', function() {
	var ago = $(this).attr('formatted_time');
	$('#time_machine').val(ago);
	localStorage.setItem('time_machine',ago);
});


$(document).on('click', '.time, .appointment_header, .since', function() {
	var header = $(this);
	if (!header.is('input')) {
		// drop the fixed-mode repaint gate so the switch shows up right away
		header.removeAttr('next_check');
		if (header.attr('mode') == 'fixed') {
			header.attr('mode', 'dynamic');
		}
		else {
			header.attr('mode', 'fixed');
			var timestamp = numeral(header.attr('timestamp')).value();
			header.attr('formatted_time', fixedTimeString(timestamp));
		}
		appointment_chron();
	}
});

function fixedTimeString(timestamp) {
const date = new Date(timestamp);
	const datevalues = [
		date.getFullYear(),
		date.getMonth()+1,
		date.getDate(),
		date.getHours(),
		date.getMinutes(),
		date.getSeconds(),
		dayProcessor(date.getDay())
	];
	$.each(datevalues, function(i,v) {
		if (v < 10) {
			datevalues[i] = '0' + v;
		}
	});
	return datevalues[6] + ' ' + datevalues[1] + '/' + datevalues[2] + '/' + datevalues[0] + ' ' + datevalues[3] + ':' + datevalues[4] + ':' + datevalues[5]
			
}

function dayProcessor(day) {
	var d;
	if (day == 0) {
		d = 'Sun';
	}
	else if (day == 1) {
		d = 'Mon';
	}
	else if (day == 2) {
		d = 'Tue';
	}
	else if (day == 3) {
		d = 'Wed';
	}
	else if (day == 4) {
		d = 'Thu';
	}
	else if (day == 5) {
		d = 'Fri';
	}
	else if (day == 6) {
		d = 'Sat';
	}
	else { d = ''; }
	return d;
}

function isJson(str) {
	try {
		JSON.parse(str);
	}
	catch (e) {
		return false;
	}
	return true;
}

function timestampDater() {
	$('.timestamp').each(function() {
		var t = numeral($(this).text()).value();
		var m = moment(t).format('M/D/YYYY');
		$(this).text(m);
		$(this).removeClass('timestamp');
	});
}

$(document).on('click', '#error_dot', function() {
	clearTimeout(errorDotTimeout);
	if ($('#error_info').is(':visible')) {
		$('#error_info').hide();
	}
	else {
		$('#error_info').html('hey').show();
	}
});


async function settingSetter(setter) {
	var app = setter['app'];
	var value = setter['value'];
	var setting = setter['setting'];
	var timestamp = Date.now();
	var device = setter['device'];
	return $.ajax({
		url: '/manager/setting_setter',
		type: 'POST',
		data: { app: app, setting:setting, device: device, subsetting: setter['subsetting'], value:value, timestamp: timestamp},
		success: function(response) {
			return response;
		}
	});
}

async function settingGrabber(setter) {
	var timestamp = Date.now();
	var app = setter['app'];
	var setting = setter['setting'];
	var response = $.ajax({
		url: '/manager/setting_grabber',
		type: 'GET',
		data: { app: app, setting: setting, timestamp: timestamp},
		success: function(response) {

//			return response;
		}
	});
	if (isJson(response)) {
		response = JSON.parse(response);
	}
	return response;
}

function settingsGrabber(setter) {
	var timestamp = Date.now();
	var app = setter['app'];
	var device = setter['device'];
	$.ajax({
		url: '/manager/settings_grabber',
		type: 'GET',
		data: { app: app, device: device },
		success: function(response) {
			return response;
		}
	});
}


function settingDeleter(setter) {
	var timestamp = Date.now();
	var app = setter['app'];
	var setting = setter['setting'];
	var device = setter['device'];
	return $.ajax({
		url: '/manager/setting_deleter',
		type: 'POST',
		data: { app: app, device:device, setting: setting},
		success: function(response) {
			return response;
		}
	});
}

$(document).on('click', '.dot', function(e) {
	// A click inside the expanded info is reading it, not dismissing it.
	if ($(e.target).closest('.dot_info').length) { return; }
	var di = $(this).find('.dot_info');
	if (di.is(':visible')) {
		di.hide();
	}
	else {
		di.show();
	}
});

// Every request's own url is stashed on its jqXHR as it starts: the ajaxSetup
// error callback below is handed no settings, so without this the dot could
// only ever say "request" where it should name the route that failed.
$.ajaxPrefilter(function(options, original, jqXHR) {
	if (options && options.url) { jqXHR.jawnos_url = options.url; }
});

$.ajaxSetup({
	cache: false,
	data: { browser_tab_id: bti, browser_tab: bt, user_agent: navigator.userAgent, signatorial: signatorial },
	success: function(response) {
	},
	
	error: function(e,t,r) {
	//	errorInfo.push(e);
		// A request that never reached the server is not a fault to shout about: the
		// tree is restarting (an update is a push then a restart), the link
		// dropped, or the page is unloading as the tab reloads. Say it in the
		// console and leave the corner alone, so receiving an update never greets
		// someone with a red dot they cannot act on.
		if (t === 'abort' || !e || e.status === 0) {
			console.log('request did not reach jawn:', (e && e.jawnos_url) || '?', t);
			return;
		}
		// A lapsed session is not a request fault. The phone wakes with a stale
		// cookie after a long sleep, the first background request (the phone
		// facts sync) meets the Gate, and the old code painted a red dot for it
		// every time. Go back through the Gate instead: the app's page-finished
		// check hands over a fresh ticket, and a desktop simply lands on the Gate.
		if (e.status === 401) {
			console.log('session lapsed:', (e.jawnos_url || 'request'));
			if (!window.__jawnSessionReloading && !document.getElementById('welcome_logo')) {
				window.__jawnSessionReloading = true;
				setTimeout(function() { location.reload(); }, 400);
			}
			return;
		}
		var url = (e.jawnos_url || 'request').replace(/\?.*$/, '');
		var body = (e.responseText || '').replace(/\s+/g, ' ').trim();
		var message = e.status + ': ' + url + (body ? ' — ' + body : '');
		if (message.length > 200) {
			message = message.slice(0, 200) + '…';
		}
		$('#red_dot').show();
		$('#red_dot').find('.dot_info').text(message);
		errorDotTimeout = setTimeout(function() {
			$('#red_dot').fadeOut();
		},15000);
	}
});

// A phone that has been asleep longer than the session's activity window wakes
// with a stale cookie. Reload once on resume so the app can hand over a fresh
// ticket before the first tap, instead of losing that tap to a 401.
var jawnHiddenAt = 0;
document.addEventListener('visibilitychange', function() {
	if (document.hidden) { jawnHiddenAt = Date.now(); return; }
	var hidden = jawnHiddenAt ? (Date.now() - jawnHiddenAt) : 0;
	jawnHiddenAt = 0;
	if (hidden > 80 * 60 * 1000 && window.JawnPhone) { location.reload(); }
});


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
	if (!uuid && window.jawnLockedDevice) { uuid = window.jawnLockedDevice; }
	return uuid;
}

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
		window.__jawnAppResult = function (rid, res) {
			if (rid !== id) { return; }
			window.__jawnAppResult = null;
			if (res && res.ok) { resolve(res); } else { reject(res || { error: 'failed' }); }
		};
		try {
			window.webkit.messageHandlers.jawnos.postMessage(JSON.stringify({ action: action, id: id, args: args || {} }));
		}
		catch (e) {
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
	$.post('/manager/security/padlock_phone_show', {
		mode: mode,
		target: target,
		device_uuid: jawnDeviceUuid()
	});
}
// The app locks (gallery, music, folders) still carry the padlock partial's own
// Unlock button; it asks the house for the same in-place prompt.
$(document).on('click', '.padlock_ask_phone', function () {
	var button = $(this);
	var frame = button.closest('.padlock_frame');
	var mode = frame.attr('mode') || 'locker';
	var target = frame.attr('target') || localStorage.getItem('device_uuid') || '';
	padlockAskPhone(mode, target);
	button.text('Sent.');
});

// ---- asking a paired device to confirm an unlock -----------------------------
// A screen locking no longer pulls every phone and laptop onto the unlock page.
// That navigation added a history entry and left images stale when a phone
// woke. The person presses Unlock on the locked screen; the house sends an
// explicit request. A device that is already open shows a fingerprint prompt
// in place, signs the target screen open, and goes back to what it was doing.
// The unlock page is still available by hand.
function jawnMobileHere() {
	return !!(window.JawnPhone || /Android|iPhone|iPad|iPod|Mobile|Tablet/i.test(navigator.userAgent || ''));
}

// A message with no target is the house-wide timeout lock; a target names the
// one device that was locked from its own taskbar.
function jawnPadlockTargetMatches(target) {
	if (!target) { return true; }
	return jawnDeviceUuid() === target;
}

function jawnPadlockKeyShow(mode, target, show) {
	if ((location.pathname || '') == '/manager/security/padlock_key') { return; }
	// A legacy announcement (an older peer saying "this screen locked") is
	// ignored. Only an explicit request carries prompt=1 and is handled in
	// place by websocket.js; a lock must never raise an unsolicited prompt or
	// move the page.
}

// A device that was asleep, or that joined after the button was pressed, gets
// the pending request on its next socket connect (or when it wakes). It is
// shown in place, never by opening the unlock page.
var jawnPadlockCheckedAt = 0;
function jawnPadlockKeyCheck(force) {
	if ((location.pathname || '') == '/manager/security/padlock_key') { return; }
	// the manager and the standalone locked page both carry a paired device:
	// the locked page has no websocket, so polling is its only way to hear a
	// request that arrived while it was asleep
	if (!document.getElementById('taskbar') && !document.getElementById('locked_screen')) { return; }
	var now = Date.now();
	if (!force && now - jawnPadlockCheckedAt < 5000) { return; }
	jawnPadlockCheckedAt = now;
	$.getJSON('/manager/security/padlock_state', { device_uuid: jawnDeviceUuid() }, function(s) {
		if (!s || !s.ok) { return; }
		// The server can identify this page even when its localStorage lost the
		// uuid (a webview wake, or a ticket that signed in without one). Keep the
		// two in step so every later sign/open request names the same device.
		if (s.device && /^[A-Za-z0-9]{8,64}$/.test(s.device)) {
			try { localStorage.setItem('device_uuid', s.device); } catch (e) {}
			window.jawnLockedDevice = s.device;
		}
		// the lock overlay may be shared HTML; this device's own enrollment is
		// what decides whether its fingerprint button belongs on it
		var bio = document.getElementById('locked_biometric');
		if (bio && typeof s.biometric_enrolled !== 'undefined') {
			if (s.biometric_enrolled) {
				bio.setAttribute('data-enrolled', '1');
				bio.style.display = '';
			}
			else {
				bio.style.display = 'none';
			}
		}
		// A manager page that the server says is locked must not keep its live
		// DOM under an overlay: a browser Back could restore it without asking.
		// Reload once, so the gate answers with the standalone locked page (no
		// unlocked windows behind it, and no history entry to step back into).
		if (s.locked && document.getElementById('taskbar')) {
			var last = 0;
			try { last = parseInt(sessionStorage.getItem('jawn_padlock_reload') || '0', 10) || 0; } catch (e) { last = 0; }
			if (!last || Date.now() - last > 8000) {
				try { sessionStorage.setItem('jawn_padlock_reload', String(Date.now())); } catch (e) {}
				location.reload();
				return;
			}
		}
		var r = s.request;
		if (r && r.id && typeof jawnPadlockPrompt === 'function') {
			jawnPadlockPrompt(r.mode || 'locker', r.target || '', r.id, r.device_name || '', r.source_device || '', r.source_hostname || '', r.house);
		}
	});
}

// The in-place confirmation. It is deliberately a small overlay: the device
// keeps its page, its scroll position and its history entry. A success opens
// the screen named in the request; this device is unchanged.
var jawnPadlockPromptOpen = false;
var jawnPadlockPromptTarget = '';
var jawnPadlockPromptSeen = {};

function jawnPadlockPromptDismiss(target) {
	if (typeof target !== 'undefined' && target !== '' && target !== jawnPadlockPromptTarget) { return; }
	var box = document.getElementById('jawn_padlock_prompt');
	if (box && box.parentNode) { box.parentNode.removeChild(box); }
	jawnPadlockPromptOpen = false;
	jawnPadlockPromptTarget = '';
}

function jawnPadlockPromptText(text, value) {
	if (typeof jawnosT === 'function') {
		return (typeof value === 'undefined') ? jawnosT(text) : jawnosT(text, value);
	}
	return (typeof value === 'undefined') ? text : text.replace('{0}', value);
}

// The padlock's own vocabulary: the Manager screen, or the app whose lock it is.
function jawnPadlockContext(mode) {
	if (mode === 'gallery') { return jawnPadlockPromptText('Gallery'); }
	if (mode === 'music') { return jawnPadlockPromptText('Music'); }
	if (mode === 'folders') { return jawnPadlockPromptText('Folders'); }
	return jawnPadlockPromptText('Manager');
}

// What the person sees in the native fingerprint prompt: what is being opened,
// where the request came from, and which context asked for it.
function jawnPadlockUnlockLabel(mode, house, deviceName, sourceHost) {
	var what = house ? jawnPadlockPromptText('the house') : (deviceName || jawnPadlockPromptText('the locked screen'));
	var from = sourceHost ? (' — ' + sourceHost) : '';
	return jawnPadlockPromptText('Unlock') + ' ' + what + from + ' · ' + jawnPadlockContext(mode);
}

function jawnPadlockPrompt(mode, target, requestId, deviceName, sourceDevice, sourceHost, house) {
	if ((location.pathname || '') == '/manager/security/padlock_key') { return; }
	if (!document.getElementById('taskbar') && !document.getElementById('locked_screen')) { return; }
	// A screen that is locked is not an approval terminal. It may show its own
	// fingerprint button and its own unlock request, but it must not be asked to
	// confirm for another screen; an unlocked device will pick the request up.
	var lockLayer = document.getElementById('locked_screen');
	if (lockLayer && (lockLayer.offsetWidth || lockLayer.offsetHeight || lockLayer.getClientRects().length)) { return; }
	var mine = jawnDeviceUuid();
	if (!mine) { return; }
	// the locked screen is not asked to sign itself open, and the screen that
	// pressed Unlock is not asked to confirm its own request
	if (target && target === mine) { return; }
	if (sourceDevice && sourceDevice === mine) { return; }
	if (jawnPadlockPromptOpen) { return; }
	var key = requestId || ('request:' + (mode || 'locker') + ':' + (target || 'house'));
	if (jawnPadlockPromptSeen[key]) { return; }
	jawnPadlockPromptSeen[key] = 1;
	jawnPadlockPromptOpen = true;
	jawnPadlockPromptTarget = target || '';
	mode = mode || 'locker';
	house = (typeof house === 'undefined') ? !target : !!house;
	var contextLabel = jawnPadlockContext(mode);
	var unlockLabel = jawnPadlockUnlockLabel(mode, house, deviceName, sourceHost);

	var box = document.createElement('div');
	box.id = 'jawn_padlock_prompt';
	box.setAttribute('role', 'dialog');
	box.setAttribute('aria-modal', 'true');
	box.style.cssText = 'position:fixed;z-index:71000;left:50%;top:50%;transform:translate(-50%,-50%);width:min(92vw,360px);background:#161616;color:#f4f4f4;border:1px solid #444;border-radius:14px;padding:18px;box-shadow:0 12px 40px rgba(0,0,0,.55);font-family:sans-serif;text-align:center;';
	var title = document.createElement('div');
	title.style.cssText = 'font-size:19px;line-height:1.35;margin-bottom:6px;';
	title.textContent = house ? jawnPadlockPromptText('Unlock the house?')
		: (deviceName ? jawnPadlockPromptText('Unlock {0}?', deviceName) : jawnPadlockPromptText('Unlock the locked screen?'));
	var note = document.createElement('div');
	note.style.cssText = 'font-size:14px;color:#bbb;margin-bottom:14px;min-height:18px;';
	note.textContent = (sourceHost ? jawnPadlockPromptText('Requested by {0}', sourceHost) : jawnPadlockPromptText('Requested by another machine'))
		+ ' · ' + contextLabel + '. ' + jawnPadlockPromptText('Confirm with your fingerprint to open it.');
	var go = document.createElement('button');
	go.type = 'button';
	go.textContent = jawnPadlockPromptText('Unlock with fingerprint');
	go.style.cssText = 'font-size:15px;padding:10px 16px;border-radius:9px;border:1px solid #2b6;background:#2b6;color:#08110a;font-weight:bold;cursor:pointer;margin:0 4px 8px 4px;';
	var no = document.createElement('button');
	no.type = 'button';
	no.textContent = jawnPadlockPromptText('Not now');
	no.style.cssText = 'font-size:15px;padding:10px 16px;border-radius:9px;border:1px solid #555;background:#222;color:#f4f4f4;cursor:pointer;margin:0 4px 8px 4px;';
	box.appendChild(title);
	box.appendChild(note);
	box.appendChild(go);
	box.appendChild(no);
	document.body.appendChild(box);

	no.onclick = function () { jawnPadlockPromptDismiss(); };
	go.onclick = function () {
		go.disabled = true;
		no.disabled = true;
		note.textContent = jawnPadlockPromptText('Authenticate to continue...');
		// On the Android app the Keystore key is a real factor: the OS prompt is
		// what releases it, and its signature opens the target screen. A browser
		// (or an app with no enrolled key) falls back to the local confirm and
		// the device's pairing signature.
		var opened;
		if (window.JawnBiometricKey && typeof jawnosBiometricUnlock === 'function') {
			opened = jawnosBiometricUnlock(mode, target, function (t) { note.textContent = t; }, box, house, sourceHost, deviceName).catch(function (err) {
				var e = (err && err.error) || '';
				if (e !== 'unavailable' && e !== 'no key' && e !== 'invalidated') { throw err; }
				return jawnPadlockConfirm(unlockLabel).then(function (ok) {
					if (!ok) { throw { error: 'cancelled' }; }
					note.textContent = jawnPadlockPromptText('Unlocking...');
					return jawnPadlockSignOpen(mode, target, note, house);
				});
			});
		}
		else {
			opened = jawnPadlockConfirm(unlockLabel).then(function (ok) {
				if (!ok) { throw { error: 'cancelled' }; }
				note.textContent = jawnPadlockPromptText('Unlocking...');
				return jawnPadlockSignOpen(mode, target, note, house);
			});
		}
		opened.then(function (res) {
			// an "already" answer with relayed=1 means this machine did not hold
			// the row; the peer that does was just told to open it
			note.textContent = (res && res.already && !res.relayed) ? jawnPadlockPromptText('That screen was already open.') : jawnPadlockPromptText('Unlocked.');
			setTimeout(function () { jawnPadlockPromptDismiss(); }, 1200);
		}).catch(function (err) {
			if (err && err.error === 'cancelled') { jawnPadlockPromptDismiss(); return; }
			note.textContent = (typeof jawnosBiometricError === 'function') ? jawnosBiometricError(err) : jawnPadlockPromptText('That did not work. Try again.');
			go.disabled = false;
			no.disabled = false;
		});
	};
}

function jawnosRandom(n) {
	var a = new Uint8Array(n);
	crypto.getRandomValues(a);
	return a;
}
function jawnosB64Bytes(b64) {
	var s = atob(b64);
	var a = new Uint8Array(s.length);
	for (var i = 0; i < s.length; i++) { a[i] = s.charCodeAt(i); }
	return a;
}

// A local confirmation before the paired key signs. The Android app has a
// native prompt (window.JawnBiometric); a browser on a hostname uses WebAuthn;
// over a bare LAN address there is no RP ID, so the button press is the
// go-ahead - the same rule the unlock page uses.
function jawnPadlockConfirm(text) {
	if (window.JawnBiometric && typeof window.JawnBiometric.confirm === 'function') {
		return new Promise(function (resolve) {
			window.jawnBiometricResult = function (ok) {
				window.jawnBiometricResult = null;
				resolve(ok === 'unavailable' ? true : !!ok);
			};
			try { window.JawnBiometric.confirm(text || 'Unlock the house'); }
			catch (e) { window.jawnBiometricResult = null; resolve(true); }
		});
	}
	var h = location.hostname || '';
	if (window.PublicKeyCredential && navigator.credentials && window.isSecureContext && !/^\d{1,3}(\.\d{1,3}){3}$/.test(h)) {
		var id = localStorage.getItem('jawn_padlock_cred') || '';
		if (!id) {
			return navigator.credentials.create({ publicKey: {
				challenge: jawnosRandom(32),
				rp: { name: 'JawnOS', id: h },
				user: { id: jawnosRandom(16), name: 'jawnos-unlock', displayName: 'JawnOS unlock' },
				pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
				authenticatorSelection: { authenticatorAttachment: 'platform', userVerification: 'required', residentKey: 'discouraged' },
				timeout: 60000,
				attestation: 'none'
			} }).then(function (cred) {
				if (cred && cred.rawId) { localStorage.setItem('jawn_padlock_cred', jawnosB64(cred.rawId)); }
				return true;
			}).catch(function (e) {
				if (e && (e.name === 'NotAllowedError' || e.name === 'AbortError')) { return false; }
				return true;
			});
		}
		return navigator.credentials.get({ publicKey: {
			challenge: jawnosRandom(32),
			allowCredentials: [{ type: 'public-key', id: jawnosB64Bytes(id) }],
			userVerification: 'required',
			timeout: 60000
		} }).then(function (a) { return !!a; }).catch(function (e) {
			if (e && (e.name === 'NotAllowedError' || e.name === 'AbortError')) { return false; }
			return true;
		});
	}
	return Promise.resolve(true);
}

// Sign the one-time challenge with this device's pairing key and ask the house
// to open the target screen (or the whole house when target is empty).
function jawnPadlockSignOpen(mode, target, status, house) {
	mode = mode || 'locker';
	house = !!house;
	var signedTarget = house ? 'house' : (target || '');
	var uuid = jawnDeviceUuid();
	if (!uuid) { return Promise.reject({ error: 'not paired' }); }
	if (!(window.crypto && crypto.subtle && crypto.subtle.sign)) { return Promise.reject({ error: 'unavailable' }); }
	return jawnosDeviceKeyGet().then(function (key) {
		if (!key) { throw { error: 'not paired' }; }
		return $.post('/manager/security/padlock_challenge', { device_uuid: uuid });
	}).then(function (ch) {
		if (!ch || !ch.ok || !ch.nonce) { throw { error: (ch && ch.error) || 'no challenge' }; }
		var msg = 'padlock-unlock\n' + uuid + '\n' + (signedTarget ? signedTarget + '\n' : '') + ch.nonce;
		return crypto.subtle.sign('Ed25519', key, new TextEncoder().encode(msg)).then(function (sig) {
			var body = { device_uuid: uuid, nonce: ch.nonce, signature: jawnosB64(sig), mode: mode };
			if (house) { body.house = 1; }
			else if (target) { body.target = target; }
			return $.post('/manager/security/padlock_unlock', body);
		});
	}).then(function (res) {
		if (!res || !res.ok) { throw { error: (res && res.error) || 'not accepted' }; }
		return res;
	});
}

// A phone that wakes should find a request that arrived while it slept, but it
// must never be sent to another page on the way.
function jawnPadlockTick() {
	if (typeof jawnPadlockKeyCheck === 'function') { jawnPadlockKeyCheck(true); }
}

document.addEventListener('visibilitychange', function () {
	if (document.hidden) { return; }
	jawnPadlockTick();
	setTimeout(jawnPadlockTick, 1200);
});
// A socket that reconnects after a sleep or a network change has missed
// whatever the house sent while it was gone. Ask for the pending request on
// every way a page can come back, not only visibilitychange.
window.addEventListener('pageshow', jawnPadlockTick);
window.addEventListener('focus', jawnPadlockTick);

// The standalone locked page has no manager websocket. Its own template starts
// the 2.5s poll (locked_screen.html.ep), which also checks pending requests;
// this file is in the head, where the body does not exist yet.

// A manager page has no lock poll of its own. One slow tick catches a request
// that arrived while the socket was down (the phone wake), and lets a page
// whose session lost its device identity find out that this screen is locked.
setTimeout(jawnPadlockTick, 800);
setInterval(jawnPadlockTick, 15000);

// Back must not restore a manager page from before the lock. The browser's
// bfcache keeps that DOM (and its clickable windows) without asking the server;
// a persisted pageshow reloads it, so the gate answers with the lock again.
window.addEventListener('pageshow', function (e) {
	if (e.persisted && (document.getElementById('taskbar') || document.getElementById('locked_screen'))) {
		location.reload();
	}
});
// A history move that did not come from the bfcache still gets checked: if this
// device is locked, the stale page is replaced with the server's lock page.
window.addEventListener('popstate', function () {
	if (!document.getElementById('taskbar')) { return; }
	$.getJSON('/manager/security/padlock_state', { device_uuid: jawnDeviceUuid() }, function (s) {
		if (s && s.ok && s.locked) { location.reload(); }
	});
});



$(document).on('click', '#download_program', function() {
	var text = $(this).text();
	$(this).text('hold on...');
	var timestamp = Date.now();
	window.location='/download_program?timestamp=' + timestamp;
	$(this).text(text);
});

var vidControls = {};

// ---- theme ink: light text/icons when the background is dark -------------------
function jawnosInk() {
	var c = '';
	try { c = getComputedStyle(document.body).getPropertyValue('--ink'); } catch (e) { c = ''; }
	return (c && c.trim()) || '#000000';
}
// The Misc → Font choice. The layout writes it onto the root as --jawnos-font,
// so the whole shell inherits it; canvas art has no CSS inheritance, so the
// printers read the same value back through here.
function jawnosFont() {
	var f = '';
	try { f = getComputedStyle(document.documentElement).getPropertyValue('--jawnos-font'); } catch (e) { f = ''; }
	return (f && f.trim()) || 'system-ui, sans-serif';
}
// A colour that contrasts with the ink. Canvas art that is drawn over a user's
// background picture cannot trust the themed ink alone (a dark scheme gives
// near-white ink, which vanishes on a light photo), so it gets outlined with
// this instead.
function jawnosInkHalo(ink) {
	var hex = (ink || '#000000').replace('#', '');
	if (hex.length == 3) { hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]; }
	var n = parseInt(hex, 16);
	if (isNaN(n)) { n = 0; }
	var lum = (0.2126 * ((n >> 16) & 255) + 0.7152 * ((n >> 8) & 255) + 0.0722 * (n & 255)) / 255;
	return lum > 0.5 ? 'rgba(0,0,0,0.6)' : 'rgba(255,255,255,0.6)';
}
// Pick black or white for a label sitting on an arbitrary background colour, so
// each item can decide its own text colour from its own fill (a garment tile, a
// coloured chip) rather than trusting the themed ink - a dark theme's near-white
// ink vanishes on a pale garment. WCAG-weighted, the same maths and the same
// ~0.179 tie as subs::contrast_ink, so canvas and templates agree.
function jawnosContrastInk(bg) {
	var hex = ('' + (bg == null ? '' : bg)).replace(/^\s*#/, '').trim();
	if (hex.length == 3) { hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2]; }
	if (!/^[0-9a-fA-F]{6}$/.test(hex)) { return '#000000'; }
	var n = parseInt(hex, 16);
	var part = [ (n >> 16) & 255, (n >> 8) & 255, n & 255 ];
	var weight = [ 0.2126, 0.7152, 0.0722 ];
	var lum = 0;
	for (var i = 0; i < 3; i++) {
		var c = part[i] / 255;
		c = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
		lum += c * weight[i];
	}
	return lum < 0.179 ? '#ffffff' : '#000000';
}
// The colour an appointment paints with right now: its own colour on a light
// desktop, and the dark-theme counterpart (settings.dark_colour) while the body
// wears dark_theme. The stored colour is never changed - this only chooses the
// face. Canvas printers call it per draw, so a theme change takes effect on the
// next redraw.
function jawnosApptColour(setting) {
	if (!setting) { return undefined; }
	if (document.body.classList.contains('dark_theme') && setting['dark_colour']) {
		return setting['dark_colour'];
	}
	return setting['colour'];
}
// Repaint the live appointment markup for a changed colour. The server writes
// the two values into the elements as custom properties, so updating them here
// keeps a panel change and a dark-theme switch in step. A window's name span
// carries its app as "'name'" (a legacy quoting quirk), so the app attribute is
// normalised before it is compared.
function jawnosApptNodes(app) {
	var found = $();
	$('[data-appt-tint], [data-appt-ink]').each(function () {
		var a = ('' + ($(this).attr('app') || '')).replace(/^'+|'+$/g, '');
		if (a === app) { found = found.add(this); }
	});
	return found;
}
function jawnosApptColourSet(app, colour, dark) {
	if (!app) { return; }
	var ink = jawnosContrastInk(colour);
	var dark_ink = dark ? jawnosContrastInk(dark) : undefined;
	var nodes = jawnosApptNodes(app);
	nodes.filter('[data-appt-tint]').each(function () {
		if (dark) {
			this.style.setProperty('--appt-dark', dark);
			this.style.setProperty('--appt-dark-ink', dark_ink);
		}
		this.style.backgroundColor = colour;
		this.style.color = ink;
	});
	nodes.filter('[data-appt-ink]').each(function () {
		if (dark) { this.style.setProperty('--appt-dark-ink', dark_ink); }
		this.style.color = ink;
	});
}
function jawnosApptDarkColourSet(app, dark) {
	if (!app || !dark) { return; }
	var dark_ink = jawnosContrastInk(dark);
	jawnosApptNodes(app).each(function () {
		this.style.setProperty('--appt-dark', dark);
		this.style.setProperty('--appt-dark-ink', dark_ink);
	});
}
// Ink for a surface whose colour the caller paints (the sync dot's panel):
// below the same WCAG tie it takes the theme's light ink, otherwise black. On
// a light theme the themed ink is black already, so both branches agree.
function jawnosSurfaceInk(bg) {
	if (jawnosContrastInk(bg) !== '#ffffff') { return '#000000'; }
	// A dark surface wants a light ink. The theme's ink is light only on a dark
	// theme; a light theme's black would vanish here, so fall back to the dark
	// theme's own near-white.
	var ink = jawnosInk();
	return jawnosContrastInk(ink) === '#ffffff' ? ink : '#d4d4d4';
}
// Canvas text for the manager printers. The themed ink alone can vanish over a
// background picture, so when pictures are on the text gets a contrasting SOFT
// SHADOW to sit on. It used to be stroked (ctx.strokeText) instead, which read
// as a hard white/black border around every glyph; the shadow keeps the same
// legibility over a picture without the fringe. Vertical centring is the default
// - the printers reason about marker rows, not baselines.
function jawnosPrinterText(ctx, text, x, y, opts) {
	opts = opts || {};
	ctx.save();
	if (opts.font) { ctx.font = opts.font; }
	if (opts.align) { ctx.textAlign = opts.align; }
	ctx.textBaseline = opts.baseline || 'middle';
	if (opts.alpha != null) { ctx.globalAlpha = opts.alpha; }
	if (opts.halo) {
		ctx.shadowColor = opts.halo;
		ctx.shadowBlur = opts.haloBlur || 4;
	}
	ctx.fillStyle = opts.colour || jawnosInk();
	ctx.fillText('' + text, x, y);
	ctx.restore();
}
// The halo to draw under printer text, or undefined when no picture is up.
function jawnosPrinterHalo() {
	if (localStorage.getItem('background_images') == 'on' && typeof jawnosInkHalo == 'function') {
		return jawnosInkHalo(jawnosInk());
	}
	return undefined;
}
function jawnosRgbToHsl(r, g, b) {
	r /= 255; g /= 255; b /= 255;
	var max = Math.max(r, g, b), min = Math.min(r, g, b);
	var h = 0, s = 0, l = (max + min) / 2, d = max - min;
	if (d) {
		s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
		if (max === r) { h = (g - b) / d + (g < b ? 6 : 0); }
		else if (max === g) { h = (b - r) / d + 2; }
		else { h = (r - g) / d + 4; }
		h *= 60;
	}
	return [h, s, l];
}
function jawnosRgbToHex(r, g, b) {
	var part = function (v) {
		var p = Math.max(0, Math.min(255, Math.round(v))).toString(16);
		return p.length < 2 ? '0' + p : p;
	};
	return '#' + part(r) + part(g) + part(b);
}
function jawnosHslToHex(h, s, l) {
	h = ((h % 360) + 360) % 360;
	var c = (1 - Math.abs(2 * l - 1)) * s;
	var x = c * (1 - Math.abs(((h / 60) % 2) - 1));
	var m = l - c / 2;
	var r = 0, g = 0, b = 0;
	if (h < 60) { r = c; g = x; }
	else if (h < 120) { r = x; g = c; }
	else if (h < 180) { g = c; b = x; }
	else if (h < 240) { g = x; b = c; }
	else if (h < 300) { r = x; b = c; }
	else { r = c; b = x; }
	var part = function (v) { var p = Math.round((v + m) * 255).toString(16); return p.length < 2 ? '0' + p : p; };
	return '#' + part(r) + part(g) + part(b);
}
// Recompute the panel and ink variables from the page background so windows and
// text follow the active colour scheme. configure.js updates the body colour on a
// live scheme change and then calls this, so windows re-theme without a reload.
function jawnosApplyInk() {
	var bg = '';
	try { bg = getComputedStyle(document.body).backgroundColor || ''; } catch (e) { bg = ''; }
	var m = bg.match(/rgba?\(([^)]+)\)/);
	if (!m) { return; }
	var parts = m[1].split(',').map(function (x) { return parseFloat(x); });
	if (parts.length < 3) { return; }
	// a transparent body has no scheme colour to derive from; deriving one from
	// black would flip the ink to white and hide the canvas art
	if (parts.length >= 4 && parts[3] === 0) { return; }
	var r = parts[0], g = parts[1], b = parts[2];
	var lum = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
	var hsl = jawnosRgbToHsl(r, g, b);
	var tint = hsl[1] < 0.18 ? hsl[1] : 0.18;
	// keep in step with subroutines.pl::theme_panel_css: --line is the chrome
	// border (a shade off --panel), --ink the text (softened from near-white so
	// a dark theme does not glare), and --ink-muted the fainter text/state edge.
	var panel, panel2, ink, ink_muted, line;
	if (lum < 0.5) {
		panel = jawnosHslToHex(hsl[0], tint, 0.16);
		panel2 = jawnosHslToHex(hsl[0], tint, 0.23);
		line = jawnosHslToHex(hsl[0], tint, 0.32);
		ink = '#d4d4d4'; ink_muted = '#8f8f8f';
	}
	else {
		panel = jawnosHslToHex(hsl[0], tint, 0.88);
		panel2 = jawnosHslToHex(hsl[0], tint, 0.80);
		line = jawnosHslToHex(hsl[0], tint, 0.66);
		ink = '#000000'; ink_muted = '#333333';
	}
	// The window surface is its own shade in every scheme: the curated next
	// step of the palette's ramp when the manager colour names a scheme (the
	// manager layout hands that map in), otherwise derived the same way the
	// server's theme_panel_css derives it.
	var bg_hex = jawnosRgbToHex(r, g, b).toLowerCase();
	var window_hex = '';
	if (typeof jawnos_colour_windows != 'undefined' && jawnos_colour_windows) {
		window_hex = jawnos_colour_windows[bg_hex] || '';
	}
	if (!window_hex) {
		window_hex = jawnosHslToHex(hsl[0], tint, lum < 0.5 ? 0.24 : 0.96);
	}
	var style = document.body.style;
	style.setProperty('--panel', panel);
	style.setProperty('--panel-2', panel2);
	style.setProperty('--window', window_hex);
	style.setProperty('--line', line);
	style.setProperty('--ink', ink);
	style.setProperty('--ink-muted', ink_muted);
	// the icon sets ship a light and a dark cut: when the desktop crosses the
	// light/dark line the buttons on screen have to be asked for again
	var was_dark = document.body.classList.contains('dark_theme');
	var is_dark = lum < 0.5;
	document.body.classList.toggle('dark_theme', is_dark);
	if (was_dark !== is_dark && !window.jawnos_theme_suppress_icon_reload && typeof jawnosReloadIcons === 'function') {
		setTimeout(jawnosReloadIcons, 80);
	}
}
// Paint the manager for a new theme. `appt` marks that a running appointment's
// theme (not the Misc system theme) is in charge, so a later Misc change does
// not paint over it. Deriving the panel/ink variables from the new background
// is the same path a hand-picked manager colour already takes.
function jawnosThemeApply(bg, appt) {
	if (!bg) { return; }
	if (appt) { document.body.setAttribute('data-appt-theme', 'yes'); }
	else { document.body.removeAttribute('data-appt-theme'); }
	document.body.style.backgroundColor = bg;
	jawnosApplyInk();
}
$(function () { jawnosApplyInk(); });

// ---- icon set swap: refresh the icons currently on screen ----------------------
// Called over the websocket after the pseudonym icon set changes; re-renders any
// open appointment windows and rebuilds the start-menu dock from their icons.

// The now button wears the state of the time machine in its tile: the same
// yellow the button's background turns at home, and the same blue it turns
// while the machine is walking. Every icon set keeps the pair beside its plain
// now tile - "now here" and "now time machine" - so each answers the state in
// its own colours; the hand-drawn set, and any set built before the pair
// existed, keep the plain icon. The pair is derived from the plain now tile in
// the button's src, which is what both the template and the set-change reload
// put there.
function nowIconApply(state) {
	var button = $('#now_toggle');
	if (button.length == 0) { return; }
	var src = button.attr('src') || '';
	var match = src.match(/^(.*\/)now( here| time machine)?\.svg$/i);
	if (!match) { return; }
	button.attr('src', match[1] + 'now' + (state == 'time_machine' ? ' time machine' : ' here') + '.svg');
}

function jawnosReloadIcons() {
	try {
		// The desktop's own buttons were rendered with the old set, and only the
		// server knows where a path lives in the new one, so ask it for those
		// paths again and swap the sources.
		var nodes = $('[jawnos_icon]');
		if (nodes.length > 0) {
			var paths = [];
			nodes.each(function () {
				var p = $(this).attr('jawnos_icon');
				if (p && paths.indexOf(p) == -1) { paths.push(p); }
			});
			$.ajax({
				url: '/manager/icons',
				type: 'GET',
				data: { paths: JSON.stringify(paths), refresh: 1 },
				success: function (response) {
					nodes.each(function () {
						var p = $(this).attr('jawnos_icon');
						if (response.icons && response.icons[p]) { $(this).attr('src', response.icons[p]); }
					});
					// that swap put the plain now tile back; let it answer the state
					nowIconApply(localStorage.getItem('time_machine') ? 'time_machine' : 'here');
				}
			});
		}
		$('.wind').each(function () {
			var app = $(this).attr('app');
			if (!app) { return; }
			if (typeof appWindowOpener === 'function') {
				appWindowOpener(app, Date.now(), { visible: 'yes' });
			}
			else if (typeof appointmentGrabber === 'function') {
				appointmentGrabber(app);
			}
		});
		// refresh an open start menu (passing `source` skips the close branch)
		if (typeof startMenuToggle === 'function' && $('#start_menu').is(':visible')) {
			startMenuToggle({ source: 'icon_refresh' });
		}
		if (typeof startMenuListify === 'function') { startMenuListify(); }
		if (typeof taskbarDisplayer === 'function') {
			setTimeout(function () { taskbarDisplayer(); }, 1200);
		}
	} catch (e) {}
}

// ---- local biometric unlock ---------------------------------------------------
// The Android app holds an EC P-256 key in Android Keystore that the OS releases
// only after a fingerprint prompt (window.JawnBiometricKey). The house verifies
// the signature, so this is a real factor and the one local signature the
// padlock accepts: it opens only the screen the key belongs to.
function jawnosB64(buf) {
	var bytes = new Uint8Array(buf);
	var s = '';
	for (var i = 0; i < bytes.length; i++) { s += String.fromCharCode(bytes[i]); }
	return btoa(s);
}
function jawnosSha256Hex(text) {
	return crypto.subtle.digest('SHA-256', new TextEncoder().encode(text)).then(function (buf) {
		return Array.prototype.map.call(new Uint8Array(buf), function (b) {
			return ('0' + b.toString(16)).slice(-2);
		}).join('');
	});
}
function jawnosDeviceKeyGet() {
	return new Promise(function (res, rej) {
		var r = indexedDB.open('jawn_device', 1);
		r.onupgradeneeded = function () { r.result.createObjectStore('keys'); };
		r.onsuccess = function () {
			var db = r.result;
			var tx = db.transaction('keys', 'readonly');
			var q = tx.objectStore('keys').get('device_key');
			q.onsuccess = function () { res(q.result); };
			q.onerror = function () { rej(q.error); };
		};
		r.onerror = function () { rej(r.error); };
	});
}
function jawnosBiometricKeyCall(method, args) {
	return new Promise(function (resolve, reject) {
		if (!window.JawnBiometricKey) { reject({ error: 'unavailable' }); return; }
		var done = false;
		window.jawnosBiometricKeyResult = function (res) {
			if (done) { return; }
			done = true;
			window.jawnosBiometricKeyResult = null;
			resolve(res || { ok: false, error: 'failed' });
		};
		try {
			if (method === 'enroll') { window.JawnBiometricKey.enroll(args[0] || 'Set up this device\'s unlock'); }
			else if (method === 'sign') { window.JawnBiometricKey.sign(args[0], args[1] || 'Unlock the house'); }
			else if (method === 'hasKey') { window.JawnBiometricKey.hasKey(); }
			else { done = true; reject({ error: 'unavailable' }); }
		}
		catch (e) { done = true; window.jawnosBiometricKeyResult = null; reject({ error: 'unavailable' }); }
	});
}
// Make (or rotate) the phone's biometric key and register its public half with
// the house. The enrollment message is signed by the device's existing pairing
// key, so a page that merely knows a UUID cannot register a key. When a key is
// already enrolled, the caller must pass the proof returned by
// jawnosBiometricVerify so the old fingerprint authorizes its replacement.
function jawnosBiometricEnroll(status, proof) {
	status = status || function () {};
	proof = proof || {};
	var uuid = localStorage.getItem('device_uuid') || '';
	if (!uuid) { return Promise.reject({ error: 'not paired' }); }
	if (!window.JawnBiometricKey) { return Promise.reject({ error: 'unavailable' }); }
	status('Waiting for authentication...');
	return jawnosDeviceKeyGet().then(function (key) {
		if (!key) { throw { error: 'not paired' }; }
		return jawnosBiometricKeyCall('enroll', ['Set up this device\'s unlock']);
	}).then(function (res) {
		if (!res || !res.ok || !res.pubkey) { throw { error: (res && res.error) || 'unavailable' }; }
		var pubkey = res.pubkey;
		return $.post('/manager/security/biometric_challenge', { device_uuid: uuid, purpose: 'enroll' }).then(function (ch) {
			if (!ch || !ch.ok || !ch.nonce) { throw { error: 'challenge' }; }
			return jawnosSha256Hex(pubkey).then(function (hash) {
				var msg = 'padlock-bio-enroll\n' + uuid + '\n' + ch.nonce + '\n' + hash;
				return jawnosDeviceKeyGet().then(function (key) {
					return crypto.subtle.sign('Ed25519', key, new TextEncoder().encode(msg));
				}).then(function (sig) {
					return $.post('/manager/security/biometric_enroll', {
						device_uuid: uuid, nonce: ch.nonce, device_signature: jawnosB64(sig), pubkey: pubkey,
						bio_nonce: proof.nonce || '', bio_signature: proof.signature || ''
					});
				});
			});
		});
	}).then(function (res) {
		if (!res || !res.ok) { throw { error: (res && res.error) || 'not accepted' }; }
		return res;
	});
}
// Prove the fingerprint already enrolled on this phone. Used before replacing
// it, so a new fingerprint cannot be set without passing the old one.
function jawnosBiometricVerify(status) {
	status = status || function () {};
	var uuid = localStorage.getItem('device_uuid') || '';
	if (!uuid) { return Promise.reject({ error: 'not paired' }); }
	if (!window.JawnBiometricKey) { return Promise.reject({ error: 'unavailable' }); }
	status('Confirm it is you...');
	return $.post('/manager/security/biometric_challenge', { device_uuid: uuid, purpose: 'verify' }).then(function (ch) {
		if (!ch || !ch.ok || !ch.nonce) { throw { error: (ch && ch.error) || 'no challenge' }; }
		var msg = 'padlock-bio-verify\n' + uuid + '\n' + ch.nonce;
		return jawnosBiometricKeyCall('sign', [jawnosB64(new TextEncoder().encode(msg)), 'Confirm your fingerprint']).then(function (res) {
			if (!res || !res.ok || !res.signature) { throw { error: (res && res.error) || 'not accepted' }; }
			return { nonce: ch.nonce, signature: res.signature };
		});
	});
}
function jawnosBiometricUnlock(mode, target, status, context, house, sourceHost, deviceName) {
	status = status || function () {};
	mode = mode || 'locker';
	house = !!house;
	var uuid = jawnDeviceUuid();
	if (!uuid) { return Promise.reject({ error: 'not paired' }); }
	if (!window.JawnBiometricKey) { return Promise.reject({ error: 'unavailable' }); }
	// The target (or the house) is bound into the signed message: a fingerprint
	// confirmation made for one screen cannot be replayed to open another.
	var signedTarget = house ? 'house' : (target || '');
	var promptText = jawnPadlockUnlockLabel(mode, house, deviceName, sourceHost);
	function once() {
		return $.post('/manager/security/biometric_challenge', { device_uuid: uuid, purpose: 'unlock' }).then(function (ch) {
			if (!ch || !ch.ok || !ch.nonce) { throw { error: (ch && ch.error) || 'challenge' }; }
			var msg = 'padlock-bio-unlock\n' + uuid + '\n' + (signedTarget ? signedTarget + '\n' : '') + ch.nonce;
			return jawnosBiometricKeyCall('sign', [jawnosB64(new TextEncoder().encode(msg)), promptText]).then(function (res) {
				if (!res || !res.ok || !res.signature) { throw { error: (res && res.error) || 'not accepted' }; }
				// the thumb passed; the shackle opens while the house verifies the signature
				if (typeof jawnPadlockArtUnlocking === 'function') { jawnPadlockArtUnlocking(context); }
				var body = { device_uuid: uuid, nonce: ch.nonce, signature: res.signature, mode: mode };
				if (house) { body.house = 1; }
				else if (target) { body.target = target; }
				return $.post('/manager/security/biometric_unlock', body);
			});
		});
	}
	status('Authenticate to unlock...');
	return once().then(function (res) {
		if (!res || !res.ok) { throw { error: (res && res.error) || 'not accepted' }; }
		return res;
	});
}
function jawnosBiometricError(err) {
	var e = (err && err.error) || '';
	if (e === 'unavailable') { return 'Fingerprint unlock is not available in this app.'; }
	if (e === 'not paired') { return 'This phone is not paired to the house.'; }
	if (e === 'no biometric key') { return 'No fingerprint is enrolled. Set it up under Security before locking.'; }
	if (e === 'no key') { return 'No fingerprint is enrolled. Set it up under Security before locking.'; }
	if (e === 'invalidated') { return 'The fingerprint key was reset. Use the recovery code, then enroll it again.'; }
	if (e === 'too many' || e === 'locked') { return 'Too many attempts. Try again later.'; }
	if (e === 'no challenge') { return 'The unlock challenge expired. Try again.'; }
	if (e === 'bad key') { return "The phone's key could not be registered. Try again."; }
	if (e === 'confirm fingerprint') { return 'Confirm the enrolled fingerprint before setting a new one.'; }
	if (e === 'not signed in') { return 'Sign in, then enroll the fingerprint.'; }
	// a failed request (a 500, or a dropped connection) has a status rather than
	// an error word; saying "fingerprint not accepted" blamed the thumb for a
	// server fault, which is exactly how a missing helper stayed hidden
	if (!e && err && err.status) { return 'The house did not register the key (HTTP ' + err.status + ').'; }
	return 'Fingerprint not accepted.';
}
// The lock screens show the denial picture at rest. While a fingerprint is being
// read the hand-drawn padlock replaces it: the shackle lifts into the open
// drawing, and a failed read snaps it shut again. The button names the frame it
// belongs to, so an app lock's hidden padlock is never the one animated.
function jawnPadlockArtScope(el) {
	var s = el ? $(el).closest('#locked_screen, .padlock_frame') : null;
	if (s && s.length) { return s; }
	var visible = $('#locked_screen').filter(':visible').first();
	if (visible.length) { return visible; }
	return $(document);
}
function jawnPadlockArtLocked(snap, el) {
	var scope = jawnPadlockArtScope(el);
	var box = scope.find('.padlock_lock_art').first();
	if (!box.length) { return; }
	scope.find('.padlock_emblem .denial_image').first().css('visibility', 'hidden');
	box.show();
	if (snap) {
		box.addClass('snap').removeClass('unlocking');
		void box[0].offsetWidth;
		setTimeout(function () { box.removeClass('snap'); }, 40);
	}
	else {
		box.removeClass('unlocking');
	}
}
function jawnPadlockArtUnlocking(el) {
	var scope = jawnPadlockArtScope(el);
	var box = scope.find('.padlock_lock_art').first();
	if (!box.length) { return; }
	scope.find('.padlock_emblem .denial_image').first().css('visibility', 'hidden');
	box.show().removeClass('snap').removeClass('unlocking');
	void box[0].offsetWidth;
	box.addClass('unlocking');
}
$(document).on('click', '.padlock_biometric, #locked_biometric', function () {
	var button = $(this);
	var frame = button.closest('.padlock_frame');
	var mode = frame.length ? (frame.attr('mode') || 'locker') : 'locker';
	var note = frame.length ? frame.find('.padlock_fingerprint_status') : $('#locked_phone_status');
	button.prop('disabled', true);
	jawnPadlockArtLocked(false, button);
	if (note.length) { note.text('Touch the fingerprint reader...'); }
	var mine = jawnDeviceUuid();
	jawnosBiometricUnlock(mode, mine, function (t) {
		if (note.length) { note.text(t); }
	}, button).catch(function (err) {
		var e = (err && err.error) || '';
		// A browser without the Android bridge can still ask the platform
		// authenticator (WebAuthn) and then sign with the pairing key.
		if (e === 'unavailable' || e === 'no key' || e === 'invalidated') {
			return jawnPadlockConfirm('Unlock the locked screen').then(function (ok) {
				if (!ok) { throw { error: 'cancelled' }; }
				if (note.length) { note.text('Unlocking...'); }
				return jawnPadlockSignOpen(mode, mine, note);
			});
		}
		throw err;
	}).then(function () {
		if (note.length) { note.text('Unlocked. Loading...'); }
		// the gate repaints from the server; an app padlock is refreshed by the
		// console message the unlock already sent
		if (mode === 'locker') { setTimeout(function () { window.location.reload(); }, 700); }
	}).catch(function (err) {
		jawnPadlockArtLocked(true, button);
		button.prop('disabled', false);
		if (note.length) { note.text(jawnosBiometricError(err)); }
	});
});

// The computer's own reader, for an in-app padlock as well as the lock screen.
// The Gate's locked page has its own copy; this one lives with the partial so
// the music, folders and gallery padlocks get the same way in.
$(document).on('click', '.padlock_fingerprint', function () {
	var button = $(this);
	if (window.jawnos_local_fingerprint === 0) { return; }
	var frame = button.closest('.padlock_frame');
	if (!frame.length) { return; }
	var mode = frame.attr('mode') || 'locker';
	var note = frame.find('.padlock_fingerprint_status');
	var t = function (text) { return (typeof jawnosT === 'function') ? jawnosT(text) : text; };
	var say = function (text) { if (note.length) { note.text(text); } };
	var finish = function (res) {
		if (res && res.ok) {
			// the accepted print mints the app's token and refreshes the window
			say(t('Unlocked. Loading...'));
			return;
		}
		button.prop('disabled', false);
		if (typeof jawnPadlockArtLocked === 'function') { jawnPadlockArtLocked(true, button); }
		var e = (res && res.error) || '';
		say((e === 'busy') ? t('A fingerprint is already being read.')
			: (e === 'timeout') ? t('No fingerprint was read. Try again.')
			: (e === 'local only') ? t('This reader only works on the computer it is attached to.')
			: (e === 'no fingerprint') ? t('No fingerprint is enrolled on this computer.')
			: (e === 'not signed in') ? t('Sign in again, then use the fingerprint.')
			: (e === 'not at home') ? t('That padlock only opens at home.')
			: (e === 'no device') ? t('That screen is not known to the house.')
			: t('Fingerprint not accepted.'));
	};
	var poll = function (token, tries) {
		tries = tries || 0;
		$.ajax({ url: '/manager/security/fingerprint_unlock_status', type: 'GET', data: { token: token }, cache: false })
			.then(function (res) {
				if (res && res.pending) {
					if (tries > 30) { finish({ ok: 0, error: 'timeout' }); return; }
					setTimeout(function () { poll(token, tries + 1); }, 700);
					return;
				}
				finish(res);
			})
			.catch(function () { finish({ ok: 0, error: 'unavailable' }); });
	};
	button.prop('disabled', true);
	if (typeof jawnPadlockArtLocked === 'function') { jawnPadlockArtLocked(false, button); }
	say(t('Touch the fingerprint reader now...'));
	$.ajax({ url: '/manager/security/fingerprint_unlock', type: 'POST', data: { mode: mode }, cache: false })
		.then(function (res) {
			if (res && res.pending && res.token) { poll(res.token, 0); return; }
			finish(res);
		})
		.catch(function () { finish({ ok: 0, error: 'unavailable' }); });
});

// ---- icon hints: hover label on desktop, long-press label on touch ------------
// Any element with a `hint="..."` attribute shows a small floating label when
// hovered (pointer devices) or long-pressed (touch). Draggable elements are
// skipped on touch so a long press can start a drag instead.
var jawnos_hint_timer = null;
var jawnos_touch_hint_active = false;
function jawnosHintNode() {
	var h = document.getElementById('jawnos_hint');
	if (!h) {
		h = document.createElement('div');
		h.id = 'jawnos_hint';
		h.style.cssText = 'position:fixed;display:none;z-index:90000;background:rgba(0,0,0,0.86);color:#fff;padding:3px 8px;border-radius:6px;font-size:13px;line-height:1.3;max-width:260px;pointer-events:none;box-shadow:0 1px 4px rgba(0,0,0,0.4);white-space:nowrap;';
		document.body.appendChild(h);
	}
	return h;
}
function jawnosHintShow(el, x, y, gap) {
	var hint = $(el).attr('hint');
	var topic = $(el).attr('help');
	// An element may carry a short label (hint), a help topic (help), or both.
	// When a topic is present the label says so, and F1 opens the full entry.
	var text = hint || '';
	if (topic) { text = text ? (text + ' \u00b7 F1') : 'Help \u00b7 F1'; }
	if (!text) { return; }
	if (gap == null) { gap = 12; }
	var h = jawnosHintNode();
	h.textContent = text;
	h.style.display = 'block';
	var w = h.offsetWidth, hh = h.offsetHeight;
	if (x == null) {
		var o = $(el).offset() || { left: 0, top: 0 };
		x = o.left + ($(el).width() / 2);
		y = o.top;
	}
	var left = Math.max(4, Math.min(x - (w / 2), $(window).width() - w - 4));
	var top = y - hh - gap;
	if (top < 4) { top = y + gap + 16; }
	h.style.left = left + 'px';
	h.style.top = top + 'px';
}
function jawnosHintHide() {
	var h = document.getElementById('jawnos_hint');
	if (h) { h.style.display = 'none'; }
}
var jawnos_click_killer = null;
var jawnos_killer_timer = null;
// how near the press a click has to land to be the press's own; a fingertip's
// worth of drift covers the lag between the finger and the browser's click
var jawnos_click_slop = 30;
// for a moment after a long press, throw away the click the browser is about to
// deliver, so reading a hint does not also press the thing underneath it. Only
// a click at the press is thrown away: that is where the press's own delayed
// click lands, while a later tap elsewhere - a row on the timeline, say - keeps
// its click even when it falls inside the moment. A press that names no point
// keeps the old whole-page hold, since there is nothing to measure against.
function jawnosSuppressClick(x, y) {
	jawnosUnsuppressClick();
	jawnos_click_killer = function (e) {
		if (x != undefined && (Math.abs(e.clientX - x) > jawnos_click_slop || Math.abs(e.clientY - y) > jawnos_click_slop)) { return; }
		e.stopPropagation();
		e.preventDefault();
		jawnosUnsuppressClick();
	};
	document.addEventListener('click', jawnos_click_killer, true);
	jawnos_killer_timer = setTimeout(jawnosUnsuppressClick, 700);
}
function jawnosUnsuppressClick() {
	if (jawnos_click_killer) {
		document.removeEventListener('click', jawnos_click_killer, true);
		jawnos_click_killer = null;
	}
	clearTimeout(jawnos_killer_timer);
	jawnos_killer_timer = null;
}

var jawnos_hover_capable = true;
try { jawnos_hover_capable = window.matchMedia('(hover: hover)').matches; } catch (e) {}

if (jawnos_hover_capable) {
	$(document).on('mouseenter', '[hint], [help]', function () {
		if (jawnos_touch_hint_active) { return; }
		var el = this;
		clearTimeout(jawnos_hint_timer);
		// wait before showing so the label doesn't flash on every pass
		jawnos_hint_timer = setTimeout(function () {
			var m = mouse_position();
			jawnosHintShow(el, m.x, m.y);
		}, 1000);
	});
	$(document).on('mouseleave', '[hint], [help]', function () {
		clearTimeout(jawnos_hint_timer);
		jawnosHintHide();
	});
	$(document).on('mousedown', function () { clearTimeout(jawnos_hint_timer); jawnosHintHide(); });
}

$(document).on('touchstart', '[hint], [help]', function (e) {
	var el = this;
	if ($(el).hasClass('draggable') || $(el).closest('.draggable').length > 0) { return; }
	// where a context menu is registered the hold belongs to it, not the hint
	if (typeof jawnosHasContextMenu == 'function' && jawnosHasContextMenu(el)) { return; }
	// the start menu rows wear their name already; a long press there must not
	// swallow the tap that would open the app
	if ($(el).closest('.start_menu_item').length > 0) { return; }
	// a fresh press owns its click, whatever the last long press left behind
	jawnosUnsuppressClick();
	var touch = e.originalEvent.touches && e.originalEvent.touches[0];
	if (!touch) { return; }
	var tx = touch.clientX, ty = touch.clientY;
	clearTimeout(jawnos_hint_timer);
	jawnos_hint_timer = setTimeout(function () {
		jawnos_touch_hint_active = true;
		jawnosHintShow(el, tx, ty, 30);
		jawnosSuppressClick(tx, ty);
	}, 500);
});
$(document).on('touchend touchcancel', function () {
	clearTimeout(jawnos_hint_timer);
	if (jawnos_touch_hint_active) {
		setTimeout(function () { jawnosHintHide(); jawnos_touch_hint_active = false; }, 1200);
	}
});
$(document).on('touchmove', function () {
	if (!jawnos_touch_hint_active) { clearTimeout(jawnos_hint_timer); }
});

// ---- long press opens the context menus on touch --------------------------
// A hold on a registered surface dispatches the very contextmenu event the right
// button raises on a desk, at the finger, so every handler that answers a
// right-click answers a hold too. The hint's own long press stands down on those
// surfaces (see jawnosHasContextMenu above), so a menu and a label never race.
var jawnos_context_selectors = [];
var jawnos_context_timer = null;
function jawnosContextMenuOn(selector) {
	if (jawnos_context_selectors.indexOf(selector) < 0) { jawnos_context_selectors.push(selector); }
}
function jawnosHasContextMenu(el) {
	for (var i = 0; i < jawnos_context_selectors.length; i++) {
		if ($(el).closest(jawnos_context_selectors[i]).length) { return true; }
	}
	return false;
}
$(document).on('touchstart', function (e) {
	for (var i = 0; i < jawnos_context_selectors.length; i++) {
		if (!$(e.target).closest(jawnos_context_selectors[i]).length) { continue; }
		var t = e.originalEvent.touches && e.originalEvent.touches[0];
		if (!t) { return; }
		var target = e.target;
		var x = t.clientX, y = t.clientY;
		clearTimeout(jawnos_context_timer);
		jawnos_context_timer = setTimeout(function () {
			jawnosHintHide();
			jawnos_touch_hint_active = false;
			jawnosSuppressClick(x, y);
			target.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: x, clientY: y, button: 2 }));
		}, 550);
		return;
	}
});
$(document).on('touchend touchcancel touchmove', function () {
	clearTimeout(jawnos_context_timer);
});

// ---- multi-selects, the phone way -------------------------------------------
// A <select multiple> is a tall list that eats the page. It is painted as a
// compact trigger instead, and opened in a popup whose options are toggles -
// the way a phone shows a multi picker. The real select stays behind the
// trigger (kept, only hidden), so every existing change handler still fires.
(function () {
	if (window.jawnos_multiselect_installed) { return; }
	window.jawnos_multiselect_installed = true;
	var css = document.createElement('style');
	css.textContent = [
		'.ms-native { position:absolute !important; width:1px !important; height:1px !important; opacity:0 !important; pointer-events:none !important; left:-9999px !important; }',
		'.ms-trigger { font:inherit; text-align:left; cursor:pointer; padding:3px 24px 3px 8px; border:1px solid var(--line, rgba(0,0,0,.35)); border-radius:5px; background:var(--panel, #fff); color:var(--ink, #111); position:relative; max-width:280px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; vertical-align:top; }',
		'.ms-trigger:after { content:"\\25be"; position:absolute; right:8px; top:50%; transform:translateY(-50%); opacity:.55; }',
		'.ms-popup { position:fixed; z-index:100000; background:var(--panel, #fff); color:var(--ink, #111); border:1px solid var(--line, rgba(0,0,0,.4)); border-radius:8px; box-shadow:0 12px 44px rgba(0,0,0,.35); display:flex; flex-direction:column; min-width:200px; max-width:min(420px,92vw); }',
		'.ms-head { padding:9px 14px; font-weight:700; border-bottom:1px solid var(--line, rgba(0,0,0,.15)); }',
		'.ms-body { overflow:auto; padding:6px 0; }',
		'.ms-option { display:flex; align-items:center; gap:10px; padding:8px 14px; cursor:pointer; white-space:nowrap; }',
		'.ms-option:hover { background:var(--panel-2, rgba(0,0,0,.06)); }',
		'.ms-option input { width:18px; height:18px; accent-color:var(--accent, #0d47a1); }',
		'.ms-foot { border-top:1px solid var(--line, rgba(0,0,0,.15)); padding:6px 12px; text-align:right; }',
		'.ms-foot button { font:inherit; padding:4px 18px; border-radius:5px; border:1px solid var(--line, rgba(0,0,0,.3)); background:var(--panel-2, #f2f2f2); color:var(--ink, #111); cursor:pointer; }'
	].join('\n');
	document.head.appendChild(css);
})();
function multiselectSummary(sel) {
	var chosen = $(sel).find('option:selected').map(function () { return $.trim($(this).text()); }).get();
	chosen = chosen.filter(function (t) { return t.length; });
	if (!chosen.length) { return 'none'; }
	if (chosen.length <= 2) { return chosen.join(', '); }
	return chosen.length + ' selected';
}
function multiselectPaint(sel) {
	$(sel).siblings('.ms-trigger').first().text(multiselectSummary(sel));
}
function multiselectUpgrade(root) {
	$(root || document.body).find('select[multiple]').each(function () {
		var s = $(this);
		if (s.data('ms')) { return; }
		s.data('ms', 1);
		s.addClass('ms-native').before('<button type="button" class="ms-trigger"></button>');
		s.on('change', function () { multiselectPaint(this); });
		multiselectPaint(this);
	});
}
var ms_current, ms_current_sel;
function multiselectClose() {
	if (ms_current) { ms_current.remove(); ms_current = null; ms_current_sel = null; }
}
function multiselectOpen(sel) {
	multiselectClose();
	var s = $(sel);
	if (!s.length) { return; }
	var pop = $('<div class="ms-popup"></div>');
	pop.append($('<div class="ms-head"></div>').text(s.attr('hint') || s.attr('name') || 'Choose'));
	var body = $('<div class="ms-body"></div>');
	s.find('option').each(function () {
		var o = $(this);
		var cb = $('<input type="checkbox">').prop('checked', o.is(':selected'));
		cb.on('change', function () { o.prop('selected', this.checked); s.trigger('change'); });
		body.append($('<label class="ms-option"></label>').append(cb).append($('<span></span>').text(o.text() || '(none)')));
	});
	pop.append(body);
	pop.append($('<div class="ms-foot"><button type="button" class="ms-done">Done</button></div>'));
	$('body').append(pop);
	var maxH = Math.min(window.innerHeight * 0.72, 500);
	pop.css({ 'max-height': maxH + 'px' });
	body.css({ 'max-height': (maxH - 92) + 'px' });
	var t = s.siblings('.ms-trigger').first();
	var r = (t.length ? t[0] : s[0]).getBoundingClientRect();
	var left = Math.min(r.left, window.innerWidth - pop.outerWidth() - 8);
	if (left < 8) { left = 8; }
	var top = r.bottom + 4;
	if (top + pop.outerHeight() > window.innerHeight && r.top - pop.outerHeight() - 4 > 0) { top = r.top - pop.outerHeight() - 4; }
	if (top < 8) { top = 8; }
	pop.css({ left: left + 'px', top: top + 'px' });
	pop.find('.ms-done').on('click', function (e) { e.preventDefault(); multiselectClose(); });
	ms_current = pop;
	ms_current_sel = s;
}
$(document).on('click', '.ms-trigger', function (e) {
	e.preventDefault();
	e.stopPropagation();
	var sel = $(this).siblings('select[multiple]').first();
	// pressing the same trigger again puts the picker away
	if (ms_current && ms_current_sel && ms_current_sel.is(sel)) { multiselectClose(); return; }
	multiselectOpen(sel);
});
$(document).on('click', function (e) {
	if (!ms_current) { return; }
	if ($(e.target).closest('.ms-popup, .ms-trigger').length) { return; }
	multiselectClose();
});
$(document).on('keydown', function (e) {
	if (e.key === 'Escape') { multiselectClose(); }
});
// upgrade the selects already on the page and any a window brings in later; the
// sweep is debounced because the house re-renders a lot
var ms_sweep;
function multiselectSweep() {
	clearTimeout(ms_sweep);
	ms_sweep = setTimeout(function () { multiselectUpgrade(document.body); }, 120);
}
$(document).ready(function () { multiselectUpgrade(document.body); });
new MutationObserver(multiselectSweep).observe(document.documentElement, { childList: true, subtree: true });

// Fatal JavaScript errors report themselves to the error watch (the same
// staging area the tree's own log feeds), so the Coding agent can propose a
// fix. Only uncaught things are sent - an uncaught exception, an unhandled
// promise rejection, a script or stylesheet that would not load - because
// those are the fatal ones; console chatter is not. Each fault reports once
// and then at most every ten minutes, carrying the count it has reached; an
// extension's own errors and the browser's blank cross-origin "Script error."
// are ignored. Reporting must never be the thing that breaks the page, so the
// whole thing is wrapped and quiet.
(function () {
	if (window.jawnosJSErrorsReady) { return; }
	window.jawnosJSErrorsReady = true;
	var sent = {};      // signature -> when it was last sent
	var counts = {};    // signature -> times seen since that send
	var RESEND_MS = 10 * 60 * 1000;
	function report(message, source, line, column, stack) {
		try {
			message = String(message == null ? 'Unknown error' : message).slice(0, 500);
			source = String(source || '').slice(0, 500);
			stack = String(stack || '').slice(0, 2000);
			if (/^(?:chrome|moz|safari|edge)-extension:/.test(source)) { return; }
			if (/^Script error\.?$/.test(message)) { return; }
			var key = message + '|' + source + '|' + (line || 0);
			var now = Date.now();
			counts[key] = (counts[key] || 0) + 1;
			if (sent[key] && (now - sent[key]) < RESEND_MS) { return; }
			var count = counts[key];
			counts[key] = 0;
			sent[key] = now;
			var payload = JSON.stringify({
				page: location.pathname + location.hash,
				message: message,
				source: source,
				line: line || 0,
				column: column || 0,
				stack: stack,
				count: count,
				agent: navigator.userAgent
			});
			if (navigator.sendBeacon) {
				navigator.sendBeacon('/manager/js_error', new Blob([payload], { type: 'application/json' }));
			}
			else {
				var xhr = new XMLHttpRequest();
				xhr.open('POST', '/manager/js_error', true);
				xhr.setRequestHeader('Content-Type', 'application/json');
				xhr.send(payload);
			}
		}
		catch (e) { /* reporting must never be the error */ }
	}
	window.addEventListener('error', function (e) {
		if (e.target && e.target !== window && e.target.tagName) {
			var t = e.target.tagName;
			if (t === 'SCRIPT' || t === 'LINK') {
				var href = e.target.src || e.target.href || '';
				report('failed to load ' + t.toLowerCase() + ': ' + href, href, 0, 0, '');
			}
			return;
		}
		var err = e.error || {};
		report(e.message, e.filename, e.lineno, e.colno, err.stack || '');
	}, true);
	window.addEventListener('unhandledrejection', function (e) {
		var r = e.reason || {};
		var msg = (r && r.message) ? r.message : (typeof r === 'string' ? r : 'unknown reason');
		report('Unhandled promise rejection: ' + msg, '', 0, 0, (r && r.stack) || '');
	});
})();
