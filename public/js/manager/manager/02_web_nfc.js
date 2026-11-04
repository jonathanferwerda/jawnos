// ---- Web NFC over the app's native bridge -----------------------------
// Chrome for Android ships NDEFReader; a plain WebView does not, so the app
// injects window.JawnNFC (JawnNfcBridge, its NfcAdapter reader-mode bridge) and
// jawnNfcAdapter() presents the same NDEFReader surface over it. The scan and
// write call sites below are then identical either way.
function jawnNfcAvailable() {
	if ('NDEFReader' in window) return true;
	return !!(window.JawnNFC && window.JawnNFC.available() === 'yes');
}
function jawnNfcMake() {
	// The app's own bridge (window.JawnNFC, Android reader mode) is preferred:
	// a Chromium WebView now exposes NDEFReader too, but the app cannot grant
	// the WebView's Web NFC the way it grants its bridge, so prefer the one we
	// drive. Chrome has no window.JawnNFC, so there the native NDEFReader wins.
	if (window.JawnNFC && window.JawnNFC.available() === 'yes') return jawnNfcAdapter();
	if ('NDEFReader' in window) return new NDEFReader();
	return jawnNfcAdapter();
}
function jawnNfcBase64ToBytes(b64) {
	var bin = atob(b64 || '');
	var out = new Uint8Array(bin.length);
	for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
	return out;
}
function jawnNfcBytesToBase64(bytes) {
	var b = new Uint8Array(bytes || []);
	var bin = '';
	for (var i = 0; i < b.length; i++) bin += String.fromCharCode(b[i]);
	return btoa(bin);
}
function jawnNfcAdapter() {
	var handlers = { reading: [], readingerror: [] };
	var pendingWrite = null;
	function dispatch(type, ev) {
		$.each(handlers[type] || [], function(i, cb) { try { cb(ev); } catch (e) {} });
	}
	// the app calls this from the native side with the tag it saw
	window.__jawnNfcEvent = function(type, payload) {
		payload = payload || {};
		if (type === 'reading') {
			var records = $.map(payload.records || [], function(r) {
				return { recordType: r.recordType, mediaType: r.mediaType, encoding: r.encoding, data: jawnNfcBase64ToBytes(r.data) };
			});
			dispatch('reading', { message: { records: records }, serialNumber: payload.serial });
		}
		else if (type === 'readingerror') { dispatch('readingerror', {}); }
		else if (type === 'write') {
			var w = pendingWrite;
			pendingWrite = null;
			if (w) { payload.ok ? w.resolve() : w.reject(new Error(payload.error || 'write failed')); }
		}
	};
	return {
		addEventListener: function(type, cb) { if (handlers[type]) handlers[type].push(cb); },
		scan: function(options) {
			options = options || {};
			var signal = options.signal;
			var result = window.JawnNFC.startScan();
			return new Promise(function(resolve, reject) {
				if (result !== 'ok') { reject(new Error('nfc scan: ' + result)); return; }
				if (signal) {
					var stop = function() { window.JawnNFC.stopScan(); };
					if (signal.aborted) { stop(); reject(new DOMException('AbortError', 'AbortError')); return; }
					signal.addEventListener('abort', stop);
				}
				resolve();
			});
		},
		write: function(message) {
			var records = $.map(message.records || [], function(r) {
				return { recordType: r.recordType, mediaType: r.mediaType, encoding: r.encoding, data: jawnNfcBytesToBase64(r.data) };
			});
			// A second write while one waits for a tag replaces the first, so the
			// first promise must settle instead of hanging the caller's state.
			if (pendingWrite) {
				var stale = pendingWrite;
				pendingWrite = null;
				try { stale.reject(new DOMException('superseded', 'AbortError')); } catch (e) {}
			}
			return new Promise(function(resolve, reject) {
				pendingWrite = { resolve: resolve, reject: reject };
				var result = window.JawnNFC.write(JSON.stringify({ records: records }));
				if (result !== 'ok') { pendingWrite = null; reject(new Error('nfc write: ' + result)); }
			});
		},
		// Tell the app to drop a write nobody is waiting for any more; otherwise
		// the next unrelated tag tapped would silently be overwritten.
		cancelWrite: function() {
			if (pendingWrite) {
				var w = pendingWrite;
				pendingWrite = null;
				try { w.reject(new DOMException('aborted', 'AbortError')); } catch (e) {}
			}
			if (window.JawnNFC && typeof window.JawnNFC.cancelWrite === 'function') {
				try { window.JawnNFC.cancelWrite(); } catch (e) {}
			}
		}
	};
}

// ---- the app's own camera (window.JawnCamera) ------------------------
// The app opens the OS camera or the OS video recorder; it hands the file
// back as base64 over window.__jawnCameraResult, which is posted to the
// ordinary upload route - the route files an image/video and creates the
// appointment for the app, exactly as the termux camera path does.
function jawnCameraAvailable() {
	return !!(window.JawnCamera && window.JawnCamera.available && window.JawnCamera.available() === 'yes');
}
function jawnCameraUpload(result) {
	var pending = window.__jawnCameraPending || {};
	window.__jawnCameraPending = null;
	var status = pending.status;
	var setStatus = function (text) { if (status) { $(status).text(text); } };
	if (!result || !result.ok) {
		setStatus(result && result.error && result.error !== 'cancelled' ? ('Capture failed: ' + result.error) : '');
		return;
	}
	var kind = result.kind === 'video' ? 'video' : 'image';
	// The app writes the capture into the Termux home it shares with the manager
	// and hands back only the path. A real photo's base64 is several megabytes,
	// which the WebView's binder transaction cannot carry - the camera opened and
	// the answer never arrived. The path keeps both the details view and the
	// wrapper on the one route that already knows how to file a picture.
	if (result.path) {
		$.ajax({
			url: '/manager/take_picture',
			type: 'POST',
			data: {
				app: pending.app || '',
				uuid: pending.uuid || '',
				camera: pending.camera || '0',
				timestamp: pending.timestamp || Date.now(),
				native_path: result.path,
				native_kind: kind,
				native_name: result.name || '',
				native_mime: result.mime || ''
			},
			success: function(response) {
				setStatus('Saved.');
				// The server resolved which row the capture belongs to (the app's
				// open session, else its newest one); refresh that row rather than
				// trusting a uuid this page did not know.
				if (response && response.uuid && pending.app && typeof appointmentDetailGrabber === 'function') {
					appointmentDetailGrabber(pending.app, response.uuid);
				}
				if (pending.app === 'camera' && typeof jawnCameraAppPool === 'function') { jawnCameraAppPool(); }
			},
			error: function() { setStatus('Upload failed.'); }
		});
		return;
	}
	if (!result.data) { setStatus('Capture failed: no file'); return; }
	var ext = kind === 'video' ? '.mp4' : '.jpg';
	var bin = atob(result.data);
	var bytes = new Uint8Array(bin.length);
	for (var i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
	var blob = new Blob([bytes], { type: result.mime || (kind === 'video' ? 'video/mp4' : 'image/jpeg') });
	var formData = new FormData();
	formData.append('app', pending.app || '');
	formData.append('uuid', pending.uuid || '');
	formData.append('timestamp', Date.now());
	formData.append('type', kind);
	formData.append('blob', blob, (pending.app || 'capture') + ext);
	$.ajax({
		url: '/manager/upload_file',
		type: 'POST',
		data: formData,
		success: function(response) {
			setStatus('Saved.');
			continent_record({ uuid: response.uuid, app: response.app, timestamp: response.timestamp });
			if (pending.app === 'camera' && typeof jawnCameraAppPool === 'function') { jawnCameraAppPool(); }
		},
		error: function() { setStatus('Upload failed.'); },
		cache: false,
		contentType: false,
		processData: false
	});
}
// the app calls this from the native side with the file it captured
window.__jawnCameraResult = function(result) { jawnCameraUpload(result); };

// ---- the app's launch extras (window.__jawnLaunchExtras) --------------
// The system's sms send and dial intents open the app with jawn_sms_number /
// jawn_sms_body / jawn_dial_number extras; the native side hands them here once
// the page is up. A share-to-sms opens that number's conversation with the body
// prefilled; a dial intent opens the Phone app with the number on the pad.
window.__jawnLaunchExtras = function(extras) {
	extras = extras || {};
	var run = function() {
		if (extras.sms_number) { jawnLaunchSms(extras.sms_number, extras.sms_body || ''); }
		else if (extras.dial_number) { jawnLaunchDial(extras.dial_number); }
	};
	var tries = 0;
	var ready = function() { return typeof windowMaker === 'function' && window.jQuery; };
	if (ready()) { run(); return; }
	var t = setInterval(function() {
		tries++;
		if (ready() || tries > 120) { clearInterval(t); if (tries <= 120) { run(); } }
	}, 500);
};
function jawnLaunchSms(number, body) {
	localStorage.setItem('mail_contact', '');
	localStorage.setItem('mail_phone', number);
	$.ajax({
		url: '/manager/chat',
		type: 'GET',
		data: {
			timestamp: Date.now(),
			window_maker: 'yes',
			phone: number,
			incoming_data: JSON.stringify({ settings: [{ setting: 'subsection', value: 'sms' }] })
		},
		success: function(response) {
			windowMaker(response);
			var w = $('.wind[app="chat"]');
			if (body) { w.find('#message').val(body); }
			w.find('#mail_transport').val('sms');
			if (typeof chatTransportOptions === 'function') { chatTransportOptions(); }
			if (typeof mailWebSocketStart === 'function') { mailWebSocketStart(); }
			if (typeof mailScrollBottom === 'function') { mailScrollBottom('load'); }
		}
	});
}
function jawnLaunchDial(number) {
	$.ajax({
		url: '/manager/phone',
		type: 'GET',
		data: { timestamp: Date.now(), window_maker: 'yes' },
		success: function(response) {
			windowMaker(response);
			setTimeout(function() {
				var w = $('.wind[app="phone"]');
				if (typeof jawnPhoneApp !== 'undefined' && jawnPhoneApp) { jawnPhoneApp.number = number; }
				w.find('#phone_app_display').text(number);
				w.find('.phone_app_tab[pane="dial"]').trigger('click');
			}, 500);
		}
	});
}
$(document).on('click', '.native_capture, .native_video', function() {
	if (!jawnCameraAvailable()) { return; }
	var b = $(this);
	var appointment = b.closest('.appointment');
	var app = b.attr('app') || appointment.attr('app');
	// the wrapper shows an app, not one session row; the server files the
	// capture onto the app's open session (else its newest row) when no uuid
	// is named, and answers with that row so the details view refreshes it
	var uuid = b.attr('uuid') || appointment.attr('uuid') || '';
	window.__jawnCameraPending = { app: app, uuid: uuid, camera: b.attr('capture') || '0', timestamp: Date.now() };
	if (b.hasClass('native_video')) { window.JawnCamera.video(); }
	else { window.JawnCamera.photo(b.attr('capture') || '0'); }
});

// ---- the house's phone facts (window.JawnPhone) -------------------------
// A call arrives when no page is open, so what the native half needs is handed
// to it and kept: the desk's blacklist (the CallScreeningService turns a listed
// caller away before the phone rings) and the house's numbers by name (the
// in-call screen names the caller). The calls it refused are picked up here and
// filed, so an ignored call still shows in the log. Refreshed on load and every
// few minutes; a browser has no window.JawnPhone and nothing happens.
function jawnPhoneSync() {
	if (!window.JawnPhone) { return; }
	if (typeof window.JawnPhone.setFacts === 'function') {
		$.ajax({
			url: '/manager/phone/sync',
			type: 'GET',
			data: { timestamp: Date.now() },
			success: function(response) {
				try {
					window.JawnPhone.setFacts(JSON.stringify({
						blocked: (response && response.blocked) || [],
						names: (response && response.names) || {},
						relationships: (response && response.relationships) || {},
						avatars: (response && response.avatars) || {},
						ivr: (response && response.ivr) || {}
					}));
				} catch (e) { }
			}
		});
	}
	if (typeof window.JawnPhone.takeBlockedCalls === 'function') {
		var calls = [];
		try { calls = JSON.parse(window.JawnPhone.takeBlockedCalls()) || []; } catch (e) { calls = []; }
		$.each(calls, function(i, c) {
			$.ajax({
				url: '/manager/phone/call',
				type: 'POST',
				data: { event: 'ignore', number: (c && c.number) || '', timestamp: (c && c.at) || Date.now() }
			});
		});
	}
	// the app's own record of the calls it saw (jawnPhoneAppFileCalls, phone.js):
	// a call taken with no page up leaves one, and this is where it is filed
	if (typeof jawnPhoneAppFileCalls === 'function') { jawnPhoneAppFileCalls(); }
}
if (window.JawnPhone) {
	jawnPhoneSync();
	setInterval(jawnPhoneSync, 300000);
}

function nfcInitializer() {
	if (nfc['initialized'] == false) {
		nfc['initialized'] = true;
		nfc['ndef'].addEventListener("readingerror", () => {
		});
		nfc['abort'].signal.onabort = function() {
			nfc['scanning'] = false;
		};
		nfc['ndef'].addEventListener("reading", ({ message, serialNumber }) => {
			// A tag seen while a write is armed belongs to that write, and a tag
			// reported just after a successful write is the same tag being read
			// back - neither is a tap, so neither may start or stop an app.
			if (nfc['writing']) { return; }
			if (nfc['lastWrite'] && Date.now() - nfc['lastWrite'] < 2500) { return; }

			var md = [];
			$.each(message.records || [], function(i,record) {
				if (record.recordType === "text" || record.recordType === "url") {
					// 6. Decode the binary DataView payload into a string
					try {
						const textDecoder = new TextDecoder(record.encoding || "utf-8");
						md.push({'text': textDecoder.decode(record.data) });
					} catch (e) {}
				}
				if (record.mediaType === "application/json") {
					try {
						const decoder = new TextDecoder();
						md.push(JSON.parse(decoder.decode(record.data)));
					} catch (e) {}
				}
			});
			if (!md.length) { return; }

			var jmessage = JSON.stringify(md);
			// Reader mode can report one presence twice (and a second reader
			// object would double every tap); one tap must act only once.
			var readKey = (serialNumber || '') + '|' + jmessage;
			if (nfc['lastReadKey'] === readKey && Date.now() - (nfc['lastReadAt'] || 0) < 1500) { return; }
			nfc['lastReadKey'] = readKey;
			nfc['lastReadAt'] = Date.now();

			var timestamp = Date.now();
			var lastWrite = nfc['lastWrite'];

			$.ajax({
				url: '/manager/nfc/read',
				type: 'POST',
				data: { message: jmessage, serial: serialNumber, last_write: lastWrite, timestamp: timestamp, benign: nfc['benign'] },
				success: function(response) {
					var jr = JSON.stringify(response);

					$('.nfc_read_status').text(response.status);
					if (response && response.construct_app && typeof peopleConstructOpen === 'function') {
						peopleConstructOpen(response.construct_app);
					}
					else if (response && response.crest_uuid && typeof peopleCrestOpen === 'function') {
						peopleCrestOpen(response.crest_uuid);
					}
					setTimeout(function() {
						$('.nfc_read_status').text('');
					},10000);
				//	alert('reading tag ' + jr);
				}
			});
		});
	}
}

$(document).on('click', '.nfc_benign_reader', function() {
	var nb = $(this);
	var enabled = nb.attr('enabled');
	clearTimeout(nfc['benignTimeout']);
	if (enabled == 'on') {
		nfc['benign'] = 'off';
	}
	else {
		nfc['benign'] = 'on';
		nfc['benignTimeout'] = setTimeout(function() {
			nfc['benign'] = 'off';
			nb.attr('enabled', nfc['benign']);
		},10000);
	}
	nb.attr('enabled', nfc['benign']);
});

async function nfcListener() {
	if (!nfc['ndef'] || nfc.scanning || nfc.writing) { return; }
	if (nfc.scanFailedAt && Date.now() - nfc.scanFailedAt < 2000) { return; }
	nfc.scanning = true;
	nfc['abort'] = new AbortController();
	try {
		await nfc['ndef'].scan({ signal: nfc['abort'].signal });
	}
	catch (error) {
		// A refused scan (permission, a second tab, the reader still busy)
		// must not wedge the reader: drop the flag and retry once after a
		// beat, never in a tight loop on every mouse event.
		nfc.scanning = false;
		nfc.scanFailedAt = Date.now();
		if (!nfc.scanRetry) {
			nfc.scanRetry = setTimeout(function() {
				nfc.scanRetry = null;
				nfcListener();
			}, 2000);
		}
	}
}

// Show a write's progress on its own tag card, so a failed or still-waiting
// write is visible instead of leaving the button lit and the reader disarmed.
function nfcText(text) {
	return (typeof jawnosT === 'function') ? jawnosT(text) : text;
}
function nfcWriteStatus(a, text, kind) {
	if (!a || !a.length) { return; }
	var row = a.closest('.nfc_settings');
	if (!row.length) { return; }
	row.find('.nfc_write_status').text(text || '').removeClass('on error').addClass(kind || '');
}

var nfcWriteTimer = null;
var nfcWriteSession = 0;

async function nfcWriter(msg,a) {
	if (device != 'mobile') { return; }
	if (!nfc['ndef'] || typeof nfc['ndef'].write !== 'function') {
		nfcWriteStatus(a, nfcText('No NFC reader here.'), 'error');
		return;
	}
	if (nfc.writing) { return; }

	// The tag carries only the row uuid's first 12 characters. The old write
	// embedded the whole settings row (control, taps, serials - hundreds of
	// bytes), which no longer fit a 144-byte NTAG213 once the tap count grew;
	// that is why a write would fail and only succeed on re-scan or on a
	// larger tag.
	var tag = String(msg.uuid || '').slice(0, 12);
	if (!tag.length) { return; }
	var encoder = new TextEncoder();
	var session = ++nfcWriteSession;
	nfc.writing = true;
	a.addClass('active_background');
	nfcWriteStatus(a, nfcText('Hold the tag to the phone…'), '');

	var expiry = new Promise(function(resolve, reject) {
		clearTimeout(nfcWriteTimer);
		nfcWriteTimer = setTimeout(function() {
			reject(new Error('timeout'));
		}, 25000);
	});

	try {
		// Web NFC's write must begin inside the click's gesture, so it is
		// called before any network round trip.
		await Promise.race([
			nfc['ndef'].write({
				records: [{
					recordType: 'mime',
					mediaType: 'application/json',
					data: encoder.encode(JSON.stringify({ tag: tag }))
				}]
			}),
			expiry
		]);
		nfc['lastWrite'] = Date.now();
		nfcWriteStatus(a, nfcText('Tag saved.'), 'on');
		// Stamp the write on the server after the tag itself is written; the
		// tag needs nothing from this round trip.
		$.ajax({ url: '/manager/nfc/write', type: 'POST', data: { uuid: msg.uuid, app: msg.app, type: msg.type } });
	}
	catch (error) {
		try { if (nfc['ndef'].cancelWrite) { nfc['ndef'].cancelWrite(); } } catch (e) {}
		if (error && error.message === 'timeout') {
			nfcWriteStatus(a, nfcText('No tag found. Hold the tag to the phone and try again.'), 'error');
		}
		else if (!error || error.name !== 'AbortError') {
			nfcWriteStatus(a, nfcText('Could not write the tag. Hold it still and try again.'), 'error');
		}
	}
	finally {
		clearTimeout(nfcWriteTimer);
		nfcWriteTimer = null;
		if (session == nfcWriteSession) {
			nfc.writing = false;
			a.removeClass('active_background');
			nfcListener();
		}
	}
}


$(document).on('click', 'input',function() {

	focused_input.removeClass('focused_input');
//	focused_input.css({'background-image': '' });
//	focused_input.trigger('change');
	focused_input = $(this);
//	focused_input.addClass('focused_input');

	if ($('#numberpad').is(':visible')) {
		focused_input.blur();
	}
});
$(document).on('click', 'textarea',function() {
	focused_input = $(this);

	if ($('#numberpad').is(':visible')) {
		focused_input.blur();
	}
});

$(document).on('click', '.app_act', function() {
	clearTimeout(searchTimeout);
});
var searchTimeout;

$(document).on('dblclick', 'input', function(i,e) {
	var s = $('#search');
	var search = s.val();
	if (search == '') {
		clipboardGetter(s);
	}
	else {
		clipboardSetter(search);
	}

	s.val('');
});

