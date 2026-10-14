// Paired devices (phase 2): a citizen session pairs this browser once - the
// ticket scan that signs it in is the pairing grant - and after that the device
// logs itself back in with a signed challenge: no ticket to lose, no password,
// any network. The private key is a non-extractable WebCrypto Ed25519 key kept
// in IndexedDB; the house stores only the public half. Resident and guest
// access stays ticket-only.
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

	if (onGate) {
		// at the gate: walk in on this device's own key, if it has one
		var uuid = localStorage.getItem('device_uuid');
		if (!uuid || !ed25519() || !crypto.subtle.importKey) { return; }
		var arm = true;
		setTimeout(function () { arm = false; }, 15000);
		idbGet('device_key').then(function (key) {
			if (!key || !arm) { return; }
			return post('/manager/device/challenge', { device_uuid: uuid }).then(function (r) {
				if (!r || !r.ok || !r.nonce) { return; }
				var msg = 'device-login\n' + uuid + '\n' + r.nonce;
				var enc = new TextEncoder();
				return crypto.subtle.sign('Ed25519', key, enc.encode(msg)).then(function (sig) {
					if (!arm) { return; }
					return post('/manager/device/login', { device_uuid: uuid, nonce: r.nonce, signature: b64(sig) }).then(function (r2) {
						if (r2 && r2.ok) { window.location.reload(); }
					});
				});
			});
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
})();
