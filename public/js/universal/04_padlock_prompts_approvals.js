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
			jawnDeviceUuidSave(s.device);
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
		else if (!r && jawnPadlockPromptOpen && !jawnPadlockPromptBusy && typeof jawnPadlockPromptDismiss === 'function') {
			// answered or withdrawn elsewhere: this screen must not keep asking
			jawnPadlockPromptDismiss();
		}
	});
}

// The in-place confirmation. It is deliberately a small overlay: the device
// keeps its page, its scroll position and its history entry. A success opens
// the screen named in the request; this device is unchanged.
var jawnPadlockPromptOpen = false;
var jawnPadlockPromptTarget = '';
var jawnPadlockPromptId = '';
var jawnPadlockPromptBusy = false;
var jawnPadlockPromptSeen = {};

function jawnPadlockPromptDismiss(target) {
	if (typeof target !== 'undefined' && target !== '' && target !== jawnPadlockPromptTarget) { return; }
	var box = document.getElementById('jawn_padlock_prompt');
	if (box && box.parentNode) { box.parentNode.removeChild(box); }
	jawnPadlockPromptOpen = false;
	jawnPadlockPromptTarget = '';
	jawnPadlockPromptId = '';
	jawnPadlockPromptBusy = false;
}

// The request that was answered or withdrawn is gone everywhere: close the
// prompt only if it is that request, never a newer one.
function jawnPadlockPromptClear(requestId) {
	if (requestId && requestId !== jawnPadlockPromptId) { return; }
	jawnPadlockPromptDismiss();
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
	if (mode === 'private') { return jawnPadlockPromptText('Private apps'); }
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
	// The screen that pressed Go already shows its own approval dialog; it is
	// never asked again through the padlock prompt while that dialog is up.
	if (mode === 'go' && document.getElementById('jawnos_go_prompt')) { return; }
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
	jawnPadlockPromptId = requestId || '';
	jawnPadlockPromptBusy = false;
	mode = mode || 'locker';
	house = (typeof house === 'undefined') ? !target : !!house;
	var is_go = (mode === 'go');
	var contextLabel = is_go ? jawnPadlockPromptText('Go') : jawnPadlockContext(mode);
	var unlockLabel = is_go
		? jawnPadlockPromptText('Approve Go to {0}', deviceName || jawnPadlockPromptText('another machine'))
		: jawnPadlockUnlockLabel(mode, house, deviceName, sourceHost);

	var box = document.createElement('div');
	box.id = 'jawn_padlock_prompt';
	box.setAttribute('role', 'dialog');
	box.setAttribute('aria-modal', 'true');
	box.style.cssText = 'position:fixed;z-index:71000;left:50%;top:50%;transform:translate(-50%,-50%);width:min(92vw,360px);background:#161616;color:#f4f4f4;border:1px solid #444;border-radius:14px;padding:18px;box-shadow:0 12px 40px rgba(0,0,0,.55);font-family:sans-serif;text-align:center;';
	var title = document.createElement('div');
	title.style.cssText = 'font-size:19px;line-height:1.35;margin-bottom:6px;';
	title.textContent = is_go
		? jawnPadlockPromptText('Approve Go to {0}?', deviceName || jawnPadlockPromptText('another machine'))
		: (house ? jawnPadlockPromptText('Unlock the house?')
			: (deviceName ? jawnPadlockPromptText('Unlock {0}?', deviceName) : jawnPadlockPromptText('Unlock the locked screen?')));
	var note = document.createElement('div');
	note.style.cssText = 'font-size:14px;color:#bbb;margin-bottom:14px;min-height:18px;';
	note.textContent = is_go
		? ((sourceHost ? jawnPadlockPromptText('Requested by {0}', sourceHost) : jawnPadlockPromptText('Requested by another machine'))
			+ '. ' + jawnPadlockPromptText('Confirm with your fingerprint to open that machine.'))
		: ((sourceHost ? jawnPadlockPromptText('Requested by {0}', sourceHost) : jawnPadlockPromptText('Requested by another machine'))
			+ ' · ' + contextLabel + '. ' + jawnPadlockPromptText('Confirm with your fingerprint to open it.'));
	var go = document.createElement('button');
	go.type = 'button';
	var have_print = !!(window.JawnBiometricKey
		|| typeof window.jawnos_local_fingerprint === 'undefined'
		|| window.jawnos_local_fingerprint !== 0);
	go.textContent = is_go
		? jawnPadlockPromptText('Approve with fingerprint')
		: (have_print ? jawnPadlockPromptText('Unlock with fingerprint') : jawnPadlockPromptText('Approve on this device'));
	go.style.cssText = 'font-size:15px;padding:10px 16px;border-radius:9px;border:1px solid #2b6;background:#2b6;color:#08110a;font-weight:bold;cursor:var(--jawnos-cursor-pointer, pointer);margin:0 4px 8px 4px;';
	var no = document.createElement('button');
	no.type = 'button';
	no.textContent = jawnPadlockPromptText('Not now');
	no.style.cssText = 'font-size:15px;padding:10px 16px;border-radius:9px;border:1px solid #555;background:#222;color:#f4f4f4;cursor:var(--jawnos-cursor-pointer, pointer);margin:0 4px 8px 4px;';
	box.appendChild(title);
	box.appendChild(note);
	box.appendChild(go);
	box.appendChild(no);
	document.body.appendChild(box);

	no.onclick = function () {
		// withdraw it: the other screens must stop asking too
		$.post('/manager/security/padlock_request_cancel', { request_id: jawnPadlockPromptId }, function() {}, 'json');
		jawnPadlockPromptDismiss();
	};
	go.onclick = function () {
		jawnPadlockPromptBusy = true;
		go.disabled = true;
		no.disabled = true;
		note.textContent = jawnPadlockPromptText('Authenticate to continue...');
		// On the Android app the Keystore key is a real factor: the OS prompt is
		// what releases it, and its signature opens the target screen. A browser
		// (or an app with no enrolled key) falls back to the local confirm and
		// the device's pairing signature.
		var opened;
		if (is_go) {
			// A Go approval is its own signature: it names the request, not a
			// screen, and the server hands it to the machine that pressed Go.
			if (window.JawnBiometricKey && typeof jawnosBiometricGo === 'function') {
				opened = jawnosBiometricGo(requestId, deviceName, function (t) { note.textContent = t; });
			}
			else {
				opened = jawnPadlockConfirm(unlockLabel).then(function (ok) {
					if (!ok) { throw { error: 'cancelled' }; }
					note.textContent = jawnPadlockPromptText('Approving...');
					return jawnGoSignApproval(requestId, note);
				});
			}
		}
		else if (window.JawnBiometricKey && typeof jawnosBiometricUnlock === 'function') {
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
			note.textContent = is_go
				? jawnPadlockPromptText('Approved.')
				: ((res && res.already && !res.relayed) ? jawnPadlockPromptText('That screen was already open.') : jawnPadlockPromptText('Unlocked.'));
			setTimeout(function () { jawnPadlockPromptDismiss(); }, 1200);
		}).catch(function (err) {
			if (err && err.error === 'cancelled') { jawnPadlockPromptDismiss(); return; }
			jawnPadlockPromptBusy = false;
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
	var signKey = null;
	return jawnosDeviceKeyGet().then(function (key) {
		if (!key) { throw { error: 'not paired' }; }
		signKey = key;
		return $.post('/manager/security/padlock_challenge', { device_uuid: uuid });
	}).then(function (ch) {
		if (!ch || !ch.ok || !ch.nonce) { throw { error: (ch && ch.error) || 'no challenge' }; }
		var msg = 'padlock-unlock\n' + uuid + '\n' + (signedTarget ? signedTarget + '\n' : '') + ch.nonce;
		return crypto.subtle.sign('Ed25519', signKey, new TextEncoder().encode(msg)).then(function (sig) {
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

// A payment started on a device with no fingerprint (a laptop, or a tablet with
// only a PIN) is approved here, on a device whose Keystore key is behind a
// fingerprint prompt. The signed statement names the request, and the house
// binds that approval to the payment's digest.
function jawnosCryptoPaymentPrompt(data) {
	if (!data || !data.request_id) { return; }
	if (!window.JawnBiometricKey || typeof jawnosBiometricKeyCall !== 'function') { return; }
	var mine = jawnDeviceUuid();
	if (!mine) { return; }
	if (data.source_device && data.source_device === mine) { return; }
	if (data.targets && data.targets.length && data.targets.indexOf(mine) < 0) { return; }
	var lockLayer = document.getElementById('locked_screen');
	if (lockLayer && (lockLayer.offsetWidth || lockLayer.offsetHeight || lockLayer.getClientRects().length)) { return; }
	if (document.getElementById('jawn_crypto_pay_prompt')) { return; }

	var box = document.createElement('div');
	box.id = 'jawn_crypto_pay_prompt';
	box.setAttribute('role', 'dialog');
	box.setAttribute('aria-modal', 'true');
	box.style.cssText = 'position:fixed;z-index:72000;left:50%;top:50%;transform:translate(-50%,-50%);width:min(92vw,380px);background:#161616;color:#f4f4f4;border:1px solid #444;border-radius:14px;padding:18px;box-shadow:0 12px 40px rgba(0,0,0,.55);font-family:sans-serif;text-align:center;';
	var title = document.createElement('div');
	title.style.cssText = 'font-size:19px;line-height:1.35;margin-bottom:6px;font-weight:bold;';
	title.textContent = jawnPadlockPromptText('Approve a crypto payment?');
	var note = document.createElement('div');
	note.style.cssText = 'font-size:14px;color:#bbb;margin-bottom:14px;min-height:18px;white-space:pre-wrap;';
	note.textContent = (data.summary || '') + '\n' + jawnPadlockPromptText('Confirm with your fingerprint to approve it.');
	var go = document.createElement('button');
	go.type = 'button';
	go.textContent = jawnPadlockPromptText('Approve with fingerprint');
	go.style.cssText = 'font-size:15px;padding:10px 16px;border-radius:9px;border:1px solid #2b6;background:#2b6;color:#08110a;font-weight:bold;cursor:var(--jawnos-cursor-pointer, pointer);margin:0 4px 8px 4px;';
	var no = document.createElement('button');
	no.type = 'button';
	no.textContent = jawnPadlockPromptText('Not now');
	no.style.cssText = 'font-size:15px;padding:10px 16px;border-radius:9px;border:1px solid #555;background:#222;color:#f4f4f4;cursor:var(--jawnos-cursor-pointer, pointer);margin:0 4px 8px 4px;';
	box.appendChild(title);
	box.appendChild(note);
	box.appendChild(go);
	box.appendChild(no);
	document.body.appendChild(box);

	no.onclick = function() { box.remove(); };
	go.onclick = function() {
		go.disabled = true;
		no.disabled = true;
		note.textContent = jawnPadlockPromptText('Confirm your fingerprint...');
		$.post('/manager/security/biometric_challenge', { device_uuid: mine, purpose: 'pay' }).then(function(ch) {
			if (!ch || !ch.ok || !ch.nonce) { throw { error: (ch && ch.error) || 'challenge' }; }
			var msg = 'crypto-payment\n' + mine + '\n' + data.request_id + '\n' + ch.nonce;
			return jawnosBiometricKeyCall('sign', [jawnosB64(new TextEncoder().encode(msg)), jawnPadlockPromptText('Approve the crypto payment')]).then(function(res) {
				if (!res || !res.ok || !res.signature) { throw { error: (res && res.error) || 'not accepted' }; }
				return $.post('/manager/crypto/payment_approve', {
					device_uuid: mine, request_id: data.request_id, nonce: ch.nonce, signature: res.signature
				});
			});
		}).then(function(res) {
			if (!res || !res.ok) { throw { error: (res && res.error) || 'not accepted' }; }
			note.textContent = jawnPadlockPromptText('Approved.');
			setTimeout(function() { box.remove(); }, 1200);
		}).catch(function(err) {
			note.textContent = (typeof jawnosBiometricError === 'function') ? jawnosBiometricError(err) : jawnPadlockPromptText('That did not work. Try again.');
			go.disabled = false;
			no.disabled = false;
		});
	};
}

// A Go approval names the request, not a screen. The phone's Keystore key is
// the real factor: the OS fingerprint prompt releases it, and the house verifies
// the signature against the device's bio_pubkey.
function jawnosBiometricGo(requestId, deviceName, status) {
	status = status || function () {};
	var uuid = jawnDeviceUuid();
	if (!uuid) { return Promise.reject({ error: 'not paired' }); }
	if (!window.JawnBiometricKey) { return Promise.reject({ error: 'unavailable' }); }
	status(jawnPadlockPromptText('Confirm your fingerprint...'));
	return jawnosBiometricKeyReady(status).then(function () {
		status(jawnPadlockPromptText('Confirm your fingerprint...'));
		return $.post('/manager/security/biometric_challenge', { device_uuid: uuid, purpose: 'go' });
	}).then(function (ch) {
		if (!ch || !ch.ok || !ch.nonce) { throw { error: (ch && ch.error) || 'no challenge' }; }
		var msg = 'go-approve\n' + uuid + '\n' + requestId + '\n' + ch.nonce;
		var label = jawnPadlockPromptText('Approve Go to {0}', deviceName || jawnPadlockPromptText('another machine'));
		return jawnosBiometricKeyCall('sign', [jawnosB64(new TextEncoder().encode(msg)), label]).then(function (res) {
			if (!res || !res.ok || !res.signature) { throw { error: (res && res.error) || 'not accepted' }; }
			return $.post('/manager/security/go_approve', { kind: 'bio', device_uuid: uuid, request_id: requestId, nonce: ch.nonce, signature: res.signature });
		});
	}).then(function (res) {
		if (!res || !res.ok) { throw { error: (res && res.error) || 'not accepted' }; }
		return res;
	});
}

// A device that has the pairing key but no app bridge (a desktop window, or a
// browser) confirms with the platform prompt and signs the same approval. The
// server still verifies the paired key, so the finger is the gate, not a promise.
function jawnGoSignApproval(requestId, status) {
	var uuid = jawnDeviceUuid();
	if (!uuid) { return Promise.reject({ error: 'not paired' }); }
	if (!(window.crypto && crypto.subtle && crypto.subtle.sign)) { return Promise.reject({ error: 'unavailable' }); }
	var signKey = null;
	return jawnosDeviceKeyGet().then(function (key) {
		if (!key) { throw { error: 'not paired' }; }
		signKey = key;
		return $.post('/manager/security/padlock_challenge', { device_uuid: uuid });
	}).then(function (ch) {
		if (!ch || !ch.ok || !ch.nonce) { throw { error: (ch && ch.error) || 'no challenge' }; }
		var msg = 'go-approve\n' + uuid + '\n' + requestId + '\n' + ch.nonce;
		return crypto.subtle.sign('Ed25519', signKey, new TextEncoder().encode(msg)).then(function (sig) {
			return $.post('/manager/security/go_approve', { kind: 'pair', device_uuid: uuid, request_id: requestId, nonce: ch.nonce, signature: jawnosB64(sig) });
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

