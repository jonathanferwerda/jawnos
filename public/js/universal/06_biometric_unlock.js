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
	var uuid = jawnDeviceUuid();
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
	var uuid = jawnDeviceUuid();
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
// The app keeps its EC key in Android Keystore, and the OS deletes every key
// when the app is uninstalled - which is how a signature-change reinstall
// arrives - while enrolling a new fingerprint invalidates the old key. The
// house can only verify a signature from a public key it was given, so an
// unlock with no usable key must make and register one first; otherwise the
// padlock reports "no key" and stays shut however well the fingerprint reads.
// `hasKey` answers without a prompt, so an ordinary unlock asks nothing extra.
// An enrollment that is refused (a locked screen, no session) is not fatal:
// the unlock runs on and reports its own reason, and the caller's paired-key
// fallback still works exactly as it did before.
function jawnosBiometricKeyReady(status) {
	status = status || function () {};
	return jawnosBiometricKeyCall('hasKey', []).catch(function () { return { ok: false, error: 'unavailable' }; }).then(function (res) {
		if (res && res.ok) { return false; }
		var e = (res && res.error) || '';
		if (e !== 'no key' && e !== 'invalidated') { return false; }
		status(jawnPadlockPromptText('Set up this phone\'s fingerprint...'));
		return jawnosBiometricEnroll(status).then(function () { return true; }).catch(function () { return false; });
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
				var body = { device_uuid: uuid, nonce: ch.nonce, signature: res.signature, mode: mode, browser_tab_id: jawnosMediaTab() };
				if (house) { body.house = 1; }
				else if (target) { body.target = target; }
				return $.post('/manager/security/biometric_unlock', body);
			});
		});
	}
	function attempt() {
		return jawnosBiometricKeyReady(status).then(function () {
			status('Authenticate to unlock...');
			return once();
		});
	}
	return attempt().then(function (res) {
		if (!res || res.ok) { return res; }
		// The key signed, but the house knows no key for this device: an earlier
		// enrollment made the Keystore key without its public half reaching the
		// manager (the reinstall case, or a request lost on the way). Register the
		// key now and sign once more; this is never reached for a key the house
		// holds, so it cannot turn a genuine refusal into an open.
		if (res.error !== 'no biometric key') { throw { error: res.error || 'not accepted' }; }
		status(jawnPadlockPromptText('Registering this phone\'s fingerprint...'));
		return jawnosBiometricEnroll(status).then(attempt);
	}).then(function (res) {
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
	}).then(function (res) {
		if (note.length) { note.text('Unlocked. Loading...'); }
		if (res && res.unlock && typeof jawnosMediaApplyToken === 'function') {
			jawnosMediaApplyToken(mode, res.unlock, res.target);
		}
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
			if (res.unlock && typeof jawnosMediaApplyToken === 'function') {
				jawnosMediaApplyToken(mode, res.unlock, res.target);
			}
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
		$.ajax({ url: '/manager/security/fingerprint_unlock_status', type: 'GET', data: { token: token, browser_tab_id: jawnosMediaTab(), device_uuid: jawnDeviceUuid() }, cache: false })
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
	$.ajax({ url: '/manager/security/fingerprint_unlock', type: 'POST', data: { mode: mode, browser_tab_id: jawnosMediaTab(), device_uuid: jawnDeviceUuid() }, cache: false })
		.then(function (res) {
			if (res && res.pending && res.token) { poll(res.token, 0); return; }
			finish(res);
		})
		.catch(function () { finish({ ok: 0, error: 'unavailable' }); });
});

