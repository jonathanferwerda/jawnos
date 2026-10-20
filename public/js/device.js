// Paired devices (phase 2) and the recovery door (phase 3): a citizen session
// pairs this browser once - the ticket scan that signs it in is the pairing
// grant - and after that the device logs itself back in with a signed challenge:
// no ticket to lose, no password, any network. The private key is a
// non-extractable WebCrypto Ed25519 key kept in IndexedDB; the house stores only
// the public half. If every device is gone, the paper recovery code typed at the
// gate unwraps the house key and pairs the device on the spot. Resident and
// guest access stays ticket-only.
(function () {
	function b64(buf) {
		var bytes = new Uint8Array(buf);
		var s = '';
		for (var i = 0; i < bytes.length; i++) { s += String.fromCharCode(bytes[i]); }
		return btoa(s);
	}
	function idbOpen() {
		return new Promise(function (res, rej) {
			var r = indexedDB.open('jawn_device', 1);
			r.onupgradeneeded = function () { r.result.createObjectStore('keys'); };
			r.onsuccess = function () { res(r.result); };
			r.onerror = function () { rej(r.error); };
		});
	}
	function idbPut(key, val) {
		return idbOpen().then(function (db) {
			return new Promise(function (res, rej) {
				var tx = db.transaction('keys', 'readwrite');
				tx.objectStore('keys').put(val, key);
				tx.oncomplete = function () { res(); };
				tx.onerror = function () { rej(tx.error); };
			});
		});
	}
	function idbGet(key) {
		return idbOpen().then(function (db) {
			return new Promise(function (res, rej) {
				var tx = db.transaction('keys', 'readonly');
				var q = tx.objectStore('keys').get(key);
				q.onsuccess = function () { res(q.result); };
				q.onerror = function () { rej(q.error); };
			});
		});
	}
	function deviceLabel() {
		var ua = navigator.userAgent;
		var kind = /Android/i.test(ua) ? 'Android' : (/iPhone|iPad/i.test(ua) ? 'iOS' : (/Mac/i.test(ua) ? 'Mac' : (/Windows/i.test(ua) ? 'Windows' : 'Linux')));
		var browser = /Firefox\//.test(ua) ? 'Firefox' : (/Edg\//.test(ua) ? 'Edge' : (/Chrome\//.test(ua) ? 'Chrome' : 'Browser'));
		return browser + ' - ' + kind;
	}
	function post(url, data) {
		return $.ajax({ url: url, type: 'POST', data: data, dataType: 'json' });
	}
	function ed25519() {
		return !!(window.crypto && crypto.subtle && crypto.subtle.generateKey && window.TextEncoder);
	}

	var onGate = !!document.getElementById('president');

	// the gate's recovery door: the paper code unwraps the house key and pairs
	// this browser. Shown to everyone at the gate, but only the code opens it.
	function wireRecovery() {
		var toggle = document.getElementById('recovery_toggle');
		if (!toggle) { return; }
		var panel = document.getElementById('recovery_panel');
		var status = document.getElementById('recovery_status');
		toggle.addEventListener('click', function () {
			panel.style.display = panel.style.display === 'none' ? 'block' : 'none';
		});
		document.getElementById('recovery_submit').addEventListener('click', function () {
			var code = (document.getElementById('recovery_code_input').value || '').trim();
			if (!code) { status.textContent = 'Type the code first.'; return; }
			if (!ed25519()) { status.textContent = 'This browser cannot hold a device key.'; return; }
			status.textContent = 'Checking...';
			crypto.subtle.generateKey({ name: 'Ed25519' }, false, ['sign', 'verify']).then(function (pair) {
				return crypto.subtle.exportKey('spki', pair.publicKey).then(function (spki) {
					return post('/manager/device/recover', { code: code, pubkey: b64(spki), name: deviceLabel() }).then(function (r) {
						if (r && r.ok && r.device_uuid) {
							return idbPut('device_key', pair.privateKey).then(function () {
								localStorage.setItem('device_uuid', r.device_uuid);
								status.textContent = 'Recovered. Loading...';
								window.location.reload();
							});
						}
						status.textContent = (r && r.error === 'too many') ? 'Too many attempts. Try again later.' : 'That code was not accepted.';
					});
				});
			}).catch(function () { status.textContent = 'That code was not accepted.'; });
		});
	}

	// the signed walk-in: prove the key, get the session. The last step of the
	// gate's own key and of the approval door, once a citizen has approved it
	function signIn(uuid, key, guard) {
		return post('/manager/device/challenge', { device_uuid: uuid }).then(function (r) {
			if (!r || !r.ok || !r.nonce) { return; }
			var msg = 'device-login\n' + uuid + '\n' + r.nonce;
			return crypto.subtle.sign('Ed25519', key, new TextEncoder().encode(msg)).then(function (sig) {
				if (guard && !guard()) { return; }
				return post('/manager/device/login', { device_uuid: uuid, nonce: r.nonce, signature: b64(sig) }).then(function (r2) {
					if (r2 && r2.ok) { window.location.href = '/manager'; }
				});
			});
		});
	}

	// the signed-in session carries a warranty that lapses while a tab idles (phone
	// asleep, tab backgrounded) and the next touch would flash the gate. Prove the
	// key again quietly - challenge then login, no reload, no gate - so the warranty
	// is renewed under the user instead of asking them to walk back in.
	function reauth() {
		var uuid = localStorage.getItem('device_uuid');
		if (!uuid) { return Promise.resolve(); }
		return idbGet('device_key').then(function (key) {
			if (!key) { return; }
			return post('/manager/device/challenge', { device_uuid: uuid }).then(function (r) {
				if (!r || !r.ok || !r.nonce) { return; }
				var msg = 'device-login\n' + uuid + '\n' + r.nonce;
				return crypto.subtle.sign('Ed25519', key, new TextEncoder().encode(msg)).then(function (sig) {
					return post('/manager/device/login', { device_uuid: uuid, nonce: r.nonce, signature: b64(sig) });
				});
			});
		}).catch(function () {});
	}

	// keep the warranty warm: re-prove the key when the page becomes visible again
	// (the moment a sleeping phone or background tab wakes) and on a slow timer, so
	// an always-visible but idle desktop does not lapse either. Throttled so a burst
	// of focus/visibility/pageshow events does not hammer the house.
	function wireKeepalive() {
		if (!ed25519() || !localStorage.getItem('device_uuid')) { return; }
		var last = Date.now();
		function maybe() {
			var now = Date.now();
			if (now - last < 60000) { return; }
			last = now;
			reauth();
		}
		document.addEventListener('visibilitychange', function () {
			if (document.visibilityState === 'visible') { maybe(); }
		});
		window.addEventListener('focus', maybe);
		window.addEventListener('pageshow', maybe);
		setInterval(maybe, 25 * 60 * 1000);
	}

	// the approval door: ask the house; a citizen approves the short code on a
	// device that is already signed in; then walk in on the key made here
	function wireApproval() {
		var toggle = document.getElementById('approval_toggle');
		if (!toggle) { return; }
		var panel = document.getElementById('approval_panel');
		var codeEl = document.getElementById('approval_code');
		var status = document.getElementById('approval_status');
		var start = document.getElementById('approval_start');
		var timer = null;
		function ask() {
			if (!ed25519()) { status.textContent = 'This browser cannot hold a device key.'; return; }
			start.disabled = true;
			status.textContent = 'Asking the house...';
			crypto.subtle.generateKey({ name: 'Ed25519' }, false, ['sign', 'verify']).then(function (pair) {
				return crypto.subtle.exportKey('spki', pair.publicKey).then(function (spki) {
					return post('/manager/device/request', { pubkey: b64(spki), name: deviceLabel() }).then(function (r) {
						if (!r || !r.ok || !r.uuid) {
							start.disabled = false;
							status.textContent = (r && r.error === 'too many') ? 'Too many asks. Try again later.' : 'The house did not take the ask.';
							return;
						}
						codeEl.textContent = r.code;
						status.textContent = 'On a device that is already signed in: Security, then Devices, and approve this code. The approval can take a couple of minutes to reach this device; this page keeps checking and continues by itself.';
						var tries = 0;
						timer = setInterval(function () {
							tries++;
							if (tries > 240) { clearInterval(timer); status.textContent = 'The ask expired. Try again.'; start.disabled = false; return; }
							post('/manager/device/request_status', { uuid: r.uuid }).then(function (s) {
								if (!s) { return; }
								if (s.status === 'approved' && s.device_uuid) {
									clearInterval(timer);
									status.textContent = 'Approved. Loading...';
									idbPut('device_key', pair.privateKey).then(function () {
										localStorage.setItem('device_uuid', s.device_uuid);
										return signIn(s.device_uuid, pair.privateKey);
									});
								}
								else if (s.status === 'denied') { clearInterval(timer); status.textContent = 'The ask was denied.'; start.disabled = false; }
								else if (s.status === 'expired' || s.status === 'unknown') { clearInterval(timer); status.textContent = 'The ask expired. Try again.'; start.disabled = false; }
							});
						}, 3000);
					});
				});
			}).catch(function () { start.disabled = false; status.textContent = 'The house did not take the ask.'; });
		}
		toggle.addEventListener('click', function () {
			panel.style.display = panel.style.display === 'none' ? 'block' : 'none';
		});
		start.addEventListener('click', ask);
	}

	if (onGate) {
		wireRecovery();
		wireApproval();
		// at the gate: walk in on this device's own key, if it has one
		var uuid = localStorage.getItem('device_uuid');
		if (!uuid || !ed25519() || !crypto.subtle.importKey) { return; }
		var arm = true;
		setTimeout(function () { arm = false; }, 15000);
		idbGet('device_key').then(function (key) {
			if (!key || !arm) { return; }
			return signIn(uuid, key, function () { return arm; });
		}).catch(function () {});
		return;
	}

	// a signed-in page: pair this browser once, quietly. The keypair (not the
	// remembered uuid) is what says paired: a debrief can pour a uuid back into
	// localStorage of a browser that has no key, and that one pairs fresh.
	if (typeof signatorial !== 'string' || signatorial === 'unknown') { return; }
	if (!ed25519()) { return; }
	idbGet('device_key').then(function (existing) {
		if (existing) { return; }
		localStorage.removeItem('device_uuid');
		return crypto.subtle.generateKey({ name: 'Ed25519' }, false, ['sign', 'verify']).then(function (pair) {
			return crypto.subtle.exportKey('spki', pair.publicKey).then(function (spki) {
				return idbPut('device_key', pair.privateKey).then(function () {
					return post('/manager/device/pair', { pubkey: b64(spki), name: deviceLabel() }).then(function (r) {
						if (r && r.ok && r.device_uuid) { localStorage.setItem('device_uuid', r.device_uuid); }
					});
				});
			});
		});
	}).catch(function () {});
wireKeepalive();
})();
